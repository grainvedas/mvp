-- GrainVeda MVP · migration 58 (release 11; Veda, 16 Oct 2026: "There should a mechanism to choose packs and in future
-- there will be more than 1 lakhs packs"; "carton size - cm sets them in the pack list"; on the HR Admin's screens: "report
-- to - it sees all people which should not be the case; department ... there should be drop down"; "proceed with 58").
--   Cartons   A pack type of the client's pack list may say how many packs go in a carton (the Client Manager sets it).
--             Packing then puts its packs in cartons by themselves: carton 1 holds packs 0001-0020, carton 2 the next
--             twenty, the last one what is left; each carton has its code (<batch>-C0001) and a label. A pack voided
--             in a carton opens the carton.
--   Orders    A sale of packs sets aside the cartons (and loose packs) it takes: the cartons chosen, then the oldest free
--             cartons, then loose packs; never what another live order has set aside. Kept in the sale's worked-out
--             values ("units"), so a correction sets them aside again.
--   Shipment  A carton's code stands for its packs: 1 lakh packs are about 5,000 scans of cartons. A pack or carton not
--             set aside for the order, an opened carton, or a pack shipped already is refused. The checks work on sets,
--             not one code at a time, so they stay quick with 1 lakh packs.
--   People    "Reports to" offers, and the database accepts, only a manager of the person's state (band Manager or
--             above, or one who holds a seat; head office, with no state, for everyone); the buddy a colleague of that
--             state. The department is one of a list the HR Admin keeps (it starts with nine). A spreadsheet import
--             leaves out a manager or a department that is not allowed, with a warning.
-- Nothing is deleted or rewritten: new columns, two new tables, new functions; existing packs, records and people stay
-- as they are (a department typed before stays until someone changes it).
select set_config('app.change_path', 'migration 58', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- Cartons
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.pack_skus add column packs_per_carton integer check (packs_per_carton is null or packs_per_carton between 1 and 1000);
alter table public.pack_batches add column last_carton integer not null default 0;
create table public.cartons (
  code          text primary key,
  batch_code    text not null references public.pack_batches (batch_code),
  footprint_id  uuid not null references public.footprints (id),
  scope_id      uuid not null references public.scopes (id),
  sku_id        uuid references public.pack_skus (id),
  seq           integer not null,
  first_serial  text not null,
  last_serial   text not null,
  n             integer not null check (n > 0),
  status        text not null default 'packed' check (status in ('packed', 'opened', 'void')),
  created_at    timestamptz not null default now());
create index cartons_footprint on public.cartons (footprint_id, sku_id, seq);
alter table public.packs add column carton_code text references public.cartons (code);
create index packs_carton on public.packs (carton_code) where carton_code is not null;
alter table public.cartons enable row level security;
revoke all on public.cartons from anon, authenticated;
grant select on public.cartons to authenticated;
create policy cartons_read on public.cartons for select to authenticated using (app.can_see_footprint(scope_id, 'packing'));
create trigger zz_change_log after insert or update or delete on public.cartons for each row execute function app.log_change('code');

-- the packs from first to last (numbers) of a batch, in cartons of p_k
create or replace function app.make_cartons(p_batch text, p_fp uuid, p_scope uuid, p_sku uuid, p_from integer, p_to integer, p_k integer)
returns integer language plpgsql security definer set search_path = public as $$
declare a integer := p_from; z integer; v_seq integer; v_code text; n integer := 0;
begin
  if p_k is null or p_to < p_from then return 0; end if;
  while a <= p_to loop
    z := least(a + p_k - 1, p_to);
    update public.pack_batches set last_carton = last_carton + 1 where batch_code = p_batch returning last_carton into v_seq;
    v_code := p_batch || '-C' || lpad(v_seq::text, greatest(4, length(v_seq::text)), '0');
    insert into public.cartons (code, batch_code, footprint_id, scope_id, sku_id, seq, first_serial, last_serial, n)
    values (v_code, p_batch, p_fp, p_scope, p_sku, v_seq, p_batch || '-' || lpad(a::text, greatest(4, length(a::text)), '0'),
            p_batch || '-' || lpad(z::text, greatest(4, length(z::text)), '0'), z - a + 1);
    update public.packs set carton_code = v_code
     where batch_code = p_batch and serial in (select p_batch || '-' || lpad(g::text, greatest(4, length(g::text)), '0') from generate_series(a, z) g);
    n := n + 1; a := z + 1;
  end loop;
  return n;
end $$;

-- the codes another live order of this packing record has set aside (cartons and packs)
create or replace function app.taken_units(p_packing uuid, p_except uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(u->>'code'), '{}')
    from public.footprints o, jsonb_array_elements(case when jsonb_typeof(o.computed->'units') = 'array' then o.computed->'units' else '[]'::jsonb end) u
   where o.stage_type = 'commercial' and o.prev_footprint_id = p_packing and o.status not in ('superseded', 'legacy') and o.id is distinct from p_except
$$;

-- what a sale of packs sets aside: per pack type that came in cartons, the cartons chosen, the oldest free cartons, then
-- loose packs (outside a carton or of an opened one), then the packs of a carton not taken whole (the smallest, the last)
create or replace function app.allocate_units(p_order uuid, p_packing uuid, p_lines jsonb, p_chosen jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_taken text[]; v_part text[]; v_chosen text[]; v_used text[] := '{}'; l jsonb; v_sku uuid; v_left integer; v_name text;
        ct record; v_code text; out jsonb := '[]'::jsonb;
begin
  if p_packing is null or not exists (select 1 from public.cartons where footprint_id = p_packing) then return null; end if;
  v_taken := app.taken_units(p_packing, p_order);
  select coalesce(array_agg(distinct pk.carton_code), '{}') into v_part
    from public.packs pk where pk.serial in (select unnest(v_taken)) and pk.carton_code is not null;
  select coalesce(array_agg(distinct upper(btrim(x))), '{}') into v_chosen
    from jsonb_array_elements_text(case when jsonb_typeof(p_chosen) = 'array' then p_chosen else '[]'::jsonb end) x where btrim(x) <> '';
  select string_agg(x, ', ') into v_code from unnest(v_chosen) x
   where not exists (select 1 from public.cartons c where c.code = x and c.footprint_id = p_packing and c.status = 'packed')
      or x in (select unnest(v_taken)) or x in (select unnest(v_part));
  if v_code is not null then raise exception 'commercial: % not a free carton of this lot', v_code using errcode = '23514'; end if;
  for l in select x from jsonb_array_elements(p_lines) x loop
    v_sku := (l->>'sku_id')::uuid; v_left := (l->>'units')::integer; v_name := l->>'name';
    if not exists (select 1 from public.cartons where footprint_id = p_packing and sku_id = v_sku) then continue; end if;
    for ct in select c.code, c.n, c.code = any (v_chosen) as chosen from public.cartons c
               where c.footprint_id = p_packing and c.sku_id = v_sku and c.status = 'packed'
                 and c.code not in (select unnest(v_taken)) and c.code not in (select unnest(v_part))
               order by (c.code = any (v_chosen)) desc, c.seq loop
      exit when v_left = 0;
      if ct.chosen and ct.n > v_left then
        raise exception 'commercial: the cartons chosen hold more packs of % than the order', v_name using errcode = '23514'; end if;
      if ct.n <= v_left then
        out := out || jsonb_build_array(jsonb_build_object('code', ct.code, 'kind', 'carton', 'sku_id', v_sku, 'n', ct.n));
        v_used := v_used || ct.code; v_left := v_left - ct.n;
      end if;
    end loop;
    if v_left > 0 then
      for v_code in select pk.serial from public.packs pk left join public.cartons c on c.code = pk.carton_code
                     where pk.footprint_id = p_packing and pk.sku_id = v_sku and pk.status = 'packed'
                       and pk.serial not in (select unnest(v_taken)) and coalesce(pk.carton_code, '-') not in (select unnest(v_taken))
                       and coalesce(pk.carton_code, '-') <> all (v_used)
                     order by case when pk.carton_code is null or c.status <> 'packed' then 0 when pk.carton_code = any (v_part) then 1 else 2 end,
                              c.n, c.seq desc, pk.serial
                     limit v_left loop
        out := out || jsonb_build_array(jsonb_build_object('code', v_code, 'kind', 'pack', 'sku_id', v_sku, 'n', 1));
        v_left := v_left - 1;
      end loop;
    end if;
    if v_left > 0 then
      raise exception 'commercial: only % packs of % can be set aside for this order (the rest are set aside for other orders)',
        (l->>'units')::integer - v_left, v_name using errcode = '23514'; end if;
  end loop;
  select string_agg(x, ', ') into v_code from unnest(v_chosen) x where x <> all (v_used);
  if v_code is not null then raise exception 'commercial: % not a carton of the pack types of this order', v_code using errcode = '23514'; end if;
  return out;
end $$;

-- the Commercial form: the free cartons of a packing record, per pack type, in runs (oldest first)
create or replace function app.available_cartons(p_packing uuid, p_except uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; v_taken text[];
begin
  select * into f from public.footprints where id = p_packing and stage_type = 'packing';
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  v_taken := app.taken_units(p_packing, p_except);
  return coalesce((
    with part as (select distinct pk.carton_code as code from public.packs pk where pk.serial in (select unnest(v_taken)) and pk.carton_code is not null),
    free as (select c.* from public.cartons c where c.footprint_id = p_packing and c.status = 'packed'
               and c.code not in (select unnest(v_taken)) and c.code not in (select code from part)),
    g as (select free.*, free.seq - row_number() over (partition by free.sku_id order by free.seq) as grp from free),
    r as (select g.sku_id, (array_agg(g.code order by g.seq))[1] as a, (array_agg(g.code order by g.seq desc))[1] as z,
                 count(*) as cartons, sum(g.n) as packs, min(g.seq) as s from g group by g.sku_id, g.grp)
    select jsonb_agg(jsonb_build_object('sku_id', k.id, 'sku', app.sku_name(k), 'per_carton', k.packs_per_carton,
             'cartons', x.cartons, 'packs', x.packs, 'runs', x.runs) order by app.sku_name(k))
      from (select r.sku_id, sum(r.cartons) as cartons, sum(r.packs) as packs,
                   jsonb_agg(jsonb_build_object('from', r.a, 'to', r.z, 'cartons', r.cartons, 'packs', r.packs) order by r.s) as runs
              from r group by r.sku_id) x join public.pack_skus k on k.id = x.sku_id), '[]'::jsonb);
end $$;

-- the carton labels of a packing record (no QR page: a carton's code is for the loaders)
create or replace function app.carton_labels(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; sc public.scopes; cr public.crops; cl public.clients;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) or f.stage_type <> 'packing' then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.is_my_stage(me, f.scope_id, 'packing') then
    raise exception 'labels are printed at Packing (or by a manager of this scope)' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  select * into cl from public.clients where id = sc.client_id;
  return jsonb_build_object('crop', cr.name, 'gi_tag', cr.gi_tag, 'gi_status', app.lot_gi_status(f.id), 'season', sc.season_code,
    'geography', sc.geography, 'client', cl.name, 'batch_code', f.payload->>'batch_code',
    'cartons', coalesce((select jsonb_agg(jsonb_build_object('code', c.code, 'sku', app.sku_name(k), 'n', c.n, 'first_serial', c.first_serial,
                 'last_serial', c.last_serial, 'status', c.status,
                 'packed_on', (select min(p.packed_on) from public.packs p where p.carton_code = c.code),
                 'best_before', (select min(p.best_before) from public.packs p where p.carton_code = c.code)) order by c.seq)
               from public.cartons c left join public.pack_skus k on k.id = c.sku_id where c.footprint_id = f.id and c.status <> 'void'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Departments and who a person reports to
-- ---------------------------------------------------------------------------------------------------------------------
create table public.departments (
  name        text primary key check (length(btrim(name)) between 2 and 60),
  active      boolean not null default true,
  sort        integer not null default 100,
  created_by  uuid,
  created_at  timestamptz not null default now());
alter table public.departments enable row level security;
revoke all on public.departments from anon, authenticated;
grant select on public.departments to authenticated;
create policy departments_read on public.departments for select to authenticated using (true);
create trigger zz_change_log after insert or update or delete on public.departments for each row execute function app.log_change('name');
insert into public.departments (name, sort) values
  ('Operations', 10), ('Field Procurement', 20), ('Quality', 30), ('Warehouse & Logistics', 40), ('Sales & Export', 50),
  ('Finance & Accounts', 60), ('HR & Admin', 70), ('Technology', 80), ('Management', 90);

create or replace function app.set_department(p_name text, p_active boolean default true) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); v text := btrim(coalesce(p_name, '')); d public.departments;
begin
  if not (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())) then
    raise exception 'departments are kept by the HR Admin' using errcode = '42501'; end if;
  if length(v) < 2 or length(v) > 60 then raise exception 'a department name is 2 to 60 characters' using errcode = '23514'; end if;
  select * into d from public.departments where lower(name) = lower(v);
  if d.name is null then
    insert into public.departments (name, active, created_by) values (v, coalesce(p_active, true), me) returning * into d;
  else
    update public.departments set active = coalesce(p_active, true) where name = d.name returning * into d;
  end if;
  perform app.audit('department_set', null, jsonb_build_object('name', d.name, 'active', d.active), false);
  return to_jsonb(d);
end $$;

-- a manager of the state: band Manager or above, or one who holds a seat; head office (no state) for every state
create or replace function app.manager_ok(p_mgr uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users u left join public.employee_org o on o.employee_id = u.id
                  where u.id = p_mgr and not u.external and not u.test_data and u.status in ('invited', 'onboarding', 'active')
                    and (o.designation_band in ('Manager', 'Senior Manager', 'Head') or u.system_role in ('admin', 'hr_admin')
                         or exists (select 1 from public.assignments a where a.employee_id = u.id and a.active
                                      and (a.ends_on is null or a.ends_on >= app.today()) and a.op_role in ('state_supervisor', 'client_account')))
                    and (p_state is null or o.base_state_id is null or o.base_state_id = p_state))
$$;
create or replace function app.buddy_ok(p_buddy uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users u left join public.employee_org o on o.employee_id = u.id
                  where u.id = p_buddy and not u.external and not u.test_data and u.status in ('onboarding', 'active') and u.system_role <> 'admin'
                    and (p_state is null or o.base_state_id is null or o.base_state_id = p_state))
$$;
-- the choices the HR screens offer for a person based in p_state (the same rule the database keeps)
create or replace function app.org_choices(p_state uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR of the person''s state chooses these' using errcode = '42501'; end if;
  if p_state is not null and not app.hr_full() and p_state <> all (app.my_hr_states()) then
    raise exception 'only HR of the person''s state chooses these' using errcode = '42501'; end if;                                       -- HR works by state
  return jsonb_build_object(
    'managers', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'band', o.designation_band,
                   'seat', case when u.system_role = 'admin' then 'admin' when u.system_role = 'hr_admin' then 'hr_admin'
                                when exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.op_role = 'state_supervisor') then 'state_manager'
                                when exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.op_role = 'client_account') then 'client_manager' end,
                   'state', (select s.name from public.states s where s.id = o.base_state_id)) order by u.display_name)
                 from public.app_users u left join public.employee_org o on o.employee_id = u.id where app.manager_ok(u.id, p_state)), '[]'::jsonb),
    'buddies', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'band', o.designation_band,
                   'state', (select s.name from public.states s where s.id = o.base_state_id)) order by u.display_name)
                 from public.app_users u left join public.employee_org o on o.employee_id = u.id where app.buddy_ok(u.id, p_state)), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(d.name order by d.sort, d.name) from public.departments d where d.active), '[]'::jsonb));
