-- Migration 32: access is the UNION of a person's assignments, and every "is a manager" question is asked about the
-- scope in hand. Fixtures are made here, as scripts would (old-style rows, stages written directly).
begin;
select t.as_service();

create temp table fx (k text primary key, id uuid);
grant select on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;

do $$
declare c1 constant uuid := '00000000-0000-4000-8000-000000000201'; c2 constant uuid := '00000000-0000-4000-8000-000000000202';
        up constant uuid := '00000000-0000-4000-8000-000000000001'; asm constant uuid := '00000000-0000-4000-8000-000000000002';
        v uuid; sx uuid; sa uuid; p1 uuid; q1 uuid; lx uuid;
begin
  -- sx: a scope of the OTHER client (Demo Exporter) in UP.   sa: a scope of Prasaadam in ASSAM.
  insert into public.scopes (client_id, crop_id, season_code, geography, chain)
  values (c2, '00000000-0000-4000-8000-000000000101', 'KH26', 'Exporter yard', '{lot_inward,qc,qr_activation}') returning id into sx;
  insert into public.scopes (client_id, crop_id, state_id, season_code, geography, chain)
  values (c1, '00000000-0000-4000-8000-000000000102', asm, 'KH26', 'Jorhat', '{lot_inward,qc,qr_activation}') returning id into sa;
  insert into fx values ('sx', sx), ('sa', sa);

  -- M: the account of client 2, who ALSO holds one stage (QC) on scope 01 of client 1.
  insert into public.app_users (id, auth_uid, role, display_name, email, client_id)
  values ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-000000000a01', 'client_manager', 'Mixed Manager', 'mixed@test.in', c2) returning id into v;
  insert into fx values ('M', v);
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (v, t.scope('01'), 'qc');
  -- O: an operator working for both clients.
  insert into public.app_users (id, auth_uid, display_name, email)
  values ('00000000-0000-4000-8000-000000000a02', '00000000-0000-4000-8000-000000000a02', 'Two-client Operator', 'two.clients@test.in') returning id into v;
  insert into fx values ('O', v);
  insert into public.slot_assignments (user_id, scope_id, stage_type) values (v, t.scope('04'), 'lot_inward'), (v, sx, 'lot_inward'), (v, sa, 'lot_inward');
  -- AS: the supervisor of Assam.
  insert into public.app_users (id, auth_uid, role, display_name, email, state_ids)
  values ('00000000-0000-4000-8000-000000000a03', '00000000-0000-4000-8000-000000000a03', 'state_manager', 'Assam Supervisor', 'assam@test.in', array[asm]) returning id into v;
  insert into fx values ('AS', v);
  -- E: an export manager on scope 03 who also holds Commercial there.
  insert into public.app_users (id, auth_uid, display_name, email)
  values ('00000000-0000-4000-8000-000000000a04', '00000000-0000-4000-8000-000000000a04', 'Export Manager', 'export@test.in') returning id into v;
  insert into fx values ('E', v);
  insert into public.assignments (employee_id, lens, op_role, scope_id) values (v, 'scope', 'export_manager', t.scope('03'));
  -- other stages of the two new scopes
  insert into public.slot_assignments (user_id, scope_id, stage_type) values
    (t.u('06'), sx, 'qc'), (t.u('07'), sx, 'qr_activation'), (t.u('06'), sa, 'qc'), (t.u('07'), sa, 'qr_activation');
  update public.scopes set status = 'active' where id in (sx, sa);

  -- records: p1 procurement + q1 QC in scope 01 (client 1); lx a lot in sx (client 2); la a lot in sa (Assam)
  p1 := t.procure(t.scope('01'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);
  perform t.verify(p1, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), c1, 'qc', p1, t.u('06'), '{"qty_kg":120,"sample_qty_kg":0.5,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q1;
  insert into public.footprints (scope_id, client_id, stage_type, created_by, payload)
  values (sx, c2, 'lot_inward', pg_temp.f('O'), '{"declared_kg":500,"weighed_kg":498,"source_type":"trader","source_name":"Exporter Supplier","moisture_pct":12}') returning id into lx;
  insert into fx values ('p1', p1), ('q1', q1), ('lx', lx);
  insert into public.footprints (scope_id, client_id, stage_type, created_by, payload)
  values (sa, c1, 'lot_inward', pg_temp.f('O'), '{"declared_kg":300,"weighed_kg":300,"source_type":"trader","source_name":"Jorhat Supplier","moisture_pct":12}') returning id into v;
  insert into fx values ('la', v);
end $$;

-- 1 · THE TRAP: a manager of client 2 who holds one stage for client 1 is NOT a manager in client 1 ------------------------
select t.ok(app.manages_scope(pg_temp.f('M'), pg_temp.f('sx')) and not app.manages_scope(pg_temp.f('M'), t.scope('01')),
            'union: the mixed manager manages the other client''s scope, and does not manage the scope where they hold one stage');
select t.ok(app.is_my_stage(pg_temp.f('M'), t.scope('01'), 'qc') and not app.is_my_stage(pg_temp.f('M'), t.scope('01'), 'procurement')
            and app.is_my_stage(pg_temp.f('M'), pg_temp.f('sx'), 'lot_inward'),
            'union: in client 1 they work at their one stage only; in client 2 at any stage');
select t.as_user(pg_temp.f('M'));
select t.ok((select count(*) from public.scopes) = 2, 'union: they see exactly two scopes (the one they manage, the one they hold a stage in)');
select t.ok((select count(*) from public.footprints where scope_id = t.scope('01')) = 2 and (select count(*) from public.footprints where id = pg_temp.f('lx')) = 1,
            'union: in client 1 they see their stage and the one behind it (thumb rule); in client 2 everything');
select t.fails(format($q$ select app.withdraw_footprint(%L, 'tidying up') $q$, pg_temp.f('q1')), 'only a manager', 'trap: they cannot withdraw a record in client 1');
select t.ok((app.withdraw_footprint(pg_temp.f('lx'), 'wrong weight')).status = 'superseded', 'trap: they can in client 2, which they manage');
select t.ok(not (app.stage_form(t.scope('01'), 'procurement')->>'can_create')::boolean and (app.stage_form(t.scope('01'), 'qc')->>'can_create')::boolean,
            'trap: the form says so too: create at QC only');
select t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
   values (%L, '00000000-0000-4000-8000-000000000201', 'procurement', %L, %L, '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') $q$,
   t.scope('01'), t.farmer('02'), pg_temp.f('M')), 'may not create', 'trap: they cannot record at another stage of client 1');
