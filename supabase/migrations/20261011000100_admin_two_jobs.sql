-- Migration 35 · THE ADMIN HAS TWO JOBS (Veda, 10 October 2026, follow-up brief "Admin role, follow-up" and her answers).
-- "admin can only add HR admin. and add state (hence admin has only 2 jobs) - rest he will just look onto data as admin
-- for making strategic decision." No override (her answer 1: "no override required").
--
-- The admin KEEPS: states; adding the person for the HR Admin seat and appointing or moving that seat; resetting the
-- HR Admin's password (nobody else can); reading everything that is not a person's HR file; the ledger check.
-- The admin LOSES (refused here, whatever a screen shows): seating a State Manager (now the HR Admin's: her answer);
-- adding any other joiner, also while the HR Admin seat is empty, and never an admin (an admin is made by the database
-- owner with the break-glass script); changing anyone's system role; suspending, offboarding or re-hiring anyone,
-- the HR Admin included (to replace the HR Admin, move the seat); reading HR files (documents, ID and bank last-fours,
-- notes, exits, goals, joining checklists) while the HR Admin seat is filled. While it is empty the admin acts for HR
-- only to bring in the HR person (add, mark as joined, appoint).
-- New: app.acts_as_hr(); app.admin_trends() (the dashboard's charts); the overview's people block and pipeline chain
-- position; the public journey says whether every step was recorded and checked by different people.
-- Additive: no row and no ledger block is changed. Tests: tests/29_admin_two_jobs.sql.

-- 1 · who acts as HR: HR people; the admin only while the HR Admin seat is empty
create or replace function app.acts_as_hr() returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_hr() or (app.is_admin() and not app.hr_seat_filled())
$$;

-- 2 · HR acts: the admin only while the HR Admin seat is empty, and never on an admin

CREATE OR REPLACE FUNCTION app.hr_may_manage(p_target system_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case (select system_role from public.app_users where id = app.current_user_id() and status = 'active')
    when 'admin' then not app.hr_seat_filled() and p_target <> 'admin'
    when 'hr_admin' then p_target in ('hr_resource', 'operational')
    when 'hr_resource' then p_target = 'operational'
    else false end
$function$;

-- 3 · passwords: the admin resets the HR Admin's and another admin's (nobody else resets either); with no other admin, break-glass

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
  -- the admin: the HR Admin's and another admin's password (nobody else may reset them), and HR's work while the seat is empty
  if app.is_admin() and not tgt.external and (tgt.system_role in ('hr_admin', 'admin') or app.hr_may_manage(tgt.system_role)) then return true; end if;
  if tgt.external then
    return exists (select 1 from public.assignments a
                    where a.employee_id = tgt.id and a.active and a.lens = 'client' and app.manages_client(me, a.client_id));
  end if;
  return app.is_hr() and app.hr_may_manage(tgt.system_role);
end $function$;

-- 4 · joiners: the admin adds only the person for the HR Admin seat, only while it is empty; nobody adds an admin

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
  -- An admin is never made in the app: the database owner runs the break-glass script (docs/OPERATIONS.md).
  if v_role = 'admin' then
    raise exception 'not allowed here: an admin is made only by the database owner (break-glass script)' using errcode = '42501'; end if;
  -- The admin adds one kind of person: the one for the HR Admin seat, and only while that seat is empty.
  if my_role = 'admin' and app.hr_seat_filled() then
    raise exception 'only HR adds joiners now: the HR Admin seat is filled' using errcode = '42501'; end if;
  if my_role = 'admin' and v_role not in ('hr_resource', 'hr_admin') then
    raise exception 'only HR adds joiners: the admin adds only the person for the HR Admin seat (system role HR)' using errcode = '42501'; end if;
  -- the HR Admin seat is the admin's to give
  if v_role = 'hr_admin' and my_role <> 'admin' then
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

-- 5 · system roles: the HR Admin (operational ↔ HR); the admin only while the seat is empty; admin never from here

CREATE OR REPLACE FUNCTION app.set_system_role(p_employee uuid, p_role system_role)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; my_role public.system_role;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = me then raise exception 'you cannot change your own system role' using errcode = '42501'; end if;
  if p_role = 'hr_admin' or u.system_role = 'hr_admin' then
    raise exception 'the HR Admin seat is given under System → Seats' using errcode = '42501'; end if;
  if not ((my_role = 'hr_admin' or (my_role = 'admin' and not app.hr_seat_filled()))
          and u.system_role in ('operational', 'hr_resource') and p_role in ('operational', 'hr_resource')) then
    raise exception 'you cannot give this system role' using errcode = '42501'; end if;
  if u.system_role = p_role then return; end if;
  update public.app_users set system_role = p_role where id = u.id;
  perform app.audit('system_role_changed', u.id, jsonb_build_object('name', u.display_name, 'from', u.system_role, 'to', p_role),
                    p_role = 'admin' or u.system_role = 'admin');
end $function$;

-- 6 · the State Manager seat moves from the admin to the HR Admin; the admin gives no assignment

CREATE OR REPLACE FUNCTION app.may_assign(p_lens assignment_lens, p_op_role op_role, p_target uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null then return false; end if;
  if app.is_admin() then return false; end if;                                -- the admin gives nothing (migration 35)
  if p_lens = 'state' then return app.is_hr_admin(); end if;                  -- the HR Admin seats State Managers (Veda, 10 Oct)
  if p_lens = 'client' then
    if p_op_role = 'client_account' then                                      -- a client's account: by a supervisor of its home state
      return exists (select 1 from app.eff_assignments(me) a
                      where a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_target));
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $function$;

-- 7 · a person's page: what the admin is offered follows the rules above; exits and the HR file are HR's

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
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', (app.is_hr_admin() or (app.can_assign() and not app.is_admin())) and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> me and u.system_role <> 'admin',
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

-- 8 · joiner_detail: HR's (the admin only while the HR Admin seat is empty)

CREATE OR REPLACE FUNCTION app.joiner_detail(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; o public.employee_org; d public.employee_docs;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or not app.acts_as_hr() then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  select * into d from public.employee_docs where employee_id = u.id;
  return jsonb_build_object(
    'person', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
               'system_role', u.system_role, 'join_date', u.join_date, 'created_at', u.created_at,
               'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
               'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
               'created_by', (select display_name from public.app_users where id = u.created_by)),
    'can_manage', app.hr_may_manage(u.system_role) and u.id <> app.current_user_id(),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to', o.reports_to, 'buddy', o.buddy,
             'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
             'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
             'nominee_relation', d.nominee_relation, 'form16_ref', d.form16_ref),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'storage_path', f.storage_path,
               'sha256', f.sha256, 'task_id', f.task_id, 'created_at', f.created_at,
               'uploaded_by', (select display_name from public.app_users where id = f.uploaded_by)) order by f.created_at)
               from public.employee_files f where f.employee_id = u.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
               'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note,
               'overdue', t.status = 'pending' and t.due_on < app.today(),
               'done_by', (select display_name from public.app_users where id = t.done_by)) order by t.seq)
               from public.onboarding_tasks t where t.employee_id = u.id), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'at', n.created_at,
               'by', (select display_name from public.app_users where id = n.written_by)) order by n.created_at desc)
               from public.employee_notes n where n.employee_id = u.id), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
               from public.employee_goals g where g.employee_id = u.id), '[]'::jsonb),
    'exits', coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason, 'final_settlement', e.final_settlement,
               'form16_ref', e.form16_ref, 'at', e.created_at) order by e.created_at desc)
               from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb),
    'assignments', (select count(*) from public.assignments a where a.employee_id = u.id and a.active)
  );