end $$;

-- the database keeps the rule, whoever writes (the screens, the import, the API); the owner's own writes (seeds,
-- migrations) are not a person's choice and are left alone
create or replace function app.employee_org_choices() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_dept text;
begin
  if app.current_user_id() is null then return new; end if;
  if new.reports_to is not null and (tg_op = 'INSERT' or new.reports_to is distinct from old.reports_to)
     and (new.reports_to = new.employee_id or not app.manager_ok(new.reports_to, new.base_state_id)) then
    raise exception 'reports to: choose a manager of the person''s state (band Manager or above, or one who holds a seat)' using errcode = '23514'; end if;
  if new.buddy is not null and (tg_op = 'INSERT' or new.buddy is distinct from old.buddy)
     and (new.buddy = new.employee_id or not app.buddy_ok(new.buddy, new.base_state_id)) then
    raise exception 'buddy: choose a colleague of the person''s state' using errcode = '23514'; end if;
  if new.department is not null and (tg_op = 'INSERT' or new.department is distinct from old.department) then
    select d.name into v_dept from public.departments d where lower(d.name) = lower(btrim(new.department)) and d.active;
    if v_dept is null then
      raise exception 'department: choose one from the list (the HR Admin keeps it)' using errcode = '23514'; end if;
    new.department := v_dept;                                                                     -- the list's spelling
  end if;
  return new;
end $$;
create trigger employee_org_b5_choices before insert or update on public.employee_org for each row execute function app.employee_org_choices();

