-- Migration 38 (Veda, 11 Oct 2026, "Onboarding at scale"; decisions "as recommended"). Openings, role at hire and the
-- checklist for the role, the bulk import, invites (the database half: the token's hash; the server function's half is
-- in web/tests/invite.test.ts), paged lists, bulk acts logged per person, the gate on Mark as joined, a statutory step on
-- paper, the admin on the HR Admin's checklist, the Deputy for seating State Managers, assigning several people at once,
-- "ready to assign", the numbers of an opening at every point, reminders. The 200-person run: tests/load_onboarding.mjs.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.j(p text) returns jsonb language sql stable as $$ select j from fx where k = p $$;
create or replace function pg_temp.opening(p_code text) returns jsonb language sql stable security definer as $$
  select x from jsonb_array_elements(app.openings_summary()->'openings') x where x->>'code' = p_code $$;
create or replace function pg_temp.n(p_code text, p_key text) returns int language sql stable as $$ select (pg_temp.opening(p_code)->>p_key)::int $$;
create or replace function pg_temp.audits(p_action text) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action $$;
create or replace function pg_temp.people() returns int language sql stable security definer as $$ select count(*)::int from public.app_users $$;
-- migration 59 (B4): email is no longer readable from the table through the API; the test reads it as the service would
create or replace function pg_temp.users_e() returns table (id uuid, email text) language sql stable security definer as $$ select id, email from public.app_users $$;
create or replace function pg_temp.org(p uuid) returns public.employee_org language sql stable security definer as $$
  select * from public.employee_org where employee_id = p $$;
create or replace function pg_temp.task(p_emp uuid, p_code text) returns uuid language sql stable security definer as $$
  select id from public.onboarding_tasks where employee_id = p_emp and code = p_code $$;
create or replace function pg_temp.row(p jsonb, p_row int) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(p->'rows') x where (x->>'row')::int = p_row $$;
create or replace function pg_temp.joiner(n int, opening text default null, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('full_name', 'Scale Joiner ' || n, 'personal_email', 'scale' || n || '@example.com',
           'phone', '90000' || lpad(n::text, 5, '0'), 'join_date', (current_date + 10)::text, 'employment_type', 'full_time',
           'opening', opening) || extra $$;

-- (migration 39: Imran works for both demo states here; what an HR resource may not do outside her states: tests/33)
select t.as_user(t.u('16'));
select app.set_hr_states(t.u('17'), array['00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000002']::uuid[]);

-- A · openings: HR plans them; the rules -------------------------------------------------------------------------------
select t.as_user(t.u('17'));                        -- Imran, an HR resource
insert into fx (k, j) values
  ('o_sm', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "state_manager", "positions": 1}')),
  ('o_cm', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "client_manager", "positions": 2, "client_id": "00000000-0000-4000-8000-000000000201"}')),
  ('o_op', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "operator", "stage": "procurement", "positions": 5, "scope_id": "00000000-0000-4000-8000-000000000401"}')),
  ('o_qc', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "operator", "stage": "qc", "positions": 3, "scope_id": "00000000-0000-4000-8000-000000000401"}')),
  ('o_hr', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "hr", "positions": 1}')),
  ('o_as', app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000002", "role": "client_manager", "positions": 1}'));
update fx set id = (j->>'id')::uuid where k like 'o\_%';
select t.ok(pg_temp.j('o_sm')->>'code' = 'UP-SM-001' and pg_temp.j('o_op')->>'code' = 'UP-OPR-001' and pg_temp.j('o_qc')->>'code' = 'UP-OPR-002'
            and pg_temp.j('o_as')->>'code' = 'AS-CM-001', 'openings: a code per state and role (UP-SM-001, UP-OPR-001, UP-OPR-002, AS-CM-001)');
select t.ok((pg_temp.j('o_op')->>'positions')::int = 5 and (pg_temp.j('o_op')->>'vacant')::int = 5 and (pg_temp.j('o_op')->>'joining')::int = 0
            and pg_temp.j('o_op')->>'client_id' = '00000000-0000-4000-8000-000000000201', 'openings: a new one is all vacant; the scope gives the client');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "operator", "positions": 3}') $q$,
               'needs the stage', 'openings: an operator opening names the stage');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000002", "role": "client_manager", "positions": 1, "client_id": "00000000-0000-4000-8000-000000000201"}') $q$,
               'not in this state', 'openings: the client must be in the state');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "operator", "stage": "sorting", "positions": 1, "scope_id": "00000000-0000-4000-8000-000000000401"}') $q$,
               'not in this scope', 'openings: the stage must be in the scope''s chain');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "operator", "stage": "qc", "positions": 0}') $q$,
               'positions', 'openings: at least one position');
