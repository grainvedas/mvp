-- GrainVeda MVP · migration 55: the Warehouse (release 8 of the operator-stages plan, C3; Veda, 16 Oct 2026, "yes proceed").
-- Chosen per scope (when the scope is built: its chain), right after the entry stage or the Collection Batch and before
-- Milling or anything else. The prototype's Warehouse Inward, rebuilt:
--   arrival: what was sent (taken from the lot) and what was received, the difference worked out; a reason for any
--            difference; above 2 % (the crop's warehouse_discrepancy_pct) a flag for the manager;
--   storage: the warehouse or location and the stack, the condition on arrival, bags in, and bags out as they leave;
--   inspections: every N days (the scope's warehouse_inspection_days, set by its Client Manager): condition, date, who;
--            a stored lot shows as inspection due or overdue;
--   days in storage on the lot's record and on the public page.
-- In a scope without a Warehouse, a batch that waits more than 15 days (the crop's stored_unrecorded_days) for Milling
-- with nothing taken is shown to its Client Manager: "stored but not recorded".
-- Also: a domestic order no longer shows the export fields (a field may be shown for one value of another), and the
-- folder "Claude outputs" is git-ignored (Veda, 16 Oct).
select set_config('app.change_path', 'migration 55', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- The scope's inspection interval (its Client Manager; any time)
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.scopes add column if not exists warehouse_inspection_days int not null default 15;
alter table public.scopes drop constraint if exists scopes_warehouse_inspection_days;
alter table public.scopes add constraint scopes_warehouse_inspection_days check (warehouse_inspection_days between 1 and 120);

-- ---------------------------------------------------------------------------------------------------------------------
-- Inspections and bags out of a stored lot (the warehouse record). Written only by their functions; read by who sees the
-- record; every change in the change log.
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.warehouse_inspections (
  id            uuid primary key default gen_random_uuid(),
  footprint_id  uuid not null references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  inspected_on  date not null,
  condition     text not null check (condition in ('good', 'minor', 'significant', 'pest')),
  note          text check (note is null or length(note) <= 300),
  inspected_by  uuid not null references public.app_users(id),
  created_at    timestamptz not null default now()
);
create index if not exists warehouse_inspections_fp on public.warehouse_inspections (footprint_id, inspected_on);
alter table public.warehouse_inspections enable row level security;
revoke all on public.warehouse_inspections from anon, authenticated;
grant select on public.warehouse_inspections to authenticated;
drop policy if exists warehouse_inspections_read on public.warehouse_inspections;
create policy warehouse_inspections_read on public.warehouse_inspections for select to authenticated
  using (app.can_see_footprint(scope_id, 'warehouse'));
drop trigger if exists zz_change_log on public.warehouse_inspections;
create trigger zz_change_log after insert or update or delete on public.warehouse_inspections for each row execute function app.log_change('id');

create table if not exists public.warehouse_bags_out (
  id            uuid primary key default gen_random_uuid(),
  footprint_id  uuid not null references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  out_on        date not null,
  bags          int not null check (bags >= 1),
  note          text check (note is null or length(note) <= 300),
  recorded_by   uuid not null references public.app_users(id),
  created_at    timestamptz not null default now()
);
create index if not exists warehouse_bags_out_fp on public.warehouse_bags_out (footprint_id);
alter table public.warehouse_bags_out enable row level security;
revoke all on public.warehouse_bags_out from anon, authenticated;
grant select on public.warehouse_bags_out to authenticated;
drop policy if exists warehouse_bags_out_read on public.warehouse_bags_out;
create policy warehouse_bags_out_read on public.warehouse_bags_out for select to authenticated
  using (app.can_see_footprint(scope_id, 'warehouse'));
drop trigger if exists zz_change_log on public.warehouse_bags_out;
create trigger zz_change_log after insert or update or delete on public.warehouse_bags_out for each row execute function app.log_change('id');

-- ---------------------------------------------------------------------------------------------------------------------
-- What a stored lot is: days in storage, bags, the next inspection
-- ---------------------------------------------------------------------------------------------------------------------
-- Days in storage: from the day it arrived to the day the last of it left (or today, while some is still there).
create or replace function app.storage_days(p_fp uuid) returns int
language sql stable security definer set search_path = public as $$
  with f as (select x.*, coalesce(x.happened_on, (coalesce(x.captured_at, x.created_at) at time zone 'Asia/Kolkata')::date) as arrived
               from public.footprints x where x.id = p_fp and x.stage_type = 'warehouse'),
       k as (select max(coalesce(c.happened_on, (coalesce(c.captured_at, c.created_at) at time zone 'Asia/Kolkata')::date)) as last_out
               from public.footprints c join f on c.prev_footprint_id = f.id where c.status not in ('superseded', 'legacy'))
  select greatest(0, (case when app.available_qty(f.id) > app.kg_tolerance() and not coalesce(f.lot_closed, false) then app.today()
                           else coalesce(k.last_out, app.today()) end) - f.arrived)
    from f cross join k $$;

-- The inspection state of a stored lot: the interval, the last inspection, the next one due; 'due' within 2 days of it,
-- 'overdue' after it, 'ok' before, 'done' when nothing is left in storage.
create or replace function app.inspection_state(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; sc public.scopes; v_last date; v_from date; v_next date; v_state text;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.stage_type <> 'warehouse' then return null; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select max(inspected_on) into v_last from public.warehouse_inspections where footprint_id = f.id;
  v_from := coalesce(v_last, f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  v_next := v_from + sc.warehouse_inspection_days;
  v_state := case when f.status not in ('pending', 'verified') or f.lot_closed or app.available_qty(f.id) <= app.kg_tolerance() then 'done'
                  when app.today() > v_next then 'overdue'
                  when app.today() >= v_next - 2 then 'due'
                  else 'ok' end;
  return jsonb_build_object('interval_days', sc.warehouse_inspection_days, 'last_on', v_last, 'next_due', v_next, 'state', v_state,
    'last_condition', (select i.condition from public.warehouse_inspections i where i.footprint_id = f.id order by i.inspected_on desc, i.created_at desc limit 1));
end $$;

-- Who keeps a stored lot: the person holding the Warehouse stage of its scope, or a manager of the scope.
create or replace function app.keeps_warehouse(p_user uuid, p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.is_my_stage(p_user, p_scope, 'warehouse') or app.manages_scope(p_user, p_scope), false) $$;

-- An inspection: the date (between its arrival and today), the condition, a note (asked for anything but good).
create or replace function app.record_inspection(p_fp uuid, p_on date, p_condition text, p_note text default null)
returns public.warehouse_inspections
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; r public.warehouse_inspections; v_arr date;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type <> 'warehouse' then raise exception 'an inspection is of a lot in the warehouse' using errcode = '23514'; end if;
  if not app.keeps_warehouse(me, f.scope_id) then
    raise exception 'a stored lot is inspected by the Warehouse or a manager of the scope' using errcode = '42501'; end if;
  if f.status not in ('pending', 'verified') then raise exception 'this lot is %', f.status using errcode = '23514'; end if;
  v_arr := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  if p_on is null or p_on < v_arr or p_on > app.today() then
    raise exception 'inspection: the date is between the lot''s arrival (%) and today', to_char(v_arr, 'DD Mon YYYY') using errcode = '23514'; end if;
  if p_condition is null or p_condition not in ('good', 'minor', 'significant', 'pest') then
    raise exception 'inspection: the condition is good, minor deterioration, significant deterioration, or pest found' using errcode = '23514'; end if;
  if p_condition <> 'good' and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'inspection: say what was found (at least 5 characters)' using errcode = '23514'; end if;
  insert into public.warehouse_inspections (footprint_id, scope_id, inspected_on, condition, note, inspected_by)
  values (f.id, f.scope_id, p_on, p_condition, nullif(left(btrim(coalesce(p_note, '')), 300), ''), me) returning * into r;
  perform app.audit('warehouse_inspection', f.id, jsonb_build_object('code', f.footprint_code, 'on', p_on, 'condition', p_condition), false);
  return r;
end $$;

-- Bags out: how many left the warehouse and when; never more than came in.
create or replace function app.record_bags_out(p_fp uuid, p_bags int, p_on date, p_note text default null)
returns public.warehouse_bags_out
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; r public.warehouse_bags_out; v_in int; v_out int; v_arr date;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type <> 'warehouse' then raise exception 'bags out are of a lot in the warehouse' using errcode = '23514'; end if;
  if not (app.keeps_warehouse(me, f.scope_id) or app.is_my_stage(me, f.scope_id, app.chain_next(f.scope_id, 'warehouse'))) then
    raise exception 'bags out are recorded by the Warehouse, the stage that takes the lot, or a manager of the scope' using errcode = '42501'; end if;
  if f.status not in ('pending', 'verified') then raise exception 'this lot is %', f.status using errcode = '23514'; end if;
  v_arr := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  if p_on is null or p_on < v_arr or p_on > app.today() then
    raise exception 'bags out: the date is between the lot''s arrival (%) and today', to_char(v_arr, 'DD Mon YYYY') using errcode = '23514'; end if;
  v_in := (f.computed->>'bags_in')::int;
  select coalesce(sum(bags), 0) into v_out from public.warehouse_bags_out where footprint_id = f.id;
  if p_bags is null or p_bags < 1 then raise exception 'bags out: the number of bags is a whole number, 1 or more' using errcode = '23514'; end if;
  if v_in is not null and v_out + p_bags > v_in then
    raise exception 'bags out: only % bags of % are still in the warehouse', v_in - v_out, v_in using errcode = '23514'; end if;
  insert into public.warehouse_bags_out (footprint_id, scope_id, out_on, bags, note, recorded_by)
  values (f.id, f.scope_id, p_on, p_bags, nullif(left(btrim(coalesce(p_note, '')), 300), ''), me) returning * into r;
  perform app.audit('warehouse_bags_out', f.id, jsonb_build_object('code', f.footprint_code, 'on', p_on, 'bags', p_bags), false);
  return r;
end $$;

-- What the record page shows of a stored lot.
create or replace function app.warehouse_of(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when f.stage_type <> 'warehouse' then null else jsonb_build_object(
    'days', app.storage_days(f.id),
    'bags_in', (f.computed->>'bags_in')::int,
    'bags_out', (select coalesce(sum(b.bags), 0) from public.warehouse_bags_out b where b.footprint_id = f.id),
    'moves', (select coalesce(jsonb_agg(jsonb_build_object('on', b.out_on, 'bags', b.bags, 'note', b.note,
                'by', (select u.display_name from public.app_users u where u.id = b.recorded_by)) order by b.out_on, b.created_at), '[]'::jsonb)
                from public.warehouse_bags_out b where b.footprint_id = f.id),
    'inspections', (select coalesce(jsonb_agg(jsonb_build_object('on', i.inspected_on, 'condition', i.condition, 'note', i.note,
                'by', (select u.display_name from public.app_users u where u.id = i.inspected_by)) order by i.inspected_on desc, i.created_at desc), '[]'::jsonb)
                from public.warehouse_inspections i where i.footprint_id = f.id),
    'inspection', app.inspection_state(f.id)) end
    from public.footprints f where f.id = p_fp $$;

-- A difference above the limit opens a flag for the manager, once (the record's maker raises it; it is the save's).
create or replace function app.footprints_warehouse_flag() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_lim numeric;
begin
  if new.stage_type <> 'warehouse' or new.status <> 'pending' then return new; end if;
  select coalesce((c.thresholds->>'warehouse_discrepancy_pct')::numeric, 2) into v_lim
    from public.scopes s join public.crops c on c.id = s.crop_id where s.id = new.scope_id;
  if coalesce((new.computed->>'discrepancy_pct')::numeric, 0) > v_lim
     and not exists (select 1 from public.flags fl where fl.footprint_id = new.id and fl.status = 'open' and fl.text like 'Warehouse:%') then
    insert into public.flags (footprint_id, raised_by, text, kind)
    values (new.id, new.created_by, format('Warehouse: received %s kg, %s %% less than was sent (%s kg); more than %s %%. Reason given: %s',
              trim_scale(new.qty_out), trim_scale((new.computed->>'discrepancy_pct')::numeric), trim_scale(new.qty_in), trim_scale(v_lim),
              coalesce(new.payload->>'discrepancy_reason', '—')), 'flag');
  end if;
  return new;
end $$;
drop trigger if exists footprints_z9_warehouse_flag on public.footprints;
create trigger footprints_z9_warehouse_flag after insert or update of payload on public.footprints
  for each row execute function app.footprints_warehouse_flag();

-- ---------------------------------------------------------------------------------------------------------------------
-- The Warehouse stage (stage_definitions) and the domestic order's form (Veda, 16 Oct)
-- ---------------------------------------------------------------------------------------------------------------------
insert into public.stage_definitions
  (stage_type, code, label, is_first, is_gate, splits_forward, aggregates, allows_exceed_input, yield_alarm, is_processing, sort_order, form_schema, handoff_checks, physical_checks)
values ('warehouse', 'WH', 'Warehouse', false, false, false, false, false, false, false, 35,
 '[{"key": "declared_kg", "type": "number", "unit": "kg", "label": "Sent (what the lot holds)", "section": "arrival", "required": true},
   {"key": "received_kg", "type": "number", "unit": "kg", "label": "Received (weighed here)", "section": "arrival", "required": true},
   {"key": "discrepancy_reason", "type": "text", "label": "Why the weights differ (when they do)", "section": "arrival", "required": false},
   {"key": "condition", "type": "select", "label": "Condition on arrival", "options": ["good", "damp", "pest", "mixed"], "section": "arrival", "required": true},
   {"key": "bags_in", "type": "integer", "label": "Bags in", "section": "arrival", "required": true},
   {"key": "location", "type": "text", "label": "Warehouse or location", "section": "stored", "required": true},
   {"key": "stack", "type": "text", "label": "Stack or row", "section": "stored", "required": false},
   {"key": "photo", "type": "attachment", "label": "Photo of the stack (optional)", "section": "stored", "required": false}]'::jsonb,
 '["Received weight recorded; any difference explained", "Location and stack recorded", "Bags counted in"]'::jsonb,
 '["Bags counted out of the warehouse", "The grain looks and smells sound (no mould, no insects)"]'::jsonb)
on conflict (stage_type) do update set
  code = excluded.code, label = excluded.label, is_first = excluded.is_first, is_gate = excluded.is_gate,
  splits_forward = excluded.splits_forward, aggregates = excluded.aggregates, allows_exceed_input = excluded.allows_exceed_input,
  yield_alarm = excluded.yield_alarm, is_processing = excluded.is_processing, sort_order = excluded.sort_order,
  form_schema = excluded.form_schema, handoff_checks = excluded.handoff_checks, physical_checks = excluded.physical_checks;

-- A domestic order does not show the export fields: the market's profile, the destination and the Incoterms show only
-- when the market chosen is export ("shown_if"; display only, the save asks them for export as before).
update public.stage_definitions set form_schema = (
  select jsonb_agg(case when x->>'key' in ('market_code', 'destination_country', 'incoterms')
                        then x || '{"shown_if": {"market": "export"}}'::jsonb else x end order by n)
    from jsonb_array_elements(form_schema) with ordinality as e(x, n))
 where stage_type = 'commercial';

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen55.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- The save's rule for the Warehouse: what was sent and what was received, the difference and its reason, condition,
-- bags in, location
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
        else
          v_in := app.req_num(p, 'qty_kg');
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', p->>'market', 'buyer', coalesce(v_buyer.name, btrim(p->>'buyer')), 'order_no', btrim(p->>'order_no'))
             || case when v_buyer.id is not null then jsonb_build_object('buyer_id', v_buyer.id, 'buyer_country', v_buyer.country) else '{}'::jsonb end
             || case when v_prof.id is not null then jsonb_build_object('market_code', v_prof.code, 'market_name', v_prof.name,
                                                                      'destination_country', btrim(p->>'destination_country')) else '{}'::jsonb end
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
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
          if v_pl is not null then
            select array_agg(upper(btrim(x))) into v_ser from jsonb_array_elements_text(coalesce(p->'serials', '[]'::jsonb)) x where btrim(x) <> '';
            if coalesce(cardinality(v_ser), 0) = 0 then
              raise exception 'shipment: scan or type the codes of the packs loaded (export)' using errcode = '23514'; end if;
            if cardinality(v_ser) <> (select count(distinct sr) from unnest(v_ser) sr) then
              raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;
            select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
             where not exists (select 1 from public.packs pk where pk.serial = sr and pk.status = 'packed' and pk.footprint_id = prev.prev_footprint_id);
            if v_ser_txt is not null then
              raise exception 'shipment: % not a pack of this order''s batch (or void)', v_ser_txt using errcode = '23514'; end if;
            select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
             where exists (select 1 from public.footprints o where o.stage_type = 'shipment' and o.id <> f.id and o.status not in ('superseded', 'legacy')
                             and coalesce(o.payload->'serials', '[]'::jsonb) ? sr);
            if v_ser_txt is not null then
              raise exception 'shipment: % shipped already', v_ser_txt using errcode = '23514'; end if;
            select string_agg(x->>'name', ', ') into v_ser_txt from jsonb_array_elements(v_pl->'lines') x
             where (x->>'units')::numeric <> (select count(*) from unnest(v_ser) sr join public.packs pk on pk.serial = sr where pk.sku_id::text = x->>'sku_id');
            if v_ser_txt is not null or cardinality(v_ser) <> (select sum((x->>'units')::numeric) from jsonb_array_elements(v_pl->'lines') x) then
              raise exception 'shipment: the codes scanned do not match the packs shipped (%)', coalesce(v_ser_txt, 'other pack types') using errcode = '23514'; end if;
          end if;
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
        v_out := v_in;
        c := jsonb_build_object('market', v_mkt, 'invoice_no', btrim(p->>'invoice_no'))
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_ser is not null then jsonb_build_object('serials_count', cardinality(v_ser)) else '{}'::jsonb end
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
-- What the next stage sees checked: the difference within the limit, the inspections up to date
CREATE OR REPLACE FUNCTION app.system_checks(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; fm public.farmers; sc public.scopes; cr public.crops; out jsonb := '[]'::jsonb; n int; m int; ans jsonb;
  ok boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  out := out || jsonb_build_array(jsonb_build_object('key', 'recorded', 'ok', true, 'vars', jsonb_build_object(
           'by', (select display_name from public.app_users where id = f.created_by),
           'on', to_char(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date), 'DD Mon YYYY'))));
  case f.stage_type
    when 'procurement' then
      select * into fm from public.farmers where id = f.farmer_id;
      out := out || jsonb_build_array(jsonb_build_object('key', 'farmer_active', 'ok', fm.status = 'active', 'vars', jsonb_build_object('name', fm.name)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'moisture_three',
               'ok', jsonb_typeof(f.payload->'moisture_pct') = 'array' and jsonb_array_length(f.payload->'moisture_pct') = 3, 'vars', '{}'::jsonb));
      out := out || jsonb_build_array(jsonb_build_object('key', 'net_worked_out', 'ok', true, 'vars', jsonb_build_object('kg', f.qty_out)));
      select answers into ans from public.farmer_gap where farmer_id = f.farmer_id and crop_id = cr.id;
      out := out || jsonb_build_array(jsonb_build_object('key', 'practice_complete',
               'ok', jsonb_array_length(app.gap_missing(cr.gap_items, ans)->'required') = 0, 'vars', '{}'::jsonb));
    when 'lot_inward' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'source_declared',
               'ok', coalesce(btrim(f.payload->>'source_type'), '') <> '' and coalesce(btrim(f.payload->>'source_name'), '') <> '', 'vars', '{}'::jsonb));
    when 'village_batch' then
      select count(*), count(*) filter (where s.status = 'verified') into n, m from public.footprints s
       where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(f.payload->'source_footprint_ids', '[]'::jsonb)) x);
      out := out || jsonb_build_array(jsonb_build_object('key', 'sources_verified', 'ok', n = m and n > 0, 'vars', jsonb_build_object('n', n)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'batch_sum', 'ok', true, 'vars', jsonb_build_object('kg', f.qty_in)));
      -- migration 54: the villages are taken from the lots (a batch of before named its village)
      out := out || jsonb_build_array(jsonb_build_object('key', 'villages_from_lots',
               'ok', coalesce(btrim(f.payload->>'village'), '') <> '' or jsonb_array_length(coalesce(f.computed->'villages', '[]'::jsonb)) > 0,
               'vars', jsonb_build_object('n', jsonb_array_length(coalesce(f.computed->'villages', '[]'::jsonb)))));
    when 'warehouse' then
      -- migration 55 (C3)
      out := out || jsonb_build_array(jsonb_build_object('key', 'wh_difference',
               'ok', coalesce((f.computed->>'discrepancy_pct')::numeric, 0) <= app.opt_num(cr.thresholds, 'warehouse_discrepancy_pct', 2),
               'vars', jsonb_build_object('kg', coalesce(trim_scale((f.computed->>'discrepancy_kg')::numeric)::text, '0'), 'pct', coalesce(trim_scale((f.computed->>'discrepancy_pct')::numeric)::text, '0'))));
      out := out || jsonb_build_array(jsonb_build_object('key', 'wh_inspections',
               'ok', coalesce(app.inspection_state(f.id)->>'state', 'ok') <> 'overdue',
               'vars', jsonb_build_object('days', app.storage_days(f.id))));
    when 'qc' then
      select count(*) into m from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q;
      select count(*) into n from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q
       where coalesce(f.payload->'readings', '{}'::jsonb) ? (q->>'param');
      out := out || jsonb_build_array(jsonb_build_object('key', 'params_read', 'ok', n = m, 'vars', jsonb_build_object('n', n, 'm', m)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'verdicts_derived',
               'ok', exists (select 1 from public.qc_verdicts v where v.footprint_id = f.id), 'vars', '{}'::jsonb));
    when 'commercial' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'buyer_market',
               'ok', coalesce(btrim(f.computed->>'buyer'), btrim(f.payload->>'buyer'), '') <> '' and coalesce(f.payload->>'market', '') <> '', 'vars', '{}'::jsonb));
      out := out || jsonb_build_array(jsonb_build_object('key', 'export_backed',
               'ok', coalesce(f.payload->>'market', '') <> 'export'
                     or (case when f.computed ? 'market_code' then app.profile_allowed(f.prev_footprint_id, f.computed->>'market_code')
                              else app.export_allowed(f.prev_footprint_id) end), 'vars', '{}'::jsonb));
      -- migration 54 (C7): an export sale's documents, each received with its file or not required
      if f.computed ? 'market_code' then
        select count(*), count(*) filter (where (x->>'done')::boolean) into m, n from jsonb_array_elements(app.export_docs_of(f.id)) x;
        out := out || jsonb_build_array(jsonb_build_object('key', 'export_docs', 'ok', n = m, 'vars', jsonb_build_object('n', n, 'm', m)));
      end if;
    when 'shipment' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'documents',
               'ok', exists (select 1 from public.attachments a where a.footprint_id = f.id),
               'vars', jsonb_build_object('n', (select count(*) from public.attachments a where a.footprint_id = f.id))));
    else
      out := out || jsonb_build_array(jsonb_build_object('key', 'balance', 'ok', true, 'vars', jsonb_build_object('in', f.qty_in, 'out', f.qty_out)));
      if f.stage_type = 'packing' then
        out := out || jsonb_build_array(jsonb_build_object('key', 'batch_code', 'ok', coalesce(btrim(f.payload->>'batch_code'), '') <> '', 'vars', '{}'::jsonb));
      end if;
  end case;
  select not exists (select 1 from public.flags fl where fl.footprint_id = f.id and fl.status = 'open') into ok;
  out := out || jsonb_build_array(jsonb_build_object('key', 'no_open_flags', 'ok', ok, 'vars', '{}'::jsonb));
  return out;
