-- GrainVeda MVP · migration 53 (Veda, 15 Oct 2026, "ok proceed ahead with release 53", decision G19): release 6 of the
-- operator-stages plan. C4 Milling (the mill from the list, line clearance, the mill operator, head rice / broken /
-- husk / bran with the loss worked out, recovery and head-rice %, transit loss when the mill is elsewhere, the usual
-- range learned per mill, "close lot" with the rest as floor loss), C5 Quality Control (the lab from the list, a sample
-- drawn by the system with its retained counter-sample, "sent to the lab, awaiting results", disposal, lab tests only
-- at an external lab, a verdict per market profile of the scope), C6 Packing (the packing unit from the list, packs from
-- the client's pack list, wastage worked out with a reason above 2 %, best-before per packing material, the net weight
-- check of 5 packs picked by the system). Additive: nothing is deleted or rewritten; records already there keep their
-- payloads and are read as before.
select set_config('app.change_path', 'migration 53', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- The scope's settings (the Client Manager's, changed at any time)
-- ---------------------------------------------------------------------------------------------------------------------
-- The full details at Milling, QC and Packing (the mill, its operator; the sample and the lab from the list; the packing
-- unit and packs from the pack list). A scope made from now on asks them; the demo scopes are set not to (seed 09).
alter table public.scopes add column if not exists stage_details_required boolean not null default true;
-- The markets the lab tests for (C5: "built from the market profiles for this scope's markets"): profile codes.
alter table public.scopes add column if not exists market_codes text[] not null default '{domestic,export}';
do $$ begin
  alter table public.scopes add constraint scopes_market_codes_size check (cardinality(market_codes) between 1 and 12);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C4 · Milling: the usual range of a mill; close a lot with the rest as floor loss
-- ---------------------------------------------------------------------------------------------------------------------
-- "After about 10 runs for a mill (and variety), outside the usual range for this mill" (information only). The variety
-- is not recorded (Veda: no variety check now): the mill and the crop.
create or replace function app.milling_range_mill(p_crop uuid, p_mill text, p_except uuid)
returns table (n bigint, mean numeric, sd numeric)
language sql stable security definer set search_path = public as $$
  select count(*), avg((m.computed->>'recovery_pct')::numeric), stddev_samp((m.computed->>'recovery_pct')::numeric)
    from public.footprints m join public.scopes s on s.id = m.scope_id
   where m.stage_type = 'milling' and m.status = 'verified' and s.crop_id = p_crop and m.payload->>'mill_id' = p_mill
     and m.id is distinct from p_except and m.computed ? 'recovery_pct' $$;

