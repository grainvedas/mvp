-- GrainVeda MVP · Phase 0 · migration 8: restore the tested seal_lot (migration 7 changed its logic while fixing search_path)
-- Migration 7 correctly added `extensions` to search_path (Supabase installs pgcrypto there) but also:
--   * added a rule that refuses sealing when any ancestor is lot_closed — wrong: auto-close marks a fully consumed
--     source as lot_closed by design (PRD §7), so every real chain would fail at the seal (tests/05_chains.sql T1);
--   * dropped the 'final quantity recorded' gate and the 64-hop loop guard;
--   * replaced the qr_seals existence check with a status check.
-- This migration re-installs the body verified by tests/05_chains.sql, keeping the search_path fix.

-- QR gate (isGate): re-walk the whole chain, then seal. Predecessor-agnostic: works after QC, Commercial or Shipment.
create or replace function app.seal_lot(p_qr_fp uuid, p_sealer uuid default null) returns public.qr_seals
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := coalesce(app.current_user_id(), p_sealer); qr public.footprints; cur public.footprints;
        hops int := 0; has_qc boolean := false; batch text[] := '{}'; v_hash text; seal public.qr_seals; v_code text;
        vd record;
begin
  select * into qr from public.footprints where id = p_qr_fp;
  if qr.id is null or qr.stage_type <> 'qr_activation' then raise exception 'not a qr_activation footprint' using errcode = 'P0002'; end if;
  if me is null or not app.is_my_stage(me, qr.scope_id, 'qr_activation') then
    raise exception 'only the assigned QR operator (or a gateway role) may seal' using errcode = '42501'; end if;
  if exists (select 1 from public.qr_seals where footprint_id = qr.id) then raise exception 'already sealed' using errcode = '23505'; end if;
  if qr.qty_out <= 0 then raise exception 'gate: final quantity not recorded' using errcode = '23514'; end if;

  -- Gate: every ancestor verified, no open flags, QC verdict present.
  cur := qr;
  while cur.prev_footprint_id is not null and hops < 64 loop
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    if cur.status <> 'verified' then
      raise exception 'gate: % % is not verified', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
    if exists (select 1 from public.flags fl where fl.footprint_id = cur.id and fl.status = 'open') then
      raise exception 'gate: open flag on % %', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
    if cur.stage_type = 'qc' then has_qc := true; end if;
    if cur.stage_type = 'packing' then batch := array_append(batch, cur.payload->>'batch_code'); end if;
    hops := hops + 1;
  end loop;
  if not has_qc then raise exception 'gate: no QC record behind this lot' using errcode = '23514'; end if;
  select * into vd from app.resolve_market_verdict(qr.id);
  if vd.domestic = 'pending' and vd.export = 'pending' then
    raise exception 'gate: QC verdict is pending' using errcode = '23514'; end if;

  -- Seal: the QR footprint is verified by the sealer (whole-chain re-walk is its verification), then the block is written.
  update public.footprints set status = 'verified', verified_by = me, verified_at = now() where id = qr.id and status = 'pending';
  update public.footprints set lot_closed = true where id = qr.id;
  v_code := 'GV-' || upper(substr(encode(digest(qr.id::text || clock_timestamp()::text, 'sha256'), 'hex'), 1, 12));
  v_hash := app.ledger_append(qr.id, qr.scope_id, 'seal', me,
    jsonb_build_object('footprint_id', qr.id, 'footprint_code', qr.footprint_code, 'qr_code', v_code,
                       'batch_codes', to_jsonb(batch), 'final_kg', qr.qty_out,
                       'domestic_verdict', vd.domestic, 'export_verdict', vd.export, 'override', vd.override));
  insert into public.qr_seals (footprint_id, qr_code, batch_codes, sealed_by, ledger_hash)
  values (qr.id, v_code, batch, me, v_hash) returning * into seal;
  return seal;
end $$;
