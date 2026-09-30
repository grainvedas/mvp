-- GrainVeda MVP · migration 16: Phase 1 backend part 2 — the read/write API the Phase 1 screens call
-- (execution plan §5: B3 stage_form, B4 farmer import + workflow, B6 photo evidence; plus my_context and footprint_detail).
-- Every function is closed by default at the bottom and granted by name (migration 14 / tests/08_api_surface.sql).

-- ---------------------------------------------------------------------------------------------------------------
-- Who am I, and where can I work? One call builds the app shell (navigation, slot switcher).
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.my_context() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where auth_uid = auth.uid() and active;
  if u.id is null then return jsonb_build_object('user', null, 'slots', '[]'::jsonb, 'scopes', '[]'::jsonb); end if;
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'role', u.role, 'display_name', u.display_name, 'email', u.email, 'phone', u.phone,
             'client_id', u.client_id, 'client_name', (select name from public.clients where id = u.client_id),
             'state_ids', to_jsonb(u.state_ids)),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', sa.scope_id, 'stage_type', sa.stage_type, 'stage_label', d.label,
               'scope_label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_name', c.name,
               'chain', to_jsonb(s.chain), 'scope_status', s.status) order by s.geography, d.sort_order)
        from public.slot_assignments sa
        join public.scopes s on s.id = sa.scope_id
        join public.crops cr on cr.id = s.crop_id
        join public.clients c on c.id = s.client_id
        join public.stage_definitions d on d.stage_type = sa.stage_type
       where sa.user_id = u.id), '[]'::jsonb),
    'scopes', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client_id', s.client_id, 'client_name', c.name,
               'crop_name', cr.name, 'season_code', s.season_code, 'geography', s.geography, 'status', s.status,
               'chain', to_jsonb(s.chain)) order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
       where app.can_access_scope(s.id)), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B3. Everything the 8-step engine needs for one stage of one scope, in one call.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.stage_form(p_scope uuid, p_stage public.stage_type) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc public.scopes; me uuid := app.current_user_id(); idx int; prev_t public.stage_type; next_t public.stage_type;
begin
  if me is null or not app.can_access_scope(p_scope) then
    raise exception 'no access to this scope' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = p_scope;
  idx := app.chain_index(p_scope, p_stage);
  if idx is null then raise exception 'stage % is not in this scope''s chain', p_stage using errcode = '23514'; end if;
  prev_t := case when idx > 1 then sc.chain[idx - 1] end;
  next_t := sc.chain[idx + 1];
  return jsonb_build_object(
    'scope', jsonb_build_object('id', sc.id, 'season_code', sc.season_code, 'geography', sc.geography, 'status', sc.status,
               'chain', to_jsonb(sc.chain), 'tolerances', sc.tolerances,
               'client', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.clients where id = sc.client_id),
               'crop', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'gi_tag', gi_tag, 'primary_unit', primary_unit)
                          from public.crops where id = sc.crop_id)),
    'stage', (select to_jsonb(d) from public.stage_definitions d where d.stage_type = p_stage),
    'position', idx,
    'prev_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label, 'handoff_checks', d.handoff_checks)
                     from public.stage_definitions d where d.stage_type = prev_t),
    'next_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label)
                     from public.stage_definitions d where d.stage_type = next_t),
    'quality_params', coalesce(sc.quality_params, (select quality_params from public.crops where id = sc.crop_id)),
    'can_create', app.is_my_stage(me, p_scope, p_stage),
    'can_verify_incoming', prev_t is not null and (app.is_gateway_role(app.current_role()) or app.has_slot(me, p_scope, p_stage))
  );
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Record detail (S17): the record, its verdict, seal, flags, attachments and ledger blocks. Access = can see it.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.footprint_detail(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; vd record; name_of jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  return jsonb_build_object(
    'footprint', to_jsonb(f),
    'stage_label', (select label from public.stage_definitions where stage_type = f.stage_type),
    'created_by_name', (select display_name from public.app_users where id = f.created_by),
    'verified_by_name', (select display_name from public.app_users where id = f.verified_by),
    'farmer', (select jsonb_build_object('name', name, 'farmer_code', farmer_code, 'village', village)
                 from public.farmers where id = f.farmer_id),
    'prev', (select jsonb_build_object('id', p.id, 'footprint_code', p.footprint_code, 'stage_type', p.stage_type)
               from public.footprints p where p.id = f.prev_footprint_id),
    'available_kg', app.available_qty(f.id),
    'qc', (select to_jsonb(v) from public.qc_verdicts v where v.footprint_id = f.id),
    'market_verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'seal', (select to_jsonb(q) from public.qr_seals q where q.footprint_id = f.id),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'status', fl.status, 'created_at', fl.created_at,
               'raised_by_name', (select display_name from public.app_users where id = fl.raised_by)) order by fl.created_at)
               from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B4. Farmers: one phone per client; submit, send back, verify; Excel import (all rows or none).
