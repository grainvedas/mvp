-- Migration 67 (Phase 3, release 1 of Veda's combined brief of 19 Oct 2026: Parts A and B, with Phase 2's B4).
--   1  B4: a scope's delivery model and GI authorised-user number: set by its Client Manager only, through their functions
--   2  A3: today's client login (04, "Prasaadam Client View") is a viewer of the whole client; it is not an owner
--   3  A1: the admin makes an owner, once the client's first Active is approved; nobody else does; nothing is made
--      without saying first what it is
--   4  A1/B: the owner invites a viewer of the Bansi scope only; it sees Bansi and nothing else of the client; internal
--      copies only when the owner allows it. The Client Manager makes a viewer of one state only (Assam): never the
--      whole client, never two states
--   5  A2: a viewer's writes are all refused; the owner's acts are allowed (a buyer link made and revoked, the client's
--      acceptance on a lab record, a viewer invited) and nothing else
--   6  A1/A2.5: an operator made by the Client Manager: refused on a Managed scope, placed on a Hybrid one; in the roster
--      pool of the Hybrid scope only; his record says "made by client staff" and is verified by GrainVeda only
--   7  A2.3: accounts suspended and removed by whoever may (the admin for owners); a suspended viewer sees nothing
--   8  A4: while the client is suspended in a state, the owner makes no buyer link there but revokes one
--   9  B: a second client: neither side sees the other's accounts, scopes or people; a client account reads no HR record
--  10  B: a viewer's farmers, client record and notices are those of what it reaches
-- Fake, format-valid numbers only.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.acct(p uuid) returns public.client_accounts language sql stable security definer as $$ select * from public.client_accounts where user_id = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$ select * from public.footprints where id = p $$;
create or replace function pg_temp.raw(p_scope uuid, p_client uuid, p_stage public.stage_type, p_by uuid, p_code text) returns uuid language plpgsql security definer as $$
declare v uuid; begin
  set local session_replication_role = replica;
  insert into public.footprints (scope_id, client_id, stage_type, created_by, footprint_code, qty_in, qty_out, payload, status, verified_by, verified_at)
  values (p_scope, p_client, p_stage, p_by, p_code, 100, 100, '{}', 'verified', '00000000-0000-4000-8000-000000000306', now()) returning id into v;
  set local session_replication_role = origin;
  return v; end $$;
-- a login, as create-user leaves it: the database row the creator made, linked to a sign-in
create or replace function pg_temp.login(p uuid) returns void language sql security definer as $$ update public.app_users set auth_uid = p where id = p $$;
-- a file put in the evidence store (as the browser's upload leaves it)
create or replace function pg_temp.stored(p_name text) returns text language plpgsql security definer as $$
begin
  if to_regclass('storage.objects') is not null then execute 'insert into storage.objects (bucket_id, name) values ($1, $2)' using 'evidence', p_name; end if;
  return p_name; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- the fixtures: client 201 (Prasaadam) Active in Uttar Pradesh and Assam; scopes 01 (Siddharthnagar, UP), 06 (Bansi
-- batch, UP), 07 (Nagaon, Assam, draft); its Client Manager 03; client 202 (Demo Exporter) with a Client Manager and a scope
insert into public.client_states (client_id, state_id, status, legacy) values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'active', true)
  on conflict do nothing;
insert into public.app_users (id, auth_uid, display_name, email) values
  ('00000000-0000-4000-8000-000000000e01', '00000000-0000-4000-8000-000000000e01', 'Demo Exporter Client Manager', 'cm.demox67@example.com');
insert into public.assignments (employee_id, lens, op_role, client_id) values ('00000000-0000-4000-8000-000000000e01', 'client', 'client_account', '00000000-0000-4000-8000-000000000202');
insert into fx values ('CM2', '00000000-0000-4000-8000-000000000e01'), ('C1', '00000000-0000-4000-8000-000000000201'), ('C2', '00000000-0000-4000-8000-000000000202'),
                      ('UP', '00000000-0000-4000-8000-000000000001'), ('AS', '00000000-0000-4000-8000-000000000002');
