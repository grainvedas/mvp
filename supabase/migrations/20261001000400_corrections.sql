-- GrainVeda MVP · migration 17: correcting a pending record (execution plan S20)
--
-- Gap found while building S20: footprints_update (migration 5) lets anyone who can SEE a pending record update it, and
-- the pending branch of footprints_before_update re-runs the maths but never asks who is editing. So the next stage's
-- operator could rewrite the figures of a lot before verifying it. From now on only the record's creator (or a
-- gateway role, ledgered as supervisory at verification anyway) may change a pending record's figures.
-- Guard added beside the existing trigger, no body re-pasted (AGENTS.md).

create or replace function app.footprints_correction_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.status = 'pending' and new.status = 'pending'
     and (new.payload is distinct from old.payload or new.farmer_id is distinct from old.farmer_id)
     and old.created_by is distinct from app.current_user_id()
     and not app.is_gateway_role(app.current_role()) then
    raise exception 'only the person who recorded this lot can correct it' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger footprints_correction_guard before update on public.footprints
  for each row execute function app.footprints_correction_guard();

-- Preview of a correction: what the corrected record would store. Mirrors the pending branch of
-- footprints_before_update (reconcile, then availability counting the record's own current draw).
create or replace function app.preview_correction(p_fp uuid, p_payload jsonb, p_farmer uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f public.footprints; old_in numeric; sc public.scopes; me uuid := app.current_user_id();
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    return jsonb_build_object('ok', false, 'error', 'record not found', 'code', 'P0002'); end if;
  if f.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'only a pending record can be corrected', 'code', '42501'); end if;
  if f.created_by <> me and not app.is_gateway_role(app.current_role()) then
    return jsonb_build_object('ok', false, 'error', 'only the person who recorded this lot can correct it', 'code', '42501'); end if;
  old_in := f.qty_in;
  f.payload := coalesce(p_payload, '{}'::jsonb);
  if p_farmer is not null then f.farmer_id := p_farmer; end if;
  select * into sc from public.scopes where id = f.scope_id;
  begin
    f := app.reconcile(f, sc);
    if f.prev_footprint_id is not null and not f.is_grade_lot and f.stage_type <> 'village_batch'
       and f.qty_in > app.available_qty(f.prev_footprint_id) + old_in + app.kg_tolerance() then
      raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
    return jsonb_build_object('ok', true, 'qty_in', f.qty_in, 'qty_out', f.qty_out, 'computed', f.computed,
      'warnings', to_jsonb(f.warnings),
      'available_on_prev', case when f.prev_footprint_id is null then null else app.available_qty(f.prev_footprint_id) + old_in end);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'code', sqlstate);
  end;
end $$;

revoke execute on function app.footprints_correction_guard(), app.preview_correction(uuid, jsonb, uuid) from public, anon, authenticated;
grant execute on function app.preview_correction(uuid, jsonb, uuid) to authenticated;
notify pgrst, 'reload schema';
