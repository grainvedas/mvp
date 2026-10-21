-- Migration 66 (Phase 2, release 3 of Veda's combined brief of 19 Oct 2026: Parts E, F and G). Shared sourcing,
-- allocated at the farmer; GrainVeda's own brand said on its public page; what is kept open for the next phase.
--
--   E1  a farmer is in the state register once (by phone) and a client's farmer record is that farmer's consent to that
--       client: a scope's procurement takes only its own client's farmers (asked again here: footprints_a04_partner)
--   E2  "Member of": a farmer's FPO or aggregator (public.farmer_memberships; app.set_farmer_member by the Client Manager);
--       the procurement form filters by it ("ABFPO members": app.scope_farmer_members)
--   E3  sourcing partners: an entity with the role sourcing_partner (app.register_sourcing_partner, PAN first; a business
--       already known gets the role on its own record), on a scope (public.scope_partners, app.set_scope_partner,
--       app.remove_scope_partner, app.scope_partners) with the tick "Partner agrees to be named publicly"; a procurement's
--       "Procured through" is one of its scope's partners (pre-filled), and the public page says "Sourced through …" only
--       for a partner that agreed
--   E4  the season check across clients: what a farmer (his state farmer ID) sold through GrainVeda this season, every
--       client together, against his land × the yield per acre: a warning with the total and the limit only
--   E5  no cross-client visibility: the new tables are closed; their functions answer only the scope's own people
--   F   the public page says "Operated by GrainVeda (own brand)" for an own-brand client's lot (client.own_brand)
--   G1  every scope has an entry point (scopes.entry_point): "farmer_procurement" is the only one selectable today
--   G2  every record carries "farm-verified" (footprints.farm_verified, true today, set by the server); a lot is
--       farm-verified only when all its sources are (app.lot_farm_verified); the GI badge needs it (app.lot_gi_status)
--   G3  a buyer is linked silently to the registry (public.buyer_entities, closed): a domestic buyer by the PAN inside its
--       GSTIN, a foreign one by country and importer ID; never shown to anyone in the app
-- Additive: new columns, tables and functions; existing buyers linked (new rows only); replaced from their own text,
-- each change named: app.public_lot_journey, app.lot_gi_status, app.procurement_crop_checks.
select set_config('app.change_path', 'migration 66', true);

-- 1 · G1: the scope's entry point ------------------------------------------------------------------------------------
alter table public.scopes add column if not exists entry_point text not null default 'farmer_procurement'
  check (entry_point in ('farmer_procurement', 'received_lot'));
create or replace function app.scopes_entry_point() returns trigger
language plpgsql as $$
begin
  if new.entry_point <> 'farmer_procurement' and (tg_op = 'INSERT' or new.entry_point is distinct from old.entry_point) then
    raise exception 'entry point: only farmer procurement for now (a lot received from another client or a supplier comes later)' using errcode = '23514'; end if;
  return new;
end $$;
create trigger scopes_a1e_entry_point before insert or update of entry_point on public.scopes for each row execute function app.scopes_entry_point();

-- 2 · G2: farm-verified ------------------------------------------------------------------------------------------------
alter table public.footprints add column if not exists farm_verified boolean not null default true;
-- a person's record is farm-verified (every record today); only a server path may say otherwise (a declared outside
-- supplier, later). A change afterwards is refused by footprints_a0_api_update (not a column a person may change).
create or replace function app.footprints_farm_verified() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') then new.farm_verified := true; end if;
  return new;
end $$;
create trigger footprints_a03_farm_verified before insert on public.footprints for each row execute function app.footprints_farm_verified();

-- a lot is farm-verified when the record and every source it came from are (through every merge and split, as GI)
create or replace function app.lot_farm_verified(p_fp uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select f.farm_verified from public.footprints f where f.id = p_fp), true)
     and not exists (select 1 from app.lot_sources(p_fp) s join public.footprints e on e.id = s.entry_id where not e.farm_verified)
