-- Migration 39 (Veda, 12 Oct 2026): HR by geography, and a base location for everyone. An HR resource works only on
-- the people based in her states (records, joiners, openings, HR files); the HR Admin on everyone. "HR should never be
-- the State Manager": an HR person holds no seat. Asha (316) is the HR Admin; Imran (317) an HR resource for Uttar
-- Pradesh (seed 07); every demo employee is based in Uttar Pradesh.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.org(p uuid) returns public.employee_org language sql stable security definer as $$
  select * from public.employee_org where employee_id = p $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and (p_target is null or target = p_target) $$;
create or replace function pg_temp.task(p_emp uuid, p_code text) returns uuid language sql stable security definer as $$
  select id from public.onboarding_tasks where employee_id = p_emp and code = p_code $$;
create or replace function pg_temp.joiner(n int, extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('full_name', 'Geo Joiner ' || n, 'personal_email', 'geo' || n || '@example.com',
           'phone', '90001' || lpad(n::text, 5, '0'), 'join_date', (current_date + 10)::text, 'employment_type', 'full_time') || extra $$;
\set UP '''00000000-0000-4000-8000-000000000001'''
\set AS '''00000000-0000-4000-8000-000000000002'''

-- 1 · the schema and the seed -------------------------------------------------------------------------------------------
select t.ok(to_regclass('public.hr_states') is not null
            and exists (select 1 from information_schema.columns where table_name = 'employee_org' and column_name = 'base_state_id')
            and exists (select 1 from information_schema.columns where table_name = 'employee_org' and column_name = 'base_district'),
            'schema: hr_states, and a base state and district on every HR record');
select t.ok((select count(*) from public.employee_org e join public.app_users u on u.id = e.employee_id
              where not u.external and u.system_role <> 'admin' and e.base_state_id is null) = 0,
            'seed 07: every demo employee is based somewhere (Uttar Pradesh)');
select t.as_user(t.u('17'));
select t.ok((select (x->>'full')::boolean = false and x->'states' = jsonb_build_array(jsonb_build_object('id', :UP::uuid, 'name', 'Uttar Pradesh'))
               from app.hr_scope() x), 'Imran: an HR resource for Uttar Pradesh only');
select t.as_user(t.u('16'));
select t.ok((select (x->>'full')::boolean from app.hr_scope() x), 'Asha, the HR Admin: every state');

-- 2 · who gives an HR resource her states --------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.set_hr_states(%L, array[%L]::uuid[]) $q$, t.u('17'), :AS), 'only the HR Admin', 'states: an HR resource does not give herself states');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.set_hr_states(%L, array[%L]::uuid[]) $q$, t.u('17'), :AS), 'only the HR Admin', 'states: nor the admin while the HR Admin seat is filled');
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.set_hr_states(%L, array[%L]::uuid[]) $q$, t.u('18'), :AS), 'given to HR resources', 'states: only HR resources have states');
select t.fails(format($q$ select app.set_hr_states(%L, array[%L]::uuid[]) $q$, t.u('17'), gen_random_uuid()), 'unknown state', 'states: a state that exists');
select t.fails($q$ insert into public.hr_states (employee_id, state_id) values (t.u('17'), '00000000-0000-4000-8000-000000000002') $q$,
               'permission denied', 'states: not written directly through the API');

-- 3 · an Assam joiner, added by the HR Admin -------------------------------------------------------------------------------
insert into fx (k, j) values ('as1', app.add_joiner(pg_temp.joiner(1, jsonb_build_object('base_state_id', :AS, 'base_district', 'Nagaon'))));
insert into fx (k, j) values ('up1', app.add_joiner(pg_temp.joiner(2, jsonb_build_object('base_state_id', :UP))));
update fx set id = (j->>'id')::uuid where id is null;
select t.as_service();
select t.ok((pg_temp.org(pg_temp.f('as1'))).base_state_id = :AS and (pg_temp.org(pg_temp.f('as1'))).base_district = 'Nagaon'
            and (select detail->>'based' = 'Assam' from public.audit_log where action = 'identity_created' and target = pg_temp.f('as1')),
            'add joiner: the base state and district are kept and logged');