end $function$;
-- The chain: the Warehouse right after the entry stage (or the Collection Batch), before anything else
CREATE OR REPLACE FUNCTION app.chain_problems(p_chain stage_type[], p_crop uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare problems text[] := '{}'; n int := coalesce(array_length(p_chain, 1), 0); allowed public.stage_type[]; st public.stage_type;
begin
  if n < 3 then problems := array_append(problems, 'chain needs at least entry, qc and qr_activation'); return problems; end if;
  if p_chain[1] not in ('procurement','lot_inward') then
    problems := array_append(problems, 'chain must start with procurement or lot_inward'); end if;
  if p_chain[n] <> 'qr_activation' then
    problems := array_append(problems, 'chain must end with qr_activation'); end if;
  if not ('qc' = any(p_chain)) then problems := array_append(problems, 'qc is mandatory in every chain'); end if;
  if (select count(*) from unnest(p_chain)) <> (select count(distinct x) from unnest(p_chain) x) then
    problems := array_append(problems, 'a stage type may appear only once per chain'); end if;
  if 'procurement' = any(p_chain) and 'lot_inward' = any(p_chain) then
    problems := array_append(problems, 'chain may contain procurement or lot_inward, not both'); end if;
  if 'village_batch' = any(p_chain) and p_chain[1] <> 'procurement' then
    problems := array_append(problems, 'village_batch requires procurement as the entry stage'); end if;
  -- migration 55 (C3): the Warehouse takes the farm lots (or the batch) before any processing or the lab
  if 'warehouse' = any(p_chain) and array_position(p_chain, 'warehouse') <> (case when p_chain[2] = 'village_batch' then 3 else 2 end) then
    problems := array_append(problems, 'the warehouse comes right after the entry stage (or the Collection Batch)'); end if;
  select allowed_stages into allowed from public.crops where id = p_crop;
  foreach st in array p_chain loop
    if (select is_processing from public.stage_definitions d where d.stage_type = st)
       and not (st = any(coalesce(allowed, '{}'))) then
      problems := array_append(problems, format('stage %s is not allowed for this crop', st));
    end if;
  end loop;
  return problems;
end $function$;
-- Needs my action: stored lots whose inspection is due; batches stored but not recorded (scopes without a Warehouse)
CREATE OR REPLACE FUNCTION app.my_actions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  return jsonb_build_object(
    -- my records sent back to me
    'returned', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'scope_id', f.scope_id,
               'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'reason', r.reason,
               'by', (select u.display_name from public.app_users u where u.id = r.returned_by), 'at', r.returned_at,
               'in_place', not (f.stage_type in ('qc', 'village_batch') or f.is_grade_lot or f.split_into_grades
                                or exists (select 1 from public.footprints c where c.prev_footprint_id = f.id and c.status not in ('superseded', 'legacy'))))
             order by r.returned_at)
        from public.footprint_returns r
        join public.footprints f on f.id = r.footprint_id
        join public.scopes s on s.id = f.scope_id join public.crops cr on cr.id = s.crop_id
       where r.status = 'open' and f.created_by = me), '[]'::jsonb),
    -- records waiting at the stages I hold (my verification), returned ones apart
    'to_verify', coalesce((
      select jsonb_agg(x order by x->>'scope', (x->>'pos')::int) from (
        select jsonb_build_object('scope_id', sa.scope_id, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
                 'stage', sa.stage_type, 'from_stage', app.chain_prev(sa.scope_id, sa.stage_type), 'pos', app.chain_index(sa.scope_id, sa.stage_type),
                 'n', (select count(*) from public.footprints f
                        where f.scope_id = sa.scope_id and f.stage_type = app.chain_prev(sa.scope_id, sa.stage_type) and f.status = 'pending'
                          and not exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'))) as x
          from (select distinct scope_id, stage_type from public.slot_assignments where user_id = me) sa
          join public.scopes s on s.id = sa.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
         where app.has_slot(me, sa.scope_id, sa.stage_type) and app.chain_prev(sa.scope_id, sa.stage_type) is not null) y
       where (x->>'n')::int > 0), '[]'::jsonb),
    -- corrections of verified farmers proposed by Procurement, for the clients whose account I hold
    'proposals', (select count(*) from public.farmer_proposals p where p.status = 'requested' and app.client_account_holder(me, p.client_id)),
    -- farmers added (drafts) waiting for the Client Manager's verification
    'farmers_to_verify', (select count(*) from public.farmers fm where fm.status = 'draft' and app.client_account_holder(me, fm.client_id)),
    -- migration 51 (Part B): farmers whose farm has no GPS yet, for their Client Manager
    'farmers_without_gps', (select count(*) from public.farmers fm where fm.status in ('under_review', 'active') and fm.farm_lat is null
                             and app.client_account_holder(me, fm.client_id)),
    -- requirement lines HR returned to me with a question
    'requirement_lines', (select count(*) from public.requirement_lines l join public.requirements q on q.id = l.requirement_id
                           where l.status = 'returned' and app.owns_requirement(q)),
    -- open flags and conditions on records of the scopes I manage
    'flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
               where fl.status = 'open' and fl.kind = 'flag' and app.manages_scope(me, f.scope_id)),
    'conditions', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                    where fl.status = 'open' and fl.kind = 'condition' and app.manages_scope(me, f.scope_id)),
    -- migration 49 (A7): milling runs of the last 60 days above their crop's ceiling, in the State Manager's states
    'outturn_review', (select count(*) from public.footprints f join public.scopes s on s.id = f.scope_id
                        where f.stage_type = 'milling' and f.status in ('pending', 'verified') and f.created_at > now() - interval '60 days'
                          and exists (select 1 from unnest(f.warnings) w where w like 'outturn % above the crop''s ceiling%')
                          and exists (select 1 from app.eff_assignments(me) a where a.lens = 'state' and a.state_id = s.state_id)),
    -- migration 55 (C3): lots in the warehouse whose inspection is due or overdue, for who keeps them
    'inspections', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
               'state', i->>'state', 'next_due', i->>'next_due') order by i->>'next_due', f.footprint_code)
        from public.footprints f join public.scopes s on s.id = f.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
        cross join lateral app.inspection_state(f.id) i
       where f.stage_type = 'warehouse' and f.status in ('pending', 'verified') and i->>'state' in ('due', 'overdue')
         and app.keeps_warehouse(me, f.scope_id)), '[]'::jsonb),
    -- migration 55 (C3): in a scope without a Warehouse, a lot waiting for Milling longer than the crop's
    -- stored_unrecorded_days (15) with nothing taken: stored, but not recorded. For the scope's managers.
    'stored_unrecorded', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
               'days', app.today() - (f.verified_at at time zone 'Asia/Kolkata')::date) order by f.verified_at)
        from public.footprints f join public.scopes s on s.id = f.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
       where 'milling' = any (s.chain) and not ('warehouse' = any (s.chain))
         and f.stage_type = app.chain_prev(s.id, 'milling') and f.status = 'verified' and not coalesce(f.lot_closed, false)
         and f.verified_at < now() - make_interval(days => app.opt_num(cr.thresholds, 'stored_unrecorded_days', 15)::int)
         and not exists (select 1 from public.footprints c where c.prev_footprint_id = f.id and c.status not in ('superseded', 'legacy'))
         and app.manages_scope(me, s.id)), '[]'::jsonb)
  );