with r as (insert into public.scopes (client_id, state_id, crop_id, season_code, geography, chain, status, market_codes, qc_report_required, stage_details_required)
           values (pg_temp.f('C2'), pg_temp.f('UP'), '00000000-0000-4000-8000-000000000101', 'KH26', 'Demox Deoria', '{procurement,qc,qr_activation}', 'draft', '{domestic}', false, false)
           returning id) insert into fx select 'S2', id from r;

-- 1 · B4: delivery model and GI authorised user ---------------------------------------------------------------------------
select t.ok((select delivery_model = 'managed' and gi_user_no is null from public.scopes where id = t.scope('01')), '1: a scope starts Managed (every scope of before)');
select t.as_user(t.u('02'));
select t.fails(format($$select app.set_scope_delivery(%L, 'hybrid', 'the client runs its own collection centre')$$, t.scope('01')), 'set by the scope''s Client Manager', '1: the State Manager does not set it');
select t.as_user(t.u('04'));
select t.fails(format($$select app.set_scope_delivery(%L, 'hybrid', 'the client runs its own collection centre')$$, t.scope('01')), 'set by the scope''s Client Manager', '1: nor the client''s login');
select t.as_user(t.u('03'));
select t.fails(format($$update public.scopes set delivery_model = 'hybrid' where id = %L$$, t.scope('01')), 'set on the scope''s page by the Client Manager', '1: not by a direct write');
select t.fails(format($$select app.set_scope_delivery(%L, 'hybrid')$$, t.scope('01')), 'say why it changes', '1: an active scope''s model changes with a reason');
select t.fails(format($$select app.set_scope_delivery(%L, 'outsourced', 'the client runs its own collection centre')$$, t.scope('01')), 'managed, hybrid or self-run', '1: three models only');
select app.set_scope_delivery(t.scope('01'), 'hybrid', 'the client runs its own collection centre');
select app.set_scope_gi_user(t.scope('01'), 'GI-AU-280-0099');
select t.as_service();
select t.ok((select delivery_model = 'hybrid' and gi_user_no = 'GI-AU-280-0099' from public.scopes where id = t.scope('01'))
            and exists (select 1 from public.audit_log where action = 'scope_delivery_model' and target = t.scope('01'))
            and exists (select 1 from public.audit_log where action = 'scope_gi_user' and target = t.scope('01')),
            '1: the Client Manager sets Hybrid (with its reason) and the GI authorised-user number; both in the Audit log');
select t.as_user(t.u('03'));
select t.fails(format($$select app.set_scope_gi_user(%L, 'GI-AU-280-0099', 'nope/x.pdf', '%s')$$, t.scope('01'), repeat('a', 64)), 'stored as', '1: the file in its own place only');

-- 2 · A3: today's client login is a viewer of the whole client ----------------------------------------------------------------
select t.as_service();
select t.ok((pg_temp.acct(t.u('04'))).kind = 'viewer' and (pg_temp.acct(t.u('04'))).reach = 'client' and (pg_temp.acct(t.u('04'))).made_as = 'migration',
            '2: the client login of before is a viewer of all its client''s scopes');
select t.as_user(t.u('04'));
select t.ok(app.can_access_scope(t.scope('01')) and app.can_access_scope(t.scope('06')) and app.can_access_scope(t.scope('07'))
            and not app.client_owner_check('00000000-0000-4000-8000-000000000201'),
            '2: it reads every scope of its client, in both states; it is not an owner');
select t.ok(((app.my_context()) -> 'user' -> 'client_account' ->> 'kind') = 'viewer', '2: the app is told what it is');
select t.ok(not (app.client_view('00000000-0000-4000-8000-000000000201') -> 'may' ->> 'renew')::boolean, '2: a viewer uploads no renewal');

-- 3 · A1: the owner, made by the admin -------------------------------------------------------------------------------------------
-- a client still a Prospect (no Active yet): no owner; Prasaadam and Demo Exporter, kept Active, have one
select t.as_service();
with r as (insert into public.clients (name, code, type, state_id) values ('Prospect Foods (test)', 'PRSP', 'brand', '00000000-0000-4000-8000-000000000001') returning id)
  insert into fx select 'C3', id from r;
