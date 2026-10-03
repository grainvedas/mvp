-- GrainVeda MVP · migration 24: one act, one transaction (seal; grading split)
--
-- PRD §10: "RPC functions for multi-row saves (grading split, commercial split, seal): atomic writes where one action
-- creates several footprints". Two acts were still two requests, and a failure between them left a lot stuck.
--
-- 1 · SEAL. Found in the Phase 4 pre-go-live run. The app sealed in two requests: (1) insert the QR Activation record, which
-- takes the whole source lot and closes it; (2) app.seal_lot(), which walks the chain and may refuse at the gate
-- ("open flag on …", "… is not verified", "QC verdict is pending"). When (2) refused, (1) had already been saved:
-- the source lot was closed, a pending QR record was left behind, the lot disappeared from the sealer's list, and after
-- the manager resolved the flag a new attempt was refused with "predecessor lot is closed". The lot was stuck.
-- An open flag is the ordinary reason a seal is refused, so this would have happened in the first week of a season.
--
-- app.seal_source(source lot) does both steps in one transaction: if the gate refuses, nothing is saved and the lot
-- stays in the sealer's list. It runs with the caller's rights, so the insert goes through the same RLS policies and
-- triggers as before (only the assigned QR operator or a gateway role may create at QR Activation), and the QR code
-- is still minted only by app.seal_lot (AGENTS.md rule 6).
--
-- A QR record left behind by the old two-step path is finished with app.seal_lot(that record) once the gate passes
-- (the record page offers it), or withdrawn by a manager (migration 22).

create or replace function app.seal_source(p_source uuid) returns public.qr_seals
language plpgsql volatile security invoker set search_path = public as $$
declare src public.footprints; qr public.footprints;
begin
  select * into src from public.footprints where id = p_source;        -- RLS: only a lot the caller may see
  if src.id is null then raise exception 'record not found' using errcode = 'P0002'; end if;
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (src.scope_id, src.client_id, 'qr_activation', src.id, app.current_user_id(), '{}'::jsonb)
  returning * into qr;
  return app.seal_lot(qr.id);                                           -- raises at the gate: the insert above is undone
end $$;

-- 2 · GRADING SPLIT. The app saved the grading run, then called app.split_grades(run) in a second request. If that
-- request failed (the network dropped; an offline save syncing on a weak signal) the run existed, marked "split", with
-- no grade lots: hidden from the next stage (rule 8) and with nothing downstream to take its place. The same happened
-- when a pending run was corrected to "split": the app never asked for the lots.
-- Now the lots are made by the save itself: an AFTER trigger calls app.split_grades for a grading run saved (or
-- corrected) with the split flag, in the same transaction. If a lot is refused, the run is not saved either.
-- app.split_grades is re-created MECHANICALLY from migration 19 (script) with two changes: asked for a run that
-- already has its lots it returns them (apps built before this migration still call it after saving), and in a server
-- context with no signed-in user the lots carry the run's creator.
create or replace function app.split_grades(p_run uuid) returns setof public.footprints
language plpgsql security invoker set search_path = public as $$
declare r public.footprints; g text; kg numeric; me uuid := app.current_user_id();
begin
  select * into r from public.footprints where id = p_run;
  if r.id is null then raise exception 'grading run not found' using errcode = 'P0002'; end if;
  me := coalesce(me, r.created_by);                                     -- migration 24: called by the save trigger in a server context
  if r.stage_type <> 'grading' or r.is_grade_lot or not r.split_into_grades then
    raise exception 'only a grading run saved with "split into grade lots" can be split' using errcode = '23514'; end if;
  if exists (select 1 from public.footprints c where c.prev_footprint_id = r.id and c.is_grade_lot and c.status <> 'superseded') then
    -- migration 24: the lots are made when the run is saved; asking again answers with them instead of refusing
    return query select c.* from public.footprints c
                  where c.prev_footprint_id = r.id and c.is_grade_lot and c.status <> 'superseded' order by c.grade;
    return;
  end if;
  foreach g in array array['A', 'B', 'C'] loop
    kg := coalesce((r.computed->'grade_split'->>g)::numeric, 0);
    if kg > 0 then
      return query
        insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, is_grade_lot, grade)
        values (r.scope_id, r.client_id, 'grading', r.id, me, jsonb_build_object('qty_kg', kg), true, g)
        returning *;
    end if;
  end loop;
end $$;

create or replace function app.footprints_split_on_save() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if new.stage_type = 'grading' and new.split_into_grades and not new.is_grade_lot and new.status = 'pending'
     and (tg_op = 'INSERT' or not old.split_into_grades) then
    perform app.split_grades(new.id);
  end if;
  return null;
end $$;
-- z1: after footprints_after_insert / footprints_after_update, so the run's own ledger block comes before its lots'
create trigger footprints_z1_split_on_save after insert or update of split_into_grades on public.footprints
  for each row execute function app.footprints_split_on_save();

revoke execute on function app.seal_source(uuid), app.split_grades(uuid), app.footprints_split_on_save() from public, anon, authenticated;
grant execute on function app.seal_source(uuid), app.split_grades(uuid) to authenticated;
notify pgrst, 'reload schema';