select t.ok((select count(*) from jsonb_array_elements(app.opening_targets('00000000-0000-4000-8000-000000000001')->'clients') c where c->>'id' = '00000000-0000-4000-8000-000000000201') = 1
            and (select count(*) from jsonb_array_elements(app.opening_targets('00000000-0000-4000-8000-000000000001')->'scopes') c where c->>'id' = '00000000-0000-4000-8000-000000000401') = 1
            and not exists (select 1 from jsonb_array_elements(app.opening_targets('00000000-0000-4000-8000-000000000001')->'scopes') c where c->>'status' = 'closed'),
            'openings: HR reads the names of a state''s clients and open scopes for the form (it reads no client otherwise)');
select t.as_user(t.u('05'));
select t.fails($q$ select app.opening_targets('00000000-0000-4000-8000-000000000001') $q$, 'planned by HR', 'openings: an operator does not read the form''s lists');
select t.fails($q$ select app.openings_summary() $q$, 'for HR and the admin', 'openings: an operator does not read them');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "hr", "positions": 1}') $q$, 'only HR', 'openings: nor makes them');
select t.as_user(t.u('01'));
select t.ok(jsonb_array_length(app.openings_summary()->'openings') = 6 and not (app.openings_summary()->>'can_plan')::boolean,
            'openings: the admin reads them (numbers only), and cannot plan');
select t.fails($q$ select app.save_opening('{"state_id": "00000000-0000-4000-8000-000000000001", "role": "hr", "positions": 1}') $q$, 'only HR', 'openings: the admin does not make them');

-- A, D, E1 · Add joiner against an opening: role, the role's checklist, an HR owner; a full opening refuses ---------------------
select t.as_user(t.u('17'));
insert into fx (k, j) select 'op' || g, app.add_joiner(pg_temp.joiner(g) || jsonb_build_object('opening_id', pg_temp.f('o_op'))) from generate_series(1, 5) g;
update fx set id = (j->>'id')::uuid where k like 'op_';
select t.ok((pg_temp.org(pg_temp.f('op1'))).intended_role = 'operator' and (pg_temp.org(pg_temp.f('op1'))).intended_stage = 'procurement'
            and (pg_temp.org(pg_temp.f('op1'))).opening_id = pg_temp.f('o_op') and (pg_temp.org(pg_temp.f('op1'))).hr_owner = t.u('17'),
            'add joiner: the opening gives the role and the stage; the HR person adding is the HR owner');
select t.ok((select x.role = 'operator' from public.onboarding_templates x where x.id = (pg_temp.org(pg_temp.f('op1'))).template_id),
            'add joiner: the checklist is the Operator template, picked by the role');
select t.ok(pg_temp.n('UP-OPR-001', 'joining') = 5 and pg_temp.n('UP-OPR-001', 'vacant') = 0, 'opening numbers: 5 joining, 0 vacant');
select t.fails(format($q$ select app.add_joiner(%L) $q$, pg_temp.joiner(6) || jsonb_build_object('opening_id', pg_temp.f('o_op'))), 'opening is full',
               'add joiner: a full opening refuses a sixth person');
select app.set_opening_status(pg_temp.f('o_qc'), 'on_hold');
select t.fails(format($q$ select app.add_joiner(%L) $q$, pg_temp.joiner(7) || jsonb_build_object('opening_id', pg_temp.f('o_qc'))), 'not open',
               'add joiner: an opening on hold refuses people');
select app.set_opening_status(pg_temp.f('o_qc'), 'open');
insert into fx (k, j) values ('hr1', app.add_joiner(pg_temp.joiner(8) || jsonb_build_object('opening_id', pg_temp.f('o_hr'))));
update fx set id = (j->>'id')::uuid where k = 'hr1';
select t.as_service();
select t.ok((select system_role = 'hr_resource' from public.app_users where id = pg_temp.f('hr1'))
            and exists (select 1 from public.audit_log where action = 'hr_resource_created' and target = pg_temp.f('hr1') and flagged),
            'add joiner: an HR opening makes an HR person (flagged when an HR resource adds one)');
select t.as_user(t.u('17'));
select t.fails($q$ update public.employee_org set hr_owner = '00000000-0000-4000-8000-000000000317' where employee_id = '00000000-0000-4000-8000-000000000318' $q$,
               'through HR''s screens', 'the opening, role and HR owner are not written directly through the API');