insert into public.client_states (client_id, state_id, status) values (pg_temp.f('C3'), pg_temp.f('UP'), 'prospect')
  on conflict (client_id, state_id) do update set status = 'prospect';
select t.as_user(t.u('01'));
select t.fails(format($$select app.prepare_client_account(%L, 'owner', 'owner@prospect.test')$$, pg_temp.f('C3')), 'once the client''s first Active is approved', '3: not before the first Active is approved');
select t.as_user(t.u('03'));
select t.fails($$select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner@prasaadam.test')$$, 'made by the admin', '3: the Client Manager makes no owner');
select t.as_user(t.u('02'));
select t.fails($$select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner@prasaadam.test')$$, 'made by the admin', '3: nor the State Manager');
select t.as_user(t.u('01'));
select t.fails($$select app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Owner', 'owner@prasaadam.test')$$, 'say first what it is', '3: nothing is made without saying first what it is');
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner@prasaadam.test');
insert into fx select 'OWN', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Owner', 'owner@prasaadam.test');
select t.fails($$select app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Owner again', 'owner@prasaadam.test')$$, 'say first what it is', '3: what was said is used once');
select app.prepare_client_account('00000000-0000-4000-8000-000000000202', 'owner', 'owner@demox.test');
insert into fx select 'OWN2', app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Demox Owner', 'owner@demox.test');
select t.as_service();
select pg_temp.login(pg_temp.f('OWN')); select pg_temp.login(pg_temp.f('OWN2'));
select t.ok((pg_temp.acct(pg_temp.f('OWN'))).kind = 'owner' and (pg_temp.acct(pg_temp.f('OWN'))).made_as = 'admin'
            and (select external and not exists (select 1 from public.onboarding_tasks o where o.employee_id = u.id)
                   and not exists (select 1 from public.employee_org o where o.employee_id = u.id) from public.app_users u where u.id = pg_temp.f('OWN'))
            and exists (select 1 from public.audit_log where action = 'client_login_created' and target = pg_temp.f('OWN') and detail ->> 'kind' = 'owner'),
            '3: the admin made the owner: a client account, no HR record, no checklist; in the Audit log');
select t.as_user(pg_temp.f('OWN'));
select t.ok(app.client_owner_check(pg_temp.f('C1')) and app.can_access_scope(t.scope('01')) and app.can_access_scope(t.scope('07'))
            and not app.can_access_scope(pg_temp.f('S2')) and (app.client_view(pg_temp.f('C1')) -> 'may' ->> 'renew')::boolean,
            '3: the owner sees every scope of its client in both states, none of another client''s; it may upload a renewal');

-- 4 · A1/B: viewers: the owner's (one scope), the Client Manager's (one state) -----------------------------------------------
select t.as_user(pg_temp.f('OWN'));
select app.prepare_client_account(pg_temp.f('C1'), 'viewer', 'bansi@prasaadam.test', 'scopes', null, array[t.scope('06')]);
insert into fx select 'VB', app.add_client_viewer(pg_temp.f('C1'), 'Bansi Desk', 'bansi@prasaadam.test');
select t.fails(format($$select app.prepare_client_account(%L, 'viewer', 'x@prasaadam.test', 'scopes', null, array[%L]::uuid[])$$, pg_temp.f('C1'), pg_temp.f('S2')),
               'only this client''s scopes', '4: an owner chooses only its own client''s scopes');
select t.as_service(); select pg_temp.login(pg_temp.f('VB'));
select t.as_user(pg_temp.f('VB'));
select t.ok(app.can_access_scope(t.scope('06')) and not app.can_access_scope(t.scope('01')) and not app.can_access_scope(t.scope('07'))
            and jsonb_array_length(app.my_context() -> 'scopes') = 1,
            '4: the Bansi viewer sees the Bansi scope and nothing else of its client (not Siddharthnagar, not Nagaon)');
select t.ok(not app.may_internal_copy(t.scope('06')), '4: no internal copy until the owner allows it');
select t.as_user(pg_temp.f('OWN'));
select app.set_viewer_internal(pg_temp.f('VB'), true);
select t.as_user(pg_temp.f('VB'));
select t.ok(app.may_internal_copy(t.scope('06')) and not app.may_internal_copy(t.scope('01')), '4: allowed by the owner: internal copies of its scope only');
select t.as_user(t.u('03'));
select t.fails(format($$select app.prepare_client_account(%L, 'viewer', 'all@prasaadam.test', 'client')$$, pg_temp.f('C1')), 'sees one state''s scopes', '4: the Client Manager makes no whole-client viewer');
select t.fails(format($$select app.prepare_client_account(%L, 'viewer', 'two@prasaadam.test', 'scopes', null, array[%L, %L]::uuid[])$$, pg_temp.f('C1'), t.scope('01'), t.scope('07')),
               'sees one state''s scopes', '4: nor one of scopes in two states');
select t.fails(format($$select app.prepare_client_account(%L, 'viewer', 'int@prasaadam.test', 'state', %L, '{}', true)$$, pg_temp.f('C1'), pg_temp.f('AS')),
               'only the client''s owner allows internal copies', '4: nor one with internal copies');
select t.fails(format($$select app.set_viewer_internal(%L, false)$$, pg_temp.f('VB')), 'only the client''s owner', '4: the Client Manager does not allow internal copies');
select app.prepare_client_account(pg_temp.f('C1'), 'viewer', 'assam@prasaadam.test', 'state', pg_temp.f('AS'));
insert into fx select 'VA', app.add_client_viewer(pg_temp.f('C1'), 'Assam Desk', 'assam@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('VA'));
select t.as_user(pg_temp.f('VA'));
select t.ok(app.can_access_scope(t.scope('07')) and not app.can_access_scope(t.scope('01')) and not app.can_access_scope(t.scope('06')),
            '4: the Client Manager''s Assam viewer sees the Assam scope only');
select t.ok((select array_agg(x ->> 'state_id') = array[pg_temp.f('AS')::text] from jsonb_array_elements(app.client_view(pg_temp.f('C1')) -> 'states') x),
            '4/10: its client record shows the Assam state only');

-- 5 · A2: a viewer writes nothing; the owner does its acts only ----------------------------------------------------------------
select t.as_service();
insert into fx select 'SALE', pg_temp.raw(t.scope('06'), pg_temp.f('C1'), 'commercial', t.u('05'), 'T67-CM-0001');
insert into fx select 'LAB', pg_temp.raw(t.scope('06'), pg_temp.f('C1'), 'qc', t.u('05'), 'T67-QC-0001');
insert into fx select 'PROC', pg_temp.raw(t.scope('06'), pg_temp.f('C1'), 'procurement', t.u('05'), 'T67-P-0001');
select t.as_user(pg_temp.f('VB'));
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('SALE')), 'made by the Client Manager', '5: a viewer makes no buyer link');
select t.fails(format($$select app.add_client_acceptance(%L, 'x', '%s')$$, pg_temp.f('LAB'), repeat('a', 64)), 'uploaded by its owner', '5: nor uploads an acceptance');
select t.fails(format($$select app.prepare_client_account(%L, 'viewer', 'v2@prasaadam.test', 'scopes', null, array[%L]::uuid[])$$, pg_temp.f('C1'), t.scope('06')),
               'made by the client''s owner or its Client Manager', '5: nor invites a viewer');
select t.fails(format($$insert into public.flags (footprint_id, raised_by, text) values (%L, %L, 'looks wrong to me')$$, pg_temp.f('PROC'), pg_temp.f('VB')), '', '5: nor raises a flag');
select t.fails(format($$insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by) values (%L, 'photo', %L, %L, %L)$$,
               pg_temp.f('PROC'), format('%s/%s/%s/x.jpg', pg_temp.f('C1'), t.scope('06'), pg_temp.f('PROC')), repeat('b', 64), pg_temp.f('VB')), '', '5: nor attaches a file');
select t.fails(format($$select app.set_scope_delivery(%L, 'managed', 'back to GrainVeda people')$$, t.scope('06')), 'Client Manager', '5: nor changes a scope''s settings');
select t.fails(format($$select app.set_client_account_status(%L, 'suspended', 'not needed now')$$, pg_temp.f('VA')), 'managed by whoever made it', '5: nor touches another account');
select t.as_user(pg_temp.f('OWN'));
insert into fx select 'LINK', ((app.create_buyer_link(pg_temp.f('SALE'), 10, 'for the buyer')) ->> 'id')::uuid;
select t.ok(jsonb_array_length(app.buyer_links_of(pg_temp.f('SALE'))) = 1, '5: the owner makes a buyer link and reads it');
select app.revoke_buyer_link(pg_temp.f('LINK'), 'sent to the wrong buyer');
select t.ok((app.buyer_links_of(pg_temp.f('SALE')) -> 0 ->> 'state') = 'revoked', '5: and revokes it');
select t.fails(format($$select app.add_client_acceptance(%L, %L, '%s')$$, pg_temp.f('PROC'), format('%s/%s/%s/a.pdf', pg_temp.f('C1'), t.scope('06'), pg_temp.f('PROC')), repeat('c', 64)),
               'attached to the lab record', '5: an acceptance goes on the lab record only');
select app.add_client_acceptance(pg_temp.f('LAB'), pg_temp.stored(format('%s/%s/%s/a.pdf', pg_temp.f('C1'), t.scope('06'), pg_temp.f('LAB'))), repeat('c', 64));
select t.as_service();
select t.ok(exists (select 1 from public.attachments where footprint_id = pg_temp.f('LAB') and label = 'acceptance' and uploaded_by = pg_temp.f('OWN')),
            '5: the owner''s acceptance is on the lab record, as its upload');
select t.as_user(pg_temp.f('OWN'));
select t.fails(format($$insert into public.flags (footprint_id, raised_by, text) values (%L, %L, 'looks wrong to me')$$, pg_temp.f('PROC'), pg_temp.f('OWN')), '', '5: the owner raises no flag');
select t.fails(format($$insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by, label) values (%L, 'document', %L, %L, %L, 'acceptance')$$,
               pg_temp.f('LAB'), format('%s/%s/%s/y.pdf', pg_temp.f('C1'), t.scope('06'), pg_temp.f('LAB')), repeat('d', 64), pg_temp.f('OWN')),
               'reads only', '5: nor writes an attachment directly (only through its act)');
select t.fails(format($$select app.set_scope_delivery(%L, 'managed', 'back to GrainVeda people')$$, t.scope('06')), 'Client Manager', '5: nor changes a scope''s settings');
select t.fails($$select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'operator', 'op@prasaadam.test')$$, 'made by the client''s Client Manager', '5: nor makes an operator');

