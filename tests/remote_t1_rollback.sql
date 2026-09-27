-- REMOTE T1 CHECK, rolled back: Procurement → QC → QR seal on the LIVE Supabase project, then undone.
-- Execution plan, workstream B step 4. tests/remote_smoke.sql only proves app.seal_lot exists; this proves it seals a
-- real chain. (Migration 7 installed a seal_lot that refused every real chain; migration 8 restored it. This catches that.)
--
-- Run with any of (one statement does the work, so no psql-only commands and nothing to carry across a ROLLBACK):
--   supabase db query --linked -f tests/remote_t1_rollback.sql
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f tests/remote_t1_rollback.sql      (session connection, port 5432)
--   Dashboard → SQL Editor (paste the whole file)
-- Needs migrations 1–8 and both seeds (scope 01, Sita Devi, users 05/06/07). Run it while nobody else is writing to the
-- project: the last checks compare row counts and the ledger tip before and after.
--
-- How it leaves nothing behind: the whole chain runs inside a PL/pgSQL exception block (a savepoint). At the end it raises
-- a private error (SQLSTATE GV001) that only its own handler catches, which rolls back to the savepoint. Any failed
-- assertion is a different error and aborts the whole statement, which also writes nothing. Only ledger.seq numbers are
-- used up (sequences are not transactional); app.verify_ledger() walks in order, so the gap does not matter.
-- Same path as tests/05_chains.sql: no JWT, actors come from created_by / verified_by / p_sealer. Real logins are
-- workstream E (tests/remote_rls.mjs). run_local.sh also runs this file against the fresh local build as a self-test.
--
-- Pass = one result row: REMOTE T1 PASSED — sealed GV-…, public journey checked, rolled back, nothing left behind
-- Fail = an error whose message starts with ASSERTION FAILED (psql also prints an "ok …" NOTICE per passed check).

