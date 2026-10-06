-- GrainVeda MVP · migration 32: identity layer, part 2 of 3 (who may see and do what)
--
-- Every access rule now reads two things only: the person's system role and their live assignments.
-- What a person may see is the UNION of their assignments, never the intersection:
--   scope lens   operator          the stages held on that scope (and, by the thumb rule, the stage before each)
--                export_manager    the whole of that scope, read-only, plus any stages held there
--   client lens  client_account    manages every scope of that client, in every state
--                client_viewer     reads every scope of that client (a client's own login)
--   state lens   state_supervisor  manages every scope in that state, whatever the client (internal staff)
--   system role  admin             everything
--                hr_admin / hr_resource   people records only; no scope, no client, no state
-- An assignment counts while it is live, not lapsed (ends_on) and its holder's status is `active`.
--
-- THE TRAP THIS MIGRATION REMOVES. The old rules asked "is this person a manager?" once, globally
-- (is_gateway_role(role)), and separately "can they reach this scope?". With one role per person that was the same
-- question. With a union it is not: someone who manages client A and holds one stage for client B would have been a
-- manager in B. Every such check now asks about the scope in hand: app.manages_scope(person, scope).

-- 1 · who is signed in --------------------------------------------------------------------------------------------------
create or replace function app.today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function app.daily_code_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'on' from public.app_meta where key = 'daily_code'), false)
$$;

-- The login's person, before the once-a-day code is asked for (used only to show the code screen and to verify it).
create or replace function app.login_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.app_users where auth_uid = auth.uid() and active
$$;

-- The person every rule works with. When the once-a-day code is switched on, a login that has not passed it today
-- is nobody: no rule below lets it read or write anything.
create or replace function app.current_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select u.id from public.app_users u
   where u.auth_uid = auth.uid() and u.active
     and (not app.daily_code_on()
          or exists (select 1 from public.daily_code_passes p where p.user_id = u.id and p.day = app.today()))
$$;

-- The summary role (for display and the app's menu). No rule below decides by it.
create or replace function app.current_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.app_users where id = app.current_user_id()
$$;

-- 2 · the two things that grant access -----------------------------------------------------------------------------------
create or replace function app.user_is_admin(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where id = p_user and system_role = 'admin' and status = 'active')
$$;

create or replace function app.eff_assignments(p_user uuid) returns setof public.assignments
language sql stable security definer set search_path = public as $$
  select a.* from public.assignments a join public.app_users u on u.id = a.employee_id
   where a.employee_id = p_user and a.active and u.status = 'active'
     and (a.ends_on is null or a.ends_on >= app.today())
$$;

create or replace function app.is_admin() returns boolean
language sql stable security definer set search_path = public as $$ select app.user_is_admin(app.current_user_id()) $$;

create or replace function app.is_hr() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where id = app.current_user_id()
                    and system_role in ('hr_admin', 'hr_resource') and status = 'active')
$$;

create or replace function app.is_hr_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where id = app.current_user_id() and system_role = 'hr_admin' and status = 'active')
$$;

-- May the signed-in HR person or admin manage a person holding this system role? The admin: anyone. The HR Admin:
-- HR resources and operational people. An HR resource: operational people only. Nobody below the admin touches the admin.
create or replace function app.hr_may_manage(p_target public.system_role) returns boolean
language sql stable security definer set search_path = public as $$
  select case (select system_role from public.app_users where id = app.current_user_id() and status = 'active')
    when 'admin' then true
    when 'hr_admin' then p_target in ('hr_resource', 'operational')
    when 'hr_resource' then p_target = 'operational'
    else false end
$$;

create or replace function app.holds_op_role(p_role public.op_role) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app.eff_assignments(app.current_user_id()) a where a.op_role = p_role)
$$;

-- 3 · the lenses ----------------------------------------------------------------------------------------------------------
-- Manages a scope standing at (client, state): the admin, a state supervisor of that state, the client's account.
create or replace function app.manages_place(p_user uuid, p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from app.eff_assignments(p_user) a
     where (a.lens = 'state' and a.state_id = p_state)
        or (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client))
$$;

create or replace function app.manages_scope(p_user uuid, p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.manages_place(p_user, s.client_id, s.state_id) from public.scopes s where s.id = p_scope), false)
$$;

create or replace function app.i_manage_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$ select app.manages_scope(app.current_user_id(), p_scope) $$;

