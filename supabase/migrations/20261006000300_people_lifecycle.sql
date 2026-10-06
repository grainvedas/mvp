-- GrainVeda MVP · migration 33: identity layer, part 3 of 3 (the actions: onboarding, assignment, lifecycle, sign-in code)
--
-- Every change to a person or to their access goes through one of the functions below. Each one checks who is
-- asking, does the change, and writes one line to public.audit_log. The tables themselves are closed to direct writes.
--
-- Who may do what:
--   create a person            HR Admin, HR resource, admin                       app.add_joiner
--   create a client's login    whoever manages that client                        app.add_client_viewer
--   give / end an assignment   admin: any; state supervisor: scopes in the state and the accounts of clients homed
--                              there; client account: scopes of the client and the client's own logins.
--                              HR: never.                                         app.assign / app.end_assignment / app.reassign
--   suspend, reinstate, offboard, re-hire      HR Admin, HR resource, admin       app.suspend_person …
--   system role                admin: any; HR Admin: operational ↔ HR resource    app.set_system_role, app.appoint_hr_admin

-- 0 · small helpers ----------------------------------------------------------------------------------------------------
create or replace function app.me_or_raise() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id();
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return me;
end $$;

create or replace function app.person_brief(p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status) from public.app_users u where u.id = p_user
$$;

-- 1 · onboarding ---------------------------------------------------------------------------------------------------------
create or replace function app.stamp_tasks(p_employee uuid, p_template uuid, p_join date, p_type public.employment_type) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  -- Statutory tasks (PF, gratuity) are for full-time employees only: interns, contractors and consultants skip them.
  insert into public.onboarding_tasks (employee_id, seq, code, title, owner, due_on, statutory, kind)
  select p_employee, t.seq, t.code, t.title, t.owner, p_join + t.due_offset_days, t.statutory, t.kind
    from public.template_tasks t
   where t.template_id = p_template and not (t.statutory and p_type <> 'full_time')
   order by t.seq;
  get diagnostics n = row_count;
  return n;
end $$;

-- HR adds a joiner: the person is created once, as an identity. No scope, no client, no state: HR never grants access.
create or replace function app.add_joiner(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); my_role public.system_role; v_role public.system_role;
        v_name text := btrim(coalesce(p->>'full_name', '')); v_email text := app.email_key(p->>'personal_email');
        v_phone text; v_join date; v_type public.employment_type; v_tpl uuid; v_id uuid; n int;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  if my_role is null or my_role not in ('admin', 'hr_admin', 'hr_resource') then
    raise exception 'only HR adds a joiner' using errcode = '42501'; end if;
  v_role := coalesce(nullif(p->>'system_role', ''), 'operational')::public.system_role;
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
end $$;

-- The server function that made the login tells the database so (one audit line: the invite went out).
create or replace function app.note_invite_sent(p_employee uuid, p_how text default 'password') returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise();
begin
  if not (app.is_admin() or app.is_hr() or app.manages_viewer(p_employee)) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  perform app.audit('invite_sent', p_employee, jsonb_build_object('how', left(coalesce(p_how, 'password'), 40)));
end $$;

-- The server function that reset a password says so (one audit line; it checks the same rule the function asked).
create or replace function app.note_login_reset(p_target uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not app.reset_login_allowed(p_target) then raise exception 'not allowed' using errcode = '42501'; end if;
  perform app.audit('login_reset', p_target, jsonb_build_object('name', (select display_name from public.app_users where id = p_target)));
end $$;

-- A client's own read-only login: not an employee, no HR record. Made by whoever manages that client.
create or replace function app.add_client_viewer(p_client uuid, p_name text, p_email text) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); v_id uuid; v_email text := app.email_key(p_email);
begin
  if not app.can_manage_client(p_client) then
    raise exception 'you do not manage this client' using errcode = '42501'; end if;
  if btrim(coalesce(p_name, '')) = '' then raise exception 'a name is required' using errcode = '23514'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid email is required: it is the sign-in' using errcode = '23514'; end if;
  begin
    insert into public.app_users (display_name, email, status, external, created_by)
    values (btrim(p_name), v_email, 'active', true, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email already exists' using errcode = '23505';
  end;
  insert into public.assignments (employee_id, lens, op_role, client_id, created_by) values (v_id, 'client', 'client_viewer', p_client, me);
  perform app.audit('client_login_created', v_id, jsonb_build_object('name', btrim(p_name), 'client_id', p_client));
  return v_id;
end $$;

-- First sign-in of an invited person: onboarding begins.
create or replace function app.mark_first_login() returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := app.login_user_id(); st public.employee_status;
begin
  if me is null then return null; end if;
  update public.app_users set status = 'onboarding' where id = me and status = 'invited' returning status into st;
  if st is not null then perform app.audit('first_login', me, '{}'::jsonb); end if;
  return (select status::text from public.app_users where id = me);
end $$;

create or replace function app.activate_joiner(p_employee uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role)) or u.id = me then
    raise exception 'only HR marks a joiner as joined' using errcode = '42501'; end if;
  if u.status not in ('invited', 'onboarding') then
    raise exception 'this person is % already', u.status using errcode = '23514'; end if;
  update public.app_users set status = 'active' where id = u.id;
  perform app.audit('activated', u.id, jsonb_build_object('name', u.display_name, 'from', u.status,
    'tasks_open', (select count(*) from public.onboarding_tasks t where t.employee_id = u.id and t.status = 'pending')));
  return 'active';
end $$;

-- What a new hire sees: their own checklist and what HR has set up for them.
create or replace function app.my_onboarding() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; d public.employee_docs;
begin
  select * into u from public.app_users where id = me;
  select * into o from public.employee_org where employee_id = me;
  select * into d from public.employee_docs where employee_id = me;
  return jsonb_build_object(
    'status', u.status, 'name', u.display_name, 'join_date', u.join_date, 'today', app.today(),
    'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
    'org', jsonb_build_object('job_title', o.job_title, 'department', o.department, 'designation_band', o.designation_band,
                              'employment_type', o.employment_type),
    'reports_to', (select jsonb_build_object('name', r.display_name, 'email', r.email, 'phone', r.phone) from public.app_users r where r.id = o.reports_to),
    'buddy', (select jsonb_build_object('name', b.display_name, 'email', b.email, 'phone', b.phone) from public.app_users b where b.id = o.buddy),
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
                               'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
                               'nominee_relation', d.nominee_relation),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'task_id', f.task_id, 'created_at', f.created_at)
                                        order by f.created_at) from public.employee_files f where f.employee_id = me), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
                         'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note)
                         order by t.seq) from public.onboarding_tasks t where t.employee_id = me), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
                         from public.employee_goals g where g.employee_id = me), '[]'::jsonb)
  );
