-- Phase 2 chains as signed-in users: T4 (procure → QC → mill → pack → 2 buyers → ship → seal), T2 with the split RPC
-- (grade lot verification verifies its run), Village Batch (aggregation, all farmers public, gate over all sources).
begin;
select t.as_service();

-- ===========================================================================================================
-- T4 on scope 405 (Basti mill)
-- ===========================================================================================================
do $$
declare s uuid := '00000000-0000-4000-8000-000000000405'; c uuid := '00000000-0000-4000-8000-000000000201';
        p uuid; q uuid; m uuid; pk uuid; dom uuid; ex uuid; sh uuid; qr uuid; seal public.qr_seals; j jsonb; r public.footprints;
begin
  p := t.procure(s, t.farmer('05'), 199, 2, 2, 11.8, 11.7, 11.9);                                   -- 195 kg
  perform t.as_user(t.u('06')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', p, t.u('06'), '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.as_user(t.u('08')); perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'milling', q, t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}') returning id into m;
  perform t.as_user(t.u('09')); perform app.verify_footprint(m);
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values ('00000000-0000-4000-8000-000000000405', '00000000-0000-4000-8000-000000000201', 'packing', %L, t.u('09'),
             '{"input_kg":130,"packets":[{"units":129,"size_kg":1}],"wastage_kg":1}') $q$, m), 'batch_code', 'T4 packing without a batch code refused');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'packing', m, t.u('09'),
          '{"input_kg":130,"packets":[{"units":100,"size_kg":1},{"units":58,"size_kg":0.5}],"wastage_kg":1,"batch_code":"KNM-KH26-B001"}')
  returning * into r;
  pk := r.id;
  perform t.ok(r.qty_out = 129, 'T4 packing: 100 × 1 kg + 58 × 0.5 kg = 129 kg packed, 1 kg wastage');
  perform t.as_user(t.u('11')); perform app.verify_footprint(pk);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'commercial', pk, t.u('11'), '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":50}') returning id into dom;
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'commercial', pk, t.u('11'), '{"buyer":"EU Importer","market":"export","qty_kg":79}') returning id into ex;
  perform t.ok(app.available_qty(pk) = 0 and (select lot_closed from public.footprints where id = pk),
               'T4 commercial splits forward: two buyers take all 129 kg and the packed lot closes');
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values ('00000000-0000-4000-8000-000000000405', '00000000-0000-4000-8000-000000000201', 'commercial', %L, t.u('11'),
             '{"buyer":"Third","market":"domestic","qty_kg":1}') $q$, pk), 'closed', 'T4 a third allocation from a closed lot refused');
  perform t.as_user(t.u('14')); perform app.verify_footprint(ex);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'shipment', ex, t.u('14'), '{"shipped_kg":79,"transit_loss_kg":0.5,"vehicle_or_container":"MSKU1234567",
          "dispatch_date":"2026-11-20","destination":"Rotterdam"}') returning * into r;
  sh := r.id;
  perform t.ok(r.qty_out = 78.5, 'T4 shipment: 79 kg shipped, 0.5 kg transit loss carried forward');
  perform t.as_user(t.u('07')); perform app.verify_footprint(sh);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', sh, t.u('07'), '{}') returning id into qr;
  perform t.ok((select qty_out from public.footprints where id = qr) = 78.5, 'T4 the QR lot carries 78.5 kg');
  seal := app.seal_lot(qr);
  perform t.ok(seal.batch_codes = array['KNM-KH26-B001'], 'T4 seal carries the packing batch code');
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok(jsonb_array_length(j->'journey') = 7, 'T4 public journey has 7 steps (procure, qc, mill, pack, commercial, ship, qr)');
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'journey') e where e->>'batch_code' = 'KNM-KH26-B001')
               and exists (select 1 from jsonb_array_elements(j->'journey') e where e->>'destination' = 'Rotterdam'),
               'T4 public journey shows batch code and destination');
  perform t.as_service();
end $$;

-- ===========================================================================================================
-- T2 with the split RPC on scope 402: verifying a grade lot also verifies its run
-- ===========================================================================================================
do $$
declare s uuid := '00000000-0000-4000-8000-000000000402'; c uuid := '00000000-0000-4000-8000-000000000201';
        p uuid; so uuid; g uuid; lots public.footprints[]; a public.footprints; q uuid; qr uuid; seal public.qr_seals;