update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'buyer accepts', 'authoriser', pg_temp.f('M')) where footprint_id = pg_temp.f('q1');
select t.as_service();
select t.ok((select override is null from public.qc_verdicts where footprint_id = pg_temp.f('q1')), 'trap: they cannot override a QC verdict in client 1');
select t.fails(format($q$ update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'x', 'authoriser', %L) where footprint_id = %L $q$,
                      pg_temp.f('M'), pg_temp.f('q1')), 'client_manager or above', 'trap: nor be named as the authoriser by anyone else');
select t.as_user(pg_temp.f('M'));
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'procurement') $q$, pg_temp.f('M'), t.scope('01')),
               'row-level security', 'trap: they cannot give themselves another stage in client 1');
select t.fails(format($q$ select app.lot_trace(%L) $q$, pg_temp.f('q1')), 'not allowed to trace', 'trap: nor trace a lot of client 1');
select t.ok((select count(*) from public.farmers) = 0, 'trap: nor read the farmers of client 1 (a QC stage does not open them)');
select t.ok((select count(*) from public.ledger where scope_id = t.scope('01') and footprint_id is null) = 0, 'trap: nor the scope-level ledger blocks of client 1');
select t.ok((select count(*) from public.ledger where scope_id = pg_temp.f('sx') and footprint_id is null) > 0, 'union: but those of the scope they manage');
select t.as_service();

-- 2 · one operator, two clients, two states: the union, and nothing more -----------------------------------------------------
select t.as_user(pg_temp.f('O'));
select t.ok((select count(*) from public.scopes) = 3 and (select count(distinct client_id) from public.scopes) = 2 and (select count(distinct state_id) from public.scopes) = 2,
            'union: an operator assigned for two clients in two states sees those three scopes');
select t.ok((select count(*) from public.clients) = 2, 'union: and the names of both clients');
select t.ok(jsonb_array_length(app.my_context()->'assignments') = 3 and jsonb_array_length(app.my_context()->'slots') = 3
            and (select bool_and(not (s->>'manage')::boolean) from jsonb_array_elements(app.my_context()->'scopes') s),
            'union: my_context lists the three assignments and manages none of the scopes');
