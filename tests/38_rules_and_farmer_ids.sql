-- Migration 44 (Veda, 14 Oct 2026, "Follow-up: State Manager, Client Manager, HR, scopes and farmer IDs", Release 4).
-- The five tests of her section A, as the people she used: 303 the Client Manager of PRSDM ("Lucky"), 302 the UP State
-- Manager ("Ram"), 301 the admin ("Veda"), 316 the HR Admin ("Minal"). Each check asks the database as that person would.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.farmer(p uuid) returns public.farmers language sql stable security definer as $$
  select * from public.farmers where id = p $$;
create or replace function pg_temp.sfcode(p uuid) returns text language sql stable security definer as $$
  select sf.code from public.farmers f join public.state_farmers sf on sf.id = f.state_farmer_id where f.id = p $$;
create or replace function pg_temp.last_block() returns jsonb language sql stable security definer as $$
  select payload || jsonb_build_object('_actor', actor) from public.ledger order by seq desc limit 1 $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and target = p_target $$;
create or replace function pg_temp.scope_status(p uuid) returns text language sql stable security definer as $$
  select status::text from public.scopes where id = p $$;

-- a draft scope of PRSDM in UP, and an Assam-based operator
do $$ declare sc uuid; v uuid; begin
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'RB27', 'Follow-up test', '{procurement,qc,qr_activation}', 'draft')
  returning id into sc;
  insert into fx values ('SC', sc);
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000e01', '00000000-0000-4000-8000-000000000e01', 'Assam Operator', 'op.assam4@example.com') returning id into v;
  insert into public.employee_org (employee_id, base_state_id) values (v, '00000000-0000-4000-8000-000000000002');
  insert into fx values ('AO', v);
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000e02', '00000000-0000-4000-8000-000000000e02', 'Nowhere Yet', 'op.nobase@example.com') returning id into v;
  insert into fx values ('NB', v);                                         -- no base location yet
end $$;

-- A · the five tests --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('01'), pg_temp.f('SC')), 'admin',
               'A test 1: Lucky puts Veda (Admin) on a stage: refused');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('16'), pg_temp.f('SC')), 'HR holds no',
               'A test 2: Lucky gives Minal (HR Admin) a scope assignment: refused');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('02'), pg_temp.f('SC')), 'a State Manager holds no stage',
               'A test 3: Lucky puts Ram (State Manager) on a stage: refused');
select t.fails(format($q$ update public.scopes set status = 'active' where id = %L $q$, pg_temp.f('SC')), 'every stage needs a person',
               'A test 4: Lucky activates a scope with empty stages: refused');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, t.u('05'), pg_temp.f('SC')), 'outside what you manage',
               'A test 5: Ram (State Manager) puts someone on a stage: refused');
select t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'qc') $q$, t.u('05'), pg_temp.f('SC')),
               'row-level security', 'A test 5: nor by writing the roster row himself');
select t.fails(format($q$ select app.roster_pool(%L) $q$, pg_temp.f('SC')), 'Client Manager of this scope', 'A1 the pool is not his to read');
do $$ begin
  perform t.ok(not (app.scope_roster(pg_temp.f('SC'))->>'can_manage')::boolean and jsonb_array_length(app.scope_roster(pg_temp.f('SC'))->'stages') = 3,
               'A1 Ram reads the scope''s roster but may not change it');
  perform t.ok(not exists (select 1 from jsonb_array_elements(app.my_context()->'scopes') s where (s->>'manage')::boolean)
               and exists (select 1 from jsonb_array_elements(app.my_context()->'scopes') s where s->>'scope_id' = pg_temp.f('SC')::text and (s->>'whole')::boolean),
               'A1 his scopes are whole to read and none his to manage (so no "A scope" on his Assign page)');
end $$;

-- A2 · the pool: operational people based in the scope's state, and the Client Manager himself --------------------------------
select t.as_user(t.u('03'));
do $$ declare p jsonb; ids text[]; begin
  p := app.roster_pool(pg_temp.f('SC'));
  select array_agg(x->>'id') into ids from jsonb_array_elements(p) x;
  perform t.ok(t.u('05')::text = any (ids) and t.u('18')::text = any (ids), 'A2 pool: operational people based in Uttar Pradesh');
  perform t.ok((p->0->>'id') = t.u('03')::text and (p->0->>'me')::boolean, 'A2 pool: the Client Manager himself, first');
  perform t.ok(not (t.u('01')::text = any (ids)) and not (t.u('16')::text = any (ids)) and not (t.u('17')::text = any (ids)) and not (t.u('02')::text = any (ids)),
               'A2 pool: never the admin, the HR Admin, HR or a State Manager');
  perform t.ok(not (pg_temp.f('AO')::text = any (ids)) and not (pg_temp.f('NB')::text = any (ids)),
               'A2 pool: nobody based in another state, nor anyone whose base is not set');
  perform t.ok(jsonb_array_length(app.roster_pool(pg_temp.f('SC'), 'ravi')) = 1, 'A2 pool: searched by name');