$$;

-- 3 · G3: buyers linked to the registry (never shown) ---------------------------------------------------------------------
alter table public.entities add column if not exists foreign_hash text unique;     -- a foreign importer: country + importer ID, keyed
create table if not exists public.buyer_entities (
  buyer_id uuid primary key references public.buyers(id),
  entity_id uuid not null references public.entities(id),
  basis text not null check (basis in ('gstin', 'importer')),
  linked_at timestamptz not null default now()
);
alter table public.buyer_entities enable row level security;
revoke all on public.buyer_entities from anon, authenticated;
create trigger zz_change_log after insert or update or delete on public.buyer_entities for each row execute function app.log_change('buyer_id');

create or replace function app.type_of_pan(p_pan text) returns public.entity_type
language sql immutable as $$
  select (case substr(p_pan, 4, 1) when 'C' then 'company' when 'F' then 'firm' when 'P' then 'individual' when 'T' then 'trust'
                                   when 'A' then 'society' when 'H' then 'huf' when 'G' then 'government' else 'company' end)::public.entity_type
$$;

create or replace function app.link_buyer(p_buyer uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare b public.buyers; v_pan text; v_hash text; e uuid; v_basis text;
begin
  select * into b from public.buyers where id = p_buyer;
  if b.id is null then return null; end if;
  if upper(btrim(b.country)) in ('IN', 'IND', 'INDIA') and b.gstin is not null then
    v_pan := substr(upper(regexp_replace(b.gstin, '\s', '', 'g')), 3, 10);
    if v_pan !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then return null; end if;
    v_hash := app.id_hash('pan', v_pan); v_basis := 'gstin';
    perform pg_advisory_xact_lock(hashtext('grainveda_registry'));
    select i.entity_id into e from public.entity_ids i where i.kind = 'pan' and i.current and i.hash = v_hash;
    if e is null then
      insert into public.entities (legal_name, entity_type, pan_hash, pan_masked, pan_pending)
      values (b.name, app.type_of_pan(v_pan), v_hash, app.mask_id('pan', v_pan), false) returning id into e;
      insert into public.entity_ids (entity_id, kind, value, hash, masked) values (e, 'pan', v_pan, v_hash, app.mask_id('pan', v_pan));
    end if;
  elsif nullif(btrim(coalesce(b.importer_id, '')), '') is not null then
    v_hash := app.id_hash('importer', upper(btrim(b.country)) || ':' || upper(regexp_replace(b.importer_id, '\s', '', 'g'))); v_basis := 'importer';
    perform pg_advisory_xact_lock(hashtext('grainveda_registry'));
    select id into e from public.entities where foreign_hash = v_hash;
    if e is null then
      insert into public.entities (legal_name, entity_type, pan_pending, foreign_hash) values (b.name, 'company', true, v_hash) returning id into e;   -- no PAN (a foreign importer)
    end if;
  else
    return null;
  end if;
  insert into public.entity_roles (entity_id, role) values (e, 'buyer') on conflict do nothing;
  insert into public.buyer_entities (buyer_id, entity_id, basis) values (b.id, e, v_basis)
  on conflict (buyer_id) do update set entity_id = excluded.entity_id, basis = excluded.basis, linked_at = now()
   where buyer_entities.entity_id is distinct from excluded.entity_id;
  return e;
end $$;
create or replace function app.buyers_registry() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.link_buyer(new.id);
  return null;
end $$;
create trigger buyers_z1_registry after insert or update of gstin, importer_id, country on public.buyers for each row execute function app.buyers_registry();
do $$ declare b record; begin
  for b in select id from public.buyers order by created_at loop perform app.link_buyer(b.id); end loop;
end $$;

-- 4 · E2/E3: sourcing partners, memberships -------------------------------------------------------------------------------
create table if not exists public.scope_partners (
  scope_id uuid not null references public.scopes(id),
  entity_id uuid not null references public.entities(id),
  named_publicly boolean not null default false,             -- "Partner agrees to be named publicly"
  added_by uuid, added_at timestamptz not null default now(),
  removed_at timestamptz, removed_by uuid, removed_reason text,
  primary key (scope_id, entity_id)
);
alter table public.scope_partners enable row level security;
revoke all on public.scope_partners from anon, authenticated;
create trigger zz_change_log after insert or update or delete on public.scope_partners for each row execute function app.log_change('scope_id', 'entity_id');
create trigger a01_closed_scope before insert or update or delete on public.scope_partners for each row execute function app.closed_scope_guard();
create trigger a02_client_status before insert or update or delete on public.scope_partners for each row execute function app.client_status_guard();

create table if not exists public.farmer_memberships (
  farmer_id uuid primary key references public.farmers(id),
  entity_id uuid references public.entities(id),                 -- null: no longer a member (the row stays)
  set_by uuid, set_at timestamptz not null default now()
);
alter table public.farmer_memberships enable row level security;
revoke all on public.farmer_memberships from anon, authenticated;
create trigger zz_change_log after insert or update or delete on public.farmer_memberships for each row execute function app.log_change('farmer_id');

-- GrainVeda's people who register a partner: a State Manager or a Client Manager (not the admin, not a client's login)
create or replace function app.works_clients() returns boolean
language sql stable security definer set search_path = public as $$
  select not app.is_admin() and not app.is_client_login()
     and (cardinality(app.my_state_ids()) > 0
          or exists (select 1 from app.eff_assignments(app.current_user_id()) a where a.lens = 'client' and a.op_role = 'client_account'))