-- B · the bulk import: dry run, commit of the valid rows, a second upload makes nobody twice -----------------------------------
insert into fx (k, j) values ('rows', jsonb_build_array(
  pg_temp.joiner(101, 'UP-OPR-002'),                                                      -- 1 ready
  pg_temp.joiner(102, 'UP-OPR-002', '{"personal_email": "not-an-email"}'),                -- 2 bad email
  pg_temp.joiner(103, 'UP-OPR-002', '{"phone": ""}'),                                     -- 3 no phone
  pg_temp.joiner(104, 'UP-OPR-002', '{"personal_email": "scale101@example.com"}'),        -- 4 the same email as row 1
  pg_temp.joiner(105, 'up-opr-002', '{"phone": "9000000001"}'),                           -- 5 phone of op1 (in the system); code in lower case is fine
  pg_temp.joiner(106, 'UP-XYZ-009'),                                                      -- 6 unknown opening
  pg_temp.joiner(107, 'UP-OPR-002', '{"join_date": "31/02/2026"}'),                       -- 7 bad date
  pg_temp.joiner(108, null, '{"reports_to": "nobody@example.com", "state": "up"}'),     -- 8 warning: no opening, unknown reports-to (based in UP: state by code)
  pg_temp.joiner(109, 'UP-OPR-002', '{"employment_type": "Intern"}'),                     -- 9 ready (2nd on the opening)
  pg_temp.joiner(110, 'UP-OPR-002'),                                                      -- 10 ready (3rd)
  pg_temp.joiner(111, 'UP-OPR-002'),                                                      -- 11 the opening is full by now
  pg_temp.joiner(1, 'UP-OPR-001'),                                                        -- 12 op1 again: already added
  pg_temp.joiner(112, 'UP-OPR-002', '{"employment_type": "permanent"}')));                -- 13 unknown employment type
insert into fx (k, j) values ('dry', app.import_joiners(pg_temp.j('rows'), true));
select t.ok(pg_temp.people() = (select pg_temp.people()), 'import: (setup)');
select t.ok((select string_agg((x->>'row') || ':' || (x->>'status'), ',' order by (x->>'row')::int) from jsonb_array_elements(pg_temp.j('dry')->'rows') x)
            = '1:ready,2:error,3:error,4:error,5:error,6:error,7:error,8:warning,9:ready,10:ready,11:error,12:skipped,13:error',
            'import, dry run: each row ready, warning, error or skipped');
select t.ok(pg_temp.row(pg_temp.j('dry'), 2)->'reasons' ? 'imp.bad_email' and pg_temp.row(pg_temp.j('dry'), 3)->'reasons' ? 'imp.no_phone'
            and pg_temp.row(pg_temp.j('dry'), 4)->'reasons' ? 'imp.email_twice' and pg_temp.row(pg_temp.j('dry'), 5)->'reasons' ? 'imp.phone_taken'
            and pg_temp.row(pg_temp.j('dry'), 6)->'reasons' ? 'imp.opening_unknown' and pg_temp.row(pg_temp.j('dry'), 7)->'reasons' ? 'imp.bad_date'
            and pg_temp.row(pg_temp.j('dry'), 8)->'reasons' ? 'imp.no_opening' and pg_temp.row(pg_temp.j('dry'), 8)->'reasons' ? 'imp.reports_to_unknown'
            and pg_temp.row(pg_temp.j('dry'), 11)->'reasons' ? 'imp.opening_full' and pg_temp.row(pg_temp.j('dry'), 12)->'reasons' ? 'imp.already_added'
            and pg_temp.row(pg_temp.j('dry'), 13)->'reasons' ? 'imp.bad_type', 'import, dry run: the reason of each');
select t.ok((pg_temp.j('dry')->'counts')::jsonb @> '{"rows": 13, "ready": 3, "warning": 1, "error": 8, "skipped": 1, "created": 0}',
            'import, dry run: the counts; nothing made');
insert into fx (k, id) values ('before', null);
update fx set j = to_jsonb(pg_temp.people()) where k = 'before';
insert into fx (k, j) values ('commit', app.import_joiners(pg_temp.j('rows'), false, 'test-batch-1'));
select t.ok((pg_temp.j('commit')->'counts'->>'created')::int = 4 and pg_temp.people() = (pg_temp.j('before'))::int + 4,
            'import, commit: the 4 valid rows (3 ready, 1 warning) are made, in one go');