-- The same question asked of a row's own columns (a policy must decide an INSERT … RETURNING without looking the new
-- row up by id: migrations 18 and 30).
create or replace function app.manages_scope_row(p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$ select app.manages_place(app.current_user_id(), p_client, p_state) $$;

-- Manages the client record itself and its logins: the admin, the client's account, a supervisor of its home state.
create or replace function app.manages_client(p_user uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from app.eff_assignments(p_user) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_client)))
$$;

create or replace function app.can_manage_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$ select app.manages_client(app.current_user_id(), p_client) $$;

-- Sees a client: any lens that touches it. A state supervisor sees a client whose home is their state or who has a
-- scope there; a person holding a stage sees the client of that scope (its name on their screens).
create or replace function app.can_access_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.client_id = p_client)
        or (a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                  or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
        or (a.lens = 'scope' and exists (select 1 from public.scopes s where s.id = a.scope_id and s.client_id = p_client)))
$$;

-- Reads the whole of a scope without managing it: the client's own login, an export manager assigned to it.
create or replace function app.views_scope_row(p_scope uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client)
        or (a.lens = 'scope' and a.op_role = 'export_manager' and a.scope_id = p_scope))
$$;

create or replace function app.sees_scope_row(p_scope uuid, p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.manages_scope_row(p_client, p_state) or app.views_scope_row(p_scope, p_client)
      or exists (select 1 from app.eff_assignments(app.current_user_id()) a where a.lens = 'scope' and a.scope_id = p_scope)
$$;

create or replace function app.can_access_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.sees_scope_row(s.id, s.client_id, s.state_id) from public.scopes s where s.id = p_scope), false)
$$;

create or replace function app.sees_whole_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id)
                     from public.scopes s where s.id = p_scope), false)
$$;

