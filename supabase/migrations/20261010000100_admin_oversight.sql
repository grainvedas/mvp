-- Migration 34 · ADMIN OVERSIGHT (Veda, 10 October 2026, review of the live app as Admin).
-- "Admin is oversight only. The Admin watches the operation and uses the dashboard to make strategic decisions."
-- Override was dropped for now (Veda: "it will create confusion"): what the admin may not do, the admin cannot do.
--
-- The admin KEEPS: reading everything; states; seating a State Manager (the state lens); the two seats; the sign-in code switch; the ledger check;
-- adding a joiner and every HR act while the HR Admin seat is empty; HR acts on the HR Admin and on admins (nobody else
-- may do them).
-- The admin LOSES (refused by these rules, whatever a screen shows): stage work (record, verify, seal, withdraw,
-- correct, verdict override, resolve a flag); farmers (create, import, submit, verify, send back, deactivate); clients
-- (create, edit) and client logins; crops (the State Manager's now); scopes (create, chain, activate) and their rosters; giving a client's account or a
-- scope assignment; HR acts on everyone else once the HR Admin seat is filled; checklist templates once it is filled.
-- And: assignments held by an admin grant nothing, and an admin cannot be given one (else the admin could seat
-- themselves as State Manager and do it all again).
--
-- How: the admin's power came from a few shared rules. Each is the version in force (read back from the database, not
-- retyped) with exactly the change named above it. Reads that used to come through "manages" now ask "is admin" on
-- their own. New: app.hr_seat_filled, app.platform_overview (the admin's dashboard), app.ledger_page (every block).
-- Nothing is deleted or rewritten: no row, no ledger block. Tests: tests/28_admin_oversight.sql.

-- 1 · the HR Admin seat -------------------------------------------------------------------------------------------------
-- Filled while an ACTIVE person holds it: if the HR Admin is suspended or has left, HR acts fall back to the admin.
create or replace function app.hr_seat_filled() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users where system_role = 'hr_admin' and status = 'active')
$$;

-- 2 · HR acts: the admin only while the seat is empty, and always on the HR Admin and on admins

CREATE OR REPLACE FUNCTION app.hr_may_manage(p_target system_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case (select system_role from public.app_users where id = app.current_user_id() and status = 'active')
    when 'admin' then not app.hr_seat_filled() or p_target in ('hr_admin', 'admin')
    when 'hr_admin' then p_target in ('hr_resource', 'operational')
    when 'hr_resource' then p_target = 'operational'
    else false end
$function$;

-- 3 · an admin's own assignments grant nothing (the admin oversees; to do a job, a person holds it without the admin seat)

CREATE OR REPLACE FUNCTION app.eff_assignments(p_user uuid)
 RETURNS SETOF assignments
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select a.* from public.assignments a join public.app_users u on u.id = a.employee_id
   where a.employee_id = p_user and a.active and u.status = 'active' and u.system_role <> 'admin'
     and (a.ends_on is null or a.ends_on >= app.today())
$function$;

CREATE OR REPLACE FUNCTION app.has_slot(p_user uuid, p_scope uuid, p_stage stage_type)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = p_user and sa.scope_id = p_scope and sa.stage_type = p_stage
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin')
$function$;

CREATE OR REPLACE FUNCTION app.acts_in_scope(p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.i_manage_scope(p_scope) or exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = app.current_user_id() and sa.scope_id = p_scope
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin')
$function$;

CREATE OR REPLACE FUNCTION app.can_see_footprint(p_scope uuid, p_stage stage_type)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.sees_whole_scope(p_scope) or exists (
    select 1 from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where sa.user_id = app.current_user_id() and sa.scope_id = p_scope
       and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'
       and (sa.stage_type = p_stage or app.chain_prev(p_scope, sa.stage_type) = p_stage))
$function$;

-- 4 · managing a place (scope rules, stage work, roster), a client, farmers: by assignment only; no longer the admin

CREATE OR REPLACE FUNCTION app.manages_place(p_user uuid, p_client uuid, p_state uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from app.eff_assignments(p_user) a
     where (a.lens = 'state' and a.state_id = p_state)
        or (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client))
$function$;

CREATE OR REPLACE FUNCTION app.manages_client(p_user uuid, p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from app.eff_assignments(p_user) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_client)))
$function$;

CREATE OR REPLACE FUNCTION app.farmer_write(p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                  or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
        or (a.lens = 'scope' and exists (
              select 1 from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
               where sa.assignment_id = a.id and s.client_id = p_client and sa.stage_type in ('procurement', 'village_batch'))))
$function$;

