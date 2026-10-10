-- Migration 33: who may create people, give and end assignments, suspend, offboard and re-hire, and what each
-- action leaves in the audit log.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.today() returns date language sql stable security definer as $$ select app.today() $$;
create or replace function pg_temp.last_audit(p_target uuid) returns public.audit_log language sql stable security definer as $$
  select * from public.audit_log where target = p_target order by id desc limit 1 $$;

-- 1 · HR creates the person: an identity, and nothing else ---------------------------------------------------------------
select t.as_user(t.u('05'));
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","join_date":"2026-11-01"}') $q$, 'only HR adds a joiner', 'create: an operator cannot');
select t.as_user(t.u('03'));
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","join_date":"2026-11-01"}') $q$, 'only HR adds a joiner', 'create: a Client Manager cannot');
select t.as_user(t.u('02'));
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","join_date":"2026-11-01"}') $q$, 'only HR adds a joiner', 'create: a State Manager cannot');

select t.as_user(t.u('17'));   -- HR resource
select t.fails($q$ select app.add_joiner('{"full_name":"","personal_email":"a@test.in","join_date":"2026-11-01"}') $q$, 'full name is required', 'create: a name is needed');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"not-an-email","join_date":"2026-11-01"}') $q$, 'valid personal email', 'create: and an email, which is the sign-in');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in"}') $q$, 'join date is required', 'create: and a join date');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","phone":"12345","join_date":"2026-11-01"}') $q$, '10-digit', 'create: a phone, if given, must be a mobile number');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"GRAINVEDAS+hr@gmail.com","join_date":"2026-11-01"}') $q$, 'already exists', 'create: the same email twice is refused, whatever the case');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","join_date":"2026-11-01","system_role":"admin"}') $q$, 'made only by the database owner', 'create: HR cannot create an admin (nobody can, in the app: migration 35)');
select t.fails($q$ select app.add_joiner('{"full_name":"A","personal_email":"a@test.in","join_date":"2026-11-01","system_role":"hr_admin"}') $q$, 'only the admin gives', 'create: nor an HR Admin');

insert into fx (k, j) values ('full', app.add_joiner(jsonb_build_object('full_name', 'Kiran Full', 'personal_email', 'Kiran@Test.in', 'phone', '98123 45601',
  'join_date', (pg_temp.today() + 10)::text, 'employment_type', 'full_time', 'designation_band', 'Associate', 'department', 'Operations',
  'job_title', 'Sorting Associate', 'reports_to', t.u('03')::text)));
insert into fx (k, j) values ('intern', app.add_joiner(jsonb_build_object('full_name', 'Ila Intern', 'personal_email', 'ila@test.in',
  'join_date', (pg_temp.today() + 10)::text, 'employment_type', 'intern')));
insert into fx (k, j) values ('contract', app.add_joiner(jsonb_build_object('full_name', 'Chetan Contract', 'personal_email', 'chetan@test.in',
  'join_date', (pg_temp.today() + 10)::text, 'employment_type', 'contract')));
insert into fx (k, j) values ('consult', app.add_joiner(jsonb_build_object('full_name', 'Charu Consultant', 'personal_email', 'charu@test.in',
  'join_date', (pg_temp.today() + 10)::text, 'employment_type', 'consultant')));
insert into fx (k, j) values ('hr2', app.add_joiner(jsonb_build_object('full_name', 'Hari HR', 'personal_email', 'hari@test.in',
  'join_date', (pg_temp.today() + 1)::text, 'system_role', 'hr_resource')));
update fx set id = (j->>'id')::uuid where id is null;
select t.as_service();

select t.ok((select status = 'invited' and system_role = 'operational' and role = 'operator' and client_id is null and state_ids = '{}'
                and email = 'kiran@test.in' and phone = '+919812345601' and created_by = t.u('17') and active
               from public.app_users where id = pg_temp.f('full'))
            and (select count(*) from public.assignments where employee_id = pg_temp.f('full')) = 0,
            'create: the joiner is an invited identity with no client, no state, no scope');