end $$;
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, pg_temp.f('AO'), pg_temp.f('SC')), 'not based in Uttar Pradesh',
               'A2 assign: not someone based in another state');
select t.fails(format($q$ select app.assign(%L, 'scope', %L, 'operator', '{qc}') $q$, pg_temp.f('NB'), pg_temp.f('SC')), 'not based in',
               'A2 assign: nor someone with no base location');

-- A3 · activation: a person on every stage, and a ready crop -----------------------------------------------------------------
do $$ declare m jsonb; begin
  m := app.activation_missing(pg_temp.f('SC'));
  perform t.ok(m->'stages' = '["procurement","qc","qr_activation"]'::jsonb and m->'crop' = '[]'::jsonb, 'A3 the missing list: every stage, a ready crop');
  perform app.assign(t.u('05'), 'scope', pg_temp.f('SC'), 'operator', '{procurement}');
  perform app.assign(t.u('03'), 'scope', pg_temp.f('SC'), 'operator', '{qc}');   -- Lucky takes QC himself (Veda: for small clients)
  perform t.ok(app.activation_missing(pg_temp.f('SC'))->'stages' = '["qr_activation"]'::jsonb, 'A3 the list shrinks as people are put on stages');
end $$;
select t.fails(format($q$ update public.scopes set status = 'active' where id = %L $q$, pg_temp.f('SC')), 'nobody yet at: QR Activation',
               'A3 one stage with nobody still refuses, and says which');
do $$ begin
  perform app.assign(t.u('18'), 'scope', pg_temp.f('SC'), 'operator', '{qr_activation}');
  update public.scopes set status = 'active' where id = pg_temp.f('SC');
  perform t.ok(pg_temp.scope_status(pg_temp.f('SC')) = 'active', 'A3 with every stage staffed and the crop ready, the scope is activated');
end $$;
select t.fails($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
   values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'RB27', 'Straight to active', '{procurement,qc,qr_activation}', 'active') $q$,
   'every stage needs a person', 'A3 nor is a scope created active');

-- A4 · the Client Manager's People & access ---------------------------------------------------------------------------------
do $$ declare r jsonb; begin
  r := app.people_page('{"limit":200}');
  perform t.ok(not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'system_role' <> 'operational'), 'A4 people: no admin, no HR');
  perform t.ok(not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' in (t.u('02')::text, pg_temp.f('AO')::text)),
               'A4 people: no State Manager, nobody of another state');
  perform t.ok(exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = t.u('18')::text and (x->>'assignable')::boolean)
               and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = t.u('03')::text and (x->>'assignable')::boolean),
               'A4 people: "Assign" is offered on his pool, not on himself');
end $$;
select t.fails(format('select app.employee_profile(%L)', t.u('16')), 'not found', 'A4 people: an HR profile does not open by its address');
select t.ok((select count(*) from public.app_users where id in (t.u('01'), t.u('02'), t.u('16'), t.u('17'), pg_temp.f('AO'))) = 0,
            'A4 people: nor are they read from the table');

-- K62 closed · the State Manager watches records; he does not act on them -------------------------------------------------------
select t.as_service();
do $$ declare p uuid; begin p := t.procure(t.scope('01'), t.farmer('01'), 50, 1, 1, 12, 12, 12); insert into fx values ('P1', p); end $$;
select t.as_user(t.u('02'));
select t.ok((select count(*) from public.footprints where id = pg_temp.f('P1')) = 1, 'K62 Ram reads a record of his state');
select t.fails(format($q$ select app.withdraw_footprint(%L, 'x') $q$, pg_temp.f('P1')), 'only a manager', 'K62 but does not withdraw it');
select t.fails(format($q$ select t.procure_as(%L, %L, %L) $q$, t.scope('01'), t.farmer('01'), t.u('02')), 'may not create at stage', 'K62 nor records at a stage');

-- E · two farmer IDs, the order, the history, changes with a reason ----------------------------------------------------------
select t.as_user(t.u('03'));
do $$ declare f uuid; begin
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000201', 'Ids Farmer', 'Father', 'Bansi', 'Siddharthnagar', '+919870004401', 2, 1, 27.200000, 83.000000) returning id into f;
  insert into fx values ('F1', f);
