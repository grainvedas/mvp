-- Migration 29, part 1: the time a record was captured on the phone is kept with it (FIX_LIST item 8).
-- Before it, a record saved with no network was dated when it reached the server.
begin;
select t.as_service();

do $$
declare s uuid := t.scope('01'); c constant uuid := '00000000-0000-4000-8000-000000000201';
        pay constant jsonb := '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}';
        r public.footprints; x public.footprints; blk jsonb; q uuid; qr uuid; seal public.qr_seals; j jsonb; step jsonb;
        warn constant text := 'phone clock not plausible: server time used';
begin
  perform t.as_user(t.u('05'));
  -- sent at once: the phone gives no time
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (s, c, 'procurement', t.farmer('01'), t.u('05'), pay) returning * into x;
  perform t.ok(x.captured_at = x.created_at, 'capture time: a record sent at once carries the server''s time');

  -- kept on the phone for three days, then sent
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, captured_at)
  values (s, c, 'procurement', t.farmer('02'), t.u('05'), pay, now() - interval '3 days') returning * into r;
  perform t.ok(r.captured_at = r.created_at - interval '3 days' and r.created_at = now(),
               'capture time: a record that waited three days keeps the time it was captured; created_at is the server''s');
  perform t.ok(not (warn = any (r.warnings)), 'capture time: a plausible time draws no warning');
  perform t.as_service();
  select l.payload into blk from public.ledger l where l.footprint_id = r.id and l.event = 'create';
  perform t.ok((blk->>'captured_at')::timestamptz = r.captured_at, 'capture time: it is part of the record''s ledger block');
  perform t.as_user(t.u('05'));
  perform t.fails(format('update public.footprints set captured_at = now() where id = %L', r.id), 'set by the server',
                  'capture time: the person who saved it cannot change it afterwards');
  perform t.as_user(t.u('03'));
  perform t.fails(format('update public.footprints set captured_at = now() where id = %L', r.id), 'set by the server',
                  'capture time: nor can a manager');

  -- a phone clock two hours fast, a little fast, and far too old
  perform t.as_user(t.u('05'));
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, captured_at)
  values (s, c, 'procurement', t.farmer('03'), t.u('05'), pay, now() + interval '2 hours') returning * into x;
  perform t.ok(x.captured_at = x.created_at and warn = any (x.warnings), 'capture time: a time in the future is not believed: server time, with a warning on the record');
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, captured_at)
  values (s, c, 'procurement', t.farmer('04'), t.u('05'), pay, now() + interval '2 minutes') returning * into x;
  perform t.ok(x.captured_at = x.created_at and not (warn = any (x.warnings)), 'capture time: a clock two minutes fast: server time, no warning');
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, captured_at)
  values (s, c, 'procurement', t.farmer('05'), t.u('05'), pay, now() - interval '40 days') returning * into x;
  perform t.ok(x.captured_at = x.created_at and warn = any (x.warnings), 'capture time: older than 31 days is not believed: server time, with a warning');
  perform t.ok(x.qty_out = 98 and x.status = 'pending', 'capture time: the record itself is saved as usual (98 kg, pending)');

  -- the public page and the lot journey date the step by the capture time
  perform t.as_user(t.u('06')); perform app.verify_footprint(r.id);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', r.id, t.u('06'), '{"qty_kg":98,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.as_user(t.u('07')); perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr);
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  select e into step from jsonb_array_elements(j->'journey') e where e->>'stage' = 'procurement';
  perform t.ok((step->>'captured_at')::timestamptz = r.captured_at and (step->>'created_at')::timestamptz = r.created_at,
               'capture time: the public page is given the day the lot was bought, not the day it was sent');
  select e into step from jsonb_array_elements(j->'journey') e where e->>'stage' = 'qc';
  perform t.ok((step->>'captured_at')::timestamptz = (step->>'created_at')::timestamptz, 'capture time: a step recorded at once has the same two times');
  perform t.as_user(t.u('03'));
  j := app.lot_trace(qr);
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'steps') e where e->>'stage' = 'procurement' and (e->>'captured_at')::timestamptz = r.captured_at),
               'capture time: the lot journey for managers carries it');
  perform t.as_service();
end $$;

rollback;