-- 6 · A1/A2.5: the client operator ---------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select app.prepare_client_account(pg_temp.f('C1'), 'operator', 'op@prasaadam.test');
insert into fx select 'OP', app.add_client_viewer(pg_temp.f('C1'), 'Prasaadam Field Staff', 'op@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OP'));
select t.ok((pg_temp.acct(pg_temp.f('OP'))).kind = 'operator' and not exists (select 1 from public.assignments where employee_id = pg_temp.f('OP')),
            '6: the operator has no client view: it sees only the stages it is given');
select t.fails(format($$select t.staff(%L, %L)$$, t.scope('06'), pg_temp.f('OP')), 'can only view its own client', '6: refused on a Managed scope');
select t.ok(app.stage_refusal(pg_temp.f('OP'), t.scope('06')) = 'the client''s own staff hold stages only on a Hybrid or Self-run scope'
            and app.stage_refusal(pg_temp.f('OP'), pg_temp.f('S2')) = 'a client''s login holds no stage'
            and app.stage_refusal(pg_temp.f('OP'), t.scope('01')) is null,
            '6: the stage rule: Managed refused in words, another client refused, the Hybrid scope allowed');
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.roster_pool(t.scope('01'))) x where (x ->> 'id')::uuid = pg_temp.f('OP'))
            and not exists (select 1 from jsonb_array_elements(app.roster_pool(t.scope('06'))) x where (x ->> 'id')::uuid = pg_temp.f('OP')),
            '6: in the roster pool of the Hybrid scope, not of the Managed one');