-- 4 · Imran (Uttar Pradesh) does not reach the Assam joiner -----------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok(not exists (select 1 from public.app_users where id = pg_temp.f('as1')) and exists (select 1 from public.app_users where id = pg_temp.f('up1'))
            and not exists (select 1 from public.employee_org where employee_id = pg_temp.f('as1'))
            and not exists (select 1 from public.onboarding_tasks where employee_id = pg_temp.f('as1'))
            and not exists (select 1 from public.employee_docs where employee_id = pg_temp.f('as1')),
            'reach: Imran reads nothing of a person based in Assam (person, HR record, checklist, documents), and the UP one');
select t.ok(exists (select 1 from public.app_users where id = t.u('16')) and not exists (select 1 from public.app_users where system_role = 'admin'),
            'reach: HR colleagues are named; the admin is not');
select t.fails(format($q$ select app.joiner_detail(%L) $q$, pg_temp.f('as1')), '', 'reach: no joiner page for the Assam joiner');
select t.fails(format($q$ select app.employee_profile(%L) $q$, pg_temp.f('as1')), 'person not found', 'reach: nor her profile');
select t.ok((app.employee_profile(pg_temp.f('up1'))->'identity'->>'id') = pg_temp.f('up1')::text, 'reach: the UP joiner''s profile opens');
select t.ok((select count(*) from jsonb_array_elements((app.joiners_page(jsonb_build_object('q', 'geo joiner', 'limit', 50)))->'rows') x
              where x->>'id' = pg_temp.f('as1')::text) = 0
            and (select count(*) from jsonb_array_elements((app.joiners_page(jsonb_build_object('q', 'geo joiner', 'limit', 50)))->'rows') x
                  where x->>'id' = pg_temp.f('up1')::text) = 1,
            'reach: the joiners list shows the UP joiner and not the Assam one');
select t.ok((select count(*) from jsonb_array_elements((app.people_page(jsonb_build_object('q', 'geo joiner', 'limit', 50)))->'rows') x
              where x->>'id' = pg_temp.f('as1')::text) = 0,
            'reach: People & access does not list her either');
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('as1'), 'countersign')), '', 'reach: no HR step done for her');
select t.fails(format($q$ select app.activate_joiner(%L, 'joined today, all fine') $q$, pg_temp.f('as1')), 'only HR', 'reach: not marked as joined');
select t.fails(format($q$ select app.suspend_person(%L, 'test') $q$, pg_temp.f('as1')), '', 'reach: not suspended');
select t.fails(format($q$ select app.update_joiner(%L, '{"job_title": "x"}') $q$, pg_temp.f('as1')), '', 'reach: her record is not edited');
select t.ok(not app.reset_login_allowed(pg_temp.f('as1')) and app.reset_login_allowed(pg_temp.f('up1')), 'reach: her password is not reset; the UP joiner''s is');
select t.ok((select (x->>'id') is null or x->>'id' <> pg_temp.f('as1')::text from jsonb_array_elements(app.invite_targets(array[pg_temp.f('as1')])->'targets') x limit 1) is not false,
            'reach: no invite for her');
select t.ok(not app.hr_covers_path(pg_temp.f('as1')::text || '/pan.jpg') and app.hr_covers_path(pg_temp.f('up1')::text || '/pan.jpg'),
            'reach: her files in the store are not Imran''s to open (the store''s rule asks this)');
select t.fails(format($q$ select app.set_base_location(%L, %L, 'Gorakhpur') $q$, pg_temp.f('as1'), :UP), 'only HR for this person', 'reach: nor moved into his state');
-- adding and importing: his states only
select t.fails(format($q$ select app.add_joiner(pg_temp.joiner(3, jsonb_build_object('base_state_id', %L))) $q$, :AS), 'not one of yours',
               'add joiner: an HR resource adds people for her states only');