CREATE OR REPLACE FUNCTION app.farmer_verifier(p_user uuid, p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from app.eff_assignments(p_user) a
     where a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                 or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
$function$;

-- 5 · what the admin reads, now asked on its own (it used to come through "manages")

CREATE OR REPLACE FUNCTION app.farmer_access(p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.is_admin() or app.farmer_write(p_client) or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client)
$function$;

CREATE OR REPLACE FUNCTION app.sees_scope_row(p_scope uuid, p_client uuid, p_state uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.is_admin() or app.manages_scope_row(p_client, p_state) or app.views_scope_row(p_scope, p_client)
      or exists (select 1 from app.eff_assignments(app.current_user_id()) a where a.lens = 'scope' and a.scope_id = p_scope)
$function$;

CREATE OR REPLACE FUNCTION app.sees_whole_scope(p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.is_admin() or coalesce((select app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id)
                     from public.scopes s where s.id = p_scope), false)
$function$;

-- 6 · assignments: the admin seats State Managers (the state lens) and nothing else; nobody assigns an admin or themself

CREATE OR REPLACE FUNCTION app.may_assign(p_lens assignment_lens, p_op_role op_role, p_target uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null then return false; end if;
  if app.is_admin() then return p_lens = 'state'; end if;                       -- the admin seats State Managers only
  if p_lens = 'state' then return false; end if;                              -- a state supervisor is appointed by the admin
  if p_lens = 'client' then
    if p_op_role = 'client_account' then                                      -- a client's account: by a supervisor of its home state
      return exists (select 1 from app.eff_assignments(me) a
                      where a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_target));
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $function$;

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
  return jsonb_build_object('assignment', to_jsonb(a), 'warnings', w);
end $function$;

-- 7 · people: client logins belong to who manages the client; HR acts as in 2

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
  if u.external then return app.manages_viewer(u.id); end if;
  return (app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role);
end $function$;

CREATE OR REPLACE FUNCTION app.reset_login_allowed(p_target uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); tgt public.app_users;
begin
  if me is null or p_target is null or p_target = me then return false; end if;      -- your own: change it yourself
  select * into tgt from public.app_users where id = p_target;
  if tgt.id is null or tgt.status = 'offboarded' then return false; end if;
  if app.is_admin() and not tgt.external and app.hr_may_manage(tgt.system_role) then return true; end if;
  if tgt.external then
    return exists (select 1 from public.assignments a
                    where a.employee_id = tgt.id and a.active and a.lens = 'client' and app.manages_client(me, a.client_id));
  end if;
  return app.is_hr() and app.hr_may_manage(tgt.system_role);
end $function$;

CREATE OR REPLACE FUNCTION app.note_invite_sent(p_employee uuid, p_how text DEFAULT 'password'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise();
begin
  if not ((app.is_admin() and not app.hr_seat_filled()) or app.is_hr() or app.manages_viewer(p_employee)) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  perform app.audit('invite_sent', p_employee, jsonb_build_object('how', left(coalesce(p_how, 'password'), 40)));
end $function$;

CREATE OR REPLACE FUNCTION app.add_joiner(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); my_role public.system_role; v_role public.system_role;
        v_name text := btrim(coalesce(p->>'full_name', '')); v_email text := app.email_key(p->>'personal_email');
        v_phone text; v_join date; v_type public.employment_type; v_tpl uuid; v_id uuid; n int;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  if my_role is null or my_role not in ('admin', 'hr_admin', 'hr_resource') then
    raise exception 'only HR adds a joiner' using errcode = '42501'; end if;
  v_role := coalesce(nullif(p->>'system_role', ''), 'operational')::public.system_role;
  -- Once the HR Admin seat is filled, onboarding belongs to HR: the admin adds only the two seats (admin, HR Admin).
  if my_role = 'admin' and app.hr_seat_filled() and v_role not in ('admin', 'hr_admin') then
    raise exception 'only HR adds joiners now: the HR Admin seat is filled' using errcode = '42501'; end if;
  -- HR onboards operational people and other HR resources; the admin seat and the HR Admin seat are the admin's to give.
  if v_role in ('admin', 'hr_admin') and my_role <> 'admin' then
    raise exception 'only the admin gives the % seat', v_role using errcode = '42501'; end if;
  if v_role = 'hr_admin' and exists (select 1 from public.app_users where system_role = 'hr_admin' and status <> 'offboarded') then
    raise exception 'the HR Admin seat is taken: there is exactly one' using errcode = '23514'; end if;

  if v_name = '' then raise exception 'full name is required' using errcode = '23514'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid personal email is required: it is the sign-in' using errcode = '23514'; end if;
  if coalesce(btrim(p->>'phone'), '') <> '' then
    v_phone := app.normalise_in_mobile(p->>'phone');
    if v_phone is null then raise exception 'phone must be a 10-digit Indian mobile number' using errcode = '23514'; end if;
  end if;
  begin v_join := (p->>'join_date')::date; exception when others then v_join := null; end;
  if v_join is null then raise exception 'join date is required' using errcode = '23514'; end if;
  v_type := coalesce(nullif(p->>'employment_type', ''), 'full_time')::public.employment_type;
  v_tpl := coalesce(nullif(p->>'template_id', '')::uuid, (select id from public.onboarding_templates where is_default and active));
  if v_tpl is null or not exists (select 1 from public.onboarding_templates where id = v_tpl and active) then
    raise exception 'no onboarding template: make one under HR → Templates' using errcode = '23514'; end if;

  begin
    insert into public.app_users (display_name, email, phone, status, system_role, join_date, created_by)
    values (v_name, v_email, v_phone, 'invited', v_role, v_join, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email or phone already exists' using errcode = '23505';
  end;
  insert into public.employee_org (employee_id, employment_type, designation_band, department, job_title, reports_to, buddy, updated_by)
  values (v_id, v_type, nullif(btrim(p->>'designation_band'), ''), nullif(btrim(p->>'department'), ''), nullif(btrim(p->>'job_title'), ''),
          nullif(p->>'reports_to', '')::uuid, nullif(p->>'buddy', '')::uuid, me);
  insert into public.employee_docs (employee_id) values (v_id);
  n := app.stamp_tasks(v_id, v_tpl, v_join, v_type);

  perform app.audit('identity_created', v_id, jsonb_build_object('name', v_name, 'system_role', v_role, 'employment_type', v_type,
                                                                 'join_date', v_join, 'tasks', n));
  if v_role = 'hr_resource' then
    -- an HR resource making another HR resource is allowed, and always flagged for the admin to see
    perform app.audit('hr_resource_created', v_id, jsonb_build_object('name', v_name, 'by_role', my_role), my_role = 'hr_resource');
  end if;
  return jsonb_build_object('id', v_id, 'tasks', n, 'status', 'invited');
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
  full_view := app.is_admin() or app.is_hr();
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded')))
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
    'exits', case when full_view then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', app.can_assign() and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> me and u.system_role <> 'admin',
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role <> 'hr_admin'
                  and (app.is_admin() or (app.is_hr_admin() and u.system_role in ('operational', 'hr_resource'))),
      'hr_record', full_view and not u.external));
end $function$;

-- 8 · what the app's menu and screens are told (the server decides; the screens only follow)

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
               'whole', app.is_admin() or app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id))
               order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
        join public.states st on st.id = s.state_id
       where app.sees_scope_row(s.id, s.client_id, s.state_id)), '[]'::jsonb)
  );