select t.as_service();
select t.staff(t.scope('01'), pg_temp.f('OP'));
select t.as_user(pg_temp.f('OP'));
insert into fx select 'OPLOT', t.procure_as(t.scope('01'), t.farmer('01'), pg_temp.f('OP'));
select t.ok((pg_temp.fp(pg_temp.f('OPLOT'))).client_staff and (pg_temp.fp(pg_temp.f('OPLOT'))).created_by = pg_temp.f('OP'),
            '6: the operator records at its stage; the record is marked as made by client staff');
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('OPLOT')), 'verified by GrainVeda', '6: a record by client staff is not verified by client staff');
select t.ok(not app.may_internal_copy(t.scope('01')), '6: an operator downloads no internal copy');
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('SALE')), '', '6: an operator makes no buyer link');
update public.scopes set geography = 'renamed' where id = t.scope('01');
select t.as_service();
select t.ok((select geography <> 'renamed' from public.scopes where id = t.scope('01')), '6: nor changes the scope (the write reaches no row)');
select t.as_user(t.u('06'));
select app.verify_footprint(pg_temp.f('OPLOT'));
select t.ok((pg_temp.fp(pg_temp.f('OPLOT'))).status = 'verified', '6: GrainVeda''s QC verifies it');
select t.as_user(t.u('03'));
select t.fails(format($$select app.set_scope_delivery(%L, 'managed', 'back to GrainVeda people')$$, t.scope('01')), 'still hold stages here', '6: Managed again only once the client''s staff hold no stage');