select t.ok(pg_temp.n('UP-OPR-002', 'joining') = 3 and pg_temp.n('UP-OPR-002', 'vacant') = 0, 'import: the qc opening is full (3 joining)');
select t.as_service();
select t.ok((select count(*) from public.employee_org where import_batch = 'test-batch-1') = 4
            and (select bool_and(n > 0) from (select count(t2.id) as n from public.employee_org e left join public.onboarding_tasks t2 on t2.employee_id = e.employee_id
                                               where e.import_batch = 'test-batch-1' group by e.employee_id) x)
            and (select count(*) from public.app_users u join public.employee_org e on e.employee_id = u.id
                  where e.import_batch = 'test-batch-1' and u.status = 'invited' and u.auth_uid is null) = 4,
            'import: each person has a checklist, is Invited, and has no sign-in yet (it comes with the invite)');
select t.ok((select count(*) from public.audit_log where action = 'joiners_imported') = 1
            and (select count(*) from public.audit_log where action = 'identity_created' and detail->>'import_batch' = 'test-batch-1') = 4,
            'import: one summary line, and one "person created" line per person');
select t.ok((select employment_type = 'intern' from public.employee_org e join public.app_users u on u.id = e.employee_id where u.email = 'scale109@example.com'),
            'import: "Intern" is read as the intern employment type');
select t.as_user(t.u('17'));
update fx set j = to_jsonb(pg_temp.people()) where k = 'before';
insert into fx (k, j) values ('again', app.import_joiners(pg_temp.j('rows'), false, 'test-batch-2'));
select t.ok((pg_temp.j('again')->'counts'->>'created')::int = 0 and (pg_temp.j('again')->'counts'->>'skipped')::int = 5
            and pg_temp.people() = (pg_temp.j('before'))::int, 'import: the same file again makes nobody (5 rows already added)');
select t.as_user(t.u('05'));
select t.fails(format($q$ select app.import_joiners(%L, true) $q$, pg_temp.j('rows')), 'only HR', 'import: only HR');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.import_joiners(%L, true) $q$, (select jsonb_agg(pg_temp.joiner(g)) from generate_series(1, 1001) g)),
               'at most 1000', 'import: at most 1000 rows per file');
insert into fx (k, id) select 'imp' || row_number() over (order by u.email), u.id from pg_temp.users_e() u where u.email like 'scale1__@example.com' and u.email <> 'scale108@example.com';

-- C · invites: who may be invited (as the caller); the rest with the service key only ---------------------------------------
insert into fx (k, j) values ('targets', app.invite_targets(array[pg_temp.f('op1'), t.u('18'), t.u('01'), t.u('17')]));
select t.ok(jsonb_array_length(pg_temp.j('targets')->'people') = 1 and pg_temp.j('targets')->'people'->0->>'id' = pg_temp.f('op1')::text
            and pg_temp.j('targets')->>'actor' = t.u('17')::text
            and (select string_agg(x->>'reason', ',' order by x->>'reason') from jsonb_array_elements(pg_temp.j('targets')->'skipped') x) = 'not_allowed,not_allowed,not_joining',
            'invites: only joiners HR manages, not yet joined (Ravi has joined; the admin and oneself are not HR''s to invite)');
select t.fails(format($q$ select app.record_invite(%L, %L, %L) $q$, pg_temp.f('op1'), t.u('17'), repeat('a', 64)), 'permission denied', 'invites: a person cannot record one');
select t.fails($q$ select app.invite_lookup('x') $q$, 'permission denied', 'invites: nor look one up');
select t.as_service();
insert into fx (k, j) values ('inv1', app.record_invite(pg_temp.f('op1'), t.u('17'), repeat('a', 64)));
insert into fx (k, j) values ('inv2', app.record_invite(pg_temp.f('op1'), t.u('17'), repeat('b', 64), 'link', 72));
select t.ok(app.invite_lookup(repeat('a', 64))->>'state' = 'revoked' and app.invite_lookup(repeat('b', 64))->>'state' = 'ok'
            and app.invite_lookup(repeat('b', 64))->>'email' = 'scale1@example.com' and app.invite_lookup(repeat('c', 64))->>'state' = 'not_found',
            'invites: a new one replaces the old; the lookup gives the person');
select t.ok((select (expires_at - created_at) between interval '71 hours' and interval '73 hours' from public.invites where token_hash = repeat('b', 64))
            and not exists (select 1 from information_schema.column_privileges where table_name = 'invites' and column_name = 'token_hash' and grantee = 'authenticated'),
            'invites: 72 hours; nobody reads the hash through the API');