end $function$;

-- 8 · hr_pipeline: HR's (the admin only while the HR Admin seat is empty)

CREATE OR REPLACE FUNCTION app.hr_pipeline()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if app.me_or_raise() is null or not app.acts_as_hr() then
    raise exception 'only HR opens the pipeline' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(row_ order by (x.status = 'active'), x.join_date nulls last, x.name)
      from (
        select u.status, u.join_date, u.display_name as name,
               jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
                 'system_role', u.system_role, 'join_date', u.join_date,
                 'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
                 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
                 'employment_type', o.employment_type, 'job_title', o.job_title, 'department', o.department,
                 'total', tk.total, 'done', tk.done, 'overdue', tk.overdue,
                 'pct', case when tk.total > 0 then round(tk.done * 100.0 / tk.total) else 100 end,
                 'blocked_by', nx.owner, 'next_task', nx.title, 'next_due', nx.due_on,
                 -- everyone who has a task due by today: a joiner and HR can both be holding things up at once
                 'waiting_on', coalesce((select jsonb_agg(distinct t.owner) from public.onboarding_tasks t
                                          where t.employee_id = u.id and t.status = 'pending' and t.due_on <= app.today()), '[]'::jsonb)) as row_
          from public.app_users u
          left join public.employee_org o on o.employee_id = u.id
          cross join lateral (
            select count(*) as total, count(*) filter (where t.status = 'done') as done,
                   count(*) filter (where t.status = 'pending' and t.due_on < app.today()) as overdue
              from public.onboarding_tasks t where t.employee_id = u.id) tk
          left join lateral (
            select t.owner, t.title, t.due_on from public.onboarding_tasks t
             where t.employee_id = u.id and t.status = 'pending' order by t.due_on, t.seq limit 1) nx on true
         where not u.external
           and (u.status in ('invited', 'onboarding') or (u.status = 'active' and tk.total > tk.done))
      ) x), '[]'::jsonb);
