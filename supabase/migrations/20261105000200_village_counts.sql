-- Migration 61b (Phase 1, release 3, found on staging 20 Oct 2026 in run-sheet row 8, /verify/GV-8B1E15E15317). The
-- public page's heading counted the lot's villages as recorded ("village1" and "village 1": "2 farmers in 2 villages"),
-- migration 61's new lines counted them by their letters only ("2 farmers from 1 village", "village 1 100 %"): one page,
-- two answers. Veda's brief (E2.3) expects "2 farmers from 2 villages" for that batch. The new lines and the exports'
-- villages column now count as the heading does: by the village and district as recorded on the farmers.
-- Replaced functions only (the public lot data, one export record); no table, no record changed.

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

CREATE OR REPLACE FUNCTION app.export_record(p_fp uuid, p_internal boolean, p_share numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- migration 61b: from the batch's lots, by the village and district as recorded (as the public page counts them)
    'villages', case when f.stage_type = 'village_batch' then
                  (select string_agg(g.village || ' ' || round(g.kg / nullif(f.qty_in, 0) * 100, 1) || ' %', '; ' order by g.kg desc, g.village)
                     from (select fv.village, fv.district, sum(sf.qty_out) as kg
                             from public.footprints sf join public.farmers fv on fv.id = sf.farmer_id
                            where sf.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)
                            group by fv.village, fv.district) g) end);
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
end $function$;

revoke execute on function app.export_record(uuid, boolean, numeric) from public, anon, authenticated;
