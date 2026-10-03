-- Acceptance chains (PRD §12): T1 minimal, T2 grading split, T3 market fork + override. Seal + public journey.
begin;
select t.as_service();

-- ---------------------------------------------------------------------------
-- T1: Procurement → QC → QR  (scope 01)
-- ---------------------------------------------------------------------------
create temp table t1 (k text primary key, v uuid);
grant select on t1 to anon, authenticated;
do $$
declare p uuid; q uuid; qr uuid; seal public.qr_seals; j jsonb;
begin
  p := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);   -- Sita Devi 147.5 kg
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2},"lab_ref":"LAB-001"}')
  returning id into q;
  -- QR operator cannot build on a pending QC
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', %L, t.u('07'), '{}') $q$, q),
     'must be verified', 'T1: QR cannot activate on an unverified QC');
  perform t.verify(q, t.u('07'));          -- QR sealer is the receiving stage → verifies QC
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  perform t.ok((select qty_out from public.footprints where id = qr) = 147, 'T1: QR footprint carries the final 147 kg');

  -- Gate: open flag blocks the seal
  insert into public.flags (footprint_id, raised_by, text) values (p, t.u('06'), 'bag count looked off');
  perform t.fails(format($q$ select app.seal_lot(%L, t.u('07')) $q$, qr), 'open flag', 'T1 gate: open flag on an ancestor blocks sealing');
  update public.flags set status = 'resolved' where footprint_id = p;
  -- Gate: wrong user cannot seal
  perform t.fails(format($q$ select app.seal_lot(%L, t.u('06')) $q$, qr), 'only the assigned QR operator', 'T1 gate: QC technician cannot seal');
  seal := app.seal_lot(qr, t.u('07'));
  perform t.ok(seal.qr_code like 'GV-%', 'T1: sealed with QR code ' || seal.qr_code);
  perform t.ok((select status from public.footprints where id = qr) = 'verified', 'T1: QR footprint verified by the seal');
  perform t.ok((select event from public.ledger order by seq desc limit 1) = 'seal', 'T1: seal block written');
  perform t.ok((select count(*) from public.ledger where footprint_id in (p, q, qr)) >= 5, 'T1: ≥ 5 ledger blocks across the lot');
  perform t.fails(format($q$ select app.seal_lot(%L, t.u('07')) $q$, qr), 'already sealed', 'T1: cannot seal twice');
  perform t.fails(format($q$ delete from public.qr_seals where footprint_id = %L $q$, qr), 'immutable', 'T1: seal immutable');
  insert into t1 values ('qr_code', null); update t1 set v = null;  -- placeholder row; code stored below
  insert into t1 values ('p', p), ('q', q), ('qrfp', qr);
  perform set_config('t1.qr_code', seal.qr_code, true);
end $$;

-- Public verify page as an anonymous visitor
select t.as_anon();
do $$
declare j jsonb;
begin
  j := app.public_lot_journey(current_setting('t1.qr_code', true));
  perform t.ok(j is not null, 'T1 public: journey resolves for the QR code');
  perform t.ok(j->'crop'->>'gi_tag' = 'GI 280', 'T1 public: GI tag shown');
  perform t.ok(jsonb_array_length(j->'journey') = 3, 'T1 public: 3 steps (procurement, qc, qr)');
  perform t.ok(j->'journey'->0->'farmer'->>'name' = 'Sita Devi' and j->'journey'->0->'farmer'->>'village' = 'Itwa', 'T1 public: farmer name + village');
  perform t.ok(j->'journey'->0->'farmer' ? 'phone' = false, 'T1 public: farmer phone never exposed');
  perform t.ok(j->'verdict'->>'export' = 'pass', 'T1 public: export PASS shown');
  perform t.ok(app.public_lot_journey('GV-DOESNOTEXIST') is null, 'T1 public: unknown code → null');
end $$;
select t.fails($q$ select count(*) from public.farmers $q$, 'permission denied', 'T1 public: anon cannot read farmers table');
select t.as_service();