select t.ok((select job_title = 'Sorting Associate' and reports_to = t.u('03') and employment_type = 'full_time' from public.employee_org where employee_id = pg_temp.f('full')),
            'create: the org facts are kept beside the person');
select t.ok((select count(*) from public.onboarding_tasks where employee_id = pg_temp.f('full')) = 8
            and (select count(*) from public.onboarding_tasks where employee_id = pg_temp.f('full') and statutory) = 1,
            'checklist: a full-time joiner gets all eight tasks, the statutory one included');
select t.ok((select count(*) = 7 and bool_and(not statutory) from public.onboarding_tasks where employee_id = pg_temp.f('intern'))
            and (select count(*) = 7 and bool_and(not statutory) from public.onboarding_tasks where employee_id = pg_temp.f('contract'))
            and (select count(*) = 7 and bool_and(not statutory) from public.onboarding_tasks where employee_id = pg_temp.f('consult')),
            'checklist: an intern, a contractor and a consultant skip the statutory task (PF and gratuity)');
select t.ok((select due_on = pg_temp.today() + 3 from public.onboarding_tasks where employee_id = pg_temp.f('full') and code = 'offer_nda')
            and (select due_on = pg_temp.today() + 10 from public.onboarding_tasks where employee_id = pg_temp.f('full') and code = 'buddy')
            and (select due_on = pg_temp.today() + 13 from public.onboarding_tasks where employee_id = pg_temp.f('full') and code = 'goals'),
            'checklist: due dates are counted from the join date (-7 days, day 1, day 3)');
select t.ok((select action = 'hr_resource_created' and flagged and actor = t.u('17') from pg_temp.last_audit(pg_temp.f('hr2')))
            and (select count(*) from public.audit_log where target = pg_temp.f('hr2') and action = 'identity_created' and not flagged) = 1,
            'audit: an HR resource creating another HR resource is allowed, logged and FLAGGED');
select t.ok((select action = 'identity_created' and not flagged and actor = t.u('17') and detail->>'employment_type' = 'intern' from pg_temp.last_audit(pg_temp.f('intern'))),
            'audit: an ordinary joiner is one unflagged line');
select t.as_user(t.u('16'));   -- the HR Admin doing the same is not flagged
insert into fx (k, j) values ('hr3', app.add_joiner(jsonb_build_object('full_name', 'Hema HR', 'personal_email', 'hema@test.in', 'join_date', pg_temp.today()::text, 'system_role', 'hr_resource')));
update fx set id = (j->>'id')::uuid where id is null;
select t.as_service();
select t.ok((select action = 'hr_resource_created' and not flagged from pg_temp.last_audit(pg_temp.f('hr3'))), 'audit: the HR Admin creating an HR resource is logged, not flagged');
select t.as_user(t.u('01'));
select t.fails($q$ select app.add_joiner('{"full_name":"Second HR Admin","personal_email":"hra2@test.in","join_date":"2026-11-01","system_role":"hr_admin"}') $q$,
               'only HR adds joiners now', 'seats: not even the admin creates a second HR Admin (with the seat filled the admin adds nobody: migration 35)');