end $function$;

-- 9 · the app is told who seats State Managers

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
                                       'state_seat', app.is_hr_admin())),
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

-- 10 · the admin's overview: the pipeline in chain order, verified quantities, and people as numbers

CREATE OR REPLACE FUNCTION app.platform_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from public.scopes s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- Chain order, not registry order: each stage's step number in the chains of the active scopes that have it,
  -- averaged (every chain starts at its entry stage); the seal is always last. Stages of active chains are listed even
  -- with no record yet, so a stage nobody has reached shows as 0.
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from public.scopes s where s.status = 'active')
                     then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from public.scopes s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
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
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp where pp.position is not null or pp.pending + pp.done > 0), '[]'),
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
    -- people, as numbers only: no HR file is read here (Veda, 10 Oct: "counts and charts, not personal HR records")
    'people', jsonb_build_object(
       'by_role', coalesce((select jsonb_object_agg(z.r, z.n) from (select system_role::text as r, count(*) as n from public.app_users
                              where not external and status <> 'offboarded' group by 1) z), '{}'),
       'by_status', coalesce((select jsonb_object_agg(z.s, z.n) from (select status::text as s, count(*) as n from public.app_users
                              where not external group by 1) z), '{}'),
       'client_logins', (select count(*) from public.app_users where external and status = 'active'),
       'state_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and u.status = 'active'),
       'client_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'),
       'stage_people', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                         where a.active and a.lens = 'scope' and u.status = 'active'),
       'unassigned', (select count(*) from public.app_users u where not u.external and u.status = 'active' and u.system_role = 'operational'
                       and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active)),
       'joining', (select count(*) from public.app_users where not external and status in ('invited', 'onboarding')),
       'checklist_pct', (select round(100.0 * count(*) filter (where t.status <> 'pending') / nullif(count(*), 0))
                           from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id
                          where u.status in ('invited', 'onboarding')),
       'left_90d', (select count(distinct e.employee_id) from public.employee_exits e where e.exit_date >= app.today() - 90)),
    'setup', jsonb_build_object(
       'states', (select count(*) from public.states),
       'hr_admin', app.hr_seat_filled(),
       'state_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and u.status = 'active'))
  ) into r;
  return r;
end $function$;

-- 11 · the public page tells the truth about who checked the lot (no name is sent: one yes or no)

CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid;
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
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    v_later_maker := cur.created_by;
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
    'journey', steps,
    'independent', v_independent
  );
end $function$;

-- 12 · the dashboard's charts: weekly series and breakdowns, counted on the server (admin only)
create or replace function app.admin_trends(p_weeks int default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); w0 date; r jsonb;
begin
  if me is null or not app.is_admin() then raise exception 'the trends are for the admin' using errcode = '42501'; end if;
  p_weeks := least(greatest(coalesce(p_weeks, 12), 4), 52);
  w0 := date_trunc('week', now() at time zone 'Asia/Kolkata')::date - 7 * (p_weeks - 1);
  with weeks as (select (w0 + 7 * i)::date as wk from generate_series(0, p_weeks - 1) as i),
  entry as (
    select f.qty_out, s.state_id, s.crop_id,
           date_trunc('week', coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date as wk
      from public.footprints f join public.scopes s on s.id = f.scope_id
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded'),
  verdicts as (
    select v.domestic_verdict, v.export_verdict, s.crop_id, date_trunc('week', v.created_at at time zone 'Asia/Kolkata')::date as wk
      from public.qc_verdicts v join public.footprints f on f.id = v.footprint_id join public.scopes s on s.id = f.scope_id
     where f.status <> 'superseded')
  select jsonb_build_object(
    'since', w0,
    'weeks', (select jsonb_agg(jsonb_build_object(
        'week', w.wk,
        'kg', coalesce((select sum(e.qty_out) from entry e where e.wk = w.wk), 0),
        'lots', (select count(*) from entry e where e.wk = w.wk),
        'qr', (select count(*) from public.qr_seals q where date_trunc('week', q.sealed_at at time zone 'Asia/Kolkata')::date = w.wk),
        'farmers_added', (select count(*) from public.farmers fm where date_trunc('week', fm.created_at at time zone 'Asia/Kolkata')::date = w.wk),
        'farmers_verified', (select count(*) from public.farmers fm where fm.verified_at is not null
                               and date_trunc('week', fm.verified_at at time zone 'Asia/Kolkata')::date = w.wk),
        'lab_pass', (select count(*) from verdicts v where v.wk = w.wk and v.domestic_verdict = 'pass'),
        'lab_fail', (select count(*) from verdicts v where v.wk = w.wk and v.domestic_verdict = 'fail'),
        'flags', (select count(*) from public.flags fl where date_trunc('week', fl.created_at at time zone 'Asia/Kolkata')::date = w.wk))
        order by w.wk) from weeks w),
    'kg_by_crop', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name,
        'series', (select jsonb_agg(coalesce((select sum(e.qty_out) from entry e where e.wk = w.wk and e.crop_id = cr.id), 0) order by w.wk) from weeks w),
        'total', coalesce((select sum(e.qty_out) from entry e where e.crop_id = cr.id), 0)) order by cr.name) from public.crops cr), '[]'),
    'kg_by_state', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name,
        'series', (select jsonb_agg(coalesce((select sum(e.qty_out) from entry e where e.wk = w.wk and e.state_id = st.id), 0) order by w.wk) from weeks w),
        'total', coalesce((select sum(e.qty_out) from entry e where e.state_id = st.id), 0)) order by st.name) from public.states st), '[]'),
    'quality_by_crop', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name,
        'domestic_pass', (select count(*) from verdicts v where v.crop_id = cr.id and v.domestic_verdict = 'pass'),
        'domestic_fail', (select count(*) from verdicts v where v.crop_id = cr.id and v.domestic_verdict = 'fail'),
        'export_pass', (select count(*) from verdicts v where v.crop_id = cr.id and v.export_verdict = 'pass'),
        'export_fail', (select count(*) from verdicts v where v.crop_id = cr.id and v.export_verdict = 'fail')) order by cr.name)
        from public.crops cr), '[]'),
    'farmers_by_state', coalesce((select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object('name', coalesce(st.name, '—'),
               'active', count(*) filter (where fm.status = 'active'),
               'waiting', count(*) filter (where fm.status in ('draft', 'under_review')),
               'inactive', count(*) filter (where fm.status = 'inactive')) as x
          from public.farmers fm left join public.states st on st.id = fm.state_id group by st.name) y), '[]')
  ) into r;
  return r;