-- 4 · stages ---------------------------------------------------------------------------------------------------------------
create or replace function app.has_slot(p_user uuid, p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = p_user and sa.scope_id = p_scope and sa.stage_type = p_stage
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active')
$$;

create or replace function app.is_my_stage(p_user uuid, p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select app.manages_scope(p_user, p_scope) or app.has_slot(p_user, p_scope, p_stage)
$$;

create or replace function app.is_next_stage_user(p_user uuid, p_scope uuid, p_prev_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select app.manages_scope(p_user, p_scope) or app.has_slot(p_user, p_scope, app.chain_next(p_scope, p_prev_stage))
$$;

-- Holds any stage on the scope, or manages it: may write there at all (the triggers decide what exactly).
create or replace function app.acts_in_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.i_manage_scope(p_scope) or exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = app.current_user_id() and sa.scope_id = p_scope
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active')
$$;

-- A record is seen by: whoever manages or views the whole scope; the holder of its stage; and the holder of the
-- stage after it (the thumb rule: you see what is coming to you).
create or replace function app.can_see_footprint(p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select app.sees_whole_scope(p_scope) or exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = app.current_user_id() and sa.scope_id = p_scope
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'
       and (sa.stage_type = p_stage or app.chain_prev(p_scope, sa.stage_type) = p_stage))
$$;

-- 5 · farmers ---------------------------------------------------------------------------------------------------------------
-- Farmers belong to a client. They are read by every lens that manages or views the client, and by whoever holds
-- Procurement or Village Batch on one of its scopes; written by the same people except the client's own login.
create or replace function app.farmer_write(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                  or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
        or (a.lens = 'scope' and exists (
              select 1 from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
               where sa.assignment_id = a.id and s.client_id = p_client and sa.stage_type in ('procurement', 'village_batch'))))
$$;

create or replace function app.farmer_access(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.farmer_write(p_client) or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client)
$$;

-- A Farmer ID is issued by the admin or by a state supervisor whose state the client works in.
create or replace function app.farmer_verifier(p_user uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.user_is_admin(p_user) or exists (
    select 1 from app.eff_assignments(p_user) a
     where a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                 or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
$$;

create or replace function app.i_verify_farmers(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$ select app.farmer_verifier(app.current_user_id(), p_client) $$;

-- 6 · the old helpers, kept under their names ------------------------------------------------------------------------------
-- "Is a manager somewhere": used for things that are not about one scope (may open the people directory, may read
-- the ledger-check history). Never used to decide what may be done IN a scope.
create or replace function app.can_assign() returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a where a.op_role in ('client_account', 'state_supervisor'))
$$;
create or replace function app.is_gateway() returns boolean
language sql stable security definer set search_path = public as $$ select app.can_assign() $$;

create or replace function app.my_state_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array(select a.state_id from app.eff_assignments(app.current_user_id()) a where a.lens = 'state'), '{}')
$$;
create or replace function app.my_client_id() returns uuid
language sql stable security definer set search_path = public as $$
  select client_id from public.app_users where id = app.current_user_id()
$$;

-- 7 · record rules, re-pointed from "a manager somewhere" to "manages THIS scope" ----------------------------------------
-- Each function below is the version in force before this migration with exactly the change named above it.
-- grade lots: the creator of the run, or whoever manages this scope
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
      if f.created_by <> prev.created_by and not app.manages_scope(f.created_by, f.scope_id) then
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
end$$;

-- a create by someone who manages this scope without holding the stage is a supervisory block
create or replace function app.footprints_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; src uuid; v_close_kg numeric; v_actor uuid; v_event public.ledger_event;
begin
  select * into sc from public.scopes where id = new.scope_id;
  v_close_kg := app.opt_num(sc.tolerances, 'auto_close_kg', 2);
  v_actor := coalesce(app.current_user_id(), new.created_by);
  v_event := case when app.manages_scope(new.created_by, new.scope_id)
                   and not app.has_slot(new.created_by, new.scope_id, new.stage_type)
                  then 'supervisory'::public.ledger_event else 'create'::public.ledger_event end;

  -- Auto-close: a run that leaves < auto_close_kg of the source closes it.
  if new.prev_footprint_id is not null and not new.is_grade_lot then
    if app.available_qty(new.prev_footprint_id) < v_close_kg then
      update public.footprints set lot_closed = true where id = new.prev_footprint_id and lot_closed = false;
    end if;
  end if;
  if new.stage_type = 'village_batch' then
    for src in select (x)::uuid from jsonb_array_elements_text(new.payload->'source_footprint_ids') x loop
      update public.footprints set lot_closed = true where id = src and lot_closed = false;
    end loop;
  end if;

  -- QC: derive both verdicts from readings vs the crop's structured limits.
  if new.stage_type = 'qc' then
    perform app.derive_qc_verdict(new);
  end if;

  perform app.ledger_append(new.id, new.scope_id, v_event, v_actor, app.footprint_snapshot(new));
  return new;
end$$;

-- a verification by someone who manages this scope without holding the receiving stage is a supervisory block
create or replace function app.footprints_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_actor uuid;
begin
  if old.status = 'pending' and new.status = 'verified' then
    v_actor := coalesce(app.current_user_id(), new.verified_by);
    perform app.ledger_append(new.id, new.scope_id,
      case when app.manages_scope(new.verified_by, new.scope_id)
            and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           then 'supervisory'::public.ledger_event else 'verify'::public.ledger_event end,
      v_actor, app.footprint_snapshot(new));
  end if;
  if new.status = 'superseded' and old.status <> 'superseded' then
    perform app.ledger_append(new.id, new.scope_id, 'supersede', app.current_user_id(), app.footprint_snapshot(new));
  end if;
  if new.lot_closed and not old.lot_closed then
    perform app.ledger_append(new.id, new.scope_id, 'close', app.current_user_id(),
      jsonb_build_object('id', new.id, 'lot_closed', true, 'available_kg', app.available_qty(new.id)));
  end if;
  return new;
end$$;

-- own-record verification: only by someone who manages this scope
create or replace function app.footprints_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        if new.verified_by = old.created_by and not app.manages_scope(new.verified_by, new.scope_id) then
          raise exception 'a record cannot be verified by its own creator' using errcode = '42501'; end if;
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end$$;

-- a pending record is corrected by its creator or by whoever manages this scope
create or replace function app.footprints_correction_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and old.status = 'pending' and new.status = 'pending'
     and (new.payload is distinct from old.payload or new.farmer_id is distinct from old.farmer_id)
     and old.created_by is distinct from app.current_user_id()
     and not app.i_manage_scope(old.scope_id) then
    raise exception 'only the person who recorded this lot can correct it' using errcode = '42501';
  end if;
  return new;
end$$;

-- the same, in the update rules
create or replace function app.footprints_update_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare later text;
begin
  -- A correction of a pending record.
  if old.status = 'pending' and new.status = 'pending'
     and (new.payload is distinct from old.payload or new.farmer_id is distinct from old.farmer_id
          or new.split_into_grades is distinct from old.split_into_grades) then
    if auth.uid() is not null and old.created_by is distinct from app.current_user_id()
       and not app.i_manage_scope(old.scope_id) then
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
end$$;

-- the same, in the preview the form shows before saving
create or replace function app.preview_correction(p_fp uuid, p_payload jsonb, p_farmer uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare f public.footprints; old_in numeric; sc public.scopes; me uuid := app.current_user_id();
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    return jsonb_build_object('ok', false, 'error', 'record not found', 'code', 'P0002'); end if;
  if f.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'only a pending record can be corrected', 'code', '42501'); end if;
  if f.created_by <> me and not app.i_manage_scope(f.scope_id) then
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
end$$;

-- a record is withdrawn by whoever manages its scope
create or replace function app.withdraw_footprint(p_fp uuid, p_reason text) returns public.footprints
language plpgsql security definer set search_path = public as $$
declare f public.footprints; r public.footprints; me uuid := app.current_user_id(); src uuid;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.i_manage_scope(f.scope_id) then
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
end$$;

-- may verify incoming lots: holds the stage, or manages this scope
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
    'can_verify_incoming', prev_t is not null and (app.i_manage_scope(p_scope) or app.has_slot(me, p_scope, p_stage))
  );
end$$;

-- an override is authorised by someone who manages the lot's scope
create or replace function app.qc_verdicts_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_scope uuid;
begin
  if new.domestic_verdict <> old.domestic_verdict or new.export_verdict <> old.export_verdict
     or new.readings <> old.readings or new.judged <> old.judged then
    raise exception 'derived verdicts and readings are immutable; only override may be set' using errcode = '42501';
  end if;
  if new.override is distinct from old.override then
    if old.override is not null then raise exception 'an override cannot be changed or removed' using errcode = '42501'; end if;
    if coalesce(new.override->>'reason', '') = '' or coalesce(new.override->>'authoriser', '') = ''
       or coalesce(new.override->>'market', '') not in ('domestic','export') then
      raise exception 'override needs market, reason and authoriser' using errcode = '23514'; end if;
    select scope_id into v_scope from public.footprints where id = new.footprint_id;
    if not app.manages_scope((new.override->>'authoriser')::uuid, v_scope) then
      raise exception 'override authoriser must be client_manager or above' using errcode = '42501'; end if;
    new.override := new.override || jsonb_build_object('at', now());
    perform app.ledger_append(new.footprint_id, (select scope_id from public.footprints where id = new.footprint_id),
      'override', coalesce(app.current_user_id(), (new.override->>'authoriser')::uuid),
      jsonb_build_object('footprint_id', new.footprint_id, 'override', new.override,
                         'domestic_verdict', new.domestic_verdict, 'export_verdict', new.export_verdict));
  end if;
  return new;
end$$;

-- a Farmer ID is issued by the admin or a state supervisor of a state the client works in
create or replace function app.farmers_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' then
    if new.verified_by is null then raise exception 'farmer verification needs verified_by' using errcode = '23514'; end if;
    if not app.farmer_verifier(new.verified_by, new.client_id) then raise exception 'only a State Manager or admin issues a Farmer ID' using errcode = '42501'; end if;
    new.verified_at := coalesce(new.verified_at, now());
    if new.farmer_code is null then
      new.farmer_code := app.next_farmer_code(new.client_id);
    end if;
  elsif tg_op = 'INSERT' and new.status = 'active' then
    raise exception 'farmers are created as draft/under_review; activation is a verification act' using errcode = '23514';
  end if;
  return new;
end$$;

-- the same people may change a farmer after it was submitted
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
  staff := coalesce(app.farmer_verifier(app.current_user_id(), new.client_id), false);
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
end$$;

-- and send one back
create or replace function app.send_back_farmer(p_farmer uuid, p_reason text) returns public.farmers
language plpgsql set search_path = public as $$
declare r public.farmers;
begin
  if not coalesce(app.i_verify_farmers((select f.client_id from public.farmers f where f.id = p_farmer)), false) then
    raise exception 'only a State Manager sends a farmer back' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.farmers set status = 'draft', extra = extra || jsonb_build_object('sent_back_reason', btrim(p_reason))
   where id = p_farmer and status = 'under_review' returning * into r;
  if r.id is null then raise exception 'farmer not found or not waiting for verification' using errcode = 'P0002'; end if;
  return r;
end$$;

-- import: whoever may write this client's farmers
create or replace function app.import_farmers(p_client uuid, p_rows jsonb, p_dry_run boolean default true, p_scope_ids uuid[] default '{}') returns jsonb
language plpgsql set search_path = public as $$
declare r jsonb; i int := 0; rn int; errs jsonb := '[]'::jsonb; ph text; area numeric; seen text[] := '{}';
        req text[] := array['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
        k text; n int := 0; known text[] := array['row', 'name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
begin
  if not app.farmer_write(p_client) then
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
end$$;

-- the full trace is for whoever manages or views the whole scope, not for the holder of one stage
create or replace function app.lot_trace(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope uuid; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
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
end$$;

-- the ledger check is run by the admin or a state supervisor
create or replace function app.check_ledger_now() returns public.ledger_checks
language plpgsql security definer set search_path = public as $$
declare r public.ledger_checks;
begin
  if coalesce(app.is_admin() or app.holds_op_role('state_supervisor'), false) is not true then
    raise exception 'only the admin or a State Manager may run the ledger check' using errcode = '42501';
  end if;
  select * into r from public.ledger_checks where checked_at > now() - interval '60 seconds' order by checked_at desc limit 1;
  if r.id is not null then return r; end if;                 -- a full walk of the chain: at most once a minute
  return app.run_ledger_check('manual');
end$$;

-- 8 · what the signed-in person is told about themselves ------------------------------------------------------------------
create or replace function app.my_context() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; me uuid;
begin
  select * into u from public.app_users where auth_uid = auth.uid() and active;
  if u.id is null then
    return jsonb_build_object('user', null, 'slots', '[]'::jsonb, 'scopes', '[]'::jsonb, 'assignments', '[]'::jsonb);
  end if;
  me := app.current_user_id();                              -- null while today's sign-in code is still owed
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'role', u.role, 'system_role', u.system_role, 'status', u.status, 'external', u.external,
             'display_name', u.display_name, 'email', u.email, 'phone', u.phone, 'join_date', u.join_date,
             'client_id', u.client_id, 'client_name', (select name from public.clients where id = u.client_id),
             'state_ids', to_jsonb(u.state_ids),
             'can', jsonb_build_object('admin', app.is_admin(), 'hr', app.is_hr() or app.is_admin(), 'hr_admin', app.is_hr_admin() or app.is_admin(),
                                       'assign', app.can_assign(), 'state_lens', app.is_admin() or app.holds_op_role('state_supervisor'))),
    'needs_daily_code', me is null,
    'onboarding', (select jsonb_build_object('total', count(*), 'open', count(*) filter (where t.status = 'pending'))
                     from public.onboarding_tasks t where t.employee_id = u.id),
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'lens', a.lens, 'op_role', a.op_role, 'scope_id', a.scope_id,
               'client_id', coalesce(a.client_id, s.client_id), 'state_id', coalesce(a.state_id, s.state_id),
               'client_name', c.name, 'state_name', st.name, 'stages', to_jsonb(a.stages), 'posting', a.posting,
               'season_code', a.season_code, 'ends_on', a.ends_on,
               'label', case a.lens when 'scope' then format('%s · %s · %s', cr.name, s.season_code, s.geography)
                                    when 'client' then c.name else st.name end)
               order by a.lens, c.name, st.name, s.geography)
        from app.eff_assignments(me) a
        left join public.scopes s on s.id = a.scope_id
        left join public.crops cr on cr.id = s.crop_id
        left join public.clients c on c.id = coalesce(a.client_id, s.client_id)
        left join public.states st on st.id = coalesce(a.state_id, s.state_id)), '[]'::jsonb),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', sa.scope_id, 'stage_type', sa.stage_type, 'stage_label', d.label,
               'scope_label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_name', c.name,
               'chain', to_jsonb(s.chain), 'scope_status', s.status) order by s.geography, d.sort_order)
        from public.slot_assignments sa
        join app.eff_assignments(me) a on a.id = sa.assignment_id
        join public.scopes s on s.id = sa.scope_id
        join public.crops cr on cr.id = s.crop_id
        join public.clients c on c.id = s.client_id
        join public.stage_definitions d on d.stage_type = sa.stage_type), '[]'::jsonb),
    'scopes', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client_id', s.client_id, 'client_name', c.name,
               'crop_name', cr.name, 'season_code', s.season_code, 'geography', s.geography, 'status', s.status,
               'chain', to_jsonb(s.chain), 'state_id', s.state_id, 'state_name', st.name,
               'manage', app.manages_scope_row(s.client_id, s.state_id),
               'whole', app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id))
               order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
        join public.states st on st.id = s.state_id
       where app.sees_scope_row(s.id, s.client_id, s.state_id)), '[]'::jsonb)
  );
