-- Migration 31: the identity layer's tables, the move of the existing people, and the rules the tables keep by
-- themselves (status, summary, forward-only assignments, the two seats, the append-only audit log).
begin;
select t.as_service();

-- 1 · the people of the old model became assignments ---------------------------------------------------------------------
select t.ok((select system_role = 'admin' and role = 'admin' and status = 'active' from public.app_users where id = t.u('01')),
            'moved: the admin holds the admin seat');
select t.ok((select count(*) = 1 and bool_and(lens = 'state' and op_role = 'state_supervisor' and state_id = '00000000-0000-4000-8000-000000000001')
               from public.assignments where employee_id = t.u('02') and active)
            and (select role = 'state_manager' and system_role = 'operational' and state_ids = '{00000000-0000-4000-8000-000000000001}'
                   from public.app_users where id = t.u('02')),
            'moved: the State Manager is an operational person with one state-lens assignment (Uttar Pradesh)');
select t.ok((select count(*) = 1 and bool_and(lens = 'client' and op_role = 'client_account' and client_id = '00000000-0000-4000-8000-000000000201')
               from public.assignments where employee_id = t.u('03') and active)
            and (select role = 'client_manager' and client_id = '00000000-0000-4000-8000-000000000201' from public.app_users where id = t.u('03')),
            'moved: the Client Manager has one client-lens assignment (the account of Prasaadam)');
select t.ok((select external and role = 'client_view' from public.app_users where id = t.u('04'))
            and (select count(*) = 1 and bool_and(op_role = 'client_viewer') from public.assignments where employee_id = t.u('04') and active),
            'moved: Client View is a client''s own login (not an employee) with a viewer assignment');
select t.ok((select count(*) = 5 and bool_and(lens = 'scope' and op_role = 'operator' and stages = '{procurement}' and season_code = 'KH26')
               from public.assignments where employee_id = t.u('05') and active),
            'moved: the procurement operator has five scope assignments, each holding Procurement');
select t.ok((select count(*) = 0 from public.slot_assignments sa
              where not exists (select 1 from public.assignments a where a.id = sa.assignment_id and a.active
                                   and a.employee_id = sa.user_id and a.scope_id = sa.scope_id and sa.stage_type = any(a.stages))),
            'moved: every stage row belongs to a live assignment of the same person and scope that lists it');
select t.ok((select count(*) = 0 from public.assignments where employee_id = t.u('12'))
            and (select role = 'operator' and client_id is null from public.app_users where id = t.u('12')),
            'moved: an operator who held no stage has no assignment and belongs to no client (the pool)');
select t.ok((select count(*) from public.audit_log where action = 'bootstrap_seed' and target = t.u('01')) = 1,
            'moved: the admin seat is in the audit log as the bootstrap seed');

