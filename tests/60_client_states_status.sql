-- Migration 65 (Phase 2, release 2 of Veda's combined brief of 19 Oct 2026: Part C and Part D).
--   1  C: the Uttarakhand State Manager types ABC Exim's PAN ("Already registered", "Add Uttarakhand"), adds his state;
--      the UP State Manager, the client's owner and the admin are told, he is not; he sees nothing of UP (no GSTIN,
--      contact, scope); the national items are reused "on file"; his state runs through its own gates (a UP GSTIN refused
--      for it) and goes Active on his KYC tick (the admin approved the first Active already); he may give the client a
--      Client Manager; the owner sees both states' scopes in one portfolio, each State Manager his own
--   2  D: suspended in UP: no new procurement, the work in progress finishes to Packing, no sale and no release; the
--      released page stays live and says "Verification paused"; a status the admin set is moved back by the admin
--   3  D: ended: every record of the client's scopes there reads only; "Verification ended on …"; the page stays live for
--      the longer of best-before + 12 months and 24 months after the end, then says it is no longer live; the return
--      goes through Gate 3 again; every change has its reason and is logged
--   4  D: the warnings: an FSSAI licence 60 days ahead (not 61), the RCMC 15 days, an MSA after expiry; to whom
--   5  B5: the client's own login uploads a renewal; its State Manager accepts it (the expiry moves) or declines it
--   6  closed: the tables, the internal functions; the notifications are one's own
-- Fake, format-valid numbers only (ZZZ…).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.upload(p_client uuid) returns text language plpgsql security definer as $$
declare v text := p_client::text || '/' || gen_random_uuid()::text || '.pdf';
begin
  if to_regclass('storage.objects') is not null then
    execute 'insert into storage.objects (bucket_id, name) values ($1, $2)' using 'client-docs', v;
  end if;
  return v;
end $$;
create or replace function pg_temp.doc(p_client uuid, p_state uuid, p_kind public.client_doc_kind, p_meta jsonb default '{}') returns jsonb language plpgsql as $$
begin
  return app.add_client_document(p_client, p_state, p_kind, pg_temp.upload(p_client), repeat('a', 64), 1234, p_kind::text || '.pdf', p_meta);
end $$;
create or replace function pg_temp.st(p_client uuid, p_state uuid) returns jsonb language sql stable as $$
  select s from jsonb_array_elements(app.client_view(p_client) -> 'states') s where (s ->> 'state_id')::uuid = p_state $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
create or replace function pg_temp.nots(p_user uuid, p_kind text) returns int language sql stable security definer as $$
  select count(*)::int from public.notifications where user_id = p_user and kind = p_kind $$;
-- app.may_assign is the server's (no grant): asked as the person, the way the assignment functions ask it
create or replace function pg_temp.may_cm(p uuid) returns boolean language sql stable security definer as $$ select app.may_assign('client', 'client_account', p) $$;
create or replace function pg_temp.cstates() returns setof public.client_states language sql stable security definer as $$ select * from public.client_states $$;
create or replace function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