-- 2 · who may give which assignment ---------------------------------------------------------------------------------------------
select t.as_service();
update public.app_users set status = 'active' where id in (pg_temp.f('full'), pg_temp.f('intern'), pg_temp.f('hr2'));
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}') $q$, pg_temp.f('full'), t.scope('02')), 'outside what you manage', 'assign: HR never grants access');
select t.as_user(t.u('05'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}') $q$, pg_temp.f('full'), t.scope('02')), 'outside what you manage', 'assign: nor does an operator');
select t.as_user(t.u('04'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}') $q$, pg_temp.f('full'), t.scope('02')), 'outside what you manage', 'assign: nor a client''s own login');

select t.as_user(t.u('03'));   -- account of Prasaadam
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{}') $q$, pg_temp.f('full'), t.scope('02')), 'at least one stage', 'assign: an operator needs a stage');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{milling}') $q$, pg_temp.f('full'), t.scope('02')), 'not in this scope''s chain', 'assign: and one that is in the chain');
insert into fx (k, j) values ('a1', app.assign(pg_temp.f('full'), 'scope', t.scope('02'), 'operator', '{grading,sorting}', 'Gorakhpur mill'));
update fx set id = (j->'assignment'->>'id')::uuid where k = 'a1';
select t.ok((select j->'assignment'->'stages' = '["sorting","grading"]' and j->'assignment'->>'posting' = 'Gorakhpur mill'
                and j->'warnings' @> '[{"code":"adjacent_stages","first":"sorting","second":"grading"}]'
                and j->'warnings' @> '[{"code":"no_login"}]' from fx where k = 'a1'),
            'assign: the client''s account assigns within the client; stages come back in chain order, with the warnings worth a look');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, pg_temp.f('full'), t.scope('02')), 'already assigned here', 'assign: once per person and scope');
select t.fails(format($q$ select app.assign(%L, 'client', %L, 'client_account') $q$, pg_temp.f('intern'), '00000000-0000-4000-8000-000000000201'),
               'outside what you manage', 'assign: a client''s account cannot appoint another account');
select t.fails(format($q$ select app.assign(%L, 'state', %L, 'state_supervisor') $q$, pg_temp.f('intern'), '00000000-0000-4000-8000-000000000001'),
               'outside what you manage', 'assign: nor a state supervisor');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{procurement}') $q$, t.u('03'), t.scope('02')), 'cannot assign yourself', 'assign: nor themselves');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('04'), t.scope('02')), 'only view its own client', 'assign: a client login is never given a stage');
select t.as_service();
select t.ok((select count(*) from public.slot_assignments where assignment_id = pg_temp.f('a1')) = 2
            and (select action = 'assigned' and actor = t.u('03') and detail->'stages' = '["sorting","grading"]' from pg_temp.last_audit(pg_temp.f('full')))
            and (select count(*) from public.audit_log where target = pg_temp.f('full') and action = 'assigned') = 1
            and (select client_id = '00000000-0000-4000-8000-000000000201' from public.app_users where id = pg_temp.f('full')),
            'assign: one assignment, two stage rows, ONE audit line, and the person''s summary shows the client');
select t.ok((select count(*) from public.ledger where payload->>'act' = 'slot_assigned' and payload->>'user_id' = pg_temp.f('full')::text and actor = t.u('03')) = 2,
            'assign: each stage on an active scope is a ledger block, as before');

-- a guardrail, not a wall: the same person in another place the same season
select t.as_user(t.u('03'));
select t.ok(app.assignment_warnings(pg_temp.f('full'), 'scope', t.scope('01'), 'operator', '{qc}') @> '[{"code":"other_place","place":"Gorakhpur"}]',
            'guardrail: an operational role in two places in one season is warned about');
select t.ok(not (app.assignment_warnings(t.u('18'), 'scope', t.scope('01'), 'operator', '{qc}') @> '[{"code":"other_place"}]'),
            'guardrail: and not for someone who is nowhere else');
