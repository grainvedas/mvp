-- GrainVeda MVP · migration 22: integrity guards from the pre-go-live review of direct writes (Phase 4)
--
-- Migration 14 closed the FUNCTION surface of the API. This one closes the TABLE surface: what a signed-in user can write
-- with plain REST calls on public.* (PATCH / POST), bypassing the screens. Each item below was reproduced on a local
-- build before the fix and is held as a refused write in tests/14_integrity_guards.sql.
--
--   F1  a pending record's quantities, computed values, warnings, dates and lot status could be rewritten by its
--       creator AND by the next stage's operator; verification then froze the forged figures
--   F2  any operator who could see a record (own stage or the stage behind) could void it (status → superseded), even
--       a verified record with later records built on it; lot_closed could be flipped by hand
--   F3  a new record could be back-dated and given a hand-picked code
--   F4  a saved QC record could be "corrected": the verdict stayed as derived from the first readings
--   F5  a grade lot did not have to match the run's split (165 kg of grade A from a run that graded 100 kg as A), and a
--       pending grade lot could be corrected to any quantity; a split run could be corrected under its grade lots
--   F6  a correction could swap in a farmer who is not verified
--   F7  a withdrawn record (PRD §8 "supersession") had no rule: who, when, why, and what replaces it
--   S1  an active scope could go back to draft, have its chain rewritten and be re-activated
--   R1  a verified farmer's name and village (shown on public pages of sealed lots) and photo consent could be changed
--       by a procurement operator, with no trace
--   L1  a manager could rewrite the text, author, date or target of a flag, or insert one already resolved
--   A1  evidence could be registered with any path and a back-dated time by inserting the row directly
--
-- How "direct write" is recognised: trigger functions marked SECURITY INVOKER see current_user = 'authenticated' for a
-- statement sent by an API user, and the function owner for a statement issued inside server code (security definer
-- functions and triggers: verify_footprint, seal_lot, auto-close, withdraw_footprint). Server code is trusted; direct
-- writes are held to a whitelist. No existing function body is re-pasted (AGENTS.md): every rule is a new trigger
-- beside the existing ones, named so that it sorts where it must run.

-- =====================================================================================================================
-- 1. Footprints
-- =====================================================================================================================

-- F3 · a new record sent by an API user: code, creation time and lot status are the server's.
create or replace function app.footprints_api_insert() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  new.footprint_code := null;          -- footprints_before_insert assigns it from the series counter
  new.created_at := now();
  new.lot_closed := false;
  return new;
end $$;
create trigger footprints_a0_api_insert before insert on public.footprints
  for each row execute function app.footprints_api_insert();

-- F1, F2 · an update sent by an API user may touch only the entered values of a record (a correction; the existing
-- triggers decide whether it is allowed and re-derive the quantities) or verify it. Everything else is the server's.
create or replace function app.footprints_api_update() returns trigger
language plpgsql security invoker set search_path = public as $$
declare keep text[] := array['payload', 'farmer_id', 'split_into_grades', 'status', 'verified_by', 'verified_at'];
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if (to_jsonb(new) - keep) is distinct from (to_jsonb(old) - keep) then
    raise exception 'quantities, codes, dates and lot status are set by the server; only the entered values of a pending record can be corrected'
      using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not (old.status = 'pending' and new.status = 'verified') then
      raise exception 'a record''s status cannot be set directly: it is verified by the receiving stage and withdrawn by a manager (app.withdraw_footprint)'
        using errcode = '42501';
    end if;
    new.verified_at := now();
  elsif new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at then
    raise exception 'verified_by and verified_at are set by verification only' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger footprints_a0_api_update before update on public.footprints
  for each row execute function app.footprints_api_update();