do $$ declare v uuid; uk uuid;
begin
  insert into public.states (name, code) values ('Uttarakhand', 'UK') returning id into uk;
  update public.states set gst_code = '05' where id = uk;
  insert into fx values ('UK', uk), ('UP', '00000000-0000-4000-8000-000000000001'), ('AS', '00000000-0000-4000-8000-000000000002');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c11', '00000000-0000-4000-8000-000000000c11', 'Assam State Manager', 'sm.assam65@example.com') returning id into v;
  insert into fx values ('SMA', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', '00000000-0000-4000-8000-000000000002');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c12', '00000000-0000-4000-8000-000000000c12', 'Uttarakhand State Manager', 'sm.uk65@example.com') returning id into v;
  insert into fx values ('SMK', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', uk);
end $$;

-- 0 · ABC Exim, Active in Uttar Pradesh (Ram, the gates, the admin's approval), with its own login -------------------------
select t.as_user(t.u('02'));
insert into fx select 'ABC', (app.create_client('{"pan":"ZZZCZ0001Z","entity_type":"company","legal_name":"ABC Exim Ltd","state_id":"00000000-0000-4000-8000-000000000001",
  "contact":{"name":"A. Kumar","designation":"Director","phone":"9000000001","email":"a@abcexim.test"},
  "crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') ->> 'client_id')::uuid;
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"gstin":"09ZZZCZ0001Z1Z5","reg_office":{"address":"12 Civil Lines","city":"Gorakhpur","state":"Uttar Pradesh"},
  "reg_number":"U01100UP2025PTC123456","signatory":{"name":"A. Kumar","designation":"Director"},
  "state_contact":{"name":"UP desk","designation":"Manager","phone":"9000000011","email":"up@abcexim.test"}}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'diagnostic_order', '{"signed_on":"2026-10-20","amount":50000}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'incorporation');
select app.client_move(pg_temp.f('ABC'), pg_temp.f('UP'), 'diagnostic');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"billing":{"contact":"Accounts","email":"accounts@abcexim.test"}}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'msa', format('{"signed_on":"2026-10-20","term_end":"%s"}', pg_temp.today() + 1000)::jsonb);
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'consent_addendum', '{"signed_on":"2026-10-20"}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'signatory_authority');
select app.client_kyc(pg_temp.f('ABC'), pg_temp.f('UP'));
select app.client_move(pg_temp.f('ABC'), pg_temp.f('UP'), 'active');
select t.as_user(t.u('01'));
select app.decide_client_activation(pg_temp.f('ABC'), pg_temp.f('UP'), true);
select t.as_service();
do $$ declare v uuid; begin
  insert into public.app_users (id, auth_uid, display_name, email, external) values
    ('00000000-0000-4000-8000-000000000c13', '00000000-0000-4000-8000-000000000c13', 'ABC Exim (login)', 'owner.abc65@example.com', true) returning id into v;
  insert into fx values ('OWN', v);
  insert into public.assignments (employee_id, lens, op_role, client_id) values (v, 'client', 'client_viewer', pg_temp.f('ABC'));
end $$;
select t.ok((select status = 'active' from public.client_states where client_id = pg_temp.f('ABC') and state_id = pg_temp.f('UP')), '0: ABC Exim is Active in Uttar Pradesh');

-- 1 · Part C: Uttarakhand added --------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('SMK'));
select t.ok(app.lookup_pan('ZZZCZ0001Z') ->> 'situation' = 'client'
            and app.lookup_pan('ZZZCZ0001Z') -> 'add_states' = jsonb_build_array(jsonb_build_object('id', pg_temp.f('UK'), 'name', 'Uttarakhand')),
            'C1: "Already registered with GrainVeda" and one action: "Add Uttarakhand to this client"');
select t.ok((app.client_view(pg_temp.f('ABC')) #>> '{may,add_states,0,name}') = 'Uttarakhand', 'C1: the same from the shared record');
select t.fails(format($q$ select app.add_client_state(%L, '00000000-0000-4000-8000-000000000001') $q$, pg_temp.f('ABC')),
               'by that state''s State Manager', 'C1: he adds his own state only');
select app.add_client_state(pg_temp.f('ABC'), pg_temp.f('UK'));
select t.ok((pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UK')) ->> 'status') = 'prospect' and (pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UK')) ->> 'mine')::boolean,
            'C1: Uttarakhand added: a Prospect there, his to fill');