end $$;
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.verify_farmer(%L) $q$, pg_temp.f('F1')), 'not waiting', 'E2 Ram cannot verify before the Client Manager');
select t.as_user(t.u('03'));
do $$ declare r public.farmers; b jsonb; begin
  r := app.submit_farmer(pg_temp.f('F1'));
  b := pg_temp.last_block();
  perform t.ok(r.farmer_code ~ '^PRSDM-F-\d{4,}$' and r.state_farmer_id is null, 'E1 the Client Manager''s verification gives the client farmer ID');
  perform t.ok(b->>'kind' = 'farmer_verified_client' and b->>'farmer_code' = r.farmer_code and (b->>'_actor')::uuid = t.u('03'),
               'E2 and is a ledger block of its own, signed by him');
end $$;
select t.as_user(t.u('02'));
do $$ declare r public.farmers; b jsonb; h jsonb; begin
  r := app.verify_farmer(pg_temp.f('F1'));
  b := pg_temp.last_block();
  perform t.ok(pg_temp.sfcode(r.id) ~ '^F-UP-\d{5}$', 'E1 the State Manager''s verification gives the state farmer ID, F-UP-00000');
  perform t.ok(b->>'kind' = 'farmer_verified_state' and b->>'state_farmer_code' = pg_temp.sfcode(r.id) and not (b->>'linked')::boolean,
               'E2 a block of its own: the state ID, new');
  h := app.farmer_history(r.id);
  perform t.ok(h->>'farmer_code' = r.farmer_code and h->>'state_farmer_code' = pg_temp.sfcode(r.id)
               and h->'client_verified'->>'by' = 'Prasaadam Client Manager' and h->'state_verified' is not null
               and (select array_agg(e->>'kind' order by (e->>'seq')::bigint) from jsonb_array_elements(h->'events') e) = array['farmer_verified_client', 'farmer_verified_state']
               and (select array_agg(e->>'role' order by (e->>'seq')::bigint) from jsonb_array_elements(h->'events') e) = array['client_manager', 'state_manager'],
               'E3 the history: drafted, verified by the Client Manager, then the State Manager, each with the role he held');
end $$;
-- the same phone in the state: linked to the same state farmer, or (with a reason) another
select t.as_service();
do $$ declare a uuid; b uuid; begin
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, reviewed_by, reviewed_at, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000202', 'under_review', 'Ids Farmer', 'Father', 'Bansi', 'Siddharthnagar', '9870004401', 2, 1, t.u('03'), now(), 27.200000, 83.000000) returning id into a;
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, reviewed_by, reviewed_at, farmer_code, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000202', 'under_review', 'His Brother', 'Father', 'Bansi', 'Siddharthnagar', '+91 98700 04402', 2, 1, t.u('03'), now(), 'DEMOX-F-9001', 27.200000, 83.000000) returning id into b;
  insert into fx values ('F2', a), ('F3', b);
  update public.farmers set phone = '+919870004402' where id = b;
end $$;
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.verify_farmer(%L) $q$, pg_temp.f('F2')), 'same phone as F-UP-', 'E1 a second record with his phone waits for Ram''s choice');
select t.ok(jsonb_array_length(app.state_choice(pg_temp.f('F2'))) = 1 and app.state_choice(pg_temp.f('F2'))->0->>'code' = pg_temp.sfcode(pg_temp.f('F1')),
            'E1 he is shown that state farmer to link to');
do $$ declare r public.farmers; begin
  r := app.verify_farmer_state(pg_temp.f('F2'), (pg_temp.farmer(pg_temp.f('F1'))).state_farmer_id, null);
  perform t.ok(r.state_farmer_id = (pg_temp.farmer(pg_temp.f('F1'))).state_farmer_id and (pg_temp.last_block()->>'linked')::boolean,
               'E1 linked: one state farmer ID for both clients'' records');
end $$;
select t.as_service();
update public.farmers set phone = '+919870004401' where id = pg_temp.f('F3');   -- the brother's record has the same phone too
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.verify_farmer_state(%L, %L, null) $q$, pg_temp.f('F3'), gen_random_uuid()), 'no record with this phone',
               'E1 only a state farmer with this phone may be linked');
do $$ declare r public.farmers; begin
  r := app.verify_farmer_state(pg_temp.f('F3'), null, 'his brother: same family phone, own land');
  perform t.ok(r.state_farmer_id <> (pg_temp.farmer(pg_temp.f('F1'))).state_farmer_id and pg_temp.last_block()->>'reason' = 'his brother: same family phone, own land',
               'E1 "not the same person": his own state ID, the reason in the ledger');