end $function$;
-- The record page: a stored lot's days, bags and inspections
CREATE OR REPLACE FUNCTION app.footprint_detail(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; vd record; name_of jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  return jsonb_build_object(
    'footprint', to_jsonb(f),
    'stage_label', (select label from public.stage_definitions where stage_type = f.stage_type),
    'created_by_name', (select display_name from public.app_users where id = f.created_by),
    'verified_by_name', (select display_name from public.app_users where id = f.verified_by),
    'farmer', (select jsonb_build_object('name', name, 'farmer_code', farmer_code, 'village', village,
                 'state_farmer_code', (select sf.code from public.state_farmers sf where sf.id = farmers.state_farmer_id))   -- migration 44
                 from public.farmers where id = f.farmer_id),
    'prev', (select jsonb_build_object('id', p.id, 'footprint_code', p.footprint_code, 'stage_type', p.stage_type)
               from public.footprints p where p.id = f.prev_footprint_id),
    'available_kg', app.available_qty(f.id),
    'qc', (select to_jsonb(v) from public.qc_verdicts v where v.footprint_id = f.id),
    'profile_verdicts', coalesce((select jsonb_agg(to_jsonb(pv) order by pv.created_at, pv.code) from public.qc_profile_verdicts pv
                          where pv.footprint_id = vd.qc_footprint_id), '[]'::jsonb),                            -- migration 53
    'closure', (select to_jsonb(lc) || jsonb_build_object('closed_by_name', (select display_name from public.app_users where id = lc.closed_by))
                  from public.lot_closures lc where lc.footprint_id = f.id),
    'net_weight', case when f.stage_type = 'packing' then jsonb_build_object(
                    'needed', app.needs_weight_check(f) and (select s.stage_details_required from public.scopes s where s.id = f.scope_id),
                    'check', (select to_jsonb(n) from public.net_weight_checks n where n.footprint_id = f.id)) end,
    'market_verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'seal', (select to_jsonb(q) from public.qr_seals q where q.footprint_id = f.id),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'status', fl.status, 'created_at', fl.created_at,
               'raised_by_name', (select display_name from public.app_users where id = fl.raised_by), 'kind', fl.kind) order by fl.created_at)
               from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'status', r.status, 'returned_at', r.returned_at,
               'returned_by_name', (select display_name from public.app_users where id = r.returned_by),
               'resolved_at', r.resolved_at, 'resolved_by_name', (select display_name from public.app_users where id = r.resolved_by)) order by r.returned_at)
               from public.footprint_returns r where r.footprint_id = f.id), '[]'::jsonb),                       -- migration 48
    'can_return', f.status = 'pending' and f.created_by is distinct from app.current_user_id()
                  and not coalesce((select d.is_gate from public.stage_definitions d where d.stage_type = f.stage_type), false)
                  and app.is_next_stage_user(app.current_user_id(), f.scope_id, f.stage_type)
                  and not exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'),
    'packs', case when f.stage_type = 'packing' then jsonb_build_object('batch_code', f.payload->>'batch_code',          -- migration 50
               'packed', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'packed'),
               'void', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'void'),
               'prints', (select count(*) from public.label_prints lp where lp.footprint_id = f.id),
               'best_before', (select min(best_before) from public.packs p where p.footprint_id = f.id and p.status = 'packed')) end,
    'sale_terms', (select to_jsonb(st) from public.sale_terms st where st.footprint_id = f.id and app.reads_lot_payment(st.client_id, st.recorded_by)),   -- migration 54
    'export_docs', case when f.stage_type = 'commercial' and f.computed ? 'market_code' then app.export_docs_of(f.id) end,
    'bill_of_lading', (select to_jsonb(b) from public.bills_of_lading b where b.footprint_id = f.id),
    'packs_left', case when f.stage_type in ('packing', 'commercial') then app.packs_left_of(f.id) end,
    'warehouse', app.warehouse_of(f.id),                                                                    -- migration 55
    'delivery', (select to_jsonb(d) || jsonb_build_object('confirmed_by_name', (select display_name from public.app_users where id = d.confirmed_by))
                   from public.deliveries d where d.shipment_id = f.id),
    'release', case when exists (select 1 from public.qr_seals q where q.footprint_id = f.id) then app.release_status(f.id) end,
    'farmers', app.lot_farmers(f.id),                                                                         -- migration 49
    'gi_status', app.lot_gi_status(f.id),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.footprint_code, 'stage', p.stage_type, 'kg', l.kg,
                 'how', l.how, 'from_older', l.from_older) order by p.footprint_code)
                 from public.footprint_links l join public.footprints p on p.id = l.parent_id where l.child_id = f.id), '[]'::jsonb),
    'system_checks', app.system_checks(f.id),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $function$;