-- another client: the wall
insert into fx (k, id) select 'sx', id from (select gen_random_uuid() as id) x;
select t.as_service();
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain)
values (pg_temp.f('sx'), '00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'KH26', 'Exporter yard', '{lot_inward,qc,qr_activation}');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, pg_temp.f('intern'), pg_temp.f('sx')), 'outside what you manage', 'assign: a client''s account cannot assign into another client');
select t.as_user(t.u('02'));   -- supervisor of UP: any client's scope in the state, and the accounts of clients homed there
insert into fx (k, j) values ('a2', app.assign(pg_temp.f('intern'), 'scope', pg_temp.f('sx'), 'operator', '{qc}'));
insert into fx (k, j) values ('a3', app.assign(pg_temp.f('intern'), 'client', '00000000-0000-4000-8000-000000000202', 'client_account'));
update fx set id = (j->'assignment'->>'id')::uuid where id is null;
select t.ok((select count(*) from fx where k in ('a2', 'a3') and id is not null) = 2, 'assign: the state supervisor assigns in any client''s scope in the state, and appoints a client''s account');
select t.fails(format($q$ select app.assign(%L, 'state', %L, 'state_supervisor') $q$, pg_temp.f('full'), '00000000-0000-4000-8000-000000000001'),
               'outside what you manage', 'assign: but does not appoint a fellow supervisor');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{procurement}') $q$, pg_temp.f('full'), '00000000-0000-4000-8000-000000000407'),
               'outside what you manage', 'assign: nor into a scope in another state');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.assign(%L, 'state', %L, 'state_supervisor') $q$, pg_temp.f('hr2'), '00000000-0000-4000-8000-000000000002'),
               'outside what you manage', 'assign: the admin no longer appoints a state supervisor (migration 35: the HR Admin does)');
select t.as_user(t.u('16'));
insert into fx (k, j) values ('a4', app.assign(pg_temp.f('hr2'), 'state', '00000000-0000-4000-8000-000000000002', 'state_supervisor'));
update fx set id = (j->'assignment'->>'id')::uuid where id is null;
select t.as_service();
select t.ok((select role = 'state_manager' and system_role = 'hr_resource' from public.app_users where id = pg_temp.f('hr2'))
            and (select count(*) from public.ledger where payload->>'act' = 'assignment_given' and payload->>'assignment_id' = pg_temp.f('a4')::text and actor = t.u('16')) = 1,
            'assign: the HR Admin appoints a state supervisor (a ledger block); the two axes are independent: still an HR resource');
select t.ok((select role = 'client_manager' and client_id = '00000000-0000-4000-8000-000000000202' from public.app_users where id = pg_temp.f('intern')),
            'summary: the account of one client who also holds a stage for it is shown as that client''s manager');

-- 3 · stages, ending, moving ---------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok((app.set_stages(pg_temp.f('a1'), '{grading}')->'assignment'->'stages') = '["grading"]', 'stages: the manager changes which stages an assignment holds');
select t.fails(format($q$ select app.set_stages(%L, '{}') $q$, pg_temp.f('a1')), 'end the assignment instead', 'stages: an operator keeps at least one');
select t.fails(format($q$ select app.set_stages(%L, '{qc}') $q$, pg_temp.f('a2')), 'do not manage this scope', 'stages: not on another client''s scope');
select t.as_service();
select t.ok((select array_agg(stage_type) = '{grading}' from public.slot_assignments where assignment_id = pg_temp.f('a1'))
            and (select action = 'stages_changed' and detail->'before' = '["sorting","grading"]' and detail->'after' = '["grading"]' from pg_temp.last_audit(pg_temp.f('full'))),
            'stages: the stage rows follow, with one audit line showing before and after');

-- coverage: ending the only holder of a stage is allowed, and says what it leaves unstaffed
select t.as_user(t.u('03'));
select t.ok(app.end_preview((select id from public.assignments where employee_id = t.u('10') and scope_id = t.scope('02') and active))->'gaps' = '[]'::jsonb,
            'coverage: ending one of two holders of Grading would leave nothing unstaffed');
insert into fx (k, j) values ('end1', app.end_assignment(pg_temp.f('a1'), 'moved to another mill'));
select t.ok((select j->'gaps' = '[]'::jsonb and (j->'assignment'->>'active')::boolean = false and j->'assignment'->>'end_reason' = 'moved to another mill' from fx where k = 'end1'),
            'end: the assignment ends with its reason');
