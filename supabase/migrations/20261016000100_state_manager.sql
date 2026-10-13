-- Migration 41 (Veda, 13 Oct 2026, "GrainVeda MVP — State Manager role"; FIX_LIST item 36): the State Manager owns one
-- state. He keeps its crops, onboards its clients, gives each its Client Manager, verifies farmers after the Client
-- Manager and watches everything in his state. He does not build scopes, hire, touch other states or override records.
-- Found on 13 Oct (a probe as Ram on a copy of the database), all closed here and each covered by tests/35:
--   · any State Manager edited every crop (crops had no state)             → crops.state_id; writes only in his state
--   · he created and edited scopes, also for clients of other states        → scopes are written by the Client Manager;
--                                                                            a NEW scope is in its client's own state
--   · a seat insert past app.assign seated HR, the admin and himself         → the same person rules on that path
--   · he could skip the Client Manager (draft → active), and a blank state
--     switched every step-2 check off                                        → order on every route; state never blank
--   · another state's manager reached a client's farmers through a scope    → a farmer's state decides who is staff
--   · he created and imported farmers                                       → the Client Manager and procurement do
--   · he saw everyone (the admin, HR, other states) and changed the email
--     of a client login shared with another state                          → his state's people; logins fully his
--   · QC override by a State Manager                                         → the Client Manager only (no override)
-- New read functions: app.state_home (his overview, the client cards, the pipeline of his state), app.state_ledger_page
-- (the blocks of his state, read-only). Additive: columns, functions and rules; no row is rewritten.

-- 1 · helpers ------------------------------------------------------------------------------------------------------------
create or replace function app.client_home(p_client uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select c.state_id from public.clients c where c.id = p_client $$;

-- the Client Manager of this client (holds its account): builds its scopes, adds its farmers, overrides its QC
create or replace function app.runs_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.client_account_holder(app.current_user_id(), p_client) $$;

-- a State Manager acting as one: not also a Client Manager, not HR, not the admin
create or replace function app.sm_limited() returns boolean
language sql stable security definer set search_path = public as $$
  select app.holds_op_role('state_supervisor') and not app.holds_op_role('client_account') and not app.is_hr() and not app.is_admin() $$;

-- Whom a State Manager sees (Veda, 13 Oct): himself; operational employees who hold an assignment in his state (state,
-- client or scope); operational employees with no assignment who are based in his state (or, with no base, whose opening
-- is in it). Never the admin, the HR Admin or HR, never another state's people.
-- Computed once per statement: lists and read rules ask "id in (select unnest(app.sm_seen_ids()))", a sub-select the planner
-- runs once (a per-row call took 0.15 s a person, 30 s for People & access with 240 people, 13 Oct).
create or replace function app.sm_seen_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  with s as materialized (select app.my_state_ids() as ids, app.current_user_id() as me)
  select coalesce(array_agg(u.id), '{}') from public.app_users u, s
   where u.id = s.me
      or (not u.external and u.system_role = 'operational' and (
            exists (select 1 from public.assignments a left join public.scopes sc on sc.id = a.scope_id
                      left join public.clients c on c.id = a.client_id
                     where a.employee_id = u.id and a.active and coalesce(a.state_id, sc.state_id, c.state_id) = any (s.ids))
            or (not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active)
                and exists (select 1 from public.employee_org o left join public.openings op on op.id = o.opening_id
                             where o.employee_id = u.id and coalesce(o.base_state_id, op.state_id) = any (s.ids)))))
