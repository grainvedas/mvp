-- GrainVeda MVP · migration 29: the time a record was captured; the lab verdict before saving (faults 8 and 9, 4 Oct 2026)
--
-- Found while the built system was compared with the prototype (docs/INTERFACE_GAP.md, docs/FIX_LIST.md items 8, 9).
--
-- 1. CAPTURE TIME. A record saved on a phone with no network was dated when it reached the server: a lot bought on
--    Monday and sent on Wednesday was dated Wednesday, on the record and on the public page. footprints.captured_at
--    keeps the time the operator saved it. The phone sends it only for a save that waited in its outbox; everything
--    else gets the server's time. A phone clock cannot be trusted, so the time is accepted only between 31 days before
--    and 5 minutes after the server's time; outside that the server's time is used and the record carries a warning.
--    Nobody can change it afterwards (migration 22's whitelist does not name it), and it is part of the record's
--    ledger block. created_at stays what it was: the time the server received the record.
-- 2. The public page and the lot journey date a step by the capture time.
-- 3. VERDICT BEFORE SAVING. The lab form showed no pass / fail until the record was saved (PRD §4: the technician sees
--    both verdicts). app.preview_verdict answers what the save would derive, for the review step.
--
-- No function body is typed by hand (AGENTS.md): footprint_snapshot (migration 4), public_lot_journey (migration 28),
-- lot_trace (migration 23) are re-created by script with one key added each; judge_readings is derive_qc_verdict
-- (migration 15) by script, with its inputs made parameters and its INSERT made a RETURN. tests/21 holds the two to
-- the same answer on every case; derive_qc_verdict itself is untouched.

-- =====================================================================================================================
-- 1. Capture time
-- =====================================================================================================================
alter table public.footprints add column captured_at timestamptz;
comment on column public.footprints.captured_at is
  'When the operator saved the record on the phone. Equal to created_at unless the save waited for a network. Null on records older than migration 29: read coalesce(captured_at, created_at).';

create or replace function app.footprints_capture_time() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if new.captured_at is null then
    new.captured_at := new.created_at;
  elsif new.captured_at > new.created_at + interval '5 minutes' or new.captured_at < new.created_at - interval '31 days' then
    new.warnings := array_append(coalesce(new.warnings, '{}'::text[]), 'phone clock not plausible: server time used');
    new.captured_at := new.created_at;
  elsif new.captured_at > new.created_at then
    new.captured_at := new.created_at;                    -- a clock a little fast
  end if;
  return new;
end $$;
-- Named to run last among the BEFORE INSERT triggers: after a0 (the server's created_at) and after the save rules
-- (which set the warnings this one may add to).
create trigger footprints_d0_capture_time before insert on public.footprints
  for each row execute function app.footprints_capture_time();

create or replace function app.footprint_snapshot(f public.footprints) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'id', f.id, 'footprint_code', f.footprint_code, 'client_id', f.client_id, 'scope_id', f.scope_id,
    'stage_type', f.stage_type, 'prev_footprint_id', f.prev_footprint_id, 'farmer_id', f.farmer_id,
    'qty_in', f.qty_in, 'qty_out', f.qty_out, 'status', f.status, 'payload', f.payload, 'computed', f.computed,
    'warnings', to_jsonb(f.warnings), 'lot_closed', f.lot_closed, 'is_grade_lot', f.is_grade_lot, 'grade', f.grade,
    'split_into_grades', f.split_into_grades, 'supersedes_id', f.supersedes_id,
    'created_by', f.created_by, 'verified_by', f.verified_by, 'verified_at', f.verified_at, 'created_at', f.created_at,
    'captured_at', f.captured_at
  )
$$;

-- =====================================================================================================================
-- 2. The public page and the lot journey carry it
-- =====================================================================================================================
create or replace function app.public_lot_journey(p_qr_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      step := step || jsonb_build_object('farmer', jsonb_build_object('name', fm.name, 'village', fm.village, 'district', fm.district,
                                            'photo', case when fm.photo_consent then fm.extra->>'photo_path' else null end));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', cur.payload->>'village', 'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('name', fa.name, 'village', fa.village, 'district', fa.district, 'qty_kg', src.qty_out)
                         order by fa.name)
          from public.footprints src join public.farmers fa on fa.id = src.farmer_id
         where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then
      step := step || jsonb_build_object('destination', cur.payload->>'destination', 'dispatched_on', cur.payload->>'dispatch_date'); end if;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps
  );
end $$;

