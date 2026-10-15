-- GrainVeda MVP · migration 49: numbers you can trust (the operator-stages brief, release 2; decision G19).
-- Veda, 15 October 2026, "ok complete everything". This release (docs/FIX_LIST.md item 44):
--   A2/G3   The system checks what it knows; people tick only what they see. Each stage has a short list of physical
--           checks (stage_definitions.physical_checks) that the receiving person ticks; app.system_checks(record)
--           answers the rest from the data (farmer verified, readings complete, balance, sources, verdicts, flags).
--           app.verify_record takes the ticks and refuses a verification without them; the ledger keeps them.
--   A3/G2   What is left of a lot: app.incoming_lots gives each waiting lot with its remaining kilograms (the form fills
--           them in), whether it is returned, who made it, its GI status and its farmers.
--   A7/G5   Thresholds from data: the fixed "yield below threshold" (70 % of every scope) is gone. A milling run is
--           warned when its outturn is above the crop's ceiling (crops.thresholds, 70 % unless set), which the State
--           Manager sees, or, once the crop has 10 verified runs, outside their usual range (mean ± 2 SD).
--   E (lineage) footprint_links: every record's sources with the kilograms it took (a batch takes whole lots; a grade
--           lot its grade; any other record its input). Filled for the records already there (marked "older"). From
--           it: app.lot_sources (documented proportions of the first-stage lots), app.lot_farmers (distinct farmers
--           and their shares, G6), app.lot_gi_status (GI only when every source is from the crop's GI districts).
--   GI      crops.gi_districts (the GI area); a farmer's district is matched without spaces or case.
-- Additive only: no record is changed; the new table is filled from what is recorded.
select set_config('app.change_path', 'migration 49', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- GI area and thresholds of a crop (set by its State Manager on the crop's page)
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.crops add column if not exists gi_districts text[] not null default '{}';
alter table public.crops add column if not exists thresholds jsonb not null default '{}'::jsonb;
alter table public.crops add constraint crops_gi_districts_shape check (array_position(gi_districts, '') is null and cardinality(gi_districts) <= 60);
alter table public.crops add constraint crops_thresholds_object check (jsonb_typeof(thresholds) = 'object');

-- ---------------------------------------------------------------------------------------------------------------------
-- A2 · what a person checks with his own eyes; the rest the system checks
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.stage_definitions add column if not exists physical_checks jsonb not null default '[]'::jsonb;
alter table public.stage_definitions add constraint stage_definitions_physical_checks_array check (jsonb_typeof(physical_checks) = 'array');
update public.stage_definitions d set physical_checks = v.c::jsonb from (values
  ('procurement',  '["Bags counted: the number matches the record", "The grain looks and smells sound (no mould, no insects)", "Bags tagged with the lot number"]'),
  ('lot_inward',   '["Bags counted: the number matches the record", "The grain looks and smells sound (no mould, no insects)"]'),
  ('village_batch','["Bags of every lot counted at the collection point", "Batch bags tagged with the batch number"]'),
  ('milling',      '["Rice bags sealed and tagged with the lot number", "The mill line was clear of any other rice"]'),
  ('sorting',      '["Bags sealed and tagged with the lot number"]'),
  ('grading',      '["Each grade bagged apart and tagged with its lot number"]'),
  ('drying',       '["Bags sealed and tagged with the lot number"]'),
  ('popping',      '["Bags sealed and tagged with the lot number"]'),
  ('cleaning',     '["Bags sealed and tagged with the lot number"]'),
  ('blanching',    '["Bags sealed and tagged with the lot number"]'),
  ('cold_storage', '["Bags counted out of storage"]'),
  ('packing',      '["Packs sealed; the labels match the batch", "Wastage bagged and weighed"]'),
  ('qc',           '["Sample bag sealed and labelled", "Counter-sample stored"]'),
  ('commercial',   '["Packs set aside for this buyer counted"]'),
  ('shipment',     '["Packs counted at loading", "Vehicle clean and dry"]'),
  ('qr_activation','[]')) as v(t, c)
 where d.stage_type::text = v.t;

-- What the data already answers about a record, for the person who receives it. Each line: a key (the words are the
-- app's: chk.<key>), whether it holds, and the values it names.
create or replace function app.system_checks(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
      out := out || jsonb_build_array(jsonb_build_object('key', 'village_named', 'ok', coalesce(btrim(f.payload->>'village'), '') <> '', 'vars', '{}'::jsonb));
    when 'qc' then
      select count(*) into m from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q;
      select count(*) into n from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q
       where coalesce(f.payload->'readings', '{}'::jsonb) ? (q->>'param');
      out := out || jsonb_build_array(jsonb_build_object('key', 'params_read', 'ok', n = m, 'vars', jsonb_build_object('n', n, 'm', m)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'verdicts_derived',
               'ok', exists (select 1 from public.qc_verdicts v where v.footprint_id = f.id), 'vars', '{}'::jsonb));
    when 'commercial' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'buyer_market',
               'ok', coalesce(btrim(f.payload->>'buyer'), '') <> '' and coalesce(f.payload->>'market', '') <> '', 'vars', '{}'::jsonb));
      out := out || jsonb_build_array(jsonb_build_object('key', 'export_backed',
               'ok', coalesce(f.payload->>'market', '') <> 'export' or app.export_allowed(f.prev_footprint_id), 'vars', '{}'::jsonb));
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
end $$;

-- Verify (migration 48) now with the ticks: every physical check of the record's stage ticked, kept in the ledger.
drop function if exists app.verify_record(uuid, text, text);
create or replace function app.verify_record(p_fp uuid, p_reason text default null, p_condition text default null, p_checked jsonb default null)
returns public.footprints language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.footprints; v_cond text := nullif(btrim(coalesce(p_condition, '')), '');
  v_need jsonb; v_missing text;
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if v_cond is not null and length(v_cond) < 10 then
    raise exception 'write the condition (at least 10 characters)' using errcode = '23514'; end if;
  if p_checked is not null and jsonb_typeof(p_checked) <> 'array' then
    raise exception 'the checks ticked are a list' using errcode = '22023'; end if;
  select d.physical_checks into v_need from public.footprints f join public.stage_definitions d on d.stage_type = f.stage_type where f.id = p_fp;
  select string_agg(x, '; ') into v_missing from jsonb_array_elements_text(coalesce(v_need, '[]'::jsonb)) x
   where not (coalesce(p_checked, '[]'::jsonb) ? x);
  if v_missing is not null then
    raise exception 'tick what you checked with your own eyes: %', v_missing using errcode = '23514'; end if;
  perform set_config('app.act_reason', left(btrim(coalesce(p_reason, '')), 500), true);
  perform set_config('app.act_condition', coalesce(left(v_cond, 500), ''), true);
  perform set_config('app.act_checked', coalesce(p_checked, '[]'::jsonb)::text, true);
  r := app.verify_footprint(p_fp);
  if v_cond is not null then
    insert into public.flags (footprint_id, raised_by, text, kind) values (r.id, me, left(v_cond, 500), 'condition');
  end if;
  perform set_config('app.act_reason', '', true);
  perform set_config('app.act_condition', '', true);
  perform set_config('app.act_checked', '', true);
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- E · lineage: every record's sources and the kilograms it took
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.footprint_links (
  child_id    uuid not null references public.footprints(id),
  parent_id   uuid not null references public.footprints(id),
  kg          numeric(12,3) not null check (kg >= 0),
  how         text not null check (how in ('input', 'batch', 'grade')),
  from_older  boolean not null default false,            -- filled by migration 49 from what was recorded before
  created_at  timestamptz not null default now(),
  primary key (child_id, parent_id)
);
create index if not exists footprint_links_parent on public.footprint_links (parent_id);
alter table public.footprint_links enable row level security;
revoke all on public.footprint_links from anon, authenticated;            -- read through the functions below only
drop trigger if exists zz_change_log on public.footprint_links;
create trigger zz_change_log after insert or update or delete on public.footprint_links
  for each row execute function app.log_change('child_id', 'parent_id');

-- The links of one record, from the record itself: a batch takes whole lots; a grade lot its grade; anything else
-- its input from the lot it comes from.
create or replace function app.footprint_links_of(f public.footprints) returns table (parent_id uuid, kg numeric, how text)
language sql stable security definer set search_path = public as $$
  select (x)::uuid, coalesce(s.qty_out, 0), 'batch'
    from jsonb_array_elements_text(case when f.stage_type = 'village_batch' then coalesce(f.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x
    left join public.footprints s on s.id = (x)::uuid
  union all
  select f.prev_footprint_id, case when f.is_grade_lot then f.qty_out else f.qty_in end, case when f.is_grade_lot then 'grade' else 'input' end
   where f.prev_footprint_id is not null and f.stage_type <> 'village_batch' $$;

create or replace function app.footprints_links() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.footprint_links (child_id, parent_id, kg, how)
  select new.id, l.parent_id, l.kg, l.how from app.footprint_links_of(new) l
  on conflict (child_id, parent_id) do nothing;
  return new;
end $$;
drop trigger if exists footprints_z3_links on public.footprints;
create trigger footprints_z3_links after insert on public.footprints for each row execute function app.footprints_links();

-- A pending record corrected in place changes its input: its links follow (only a pending one can change).
create or replace function app.footprints_links_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.qty_in is distinct from old.qty_in or new.qty_out is distinct from old.qty_out then
    update public.footprint_links l set kg = x.kg from app.footprint_links_of(new) x
     where l.child_id = new.id and l.parent_id = x.parent_id and l.kg is distinct from x.kg;
  end if;
  return new;
end $$;
drop trigger if exists footprints_z4_links_update on public.footprints;
create trigger footprints_z4_links_update after update on public.footprints for each row execute function app.footprints_links_update();

insert into public.footprint_links (child_id, parent_id, kg, how, from_older)
select f.id, l.parent_id, l.kg, l.how, true
  from public.footprints f cross join lateral app.footprint_links_of(f) l
 where l.parent_id is not null
on conflict (child_id, parent_id) do nothing;

-- The first-stage lots in a record, each with its documented proportion of the record (mass balance through every
-- batch and split: a source's share is the kilograms taken from it over all kilograms taken). Withdrawn records count
-- for nothing.
create or replace function app.lot_sources(p_fp uuid) returns table (entry_id uuid, share numeric)
language sql stable security definer set search_path = public as $$
  with recursive walk(id, share, depth) as (
    select p_fp, 1.0::numeric, 0
    union all
    select l.parent_id, w.share * l.kg / nullif(t.total, 0), w.depth + 1
      from walk w
      join public.footprint_links l on l.child_id = w.id
      join lateral (select sum(kg) as total from public.footprint_links where child_id = w.id) t on true
     where w.depth < 64)
  select w.id, sum(w.share)
    from walk w
   where not exists (select 1 from public.footprint_links l where l.child_id = w.id)
   group by w.id $$;

-- Pure: a place name for comparing ("Siddharth Nagar" = "siddharthnagar").
create or replace function app.norm_place(p text) returns text language sql immutable as $$
  select nullif(lower(regexp_replace(coalesce(p, ''), '[^A-Za-z]', '', 'g')), '') $$;

-- GI status of a first-stage lot: from the crop's GI area and the farmer's district.
create or replace function app.entry_gi(p_fp uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
           when cr.gi_tag is null then 'non_gi'
           when cardinality(cr.gi_districts) = 0 then 'unknown'
           when f.stage_type <> 'procurement' or fm.id is null or app.norm_place(fm.district) is null then 'unknown'
           when app.norm_place(fm.district) in (select app.norm_place(x) from unnest(cr.gi_districts) x) then 'gi'
           else 'non_gi' end
    from public.footprints f
    join public.scopes s on s.id = f.scope_id join public.crops cr on cr.id = s.crop_id
    left join public.farmers fm on fm.id = f.farmer_id
   where f.id = p_fp $$;


-- GI status of any record: GI only when every first-stage lot in it is GI; not GI when any is not; else not known.
create or replace function app.lot_gi_status(p_fp uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when count(*) = 0 then 'unknown'
              when bool_or(g = 'non_gi') then 'non_gi'
              when bool_and(g = 'gi') then 'gi'
              else 'unknown' end
    from (select app.entry_gi(s.entry_id) as g from app.lot_sources(p_fp) s) x $$;

-- The farmers in a record: distinct farmers with their documented share (kilograms of this record and per cent).
create or replace function app.lot_farmers(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('farmer_id', x.farmer_id, 'name', x.name, 'village', x.village, 'district', x.district,
           'share_pct', round(x.share * 100, 1), 'kg', round(x.share * (select qty_out from public.footprints where id = p_fp), 1))
           order by x.share desc, x.name), '[]'::jsonb)
    from (select fm.id as farmer_id, fm.name, fm.village, fm.district, sum(s.share) as share
            from app.lot_sources(p_fp) s
            join public.footprints e on e.id = s.entry_id
            join public.farmers fm on fm.id = e.farmer_id
           group by fm.id, fm.name, fm.village, fm.district) x $$;

-- The lots waiting at a stage, with what is left on each (A3/G2) and what the receiver should know at a glance.
create or replace function app.incoming_lots(p_scope uuid, p_stage public.stage_type) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object(
           'available_kg', app.available_qty(f.id),
           'returned', exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'),
           'maker_name', (select u.display_name from public.app_users u where u.id = f.created_by),
           'made_by_me', f.created_by = app.current_user_id(),
           'gi_status', app.lot_gi_status(f.id),
           'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(f.id) s join public.footprints e on e.id = s.entry_id))
         order by f.created_at), '[]'::jsonb)
    from app.incoming_records(p_scope, p_stage) f $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- A7/G5 · a milling run's outturn against the crop's ceiling and the range of its own verified runs
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.milling_range(p_crop uuid, p_client uuid, p_except uuid)
returns table (n bigint, mean numeric, sd numeric)
language sql stable security definer set search_path = public as $$
  select count(*), avg((m.computed->>'yield_pct')::numeric), stddev_samp((m.computed->>'yield_pct')::numeric)
    from public.footprints m join public.scopes s on s.id = m.scope_id
   where m.stage_type = 'milling' and m.status = 'verified' and s.crop_id = p_crop and s.client_id = p_client
     and m.id is distinct from p_except and m.computed ? 'yield_pct' $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen49.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- A7/G5: no fixed yield threshold; the crop's ceiling and its learned range

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
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;

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

    when 'milling' then
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

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg'); d := app.req_num(p, 'wastage_kg');
      if coalesce(p->>'batch_code', '') = '' then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      if not app.approx_eq(v_in, v_out + d) then
        raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', d, 'batch_code', p->>'batch_code');

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg'); a := app.req_num(p, 'sample_qty_kg');
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);

    when 'commercial' then
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');

    when 'shipment' then
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);

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

-- A2: the verification block carries the checks ticked

CREATE OR REPLACE FUNCTION app.footprints_after_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid;
begin
  if old.status = 'pending' and new.status = 'verified' then
    v_actor := coalesce(app.current_user_id(), new.verified_by);
    perform app.ledger_append(new.id, new.scope_id,
      case when app.manages_scope(new.verified_by, new.scope_id)
            and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           then 'supervisory'::public.ledger_event else 'verify'::public.ledger_event end,
      v_actor, app.footprint_snapshot(new) || jsonb_strip_nulls(jsonb_build_object(                -- migration 48
        'verify_reason', nullif(current_setting('app.act_reason', true), ''), 'condition', nullif(current_setting('app.act_condition', true), ''),
        'checked', nullif(nullif(current_setting('app.act_checked', true), ''), '[]')::jsonb)));   -- migration 49: what he ticked
  end if;
  if new.status = 'superseded' and old.status <> 'superseded' then
    perform app.ledger_append(new.id, new.scope_id, 'supersede', app.current_user_id(), app.footprint_snapshot(new));
  end if;
  if new.lot_closed and not old.lot_closed then
    perform app.ledger_append(new.id, new.scope_id, 'close', app.current_user_id(),
      jsonb_build_object('id', new.id, 'lot_closed', true, 'available_kg', app.available_qty(new.id)));
  end if;
  return new;
end$function$;

-- A2: the stage form gives the previous stage's physical checks (the receiver ticks them)

CREATE OR REPLACE FUNCTION app.stage_form(p_scope uuid, p_stage stage_type)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; me uuid := app.current_user_id(); idx int; prev_t public.stage_type; next_t public.stage_type;
begin
  if me is null or not app.can_access_scope(p_scope) then
    raise exception 'no access to this scope' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = p_scope;
  idx := app.chain_index(p_scope, p_stage);
  if idx is null then raise exception 'stage % is not in this scope''s chain', p_stage using errcode = '23514'; end if;
  prev_t := case when idx > 1 then sc.chain[idx - 1] end;
  next_t := sc.chain[idx + 1];
  return jsonb_build_object(
    'scope', jsonb_build_object('id', sc.id, 'season_code', sc.season_code, 'geography', sc.geography, 'status', sc.status, 'short_code', sc.short_code,
               'chain', to_jsonb(sc.chain), 'tolerances', sc.tolerances,
               'client', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.clients where id = sc.client_id),
               'crop', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'gi_tag', gi_tag, 'primary_unit', primary_unit)
                          from public.crops where id = sc.crop_id)),
    'stage', (select to_jsonb(d) from public.stage_definitions d where d.stage_type = p_stage),
    'position', idx,
    'prev_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label, 'handoff_checks', d.handoff_checks, 'physical_checks', d.physical_checks)
                     from public.stage_definitions d where d.stage_type = prev_t),
    'next_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label)
                     from public.stage_definitions d where d.stage_type = next_t),
    'quality_params', coalesce(sc.quality_params, (select quality_params from public.crops where id = sc.crop_id)),
    'can_create', app.is_my_stage(me, p_scope, p_stage),
    'can_verify_incoming', prev_t is not null and (app.i_manage_scope(p_scope) or app.has_slot(me, p_scope, p_stage)),
    -- migration 48 (A10): a manager at a stage he does not hold gives a reason
    'records_as_manager', app.is_my_stage(me, p_scope, p_stage) and app.manages_scope(me, p_scope) and not app.has_slot(me, p_scope, p_stage),
    'verifies_as_manager', prev_t is not null and app.i_manage_scope(p_scope) and not app.has_slot(me, p_scope, p_stage)
  );