$$;
create or replace function app.sm_sees(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_person = any (app.sm_seen_ids()) $$;

-- the one place for "may this person be given a seat by me": app.assign and a seat inserted directly both ask it
create or replace function app.assert_assignable(p_employee uuid) returns void
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users;
begin
  select * into u from public.app_users where id = p_employee;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = app.current_user_id() then raise exception 'you cannot assign yourself' using errcode = '42501'; end if;
  if u.system_role = 'admin' then raise exception 'an admin oversees and holds no assignment' using errcode = '42501'; end if;
  if u.system_role in ('hr_admin', 'hr_resource') then
    raise exception 'HR holds no seat: an HR person works for states as HR (HR states), not as a manager or operator' using errcode = '42501'; end if;
  if u.external then raise exception 'a client''s login holds no stage' using errcode = '42501'; end if;
  if app.sm_limited() and not app.sm_sees(u.id) then
    raise exception 'this person is not in your state: a State Manager gives seats to the people of his own state' using errcode = '42501'; end if;
end $$;

-- a client's login is managed by me only if every client seat it holds is on a client I manage (one login may serve
-- clients of two states: neither State Manager may then offboard it or change its sign-in alone)
create or replace function app.manages_viewer_fully(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.manages_viewer(p_person)
     and not exists (select 1 from public.assignments a
                      where a.employee_id = p_person and a.active and a.lens = 'client'
                        and not app.manages_client(app.current_user_id(), a.client_id)) $$;

-- 2 · scopes: the Client Manager builds them; a new scope is in its client's state --------------------------------------
drop policy scopes_insert on public.scopes;
drop policy scopes_update on public.scopes;
create policy scopes_insert on public.scopes for insert to authenticated with check (app.runs_client(client_id));
create policy scopes_update on public.scopes for update to authenticated using (app.runs_client(client_id));

-- 3 · crops have a state; a State Manager writes the crops of his state ----------------------------------------------------
alter table public.crops add column if not exists state_id uuid references public.states(id);
create index if not exists crops_state_idx on public.crops (state_id);
drop policy crops_write on public.crops;
create policy crops_insert on public.crops for insert to authenticated
  with check (app.holds_op_role('state_supervisor') and state_id = any (app.my_state_ids()));
create policy crops_update on public.crops for update to authenticated
  using (app.holds_op_role('state_supervisor') and (state_id is null or state_id = any (app.my_state_ids())))
  with check (state_id = any (app.my_state_ids()));

create or replace function app.crops_state_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and tg_op = 'UPDATE'
     and old.state_id is not null and new.state_id is distinct from old.state_id then
    raise exception 'a crop''s state is set once' using errcode = '42501'; end if;
  return new;
end $$;
create trigger crops_a0_state_guard before update on public.crops for each row execute function app.crops_state_guard();

-- every crop change by a person is logged (target: the crop; the Audit log names it from the detail)
create or replace function app.crops_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text[];
begin
  if app.current_user_id() is null then return new; end if;
  if tg_op = 'INSERT' then
    perform app.audit('crop_added', new.id, jsonb_build_object('name', new.name, 'code', new.code,
      'state', (select name from public.states where id = new.state_id)));
    return new;
  end if;
  if old.state_id is null and new.state_id is not null then
    perform app.audit('crop_state_set', new.id, jsonb_build_object('name', new.name, 'code', new.code,
      'from', '', 'to', (select name from public.states where id = new.state_id)));
  end if;
  select coalesce(array_agg(key order by key), '{}') into k
    from jsonb_each(to_jsonb(new)) n where key not in ('state_id', 'created_at') and n.value is distinct from to_jsonb(old) -> key;
  if cardinality(k) > 0 then
    perform app.audit('crop_changed', new.id, jsonb_build_object('name', new.name, 'code', new.code, 'fields', to_jsonb(k)));
  end if;
  return new;
end $$;
create trigger crops_z0_audit after insert or update on public.crops for each row execute function app.crops_audit();

-- 4 · farmers: the Client Manager and procurement create; the farmer's state decides who is staff -------------------------
-- creates a client's farmers: its Client Manager, or someone at Procurement or Village Batch in one of its scopes
create or replace function app.farmer_create(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'scope' and exists (
              select 1 from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
               where sa.assignment_id = a.id and s.client_id = p_client and sa.stage_type in ('procurement', 'village_batch')))) $$;

