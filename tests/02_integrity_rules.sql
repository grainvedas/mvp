-- Integrity rules 1–9 (PRD §8) and per-stage physics (PRD §7). Runs in one transaction, rolled back at the end.
begin;
select t.as_service();

-- ---------------------------------------------------------------------------
-- Rule 5: chain shape validated at activation; frozen afterwards
-- ---------------------------------------------------------------------------
select t.fails($$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','KH26','t1','{procurement,milling,qr_activation}','active') $$,
  'qc is mandatory', 'rule 5: chain without QC rejected');
select t.fails($$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','KH26','t2','{procurement,milling,milling,qc,qr_activation}','active') $$,
  'only once', 'rule 5: same stage type twice rejected');
select t.fails($$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','KH26','t3','{milling,qc,qr_activation}','active') $$,
  'must start with', 'rule 5: chain must start with procurement or lot_inward');
select t.fails($$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','KH26','t4','{procurement,qc,commercial}','active') $$,
  'must end with qr_activation', 'rule 5: chain must end with QR');
select t.fails($$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201','00000000-0000-4000-8000-000000000101','KH26','t5','{procurement,popping,qc,qr_activation}','active') $$,
  'not allowed for this crop', 'rule 5: popping not allowed for Kalanamak');
select t.fails($$ update public.scopes set chain = '{procurement,milling,qc,qr_activation}' where id = t.scope('01') $$,
  'frozen', 'rule 5: active chain is frozen (D1)');
select t.ok((select status from public.scopes where id = t.scope('01')) = 'active', 'seeded minimal scope is active');

-- ---------------------------------------------------------------------------
-- Rule 1 & 2: sacred stamps and predecessor coupling
-- ---------------------------------------------------------------------------
select t.fails($$ insert into public.footprints (scope_id, client_id, stage_type, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', t.u('06'), '{"qty_kg":100,"sample_qty_kg":1,"readings":{}}') $$,
  'prev_footprint_id is required', 'rule 1: non-first stage without predecessor rejected');
select t.fails($$ insert into public.footprints (scope_id, client_id, stage_type, created_by, farmer_id, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'milling', t.u('08'), null, '{}') $$,
  'not in this scope', 'rule 2: stage outside the scope chain rejected');

-- Procurement: net = gross - bags x tare; canonical qty stamped; client_id stamped from scope
do $$
declare fp uuid; r public.footprints;
begin
  fp := t.procure(t.scope('01'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);
  select * into r from public.footprints where id = fp;
  perform t.ok(r.qty_in = 120 and r.qty_out = 120, 'procurement: net 126 - 3x2 = 120 stamped as qty_in/qty_out');
  perform t.ok(r.client_id = '00000000-0000-4000-8000-000000000201', 'procurement: client_id stamped from scope');
  perform t.ok(r.footprint_code = 'PRSDM-KNM-KH26-P-0001', 'procurement: footprint code format ' || r.footprint_code);
  perform t.ok((r.computed->>'moisture_avg')::numeric = 12.10, 'procurement: moisture avg computed');
  perform t.ok(r.status = 'pending', 'procurement: created pending');
end $$;

select t.fails($$ select t.procure(t.scope('01'), t.farmer('01'), 5, 3, 2, 12, 12, 12) $$,
  'net weight must be positive', 'procurement: gross < bags x tare rejected');
select t.fails($$ insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('06'),
          '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') $$,
  'may not create at stage', 'isMyStage: QC technician cannot create at procurement');

-- Wrong-stage predecessor: QC built directly on another QC-type / wrong type
do $$
declare fp uuid; qc uuid;
begin
  fp := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);   -- 147.5
  -- next stage cannot build on a pending predecessor
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', %L, t.u('06'),
             '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}') $q$, fp),
     'must be verified', 'rule 2: predecessor must be verified first');
  -- creator cannot verify own record; wrong-stage user cannot verify
  perform t.fails(format($q$ select t.verify(%L, t.u('05')) $q$, fp), 'may not verify', 'verify: procurement op is not the receiving stage');
  perform t.fails(format($q$ select t.verify(%L, t.u('07')) $q$, fp), 'may not verify', 'verify: QR sealer is not the stage after procurement');
  perform t.verify(fp, t.u('06'));
  perform t.ok((select status from public.footprints where id = fp) = 'verified', 'verify: QC technician (next stage) verifies procurement');

  -- Rule 4: immutability after verification
  perform t.fails(format($q$ update public.footprints set payload = payload || '{"gross_kg":999}' where id = %L $q$, fp),
     'immutable', 'rule 4: verified payload immutable');
  perform t.fails(format($q$ update public.footprints set qty_out = 1 where id = %L $q$, fp), 'immutable', 'rule 4: verified qty immutable');
  perform t.fails(format($q$ update public.footprints set scope_id = t.scope('02') where id = %L $q$, fp), 'immutable', 'rule 4: scope_id immutable');
  perform t.fails(format($q$ delete from public.footprints where id = %L $q$, fp), 'never deleted', 'rule 4: footprints never deleted');

  -- Rule 7: QC sample deduction; availability; reading-derived verdicts
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', fp, t.u('06'),
          '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into qc;
  perform t.ok((select qty_out from public.footprints where id = qc) = 147, 'rule 7: QC qty_out = 147.5 - 0.5 sample');
  perform t.ok((select domestic_verdict from public.qc_verdicts where footprint_id = qc) = 'pass', 'qc: domestic PASS derived (11.9 <= 13)');
  perform t.ok((select export_verdict   from public.qc_verdicts where footprint_id = qc) = 'pass', 'qc: export PASS derived (11.9 <= 12)');
  perform t.ok(app.available_qty(fp) = 0, 'availability: procurement lot fully consumed by QC');
  perform t.ok((select lot_closed from public.footprints where id = fp), 'auto-close: source with < 2 kg left is closed');
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', %L, t.u('06'), '{"qty_kg":10,"sample_qty_kg":0.1,"readings":{}}') $q$, fp),
     'closed', 'availability: closed lot cannot be drawn again');

  -- QC verdict: derived columns immutable; override needs reason + authoriser with gateway role
  perform t.fails(format($q$ update public.qc_verdicts set export_verdict = 'fail' where footprint_id = %L $q$, qc), 'immutable', 'qc: derived verdict immutable');
  perform t.fails(format($q$ update public.qc_verdicts set override = '{"market":"export","reason":"x","authoriser":"%s"}' where footprint_id = %L $q$, t.u('06'), qc),
     'client_manager or above', 'qc override: operator cannot authorise');