end $$;

-- A file put into hr-docs is registered here (who, what kind, its SHA-256). The person registers into their own
-- folder; HR and the admin into anyone's.
create or replace function app.register_hr_file(p_employee uuid, p_kind text, p_path text, p_sha256 text,
                                                p_file_name text default null, p_task uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); v_id uuid;
begin
  if not (p_employee = me or ((app.is_admin() or app.is_hr()) and app.hr_may_manage((select system_role from public.app_users where id = p_employee)))) then
    raise exception 'not allowed to add a document for this person' using errcode = '42501'; end if;
  if p_path is distinct from format('%s/%s', p_employee, split_part(p_path, '/', 2)) or split_part(p_path, '/', 2) = '' then
    raise exception 'document path must be <person>/<file>' using errcode = '23514'; end if;
  if p_task is not null and not exists (select 1 from public.onboarding_tasks t where t.id = p_task and t.employee_id = p_employee) then
    raise exception 'that task belongs to someone else' using errcode = '23514'; end if;
  insert into public.employee_files (employee_id, kind, storage_path, file_name, sha256, task_id, uploaded_by)
  values (p_employee, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_task, me) returning id into v_id;
  return v_id;
end $$;

-- One task ticked off. The hire does their own (owner = hire); HR does HR's and IT's, and may do a hire's on their
-- behalf. What the task needs depends on its kind; identity and bank numbers arrive as their last four characters only.
create or replace function app.complete_task(p_task uuid, p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; as_hr boolean; d jsonb := coalesce(p_data, '{}'::jsonb);
        g jsonb; n_open int;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  as_hr := (app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role) and u.id <> me;
  if not (as_hr or (t.employee_id = me and t.owner = 'hire')) then
    raise exception 'this task is not yours to complete' using errcode = '42501'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  if t.status = 'done' then raise exception 'this task is already done' using errcode = '23514'; end if;

  -- Numbers arrive as their last four characters only; anything longer is refused rather than cut, so a full number
  -- typed into the wrong box is never stored.
  if coalesce(d->>'pan_last4', '') <> '' and upper(d->>'pan_last4') !~ '^[0-9A-Z]{4}$' then
    raise exception 'PAN: give the last four characters only' using errcode = '23514'; end if;
  if coalesce(d->>'aadhaar_last4', '') <> '' and d->>'aadhaar_last4' !~ '^[0-9]{4}$' then
    raise exception 'Aadhaar: give the last four digits only' using errcode = '23514'; end if;
  if coalesce(d->>'bank_last4', '') <> '' and d->>'bank_last4' !~ '^[0-9]{4}$' then
    raise exception 'bank account: give the last four digits only' using errcode = '23514'; end if;
  if coalesce(d->>'bank_ifsc', '') <> '' and upper(d->>'bank_ifsc') !~ '^[A-Z]{4}0[A-Z0-9]{6}$' then
    raise exception 'IFSC looks wrong: it is 11 characters, like HDFC0001234' using errcode = '23514'; end if;
  if coalesce(d->>'pf_uan_last4', '') <> '' and d->>'pf_uan_last4' !~ '^[0-9]{4}$' then
    raise exception 'UAN: give the last four digits only' using errcode = '23514'; end if;

  case t.kind
    when 'sign' then
      if not as_hr and coalesce((d->>'acknowledged')::boolean, false) is not true then
        raise exception 'tick the box to say you have read and signed' using errcode = '23514'; end if;
    when 'identity' then
      if coalesce(d->>'pan_last4', '') = '' and coalesce(d->>'aadhaar_last4', '') = '' then
        raise exception 'give the last four characters of your PAN or Aadhaar' using errcode = '23514'; end if;
      if not exists (select 1 from public.employee_files f where f.employee_id = u.id and f.kind in ('pan', 'aadhaar')) then
        raise exception 'attach a photo or scan of the PAN or Aadhaar card first' using errcode = '23514'; end if;
      update public.employee_docs set pan_last4 = coalesce(nullif(upper(d->>'pan_last4'), ''), pan_last4),
             aadhaar_last4 = coalesce(nullif(d->>'aadhaar_last4', ''), aadhaar_last4), updated_at = now() where employee_id = u.id;
    when 'bank' then
      if coalesce(btrim(d->>'bank_name'), '') = '' or coalesce(d->>'bank_ifsc', '') = '' or coalesce(d->>'bank_last4', '') = '' then
        raise exception 'bank name, IFSC and the last four digits of the account are required' using errcode = '23514'; end if;
      update public.employee_docs set bank_name = btrim(d->>'bank_name'), bank_ifsc = upper(d->>'bank_ifsc'), bank_last4 = d->>'bank_last4',
             updated_at = now() where employee_id = u.id;
    when 'nomination' then
      if coalesce(btrim(d->>'gratuity_nominee'), '') = '' or coalesce(btrim(d->>'nominee_relation'), '') = '' then
        raise exception 'the nominee''s name and relation are required' using errcode = '23514'; end if;
      update public.employee_docs set gratuity_nominee = btrim(d->>'gratuity_nominee'), nominee_relation = btrim(d->>'nominee_relation'),
             pf_uan_last4 = coalesce(nullif(d->>'pf_uan_last4', ''), pf_uan_last4), updated_at = now() where employee_id = u.id;
    when 'buddy' then
      if coalesce(d->>'buddy', '') = '' and (select buddy from public.employee_org where employee_id = u.id) is null then
        raise exception 'choose the buddy first' using errcode = '23514'; end if;
      if coalesce(d->>'buddy', '') <> '' then
        update public.employee_org set buddy = (d->>'buddy')::uuid, updated_by = me, updated_at = now() where employee_id = u.id;
      end if;
    when 'goals' then
      for g in select * from jsonb_array_elements(coalesce(d->'goals', '[]'::jsonb)) loop
        insert into public.employee_goals (employee_id, horizon, goal, set_by) values (u.id, (g->>'horizon')::int, btrim(g->>'goal'), me);
      end loop;
      if (select count(distinct horizon) from public.employee_goals where employee_id = u.id) < 3 then
        raise exception 'set at least one goal each for 30, 60 and 90 days' using errcode = '23514'; end if;
    else null;
  end case;

  update public.onboarding_tasks set status = 'done', done_at = now(), done_by = me, note = nullif(btrim(d->>'note'), '') where id = t.id;
  select count(*) into n_open from public.onboarding_tasks where employee_id = u.id and status = 'pending';
  -- Everything done: the joiner is active without HR having to press anything.
  if n_open = 0 and u.status = 'onboarding' then
    update public.app_users set status = 'active' where id = u.id;
    perform app.audit('activated', u.id, jsonb_build_object('name', u.display_name, 'from', 'onboarding', 'how', 'checklist complete'));
  end if;
  return jsonb_build_object('ok', true, 'open', n_open, 'status', (select status from public.app_users where id = u.id));
end $$;

create or replace function app.reopen_task(p_task uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage((select system_role from public.app_users where id = t.employee_id))) then
    raise exception 'only HR reopens a task' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.onboarding_tasks set status = 'pending', done_at = null, done_by = null, note = 'reopened: ' || btrim(p_reason) where id = p_task;
end $$;

create or replace function app.add_hr_note(p_employee uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise();
begin
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage((select system_role from public.app_users where id = p_employee))) then
    raise exception 'only HR writes HR notes' using errcode = '42501'; end if;
  insert into public.employee_notes (employee_id, note, written_by) values (p_employee, btrim(p_note), me);
end $$;

-- 30-60-90 goals: HR sets them (replacing the list), the person reads them.
create or replace function app.set_goals(p_employee uuid, p_goals jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); g jsonb; n int := 0;
begin
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage((select system_role from public.app_users where id = p_employee))) then
    raise exception 'only HR sets goals' using errcode = '42501'; end if;
  delete from public.employee_goals where employee_id = p_employee;
  for g in select * from jsonb_array_elements(coalesce(p_goals, '[]'::jsonb)) loop
    if coalesce(btrim(g->>'goal'), '') <> '' then
      insert into public.employee_goals (employee_id, horizon, goal, set_by) values (p_employee, (g->>'horizon')::int, btrim(g->>'goal'), me);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- HR edits the descriptive facts and the join date (a moved join date moves the due dates of what is still open).