-- A lot with 2 % or less left (or under the scope's auto-close weight) is closed by the next stage or a manager: what is
-- left is recorded as floor loss, and nothing more can be taken from it. Kept apart from the record (the record does not
-- change); its history in the change log.
create table if not exists public.lot_closures (
  footprint_id  uuid primary key references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  floor_loss_kg numeric(14,3) not null check (floor_loss_kg >= 0),
  reason        text not null check (length(btrim(reason)) between 5 and 300),
  closed_by     uuid not null references public.app_users(id),
  closed_at     timestamptz not null default now()
);
alter table public.lot_closures enable row level security;
revoke all on public.lot_closures from anon, authenticated;
grant select on public.lot_closures to authenticated;
drop policy if exists lot_closures_read on public.lot_closures;
create policy lot_closures_read on public.lot_closures for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
drop trigger if exists zz_change_log on public.lot_closures;
create trigger zz_change_log after insert or update or delete on public.lot_closures for each row execute function app.log_change('lot_closure');

create or replace function app.close_lot(p_fp uuid, p_reason text) returns public.lot_closures
language plpgsql security definer set search_path = public as $$
declare f public.footprints; me uuid := app.current_user_id(); v_left numeric; v_close numeric; r public.lot_closures;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not (app.manages_scope(me, f.scope_id) or app.is_next_stage_user(me, f.scope_id, f.stage_type)) then
    raise exception 'a lot is closed by the next stage or a manager of the scope' using errcode = '42501'; end if;
  if f.status <> 'verified' then raise exception 'only a verified lot is closed' using errcode = '23514'; end if;
  if exists (select 1 from public.lot_closures c where c.footprint_id = f.id) then
    raise exception 'this lot is closed already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'say why the lot is closed (at least 5 characters)' using errcode = '23514'; end if;
  v_left := app.available_qty(f.id);
  if v_left <= 0 then raise exception 'nothing is left of this lot: it is closed already' using errcode = '23514'; end if;
  select app.opt_num(s.tolerances, 'auto_close_kg', 2) into v_close from public.scopes s where s.id = f.scope_id;
  if v_left > greatest(f.qty_out * 0.02, v_close) then
    raise exception 'only a lot with 2 %% or less left is closed (% kg of % kg is left)', round(v_left, 1), round(f.qty_out, 1)
      using errcode = '23514'; end if;
  insert into public.lot_closures (footprint_id, scope_id, floor_loss_kg, reason, closed_by)
  values (f.id, f.scope_id, greatest(v_left, 0), btrim(p_reason), me) returning * into r;
  perform app.sync_lot_closed(f.id);
  perform app.audit('lot_closed', f.id, jsonb_build_object('code', f.footprint_code, 'floor_loss_kg', r.floor_loss_kg, 'reason', r.reason), false);
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C5 · Quality Control: the sample, drawn first, with its retained counter-sample
-- ---------------------------------------------------------------------------------------------------------------------
-- The sample is drawn from the lot QC received ("Sent to lab, awaiting results"); its ID is given by the system
-- (<lot>-S1, -S2 …); the counter-sample is sealed and kept until a date; a buyer's sample may go with it. The QC
-- record names the sample when the results are in. A disposal is recorded; nothing is deleted.
create table if not exists public.qc_samples (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  footprint_id     uuid not null references public.footprints(id),
  scope_id         uuid not null references public.scopes(id),
  client_id        uuid not null references public.clients(id),
  drawn_on         date not null,
  qty_kg           numeric(12,3) not null check (qty_kg > 0),
  lab_id           uuid references public.labs(id),
  counter_seal_no  text check (counter_seal_no is null or length(btrim(counter_seal_no)) between 2 and 40),
  counter_stored_at text check (counter_stored_at is null or length(btrim(counter_stored_at)) between 2 and 120),
  keep_until       date,
  buyer_seal_no    text check (buyer_seal_no is null or length(btrim(buyer_seal_no)) between 2 and 40),
  buyer_recipient  text check (buyer_recipient is null or length(btrim(buyer_recipient)) between 2 and 120),
  status           text not null default 'sent' check (status in ('sent', 'results_in', 'disposed')),
  qc_footprint_id  uuid references public.footprints(id),
  disposed_on      date,
  disposal_note    text check (disposal_note is null or length(btrim(disposal_note)) between 10 and 300),
  disposed_by      uuid references public.app_users(id),
  created_by       uuid not null references public.app_users(id),
  created_at       timestamptz not null default now(),
  check ((buyer_seal_no is null) = (buyer_recipient is null)),
  check (keep_until is null or keep_until >= drawn_on),
  check (status <> 'disposed' or (disposed_on is not null and disposal_note is not null and disposed_by is not null))
);
alter table public.qc_samples enable row level security;
revoke all on public.qc_samples from anon, authenticated;
grant select on public.qc_samples to authenticated;
drop policy if exists qc_samples_read on public.qc_samples;
create policy qc_samples_read on public.qc_samples for select to authenticated using (app.can_see_footprint(scope_id, 'qc'));
drop trigger if exists zz_change_log on public.qc_samples;
create trigger zz_change_log after insert or update or delete on public.qc_samples for each row execute function app.log_change('qc_sample');

create or replace function app.draw_sample(p_fp uuid, p jsonb) returns public.qc_samples
language plpgsql security definer set search_path = public as $$
declare f public.footprints; sc public.scopes; me uuid := app.current_user_id(); v_on date; v_lot date; v_qty numeric; lb public.labs;
        r public.qc_samples; v_n int; v_keep date;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  if app.chain_next(f.scope_id, f.stage_type) is distinct from 'qc' then
    raise exception 'a sample is drawn from a lot that goes to Quality Control' using errcode = '23514'; end if;
  if not (app.has_slot(me, f.scope_id, 'qc') or app.manages_scope(me, f.scope_id)) then
    raise exception 'the sample is drawn by Quality Control of this scope' using errcode = '42501'; end if;
  if f.status <> 'verified' then raise exception 'verify the lot before drawing its sample' using errcode = '23514'; end if;
  begin v_on := coalesce(nullif(p->>'drawn_on', '')::date, (now() at time zone 'Asia/Kolkata')::date);
  exception when others then raise exception 'sample: the date drawn is a date' using errcode = '23514'; end;
  v_lot := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  if v_on > (now() at time zone 'Asia/Kolkata')::date or v_on < v_lot then
    raise exception 'sample: drawn between the lot''s date (%) and today', to_char(v_lot, 'DD Mon YYYY') using errcode = '23514'; end if;
  v_qty := app.opt_num(p, 'qty_kg', null);
  if v_qty is null or v_qty <= 0 then raise exception 'sample: the quantity drawn is more than 0 kg' using errcode = '23514'; end if;
  if v_qty >= app.available_qty(f.id) then
    raise exception 'sample: the sample is smaller than what is left of the lot (% kg)', round(app.available_qty(f.id), 1) using errcode = '23514'; end if;
  if nullif(p->>'lab_id', '') is not null then
    select * into lb from public.labs where id::text = p->>'lab_id' and active and state_id = sc.state_id;
    if lb.id is null then raise exception 'sample: the lab is not one of this state''s labs' using errcode = '23514'; end if;
  elsif sc.stage_details_required then
    raise exception 'sample: name the lab it goes to (from the state''s list)' using errcode = '23514';
  end if;
  if sc.stage_details_required and (length(btrim(coalesce(p->>'counter_seal_no', ''))) < 2 or length(btrim(coalesce(p->>'counter_stored_at', ''))) < 2) then
    raise exception 'sample: the retained counter-sample''s seal number and where it is stored are required' using errcode = '23514'; end if;
  if (nullif(btrim(p->>'buyer_seal_no'), '') is null) <> (nullif(btrim(p->>'buyer_recipient'), '') is null) then
    raise exception 'sample: a buyer''s sample names its seal number and who receives it' using errcode = '23514'; end if;
  begin v_keep := coalesce(nullif(p->>'keep_until', '')::date, (v_on + interval '12 months')::date);
  exception when others then raise exception 'sample: keep until is a date' using errcode = '23514'; end;
  if v_keep < v_on then raise exception 'sample: kept until a date after it is drawn' using errcode = '23514'; end if;
  select count(*) + 1 into v_n from public.qc_samples s where s.footprint_id = f.id;
  insert into public.qc_samples (code, footprint_id, scope_id, client_id, drawn_on, qty_kg, lab_id, counter_seal_no, counter_stored_at,
                                 keep_until, buyer_seal_no, buyer_recipient, created_by)
  values (f.footprint_code || '-S' || v_n, f.id, f.scope_id, f.client_id, v_on, v_qty, lb.id, nullif(btrim(p->>'counter_seal_no'), ''),
          nullif(btrim(p->>'counter_stored_at'), ''), v_keep, nullif(btrim(p->>'buyer_seal_no'), ''), nullif(btrim(p->>'buyer_recipient'), ''), me)
  returning * into r;
  return r;
end $$;

create or replace function app.dispose_sample(p_sample uuid, p_note text) returns public.qc_samples
language plpgsql security definer set search_path = public as $$
declare s public.qc_samples; me uuid := app.current_user_id();
begin
  select * into s from public.qc_samples where id = p_sample;
  if s.id is null or me is null or not app.can_see_footprint(s.scope_id, 'qc') then raise exception 'sample not found' using errcode = 'P0002'; end if;
  if not (app.has_slot(me, s.scope_id, 'qc') or app.manages_scope(me, s.scope_id)) then
    raise exception 'a sample is disposed of by Quality Control or a manager of the scope' using errcode = '42501'; end if;
  if s.status = 'disposed' then raise exception 'this sample is disposed of already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then raise exception 'say how and why it was disposed of (at least 10 characters)' using errcode = '23514'; end if;
  if s.keep_until is not null and s.keep_until > (now() at time zone 'Asia/Kolkata')::date and not app.manages_scope(me, s.scope_id) then
    raise exception 'the counter-sample is kept until %: before then only a manager disposes of it', to_char(s.keep_until, 'DD Mon YYYY')
      using errcode = '42501'; end if;
  update public.qc_samples set status = 'disposed', disposed_on = (now() at time zone 'Asia/Kolkata')::date, disposal_note = btrim(p_note), disposed_by = me
   where id = s.id returning * into s;
  return s;
end $$;

-- The samples of a lot (its QC page and record page). Read through the table's own rule.
create or replace function app.lot_samples(p_fp uuid) returns jsonb
language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(s) || jsonb_build_object('lab_name', (select l.name from public.labs l where l.id = s.lab_id),
           'qc_code', (select q.footprint_code from public.footprints q where q.id = s.qc_footprint_id)) order by s.created_at), '[]'::jsonb)
    from public.qc_samples s where s.footprint_id = p_fp $$;

