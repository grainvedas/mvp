-- Migration 43 (Veda, 13 Oct 2026, "GrainVeda MVP — State Manager role", part D; FIX_LIST item 38): the farmer register
-- of a state. Release 3 of three. Her answers of 13 Oct:
--   · two farmer records are the same person when they have the same phone in the same state (one client cannot hold the
--     same phone twice already: farmers_client_phone_key); the register shows the phone masked (last four digits)
--   · a possible duplicate is saved but FLAGGED for the State Manager: he sees it on the register and in "Needs my
--     action", and decides (keep both: "not the same person", or deactivate one) before he issues the Farmer ID
--   · the GI land (acres under the GI crop, a new field) is needed before the Farmer ID; a draft may be saved without it
--   · the yield check: GI land × the crop's yield per acre is what the farmer can sell in a season; a lot that takes the
--     season's total past it is saved with a warning; past 120 % the farmer is flagged for the State Manager
-- Additive: one column, one table, functions and rules; no row is rewritten.

-- 1 · the GI land ---------------------------------------------------------------------------------------------------------
alter table public.farmers add column if not exists gi_land_acres numeric(8,2)
  check (gi_land_acres is null or (gi_land_acres > 0 and gi_land_acres <= 1000));
alter table public.farmers add constraint farmers_gi_land_within_land
  check (gi_land_acres is null or land_area_acres is null or gi_land_acres <= land_area_acres) not valid;
-- (not valid: no old row is judged; every new or changed row is)

-- the state a farmer belongs to: his own, or his client's home
create or replace function app.farmer_home(p_state uuid, p_client uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(p_state, (select c.state_id from public.clients c where c.id = p_client)) $$;

-- 2 · possible duplicates: the same phone in the same state, on another client's record --------------------------------------
create table if not exists public.farmer_dup_reviews (
  farmer_a   uuid not null references public.farmers(id),
  farmer_b   uuid not null references public.farmers(id),
  decision   text not null check (decision in ('distinct')),
  note       text not null check (btrim(note) <> ''),
  decided_by uuid not null references public.app_users(id),
  decided_at timestamptz not null default now(),
  primary key (farmer_a, farmer_b),
  check (farmer_a < farmer_b));
alter table public.farmer_dup_reviews enable row level security;
create policy farmer_dup_reviews_read on public.farmer_dup_reviews for select to authenticated using (
  exists (select 1 from public.farmers f where f.id = farmer_a and app.farmer_read(f.client_id, f.state_id)));
grant select on public.farmer_dup_reviews to authenticated;
-- written only by app.mark_not_duplicate

-- a phone as its last ten digits: "+91 98700 00002" and "9870000002" are one number
create or replace function app.phone10(p text) returns text
language sql immutable set search_path = public as $$ select right(app.phone_key(p), 10) $$;

-- the open possible duplicates of one farmer: other records (not deactivated) with his phone in his state, not cleared
create or replace function app.open_duplicates(p_farmer uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'farmer_code', o.farmer_code, 'client', c.name, 'status', o.status)
                            order by o.name), '[]'::jsonb)
    from public.farmers f
    join public.farmers o on o.id <> f.id and app.phone10(o.phone) = app.phone10(f.phone)
                         and app.farmer_home(o.state_id, o.client_id) = app.farmer_home(f.state_id, f.client_id)
    join public.clients c on c.id = o.client_id
   where f.id = p_farmer and f.status <> 'inactive' and o.status <> 'inactive'
     and not exists (select 1 from public.farmer_dup_reviews r where r.farmer_a = least(f.id, o.id) and r.farmer_b = greatest(f.id, o.id)) $$;