end $function$;
-- 9 · table rules that named the admin directly -------------------------------------------------------------------------
-- Clients: made and changed by the State Manager of the client's home state (the admin reads them).
alter policy clients_write on public.clients with check (state_id = any (app.my_state_ids()));
alter policy clients_update on public.clients using (state_id = any (app.my_state_ids()));
-- Crops: the State Manager's (Veda, 10 Oct 2026: "State Manager creates crop"). A crop is shared by every state, so
-- any State Manager may make or change one. The admin reads them; everyone reads them (crops_read).
drop policy crops_admin on public.crops;
create policy crops_write on public.crops for all to authenticated
  using (app.holds_op_role('state_supervisor')) with check (app.holds_op_role('state_supervisor'));
-- A person's own fields (name, phone, email): HR, or the admin where 2 allows; a client login: who manages the client.
alter policy users_update on public.app_users using (
  (app.is_admin() and not external and app.hr_may_manage(system_role))
  or ((not external) and app.is_hr() and app.hr_may_manage(system_role))
  or (external and app.manages_viewer(id)));
-- Joining checklists: the HR Admin's, and the admin's only while that seat is empty.
alter policy onboarding_templates_write on public.onboarding_templates
  using ((app.is_admin() and not app.hr_seat_filled()) or app.is_hr_admin())
  with check ((app.is_admin() and not app.hr_seat_filled()) or app.is_hr_admin());
alter policy template_tasks_write on public.template_tasks
  using ((app.is_admin() and not app.hr_seat_filled()) or app.is_hr_admin())
  with check ((app.is_admin() and not app.hr_seat_filled()) or app.is_hr_admin());

