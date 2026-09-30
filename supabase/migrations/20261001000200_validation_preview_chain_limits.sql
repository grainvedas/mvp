-- GrainVeda MVP · migration 15: Phase 1 backend part 1 — one validation path for save AND preview; chain problems;
-- crop limits frozen per scope (execution plan §5: B1, B2, B7).
--
-- Function bodies below are extracted MECHANICALLY from migration 4 (script, not retyped):
--   * app.check_new_footprint = the body of footprints_before_insert with NEW renamed to f; the trigger now calls it.
--   * app.chain_problems      = the body of validate_chain collecting every problem instead of raising the first.
--   * app.derive_qc_verdict   = migration 4's body with one line changed: limits come from the scope's frozen copy.

-- ---------------------------------------------------------------------------------------------------------------
-- B1. One validation path. The save trigger and the review preview run the same function, so Review = Save.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.check_new_footprint(p_new public.footprints) returns public.footprints
language plpgsql security definer set search_path = public as $$
declare f public.footprints := p_new; sc public.scopes; def public.stage_definitions; prev public.footprints; src uuid; expected_prev public.stage_type;
begin
  select * into sc from public.scopes where id = f.scope_id;
  if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
  if sc.status <> 'active' then raise exception 'scope is not active' using errcode = '42501'; end if;
  f.client_id := sc.client_id;                                        -- stamped from the scope, never trusted from the client

  select * into def from public.stage_definitions where stage_type = f.stage_type;
  if def.stage_type is null then raise exception 'unknown stage type %', f.stage_type using errcode = '23514'; end if;
  if app.chain_index(f.scope_id, f.stage_type) is null then
    raise exception 'stage % is not in this scope''s chain', f.stage_type using errcode = '23514'; end if;

  if f.status not in ('pending','legacy') then
    raise exception 'a footprint is created as pending; verification is a separate act' using errcode = '23514'; end if;
  if f.verified_by is not null or f.verified_at is not null then
    raise exception 'verified_by/verified_at are set by verification, not at create' using errcode = '23514'; end if;

  -- Creator must hold the slot (isMyStage) or be a gateway role.
  if not app.is_my_stage(f.created_by, f.scope_id, f.stage_type) then
    raise exception 'user % may not create at stage % in this scope', f.created_by, f.stage_type using errcode = '42501'; end if;

  -- Rule 1 / 2: predecessor coupling.
  if def.is_first then
    if f.prev_footprint_id is not null then raise exception 'first stage has no predecessor' using errcode = '23514'; end if;
  else
    if f.prev_footprint_id is null then raise exception 'prev_footprint_id is required for stage %', f.stage_type using errcode = '23514'; end if;
    select * into prev from public.footprints where id = f.prev_footprint_id;
    if prev.scope_id <> f.scope_id then raise exception 'predecessor must be in the same scope' using errcode = '23514'; end if;
    if prev.lot_closed then raise exception 'predecessor lot is closed' using errcode = '23514'; end if;
    if prev.status in ('superseded','legacy') then raise exception 'predecessor is % and cannot be built on', prev.status using errcode = '23514'; end if;

    if f.is_grade_lot then
      if prev.stage_type <> 'grading' or not prev.split_into_grades or prev.is_grade_lot then
        raise exception 'a grade lot must be coupled to a grading run that was split' using errcode = '23514'; end if;
      if f.created_by <> prev.created_by and not app.is_gateway_role(app.user_role_of(f.created_by)) then
        raise exception 'grade lots are created by the grading run''s creator' using errcode = '42501'; end if;
    else
      expected_prev := app.chain_prev(f.scope_id, f.stage_type);
      if prev.stage_type <> expected_prev then
        raise exception 'predecessor of % must be % (got %)', f.stage_type, expected_prev, prev.stage_type using errcode = '23514'; end if;
      if prev.split_into_grades then
        raise exception 'a split grading run is not a source; use its grade lots' using errcode = '23514'; end if;
      if prev.status <> 'verified' then
        raise exception 'predecessor must be verified before the next stage builds on it' using errcode = '23514'; end if;
    end if;
  end if;

  -- Aggregates (village_batch): every source is a verified predecessor-stage lot in this scope.
  if def.aggregates then
    if not (f.payload ? 'source_footprint_ids' and jsonb_typeof(f.payload->'source_footprint_ids') = 'array') then
      raise exception 'village_batch requires payload.source_footprint_ids' using errcode = '23514'; end if;
    for src in select (x)::uuid from jsonb_array_elements_text(f.payload->'source_footprint_ids') x loop
      select * into prev from public.footprints where id = src;
      if prev.id is null or prev.scope_id <> f.scope_id or prev.stage_type <> app.chain_prev(f.scope_id, f.stage_type)
         or prev.status <> 'verified' or prev.lot_closed then
        raise exception 'village_batch source % is not a verified, open predecessor lot in this scope', src using errcode = '23514'; end if;
    end loop;
    if f.prev_footprint_id <> (f.payload->'source_footprint_ids'->>0)::uuid then
      raise exception 'village_batch prev_footprint_id must be the first source' using errcode = '23514'; end if;
  end if;

  -- Procurement: farmer must be active and belong to the client.
  if f.stage_type = 'procurement' then
    if not exists (select 1 from public.farmers fm where fm.id = f.farmer_id and fm.client_id = f.client_id and fm.status = 'active') then
      raise exception 'procurement requires an active farmer of this client' using errcode = '23514'; end if;
  end if;

  -- Reconciliation (rules 3, 7) → canonical quantities.
  f := app.reconcile(f, sc);

  -- Availability: cannot take more than the predecessor still holds (aggregates take whole sources, checked above).
  if f.prev_footprint_id is not null and not def.aggregates then
    if f.qty_in > app.available_qty(f.prev_footprint_id) + app.kg_tolerance() then
      raise exception 'qty_in % exceeds available % on predecessor', f.qty_in, app.available_qty(f.prev_footprint_id) using errcode = '23514'; end if;
  end if;

  return f;
