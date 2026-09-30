-- Phase 3 server pieces: nightly ledger check (catches a hand-altered payload_hash), idempotent offline sync
-- (client_ref), lot trace for export (managers / client view only; walks every batch source), 500-lot performance.
begin;
select t.as_service();

-- 1 · ledger check -----------------------------------------------------------------------------------------------
do $$
declare r public.ledger_checks; bad bigint;
begin
  r := app.run_ledger_check('test');
  perform t.ok(r.ok and r.blocks > 0 and r.first_bad_seq is null, 'ledger check: clean chain recorded as ok (' || r.blocks || ' blocks)');
  perform t.as_user(t.u('03'));
  perform t.fails($q$ select app.run_ledger_check('manual') $q$, 'permission denied', 'ledger check: a Client Manager cannot run it (service role only)');
  perform t.ok((select count(*) from public.ledger_checks) >= 1, 'ledger check: a Client Manager can read the results');
  perform t.fails($q$ insert into public.ledger_checks (blocks, ok) values (1, true) $q$, 'permission denied', 'ledger check: nobody can write a fake result');
  perform t.as_user(t.u('05'));
  perform t.ok((select count(*) from public.ledger_checks) = 0, 'ledger check: operators do not see the results');
  perform t.as_service();

  -- Tamper the way only a database superuser could: bypass the ledger guard and alter one payload_hash.
  select max(seq) - 3 into bad from public.ledger;
  set local session_replication_role = replica;
  update public.ledger set payload_hash = repeat('0', 64) where seq = bad;
  set local session_replication_role = origin;
  r := app.run_ledger_check('test');
  perform t.ok(not r.ok and r.first_bad_seq = bad and r.problem = 'payload_hash mismatch',
               'ledger check: a hand-altered payload_hash is caught at block ' || bad);
end $$;
rollback;

begin;
select t.as_service();
-- 2 · offline sync is idempotent and keeps capture order ----------------------------------------------------------
do $$
declare s uuid := '00000000-0000-4000-8000-000000000405'; c uuid := '00000000-0000-4000-8000-000000000201';
        refs uuid[] := array[]::uuid[]; codes text[]; i int; ref uuid;
begin
  perform t.as_user(t.u('05'));
  for i in 1..10 loop
    ref := gen_random_uuid(); refs := refs || ref;
    insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, client_ref, payload)
    values (s, c, 'procurement', t.farmer('0' || (1 + i % 5)), t.u('05'), ref,
            jsonb_build_object('gross_kg', 100 + i, 'bags', 1, 'tare_kg_per_bag', 1, 'moisture_pct', jsonb_build_array(12, 12, 12)));
  end loop;
  select array_agg(footprint_code order by array_position(refs, client_ref)) into codes
    from public.footprints where client_ref = any(refs);
  perform t.ok(array_length(codes, 1) = 10, 'offline: 10 queued lots synced');
  perform t.ok((select bool_and(right(codes[k], 4)::int = right(codes[1], 4)::int + k - 1) from generate_series(1, 10) k),
               'offline: codes run in capture order with no gaps (' || codes[1] || ' … ' || codes[10] || ')');
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, client_ref, payload)
     values ('00000000-0000-4000-8000-000000000405', '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'), %L,
             '{"gross_kg":101,"bags":1,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') $q$, refs[1]),
     'footprints_client_ref_key', 'offline: a retried sync of the same lot is refused, not duplicated');
  perform t.ok((select count(*) from public.footprints where client_ref = refs[1]) = 1, 'offline: still exactly one lot for that client_ref');
  perform t.as_service();
end $$;
rollback;

begin;
select t.as_service();
-- 3 · lot trace ----------------------------------------------------------------------------------------------------
do $$
declare s uuid := '00000000-0000-4000-8000-000000000406'; c uuid := '00000000-0000-4000-8000-000000000201';
        a uuid; b uuid; vb uuid; q uuid; j jsonb;
begin
  a := t.procure(s, t.farmer('01'), 126, 3, 2, 12, 12, 12);
  b := t.procure(s, t.farmer('04'), 166, 2, 2, 12, 12, 12);
  perform t.as_user(t.u('15'));
  perform app.verify_footprint(a); perform app.verify_footprint(b);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'village_batch', a, t.u('15'), jsonb_build_object('village', 'Bansi', 'source_footprint_ids', jsonb_build_array(a, b)))
  returning id into vb;
  perform t.as_user(t.u('06')); perform app.verify_footprint(vb);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', vb, t.u('06'), '{"qty_kg":282,"sample_qty_kg":1,"readings":{"moisture_pct":12,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;

  perform t.as_user(t.u('06'));
  perform t.fails(format('select app.lot_trace(%L)', q), 'not allowed', 'trace: an operator cannot trace a whole lot');
  perform t.as_user(t.u('12'));
  perform t.fails(format('select app.lot_trace(%L)', q), 'not allowed', 'trace: another client''s user cannot trace it');
  perform t.as_user(t.u('04'));
  j := app.lot_trace(q);
  perform t.ok(jsonb_array_length(j->'steps') = 4, 'trace: Client View gets both farmer lots, the batch and QC (4 steps)');
  perform t.as_user(t.u('03'));
  j := app.lot_trace(q);
  perform t.ok((select count(*) from jsonb_array_elements(j->'steps') e where e->'farmer' is not null and e->'farmer' <> 'null'::jsonb) = 2,
               'trace: both farmers of the batch are named');
  perform t.ok((select bool_and(jsonb_array_length(e->'ledger') >= 1) from jsonb_array_elements(j->'steps') e),
               'trace: every step carries its ledger blocks');
  perform t.ok((select e->'qc'->>'export' from jsonb_array_elements(j->'steps') e where e->>'stage' = 'qc') is not null,
               'trace: QC verdict included');
  perform t.ok(j->'steps'->0->>'created_by' is not null, 'trace: who recorded each step is named');
  perform t.as_service();
end $$;
rollback;

begin;
select t.as_service();
-- 4 · performance: a 500-lot scope ------------------------------------------------------------------------------------
do $$
declare s uuid := '00000000-0000-4000-8000-000000000405'; t0 timestamptz; ms numeric; n int;
begin
  for n in 1..500 loop perform t.procure(s, t.farmer('0' || (1 + n % 5)), 100 + n % 50, 1, 1, 12, 12, 12); end loop;
  analyze public.footprints;
  perform t.as_user(t.u('06'));
  t0 := clock_timestamp();
  select count(*) into n from app.incoming_records(s, 'qc');
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform t.ok(n >= 500 and ms < 1000, format('performance: incoming list for a 500-lot scope in %s ms (< 1000)', round(ms)));
  perform t.as_user(t.u('03'));
  t0 := clock_timestamp();
  perform * from app.pipeline_summary(s);
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform t.ok(ms < 1000, format('performance: pipeline summary for a 500-lot scope in %s ms (< 1000)', round(ms)));
  t0 := clock_timestamp();
  perform count(*) from public.footprints where scope_id = s;
  ms := extract(epoch from clock_timestamp() - t0) * 1000;
  perform t.ok(ms < 1000, format('performance: season export read (RLS) for a 500-lot scope in %s ms (< 1000)', round(ms)));
  perform t.as_service();
end $$;
rollback;