create or replace function app.update_joiner(p_employee uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; v_join date; delta int;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role)) then
    raise exception 'only HR edits a person''s record' using errcode = '42501'; end if;
  insert into public.employee_org (employee_id, updated_by) values (u.id, me) on conflict (employee_id) do nothing;
  update public.employee_org set
    employment_type  = coalesce(nullif(p->>'employment_type', '')::public.employment_type, employment_type),
    designation_band = case when p ? 'designation_band' then nullif(btrim(p->>'designation_band'), '') else designation_band end,
    department       = case when p ? 'department' then nullif(btrim(p->>'department'), '') else department end,
    job_title        = case when p ? 'job_title' then nullif(btrim(p->>'job_title'), '') else job_title end,
    reports_to       = case when p ? 'reports_to' then nullif(p->>'reports_to', '')::uuid else reports_to end,
    buddy            = case when p ? 'buddy' then nullif(p->>'buddy', '')::uuid else buddy end,
    updated_by = me, updated_at = now()
  where employee_id = u.id;
  if coalesce(p->>'join_date', '') <> '' then
    v_join := (p->>'join_date')::date;
    if u.join_date is distinct from v_join then
      delta := v_join - coalesce(u.join_date, v_join);
      update public.app_users set join_date = v_join where id = u.id;
      update public.onboarding_tasks set due_on = due_on + delta where employee_id = u.id and status = 'pending';
    end if;
  end if;
end $$;

-- The pipeline: every joiner still on the way in, how far along, and who the next step is waiting on.
create or replace function app.hr_pipeline() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app.me_or_raise() is null or not (app.is_admin() or app.is_hr()) then
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
end $$;