-- The Commercial form: the cartons an order may choose (where the lot came in cartons)
update public.stage_definitions d
   set form_schema = (select jsonb_agg(f order by n) from (
          select f, n::numeric as n from jsonb_array_elements(d.form_schema) with ordinality as x(f, n)
          union all
          select '{"key": "cartons", "type": "order_cartons", "label": "Cartons", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true}'::jsonb,
                 (select n + 0.5 from jsonb_array_elements(d.form_schema) with ordinality as y(g, n) where g->>'key' = 'packs')) z)
 where d.stage_type = 'commercial'
   and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'packs')
   and not exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'cartons');

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen58.py)
-- ---------------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION app.make_packs(p_fp uuid, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; pk jsonb; i int; n int := 0; v_on date; v_bb date; v_shelf int; b public.pack_batches; v_total int;
        v_sku public.pack_skus; v_mshelf int; v_bymat jsonb;                                              -- migration 53
        v_first int;                                                                                      -- migration 58
begin
  select * into f from public.footprints where id = p_fp;
  update public.packs set status = 'void', void_reason = coalesce(p_reason, 'record corrected'), voided_by = app.current_user_id(), voided_at = now()
   where footprint_id = f.id and status = 'packed';
  update public.cartons set status = 'void' where footprint_id = f.id and status <> 'void';               -- migration 58
  if f.status = 'superseded' then return 0; end if;
  insert into public.pack_batches (batch_code, footprint_id, scope_id) values (f.payload->>'batch_code', f.id, f.scope_id)
  on conflict (batch_code) do nothing;
  select * into b from public.pack_batches where footprint_id = f.id;
  if b.batch_code is null then return 0; end if;                    -- a typed code that another record already carries
  select coalesce(sum((x->>'units')::int), 0) into v_total from jsonb_array_elements(coalesce(f.payload->'packets', '[]'::jsonb)) x;
  if v_total > 20000 then raise exception 'at most 20000 packs in one packing record (% given)', v_total using errcode = '23514'; end if;
  v_on := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  select cr.shelf_life_days, cr.shelf_life_by_material into v_shelf, v_bymat from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = f.scope_id;
  v_bb := case when v_shelf is null then null else v_on + v_shelf end;
  for pk in select x from jsonb_array_elements(coalesce(f.payload->'packets', '[]'::jsonb)) x loop
    -- migration 53 (C6): a pack from the pack list takes its material's shelf life (the crop's, set by the State Manager)
    select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id';
    v_mshelf := coalesce(case when v_sku.id is not null then (v_bymat->>v_sku.material)::int end, v_shelf);
    v_bb := case when v_mshelf is null then null else v_on + v_mshelf end;
    v_first := b.last_serial + 1;                                                                      -- migration 58
    for i in 1 .. coalesce((pk->>'units')::int, 0) loop
      update public.pack_batches set last_serial = last_serial + 1 where batch_code = b.batch_code returning * into b;
      insert into public.packs (serial, batch_code, footprint_id, scope_id, size_kg, packed_on, best_before, sku_id)
      values (b.batch_code || '-' || lpad(b.last_serial::text, greatest(4, length(b.last_serial::text)), '0'), b.batch_code, f.id, f.scope_id,
              (pk->>'size_kg')::numeric, v_on, v_bb, v_sku.id);
      n := n + 1;
    end loop;
    -- migration 58: the pack type says how many go in a carton (the Client Manager's pack list): cartons of them
    if v_sku.packs_per_carton is not null and b.last_serial >= v_first then
      perform app.make_cartons(b.batch_code, f.id, f.scope_id, v_sku.id, v_first, b.last_serial, v_sku.packs_per_carton);
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION app.void_pack(p_serial text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); p public.packs;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null or me is null or not app.can_see_footprint(p.scope_id, 'packing') then raise exception 'pack not found' using errcode = 'P0002'; end if;
  if not app.is_my_stage(me, p.scope_id, 'packing') then raise exception 'a pack is voided at Packing (or by a manager of this scope)' using errcode = '42501'; end if;
  if p.status = 'void' then raise exception 'this pack is void already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'say why the pack is void (at least 10 characters)' using errcode = '23514'; end if;
  update public.packs set status = 'void', void_reason = left(btrim(p_reason), 300), voided_by = me, voided_at = now() where serial = p.serial returning * into p;
  if p.carton_code is not null then update public.cartons set status = 'opened' where code = p.carton_code and status = 'packed'; end if;   -- migration 58
  perform app.audit('pack_voided', p.footprint_id, jsonb_build_object('serial', p.serial, 'reason', p.void_reason), true);
  return to_jsonb(p);
end $function$;

CREATE OR REPLACE FUNCTION app.reconcile(f footprints, p_scope scopes)
 RETURNS footprints
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  p jsonb := f.payload; c jsonb := '{}'::jsonb; w text[] := '{}';
  tol jsonb := p_scope.tolerances;
  v_in numeric; v_out numeric; a numeric; b numeric; d numeric; e numeric; s numeric; pk jsonb;
  prev public.footprints;
  v_ceiling numeric; v_learn int; v_rng record; v_pct numeric;   -- migration 49
  v_rdate date; v_taken text; v_on date;                          -- migration 50
  v_cp text; v_n int; v_crop public.crops; v_lim numeric; v_spread numeric; v_vill jsonb; v_nv int; v_moist numeric; v_far int;   -- migration 52
  v_mill public.mills; v_pu public.packing_units; v_sku public.pack_skus; v_smp public.qc_samples; v_lab public.labs;
  v_labname text; v_labtests text; v_loss numeric;                                                                   -- migration 53
  v_buyer public.buyers; v_left jsonb; v_pl jsonb; v_mkt text; v_prof public.market_profiles; v_ser text[]; v_ser_txt text;
  v_units jsonb; v_packs text[]; v_ncart int;                                                            -- migration 58
  v_scp public.collection_points;                                                                                    -- migration 54
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;
  select * into v_crop from public.crops where id = p_scope.crop_id;          -- migration 52: its limits and thresholds

  case f.stage_type
    when 'procurement' then
      a := app.req_num(p, 'gross_kg'); b := app.req_num(p, 'bags'); d := app.req_num(p, 'tare_kg_per_bag');
      if not (p ? 'moisture_pct' and jsonb_typeof(p->'moisture_pct') = 'array' and jsonb_array_length(p->'moisture_pct') = 3) then
        raise exception 'payload.moisture_pct must be an array of 3 readings' using errcode = '23514';
      end if;
      select avg(x::numeric), min(x::numeric), max(x::numeric) into a, b, d
        from jsonb_array_elements_text(p->'moisture_pct') x;   -- reuse vars: a=avg b=min d=max
      v_in := app.req_num(p, 'gross_kg') - app.req_num(p, 'bags') * app.req_num(p, 'tare_kg_per_bag');
      if v_in <= 0 then raise exception 'net weight must be positive (gross - bags x tare)' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('net_kg', v_in, 'moisture_avg', round(a, 2), 'moisture_min', b, 'moisture_max', d);
      if f.farmer_id is null then raise exception 'procurement requires farmer_id' using errcode = '23514'; end if;
      -- migration 52 (C1): where it was weighed, its GPS, who delivered it (asked where the scope says so)
      v_cp := nullif(btrim(p->>'collection_point_id'), '');
      if v_cp is not null and v_cp <> 'farm' and not exists (select 1 from public.collection_points cp
           where cp.id::text = v_cp and cp.client_id = p_scope.client_id and cp.active) then
        raise exception 'procurement: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
      if v_cp is not null then                                                  -- its name, for the record, the receipt and the batch
        c := c || jsonb_build_object('collection_point', case when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end); end if;
      if (p ? 'gps_lat' or p ? 'gps_lng') and (app.opt_num(p, 'gps_lat', null) is null or app.opt_num(p, 'gps_lng', null) is null
           or not app.valid_gps(app.opt_num(p, 'gps_lat', null), app.opt_num(p, 'gps_lng', null))) then
        raise exception 'procurement: the GPS point is two numbers in India' using errcode = '23514'; end if;
      if coalesce(p->>'delivered_by', 'farmer') not in ('farmer', 'family', 'agent') then
        raise exception 'procurement: delivered by the farmer, his family or an agent' using errcode = '23514'; end if;
      if p->>'delivered_by' = 'agent' and length(btrim(coalesce(p->>'agent_name', ''))) < 2 then
        raise exception 'procurement: name the agent who delivered the lot' using errcode = '23514'; end if;
      if p ? 'condition' and p->>'condition' not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'procurement: the condition is good, damp, pest or mixed' using errcode = '23514'; end if;
      if coalesce(p_scope.procurement_details_required, false) then
        if v_cp is null then
          raise exception 'procurement: say where the lot was weighed (a collection point, or at the farm)' using errcode = '23514'; end if;
        if not (p ? 'gps_lat') then
          raise exception 'procurement: the GPS of where the lot was weighed is required' using errcode = '23514'; end if;
        if not (p ? 'delivered_by') then
          raise exception 'procurement: say who delivered the lot (the farmer, his family or an agent)' using errcode = '23514'; end if;
      end if;
      -- warnings only: above the crop's moisture limit; three readings far apart (the crop's threshold, else 1.5 points)
      select app.opt_num(q, 'domestic_limit', null) into v_lim
        from jsonb_array_elements(coalesce(p_scope.quality_params, v_crop.quality_params, '[]'::jsonb)) q
       where q->>'param' in ('moisture_pct', 'moisture') and coalesce(q->>'operator', '<=') in ('<=', '<') limit 1;
      if v_lim is not null and a > v_lim then
        w := array_append(w, format('moisture %s %% is above the crop''s limit of %s %%', round(a, 1), v_lim)); end if;
      v_spread := coalesce((v_crop.thresholds->>'moisture_spread_pct')::numeric, 1.5);
      if d - b > v_spread then
        w := array_append(w, format('the moisture readings are %s points apart (more than %s): read them again', round(d - b, 1), v_spread)); end if;

    when 'lot_inward' then
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'weighed_kg');
      if b <= 0 then raise exception 'weighed_kg must be positive' using errcode = '23514'; end if;
      if coalesce(p->>'source_type', '') = '' or coalesce(p->>'source_name', '') = '' then
        raise exception 'payload.source_type and source_name are required' using errcode = '23514'; end if;
      perform app.req_num(p, 'moisture_pct');
      v_in := b; v_out := b;
      c := jsonb_build_object('variance_kg', a - b, 'variance_pct', case when a > 0 then round((a - b) / a * 100, 2) else null end);
      if a > 0 and abs(a - b) / a * 100 > app.opt_num(tol, 'lot_inward_variance_pct', 2) then
        w := array_append(w, 'declared vs weighed variance exceeds tolerance'); end if;

    when 'village_batch' then
      -- aggregates: qty_in = Σ qty_out of the source procurement lots (validated in the insert trigger)
      select coalesce(sum(s.qty_out), 0) into v_in
        from public.footprints s
        where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_in <= 0 then raise exception 'village_batch needs payload.source_footprint_ids with quantity' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('source_count', jsonb_array_length(p->'source_footprint_ids'));
      -- migration 52 (C2): one collection point; villages and farmers from the lots; single origin; re-weighed total
      select count(distinct coalesce(s.payload->>'collection_point_id', '')), min(coalesce(s.payload->>'collection_point_id', ''))
        into v_n, v_cp from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_n > 1 then
        raise exception 'collection batch: the lots are from different collection points (%): a batch is the lots at one place',
          (select string_agg(s.footprint_code || ' ' || coalesce(cp.name, case s.payload->>'collection_point_id' when 'farm' then 'at the farm' else 'no place recorded' end),
                             ', ' order by s.footprint_code)
             from public.footprints s left join public.collection_points cp on cp.id::text = s.payload->>'collection_point_id'
            where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)) using errcode = '23514'; end if;
      -- migration 54: the batch names its collection point (or "at the farm"); its lots are that point's
      if nullif(p->>'collection_point_id', '') is not null then
        if p->>'collection_point_id' <> 'farm' then
          select * into v_scp from public.collection_points cp where cp.id::text = p->>'collection_point_id' and cp.client_id = p_scope.client_id and cp.active;
          if v_scp.id is null then raise exception 'collection batch: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
        end if;
        select string_agg(s.footprint_code, ', ' order by s.footprint_code) into v_ser_txt from public.footprints s
         where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)
           and coalesce(s.payload->>'collection_point_id', '') <> p->>'collection_point_id';
        if v_ser_txt is not null then
          raise exception 'collection batch: % not weighed at this collection point (a batch is the lots of the point it names)', v_ser_txt using errcode = '23514'; end if;
        v_cp := p->>'collection_point_id';
      elsif p_scope.stage_details_required then
        raise exception 'collection batch: choose the collection point (where the bags are)' using errcode = '23514';
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('village', g.village, 'kg', g.kg, 'share_pct', round(g.kg / nullif(v_in, 0) * 100, 1))
                                order by g.kg desc, g.village), '[]'::jsonb), count(*)
        into v_vill, v_nv
        from (select min(fm.village) as village, sum(s.qty_out) as kg
                from public.footprints s join public.farmers fm on fm.id = s.farmer_id
               where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x) group by app.norm_place(fm.village)) g;
      if coalesce((p->>'single_origin')::boolean, false) and v_nv > 1 then
        raise exception 'collection batch: a single-origin batch is from one village (these lots are from %)',
          (select string_agg(x->>'village', ', ') from jsonb_array_elements(v_vill) x) using errcode = '23514'; end if;
      select count(distinct s.farmer_id),
             round(sum(s.qty_out * (s.computed->>'moisture_avg')::numeric) / nullif(sum(s.qty_out) filter (where s.computed ? 'moisture_avg'), 0), 2)
        into v_far, v_moist from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if p ? 'bags' and app.req_num(p, 'bags') < 1 then
        raise exception 'collection batch: the bags are 1 or more' using errcode = '23514'; end if;
      if p ? 'moisture_fresh_pct' and (app.req_num(p, 'moisture_fresh_pct') < 0 or app.req_num(p, 'moisture_fresh_pct') >= 100) then
        raise exception 'moisture must be below 100' using errcode = '23514'; end if;
      if p ? 'reweighed_kg' then
        e := app.req_num(p, 'reweighed_kg');
        if e <= 0 then raise exception 'collection batch: the re-weighed total is more than 0' using errcode = '23514'; end if;
        if e > v_in + app.kg_tolerance() then
          raise exception 'collection batch: the re-weighed total (% kg) is more than the lots (% kg)', e, v_in using errcode = '23514'; end if;
        v_out := least(e, v_in);
        if (v_in - v_out) / v_in * 100 > coalesce((v_crop.thresholds->>'batch_loss_pct')::numeric, 1) then
          w := array_append(w, format('the batch weighs %s kg (%s %%) less than its lots', round(v_in - v_out, 1), round((v_in - v_out) / v_in * 100, 1))); end if;
      end if;
      c := c || jsonb_build_object('total_kg', v_in, 'farmers', v_far, 'villages', v_vill, 'moisture_avg', v_moist,
                                   'collection_point', case when v_cp = '' then null when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end)
                || case when p ? 'reweighed_kg' then jsonb_build_object('loss_kg', round(v_in - v_out, 3)) else '{}'::jsonb end;

    when 'milling' then
      if p ? 'head_rice_kg' then
        -- migration 53 (C4): head rice, broken, husk and bran; the loss worked out (never typed, never below 0); the mill
        -- from the client's list, its operator, how the line was cleared (recorded by itself at a mill dedicated to the
        -- crop); sent vs received when the mill is elsewhere. Head rice goes forward; broken rice is a by-product.
        v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'head_rice_kg');
        b := app.opt_num(p, 'broken_kg', 0); d := app.opt_num(p, 'husk_kg', 0); e := app.opt_num(p, 'bran_kg', 0);
        if v_in <= 0 then raise exception 'milling: the paddy in is more than 0 kg' using errcode = '23514'; end if;
        if least(a, b, d, e) < 0 then raise exception 'milling: an output is 0 kg or more' using errcode = '23514'; end if;
        v_loss := v_in - a - b - d - e;
        if v_loss < -app.kg_tolerance() then
          raise exception 'milling: the outputs (% kg) are more than the paddy in (% kg)', a + b + d + e, v_in using errcode = '23514'; end if;
        v_loss := greatest(v_loss, 0);
        if nullif(p->>'mill_id', '') is not null then
          select * into v_mill from public.mills m where m.id::text = p->>'mill_id' and m.client_id = p_scope.client_id and m.active;
          if v_mill.id is null then raise exception 'milling: the mill is not one of this client''s active mills' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'milling: say which mill (from the client''s list)' using errcode = '23514'; end if;
        if p_scope.stage_details_required and length(btrim(coalesce(p->>'mill_operator', ''))) < 2 then
          raise exception 'milling: name the mill operator' using errcode = '23514'; end if;
        if v_mill.id is not null and v_mill.dedicated_crop_id = p_scope.crop_id then v_cp := 'dedicated';
        else
          v_cp := nullif(p->>'line_clearance', '');
          if v_cp is not null and v_cp not in ('fully_cleaned', 'quick_clean', 'same_crop') then
            raise exception 'milling: the line was fully cleaned, given a quick clean, or its previous run was this crop' using errcode = '23514'; end if;
          if v_cp is null and v_mill.id is not null then
            raise exception 'milling: say how the line was cleared (the mill is not dedicated to this crop)' using errcode = '23514'; end if;
        end if;
        if p ? 'polish' and p->>'polish' not in ('light', 'medium', 'full') then
          raise exception 'milling: the polish is light, medium or full' using errcode = '23514'; end if;
        v_out := a;
        c := jsonb_build_object('head_rice_kg', a, 'broken_kg', b, 'husk_kg', d, 'bran_kg', e, 'loss_kg', round(v_loss, 3),
               'recovery_pct', round((a + b) / v_in * 100, 2), 'head_rice_pct', round(a / v_in * 100, 2), 'yield_pct', round((a + b) / v_in * 100, 2));
        if v_mill.id is not null then c := c || jsonb_build_object('mill', v_mill.name); end if;
        if v_cp is not null then c := c || jsonb_build_object('line_clearance', v_cp); end if;
        if p ? 'sent_kg' then
          s := app.req_num(p, 'sent_kg');
          if v_in > s + app.kg_tolerance() then
            raise exception 'milling: the mill received (% kg) more than was sent (% kg)', v_in, s using errcode = '23514'; end if;
          c := c || jsonb_build_object('transit_loss_kg', round(greatest(s - v_in, 0), 3));
        end if;
        -- no fixed threshold: the crop's ceiling (the State Manager is told) and, after enough runs, this mill's usual range
        v_pct := round((a + b) / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        if v_mill.id is not null then
          select * into v_rng from app.milling_range_mill(p_scope.crop_id, v_mill.id::text, f.id);
          if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
            w := array_append(w, format('recovery %s %% is outside the usual range of this mill (%s to %s %%, from %s verified runs)', v_pct,
                   round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
        end if;
      else
      -- a record of before migration 53: rice out, bran and loss typed
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'rice_kg'); b := app.req_num(p, 'bran_kg'); d := app.req_num(p, 'loss_kg');
      if not app.approx_eq(v_in, a + b + d) then
        raise exception 'milling: input (%) must equal rice + bran + loss (%)', v_in, a + b + d using errcode = '23514'; end if;
      v_out := a;
      c := jsonb_build_object('yield_pct', round(a / nullif(v_in, 0) * 100, 2), 'bran_kg', b, 'loss_kg', d);
      -- migration 49 (A7/G5): no fixed threshold. Above the crop's ceiling (70 % unless set) the State Manager is told;
      -- once the crop has its own verified runs (10 unless set), outside their usual range (mean ± 2 SD) is warned.
      if v_in > 0 then
        v_pct := round(a / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        select * into v_rng from app.milling_range(p_scope.crop_id, p_scope.client_id, f.id);
        if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
          w := array_append(w, format('outturn %s %% is outside the usual range of this crop (%s to %s %%, from %s verified runs)', v_pct,
                 round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
      end if;
      end if;                                                                           -- migration 53

    when 'sorting' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'reject_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;                                          -- clean output is DERIVED, never entered
      if v_out < 0 then raise exception 'sorting: reject + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('clean_kg', v_out, 'reject_kg', a, 'loss_kg', d, 'reject_reasons', coalesce(p->'reject_reasons', '[]'::jsonb));

    when 'grading' then
      if f.is_grade_lot then
        -- child grade lot: quantity given directly, coupled to the grading run (validated in trigger)
        v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
        c := jsonb_build_object('grade', f.grade);
      else
        v_in := app.req_num(p, 'input_kg');
        a := app.req_num(p, 'grade_a_kg'); b := app.req_num(p, 'grade_b_kg'); d := app.req_num(p, 'grade_c_kg');
        e := app.req_num(p, 'reject_kg'); s := app.req_num(p, 'loss_kg');
        if not app.approx_eq(v_in, a + b + d + e + s) then
          raise exception 'grading: A + B + C + reject + loss (%) must equal input (%)', a + b + d + e + s, v_in using errcode = '23514'; end if;
        v_out := a + b + d;
        c := jsonb_build_object('grade_split', jsonb_build_object('A', a, 'B', b, 'C', d), 'reject_kg', e, 'loss_kg', s);
      end if;

    when 'drying' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'moisture_in_pct'); b := app.req_num(p, 'moisture_out_pct');
      v_out := app.req_num(p, 'output_kg');
      if b >= 100 or a >= 100 then raise exception 'moisture must be below 100%%' using errcode = '23514'; end if;
      e := v_in * (100 - a) / (100 - b);                              -- dry-matter expected output
      c := jsonb_build_object('expected_out_kg', round(e, 3), 'water_removed_kg', round(v_in - e, 3),
                              'grain_loss_kg', round(greatest(e - v_out, 0), 3));
      if v_out > e * 1.01 + app.kg_tolerance() then w := array_append(w, 'output exceeds dry-matter expectation'); end if;  -- 1% weighing noise
      if e - v_out > greatest(e * 0.02, app.kg_tolerance()) then w := array_append(w, 'grain loss beyond moisture removal'); end if;

    when 'popping' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg'); a := app.req_num(p, 'pop_rate_pct');
      c := jsonb_build_object('pop_rate_pct', a, 'weight_yield_pct', round(v_out / nullif(v_in, 0) * 100, 2));
      if a < app.opt_num(tol, 'pop_rate_min_pct', 80) then w := array_append(w, 'pop rate below threshold'); end if;

    when 'blanching' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg');
      c := jsonb_build_object('water_uptake_kg', round(v_out - v_in, 3));   -- output > input is valid here

    when 'cleaning' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'foreign_matter_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;
      if v_out < 0 then raise exception 'cleaning: foreign matter + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('foreign_matter_kg', a, 'loss_kg', d);

    when 'warehouse' then
      -- migration 55 (C3): sent (taken from the lot) vs received; a reason for any difference; condition, bags, location
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'received_kg');
      if a <= 0 then raise exception 'warehouse: what was sent is more than 0 kg' using errcode = '23514'; end if;
      if b <= 0 then raise exception 'warehouse: what was received is more than 0 kg' using errcode = '23514'; end if;
      if b > a + app.kg_tolerance() then
        raise exception 'warehouse: the received weight (% kg) is more than was sent (% kg)', trim_scale(b), trim_scale(a) using errcode = '23514'; end if;
      d := a - b; v_pct := round(d / a * 100, 2);
      if d > app.kg_tolerance() and length(btrim(coalesce(p->>'discrepancy_reason', ''))) < 5 then
        raise exception 'warehouse: say why % kg less was received than sent (at least 5 characters)', trim_scale(round(d, 3)) using errcode = '23514'; end if;
      if coalesce(p->>'condition', '') not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'warehouse: the condition on arrival is good, damp, pest or mixed' using errcode = '23514'; end if;
      e := app.req_num(p, 'bags_in');
      if e < 1 or e <> trunc(e) then raise exception 'warehouse: the bags in are a whole number, 1 or more' using errcode = '23514'; end if;
      if length(btrim(coalesce(p->>'location', ''))) < 2 then
        raise exception 'warehouse: name the warehouse or location' using errcode = '23514'; end if;
      v_in := a; v_out := b;
      c := jsonb_build_object('discrepancy_kg', round(d, 3), 'discrepancy_pct', v_pct, 'condition', p->>'condition', 'bags_in', e,
                              'location', btrim(p->>'location')) || case when nullif(btrim(p->>'stack'), '') is not null
                              then jsonb_build_object('stack', btrim(p->>'stack')) else '{}'::jsonb end;
      if v_pct > app.opt_num(v_crop.thresholds, 'warehouse_discrepancy_pct', 2) then
        w := array_append(w, format('the warehouse received %s kg (%s %%) less than was sent: flagged for the manager', trim_scale(round(d, 1)), trim_scale(round(v_pct, 1))));
      end if;

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg');
      -- migration 50 (G1): the save gives the batch code (trigger footprints_a1_batch_code); the preview has none yet
      if coalesce(p->>'batch_code', '') = '' and f.id is not null then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      -- migration 53 (C6): packs from the client's pack list (each keeps its own size), the packing unit from the list;
      -- the wastage worked out (a record of before typed it); above 2 % (the crop's packing_wastage_pct) a reason
      for pk in select * from jsonb_array_elements(p->'packets') loop
        if nullif(pk->>'sku_id', '') is not null then
          select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id' and k.client_id = p_scope.client_id and k.active;
          if v_sku.id is null then raise exception 'packing: a pack is not on the client''s pack list' using errcode = '23514'; end if;
          if abs(app.req_num(pk, 'size_kg') - case v_sku.unit when 'g' then v_sku.size / 1000 else v_sku.size end) > 0.0005 then
            raise exception 'packing: a pack from the list keeps its own size (% %)', v_sku.size, v_sku.unit using errcode = '23514'; end if;
          if app.req_num(pk, 'units') < 1 or app.req_num(pk, 'units') <> trunc(app.req_num(pk, 'units')) then
            raise exception 'packing: the number of packs is a whole number, 1 or more' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'packing: choose the packs from the client''s pack list' using errcode = '23514';
        end if;
      end loop;
      if nullif(p->>'packing_unit_id', '') is not null then
        select * into v_pu from public.packing_units u where u.id::text = p->>'packing_unit_id' and u.client_id = p_scope.client_id and u.active;
        if v_pu.id is null then raise exception 'packing: the packing unit is not one of this client''s active units' using errcode = '23514'; end if;
      elsif p_scope.stage_details_required then
        raise exception 'packing: say where it was packed (a packing unit of the client)' using errcode = '23514';
      end if;
      if p ? 'wastage_kg' then
        d := app.req_num(p, 'wastage_kg');
        if not app.approx_eq(v_in, v_out + d) then
          raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      else
        d := v_in - v_out;
        if d < -app.kg_tolerance() then
          raise exception 'packing: the packs (% kg) are more than the input (% kg)', v_out, v_in using errcode = '23514'; end if;
        d := greatest(d, 0);
      end if;
      v_lim := coalesce((v_crop.thresholds->>'packing_wastage_pct')::numeric, 2);
      if v_in > 0 and d / v_in * 100 > v_lim then
        if length(btrim(coalesce(p->>'wastage_reason', ''))) < 5 then
          raise exception 'packing: the wastage is % %% of the input (more than % %%): say why', round(d / v_in * 100, 1), v_lim using errcode = '23514'; end if;
        w := array_append(w, format('wastage %s %% is above %s %%: %s', round(d / v_in * 100, 1), v_lim, btrim(p->>'wastage_reason')));
      end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', round(d, 3), 'wastage_pct', round(d / nullif(v_in, 0) * 100, 2), 'batch_code', p->>'batch_code')
           || case when v_pu.id is not null then jsonb_build_object('packing_unit', v_pu.name) else '{}'::jsonb end;

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg');
      -- migration 53 (C5): the sample drawn first (its quantity and lab come with it); the lab from the state's list; a
      -- lab test (the library says "lab") is read at an accredited external lab, never in-house
      if nullif(p->>'sample_ref', '') is not null then
        select * into v_smp from public.qc_samples sm where sm.id::text = p->>'sample_ref';
        if v_smp.id is null or v_smp.footprint_id is distinct from f.prev_footprint_id then
          raise exception 'qc: the sample is not one drawn from this lot' using errcode = '23514'; end if;
        if v_smp.status <> 'sent' and v_smp.qc_footprint_id is distinct from f.id then
          raise exception 'qc: the results of sample % are in already (or it was disposed of)', v_smp.code using errcode = '23514'; end if;
        a := v_smp.qty_kg;
        if v_smp.lab_id is not null then select * into v_lab from public.labs l where l.id = v_smp.lab_id; end if;
      else
        if p_scope.stage_details_required then
          raise exception 'qc: choose the sample drawn from this lot (draw it first: it goes to the lab)' using errcode = '23514'; end if;
        a := app.req_num(p, 'sample_qty_kg');
      end if;
      if v_lab.id is null and nullif(p->>'lab_id', '') is not null then
        select * into v_lab from public.labs l where l.id::text = p->>'lab_id' and app.lab_for_scope(l.id, p_scope.id);   -- migration 54
        if v_lab.id is null then raise exception 'qc: the lab is not on this state''s or this client''s list' using errcode = '23514'; end if;
      end if;
      v_labname := coalesce(v_lab.name, nullif(btrim(p->>'lab_name'), ''));
      if p ? 'readings' and jsonb_typeof(p->'readings') = 'object' then
        select string_agg(distinct coalesce(lb.name, la.name), ', ') into v_labtests
          from jsonb_each(p->'readings') r
          join public.quality_param_library la on la.param = r.key
          left join public.quality_param_library lb on lb.param = la.alias_of
         where coalesce(lb.done_by, la.done_by) = 'lab' and nullif(btrim(r.value #>> '{}'), '') is not null;
        if v_labtests is not null and (v_lab.kind = 'in_house' or (v_lab.id is null and p_scope.stage_details_required)) then
          raise exception 'qc: % is a lab test: it is read at an accredited external lab', v_labtests using errcode = '23514'; end if;
      end if;
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);
      if v_smp.id is not null then c := c || jsonb_build_object('sample_code', v_smp.code); end if;                 -- migration 53
      if v_lab.id is not null then c := c || jsonb_build_object('lab', v_lab.name, 'lab_kind', v_lab.kind); end if;
      -- migration 50 (C5): the scope asks for the lab report (the default): the lab, its number and date; the file comes
      -- before verification. The date: not ahead of today, not before the lot existed. A number once per lab, unless
      -- the lots share the sample.
      if p_scope.qc_report_required then
        if coalesce(v_labname, '') = '' or coalesce(btrim(p->>'report_no'), '') = '' or coalesce(p->>'report_date', '') = '' then
          raise exception 'qc: the lab, the report number and the report date are required' using errcode = '23514'; end if;
        begin v_rdate := (p->>'report_date')::date; exception when others then
          raise exception 'qc: the report date is a date' using errcode = '23514'; end;
        if v_rdate > (now() at time zone 'Asia/Kolkata')::date then
          raise exception 'qc: the report date (%) is in the future', to_char(v_rdate, 'DD Mon YYYY') using errcode = '23514'; end if;
        v_on := coalesce(prev.happened_on, (coalesce(prev.captured_at, prev.created_at) at time zone 'Asia/Kolkata')::date);
        if prev.id is not null and v_rdate < v_on then
          raise exception 'qc: the report date (%) is before the lot it tests (% on %)', to_char(v_rdate, 'DD Mon YYYY'), prev.footprint_code, to_char(v_on, 'DD Mon YYYY')
            using errcode = '23514'; end if;
        v_taken := app.report_no_taken(v_labname, p->>'report_no', p->>'sample_id', f.id);
        if v_taken is not null then
          raise exception 'qc: report % of this lab is on % already (the same report twice needs the same sample ID)', btrim(p->>'report_no'), v_taken
            using errcode = '23505'; end if;
        c := c || jsonb_build_object('lab_name', v_labname, 'report_no', btrim(p->>'report_no'), 'report_date', v_rdate);
      end if;

    when 'commercial' then
      if p ? 'buyer_id' or p ? 'packs' or p ? 'order_no' or p_scope.stage_details_required then
        -- migration 54 (C7): the buyer from the client's list; the market, and for export its profile and the destination
        -- (the batch passed QC for that profile, or carries the client's written acceptance); the order number; packs by
        -- type where the batch was packed from the pack list (no more than are left), else the kilograms
        if coalesce(p->>'market', '') not in ('domestic','export') then
          raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
        if nullif(p->>'buyer_id', '') is not null then
          select * into v_buyer from public.buyers b where b.id::text = p->>'buyer_id' and b.client_id = p_scope.client_id and b.active;
          if v_buyer.id is null then raise exception 'commercial: the buyer is not one of this client''s active buyers' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required or coalesce(btrim(p->>'buyer'), '') = '' then
          raise exception 'commercial: choose the buyer from the client''s list' using errcode = '23514';
        end if;
        if length(btrim(coalesce(p->>'order_no', ''))) < 2 then
          raise exception 'commercial: give the order or contract number' using errcode = '23514'; end if;
        if p->>'market' = 'export' then
          select * into v_prof from public.market_profiles m where m.crop_id = p_scope.crop_id and m.status = 'active'
             and m.code = p->>'market_code' and m.code <> 'domestic' and m.code = any (p_scope.market_codes);
          if v_prof.id is null then
            raise exception 'commercial: choose the export market (one of this scope''s market profiles)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'destination_country', ''))) < 2 then
            raise exception 'commercial: name the destination country' using errcode = '23514'; end if;
          if not app.profile_allowed(f.prev_footprint_id, v_prof.code) then
            raise exception 'commercial: this batch has not passed QC for % (nor carries the client''s written acceptance)', v_prof.name using errcode = '23514'; end if;
        end if;
        if p ? 'sale_route' and p->>'sale_route' not in ('own_brand', 'white_label', 'bulk', 'prasaadam') then
          raise exception 'commercial: the sale route is own brand, white label, bulk or Prasaadam' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'packing' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'commercial');
          v_in := (v_pl->>'kg')::numeric;
          v_units := app.allocate_units(f.id, prev.id, v_pl->'lines', p->'cartons');                    -- migration 58: what it sets aside
        else
          v_in := app.req_num(p, 'qty_kg');
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', p->>'market', 'buyer', coalesce(v_buyer.name, btrim(p->>'buyer')), 'order_no', btrim(p->>'order_no'))
             || case when v_buyer.id is not null then jsonb_build_object('buyer_id', v_buyer.id, 'buyer_country', v_buyer.country) else '{}'::jsonb end
             || case when v_prof.id is not null then jsonb_build_object('market_code', v_prof.code, 'market_name', v_prof.name,
                                                                      'destination_country', btrim(p->>'destination_country')) else '{}'::jsonb end
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_units is not null then jsonb_build_object('units', v_units) else '{}'::jsonb end   -- migration 58
             || case when p ? 'sale_route' then jsonb_build_object('sale_route', p->>'sale_route') else '{}'::jsonb end;
      else
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');
      end if;                                                                           -- migration 54

    when 'shipment' then
      if p ? 'packs' or p ? 'invoice_no' or p_scope.stage_details_required then
        -- migration 54 (C8): the packs of one order (partial shipments: no more than are left of it); for export the pack
        -- codes scanned while loading, and the order's export documents complete; the papers of the market, their formats
        v_mkt := coalesce(prev.computed->>'market', prev.payload->>'market', 'domestic');
        if length(btrim(coalesce(p->>'invoice_no', ''))) < 2 then
          raise exception 'shipment: give the invoice number' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'commercial' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'shipment');
          v_in := (v_pl->>'kg')::numeric;
        else
          v_in := app.req_num(p, 'shipped_kg');
        end if;
        if v_mkt = 'export' then
          if not app.container_ok(p->>'container_no') then
            raise exception 'shipment: the container number is 4 letters and 7 digits (e.g. MSKU1234567)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'seal_no', ''))) < 3 then
            raise exception 'shipment: give the container seal number' using errcode = '23514'; end if;
          if btrim(coalesce(p->>'shipping_bill_no', '')) !~ '^[0-9]{6,8}$' then
            raise exception 'shipment: the shipping bill number is 6 to 8 digits' using errcode = '23514'; end if;
          if nullif(btrim(p->>'bl_no'), '') is not null and btrim(p->>'bl_no') !~ '^[A-Za-z0-9/-]{4,30}$' then
            raise exception 'shipment: a bill of lading number is 4 to 30 letters or digits' using errcode = '23514'; end if;
          select string_agg(x->>'doc', ', ') into v_ser_txt from jsonb_array_elements(app.export_docs_of(prev.id)) x where not (x->>'done')::boolean;
          if v_ser_txt is not null then
            raise exception 'shipment: the export documents of order % are not complete (%): attach their files at Commercial first', prev.footprint_code, v_ser_txt
              using errcode = '23514'; end if;
        else
          if not app.vehicle_ok(p->>'vehicle_no') then
            raise exception 'shipment: the vehicle number reads like UP53AB1234' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'lr_no', ''))) < 2 then
            raise exception 'shipment: give the LR (lorry receipt) number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'driver_phone'), '') is not null and regexp_replace(p->>'driver_phone', '[^0-9]', '', 'g') !~ '^(91)?[6-9][0-9]{9}$' then
            raise exception 'shipment: the driver''s phone is a 10-digit mobile number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'eway_bill_no'), '') is not null and regexp_replace(p->>'eway_bill_no', '\s', '', 'g') !~ '^[0-9]{12}$' then
            raise exception 'shipment: an e-way bill number is 12 digits' using errcode = '23514'; end if;
        end if;
        -- migration 57: the codes of the packs loaded, for a domestic shipment too; migration 58: a carton's code stands
        -- for its packs, and every check is on sets (1 lakh packs stay quick)
        if v_pl is not null then
          select array_agg(upper(btrim(x))) into v_ser from jsonb_array_elements_text(case when jsonb_typeof(p->'serials') = 'array' then p->'serials' else '[]'::jsonb end) x where btrim(x) <> '';
          if coalesce(cardinality(v_ser), 0) = 0 then
            raise exception 'shipment: scan or type the codes of the packs loaded' using errcode = '23514'; end if;
          if cardinality(v_ser) <> (select count(distinct sr) from unnest(v_ser) sr) then
            raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;
          select string_agg(code, ', '), count(*) into v_ser_txt, v_ncart
            from (select ct.code from public.cartons ct where ct.code in (select unnest(v_ser)) and ct.status <> 'packed' order by ct.code limit 10) z;
          if v_ser_txt is not null then
            raise exception 'shipment: carton % was opened: scan its packs one by one', v_ser_txt using errcode = '23514'; end if;
          select count(*) into v_ncart from public.cartons ct where ct.code in (select unnest(v_ser));
          select array_agg(cs) into v_packs from (
            select pq.serial as cs from public.cartons ct join public.packs pq on pq.carton_code = ct.code and pq.status = 'packed'
             where ct.code in (select unnest(v_ser))
            union all
            select sr from unnest(v_ser) sr where sr not in (select ct.code from public.cartons ct where ct.code in (select unnest(v_ser)))) e;
          if cardinality(v_packs) <> (select count(distinct x) from unnest(v_packs) x) then
            raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;      -- a pack and its carton
          select string_agg(sr, ', ') into v_ser_txt from (select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr
             where sr not in (select pq.serial from public.packs pq where pq.footprint_id = prev.prev_footprint_id and pq.status = 'packed') order by 1 limit 10) z;
          if v_ser_txt is not null then
            raise exception 'shipment: % not a pack of this order''s batch (or void)', v_ser_txt using errcode = '23514'; end if;
          select string_agg(sr, ', ') into v_ser_txt from (
            with others as (select x as code from public.footprints o,
                                   jsonb_array_elements_text(case when jsonb_typeof(o.payload->'serials') = 'array' then o.payload->'serials' else '[]'::jsonb end) x
                             where o.stage_type = 'shipment' and o.scope_id = f.scope_id and o.id <> f.id and o.status not in ('superseded', 'legacy')),
                 shipped as (select upper(code) as cs from others union all select pq.serial from others oo join public.packs pq on pq.carton_code = upper(oo.code))
            select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr where sr in (select cs from shipped) order by 1 limit 10) z;
          if v_ser_txt is not null then
            raise exception 'shipment: % shipped already', v_ser_txt using errcode = '23514'; end if;
          if jsonb_typeof(prev.computed->'units') = 'array' then                                       -- the order set them aside
            select string_agg(sr, ', ') into v_ser_txt from (
              with u as (select x from jsonb_array_elements(prev.computed->'units') x),
                   alloc as (select x->>'code' as cs from u union all select pq.serial from u join public.packs pq on pq.carton_code = u.x->>'code' where u.x->>'kind' = 'carton')
              select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr
               where sr not in (select cs from alloc)
                 and (select pq.sku_id from public.packs pq where pq.serial = sr) in (select (x->>'sku_id')::uuid from u)
               order by 1 limit 10) z;
            if v_ser_txt is not null then
              raise exception 'shipment: % not set aside for this order', v_ser_txt using errcode = '23514'; end if;
          end if;
          select string_agg(x->>'name', ', ') into v_ser_txt from jsonb_array_elements(v_pl->'lines') x
           where (x->>'units')::numeric <> (select count(*) from unnest(v_packs) sr join public.packs pq on pq.serial = sr where pq.sku_id::text = x->>'sku_id');
          if v_ser_txt is not null or cardinality(v_packs) <> (select sum((x->>'units')::numeric) from jsonb_array_elements(v_pl->'lines') x) then
            raise exception 'shipment: the codes scanned do not match the packs shipped (%)', coalesce(v_ser_txt, 'other pack types') using errcode = '23514'; end if;
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', v_mkt, 'invoice_no', btrim(p->>'invoice_no'))
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_ser is not null then jsonb_build_object('serials_count', cardinality(v_packs)) else '{}'::jsonb end   -- 58: packs
             || case when coalesce(v_ncart, 0) > 0 then jsonb_build_object('cartons_count', v_ncart) else '{}'::jsonb end           -- migration 58
             || case when v_mkt = 'export' then jsonb_build_object('container_no', upper(regexp_replace(p->>'container_no', '[\s-]', '', 'g')),
                       'bl_pending', nullif(btrim(p->>'bl_no'), '') is null) else '{}'::jsonb end;
      else
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);
      end if;                                                                           -- migration 54

    when 'qr_activation' then
      if prev.id is null then raise exception 'qr_activation needs a predecessor' using errcode = '23514'; end if;
      v_in := app.available_qty(prev.id); v_out := v_in;              -- takes whatever remains of the final lot
      if v_in <= 0 then raise exception 'qr_activation: final quantity must be recorded and positive' using errcode = '23514'; end if;
      c := jsonb_build_object('final_kg', v_in);

    else
      raise exception 'no reconciliation rule for stage %', f.stage_type using errcode = '23514';
  end case;

  -- Rule 3: output never exceeds input, except blanching.
  if v_out > v_in + app.kg_tolerance() and f.stage_type <> 'blanching' then
    raise exception '% : output (%) exceeds input (%)', f.stage_type, v_out, v_in using errcode = '23514';
  end if;

  f.qty_in := round(v_in, 3); f.qty_out := round(v_out, 3); f.computed := c; f.warnings := w;
  return f;