select t.ok((select code from public.clients where id = pg_temp.f('ABC')) = (app.client_view(pg_temp.f('ABC')) #>> '{identity,code}')
            and (select pg_temp.f('UK') = any (states_of_interest) from public.clients where id = pg_temp.f('ABC')),
            'C1: one record: the same client code; Uttarakhand among its states');
select t.fails(format($q$ select app.add_client_state(%L, %L) $q$, pg_temp.f('ABC'), pg_temp.f('UK')), 'already in this state', 'C1: not twice');
select t.ok(jsonb_array_length(app.client_view(pg_temp.f('ABC')) -> 'states') = 1 and pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UP')) is null
            and position('09ZZZCZ0001Z1Z5' in app.client_view(pg_temp.f('ABC'))::text) = 0
            and position('up@abcexim.test' in app.client_view(pg_temp.f('ABC'))::text) = 0,
            'C1: he sees nothing of Uttar Pradesh: not its GSTIN, its address or contacts');
select t.ok((select bool_and(d ->> 'path' is null) and count(*) = 4 from jsonb_array_elements(app.client_view(pg_temp.f('ABC')) #> '{national,documents}') d),
            'C1: the national documents are reused and show "on file" (not the file itself)');
select t.fails(format($q$ select pg_temp.doc(%L, %L, 'msa', '{"signed_on":"2026-10-20","term_end":"2029-10-19"}') $q$, pg_temp.f('ABC'), pg_temp.f('UK')),
               'home state', 'C1: nor replaces them (the home state''s State Manager keeps them)');
select t.as_service();
select t.ok(pg_temp.nots(t.u('02'), 'client_state_added') = 1 and pg_temp.nots(t.u('01'), 'client_state_added') = 1
            and pg_temp.nots(pg_temp.f('OWN'), 'client_state_added') = 1 and pg_temp.nots(pg_temp.f('SMK'), 'client_state_added') = 0
            and pg_temp.nots(pg_temp.f('SMA'), 'client_state_added') = 0,
            'C1: told: the UP State Manager, the admin, the client''s owner; not he who added it, not another state');
select t.as_user(t.u('02'));
select t.ok((select n ->> 'kind' = 'client_state_added' and n #>> '{data,state}' = 'Uttarakhand' and n #>> '{data,by}' = 'Uttarakhand State Manager'
               and n #>> '{data,client}' = 'ABC Exim Ltd' and not (n ->> 'read')::boolean
               from jsonb_array_elements(app.my_notifications()) n where n ->> 'kind' = 'client_state_added'),
            'C1: "ABC Exim added in Uttarakhand by Uttarakhand State Manager"');
select t.ok(app.read_notifications(array(select (n ->> 'id')::uuid from jsonb_array_elements(app.my_notifications()) n)) >= 1, 'C1: marked read');
select t.ok((select bool_and((n ->> 'read')::boolean) from jsonb_array_elements(app.my_notifications()) n), 'C1: and read they stay');
select t.ok(pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UK')) is null and (pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UP')) ->> 'status') = 'active'
            and (app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 ->> 'state') = 'Uttar Pradesh' and jsonb_array_length(app.client_view(pg_temp.f('ABC')) -> 'states') = 1,
            'C1: Ram''s UP is untouched; he reads his own state only');

-- Uttarakhand through its gates: its GSTIN starts with 05 and carries the PAN; Active on the KYC tick (no second approval)
select t.as_user(pg_temp.f('SMK'));
select t.fails(format($q$ select app.save_client_details(%L, %L, '{"gstin":"09ZZZCZ0001Z1Z5"}') $q$, pg_temp.f('ABC'), pg_temp.f('UK')),
               'which is not Uttarakhand (05)', 'C2: a UP GSTIN entered for Uttarakhand is refused');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UK'), '{"gstin":"05ZZZCZ0001Z1Z5","signatory":{"name":"A. Kumar","designation":"Director"},
  "address":{"address":"Rajpur Road","city":"Dehradun"},"state_contact":{"name":"UK desk","designation":"Manager","phone":"9000000012","email":"uk@abcexim.test"},
  "billing":{"contact":"Accounts UK","email":"uk.accounts@abcexim.test"}}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UK'), 'diagnostic_order', '{"signed_on":"2026-10-21","amount":30000}');
select app.client_move(pg_temp.f('ABC'), pg_temp.f('UK'), 'diagnostic');
select app.client_kyc(pg_temp.f('ABC'), pg_temp.f('UK'));
select t.ok(coalesce((app.client_move(pg_temp.f('ABC'), pg_temp.f('UK'), 'active') ->> 'awaiting_approval')::boolean, false) = false, 'C2: no second approval asked');
select t.ok((pg_temp.st(pg_temp.f('ABC'), pg_temp.f('UK')) ->> 'status') = 'active', 'C2: Uttarakhand Active on his KYC tick (the national items reused)');
select t.as_user(t.u('02'));
select t.ok(position('uk@abcexim.test' in app.client_view(pg_temp.f('ABC'))::text) = 0 and position('05ZZZCZ0001Z1Z5' in app.client_view(pg_temp.f('ABC'))::text) = 0,
            'C2: and Ram reads nothing of Uttarakhand''s GSTIN or contacts');