-- 10 · farmers: two verifications (Veda, 10 Oct 2026) -------------------------------------------------------------------
-- "Client Manager adds the farmer and verifies once, then State Manager verifies the farmer again by location only (as
-- farmer should be part of that state)." A farmer now belongs to a state (by default the client's home state; any state
-- the client works in). Step 1, draft → under_review, is the Client Manager's (the client's account), recorded as
-- reviewed_by / reviewed_at. Step 2, under_review → active (the Farmer ID), is the State Manager OF THAT STATE, and
-- never the person of step 1. Sending back clears step 1. Farmers made before this migration have no state: for them
-- step 2 stays as it was (a State Manager of a state the client works in), so nothing that exists is stranded.
alter table public.farmers add column state_id uuid references public.states(id);
alter table public.farmers add column reviewed_by uuid references public.app_users(id);
alter table public.farmers add column reviewed_at timestamptz;

create or replace function app.client_account_holder(p_user uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app.eff_assignments(p_user) a
                  where a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
$$;

create or replace function app.state_supervisor_of(p_user uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app.eff_assignments(p_user) a where a.lens = 'state' and a.state_id = p_state)
$$;

-- The states a client works in: its home state and the state of each of its scopes.
create or replace function app.client_states(p_client uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select state_id as x from public.clients where id = p_client
    union select state_id from public.scopes where client_id = p_client) q where x is not null
$$;

create or replace function app.farmers_two_steps() returns trigger
language plpgsql security definer set search_path = public as $$
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
  if old.status = 'under_review' and new.status = 'active' then
    if new.state_id is not null then
      if not app.state_supervisor_of(new.verified_by, new.state_id) then
        select name into st from public.states where id = new.state_id;
        raise exception 'only the State Manager of % verifies this farmer''s location', coalesce(st, 'the farmer''s state') using errcode = '42501'; end if;
      if new.reviewed_by is null then
        raise exception 'the Client Manager has not verified this farmer yet' using errcode = '42501'; end if;
      if new.reviewed_by = new.verified_by then
        raise exception 'the second verification is by another person than the first' using errcode = '42501'; end if;
    end if;
  end if;
  return new;
end $$;

create trigger farmers_z1_two_steps before insert or update on public.farmers
  for each row execute function app.farmers_two_steps();

-- The guard's words, now that the admin issues no Farmer ID.
CREATE OR REPLACE FUNCTION app.farmers_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' then
    if new.verified_by is null then raise exception 'farmer verification needs verified_by' using errcode = '23514'; end if;
    if not app.farmer_verifier(new.verified_by, new.client_id) then raise exception 'only a State Manager issues a Farmer ID' using errcode = '42501'; end if;
    new.verified_at := coalesce(new.verified_at, now());
    if new.farmer_code is null then
      new.farmer_code := app.next_farmer_code(new.client_id);
    end if;
  elsif tg_op = 'INSERT' and new.status = 'active' then
    raise exception 'farmers are created as draft/under_review; activation is a verification act' using errcode = '23514';
  end if;
  return new;
end$function$;

-- An imported file lands as drafts (it went straight to the State Manager before): the Client Manager verifies each.
CREATE OR REPLACE FUNCTION app.import_farmers(p_client uuid, p_rows jsonb, p_dry_run boolean DEFAULT true, p_scope_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
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
    values (p_client, coalesce(p_scope_ids, '{}'), 'draft', btrim(r->>'name'), btrim(r->>'guardian_name'),
            btrim(r->>'village'), btrim(r->>'district'), app.normalise_in_mobile(r->>'phone'),
            (r->>'land_area_acres')::numeric,
            coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(r) e where not e.key = any(known)), '{}'::jsonb) ||
            jsonb_build_object('imported', true));
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dry_run', false, 'rows', i, 'errors', '[]'::jsonb, 'inserted', n);
end$function$;
-- 11 · the admin's dashboard: the whole platform in one call ---------------------------------------------------------------
-- Counted here, not in the browser. "Live" stage holders are the ones the rules count (an active assignment of an
-- active person who is not an admin). Volume procured: the quantity out of the entry stages (Procurement, Lot Inward),
-- superseded records left out. Needs attention: open flags, farmers waiting for a verification (either step), and the
-- stages of active scopes that nobody holds.
create or replace function app.platform_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not app.is_admin() then
    raise exception 'the platform overview is for the admin' using errcode = '42501'; end if;
  with live as (
    select distinct sa.scope_id, sa.stage_type, sa.user_id
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from public.scopes s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join public.scopes s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  managed as (
    select distinct a.client_id from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from public.scopes s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from public.scopes s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join public.scopes s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(q.n) from qr q join public.scopes s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           exists (select 1 from managed m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from public.scopes s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order)
  select jsonb_build_object(
    'clients', jsonb_build_object(
       'total', (select count(*) from cl),
       'active', (select count(*) from cl where scopes_active > 0),
       'dormant', (select count(*) from cl where scopes_active = 0),
       'without_manager', (select count(*) from cl where not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.state_name, cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from public.scopes s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from public.scopes s where s.crop_id = cr.id)) order by cr.name)
                  from public.crops cr), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from public.scopes where status = 'active'),
       'setup', (select count(*) from public.scopes where status = 'draft'),
       'closed', (select count(*) from public.scopes where status = 'closed'),
       'qr_issued', (select count(*) from public.qr_seals)),
    'attention', jsonb_build_object(
       'open_flags', (select count(*) from public.flags where status = 'open'),
       'farmers_step1', (select count(*) from public.farmers where status = 'draft'),
       'farmers_step2', (select count(*) from public.farmers where status = 'under_review'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join public.scopes s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', f.footprint_code, 'client', c.name) order by fl.created_at)
                  from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
                  where fl.status = 'open'), '[]')),
    'states', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'code', st.code,
                  'managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                                where a.active and a.lens = 'state' and a.state_id = st.id and u.status = 'active')) order by st.name)
                  from public.states st), '[]'),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pipe) order by pipe.sort_order) from pipe where pipe.pending + pipe.done > 0), '[]'),
    'volume_by_state', coalesce((select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object('id', st.id, 'name', st.name, 'kg', coalesce(sum(v.kg), 0), 'lots', coalesce(sum(v.lots), 0),
               'qr', coalesce((select sum(q.n) from qr q join public.scopes s2 on s2.id = q.scope_id where s2.state_id = st.id), 0)) as x
          from public.states st left join public.scopes s on s.state_id = st.id left join vol v on v.scope_id = s.id
         group by st.id, st.name) y), '[]'),
    'volume_by_crop', coalesce((select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object('id', cr.id, 'name', cr.name, 'unit', cr.primary_unit, 'kg', coalesce(sum(v.kg), 0), 'lots', coalesce(sum(v.lots), 0),
               'qr', coalesce((select sum(q.n) from qr q join public.scopes s2 on s2.id = q.scope_id where s2.crop_id = cr.id), 0)) as x
          from public.crops cr left join public.scopes s on s.crop_id = cr.id left join vol v on v.scope_id = s.id
         group by cr.id, cr.name, cr.primary_unit) y), '[]'),
    'setup', jsonb_build_object(
       'states', (select count(*) from public.states),
       'hr_admin', app.hr_seat_filled(),
       'state_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and u.status = 'active'))
  ) into r;
  return r;