-- ---------------------------------------------------------------------------
-- T2: Procurement → Sorting → Grading (split A/B/C) → QC → QR  (scope 02)
-- ---------------------------------------------------------------------------
do $$
declare p uuid; s uuid; g uuid; ga uuid; gb uuid; gc uuid; q uuid; qr uuid; seal public.qr_seals;
begin
  p := t.procure(t.scope('02'), t.farmer('03'), 180, 1, 2, 12.4, 12.3, 12.5);   -- Mohan Lal 178 kg
  perform t.verify(p, t.u('09'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'sorting', p, t.u('09'),
          '{"input_kg":178,"reject_kg":6,"loss_kg":2,"reject_reasons":[{"reason":"discoloured","kg":4},{"reason":"broken","kg":2}]}') returning id into s;
  perform t.ok((select qty_out from public.footprints where id = s) = 170, 'T2: sorting clean output derived 170');
  perform t.verify(s, t.u('10'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, split_into_grades)
  values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', s, t.u('10'),
          '{"input_kg":170,"grade_a_kg":100,"grade_b_kg":50,"grade_c_kg":15,"reject_kg":3,"loss_kg":2}', true) returning id into g;
  -- grade lots coupled to the run. Since migration 24 the save of a split run makes them itself, in the same
  -- transaction (before: three separate inserts here, and in the app a second request that could fail).
  select id into ga from public.footprints where prev_footprint_id = g and is_grade_lot and grade = 'A';
  select id into gb from public.footprints where prev_footprint_id = g and is_grade_lot and grade = 'B';
  select id into gc from public.footprints where prev_footprint_id = g and is_grade_lot and grade = 'C';
  perform t.ok(ga is not null and gb is not null and gc is not null
               and (select array_agg(qty_out order by grade) from public.footprints where prev_footprint_id = g and is_grade_lot) = array[100, 50, 15]::numeric[]
               and (select bool_and(created_by = t.u('10')) from public.footprints where prev_footprint_id = g and is_grade_lot),
               'T2: saving the split run creates grade lots A 100 / B 50 / C 15 kg, in the grader''s name');
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
     values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', %L, t.u('10'), '{"qty_kg":20}', true, 'C') $q$, g),
     'exceeds available', 'T2: grade lots cannot exceed the run''s A+B+C (165)');
  perform t.ok((select footprint_code from public.footprints where id = ga) like 'PRSDM-KNM-KH26-G-%-A', 'T2: grade lot code carries the grade');
  perform t.ok(app.available_qty(g) = 0, 'T2: split parent fully allocated to grade lots');

  -- verify run + grade lots (QC technician is the receiving stage)
  perform t.verify(g, t.u('06')); perform t.verify(ga, t.u('06')); perform t.verify(gb, t.u('06')); perform t.verify(gc, t.u('06'));
  -- rule 8: split parent is not an incoming source; the grade lots are
  perform t.ok(not exists (select 1 from app.incoming_records(t.scope('02'), 'qc') where id = g), 'T2 rule 8: split parent hidden from QC incoming');
  perform t.ok((select count(*) from app.incoming_records(t.scope('02'), 'qc')) = 3, 'T2 rule 8: 3 grade lots incoming at QC');
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'qc', %L, t.u('06'), '{"qty_kg":10,"sample_qty_kg":0.1,"readings":{}}') $q$, g),
     'not a source', 'T2 rule 8: QC cannot build on the split parent');

  -- QC on grade A only, then seal it independently
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'qc', ga, t.u('06'),
          '{"qty_kg":100,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.4,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.verify(q, t.u('07'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr, t.u('07'));
  perform t.ok(seal.qr_code is not null, 'T2: grade-A lot sealed independently');
  perform t.ok((select jsonb_array_length(app.public_lot_journey(seal.qr_code)->'journey')) = 6,
               'T2 public: journey = procurement, sorting, grading run, grade lot, qc, qr (6 steps)');
  perform t.ok(app.available_qty(gb) = 50 and app.available_qty(gc) = 15, 'T2: grade B and C still available for other buyers');
end $$;

-- ---------------------------------------------------------------------------
-- T3: Procurement → QC → Milling → Commercial → QR  (scope 03): export/domestic fork, override
-- ---------------------------------------------------------------------------
do $$
declare p uuid; q uuid; m uuid; c1 uuid; c2 uuid; qr uuid; seal public.qr_seals; vd record;
begin
  p := t.procure(t.scope('03'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);   -- Ram Achal 120 kg, 12.1% → domestic only
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.ok((select export_verdict from public.qc_verdicts where footprint_id = q) = 'fail', 'T3: 12.1% → export FAIL, domestic PASS');
  perform t.verify(q, t.u('08'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'milling', q, t.u('08'), '{"input_kg":119,"rice_kg":80,"bran_kg":30,"loss_kg":9}') returning id into m;
  perform t.verify(m, t.u('11'));

  -- market verdict resolves through milling back to QC
  select * into vd from app.resolve_market_verdict(m);
  perform t.ok(vd.qc_footprint_id = q and vd.export = 'fail', 'T3: market verdict resolved through milling to the QC record');
  -- export sale blocked; domestic allowed
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
     values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'commercial', %L, t.u('11'), '{"buyer":"EU Importer","market":"export","qty_kg":50}') $q$, m),
     'export PASS or a client-level override', 'T3: export sale of a domestic-only lot refused');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'commercial', m, t.u('11'), '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":50}') returning id into c1;
  perform t.ok(app.available_qty(m) = 30, 'T3: 30 kg of rice left after a 50 kg domestic allocation');

  -- client-level override with reason + authoriser unlocks export for the remainder
  perform t.fails(format($q$ update public.qc_verdicts set override = '{"market":"export","reason":"","authoriser":"%s"}' where footprint_id = %L $q$, t.u('03'), q),
     'reason', 'T3 override: reason mandatory');
  update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'Buyer accepts 12.1% with re-drying at destination', 'authoriser', t.u('03'))
   where footprint_id = q;
  perform t.ok((select export_verdict from public.qc_verdicts where footprint_id = q) = 'fail', 'T3 override: derived FAIL kept for audit');
  perform t.ok((select event from public.ledger order by seq desc limit 1) = 'override', 'T3 override: ledgered');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'commercial', m, t.u('11'), '{"buyer":"EU Importer","market":"export","qty_kg":30}') returning id into c2;
  perform t.ok((select lot_closed from public.footprints where id = m), 'T3: milling lot auto-closed at 0 kg available');
  perform t.fails(format($q$ update public.qc_verdicts set override = null where footprint_id = %L $q$, q), 'cannot be changed', 'T3 override: cannot be removed');

  -- seal the export allocation
  perform t.verify(c2, t.u('07'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'qr_activation', c2, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr, t.u('07'));
  perform t.ok((app.public_lot_journey(seal.qr_code)->'verdict'->>'overridden')::boolean, 'T3 public: verify page discloses the override');

  -- supervisory act: client manager creates at a stage without holding the slot → ledgered as supervisory
  perform t.procure_as(t.scope('03'), t.farmer('04'), t.u('03'));
  perform t.ok((select event from public.ledger order by seq desc limit 1) = 'supervisory', 'gateway: client manager''s create is ledgered as supervisory');
end $$;

rollback;