select t.as_user(pg_temp.f('SMK'));
select t.ok(pg_temp.may_cm(pg_temp.f('ABC')), 'C3: he may give the client a Client Manager, as today');
select t.as_user(pg_temp.f('SMA'));
select t.ok(not pg_temp.may_cm(pg_temp.f('ABC')), 'C3: a State Manager of a state the client is not in may not');
select t.fails(format($q$ select app.add_client_state(%L, %L) $q$, pg_temp.f('ABC'), pg_temp.f('UK')), 'by that state''s State Manager', 'C3: nor adds another''s state');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.add_client_state(%L, %L) $q$, pg_temp.f('ABC'), pg_temp.f('UK')), 'by that state''s State Manager', 'C3: the admin adds no state');

-- one portfolio: a scope in each state; the owner reads both, each State Manager his own
select t.as_service();
do $$ begin
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c14', '00000000-0000-4000-8000-000000000c14', 'ABC Client Manager', 'cm.abc65@example.com');
  insert into fx values ('CMA', '00000000-0000-4000-8000-000000000c14');
  insert into public.assignments (employee_id, lens, op_role, client_id) values ('00000000-0000-4000-8000-000000000c14', 'client', 'client_account', pg_temp.f('ABC'));
  insert into public.scopes (client_id, state_id, crop_id, season_code, geography, chain, status, market_codes)
  values (pg_temp.f('ABC'), pg_temp.f('UP'), '00000000-0000-4000-8000-000000000101', 'KH26', 'Basti', '{procurement,qc,qr_activation}', 'draft', '{domestic}'),
         (pg_temp.f('ABC'), pg_temp.f('UK'), '00000000-0000-4000-8000-000000000101', 'KH26', 'Dehradun', '{procurement,qc,qr_activation}', 'draft', '{domestic}');
end $$;
select t.as_user(pg_temp.f('OWN'));
select t.ok((select count(*) from public.scopes where client_id = pg_temp.f('ABC')) = 2, 'C4: the client''s owner sees both states'' scopes in one portfolio');
select t.as_user(pg_temp.f('SMK'));
select t.ok((select array_agg(geography) from public.scopes where client_id = pg_temp.f('ABC')) = array['Dehradun'], 'C4: the Uttarakhand State Manager: his own only');
select t.as_user(t.u('02'));
select t.ok((select array_agg(geography) from public.scopes where client_id = pg_temp.f('ABC')) = array['Basti'], 'C4: the UP State Manager: his own only');
select t.as_user(pg_temp.f('CMA'));
select t.ok((select array_agg(x ->> 'name' order by x ->> 'name') from jsonb_array_elements(app.client_scope_states(pg_temp.f('ABC'))) x) = array['Uttar Pradesh', 'Uttarakhand'],
            'C4: the Client Manager may make a scope in either state (the scope''s form)');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.client_scope_states(%L) $q$, pg_temp.f('ABC')), 'not found', 'C4: another client''s Client Manager: nothing');