-- Session-only helpers (temp objects: gone when the connection closes).
create or replace function pg_temp.ok(cond boolean, name text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ASSERTION FAILED: %', name; end if;
  raise notice 'ok   %', name;
end $$;

-- Expect the statement to fail with a message containing p_like.
create or replace function pg_temp.fails(p_sql text, p_like text, name text) returns void language plpgsql as $$
declare msg text;
begin
  begin
    execute p_sql;
  exception when others then
    msg := sqlerrm;
    if msg ilike '%' || p_like || '%' then raise notice 'ok   % (refused: %)', name, left(msg, 90); return; end if;
    raise exception 'ASSERTION FAILED: % — refused for a different reason: %', name, msg;
  end;
  raise exception 'ASSERTION FAILED: % — statement was accepted', name;
end $$;

-- Everything T1 can write, plus the ledger tip.
create or replace function pg_temp.snapshot() returns text language sql as $$
  select concat_ws(' · ',
    'footprints '  || (select count(*) from public.footprints),
    'qc_verdicts ' || (select count(*) from public.qc_verdicts),
    'qr_seals '    || (select count(*) from public.qr_seals),
    'flags '       || (select count(*) from public.flags),
    'ledger '      || (select count(*) from public.ledger),
    'ledger tip '  || coalesce((select hash from public.ledger order by seq desc limit 1), 'none'),
    'counters '    || (select md5(coalesce(string_agg(c::text, '|' order by c::text), '')) from public.footprint_counters c))
$$;

create or replace function pg_temp.remote_t1_check() returns text language plpgsql as $$
declare
  scope01 constant uuid := '00000000-0000-4000-8000-000000000401';
  client  constant uuid := '00000000-0000-4000-8000-000000000201';
  sita    constant uuid := '00000000-0000-4000-8000-000000000502';
  proc_op constant uuid := '00000000-0000-4000-8000-000000000305';
  qc_op   constant uuid := '00000000-0000-4000-8000-000000000306';
  qr_op   constant uuid := '00000000-0000-4000-8000-000000000307';
  v_before text := pg_temp.snapshot();
  p uuid; q uuid; qr uuid; seal public.qr_seals; v_code text; j jsonb;
begin
  -- Preconditions: the live seed is the one T1 was written against.
  perform pg_temp.ok((select status = 'active' and array_to_string(chain, ',') = 'procurement,qc,qr_activation'
                        from public.scopes where id = scope01),
                     'pre: scope 01 is active with chain procurement → qc → qr_activation');
  perform pg_temp.ok(exists (select 1 from public.farmers where id = sita and status = 'active'), 'pre: Sita Devi is an active farmer');

  begin  -- savepoint: everything in here is undone by the GV001 raise at the end
    -- 1. Procurement: Sita Devi, 150 kg gross, 1 bag, 2.5 kg tare. client_id is left to the trigger (AGENTS.md rule 3).
    insert into public.footprints (scope_id, stage_type, farmer_id, created_by, payload)
    values (scope01, 'procurement', sita, proc_op,
            '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}')
    returning id into p;
    perform pg_temp.ok((select qty_in = 147.5 and qty_out = 147.5 from public.footprints where id = p),
                       'procurement: net 150 - 1 x 2.5 = 147.5 stamped as qty_in / qty_out');
    perform pg_temp.ok((select client_id from public.footprints where id = p) = client, 'procurement: client_id stamped from the scope');
    perform pg_temp.ok((select status from public.footprints where id = p) = 'pending', 'procurement: created pending');

    -- 2. Verification is by the receiving stage: the creator is refused, the QC technician verifies.
    perform pg_temp.fails(format($q$ update public.footprints set status = 'verified', verified_by = %L where id = %L $q$, proc_op, p),
                          'receiving stage', 'verify: procurement operator cannot verify own record');
    update public.footprints set status = 'verified', verified_by = qc_op where id = p;

    -- 3. QC: 147.5 kg, 0.5 kg sample → 147 forwarded; 11.9 % moisture passes both markets.
    insert into public.footprints (scope_id, stage_type, prev_footprint_id, created_by, payload)
    values (scope01, 'qc', p, qc_op,
            '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2},"lab_ref":"REMOTE-T1"}')
    returning id into q;
    perform pg_temp.ok((select qty_out from public.footprints where id = q) = 147, 'qc: qty_out = 147.5 - 0.5 sample = 147');
    perform pg_temp.ok((select domestic_verdict = 'pass' and export_verdict = 'pass' from public.qc_verdicts where footprint_id = q),
                       'qc: domestic PASS and export PASS derived (11.9 <= 13, 11.9 <= 12)');
    -- The state migration 7 mishandled: a fully consumed source is closed, and the seal must still pass over it.
    perform pg_temp.ok((select lot_closed from public.footprints where id = p), 'auto-close: procurement lot fully consumed by QC is closed');

    -- 4. QR: cannot activate on a pending QC; the QR operator verifies QC, then activates.
    perform pg_temp.fails(format($q$ insert into public.footprints (scope_id, stage_type, prev_footprint_id, created_by, payload)
                                     values (%L, 'qr_activation', %L, %L, '{}') $q$, scope01, q, qr_op),
                          'must be verified', 'qr: cannot activate on an unverified QC');
    update public.footprints set status = 'verified', verified_by = qr_op where id = q;
    insert into public.footprints (scope_id, stage_type, prev_footprint_id, created_by, payload)
    values (scope01, 'qr_activation', q, qr_op, '{}') returning id into qr;
    perform pg_temp.ok((select qty_out from public.footprints where id = qr) = 147, 'qr: footprint carries the final 147 kg');

    -- 5. Seal gate: an open flag blocks it; the wrong operator is refused.
    insert into public.flags (footprint_id, raised_by, text) values (p, qc_op, 'remote T1 check: gate test');
    perform pg_temp.fails(format($q$ select app.seal_lot(%L, %L) $q$, qr, qr_op), 'open flag', 'seal gate: open flag on an ancestor blocks sealing');
    update public.flags set status = 'resolved' where footprint_id = p;
    perform pg_temp.fails(format($q$ select app.seal_lot(%L, %L) $q$, qr, qc_op), 'only the assigned QR operator', 'seal gate: QC technician cannot seal');

    -- 6. The seal: the step the smoke check cannot see.
    begin
      seal := app.seal_lot(qr, qr_op);
    exception when others then
      raise exception 'ASSERTION FAILED: T1 seal refused on this project: %. If it mentions "another closed lot", migration 8 is not applied.', sqlerrm;
    end;
    v_code := seal.qr_code;
    perform pg_temp.ok(v_code like 'GV-%', 'seal: QR code minted ' || v_code);
    perform pg_temp.ok((select status from public.footprints where id = qr) = 'verified', 'seal: QR footprint verified by the seal');
    perform pg_temp.ok(exists (select 1 from public.ledger where footprint_id = qr and event = 'seal'), 'seal: seal block written to the ledger');
    perform pg_temp.ok((select count(*) from public.ledger where footprint_id in (p, q, qr)) >= 5, 'ledger: at least 5 blocks across the lot');
    perform pg_temp.ok(not exists (select 1 from app.verify_ledger()), 'ledger: whole chain still verifies with the new blocks');
    perform pg_temp.fails(format($q$ select app.seal_lot(%L, %L) $q$, qr, qr_op), 'already sealed', 'seal: cannot seal twice');
    perform pg_temp.fails(format($q$ delete from public.qr_seals where footprint_id = %L $q$, qr), 'immutable', 'seal: seal row cannot be deleted');

    -- 7. Public verify page as an anonymous visitor. Plain checks here: the temp helpers are not for anon.
    execute 'set local role anon';
    j := app.public_lot_journey(v_code);
    if j is null then raise exception 'ASSERTION FAILED: public: journey resolves for %', v_code; end if;
    if jsonb_array_length(j->'journey') <> 3 then
      raise exception 'ASSERTION FAILED: public: 3 steps (procurement, qc, qr), got %', jsonb_array_length(j->'journey'); end if;
    if j->'journey'->0->'farmer'->>'name' is distinct from 'Sita Devi' then raise exception 'ASSERTION FAILED: public: farmer name shown'; end if;
    if j->'journey'->0->'farmer' ? 'phone' then raise exception 'ASSERTION FAILED: public: farmer phone is exposed'; end if;
    if j->'verdict'->>'export' is distinct from 'pass' then raise exception 'ASSERTION FAILED: public: export PASS shown'; end if;
    if app.public_lot_journey('GV-DOESNOTEXIST') is not null then raise exception 'ASSERTION FAILED: public: unknown code returns null'; end if;
    begin
      perform count(*) from public.farmers;
      raise exception 'ASSERTION FAILED: public: anon can read the farmers table';
    exception when insufficient_privilege then null;
    end;
    execute 'reset role';
    perform pg_temp.ok(true, 'public: journey resolves as anon (3 steps, Sita Devi, no phone, export PASS); unknown code null; farmers table closed');

    raise exception 'undo the T1 check' using errcode = 'GV001';
  exception when sqlstate 'GV001' then
    null;  -- rolled back to the savepoint; assertion failures are other SQLSTATEs and propagate
  end;

  -- 8. Nothing left behind.
  perform pg_temp.ok(not exists (select 1 from public.footprints where id in (p, q, qr)), 'rollback: no T1 footprints remain');
  perform pg_temp.ok(not exists (select 1 from public.qr_seals where qr_code = v_code), 'rollback: ' || v_code || ' is not in qr_seals');
  perform pg_temp.ok(not exists (select 1 from public.ledger where footprint_id in (p, q, qr)), 'rollback: no ledger blocks for the T1 lot');
  if pg_temp.snapshot() is distinct from v_before then
    raise exception 'ASSERTION FAILED: rollback: rows changed, or another session wrote meanwhile. before: % | after: %', v_before, pg_temp.snapshot();
  end if;
  perform pg_temp.ok(true, 'rollback: row counts, ledger tip and footprint counters identical to before the run');

  return 'REMOTE T1 PASSED — sealed ' || v_code || ', public journey checked, rolled back, nothing left behind';
end $$;

select pg_temp.remote_t1_check() as result;