select app.use_invite((pg_temp.j('inv2')->>'id')::uuid);
select t.ok(app.invite_lookup(repeat('b', 64))->>'state' = 'used'
            and exists (select 1 from public.audit_log where action = 'invite_accepted' and target = pg_temp.f('op1') and actor = pg_temp.f('op1')),
            'invites: used once; "accepted" in the audit log, as the joiner');
select t.fails(format($q$ select app.use_invite(%L) $q$, pg_temp.j('inv2')->>'id'), 'cannot be used', 'invites: not twice');
insert into fx (k, j) values ('inv3', app.record_invite(pg_temp.f('op2'), t.u('17'), repeat('d', 64), 'link', 1));
update public.invites set expires_at = now() - interval '1 minute' where token_hash = repeat('d', 64);
select t.ok(app.invite_lookup(repeat('d', 64))->>'state' = 'expired', 'invites: an old one has expired');
select t.fails(format($q$ select app.use_invite(%L) $q$, pg_temp.j('inv3')->>'id'), 'cannot be used', 'invites: an expired one cannot be used');

-- E2, E3 · the lists, paged and filtered on the server -------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok((app.joiners_page(jsonb_build_object('opening', pg_temp.f('o_op')))->>'total')::int = 5, 'joiners: filtered by opening');
select t.ok((app.joiners_page('{"owner": "mine", "limit": 2}')->>'total')::int >= 10 and jsonb_array_length(app.joiners_page('{"owner": "mine", "limit": 2}')->'rows') = 2
            and (app.joiners_page('{"owner": "mine", "limit": 2, "offset": 2}')->'rows'->0->>'id') <> (app.joiners_page('{"owner": "mine", "limit": 2}')->'rows'->0->>'id'),
            'joiners: "Mine", in pages');
select t.ok((app.joiners_page('{"q": "scale joiner 10"}')->>'total')::int = 3 and (app.joiners_page('{"q": "9000000003"}')->>'total')::int = 1,
            'joiners: search by name and by phone');
select t.ok((app.joiners_page('{"role": "operator", "state": "00000000-0000-4000-8000-000000000001"}')->>'total')::int >= 8,
            'joiners: filtered by role and state');
select t.ok((select x->>'role' = 'operator' and x->>'opening_code' = 'UP-OPR-001' and x->>'hr_owner_name' = 'Imran (HR)' and x->'invite'->>'state' = 'accepted'
               from jsonb_array_elements(app.joiners_page('{"q": "scale joiner 1", "limit": 200}')->'rows') x where x->>'id' = pg_temp.f('op1')::text),
            'joiners: each row says role, opening, HR owner and the invite');
select t.ok((app.joiners_page('{}')->'stats') ?& array['joining', 'on_us', 'on_them', 'overdue', 'mine'], 'joiners: the numbers at the top come from the server');
select t.ok((app.people_page('{"q": "scale joiner 10"}')->>'total')::int = 3 and (app.people_page(jsonb_build_object('opening', pg_temp.f('o_op'), 'limit', 3))->>'total')::int = 5
            and jsonb_array_length(app.people_page(jsonb_build_object('opening', pg_temp.f('o_op'), 'limit', 3))->'rows') = 3,
            'people & access: search, filter by opening, in pages');
select t.as_user(t.u('02'));                        -- the State Manager assigns, so reads People & access
select t.ok((app.people_page('{}')->>'total')::int > 0, 'people & access: a manager reads it too');
select t.fails($q$ select app.joiners_page('{}') $q$, 'only HR', 'joiners: not a manager''s');
select t.as_user(t.u('05'));
select t.fails($q$ select app.people_page('{}') $q$, 'for HR and for those who assign', 'people & access: not an operator''s');
select t.as_user(t.u('16'));
select t.ok((app.audit_page('{"action": "joiners_imported"}')->>'total')::int = 2 and jsonb_array_length(app.audit_page('{"limit": 5}')->'rows') = 5
            and (app.audit_page('{"limit": 5, "offset": 5}')->'rows'->0->>'id')::bigint < (app.audit_page('{"limit": 5}')->'rows'->4->>'id')::bigint,
            'audit log: by action, in pages, newest first');
select t.as_user(t.u('17'));
select t.fails($q$ select app.audit_page('{}') $q$, 'admin and the HR Admin', 'audit log: not an HR resource''s');

