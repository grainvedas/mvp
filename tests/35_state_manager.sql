-- Migration 41 (Veda, 13 Oct 2026, "GrainVeda MVP — State Manager role"): the State Manager owns one state. Ram here is
-- the demo UP State Manager (302); 'AS' an Assam State Manager made below. Every rule is the server's: each check asks
-- the database as the person would, through the API's own role.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and target = p_target $$;
create or replace function pg_temp.crop_state(p uuid) returns uuid language sql stable security definer as $$
  select state_id from public.crops where id = p $$;
create or replace function pg_temp.farmer(p uuid) returns public.farmers language sql stable security definer as $$
  select * from public.farmers where id = p $$;
\set UP '''00000000-0000-4000-8000-000000000001'''
\set AS '''00000000-0000-4000-8000-000000000002'''
\set KNM '''00000000-0000-4000-8000-000000000101'''
\set JOHA '''00000000-0000-4000-8000-000000000102'''
\set PRSDM '''00000000-0000-4000-8000-000000000201'''

-- fixtures, as a script would make them: an Assam client, its State Manager, an operator working only in Assam, an
-- unassigned person based in Assam, a client login shared by a UP client and the Assam client
do $$
declare asm constant uuid := '00000000-0000-4000-8000-000000000002'; c uuid; v uuid; sc uuid;
begin
  insert into public.clients (name, code, type, state_id) values ('Assam Client', 'ASMX', 'fpo', asm) returning id into c;
  insert into fx values ('ASMX', c);
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000b01', '00000000-0000-4000-8000-000000000b01', 'Assam State Manager', 'sm.assam@example.com') returning id into v;
  insert into fx values ('AS', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', asm);
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000b02', '00000000-0000-4000-8000-000000000b02', 'Assam Operator', 'op.assam@example.com') returning id into v;
  insert into fx values ('AO', v);
  insert into public.assignments (employee_id, lens, op_role, scope_id, stages) values (v, 'scope', 'operator', t.scope('07'), '{}');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000b03', '00000000-0000-4000-8000-000000000b03', 'Based in Assam', 'based.assam@example.com') returning id into v;
  insert into fx values ('AB', v);
  insert into public.employee_org (employee_id, base_state_id) values (v, asm);
  insert into public.app_users (id, auth_uid, display_name, email, external) values
    ('00000000-0000-4000-8000-000000000b04', '00000000-0000-4000-8000-000000000b04', 'Shared Login', 'shared.login@example.com', true) returning id into v;
  insert into fx values ('SL', v);
  insert into public.assignments (employee_id, lens, op_role, client_id) values
    (v, 'client', 'client_viewer', '00000000-0000-4000-8000-000000000201'), (v, 'client', 'client_viewer', c);
  insert into public.client_errors (user_id, kind, message) values (t.u('05'), 'error', 'an operator''s error');
end $$;

-- 1 · states are the admin's ------------------------------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.fails($q$ insert into public.states (name, code) values ('Bihar', 'BR') $q$, 'row-level security', 'A1 states: Ram creates no state');
do $$ declare n int; begin
  update public.states set name = 'Renamed' where id = '00000000-0000-4000-8000-000000000001'; get diagnostics n = row_count;
  perform t.ok(n = 0, 'A1 states: nor edits his own');
end $$;

-- 2 · scopes: read-only for him; the Client Manager builds them, in the client's own state ---------------------------------
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain) values (%L, %L, 'KH27', 'Ram''s scope', '{procurement,qc,qr_activation}') $q$, :PRSDM, :KNM),
               'row-level security', 'A2 scopes: Ram creates no scope');
do $$ declare n int; begin
  update public.scopes set geography = 'Renamed by Ram' where id = t.scope('01'); get diagnostics n = row_count;
  perform t.ok(n = 0, 'A2 scopes: nor edits one');
  update public.scopes set status = 'closed' where id = t.scope('01'); get diagnostics n = row_count;
  perform t.ok(n = 0, 'A2 scopes: nor closes one');
end $$;
select t.ok((select count(*) from public.scopes where state_id = :UP) >= 6 and (select count(*) from public.scopes where state_id = :AS) = 0,
            'A2 scopes: he still reads his state''s scopes, and only those');