select t.ok(app.end_preview((select id from public.assignments where employee_id = t.u('09') and scope_id = t.scope('02') and active))->'gaps' = '["sorting"]'::jsonb,
            'coverage: ending the only holder of Sorting would leave Sorting unstaffed, and the preview says so');
insert into fx (k, j) values ('end2', app.end_assignment((select id from public.assignments where employee_id = t.u('09') and scope_id = t.scope('02') and active), null));
select t.ok((select j->'gaps' = '["sorting"]'::jsonb from fx where k = 'end2'), 'coverage: it is a warning, not a refusal: the answer names the gap');
select t.ok((app.scope_roster(t.scope('02'))->'gaps') = '["sorting"]'::jsonb
            and (select jsonb_array_length(s->'holders') = 0 from jsonb_array_elements(app.scope_roster(t.scope('02'))->'stages') s where s->>'stage' = 'sorting'),
            'coverage: the scope roster flags the unstaffed stage');
select t.fails(format($q$ select app.end_assignment(%L) $q$, pg_temp.f('a1')), 'already ended', 'end: once');
select t.fails(format($q$ select app.end_assignment(%L) $q$, pg_temp.f('a2')), 'outside what you manage', 'end: not another client''s assignment');
select t.fails(format($q$ select app.end_assignment(%L) $q$, (select id from public.assignments where employee_id = t.u('03') and active)), 'outside what you manage', 'end: not their own seat');
select t.as_service();
select t.ok(not app.is_my_stage(pg_temp.f('full'), t.scope('02'), 'grading')
            and (select action = 'revoked' and detail->>'reason' = 'moved to another mill' from pg_temp.last_audit(pg_temp.f('full')))
            and (select not active and stages = '{grading}' and ended_by = t.u('03') from public.assignments where id = pg_temp.f('a1')),
            'end: the person may no longer work there; the audit line says revoked; the row stays as history');

-- reassign: the old one ends, a new one begins, nothing is rewritten
select t.as_user(t.u('03'));
insert into fx (k, j) values ('re', app.reassign((select id from public.assignments where employee_id = t.u('10') and scope_id = t.scope('02') and active),
                                                t.scope('03'), '{milling}', 'Basti mill', 'season plan'));
select t.as_service();
select t.ok((select (j->'ended'->>'active')::boolean = false and j->'ended'->>'end_reason' = 'reassigned: season plan' and j->'gaps' = '["grading"]'::jsonb
                and j->'assignment'->>'scope_id' = t.scope('03')::text and j->'assignment'->'stages' = '["milling"]' from fx where k = 're'),
            'reassign: the old assignment ends (naming the gap it leaves), the new one starts');
select t.ok((select count(*) from public.audit_log where target = t.u('10') and action = 'reassigned') = 1
            and (select count(*) from public.audit_log where target = t.u('10') and action = 'assigned' and detail->>'scope_id' = t.scope('03')::text) = 1
            and app.is_my_stage(t.u('10'), t.scope('03'), 'milling') and not app.is_my_stage(t.u('10'), t.scope('02'), 'grading'),
            'reassign: two audit lines (reassigned, assigned); the person works in the new place only');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.reassign(%L, %L, '{qc}') $q$, (select id from public.assignments where employee_id = t.u('10') and scope_id = t.scope('03') and active), pg_temp.f('sx')),
               'outside what you manage', 'reassign: not into another client (and the old assignment is left untouched)');
select t.as_service();
select t.ok(app.is_my_stage(t.u('10'), t.scope('03'), 'milling'), 'reassign: a refused move changes nothing');

