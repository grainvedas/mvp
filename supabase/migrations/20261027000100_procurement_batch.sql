-- GrainVeda MVP · migration 52 (Veda, 15 Oct 2026, "ok complete everything", decision G19): release 5 of the
-- operator-stages plan. C1 Procurement (where, GPS, delivered by, price and payment kept apart, a farmer card, a
-- receipt, moisture warnings), C2 Collection Batch (one collection point, villages and farmers from the lots, single
-- origin, re-weighed total, weighted moisture), A13 the journey both ways (where a lot went), and three faults found
-- on staging the evening of 15 Oct (the parameter library's duplicate, see below). Additive: nothing is deleted or
-- rewritten; records already there keep their payloads.
select set_config('app.change_path', 'migration 52', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- The scope's settings (the Client Manager's)
-- ---------------------------------------------------------------------------------------------------------------------
-- "Record price & payment" (C1): off unless the Client Manager turns it on. Price and payment are then asked at
-- Procurement, kept in lot_payments (never in the record, its ledger block or any public or buyer view).
alter table public.scopes add column if not exists record_price boolean not null default false;
-- Where, GPS and who delivered the lot are asked at Procurement (C1). A scope made from now on asks them; the demo
-- scopes are set not to (seed 10), except the Bansi batch scope, which tests the path.
alter table public.scopes add column if not exists procurement_details_required boolean not null default true;

-- ---------------------------------------------------------------------------------------------------------------------
-- C1 · Price and payment, apart from the record
-- ---------------------------------------------------------------------------------------------------------------------
-- The Procurement form sends price_per_quintal, payment_status, payment_mode and txn_ref with the record (so a save
-- kept on the phone carries them too); the first trigger on the record takes them out of the payload before anything
-- else reads it (the ledger block, the next stage, the public page never see them) and they are kept here, read by the
-- client's account and the person who recorded the lot (and the admin). A payment reference is a transaction ID:
-- never an account number (the field says so; Veda, brief constraint).
create table if not exists public.lot_payments (
  footprint_id      uuid primary key references public.footprints(id),
  client_id         uuid not null references public.clients(id),
  scope_id          uuid not null references public.scopes(id),
  price_per_quintal numeric(12,2) check (price_per_quintal is null or price_per_quintal > 0),
  amount            numeric(14,2) check (amount is null or amount >= 0),
  status            text not null default 'pending' check (status in ('pending', 'paid')),
  mode              text check (mode is null or mode in ('bank', 'upi', 'cash')),
  txn_ref           text check (txn_ref is null or txn_ref ~ '^[A-Za-z0-9/-]{4,40}$'),
  recorded_by       uuid references public.app_users(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (status = 'pending' or mode is not null),
  check (status = 'pending' or mode = 'cash' or txn_ref is not null)
);
alter table public.lot_payments enable row level security;
revoke all on public.lot_payments from anon, authenticated;
grant select on public.lot_payments to authenticated;
create or replace function app.reads_lot_payment(p_client uuid, p_by uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and (app.is_admin() or p_by = app.current_user_id()
         or app.client_account_holder(app.current_user_id(), p_client)) $$;
drop policy if exists lot_payments_read on public.lot_payments;
create policy lot_payments_read on public.lot_payments for select to authenticated using (app.reads_lot_payment(client_id, recorded_by));
drop trigger if exists zz_change_log on public.lot_payments;
create trigger zz_change_log after insert or update or delete on public.lot_payments for each row execute function app.log_change('lot_payment');

create or replace function app.payment_problem(p jsonb) returns text language sql immutable as $$
  select case
    when p ? 'price_per_quintal' and app.opt_num(p, 'price_per_quintal', null) is null then 'the price per quintal is a number'
    when app.opt_num(p, 'price_per_quintal', 1) <= 0 then 'the price per quintal is more than 0'
    when coalesce(p->>'payment_status', 'pending') not in ('pending', 'paid') then 'the payment is paid or pending'
    when p->>'payment_mode' is not null and p->>'payment_mode' not in ('bank', 'upi', 'cash') then 'the payment is by bank, UPI or cash'
    when p->>'payment_status' = 'paid' and p->>'payment_mode' is null then 'say how it was paid (bank, UPI or cash)'
    when p->>'payment_status' = 'paid' and p->>'payment_mode' <> 'cash' and nullif(btrim(p->>'txn_ref'), '') is null then 'give the transaction ID of the payment'
    when nullif(btrim(p->>'txn_ref'), '') is not null and btrim(p->>'txn_ref') !~ '^[A-Za-z0-9/-]{4,40}$' then 'a transaction ID is 4 to 40 letters or digits (never an account number)'
  end $$;

-- BEFORE INSERT / UPDATE, first of all (a00): the payment keys leave the payload; a transaction-local note carries them
-- to the AFTER trigger, which keeps them once the record exists.
create or replace function app.footprints_take_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare pay jsonb; k text; v_problem text; sc public.scopes;
begin
  pay := '{}'::jsonb;
  foreach k in array array['price_per_quintal', 'payment_status', 'payment_mode', 'txn_ref'] loop
    if new.payload ? k then
      if nullif(btrim(new.payload->>k), '') is not null then pay := pay || jsonb_build_object(k, new.payload->k); end if;
      new.payload := new.payload - k;
    end if;
  end loop;
  if pay = '{}'::jsonb then return new; end if;
  if new.stage_type <> 'procurement' then raise exception 'price and payment are recorded at Procurement' using errcode = '23514'; end if;
  select * into sc from public.scopes where id = new.scope_id;
  if not coalesce(sc.record_price, false) then
    raise exception 'this scope does not record price and payment (its Client Manager turns it on)' using errcode = '23514'; end if;
  v_problem := app.payment_problem(pay);
  if v_problem is not null then raise exception 'payment: %', v_problem using errcode = '23514'; end if;
  perform set_config('app.pending_payment', (pay || jsonb_build_object('fp', new.id))::text, true);
  return new;
end $$;
drop trigger if exists footprints_a00_payment on public.footprints;
create trigger footprints_a00_payment before insert or update on public.footprints for each row execute function app.footprints_take_payment();

create or replace function app.footprints_keep_payment() returns trigger
language plpgsql security definer set search_path = public as $$
declare pay jsonb; v_price numeric;
begin
  pay := nullif(current_setting('app.pending_payment', true), '')::jsonb;
  if pay is null or (pay->>'fp')::uuid is distinct from new.id then return null; end if;
  perform set_config('app.pending_payment', '', true);
  v_price := app.opt_num(pay, 'price_per_quintal', null);
  insert into public.lot_payments (footprint_id, client_id, scope_id, price_per_quintal, amount, status, mode, txn_ref, recorded_by)
  values (new.id, new.client_id, new.scope_id, v_price, case when v_price is null then null else round(v_price * new.qty_out / 100, 2) end,
          coalesce(pay->>'payment_status', 'pending'), pay->>'payment_mode', nullif(btrim(pay->>'txn_ref'), ''), app.current_user_id())
  on conflict (footprint_id) do update set price_per_quintal = excluded.price_per_quintal, amount = excluded.amount, status = excluded.status,
     mode = excluded.mode, txn_ref = excluded.txn_ref, updated_at = now();
  return null;
end $$;
drop trigger if exists footprints_z6_payment on public.footprints;
create trigger footprints_z6_payment after insert or update on public.footprints for each row execute function app.footprints_keep_payment();

-- Later (paid after the lot was weighed): the person who recorded it, or the client's Client Manager.
create or replace function app.save_lot_payment(p_fp uuid, p jsonb) returns public.lot_payments
language plpgsql security definer set search_path = public as $$
declare f public.footprints; sc public.scopes; me uuid := app.current_user_id(); r public.lot_payments; v_problem text; v_price numeric;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.stage_type <> 'procurement' then raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  if not (f.created_by = me or app.client_account_holder(me, f.client_id)) then
    raise exception 'the person who recorded the lot or the client''s Client Manager records its payment' using errcode = '42501'; end if;
  if not sc.record_price then raise exception 'this scope does not record price and payment (its Client Manager turns it on)' using errcode = '23514'; end if;
  v_problem := app.payment_problem(p);
  if v_problem is not null then raise exception 'payment: %', v_problem using errcode = '23514'; end if;
  v_price := app.opt_num(p, 'price_per_quintal', null);
  insert into public.lot_payments (footprint_id, client_id, scope_id, price_per_quintal, amount, status, mode, txn_ref, recorded_by)
  values (f.id, f.client_id, f.scope_id, v_price, case when v_price is null then null else round(v_price * f.qty_out / 100, 2) end,
          coalesce(p->>'payment_status', 'pending'), p->>'payment_mode', nullif(btrim(p->>'txn_ref'), ''), me)
  on conflict (footprint_id) do update set
     price_per_quintal = coalesce(excluded.price_per_quintal, lot_payments.price_per_quintal),
     amount = coalesce(excluded.amount, lot_payments.amount), status = excluded.status, mode = excluded.mode,
     txn_ref = excluded.txn_ref, updated_at = now()
  returning * into r;
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C1 · The farmer card at Procurement
-- ---------------------------------------------------------------------------------------------------------------------
-- GI land; what he sold this season (this crop, every scope of the season) against what his GI land should give;
-- whether his good farming practice is complete; his GI-area status for the scope's crop.
create or replace function app.farmer_card(p_farmer uuid, p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fm public.farmers; sc public.scopes; cr public.crops; v_sold numeric; v_answers jsonb; v_missing jsonb;
begin
  select * into fm from public.farmers where id = p_farmer;
  select * into sc from public.scopes where id = p_scope;
  if fm.id is null or sc.id is null or not app.can_access_scope(p_scope) or not app.farmer_read(fm.client_id, fm.state_id) then
    raise exception 'farmer not found' using errcode = 'P0002'; end if;
  select * into cr from public.crops where id = sc.crop_id;
  select coalesce(sum(f.qty_out), 0) into v_sold
    from public.footprints f join public.scopes s on s.id = f.scope_id
   where f.farmer_id = fm.id and f.stage_type = 'procurement' and s.season_code = sc.season_code and s.crop_id = sc.crop_id
     and f.status not in ('superseded', 'legacy');
  select g.answers into v_answers from public.farmer_gap g where g.farmer_id = fm.id and g.crop_id = cr.id;
  v_missing := app.gap_missing(coalesce(cr.gap_items, '[]'::jsonb), coalesce(v_answers, '{}'::jsonb));
  return jsonb_build_object(
    'farmer_id', fm.id, 'name', fm.name, 'code', fm.farmer_code, 'village', fm.village, 'district', fm.district,
    'gi_land_acres', fm.gi_land_acres, 'sold_kg', v_sold,
    'expected_kg', case when fm.gi_land_acres is null or cr.yield_per_acre_kg is null then null else round(fm.gi_land_acres * cr.yield_per_acre_kg, 1) end,
    'gap', v_missing, 'gi_area', case when not cr.gi_crop then 'non_gi_crop'
                                      when cardinality(cr.gi_districts) = 0 then 'unknown'
                                      when app.norm_place(fm.district) in (select app.norm_place(x) from unnest(cr.gi_districts) x) then 'inside'
                                      else 'outside' end,
    'has_gps', fm.farm_lat is not null);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- A13 · The journey both ways: where a lot went
-- ---------------------------------------------------------------------------------------------------------------------
-- Every record built on this one, through every batch, run, sale and seal (footprint_links, written by the saves),
-- with the kilograms taken, the packs, the buyer or destination and the released codes. Read by whoever reads the
-- whole scope (as lot_trace). Farmers' names are not part of it.
create or replace function app.lot_forward(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope uuid; out jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501'; end if;
  with recursive down(id, parent, kg, depth) as (
      select p_fp, null::uuid, null::numeric, 0
    union
      select l.child_id, l.parent_id, l.kg, d.depth + 1
        from down d join public.footprint_links l on l.parent_id = d.id
       where d.depth < 64)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'status', f.status, 'depth', d.depth,
           'from_id', d.parent, 'kg_taken', d.kg, 'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out,
           'on', coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date),
           'buyer', case when f.stage_type in ('commercial', 'shipment') then coalesce(f.payload->>'buyer', f.payload->>'buyer_name', f.payload->>'consignee') end,
           'destination', case when f.stage_type = 'shipment' then f.payload->>'destination' end,
           'packs', case when f.stage_type = 'packing' then (select jsonb_build_object('n', count(*) filter (where pk.status = 'packed'),
                                                                                        'batch', min(pk.batch_code))
                                                                from public.packs pk where pk.footprint_id = f.id) end,
           'seal', (select jsonb_build_object('qr_code', s.qr_code, 'sealed_at', s.sealed_at,
                                              'release', (app.release_status(s.footprint_id))->>'status')
                      from public.qr_seals s where s.footprint_id = f.id))
         order by d.depth, f.created_at), '[]'::jsonb)
    into out
    from (select id, min(depth) as depth, (array_agg(parent order by depth))[1] as parent, (array_agg(kg order by depth))[1] as kg
            from down where depth > 0 group by id) d
    join public.footprints f on f.id = d.id;
  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', out);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Found on staging, 15 Oct: the parameter library showed "Moisture (%)" twice. A crop's own test that has the name of a
-- library test (Kalanamak's `moisture` beside the library's `moisture_pct`) is now marked as the same test: the lists
-- show the library's one; a limit already written with the crop's key keeps working.
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.quality_param_library add column if not exists alias_of text references public.quality_param_library(param);
create or replace function app.mark_library_aliases() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.quality_param_library a set alias_of = (
           select b.param from public.quality_param_library b
            where lower(btrim(b.name)) = lower(btrim(a.name)) and b.param <> a.param and b.alias_of is null
            order by b.sort_order, b.param limit 1)
   where a.alias_of is null
     and exists (select 1 from public.quality_param_library b where lower(btrim(b.name)) = lower(btrim(a.name)) and b.param <> a.param
                   and (b.sort_order, b.param) < (a.sort_order, a.param));
  get diagnostics n = row_count;
  return n;
end $$;
select app.mark_library_aliases();

-- ---------------------------------------------------------------------------------------------------------------------
-- What the forms ask (the same edits are in seed 01, for a database built from nothing)
-- ---------------------------------------------------------------------------------------------------------------------
update public.stage_definitions set form_schema = (
    select coalesce(jsonb_agg(x order by n), '[]'::jsonb) from jsonb_array_elements(form_schema) with ordinality as e(x, n)
     where x->>'key' not in ('collection_point_id', 'gps', 'delivered_by', 'agent_name', 'harvest_date', 'condition', 'slip',
                             'price_per_quintal', 'payment_status', 'payment_mode', 'txn_ref'))
  || '[
  {"key": "collection_point_id", "type": "collection_point", "label": "Where (collection point, or at the farm)", "section": "where", "required": false, "required_when": "procurement_details_required"},
  {"key": "gps", "type": "gps", "label": "GPS where the lot was weighed", "section": "where", "required": false, "required_when": "procurement_details_required"},
  {"key": "delivered_by", "type": "select", "label": "Delivered by", "options": ["farmer", "family", "agent"], "section": "where", "required": false, "required_when": "procurement_details_required"},
  {"key": "agent_name", "type": "text", "label": "Agent''s name (when an agent delivered)", "section": "where", "required": false},
  {"key": "harvest_date", "type": "date", "label": "Harvest date", "section": "optional", "required": false},
  {"key": "condition", "type": "select", "label": "Condition", "options": ["good", "damp", "pest", "mixed"], "section": "optional", "required": false},
  {"key": "slip", "type": "attachment", "label": "Weighbridge or scale slip (photo)", "section": "optional", "required": false, "label_as": "document"},
  {"key": "price_per_quintal", "type": "number", "unit": "₹/quintal", "label": "Price per quintal", "section": "payment", "required": false, "shown_when": "record_price", "required_when": "record_price"},
  {"key": "payment_status", "type": "select", "label": "Payment", "options": ["pending", "paid"], "section": "payment", "required": false, "shown_when": "record_price", "required_when": "record_price"},
  {"key": "payment_mode", "type": "select", "label": "Paid by", "options": ["bank", "upi", "cash"], "section": "payment", "required": false, "shown_when": "record_price"},
  {"key": "txn_ref", "type": "text", "label": "Transaction ID (never an account number)", "section": "payment", "required": false, "shown_when": "record_price"}
]'::jsonb
 where stage_type = 'procurement';