-- 2 · Part D: suspended (client 201 in UP; scope 01 and scope 05) ---------------------------------------------------------------
select t.as_service();
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-6521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id)
insert into fx select 'SKU1', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id)
insert into fx select 'BUY', id from r;
-- client 201 is in Assam too (its scope 07 there), Active as a kept test client
insert into public.client_states (client_id, state_id, status, legacy) values ('00000000-0000-4000-8000-000000000201', pg_temp.f('AS'), 'active', true)
on conflict (client_id, state_id) do nothing;
-- scope 01: one lot sealed (released) before; one lot at its QR step, not yet sealed
insert into fx select 'P1', t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
select t.verify(pg_temp.f('P1'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q1', pg_temp.ins(t.scope('01'), 'qc', pg_temp.f('P1'), t.u('06'), '{"qty_kg":98,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service(); select t.attach(pg_temp.f('Q1'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q1'));
insert into fx select 'R1', pg_temp.ins(t.scope('01'), 'qr_activation', pg_temp.f('Q1'), t.u('07'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_service();
insert into fx select 'P2', t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
select t.verify(pg_temp.f('P2'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q2', pg_temp.ins(t.scope('01'), 'qc', pg_temp.f('P2'), t.u('06'), '{"qty_kg":98,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service(); select t.attach(pg_temp.f('Q2'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q2'));
insert into fx select 'R2', pg_temp.ins(t.scope('01'), 'qr_activation', pg_temp.f('Q2'), t.u('07'), '{}');
-- scope 05: a lot milled, waiting to be packed
select t.as_service();
insert into fx select 'P5', t.procure(t.scope('05'), t.farmer('01'), 132, 2, 1, 11.8, 11.7, 11.9);
select t.verify(pg_temp.f('P5'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q5', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P5'), t.u('06'), jsonb_build_object('qty_kg', 130, 'sample_qty_kg', 1,
  'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2), 'lab_id', pg_temp.f('LAB'),
  'report_no', 'GGL/2026/65', 'report_date', pg_temp.today()::text, 'sample_id', 'S-65'));
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q5'));
insert into fx select 'M5', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q5'), t.u('08'), '{"input_kg":129,"head_rice_kg":80,"broken_kg":10,"husk_kg":30,"bran_kg":6}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M5'));

select t.as_user(t.u('02'));                                          -- Ram suspends client 201 in UP
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'suspended', 'pay') $q$,
               'a reason of 10 characters', 'D1: a reason is needed');
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'suspended', 'payment overdue 90 days') $q$,
               'by the admin', 'D1: every state at once is the admin''s');
select app.client_set_status('00000000-0000-4000-8000-000000000201', pg_temp.f('UP'), 'suspended', 'payment overdue 90 days');
select t.ok((pg_temp.st('00000000-0000-4000-8000-000000000201', pg_temp.f('UP')) ->> 'status') = 'suspended', 'D1: suspended in Uttar Pradesh');
select t.as_service();
select t.fails($q$ select t.procure_as(t.scope('01'), t.farmer('01'), t.u('05')) $q$, 'no new procurement', 'D1: no new procurement there');
select t.as_user(t.u('09'));
insert into fx select 'K5', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M5'), t.u('09'),
  format('{"input_kg":30,"packets":[{"sku_id":"%s","units":30,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.ok(pg_temp.f('K5') is not null and exists (select 1 from public.packs where footprint_id = pg_temp.f('K5')),
            'D1: the work in progress finishes to Packing (its packs are made)');
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K5'));
select t.ok((select status = 'verified' from public.footprints where id = pg_temp.f('K5')), 'D1: and is verified by the next stage');
select t.fails(format($q$ select pg_temp.ins(t.scope('05'), 'commercial', %L, t.u('11'), '{"buyer_id":"%s","market":"domestic","order_no":"PO-65","packs":[{"sku_id":"%s","units":5}]}') $q$,
                      pg_temp.f('K5'), pg_temp.f('BUY'), pg_temp.f('SKU1')), 'no sale, shipment or release', 'D1: no sale');
select t.as_user(t.u('07'));
select t.fails(format($q$ select app.seal_lot(%L) $q$, pg_temp.f('R2')), 'no sale, shipment or release', 'D1: no new release');
select t.as_anon();
create temp table pj as select app.public_lot_journey((select code from seal)) as j;
select t.ok((select j ? 'journey' and j -> 'verification' = '{"status": "paused"}'::jsonb from pj),
            'D1: the page already released stays live and says "Verification paused"');
select t.as_service();
select t.ok(pg_temp.nots(t.u('04'), 'client_suspended') = 1 and pg_temp.nots(t.u('01'), 'client_suspended') = 1 and pg_temp.nots(t.u('02'), 'client_suspended') = 0
            and (select data ? 'reason' from public.notifications where user_id = t.u('01') and kind = 'client_suspended')
            and (select not (data ? 'reason') from public.notifications where user_id = t.u('04') and kind = 'client_suspended'),
            'D1: told: the client''s login (without GrainVeda''s reason) and the admin');

-- the admin's national suspension; a status the admin set is moved back by the admin
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'suspended', 'licence under review nationally');
select t.ok((select bool_and(status = 'suspended') from pg_temp.cstates() where client_id = '00000000-0000-4000-8000-000000000201')
            and (app.client_identity('00000000-0000-4000-8000-000000000201') ->> 'status') = 'suspended',
            'D2: nationally: every state suspended; the overall status says so');
select t.as_user(pg_temp.f('SMA'));
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'active', 'licence renewed in Assam') $q$,
               'the admin moves it back', 'D2: the Assam State Manager cannot resume what the admin suspended');
select t.as_user(t.u('02'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', pg_temp.f('UP'), 'active', 'payment received in full');
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'active', 'licence review closed');
select t.ok((select bool_and(status = 'active') from pg_temp.cstates() where client_id = '00000000-0000-4000-8000-000000000201'), 'D2: resumed everywhere');
select t.as_user(t.u('07'));
select t.ok((app.seal_lot(pg_temp.f('R2'))).qr_code is not null, 'D2: resumed: the lot is released');

-- 3 · Part D: ended -------------------------------------------------------------------------------------------------------------
select t.as_service();
update public.packs set best_before = pg_temp.today() + 30 where footprint_id = pg_temp.f('K5');
update public.client_states set kyc_at = now() where client_id = '00000000-0000-4000-8000-000000000201';   -- its KYC ticked (the return undoes it)
create temp table pk as select serial from public.packs where footprint_id = pg_temp.f('K5') order by serial limit 1;
grant select on pk to anon, authenticated;
select t.as_user(t.u('02'));
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'diagnostic', 'come back please') $q$,
               'cannot be returned', 'D3: only an ended client returns');
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'ended', 'contract over at the end of the season');
select t.ok((select bool_and(status = 'ended' and ended_on = pg_temp.today()) from pg_temp.cstates() where client_id = '00000000-0000-4000-8000-000000000201'),
            'D3: ended in every state, on today''s date');
select t.as_service();
select t.fails($q$ select t.procure_as(t.scope('01'), t.farmer('01'), t.u('05')) $q$, 'contract has ended', 'D3: no new record');
select t.as_user(t.u('11'));
select t.fails(format($q$ update public.footprints set payload = payload || '{"note":"x"}' where id = %L $q$, pg_temp.f('K5')), 'contract has ended', 'D3: the records read only');
select t.as_user(t.u('03'));
select t.fails($q$ update public.scopes set geography = geography || ' (edited)' where id = '00000000-0000-4000-8000-000000000407' $q$, 'contract has ended', 'D3: the scopes read only');
select t.as_anon();
select t.ok((select app.public_lot_journey(code) -> 'verification' from seal)
            = jsonb_build_object('status', 'ended', 'ended_on', pg_temp.today(), 'live_until', (pg_temp.today() + interval '24 months')::date),
            'D3: "Verification ended on …"; live until 24 months after the end');
select t.as_service();
update public.client_states set ended_on = date '2023-01-01' where client_id = '00000000-0000-4000-8000-000000000201';
select t.as_anon();
select t.ok((select (j ->> 'expired')::boolean and not (j ? 'journey') and j #>> '{verification,ended_on}' = '2023-01-01' and j #>> '{crop,name}' is not null
               from (select app.public_lot_journey(code) as j from seal) x),
            'D3: 24 months after the end, and no best-before keeps it: the page is no longer live (nothing of the lot)');
select t.ok((select not coalesce((j ->> 'expired')::boolean, false) and j #>> '{verification,live_until}' = ((pg_temp.today() + 30 + interval '12 months')::date)::text
               from (select app.public_pack(serial) as j from pk) x),
            'D3: a pack whose best-before + 12 months is later stays live till then');
select t.as_user(t.u('02'));
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'diagnostic', 'new contract signed') $q$,
               'the admin moves it back', 'D3: what the admin ended, the admin returns');
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', pg_temp.f('UP'), 'diagnostic', 'new contract signed for 2027');
select t.ok((select status = 'diagnostic' and ended_on is null and kyc_at is null from pg_temp.cstates()
              where client_id = '00000000-0000-4000-8000-000000000201' and state_id = pg_temp.f('UP')),
            'D3: returned: Diagnostic, the same record; Gate 3 and the KYC tick again');
select t.as_service();
select t.ok((select array_agg(act order by id) from public.client_status_events where client_id = '00000000-0000-4000-8000-000000000201' and state_id = pg_temp.f('UP')
              and act in ('suspended', 'resumed', 'ended', 'returned')) = array['suspended', 'resumed', 'ended', 'returned']   -- the admin's national moves left UP as it was (already suspended, already resumed)
            and (select bool_and(length(reason) >= 10) from public.client_status_events where client_id = '00000000-0000-4000-8000-000000000201'
                   and act in ('suspended', 'resumed', 'ended', 'returned'))
            and (select count(*) from public.audit_log where action = 'client_status' and target = '00000000-0000-4000-8000-000000000201') = 6,
            'D3: every change with its reason, in the client''s history and the Audit log');

-- 4 · the warnings ------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('02'));
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), format('{"fssai":{"number":"10026999000001","expires_on":"%s"}}', pg_temp.today() + 61)::jsonb);
select t.ok(not exists (select 1 from jsonb_array_elements(app.client_expiries()) x where x ->> 'kind' = 'fssai' and (x ->> 'client_id')::uuid = pg_temp.f('ABC')),
            'D4: an FSSAI licence 61 days ahead: no warning yet');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), format('{"fssai":{"number":"10026999000001","expires_on":"%s"},"rcmc":{"number":"RCMC/APEDA/0001","expires_on":"%s"}}',
  pg_temp.today() + 60, pg_temp.today() + 10)::jsonb);
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'msa', format('{"signed_on":"2023-10-20","term_end":"%s"}', pg_temp.today() - 1)::jsonb);
create temp table ex as select x from jsonb_array_elements(app.client_expiries()) x where (x ->> 'client_id')::uuid = pg_temp.f('ABC');
grant select on ex to authenticated;
select t.ok((select x ->> 'level' = 'd60' and (x ->> 'days_left')::int = 60 and x ->> 'state' = 'Uttar Pradesh' from ex where x ->> 'kind' = 'fssai'),
            'D4: an FSSAI licence 60 days ahead warns the State Manager');
