-- Migration 24: one act, one transaction.
-- Seal: a seal refused at the gate must leave nothing behind (the lot stays with the sealer and can be sealed once the
-- reason is fixed). Before it, the QR record of the refused attempt stayed and the lot was stuck.
-- Grading split: the grade lots are made by the save of the run; a run marked "split" without lots cannot exist.
begin;
select t.as_service();

do $$
declare p uuid; q uuid; n_fp bigint; n_led bigint; seal public.qr_seals; orphan uuid; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  insert into public.flags (footprint_id, raised_by, text) values (p, t.u('06'), 'bag count looked off on the truck');

  -- who may seal
  perform t.as_anon();
  perform t.fails(format('select app.seal_source(%L)', q), 'permission denied', 'seal: an anonymous visitor cannot call it');
  perform t.as_user(t.u('12'));
  perform t.fails(format('select app.seal_source(%L)', q), 'record not found', 'seal: another client''s operator cannot even name the lot');
  perform t.as_user(t.u('06'));
  perform t.fails(format('select app.seal_source(%L)', q), 'may not create at stage qr_activation', 'seal: the QC technician who tested the lot cannot seal it');
  perform t.as_user(t.u('04'));
  perform t.fails(format('select app.seal_source(%L)', q), 'may not create', 'seal: Client View cannot seal');

  -- the sealer, while the QC record is still unverified and a flag is open
  perform t.as_user(t.u('07'));
  perform t.fails(format('select app.seal_source(%L)', q), 'predecessor must be verified', 'seal: refused while the lot is not verified by the sealer');
  perform app.verify_footprint(q);
  perform t.as_service();
  select count(*) into n_fp from public.footprints; select count(*) into n_led from public.ledger;
  perform t.as_user(t.u('07'));
  perform t.fails(format('select app.seal_source(%L)', q), 'gate: open flag on procurement', 'seal: refused at the gate while a flag is open on the lot''s history');
  perform t.ok((select count(*) from app.incoming_records(t.scope('01'), 'qr_activation') r where r.id = q) = 1,
               'seal: after the refusal the lot is still waiting in the sealer''s list');
  perform t.as_service();
  perform t.ok((select count(*) from public.footprints) = n_fp and (select count(*) from public.ledger) = n_led
               and not (select lot_closed from public.footprints where id = q)
               and (select count(*) from public.footprints where prev_footprint_id = q) = 0,
               'seal: the refused attempt saved nothing: no QR record, no ledger block, the lot is not closed');

  -- the manager resolves the flag; the same sealer seals the same lot
  perform t.as_user(t.u('03'));
  update public.flags set status = 'resolved' where footprint_id = p;
  perform t.as_user(t.u('07'));
  seal := app.seal_source(q);
  perform t.ok(seal.qr_code like 'GV-%' and seal.sealed_by = t.u('07'), 'seal: once the flag is resolved the lot seals, by the sealer');
  perform t.as_service();
  perform t.ok((select f.status = 'verified' and f.lot_closed and f.created_by = t.u('07') and f.verified_by = t.u('07') and f.qty_out = 147
                  from public.footprints f where f.id = seal.footprint_id)
               and (select lot_closed from public.footprints where id = q)
               and (select count(*) from public.ledger l where l.footprint_id = seal.footprint_id and l.event = 'seal') = 1,
               'seal: one QR record (147 kg), verified and closed, the tested lot closed, one seal block in the ledger');
  perform t.ok(app.public_lot_journey(seal.qr_code) is not null, 'seal: the public page answers for the new code');
  perform t.as_user(t.u('07'));
  perform t.fails(format('select app.seal_source(%L)', q), 'closed', 'seal: a sealed lot cannot be sealed a second time');

  -- a QR record left behind by the old two-step path is finished with seal_lot (the record page offers it)
  perform t.as_service();
  p := t.procure(t.scope('01'), t.farmer('05'), 199, 2, 2, 11.8, 11.8, 11.8);
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qc', p, t.u('06'), '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  insert into public.flags (footprint_id, raised_by, text) values (q, t.u('06'), 'retest moisture');
  perform t.as_user(t.u('07'));
  perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c, 'qr_activation', q, t.u('07'), '{}') returning id into orphan;
  perform t.fails(format('select app.seal_lot(%L)', orphan), 'gate: open flag on qc', 'left-behind QR record: the old path refused at the gate after saving the record');
  perform t.ok((select count(*) from app.incoming_records(t.scope('01'), 'qr_activation') r where r.id = q) = 0,
               'left-behind QR record: the lot has left the sealer''s list (this is what migration 24 prevents)');
  perform t.as_user(t.u('03'));
  update public.flags set status = 'dismissed' where footprint_id = q;
  perform t.as_user(t.u('06'));
  perform t.fails(format('select app.seal_lot(%L)', orphan), 'only the assigned QR operator', 'left-behind QR record: the QC technician cannot finish it');
  perform t.as_user(t.u('07'));
  seal := app.seal_lot(orphan);
  perform t.ok(seal.qr_code like 'GV-%', 'left-behind QR record: the sealer finishes it from the record page once the flag is closed');
  perform t.as_service();
