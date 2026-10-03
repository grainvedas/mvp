-- Migration 22: direct writes by signed-in users (PATCH / POST on the tables, bypassing the screens).
-- Every hole found in the pre-go-live review is held here as a refused write; the legitimate paths beside each one
-- (correction, verification, seal, auto-close, split, farmer workflow, flag resolution) are shown to still work.

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Footprints: server-derived columns, status and lot_closed are not writable by API users
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare p uuid; q uuid; qr uuid; r public.footprints; seal public.qr_seals;
        fp text; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  -- F3: a new record sent with a back-dated time, a hand-picked code and lot_closed
  perform t.as_user(t.u('05'));
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, created_at, footprint_code, lot_closed, qty_out, computed)
  values (t.scope('01'), c, 'procurement', t.farmer('02'), t.u('05'), '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}',
          now() - interval '30 days', 'PRSDM-KNM-KH26-P-9999', true, 999, '{"net_kg":999}')
  returning * into r;
  p := r.id; fp := quote_literal(p);
  perform t.ok(r.created_at = now(), 'F3 a new record cannot be back-dated: created_at is the server''s clock');
  perform t.ok(r.footprint_code <> 'PRSDM-KNM-KH26-P-9999' and r.footprint_code ~ '^PRSDM-KNM-KH26-P-[0-9]{4}$', 'F3 a new record cannot choose its code: ' || r.footprint_code);
  perform t.ok(not r.lot_closed and r.qty_out = 147.5 and (r.computed->>'net_kg')::numeric = 147.5, 'F3 lot status and quantities sent with a new record are ignored');

  -- F1: the creator rewrites derived columns of his own pending record
  perform t.fails('update public.footprints set qty_out = 999 where id = ' || fp, 'set by the server', 'F1 creator cannot rewrite qty_out of a pending record');
  perform t.fails('update public.footprints set qty_in = 999 where id = ' || fp, 'set by the server', 'F1 creator cannot rewrite qty_in');
  perform t.fails($q$update public.footprints set computed = '{"net_kg":999}', warnings = '{}' where id = $q$ || fp, 'set by the server', 'F1 creator cannot rewrite computed values or warnings');
  perform t.fails($q$update public.footprints set created_at = now() - interval '30 days' where id = $q$ || fp, 'set by the server', 'F1 creator cannot back-date a saved record');
  perform t.fails('update public.footprints set lot_closed = true where id = ' || fp, 'set by the server', 'F2 creator cannot close a lot by hand');
  perform t.fails($q$update public.footprints set status = 'superseded' where id = $q$ || fp, 'cannot be set directly', 'F2 creator cannot void his own pending record');
  -- and the correction that IS his to make still works, with the server deriving the figures
  update public.footprints set payload = '{"gross_kg":160,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}' where id = p returning * into r;
  perform t.ok(r.qty_out = 157.5 and (r.computed->>'net_kg')::numeric = 157.5, 'correction by the creator still works: 160 - 2.5 = 157.5 derived by the server');

  -- F1, F2: the next stage's operator, before verifying
  perform t.as_user(t.u('06'));
  perform t.fails('update public.footprints set qty_out = 500 where id = ' || fp, 'set by the server', 'F1 next-stage operator cannot rewrite the quantity he is about to verify');
  perform t.fails('update public.footprints set split_into_grades = true where id = ' || fp, 'only the person who recorded', 'F1 next-stage operator cannot set the split flag');
  perform t.fails('update public.footprints set supersedes_id = id, client_ref = gen_random_uuid() where id = ' || fp, 'set by the server', 'F1 next-stage operator cannot set supersedes_id or client_ref');
  perform t.fails($q$update public.footprints set status = 'superseded' where id = $q$ || fp, 'cannot be set directly', 'F2 next-stage operator cannot void a pending record');
  perform t.fails(format('update public.footprints set verified_by = %L where id = %L', t.u('06'), p), 'set by verification only', 'F1 verified_by cannot be set without verifying');
  -- direct verification is still judged by the existing rules, with the server's clock
  update public.footprints set status = 'verified', verified_by = t.u('06'), verified_at = now() - interval '10 days' where id = p returning * into r;
  perform t.ok(r.status = 'verified' and r.verified_at = now() and r.qty_out = 157.5, 'verification cannot be back-dated, and it froze the true 157.5 kg');
  perform t.fails($q$update public.footprints set status = 'superseded' where id = $q$ || fp, 'cannot be set directly', 'F2 next-stage operator cannot void a verified record');
  perform t.fails('update public.footprints set lot_closed = true where id = ' || fp, 'set by the server', 'F2 next-stage operator cannot close a verified lot by hand');
  perform t.fails($q$update public.footprints set status = 'pending' where id = $q$ || fp, 'cannot be set directly', 'F2 a verified record cannot be set back to pending');

  -- server paths that change lot_closed and status are untouched: QC takes the whole lot (auto-close), the sealer seals
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":157.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.ok((select lot_closed from public.footprints where id = p), 'auto-close still works when an operator''s record takes the whole lot');
  perform t.as_user(t.u('07'));
  perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload) values (t.scope('01'), c, 'qr_activation', q, t.u('07'), '{}')
  returning id into qr;
  seal := app.seal_lot(qr);
  perform t.ok(seal.qr_code like 'GV-%' and (select lot_closed and status = 'verified' from public.footprints where id = qr), 'seal by the QR operator still works (it closes and verifies the QR record in server code)');
  perform t.as_service();
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Corrections that would leave derived rows behind: QC verdict, grade lots, batch sources; farmer swap
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare p uuid; q uuid; s uuid; g uuid; ga uuid; r public.footprints; n int; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  -- F4: QC
  p := t.procure(t.scope('01'), t.farmer('01'), 150, 1, 2.5, 12.1, 12.1, 12.1);
  perform t.as_user(t.u('06')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.5,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.fails(format($q$update public.footprints set payload = '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":14.5,"broken_pct":2,"foreign_matter_pct":0.2}}' where id = %L$q$, q),
                  'cannot be corrected after saving', 'F4 a saved QC record cannot be corrected (its verdict was derived from the first readings)');
  perform t.ok((select (f.payload->'readings'->>'moisture_pct')::numeric = (v.readings->>'moisture_pct')::numeric
                  from public.footprints f join public.qc_verdicts v on v.footprint_id = f.id where f.id = q),
               'F4 the readings in the record and in its verdict are the same');

  -- F6: farmer swap on a pending procurement lot
  perform t.as_service();
  insert into public.farmers (id, client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000598', c, 'draft', 'Not Verified', 'G', 'V', 'D', '+919000004321', 1);
  p := t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
  perform t.as_user(t.u('05'));
  perform t.fails(format($q$update public.footprints set farmer_id = '00000000-0000-4000-8000-000000000598' where id = %L$q$, p),
                  'active farmer of this client', 'F6 a correction cannot swap in a farmer who is not verified');
  update public.footprints set farmer_id = t.farmer('02') where id = p returning * into r;
  perform t.ok(r.farmer_id = t.farmer('02'), 'a correction to another verified farmer still works');
  perform t.fails(format('update public.footprints set split_into_grades = true where id = %L', p), 'only a grading run', 'F5 only a grading run can carry the split flag (update)');
  perform t.fails($q$insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, split_into_grades)
                     values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('02'), t.u('05'),
                             '{"gross_kg":50,"bags":1,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', true)$q$, 'only a grading run', 'F5 only a grading run can carry the split flag (insert)');

  -- F5: grading
  perform t.as_service();
  p := t.procure(t.scope('02'), t.farmer('03'), 180, 1, 2, 12.4, 12.3, 12.5);
  perform t.verify(p, t.u('09'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), c, 'sorting', p, t.u('09'), '{"input_kg":178,"reject_kg":6,"loss_kg":2,"reject_reasons":[{"reason":"discoloured","kg":6}]}') returning id into s;
  perform t.verify(s, t.u('10'));
  perform t.as_user(t.u('10'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, split_into_grades)
  values (t.scope('02'), c, 'grading', s, t.u('10'), '{"input_kg":170,"grade_a_kg":100,"grade_b_kg":50,"grade_c_kg":15,"reject_kg":3,"loss_kg":2}', true) returning id into g;
  -- Since migration 24 the save has already made lots A, B and C. A manager withdraws A and B, so 150 kg of the run is
  -- unallocated again and the rules on a grade lot sent straight to the API are what refuses (not "exceeds available").
  perform t.as_user(t.u('03'));
  perform app.withdraw_footprint((select id from public.footprints where prev_footprint_id = g and grade = 'A'), 'test: lot A withdrawn');
  perform app.withdraw_footprint((select id from public.footprints where prev_footprint_id = g and grade = 'B'), 'test: lot B withdrawn');
  perform t.as_user(t.u('10'));
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
                            values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', %L, t.u('10'), '{"qty_kg":150}', true, 'A')$q$, g),
                  'exactly what the run graded as A (100 kg)', 'F5 a grade A lot cannot carry more than the run graded as A');
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
                            values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', %L, t.u('10'), '{"qty_kg":40}', true, 'B')$q$, g),
                  'exactly what the run graded as B (50 kg)', 'F5 nor less');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
  values (t.scope('02'), c, 'grading', g, t.u('10'), '{"qty_kg":50}', true, 'B');
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
                            values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', %L, t.u('10'), '{"qty_kg":50}', true, 'B')$q$, g),
                  'already has a grade B lot', 'F5 a second grade B lot of the same run is refused (100 kg were still unallocated)');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
  values (t.scope('02'), c, 'grading', g, t.u('10'), '{"qty_kg":100}', true, 'A');
  perform t.ok((select count(*) = 3 and sum(qty_out) = 165 from public.footprints where prev_footprint_id = g and is_grade_lot and status <> 'superseded'),
               'the three grade lots that match the split are accepted (165 kg)');
  select id into ga from public.footprints where prev_footprint_id = g and grade = 'A' and status <> 'superseded';
  perform t.fails(format($q$update public.footprints set payload = '{"qty_kg":500}' where id = %L$q$, ga),
                  'cannot be corrected after saving', 'F5 a pending grade lot cannot be corrected to another quantity');
  perform t.fails(format($q$update public.footprints set payload = '{"input_kg":170,"grade_a_kg":10,"grade_b_kg":50,"grade_c_kg":105,"reject_kg":3,"loss_kg":2}' where id = %L$q$, g),
                  'cannot be corrected after saving', 'F5 a split run cannot be corrected under its grade lots');
  perform t.as_service();
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. A correction recomputes whether the source lot is closed
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare p uuid; q uuid; m uuid; c1 uuid; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('03'), t.farmer('05'), 126, 3, 2, 11.8, 11.8, 11.8);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'qc', p, t.u('06'), '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.verify(q, t.u('08'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'milling', q, t.u('08'), '{"input_kg":119,"rice_kg":80,"bran_kg":30,"loss_kg":9}') returning id into m;
  perform t.verify(m, t.u('11'));
  perform t.as_user(t.u('11'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'commercial', m, t.u('11'), '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":80}') returning id into c1;
  perform t.ok((select lot_closed from public.footprints where id = m), 'an allocation of all 80 kg closes the milled lot');
  update public.footprints set payload = '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":50}' where id = c1;
  perform t.ok(not (select lot_closed from public.footprints where id = m) and app.available_qty(m) = 30,
               'corrected to 50 kg: the milled lot is open again with 30 kg on it (before: it stayed closed)');
  update public.footprints set payload = '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":79}' where id = c1;
  perform t.ok((select lot_closed from public.footprints where id = m), 'corrected to 79 kg: 1 kg left is under the 2 kg limit, the lot closes again');
  perform t.as_service();
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Withdrawing a wrong record (F7): managers only, reason, leaf records only, never sealed; replacement linked
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare p uuid; q uuid; q2 uuid; qr uuid; r public.footprints; seal public.qr_seals; blocks int; a uuid; b uuid; vb uuid;
        c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('01'), t.farmer('01'), 150, 1, 2.5, 12.1, 12.1, 12.1);
  perform t.as_user(t.u('06')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":21.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.ok((select lot_closed from public.footprints where id = p), 'the QC record took the whole lot: the procurement lot is closed');

  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q, 'typed 21.1 instead of 12.1'), 'only a manager', 'F7 an operator cannot withdraw a record, not even his own');
  perform t.as_user(t.u('04'));
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q, 'x'), 'only a manager', 'F7 Client View cannot withdraw');
  perform t.as_user(t.u('12'));
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q, 'x'), 'record not found', 'F7 another client''s user cannot even find it');
  perform t.as_user(t.u('03'));
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q, '  '), 'reason is required', 'F7 a reason is mandatory');
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', p, 'wrong weight'), 'withdraw those first', 'F7 a record with later records built on it cannot be withdrawn');
  select count(*) into blocks from public.ledger where footprint_id = q;
  r := app.withdraw_footprint(q, 'typed 21.1 instead of 12.1');
  perform t.ok(r.status = 'superseded', 'F7 the Client Manager withdraws the wrong QC record');
  perform t.ok((select reason = 'typed 21.1 instead of 12.1' and withdrawn_by = t.u('03') from public.withdrawals where footprint_id = q), 'F7 who and why are recorded');
  perform t.ok((select array_agg(event::text order by seq) from public.ledger where footprint_id = q and seq > (select max(seq) - 2 from public.ledger)) = array['supersede', 'supervisory']
               and (select payload->>'reason' from public.ledger where footprint_id = q order by seq desc limit 1) = 'typed 21.1 instead of 12.1',
               'F7 the withdrawal is two ledger blocks: the record as withdrawn, and the supervisory act with its reason');
  perform t.ok(not (select lot_closed from public.footprints where id = p) and app.available_qty(p) = 147.5, 'F7 the procurement lot is open again with its 147.5 kg');
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q, 'again'), 'only a pending or verified record', 'F7 a withdrawn record cannot be withdrawn twice');

  -- the replacement is a normal new record that names the withdrawn one
  perform t.as_user(t.u('06'));
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, supersedes_id)
       values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', %L, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}', %L)$q$, p, p),
       'withdrawn record of the same stage', 'F7 supersedes_id must name a withdrawn record of the same stage');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, supersedes_id)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}', q) returning id into q2;
  perform t.ok((select supersedes_id from public.footprints where id = q2) = q and (select export_verdict from public.qc_verdicts where footprint_id = q2) = 'fail'
               and (select domestic_verdict from public.qc_verdicts where footprint_id = q2) = 'pass',
               'F7 the replacement is linked to the withdrawn record and carries its own verdict (12.1%: domestic pass, export fail)');
  -- one replacement per withdrawn record (shown on a first-stage record, where nothing else limits a second one)
  perform t.as_service();
  a := t.procure_as(t.scope('01'), t.farmer('03'), t.u('05'));
  perform t.as_user(t.u('03')); perform app.withdraw_footprint(a, 'recorded twice by mistake');
  perform t.as_user(t.u('05'));
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, supersedes_id)
  values (t.scope('01'), c, 'procurement', t.farmer('03'), t.u('05'), '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', a);
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, supersedes_id)
       values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('03'), t.u('05'), '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', %L)$q$, a),
       'already has a replacement', 'F7 a withdrawn record gets one replacement only');

  -- sealed lots are final
  perform t.as_user(t.u('07')); perform app.verify_footprint(q2);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload) values (t.scope('01'), c, 'qr_activation', q2, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr);
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', qr, 'x'), 'sealed lot cannot be withdrawn', 'F7 a sealed lot cannot be withdrawn, even by the admin');
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', q2, 'x'), 'withdraw those first', 'F7 nor any record behind a sealed lot');

  -- a withdrawn Village Batch gives its farmer lots back
  perform t.as_service();
  a := t.procure(t.scope('06'), t.farmer('01'), 126, 3, 2, 12, 12, 12);
  b := t.procure(t.scope('06'), t.farmer('04'), 166, 2, 2, 12, 12, 12);
  perform t.as_user(t.u('15')); perform app.verify_footprint(a); perform app.verify_footprint(b);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('06'), c, 'village_batch', a, t.u('15'), jsonb_build_object('village', 'Bansi', 'source_footprint_ids', jsonb_build_array(a, b))) returning id into vb;
  perform t.fails(format($q$update public.footprints set payload = payload || '{"village":"Elsewhere"}' where id = %L$q$, vb), 'cannot be corrected after saving', 'a saved Village Batch cannot be corrected in place');
  perform t.as_user(t.u('03'));
  perform t.fails(format('select app.withdraw_footprint(%L, %L)', b, 'x'), 'withdraw those first', 'F7 a farmer lot inside a batch cannot be withdrawn (not only the first source)');
  perform app.withdraw_footprint(vb, 'wrong farmer lot in the batch');
  perform t.ok((select bool_and(not lot_closed) from public.footprints where id in (a, b)), 'F7 withdrawing the batch reopens both farmer lots');
  perform t.as_service();
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Scopes (S1)
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare s1 text := quote_literal(t.scope('01')); r public.scopes;
begin
  perform t.as_user(t.u('03'));
  perform t.fails('update public.scopes set status = ''draft'' where id = ' || s1, 'cannot go back to draft', 'S1 an active scope cannot be put back to draft (then re-chained)');
  perform t.fails($q$update public.scopes set tolerances = '{"auto_close_kg":500}' where id = $q$ || s1, 'frozen after activation', 'S1 tolerances are frozen after activation');
  perform t.fails('update public.scopes set geography = ''Moved'' where id = ' || s1, 'frozen after activation', 'S1 the place of an active scope cannot be renamed');
  update public.scopes set created_at = now() - interval '99 days', activated_at = now() - interval '99 days' where id = t.scope('01') returning * into r;
  perform t.ok(r.created_at > now() - interval '98 days' and r.activated_at > now() - interval '98 days', 'S1 a scope''s creation and activation times cannot be back-dated');
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, status, created_at, activated_at)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'KH26', 'Guard test', '{procurement,qc,qr_activation}', 'draft',
          now() - interval '50 days', now() - interval '50 days') returning * into r;
  perform t.ok(r.created_at = now() and r.activated_at is null, 'S1 a new draft cannot arrive back-dated or pre-activated');
  update public.scopes set status = 'active', activated_at = now() - interval '50 days' where id = r.id returning * into r;
  perform t.ok(r.status = 'active' and r.activated_at = now(), 'S1 activation is stamped by the server');
  update public.scopes set status = 'closed' where id = r.id returning * into r;
  perform t.ok(r.status = 'closed', 'closing a scope at season end still works');
  perform t.as_service();
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Farmers (R1): drafts belong to the field; after submission only a State Manager changes a farmer; ledger
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare f1 text := quote_literal(t.farmer('01')); d uuid; r public.farmers; b jsonb;
begin
  perform t.as_user(t.u('05'));
  perform t.fails('update public.farmers set name = ''Someone Else'', village = ''Elsewhere'' where id = ' || f1, 'only a State Manager', 'R1 a procurement operator cannot rename a verified farmer');
  perform t.fails('update public.farmers set photo_consent = true where id = ' || f1, 'only a State Manager', 'R1 nor switch photo consent on');
  perform t.fails('update public.farmers set status = ''inactive'' where id = ' || f1, 'only a State Manager', 'R1 nor deactivate him');
  perform t.fails('update public.farmers set status = ''draft'' where id = ' || f1, 'only a State Manager', 'R1 nor send him back to draft');
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, created_at)
  values ('00000000-0000-4000-8000-000000000201', 'draft', 'Naya Kisan', 'Shri Ram', 'Itwa', 'Siddharthnagar', '+919000001234', 1.2, now() - interval '99 days') returning * into r;
  d := r.id;
  perform t.ok(r.created_at = now(), 'R1 a new farmer cannot be back-dated');
  update public.farmers set village = 'Bansi', photo_consent = true where id = d returning * into r;
  perform t.ok(r.village = 'Bansi' and r.photo_consent, 'the operator still edits his own draft, consent included');
  perform app.submit_farmer(d);
  perform t.fails(format('update public.farmers set village = ''Changed after submit'' where id = %L', d), 'only a State Manager', 'R1 a submitted farmer is not edited by the operator while it waits for verification');
  perform t.as_user(t.u('03'));
  perform t.fails('update public.farmers set name = ''Someone Else'' where id = ' || f1, 'only a State Manager', 'R1 a Client Manager cannot rename a verified farmer either');

  perform t.as_user(t.u('02'));
  update public.farmers set status = 'active', verified_by = t.u('02'), verified_at = now() - interval '60 days', created_at = now() - interval '99 days' where id = d returning * into r;
  perform t.ok(r.status = 'active' and r.farmer_code is not null and r.verified_at = now() and r.created_at = now(), 'R1 the State Manager verifies; verification cannot be back-dated');
  perform t.as_service();
  select payload into b from public.ledger order by seq desc limit 1;
  perform t.ok(b->>'kind' = 'farmer_verified' and b->>'name' = 'Naya Kisan' and b->>'village' = 'Bansi' and b->>'farmer_code' = r.farmer_code and not (b::text like '%9000001234%'),
               'R1 a farmer''s verification is a ledger block with the verified name and village, without the phone');
  perform t.as_user(t.u('02'));
  update public.farmers set name = 'Naya Kisan Yadav', phone = '+919000005678' where id = d;
  perform t.as_service();
  select payload into b from public.ledger order by seq desc limit 1;
  perform t.ok(b->>'kind' = 'farmer_changed' and b->'before'->>'name' = 'Naya Kisan' and b->'after'->>'name' = 'Naya Kisan Yadav' and b->'after'->>'phone' = 'changed'
               and not (b::text like '%9000005678%') and (select actor from public.ledger order by seq desc limit 1) = t.u('02'),
               'R1 a later change to a verified farmer is a ledger block: before, after, who (phone: only that it changed)');
  perform t.as_user(t.u('02'));
  update public.farmers set status = 'inactive' where id = d;
  perform t.as_service();
  perform t.ok((select payload->'after'->>'status' from public.ledger order by seq desc limit 1) = 'inactive', 'R1 deactivating a verified farmer is ledgered too');
  perform t.ok(not exists (select 1 from app.verify_ledger()), 'the ledger chain verifies with farmer blocks in it');