select t.ok((app.my_context()->'user'->'can'->>'state_manager')::boolean and not (app.my_context()->'user'->'can'->>'build_scope')::boolean
            and not exists (select 1 from jsonb_array_elements(app.my_context()->'scopes') s where (s->>'build')::boolean),
            'A2 scopes: the screens are told: a State Manager, who builds no scope');
select t.as_user(t.u('03'));
do $$ declare sc uuid; begin
  insert into public.scopes (client_id, crop_id, season_code, geography, chain)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'KH27', 'CM scope', '{procurement,qc,qr_activation}') returning id into sc;
  perform t.ok(sc is not null and (select state_id from public.scopes where id = sc) = '00000000-0000-4000-8000-000000000001',
               'A2 scopes: the Client Manager still builds a scope for his client, in its state, and reads it back');
end $$;
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, state_id, season_code, geography, chain) values (%L, %L, %L, 'KH27', 'Jorhat 2', '{procurement,qc,qr_activation}') $q$, :PRSDM, :KNM, :AS),
               'in its client''s own state', 'scopes: a NEW scope is in its client''s own state (Veda, 13 Oct)');
select t.ok((app.my_context()->'user'->'can'->>'build_scope')::boolean and not (app.my_context()->'user'->'can'->>'state_manager')::boolean,
            'scopes: the Client Manager is told he builds scopes');

-- 3 · crops have a state; Ram writes his state's crops; the state is set once and logged --------------------------------
select t.as_user(t.u('02'));
select t.fails($q$ insert into public.crops (name, code, primary_unit) values ('No State', 'NOST', 'kg') $q$, 'row-level security', 'C1 crops: a new crop has his state');
select t.fails(format($q$ insert into public.crops (name, code, primary_unit, state_id) values ('Assam Crop', 'ASCR', 'kg', %L) $q$, :AS),
               'row-level security', 'C1 crops: not another state');
do $$ declare cr uuid; begin
  insert into public.crops (name, code, primary_unit, state_id) values ('Basmati', 'BSMT', 'kg', '00000000-0000-4000-8000-000000000001') returning id into cr;
  insert into fx values ('BSMT', cr);
  perform t.ok(cr is not null, 'C1 crops: a crop of his state, read back');
end $$;
select t.ok(pg_temp.audits('crop_added', pg_temp.f('BSMT')) = 1, 'C8 crops: the new crop is in the Audit log');
select t.ok(pg_temp.crop_state(:KNM) is null, 'C2 crops: Kalanamak has no state (the seed made it before crops had one)');
do $$ declare n int; begin
  update public.crops set gi_tag = 'GI 280' where id = '00000000-0000-4000-8000-000000000101'; get diagnostics n = row_count;
  perform t.ok(false, 'C2 crops: editing a crop with no state without setting it should be refused');
exception when others then
  perform t.ok(sqlerrm like '%row-level security%', 'C2 crops: a crop with no state is edited only by setting his state (' || sqlerrm || ')');
end $$;
do $$ declare n int; begin
  update public.crops set state_id = '00000000-0000-4000-8000-000000000001' where id = '00000000-0000-4000-8000-000000000101'; get diagnostics n = row_count;
  perform t.ok(n = 1, 'C2 crops: Ram sets Kalanamak''s state once');
end $$;
select t.ok(pg_temp.crop_state(:KNM) = :UP::uuid and pg_temp.audits('crop_state_set', :KNM) = 1, 'C2 crops: set to Uttar Pradesh, and logged');
select t.fails(format($q$ update public.crops set state_id = %L where id = %L $q$, :AS, :KNM), '', 'C2 crops: the state is not changed again');
do $$ declare n int; begin
  update public.crops set gi_tag = 'GI 280 (test)' where id = '00000000-0000-4000-8000-000000000101'; get diagnostics n = row_count;
  perform t.ok(n = 1 and pg_temp.audits('crop_changed', '00000000-0000-4000-8000-000000000101') = 1, 'C8 crops: a change is logged');
end $$;
select t.as_service();
update public.crops set state_id = :AS where id = :JOHA;
select t.as_user(t.u('02'));
do $$ declare n int; begin
  update public.crops set gi_tag = 'x' where id = '00000000-0000-4000-8000-000000000102'; get diagnostics n = row_count;
  perform t.ok(n = 0, 'C1 crops: nor edits another state''s crop');