-- F5, F7 · rules on a new record that the insert validation did not have. Runs after footprints_before_insert, so
-- qty_out is the reconciled figure. Holds for every role.
create or replace function app.footprints_insert_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare run public.footprints; expected numeric; gone public.footprints;
begin
  if new.split_into_grades and new.stage_type <> 'grading' then
    raise exception 'only a grading run can be split into grade lots' using errcode = '23514'; end if;

  if new.is_grade_lot then
    select * into run from public.footprints where id = new.prev_footprint_id;
    expected := coalesce((run.computed->'grade_split'->>new.grade)::numeric, 0);
    if expected <= 0 or abs(new.qty_out - expected) > app.kg_tolerance() then
      raise exception 'a grade % lot carries exactly what the run graded as % (% kg), not % kg', new.grade, new.grade, expected, new.qty_out
        using errcode = '23514'; end if;
    if exists (select 1 from public.footprints c
                where c.prev_footprint_id = run.id and c.is_grade_lot and c.grade = new.grade and c.id <> new.id
                  and c.status not in ('superseded', 'legacy')) then
      raise exception 'this run already has a grade % lot', new.grade using errcode = '23505'; end if;
  end if;

  if new.supersedes_id is not null then
    select * into gone from public.footprints where id = new.supersedes_id;
    if gone.id is null or gone.status <> 'superseded' or gone.scope_id <> new.scope_id or gone.stage_type <> new.stage_type then
      raise exception 'supersedes_id must name a withdrawn record of the same stage in this scope' using errcode = '23514'; end if;
    if exists (select 1 from public.footprints c
                where c.supersedes_id = new.supersedes_id and c.id <> new.id and c.status not in ('superseded', 'legacy')) then
      raise exception 'that withdrawn record already has a replacement' using errcode = '23505'; end if;
  end if;
  return new;
end $$;
create trigger footprints_c0_insert_rules before insert on public.footprints
  for each row execute function app.footprints_insert_rules();

-- F4, F5, F6, F2 · rules on an update that hold for every role.
create or replace function app.footprints_update_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare later text;
begin
  -- A correction of a pending record.
  if old.status = 'pending' and new.status = 'pending'
     and (new.payload is distinct from old.payload or new.farmer_id is distinct from old.farmer_id
          or new.split_into_grades is distinct from old.split_into_grades) then
    if auth.uid() is not null and old.created_by is distinct from app.current_user_id()
       and not app.is_gateway_role(app.current_role()) then
      raise exception 'only the person who recorded this lot can correct it' using errcode = '42501'; end if;
    if (select s.status from public.scopes s where s.id = old.scope_id) is distinct from 'active' then
      raise exception 'scope is not active' using errcode = '42501'; end if;
    if new.split_into_grades and new.stage_type <> 'grading' then
      raise exception 'only a grading run can be split into grade lots' using errcode = '23514'; end if;
    -- Records whose save derived something elsewhere (a QC verdict, closed batch sources, grade lots) are not edited
    -- in place: the derived rows would no longer match. A manager withdraws them and they are recorded again.
    if old.stage_type in ('qc', 'village_batch') or old.is_grade_lot
       or exists (select 1 from public.footprints c
                   where c.prev_footprint_id = old.id and c.status not in ('superseded', 'legacy')) then
      raise exception 'this record cannot be corrected after saving (a verdict, a batch or grade lots were derived from it); a manager withdraws it and it is recorded again'
        using errcode = '42501'; end if;
    if new.farmer_id is distinct from old.farmer_id and new.stage_type = 'procurement'
       and not exists (select 1 from public.farmers fm
                        where fm.id = new.farmer_id and fm.client_id = new.client_id and fm.status = 'active') then
      raise exception 'procurement requires an active farmer of this client' using errcode = '23514'; end if;
  end if;

  -- Withdrawing: only a record nothing has been built on, never a sealed lot.
  if new.status = 'superseded' and old.status <> 'superseded' then
    if exists (select 1 from public.qr_seals q where q.footprint_id = old.id) then
      raise exception 'a sealed lot cannot be withdrawn' using errcode = '42501'; end if;
    select string_agg(c.footprint_code, ', ' order by c.footprint_code) into later
      from public.footprints c
     where c.status not in ('superseded', 'legacy')
       and (c.prev_footprint_id = old.id
            or (c.stage_type = 'village_batch' and coalesce(c.payload->'source_footprint_ids', '[]'::jsonb) ? old.id::text));
    if later is not null then
      raise exception 'later records are built on this one (%); withdraw those first', later using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger footprints_c0_update_rules before update on public.footprints
  for each row execute function app.footprints_update_rules();

