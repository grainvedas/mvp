-- Migration 61 (Phase 1, release 3 of Veda's combined brief of 19 Oct 2026: release 2's corrections and the shown parts of
-- the season corrections E2.2 to E2.5; Veda, 19 Oct: "do what is left as per best", the plan's defaults accepted).
-- Release 2 (migration 60) fell short of Part C in some points, and its floor loss counted the milling by-products:
--   C1.1/C1.2  One column per field (gross, bags, moisture readings, head rice, broken, husk, bran, invoice, LR, vehicle,
--              container ...), names instead of ids (mill, pack type, collection point, packing unit and its FSSAI
--              licence, the sample's code), the raw saved values only in the internal copy's last column, "raw_values".
--              A column empty in every row is left out.
--   C1.3       Prices and payment references only in the internal copy, and only where the scope's "Record price" is
--              ticked (the raw values lose their price keys otherwise).
--   C1.4       Packs counted by size ("150 × 1 kg pouch").
--   C3         The shareable copy follows the brief's words: no prices, no farmer's name or phone, no internal ids (staff
--              and buyers are named); the internal copy adds the farmer's name, the agent, the driver's phone, prices.
--   C2         The season's Summary per stage: in, out, by-products, floor loss, closed as floor loss, kg left; its
--              heading says who made it.
--   E2.2       Floor loss = input − (head rice + broken + husk + bran) at milling (the by-products have their own
--              columns, in kg and as a % of the input); likewise rejects and foreign matter are not a loss
--              (app.record_parts). Applied in both exports and on the journey page and the dashboard.
--   E2.5/C1.5  A lot closed as floor loss (the 2 %-or-less rule) is its own line: "Closed as floor loss: 4 kg, date,
--              by". app.stage_balance: per stage, what came in = what went on + by-products + floor loss + closed + left;
--              any difference is shown (it blocks the scope's close from release 63).
--   E2.3       The public page: a collection batch shows one line for all its purchases ("Bought from 2 farmers:
--              250 kg", the villages' shares) instead of the one purchase its record points back to.
--   E2.4       The best-before date on the pack page before release too; Packing is refused while the crop has no shelf
--              life for the pack's material ("ask the State Manager to set the shelf life for this crop and pack
--              material"). Records already made keep theirs (none: "not recorded (old data)" on the page).
-- Additive: new functions; replaced functions (the exports, the journey page data, the pack page data, the lot's trace,
-- the save rules of Packing); no table, no record changed.

-- =====================================================================================================================
-- E2.2 · what a record's kilograms became: out, by-products, samples or water, floor loss, transit loss
-- =====================================================================================================================
-- in = out + by_products + other + floor_loss + transit_in (transit_up is lost before the record's input: a mill that
-- received less than was sent)
create or replace function app.record_parts(f public.footprints) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('in', x.i, 'out', x.o, 'by_products', x.b, 'other', x.oth, 'transit_in', x.ti, 'transit_up', x.tu,
           'floor_loss', round(x.i - x.o - x.b - x.oth - x.ti, 3))
    from (select case when f.stage_type in ('procurement', 'lot_inward') or f.is_grade_lot then f.qty_out else f.qty_in end as i,
                 f.qty_out as o,
                 case when f.stage_type = 'milling' then coalesce((f.computed->>'broken_kg')::numeric, 0) + coalesce((f.computed->>'husk_kg')::numeric, 0)
                                                          + coalesce((f.computed->>'bran_kg')::numeric, 0)
                      when f.stage_type in ('sorting', 'grading') and not f.is_grade_lot then coalesce((f.computed->>'reject_kg')::numeric, 0)
                      when f.stage_type = 'cleaning' then coalesce((f.computed->>'foreign_matter_kg')::numeric, 0)
                      else 0 end as b,
                 case f.stage_type when 'qc' then coalesce((f.computed->>'sample_qty_kg')::numeric, 0)
                      when 'drying' then coalesce((f.computed->>'water_removed_kg')::numeric, 0)
                      when 'blanching' then f.qty_in - f.qty_out
                      when 'popping' then f.qty_in - f.qty_out
                      else 0 end as oth,
                 case when f.stage_type = 'shipment' then coalesce((f.computed->>'transit_loss_kg')::numeric, 0) else 0 end as ti,
                 case when f.stage_type = 'milling' then coalesce((f.computed->>'transit_loss_kg')::numeric, 0) else 0 end as tu) x $$;

-- =====================================================================================================================
-- E2.5 · the mass balance of a scope, per stage of its chain
-- =====================================================================================================================
-- came in = went on to the next stage + by-products + samples or water + floor loss + transit loss + closed as floor
-- loss + left. A collection batch's lots went on whole; the chain's last stage sends its lots out of the chain.
create or replace function app.stage_balance_of(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with sc as (select s.*, s.chain[cardinality(s.chain)]::text as last_stage from public.scopes s where s.id = p_scope),
  live as (select f.*, app.record_parts(f) as m from public.footprints f
            where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')),
  batched as (select distinct (x)::uuid as id from live b, jsonb_array_elements_text(coalesce(b.payload->'source_footprint_ids', '[]'::jsonb)) x
               where b.stage_type = 'village_batch'),
  rec as (
    select l.*, coalesce(cl.floor_loss_kg, 0) as closed_kg,
           case when l.split_into_grades then 0
                when l.stage_type::text = (select last_stage from sc) or l.id in (select id from batched) then l.qty_out
                else coalesce((select sum(c.qty_in + (c.m->>'transit_up')::numeric) from live c
                                where c.prev_footprint_id = l.id and c.stage_type <> 'village_batch'), 0) end as handed,
           case when l.split_into_grades or cl.footprint_id is not null or l.id in (select id from batched)
                     or l.stage_type::text = (select last_stage from sc) then 0
                else greatest(app.available_qty(l.id) - coalesce((select sum((c.m->>'transit_up')::numeric) from live c
                                                                   where c.prev_footprint_id = l.id), 0), 0) end as left_kg
      from live l left join public.lot_closures cl on cl.footprint_id = l.id),
  agg as (
    select r.stage_type::text as stage, count(*) as n, count(*) filter (where r.status = 'pending') as pending,
           count(*) filter (where r.status in ('verified', 'closed')) as verified,
           coalesce(sum((r.m->>'in')::numeric + (r.m->>'transit_up')::numeric) filter (where not r.is_grade_lot), 0) as kg_in,
           coalesce(sum(r.qty_out) filter (where not r.is_grade_lot), 0) as kg_out,
           coalesce(sum((r.m->>'by_products')::numeric) filter (where not r.is_grade_lot), 0) as byp,
           coalesce(sum((r.m->>'other')::numeric) filter (where not r.is_grade_lot), 0) as oth,
           coalesce(sum((r.m->>'floor_loss')::numeric) filter (where not r.is_grade_lot and r.stage_type not in ('procurement', 'lot_inward')), 0) as floor,
           coalesce(sum((r.m->>'transit_in')::numeric + (r.m->>'transit_up')::numeric) filter (where not r.is_grade_lot), 0) as transit,
           coalesce(sum(r.closed_kg) filter (where r.stage_type::text <> (select last_stage from sc)), 0) as closed,
           coalesce(sum(r.handed), 0) as handed, coalesce(sum(r.left_kg), 0) as left_kg
      from rec r group by r.stage_type)
  select coalesce(jsonb_agg(jsonb_build_object('stage', ch.stage, 'pos', ch.pos,
           'records', coalesce(a.n, 0), 'pending', coalesce(a.pending, 0), 'verified', coalesce(a.verified, 0),
           'kg_in', round(coalesce(a.kg_in, 0), 3), 'kg_out', round(coalesce(a.kg_out, 0), 3),
           'by_products_kg', round(coalesce(a.byp, 0), 3), 'other_kg', round(coalesce(a.oth, 0), 3),
           'floor_loss_kg', round(coalesce(a.floor, 0), 3), 'transit_loss_kg', round(coalesce(a.transit, 0), 3),
           'closed_kg', round(coalesce(a.closed, 0), 3), 'handed_on_kg', round(coalesce(a.handed, 0), 3), 'left_kg', round(coalesce(a.left_kg, 0), 3),
           'last', ch.stage::text = (select last_stage from sc),
           'difference_kg', round(coalesce(a.kg_in - (a.handed + a.byp + a.oth + a.floor + a.transit + a.closed + a.left_kg), 0), 3),
           'balanced', abs(coalesce(a.kg_in - (a.handed + a.byp + a.oth + a.floor + a.transit + a.closed + a.left_kg), 0))
                         <= app.kg_tolerance() * greatest(coalesce(a.n, 0), 1))
           order by ch.pos), '[]'::jsonb)
    from sc, unnest(sc.chain) with ordinality ch(stage, pos)
    left join agg a on a.stage = ch.stage::text $$;

-- the same, for the dashboard: whoever may open the scope (kilograms only, no names)
create or replace function app.stage_balance(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.can_access_scope(p_scope) then
    raise exception 'not allowed to read this scope' using errcode = '42501'; end if;
  return app.stage_balance_of(p_scope);
end $$;

-- =====================================================================================================================
-- C1/C3 · one record, readable (the internal copy adds the farmer's name, the agent, the driver's phone, prices where
-- the scope records them, and the raw saved values)
-- =====================================================================================================================
create or replace function app.exp_txt(j jsonb, k text) returns text language sql immutable as $$ select nullif(btrim(j->>k), '') $$;

create or replace function app.export_record(p_fp uuid, p_internal boolean, p_share numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; fa public.farmers; q public.qc_verdicts; s public.qr_seals; v_lab jsonb; r jsonb; v_entry boolean;
        lp public.lot_payments; st public.sale_terms; c jsonb; p jsonb; m jsonb; v_price boolean; v_in numeric; pu public.packing_units;
        pk record; v_mill boolean; v_buyer text;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null then return null; end if;
  select * into fa from public.farmers where id = f.farmer_id;
  select * into q from public.qc_verdicts where footprint_id = f.id;
  select * into s from public.qr_seals where footprint_id = f.id;
  select * into st from public.sale_terms where footprint_id = f.id;
  select coalesce(sc.record_price, false) into v_price from public.scopes sc where sc.id = f.scope_id;
  v_lab := app.qc_lab(f.id);
  c := coalesce(app.live_computed(f), '{}'::jsonb); p := coalesce(f.payload, '{}'::jsonb); m := app.record_parts(f);
  v_entry := f.stage_type in ('procurement', 'lot_inward');
  v_mill := f.stage_type = 'milling';
  v_in := nullif(f.qty_in, 0);
  select * into pu from public.packing_units u where u.id::text = p->>'packing_unit_id';
  select coalesce(b.name, app.exp_txt(c, 'buyer'), app.exp_txt(p, 'buyer')) into v_buyer
    from (select 1) x left join public.buyers b on b.id::text = p->>'buyer_id';
  select count(*) filter (where k.status <> 'void') as n, min(k.serial) as first, max(k.serial) as last,
         min(k.best_before) filter (where k.status <> 'void') as bb,
         count(*) filter (where k.status <> 'void' and k.best_before is null) as no_bb,
         (select string_agg(x.n || ' × ' || x.label, ', ' order by x.size desc, x.label)
            from (select count(*) as n, coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg') as label,
                         max(k2.size_kg) as size
                    from public.packs k2 left join public.pack_skus sk on sk.id = k2.sku_id
                   where k2.footprint_id = f.id and k2.status <> 'void'
                   group by coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg')) x) as by_size
    into pk from public.packs k where k.footprint_id = f.id;
  -- when, who, how much
  r := jsonb_build_object(
    'code', f.footprint_code, 'stage', f.stage_type, 'status', f.status, 'happened_on', f.happened_on,
    'recorded_at', to_char(coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'verified_at', to_char(f.verified_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'recorded_by', (select u.display_name from public.app_users u where u.id = f.created_by),
    'verified_by', (select u.display_name from public.app_users u where u.id = f.verified_by),
    'same_person', case when f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by then 'yes' end,
    'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out);
  -- E2.2: the by-products in kg and as a % of the input, each its own column; the floor loss without them
  r := r || jsonb_build_object(
    'head_rice_kg', case when v_mill then c->'head_rice_kg' end,
    'head_rice_pct', case when v_mill and c ? 'head_rice_kg' then round((c->>'head_rice_kg')::numeric / v_in * 100, 1) end,
    'broken_kg', case when v_mill then c->'broken_kg' end,
    'broken_pct', case when v_mill and c ? 'broken_kg' then round((c->>'broken_kg')::numeric / v_in * 100, 1) end,
    'husk_kg', case when v_mill then c->'husk_kg' end,
    'husk_pct', case when v_mill and c ? 'husk_kg' then round((c->>'husk_kg')::numeric / v_in * 100, 1) end,
    'bran_kg', case when v_mill then c->'bran_kg' end,
    'bran_pct', case when v_mill and c ? 'bran_kg' then round((c->>'bran_kg')::numeric / v_in * 100, 1) end,
    'recovery_pct', case when v_mill then coalesce(c->'recovery_pct', c->'yield_pct') end,
    'reject_kg', case when f.stage_type in ('sorting', 'grading') then c->'reject_kg' end,
    'foreign_matter_kg', case when f.stage_type = 'cleaning' then c->'foreign_matter_kg' end,
    'sample_kg', case when f.stage_type = 'qc' then c->'sample_qty_kg' end,
    'water_removed_kg', case when f.stage_type = 'drying' then c->'water_removed_kg' end,
    'floor_loss_kg', case when not (v_entry or f.is_grade_lot) then (m->>'floor_loss')::numeric end,
    'floor_loss_pct', case when not (v_entry or f.is_grade_lot) then round((m->>'floor_loss')::numeric / v_in * 100, 2) end,
    'transit_loss_kg', case when c ? 'transit_loss_kg' then c->'transit_loss_kg' end);
  -- where it came from: the farm or the source, the share, GI, the bags and the moisture readings
  r := r || jsonb_build_object(
    'farmer_code', fa.farmer_code, 'village', fa.village, 'district', fa.district,
    'share_pct', case when p_share is not null then round(p_share * 100, 1) end,
    'gi_status', case when v_entry then app.entry_gi(f.id) end,
    'farm_verified', case f.stage_type when 'procurement' then 'yes' when 'lot_inward' then 'no' end,
    'source_type', case when f.stage_type = 'lot_inward' then app.exp_txt(p, 'source_type') end,
    'source_name', case when f.stage_type = 'lot_inward' then app.exp_txt(p, 'source_name') end,
    'gross_kg', case when f.stage_type = 'procurement' then p->'gross_kg' end,
    'bags', case when f.stage_type in ('procurement', 'village_batch', 'lot_inward') then p->'bags' end,
    'tare_kg_per_bag', case when f.stage_type = 'procurement' then p->'tare_kg_per_bag' end,
    'moisture_readings', case when jsonb_typeof(p->'moisture_pct') = 'array'
                              then (select string_agg(x, ' / ' order by o) from jsonb_array_elements_text(p->'moisture_pct') with ordinality t(x, o)) end,
    'moisture_avg', case when f.stage_type in ('procurement', 'village_batch') then c->'moisture_avg' end,
    'collection_point', case when f.stage_type in ('procurement', 'village_batch') then app.exp_txt(c, 'collection_point') end,
    'harvest_date', app.exp_txt(p, 'harvest_date'), 'condition', app.exp_txt(p, 'condition'),
    'delivered_by', case when f.stage_type = 'procurement' then app.exp_txt(p, 'delivered_by') end,
    'farmers', case when f.stage_type = 'village_batch' then c->'farmers' end,
    'villages', case when f.stage_type = 'village_batch' and jsonb_typeof(c->'villages') = 'array'
                     then (select string_agg((v->>'village') || ' ' || (v->>'share_pct') || ' %', '; ')
                             from jsonb_array_elements(c->'villages') v) end);
  -- milling, the lab, packing
  r := r || jsonb_build_object(
    'mill', case when v_mill then app.exp_txt(c, 'mill') end,
    'mill_operator', case when v_mill then app.exp_txt(p, 'mill_operator') end,
    'polish', case when v_mill then app.exp_txt(p, 'polish') end,
    'line_clearance', case when v_mill then app.exp_txt(c, 'line_clearance') end,
    'grade', f.grade, 'qc_domestic', q.domestic_verdict, 'qc_export', q.export_verdict, 'readings', coalesce(q.readings, '{}'::jsonb),
    'sample_code', case when f.stage_type = 'qc' then app.exp_txt(c, 'sample_code') end,
    'lab', v_lab->>'name', 'lab_accreditation', v_lab->>'accreditation_no', 'report_no', v_lab->>'report_no', 'report_date', v_lab->>'report_date',
    'packing_unit', pu.name, 'fssai_licence', pu.fssai_licence,
    'batch_code', coalesce((select string_agg(distinct k.batch_code, ' ') from public.packs k where k.footprint_id = f.id),
                           case when f.stage_type = 'packing' then p->>'batch_code' end),
    'packs', nullif(pk.n, 0), 'packs_by_size', pk.by_size,
    'serials', case when pk.first is not null then pk.first || ' to ' || pk.last end,
    'best_before', case when pk.n > 0 and pk.no_bb > 0 then 'not_recorded' when pk.bb is not null then pk.bb::text end);
  -- the order and the shipment
  r := r || jsonb_build_object(
    'market', case when f.stage_type in ('commercial', 'shipment') then coalesce(app.exp_txt(c, 'market'), app.exp_txt(p, 'market')) end,
    'buyer', case when f.stage_type in ('commercial', 'shipment') then v_buyer end,
    'destination_country', app.exp_txt(p, 'destination_country'), 'order_no', app.exp_txt(p, 'order_no'),
    'incoterms', coalesce(app.exp_txt(p, 'incoterms'), st.incoterms),
    'invoice_no', coalesce(app.exp_txt(p, 'invoice_no'), app.exp_txt(c, 'invoice_no')), 'dispatch_date', app.exp_txt(p, 'dispatch_date'),
    'destination', app.exp_txt(p, 'destination'), 'transporter', app.exp_txt(p, 'transporter'), 'vehicle_no', app.exp_txt(p, 'vehicle_no'),
    'lr_no', app.exp_txt(p, 'lr_no'), 'container_no', app.exp_txt(p, 'container_no'), 'seal_no', app.exp_txt(p, 'seal_no'),
    'vessel', app.exp_txt(p, 'vessel'), 'port_loading', app.exp_txt(p, 'port_loading'), 'port_discharge', app.exp_txt(p, 'port_discharge'),
    'eway_bill_no', app.exp_txt(p, 'eway_bill_no'), 'shipping_bill_no', app.exp_txt(p, 'shipping_bill_no'),
    'bl_no', coalesce(app.exp_txt(c, 'bl_no'), app.exp_txt(p, 'bl_no')));
  -- the seal and the record's integrity
  r := r || jsonb_build_object(
    'qr_code', s.qr_code, 'sealed_at', to_char(s.sealed_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'open_flags', (select nullif(count(*), 0) from public.flags fl where fl.footprint_id = f.id and fl.status = 'open'),
    'evidence_sha256', (select string_agg(a.sha256, ' ' order by a.created_at) from public.attachments a where a.footprint_id = f.id),
    'ledger_blocks', (select count(*) from public.ledger l where l.footprint_id = f.id),
    'last_block_hash', (select l.hash from public.ledger l where l.footprint_id = f.id order by l.seq desc limit 1),
    'warnings', nullif(array_to_string(f.warnings, ' | '), ''),
    'withdrawn', (select to_char(w.withdrawn_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || ': ' || w.reason
                    from public.withdrawals w where w.footprint_id = f.id),
    'replaces', (select o.footprint_code || ' (' || o.qty_out || ' kg)' || coalesce(': ' || w.reason, '')
                   from public.footprints o left join public.withdrawals w on w.footprint_id = o.id where o.id = f.supersedes_id),
    'lot_closed', case when f.lot_closed then 'yes' end,
    'received_at', to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    -- E2.5: closed as floor loss (the 2 %-or-less rule): its own line in the table
    'closure', (select jsonb_build_object('kg', lc.floor_loss_kg, 'at', to_char(lc.closed_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
                         'by', (select u.display_name from public.app_users u where u.id = lc.closed_by), 'reason', lc.reason)
                  from public.lot_closures lc where lc.footprint_id = f.id));
  if p_internal then
    select * into lp from public.lot_payments where footprint_id = f.id;
    r := r || jsonb_build_object(
      'farmer_name', fa.name,
      'agent_name', case when f.stage_type = 'procurement' then app.exp_txt(p, 'agent_name') end,
      'driver_phone', app.exp_txt(p, 'driver_phone'),
      -- C1.3: the raw values; without their prices where the scope does not record prices
      'raw_values', case when v_price then p else coalesce((select jsonb_object_agg(e.k, e.v) from jsonb_each(p) e(k, v)
                                                             where e.k !~ '^(price|payment|txn|total_value|currency|amount|rate)'), '{}'::jsonb) end);
    if v_price then
      r := r || jsonb_build_object(
        'price_per_quintal', coalesce(lp.price_per_quintal, (p->>'price_per_quintal')::numeric),
        'payment_status', coalesce(lp.status, app.exp_txt(p, 'payment_status')), 'payment_ref', coalesce(lp.txn_ref, app.exp_txt(p, 'txn_ref')),
        'price_per_kg', coalesce(st.price_per_kg, case when f.stage_type = 'commercial' then (p->>'price_per_kg')::numeric end),
        'currency', coalesce(st.currency, case when f.stage_type = 'commercial' then app.exp_txt(p, 'currency') end),
        'total_value', st.total_value);
    end if;
  end if;
  return r;
end $$;

-- the records as one table: the columns (a reading is 'r:<its key>'), a line per record in the order given and, after a
-- lot closed as floor loss, its closing line. A column empty in every line is left out (the core ones stay).
create or replace function app.export_table(p_ids uuid[], p_internal boolean, p_shares jsonb, p_note text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare recs jsonb[]; rkeys text[]; keys text[]; keep text[]; lines jsonb[] := '{}'; rows jsonb := '[]'::jsonb; r jsonb; i int := 0; one jsonb;
        core constant text[] := array['step', 'code', 'stage', 'status', 'recorded_at', 'qty_in_kg', 'qty_out_kg', 'floor_loss_kg'];
begin
  select coalesce(array_agg(app.export_record(u.id, p_internal, (p_shares->>u.id::text)::numeric) order by u.ord), '{}')
    into recs from unnest(coalesce(p_ids, '{}'::uuid[])) with ordinality u(id, ord);
  select coalesce(array_agg(distinct k order by k), '{}') into rkeys
    from unnest(recs) x, jsonb_object_keys(coalesce(x->'readings', '{}'::jsonb)) k;
  keys := array['step', 'code', 'stage', 'status', 'happened_on', 'recorded_at', 'verified_at', 'recorded_by', 'verified_by', 'same_person',
                'qty_in_kg', 'qty_out_kg', 'head_rice_kg', 'head_rice_pct', 'broken_kg', 'broken_pct', 'husk_kg', 'husk_pct', 'bran_kg', 'bran_pct',
                'recovery_pct', 'reject_kg', 'foreign_matter_kg', 'sample_kg', 'water_removed_kg', 'floor_loss_kg', 'floor_loss_pct', 'transit_loss_kg',
                'note', 'farmer_code', 'farmer_name', 'village', 'district', 'share_pct', 'gi_status', 'farm_verified', 'source_type', 'source_name',
                'gross_kg', 'bags', 'tare_kg_per_bag', 'moisture_readings', 'moisture_avg', 'collection_point', 'harvest_date', 'condition',
                'delivered_by', 'agent_name', 'farmers', 'villages', 'mill', 'mill_operator', 'polish', 'line_clearance',
                'grade', 'qc_domestic', 'qc_export']::text[]
       || array(select 'r:' || k from unnest(rkeys) k)
       || array['sample_code', 'lab', 'lab_accreditation', 'report_no', 'report_date', 'packing_unit', 'fssai_licence', 'batch_code', 'packs',
                'packs_by_size', 'serials', 'best_before', 'market', 'buyer', 'destination_country', 'order_no', 'incoterms', 'price_per_quintal',
                'payment_status', 'payment_ref', 'price_per_kg', 'currency', 'total_value', 'invoice_no', 'dispatch_date', 'destination',
                'transporter', 'vehicle_no', 'driver_phone', 'lr_no', 'container_no', 'seal_no', 'vessel', 'port_loading', 'port_discharge',
                'eway_bill_no', 'shipping_bill_no', 'bl_no', 'qr_code', 'sealed_at', 'open_flags', 'evidence_sha256', 'ledger_blocks',
                'last_block_hash', 'warnings', 'withdrawn', 'replaces', 'lot_closed', 'received_at', 'data_note', 'raw_values']::text[];
  if not p_internal then   -- never a column of the shareable copy, whatever a record holds
    keys := array(select k from unnest(keys) with ordinality t(k, o)
                   where k not in ('farmer_name', 'agent_name', 'driver_phone', 'price_per_quintal', 'payment_status', 'payment_ref',
                                   'price_per_kg', 'currency', 'total_value', 'raw_values') order by o);
  end if;
  foreach r in array recs loop
    i := i + 1;
    lines := array_append(lines, (r - 'readings' - 'closure')
               || coalesce((select jsonb_object_agg('r:' || e.k, e.v) from jsonb_each(coalesce(r->'readings', '{}'::jsonb)) e(k, v)), '{}'::jsonb)
               || jsonb_build_object('step', i, 'data_note', p_note));
    if jsonb_typeof(r->'closure') = 'object' then
      lines := array_append(lines, jsonb_build_object('code', r->'code', 'stage', 'floor_loss_closure', 'status', 'closed',
                 'recorded_at', r->'closure'->'at', 'recorded_by', r->'closure'->'by', 'floor_loss_kg', r->'closure'->'kg',
                 'note', r->'closure'->'reason', 'data_note', p_note));
    end if;
  end loop;
  keep := array(select k from unnest(keys) with ordinality t(k, o)
                 where k = any(core) or exists (select 1 from unnest(lines) l where nullif(l->>k, '') is not null) order by o);
  foreach r in array lines loop
    select jsonb_agg(r->k order by o) into one from unnest(keep) with ordinality t(k, o);
    rows := rows || jsonb_build_array(one);
  end loop;
  return jsonb_build_object('columns', to_jsonb(keep), 'rows', rows);
end $$;

-- the scope's heading: client, crop, season, place, state
create or replace function app.export_scope_head(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('client', c.name, 'client_code', c.code, 'crop', cr.name, 'gi_tag', cr.gi_tag, 'season', s.season_code,
           'geography', s.geography, 'state', st.name, 'status', s.status, 'data_note', s.data_note,
           'record_price', s.record_price)                                                          -- migration 61 (C1.3)
    from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
    left join public.states st on st.id = s.state_id
   where s.id = p_scope $$;

create or replace function app.export_made_by() returns text
language sql stable security definer set search_path = public as $$
  select u.display_name from public.app_users u where u.id = app.current_user_id() $$;

-- =====================================================================================================================
-- C1 · the journey of one lot (every origin lot, every step after it)
-- =====================================================================================================================
create or replace function app.export_journey(p_fp uuid, p_copy text default 'shareable') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope uuid; v_code text; v_int boolean; ids uuid[]; v_shares jsonb; t jsonb;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  select scope_id, footprint_code into v_scope, v_code from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501'; end if;
  v_int := p_copy = 'internal';
  if v_int and not app.may_internal_copy(v_scope) then
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy'
      using errcode = '42501'; end if;
  with recursive up(id, depth) as (
      select p_fp, 0
    union
      select par.id, up.depth + 1
        from up join public.footprints f on f.id = up.id
        cross join lateral (
          select f.prev_footprint_id as id where f.prev_footprint_id is not null
          union
          select (x)::uuid from jsonb_array_elements_text(
            case when f.stage_type = 'village_batch' then coalesce(f.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x
        ) par
       where up.depth < 64)
  -- migration 61: in the chain's order (the farm first, the seal last), then as recorded
  select array_agg(f.id order by array_position(sc.chain, f.stage_type), f.created_at, f.footprint_code) into ids
    from (select distinct id from up) u join public.footprints f on f.id = u.id join public.scopes sc on sc.id = f.scope_id;
  select coalesce(jsonb_object_agg(s.entry_id::text, s.share), '{}'::jsonb) into v_shares from app.lot_sources(p_fp) s;
  t := app.export_table(ids, v_int, v_shares, (select data_note from public.scopes where id = v_scope));
  perform app.audit('export_downloaded', p_fp, jsonb_build_object('kind', 'journey', 'copy', p_copy, 'code', v_code,
    'rows', jsonb_array_length(t->'rows')), false);
  return t || jsonb_build_object('kind', 'journey', 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), 'generated_by', app.export_made_by(),
    'units', app.param_units(v_scope), 'scope', app.export_scope_head(v_scope),
    'lot', jsonb_build_object('code', v_code, 'qr_code', (select s.qr_code from public.qr_seals s where s.footprint_id = p_fp)));
end $$;

-- =====================================================================================================================
-- C1/C2 · the season of one scope: a heading, a summary per stage (the mass balance) with the season's totals, every
-- record
-- =====================================================================================================================
create or replace function app.export_season(p_scope uuid, p_copy text default 'shareable') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_int boolean; ids uuid[]; v_shares jsonb; t jsonb; v_summary jsonb; v_totals jsonb; v_batches jsonb; v_byp jsonb;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.sees_whole_scope(p_scope) then
    raise exception 'not allowed to export this scope' using errcode = '42501'; end if;
  v_int := p_copy = 'internal';
  if v_int and not app.may_internal_copy(p_scope) then
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy'
      using errcode = '42501'; end if;
  select array_agg(f.id order by f.created_at, f.footprint_code) into ids from public.footprints f where f.scope_id = p_scope;
  -- a source's share of the season: its kg of all the kg that came in (records not replaced, not withdrawn)
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status <> 'superseded'
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id))
  select coalesce(jsonb_object_agg(e.id::text, e.qty_out / nullif(tot.kg, 0)) filter (where e.id is not null), '{}'::jsonb) into v_shares
    from (select sum(qty_out) as kg from live where stage_type in ('procurement', 'lot_inward')) tot
    left join live e on e.stage_type in ('procurement', 'lot_inward');
  t := app.export_table(ids, v_int, v_shares, (select data_note from public.scopes where id = p_scope));
  v_summary := app.stage_balance_of(p_scope);
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packs', b.n, 'void', b.v, 'first', b.first, 'last', b.last,
           'by_size', b.by_size, 'best_before', case when b.no_bb > 0 then 'not_recorded' else b.bb::text end) order by b.batch_code), '[]'::jsonb)
    into v_batches
    from (select p.batch_code, count(*) filter (where p.status <> 'void') as n, count(*) filter (where p.status = 'void') as v,
                 min(p.serial) as first, max(p.serial) as last, min(p.best_before) filter (where p.status <> 'void') as bb,
                 count(*) filter (where p.status <> 'void' and p.best_before is null) as no_bb,
                 (select string_agg(x.n || ' × ' || x.label, ', ' order by x.size desc, x.label)
                    from (select count(*) as n, coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg') as label,
                                 max(k2.size_kg) as size
                            from public.packs k2 left join public.pack_skus sk on sk.id = k2.sku_id
                           where k2.batch_code = p.batch_code and k2.status <> 'void'
                           group by coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg')) x) as by_size
            from public.packs p where p.scope_id = p_scope group by p.batch_code) b;
  -- E2.2: the season's by-products, each on its own, apart from the losses
  select jsonb_build_object(
           'broken_kg', coalesce(sum((f.computed->>'broken_kg')::numeric) filter (where f.stage_type = 'milling'), 0),
           'husk_kg', coalesce(sum((f.computed->>'husk_kg')::numeric) filter (where f.stage_type = 'milling'), 0),
           'bran_kg', coalesce(sum((f.computed->>'bran_kg')::numeric) filter (where f.stage_type = 'milling'), 0),
           'reject_kg', coalesce(sum((f.computed->>'reject_kg')::numeric) filter (where f.stage_type in ('sorting', 'grading') and not f.is_grade_lot), 0),
           'foreign_matter_kg', coalesce(sum((f.computed->>'foreign_matter_kg')::numeric) filter (where f.stage_type = 'cleaning'), 0),
           'head_rice_kg', coalesce(sum((f.computed->>'head_rice_kg')::numeric) filter (where f.stage_type = 'milling'), 0))
    into v_byp from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy');
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status <> 'superseded'
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ent as (select l.*, app.entry_gi(l.id) as gi from live l where l.stage_type in ('procurement', 'lot_inward'))
  select jsonb_build_object(
           'farmers', (select count(distinct farmer_id) from ent),
           'kg_in', (select coalesce(sum(qty_out), 0) from ent),
           'gi_kg', (select coalesce(sum(qty_out), 0) from ent where gi = 'gi'),
           'gi_pct', (select round(100 * coalesce(sum(qty_out) filter (where gi = 'gi'), 0) / nullif(sum(qty_out), 0), 1) from ent),
           'farm_verified_kg', (select coalesce(sum(qty_out), 0) from ent where stage_type = 'procurement'),
           'by_products', v_byp,
           'by_products_kg', (select coalesce(sum((x->>'by_products_kg')::numeric), 0) from jsonb_array_elements(v_summary) x),
           'other_kg', (select coalesce(sum((x->>'other_kg')::numeric), 0) from jsonb_array_elements(v_summary) x),
           'floor_loss_kg', (select coalesce(sum((x->>'floor_loss_kg')::numeric), 0) from jsonb_array_elements(v_summary) x),
           'transit_loss_kg', (select coalesce(sum((x->>'transit_loss_kg')::numeric), 0) from jsonb_array_elements(v_summary) x),
           'closed_kg', (select coalesce(sum((x->>'closed_kg')::numeric), 0) from jsonb_array_elements(v_summary) x),
           'differences', (select count(*) from jsonb_array_elements(v_summary) x where not (x->>'balanced')::boolean),
           'sealed_lots', (select count(*) from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope),
           'packs', (select count(*) from public.packs p where p.scope_id = p_scope and p.status <> 'void'),
           'open_flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                           where f.scope_id = p_scope and fl.status = 'open'),
           'records', coalesce(cardinality(ids), 0))
    into v_totals;
  perform app.audit('export_downloaded', p_scope, jsonb_build_object('kind', 'season', 'copy', p_copy,
    'rows', jsonb_array_length(t->'rows')), false);
  return t || jsonb_build_object('kind', 'season', 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), 'generated_by', app.export_made_by(),
    'units', app.param_units(p_scope), 'scope', app.export_scope_head(p_scope),
    'summary', v_summary, 'totals', v_totals, 'batches', v_batches);
end $$;

-- =====================================================================================================================
-- E2.3 · the public page: every purchase of a collection batch, as one line
-- =====================================================================================================================
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
        'villages_n', (select count(distinct app.norm_place(fa.village)) from public.footprints src join public.farmers fa on fa.id = src.farmer_id
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
          from (select min(fa.village) as village, min(fa.district) as district, count(distinct fa.id) as n, sum(src.qty_out) as kg
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id = any(v_src) group by app.norm_place(fa.village)) g), '[]'::jsonb));
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

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
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
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    'units', app.param_units(v_scope.id),                                                                 -- migration 59 (A3)
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before))
                from public.packs p where p.footprint_id in (select app.lot_packings(seal.footprint_id)) and p.status = 'packed')
  );
end $function$;

-- =====================================================================================================================
-- E2.4 · the pack page: its best-before date, before release too
-- =====================================================================================================================
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
    -- migration 59 (A1): before release, the crop, the batch code and the date packed; nothing else (a voided pack says so; a copied code is warned of, without the seller)
    return jsonb_build_object('released', false,
      'pack', jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'packed_on', p.packed_on, 'void', p.status = 'void',
                                 'best_before', case when p.status <> 'void' then p.best_before end,   -- migration 61 (E2.4)
                                 'copy_warning', app.scan_warning(p.serial)),
      'crop', jsonb_build_object('name', cr.name));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $function$;

-- =====================================================================================================================
-- C4/E2.2/E2.5 · the lot's journey page: the scope's heading (for the print), by-products and floor loss, closures
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION app.lot_trace(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_scope uuid; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501';
  end if;

  with recursive up(id, depth) as (
      select p_fp, 0
    union
      select par.id, up.depth + 1
        from up join public.footprints f on f.id = up.id
        cross join lateral (
          select f.prev_footprint_id as id where f.prev_footprint_id is not null
          union
          select (x)::uuid from jsonb_array_elements_text(
            case when f.stage_type = 'village_batch' then coalesce(f.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x
        ) par
       where up.depth < 64
  )
  select jsonb_agg(jsonb_build_object(
           'id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'stage_label', sd.label, 'status', f.status,
           'prev_id', f.prev_footprint_id, 'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out, 'grade', f.grade,
           'payload', f.payload, 'computed', app.live_computed(f), 'warnings', to_jsonb(f.warnings),          -- migration 59 (A4)
           'lab', app.qc_lab(f.id),                                                                            -- migration 59 (A5)
           'same_person', f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by,
           'parts', app.record_parts(f),                                                                     -- migration 61 (E2.2)
           'closure', (select jsonb_build_object('kg', lc.floor_loss_kg, 'at', lc.closed_at, 'reason', lc.reason,          -- migration 61 (E2.5)
                          'by', (select u.display_name from public.app_users u where u.id = lc.closed_by))
                         from public.lot_closures lc where lc.footprint_id = f.id),
           'farmer', case when fa.id is null then null else jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village) end,
           'created_at', f.created_at, 'captured_at', coalesce(f.captured_at, f.created_at), 'created_by', cu.display_name,
           'verified_at', f.verified_at, 'verified_by', vu.display_name,
           'qc', (select jsonb_build_object('domestic', q.domestic_verdict, 'export', q.export_verdict, 'readings', q.readings, 'override', q.override)
                    from public.qc_verdicts q where q.footprint_id = f.id),
           'seal', (select jsonb_build_object('qr_code', s.qr_code, 'sealed_at', s.sealed_at, 'ledger_hash', s.ledger_hash, 'batch_codes', to_jsonb(s.batch_codes))
                      from public.qr_seals s where s.footprint_id = f.id),
           'withdrawn', (select jsonb_build_object('reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                           from public.withdrawals w left join public.app_users wu on wu.id = w.withdrawn_by where w.footprint_id = f.id),
           'replaces', (select jsonb_build_object('code', o.footprint_code, 'qty_out_kg', o.qty_out, 'reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                          from public.footprints o left join public.withdrawals w on w.footprint_id = o.id
                          left join public.app_users wu on wu.id = w.withdrawn_by where o.id = f.supersedes_id),
           'flags', coalesce((select jsonb_agg(jsonb_build_object('text', fl.text, 'status', fl.status, 'at', fl.created_at) order by fl.created_at)
                                from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
           'evidence', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'sha256', a.sha256, 'at', a.created_at) order by a.created_at)
                                   from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
           'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash, 'at', l.created_at) order by l.seq)
                                 from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
         ) order by f.created_at, f.footprint_code)
    into steps
    from (select distinct id from up) u
    join public.footprints f on f.id = u.id
    left join public.stage_definitions sd on sd.stage_type = f.stage_type
    left join public.farmers fa on fa.id = f.farmer_id
    left join public.app_users cu on cu.id = f.created_by
    left join public.app_users vu on vu.id = f.verified_by;

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb),
    'units', app.param_units(v_scope),                                                                    -- migration 59 (A3)
    'data_note', (select s.data_note from public.scopes s where s.id = v_scope),                          -- migration 59 (A8)
    'scope', app.export_scope_head(v_scope));                                                             -- migration 61 (C4)
end$function$;

-- =====================================================================================================================
-- E2.4 · Packing needs the crop's shelf life for the pack's material (the rest of the save rules unchanged)
-- =====================================================================================================================
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
  v_mat text;                                                                                                        -- migration 61
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
        v_mat := null;                                                                                   -- migration 61
        if nullif(pk->>'sku_id', '') is not null then
          select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id' and k.client_id = p_scope.client_id and k.active;
          if v_sku.id is null then raise exception 'packing: a pack is not on the client''s pack list' using errcode = '23514'; end if;
          if abs(app.req_num(pk, 'size_kg') - case v_sku.unit when 'g' then v_sku.size / 1000 else v_sku.size end) > 0.0005 then
            raise exception 'packing: a pack from the list keeps its own size (% %)', v_sku.size, v_sku.unit using errcode = '23514'; end if;
          if app.req_num(pk, 'units') < 1 or app.req_num(pk, 'units') <> trunc(app.req_num(pk, 'units')) then
            raise exception 'packing: the number of packs is a whole number, 1 or more' using errcode = '23514'; end if;
          v_mat := v_sku.material;                                                                       -- migration 61
        elsif p_scope.stage_details_required then
          raise exception 'packing: choose the packs from the client''s pack list' using errcode = '23514';
        end if;
        -- migration 61 (E2.4, Veda's brief of 19 Oct 2026): every pack carries its best-before date (packed date + the
        -- shelf life the State Manager set for the crop and the pack's material); without one Packing does not go ahead
        if app.shelf_life_for(p_scope.crop_id, v_mat) is null then
          if v_mat is null then
            raise exception 'packing: ask the State Manager to set the shelf life for this crop' using errcode = '23514'; end if;
          raise exception 'packing: ask the State Manager to set the shelf life for this crop and pack material (%)', v_mat
            using errcode = '23514'; end if;
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


-- =====================================================================================================================
-- who may call what
-- =====================================================================================================================
revoke execute on function app.record_parts(public.footprints), app.stage_balance_of(uuid), app.stage_balance(uuid), app.exp_txt(jsonb, text),
  app.export_record(uuid, boolean, numeric), app.export_table(uuid[], boolean, jsonb, text), app.export_scope_head(uuid), app.export_made_by(),
  app.export_journey(uuid, text), app.export_season(uuid, text) from public, anon, authenticated;
grant execute on function app.stage_balance(uuid), app.export_journey(uuid, text), app.export_season(uuid, text) to authenticated;