-- ---------------------------------------------------------------------------------------------------------------
create unique index farmers_client_phone_key on public.farmers (client_id, app.phone_key(phone));

-- Indian mobile → +91XXXXXXXXXX, or null when it is not one.
create or replace function app.normalise_in_mobile(p text) returns text
language sql immutable as $$
  select case
    when length(d) = 10 and d ~ '^[6-9]' then '+91' || d
    when length(d) = 12 and d ~ '^91[6-9]' then '+' || d
    when length(d) = 11 and d ~ '^0[6-9]' then '+91' || substr(d, 2)
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x
$$;

create or replace function app.submit_farmer(p_farmer uuid) returns public.farmers
language plpgsql security invoker set search_path = public as $$
declare r public.farmers;
begin
  update public.farmers set status = 'under_review', extra = extra - 'sent_back_reason'
   where id = p_farmer and status = 'draft' returning * into r;
  if r.id is null then raise exception 'farmer not found or not a draft' using errcode = 'P0002'; end if;
  return r;
end $$;

create or replace function app.send_back_farmer(p_farmer uuid, p_reason text) returns public.farmers
language plpgsql security invoker set search_path = public as $$
declare r public.farmers;
begin
  if app.current_role() not in ('admin', 'state_manager') then
    raise exception 'only a State Manager sends a farmer back' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.farmers set status = 'draft', extra = extra || jsonb_build_object('sent_back_reason', btrim(p_reason))
   where id = p_farmer and status = 'under_review' returning * into r;
  if r.id is null then raise exception 'farmer not found or not waiting for verification' using errcode = 'P0002'; end if;
  return r;
end $$;

-- Verification by the signed-in State Manager; the farmers_guard trigger issues the Farmer ID.
create or replace function app.verify_farmer(p_farmer uuid) returns public.farmers
language plpgsql security invoker set search_path = public as $$
declare r public.farmers;
begin
  update public.farmers set status = 'active', verified_by = app.current_user_id()
   where id = p_farmer and status = 'under_review' returning * into r;
  if r.id is null then raise exception 'farmer not found or not waiting for verification' using errcode = 'P0002'; end if;
  return r;
end $$;

-- Excel import. p_rows = [{"row": 2, "name": …, "guardian_name": …, "village": …, "district": …, "phone": …,
-- "land_area_acres": …, <any other column → extra>}]. Dry run reports; a real run inserts every row or none.
create or replace function app.import_farmers(p_client uuid, p_rows jsonb, p_dry_run boolean default true,
                                              p_scope_ids uuid[] default '{}') returns jsonb