end $$;

create or replace function app.footprints_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new := app.check_new_footprint(new);
  if new.footprint_code is null or new.footprint_code = '' then
    new.footprint_code := app.next_footprint_code(new.scope_id, new.stage_type, new.grade);
  end if;
  return new;
end $$;

-- Step 5–6 of the engine: exactly what a save would store, or the exact refusal, without writing anything.
create or replace function app.preview_reconcile(
  p_scope uuid, p_stage public.stage_type, p_prev uuid default null, p_payload jsonb default '{}'::jsonb,
  p_farmer uuid default null, p_is_grade_lot boolean default false, p_grade text default null, p_split boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f public.footprints; me uuid := app.current_user_id();
begin
  if me is null then return jsonb_build_object('ok', false, 'error', 'sign in first', 'code', '42501'); end if;
  if not app.can_access_scope(p_scope) then
    return jsonb_build_object('ok', false, 'error', 'no access to this scope', 'code', '42501'); end if;
  f.scope_id := p_scope; f.stage_type := p_stage; f.prev_footprint_id := p_prev; f.farmer_id := p_farmer;
  f.payload := coalesce(p_payload, '{}'::jsonb); f.is_grade_lot := coalesce(p_is_grade_lot, false); f.grade := p_grade;
  f.split_into_grades := coalesce(p_split, false); f.status := 'pending'; f.created_by := me;
  f.computed := '{}'::jsonb; f.warnings := '{}'; f.lot_closed := false;
  begin
    f := app.check_new_footprint(f);
    return jsonb_build_object('ok', true, 'qty_in', f.qty_in, 'qty_out', f.qty_out, 'computed', f.computed,
      'warnings', to_jsonb(f.warnings),
      'available_on_prev', case when p_prev is null then null else app.available_qty(p_prev) end);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'code', sqlstate);
  end;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B2. Every problem with a chain at once (chain builder shows them live); activation still raises the first.