end $$;
-- a farmer verified before migration 44 gets his state ID once, with a block that says so
select t.as_service();
do $$ declare b jsonb; begin
  update public.farmers set state_farmer_id = null where id = t.farmer('03');
  perform app.give_missing_state_ids('test');
  b := pg_temp.last_block();
  perform t.ok(pg_temp.sfcode(t.farmer('03')) is not null and b->>'kind' = 'state_farmer_id_given' and b->>'reason' = 'test',
               'E1 a farmer verified before: his state ID, given once, in the ledger');
end $$;

-- E4 · changes after verification ---------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails(format($q$ update public.farmers set name = 'Renamed' where id = %L $q$, pg_temp.f('F1')), 'say why', 'E4 Lucky changes a verified farmer only with a reason');
select t.fails(format($q$ select app.change_farmer(%L, '{"name":"Renamed"}', ' ') $q$, pg_temp.f('F1')), 'say why', 'E4 a blank reason is none');
do $$ declare r public.farmers; b jsonb; begin
  r := app.change_farmer(pg_temp.f('F1'), '{"gi_land_acres":"1.5","phone":"9870004499"}', 'measured again; new number');
  b := pg_temp.last_block();
  perform t.ok(r.gi_land_acres = 1.5 and b->>'kind' = 'farmer_changed' and b->>'reason' = 'measured again; new number'
               and (b->'after'->>'gi_land_acres')::numeric = 1.5 and b->'after'->>'phone' = 'changed' and position('9870004499' in b::text) = 0,
               'E4 with a reason: changed; the block has the reason and the GI land, not the number');
end $$;
select t.as_user(t.u('02'));
do $$ declare r jsonb; fl uuid; begin
  r := app.farmer_register('{"state":"00000000-0000-4000-8000-000000000001","flag":"changed"}');
  perform t.ok(exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'id' = pg_temp.f('F1')::text and (x->>'changes')::int = 2),
               'E4 GI land and mobile changed after verification are flagged on Ram''s register');
  perform t.ok((app.state_home('00000000-0000-4000-8000-000000000001')->'attention'->>'changes')::int >= 1, 'E4 and in "Needs my action"');
  perform t.ok(position('9870004499' in (app.farmer_history(pg_temp.f('F1'))->'open_changes')::text) = 0, 'E4 the mobile shows only its last digits');
  for fl in select (x->>'id')::uuid from jsonb_array_elements(app.farmer_history(pg_temp.f('F1'))->'open_changes') x loop
    perform app.accept_farmer_change(fl);
  end loop;
  perform t.ok(jsonb_array_length(app.farmer_history(pg_temp.f('F1'))->'open_changes') = 0 and pg_temp.audits('farmer_change_accepted', pg_temp.f('F1')) = 2,
               'E4 Ram accepts them; logged');
  perform app.change_farmer(pg_temp.f('F1'), '{"gi_land_acres":"1.2"}', 'my own correction');
  perform t.ok(jsonb_array_length(app.farmer_history(pg_temp.f('F1'))->'open_changes') = 0, 'E4 his own change needs no acceptance');
end $$;
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.accept_farmer_change(%L) $q$, gen_random_uuid()), 'State Manager', 'E4 the Client Manager accepts nothing');

-- D6 · the ledger shows the role each signer held ----------------------------------------------------------------------------
select t.as_user(t.u('02'));
do $$ declare r jsonb; begin
  r := app.state_ledger_page('00000000-0000-4000-8000-000000000001', null, null, null, null, 50, 0);
  perform t.ok(exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'actor' = t.u('03')::text and x->>'actor_working_role' = 'client_manager')
               and exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'actor' = t.u('02')::text and x->>'actor_working_role' = 'state_manager'),
               'D6 the ledger names the working role (Client Manager, State Manager), not "Operational"');
end $$;

-- G · HR -----------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('16'));
select t.fails($q$ select app.save_opening('{"state_id":"00000000-0000-4000-8000-000000000001","role":"state_manager","positions":10}') $q$,
               'one State Manager per state', 'G3 a State Manager opening has 1 position');
do $$ declare o jsonb; c jsonb; s jsonb; begin
  o := app.save_opening('{"state_id":"00000000-0000-4000-8000-000000000001","role":"state_manager","positions":1}');
  c := app.save_opening('{"state_id":"00000000-0000-4000-8000-000000000001","role":"operator","stage":"qc","positions":7}');
  perform app.set_opening_status((c->>'id')::uuid, 'closed');
  s := app.openings_summary('00000000-0000-4000-8000-000000000001');
  perform t.ok(o->>'id' is not null and (s->'total'->>'positions')::int = 1, 'G3 one position is fine; G5 the closed opening is left out of the totals');