end $$;

-- Whose password may the signed-in person reset? Credentials belong to HR: the admin (anyone but themselves), HR
-- within app.hr_may_manage, and for a client's own login whoever manages that client. A manager no longer resets
-- the people working under them: one person may work for two clients, and a reset is a way in.
create or replace function app.reset_login_allowed(p_target uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); tgt public.app_users;
begin
  if me is null or p_target is null or p_target = me then return false; end if;      -- your own: change it yourself
  select * into tgt from public.app_users where id = p_target;
  if tgt.id is null or tgt.status = 'offboarded' then return false; end if;
  if app.is_admin() then return true; end if;
  if tgt.external then
    return exists (select 1 from public.assignments a
                    where a.employee_id = tgt.id and a.active and a.lens = 'client' and app.manages_client(me, a.client_id));
  end if;
  return app.is_hr() and app.hr_may_manage(tgt.system_role);
end $$;

-- May the signed-in person read this person's row? (policy helper: decides from the row's own columns, plus the
-- client a client login belongs to)
create or replace function app.manages_viewer(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a
                  where a.employee_id = p_person and a.active and a.lens = 'client'
                    and app.manages_client(app.current_user_id(), a.client_id))
$$;

-- 9 · policies --------------------------------------------------------------------------------------------------------------
-- people
drop policy users_insert on public.app_users;                 -- no direct insert any more: app.add_joiner / app.add_client_viewer
drop policy users_read on public.app_users;
drop policy users_update on public.app_users;
revoke insert on public.app_users from authenticated;
-- Read: yourself; the admin; HR (employees, not client logins); anyone who assigns reads the pool of employees;
-- a client login is read by whoever manages that client.
create policy users_read on public.app_users for select to authenticated using (
     auth_uid = auth.uid()
  or app.is_admin()
  or (not external and (app.is_hr() or (app.can_assign() and status <> 'offboarded')))
  or (external and app.manages_viewer(id)));