end$function$;

-- the record page: its farmers (documented proportions), GI status, sources with the kilograms taken, the checks

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

-- G6: the public page counts farmers, not lots; it says the GI status of the sealed lot

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
      step := step || jsonb_build_object('farmer', jsonb_build_object('name', fm.name, 'village', fm.village, 'district', fm.district,
                                            'photo', case when fm.photo_consent then fm.extra->>'photo_path' else null end));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', cur.payload->>'village', 'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('name', g.name, 'village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.name)
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
    'gi_status', app.lot_gi_status(seal.footprint_id)                                                    -- migration 49
  );
end $function$;

-- the State Manager's "Needs my action": milling runs above the crop's ceiling in his state

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
                          and exists (select 1 from app.eff_assignments(me) a where a.lens = 'state' and a.state_id = s.state_id))
  );
end $function$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Every new function is closed by hand, then opened to whom it is for (AGENTS.md)
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.system_checks(uuid) from public, anon, authenticated;
revoke execute on function app.verify_record(uuid, text, text, jsonb) from public, anon, authenticated;
revoke execute on function app.footprint_links_of(public.footprints) from public, anon, authenticated;
revoke execute on function app.footprints_links() from public, anon, authenticated;
revoke execute on function app.footprints_links_update() from public, anon, authenticated;
revoke execute on function app.lot_sources(uuid) from public, anon, authenticated;
revoke execute on function app.norm_place(text) from public, anon, authenticated;
revoke execute on function app.entry_gi(uuid) from public, anon, authenticated;
revoke execute on function app.lot_gi_status(uuid) from public, anon, authenticated;
revoke execute on function app.lot_farmers(uuid) from public, anon, authenticated;
revoke execute on function app.incoming_lots(uuid, public.stage_type) from public, anon, authenticated;
revoke execute on function app.milling_range(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.system_checks(uuid) to authenticated;
grant execute on function app.verify_record(uuid, text, text, jsonb) to authenticated;
grant execute on function app.incoming_lots(uuid, public.stage_type) to authenticated;