-- the State Manager of the farmers' state says two records are different people (they share a phone). Logged.
create or replace function app.mark_not_duplicate(p_farmer uuid, p_other uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare a public.farmers; b public.farmers;
begin
  select * into a from public.farmers where id = p_farmer;
  select * into b from public.farmers where id = p_other;
  if app.current_user_id() is null or a.id is null or b.id is null or a.id = b.id then
    raise exception 'farmer not found' using errcode = 'P0002'; end if;
  if not (app.i_staff_farmer(a.client_id, a.state_id) and app.i_staff_farmer(b.client_id, b.state_id)) then
    raise exception 'the State Manager of the farmers'' state decides on a possible duplicate' using errcode = '42501'; end if;
  if app.phone10(a.phone) is distinct from app.phone10(b.phone)
     or app.farmer_home(a.state_id, a.client_id) is distinct from app.farmer_home(b.state_id, b.client_id) then
    raise exception 'these two records are not a possible duplicate' using errcode = '23514'; end if;
  if coalesce(btrim(p_note), '') = '' then raise exception 'say why they are different people' using errcode = '23514'; end if;
  insert into public.farmer_dup_reviews (farmer_a, farmer_b, decision, note, decided_by)
  values (least(a.id, b.id), greatest(a.id, b.id), 'distinct', btrim(p_note), app.current_user_id())
  on conflict (farmer_a, farmer_b) do nothing;
  perform app.audit('farmer_duplicate_cleared', a.id, jsonb_build_object('name', a.name, 'farmer_code', a.farmer_code,
    'other', b.name, 'other_code', b.farmer_code, 'reason', btrim(p_note)));
end $$;

-- 3 · before the Farmer ID: the GI land, and no open possible duplicate -------------------------------------------------------
create or replace function app.farmers_register_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null then return new; end if;                          -- a person acting (not a seed or a migration)
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' and old.farmer_code is null then
    if new.gi_land_acres is null then
      raise exception 'the GI land (acres) is needed before the Farmer ID' using errcode = '23514'; end if;
    d := app.open_duplicates(new.id);
    if jsonb_array_length(d) > 0 then
      raise exception 'possible duplicate (same phone) of %: decide on the farmer register first',
        (select string_agg(coalesce(x->>'farmer_code', x->>'name') || ' (' || (x->>'client') || ')', ', ') from jsonb_array_elements(d) x)
        using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger farmers_z2_register_rules before update on public.farmers for each row execute function app.farmers_register_rules();

-- 4 · the season's sales against the expected yield ---------------------------------------------------------------------------
-- the season of a state's register: the newest scope's season
create or replace function app.state_season(p_state uuid) returns text
language sql stable security definer set search_path = public as $$
  select s.season_code from public.scopes s where s.state_id = p_state
   order by coalesce(s.activated_at, s.created_at) desc limit 1 $$;

-- what each farmer of a state sold in a season, per crop, and what his GI land should give (GI land × yield per acre)
create or replace function app.season_sales(p_state uuid, p_season text)
returns table (farmer_id uuid, crop_id uuid, sold_kg numeric, expected_kg numeric)
language sql stable security definer set search_path = public as $$
  select fp.farmer_id, s.crop_id, round(sum(coalesce(fp.qty_out, 0)), 1),
         round(max(fa.gi_land_acres * cr.yield_per_acre_kg), 1)
    from public.footprints fp
    join public.scopes s on s.id = fp.scope_id
    join public.farmers fa on fa.id = fp.farmer_id
    join public.crops cr on cr.id = s.crop_id
   where fp.stage_type = 'procurement' and fp.status in ('pending', 'verified') and s.season_code = p_season
     and app.farmer_home(fa.state_id, fa.client_id) = p_state
   group by fp.farmer_id, s.crop_id $$;

-- the farmers past 120 % of their expected yield in a season (one row a farmer: the crop furthest over)
create or replace function app.over_yield(p_state uuid, p_season text)
returns table (farmer_id uuid, crop_id uuid, sold_kg numeric, expected_kg numeric, ratio numeric)
language sql stable security definer set search_path = public as $$
  select distinct on (x.farmer_id) x.farmer_id, x.crop_id, x.sold_kg, x.expected_kg, round(x.sold_kg / x.expected_kg, 3)
    from app.season_sales(p_state, p_season) x
   where x.expected_kg > 0 and x.sold_kg > 1.2 * x.expected_kg
   order by x.farmer_id, x.sold_kg / x.expected_kg desc $$;

-- 5 · the register --------------------------------------------------------------------------------------------------------
-- p: {state, season?, client?, district?, status?, flag? (duplicate | over_yield | no_gi_land), q?, limit?, offset?}
create or replace function app.farmer_register(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st uuid := app.uuid_or_null(p->>'state'); season text; lim int; off int; res jsonb;
begin
  if app.current_user_id() is null or st is null or not (app.is_admin() or st = any (app.my_state_ids())) then
    raise exception 'the farmer register of a state is for its State Manager' using errcode = '42501'; end if;
  season := coalesce(nullif(p->>'season', ''), app.state_season(st));
  lim := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
  off := greatest(coalesce((p->>'offset')::int, 0), 0);
  with fa as (
    select f.*, c.name as client_name from public.farmers f join public.clients c on c.id = f.client_id
     where app.farmer_home(f.state_id, f.client_id) = st),
  dup as (
    select f.id, jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'farmer_code', o.farmer_code, 'client', o.client_name) order by o.name) as others
      from fa f join fa o on o.id <> f.id and app.phone10(o.phone) = app.phone10(f.phone)
     where f.status <> 'inactive' and o.status <> 'inactive'
       and not exists (select 1 from public.farmer_dup_reviews r where r.farmer_a = least(f.id, o.id) and r.farmer_b = greatest(f.id, o.id))
     group by f.id),
  sales as (select x.farmer_id, sum(x.sold_kg) as sold_kg, sum(x.expected_kg) as expected_kg,
                   max(case when x.expected_kg > 0 then x.sold_kg / x.expected_kg end) as ratio
              from app.season_sales(st, season) x group by x.farmer_id),
  rg as (
    select fa.*, d.others, s.sold_kg, s.expected_kg, s.ratio,
           array_remove(array[case when d.others is not null then 'duplicate' end,
                              case when s.ratio > 1.2 then 'over_yield' end,
                              case when fa.gi_land_acres is null and fa.status <> 'inactive' then 'no_gi_land' end], null) as flags
      from fa left join dup d on d.id = fa.id left join sales s on s.farmer_id = fa.id),
  m as (
    select * from rg r
     where (nullif(p->>'client', '') is null or r.client_id = app.uuid_or_null(p->>'client'))
       and (nullif(p->>'district', '') is null or lower(btrim(r.district)) = lower(btrim(p->>'district')))
       and (nullif(p->>'status', '') is null or r.status::text = p->>'status')
       and (nullif(p->>'flag', '') is null or (p->>'flag') = any (r.flags))
       and (nullif(p->>'q', '') is null or r.name ilike '%' || (p->>'q') || '%' or r.village ilike '%' || (p->>'q') || '%'
            or coalesce(r.farmer_code, '') ilike '%' || (p->>'q') || '%'))
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name) from public.states where id = st),
    'season', season,
    'seasons', coalesce((select jsonb_agg(distinct s.season_code) from public.scopes s where s.state_id = st), '[]'),
    'total', (select count(*) from m),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'farmer_code', m.farmer_code, 'name', m.name, 'guardian_name', m.guardian_name, 'village', m.village,
        'district', m.district, 'client', m.client_name, 'client_id', m.client_id, 'status', m.status,
        'phone_last4', right(app.phone_key(m.phone), 4),                   -- never the whole number on this screen
        'land_area_acres', m.land_area_acres, 'gi_land_acres', m.gi_land_acres,
        'sold_kg', m.sold_kg, 'expected_kg', m.expected_kg, 'ratio', round(m.ratio, 3),
        'flags', to_jsonb(m.flags), 'duplicates', coalesce(m.others, '[]'::jsonb)) order by m.name, m.id)
       from (select * from m order by m.name, m.id limit lim offset off) m), '[]'),
    'cards', jsonb_build_object(
       'farmers', (select count(*) from rg),
       'active', (select count(*) from rg where status = 'active'),
       'under_review', (select count(*) from rg where status = 'under_review'),
       'draft', (select count(*) from rg where status = 'draft'),
       'inactive', (select count(*) from rg where status = 'inactive'),
       'gi_acres', coalesce((select round(sum(gi_land_acres), 2) from rg where status = 'active'), 0),
       'land_acres', coalesce((select round(sum(land_area_acres), 2) from rg where status = 'active'), 0),
       'sold_kg', coalesce((select round(sum(sold_kg), 1) from rg), 0),
       'expected_kg', coalesce((select round(sum(expected_kg), 1) from rg where sold_kg is not null), 0),
       'selling', (select count(*) from rg where sold_kg > 0),
       'over_yield', (select count(*) from rg where 'over_yield' = any (flags)),
       'duplicates', (select count(*) from rg where 'duplicate' = any (flags)),
       'no_gi_land', (select count(*) from rg where 'no_gi_land' = any (flags)),
       'by_district', coalesce((select jsonb_agg(x order by x.farmers desc, x.district) from (
          select initcap(lower(btrim(district))) as district, count(*) as farmers, coalesce(round(sum(sold_kg), 1), 0) as sold_kg,
                 coalesce(round(sum(gi_land_acres), 2), 0) as gi_acres
            from rg where status <> 'inactive' group by 1 order by 2 desc, 1 limit 12) x), '[]')),
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(distinct jsonb_build_object('id', client_id, 'name', client_name)) from rg), '[]'),
       'districts', coalesce((select jsonb_agg(distinct initcap(lower(btrim(district)))) from rg), '[]')),
    'limit', lim, 'offset', off) into res;
  return res;