-- The QC record names its sample: it is then "results in"; a withdrawn QC record gives it back ("sent").
create or replace function app.footprints_sample() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage_type <> 'qc' or nullif(new.payload->>'sample_ref', '') is null then return null; end if;
  if tg_op = 'INSERT' then
    update public.qc_samples set status = 'results_in', qc_footprint_id = new.id where id::text = new.payload->>'sample_ref' and status = 'sent';
  elsif new.status = 'superseded' and old.status <> 'superseded' then
    update public.qc_samples set status = 'sent', qc_footprint_id = null where qc_footprint_id = new.id and status = 'results_in';
  end if;
  return null;
end $$;
drop trigger if exists footprints_z7_sample on public.footprints;
create trigger footprints_z7_sample after insert or update on public.footprints for each row execute function app.footprints_sample();

-- ---------------------------------------------------------------------------------------------------------------------
-- C5 · A verdict per market profile of the scope ("Domestic PASS · EU FAIL (residue) · UAE PASS")
-- ---------------------------------------------------------------------------------------------------------------------
-- Judged once, when the QC record is saved, against the profile versions in use then (kept with their version). The
-- domestic and export verdicts that open or close a sale stay as they are (the crop's limits, migration 42).
create table if not exists public.qc_profile_verdicts (
  footprint_id uuid not null references public.footprints(id),
  profile_id   uuid not null references public.market_profiles(id),
  code         text not null,
  name         text not null,
  version      int not null,
  verdict      public.verdict not null,
  failed       jsonb not null default '[]'::jsonb,
  missing      jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  primary key (footprint_id, profile_id)
);
alter table public.qc_profile_verdicts enable row level security;
revoke all on public.qc_profile_verdicts from anon, authenticated;
grant select on public.qc_profile_verdicts to authenticated;
drop policy if exists qc_profile_verdicts_read on public.qc_profile_verdicts;
create policy qc_profile_verdicts_read on public.qc_profile_verdicts for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
drop trigger if exists zz_change_log on public.qc_profile_verdicts;
create trigger zz_change_log after insert or update or delete on public.qc_profile_verdicts for each row execute function app.log_change('qc_profile_verdict');

-- A reading of a profile's test: under the library's key, or under a crop's own key that is the same test (alias_of).
create or replace function app.reading_for(p_param text, p_readings jsonb) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(p_readings -> p_param,
                  (select p_readings -> l.param from public.quality_param_library l
                    where l.alias_of = p_param and p_readings ? l.param order by l.param limit 1)) $$;

-- One profile against the readings: pass / fail / pending, with the tests that failed and those not read.
create or replace function app.judge_profile(p_params jsonb, p_readings jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; lib public.quality_param_library; raw jsonb; v numeric; ok boolean; failed jsonb := '[]'; missing jsonb := '[]';
begin
  for x in select * from jsonb_array_elements(coalesce(p_params, '[]'::jsonb)) loop
    select * into lib from public.quality_param_library where param = x->>'param';
    raw := app.reading_for(x->>'param', coalesce(p_readings, '{}'::jsonb));
    if raw is null or raw = 'null'::jsonb or btrim(raw #>> '{}') = '' then missing := missing || to_jsonb(coalesce(lib.name, x->>'param')); continue; end if;
    ok := null;
    if coalesce(lib.type, 'number') = 'grade' then
      ok := coalesce(x->'pass', '[]'::jsonb) @> jsonb_build_array(btrim(raw #>> '{}'));
    elsif lib.type = 'yesno' then
      ok := case when lower(raw #>> '{}') in ('true', 'yes', 'y') then true when lower(raw #>> '{}') in ('false', 'no', 'n') then false end
            = (x->>'pass')::boolean;
    else
      begin v := (raw #>> '{}')::numeric; exception when others then v := null; end;
      if v is null then missing := missing || to_jsonb(coalesce(lib.name, x->>'param')); continue; end if;
      ok := case x->>'operator' when '<=' then v <= (x->>'limit')::numeric when '<' then v < (x->>'limit')::numeric
                                when '>=' then v >= (x->>'limit')::numeric when '>' then v > (x->>'limit')::numeric end;
    end if;
    if ok is not true then failed := failed || to_jsonb(coalesce(lib.name, x->>'param')); end if;
  end loop;
  return jsonb_build_object('verdict', case when jsonb_array_length(failed) > 0 then 'fail' when jsonb_array_length(missing) > 0 then 'pending' else 'pass' end,
                            'failed', failed, 'missing', missing);
end $$;

create or replace function app.judge_profiles(p_fp uuid) returns int
language plpgsql security definer set search_path = public as $$
declare f public.footprints; sc public.scopes; mp public.market_profiles; j jsonb; n int := 0;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.stage_type <> 'qc' then return 0; end if;
  select * into sc from public.scopes where id = f.scope_id;
  for mp in select * from public.market_profiles m where m.crop_id = sc.crop_id and m.status = 'active' and m.code = any (sc.market_codes)
            order by array_position(sc.market_codes, m.code), m.code loop
    j := app.judge_profile(mp.params, f.payload->'readings');
    insert into public.qc_profile_verdicts (footprint_id, profile_id, code, name, version, verdict, failed, missing)
    values (f.id, mp.id, mp.code, mp.name, mp.version, (j->>'verdict')::public.verdict, j->'failed', j->'missing')
    on conflict (footprint_id, profile_id) do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;

-- What the QC record reads: the crop's own tests, then the tests of the scope's market profiles that the crop does not
-- already read (named from the library). The form shows them all; the operator picks nothing.
create or replace function app.scope_test_params(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with sc as (select s.*, coalesce(s.quality_params, c.quality_params, '[]'::jsonb) as qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = p_scope),
       own as (select x->>'param' as param from sc, jsonb_array_elements(sc.qp) x),
       extra as (
         select distinct on (x->>'param') x->>'param' as param, x->>'operator' as op, l.name, l.unit, l.type, l.done_by, l.sort_order
           from sc join public.market_profiles m on m.crop_id = sc.crop_id and m.status = 'active' and m.code = any (sc.market_codes)
           cross join jsonb_array_elements(m.params) x
           join public.quality_param_library l on l.param = x->>'param'
          where not exists (select 1 from own o where o.param = x->>'param')
            and not exists (select 1 from own o join public.quality_param_library a on a.param = o.param and a.alias_of = x->>'param'))
  select (select qp from sc) || coalesce((select jsonb_agg(jsonb_build_object('param', e.param, 'label', e.name, 'unit', e.unit,
            'type', e.type, 'operator', coalesce(e.op, '<='), 'from_profile', true, 'done_by', e.done_by) order by e.sort_order, e.param) from extra e), '[]'::jsonb) $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C6 · Packing: the pack's material (best-before), the net weight check
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.packs add column if not exists sku_id uuid references public.pack_skus(id);

-- Legal Metrology (Packaged Commodities) Rules, 2011, Schedule II: the error a pack may be short of its stated size.
create or replace function app.short_allowed_g(p_size_g numeric) returns numeric
language sql immutable as $$
  select case when p_size_g <= 50 then p_size_g * 0.09 when p_size_g <= 100 then 4.5 when p_size_g <= 200 then p_size_g * 0.045
              when p_size_g <= 300 then 9 when p_size_g <= 500 then p_size_g * 0.03 when p_size_g <= 1000 then 15
              when p_size_g <= 10000 then p_size_g * 0.015 when p_size_g <= 15000 then 150 else p_size_g * 0.01 end $$;

-- C6: the system picks 5 packs at random; the operator weighs them; each must be no more short of its size than the
-- rules allow. Required for export packs and packs of 5 kg or less (the packing record is verified only then).
create table if not exists public.net_weight_checks (
  footprint_id uuid primary key references public.footprints(id),
  scope_id     uuid not null references public.scopes(id),
  serials      text[] not null check (cardinality(serials) between 1 and 5),
  picked_by    uuid not null references public.app_users(id),
  picked_at    timestamptz not null default now(),
  weights      jsonb,
  result       text check (result is null or result in ('pass', 'fail')),
  checked_by   uuid references public.app_users(id),
  checked_at   timestamptz
);
alter table public.net_weight_checks enable row level security;
revoke all on public.net_weight_checks from anon, authenticated;
grant select on public.net_weight_checks to authenticated;
drop policy if exists net_weight_checks_read on public.net_weight_checks;
create policy net_weight_checks_read on public.net_weight_checks for select to authenticated using (app.can_see_footprint(scope_id, 'packing'));
drop trigger if exists zz_change_log on public.net_weight_checks;
create trigger zz_change_log after insert or update or delete on public.net_weight_checks for each row execute function app.log_change('net_weight_check');

create or replace function app.weighs_packs(p_me uuid, f public.footprints) returns boolean
language sql stable security definer set search_path = public as $$
  select f.created_by = p_me or app.has_slot(p_me, f.scope_id, 'packing') or app.manages_scope(p_me, f.scope_id)
         or app.is_next_stage_user(p_me, f.scope_id, f.stage_type) $$;

-- The 5 packs to weigh (picked once; picked again if a correction voided them).
create or replace function app.pick_net_weight(p_fp uuid) returns public.net_weight_checks
language plpgsql security definer set search_path = public as $$
declare f public.footprints; me uuid := app.current_user_id(); r public.net_weight_checks; v text[];
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type <> 'packing' then raise exception 'the net weight check is made at Packing' using errcode = '23514'; end if;
  if not app.weighs_packs(me, f) then raise exception 'the packs are weighed at Packing or by the stage that receives them' using errcode = '42501'; end if;
  select * into r from public.net_weight_checks where footprint_id = f.id;
  if r.footprint_id is not null and not exists (select 1 from unnest(r.serials) s where not exists
         (select 1 from public.packs p where p.serial = s and p.status = 'packed')) then
    return r; end if;
  select array_agg(serial order by rnd) into v from (select p.serial, random() as rnd from public.packs p
     where p.footprint_id = f.id and p.status = 'packed' order by rnd limit 5) x;
  if v is null then raise exception 'this packing record has no packs to weigh' using errcode = '23514'; end if;
  insert into public.net_weight_checks (footprint_id, scope_id, serials, picked_by) values (f.id, f.scope_id, v, me)
  on conflict (footprint_id) do update set serials = excluded.serials, picked_by = excluded.picked_by, picked_at = now(),
                                           weights = null, result = null, checked_by = null, checked_at = null
  returning * into r;
  return r;
end $$;

-- The weights, in grams, of the packs picked: {serial: grams}. Weighed again if needed (the change log keeps each).
create or replace function app.record_net_weights(p_fp uuid, p_weights jsonb) returns public.net_weight_checks
language plpgsql security definer set search_path = public as $$
declare f public.footprints; me uuid := app.current_user_id(); r public.net_weight_checks; s text; g numeric; pk public.packs;
        res jsonb := '{}'; all_ok boolean := true; v_ok boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.weighs_packs(me, f) then raise exception 'the packs are weighed at Packing or by the stage that receives them' using errcode = '42501'; end if;
  select * into r from public.net_weight_checks where footprint_id = f.id;
  if r.footprint_id is null then raise exception 'pick the packs to weigh first' using errcode = '23514'; end if;
  foreach s in array r.serials loop
    begin g := (p_weights->>s)::numeric; exception when others then g := null; end;
    if g is null or g <= 0 or g > 100000 then raise exception 'weigh pack % (its weight in grams)', s using errcode = '23514'; end if;
    select * into pk from public.packs where serial = s;
    v_ok := g >= pk.size_kg * 1000 - app.short_allowed_g(pk.size_kg * 1000);
    all_ok := all_ok and v_ok;
    res := res || jsonb_build_object(s, jsonb_build_object('g', g, 'size_g', pk.size_kg * 1000, 'allowed_short_g', round(app.short_allowed_g(pk.size_kg * 1000), 1), 'ok', v_ok));
  end loop;
  update public.net_weight_checks set weights = res, result = case when all_ok then 'pass' else 'fail' end, checked_by = me, checked_at = now()
   where footprint_id = f.id returning * into r;
  return r;
end $$;

-- Packing records that need the check: export packs, or packs of 5 kg or less (a pack from the list, or a size typed).
create or replace function app.needs_weight_check(f public.footprints) returns boolean
language sql stable security definer set search_path = public as $$
  select f.stage_type = 'packing' and exists (
    select 1 from jsonb_array_elements(coalesce(f.payload->'packets', '[]'::jsonb)) x
      left join public.pack_skus k on k.id::text = x->>'sku_id'
     where k.market = 'export' or (x->>'size_kg')::numeric <= 5) $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- The stage forms (stage_definitions): Milling, Quality Control, Packing; what Commercial ticks
-- ---------------------------------------------------------------------------------------------------------------------
-- Milling: head rice, broken, husk and bran replace "rice out / bran / loss" (the loss is worked out). Records of before
-- keep their payloads and are read and corrected as before (app.reconcile reads both).
update public.stage_definitions set form_schema = '[
  {"key": "mill_id", "type": "mill", "label": "Mill", "section": "mill", "required": false, "required_when": "stage_details_required"},
  {"key": "line_clearance", "type": "select", "label": "Line clearance", "options": ["fully_cleaned", "quick_clean", "same_crop"], "section": "mill", "required": false},
  {"key": "mill_operator", "type": "text", "label": "Mill operator", "section": "mill", "required": false, "required_when": "stage_details_required"},
  {"key": "input_kg", "type": "number", "unit": "kg", "label": "Paddy in", "section": "input", "required": true},
  {"key": "sent_kg", "type": "number", "unit": "kg", "label": "Sent from the lot (when the mill is elsewhere)", "section": "input", "required": false},
  {"key": "head_rice_kg", "type": "number", "unit": "kg", "label": "Head rice", "section": "output", "required": true},
  {"key": "broken_kg", "type": "number", "unit": "kg", "label": "Broken rice", "section": "output", "required": true},
  {"key": "husk_kg", "type": "number", "unit": "kg", "label": "Husk", "section": "output", "required": true},
  {"key": "bran_kg", "type": "number", "unit": "kg", "label": "Bran", "section": "output", "required": true},
  {"key": "polish", "type": "select", "label": "Polish", "options": ["light", "medium", "full"], "section": "optional", "required": false},
  {"key": "slip", "type": "attachment", "label": "Mill slip (photo)", "section": "optional", "required": false, "label_as": "document"}
]'::jsonb,
  handoff_checks = '["Loss worked out from the outputs", "Recovery and head rice reviewed", "Head rice forwarded"]'::jsonb
 where stage_type = 'milling';

-- Quality Control: where the scope asks the details, the sample drawn first (its quantity, lab and counter-sample come
-- with it) replaces the typed sample quantity and lab name; elsewhere the form is as before.
update public.stage_definitions d set form_schema = (
    select coalesce(jsonb_agg(y order by k), '[]'::jsonb) from (
      select case
               when x->>'key' in ('sample_qty_kg', 'lab_name') then x || '{"hidden_when": "stage_details_required"}'::jsonb
               when x->>'key' = 'sample_id' then x || '{"label": "Shared sample ID (two lots tested on one sample)"}'::jsonb
               else x end as y, n::numeric as k
        from jsonb_array_elements(d.form_schema) with ordinality as e(x, n) where x->>'key' not in ('sample_ref', 'lab_id')
      union all   -- the sample stands next to the lot quantity, in the "sample" section
      select '{"key": "sample_ref", "type": "qc_sample", "label": "Sample (drawn and sent to the lab)", "section": "sample", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"}'::jsonb,
             coalesce((select n from jsonb_array_elements(d.form_schema) with ordinality as e(x, n) where x->>'key' = 'qty_kg'), 0) + 0.5
    ) z)
 where stage_type = 'qc';

-- Packing: the packing unit; packs from the client's pack list (where the scope asks the details; typed sizes
-- otherwise); the wastage worked out, with a reason above 2 %.
update public.stage_definitions set form_schema = '[
  {"key": "input_kg", "type": "number", "unit": "kg", "label": "Input", "section": "input", "required": true},
  {"key": "packing_unit_id", "type": "packing_unit", "label": "Packing unit", "section": "packing", "required": false, "required_when": "stage_details_required"},
  {"key": "packets", "type": "sku_packs", "label": "Packs (from the pack list)", "section": "packing", "required": true, "shown_when": "stage_details_required"},
  {"key": "packets", "type": "packets[]", "label": "Packets", "section": "packing", "required": true, "hidden_when": "stage_details_required"},
  {"key": "wastage_reason", "type": "text", "label": "Why the wastage is above 2 % (when it is)", "section": "packing", "required": false}
]'::jsonb,
  handoff_checks = '["Batch code given by the system", "Packs + wastage = input", "Packed quantity forwarded"]'::jsonb
 where stage_type = 'packing';

-- Commercial checks the pack count per size, then accepts or returns (C6).
update public.stage_definitions set physical_checks = physical_checks || '["Pack count per size matches the packing record"]'::jsonb
 where stage_type = 'packing' and not (physical_checks @> '["Pack count per size matches the packing record"]'::jsonb);

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen53.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- The save's own rules: Milling (C4), Quality Control (C5), Packing (C6)
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
        select * into v_lab from public.labs l where l.id::text = p->>'lab_id' and l.active and l.state_id = p_scope.state_id;
        if v_lab.id is null then raise exception 'qc: the lab is not one of this state''s labs' using errcode = '23514'; end if;
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
-- A verdict per market profile, judged when the QC record is saved
CREATE OR REPLACE FUNCTION app.derive_qc_verdict(f footprints)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare qp jsonb; prm jsonb; jt jsonb; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select coalesce(s.quality_params, c.quality_params) into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = f.scope_id;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    jt := app.judge_typed(prm, f.payload->'readings');                     -- migration 42: a number, a grade or yes/no
    dv := (jt->>'domestic')::public.verdict; ev := (jt->>'export')::public.verdict;
    judged := judged || jt;
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  insert into public.qc_verdicts (footprint_id, domestic_verdict, export_verdict, readings, judged)
  values (f.id, dom, exp, coalesce(f.payload->'readings', '{}'::jsonb), judged);
  perform app.judge_profiles(f.id);                                             -- migration 53 (C5)
end $function$;
-- A closed lot has nothing left (the rest is floor loss)
CREATE OR REPLACE FUNCTION app.available_qty(p_fp uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  select case when exists (select 1 from public.lot_closures lc where lc.footprint_id = f.id) then 0::numeric   -- migration 53
              else f.qty_out - coalesce((
    select sum(c.qty_in) from public.footprints c
    where c.prev_footprint_id = f.id and c.status not in ('superseded','legacy')
  ), 0) end
  from public.footprints f where f.id = p_fp
$function$;
-- Packs: their place on the pack list, and best-before by their packing material
CREATE OR REPLACE FUNCTION app.make_packs(p_fp uuid, p_reason text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; pk jsonb; i int; n int := 0; v_on date; v_bb date; v_shelf int; b public.pack_batches; v_total int;
        v_sku public.pack_skus; v_mshelf int; v_bymat jsonb;                                              -- migration 53
begin
  select * into f from public.footprints where id = p_fp;
  update public.packs set status = 'void', void_reason = coalesce(p_reason, 'record corrected'), voided_by = app.current_user_id(), voided_at = now()
   where footprint_id = f.id and status = 'packed';
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
    for i in 1 .. coalesce((pk->>'units')::int, 0) loop
      update public.pack_batches set last_serial = last_serial + 1 where batch_code = b.batch_code returning * into b;
      insert into public.packs (serial, batch_code, footprint_id, scope_id, size_kg, packed_on, best_before, sku_id)
      values (b.batch_code || '-' || lpad(b.last_serial::text, greatest(4, length(b.last_serial::text)), '0'), b.batch_code, f.id, f.scope_id,
              (pk->>'size_kg')::numeric, v_on, v_bb, v_sku.id);
      n := n + 1;
    end loop;
  end loop;
  return n;
end $function$;
-- Verification of a packing record waits for the net weight check where it is required
CREATE OR REPLACE FUNCTION app.footprints_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- migration 50 (C5): the lab report file before verification, where the scope asks for the report
      if old.stage_type = 'qc' and (select s.qc_report_required from public.scopes s where s.id = old.scope_id)
         and not exists (select 1 from public.attachments a where a.footprint_id = old.id and (a.kind = 'document' or a.label = 'lab_report')) then
        raise exception 'qc: the lab report file is attached before the lab record is verified' using errcode = '23514'; end if;
      -- migration 53 (C6): export packs and packs of 5 kg or less: the packs the system picked are weighed and within the
      -- allowed error, where the scope asks the details
      if old.stage_type = 'packing' and (select s.stage_details_required from public.scopes s where s.id = old.scope_id) and app.needs_weight_check(old)
         and not exists (select 1 from public.net_weight_checks n where n.footprint_id = old.id and n.result = 'pass'
                           and not exists (select 1 from unnest(n.serials) sr where not exists
                                             (select 1 from public.packs pp where pp.serial = sr and pp.status = 'packed'))) then
        raise exception 'packing: weigh the packs the system picked (net weight check) before this record is verified' using errcode = '23514'; end if;
      -- migration 48 (A1): returned to its sender, it waits for the correction
      if exists (select 1 from public.footprint_returns r where r.footprint_id = old.id and r.status = 'open') then
        raise exception 'this record was returned to its sender: it is verified after the correction' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        -- migration 46 (Veda, 14 Oct): one person may hold two stages in a row and then verifies his own record; the
        -- ledger marks it "same person, next stage", the public page says so, the overview counts it
        -- migration 48 (A10/G14): a manager who does not hold the receiving stage verifies only with a written reason
        if auth.uid() is not null and app.manages_scope(new.verified_by, new.scope_id)
           and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           and length(btrim(coalesce(current_setting('app.act_reason', true), ''))) < 10 then
          raise exception 'a manager verifies at a stage he does not hold only with a written reason (at least 10 characters)' using errcode = '23514'; end if;
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end$function$;
-- An export release on the client's acceptance names who accepted, their title and the date (C5)
CREATE OR REPLACE FUNCTION app.qc_verdicts_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_scope uuid;
begin
  if new.domestic_verdict <> old.domestic_verdict or new.export_verdict <> old.export_verdict
     or new.readings <> old.readings or new.judged <> old.judged then
    raise exception 'derived verdicts and readings are immutable; only override may be set' using errcode = '42501';
  end if;
  if new.override is distinct from old.override then
    if old.override is not null then raise exception 'an override cannot be changed or removed' using errcode = '42501'; end if;
    if coalesce(new.override->>'reason', '') = '' or coalesce(new.override->>'authoriser', '') = ''
       or coalesce(new.override->>'market', '') not in ('domestic','export') then
      raise exception 'override needs market, reason and authoriser' using errcode = '23514'; end if;
    select scope_id into v_scope from public.footprints where id = new.footprint_id;
    if not app.manages_scope((new.override->>'authoriser')::uuid, v_scope) then
      raise exception 'override authoriser must be client_manager or above' using errcode = '42501'; end if;
    -- migration 50: the client's written acceptance, attached to the lab record first
    if new.override->>'market' = 'export' and auth.uid() is not null
       and not exists (select 1 from public.attachments a where a.footprint_id = new.footprint_id and a.label = 'acceptance') then
      raise exception 'an export release needs the client''s written acceptance attached to the lab record first' using errcode = '23514'; end if;
    -- migration 53 (C5): who at the client accepted it, their title, the date of the acceptance (where the scope asks the details)
    if new.override->>'market' = 'export' and auth.uid() is not null
       and (select s.stage_details_required from public.scopes s join public.footprints f on f.scope_id = s.id where f.id = new.footprint_id) then
      if length(btrim(coalesce(new.override->>'client_person', ''))) < 2 or length(btrim(coalesce(new.override->>'client_title', ''))) < 2
         or coalesce(new.override->>'accepted_on', '') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'an export release names the client''s authorising person, their title and the date of the acceptance' using errcode = '23514'; end if;
      if (new.override->>'accepted_on')::date > (now() at time zone 'Asia/Kolkata')::date then
        raise exception 'the date of the client''s acceptance is not after today' using errcode = '23514'; end if;
    end if;
    new.override := new.override || jsonb_build_object('at', now());
    perform app.ledger_append(new.footprint_id, (select scope_id from public.footprints where id = new.footprint_id),
      'override', coalesce(app.current_user_id(), (new.override->>'authoriser')::uuid),
      jsonb_build_object('footprint_id', new.footprint_id, 'override', new.override,
                         'domestic_verdict', new.domestic_verdict, 'export_verdict', new.export_verdict));
  end if;
  return new;
end$function$;
-- The form receives the scope's new settings and what QC tests (the crop's tests and the market profiles')
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
    'scope', jsonb_build_object('id', sc.id, 'season_code', sc.season_code, 'geography', sc.geography, 'status', sc.status, 'short_code', sc.short_code, 'qc_report_required', sc.qc_report_required,
               'record_price', sc.record_price, 'procurement_details_required', sc.procurement_details_required,   -- migration 52
               'stage_details_required', sc.stage_details_required, 'market_codes', to_jsonb(sc.market_codes),   -- migration 53
               'chain', to_jsonb(sc.chain), 'tolerances', sc.tolerances,
               'client', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.clients where id = sc.client_id),
               'crop', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'gi_tag', gi_tag, 'primary_unit', primary_unit, 'thresholds', thresholds)
                          from public.crops where id = sc.crop_id)),
    'stage', (select to_jsonb(d) from public.stage_definitions d where d.stage_type = p_stage),
    'position', idx,
    'prev_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label, 'handoff_checks', d.handoff_checks, 'physical_checks', d.physical_checks)
                     from public.stage_definitions d where d.stage_type = prev_t),
    'next_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label)
                     from public.stage_definitions d where d.stage_type = next_t),
    'quality_params', app.scope_test_params(sc.id),                              -- migration 53 (C5)
    'can_create', app.is_my_stage(me, p_scope, p_stage),
    'can_verify_incoming', prev_t is not null and (app.i_manage_scope(p_scope) or app.has_slot(me, p_scope, p_stage)),
    -- migration 48 (A10): a manager at a stage he does not hold gives a reason
    'records_as_manager', app.is_my_stage(me, p_scope, p_stage) and app.manages_scope(me, p_scope) and not app.has_slot(me, p_scope, p_stage),
    'verifies_as_manager', prev_t is not null and app.i_manage_scope(p_scope) and not app.has_slot(me, p_scope, p_stage)
  );
end$function$;
-- The record page: the verdict per market, a closed lot, the net weight check
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
-- The public page: the lab's verdict per market of the lot (its names and verdicts only)
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
-- API surface (migration 14 rule): every new function closed, the API ones opened by name
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.milling_range_mill(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function app.close_lot(uuid, text) from public, anon, authenticated;
revoke execute on function app.draw_sample(uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.dispose_sample(uuid, text) from public, anon, authenticated;
revoke execute on function app.lot_samples(uuid) from public, anon, authenticated;
revoke execute on function app.footprints_sample() from public, anon, authenticated;
revoke execute on function app.reading_for(text, jsonb) from public, anon, authenticated;
revoke execute on function app.judge_profile(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function app.judge_profiles(uuid) from public, anon, authenticated;
revoke execute on function app.scope_test_params(uuid) from public, anon, authenticated;
revoke execute on function app.short_allowed_g(numeric) from public, anon, authenticated;
revoke execute on function app.weighs_packs(uuid, public.footprints) from public, anon, authenticated;
revoke execute on function app.pick_net_weight(uuid) from public, anon, authenticated;
revoke execute on function app.record_net_weights(uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.needs_weight_check(public.footprints) from public, anon, authenticated;
grant execute on function app.close_lot(uuid, text) to authenticated;
grant execute on function app.draw_sample(uuid, jsonb) to authenticated;
grant execute on function app.dispose_sample(uuid, text) to authenticated;
grant execute on function app.lot_samples(uuid) to authenticated;
grant execute on function app.pick_net_weight(uuid) to authenticated;
grant execute on function app.record_net_weights(uuid, jsonb) to authenticated;