create policy users_update on public.app_users for update to authenticated using (
     app.is_admin()
  or (not external and app.is_hr() and app.hr_may_manage(system_role))
  or (external and app.manages_viewer(id)));

-- reference tables
drop policy crops_admin on public.crops;
create policy crops_admin on public.crops for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy states_admin on public.states;
create policy states_admin on public.states for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop policy stage_defs_admin on public.stage_definitions;
create policy stage_defs_admin on public.stage_definitions for all to authenticated using (app.is_admin()) with check (app.is_admin());

-- clients: the record is written by the admin or a supervisor of its home state
drop policy clients_read_by_row on public.clients;
drop policy clients_update on public.clients;
drop policy clients_write on public.clients;
create policy clients_read_by_row on public.clients for select to authenticated
  using (app.is_admin() or state_id = any(app.my_state_ids()));
create policy clients_update on public.clients for update to authenticated
  using (app.is_admin() or state_id = any(app.my_state_ids()));
create policy clients_write on public.clients for insert to authenticated
  with check (app.is_admin() or state_id = any(app.my_state_ids()));

-- scopes: decided from the row's own client and state
drop policy scopes_insert on public.scopes;
drop policy scopes_read on public.scopes;
drop policy scopes_read_by_client on public.scopes;
drop policy scopes_update on public.scopes;
create policy scopes_read on public.scopes for select to authenticated using (app.sees_scope_row(id, client_id, state_id));
create policy scopes_insert on public.scopes for insert to authenticated with check (app.manages_scope_row(client_id, state_id));
create policy scopes_update on public.scopes for update to authenticated using (app.manages_scope_row(client_id, state_id));