create or replace function app.joiner_detail(p_employee uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; o public.employee_org; d public.employee_docs;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or not (app.is_admin() or app.is_hr()) then
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
end $$;

-- 2 · assignments --------------------------------------------------------------------------------------------------------
-- May the signed-in person give (or end) this assignment?
create or replace function app.may_assign(p_lens public.assignment_lens, p_op_role public.op_role, p_target uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id();
begin
  if me is null then return false; end if;
  if app.is_admin() then return true; end if;
  if p_lens = 'state' then return false; end if;                              -- a state supervisor is appointed by the admin
  if p_lens = 'client' then
    if p_op_role = 'client_account' then                                      -- a client's account: by a supervisor of its home state
      return exists (select 1 from app.eff_assignments(me) a
                      where a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_target));
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $$;

-- Stages of a scope's chain that nobody holds (optionally: if this assignment were gone).
create or replace function app.coverage_gaps(p_scope uuid, p_without uuid default null) returns public.stage_type[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(c.st order by c.i), '{}')
    from public.scopes s cross join unnest(s.chain) with ordinality as c(st, i)
   where s.id = p_scope and s.status <> 'closed'
     and not exists (
       select 1 from public.slot_assignments sa
         join public.assignments a on a.id = sa.assignment_id
         join public.app_users u on u.id = sa.user_id
        where sa.scope_id = s.id and sa.stage_type = c.st and a.active
          and u.status in ('invited', 'onboarding', 'active')
          and (p_without is null or a.id <> p_without))
$$;

-- Things worth a second look before giving an assignment. They never refuse it.
create or replace function app.assignment_warnings(p_employee uuid, p_lens public.assignment_lens, p_target uuid,
                                                   p_op_role public.op_role, p_stages public.stage_type[] default '{}') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w jsonb := '[]'::jsonb; u public.app_users; sc public.scopes; r record; i int; v_chain public.stage_type[];
begin
  select * into u from public.app_users where id = p_employee;
  if u.status in ('invited', 'onboarding') then
    w := w || jsonb_build_object('code', 'not_active_yet', 'status', u.status); end if;
  if u.auth_uid is null or u.auth_uid = u.id then
    w := w || jsonb_build_object('code', 'no_login'); end if;
  if p_lens = 'scope' then
    select * into sc from public.scopes where id = p_target;
    -- an operational role in two places at once: another state, or another place in the same season
    for r in select s.geography, st.name as state_name, s.state_id, c.name as client_name
               from public.assignments a join public.scopes s on s.id = a.scope_id
               join public.states st on st.id = s.state_id join public.clients c on c.id = s.client_id
              where a.employee_id = p_employee and a.active and a.lens = 'scope' and s.id <> sc.id and s.status <> 'closed'
                and (s.state_id <> sc.state_id or (s.geography <> sc.geography and s.season_code = sc.season_code)) loop
      w := w || jsonb_build_object('code', case when r.state_id <> sc.state_id then 'other_state' else 'other_place' end,
                                   'place', r.geography, 'state', r.state_name, 'client', r.client_name);
    end loop;
    -- two stages in a row: a record is verified by the receiving stage, never by the person who made it
    v_chain := sc.chain;
    for i in 1 .. coalesce(array_length(v_chain, 1), 1) - 1 loop
      if v_chain[i] = any(p_stages) and v_chain[i + 1] = any(p_stages) and v_chain[i + 1] <> 'qr_activation' then
        w := w || jsonb_build_object('code', 'adjacent_stages', 'first', v_chain[i], 'second', v_chain[i + 1]);
      end if;
    end loop;
  end if;
  return w;
end $$;

-- Give an assignment. For a scope: the role there (operator, export manager) and the stages held.
create or replace function app.assign(p_employee uuid, p_lens public.assignment_lens, p_target uuid, p_op_role public.op_role,
                                      p_stages public.stage_type[] default '{}', p_posting text default null, p_ends_on date default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); a public.assignments; sc public.scopes; st public.stage_type; v_stages public.stage_type[] := '{}';
        w jsonb;
begin
  if not app.may_assign(p_lens, p_op_role, p_target) then
    raise exception 'you cannot give this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if p_employee = me and not app.is_admin() then
    raise exception 'you cannot assign yourself' using errcode = '42501'; end if;
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
end $$;

-- Change which stages an assignment holds (the assignment itself stays: same person, same scope).
create or replace function app.set_stages(p_assignment uuid, p_stages public.stage_type[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); a public.assignments; sc public.scopes; st public.stage_type; v_new public.stage_type[];
begin
  select * into a from public.assignments where id = p_assignment;
  if a.id is null or not a.active or a.lens <> 'scope' then raise exception 'assignment not found' using errcode = 'P0002'; end if;
  if not app.may_assign(a.lens, a.op_role, a.scope_id) then
    raise exception 'you do not manage this scope' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = a.scope_id;
  select coalesce(array_agg(x order by array_position(sc.chain, x)), '{}') into v_new
    from (select distinct unnest(coalesce(p_stages, '{}')) as x) q;
  foreach st in array v_new loop
    if not (st = any(sc.chain)) then raise exception 'stage % is not in this scope''s chain', st using errcode = '23514'; end if;
  end loop;
  if a.op_role = 'operator' and cardinality(v_new) = 0 then
    raise exception 'an operator holds at least one stage: end the assignment instead' using errcode = '23514'; end if;
  if v_new = a.stages then return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(app.coverage_gaps(a.scope_id))); end if;

  perform set_config('app.assigning', 'on', true);
  delete from public.slot_assignments where assignment_id = a.id and not (stage_type = any(v_new));
  foreach st in array v_new loop
    if not (st = any(a.stages)) then
      insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (a.employee_id, a.scope_id, st, a.id);
    end if;
  end loop;
  update public.assignments set stages = v_new where id = a.id;
  perform set_config('app.assigning', '', true);
  perform app.audit('stages_changed', a.employee_id, jsonb_build_object('assignment_id', a.id, 'scope_id', a.scope_id,
    'before', to_jsonb(a.stages), 'after', to_jsonb(v_new)));
  select * into a from public.assignments where id = a.id;
  return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(app.coverage_gaps(a.scope_id)));
end $$;

-- What ending this assignment would leave unstaffed (shown before the person confirms).
create or replace function app.end_preview(p_assignment uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.assignments;
begin
  perform app.me_or_raise();
  select * into a from public.assignments where id = p_assignment;
  if a.id is null or not app.may_assign(a.lens, a.op_role, coalesce(a.scope_id, a.client_id, a.state_id)) then
    raise exception 'assignment not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('gaps', case when a.lens = 'scope' and a.active
    then to_jsonb(array(select g from unnest(app.coverage_gaps(a.scope_id, a.id)) g where g = any(a.stages))) else '[]'::jsonb end);
end $$;

create or replace function app.end_assignment(p_assignment uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); a public.assignments; gaps public.stage_type[] := '{}';
begin
  select * into a from public.assignments where id = p_assignment;
  if a.id is null then raise exception 'assignment not found' using errcode = 'P0002'; end if;
  if not app.may_assign(a.lens, a.op_role, coalesce(a.scope_id, a.client_id, a.state_id)) then
    raise exception 'you cannot end this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if not a.active then raise exception 'this assignment has already ended' using errcode = '23514'; end if;
  if a.employee_id = me and not app.is_admin() then
    raise exception 'you cannot end your own assignment' using errcode = '42501'; end if;
  update public.assignments set active = false, end_reason = coalesce(nullif(btrim(p_reason), ''), 'ended') where id = a.id;
  if a.lens = 'scope' then
    delete from public.slot_assignments where assignment_id = a.id;
    gaps := array(select g from unnest(app.coverage_gaps(a.scope_id)) g where g = any(a.stages));
  end if;
  select * into a from public.assignments where id = a.id;
  return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(gaps));