end $$;
select t.as_user(pg_temp.f('AS'));
do $$ declare n int; begin
  update public.crops set gi_tag = 'x' where id = '00000000-0000-4000-8000-000000000101'; get diagnostics n = row_count;
  perform t.ok(n = 0, 'C1 crops: the Assam State Manager does not edit Uttar Pradesh''s crop');
end $$;
select t.as_user(t.u('01'));
do $$ declare n int; begin
  update public.crops set gi_tag = 'x'; get diagnostics n = row_count;
  perform t.ok(n = 0, 'C1 crops: the admin stays read-only');
end $$;
select t.as_user(t.u('03'));
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain) values (%L, %L, 'KH27', 'Joha here', '{procurement,qc,qr_activation}') $q$, :PRSDM, :JOHA),
               'another state', 'C1 crops: a scope is not built on another state''s crop');

-- 4 · farmers: created by the Client Manager and procurement; Ram verifies after him; the farmer's state decides -----------
select t.as_user(t.u('02'));
select t.fails(format($q$ insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres) values (%L, 'R', 'G', 'V', 'D', '+919812399001', 1) $q$, :PRSDM),
               'row-level security', 'A6 farmers: Ram creates no farmer');
select t.fails(format($q$ select app.import_farmers(%L, '[{"name":"x"}]', true) $q$, :PRSDM), 'farmers are added by', 'A6 farmers: nor imports any');
select t.as_user(t.u('03'));
do $$ declare f uuid; begin
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres)
  values ('00000000-0000-4000-8000-000000000201', 'Order Farmer', 'Father', 'Bansi', 'Siddharthnagar', '+919812399002', 1.5, 1.5) returning id into f;
  insert into fx values ('F1', f);
  perform t.ok((pg_temp.farmer(f)).state_id = '00000000-0000-4000-8000-000000000001', 'A6 farmers: the Client Manager adds one; it is of the client''s state');
end $$;
select t.fails(format($q$ update public.farmers set state_id = null where id = %L $q$, pg_temp.f('F1')), 'cannot be left blank', 'farmers: a farmer''s state is never left blank');
select t.as_user(t.u('02'));
select t.fails(format($q$ update public.farmers set status = 'active', verified_by = %L where id = %L $q$, t.u('02'), pg_temp.f('F1')),
               'has not verified this farmer yet', 'A6 farmers: Ram cannot skip the Client Manager (draft to active)');
do $$ begin
  update public.farmers set status = 'inactive' where id = pg_temp.f('F1');
  perform t.fails(format($q$ update public.farmers set status = 'active', verified_by = %L where id = %L $q$, t.u('02'), pg_temp.f('F1')),
                  'has not verified this farmer yet', 'A6 farmers: nor by way of inactive');
  update public.farmers set status = 'draft' where id = pg_temp.f('F1');
end $$;
select t.as_user(t.u('03'));
select t.ok((app.submit_farmer(pg_temp.f('F1'))).reviewed_by = t.u('03'), 'A6 farmers: the Client Manager verifies first');
select t.as_user(pg_temp.f('AS'));
do $$ declare n int; begin
  update public.farmers set name = 'Renamed in Assam' where id = pg_temp.f('F1'); get diagnostics n = row_count;
  perform t.ok(n = 0 and (select count(*) from public.farmers where id = pg_temp.f('F1')) = 0, 'farmers: another state''s manager neither reads nor edits it');
end $$;
select t.fails(format('select app.send_back_farmer(%L, %L)', pg_temp.f('F1'), 'not mine'), 'only a State Manager', 'farmers: nor sends it back');
select t.as_user(t.u('02'));
select t.ok((app.verify_farmer(pg_temp.f('F1'))).farmer_code is not null, 'A6 farmers: Ram verifies after the Client Manager: the Farmer ID');
do $$ begin
  perform set_config('app.change_reason', 'test', true);   -- migration 44: a farmer with an ID changes with a reason
  update public.farmers set status = 'inactive' where id = pg_temp.f('F1');
  update public.farmers set status = 'active', verified_by = t.u('02') where id = pg_temp.f('F1');
  perform t.ok((pg_temp.farmer(pg_temp.f('F1'))).status = 'active', 'farmers: he deactivates and reactivates a farmer of his state');
end $$;