end $$;
rollback;

-- ---------------------------------------------------------------------------------------------------------------
-- 7. Flags (L1), evidence (A1), verdict and user timestamps
-- ---------------------------------------------------------------------------------------------------------------
begin;
select t.as_service();
do $$
declare p uuid; q uuid; fl uuid; r public.flags; a public.attachments; good text; b jsonb; n int; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('01'), t.farmer('01'), 150, 1, 2.5, 12.1, 12.1, 12.1);
  perform t.as_user(t.u('06')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  insert into public.flags (footprint_id, raised_by, text, status, created_at) values (p, t.u('06'), 'bags looked wet', 'resolved', now() - interval '9 days') returning * into r;
  fl := r.id;
  perform t.ok(r.status = 'open' and r.created_at = now(), 'L1 a flag is born open, now: it cannot arrive resolved or back-dated');
  update public.flags set status = 'resolved' where id = fl;
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'an operator cannot resolve a flag (0 rows: managers only)');

  perform t.as_user(t.u('04'));
  insert into public.flags (footprint_id, raised_by, text) values (p, t.u('04'), 'buyer asks: which village?') returning * into r;
  perform t.ok(r.status = 'open', 'Client View may raise a query (PRD §4: flags are universal)');

  perform t.as_user(t.u('03'));
  perform t.fails(format('update public.flags set text = ''nothing wrong'' where id = %L', fl), 'cannot be edited', 'L1 a manager cannot rewrite the text of a flag');
  perform t.fails(format('update public.flags set raised_by = %L where id = %L', t.u('05'), fl), 'cannot be edited', 'L1 nor who raised it');
  perform t.fails(format('update public.flags set created_at = now() - interval ''9 days'' where id = %L', fl), 'cannot be edited', 'L1 nor when');
  perform t.fails(format('update public.flags set footprint_id = %L where id = %L', q, fl), 'cannot be edited', 'L1 nor move it to another record');
  update public.flags set status = 'dismissed' where id = fl returning * into r;
  perform t.as_service();
  select payload into b from public.ledger order by seq desc limit 1;
  perform t.ok(r.status = 'dismissed' and b->>'act' = 'flag_dismissed' and b->>'text' = 'bags looked wet'
               and (select event = 'supervisory' and actor = t.u('03') and footprint_id = p from public.ledger order by seq desc limit 1),
               'L1 a manager changing a flag''s status is a supervisory block in the ledger');

  -- evidence
  good := format('%s/%s/%s/photo.jpg', c, t.scope('01'), p);
  perform t.as_user(t.u('06'));
  perform t.fails(format($q$insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by) values (%L, 'photo', 'some/other/path.jpg', %L, %L)$q$, p, repeat('a', 64), t.u('06')),
                  'evidence path must be', 'A1 evidence cannot be registered with a path outside its record, even by inserting the row directly');
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by, created_at) values (p, 'photo', good, repeat('A', 64), t.u('06'), now() - interval '9 days') returning * into a;
  perform t.ok(a.created_at = now() and a.sha256 = repeat('a', 64), 'A1 evidence cannot be back-dated');
  perform t.fails(format($q$select app.register_attachment(%L, 'photo', %L, %L)$q$, p, good, repeat('b', 64)), 'attachments_storage_path_key', 'A1 the same file cannot be registered twice with another fingerprint');
  perform t.fails(format('update public.attachments set sha256 = %L where id = %L', repeat('b', 64), a.id), 'permission denied', 'A1 an evidence fingerprint cannot be rewritten');

  -- timestamps on verdicts and users
  perform t.as_user(t.u('03'));
  update public.qc_verdicts set created_at = now() - interval '9 days' where footprint_id = q;
  update public.app_users set created_at = now() - interval '99 days' where id = t.u('05');
  perform t.as_service();
  perform t.ok((select created_at = now() from public.qc_verdicts where footprint_id = q), 'a QC verdict cannot be back-dated');
  perform t.ok((select created_at > now() - interval '98 days' from public.app_users where id = t.u('05')), 'a user row cannot be back-dated');
  perform t.as_user(t.u('03'));
  perform t.fails(format($q$insert into public.qc_verdicts (footprint_id, domestic_verdict, export_verdict) values (%L, 'pass', 'pass')$q$, p), 'permission denied', 'verdict rows are written by the QC save only');
  perform t.as_service();
end $$;
rollback;