-- the State Manager of the farmer's state (a farmer with no state: of the client's home state)
create or replace function app.farmer_staff(p_user uuid, p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.state_supervisor_of(p_user, coalesce(p_state, app.client_home(p_client))) $$;

-- the same, asked about the caller (what the read and write rules on farmers evaluate)
create or replace function app.i_staff_farmer(p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.farmer_staff(app.current_user_id(), p_client, p_state) $$;

-- unchanged meaning for the Client Manager and procurement; a State Manager now only through the client's home state
-- (not through a scope of that client in his state: that reached another state's farmers)
create or replace function app.farmer_write(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.farmer_create(p_client) or app.state_supervisor_of(app.current_user_id(), app.client_home(p_client)) $$;
create or replace function app.farmer_verifier(p_user uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.state_supervisor_of(p_user, app.client_home(p_client)) $$;

drop policy farmers_insert on public.farmers;
drop policy farmers_update on public.farmers;
drop policy farmers_read on public.farmers;
create policy farmers_insert on public.farmers for insert to authenticated with check (app.farmer_create(client_id));
create policy farmers_update on public.farmers for update to authenticated
  using (app.farmer_create(client_id) or app.i_staff_farmer(client_id, state_id));
-- who reads a farmer: the admin, the client's Client Manager, procurement, its login, and the State Manager of the
-- farmer's own state (not another state's, through a scope: migration 41)
create or replace function app.farmer_read(p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or app.farmer_create(p_client) or app.i_staff_farmer(p_client, p_state) or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client) $$;
create policy farmers_read on public.farmers for select to authenticated using (app.farmer_read(client_id, state_id));

-- 5 · who sees people: a State Manager, his state's (section 1); a client's login, only if fully his ---------------------
-- the no-argument helpers as sub-selects: asked once per statement, not once per person
drop policy users_read on public.app_users;
create policy users_read on public.app_users for select to authenticated using (
  (auth_uid = auth.uid()) or (select app.is_admin())
  or ((not external) and (((select app.is_hr()) and ((select app.hr_full()) or (id = (select app.current_user_id()))
                                             or (system_role = any (array['hr_admin'::system_role, 'hr_resource'::system_role]))
                                             or app.hr_covers(id)))
                          or ((select app.can_assign()) and (status <> 'offboarded'::employee_status) and (not (select app.sm_limited()) or id in (select unnest(app.sm_seen_ids()))))))
  or (external and app.manages_viewer(id)));
drop policy users_update on public.app_users;
create policy users_update on public.app_users for update to authenticated using (
  (app.is_admin() and (not external) and app.hr_may_manage(system_role))
  or ((not external) and app.is_hr() and app.hr_may_manage(system_role) and app.hr_covers(id))
  or (external and app.manages_viewer_fully(id)));
drop policy employee_org_read on public.employee_org;
create policy employee_org_read on public.employee_org for select to authenticated using (
  (employee_id = (select app.current_user_id())) or (select app.is_admin()) or ((select app.is_hr()) and app.hr_covers(employee_id))
  or ((select app.can_assign()) and (not (select app.sm_limited()) or employee_id in (select unnest(app.sm_seen_ids())))));

-- the Health page's error list is the admin's
drop policy client_errors_read on public.client_errors;
create policy client_errors_read on public.client_errors for select to authenticated using (app.is_admin());

-- 6 · no override for a State Manager (as for the admin): a QC override is the Client Manager's ---------------------------
drop policy qc_verdicts_override on public.qc_verdicts;
create policy qc_verdicts_override on public.qc_verdicts for update to authenticated using (
  exists (select 1 from public.footprints f join public.scopes s on s.id = f.scope_id
           where f.id = qc_verdicts.footprint_id and app.runs_client(s.client_id)));



-- 7 · functions brought up to these rules (their current definitions, changed where marked) -----------------------

CREATE OR REPLACE FUNCTION app.scopes_place()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.state_id is null then
    select c.state_id into new.state_id from public.clients c where c.id = new.client_id;
  end if;
  -- migration 41: a new scope is in its client's own state (Veda, 13 Oct); its crop is of that state or has none
  if auth.uid() is not null
     and (tg_op = 'INSERT' or new.client_id is distinct from old.client_id or new.state_id is distinct from old.state_id)
     and new.state_id is distinct from (select c.state_id from public.clients c where c.id = new.client_id) then
    raise exception 'a scope is in its client''s own state' using errcode = '42501'; end if;
  if auth.uid() is not null and (tg_op = 'INSERT' or new.crop_id is distinct from old.crop_id)
     and exists (select 1 from public.crops cr where cr.id = new.crop_id and cr.state_id is not null and cr.state_id <> new.state_id) then
    raise exception 'this crop belongs to another state' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' and new.state_id is distinct from old.state_id then
    raise exception 'a scope''s state is frozen after activation; open a new scope' using errcode = '42501';
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.my_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
             'can', jsonb_build_object('admin', app.is_admin(), 'hr', app.is_hr() or (app.is_admin() and not app.hr_seat_filled()),
                                       'hr_admin', app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled()),
                                       'audit', app.is_hr_admin() or app.is_admin(), 'oversee', app.is_admin(), 'hr_seat_filled', app.hr_seat_filled(),
                                       'assign', app.can_assign(), 'state_lens', app.is_admin() or app.holds_op_role('state_supervisor'),
                                       'state_seat', app.is_hr_admin(),
                                       'state_manager', app.sm_limited(), 'build_scope', not app.is_admin() and app.holds_op_role('client_account'))),
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
               'manage', app.manages_scope_row(s.client_id, s.state_id), 'build', app.runs_client(s.client_id),
               'whole', app.is_admin() or app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id))
               order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
        join public.states st on st.id = s.state_id
       where app.sees_scope_row(s.id, s.client_id, s.state_id)), '[]'::jsonb)
  );
end $function$;

CREATE OR REPLACE FUNCTION app.farmers_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' then
    if new.verified_by is null then raise exception 'farmer verification needs verified_by' using errcode = '23514'; end if;
    if not app.farmer_staff(new.verified_by, new.client_id, new.state_id) then raise exception 'only a State Manager issues a Farmer ID' using errcode = '42501'; end if;
    new.verified_at := coalesce(new.verified_at, now());
    if new.farmer_code is null then
      new.farmer_code := app.next_farmer_code(new.client_id);
    end if;
  elsif tg_op = 'INSERT' and new.status = 'active' then
    raise exception 'farmers are created as draft/under_review; activation is a verification act' using errcode = '23514';
  end if;
  return new;
end$function$;