end $$;

-- 12 · every ledger block, for the admin --------------------------------------------------------------------------------
-- What each block is about: the record's code for a block of a record; for the others, what the block says it is
-- (a person made, a stage given, an assignment, a scope activated). Filters: event, client (of the record or of the
-- scope), scope, person who signed, and "manager acts on records" (supervisory blocks of a record: a manager acting at
-- a stage they do not hold). Pages of up to 500; the export asks page by page.
create or replace function app.ledger_page(p_event text default null, p_client uuid default null, p_scope uuid default null,
  p_actor uuid default null, p_manager_acts boolean default false, p_limit int default 100, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); total bigint; rows jsonb;
begin
  if me is null or not app.is_admin() then raise exception 'the whole ledger is for the admin' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, coalesce(f.client_id, s.client_id) as client_id, coalesce(l.scope_id, f.scope_id) as the_scope
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id)
     where (p_event is null or l.event::text = p_event)
       and (p_actor is null or l.actor = p_actor)
       and (not coalesce(p_manager_acts, false) or (l.event = 'supervisory' and l.footprint_id is not null))),
  m as (select * from b where (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
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
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset);
end $$;

-- 13 · the API: closed by hand, opened by name (tests/08_api_surface.sql) --------------------------------------------------
revoke execute on function app.hr_seat_filled() from public, anon, authenticated;
revoke execute on function app.client_account_holder(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.state_supervisor_of(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.client_states(uuid) from public, anon, authenticated;
revoke execute on function app.farmers_two_steps() from public, anon, authenticated;
revoke execute on function app.platform_overview() from public, anon, authenticated;
revoke execute on function app.ledger_page(text, uuid, uuid, uuid, boolean, int, int) from public, anon, authenticated;
-- hr_seat_filled is read inside table policies (as the signed-in role): it answers one yes/no about the seat.
grant execute on function app.hr_seat_filled() to authenticated;
grant execute on function app.platform_overview() to authenticated;
grant execute on function app.ledger_page(text, uuid, uuid, uuid, boolean, int, int) to authenticated;