select t.ok((select x ->> 'level' = 'd15' from ex where x ->> 'kind' = 'rcmc') and (select x ->> 'level' = 'expired' from ex where x ->> 'kind' = 'msa'),
            'D4: the RCMC 10 days ahead (the 15-day warning); the MSA after its expiry');
select t.ok((select status = 'active' from pg_temp.cstates() where client_id = pg_temp.f('ABC') and state_id = pg_temp.f('UP')), 'D4: a warning, never an automatic suspension');
select t.as_user(pg_temp.f('SMK'));
select t.ok((select array_agg(x ->> 'kind' order by x ->> 'kind') from jsonb_array_elements(app.client_expiries()) x where (x ->> 'client_id')::uuid = pg_temp.f('ABC'))
            = array['msa', 'rcmc'], 'D4: the Uttarakhand State Manager: the national ones, not UP''s licence');
select t.as_user(pg_temp.f('SMA'));
select t.ok(not exists (select 1 from jsonb_array_elements(app.client_expiries()) x where (x ->> 'client_id')::uuid = pg_temp.f('ABC')), 'D4: another state''s: nothing of it');
select t.as_user(pg_temp.f('CMA'));
select t.ok(app.client_expiries() = '[]'::jsonb, 'D4: the Client Manager: none (the State Manager renews)');
select t.as_user(t.u('01'));
select t.ok((select count(*) from jsonb_array_elements(app.client_expiries()) x where (x ->> 'client_id')::uuid = pg_temp.f('ABC')) = 3, 'D4: the admin: all three');