end $$;

-- Move a person: the old assignment ends (kept as history), a new one begins. Nothing is rewritten.
create or replace function app.reassign(p_assignment uuid, p_target uuid, p_stages public.stage_type[] default '{}',
                                        p_posting text default null, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.assignments; ended jsonb; given jsonb;
begin
  perform app.me_or_raise();
  select * into a from public.assignments where id = p_assignment;
  if a.id is null or not a.active then raise exception 'assignment not found' using errcode = 'P0002'; end if;
  if p_target = coalesce(a.scope_id, a.client_id, a.state_id) then
    raise exception 'that is where this person already is: change the stages instead' using errcode = '23514'; end if;
  if not app.may_assign(a.lens, a.op_role, p_target) then
    raise exception 'you cannot move this person there: it is outside what you manage' using errcode = '42501'; end if;
  ended := app.end_assignment(a.id, 'reassigned' || coalesce(': ' || nullif(btrim(p_reason), ''), ''));
  given := app.assign(a.employee_id, a.lens, p_target, a.op_role, p_stages, p_posting, null);
  return jsonb_build_object('ended', ended->'assignment', 'gaps', ended->'gaps', 'assignment', given->'assignment', 'warnings', given->'warnings');
end $$;

-- 3 · lifecycle ----------------------------------------------------------------------------------------------------------
create or replace function app.may_manage_person(p_employee uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee;
  if me is null or u.id is null or u.id = me then return false; end if;
  if u.external then return app.is_admin() or app.manages_viewer(u.id); end if;
  return (app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role);
end $$;

-- Suspended: access frozen at once, assignments kept, reversible.
create or replace function app.suspend_person(p_employee uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare u public.app_users;
begin
  perform app.me_or_raise();
  if not app.may_manage_person(p_employee) then raise exception 'you cannot suspend this person' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into u from public.app_users where id = p_employee;
  if u.status not in ('invited', 'onboarding', 'active') then raise exception 'this person is % already', u.status using errcode = '23514'; end if;
  update public.app_users set status = 'suspended' where id = u.id;
  perform app.audit('suspended', u.id, jsonb_build_object('name', u.display_name, 'from', u.status, 'reason', btrim(p_reason)));
end $$;

create or replace function app.reinstate_person(p_employee uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u public.app_users; v_to public.employee_status;
begin
  perform app.me_or_raise();
  if not app.may_manage_person(p_employee) then raise exception 'you cannot reinstate this person' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee;
  if u.status <> 'suspended' then raise exception 'this person is not suspended' using errcode = '23514'; end if;
  -- back to where they were: someone suspended before joining goes back to onboarding
  v_to := case when not u.external and exists (select 1 from public.onboarding_tasks t where t.employee_id = u.id and t.status = 'pending')
                    and not exists (select 1 from public.audit_log l where l.target = u.id and l.action = 'activated')
               then 'onboarding' else 'active' end;
  update public.app_users set status = v_to where id = u.id;
  perform app.audit('reinstated', u.id, jsonb_build_object('name', u.display_name, 'to', v_to));
end $$;

-- What offboarding would end, and which stages it would leave with nobody.
create or replace function app.offboard_preview(p_employee uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not app.may_manage_person(p_employee) then raise exception 'person not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'assignments', (select count(*) from public.assignments a where a.employee_id = p_employee and a.active),
    'gaps', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', s.id, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
                                          'client', c.name, 'stage', g) order by c.name, s.geography)
        from public.assignments a join public.scopes s on s.id = a.scope_id
        join public.crops cr on cr.id = s.crop_id join public.clients c on c.id = s.client_id
        cross join lateral unnest(app.coverage_gaps(s.id, a.id)) g
       where a.employee_id = p_employee and a.active and a.lens = 'scope' and g = any(a.stages)), '[]'::jsonb));
end $$;