CREATE OR REPLACE FUNCTION app.farmers_change_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  staff := coalesce(app.farmer_staff(app.current_user_id(), new.client_id, old.state_id), false);   -- migration 41: the farmer's state
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
end$function$;

CREATE OR REPLACE FUNCTION app.farmers_two_steps()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); st text;
begin
  if tg_op = 'INSERT' then
    new.state_id := coalesce(new.state_id, (select c.state_id from public.clients c where c.id = new.client_id));
    if auth.uid() is not null then new.reviewed_by := null; new.reviewed_at := null; end if;   -- a person cannot pre-verify
  end if;
  if new.state_id is not null and (tg_op = 'INSERT' or new.state_id is distinct from old.state_id)
     and not (new.state_id = any (app.client_states(new.client_id))) then
    raise exception 'a farmer''s state must be one the client works in' using errcode = '23514'; end if;
  if auth.uid() is null then return new; end if;                         -- service role, seeds, migrations
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'a farmer is added as a draft: the Client Manager verifies it' using errcode = '42501'; end if;
    return new;
  end if;

  if new.state_id is null and old.state_id is not null then
    raise exception 'a farmer''s state cannot be left blank' using errcode = '23514'; end if;   -- migration 41
  if new.state_id is distinct from old.state_id and old.status <> 'draft' then
    raise exception 'a farmer''s state is chosen before the Client Manager verifies' using errcode = '42501'; end if;
  if new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
    if not (old.status = 'draft' and new.status = 'under_review') and not (old.status = 'under_review' and new.status = 'draft') then
      raise exception 'the first verification is recorded by the server' using errcode = '42501'; end if;
  end if;

  -- step 1: the Client Manager verifies
  if old.status = 'draft' and new.status = 'under_review' then
    if me is null or not app.client_account_holder(me, new.client_id) then
      raise exception 'the Client Manager of this client verifies a farmer first' using errcode = '42501'; end if;
    new.reviewed_by := me; new.reviewed_at := now();
  end if;
  -- sent back: step 1 has to be done again
  if old.status = 'under_review' and new.status = 'draft' then
    new.reviewed_by := null; new.reviewed_at := null;
  end if;
  -- step 2: the State Manager of the farmer's state checks the location and issues the Farmer ID
  -- migration 41: on EVERY route to a first Farmer ID (not only from under review), and with no state the client's
  if new.status = 'active' and old.status <> 'active' and old.farmer_code is null then
    if old.status <> 'under_review' then
      raise exception 'the Client Manager has not verified this farmer yet' using errcode = '42501'; end if;
    st := null;
    if true then
      if not app.state_supervisor_of(new.verified_by, coalesce(new.state_id, app.client_home(new.client_id))) then
        select name into st from public.states where id = coalesce(new.state_id, app.client_home(new.client_id));
        raise exception 'only the State Manager of % verifies this farmer''s location', coalesce(st, 'the farmer''s state') using errcode = '42501'; end if;
      if new.reviewed_by is null then
        raise exception 'the Client Manager has not verified this farmer yet' using errcode = '42501'; end if;
      if new.reviewed_by = new.verified_by then
        raise exception 'the second verification is by another person than the first' using errcode = '42501'; end if;
    end if;
  end if;
  -- a farmer once verified and later deactivated is reactivated by the State Manager of its state only
  if new.status = 'active' and old.status <> 'active' and old.farmer_code is not null
     and not app.state_supervisor_of(new.verified_by, coalesce(new.state_id, app.client_home(new.client_id))) then
    raise exception 'a farmer is activated or deactivated by the State Manager of its state' using errcode = '42501'; end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.send_back_farmer(p_farmer uuid, p_reason text)
 RETURNS farmers
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare r public.farmers;
begin
  if not coalesce((select app.i_staff_farmer(f.client_id, f.state_id) from public.farmers f where f.id = p_farmer), false) then
    raise exception 'only a State Manager sends a farmer back' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.farmers set status = 'draft', extra = extra || jsonb_build_object('sent_back_reason', btrim(p_reason))
   where id = p_farmer and status = 'under_review' returning * into r;
  if r.id is null then raise exception 'farmer not found or not waiting for verification' using errcode = 'P0002'; end if;
  return r;
end$function$;