-- G1 · Mark as joined: statutory step open → refused; on paper → allowed with a reason (flagged) ------------------------------
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('19')), 'statutory step is still open', 'joined: refused while the PF step is open');
select t.ok((app.joiner_detail(t.u('19'))->'activation'->'statutory_open'->>0) like 'PF%', 'joined: the joiner page says which statutory step is open');
select t.fails(format($q$ select app.record_on_paper(%L) $q$, pg_temp.task(t.u('19'), 'goals')), 'only a statutory step', 'on paper: only a statutory step');
select app.record_on_paper(pg_temp.task(t.u('19'), 'pf_gratuity'), 'Form 2 and Form F signed, ref 123456789012');
select t.as_service();
select t.ok((select status = 'done' and note like 'received on paper by HR: Form 2 and Form F signed, ref [number removed]' from public.onboarding_tasks where id = pg_temp.task(t.u('19'), 'pf_gratuity'))
            and exists (select 1 from public.audit_log where action = 'statutory_on_paper' and target = t.u('19') and flagged),
            'on paper: the step is done, the note keeps no number, a flagged audit line');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('19')), 'give a reason', 'joined: other steps open, so a reason is needed');
select t.ok(app.activate_joiner(t.u('19'), 'needed at the mill from Monday') = 'active', 'joined: with a reason');
select t.as_service();
select t.ok((select flagged and detail->>'reason' = 'needed at the mill from Monday' and (detail->>'open')::int > 0 from public.audit_log
              where action = 'activated_with_open_steps' and target = t.u('19')), 'joined: a flagged line with the reason and the number of open steps');
select t.as_user(t.u('17'));
insert into fx (k, j) values ('am', app.activate_many(array[pg_temp.f('imp1'), pg_temp.f('imp2')], 'wave one'));
select t.ok((pg_temp.j('am')->>'done')::int = 1 and (select count(*) from jsonb_array_elements(pg_temp.j('am')->'results') x
              where not (x->>'ok')::boolean and x->>'error' like '%statutory%') = 1,
            'joined, several at once: person by person (the intern has no statutory step; the full-time one does)');

-- E4 · bulk acts, each person on their own line ------------------------------------------------------------------------------
insert into fx (k, j) values ('cs', app.complete_task_many(array[pg_temp.f('op1'), pg_temp.f('op2'), pg_temp.f('op3')], 'countersign'));
select t.ok((pg_temp.j('cs')->>'done')::int = 3, 'bulk: HR''s countersign done for three joiners');
select t.as_service();
select t.ok((select count(*) from public.audit_log where action = 'task_done' and (detail->>'bulk')::boolean and target in (pg_temp.f('op1'), pg_temp.f('op2'), pg_temp.f('op3'))) = 3,
            'bulk: one audit line per person');
select t.as_user(t.u('17'));
select t.ok((select x->>'error' from jsonb_array_elements(app.complete_task_many(array[pg_temp.f('op4')], 'offer_nda')->'results') x) = 'joiners_step',
            'bulk: a joiner''s own step is not HR''s to tick');
insert into fx (k, j) values ('fd', app.update_joiner_many(array[pg_temp.f('op1'), pg_temp.f('op2')], '{"first_day_place": "Basti mill gate", "job_title": "ignored"}'));
select t.ok((pg_temp.j('fd')->>'done')::int = 2
            and app.joiner_detail(pg_temp.f('op2'))->'first_day'->>'place' = 'Basti mill gate'
            and app.joiner_detail(pg_temp.f('op2'))->'org'->>'job_title' is null, 'bulk: first-day details for a group (and nothing else)');
insert into fx (k, j) values ('own', app.set_hr_owner(array[pg_temp.f('op4'), pg_temp.f('op5')], t.u('16')));
select t.ok((pg_temp.j('own')->>'done')::int = 2 and (pg_temp.org(pg_temp.f('op5'))).hr_owner = t.u('16'), 'HR owner: the work is shared out');
select t.fails(format($q$ select app.set_hr_owner(array[%L]::uuid[], %L) $q$, pg_temp.f('op4'), t.u('05')), 'active HR person', 'HR owner: must be HR');
select t.ok((app.joiners_page('{"owner": "mine", "q": "scale joiner 4"}')->>'total')::int = 0
            and (app.joiners_page('{"q": "scale joiner 4"}')->>'total')::int = 1, 'HR owner: Imran''s "Mine" no longer lists the joiner given to Asha');
select t.as_user(t.u('16'));
select t.ok((app.joiners_page('{"owner": "mine", "q": "scale joiner 4"}')->>'total')::int = 1, 'HR owner: Asha''s "Mine" does');
select t.as_user(t.u('17'));