end $$;

-- Grading split: the grade lots are saved with the run, or nothing is --------------------------------------------------
do $$
declare p uuid; so uuid; g uuid; g2 uuid; n bigint; c constant uuid := '00000000-0000-4000-8000-000000000201';
begin
  p := t.procure(t.scope('02'), t.farmer('03'), 180, 1, 2, 12.4, 12.3, 12.5);
  perform t.as_user(t.u('09')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), c, 'sorting', p, t.u('09'), '{"input_kg":178,"reject_kg":6,"loss_kg":2,"reject_reasons":[{"reason":"discoloured","kg":6}]}') returning id into so;
  perform t.as_user(t.u('10')); perform app.verify_footprint(so);

  -- a run saved WITHOUT the split, then corrected to split: the correction makes the lots (before: nobody did)
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('02'), c, 'grading', so, t.u('10'), '{"input_kg":70,"grade_a_kg":40,"grade_b_kg":20,"grade_c_kg":0,"reject_kg":6,"loss_kg":4}') returning id into g;
  perform t.ok((select count(*) from public.footprints where prev_footprint_id = g) = 0, 'split: a run saved without the split has no grade lots');
  update public.footprints set split_into_grades = true where id = g;
  perform t.ok((select array_agg(grade order by grade) = array['A', 'B'] and array_agg(qty_out order by grade) = array[40, 20]::numeric[]
                  from public.footprints where prev_footprint_id = g and is_grade_lot),
               'split: correcting the pending run to "split" creates its lots (A 40, B 20; no empty C lot)');
  perform t.ok((select count(*) from public.ledger l join public.footprints f on f.id = l.footprint_id where f.prev_footprint_id = g and l.event = 'create') = 2,
               'split: each grade lot has its own ledger block');

  -- a run saved WITH the split: lots in the same transaction
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, split_into_grades)
  values (t.scope('02'), c, 'grading', so, t.u('10'), '{"input_kg":90,"grade_a_kg":60,"grade_b_kg":20,"grade_c_kg":5,"reject_kg":3,"loss_kg":2}', true) returning id into g2;
  perform t.ok((select count(*) = 3 and sum(qty_out) = 85 from public.footprints where prev_footprint_id = g2 and is_grade_lot),
               'split: a run saved with the split has its three lots at once (85 kg)');
  perform t.ok((select max(l.seq) from public.ledger l where l.footprint_id = g2 and l.event = 'create')
               < (select min(l.seq) from public.ledger l join public.footprints f on f.id = l.footprint_id where f.prev_footprint_id = g2),
               'split: the run''s ledger block comes before its lots''');
  perform t.as_user(t.u('06'));
  perform t.ok((select count(*) from app.incoming_records(t.scope('02'), 'qc')) = 5
               and not exists (select 1 from app.incoming_records(t.scope('02'), 'qc') r where r.id in (g, g2)),
               'split: QC sees the five grade lots and neither run (rule 8)');

  -- if a lot cannot be made, the run is not saved either
  perform t.as_service();
  select count(*) into n from public.footprints;
  alter table public.footprints add constraint t_no_grade_c check (grade is distinct from 'C') not valid;   -- new rows only: the next grade C lot fails
  perform t.as_user(t.u('10'));
  perform t.fails(format($q$insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, split_into_grades)
                            values (t.scope('02'), '00000000-0000-4000-8000-000000000201', 'grading', %L, t.u('10'),
                                    '{"input_kg":8,"grade_a_kg":4,"grade_b_kg":2,"grade_c_kg":1,"reject_kg":1,"loss_kg":0}', true)$q$, so),
                  't_no_grade_c', 'split: a refused grade lot refuses the whole save');
  perform t.as_service();
  alter table public.footprints drop constraint t_no_grade_c;
  perform t.ok((select count(*) from public.footprints) = n, 'split: nothing of the refused save remains (no run without lots)');
end $$;

rollback;