CREATE OR REPLACE FUNCTION app.import_farmers(p_client uuid, p_rows jsonb, p_dry_run boolean DEFAULT true, p_scope_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare r jsonb; i int := 0; rn int; errs jsonb := '[]'::jsonb; ph text; area numeric; seen text[] := '{}';
        req text[] := array['name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
        k text; n int := 0; known text[] := array['row', 'name', 'guardian_name', 'village', 'district', 'phone', 'land_area_acres'];
begin
  if not app.farmer_create(p_client) then   -- migration 41: the Client Manager and procurement, not a State Manager
    raise exception 'farmers are added by the Client Manager of the client (or at Procurement)' using errcode = '42501'; end if;
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
    values (p_client, coalesce(p_scope_ids, '{}'), 'draft', btrim(r->>'name'), btrim(r->>'guardian_name'),
            btrim(r->>'village'), btrim(r->>'district'), app.normalise_in_mobile(r->>'phone'),
            (r->>'land_area_acres')::numeric,
            coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(r) e where not e.key = any(known)), '{}'::jsonb) ||
            jsonb_build_object('imported', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', false, 'rows', i, 'errors', '[]'::jsonb, 'inserted', n);
end$function$;

CREATE OR REPLACE FUNCTION app.assign(p_employee uuid, p_lens assignment_lens, p_target uuid, p_op_role op_role, p_stages stage_type[] DEFAULT '{}'::stage_type[], p_posting text DEFAULT NULL::text, p_ends_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); a public.assignments; sc public.scopes; st public.stage_type; v_stages public.stage_type[] := '{}';
        w jsonb;
begin
  if not app.may_assign(p_lens, p_op_role, p_target) then
    raise exception 'you cannot give this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if p_employee = me then
    raise exception 'you cannot assign yourself' using errcode = '42501'; end if;
  if app.user_is_admin(p_employee) then
    raise exception 'an admin oversees and holds no assignment' using errcode = '42501'; end if;
  -- Veda, 12 Oct 2026: "HR should never be the State Manager. HR can govern the state wrt onboarding" (migration 39)
  if exists (select 1 from public.app_users where id = p_employee and system_role in ('hr_admin', 'hr_resource')) then
    raise exception 'HR holds no seat: an HR person works for states as HR (HR states), not as a manager or operator' using errcode = '42501'; end if;
  if app.sm_limited() and not app.sm_sees(p_employee) then   -- migration 41
    raise exception 'this person is not in your state: a State Manager gives seats to the people of his own state' using errcode = '42501'; end if;
  if exists (select 1 from public.assignments x where x.employee_id = p_employee and x.active and x.lens = p_lens
                and p_target in (x.scope_id, x.client_id, x.state_id)) then
    raise exception 'this person is already assigned here: change the stages, or end that assignment first' using errcode = '23514'; end if;

  if p_lens = 'scope' then
    select * into sc from public.scopes where id = p_target;
    if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
    select coalesce(array_agg(x order by array_position(sc.chain, x)), '{}') into v_stages
      from (select distinct unnest(coalesce(p_stages, '{}')) as x) q;
    foreach st in array v_stages loop
      if not (st = any(sc.chain)) then raise exception 'stage % is not in this scope''s chain', st using errcode = '23514'; end if;
    end loop;
    if p_op_role = 'operator' and cardinality(v_stages) = 0 then
      raise exception 'choose at least one stage for an operator' using errcode = '23514'; end if;
  elsif cardinality(coalesce(p_stages, '{}')) > 0 then
    raise exception 'stages belong to a scope assignment' using errcode = '23514';
  end if;

  w := app.assignment_warnings(p_employee, p_lens, p_target, p_op_role, v_stages);
  perform set_config('app.assigning', 'on', true);
  insert into public.assignments (employee_id, lens, op_role, scope_id, client_id, state_id, stages, posting, ends_on, created_by)
  values (p_employee, p_lens, p_op_role,
          case when p_lens = 'scope' then p_target end, case when p_lens = 'client' then p_target end, case when p_lens = 'state' then p_target end,
          v_stages, nullif(btrim(p_posting), ''), p_ends_on, me)
  returning * into a;
  foreach st in array v_stages loop
    insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (p_employee, p_target, st, a.id);
  end loop;
  perform set_config('app.assigning', '', true);

  perform app.audit('assigned', p_employee, jsonb_build_object('assignment_id', a.id, 'lens', a.lens, 'op_role', a.op_role,
    'scope_id', a.scope_id, 'client_id', a.client_id, 'state_id', a.state_id, 'stages', to_jsonb(a.stages), 'posting', a.posting,
    'name', (select display_name from public.app_users where id = p_employee), 'warnings', w));
  -- F3 (migration 38): a State Manager seated by the Deputy, not the HR Admin, is flagged
  if p_lens = 'state' and not app.is_hr_admin() then
    perform app.audit('state_seated_by_deputy', p_employee, jsonb_build_object('state_id', p_target,
      'name', (select display_name from public.app_users where id = p_employee)), true); end if;
  return jsonb_build_object('assignment', to_jsonb(a), 'warnings', w);
end $function$;

CREATE OR REPLACE FUNCTION app.slots_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a public.assignments;
begin
  if new.assignment_id is not null then
    select * into a from public.assignments where id = new.assignment_id;
    if a.id is null or not a.active or a.lens <> 'scope' or a.employee_id <> new.user_id or a.scope_id <> new.scope_id then
      raise exception 'that stage does not belong to this assignment' using errcode = '23514'; end if;
    return new;
  end if;
  select * into a from public.assignments
   where employee_id = new.user_id and scope_id = new.scope_id and lens = 'scope' and active;
  if a.id is null then
    -- migration 41: a seat inserted directly (not through app.assign) follows the same person rules
    if auth.uid() is not null and coalesce(current_setting('app.assigning', true), '') <> 'on' then
      perform app.assert_assignable(new.user_id); end if;
    insert into public.assignments (employee_id, lens, op_role, scope_id, created_by, stages)
    values (new.user_id, 'scope', 'operator', new.scope_id, app.current_user_id(), array[new.stage_type]) returning * into a;
  end if;
  new.assignment_id := a.id;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.people_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb; v_limited boolean := app.is_hr() and not app.hr_full(); v_mine uuid[] := app.my_hr_states();
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner, o.base_state_id, o.base_district
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
       and (not v_limited or u.id = me or o.base_state_id = any(v_mine))
       and (full_view or u.external or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))   -- migration 41
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or lower(coalesce(v.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state)
            or v.base_state_id = v_state)
       and (v_client is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
                                         where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_client in (a.client_id, s.client_id)))
       and (v_role is null or v.intended_role = v_role)
       and (v_open is null or v.opening_id = v_open)
       and (v_owner is null or (v_owner = 'mine' and v.hr_owner = me) or (v_owner not in ('mine', 'none') and v.hr_owner::text = v_owner)
            or (v_owner = 'none' and v.hr_owner is null))
       and (not v_unass or not exists (select 1 from public.assignments a where a.employee_id = v.id and a.active))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'counts', (select jsonb_build_object('employees', count(*) filter (where not external), 'client_logins', count(*) filter (where external)) from vis),
    'rows', coalesce((select jsonb_agg(x.j order by x.external, x.display_name) from (
      select f.external, f.display_name, jsonb_build_object(
             'id', f.id, 'name', f.display_name, 'email', f.email, 'phone', f.phone, 'status', f.status, 'system_role', f.system_role,
             'external', f.external, 'join_date', f.join_date, 'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
             'role', f.intended_role, 'stage', f.intended_stage,
             'opening_code', (select code from public.openings where id = f.opening_id),
             'base', jsonb_build_object('state_id', f.base_state_id, 'state_name', (select name from public.states where id = f.base_state_id),
                                        'district', f.base_district),
             'org', jsonb_build_object('employment_type', f.employment_type, 'designation_band', f.designation_band,
                      'department', f.department, 'job_title', f.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = f.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = f.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', (select count(*) from public.assignments a where a.employee_id = f.id and a.active and not app.assignment_visible(a)),
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION app.people_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare full_view boolean;
begin
  perform app.me_or_raise();
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status, 'system_role', u.system_role,
             'external', u.external, 'join_date', u.join_date, 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
             'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band,
                      'department', o.department, 'job_title', o.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = o.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)),
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active))
           order by u.external, u.display_name)
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where (not u.external and (full_view or u.status <> 'offboarded') and (full_view or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))
            and (not app.is_hr() or app.hr_full() or u.id = app.current_user_id() or o.base_state_id = any(app.my_hr_states())))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.employee_profile(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; full_view boolean; hr_ok boolean;
begin
  select * into u from public.app_users where id = p_employee;
  full_view := app.is_admin() or (app.is_hr() and (app.hr_full() or app.hr_covers(p_employee)));
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded' and (not app.sm_limited() or app.sm_sees(u.id)))))
                          or (u.external and (app.is_admin() or app.manages_viewer(u.id)))) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  hr_ok := app.may_manage_person(u.id);
  return jsonb_build_object(
    'identity', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
                  'external', u.external, 'join_date', u.join_date, 'created_at', u.created_at,
                  'has_login', u.auth_uid is not null and u.auth_uid <> u.id),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'system_role', u.system_role,
    'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                               from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(app.assignment_json(a) order by a.ended_at desc)
                           from public.assignments a where a.employee_id = u.id and not a.active and app.assignment_visible(a)), '[]'::jsonb),
    'elsewhere', (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)),
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', (app.is_hr_admin() or (app.can_assign() and not app.is_admin())) and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> me and u.system_role not in ('admin', 'hr_admin', 'hr_resource'),
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