select t.ok((select count(*) from public.footprints) = 2, 'union: their own two lots (one per client), nothing of scope 01');
select t.ok((select count(*) from public.app_users) = 1, 'union: and no colleague: an operator reads only their own row');
select t.as_service();

-- 3 · state lens and client lens are independent ----------------------------------------------------------------------------
select t.as_user(t.u('02'));   -- supervisor of Uttar Pradesh
select t.ok((select count(*) from public.scopes where id = pg_temp.f('sx')) = 1 and (select count(*) from public.scopes where id = pg_temp.f('sa')) = 0,
            'state lens: the UP supervisor sees the other client''s UP scope, not Prasaadam''s Assam scope');
select t.ok((select count(*) from public.footprints where id = pg_temp.f('la')) = 0, 'state lens: nor its records');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('09'), pg_temp.f('sa')),
               'row-level security', 'state lens: nor can they staff it');
select t.fails($q$ insert into public.scopes (client_id, crop_id, state_id, season_code, geography, chain)
   values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000002', 'KH26', 'Dibrugarh', '{lot_inward,qc,qr_activation}') $q$,
   'row-level security', 'state lens: nor open a scope in a state that is not theirs');
do $$
declare sc uuid;
begin
  insert into public.scopes (client_id, crop_id, season_code, geography, chain)
  values ('00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'RB27', 'Exporter yard 2', '{lot_inward,qc,qr_activation}') returning id into sc;
  perform t.ok(sc is not null, 'state lens: they open a scope for any client in their own state, and read it back');
end $$;
select t.as_user(pg_temp.f('AS'));   -- supervisor of Assam
select t.ok((select count(*) from public.scopes) = 2 and (select bool_and(state_id = '00000000-0000-4000-8000-000000000002') from public.scopes),
            'state lens: the Assam supervisor sees the two Assam scopes (one draft from the seed) and no UP scope');
select t.ok((select count(*) from public.clients) = 1, 'state lens: and the one client that works in Assam, though its home is UP');
select t.ok((select count(*) from public.farmers) = 5, 'state lens: with that client''s farmers');
select t.ok((select count(*) from public.footprints) = 1, 'state lens: and the one record made in Assam');
select t.ok((app.withdraw_footprint(pg_temp.f('la'), 'state supervisor test')).status = 'superseded', 'state lens: which they may withdraw: they manage every scope in their state');
select t.as_user(t.u('03'));   -- account of Prasaadam
select t.ok((select count(*) from public.scopes where state_id = '00000000-0000-4000-8000-000000000002') = 2
            and (select count(*) from public.scopes where id = pg_temp.f('sx')) = 0,
            'client lens: the client''s account sees its scopes in both states, and not the other client''s scope');
do $$
declare sc uuid;
begin
  insert into public.scopes (client_id, crop_id, state_id, season_code, geography, chain)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000002', 'KH26', 'Dibrugarh', '{lot_inward,qc,qr_activation}')
  returning id into sc;
  perform t.ok(sc is not null, 'client lens: and opens a scope for the client in any state, reading it back');
end $$;
select t.fails($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain)
   values ('00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'KH26', 'Not mine', '{lot_inward,qc,qr_activation}') $q$,
   'row-level security', 'client lens: but not for another client');
select t.as_service();

-- 4 · those who read a whole scope without managing it --------------------------------------------------------------------------
select t.as_user(t.u('04'));   -- the client's own login
select t.ok((select count(*) from public.scopes) = 9, 'viewer: the client''s login reads all the client''s scopes, in both states');
select t.ok((select count(*) from public.footprints where scope_id = t.scope('01')) = 2 and (select count(*) from public.farmers) = 5, 'viewer: their records and farmers');
select t.fails($q$ insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres)
   values ('00000000-0000-4000-8000-000000000201','X','Y','Z','W','+919999999999','1') $q$, 'row-level security', 'viewer: writes no farmer');