-- 5 · people: Ram sees his state's people, and gives seats only to them ----------------------------------------------------
select t.as_user(t.u('02'));
select t.ok((select count(*) from public.app_users where id in (t.u('01'), t.u('16'), t.u('17'))) = 0, 'A3 people: no Admin, no HR Admin, no HR');
select t.ok((select count(*) from public.app_users where id in (pg_temp.f('AO'), pg_temp.f('AB'), pg_temp.f('AS'))) = 0, 'A3 people: nor another state''s people');
select t.ok((select count(*) from public.app_users where id in (t.u('05'), t.u('18'))) = 2, 'A3 people: but his state''s operator and the unassigned person based in UP');
select t.ok((select count(*) from public.employee_org where employee_id in (t.u('16'), t.u('17'), pg_temp.f('AB'))) = 0, 'A3 people: nor their HR records');
select t.ok(not exists (select 1 from jsonb_array_elements((app.people_page('{"limit":200}'))->'rows') r
                        where r->>'system_role' <> 'operational' or r->>'id' in (pg_temp.f('AO')::text, pg_temp.f('AB')::text)),
            'A3 people: People & access lists none of them');
select t.fails(format('select app.employee_profile(%L)', t.u('17')), 'not found', 'A3 people: an HR profile does not open by its address');
-- migration 44 (Veda, 14 Oct, A1): a scope's roster is its Client Manager's; the State Manager staffs no scope at all
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}') $q$, pg_temp.f('AO'), t.scope('02')), 'outside what you manage',
               'A3 assign: not to another state''s person');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}') $q$, t.u('17'), t.scope('02')), 'outside what you manage', 'A3 assign: never to HR');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{sorting}', null, null) $q$, t.u('18'), t.scope('02')), 'outside what you manage',
               'A1 assign: not even his state''s person: the Client Manager staffs the scope (migration 44)');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('17'), t.scope('01')),
               'HR holds no seat', 'A3 seats: a seat inserted directly does not seat HR');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('01'), t.scope('01')),
               'admin oversees', 'A3 seats: nor the admin');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('02'), t.scope('01')),
               'yourself', 'A3 seats: nor himself');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, pg_temp.f('AO'), t.scope('01')),
               'not in your state', 'A3 seats: nor another state''s person');
select t.fails(format($q$ select app.assign(%L, 'client', %L, 'client_account') $q$, t.u('18'), pg_temp.f('ASMX')), 'outside what you manage',
               'A3 assign: no Client Manager for another state''s client');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.app_users where id in (t.u('16'), t.u('17'))) = 0, 'A4 people: the Client Manager reads no HR person either (migration 44)');

-- client logins: one serving clients of two states is not Ram's alone
select t.as_user(t.u('02'));
select t.ok(not (app.employee_profile(pg_temp.f('SL'))->'can'->>'offboard')::boolean and (app.employee_profile(t.u('04'))->'can'->>'offboard')::boolean,
            'logins: a login shared with another state''s client is not his to manage; his own client''s is');
select t.fails(format($q$ select app.offboard_person(%L, current_date, 'x', '', '') $q$, pg_temp.f('SL')), '', 'logins: he cannot offboard the shared login');
do $$ declare n int; begin
  update public.app_users set email = 'taken.over@example.com' where id = pg_temp.f('SL'); get diagnostics n = row_count;
  perform t.ok(n = 0, 'logins: nor change its sign-in');
end $$;

-- 6 · Health is the admin's: the error list too ------------------------------------------------------------------------------
select t.ok((select count(*) from public.client_errors) = 0, 'A4 health: Ram reads no one''s app errors');
select t.as_user(t.u('01'));
select t.ok((select count(*) from public.client_errors) >= 1, 'A4 health: the admin does');

-- 7 · no override for him (the Client Manager's, as before) -----------------------------------------------------------------
select t.as_service();
do $$ declare p1 uuid; q1 uuid; begin
  p1 := t.procure(t.scope('01'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);
  perform t.verify(p1, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p1, t.u('06'),
          '{"qty_kg":120,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q1;
  insert into fx values ('Q1', q1);
end $$;
select t.as_user(t.u('02'));
do $$ declare n int; begin
  update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'Ram', 'authoriser', t.u('02')) where footprint_id = pg_temp.f('Q1');
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'override: Ram overrides no QC verdict');
end $$;
select t.as_user(t.u('03'));
do $$ declare n int; begin
  update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'CM', 'authoriser', t.u('03')) where footprint_id = pg_temp.f('Q1');
  get diagnostics n = row_count;
  perform t.ok(n = 1, 'override: control: the Client Manager still can');