CREATE OR REPLACE FUNCTION app.may_manage_person(p_employee uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee;
  if me is null or u.id is null or u.id = me then return false; end if;
  if u.external then return app.manages_viewer_fully(u.id); end if;   -- migration 41: a login shared with another state's client
  return (app.is_admin() or app.is_hr()) and app.hr_may_manage_person(u.id);
end $function$;

CREATE OR REPLACE FUNCTION app.state_overview(p_state uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform app.me_or_raise();
  if not (app.is_admin() or p_state = any(app.my_state_ids())) then
    raise exception 'no access to this state' using errcode = '42501'; end if;
  return jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = p_state),
    'supervisors', coalesce((select jsonb_agg(jsonb_build_object('employee_id', u.id, 'name', u.display_name, 'status', u.status) order by u.display_name)
                               from public.assignments a join public.app_users u on u.id = a.employee_id
                              where a.active and a.lens = 'state' and a.state_id = p_state), '[]'::jsonb),
    'scopes', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client_id', s.client_id, 'client_name', c.name, 'crop_name', cr.name,
               'season_code', s.season_code, 'geography', s.geography, 'status', s.status, 'stages', cardinality(s.chain),
               'gaps', to_jsonb(app.coverage_gaps(s.id)),
               'people', (select count(distinct a.employee_id) from public.assignments a where a.active and a.lens = 'scope' and a.scope_id = s.id))
               order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
       where s.state_id = p_state), '[]'::jsonb),
    'clients', (select count(*) from public.clients c where c.state_id = p_state),
    'clients_active', (select count(distinct s.client_id) from public.scopes s where s.state_id = p_state and s.status = 'active'),
    'people', (select count(distinct a.employee_id) from public.assignments a join public.scopes s on s.id = a.scope_id
                where a.active and a.lens = 'scope' and s.state_id = p_state),
    'unassigned', (select count(*) from public.app_users u where not u.external and u.status = 'active' and u.system_role = 'operational'
                      and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active)));