-- 5 · B5: the client's own login uploads a renewal; its State Manager accepts it ---------------------------------------------------
select t.as_user(pg_temp.f('OWN'));
select t.ok(app.may_write_client_object(pg_temp.f('ABC')::text || '/' || gen_random_uuid()::text || '.pdf'), 'B5: the client''s login may upload to its folder');
insert into fx select 'RN1', (app.propose_client_renewal(pg_temp.f('ABC'), pg_temp.f('UP'), 'fssai', pg_temp.upload(pg_temp.f('ABC')), repeat('b', 64), 2000, 'fssai-2027.pdf',
  format('{"expires_on":"%s"}', pg_temp.today() + 400)::jsonb) ->> 'id')::uuid;
insert into fx select 'RN2', (app.propose_client_renewal(pg_temp.f('ABC'), null, 'msa', pg_temp.upload(pg_temp.f('ABC')), repeat('c', 64), 3000, 'msa-2026.pdf',
  format('{"signed_on":"%s","term_end":"%s"}', pg_temp.today(), pg_temp.today() + 1095)::jsonb) ->> 'id')::uuid;
select t.fails(format($q$ select app.decide_client_renewal(%L, true) $q$, pg_temp.f('RN1')), 'State Manager', 'B5: the login does not accept its own upload');
select t.as_user(pg_temp.f('CMA'));
select t.fails(format($q$ select app.propose_client_renewal(%L, null, 'msa', 'x', repeat('c', 64), 1, null, '{}') $q$, pg_temp.f('ABC')), 'own login', 'B5: nobody else uploads one');
select t.as_user(pg_temp.f('SMK'));
select t.ok((select array_agg(x ->> 'kind') from jsonb_array_elements(app.client_renewals(pg_temp.f('ABC'))) x) = array['msa']
            and not (app.client_renewals(pg_temp.f('ABC')) -> 0 ->> 'may_decide')::boolean,
            'B5: the Uttarakhand State Manager sees the MSA renewal (not UP''s licence), and does not decide it');