-- The public page: how long the lot was in the warehouse
CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false;
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
                   || jsonb_build_object('markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name,
                        'verdict', pv.verdict, 'failed', pv.failed) order by pv.created_at, pv.code), '[]'::jsonb)
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
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then
      step := step || jsonb_build_object('destination', cur.payload->>'destination', 'dispatched_on', cur.payload->>'dispatch_date'); end if;
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
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    'same_person', v_same,
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before))
                from public.packs p where p.footprint_id in (select app.lot_packings(seal.footprint_id)) and p.status = 'packed')
  );
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Every new function closed by hand; the API ones granted by name (tests/08_api_surface.sql)
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.storage_days(uuid) from public, anon, authenticated;
revoke execute on function app.inspection_state(uuid) from public, anon, authenticated;
revoke execute on function app.keeps_warehouse(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.record_inspection(uuid, date, text, text) from public, anon, authenticated;
revoke execute on function app.record_bags_out(uuid, int, date, text) from public, anon, authenticated;
revoke execute on function app.warehouse_of(uuid) from public, anon, authenticated;
revoke execute on function app.footprints_warehouse_flag() from public, anon, authenticated;
grant execute on function app.record_inspection(uuid, date, text, text) to authenticated;
grant execute on function app.record_bags_out(uuid, int, date, text) to authenticated;