end $function$;

-- 8 · the State Manager's overview of his state (and the admin's, for any state) -------------------------------------------
-- Every number says what it counts. Clients: those of the state (home state), with how many have an active scope. Crops:
-- the state's own, and how many have no state yet. "Needs my action" is the sum of the four lists it shows.
create or replace function app.state_home(p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'no access to this state' using errcode = '42501'; end if;
  if not exists (select 1 from public.states where id = p_state) then raise exception 'state not found' using errcode = 'P0002'; end if;
  with sc as (select s.* from public.scopes s where s.state_id = p_state),
  live as (
    select distinct sa.scope_id, sa.stage_type
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'
       and sa.scope_id in (select id from sc)),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from sc s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' and f.scope_id in (select id from sc)
     group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id
     where f.scope_id in (select id from sc) group by f.scope_id),
  waiting as (
    select f.scope_id, count(*) as n from public.footprints f
     where f.status = 'pending' and f.scope_id in (select id from sc) group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join sc s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  mgr as (
    select a.client_id, string_agg(distinct u.display_name, ', ') as names
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())
     group by a.client_id),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'draft') as scopes_setup,
           (select count(*) from sc s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(v.lots) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as lots,
           coalesce((select sum(q.n) from qr q join sc s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           coalesce((select sum(w.n) from waiting w join sc s on s.id = w.scope_id where s.client_id = c.id), 0) as waiting,
           (select m.names from mgr m where m.client_id = c.id) as managers,
           exists (select 1 from mgr m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id
     where c.state_id = p_state or exists (select 1 from sc s where s.client_id = c.id)),
  fw as (
    select f.id, f.name, f.village, f.client_id, c.name as client
      from public.farmers f join public.clients c on c.id = f.client_id
     where f.status = 'under_review' and f.reviewed_by is not null and coalesce(f.state_id, c.state_id) = p_state),
  fl as (
    select fl.id, fl.text, fl.created_at, fl.footprint_id, f.footprint_code, c.name as client
      from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
     where fl.status = 'open' and f.scope_id in (select id from sc)),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from sc s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- chain order, as on the admin's pipeline: each stage's average step in the active chains of the state; the seal last
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from sc s where s.status = 'active') then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from sc s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = p_state),
    'managers', coalesce((select jsonb_agg(u.display_name order by u.display_name) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and a.state_id = p_state and u.status = 'active'), '[]'),
    'clients', jsonb_build_object(
       'total', (select count(*) from cl where cl.state_id = p_state),
       'active', (select count(*) from cl where cl.state_id = p_state and scopes_active > 0),
       'without_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops where state_id = p_state),
       'state_not_set', (select count(*) from public.crops where state_id is null),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from sc s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from sc s where s.crop_id = cr.id)) order by cr.name)
                  from public.crops cr where cr.state_id = p_state), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from sc where status = 'active'),
       'setup', (select count(*) from sc where status = 'draft'),
       'closed', (select count(*) from sc where status = 'closed'),
       'qr_issued', coalesce((select sum(n) from qr), 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client', c.name, 'crop', cr.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'status', s.status) order by s.status, c.name)
                  from sc s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id), '[]')),
    'farmers', jsonb_build_object(
       'total', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id where coalesce(f.state_id, c.state_id) = p_state),
       'active', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id
                   where coalesce(f.state_id, c.state_id) = p_state and f.status = 'active')),
    'attention', jsonb_build_object(
       'no_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'no_manager_list', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'name', cl.name, 'code', cl.code) order by cl.name)
                                      from cl where cl.state_id = p_state and not has_manager), '[]'),
       'farmers_waiting', (select count(*) from fw),
       'farmers_list', coalesce((select jsonb_agg(to_jsonb(fw) order by fw.client, fw.name) from (select * from fw order by client, name limit 50) fw), '[]'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join sc s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'open_flags', (select count(*) from fl),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', fl.footprint_code, 'client', fl.client) order by fl.created_at) from fl), '[]')),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp
                           where pp.position is not null or pp.pending + pp.done > 0), '[]')
  ) into r;
  return r;