-- A source lot is closed when less than auto_close_kg is left on it. A correction or a withdrawal changes what is
-- left, so the flag is recomputed (before: a corrected run could leave its source closed with grain still on it).
create or replace function app.sync_lot_closed(p_fp uuid) returns void
language plpgsql security definer set search_path = public as $$
declare f public.footprints; v_close numeric; should boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.status <> 'verified' or f.split_into_grades
     or exists (select 1 from public.qr_seals q where q.footprint_id = f.id) then return; end if;
  select app.opt_num(s.tolerances, 'auto_close_kg', 2) into v_close from public.scopes s where s.id = f.scope_id;
  should := app.available_qty(f.id) < v_close;
  if f.lot_closed is distinct from should then
    update public.footprints set lot_closed = should where id = f.id;
  end if;
end $$;

create or replace function app.footprints_after_correction() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'pending' and new.status = 'pending' and new.qty_in is distinct from old.qty_in
     and new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch' then
    perform app.sync_lot_closed(new.prev_footprint_id);
  end if;
  return new;
end $$;
create trigger footprints_z0_after_correction after update on public.footprints
  for each row execute function app.footprints_after_correction();

-- F7 · withdrawing a wrong record (PRD §6 "corrections are new records that supersede, with the original retained and
-- linked"; §4 gateway bypass "written to the ledger tagged as a supervisory act"). Managers only, with a reason.
-- The record stays, marked superseded; what it had taken from its source is given back; the replacement is a normal
-- new record that names it in supersedes_id.
create table public.withdrawals (
  footprint_id  uuid primary key references public.footprints(id),
  reason        text not null check (btrim(reason) <> ''),
  withdrawn_by  uuid not null references public.app_users(id),
  withdrawn_at  timestamptz not null default now()
);
alter table public.withdrawals enable row level security;
create policy withdrawals_read on public.withdrawals for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
revoke all on public.withdrawals from anon, authenticated;
grant select on public.withdrawals to authenticated;

create or replace function app.withdraw_footprint(p_fp uuid, p_reason text) returns public.footprints
language plpgsql security definer set search_path = public as $$
declare f public.footprints; r public.footprints; me uuid := app.current_user_id(); src uuid;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.is_gateway_role(app.current_role()) then
    raise exception 'only a manager can withdraw a record' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if f.status not in ('pending', 'verified') then
    raise exception 'only a pending or verified record can be withdrawn (this one is %)', f.status using errcode = '23514'; end if;

  insert into public.withdrawals (footprint_id, reason, withdrawn_by) values (f.id, btrim(p_reason), me);
  update public.footprints set status = 'superseded' where id = f.id returning * into r;   -- update rules: leaf, not sealed

  if f.stage_type = 'village_batch' then                               -- the batch had closed every source lot
    for src in select (x)::uuid from jsonb_array_elements_text(coalesce(f.payload->'source_footprint_ids', '[]'::jsonb)) x loop
      update public.footprints set lot_closed = false where id = src and lot_closed and status = 'verified';
    end loop;
  elsif f.prev_footprint_id is not null and not f.is_grade_lot then
    perform app.sync_lot_closed(f.prev_footprint_id);
  end if;

  perform app.ledger_append(f.id, f.scope_id, 'supervisory', me,
    jsonb_build_object('act', 'withdraw', 'footprint_id', f.id, 'footprint_code', f.footprint_code,
                       'was', f.status, 'qty_out', f.qty_out, 'reason', btrim(p_reason)));
  return r;
end $$;

-- =====================================================================================================================
-- 2. Scopes · S1
-- =====================================================================================================================
create or replace function app.scopes_state_guard() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    if old.status = 'active' and new.status = 'draft' then
      raise exception 'an active scope cannot go back to draft; close it and open a new scope' using errcode = '42501'; end if;
    if old.status <> 'draft' and (new.tolerances is distinct from old.tolerances or new.geography is distinct from old.geography) then
      raise exception 'a scope''s place and tolerances are frozen after activation; open a new scope' using errcode = '42501'; end if;
    if old.activated_at is not null then
      new.activated_at := old.activated_at;
    elsif current_user in ('authenticated', 'anon') then
      new.activated_at := null;                                          -- scopes_guard stamps now() at activation
    end if;
  elsif current_user in ('authenticated', 'anon') then
    new.created_at := now();
    new.activated_at := null;
  end if;
  return new;
end $$;
create trigger scopes_a0_state_guard before insert or update on public.scopes
  for each row execute function app.scopes_state_guard();

-- =====================================================================================================================
-- 3. Farmers · R1. Runs after farmers_actor_guard and farmers_guard, so their refusals keep their wording.
--    Operators and Client Managers work on drafts; once submitted, only a State Manager or admin changes a farmer.
--    Every change to a verified farmer is a ledger block: the name on a sealed lot's public page has a history.
-- =====================================================================================================================
create or replace function app.farmers_change_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare staff boolean;
begin
  if auth.uid() is null then return new; end if;                         -- service role, seeds, migrations
  if tg_op = 'INSERT' then
    new.created_at := now();
    return new;
  end if;
  new.created_at := old.created_at;
  if new.client_id is distinct from old.client_id or new.created_by is distinct from old.created_by then
    raise exception 'a farmer''s client and creator cannot be changed' using errcode = '42501'; end if;
  staff := coalesce(app.current_role() in ('admin', 'state_manager'), false);
  if not staff then
    if old.status <> 'draft' then
      raise exception 'this farmer has been submitted: only a State Manager can change it now' using errcode = '42501'; end if;
    if new.status not in ('draft', 'under_review') then
      raise exception 'a farmer is activated or deactivated by a State Manager' using errcode = '42501'; end if;
  end if;
  if old.status <> 'active' and new.status = 'active' and old.verified_at is null then
    new.verified_at := now();                                            -- first verification: the server's clock
  else
    new.verified_at := old.verified_at;
    if not (old.status <> 'active' and new.status = 'active') then new.verified_by := old.verified_by; end if;
  end if;
  return new;
end $$;
create trigger farmers_z0_change_guard before insert or update on public.farmers
  for each row execute function app.farmers_change_guard();

create or replace function app.farmers_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare actor uuid := coalesce(app.current_user_id(), new.verified_by); was jsonb := '{}'::jsonb; now_ jsonb := '{}'::jsonb; k text;
begin
  if old.farmer_code is null and new.farmer_code is not null then
    perform app.ledger_append(null, null, 'supervisory', actor,
      jsonb_build_object('kind', 'farmer_verified', 'farmer_id', new.id, 'farmer_code', new.farmer_code, 'client_id', new.client_id,
                         'name', new.name, 'guardian_name', new.guardian_name, 'village', new.village, 'district', new.district,
                         'land_area_acres', new.land_area_acres, 'photo_consent', new.photo_consent));
  elsif old.farmer_code is not null then
    foreach k in array array['name', 'guardian_name', 'village', 'district', 'land_area_acres', 'photo_consent', 'status'] loop
      if to_jsonb(new)->k is distinct from to_jsonb(old)->k then
        was := was || jsonb_build_object(k, to_jsonb(old)->k);
        now_ := now_ || jsonb_build_object(k, to_jsonb(new)->k);
      end if;
    end loop;
    if new.phone is distinct from old.phone then                         -- the number itself stays out of the ledger
      was := was || jsonb_build_object('phone', 'changed'); now_ := now_ || jsonb_build_object('phone', 'changed');
    end if;
    if now_ <> '{}'::jsonb then
      perform app.ledger_append(null, null, 'supervisory', actor,
        jsonb_build_object('kind', 'farmer_changed', 'farmer_id', new.id, 'farmer_code', new.farmer_code, 'before', was, 'after', now_));
    end if;
  end if;
  return new;
end $$;
create trigger farmers_ledger after update on public.farmers
  for each row execute function app.farmers_ledger();

-- =====================================================================================================================
-- 4. Flags · L1. A flag is a statement by the person who raised it: it is never edited. Its status is changed by a
--    manager (RLS), and that change is a supervisory act in the ledger (an open flag blocks the seal).
-- =====================================================================================================================
create or replace function app.flags_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status := 'open';
    return new;
  end if;
  if (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then
    raise exception 'a flag cannot be edited; only its status changes' using errcode = '42501'; end if;
  return new;
end $$;
create trigger flags_guard before insert or update on public.flags
  for each row execute function app.flags_guard();

create or replace function app.flags_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.status is distinct from old.status then
    perform app.ledger_append(new.footprint_id, (select f.scope_id from public.footprints f where f.id = new.footprint_id),
      'supervisory', app.current_user_id(),
      jsonb_build_object('act', 'flag_' || new.status, 'flag_id', new.id, 'text', new.text, 'raised_by', new.raised_by,
                         'from', old.status, 'to', new.status));
  end if;
  return new;
end $$;
create trigger flags_ledger after update on public.flags
  for each row execute function app.flags_ledger();

-- =====================================================================================================================
-- 5. Evidence · A1. The path rule of app.register_attachment now holds for a row inserted directly as well.
-- =====================================================================================================================
create or replace function app.attachments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare f public.footprints;
begin
  select * into f from public.footprints where id = new.footprint_id;
  if f.id is null or split_part(new.storage_path, '/', 4) = ''
     or new.storage_path is distinct from format('%s/%s/%s/%s', f.client_id, f.scope_id, f.id, split_part(new.storage_path, '/', 4)) then
    raise exception 'evidence path must be <client>/<scope>/<footprint>/<file>' using errcode = '23514'; end if;
  new.sha256 := lower(new.sha256);
  if auth.uid() is not null then
    new.created_at := now();
    new.uploaded_by := app.current_user_id();
  end if;
  return new;
end $$;
create trigger attachments_guard before insert on public.attachments
  for each row execute function app.attachments_guard();
create unique index attachments_storage_path_key on public.attachments (storage_path);
revoke update on public.attachments from authenticated;                -- there was never an update policy; now no grant either
revoke insert on public.qc_verdicts from authenticated;                -- verdict rows are written by the QC save only

-- =====================================================================================================================
-- 6. created_at is the server's on every table an API user can update
-- =====================================================================================================================
create or replace function app.keep_created_at() returns trigger
language plpgsql as $$
begin
  new.created_at := old.created_at;
  return new;
end $$;
create trigger qc_verdicts_a0_keep_created_at before update on public.qc_verdicts
  for each row execute function app.keep_created_at();
create trigger app_users_a0_keep_created_at before update on public.app_users
  for each row execute function app.keep_created_at();
create trigger clients_a0_keep_created_at before update on public.clients
  for each row execute function app.keep_created_at();

-- =====================================================================================================================
-- API surface (migration 14 rule): close every new function, grant the one that is API
-- =====================================================================================================================
revoke execute on function
  app.footprints_api_insert(), app.footprints_api_update(), app.footprints_insert_rules(), app.footprints_update_rules(),
  app.sync_lot_closed(uuid), app.footprints_after_correction(), app.withdraw_footprint(uuid, text),
  app.scopes_state_guard(), app.farmers_change_guard(), app.farmers_ledger(), app.flags_guard(), app.flags_ledger(),
  app.attachments_guard(), app.keep_created_at()
  from public, anon, authenticated;
grant execute on function app.withdraw_footprint(uuid, text) to authenticated;
notify pgrst, 'reload schema';