end $$;
-- G7 · test data: marked, hidden, kept
select t.as_service();
do $$ declare v uuid; begin
  insert into public.app_users (display_name, email, status) values ('TEST Other', 'test.other@example.com', 'offboarded') returning id into v;
  insert into fx values ('TM', v);
end $$;
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.mark_test_person(%L, 'x') $q$, pg_temp.f('TM')), 'permission denied', 'G7 test data is marked by the database owner, not from a screen');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.mark_test_person(%L, 'x') $q$, pg_temp.f('TM')), 'permission denied', 'G7 not even the admin''s');
select t.as_service();
select t.fails(format($q$ select app.mark_test_person(%L, 'x') $q$, t.u('05')), 'only a person who has left', 'G7 only someone who has left');
do $$ begin
  perform app.mark_test_person(pg_temp.f('TM'), 'test data');
  perform t.ok(pg_temp.audits('marked_test_data', pg_temp.f('TM')) = 1, 'G7 marked; flagged in the Audit log');
end $$;
select t.as_user(t.u('01'));
select t.ok((select count(*) from public.app_users where id = pg_temp.f('TM')) = 1, 'G7 the record is kept (the admin still reads it)');
select t.as_user(t.u('16'));
select t.ok((select count(*) from public.app_users where id = pg_temp.f('TM')) = 0
            and not exists (select 1 from jsonb_array_elements(app.people_page('{"limit":200,"status":"offboarded"}')->'rows') x where x->>'id' = pg_temp.f('TM')::text)
            and not exists (select 1 from jsonb_array_elements(app.people_directory()) x where x->>'id' = pg_temp.f('TM')::text),
            'G7 hidden from HR''s lists');

-- 0 · the practice data of 14 Oct (the database owner's one-off) ----------------------------------------------------------------
select t.as_service();
do $$ declare c uuid; sc uuid; o uuid; r text; v uuid; begin
  insert into public.clients (name, code, state_id, type) values ('Test Client UP', 'TCUP', '00000000-0000-4000-8000-000000000001', 'exporter') returning id into c;
  insert into public.scopes (client_id, crop_id, season_code, geography, chain, status)
  values (c, '00000000-0000-4000-8000-000000000101', 'KH26', 'gkp', '{procurement,qc,qr_activation}', 'active') returning id into sc;
  insert into fx values ('TS', sc);
  update public.openings set positions = 10 where code = 'UP-SM-001' returning id into o;   -- as it was made before the rule (G3 above made it)
  if o is null then
    insert into public.openings (code, state_id, role, positions, status, title) values ('UP-SM-001', '00000000-0000-4000-8000-000000000001', 'state_manager', 10, 'open', 'SM')
    returning id into o;
  end if;
  insert into public.app_users (display_name, email, status) values ('TEST Mine', 'test.mine@example.com', 'offboarded') returning id into v;
  insert into fx values ('TM2', v);
  r := app.practice_fix_14oct();
  perform t.ok(r like '%back to draft%' and r like '%10 -> 1 position%' and r like '%marked as test data%', 'section 0: the three corrections: ' || r);
  perform t.ok((select status = 'draft' and activated_at is null from public.scopes where id = sc), 'section 0: the scope is a draft again');
  perform t.ok((select payload->>'act' = 'activation_reversed' and payload->>'reason' like 'Activation reversed: activated in a test with no staff%'
                  from public.ledger where scope_id = sc order by seq desc limit 1)
               and (select count(*) from public.ledger where scope_id = sc and event = 'scope_activate') = 1,
               'section 0: a correcting block that says why; the activation block stays');
  perform t.ok((select positions from public.openings where id = o) = 1 and (select test_data from public.app_users where id = v), 'section 0: UP-SM-001 has 1 position; TEST Mine is test data');
  r := app.practice_fix_14oct();
  perform t.ok(r like '%draft already%' and r like '%1 position already%' and r like '%marked already%', 'section 0: a second run changes nothing');
  insert into public.app_meta (key, value) values ('environment', 'production') on conflict (key) do update set value = 'production';
end $$;
select t.fails($q$ select app.practice_fix_14oct() $q$, 'not on the production system', 'section 0: never on production');
select t.as_user(t.u('03'));
select t.fails($q$ select app.practice_fix_14oct() $q$, 'permission denied', 'section 0: and nobody signed in may run it');

select t.as_service();
select t.ok(not exists (select 1 from app.verify_ledger()), 'the ledger chain verifies');
rollback;