end $$;

-- 9 · the ledger of one state, read-only ---------------------------------------------------------------------------------
-- A block belongs to a state through its scope (or its record's scope), the farmer it is about, the client it is about,
-- or the state it names. Blocks with none of these (a sign-in made, an HR act) stay in the admin's whole ledger.
create or replace function app.uuid_or_null(p text) returns uuid
language sql immutable set search_path = public as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end $$;

create or replace function app.state_ledger_page(p_state uuid, p_event text, p_client uuid, p_scope uuid, p_actor uuid,
                                                 p_limit integer, p_offset integer) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); total bigint; rows jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'the ledger of a state is for its State Manager' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type,
           coalesce(f.client_id, s.client_id, app.uuid_or_null(l.payload->>'client_id'), fa.client_id) as client_id,
           s.id as the_scope,
           coalesce(s.state_id, fa.state_id, (select c.state_id from public.clients c where c.id = app.uuid_or_null(l.payload->>'client_id')),
                    app.uuid_or_null(l.payload->>'state_id')) as state_id
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id, app.uuid_or_null(l.payload->>'scope_id'))
      left join public.farmers fa on fa.id = app.uuid_or_null(l.payload->>'farmer_id')),
  m as (select * from b where b.state_id = p_state
          and (p_event is null or b.event::text = p_event) and (p_actor is null or b.actor = p_actor)
          and (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_summary_role', u.role)
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset,
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from public.clients c
                             where c.state_id = p_state or exists (select 1 from public.scopes s where s.client_id = c.id and s.state_id = p_state)), '[]'),
       'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_id', s.client_id)
                             order by cr.name, s.season_code) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.state_id = p_state), '[]')),
    -- the chain is checked whole: the last check of the whole ledger, without a button to run one
    'check', (select jsonb_build_object('checked_at', k.checked_at, 'ok', k.ok, 'blocks', k.blocks, 'first_bad_seq', k.first_bad_seq, 'source', k.source)
                from public.ledger_checks k order by k.checked_at desc limit 1));
end $$;

-- 10 · closed by default; opened by name ----------------------------------------------------------------------------------
revoke execute on function app.client_home(uuid) from public, anon, authenticated;
revoke execute on function app.runs_client(uuid) from public, anon, authenticated;
revoke execute on function app.sm_limited() from public, anon, authenticated;
revoke execute on function app.sm_sees(uuid) from public, anon, authenticated;
revoke execute on function app.sm_seen_ids() from public, anon, authenticated;
revoke execute on function app.assert_assignable(uuid) from public, anon, authenticated;
revoke execute on function app.manages_viewer_fully(uuid) from public, anon, authenticated;
revoke execute on function app.crops_state_guard() from public, anon, authenticated;
revoke execute on function app.crops_audit() from public, anon, authenticated;
revoke execute on function app.farmer_create(uuid) from public, anon, authenticated;
revoke execute on function app.farmer_staff(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function app.i_staff_farmer(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.farmer_read(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.state_home(uuid) from public, anon, authenticated;
revoke execute on function app.uuid_or_null(text) from public, anon, authenticated;
revoke execute on function app.state_ledger_page(uuid, text, uuid, uuid, uuid, integer, integer) from public, anon, authenticated;
-- helpers the rules evaluate as the caller (each answers about the caller), the trigger's person check, the two reads
grant execute on function app.runs_client(uuid) to authenticated;
grant execute on function app.sm_limited() to authenticated;
grant execute on function app.sm_sees(uuid) to authenticated;
grant execute on function app.sm_seen_ids() to authenticated;
grant execute on function app.assert_assignable(uuid) to authenticated;
grant execute on function app.manages_viewer_fully(uuid) to authenticated;
grant execute on function app.farmer_create(uuid) to authenticated;
grant execute on function app.i_staff_farmer(uuid, uuid) to authenticated;
grant execute on function app.farmer_read(uuid, uuid) to authenticated;
grant execute on function app.state_home(uuid) to authenticated;
grant execute on function app.state_ledger_page(uuid, text, uuid, uuid, uuid, integer, integer) to authenticated;