select t.fails(format($q$ select app.decide_client_renewal(%L, true) $q$, pg_temp.f('RN2')), 'home state', 'B5: the MSA is the home state''s');
select t.as_user(t.u('02'));
select t.ok((select bool_and((x ->> 'may_decide')::boolean) and count(*) = 2 from jsonb_array_elements(app.client_renewals(pg_temp.f('ABC'))) x),
            'B5: the UP State Manager decides both');
select t.fails(format($q$ select app.decide_client_renewal(%L, false, 'blurry') $q$, pg_temp.f('RN2')), 'a reason of 10', 'B5: declining needs a reason');
select app.decide_client_renewal(pg_temp.f('RN1'), true);
select app.decide_client_renewal(pg_temp.f('RN2'), false, 'the scan is not signed on every page');
select t.ok(not exists (select 1 from jsonb_array_elements(app.client_expiries()) x where x ->> 'kind' = 'fssai' and (x ->> 'client_id')::uuid = pg_temp.f('ABC'))
            and exists (select 1 from jsonb_array_elements(app.client_expiries()) x where x ->> 'kind' = 'msa' and (x ->> 'client_id')::uuid = pg_temp.f('ABC')),
            'B5: accepted: the licence''s expiry moves and its warning goes; the declined MSA still warns');
select t.as_service();
select t.ok((select e.expires_on = pg_temp.today() + 400 and e.value = '10026999000001' from public.entity_ids e join public.clients c on c.entity_id = e.entity_id
              where c.id = pg_temp.f('ABC') and e.kind = 'fssai' and e.current)
            and (select d.path = r.path from public.client_documents d join public.client_renewals r on r.document_id = d.id where r.id = pg_temp.f('RN1') and d.superseded_at is null),
            'B5: the same licence number with its new expiry; the uploaded file is the current document');
select t.fails(format($q$ update public.client_renewals set accepted = true where id = %L $q$, pg_temp.f('RN2')), 'decided once', 'B5: a decision is final');
select t.ok(pg_temp.nots(t.u('02'), 'client_renewal') = 2 and pg_temp.nots(pg_temp.f('OWN'), 'client_renewal') = 0, 'B5: the State Manager is told of each upload');

-- 6 · closed ------------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('02'));
select t.fails('select count(*) from public.notifications', 'permission denied', '6: the notifications table is closed (through functions only)');
select t.fails('select count(*) from public.client_renewals', 'permission denied', '6: so is the renewals table');
select t.fails($q$ select app.notify_client('client_ended', '00000000-0000-4000-8000-000000000201', null, '{}') $q$, 'permission denied', '6: nobody writes a notification directly');
select t.as_service();
create temp table other_n as select id from public.notifications where user_id = t.u('01') limit 1;
create temp table own_n as select array_agg(id order by id) as ids from public.notifications where user_id = t.u('02');
grant select on other_n, own_n to authenticated;
select t.as_user(t.u('02'));
select t.ok((select array_agg((n ->> 'id')::uuid order by (n ->> 'id')::uuid) from jsonb_array_elements(app.my_notifications()) n) = (select ids from own_n),
            '6: one''s own notifications only');
select t.ok(app.read_notifications(array(select id from other_n)) = 0, '6: another''s notification is not marked read');
select t.as_anon();
select t.fails($q$ select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'ended', 'from outside the system') $q$, 'permission denied', '6: the public changes nothing');
rollback;