end $$;

-- Over-draw: qty_in beyond predecessor availability
do $$
declare fp uuid;
begin
  fp := t.procure(t.scope('01'), t.farmer('03'), 180, 1, 2, 12.4, 12.3, 12.5);   -- 178
  perform t.verify(fp, t.u('06'));
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', %L, t.u('06'), '{"qty_kg":200,"sample_qty_kg":1,"readings":{}}') $q$, fp),
     'exceeds available', 'availability: qty_in 200 > 178 available rejected');
  -- QC with 12.4% moisture: domestic pass, export fail
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', fp, t.u('06'),
          '{"qty_kg":178,"sample_qty_kg":1,"readings":{"moisture_pct":12.4,"broken_pct":2,"foreign_matter_pct":0.2}}');
  perform t.ok((select domestic_verdict from public.qc_verdicts v join public.footprints f on f.id = v.footprint_id where f.prev_footprint_id = fp) = 'pass'
           and (select export_verdict from public.qc_verdicts v join public.footprints f on f.id = v.footprint_id where f.prev_footprint_id = fp) = 'fail',
           'qc: 12.4% moisture → domestic PASS, export FAIL');
end $$;

-- ---------------------------------------------------------------------------
-- Rule 3 + per-stage physics, exercised on scope 03 (procurement → qc → milling → commercial → qr)
-- ---------------------------------------------------------------------------
do $$
declare fp uuid; qc uuid; mill uuid; sc public.scopes; f public.footprints;
begin
  select * into sc from public.scopes where id = t.scope('03');
  fp := t.procure(t.scope('03'), t.farmer('05'), 199, 2, 2, 11.8, 11.7, 11.9);   -- 195
  perform t.verify(fp, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'qc', fp, t.u('06'),
          '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into qc;
  perform t.verify(qc, t.u('08'));   -- mill operator is the receiving stage
  -- milling reconciliation
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'milling', %L, t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":20,"loss_kg":10}') $q$, qc),
     'must equal rice + bran + loss', 'milling: input ≠ rice + bran + loss rejected');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'milling', qc, t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}')
  returning id into mill;
  select * into f from public.footprints where id = mill;
  perform t.ok(f.qty_out = 130, 'milling: qty_out = rice 130');
  perform t.ok('yield below threshold' = any(f.warnings), 'milling: yield 67% < 70% flagged as warning, not rejected');

  -- Pure reconcile() checks for stages not in any seeded chain: build a synthetic row and call the function directly
  f.stage_type := 'drying'; f.prev_footprint_id := null; f.is_grade_lot := false;
  f.payload := '{"input_kg":100,"moisture_in_pct":20,"moisture_out_pct":12,"output_kg":91}';
  f := app.reconcile(f, sc);
  perform t.ok(round((f.computed->>'expected_out_kg')::numeric, 2) = 90.91, 'drying: expected out 100×80/88 = 90.91');
  perform t.ok(array_length(f.warnings, 1) is null, 'drying: 9 kg drop explained by moisture → no loss flag');
  f.payload := '{"input_kg":100,"moisture_in_pct":20,"moisture_out_pct":12,"output_kg":85}';
  f := app.reconcile(f, sc);
  perform t.ok('grain loss beyond moisture removal' = any(f.warnings), 'drying: 85 kg out (< 90.9 expected) flags grain loss');

  f.stage_type := 'popping'; f.payload := '{"input_kg":100,"output_kg":50,"pop_rate_pct":85}';
  f := app.reconcile(f, sc);
  perform t.ok(array_length(f.warnings, 1) is null, 'popping: 50% weight yield at 85% pop rate → no flag');
  f.payload := '{"input_kg":100,"output_kg":50,"pop_rate_pct":75}';
  f := app.reconcile(f, sc);
  perform t.ok('pop rate below threshold' = any(f.warnings), 'popping: 75% pop rate flagged');

  f.stage_type := 'blanching'; f.payload := '{"input_kg":100,"output_kg":108}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 108 and (f.computed->>'water_uptake_kg')::numeric = 8, 'blanching: output > input allowed (water uptake 8 kg)');

  f.stage_type := 'cleaning'; f.payload := '{"input_kg":100,"output_kg":108}';
  begin
    f := app.reconcile(f, sc); raise exception 'ASSERTION FAILED: cleaning accepted output > input';
  exception when others then
    perform t.ok(sqlerrm ilike '%required%' or sqlerrm ilike '%exceeds input%', 'rule 3: non-blanching stage cannot exceed input / needs its fields');
  end;

  f.stage_type := 'sorting'; f.payload := '{"input_kg":100,"reject_kg":6,"loss_kg":1,"reject_reasons":[{"reason":"discoloured","kg":4},{"reason":"broken","kg":2}]}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 93, 'sorting: clean output derived = 100 - 6 - 1 = 93');

  f.stage_type := 'grading'; f.payload := '{"input_kg":93,"grade_a_kg":50,"grade_b_kg":30,"grade_c_kg":10,"reject_kg":2,"loss_kg":1}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 90, 'grading: A+B+C = 90 forwarded; A+B+C+reject+loss = 93 balances');
  f.payload := '{"input_kg":93,"grade_a_kg":50,"grade_b_kg":30,"grade_c_kg":10,"reject_kg":2,"loss_kg":5}';
  begin
    f := app.reconcile(f, sc); raise exception 'ASSERTION FAILED: grading imbalance accepted';
  exception when others then
    perform t.ok(sqlerrm ilike '%must equal input%', 'grading: A+B+C+reject+loss ≠ input rejected');
  end;

  f.stage_type := 'cold_storage'; f.payload := '{"stored_kg":100,"retrieved_kg":97}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 97 and (f.computed->>'spoilage_kg')::numeric = 3, 'cold storage: output = retrieved, spoilage 3');

  f.stage_type := 'packing'; f.payload := '{"input_kg":100,"packets":[{"units":90,"size_kg":1},{"units":18,"size_kg":0.5}],"wastage_kg":1,"batch_code":"KNM-KH26-B001"}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 99, 'packing: Σ packets 99 + wastage 1 = 100');
  f.payload := '{"input_kg":100,"packets":[{"units":99,"size_kg":1}],"wastage_kg":1}';
  begin
    f := app.reconcile(f, sc); raise exception 'ASSERTION FAILED: packing without batch_code accepted';
  exception when others then
    perform t.ok(sqlerrm ilike '%batch_code%', 'packing: batch_code mandatory');
  end;

  f.stage_type := 'shipment'; f.payload := '{"shipped_kg":100,"transit_loss_kg":2.5}';
  f := app.reconcile(f, sc);
  perform t.ok(f.qty_out = 97.5, 'shipment: transit loss carried forward (X − Y = 97.5)');
end $$;

rollback;