update public.stage_definitions set label = 'Collection Batch (one collection point)', form_schema = (
    select coalesce(jsonb_agg(x order by n), '[]'::jsonb) from jsonb_array_elements(form_schema) with ordinality as e(x, n)
     where x->>'key' not in ('village', 'single_origin', 'bags', 'reweighed_kg', 'moisture_fresh_pct'))
  || '[
  {"key": "single_origin", "type": "boolean", "label": "Single-origin batch (lots from one village only)", "section": "batch", "required": false},
  {"key": "bags", "type": "integer", "label": "Bags in the batch", "section": "batch", "required": false},
  {"key": "reweighed_kg", "type": "number", "unit": "kg", "label": "Re-weighed total (optional)", "section": "weighing", "required": false},
  {"key": "moisture_fresh_pct", "type": "number", "unit": "%", "label": "Fresh moisture reading (optional)", "section": "weighing", "required": false}
]'::jsonb
 where stage_type = 'village_batch';

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen52.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- The save's own rules: Procurement (C1) and Collection Batch (C2)
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
      -- migration 50 (G1): the save gives the batch code (trigger footprints_a1_batch_code); the preview has none yet
      if coalesce(p->>'batch_code', '') = '' and f.id is not null then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
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
      -- migration 50 (C5): the scope asks for the lab report (the default): the lab, its number and date; the file comes
      -- before verification. The date: not ahead of today, not before the lot existed. A number once per lab, unless
      -- the lots share the sample.
      if p_scope.qc_report_required then
        if coalesce(btrim(p->>'lab_name'), '') = '' or coalesce(btrim(p->>'report_no'), '') = '' or coalesce(p->>'report_date', '') = '' then
          raise exception 'qc: the lab, the report number and the report date are required' using errcode = '23514'; end if;
        begin v_rdate := (p->>'report_date')::date; exception when others then
          raise exception 'qc: the report date is a date' using errcode = '23514'; end;
        if v_rdate > (now() at time zone 'Asia/Kolkata')::date then
          raise exception 'qc: the report date (%) is in the future', to_char(v_rdate, 'DD Mon YYYY') using errcode = '23514'; end if;
        v_on := coalesce(prev.happened_on, (coalesce(prev.captured_at, prev.created_at) at time zone 'Asia/Kolkata')::date);
        if prev.id is not null and v_rdate < v_on then
          raise exception 'qc: the report date (%) is before the lot it tests (% on %)', to_char(v_rdate, 'DD Mon YYYY'), prev.footprint_code, to_char(v_on, 'DD Mon YYYY')
            using errcode = '23514'; end if;
        v_taken := app.report_no_taken(p->>'lab_name', p->>'report_no', p->>'sample_id', f.id);
        if v_taken is not null then
          raise exception 'qc: report % of this lab is on % already (the same report twice needs the same sample ID)', btrim(p->>'report_no'), v_taken
            using errcode = '23505'; end if;
        c := c || jsonb_build_object('lab_name', btrim(p->>'lab_name'), 'report_no', btrim(p->>'report_no'), 'report_date', v_rdate);
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
-- The form receives the scope's two new settings and the crop's thresholds
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
    'quality_params', coalesce(sc.quality_params, (select quality_params from public.crops where id = sc.crop_id)),
    'can_create', app.is_my_stage(me, p_scope, p_stage),
    'can_verify_incoming', prev_t is not null and (app.i_manage_scope(p_scope) or app.has_slot(me, p_scope, p_stage)),
    -- migration 48 (A10): a manager at a stage he does not hold gives a reason
    'records_as_manager', app.is_my_stage(me, p_scope, p_stage) and app.manages_scope(me, p_scope) and not app.has_slot(me, p_scope, p_stage),
    'verifies_as_manager', prev_t is not null and app.i_manage_scope(p_scope) and not app.has_slot(me, p_scope, p_stage)
  );
end$function$;
-- The public page: a Collection Batch names its villages from the lots (none is typed any more)
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
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', coalesce(cur.payload->>'village',      -- migration 52: from the lots
             (select string_agg(v->>'village', ', ' order by (v->>'kg')::numeric desc) from jsonb_array_elements(coalesce(cur.computed->'villages', '[]'::jsonb)) v)),
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
revoke execute on function app.payment_problem(jsonb) from public, anon, authenticated;
revoke execute on function app.footprints_take_payment() from public, anon, authenticated;
revoke execute on function app.footprints_keep_payment() from public, anon, authenticated;
revoke execute on function app.save_lot_payment(uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.farmer_card(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.lot_forward(uuid) from public, anon, authenticated;
revoke execute on function app.mark_library_aliases() from public, anon, authenticated;
grant execute on function app.save_lot_payment(uuid, jsonb) to authenticated;
grant execute on function app.farmer_card(uuid, uuid) to authenticated;
grant execute on function app.lot_forward(uuid) to authenticated;
revoke execute on function app.reads_lot_payment(uuid, uuid) from public, anon, authenticated;
grant execute on function app.reads_lot_payment(uuid, uuid) to authenticated;   -- the read policy asks it