-- 7 · A2.3: suspended and removed, by whoever may --------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails(format($$select app.set_client_account_status(%L, 'suspended', 'payment pending')$$, pg_temp.f('OWN')), 'the admin for owners', '7: the Client Manager does not suspend an owner');
select t.as_user(pg_temp.f('OWN'));
select app.set_client_account_status(pg_temp.f('VB'), 'suspended', 'desk closed for the month');
select t.as_user(pg_temp.f('VB'));
select t.ok(not app.can_access_scope(t.scope('06')) and jsonb_typeof(app.my_context() -> 'user') = 'null', '7: a suspended viewer sees nothing');
select t.as_user(pg_temp.f('OWN'));
select app.set_client_account_status(pg_temp.f('VB'), 'active', 'desk open again');
select t.as_user(pg_temp.f('VB'));
select t.ok(app.can_access_scope(t.scope('06')), '7: active again: it sees its scope again');
select t.as_user(t.u('01'));
select app.set_client_account_status(pg_temp.f('OWN2'), 'removed', 'left the company');
select t.fails(format($$select app.set_client_account_status(%L, 'active', 'came back')$$, pg_temp.f('OWN2')), 'stays removed', '7: removed is final');
select t.as_service();
select t.ok((select status = 'offboarded' from public.app_users where id = pg_temp.f('OWN2')) and not exists (select 1 from public.assignments where employee_id = pg_temp.f('OWN2') and active)
            and (select count(*) from public.audit_log where action = 'client_account_status') = 3,
            '7: the admin removed an owner: its sign-in and view ended; every change in the Audit log');
select t.as_user(t.u('01'));
select app.make_client_owner(t.u('04'));
select t.as_service();
select t.ok((pg_temp.acct(t.u('04'))).kind = 'owner', '7: the admin promotes the login of before to owner');

-- 8 · A4: the client suspended in Uttar Pradesh ----------------------------------------------------------------------------------
select t.as_user(pg_temp.f('OWN'));
insert into fx select 'LINK2', ((app.create_buyer_link(pg_temp.f('SALE'), 10, 'for the buyer')) ->> 'id')::uuid;
select t.as_user(t.u('02'));
select app.client_set_status(pg_temp.f('C1'), pg_temp.f('UP'), 'suspended', 'payment overdue 90 days');
select t.as_user(pg_temp.f('OWN'));
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('SALE')), 'an owner''s acts are paused', '8: suspended: the owner makes no buyer link');
select t.fails(format($$select app.add_client_acceptance(%L, %L, '%s')$$, pg_temp.f('LAB'), pg_temp.stored(format('%s/%s/%s/b.pdf', pg_temp.f('C1'), t.scope('06'), pg_temp.f('LAB'))), repeat('e', 64)),
               'paused', '8: nor uploads an acceptance there');
