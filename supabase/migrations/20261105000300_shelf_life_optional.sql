-- Migration 61c (Phase 1, release 3; Veda, 20 Oct 2026, at run-sheet row 1 of release 3: "DONT MAKE THIS MANDATORY.
-- DONT CHANGE AS OF NOW"). Migration 61 refused Packing while the crop had no shelf life for the pack's material (E2.4).
-- Now Packing goes ahead without one, with a warning on the record ("no shelf life is set for this crop and pack
-- material (pouch): these packs carry no best-before date"); the pack page says "Best before: not recorded". The crops on
-- staging are not changed. Replaced function only (Packing's save rules); no table, no record changed.

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
        -- migration 61 (E2.4): a pack's best-before date is the packed date + the shelf life the State Manager set for the
        -- crop and the pack's material. Migration 61c (Veda, 20 Oct 2026: "DONT MAKE THIS MANDATORY"): without one
        -- Packing goes ahead, with a warning on the record; those packs carry no best-before date
        if app.shelf_life_for(p_scope.crop_id, v_mat) is null then
          v_ser_txt := case when v_mat is null then 'no shelf life is set for this crop: these packs carry no best-before date (the State Manager sets it)'
                            else format('no shelf life is set for this crop and pack material (%s): these packs carry no best-before date (the State Manager sets it)', v_mat) end;
          if not (v_ser_txt = any(w)) then w := array_append(w, v_ser_txt); end if;
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