end $function$;

create or replace function app.order_pack_codes(p_fp uuid, p_except uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.footprints;
begin
  select * into o from public.footprints where id = p_fp and stage_type = 'commercial';
  if o.id is null or app.current_user_id() is null or not app.can_see_footprint(o.scope_id, o.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  -- migration 58: an order that set aside cartons and packs: those, each with its state (a few thousand at most)
  if jsonb_typeof(o.computed->'units') = 'array' then
    return coalesce((
      with others as (select sh.footprint_code as ship, upper(x) as code from public.footprints sh,
                             jsonb_array_elements_text(case when jsonb_typeof(sh.payload->'serials') = 'array' then sh.payload->'serials' else '[]'::jsonb end) x
                       where sh.scope_id = o.scope_id and sh.stage_type = 'shipment' and sh.status not in ('superseded', 'legacy')
                         and sh.id is distinct from p_except),
           u as (select x from jsonb_array_elements(o.computed->'units') x)
      select jsonb_agg(jsonb_build_object('serial', u.x->>'code', 'kind', u.x->>'kind', 'sku_id', u.x->>'sku_id', 'sku', app.sku_name(k),
               'size_kg', coalesce(pk.size_kg, (select min(p2.size_kg) from public.packs p2 where p2.carton_code = ct.code)),
               'n', (u.x->>'n')::int, 'first_serial', ct.first_serial, 'last_serial', ct.last_serial,
               'void', coalesce(ct.status = 'void', pk.status <> 'packed', false),
               'opened', coalesce(ct.status = 'opened', false),
               'shipped_in', (select min(oo.ship) from others oo where oo.code = u.x->>'code'
                                 or (ct.code is not null and oo.code in (select p3.serial from public.packs p3 where p3.carton_code = ct.code))
                                 or (pk.carton_code is not null and oo.code = pk.carton_code)))
               order by u.x->>'kind', u.x->>'code')
        from u left join public.cartons ct on ct.code = u.x->>'code' and u.x->>'kind' = 'carton'
               left join public.packs pk on pk.serial = u.x->>'code' and u.x->>'kind' = 'pack'
               left join public.pack_skus k on k.id = (u.x->>'sku_id')::uuid), '[]'::jsonb);
  end if;
  -- an order before migration 58, or of loose packs: every pack of its batch (as migration 57)
  return coalesce((
    with others as (select sh.footprint_code as ship, upper(x) as code from public.footprints sh,
                           jsonb_array_elements_text(case when jsonb_typeof(sh.payload->'serials') = 'array' then sh.payload->'serials' else '[]'::jsonb end) x
                     where sh.scope_id = o.scope_id and sh.stage_type = 'shipment' and sh.status not in ('superseded', 'legacy')
                       and sh.id is distinct from p_except),
         shipped as (select code as serial, min(ship) as code from others group by code)
    select jsonb_agg(jsonb_build_object('serial', pk.serial, 'kind', 'pack', 'n', 1, 'sku_id', pk.sku_id, 'sku', app.sku_name(k), 'size_kg', pk.size_kg,
             'void', pk.status <> 'packed', 'shipped_in', sp.code) order by pk.serial)
      from public.packs pk left join public.pack_skus k on k.id = pk.sku_id left join shipped sp on sp.serial = pk.serial
     where pk.footprint_id = o.prev_footprint_id), '[]'::jsonb);
end $$;

CREATE OR REPLACE FUNCTION app.joiner_detail(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; o public.employee_org; d public.employee_docs; tp public.onboarding_templates; j jsonb; v_full boolean;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  v_full := app.acts_as_hr() and app.hr_covers(u.id);   -- migration 39: an HR resource, for the people of her states
  -- H2: the admin also opens the HR Admin's page (her steps; not her HR file)
  if u.id is null or not (v_full or (app.is_admin() and u.system_role = 'hr_admin')) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  select * into d from public.employee_docs where employee_id = u.id;
  select * into tp from public.onboarding_templates
   where id = coalesce(o.template_id, (select id from public.onboarding_templates where is_default and active limit 1));
  j := jsonb_build_object(
    'person', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
               'system_role', u.system_role, 'join_date', u.join_date, 'created_at', u.created_at,
               'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
               'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
               'created_by', (select display_name from public.app_users where id = u.created_by)),
    'can_manage', app.hr_may_manage_person(u.id) and u.id <> app.current_user_id(),
    -- "Mark as joined", exactly as app.activate_joiner decides it
    'can_activate', u.status in ('invited', 'onboarding') and u.id <> app.current_user_id()
                    and ((app.is_admin() and u.system_role = 'hr_admin') or (app.is_hr() and app.hr_may_manage_person(u.id))),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to', o.reports_to, 'buddy', o.buddy,
             'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy),
             'base_state_id', o.base_state_id),                                                     -- migration 58: whom the choices are for
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
             'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
             'nominee_relation', d.nominee_relation, 'form16_ref', d.form16_ref,
             'pan_card_seen_by', (select display_name from public.app_users where id = d.pan_card_seen_by), 'pan_card_seen_at', d.pan_card_seen_at),
    -- A1: per number, whether it was checked for duplicates ("not checked": entered before migration 37, last 4 only)
    'checked', jsonb_build_object(
       'pan', case when d.pan_hmac is not null then 'checked' when d.pan_last4 is not null then 'not_checked' end,
       'aadhaar', case when d.aadhaar_hmac is not null then 'checked' when d.aadhaar_last4 is not null then 'not_checked' end,
       'uan', case when d.uan_hmac is not null then 'checked' when d.pf_uan_last4 is not null then 'not_checked' end,
       'bank', case when d.bank_hmac is not null then 'checked' when d.bank_last4 is not null then 'not_checked' end),
    -- A1: numbers that matched another person's: refused (PAN, Aadhaar, UAN) or a warning to accept (bank)
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'outcome', m.outcome, 'last4', m.last4,
               'matched_id', m.matched_employee, 'matched_name', (select display_name from public.app_users where id = m.matched_employee),
               'at', m.created_at, 'accepted_at', m.accepted_at, 'accept_reason', m.accept_reason,
               'accepted_by', (select display_name from public.app_users where id = m.accepted_by)) order by m.created_at desc)
               from public.id_number_matches m where m.employee_id = u.id), '[]'::jsonb),
    'personal', (select jsonb_build_object('date_of_birth', x.date_of_birth, 'relative_kind', x.relative_kind, 'relative_name', x.relative_name,
                   'present_address', x.present_address, 'permanent_address', x.permanent_address, 'emergency_name', x.emergency_name,
                   'emergency_relation', x.emergency_relation, 'emergency_phone', x.emergency_phone, 'updated_at', x.updated_at)
                   from public.employee_personal x where x.employee_id = u.id),
    'first_day', jsonb_build_object(
       'date', o.first_day_date, 'time', o.first_day_time, 'place', o.first_day_place, 'ask_for', o.first_day_ask_for, 'bring', o.first_day_bring,
       'default_date', u.join_date, 'default_time', tp.first_day_time, 'default_place', tp.first_day_place,
       'default_ask_for', tp.first_day_ask_for, 'default_bring', tp.first_day_bring),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'storage_path', f.storage_path,
               'sha256', f.sha256, 'task_id', f.task_id, 'created_at', f.created_at, 'masked', f.masked, 'masked_at', f.masked_at,
               'masked_by', (select display_name from public.app_users where id = f.masked_by), 'removed_at', f.removed_at,
               'uploaded_by', (select display_name from public.app_users where id = f.uploaded_by)) order by f.created_at)
               from public.employee_files f where f.employee_id = u.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
               'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note,
               'overdue', t.status = 'pending' and t.due_on < app.today(), 'depends_on', to_jsonb(t.depends_on),
               'done_by', (select display_name from public.app_users where id = t.done_by)) order by t.seq)
               from public.onboarding_tasks t where t.employee_id = u.id), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'at', n.created_at,
               'by', (select display_name from public.app_users where id = n.written_by)) order by n.created_at desc)
               from public.employee_notes n where n.employee_id = u.id), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
               from public.employee_goals g where g.employee_id = u.id), '[]'::jsonb),
    'exits', coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason, 'final_settlement', e.final_settlement,
               'form16_ref', e.form16_ref, 'at', e.created_at) order by e.created_at desc)
               from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb),
    'assignments', (select count(*) from public.assignments a where a.employee_id = u.id and a.active)
  );
  if not v_full then j := j - 'docs' - 'checked' - 'matches' - 'personal' - 'files' - 'notes' - 'exits'; end if;
  return j || jsonb_build_object(
    'role', jsonb_build_object('role', o.intended_role, 'stage', o.intended_stage, 'opening_id', o.opening_id,
               'opening_code', (select code from public.openings where id = o.opening_id),
               'state_name', (select s.name from public.openings op join public.states s on s.id = op.state_id where op.id = o.opening_id)),
    'hr_owner', (select jsonb_build_object('id', h.id, 'name', h.display_name) from public.app_users h where h.id = o.hr_owner),
    'invite', (select jsonb_build_object('state', case when i.used_at is not null then 'accepted' when i.revoked_at is not null then 'replaced'
                  when i.expires_at < now() then 'expired' else i.send_status end, 'at', i.created_at, 'expires_at', i.expires_at)
                from public.invites i where i.employee_id = u.id order by (i.revoked_at is null) desc, i.created_at desc limit 1),
    'activation', app.activation_state(u.id),
    'can_do_steps', (app.hr_may_manage_person(u.id) or (app.is_admin() and u.system_role = 'hr_admin')) and u.id <> app.current_user_id(),
    'can_invite', v_full and app.hr_may_manage_person(u.id) and u.id <> app.current_user_id() and u.status in ('invited', 'onboarding'));