select t.fails(format($q$ select app.withdraw_footprint(%L, 'no') $q$, pg_temp.f('q1')), 'only a manager', 'viewer: withdraws nothing');
select t.ok((app.lot_trace(pg_temp.f('q1'))->'steps') is not null, 'viewer: may trace a lot');
select t.ok((select count(*) from public.app_users) = 1 and (select count(*) from public.assignments) = 1, 'viewer: reads only its own row and its own assignment');
select t.as_user(pg_temp.f('E'));   -- export manager on scope 03, no stage yet
select t.ok((select count(*) from public.scopes) = 1 and app.sees_whole_scope(t.scope('03')) and not app.i_manage_scope(t.scope('03')),
            'export manager: sees the whole of the one scope they are assigned to, and manages nothing');
select t.ok(not app.acts_in_scope(t.scope('03')), 'export manager: without a stage they write nothing there');
select t.as_service();
insert into public.slot_assignments (user_id, scope_id, stage_type) values (pg_temp.f('E'), t.scope('03'), 'commercial');
select t.ok((select count(*) = 1 and bool_and(op_role = 'export_manager' and stages = '{commercial}') from public.assignments where employee_id = pg_temp.f('E') and active),
            'export manager: a stage given to them joins the same assignment');
select t.ok(app.is_my_stage(pg_temp.f('E'), t.scope('03'), 'commercial') and not app.is_my_stage(pg_temp.f('E'), t.scope('03'), 'milling'),
            'export manager: with Commercial they work at Commercial only');
select t.ok((select count(*) from public.ledger where payload->>'act' = 'assignment_given' and payload->>'user_id' = pg_temp.f('E')::text and scope_id = t.scope('03')) = 1,
            'export manager: being given the whole-scope view is a ledger block of that scope');

-- 5 · HR: people, and nothing of the operation -------------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok((select count(*) from public.scopes) = 0 and (select count(*) from public.footprints) = 0 and (select count(*) from public.farmers) = 0
            and (select count(*) from public.clients) = 0 and (select count(*) from public.ledger) = 0,
            'HR: no scope, no record, no farmer, no client, no ledger');
select t.ok((select count(*) from public.app_users where not external) = (select count(*) from public.app_users) and (select count(*) from public.app_users) >= 18,
            'HR: every employee, and no client login');
select t.ok((select count(*) from public.assignments) > 30, 'HR: reads assignments (to see what an offboarding ends)');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('18'), t.scope('01')),
               'row-level security', 'HR: but gives no stage');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('18'), t.scope('01')),
               'outside what you manage', 'HR: and no assignment');
select t.ok((app.my_context()->'user'->'can'->>'hr')::boolean and not (app.my_context()->'user'->'can'->>'assign')::boolean
            and jsonb_array_length(app.my_context()->'scopes') = 0, 'HR: my_context says the same');

-- 6 · no assignment, not yet joined, suspended, lapsed -----------------------------------------------------------------------------
select t.as_user(t.u('18'));   -- active, nothing assigned
select t.ok((select count(*) from public.scopes) = 0 and (select count(*) from public.footprints) = 0 and (select count(*) from public.clients) = 0
            and jsonb_array_length(app.my_context()->'assignments') = 0 and (app.my_context()->'user'->>'status') = 'active',
            'zero assignments: a valid state that opens nothing');
select t.as_service();
insert into public.slot_assignments (user_id, scope_id, stage_type) values (t.u('19'), t.scope('01'), 'qc');      -- Meera: still onboarding
select t.ok(not app.is_my_stage(t.u('19'), t.scope('01'), 'qc'), 'not yet joined: an assignment given ahead of the join date opens nothing yet');
select t.as_user(t.u('19'));
select t.ok((select count(*) from public.scopes) = 0 and jsonb_array_length(app.my_context()->'assignments') = 0 and (app.my_context()->'user'->>'status') = 'onboarding',
            'not yet joined: the joiner signs in and sees no scope');
select t.as_service();
update public.app_users set status = 'active' where id = t.u('19');
select t.ok(app.is_my_stage(t.u('19'), t.scope('01'), 'qc'), 'joined: the same assignment now counts');

update public.app_users set status = 'suspended' where id = t.u('05');
select t.ok(not app.is_my_stage(t.u('05'), t.scope('01'), 'procurement'), 'suspended: no stage counts');
select t.fails(format($q$ select t.procure_as(%L, %L, %L) $q$, t.scope('01'), t.farmer('02'), t.u('05')), 'may not create', 'suspended: nothing can be recorded in their name');
select t.as_user(t.u('05'));
select t.ok((select count(*) from public.scopes) = 0 and (app.my_context()->'user') = 'null'::jsonb, 'suspended: the login is recognised by nothing');
select t.as_service();
select t.ok((select count(*) from public.assignments where employee_id = t.u('05') and active) = 5, 'suspended: every assignment is kept');
update public.app_users set status = 'active' where id = t.u('05');
select t.ok(app.is_my_stage(t.u('05'), t.scope('01'), 'procurement'), 'reinstated: everything is back as it was');