-- H2 · the admin does the HR and IT steps on the HR Admin's own checklist (flagged); not hers, not others' ------------------
select t.as_service();
select app.stamp_tasks(t.u('16'), (select id from public.onboarding_templates where is_default), current_date, 'full_time');
select t.as_user(t.u('01'));
select app.complete_task(pg_temp.task(t.u('16'), 'countersign'), '{}');
select t.as_service();
select t.ok(exists (select 1 from public.audit_log where action = 'hr_admin_task_by_admin' and target = t.u('16') and flagged and actor = t.u('01')),
            'admin: countersign on the HR Admin''s checklist, flagged');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(t.u('16'), 'offer_nda')), 'not yours', 'admin: not her own steps');
select t.ok(app.joiner_detail(t.u('16')) ? 'tasks' and not (app.joiner_detail(t.u('16')) ? 'docs') and not (app.joiner_detail(t.u('16')) ? 'personal')
            and (app.joiner_detail(t.u('16'))->>'can_do_steps')::boolean, 'admin: her page shows her steps, not her HR file');
select t.fails(format($q$ select app.joiner_detail(%L) $q$, t.u('19')), 'not found', 'admin: no other joiner''s page');

-- F3 · the Deputy for seating State Managers ---------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.set_sm_deputy(%L) $q$, t.u('17')), 'only the HR Admin', 'deputy: named by the HR Admin only');
select t.fails(format($q$ select app.assign(%L, 'state', '00000000-0000-4000-8000-000000000002', 'state_supervisor') $q$, t.u('18')), 'outside what you manage',
               'deputy: before being named, an HR resource seats nobody');
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.set_sm_deputy(%L) $q$, t.u('05')), 'active HR person', 'deputy: must be an HR person');
select app.set_sm_deputy(t.u('17'));
select t.as_user(t.u('17'));
select t.ok(app.is_sm_deputy() and (app.openings_summary()->>'can_seat')::boolean, 'deputy: Imran may seat State Managers now');
select app.assign(t.u('18'), 'state', '00000000-0000-4000-8000-000000000002', 'state_supervisor');
select t.as_service();
select t.ok(exists (select 1 from public.audit_log where action = 'state_seated_by_deputy' and target = t.u('18') and flagged)
            and exists (select 1 from public.audit_log where action = 'sm_deputy_set' and target = t.u('17') and flagged),
            'deputy: being named and each seating are flagged');
select t.as_user(t.u('16'));
select app.set_sm_deputy(null);
select t.as_user(t.u('17'));
select t.ok(not app.is_sm_deputy(), 'deputy: cleared');

-- F1, F2, A · ready to assign, 5 at once on a stage, the opening's numbers at each point ------------------------------------
select t.as_service();
update public.app_users set status = 'active' where id in (pg_temp.f('op1'), pg_temp.f('op2'), pg_temp.f('op3'), pg_temp.f('op4'), pg_temp.f('op5'));
select t.as_user(t.u('17'));
select t.ok(pg_temp.n('UP-OPR-001', 'joining') = 0 and pg_temp.n('UP-OPR-001', 'joined') = 5 and pg_temp.n('UP-OPR-001', 'ready') = 5
            and pg_temp.n('UP-OPR-001', 'assigned') = 0 and pg_temp.n('UP-OPR-001', 'waiting_wave') = 0, 'opening numbers: 5 joined, ready to assign (the scope is active)');
select t.as_user(t.u('03'));                        -- the Client Manager manages scope 401
select t.ok(jsonb_array_length(app.ready_to_assign('scope', '00000000-0000-4000-8000-000000000401')) = 6
            and (select count(*) from jsonb_array_elements(app.ready_to_assign('scope', '00000000-0000-4000-8000-000000000401')) x where x->>'stage' = 'procurement') = 5,
            'ready to assign: on the scope, the five for procurement and the intern who joined for QC, each with their stage');
insert into fx (k, j) values ('many', app.assign_many(array[pg_temp.f('op1'), pg_temp.f('op2'), pg_temp.f('op3'), pg_temp.f('op4'), pg_temp.f('op5'), t.u('02')],
                                                      'scope', '00000000-0000-4000-8000-000000000401', 'operator', '{procurement}'));
select t.ok((pg_temp.j('many')->>'done')::int = 5 and (select count(*) from jsonb_array_elements(pg_temp.j('many')->'results') x where not (x->>'ok')::boolean) = 1,
            'assign many: five on the stage in one act; a State Manager refused on its own line (migration 44)');