end $function$;

CREATE OR REPLACE FUNCTION app.public_pack(p_serial text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.packs; v_seal uuid; q public.qr_seals; sc public.scopes; cr public.crops; v_pack jsonb;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null then return null; end if;
  select * into sc from public.scopes where id = p.scope_id; select * into cr from public.crops where id = sc.crop_id;
  v_pack := jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'size_kg', p.size_kg, 'packed_on', p.packed_on,
              'best_before', p.best_before, 'void', p.status = 'void',
              'copy_warning', app.scan_warning(p.serial), 'seller', (select c.name from public.clients c where c.id = sc.client_id),   -- migration 56
              'carton', p.carton_code,                                                                                         -- migration 58
              -- migration 57: how often this pack was scanned and the first place (a city, never a person)
              'scans', (select jsonb_build_object('n', count(*),
                          'first_city', (select f.city from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1),
                          'first_country', (select f.country from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1))
                          from public.scans x where x.code = p.serial));
  select s into v_seal from app.packing_seals(p.footprint_id) s limit 1;
  if v_seal is null or p.status = 'void' then
    return jsonb_build_object('pack', v_pack, 'released', false,
      'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code, 'geography', sc.geography,
      'gi_status', app.lot_gi_status(p.footprint_id));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $function$;

CREATE OR REPLACE FUNCTION app.import_joiners(p_rows jsonb, p_dry_run boolean DEFAULT true, p_batch text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); r jsonb; i int := 0; out jsonb := '[]'::jsonb; errs text[]; warns text[]; st text;
        v_email text; v_phone text; v_join date; v_type text; op public.openings; v_rep uuid; by_email uuid; by_phone uuid;
        seen_email text[] := '{}'; seen_phone text[] := '{}'; taken jsonb := '{}'::jsonb; filled int; made jsonb; row_out jsonb;
        n_ready int := 0; n_warn int := 0; n_err int := 0; n_skip int := 0; n_made int := 0; v_batch text;
        v_bstate uuid; v_full boolean := app.hr_full(); v_mine uuid[] := app.my_hr_states();
        v_dept text;                                                                                       -- migration 58