-- stages held on a scope
drop policy slots_read on public.slot_assignments;
drop policy slots_write on public.slot_assignments;
create policy slots_read on public.slot_assignments for select to authenticated
  using (user_id = app.current_user_id() or app.sees_whole_scope(scope_id));
create policy slots_write on public.slot_assignments for all to authenticated
  using (app.i_manage_scope(scope_id)) with check (app.i_manage_scope(scope_id));

-- farmers
drop policy farmers_insert on public.farmers;
drop policy farmers_update on public.farmers;
create policy farmers_insert on public.farmers for insert to authenticated with check (app.farmer_write(client_id));
create policy farmers_update on public.farmers for update to authenticated using (app.farmer_write(client_id));

-- records: a pure viewer of the scope (the client's login, an export manager without a stage) updates nothing
drop policy footprints_update on public.footprints;
create policy footprints_update on public.footprints for update to authenticated
  using (app.can_see_footprint(scope_id, stage_type) and app.acts_in_scope(scope_id));

drop policy flags_update on public.flags;
create policy flags_update on public.flags for update to authenticated
  using (exists (select 1 from public.footprints f where f.id = flags.footprint_id and app.i_manage_scope(f.scope_id)));

drop policy qc_verdicts_override on public.qc_verdicts;
create policy qc_verdicts_override on public.qc_verdicts for update to authenticated
  using (exists (select 1 from public.footprints f where f.id = qc_verdicts.footprint_id and app.i_manage_scope(f.scope_id)));

-- ledger: the admin reads the chain; everyone else the blocks of records they may see, and whoever sees a whole
-- scope also its scope-level blocks (activation, assignments, withdrawals)
drop policy ledger_read on public.ledger;
create policy ledger_read on public.ledger for select to authenticated using (
     app.is_admin()
  or (footprint_id is not null and exists (
        select 1 from public.footprints f where f.id = ledger.footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)))
  or (scope_id is not null and app.sees_whole_scope(scope_id)));