end $$;



-- 6 · functions brought up to these rules (their current definitions, changed where marked) -----------------------

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
     where fp.farmer_id = f.farmer_id and fp.stage_type = 'procurement' and fp.status in ('pending', 'verified')
       and s.crop_id = cr.id and s.season_code = sc.season_code and fp.id is distinct from f.id;
    if before + coalesce(f.qty_out, 0) > expected then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), format('above the expected yield: %s of %s kg this season (%s acres of GI land)',
        round(before + coalesce(f.qty_out, 0)), round(expected), gi)); end if;
  end if;
  return f;
end $function$;

CREATE OR REPLACE FUNCTION app.import_farmers(p_client uuid, p_rows jsonb, p_dry_run boolean DEFAULT true, p_scope_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare r jsonb; i int := 0; rn int; errs jsonb := '[]'::jsonb; ph text; area numeric; seen text[] := '{}';
        req text[] := array['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
        k text; n int := 0; known text[] := array['row', 'name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres', 'gi_land_acres'];   -- migration 43
begin
  if not app.farmer_create(p_client) then   -- migration 41: the Client Manager and procurement, not a State Manager
    raise exception 'farmers are added by the Client Manager of the client (or at Procurement)' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'no rows to import' using errcode = '23514'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'at most 2000 rows per import' using errcode = '23514'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    rn := coalesce((r->>'row')::int, i + 1);
    foreach k in array req loop
      if coalesce(btrim(r->>k), '') = '' then
        errs := errs || jsonb_build_object('row', rn, 'field', k, 'message', 'required'); end if;
    end loop;
    ph := app.normalise_in_mobile(r->>'phone');
    if coalesce(btrim(r->>'phone'), '') <> '' and ph is null then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'not a 10-digit Indian mobile number');
    elsif ph is not null and app.phone_key(ph) = any(seen) then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'same phone appears earlier in this file');
    elsif ph is not null and exists (select 1 from public.farmers f where f.client_id = p_client and app.phone_key(f.phone) = app.phone_key(ph)) then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'a farmer with this phone is already registered');
    end if;
    if ph is not null then seen := array_append(seen, app.phone_key(ph)); end if;
    begin
      area := nullif(btrim(r->>'land_area_acres'), '')::numeric;
      if area is not null and (area < 0 or area > 1000) then
        errs := errs || jsonb_build_object('row', rn, 'field', 'land_area_acres', 'message', 'must be between 0 and 1000'); end if;
    exception when others then
      errs := errs || jsonb_build_object('row', rn, 'field', 'land_area_acres', 'message', 'must be a number');
    end;
    begin                                                                   -- migration 43: GI land, optional
      if nullif(btrim(r->>'gi_land_acres'), '') is not null then
        if (r->>'gi_land_acres')::numeric <= 0 or (r->>'gi_land_acres')::numeric > coalesce(area, 1000) then
          errs := errs || jsonb_build_object('row', rn, 'field', 'gi_land_acres', 'message', 'more than 0 and not more than the land'); end if;
      end if;
    exception when others then
      errs := errs || jsonb_build_object('row', rn, 'field', 'gi_land_acres', 'message', 'must be a number');
    end;
  end loop;

  if jsonb_array_length(errs) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(errs) = 0, 'dry_run', p_dry_run, 'rows', i,
                              'errors', errs, 'inserted', 0);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.farmers (client_id, scope_ids, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, extra)
    values (p_client, coalesce(p_scope_ids, '{}'), 'draft', btrim(r->>'name'), btrim(r->>'guardian_name'),
            btrim(r->>'village'), btrim(r->>'district'), app.normalise_in_mobile(r->>'phone'),
            (r->>'land_area_acres')::numeric, nullif(btrim(r->>'gi_land_acres'), '')::numeric,
            coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(r) e where not e.key = any(known)), '{}'::jsonb) ||
            jsonb_build_object('imported', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', false, 'rows', i, 'errors', '[]'::jsonb, 'inserted', n);
end$function$;

CREATE OR REPLACE FUNCTION app.state_home(p_state uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'no access to this state' using errcode = '42501'; end if;
  if not exists (select 1 from public.states where id = p_state) then raise exception 'state not found' using errcode = 'P0002'; end if;
  with sc as (select s.* from public.scopes s where s.state_id = p_state),
  live as (
    select distinct sa.scope_id, sa.stage_type
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'
       and sa.scope_id in (select id from sc)),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from sc s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' and f.scope_id in (select id from sc)
     group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id
     where f.scope_id in (select id from sc) group by f.scope_id),
  waiting as (
    select f.scope_id, count(*) as n from public.footprints f
     where f.status = 'pending' and f.scope_id in (select id from sc) group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join sc s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  mgr as (
    select a.client_id, string_agg(distinct u.display_name, ', ') as names
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())
     group by a.client_id),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'draft') as scopes_setup,
           (select count(*) from sc s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(v.lots) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as lots,
           coalesce((select sum(q.n) from qr q join sc s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           coalesce((select sum(w.n) from waiting w join sc s on s.id = w.scope_id where s.client_id = c.id), 0) as waiting,
           (select m.names from mgr m where m.client_id = c.id) as managers,
           exists (select 1 from mgr m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id
     where c.state_id = p_state or exists (select 1 from sc s where s.client_id = c.id)),
  fw as (
    select f.id, f.name, f.village, f.client_id, c.name as client
      from public.farmers f join public.clients c on c.id = f.client_id
     where f.status = 'under_review' and f.reviewed_by is not null and coalesce(f.state_id, c.state_id) = p_state),
  fl as (
    select fl.id, fl.text, fl.created_at, fl.footprint_id, f.footprint_code, c.name as client
      from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
     where fl.status = 'open' and f.scope_id in (select id from sc)),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from sc s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- chain order, as on the admin's pipeline: each stage's average step in the active chains of the state; the seal last
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from sc s where s.status = 'active') then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from sc s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = p_state),
    'managers', coalesce((select jsonb_agg(u.display_name order by u.display_name) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and a.state_id = p_state and u.status = 'active'), '[]'),
    'clients', jsonb_build_object(
       'total', (select count(*) from cl where cl.state_id = p_state),
       'active', (select count(*) from cl where cl.state_id = p_state and scopes_active > 0),
       'without_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops where state_id = p_state),
       'state_not_set', (select count(*) from public.crops where state_id is null),
       'ready', (select count(*) from public.crops cr where cr.state_id = p_state and cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from sc s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from sc s where s.crop_id = cr.id),
                  'ready', cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0, 'missing', to_jsonb(app.crop_missing(cr))) order by cr.name)
                  from public.crops cr where cr.state_id = p_state), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from sc where status = 'active'),
       'setup', (select count(*) from sc where status = 'draft'),
       'closed', (select count(*) from sc where status = 'closed'),
       'qr_issued', coalesce((select sum(n) from qr), 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client', c.name, 'crop', cr.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'status', s.status) order by s.status, c.name)
                  from sc s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id), '[]')),
    'farmers', jsonb_build_object(
       'total', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id where coalesce(f.state_id, c.state_id) = p_state),
       'active', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id
                   where coalesce(f.state_id, c.state_id) = p_state and f.status = 'active')),
    'attention', jsonb_build_object(
       'no_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'no_manager_list', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'name', cl.name, 'code', cl.code) order by cl.name)
                                      from cl where cl.state_id = p_state and not has_manager), '[]'),
       'farmers_waiting', (select count(*) from fw),
       'farmers_list', coalesce((select jsonb_agg(to_jsonb(fw) order by fw.client, fw.name) from (select * from fw order by client, name limit 50) fw), '[]'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join sc s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'open_flags', (select count(*) from fl),
       -- migration 43: the farmer register's two flags for him
       'duplicates', (select count(*) from public.farmers f where app.farmer_home(f.state_id, f.client_id) = p_state and f.status <> 'inactive'
                        and jsonb_array_length(app.open_duplicates(f.id)) > 0),
       'over_yield', (select count(*) from app.over_yield(p_state, app.state_season(p_state))),
       'no_gi_land', (select count(*) from public.farmers f where app.farmer_home(f.state_id, f.client_id) = p_state
                        and f.status <> 'inactive' and f.gi_land_acres is null),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', fl.footprint_code, 'client', fl.client) order by fl.created_at) from fl), '[]')),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp
                           where pp.position is not null or pp.pending + pp.done > 0), '[]')
  ) into r;
  return r;
end $function$;

-- 7 · closed by default; opened by name ----------------------------------------------------------------------------------
revoke execute on function app.farmer_home(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.phone10(text) from public, anon, authenticated;
revoke execute on function app.open_duplicates(uuid) from public, anon, authenticated;
revoke execute on function app.mark_not_duplicate(uuid, uuid, text) from public, anon, authenticated;
revoke execute on function app.farmers_register_rules() from public, anon, authenticated;
revoke execute on function app.state_season(uuid) from public, anon, authenticated;
revoke execute on function app.season_sales(uuid, text) from public, anon, authenticated;
revoke execute on function app.over_yield(uuid, text) from public, anon, authenticated;
revoke execute on function app.farmer_register(jsonb) from public, anon, authenticated;

grant execute on function app.mark_not_duplicate(uuid, uuid, text) to authenticated;
grant execute on function app.farmer_register(jsonb) to authenticated;
grant execute on function app.open_duplicates(uuid) to authenticated;