-- ---------------------------------------------------------------------------------------------------------------
create or replace function app.chain_problems(p_chain public.stage_type[], p_crop uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare problems text[] := '{}'; n int := coalesce(array_length(p_chain, 1), 0); allowed public.stage_type[]; st public.stage_type;
begin
  if n < 3 then problems := array_append(problems, 'chain needs at least entry, qc and qr_activation'); return problems; end if;
  if p_chain[1] not in ('procurement','lot_inward') then
    problems := array_append(problems, 'chain must start with procurement or lot_inward'); end if;
  if p_chain[n] <> 'qr_activation' then
    problems := array_append(problems, 'chain must end with qr_activation'); end if;
  if not ('qc' = any(p_chain)) then problems := array_append(problems, 'qc is mandatory in every chain'); end if;
  if (select count(*) from unnest(p_chain)) <> (select count(distinct x) from unnest(p_chain) x) then
    problems := array_append(problems, 'a stage type may appear only once per chain'); end if;
  if 'procurement' = any(p_chain) and 'lot_inward' = any(p_chain) then
    problems := array_append(problems, 'chain may contain procurement or lot_inward, not both'); end if;
  if 'village_batch' = any(p_chain) and p_chain[1] <> 'procurement' then
    problems := array_append(problems, 'village_batch requires procurement as the entry stage'); end if;
  select allowed_stages into allowed from public.crops where id = p_crop;
  foreach st in array p_chain loop
    if (select is_processing from public.stage_definitions d where d.stage_type = st)
       and not (st = any(coalesce(allowed, '{}'))) then
      problems := array_append(problems, format('stage %s is not allowed for this crop', st));
    end if;
  end loop;
  return problems;
end $$;

create or replace function app.validate_chain(p_chain public.stage_type[], p_crop uuid) returns void
language plpgsql stable as $$
declare problems text[] := app.chain_problems(p_chain, p_crop);
begin
  if cardinality(problems) > 0 then raise exception '%', problems[1] using errcode = '23514'; end if;
end $$;

create or replace function app.check_chain(p_chain public.stage_type[], p_crop uuid) returns text[]
language sql stable security definer set search_path = public as $$ select app.chain_problems(p_chain, p_crop) $$;

-- ---------------------------------------------------------------------------------------------------------------
-- B7. Crop quality limits are copied into the scope at activation and frozen there; QC judges against the copy.
-- ---------------------------------------------------------------------------------------------------------------
alter table public.scopes add column quality_params jsonb;
update public.scopes s set quality_params = c.quality_params
  from public.crops c where c.id = s.crop_id and s.status <> 'draft' and s.quality_params is null;

create or replace function app.scopes_freeze_limits() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'draft' and (tg_op = 'INSERT' or old.status = 'draft') then
    new.quality_params := (select quality_params from public.crops where id = new.crop_id);
  elsif tg_op = 'UPDATE' and old.status <> 'draft' and new.quality_params is distinct from old.quality_params then
    raise exception 'quality limits are frozen for an active scope; open a new scope to change them' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger scopes_freeze_limits before insert or update on public.scopes
  for each row execute function app.scopes_freeze_limits();

create or replace function app.derive_qc_verdict(f public.footprints) returns void
language plpgsql security definer set search_path = public as $$
declare qp jsonb; prm jsonb; v numeric; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select coalesce(s.quality_params, c.quality_params) into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = f.scope_id;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    v := app.opt_num(f.payload->'readings', prm->>'param', null);
    dv := app.judge_param(v, prm->>'operator', prm->'domestic_limit');
    ev := app.judge_param(v, prm->>'operator', prm->'export_limit');
    judged := judged || jsonb_build_object('param', prm->>'param', 'value', v, 'domestic', dv, 'export', ev);
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  insert into public.qc_verdicts (footprint_id, domestic_verdict, export_verdict, readings, judged)
  values (f.id, dom, exp, coalesce(f.payload->'readings', '{}'::jsonb), judged);
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- API surface: new functions are closed, then the API ones granted by name (see migration 14).
-- Migration 14's `alter default privileges in schema app revoke … from public` is a no-op: Postgres cannot revoke the
-- global PUBLIC execute default per schema. So every migration closes its own new functions explicitly, as below, and
-- tests/08_api_surface.sql fails the build when one is missed (it caught this migration's first draft).
-- ---------------------------------------------------------------------------------------------------------------
revoke execute on function app.check_new_footprint(public.footprints), app.chain_problems(public.stage_type[], uuid),
  app.scopes_freeze_limits(), app.preview_reconcile(uuid, public.stage_type, uuid, jsonb, uuid, boolean, text, boolean),
  app.check_chain(public.stage_type[], uuid) from public, anon, authenticated;
grant execute on function app.preview_reconcile(uuid, public.stage_type, uuid, jsonb, uuid, boolean, text, boolean) to authenticated;
grant execute on function app.check_chain(public.stage_type[], uuid) to authenticated;
notify pgrst, 'reload schema';