begin
  p := t.procure(s, t.farmer('03'), 180, 1, 2, 12.4, 12.3, 12.5);
  perform t.as_user(t.u('09')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'sorting', p, t.u('09'), '{"input_kg":178,"reject_kg":6,"loss_kg":2,"reject_reasons":[{"reason":"discoloured","kg":6}]}') returning id into so;
  perform t.as_user(t.u('10')); perform app.verify_footprint(so);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, split_into_grades)
  values (s, c, 'grading', so, t.u('10'), '{"input_kg":170,"grade_a_kg":100,"grade_b_kg":50,"grade_c_kg":15,"reject_kg":3,"loss_kg":2}', true)
  returning id into g;
  perform t.as_user(t.u('06'));
  perform t.fails(format($q$ select app.split_grades(%L) $q$, g), 'may not create', 'T2 only the grading operator splits');
  perform t.as_user(t.u('10'));
  select array_agg(x order by x.grade) into lots from app.split_grades(g) x;
  perform t.ok(array_length(lots, 1) = 3 and lots[1].grade = 'A' and lots[1].qty_out = 100 and lots[3].qty_out = 15,
               'T2 split_grades creates A 100 / B 50 / C 15 kg from the run''s own figures');
  perform t.fails(format($q$ select app.split_grades(%L) $q$, g), 'already has grade lots', 'T2 a run is split once');
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(lots[1].id);
  perform t.ok((select status from public.footprints where id = g) = 'verified'
               and (select verified_by from public.footprints where id = g) = t.u('06'),
               'T2 verifying grade lot A also verifies the hidden run, by the same QC technician');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', lots[1].id, t.u('06'), '{"qty_kg":100,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.4,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.as_user(t.u('07')); perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr);
  perform t.ok(seal.qr_code like 'GV-%', 'T2 grade-A lot seals from signed-in users only (no service shortcuts)');
  perform t.as_service();
end $$;

-- ===========================================================================================================
-- Village Batch on scope 406
-- ===========================================================================================================
do $$
declare s uuid := '00000000-0000-4000-8000-000000000406'; c uuid := '00000000-0000-4000-8000-000000000201';
        a uuid; b uuid; d uuid; vb public.footprints; q uuid; qr uuid; seal public.qr_seals; j jsonb; flag uuid;
begin
  a := t.procure(s, t.farmer('01'), 126, 3, 2, 12, 12, 12);                                          -- 120
  b := t.procure(s, t.farmer('02'), 150, 1, 2.5, 12, 12, 12);                                        -- 147.5
  d := t.procure(s, t.farmer('03'), 180, 1, 2, 12, 12, 12);                                          -- 178
  perform t.as_user(t.u('15'));
  perform app.verify_footprint(a); perform app.verify_footprint(b);
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values ('00000000-0000-4000-8000-000000000406', '00000000-0000-4000-8000-000000000201', 'village_batch', %L, t.u('15'),
             jsonb_build_object('village', 'Bansi', 'source_footprint_ids', jsonb_build_array(%L, %L, %L))) $q$, a, a, b, d),
     'not a verified', 'VB a pending farmer lot cannot join a batch');
  perform app.verify_footprint(d);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'village_batch', a, t.u('15'), jsonb_build_object('village', 'Bansi', 'source_footprint_ids', jsonb_build_array(a, b, d)))
  returning * into vb;
  perform t.ok(vb.qty_in = 445.5 and vb.qty_out = 445.5, 'VB batch quantity = 120 + 147.5 + 178 = 445.5 kg');
  perform t.ok((select bool_and(lot_closed) from public.footprints where id in (a, b, d)), 'VB every source lot is closed by the batch');
  perform t.as_user(t.u('06')); perform app.verify_footprint(vb.id);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', vb.id, t.u('06'), '{"qty_kg":445.5,"sample_qty_kg":1.5,"readings":{"moisture_pct":12,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.as_user(t.u('07')); perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  -- an open flag on the THIRD source (not on the prev path) must block the seal
  perform t.as_user(t.u('06'));
  perform t.fails(format($q$ insert into public.flags (footprint_id, raised_by, text) values (%L, t.u('06'), 'x') $q$, d),
                  'row-level security', 'VB QC cannot even see a farmer lot two stages back, so cannot flag it');
  perform t.as_user(t.u('15'));
  insert into public.flags (footprint_id, raised_by, text) values (d, t.u('15'), 'moisture reading looked copied') returning id into flag;
  perform t.as_user(t.u('07'));
  perform t.fails(format($q$ select app.seal_lot(%L) $q$, qr), 'open flag on batch source', 'VB open flag on any batch source blocks the seal');
  perform t.as_service();
  update public.flags set status = 'resolved' where id = flag;
  perform t.as_user(t.u('07'));
  seal := app.seal_lot(qr);
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok((select jsonb_array_length(e->'farmers') from jsonb_array_elements(j->'journey') e where e->>'stage' = 'village_batch') = 3,
               'VB public page names all 3 farmers of the batch');
  perform t.ok(not (j::text like '%9000000001%'), 'VB public page never shows farmer phones');
  perform t.as_service();
end $$;

rollback;