-- Offboarded: the record stays for ever, every assignment ends, the login is recognised by nothing.
create or replace function app.offboard_person(p_employee uuid, p_exit_date date, p_reason text default null,
                                               p_final_settlement text default null, p_form16_ref text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; v_prev jsonb; n int;
begin
  if not app.may_manage_person(p_employee) then raise exception 'you cannot offboard this person' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee;
  if u.status = 'offboarded' then raise exception 'this person is offboarded already' using errcode = '23514'; end if;
  if p_exit_date is null then raise exception 'the exit date is required' using errcode = '23514'; end if;
  v_prev := app.offboard_preview(p_employee);
  update public.assignments set active = false, end_reason = 'offboarded' where employee_id = u.id and active;
  get diagnostics n = row_count;
  delete from public.slot_assignments where user_id = u.id;
  update public.app_users set status = 'offboarded' where id = u.id;
  if not u.external then
    insert into public.employee_exits (employee_id, exit_date, reason, final_settlement, form16_ref, recorded_by)
    values (u.id, p_exit_date, nullif(btrim(p_reason), ''), nullif(btrim(p_final_settlement), ''), nullif(btrim(p_form16_ref), ''), me);
    update public.employee_docs set form16_ref = coalesce(nullif(btrim(p_form16_ref), ''), form16_ref), updated_at = now() where employee_id = u.id;
  end if;
  perform app.audit('offboarded', u.id, jsonb_build_object('name', u.display_name, 'from', u.status, 'exit_date', p_exit_date,
    'assignments_ended', n, 'gaps', v_prev->'gaps', 'reason', nullif(btrim(p_reason), '')), true);
  return jsonb_build_object('assignments_ended', n, 'gaps', v_prev->'gaps');
end $$;

-- Re-hire: the same record comes back (same id, same history); a fresh checklist is stamped.
create or replace function app.rehire_person(p_employee uuid, p_join_date date, p_template uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; v_tpl uuid; n int;
begin
  if not app.may_manage_person(p_employee) then raise exception 'you cannot re-hire this person' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee;
  if u.external then raise exception 'a client login is not hired' using errcode = '23514'; end if;
  if u.status <> 'offboarded' then raise exception 'only an offboarded person is re-hired' using errcode = '23514'; end if;
  if p_join_date is null then raise exception 'the join date is required' using errcode = '23514'; end if;
  v_tpl := coalesce(p_template, (select id from public.onboarding_templates where is_default and active));
  update public.app_users set status = 'onboarding', join_date = p_join_date where id = u.id;
  delete from public.onboarding_tasks where employee_id = u.id;
  n := case when v_tpl is null then 0 else
         app.stamp_tasks(u.id, v_tpl, p_join_date, coalesce((select employment_type from public.employee_org where employee_id = u.id), 'full_time')) end;
  perform app.audit('rehired', u.id, jsonb_build_object('name', u.display_name, 'join_date', p_join_date, 'tasks', n));
  return jsonb_build_object('status', 'onboarding', 'tasks', n);
end $$;

-- System role. The admin: any. The HR Admin: makes or unmakes an HR resource. The HR Admin seat itself moves only
-- through app.appoint_hr_admin.
create or replace function app.set_system_role(p_employee uuid, p_role public.system_role) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; my_role public.system_role;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = me then raise exception 'you cannot change your own system role' using errcode = '42501'; end if;
  if p_role = 'hr_admin' or u.system_role = 'hr_admin' then
    raise exception 'the HR Admin seat is given under System → Seats' using errcode = '42501'; end if;
  if not (my_role = 'admin' or (my_role = 'hr_admin' and u.system_role in ('operational', 'hr_resource') and p_role in ('operational', 'hr_resource'))) then
    raise exception 'you cannot give this system role' using errcode = '42501'; end if;
  if u.system_role = p_role then return; end if;
  update public.app_users set system_role = p_role where id = u.id;
  perform app.audit('system_role_changed', u.id, jsonb_build_object('name', u.display_name, 'from', u.system_role, 'to', p_role),
                    p_role = 'admin' or u.system_role = 'admin');
end $$;

-- The HR Admin seat: exactly one. Only the admin appoints; the previous holder becomes an HR resource.
create or replace function app.appoint_hr_admin(p_employee uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; prev public.app_users;
begin
  if not app.is_admin() then raise exception 'only the admin appoints the HR Admin' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or u.status in ('suspended', 'offboarded') then raise exception 'choose an employee who is not suspended or offboarded' using errcode = '23514'; end if;
  if u.system_role = 'admin' then raise exception 'the admin holds the root seat already' using errcode = '23514'; end if;
  if u.system_role = 'hr_admin' then return; end if;
  select * into prev from public.app_users where system_role = 'hr_admin' and status <> 'offboarded';
  if prev.id is not null then update public.app_users set system_role = 'hr_resource' where id = prev.id; end if;
  update public.app_users set system_role = 'hr_admin' where id = u.id;
  perform app.audit('hr_admin_appointed', u.id, jsonb_build_object('name', u.display_name, 'previous', prev.display_name), true);
end $$;

-- 4 · what the screens read ------------------------------------------------------------------------------------------------
-- An assignment as the screens show it.
create or replace function app.assignment_json(a public.assignments) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'lens', a.lens, 'op_role', a.op_role, 'scope_id', a.scope_id,
           'client_id', coalesce(a.client_id, s.client_id), 'client_name', c.name,
           'state_id', coalesce(a.state_id, s.state_id), 'state_name', st.name,
           'label', case a.lens when 'scope' then format('%s · %s · %s', cr.name, s.season_code, s.geography)
                                when 'client' then c.name else st.name end,
           'scope_status', s.status, 'stages', to_jsonb(a.stages), 'posting', a.posting, 'season_code', a.season_code, 'ends_on', a.ends_on,
           'lapsed', a.ends_on is not null and a.ends_on < app.today(),
           'active', a.active, 'created_at', a.created_at, 'ended_at', a.ended_at, 'end_reason', a.end_reason,
           'created_by', (select display_name from public.app_users where id = a.created_by),
           'can_end', a.active and app.may_assign(a.lens, a.op_role, coalesce(a.scope_id, a.client_id, a.state_id)))
    from (select 1) one
    left join public.scopes s on s.id = a.scope_id
    left join public.crops cr on cr.id = s.crop_id
    left join public.clients c on c.id = coalesce(a.client_id, s.client_id)
    left join public.states st on st.id = coalesce(a.state_id, s.state_id)
$$;

-- May the signed-in person see this assignment? (the same rule as the read policy on the table)
create or replace function app.assignment_visible(a public.assignments) returns boolean
language sql stable security definer set search_path = public as $$
  select a.employee_id = app.current_user_id() or app.is_admin() or app.is_hr()
      or (a.lens = 'scope' and app.i_manage_scope(a.scope_id))
      or (a.lens = 'client' and app.can_manage_client(a.client_id))
      or (a.lens = 'state' and a.state_id = any(app.my_state_ids()))
$$;

-- The people directory: the pool of employees, with the assignments the reader is allowed to see. Assignments
-- outside the reader's lens are a number only ("2 elsewhere"): the client wall holds inside the directory too.
create or replace function app.people_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
     where (not u.external and (full_view or u.status <> 'offboarded'))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $$;

-- One person on the four axes: identity, org facts, system role, assignments. Plus what the reader may do to them.
create or replace function app.employee_profile(p_employee uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
      'assign', app.can_assign() and u.status in ('invited', 'onboarding', 'active') and not u.external and (u.id <> me or app.is_admin()),
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role <> 'hr_admin'
                  and (app.is_admin() or (app.is_hr_admin() and u.system_role in ('operational', 'hr_resource'))),
      'hr_record', full_view and not u.external));
end $$;

-- A scope's roster: every stage of the chain, who holds it, and the stages nobody holds.
create or replace function app.scope_roster(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc public.scopes;
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.sees_whole_scope(p_scope) then raise exception 'no access to this scope' using errcode = '42501'; end if;
  return jsonb_build_object(
    'scope', jsonb_build_object('id', sc.id, 'status', sc.status, 'season_code', sc.season_code, 'geography', sc.geography, 'season_end', sc.season_end,
               'client_id', sc.client_id, 'client_name', (select name from public.clients where id = sc.client_id),
               'crop_name', (select name from public.crops where id = sc.crop_id),
               'state_id', sc.state_id, 'state_name', (select name from public.states where id = sc.state_id)),
    'can_manage', app.i_manage_scope(p_scope),
    'gaps', to_jsonb(app.coverage_gaps(p_scope)),
    'stages', coalesce((
      select jsonb_agg(jsonb_build_object('stage', c.st, 'position', c.i, 'label', d.label,
               'holders', coalesce((
                 select jsonb_agg(jsonb_build_object('assignment_id', a.id, 'employee_id', u.id, 'name', u.display_name, 'status', u.status,
                          'posting', a.posting, 'since', sa.created_at, 'lapsed', a.ends_on is not null and a.ends_on < app.today())
                          order by u.display_name)
                   from public.slot_assignments sa join public.assignments a on a.id = sa.assignment_id
                   join public.app_users u on u.id = sa.user_id
                  where sa.scope_id = sc.id and sa.stage_type = c.st and a.active), '[]'::jsonb)) order by c.i)
        from unnest(sc.chain) with ordinality as c(st, i) join public.stage_definitions d on d.stage_type = c.st), '[]'::jsonb),
    'managers', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', u.id, 'name', u.display_name, 'op_role', a.op_role, 'status', u.status) order by a.op_role, u.display_name)
        from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and ((a.lens = 'client' and a.client_id = sc.client_id) or (a.lens = 'state' and a.state_id = sc.state_id)
                           or (a.lens = 'scope' and a.scope_id = sc.id and a.op_role = 'export_manager'))), '[]'::jsonb));