end $$;

-- 8 · the ledger of his state, read-only ------------------------------------------------------------------------------------
select t.as_service();
update public.scopes set status = 'active' where id = t.scope('07');            -- an Assam block: the scope activated
select t.as_user(t.u('02'));
select t.fails($q$ select app.ledger_page(null, null, null, null, false, 10, 0) $q$, 'for the admin', 'A5 ledger: the whole ledger stays the admin''s');
select t.fails(format($q$ select app.state_ledger_page(%L, null, null, null, null, 10, 0) $q$, :AS), 'State Manager', 'A5 ledger: not another state''s');
select t.ok((select (x->>'total')::int > 0 and (x->'check') is not null from app.state_ledger_page(:UP, null, null, null, null, 500, 0) x),
            'A5 ledger: his state''s blocks, with the last check of the chain');
select t.ok(not exists (select 1 from jsonb_array_elements((app.state_ledger_page(:UP, null, null, null, null, 500, 0))->'rows') r
                        where r->>'scope' like '%Jorhat%' or r->>'client' = 'Assam Client'),
            'A5 ledger: no Assam block in it');
select t.ok((select (x->>'total')::int from app.state_ledger_page(:UP, 'scope_activate', null, null, null, 500, 0) x)
            = (select count(*) from public.ledger l join public.scopes s on s.id = l.scope_id where l.event = 'scope_activate' and s.state_id = :UP),
            'A5 ledger: filters work server-side (scope activations of UP, counted)');
select t.as_user(t.u('01'));
select t.ok((select (x->>'total')::int > 0 from app.state_ledger_page(:AS, null, null, null, null, 10, 0) x), 'A5 ledger: the admin reads any state''s');

-- 9 · his overview: every number says what it counts --------------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.ok((select (h->'clients'->>'total')::int = 2 and (h->'clients'->>'without_manager')::int = 1
             and (h->'attention'->>'no_manager')::int = 1 and (h->'crops'->>'total')::int = 2
             and (h->'state'->>'name') = 'Uttar Pradesh' from app.state_home(:UP) h),
            'B home: 2 clients (1 without a Client Manager), 2 crops of his state');
select t.ok((select (h->'scopes'->>'active')::int = (select count(*) from public.scopes where state_id = :UP and status = 'active')
             and (h->'scopes'->>'setup')::int = (select count(*) from public.scopes where state_id = :UP and status = 'draft')
             from app.state_home(:UP) h), 'B home: active scopes and those in setup, counted');
select t.ok((select jsonb_array_length(h->'clients'->'list') = 2 and not exists (select 1 from jsonb_array_elements(h->'clients'->'list') c where c->>'code' = 'ASMX')
             from app.state_home(:UP) h), 'B home: one card per client of his state');
select t.ok((select (h->'attention'->>'farmers_waiting')::int = 0 and jsonb_array_length(h->'pipeline') > 0 from app.state_home(:UP) h),
            'B home: farmers waiting for him (none now) and the pipeline of his state');
select t.ok((select (o->>'clients')::int = 2 and (o->>'clients_active')::int = 1 from app.state_overview(:UP) o),
            'E counts: "Clients working here" counts the state''s clients (2), and those with an active scope (1)');
select t.fails(format('select app.state_home(%L)', :AS), 'no access', 'B home: not another state''s overview');
select t.as_user(pg_temp.f('AS'));
select t.fails(format('select app.state_home(%L)', :UP), 'no access', 'B home: nor the Assam manager UP''s');
select t.as_user(t.u('01'));
select t.ok((select (h->'clients'->>'total')::int = 2 from app.state_home(:UP) h), 'B home: the admin reads it too');

-- a State Manager of two states still cannot move a crop from one to the other: the state is set once
select t.as_service();
insert into public.assignments (employee_id, lens, op_role, state_id) values (pg_temp.f('AS'), 'state', 'state_supervisor', :UP);
select t.as_user(pg_temp.f('AS'));
select t.fails(format($q$ update public.crops set state_id = %L where id = %L $q$, :AS, :KNM), 'set once', 'C2 crops: a State Manager of two states does not move a crop between them');

select t.as_service();
select t.ok((select count(*) from app.verify_ledger()) = 0, 'the chain still verifies');
rollback;