insert into fx (k, j) values ('up2', app.add_joiner(pg_temp.joiner(4)));
update fx set id = (j->>'id')::uuid where id is null;
select t.ok((pg_temp.org(pg_temp.f('up2'))).base_state_id = :UP, 'add joiner: with no state given, his one state');
select t.ok((select string_agg(x->>'status' || ':' || coalesce(x->'reasons'->>0, ''), ',' order by (x->>'row')::int)
               from jsonb_array_elements(app.import_joiners(jsonb_build_array(
                 pg_temp.joiner(5, '{"state": "Assam"}'), pg_temp.joiner(6, '{"state": "Bihar"}'), pg_temp.joiner(7, '{"state": "UP", "district": "Basti"}')), true)->'rows') x)
            = 'error:imp.not_your_state,error:imp.state_unknown,warning:imp.no_opening',
            'import: a row for another state is refused, an unknown state named, his own goes in (warned: no opening)');
-- openings: his states only
select t.fails(format($q$ select app.save_opening(jsonb_build_object('state_id', %L, 'role', 'hr', 'positions', 1)) $q$, :AS), 'not one of yours',
               'openings: an HR resource plans openings for her states only');
select t.fails(format($q$ select app.opening_targets(%L) $q$, :AS), 'not one of yours', 'openings: nor reads another state''s clients for the form');
select t.as_user(t.u('16'));
insert into fx (k, j) values ('o_as', app.save_opening(jsonb_build_object('state_id', :AS, 'role', 'hr', 'positions', 2)));
update fx set id = (j->>'id')::uuid where id is null;
select t.as_user(t.u('17'));
select t.ok(not exists (select 1 from public.openings where id = pg_temp.f('o_as'))
            and not exists (select 1 from jsonb_array_elements(app.openings_summary()->'openings') x where x->>'id' = pg_temp.f('o_as')::text),
            'openings: the Assam opening is not on his page');
select t.fails(format($q$ select app.set_opening_status(%L, 'closed') $q$, pg_temp.f('o_as')), 'not in your states', 'openings: nor closed by him');

-- 5 · the base location -----------------------------------------------------------------------------------------------------
select app.set_base_location(pg_temp.f('up1'), :UP, '  Gorakhpur ');
select t.as_service();
select t.ok((pg_temp.org(pg_temp.f('up1'))).base_district = 'Gorakhpur'
            and (select detail->>'to' = 'Uttar Pradesh · Gorakhpur' from public.audit_log where action = 'base_location_set' and target = pg_temp.f('up1')),
            'base location: HR of the state sets the district, logged');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.set_base_location(%L, %L, null) $q$, pg_temp.f('up1'), :AS), 'not one of yours',
               'base location: an HR resource does not move a person out of her states');
select t.fails(format($q$ update public.employee_org set base_state_id = %L where employee_id = %L $q$, :AS, pg_temp.f('up1')),
               'set through HR''s screens', 'base location: not written directly through the API');
select t.ok((select x->>'state_name' = 'Uttar Pradesh' and x->>'district' = 'Gorakhpur' and (x->>'can_set_base')::boolean from app.person_geo(pg_temp.f('up1')) x),
            'base location: shown on the profile, with the right to change it');
select t.as_user(t.u('03'));
select t.ok((select not (x->>'can_set_base')::boolean and x->>'state_name' = 'Uttar Pradesh' from app.person_geo(pg_temp.f('up1')) x),
            'base location: a manager reads it, and does not set it (it grants nothing)');

-- 6 · the HR Admin gives Imran Assam too, then takes it back ----------------------------------------------------------------
select t.as_user(t.u('16'));
select app.set_hr_states(t.u('17'), array[:UP, :AS]::uuid[]);
select t.as_user(t.u('17'));
select t.ok(exists (select 1 from public.app_users where id = pg_temp.f('as1')) and (app.joiner_detail(pg_temp.f('as1'))->'person'->>'id') = pg_temp.f('as1')::text,
            'states: with Assam given, Imran reaches the Assam joiner');