$$;

create or replace function app.register_sourcing_partner(p_pan text, p_type public.entity_type, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v text; v_hash text; e public.entities; v_name text := btrim(coalesce(p_name, '')); v_new boolean := false;
begin
  if not app.works_clients() then raise exception 'a sourcing partner is registered by a State Manager or a Client Manager' using errcode = '42501'; end if;
  v := app.check_pan(p_pan, p_type);
  v_hash := app.id_hash('pan', v);
  perform pg_advisory_xact_lock(hashtext('grainveda_registry'));
  select en.* into e from public.entity_ids i join public.entities en on en.id = i.entity_id where i.kind = 'pan' and i.current and i.hash = v_hash;
  if e.id is null then
    if length(v_name) < 2 or length(v_name) > 200 then raise exception 'legal name: as on the PAN or the certificate of registration' using errcode = '22023'; end if;
    insert into public.entities (legal_name, entity_type, pan_hash, pan_masked, pan_pending, created_by)
    values (v_name, p_type, v_hash, app.mask_id('pan', v), false, app.current_user_id()) returning * into e;
    insert into public.entity_ids (entity_id, kind, value, hash, masked, created_by) values (e.id, 'pan', v, v_hash, app.mask_id('pan', v), app.current_user_id());
    v_new := true;
  elsif e.entity_type <> p_type then
    raise exception 'PAN: this business is known as a %, not a %', replace(e.entity_type::text, '_', ' '), replace(p_type::text, '_', ' ') using errcode = '22023';
  end if;
  insert into public.entity_roles (entity_id, role) values (e.id, 'sourcing_partner') on conflict do nothing;
  perform app.audit('sourcing_partner_registered', e.id, jsonb_build_object('pan', app.id_trace('pan', v), 'new', v_new), false);
  -- nothing about the business's other roles is said (A1, A4)
  return jsonb_build_object('entity_id', e.id, 'legal_name', e.legal_name, 'pan_masked', e.pan_masked, 'new', v_new);
end $$;

create or replace function app.sourcing_partners() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (app.works_clients() or app.is_admin()) then raise exception 'the registry is GrainVeda''s' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('entity_id', e.id, 'name', coalesce(e.trade_name, e.legal_name), 'legal_name', e.legal_name,
            'pan_masked', e.pan_masked) order by coalesce(e.trade_name, e.legal_name)), '[]'::jsonb)
            from public.entities e where exists (select 1 from public.entity_roles r where r.entity_id = e.id and r.role = 'sourcing_partner'));
