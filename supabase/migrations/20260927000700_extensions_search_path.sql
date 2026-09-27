-- GrainVeda MVP · Phase 0 · migration 7: ensure pgcrypto / extensions in search_path for hashing & seals
-- Allows digest() to be found when pgcrypto lives in extensions schema (standard Supabase hosted setup).

create or replace function app.ledger_append(
  p_footprint uuid, p_scope uuid, p_event public.ledger_event, p_actor uuid, p_payload jsonb
) returns text
language plpgsql security definer set search_path = public, extensions, app as $$
declare v_prev text; v_phash text; v_hash text; v_ts timestamptz := clock_timestamp();
begin
  perform pg_advisory_xact_lock(hashtext('grainveda_ledger'));   -- serialise writers → unambiguous prev_hash
  select hash into v_prev from public.ledger order by seq desc limit 1;
  v_prev  := coalesce(v_prev, repeat('0', 64));
  v_phash := encode(digest(p_payload::text, 'sha256'), 'hex');
  v_hash  := encode(digest(v_prev || v_phash || coalesce(p_actor::text, '') || v_ts::text, 'sha256'), 'hex');
  insert into public.ledger (footprint_id, scope_id, event, actor, payload, payload_hash, prev_hash, hash, created_at)
  values (p_footprint, p_scope, p_event, p_actor, p_payload, v_phash, v_prev, v_hash, v_ts);
  return v_hash;
end $$;

create or replace function app.verify_ledger()
returns table (seq bigint, problem text)
language plpgsql stable security definer set search_path = public, extensions, app as $$
declare r record; v_prev text := repeat('0', 64); v_calc text;
begin
  for r in select * from public.ledger order by ledger.seq loop
    if r.prev_hash <> v_prev then
      return query select r.seq, 'prev_hash mismatch'; return;
    end if;
    if r.payload_hash <> encode(digest(r.payload::text, 'sha256'), 'hex') then
      return query select r.seq, 'payload_hash mismatch'; return;
    end if;
    v_calc := encode(digest(r.prev_hash || r.payload_hash || coalesce(r.actor::text, '') || r.created_at::text, 'sha256'), 'hex');
    if v_calc <> r.hash then
      return query select r.seq, 'hash mismatch'; return;
    end if;
    v_prev := r.hash;
  end loop;
  return;
end $$;

create or replace function app.seal_lot(p_qr_fp uuid, p_sealer uuid default null) returns public.qr_seals
language plpgsql security definer set search_path = public, extensions, app as $$
declare me uuid := coalesce(app.current_user_id(), p_sealer); qr public.footprints; cur public.footprints;
        hops int := 0; has_qc boolean := false; batch text[] := '{}'; v_hash text; seal public.qr_seals; v_code text;
        vd record;
begin
  select * into qr from public.footprints where id = p_qr_fp;
  if qr.id is null or qr.stage_type <> 'qr_activation' then raise exception 'not a qr_activation footprint' using errcode = 'P0002'; end if;
  if me is null or not app.is_my_stage(me, qr.scope_id, 'qr_activation') then
    raise exception 'only the assigned QR operator (or a gateway role) may seal' using errcode = '42501'; end if;
  if qr.status = 'verified' then raise exception 'already sealed' using errcode = '23505'; end if;

  -- Re-walk ancestor chain: every predecessor must be verified, unclosed, no open flags.
  cur := qr;
  while cur.prev_footprint_id is not null loop
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    if cur.id is null then raise exception 'broken predecessor chain' using errcode = '23503'; end if;
    if cur.status <> 'verified' then
      raise exception 'gate: unverified predecessor % %', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
    if cur.lot_closed and cur.id <> qr.prev_footprint_id then
      raise exception 'gate: predecessor % % is already part of another closed lot', cur.stage_type, cur.footprint_code using errcode = '23514'; end if;
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