drop policy ledger_checks_read on public.ledger_checks;
create policy ledger_checks_read on public.ledger_checks for select to authenticated using (app.can_assign());

drop policy client_errors_read on public.client_errors;
create policy client_errors_read on public.client_errors for select to authenticated
  using (app.is_admin() or app.holds_op_role('state_supervisor'));

-- assignments: read your own; the admin and HR read all (HR needs them to see what an offboarding ends; HR cannot
-- write them); a manager reads those inside their own lens. Written only by the functions of migration 33.
grant select on public.assignments to authenticated;
create policy assignments_read on public.assignments for select to authenticated using (
     employee_id = app.current_user_id()
  or app.is_admin() or app.is_hr()
  or (lens = 'scope' and app.i_manage_scope(scope_id))
  or (lens = 'client' and app.can_manage_client(client_id))
  or (lens = 'state' and state_id = any(app.my_state_ids())));

-- audit log: the admin and the HR Admin read it. Nobody writes it by hand (no grant), nobody changes it (trigger).
grant select on public.audit_log to authenticated;
create policy audit_log_read on public.audit_log for select to authenticated using (app.is_admin() or app.is_hr_admin());

-- org facts: readable with the person; written by HR and the admin
grant select, insert, update on public.employee_org to authenticated;
create policy employee_org_read on public.employee_org for select to authenticated using (
     employee_id = app.current_user_id() or app.is_admin() or app.is_hr() or app.can_assign());
create policy employee_org_insert on public.employee_org for insert to authenticated with check (
     (app.is_admin() or app.is_hr())
  and app.hr_may_manage((select u.system_role from public.app_users u where u.id = employee_id)));
create policy employee_org_update on public.employee_org for update to authenticated using (
     (app.is_admin() or app.is_hr())
  and app.hr_may_manage((select u.system_role from public.app_users u where u.id = employee_id)));

-- identity details, files, notes, exits: HR and the admin; the person reads their own masked details and file list
grant select on public.employee_docs, public.employee_files, public.employee_notes, public.employee_exits,
                public.employee_goals, public.onboarding_tasks to authenticated;
create policy employee_docs_read on public.employee_docs for select to authenticated
  using (employee_id = app.current_user_id() or app.is_admin() or app.is_hr());
create policy employee_files_read on public.employee_files for select to authenticated
  using (employee_id = app.current_user_id() or app.is_admin() or app.is_hr());