end $$;

create or replace function app.set_scope_partner(p_scope uuid, p_entity uuid, p_named boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; v_old public.scope_partners;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'a scope''s sourcing partners are set by its Client Manager' using errcode = '42501'; end if;
  if not exists (select 1 from public.entity_roles where entity_id = p_entity and role = 'sourcing_partner') then
    raise exception 'sourcing partner: register it first (PAN)' using errcode = '22023'; end if;
  if p_entity = (select c.entity_id from public.clients c where c.id = sc.client_id) then
    raise exception 'sourcing partner: the client itself is not its own sourcing partner' using errcode = '22023'; end if;
  select * into v_old from public.scope_partners where scope_id = p_scope and entity_id = p_entity;
  insert into public.scope_partners (scope_id, entity_id, named_publicly, added_by)
  values (p_scope, p_entity, coalesce(p_named, false), app.current_user_id())
  on conflict (scope_id, entity_id) do update set named_publicly = excluded.named_publicly, removed_at = null, removed_by = null, removed_reason = null;
  perform app.audit('scope_partner', p_scope, jsonb_build_object('entity_id', p_entity, 'named_publicly', coalesce(p_named, false),
    'was', case when v_old.scope_id is null then null else jsonb_build_object('named_publicly', v_old.named_publicly, 'removed', v_old.removed_at is not null) end), false);
  return app.scope_partners(p_scope);
end $$;

create or replace function app.remove_scope_partner(p_scope uuid, p_entity uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'a scope''s sourcing partners are set by its Client Manager' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'a reason of 10 characters or more' using errcode = '22023'; end if;
  update public.scope_partners set removed_at = now(), removed_by = app.current_user_id(), removed_reason = v_reason
   where scope_id = p_scope and entity_id = p_entity and removed_at is null;
  if not found then raise exception 'sourcing partner: not on this scope' using errcode = '23514'; end if;
  perform app.audit('scope_partner_removed', p_scope, jsonb_build_object('entity_id', p_entity, 'reason', v_reason), false);
  return app.scope_partners(p_scope);
end $$;

-- the scope's partners, for the scope's own people (its operators, managers, its client's login); nobody else
create or replace function app.scope_partners(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := not app.is_client_login();
begin
  if not app.can_access_scope(p_scope) then raise exception 'not found' using errcode = 'P0002'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('entity_id', e.id, 'name', coalesce(e.trade_name, e.legal_name),
            'pan_masked', case when v_staff then e.pan_masked end, 'named_publicly', p.named_publicly) order by coalesce(e.trade_name, e.legal_name)), '[]'::jsonb)
            from public.scope_partners p join public.entities e on e.id = p.entity_id
           where p.scope_id = p_scope and p.removed_at is null);
end $$;

-- "Member of": the farmer's FPO or aggregator, set by its client's Client Manager (a filter, nothing more)
create or replace function app.set_farmer_member(p_farmer uuid, p_entity uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare fa public.farmers; v_old uuid;
begin
  select * into fa from public.farmers where id = p_farmer;
  if fa.id is null or not app.runs_client(fa.client_id) then
    raise exception 'a farmer''s membership is set by the Client Manager of his client' using errcode = '42501'; end if;
  select entity_id into v_old from public.farmer_memberships where farmer_id = p_farmer;
  if p_entity is null then
    update public.farmer_memberships set entity_id = null, set_by = app.current_user_id(), set_at = now() where farmer_id = p_farmer;
  else
    if not exists (select 1 from public.entity_roles where entity_id = p_entity and role = 'sourcing_partner') then
      raise exception 'member of: an FPO or aggregator registered as a sourcing partner' using errcode = '22023'; end if;
    insert into public.farmer_memberships (farmer_id, entity_id, set_by) values (p_farmer, p_entity, app.current_user_id())
    on conflict (farmer_id) do update set entity_id = excluded.entity_id, set_by = excluded.set_by, set_at = now();
  end if;
  perform app.audit('farmer_member', p_farmer, jsonb_build_object('entity_id', p_entity, 'was', v_old), false);
  return jsonb_build_object('farmer_id', p_farmer, 'member_of', p_entity);
end $$;

-- the memberships of a scope's client's farmers in its partners (the procurement form's filter "ABFPO members")
create or replace function app.scope_farmer_members(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.can_access_scope(p_scope) then raise exception 'not found' using errcode = 'P0002'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('farmer_id', m.farmer_id, 'entity_id', m.entity_id)), '[]'::jsonb)
            from public.farmer_memberships m join public.farmers fa on fa.id = m.farmer_id join public.scopes s on s.id = p_scope
           where fa.client_id = s.client_id
             and m.entity_id in (select p.entity_id from public.scope_partners p where p.scope_id = p_scope and p.removed_at is null));
end $$;
-- a farmer's membership, for his client's people (the farmer's page)
create or replace function app.farmer_member(p_farmer uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare fa public.farmers;
begin
  select * into fa from public.farmers where id = p_farmer;
  if fa.id is null or not (app.runs_client(fa.client_id) or app.can_access_client(fa.client_id)) or app.is_client_login() then
    raise exception 'not found' using errcode = 'P0002'; end if;
  return (select entity_id from public.farmer_memberships where farmer_id = p_farmer);
end $$;

-- E1/E3: a procurement takes its own client's farmer; "Procured through" is one of its scope's partners
create or replace function app.footprints_partner() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if new.stage_type <> 'procurement' then return new; end if;
  if new.farmer_id is not null and not exists (select 1 from public.farmers fa join public.scopes s on s.id = new.scope_id
                                                where fa.id = new.farmer_id and fa.client_id = s.client_id) then
    raise exception 'this farmer is not registered with this scope''s client (his consent to that client): register him for it first' using errcode = '23514'; end if;
  v := nullif(btrim(coalesce(new.payload ->> 'procured_through', '')), '');
  if v is null then
    if new.payload ? 'procured_through' then new.payload := new.payload - 'procured_through'; end if;
    return new;
  end if;
  if v !~ '^[0-9a-f-]{36}$' or not exists (select 1 from public.scope_partners p where p.scope_id = new.scope_id and p.entity_id = v::uuid and p.removed_at is null) then
    raise exception 'procured through: one of this scope''s sourcing partners' using errcode = '23514'; end if;
  return new;
end $$;
create trigger footprints_a04_partner before insert or update of payload, farmer_id on public.footprints for each row execute function app.footprints_partner();

-- the procurement form: "Procured through", after "Where", pre-filled from the scope's partner
update public.stage_definitions d
   set form_schema = (select jsonb_agg(f order by n) from (
          select f, n::numeric as n from jsonb_array_elements(d.form_schema) with ordinality as x(f, n)
          union all
          select '{"key": "procured_through", "type": "partner", "label": "Procured through", "section": "where", "required": false}'::jsonb,
                 (select n + 0.5 from jsonb_array_elements(d.form_schema) with ordinality as y(g, n) where g->>'key' = 'collection_point_id')) z)
 where d.stage_type = 'procurement'
   and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'collection_point_id')
   and not exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'procured_through');

-- 8 · the functions replaced, each from its text as migration 65 left it, with the change named -----------------------
-- the journey page: "Operated by GrainVeda (own brand)" (F); farm-verified (G2); "Sourced through …" for a partner that agreed (E3)
CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false; v_mkt text; v_dest text;   -- v_mkt, v_dest: migration 57
        v_src uuid[]; v_buy jsonb;                                                                              -- migration 61 (E2.3)
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      -- migration 50 (Part D): the village and the district, never the farmer's name or photo
      step := step || jsonb_build_object('farmer', jsonb_build_object('village', fm.village, 'district', fm.district));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id))
                   || jsonb_build_object('lab', (select case when l->>'name' is null then null
                        else jsonb_build_object('name', l->>'name', 'accreditation_no', l->>'accreditation_no') end
                        from (select app.qc_lab(cur.id) as l) x))                                       -- migration 60 (A5 on the public page)
                   || jsonb_build_object('markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name,
                        'verdict', pv.verdict, 'failed', pv.failed,
                        'limits', (select mp.params from public.market_profiles mp where mp.id = pv.profile_id))   -- migration 57
                        order by pv.created_at, pv.code), '[]'::jsonb)
                        from public.qc_profile_verdicts pv where pv.footprint_id = cur.id));                      -- migration 53
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'warehouse' then step := step || jsonb_build_object('days_in_storage', app.storage_days(cur.id)); end if;   -- migration 55
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', coalesce(cur.payload->>'village',      -- migration 52: from the lots
             app.batch_villages(cur.id)),                    -- migration 52b: the villages only, through a helper
        'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.village, g.qty_kg)
          from (select fa.name, fa.village, fa.district, sum(src.qty_out) as qty_kg                -- migration 49: one line a farmer
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb),
        -- migration 61 (E2.3): "2 farmers from 2 villages", the real counts
        'villages_n', (select count(distinct (fa.village, fa.district)) from public.footprints src join public.farmers fa on fa.id = src.farmer_id   -- migration 61b
                        where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)));
    end if;
    if cur.stage_type = 'shipment' then   -- migration 57: an export's country; nothing of a domestic dispatch's place
      select coalesce(o.payload->>'market', 'domestic'), o.payload->>'destination_country' into v_mkt, v_dest      -- the order's own words
        from public.footprints o where o.id = cur.prev_footprint_id and o.stage_type = 'commercial';
      step := step || jsonb_build_object('dispatched_on', cur.payload->>'dispatch_date',
        'destination', case when v_mkt = 'export' then coalesce(v_dest, cur.payload->>'destination') end);   -- before 54: the typed place
    end if;
    -- migration 57 (G21): checked by someone other than who recorded it (the public page says so only where true)
    step := step || jsonb_build_object('checked', cur.stage_type <> 'qr_activation' and cur.verified_by is not null
              and cur.verified_by <> cur.created_by
              and not exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory'),
              -- migration 59 (A2, Veda's brief of 19 Oct): the step recorded and checked by one person says so
              'same_person', cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by);
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    -- migration 46: the same person recorded a step and checked it, or recorded the next one (the approved words)
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by and not cur.is_grade_lot) then
      v_same := true;
    end if;
    v_later_maker := cur.created_by;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    -- migration 61 (E2.3, Veda's brief of 19 Oct 2026): a collection batch was bought from several farmers. One line for
    -- all the purchases ("Bought from 2 farmers: 250 kg", the villages' shares; never a name), not only the one its
    -- record points back to; each purchase still counts for "checked by another person".
    if cur.stage_type = 'village_batch' and jsonb_array_length(coalesce(cur.payload->'source_footprint_ids', '[]'::jsonb)) > 0 then
      v_src := array(select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x);
      select jsonb_build_object('stage', 'purchases', 'code', cur.footprint_code || ':purchases',
               'qty_in_kg', sum(src.qty_out), 'qty_out_kg', sum(src.qty_out), 'verified_at', max(src.verified_at),
               'created_at', min(src.created_at), 'captured_at', min(coalesce(src.captured_at, src.created_at)),
               'farmers_n', count(distinct src.farmer_id), 'purchases_n', count(*),
               'checked', bool_and(src.verified_by is not null and src.verified_by <> src.created_by
                          and not exists (select 1 from public.ledger l where l.footprint_id = src.id and l.event = 'supervisory')),
               'same_person', bool_or(src.verified_by is not null and src.verified_by = src.created_by))
        into v_buy from public.footprints src where src.id = any(v_src);
      v_buy := v_buy || jsonb_build_object('villages', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'farmers', g.n, 'qty_kg', g.kg,
                 'share_pct', round(g.kg / nullif((v_buy->>'qty_out_kg')::numeric, 0) * 100, 1)) order by g.kg desc, g.village)
          from (select fa.village, fa.district, count(distinct fa.id) as n, sum(src.qty_out) as kg                    -- migration 61b: as the heading counts
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id = any(v_src) group by fa.village, fa.district) g), '[]'::jsonb));
      steps := jsonb_build_array(v_buy) || steps;
      if (v_buy->>'same_person')::boolean or not (v_buy->>'checked')::boolean
         or exists (select 1 from public.footprints src where src.id = any(v_src) and src.created_by = cur.created_by) then
        v_independent := false; end if;
      if (v_buy->>'same_person')::boolean
         or exists (select 1 from public.footprints src where src.id = any(v_src) and src.created_by = cur.created_by) then
        v_same := true; end if;
      exit;
    end if;
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  -- migration 65 (Part D): the client's status in the scope's state; an ended client's page lives for the longer of
  -- best-before + 12 months and 24 months after the end (app.public_verification)
  return app.public_verification(v_scope.id, (select max(p.best_before) from app.lot_released_packs(seal.footprint_id) r join public.packs p on p.serial = r.serial),
   jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type,
               'own_brand', coalesce((select e.own_brand from public.entities e where e.id = v_client.entity_id), false)),   -- migration 66 (F)
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    -- migration 57 (G21): no same_person here (the ledger keeps it); the villages by share, with their farmers
    'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct, 'farmers', y.n)
                                  order by y.pct desc, y.village)
                 from (select fv.village, fv.district, round(sum(s.share) * 100, 1) as pct, count(distinct e.farmer_id) as n
                         from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id
                         join public.farmers fv on fv.id = e.farmer_id group by fv.village, fv.district) y), '[]'::jsonb),
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),
    'farm_verified', app.lot_farm_verified(seal.footprint_id),                                           -- migration 66 (G2)
    'sourced_through', (select coalesce(jsonb_agg(distinct coalesce(en.trade_name, en.legal_name)), '[]'::jsonb)   -- migration 66 (E3): only who agreed
                          from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id
                          join public.scope_partners sp on sp.scope_id = e.scope_id and sp.entity_id::text = e.payload->>'procured_through'
                               and sp.named_publicly and sp.removed_at is null
                          join public.entities en on en.id = sp.entity_id),                                                   -- migration 49
    'units', app.param_units(v_scope.id),                                                                 -- migration 59 (A3)
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    -- migration 62 (E2.1): the packs this lot made live (its shipments' codes), not every pack of its batches
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before),
                     'old_data', coalesce(bool_or(r.old_data), false))
                from app.lot_released_packs(seal.footprint_id) r join public.packs p on p.serial = r.serial)
  ));