update public.assignments set ends_on = app.today() - 1 where employee_id = t.u('05') and scope_id = t.scope('01');
select t.ok(not app.is_my_stage(t.u('05'), t.scope('01'), 'procurement') and app.is_my_stage(t.u('05'), t.scope('02'), 'procurement'),
            'lapsed: an assignment past its last day counts for nothing; the others still do');
select t.as_user(t.u('05'));
select t.ok((select count(*) from public.scopes where id = t.scope('01')) = 0 and (select count(*) from public.scopes) = 4, 'lapsed: the scope is gone from their list');
select t.as_service();
update public.assignments set ends_on = app.today() where employee_id = t.u('05') and scope_id = t.scope('01');
select t.ok(app.is_my_stage(t.u('05'), t.scope('01'), 'procurement'), 'lapsed: the last day itself still counts');

-- 7 · farmers: who issues a Farmer ID ---------------------------------------------------------------------------------------------
do $$
declare f uuid; assam uuid := (select state_id from public.scopes where id = pg_temp.f('sa'));
begin
  -- Migration 34: a farmer belongs to a state the client works in (Prasaadam: UP, and Assam through scope sa); step 1 is
  -- the Client Manager's, step 2 the State Manager OF THAT STATE, checking the location.
  perform t.as_user(t.u('05'));
  perform t.fails($q$ insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, status)
     values ('00000000-0000-4000-8000-000000000201', 'X', 'Y', 'Z', 'W', '+919812300009', 2, 'under_review') $q$,
     'added as a draft', 'farmers: nobody adds a farmer already "verified once": a farmer starts as a draft');
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, status, state_id)
  values ('00000000-0000-4000-8000-000000000201', 'Union Farmer', 'Father', 'Kokrajhar', 'Kokrajhar', '+919812300001', 2, 'draft',
          assam) returning id into f;
  perform t.ok((select state_id from public.farmers where id = f) = assam, 'farmers: the farmer is put in Assam, a state the client works in');
  perform t.fails(format('select app.submit_farmer(%L)', f), 'Client Manager of this client verifies', 'farmers: step 1 is not the operator''s');
  perform t.as_user(pg_temp.f('AS'));
  perform t.fails(format('select app.submit_farmer(%L)', f), 'Client Manager of this client verifies', 'farmers: nor the State Manager''s');
  perform t.as_user(t.u('03'));
  perform t.ok((app.submit_farmer(f)).reviewed_by = t.u('03'), 'farmers: the Client Manager verifies (step 1)');
  perform t.fails(format('select app.verify_farmer(%L)', f), 'State Manager', 'farmers: the client''s account cannot issue a Farmer ID');
  perform t.as_user(pg_temp.f('M'));
  perform t.ok((select count(*) from public.farmers where id = f) = 0, 'farmers: the other client''s manager does not see the farmer at all');
  perform t.as_user(t.u('02'));
  perform t.fails(format('select app.verify_farmer(%L)', f), 'State Manager of Assam', 'farmers: the State Manager of UP does not verify a farmer of Assam');
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.verify_farmer(%L)', f), 'not waiting', 'farmers: the admin verifies nobody (oversight)');
  perform t.as_user(pg_temp.f('AS'));
  perform t.ok((app.verify_farmer(f)).farmer_code is not null, 'farmers: the State Manager of the farmer''s state issues the Farmer ID (step 2)');
  perform t.as_service();
end $$;

-- 8 · the admin -----------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select t.ok((select count(*) from public.scopes) >= 11 and (select count(*) from public.app_users) >= 23
            and (select bool_and((s->>'whole')::boolean and not (s->>'manage')::boolean) from jsonb_array_elements(app.my_context()->'scopes') s)
            and jsonb_array_length(app.my_context()->'scopes') >= 11,
            'admin: sees every scope and every person, whole, and manages none (oversight, migration 34)');
select t.as_service();
select t.ok((select count(*) from app.verify_ledger()) = 0, 'the chain still verifies');

rollback;