-- 4 · suspend, offboard, re-hire ---------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, t.u('05')), 'cannot suspend', 'lifecycle: a manager does not suspend an employee');
select t.fails(format($q$ select app.offboard_person(%L, current_date) $q$, t.u('05')), 'cannot offboard', 'lifecycle: nor offboard one');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.suspend_person(%L, '') $q$, t.u('05')), 'reason is required', 'suspend: a reason is required');
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, t.u('01')), 'cannot suspend', 'suspend: an HR resource cannot touch the admin');
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, t.u('16')), 'cannot suspend', 'suspend: nor the HR Admin');
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, t.u('17')), 'cannot suspend', 'suspend: nor themselves');
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, pg_temp.f('hr3')), 'cannot suspend', 'suspend: nor a fellow HR resource (that is the HR Admin''s)');
select app.suspend_person(t.u('05'), 'under inquiry');
select t.as_service();
select t.ok((select status = 'suspended' from public.app_users where id = t.u('05'))
            and (select count(*) from public.assignments where employee_id = t.u('05') and active) = 5
            and (select action = 'suspended' and detail->>'reason' = 'under inquiry' and actor = t.u('17') from pg_temp.last_audit(t.u('05'))),
            'suspend: access is frozen, every assignment kept, one audit line');
select t.as_user(t.u('17'));
select app.reinstate_person(t.u('05'));
select t.as_service();
select t.ok((select status = 'active' from public.app_users where id = t.u('05')) and app.is_my_stage(t.u('05'), t.scope('01'), 'procurement')
            and (select action = 'reinstated' from pg_temp.last_audit(t.u('05'))), 'reinstate: it is reversible');

select t.as_user(t.u('16'));
select t.ok((app.offboard_preview(t.u('05'))->>'assignments')::int = 5 and jsonb_array_length(app.offboard_preview(t.u('05'))->'gaps') = 5
            and (app.offboard_preview(t.u('05'))->'gaps'->0->>'stage') = 'procurement',
            'offboard: the preview counts the assignments it ends and names every stage left with nobody');
select t.fails(format($q$ select app.offboard_person(%L, null) $q$, t.u('05')), 'exit date is required', 'offboard: an exit date is required');
insert into fx (k, j) values ('off', app.offboard_person(t.u('05'), current_date, 'resigned', 'paid in full on 31 Oct', 'F16-2026-0005'));
select t.as_service();
select t.ok((select (j->>'assignments_ended')::int = 5 and jsonb_array_length(j->'gaps') = 5 from fx where k = 'off')
            and (select status = 'offboarded' and not active from public.app_users where id = t.u('05'))
            and (select count(*) from public.assignments where employee_id = t.u('05') and active) = 0
            and (select count(*) = 5 and bool_and(end_reason = 'offboarded') from public.assignments where employee_id = t.u('05'))
            and (select count(*) from public.slot_assignments where user_id = t.u('05')) = 0,
            'offboard: every assignment ends, no stage is left in their name, the person is recognised by nothing');
select t.ok((select exit_date = current_date and final_settlement = 'paid in full on 31 Oct' and form16_ref = 'F16-2026-0005' and recorded_by = t.u('16')
               from public.employee_exits where employee_id = t.u('05'))
            and (select action = 'offboarded' and flagged and (detail->>'assignments_ended')::int = 5 from pg_temp.last_audit(t.u('05')))
            and exists (select 1 from public.app_users where id = t.u('05')),
            'offboard: exit date, settlement and Form 16 are captured; the audit line is FLAGGED; the record is never deleted');
select t.fails(format($q$ select t.procure_as(%L, %L, %L) $q$, t.scope('01'), t.farmer('02'), t.u('05')), 'may not create', 'offboard: nothing can be recorded in their name');
select t.as_user(t.u('05'));
select t.ok((app.my_context()->'user') = 'null'::jsonb, 'offboard: their login opens nothing');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.app_users where id = t.u('05')) = 0, 'offboard: they leave the pool managers assign from');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{procurement}') $q$, t.u('05'), t.scope('01')), 'offboarded person cannot be given', 'offboard: and cannot be assigned');
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.offboard_person(%L, current_date) $q$, t.u('05')), 'offboarded already', 'offboard: once');
select t.fails(format($q$ select app.rehire_person(%L, current_date) $q$, t.u('06')), 'only an offboarded person', 're-hire: only someone who left');
insert into fx (k, j) values ('rehire', app.rehire_person(t.u('05'), current_date + 7));
select t.as_service();
select t.ok((select status = 'onboarding' and active and join_date = current_date + 7 from public.app_users where id = t.u('05'))
            and (select count(*) from public.onboarding_tasks where employee_id = t.u('05')) = 8
            and (select count(*) from public.assignments where employee_id = t.u('05') and active) = 0
            and (select count(*) from public.assignments where employee_id = t.u('05')) = 5
            and (select count(*) from public.employee_exits where employee_id = t.u('05')) = 1
            and (select action = 'rehired' from pg_temp.last_audit(t.u('05'))),
            're-hire: the same record comes back to onboarding with a fresh checklist; old assignments stay ended, the exit stays on file');