select t.as_user(t.u('16'));
select app.set_hr_states(t.u('17'), array[:UP]::uuid[]);
select t.as_service();
select t.ok((select count(*) from public.hr_states where employee_id = t.u('17')) = 2
            and (select count(*) from public.hr_states where employee_id = t.u('17') and ended_at is not null) = 1
            and pg_temp.audits('hr_states_set', t.u('17')) = 2
            and (select detail->>'from' = 'Assam, Uttar Pradesh' and detail->>'to' = 'Uttar Pradesh' from public.audit_log
                  where action = 'hr_states_set' and target = t.u('17') order by id desc limit 1),
            'states: the whole list each time; an ended state is kept as history; both changes logged');
select t.as_user(t.u('17'));
select t.ok(not exists (select 1 from public.app_users where id = pg_temp.f('as1')), 'states: Assam taken back, the Assam joiner is out of reach again');
select t.as_user(t.u('16'));
select t.ok((select jsonb_array_length(x->'states') = 1 from jsonb_array_elements(app.hr_people_states()) x where x->>'id' = t.u('17')::text),
            'Seats page: each HR person with her states');

-- 7 · HR holds no seat ------------------------------------------------------------------------------------------------------
select t.fails(format($q$ select app.assign(%L, 'state', %L, 'state_supervisor') $q$, t.u('17'), :UP), 'HR holds no seat', 'no seat: not State Manager');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.assign(%L, 'client', %L, 'client_account') $q$, t.u('17'), '00000000-0000-4000-8000-000000000201'),
               'HR holds no seat', 'no seat: not a client''s account');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('17'), t.scope('01')), 'HR holds no', 'no seat: not a stage either');
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.set_system_role(%L, 'hr_resource') $q$, t.u('06')), 'holds a seat', 'no seat: someone with a seat is not made HR');
select t.as_service();
select t.ok((select system_role = 'operational' from public.app_users where id = t.u('06')), 'no seat: (QC Technician is still operational)');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.appoint_hr_admin(%L) $q$, t.u('06')), 'holds a seat', 'no seat: nor given the HR Admin seat');
-- leaving HR ends the states
select t.as_user(t.u('16'));
select app.set_system_role(t.u('17'), 'operational');
select t.as_service();
select t.ok(not exists (select 1 from public.hr_states where employee_id = t.u('17') and ended_at is null), 'leaving HR: her states end with it');
update public.app_users set system_role = 'hr_resource' where id = t.u('17');
insert into public.hr_states (employee_id, state_id) values (t.u('17'), :UP);

-- 8 · the Deputy seats State Managers in her states only -------------------------------------------------------------------
select t.as_user(t.u('16'));
select app.set_sm_deputy(t.u('17'));
select t.as_user(t.u('17'));
select t.ok(jsonb_typeof(app.ready_to_assign('state', :UP)) = 'array', 'Deputy: seats State Managers in her state');
select t.fails(format($q$ select app.ready_to_assign('state', %L) $q$, :AS), 'not yours to assign', 'Deputy: not in another state');

-- 9 · the HR Admin reaches everyone; a person with no base state only she does ---------------------------------------------------
select t.as_service();
update public.employee_org set base_state_id = null where employee_id = pg_temp.f('up2');
select t.as_user(t.u('17'));
select t.ok(not exists (select 1 from public.app_users where id = pg_temp.f('up2')), 'no base state: out of an HR resource''s reach');
select t.as_user(t.u('16'));
select t.ok(exists (select 1 from public.app_users where id = pg_temp.f('up2')) and exists (select 1 from public.app_users where id = pg_temp.f('as1')),
            'no base state: the HR Admin reaches her (and sets where she is based)');
select app.set_base_location(pg_temp.f('up2'), :UP, null);
select t.as_user(t.u('17'));
select t.ok(exists (select 1 from public.app_users where id = pg_temp.f('up2')), 'placed in Uttar Pradesh: back in Imran''s reach');

rollback;