begin
  if not app.acts_as_hr() then raise exception 'only HR imports joiners' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows must be a list' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'at most 1000 rows per file' using errcode = '23514'; end if;
  v_batch := coalesce(nullif(left(btrim(p_batch), 60), ''), 'import-' || to_char(now() at time zone 'Asia/Kolkata', 'YYYYMMDD-HH24MISS'));

  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1; errs := '{}'; warns := '{}'; op := null; v_rep := null;
    if coalesce(btrim(r->>'full_name'), '') = '' then errs := array_append(errs, 'imp.no_name'::text); end if;
    v_email := app.email_key(r->>'personal_email');
    if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then errs := array_append(errs, 'imp.bad_email'::text); v_email := null; end if;
    if coalesce(btrim(r->>'phone'), '') = '' then errs := array_append(errs, 'imp.no_phone'::text); v_phone := null;
    else v_phone := app.normalise_in_mobile(r->>'phone'); if v_phone is null then errs := array_append(errs, 'imp.bad_phone'::text); end if; end if;
    begin v_join := nullif(btrim(r->>'join_date'), '')::date; exception when others then v_join := null; end;
    if v_join is null then errs := array_append(errs, 'imp.bad_date'::text);
    elsif v_join < app.today() - 60 or v_join > app.today() + 366 then errs := array_append(errs, 'imp.date_range'::text);
    elsif v_join < app.today() then warns := array_append(warns, 'imp.date_past'::text); end if;
    v_type := coalesce(nullif(lower(regexp_replace(btrim(r->>'employment_type'), '[\s-]+', '_', 'g')), ''), 'full_time');
    if v_type not in ('full_time', 'intern', 'contract', 'consultant') then errs := array_append(errs, 'imp.bad_type'::text); end if;
    if coalesce(btrim(r->>'opening'), '') = '' then warns := array_append(warns, 'imp.no_opening'::text);
    else
      select * into op from public.openings where upper(code) = upper(btrim(r->>'opening'));
      if op.id is null then errs := array_append(errs, 'imp.opening_unknown'::text);
      elsif op.status <> 'open' then errs := array_append(errs, 'imp.opening_not_open'::text);
      end if;
    end if;
    if coalesce(btrim(r->>'reports_to'), '') <> '' then
      select id into v_rep from public.app_users where app.email_key(email) = app.email_key(r->>'reports_to') and not external
        and status in ('invited', 'onboarding', 'active');
      if v_rep is null then warns := array_append(warns, 'imp.reports_to_unknown'::text); end if;
    end if;
    -- where the person is based (migration 39): the row's state (name or code), else the opening's
    v_bstate := null;
    if coalesce(btrim(r->>'state'), '') <> '' then
      select id into v_bstate from public.states where lower(name) = lower(btrim(r->>'state')) or upper(code) = upper(btrim(r->>'state')) limit 1;
      if v_bstate is null then errs := array_append(errs, 'imp.state_unknown'::text); end if;
    end if;
    if v_bstate is null and coalesce(btrim(r->>'state'), '') = '' then
      v_bstate := coalesce(op.state_id, case when not v_full and cardinality(v_mine) = 1 then v_mine[1] end); end if;
    if not v_full then
      if (op.id is not null and not (op.state_id = any(v_mine))) or (v_bstate is not null and not (v_bstate = any(v_mine))) then
        errs := array_append(errs, 'imp.not_your_state'::text);
      elsif v_bstate is null and coalesce(btrim(r->>'state'), '') = '' then
        errs := array_append(errs, 'imp.no_state'::text); end if;
    end if;

    -- migration 58: a manager of the person's state only; a department of the HR Admin's list only (else left out, said)
    if v_rep is not null and not app.manager_ok(v_rep, v_bstate) then
      warns := array_append(warns, 'imp.reports_to_not_manager'::text); v_rep := null; end if;
    v_dept := nullif(btrim(coalesce(r->>'department', '')), '');
    if v_dept is not null then
      select d.name into v_dept from public.departments d where lower(d.name) = lower(v_dept) and d.active;
      if v_dept is null then warns := array_append(warns, 'imp.department_unknown'::text); end if;
    end if;
    -- in the system already?
    by_email := null; by_phone := null;
    if v_email is not null then select id into by_email from public.app_users where app.email_key(email) = v_email; end if;
    if v_phone is not null then select id into by_phone from public.app_users where app.phone_key(phone) = app.phone_key(v_phone); end if;
    st := null;
    if by_email is not null and by_email = by_phone then st := 'skipped';                       -- the same person: added before
    else
      if by_email is not null then errs := array_append(errs, 'imp.email_taken'::text); end if;
      if by_phone is not null then errs := array_append(errs, 'imp.phone_taken'::text); end if;
    end if;
    -- twice in this file?
    if st is null and v_email is not null and v_email = any(seen_email) then errs := array_append(errs, 'imp.email_twice'::text); end if;
    if st is null and v_phone is not null and app.phone_key(v_phone) = any(seen_phone) then errs := array_append(errs, 'imp.phone_twice'::text); end if;
    -- room on the opening, counting the rows above
    if st is null and op.id is not null and op.status = 'open' and cardinality(errs) = 0 then
      select count(*) into filled from public.employee_org e join public.app_users u on u.id = e.employee_id
       where e.opening_id = op.id and u.status in ('invited', 'onboarding', 'active');
      -- the rows above in this file: in a dry run counted here; in a commit they are already made, so counted above
      if coalesce(p_dry_run, true) then filled := filled + coalesce((taken->>op.id::text)::int, 0); end if;
      if filled >= op.positions then errs := array_append(errs, 'imp.opening_full'::text);
      else taken := jsonb_set(taken, array[op.id::text], to_jsonb(coalesce((taken->>op.id::text)::int, 0) + 1)); end if;
    end if;
    if v_email is not null then seen_email := seen_email || v_email; end if;
    if v_phone is not null then seen_phone := seen_phone || app.phone_key(v_phone); end if;

    st := coalesce(st, case when cardinality(errs) > 0 then 'error' when cardinality(warns) > 0 then 'warning' else 'ready' end);
    row_out := jsonb_build_object('row', i, 'name', btrim(coalesce(r->>'full_name', '')), 'email', v_email, 'opening', op.code,
                                  'role', op.role, 'stage', op.stage, 'status', st,
                                  'state', (select name from public.states where id = v_bstate),
                                  'reasons', to_jsonb(case when st = 'skipped' then array['imp.already_added'] else errs || warns end));
    if st = 'skipped' then row_out := row_out || jsonb_build_object('id', by_email); end if;

    if not coalesce(p_dry_run, true) and st in ('ready', 'warning') then
      begin
        made := app.add_joiner(jsonb_build_object('full_name', btrim(r->>'full_name'), 'personal_email', v_email, 'phone', v_phone,
                  'join_date', v_join, 'employment_type', v_type, 'designation_band', nullif(btrim(r->>'designation_band'), ''),
                  'department', v_dept, 'job_title', nullif(btrim(r->>'job_title'), ''),                     -- migration 58
                  'reports_to', v_rep, 'opening_id', op.id, 'import_batch', v_batch,
                  'base_state_id', v_bstate, 'base_district', nullif(left(btrim(coalesce(r->>'district', '')), 60), '')));
        row_out := row_out || jsonb_build_object('id', made->>'id', 'created', true);
        n_made := n_made + 1;
      exception when others then
        row_out := row_out || jsonb_build_object('status', 'error', 'reasons', jsonb_build_array('imp.failed'), 'detail', left(sqlerrm, 200));
        st := 'error';
      end;
    end if;
    case st when 'ready' then n_ready := n_ready + 1; when 'warning' then n_warn := n_warn + 1;
            when 'skipped' then n_skip := n_skip + 1; else n_err := n_err + 1; end case;
    out := out || row_out;
  end loop;

  if not coalesce(p_dry_run, true) then
    perform app.audit('joiners_imported', null, jsonb_build_object('batch', v_batch, 'rows', i, 'created', n_made,
                                                                   'skipped', n_skip, 'errors', n_err));
  end if;
  return jsonb_build_object('batch', v_batch, 'dry_run', coalesce(p_dry_run, true), 'rows', out,
    'counts', jsonb_build_object('rows', i, 'ready', n_ready, 'warning', n_warn, 'error', n_err, 'skipped', n_skip, 'created', n_made));
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.make_cartons(text, uuid, uuid, uuid, integer, integer, integer), app.taken_units(uuid, uuid),
  app.allocate_units(uuid, uuid, jsonb, jsonb), app.available_cartons(uuid, uuid), app.carton_labels(uuid), app.set_department(text, boolean),
  app.manager_ok(uuid, uuid), app.buddy_ok(uuid, uuid), app.org_choices(uuid), app.employee_org_choices() from public, anon, authenticated;
grant execute on function app.available_cartons(uuid, uuid), app.carton_labels(uuid), app.set_department(text, boolean), app.org_choices(uuid) to authenticated;