end $function$;

-- G2: the GI badge needs GI-area origin and farm-verified
CREATE OR REPLACE FUNCTION app.lot_gi_status(p_fp uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not app.lot_farm_verified(p_fp) then 'non_gi'      -- migration 66 (G2): never GI unless farm-verified
              when count(*) = 0 then 'unknown'
              when bool_or(g = 'non_gi') then 'non_gi'
              when bool_and(g = 'gi') then 'gi'
              else 'unknown' end
    from (select app.entry_gi(s.entry_id) as g from app.lot_sources(p_fp) s) x $function$;

-- E4: the season check counts the farmer's sales to every client (his state farmer ID); the warning names no client
CREATE OR REPLACE FUNCTION app.procurement_crop_checks(f footprints, sc scopes)
 RETURNS footprints
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare cr public.crops; ans jsonb; miss jsonb; m int; inside boolean; gi numeric; expected numeric; before numeric;
begin
  select * into cr from public.crops where id = sc.crop_id;
  if jsonb_array_length(coalesce(cr.gap_items, '[]'::jsonb)) > 0 then
    select g.answers into ans from public.farmer_gap g where g.farmer_id = f.farmer_id and g.crop_id = cr.id;
    miss := app.gap_missing(cr.gap_items, ans);
    if jsonb_array_length(miss->'required') > 0 then
      raise exception 'good farming practice not complete for this farmer (%): %', cr.name,
        (select string_agg(x, ', ') from jsonb_array_elements_text(miss->'required') x) using errcode = '23514'; end if;
    if jsonb_array_length(miss->'optional') > 0 then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), 'good farming practice not filled: '
        || (select string_agg(x, ', ') from jsonb_array_elements_text(miss->'optional') x)); end if;
  end if;
  if cr.harvest_from is not null then
    m := extract(month from (coalesce(f.captured_at, now()) at time zone 'Asia/Kolkata'))::int;
    inside := case when cr.harvest_from <= cr.harvest_to then m between cr.harvest_from and cr.harvest_to
                   else m >= cr.harvest_from or m <= cr.harvest_to end;
    if not inside then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), format('outside the harvest window (%s–%s)',
        to_char(make_date(2000, cr.harvest_from, 1), 'Mon'), to_char(make_date(2000, cr.harvest_to, 1), 'Mon'))); end if;
  end if;
  -- migration 43: what the farmer has sold of this crop this season, with this lot, against GI land × yield per acre
  select fa.gi_land_acres into gi from public.farmers fa where fa.id = f.farmer_id;
  if gi is not null and cr.yield_per_acre_kg is not null then
    expected := gi * cr.yield_per_acre_kg;
    select coalesce(sum(coalesce(fp.qty_out, 0)), 0) into before
      from public.footprints fp join public.scopes s on s.id = fp.scope_id
     where (fp.farmer_id = f.farmer_id or fp.farmer_id in (select o.id from public.farmers o join public.farmers me on me.id = f.farmer_id   -- migration 66 (E4)
                                                             where me.state_farmer_id is not null and o.state_farmer_id = me.state_farmer_id))
       and fp.stage_type = 'procurement' and fp.status in ('pending', 'verified')
       and s.crop_id = cr.id and s.season_code = sc.season_code and fp.id is distinct from f.id;
    if before + coalesce(f.qty_out, 0) > expected then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), format('above the expected yield: %s of %s kg this season (%s acres of GI land)',
        round(before + coalesce(f.qty_out, 0)), round(expected), gi)); end if;
  end if;
  return f;
end $function$;


-- 9 · grants: the functions above are the way in -------------------------------------------------------------------------
revoke execute on function app.scopes_entry_point(), app.footprints_farm_verified(), app.lot_farm_verified(uuid), app.type_of_pan(text),
  app.link_buyer(uuid), app.buyers_registry(), app.works_clients(), app.footprints_partner()
  from public, anon, authenticated;
revoke execute on function app.register_sourcing_partner(text, public.entity_type, text), app.sourcing_partners(),
  app.set_scope_partner(uuid, uuid, boolean), app.remove_scope_partner(uuid, uuid, text), app.scope_partners(uuid),
  app.set_farmer_member(uuid, uuid), app.scope_farmer_members(uuid), app.farmer_member(uuid)
  from public, anon;
grant execute on function app.register_sourcing_partner(text, public.entity_type, text), app.sourcing_partners(),
  app.set_scope_partner(uuid, uuid, boolean), app.remove_scope_partner(uuid, uuid, text), app.scope_partners(uuid),
  app.set_farmer_member(uuid, uuid), app.scope_farmer_members(uuid), app.farmer_member(uuid)
  to authenticated;
grant execute on function app.public_lot_journey(text) to anon, authenticated;

notify pgrst, 'reload schema';
