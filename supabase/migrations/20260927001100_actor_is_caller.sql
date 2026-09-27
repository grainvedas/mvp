-- GrainVeda MVP · Phase 0 · migration 11: the actor is the signed-in caller (execution plan, workstream H; PRD §4, §8)
-- Several rules checked the person NAMED in a row instead of the person signed in:
--   * footprints: a creator could verify their own record by writing verified_by = <the receiving operator>;
--   * seal_lot: a signed-in user with no app_users row fell back to p_sealer and could seal as the QR operator;
--   * farmers: an operator could activate a farmer by writing verified_by = <a State Manager>, and could write farmer_code;
--   * qc_verdicts: an override could name someone else as authoriser.
-- For signed-in callers (auth.uid() not null) the actor must now be the caller. The service role, seeds and the service
-- path of the tests are unchanged. Guard triggers are added beside the existing rules instead of re-pasting their bodies;
-- seal_lot is re-created from migration 8 with only its `me` line changed.

-- Footprints: verification is by the signed-in receiving operator (app.verify_footprint / app.seal_lot set it).
create or replace function app.footprints_actor_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.status = 'pending' and new.status = 'verified'
     and new.verified_by is distinct from app.current_user_id() then
    raise exception 'verified_by must be the signed-in user' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger footprints_actor_guard before update on public.footprints
  for each row execute function app.footprints_actor_guard();

-- Seal: p_sealer is honoured only without a JWT (service role, tests). Body otherwise identical to migration 8.
create or replace function app.seal_lot(p_qr_fp uuid, p_sealer uuid default null) returns public.qr_seals
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := case when auth.uid() is null then p_sealer else app.current_user_id() end;
        qr public.footprints; cur public.footprints;
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

-- QC override: the authoriser recorded is the signed-in manager.
create or replace function app.qc_verdicts_actor_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.override is distinct from old.override
     and lower(new.override->>'authoriser') is distinct from app.current_user_id()::text then
    raise exception 'the override authoriser must be the signed-in user' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger qc_verdicts_actor_guard before update on public.qc_verdicts
  for each row execute function app.qc_verdicts_actor_guard();

-- Farmers: created_by is stamped; farmer_code and verified_by come only from a real verification by the caller.
create or replace function app.farmers_actor_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.created_by := app.current_user_id();
    if new.farmer_code is not null or new.verified_by is not null or new.verified_at is not null then
      raise exception 'farmer_code and verified_by are set by verification, not at create' using errcode = '42501'; end if;
    return new;
  end if;
  if new.farmer_code is distinct from old.farmer_code then
    raise exception 'farmer_code is issued by verification only' using errcode = '42501'; end if;
  if new.verified_by is distinct from old.verified_by and new.verified_by is distinct from app.current_user_id() then
    raise exception 'verified_by must be the signed-in user' using errcode = '42501'; end if;
  return new;
end $$;
create trigger farmers_actor_guard before insert or update on public.farmers
  for each row execute function app.farmers_actor_guard();
