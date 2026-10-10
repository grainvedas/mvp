-- Migration 36 (Veda, 10 Oct 2026, "fix: the HR Admin cannot be activated"): the admin marks the HR Admin as joined.
--
-- Found on the practice system: after the reset the admin added a person and gave her the HR Admin seat; she is Joining,
-- so she has no HR access, there is no other HR person, and pressing "Mark as joined" as admin was refused ("only HR
-- marks a joiner as joined"). Every new person starts as Joining, so HR could never be switched on.
--
-- The rule: the admin may mark as joined the person who holds the HR Admin seat, and only that person (an HR Admin who
-- has not joined is, in effect, a vacant seat, and "if the seat is vacant, only the admin can fill it"). The act is a
-- flagged line in the audit log ("hr_admin_activated_by_admin"). For anyone else "only HR marks a joiner as joined"
-- stays, for the admin too, also while the seat is vacant (before: the admin could mark any HR person while the seat
-- was vacant). Not done on purpose: no one is activated by being given the seat (that would skip the checklist), and
-- the HR Admin gets no HR access while Joining (she could mark herself as joined). The joining checklist is unchanged.
-- Additive: two functions replaced; no table, row or ledger block is touched.

-- 1 · Mark as joined

CREATE OR REPLACE FUNCTION app.activate_joiner(p_employee uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; by_admin boolean;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  -- The admin marks one person as joined: the holder of the HR Admin seat, while she has not joined (until then the
  -- seat is in effect vacant and HR cannot act). Everyone else is HR's to mark, also while the seat is vacant.
  by_admin := app.is_admin() and u.system_role = 'hr_admin' and u.id <> me;
  if not by_admin and (not (app.is_hr() and app.hr_may_manage(u.system_role)) or u.id = me) then
    raise exception 'only HR marks a joiner as joined' using errcode = '42501'; end if;
  if u.status not in ('invited', 'onboarding') then
    raise exception 'this person is % already', u.status using errcode = '23514'; end if;
  update public.app_users set status = 'active' where id = u.id;
  perform app.audit(case when by_admin then 'hr_admin_activated_by_admin' else 'activated' end, u.id,
    jsonb_build_object('name', u.display_name, 'from', u.status,
      'tasks_open', (select count(*) from public.onboarding_tasks t where t.employee_id = u.id and t.status = 'pending')),
    by_admin);
  return 'active';
end $function$;

-- 2 · what the joiner page offers: "can_activate", the same rule as above

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
    -- "Mark as joined", exactly as app.activate_joiner decides it
    'can_activate', u.status in ('invited', 'onboarding') and u.id <> app.current_user_id()
                    and ((app.is_admin() and u.system_role = 'hr_admin') or (app.is_hr() and app.hr_may_manage(u.system_role))),
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