create or replace function app.lot_trace(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope uuid; v_role public.user_role; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  v_role := app.current_role();
  if v_scope is null or v_role is null or v_role = 'operator' or not app.can_access_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501';
  end if;

  with recursive up(id, depth) as (
      select p_fp, 0
    union
      select par.id, up.depth + 1
        from up join public.footprints f on f.id = up.id
        cross join lateral (
          select f.prev_footprint_id as id where f.prev_footprint_id is not null
          union
          select (x)::uuid from jsonb_array_elements_text(
            case when f.stage_type = 'village_batch' then coalesce(f.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x
        ) par
       where up.depth < 64
  )
  select jsonb_agg(jsonb_build_object(
           'id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'stage_label', sd.label, 'status', f.status,
           'prev_id', f.prev_footprint_id, 'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out, 'grade', f.grade,
           'payload', f.payload, 'computed', f.computed, 'warnings', to_jsonb(f.warnings),
           'farmer', case when fa.id is null then null else jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village) end,
           'created_at', f.created_at, 'captured_at', coalesce(f.captured_at, f.created_at), 'created_by', cu.display_name,
           'verified_at', f.verified_at, 'verified_by', vu.display_name,
           'qc', (select jsonb_build_object('domestic', q.domestic_verdict, 'export', q.export_verdict, 'readings', q.readings, 'override', q.override)
                    from public.qc_verdicts q where q.footprint_id = f.id),
           'seal', (select jsonb_build_object('qr_code', s.qr_code, 'sealed_at', s.sealed_at, 'ledger_hash', s.ledger_hash, 'batch_codes', to_jsonb(s.batch_codes))
                      from public.qr_seals s where s.footprint_id = f.id),
           'withdrawn', (select jsonb_build_object('reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                           from public.withdrawals w left join public.app_users wu on wu.id = w.withdrawn_by where w.footprint_id = f.id),
           'replaces', (select jsonb_build_object('code', o.footprint_code, 'qty_out_kg', o.qty_out, 'reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                          from public.footprints o left join public.withdrawals w on w.footprint_id = o.id
                          left join public.app_users wu on wu.id = w.withdrawn_by where o.id = f.supersedes_id),
           'flags', coalesce((select jsonb_agg(jsonb_build_object('text', fl.text, 'status', fl.status, 'at', fl.created_at) order by fl.created_at)
                                from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
           'evidence', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'sha256', a.sha256, 'at', a.created_at) order by a.created_at)
                                   from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
           'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash, 'at', l.created_at) order by l.seq)
                                 from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
         ) order by f.created_at, f.footprint_code)
    into steps
    from (select distinct id from up) u
    join public.footprints f on f.id = u.id
    left join public.stage_definitions sd on sd.stage_type = f.stage_type
    left join public.farmers fa on fa.id = f.farmer_id
    left join public.app_users cu on cu.id = f.created_by
    left join public.app_users vu on vu.id = f.verified_by;

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb));
end $$;

-- =====================================================================================================================
-- 3. The lab verdict before saving
-- =====================================================================================================================
create or replace function app.judge_readings(p_scope uuid, p_readings jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare qp jsonb; prm jsonb; v numeric; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select coalesce(s.quality_params, c.quality_params) into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = p_scope;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    v := app.opt_num(p_readings, prm->>'param', null);
    dv := app.judge_param(v, prm->>'operator', prm->'domestic_limit');
    ev := app.judge_param(v, prm->>'operator', prm->'export_limit');
    judged := judged || jsonb_build_object('param', prm->>'param', 'value', v, 'domestic', dv, 'export', ev);
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  return jsonb_build_object('domestic', dom, 'export', exp, 'judged', judged);
end $$;

create or replace function app.preview_verdict(p_scope uuid, p_readings jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app.current_user_id() is null then return jsonb_build_object('ok', false, 'error', 'sign in first', 'code', '42501'); end if;
  if not app.can_access_scope(p_scope) then
    return jsonb_build_object('ok', false, 'error', 'no access to this scope', 'code', '42501'); end if;
  return jsonb_build_object('ok', true) || app.judge_readings(p_scope, coalesce(p_readings, '{}'::jsonb));
end $$;

-- API surface: new functions are closed, then the one the screens call is granted by name.
revoke execute on function app.footprints_capture_time(), app.judge_readings(uuid, jsonb), app.preview_verdict(uuid, jsonb)
  from public, anon, authenticated;
grant execute on function app.preview_verdict(uuid, jsonb) to authenticated;