select t.as_service();
select t.ok((select count(*) from public.audit_log where action = 'assigned' and target in (pg_temp.f('op1'), pg_temp.f('op2'), pg_temp.f('op3'), pg_temp.f('op4'), pg_temp.f('op5'))) = 5,
            'assign many: one audit line per person');
select t.as_user(t.u('03'));
select t.ok(jsonb_array_length(app.ready_to_assign('scope', '00000000-0000-4000-8000-000000000401')) = 1, 'ready to assign: the five are off the list once assigned (the QC one is left)');
select t.as_user(t.u('05'));
select t.fails($q$ select app.ready_to_assign('scope', '00000000-0000-4000-8000-000000000401') $q$, 'not yours', 'ready to assign: only for whoever assigns there');
select t.as_user(t.u('17'));
select t.ok(pg_temp.n('UP-OPR-001', 'assigned') = 5 and pg_temp.n('UP-OPR-001', 'ready') = 0, 'opening numbers: 5 assigned');

-- "joined, waiting for their wave": Assam has no client yet, so its Client Manager waits; then a client comes
insert into fx (k, id) select 'n108', id from pg_temp.users_e() where email = 'scale108@example.com';
select t.ok((app.link_to_opening(array[pg_temp.f('n108')], pg_temp.f('o_as'))->'results'->0->>'ok')::boolean, 'link: a person added without an opening is linked to one');
select t.as_service();
update public.app_users set status = 'active' where id = pg_temp.f('n108');
select t.as_user(t.u('17'));
select t.ok(pg_temp.n('AS-CM-001', 'waiting_wave') = 1 and pg_temp.n('AS-CM-001', 'ready') = 0, 'waiting: joined, but nothing to assign them to yet');
select t.as_service();
insert into public.clients (state_id, name, code, type) values ('00000000-0000-4000-8000-000000000002', 'Assam Test Client', 'ATC', 'fpo');
select t.as_user(t.u('17'));
select t.ok(pg_temp.n('AS-CM-001', 'waiting_wave') = 0 and pg_temp.n('AS-CM-001', 'ready') = 1, 'waiting: a client in the state, and they are ready to assign');
select t.ok((select (x->>'positions')::int = (select sum((o->>'positions')::int) from jsonb_array_elements(app.openings_summary()->'openings') o where o->>'state_name' = 'Uttar Pradesh')
               from jsonb_array_elements(app.openings_summary()->'states') x where x->>'state_name' = 'Uttar Pradesh')
            and (app.openings_summary()->'total'->>'positions')::int = 13, 'openings: per state and overall totals add up (13 positions)');
select t.as_user(t.u('01'));
select t.ok(app.platform_overview()->'openings'->'total' = app.openings_summary()->'total', 'admin overview: the same totals as the Openings page');
select t.as_user(t.u('17'));
select t.ok((select x->>'error' from jsonb_array_elements(app.link_to_opening(array[t.u('18')], pg_temp.f('o_as'))->'results') x) = 'opening_full',
            'link: a full opening takes nobody more');

-- E5 · reminders, queued (no sender is set up here) ----------------------------------------------------------------------
select t.as_service();
update public.onboarding_tasks set due_on = current_date - 4 where id = pg_temp.task(pg_temp.f('imp3'), 'identity');
update public.app_users set email = 'imran.hr@example.com' where id = t.u('17');
select t.ok(app.queue_reminders() >= 3, 'reminders: a step 4 days late gets two nudges (day 1 and day 3), its HR owner a digest');
select t.ok(app.queue_reminders() = 0, 'reminders: the same round again queues nothing (at most two nudges per step, one digest a day)');
select t.ok((select count(*) from public.message_queue where task_id = pg_temp.task(pg_temp.f('imp3'), 'identity')) = 2
            and exists (select 1 from public.message_queue where kind = 'digest' and to_user = t.u('17') and body like '%Scale Joiner%')
            and not exists (select 1 from public.message_queue where body ~ '[0-9]{9,}'),
            'reminders: what is queued (names and step titles only)');
select t.ok(jsonb_array_length(app.messages_to_send(10)) >= 3, 'reminders: the server function reads the queue (service key)');
select t.as_user(t.u('17'));
select t.ok((app.reminder_state()->>'queued')::int >= 3, 'reminders: HR sees how many are waiting');
select t.fails($q$ select app.queue_reminders() $q$, 'permission denied', 'reminders: a person does not run the round');
select t.fails($q$ select app.messages_to_send(1) $q$, 'permission denied', 'reminders: nor read the queue');
select t.as_user(t.u('05'));
select t.ok(app.reminder_state() is null, 'reminders: an operator sees nothing of them');

rollback;
