-- GrainVeda demo journey on the STAGING project, scope 401 (procurement -> qc -> qr_activation).
-- The same steps and payloads as T1 in tests/remote_rls.mjs (Phase 3 level, which is what staging has), carried out as
-- the three demo operators by setting the caller inside one transaction: every rule, trigger and RLS policy applies.
-- __MODE__ = TRIAL: everything is rolled back and the result comes back in the error text. COMMIT: it is kept.
do $$
declare
  c_scope  constant uuid := '00000000-0000-4000-8000-000000000401';
  c_client constant uuid := '00000000-0000-4000-8000-000000000201';
  c_farmer constant uuid := '00000000-0000-4000-8000-000000000502';   -- Sita Devi, Itwa
  a305 constant uuid := '00000000-0000-4000-8000-000000000305';        -- Procurement operator
  a306 constant uuid := '00000000-0000-4000-8000-000000000306';        -- QC technician
  a307 constant uuid := '00000000-0000-4000-8000-000000000307';        -- QR sealer
  u305 uuid; u306 uuid; u307 uuid;
  v_proc public.footprints; v_qc public.footprints; v_qr public.footprints; v_seal public.qr_seals;
  v_self_verify text := 'ALLOWED'; v_wrong_seal text := 'ALLOWED';
  v_out jsonb;
begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then raise exception 'refused: this is the PRODUCTION project'; end if;
  end if;
  select auth_uid into strict u305 from public.app_users where id = a305;
  select auth_uid into strict u306 from public.app_users where id = a306;
  select auth_uid into strict u307 from public.app_users where id = a307;

  -- 1. Procurement operator records the farm-gate lot
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u305, 'role', 'authenticated')::text, true);
  set local role authenticated;
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (c_scope, c_client, 'procurement', c_farmer, a305,
          '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}'::jsonb)
  returning * into v_proc;
  begin perform app.verify_footprint(v_proc.id);                       -- the creator may not verify the own record
  exception when others then v_self_verify := 'refused: ' || sqlerrm; end;

  -- 2. QC technician verifies what arrived, then records the lab result
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u306, 'role', 'authenticated')::text, true);
  perform app.verify_footprint(v_proc.id);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (c_scope, c_client, 'qc', v_proc.id, a306,
          '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}'::jsonb)
  returning * into v_qc;

  -- 3. QR sealer verifies the lab record, records the QR stage, and seals
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u307, 'role', 'authenticated')::text, true);
  perform app.verify_footprint(v_qc.id);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (c_scope, c_client, 'qr_activation', v_qc.id, a307, '{}'::jsonb)
  returning * into v_qr;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u306, 'role', 'authenticated')::text, true);
  begin perform app.seal_lot(v_qr.id);                                  -- the QC technician may not seal
  exception when others then v_wrong_seal := 'refused: ' || sqlerrm; end;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', u307, 'role', 'authenticated')::text, true);
  v_seal := app.seal_lot(v_qr.id);

  reset role;
  perform set_config('request.jwt.claims', '', true);
  if v_self_verify = 'ALLOWED' or v_wrong_seal = 'ALLOWED' then
    raise exception 'a rule did not hold: self-verify %, wrong seal %', v_self_verify, v_wrong_seal;
  end if;

  v_out := jsonb_build_object(
    'records', (select jsonb_agg(jsonb_build_object(
        'code', f.footprint_code, 'stage', f.stage_type, 'status', f.status, 'qty_in', f.qty_in, 'qty_out', f.qty_out,
        'lot_closed', f.lot_closed, 'payload', f.payload, 'computed', f.computed, 'warnings', f.warnings,
        'by', (select display_name from public.app_users where id = f.created_by),
        'verified_by', (select display_name from public.app_users where id = f.verified_by)) order by d.sort_order)
      from public.footprints f join public.stage_definitions d on d.stage_type = f.stage_type
      where f.id in (v_proc.id, v_qc.id, v_qr.id)),
    'verdict', (select to_jsonb(q) - 'id' - 'footprint_id' from public.qc_verdicts q where q.footprint_id = v_qc.id),
    'seal', jsonb_build_object('qr_code', v_seal.qr_code, 'batch_codes', v_seal.batch_codes, 'ledger_hash', v_seal.ledger_hash),
    'public_page', app.public_lot_journey(v_seal.qr_code),
    'ledger', (select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event,
        'by', (select display_name from public.app_users where id = l.actor), 'hash', left(l.hash, 12)) order by l.seq)
      from public.ledger l where l.footprint_id in (v_proc.id, v_qc.id, v_qr.id)),
    'ledger_problems', (select count(*) from app.verify_ledger()),
    'rule_checks', jsonb_build_object('creator_verifies_own_record', v_self_verify, 'qc_technician_seals', v_wrong_seal));

  if '__MODE__' = 'COMMIT' then
    raise notice 'DEMO JOURNEY KEPT: %', v_seal.qr_code;
  else
    raise exception 'TRIAL %', v_out::text using errcode = 'GV001';
  end if;
end $$;