-- a client's own login is managed by whoever manages the client, not by HR
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.suspend_person(%L, 'x') $q$, t.u('04')), 'cannot suspend', 'client login: HR does not manage it');
select t.as_user(t.u('03'));
insert into fx (k, id) values ('viewer', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Buyer Desk', 'buyer@client.in'));
select t.fails($q$ select app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Other', 'other@client.in') $q$, 'do not manage this client', 'client login: only for a client you manage');
select app.suspend_person(pg_temp.f('viewer'), 'left the client');
select t.as_service();
select t.ok((select external and status = 'suspended' and role = 'client_view' and system_role = 'operational' from public.app_users where id = pg_temp.f('viewer'))
            and (select count(*) = 1 and bool_and(op_role = 'client_viewer') from public.assignments where employee_id = pg_temp.f('viewer'))
            and not exists (select 1 from public.onboarding_tasks where employee_id = pg_temp.f('viewer'))
            and not exists (select 1 from public.employee_org where employee_id = pg_temp.f('viewer')),
            'client login: made and suspended by the client''s account; no HR record, no checklist');

-- 5 · system roles and the two seats ----------------------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.set_system_role(%L, 'hr_resource') $q$, t.u('06')), 'cannot give this system role', 'roles: an HR resource does not promote');
select t.as_user(t.u('16'));
select app.set_system_role(t.u('06'), 'hr_resource');
select t.fails(format($q$ select app.set_system_role(%L, 'admin') $q$, t.u('06')), 'cannot give this system role', 'roles: the HR Admin makes an HR resource, not an admin');
select t.fails(format($q$ select app.set_system_role(%L, 'hr_admin') $q$, t.u('06')), 'System → Seats', 'roles: the HR Admin seat is not given this way');
select t.fails(format($q$ select app.set_system_role(%L, 'operational') $q$, t.u('16')), 'your own system role', 'roles: nobody changes their own');
select t.fails(format($q$ select app.appoint_hr_admin(%L) $q$, t.u('06')), 'only the admin appoints', 'seats: the HR Admin does not hand over the seat');
select t.as_service();
select t.ok((select system_role = 'hr_resource' and role = 'operator' from public.app_users where id = t.u('06'))
            and app.is_my_stage(t.u('06'), t.scope('01'), 'qc')
            and (select action = 'system_role_changed' and not flagged from pg_temp.last_audit(t.u('06'))),
            'roles: a system role is its own axis: the person keeps their stages');
select t.as_user(t.u('01'));
select app.appoint_hr_admin(t.u('06'));
select t.as_service();
select t.ok((select system_role = 'hr_admin' from public.app_users where id = t.u('06')) and (select system_role = 'hr_resource' from public.app_users where id = t.u('16'))
            and (select action = 'hr_admin_appointed' and flagged and detail->>'previous' = 'Asha (HR Admin)' from pg_temp.last_audit(t.u('06'))),
            'seats: the admin moves the HR Admin seat; the previous holder becomes an HR resource; flagged');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.set_system_role(%L, 'admin') $q$, t.u('17')), 'cannot give this system role',
               'roles: nobody gives the admin seat in the app, the admin included (migration 35: break-glass only)');