-- 2 · a row written the old way by a script still means what it said -------------------------------------------------------
do $$
declare sm uuid; cm uuid; op uuid; a public.assignments; n0 bigint;
begin
  insert into public.app_users (role, display_name, email, state_ids)
  values ('state_manager', 'Two-state Manager', 'two.states@test.in', '{00000000-0000-4000-8000-000000000001,00000000-0000-4000-8000-000000000002}')
  returning id into sm;
  perform t.ok((select count(*) = 2 and bool_and(lens = 'state') from public.assignments where employee_id = sm and active)
               and (select cardinality(state_ids) = 2 and role = 'state_manager' from public.app_users where id = sm),
               'old-style insert: a state_manager row with two states becomes two state-lens assignments');
  insert into public.app_users (role, display_name, email, client_id)
  values ('client_manager', 'Other CM', 'other.cm@test.in', '00000000-0000-4000-8000-000000000202') returning id into cm;
  perform t.ok((select op_role = 'client_account' and client_id = '00000000-0000-4000-8000-000000000202' from public.assignments where employee_id = cm),
               'old-style insert: a client_manager row becomes the account of that client');

  -- a stage written straight into slot_assignments makes the assignment; the last stage removed ends it
  insert into public.app_users (display_name, email) values ('Fresh Operator', 'fresh.op@test.in') returning id into op;
  select coalesce(max(id), 0) into n0 from public.audit_log;
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (op, t.scope('02'), 'sorting');
  select * into a from public.assignments where employee_id = op;
  perform t.ok(a.active and a.lens = 'scope' and a.op_role = 'operator' and a.scope_id = t.scope('02') and a.stages = '{sorting}'
               and (select assignment_id = a.id from public.slot_assignments where user_id = op)
               and (select client_id = '00000000-0000-4000-8000-000000000201' from public.app_users where id = op),
               'stages: a stage given directly makes the scope assignment (and the summary shows the client)');
  perform t.ok((select count(*) from public.audit_log where id > n0
                   and action = 'assigned' and target = op and detail->'stages' = '["sorting"]') = 1,
               'stages: that is one "assigned" line in the audit log, with the stage');
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (op, t.scope('02'), 'grading');
  perform t.ok((select stages = '{sorting,grading}' from public.assignments where id = a.id)
               and (select count(*) from public.assignments where employee_id = op) = 1,
               'stages: a second stage on the same scope joins the same assignment, in chain order');
  delete from public.slot_assignments where user_id = op and stage_type = 'sorting';
  perform t.ok((select active and stages = '{grading}' from public.assignments where id = a.id), 'stages: one removed, the assignment stays');
  delete from public.slot_assignments where user_id = op;
  select * into a from public.assignments where id = a.id;
  perform t.ok(not a.active and a.ended_at is not null and a.end_reason = 'no stage left' and a.stages = '{grading}'
               and (select client_id is null from public.app_users where id = op),
               'stages: the last one removed ends the assignment; what it held stays on record');

  -- forward-only
  perform t.fails(format('update public.assignments set active = true, ended_at = null where id = %L', a.id),
                  'history', 'forward-only: an ended assignment cannot be reopened');
  perform t.fails(format('update public.assignments set end_reason = %L where id = %L', 'tidied', a.id),
                  'history', 'forward-only: nor edited');
  select * into a from public.assignments where employee_id = cm;
  perform t.fails(format('update public.assignments set client_id = %L where id = %L', '00000000-0000-4000-8000-000000000201', a.id),
                  'given or ended, not changed', 'forward-only: a live assignment cannot be pointed somewhere else');
  perform t.fails(format('update public.assignments set employee_id = %L where id = %L', sm, a.id),
                  'given or ended, not changed', 'forward-only: nor handed to another person');
  perform t.fails(format('update public.assignments set op_role = %L where id = %L', 'client_viewer', a.id),
                  'given or ended, not changed', 'forward-only: nor turned into another role');
  perform t.fails(format($q$ insert into public.assignments (employee_id, lens, op_role, client_id) values (%L, 'client', 'client_account', '00000000-0000-4000-8000-000000000202') $q$, cm),
                  'assignments_one_client', 'one live assignment per person and place');
  perform t.fails(format($q$ insert into public.assignments (employee_id, lens, op_role, scope_id) values (%L, 'scope', 'client_account', %L) $q$, cm, t.scope('01')),
                  'assignments_shape', 'shape: a client role cannot sit on a scope lens');
  perform t.fails(format($q$ insert into public.assignments (employee_id, lens, op_role, client_id) values (%L, 'client', 'client_viewer', '00000000-0000-4000-8000-000000000201') $q$, sm),
                  'client''s own login', 'shape: an employee is not given the client view');
  perform t.fails(format($q$ insert into public.assignments (employee_id, lens, op_role, state_id) values (%L, 'state', 'state_supervisor', '00000000-0000-4000-8000-000000000001') $q$, t.u('04')),
                  'only view its own client', 'shape: a client login is not given a state');
end $$;