end $$;

-- A state at a glance: its supervisors, every scope in it across clients, and where a stage has nobody.
create or replace function app.state_overview(p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
    'clients', (select count(distinct s.client_id) from public.scopes s where s.state_id = p_state),
    'people', (select count(distinct a.employee_id) from public.assignments a join public.scopes s on s.id = a.scope_id
                where a.active and a.lens = 'scope' and s.state_id = p_state),
    'unassigned', (select count(*) from public.app_users u where not u.external and u.status = 'active' and u.system_role = 'operational'
                      and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active)));
end $$;

-- The two seats everything starts from.
create or replace function app.bootstrap_seats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not app.is_admin() then raise exception 'only the admin opens the seats' using errcode = '42501'; end if;
  return jsonb_build_object(
    'admins', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status,
                          'has_login', u.auth_uid is not null and u.auth_uid <> u.id) order by u.created_at)
                          from public.app_users u where u.system_role = 'admin' and u.status <> 'offboarded'), '[]'::jsonb),
    'hr_admin', (select jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status,
                          'has_login', u.auth_uid is not null and u.auth_uid <> u.id)
                   from public.app_users u where u.system_role = 'hr_admin' and u.status <> 'offboarded'),
    'hr_resources', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status) order by u.display_name)
                                from public.app_users u where u.system_role = 'hr_resource' and u.status <> 'offboarded'), '[]'::jsonb),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'system_role', u.system_role) order by u.display_name)
                              from public.app_users u where not u.external and u.system_role in ('operational', 'hr_resource')
                                and u.status in ('invited', 'onboarding', 'active')), '[]'::jsonb),
    'daily_code', jsonb_build_object('on', app.daily_code_on(),
      'without_email', (select count(*) from public.app_users u where u.active and app.email_key(u.email) is null)));
end $$;

create or replace function app.audit_feed(p_limit int default 200, p_flagged boolean default false) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not (app.is_admin() or app.is_hr_admin()) then raise exception 'the audit log is for the admin and the HR Admin' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', l.id, 'at', l.created_at, 'action', l.action, 'flagged', l.flagged, 'detail', l.detail,
             'actor', l.actor, 'actor_name', coalesce(a.display_name, 'System'), 'actor_role', a.system_role,
             'target', l.target, 'target_name', coalesce(t.display_name, l.detail->>'name')) order by l.id desc)
      from (select * from public.audit_log x where (not coalesce(p_flagged, false) or x.flagged)
             order by x.id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000)) l
      left join public.app_users a on a.id = l.actor
      left join public.app_users t on t.id = l.target), '[]'::jsonb);
end $$;

-- 5 · the once-a-day sign-in code (built and tested; switched OFF until a sender exists) --------------------------------
-- Password every time, plus a code once per calendar day (India time). While public.app_meta has no row
-- 'daily_code' = 'on', nothing below is asked of anybody.
create or replace function app.daily_code_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.login_user_id(); u public.app_users; c public.daily_codes;
begin
  if me is null then return jsonb_build_object('on', app.daily_code_on(), 'needed', false); end if;
  select * into u from public.app_users where id = me;
  select * into c from public.daily_codes where user_id = me;
  return jsonb_build_object('on', app.daily_code_on(),
    'needed', app.daily_code_on() and not exists (select 1 from public.daily_code_passes p where p.user_id = me and p.day = app.today()),
    'can_send', app.email_key(u.email) is not null,
    'email_hint', case when app.email_key(u.email) is null then null
                       else left(u.email, 1) || '•••' || substring(u.email from position('@' in u.email)) end,
    'sent_at', c.issued_at, 'expires_at', c.expires_at);
end $$;