select t.as_service();   -- what the break-glass script does (scripts/bootstrap_admin.mjs, with the service key)
update public.app_users set system_role = 'admin' where id = t.u('17');
select t.ok((select system_role = 'admin' and role = 'admin' from public.app_users where id = t.u('17')),
            'roles: the database owner makes a second admin outside the app (as the break-glass script does)');
select t.as_user(t.u('01'));
select t.ok(jsonb_array_length(app.bootstrap_seats()->'admins') = 2 and (app.bootstrap_seats()->'hr_admin'->>'name') = 'QC Technician'
            and (app.bootstrap_seats()->'daily_code'->>'on')::boolean = false, 'seats: the Seats screen reads both seats');
select t.as_user(t.u('03'));
select t.fails($q$ select app.bootstrap_seats() $q$, 'only the admin', 'seats: only the admin opens them');

-- 6 · the screens' reads keep the wall ------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok((select count(*) from jsonb_array_elements(app.people_directory()) p where (p->>'unassigned')::boolean) >= 1
            and (select (p->>'elsewhere')::int = 2 and jsonb_array_length(p->'assignments') = 0 from jsonb_array_elements(app.people_directory()) p where p->>'id' = pg_temp.f('intern')::text)
            and (select count(*) from jsonb_array_elements(app.people_directory()) p where p->>'status' = 'offboarded') = 0,
            'directory: a manager sees the pool; another client''s assignments are a number only ("2 elsewhere"); no offboarded people');
select t.ok((select jsonb_array_length(app.employee_profile(pg_temp.f('intern'))->'assignments') = 0 and (app.employee_profile(pg_temp.f('intern'))->>'elsewhere')::int = 2),
            'profile: the same wall on the profile');
select t.ok((select not (app.employee_profile(t.u('06'))->'can'->>'suspend')::boolean and (app.employee_profile(t.u('09'))->'can'->>'assign')::boolean),
            'profile: it tells the screen what this reader may do (assign: yes; suspend: no)');
select t.fails($q$ select app.audit_feed() $q$, 'admin and the HR Admin', 'audit: a manager does not read the feed');
select t.fails($q$ select app.hr_pipeline() $q$, 'only HR', 'pipeline: nor the HR pipeline');
select t.fails(format($q$ select app.state_overview(%L) $q$, '00000000-0000-4000-8000-000000000001'), 'no access to this state', 'state overview: nor a state');
select t.as_user(t.u('02'));
select t.ok((app.state_overview('00000000-0000-4000-8000-000000000001')->>'clients')::int = 2
            and (select count(*) from jsonb_array_elements(app.state_overview('00000000-0000-4000-8000-000000000001')->'scopes') s where s->>'client_name' like 'Demo Exporter%') = 1
            and (select s->'gaps' from jsonb_array_elements(app.state_overview('00000000-0000-4000-8000-000000000001')->'scopes') s where s->>'scope_id' = t.scope('02')::text) @> '["sorting","grading"]',
            'state overview: every scope in the state across clients, with the stages nobody holds');
select t.fails(format($q$ select app.state_overview(%L) $q$, '00000000-0000-4000-8000-000000000002'), 'no access to this state', 'state overview: not another state');
select t.as_user(t.u('01'));
select t.ok((select count(*) from jsonb_array_elements(app.audit_feed(500, true)) l) >= 3
            and (select bool_and((l->>'flagged')::boolean) from jsonb_array_elements(app.audit_feed(500, true)) l)
            and (select count(*) from jsonb_array_elements(app.audit_feed(500, true)) l where l->>'action' in ('offboarded', 'hr_resource_created', 'hr_admin_appointed')) >= 3,
            'audit: the flagged feed holds the offboarding, the HR resource made by an HR resource, and the seat change');
select t.as_service();
select t.ok((select count(*) from app.verify_ledger()) = 0, 'the chain still verifies');

rollback;