create policy employee_notes_read on public.employee_notes for select to authenticated using (app.is_admin() or app.is_hr());
create policy employee_exits_read on public.employee_exits for select to authenticated using (app.is_admin() or app.is_hr());
create policy employee_goals_read on public.employee_goals for select to authenticated
  using (employee_id = app.current_user_id() or app.is_admin() or app.is_hr());
create policy onboarding_tasks_read on public.onboarding_tasks for select to authenticated
  using (employee_id = app.current_user_id() or app.is_admin() or app.is_hr());

-- onboarding templates: HR reads; the HR Admin and the admin write
grant select, insert, update, delete on public.onboarding_templates, public.template_tasks to authenticated;
create policy onboarding_templates_read on public.onboarding_templates for select to authenticated using (app.is_admin() or app.is_hr());
create policy onboarding_templates_write on public.onboarding_templates for all to authenticated
  using (app.is_admin() or app.is_hr_admin()) with check (app.is_admin() or app.is_hr_admin());
create policy template_tasks_read on public.template_tasks for select to authenticated using (app.is_admin() or app.is_hr());
create policy template_tasks_write on public.template_tasks for all to authenticated
  using (app.is_admin() or app.is_hr_admin()) with check (app.is_admin() or app.is_hr_admin());

-- 10 · the private store for HR documents -------------------------------------------------------------------------------
-- hr-docs/<person>/<file>. A person puts files into their own folder; HR and the admin into anyone's. Only HR and
-- the admin can open a file (decision 5 Oct 2026). Nobody replaces or removes one from the app.
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage schema not present: hr-docs bucket policies skipped (local build)';
    return;
  end if;
  insert into storage.buckets (id, name, public) values ('hr-docs', 'hr-docs', false) on conflict (id) do nothing;
  execute $p$drop policy if exists hr_docs_read on storage.objects$p$;
  execute $p$drop policy if exists hr_docs_upload on storage.objects$p$;
  execute $p$
    create policy hr_docs_read on storage.objects for select to authenticated
    using (bucket_id = 'hr-docs' and (app.is_admin() or app.is_hr()))$p$;
  execute $p$
    create policy hr_docs_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'hr-docs' and (
         (storage.foldername(name))[1] = app.current_user_id()::text
      or app.is_admin() or app.is_hr()))$p$;
end $$;

-- 11 · grants: helpers that policies evaluate as the caller (each answers only about the caller) ----------------------
-- New functions are closed first (migration 15 explains why), then the policy helpers are opened by name.
revoke execute on function
  app.today(), app.daily_code_on(), app.login_user_id(), app.user_is_admin(uuid), app.eff_assignments(uuid),
  app.is_admin(), app.is_hr(), app.is_hr_admin(), app.hr_may_manage(public.system_role), app.holds_op_role(public.op_role),
  app.manages_place(uuid, uuid, uuid), app.manages_scope(uuid, uuid), app.i_manage_scope(uuid), app.manages_scope_row(uuid, uuid),
  app.manages_client(uuid, uuid), app.views_scope_row(uuid, uuid), app.sees_scope_row(uuid, uuid, uuid), app.sees_whole_scope(uuid),
  app.acts_in_scope(uuid), app.farmer_write(uuid), app.farmer_verifier(uuid, uuid), app.i_verify_farmers(uuid),
  app.can_assign(), app.manages_viewer(uuid)
  from public, anon, authenticated;
grant execute on function app.is_admin()                                    to authenticated;
grant execute on function app.is_hr()                                       to authenticated;
grant execute on function app.is_hr_admin()                                 to authenticated;
grant execute on function app.hr_may_manage(public.system_role)             to authenticated;
grant execute on function app.holds_op_role(public.op_role)                 to authenticated;
grant execute on function app.can_assign()                                  to authenticated;
grant execute on function app.i_manage_scope(uuid)                          to authenticated;
grant execute on function app.manages_scope_row(uuid, uuid)                 to authenticated;
grant execute on function app.sees_scope_row(uuid, uuid, uuid)              to authenticated;
grant execute on function app.sees_whole_scope(uuid)                        to authenticated;
grant execute on function app.acts_in_scope(uuid)                           to authenticated;
grant execute on function app.farmer_write(uuid)                            to authenticated;
grant execute on function app.i_verify_farmers(uuid)                        to authenticated;
grant execute on function app.manages_viewer(uuid)                          to authenticated;

notify pgrst, 'reload schema';