-- Called by the server function `daily-code` with the service key, after it has checked the person's own token.
-- Returns the code in clear ONCE, for sending; only its hash is kept.
create or replace function app.issue_daily_code(p_auth_uid uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u public.app_users; c public.daily_codes; v_code text;
begin
  select * into u from public.app_users where auth_uid = p_auth_uid and active;
  if u.id is null then raise exception 'no such person' using errcode = 'P0002'; end if;
  if app.email_key(u.email) is null then raise exception 'this person has no email to send a code to' using errcode = '23514'; end if;
  select * into c from public.daily_codes where user_id = u.id;
  if c.user_id is not null and c.issued_at > now() - interval '60 seconds' then
    raise exception 'a code was sent less than a minute ago' using errcode = '53400'; end if;
  v_code := lpad(((('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.daily_codes (user_id, code_hash, issued_at, expires_at, attempts)
  values (u.id, encode(digest(u.id::text || ':' || v_code, 'sha256'), 'hex'), now(), now() + interval '10 minutes', 0)
  on conflict (user_id) do update set code_hash = excluded.code_hash, issued_at = excluded.issued_at,
                                      expires_at = excluded.expires_at, attempts = 0;
  return jsonb_build_object('code', v_code, 'email', u.email, 'name', u.display_name, 'minutes', 10);
end $$;

create or replace function app.verify_daily_code(p_code text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := app.login_user_id(); c public.daily_codes;
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from public.daily_codes where user_id = me for update;
  if c.user_id is null or c.expires_at < now() then
    raise exception 'that code has expired: ask for a new one' using errcode = '23514'; end if;
  if c.attempts >= 5 then
    raise exception 'too many wrong tries: ask for a new code' using errcode = '23514'; end if;
  if c.code_hash <> encode(digest(me::text || ':' || regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g'), 'sha256'), 'hex') then
    update public.daily_codes set attempts = attempts + 1 where user_id = me;
    return false;
  end if;
  insert into public.daily_code_passes (user_id, day) values (me, app.today()) on conflict do nothing;
  delete from public.daily_codes where user_id = me;
  delete from public.daily_code_passes where day < app.today() - 30;
  return true;
end $$;

-- The switch. Turning it on is refused while anyone who signs in has no email (they could never receive a code).
-- The admin who turns it on is passed for today, so a sender that turns out not to work can be switched off again.
create or replace function app.set_daily_code(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); n int;
begin
  if me is null or not app.user_is_admin(me) then raise exception 'only the admin switches the sign-in code' using errcode = '42501'; end if;
  if p_on then
    select count(*) into n from public.app_users u where u.active and app.email_key(u.email) is null;
    if n > 0 then
      return jsonb_build_object('ok', false, 'on', app.daily_code_on(), 'without_email', n,
        'names', (select jsonb_agg(u.display_name order by u.display_name) from public.app_users u where u.active and app.email_key(u.email) is null));
    end if;
    insert into public.daily_code_passes (user_id, day) values (me, app.today()) on conflict do nothing;
  end if;
  insert into public.app_meta (key, value) values ('daily_code', case when p_on then 'on' else 'off' end)
  on conflict (key) do update set value = excluded.value;
  insert into public.audit_log (actor, action, target, detail, flagged)
  values (me, 'daily_code_switched', null, jsonb_build_object('on', p_on), true);
  return jsonb_build_object('ok', true, 'on', p_on);
end $$;

-- 6 · the API surface ------------------------------------------------------------------------------------------------------
-- New functions are closed first (migration 15 explains why), then the ones the screens call are opened by name.
revoke execute on function
  app.me_or_raise(), app.person_brief(uuid), app.stamp_tasks(uuid, uuid, date, public.employment_type), app.add_joiner(jsonb),
  app.note_invite_sent(uuid, text), app.note_login_reset(uuid), app.add_client_viewer(uuid, text, text), app.mark_first_login(), app.activate_joiner(uuid),
  app.my_onboarding(), app.register_hr_file(uuid, text, text, text, text, uuid), app.complete_task(uuid, jsonb),
  app.reopen_task(uuid, text), app.add_hr_note(uuid, text), app.set_goals(uuid, jsonb), app.update_joiner(uuid, jsonb),
  app.hr_pipeline(), app.joiner_detail(uuid),
  app.may_assign(public.assignment_lens, public.op_role, uuid), app.coverage_gaps(uuid, uuid),
  app.assignment_warnings(uuid, public.assignment_lens, uuid, public.op_role, public.stage_type[]),
  app.assign(uuid, public.assignment_lens, uuid, public.op_role, public.stage_type[], text, date),
  app.set_stages(uuid, public.stage_type[]), app.end_preview(uuid), app.end_assignment(uuid, text),
  app.reassign(uuid, uuid, public.stage_type[], text, text),
  app.may_manage_person(uuid), app.suspend_person(uuid, text), app.reinstate_person(uuid), app.offboard_preview(uuid),
  app.offboard_person(uuid, date, text, text, text), app.rehire_person(uuid, date, uuid),
  app.set_system_role(uuid, public.system_role), app.appoint_hr_admin(uuid),
  app.assignment_json(public.assignments), app.assignment_visible(public.assignments),
  app.people_directory(), app.employee_profile(uuid), app.scope_roster(uuid), app.state_overview(uuid),
  app.bootstrap_seats(), app.audit_feed(int, boolean),
  app.daily_code_state(), app.issue_daily_code(uuid), app.verify_daily_code(text), app.set_daily_code(boolean)
  from public, anon, authenticated;

grant execute on function
  app.add_joiner(jsonb), app.note_invite_sent(uuid, text), app.note_login_reset(uuid), app.add_client_viewer(uuid, text, text), app.mark_first_login(),
  app.activate_joiner(uuid), app.my_onboarding(), app.register_hr_file(uuid, text, text, text, text, uuid),
  app.complete_task(uuid, jsonb), app.reopen_task(uuid, text), app.add_hr_note(uuid, text), app.set_goals(uuid, jsonb),
  app.update_joiner(uuid, jsonb), app.hr_pipeline(), app.joiner_detail(uuid),
  app.assignment_warnings(uuid, public.assignment_lens, uuid, public.op_role, public.stage_type[]),
  app.assign(uuid, public.assignment_lens, uuid, public.op_role, public.stage_type[], text, date),
  app.set_stages(uuid, public.stage_type[]), app.end_preview(uuid), app.end_assignment(uuid, text),
  app.reassign(uuid, uuid, public.stage_type[], text, text),
  app.suspend_person(uuid, text), app.reinstate_person(uuid), app.offboard_preview(uuid),
  app.offboard_person(uuid, date, text, text, text), app.rehire_person(uuid, date, uuid),
  app.set_system_role(uuid, public.system_role), app.appoint_hr_admin(uuid),
  app.people_directory(), app.employee_profile(uuid), app.scope_roster(uuid), app.state_overview(uuid),
  app.bootstrap_seats(), app.audit_feed(int, boolean),
  app.daily_code_state(), app.verify_daily_code(text), app.set_daily_code(boolean)
  to authenticated;
-- app.issue_daily_code stays with the service key: it returns a code in clear.

notify pgrst, 'reload schema';