select app.revoke_buyer_link(pg_temp.f('LINK2'), 'client suspended: withdraw it');
select t.ok((select revoked_at is not null from public.buyer_links where id = pg_temp.f('LINK2')), '8: but revokes one');
select t.ok(app.can_access_scope(t.scope('06')), '8: and still reads');
select t.as_user(t.u('02'));
select app.client_set_status(pg_temp.f('C1'), pg_temp.f('UP'), 'active', 'payment received in full');

-- 9 · B: two clients ---------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select app.prepare_client_account(pg_temp.f('C2'), 'owner', 'owner2@demox.test');
insert into fx select 'OWN3', app.add_client_viewer(pg_temp.f('C2'), 'Demox Owner Two', 'owner2@demox.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OWN3'));
select t.as_user(pg_temp.f('OWN3'));
select t.ok(not app.can_access_scope(t.scope('01')) and not app.can_access_scope(t.scope('06')) and app.can_access_scope(pg_temp.f('S2')),
            '9: the other client''s owner sees its own scope and none of Prasaadam''s');
select t.fails(format($$select app.client_accounts_of(%L)$$, pg_temp.f('C1')), 'not found', '9: nor Prasaadam''s accounts');
select t.ok(not exists (select 1 from public.app_users where id in (pg_temp.f('OWN'), pg_temp.f('VB'), pg_temp.f('OP'), t.u('03'), t.u('05'))),
            '9: nor any of Prasaadam''s people, nor GrainVeda''s');
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('SALE')), 'not found', '9: nor shares Prasaadam''s sale');
select t.ok(not exists (select 1 from public.employee_org) and not exists (select 1 from public.employee_exits) and not exists (select 1 from public.onboarding_tasks),
            '9: a client account reads no HR record');
select t.ok(pg_temp.err('select count(*) from public.buyer_entities') like '%permission denied%' and pg_temp.err('select count(*) from public.client_accounts') like '%permission denied%',
            '9: the registry''s links and the accounts table are closed');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select count(*) from jsonb_array_elements(app.client_accounts_of(pg_temp.f('C1')) -> 'accounts')) >= 4
            and not exists (select 1 from jsonb_array_elements(app.client_accounts_of(pg_temp.f('C1')) -> 'accounts') x where (x ->> 'id')::uuid in (pg_temp.f('OWN2'), pg_temp.f('OWN3'))),
            '9: Prasaadam''s owner lists its own accounts and none of the other client''s');
select t.ok(exists (select 1 from public.app_users where id = pg_temp.f('VB')) and not exists (select 1 from public.app_users where id = pg_temp.f('OWN3'))
            and not exists (select 1 from public.app_users where id = t.u('05')),
            '9: it reads its own viewers'' names; no other client''s, no GrainVeda employee''s');
select t.as_user(pg_temp.f('VB'));
select t.ok(not exists (select 1 from public.app_users where id <> pg_temp.f('VB')), '9: a viewer reads nobody but itself');

-- 10 · B: a viewer's farmers and notices ---------------------------------------------------------------------------------------------
select t.as_service();
set local session_replication_role = replica;
update public.footprints set farmer_id = t.farmer('02') where id = pg_temp.f('PROC');      -- a lot bought from farmer 02 in Bansi
set local session_replication_role = origin;
select t.as_user(pg_temp.f('VB'));
select t.ok((select array_agg(x ->> 'id') from jsonb_array_elements(app.client_farmers()) x) = array[t.farmer('02')::text],
            '10: the Bansi viewer sees the farmer who sold into Bansi only');
select t.as_user(t.u('04'));
select t.ok(jsonb_array_length(app.client_farmers()) > 1, '10: a whole-client account sees all its client''s farmers');
select t.as_service();
select app.notify_client('client_state_added', pg_temp.f('C1'), pg_temp.f('AS'), '{"by":"test"}');
select t.ok(exists (select 1 from public.notifications where user_id = pg_temp.f('VA') and kind = 'client_state_added')
            and not exists (select 1 from public.notifications where user_id = pg_temp.f('VB') and kind = 'client_state_added')
            and exists (select 1 from public.notifications where user_id = pg_temp.f('OWN') and kind = 'client_state_added'),
            '10: a notice of Assam goes to the owner and the Assam viewer, not to the Bansi viewer');

rollback;