language plpgsql security invoker set search_path = public as $$
declare r jsonb; i int := 0; rn int; errs jsonb := '[]'::jsonb; ph text; area numeric; seen text[] := '{}';
        req text[] := array['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
        k text; n int := 0; known text[] := array['row', 'name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
begin
  if not app.farmer_access(p_client) or app.current_role() = 'client_view' then
    raise exception 'no farmer access for this client' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'no rows to import' using errcode = '23514'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'at most 2000 rows per import' using errcode = '23514'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    rn := coalesce((r->>'row')::int, i + 1);
    foreach k in array req loop
      if coalesce(btrim(r->>k), '') = '' then
        errs := errs || jsonb_build_object('row', rn, 'field', k, 'message', 'required'); end if;
    end loop;
    ph := app.normalise_in_mobile(r->>'phone');
    if coalesce(btrim(r->>'phone'), '') <> '' and ph is null then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'not a 10-digit Indian mobile number');
    elsif ph is not null and app.phone_key(ph) = any(seen) then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'same phone appears earlier in this file');
    elsif ph is not null and exists (select 1 from public.farmers f where f.client_id = p_client and app.phone_key(f.phone) = app.phone_key(ph)) then
      errs := errs || jsonb_build_object('row', rn, 'field', 'phone', 'message', 'a farmer with this phone is already registered');
    end if;
    if ph is not null then seen := array_append(seen, app.phone_key(ph)); end if;
    begin
      area := nullif(btrim(r->>'land_area_acres'), '')::numeric;
      if area is not null and (area < 0 or area > 1000) then
        errs := errs || jsonb_build_object('row', rn, 'field', 'land_area_acres', 'message', 'must be between 0 and 1000'); end if;
    exception when others then
      errs := errs || jsonb_build_object('row', rn, 'field', 'land_area_acres', 'message', 'must be a number');
    end;
  end loop;

  if jsonb_array_length(errs) > 0 or p_dry_run then
    return jsonb_build_object('ok', jsonb_array_length(errs) = 0, 'dry_run', p_dry_run, 'rows', i,
                              'errors', errs, 'inserted', 0);
  end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    insert into public.farmers (client_id, scope_ids, status, name, guardian_name, village, district, phone, land_area_acres, extra)
    values (p_client, coalesce(p_scope_ids, '{}'), 'under_review', btrim(r->>'name'), btrim(r->>'guardian_name'),
            btrim(r->>'village'), btrim(r->>'district'), app.normalise_in_mobile(r->>'phone'),
            (r->>'land_area_acres')::numeric,
            coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(r) e where not e.key = any(known)), '{}'::jsonb) ||
            jsonb_build_object('imported', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', false, 'rows', i, 'errors', '[]'::jsonb, 'inserted', n);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B6. Photo evidence. Files go to the private Storage bucket `evidence` at <client>/<scope>/<footprint>/<file>;
-- the attachments row (with SHA-256, computed in the browser) is registered through this function.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.register_attachment(p_footprint uuid, p_kind public.attachment_kind, p_path text, p_sha256 text)
returns public.attachments
language plpgsql security invoker set search_path = public as $$
declare f public.footprints; r public.attachments;
begin
  select * into f from public.footprints where id = p_footprint;
  if f.id is null then raise exception 'record not found' using errcode = 'P0002'; end if;
  if p_path is distinct from format('%s/%s/%s/%s', f.client_id, f.scope_id, f.id, split_part(p_path, '/', 4))
     or split_part(p_path, '/', 4) = '' then
    raise exception 'evidence path must be <client>/<scope>/<footprint>/<file>' using errcode = '23514'; end if;
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by)
  values (p_footprint, p_kind, p_path, lower(p_sha256), app.current_user_id()) returning * into r;
  return r;
end $$;

-- Storage policies exist only where Supabase Storage does (the live project); local builds without it skip this block.
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage schema not present: evidence bucket policies skipped (local build)';
    return;
  end if;
  insert into storage.buckets (id, name, public) values ('evidence', 'evidence', false) on conflict (id) do nothing;
  execute $p$drop policy if exists evidence_read on storage.objects$p$;
  execute $p$drop policy if exists evidence_upload on storage.objects$p$;
  execute $p$
    create policy evidence_read on storage.objects for select to authenticated
    using (bucket_id = 'evidence' and exists (
      select 1 from public.footprints f
       where f.id::text = (storage.foldername(name))[3]
         and f.client_id::text = (storage.foldername(name))[1]
         and f.scope_id::text = (storage.foldername(name))[2]
         and app.can_see_footprint(f.scope_id, f.stage_type)))$p$;
  execute $p$
    create policy evidence_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'evidence' and exists (
      select 1 from public.footprints f
       where f.id::text = (storage.foldername(name))[3]
         and f.client_id::text = (storage.foldername(name))[1]
         and f.scope_id::text = (storage.foldername(name))[2]
         and app.can_see_footprint(f.scope_id, f.stage_type)))$p$;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- API surface
-- ---------------------------------------------------------------------------------------------------------------
revoke execute on function app.my_context(), app.stage_form(uuid, public.stage_type), app.footprint_detail(uuid),
  app.normalise_in_mobile(text), app.submit_farmer(uuid), app.send_back_farmer(uuid, text), app.verify_farmer(uuid),
  app.import_farmers(uuid, jsonb, boolean, uuid[]),
  app.register_attachment(uuid, public.attachment_kind, text, text) from public, anon, authenticated;
grant execute on function app.my_context(), app.stage_form(uuid, public.stage_type), app.footprint_detail(uuid),
  app.submit_farmer(uuid), app.send_back_farmer(uuid, text), app.verify_farmer(uuid),
  app.import_farmers(uuid, jsonb, boolean, uuid[]),
  app.register_attachment(uuid, public.attachment_kind, text, text) to authenticated;
-- pure helper that the invoker function import_farmers calls as the caller
grant execute on function app.normalise_in_mobile(text) to authenticated;
notify pgrst, 'reload schema';
