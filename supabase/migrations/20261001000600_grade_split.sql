-- GrainVeda MVP · migration 19: grading split end to end (Phase 2, PRD §5.4 splitsForward, T2)
--
-- 1. app.split_grades(run): creates the A/B/C grade lots of a split grading run in ONE call (atomic), from the run's
--    own computed grade_split — the operator never re-types the grade quantities.
-- 2. Gap found while building the screen: the seal gate needs every ancestor verified, but a split run is hidden from
--    the next stage's incoming list (rule 8), so nobody could ever verify it from the app and no grade lot could be
--    sealed. Now verifying a grade lot also verifies its pending run, by the same person in the same act (that person
--    is, by definition, the operator of the stage after grading). Guard trigger beside the existing ones; no bodies
--    re-pasted.

create or replace function app.split_grades(p_run uuid) returns setof public.footprints
language plpgsql security invoker set search_path = public as $$
declare r public.footprints; g text; kg numeric; me uuid := app.current_user_id();
begin
  select * into r from public.footprints where id = p_run;
  if r.id is null then raise exception 'grading run not found' using errcode = 'P0002'; end if;
  if r.stage_type <> 'grading' or r.is_grade_lot or not r.split_into_grades then
    raise exception 'only a grading run saved with "split into grade lots" can be split' using errcode = '23514'; end if;
  if exists (select 1 from public.footprints c where c.prev_footprint_id = r.id and c.is_grade_lot and c.status <> 'superseded') then
    raise exception 'this run already has grade lots' using errcode = '23505'; end if;
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

create or replace function app.grade_lot_verifies_run() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_grade_lot and old.status = 'pending' and new.status = 'verified' then
    update public.footprints set status = 'verified', verified_by = new.verified_by, verified_at = new.verified_at
     where id = new.prev_footprint_id and status = 'pending';
  end if;
  return new;
end $$;
create trigger footprints_grade_lot_verifies_run after update on public.footprints
  for each row execute function app.grade_lot_verifies_run();

revoke execute on function app.split_grades(uuid), app.grade_lot_verifies_run() from public, anon, authenticated;
grant execute on function app.split_grades(uuid) to authenticated;
notify pgrst, 'reload schema';