-- 3 · status ---------------------------------------------------------------------------------------------------------------
do $$
declare second_admin uuid;
begin
  update public.app_users set status = 'suspended' where id = t.u('09');
  perform t.ok((select not active from public.app_users where id = t.u('09')), 'status: suspended is not active');
  perform t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('09'), t.scope('01')),
                  'suspended person cannot be given', 'status: a suspended person is given nothing new');
  perform t.ok((select count(*) = 2 from public.assignments where employee_id = t.u('09') and active), 'status: but keeps what they had');
  update public.app_users set status = 'active' where id = t.u('09');
  perform t.ok((select active from public.app_users where id = t.u('09')), 'status: reinstated is active again');
  update public.app_users set status = 'invited' where id = t.u('18');
  perform t.ok((select active from public.app_users where id = t.u('18')), 'status: an invited person can sign in (to do their checklist)');
  update public.app_users set status = 'offboarded' where id = t.u('18');
  perform t.ok((select not active from public.app_users where id = t.u('18')), 'status: an offboarded person is recognised by nothing');

  -- the root seat is never locked out
  perform t.fails(format($q$ update public.app_users set status = 'suspended' where id = %L $q$, t.u('01')), 'last active admin', 'root: the last admin cannot be suspended');
  perform t.fails(format($q$ update public.app_users set status = 'offboarded' where id = %L $q$, t.u('01')), 'last active admin', 'root: nor offboarded');
  perform t.fails(format($q$ update public.app_users set system_role = 'operational' where id = %L $q$, t.u('01')), 'last active admin', 'root: nor given another role');
  perform t.fails(format($q$ update public.app_users set active = false where id = %L $q$, t.u('01')), 'last active admin', 'root: nor switched off the old way');
  insert into public.app_users (role, display_name, email) values ('admin', 'Second Admin', 'second.admin@test.in') returning id into second_admin;
  perform t.ok((select system_role = 'admin' from public.app_users where id = second_admin), 'root: a row inserted as admin by a script takes the admin seat');
  update public.app_users set status = 'suspended' where id = t.u('01');
  perform t.ok((select status = 'suspended' from public.app_users where id = t.u('01')), 'root: with a second admin in place, the first can be suspended');
  perform t.fails(format($q$ update public.app_users set status = 'offboarded' where id = %L $q$, second_admin), 'last active admin', 'root: and then the second is the last');
  update public.app_users set status = 'active' where id = t.u('01');

  -- exactly one HR Admin
  perform t.fails(format($q$ update public.app_users set system_role = 'hr_admin' where id = %L $q$, t.u('17')), 'app_users_one_hr_admin', 'seats: there is exactly one HR Admin');
  update public.app_users set status = 'offboarded' where id = t.u('16');
  update public.app_users set system_role = 'hr_admin' where id = t.u('17');
  perform t.ok((select system_role = 'hr_admin' from public.app_users where id = t.u('17')), 'seats: an offboarded HR Admin leaves the seat free');
  perform t.fails(format($q$ update public.app_users set system_role = 'hr_resource' where id = %L $q$, t.u('04')), 'client login cannot hold a system role', 'seats: a client login holds no system role');
end $$;

-- 4 · the audit log is append-only -----------------------------------------------------------------------------------------
select t.fails($q$ update public.audit_log set action = 'nothing' where id = (select min(id) from public.audit_log) $q$, 'append-only', 'audit: a line cannot be changed');
select t.fails($q$ delete from public.audit_log where id = (select min(id) from public.audit_log) $q$, 'append-only', 'audit: nor removed');
select t.fails($q$ truncate public.audit_log $q$, 'append-only', 'audit: nor the table emptied');
select t.as_user(t.u('01'));
select t.fails($q$ insert into public.audit_log (action) values ('forged') $q$, 'permission denied', 'audit: not even the admin writes a line by hand');
select t.ok((select count(*) from public.audit_log) > 0, 'audit: the admin reads it');
select t.as_user(t.u('17'));
select t.ok((select count(*) from public.audit_log) > 0, 'audit: the HR Admin reads it');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.audit_log) = 0, 'audit: a Client Manager does not');
select t.as_service();

-- 5 · the scope carries its own state ------------------------------------------------------------------------------------------
do $$
declare sc uuid;
begin
  insert into public.scopes (client_id, crop_id, season_code, geography, chain)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'RB27', 'Maharajganj', '{procurement,qc,qr_activation}')
  returning id into sc;
  perform t.ok((select state_id = '00000000-0000-4000-8000-000000000001' from public.scopes where id = sc), 'scope: with no state given, it takes the client''s home state');
  update public.scopes set state_id = '00000000-0000-4000-8000-000000000002' where id = sc;
  perform t.ok((select state_id = '00000000-0000-4000-8000-000000000002' from public.scopes where id = sc), 'scope: a draft can be moved to another state');
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (t.u('05'), sc, 'procurement'), (t.u('06'), sc, 'qc'), (t.u('07'), sc, 'qr_activation');
  update public.scopes set status = 'active' where id = sc;
  perform t.fails(format($q$ update public.scopes set state_id = '00000000-0000-4000-8000-000000000001' where id = %L $q$, sc), 'frozen after activation', 'scope: after activation the state is frozen');
  -- the season ends: closing the scope ends every assignment on it
  update public.scopes set status = 'closed' where id = sc;
  perform t.ok((select count(*) = 3 and bool_and(not active and end_reason = 'season ended') from public.assignments where scope_id = sc)
               and (select count(*) = 0 from public.slot_assignments where scope_id = sc),
               'season end: closing a scope ends its assignments and removes the stages held there');
  perform t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('06'), sc), 'closed', 'season end: nothing is assigned on a closed scope');
  perform t.ok((select count(*) from app.verify_ledger()) = 0, 'the chain still verifies');
end $$;

rollback;