end $$;

-- 13 · HR files: HR's (the admin only while the HR Admin seat is empty, to bring the HR person in)
alter policy employee_docs_read on public.employee_docs using ((employee_id = app.current_user_id()) or app.acts_as_hr());
alter policy employee_files_read on public.employee_files using ((employee_id = app.current_user_id()) or app.acts_as_hr());
alter policy employee_notes_read on public.employee_notes using (app.acts_as_hr());
alter policy employee_exits_read on public.employee_exits using (app.acts_as_hr());
alter policy employee_goals_read on public.employee_goals using ((employee_id = app.current_user_id()) or app.acts_as_hr());
alter policy onboarding_tasks_read on public.onboarding_tasks using ((employee_id = app.current_user_id()) or app.acts_as_hr());
alter policy hr_docs_read on storage.objects using ((bucket_id = 'hr-docs') and app.acts_as_hr());
alter policy hr_docs_upload on storage.objects with check ((bucket_id = 'hr-docs')
  and (((storage.foldername(name))[1] = (app.current_user_id())::text) or app.acts_as_hr()));

-- 14 · the API (tests/08_api_surface.sql)
revoke execute on function app.acts_as_hr() from public, anon, authenticated;
revoke execute on function app.admin_trends(int) from public, anon, authenticated;
-- acts_as_hr is read inside table and storage policies (as the signed-in role): one yes/no about the caller
grant execute on function app.acts_as_hr() to authenticated;
grant execute on function app.admin_trends(int) to authenticated;

-- 15 · "Report a problem" (Help page): what a person writes lands where the admin already looks (Health)
alter table public.client_errors drop constraint client_errors_kind_check;
alter table public.client_errors add constraint client_errors_kind_check
  check (kind = any (array['error', 'rejection', 'boundary', 'sync_refused', 'report']));

CREATE OR REPLACE FUNCTION app.report_client_error(p_kind text, p_message text, p_detail text DEFAULT NULL::text, p_path text DEFAULT NULL::text, p_build text DEFAULT NULL::text, p_online boolean DEFAULT NULL::boolean, p_agent text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null or coalesce(btrim(p_message), '') = '' then return false; end if;
  if (select count(*) from public.client_errors e where e.user_id = me and e.at > now() - interval '1 hour') >= 30 then
    return false;                                                       -- a looping screen must not fill the table
  end if;
  delete from public.client_errors where at < now() - interval '90 days';
  insert into public.client_errors (user_id, role, kind, message, detail, path, build, online, agent)
  values (me, app.current_role(),
          case when p_kind in ('error', 'rejection', 'boundary', 'sync_refused', 'report') then p_kind else 'error' end,
          left(p_message, 500), left(p_detail, 2000), left(split_part(coalesce(p_path, ''), '?', 1), 200),
          left(p_build, 40), p_online, left(p_agent, 300));
  return true;
end $function$;
