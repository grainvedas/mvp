-- Migration 64 (Phase 2, release 1 of Veda's combined brief of 19 Oct 2026: Parts A and B, the client registry).
--   1  the ID checks: PAN format and its 4th letter against the entity type; GSTIN against the PAN and the state's GST
--      code; CIN, LLPIN, FSSAI, IEC formats
--   2  one PAN, one record: Ram creates "ABC Exim Ltd"; the Assam State Manager typing the same PAN sees "Already
--      registered" and the shared identity only, and cannot create it again (nor by a direct insert); a similar name
--      with another PAN is a soft warning; a business known in another role becomes a client on the same record
--   3  numbers: full only to the admin and the client's own State Managers; masked elsewhere; the audit log and the
--      change log hold no number; the registry's tables are closed to everyone
--   4  the gates: no scope while Prospect; a draft scope in Diagnostic, no activation; the checklist ("n of m"); the
--      IEC and RCMC only with an export scope; the KYC tick after the files; the first Active waits for the admin
--   5  existing clients: Active with "PAN pending" (off production); the PAN typed once; the admin's code edit once
--   6  who sees what: the Clients page per role; the admin's queue
-- Fake, format-valid numbers only (ZZZ…).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
-- a file "uploaded" to the client-docs store, as the store would hold it
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
create or replace function pg_temp.item(g jsonb, k text) returns jsonb language sql immutable as $$
  select it from jsonb_array_elements(g -> 'gates') x, jsonb_array_elements(x -> 'items') it where it ->> 'key' = k $$;
create or replace function pg_temp.g(p_client uuid) returns jsonb language sql stable as $$
  select app.client_view(p_client) -> 'states' -> 0 -> 'gates' $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

update public.crops set apeda_scheduled = true where id = '00000000-0000-4000-8000-000000000101';   -- rice (the migration marks existing rice crops)
do $$ declare v uuid; uk uuid;
begin
  insert into public.states (name, code) values ('Uttarakhand', 'UK') returning id into uk;
  update public.states set gst_code = '05' where id = uk;
  insert into fx values ('UK', uk), ('UP', '00000000-0000-4000-8000-000000000001'), ('AS', '00000000-0000-4000-8000-000000000002');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c01', '00000000-0000-4000-8000-000000000c01', 'Assam State Manager', 'sm.assam64@example.com') returning id into v;
  insert into fx values ('SMA', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', '00000000-0000-4000-8000-000000000002');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c02', '00000000-0000-4000-8000-000000000c02', 'Uttarakhand State Manager', 'sm.uk64@example.com') returning id into v;
  insert into fx values ('SMK', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', uk);
end $$;

-- 1 · the ID checks ------------------------------------------------------------------------------------------------------
select t.ok(app.check_pan('zzzcz0001z', 'company') = 'ZZZCZ0001Z', 'PAN: typed small, stored in capitals');
select t.fails($q$ select app.check_pan('ZZZC0001Z', 'company') $q$, '5 letters, 4 digits, 1 letter', 'PAN: the format is checked');
select t.fails($q$ select app.check_pan('ZZZPZ0001Z', 'company') $q$, '4th letter is P', 'PAN: a 4th letter P is not a company''s');
select t.ok(app.check_pan('ZZZFZ0001Z', 'llp') = 'ZZZFZ0001Z' and app.check_pan('ZZZAZ0001Z', 'cooperative') = 'ZZZAZ0001Z'
            and app.check_pan('ZZZHZ0001Z', 'huf') = 'ZZZHZ0001Z', 'PAN: F for an LLP or a firm, A for a society or a cooperative, H for a HUF');
select t.ok(app.check_gstin('09ZZZCZ0001Z1Z5', 'ZZZCZ0001Z', pg_temp.f('UP')) = '09ZZZCZ0001Z1Z5', 'GSTIN: the state''s code and the client''s PAN');
select t.fails($q$ select app.check_gstin('09ZZZCY0002Y1Z5', 'ZZZCZ0001Z', '00000000-0000-4000-8000-000000000001') $q$, 'must be this client''s PAN', 'GSTIN: another PAN is refused');
select t.fails(format($q$ select app.check_gstin('09ZZZCZ0001Z1Z5', 'ZZZCZ0001Z', %L) $q$, pg_temp.f('UK')), 'starts with 09, which is not Uttarakhand (05)', 'GSTIN: a UP GSTIN for Uttarakhand is refused');
select t.fails($q$ select app.check_number('cin', 'U01100UP2025PTC12345') $q$, 'CIN: 21 characters', 'CIN: the format');
select t.ok(app.check_number('cin', 'U01100UP2025PTC123456') is not null and app.check_number('llpin', 'aab-1234') = 'AAB-1234', 'CIN and LLPIN: valid forms pass');
select t.fails($q$ select app.check_number('fssai', '1234567890123') $q$, '14 digits', 'FSSAI: 14 digits');
select t.ok(app.mask_id('pan', 'ZZZCZ0001Z') = 'ZZZCZ****Z' and app.mask_id('gstin', '09ZZZCZ0001Z1Z5') = '09ZZZCZ****Z1Z5', 'masks: ABCDE****F; a GSTIN''s PAN part');

-- 2 · one PAN, one record --------------------------------------------------------------------------------------------
select t.as_user(t.u('02'));                                          -- Ram, State Manager of Uttar Pradesh
select t.ok(app.lookup_pan('ZZZCZ0001Z', 'ABC Exim Ltd', 'company') ->> 'situation' = 'new', 'lookup: a PAN not in the registry: continue');
select t.fails($q$ select app.create_client('{"pan":"ZZZPZ0001Z","entity_type":"company","legal_name":"ABC Exim Ltd","state_id":"00000000-0000-4000-8000-000000000001",
  "contact":{"name":"A. Kumar","designation":"Director","phone":"9000000001","email":"a@abcexim.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') $q$,
  '4th letter is P', 'create: a PAN whose 4th letter does not match the entity type is refused');
select t.fails($q$ select app.create_client('{"pan":"ZZZCZ0001Z","entity_type":"company","legal_name":"ABC Exim Ltd","state_id":"00000000-0000-4000-8000-000000000001",
  "contact":{"name":"A. Kumar","designation":"Director","phone":"9000000001"},"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') $q$,
  'name, designation, phone and email', 'create: Gate 1 asks the whole primary contact');
select t.fails($q$ select app.create_client('{"pan":"ZZZCZ0001Z","entity_type":"company","legal_name":"ABC Exim Ltd","state_id":"00000000-0000-4000-8000-000000000002",
  "contact":{"name":"A. Kumar","designation":"Director","phone":"9000000001","email":"a@abcexim.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') $q$,
  'State Manager of the state it starts in', 'create: only in a state of his own');
insert into fx select 'ABC', (app.create_client('{"pan":"zzzcz0001z","entity_type":"company","legal_name":"ABC Exim Ltd","state_id":"00000000-0000-4000-8000-000000000001",
  "contact":{"name":"A. Kumar","designation":"Director","phone":"9000000001","email":"A@abcexim.test"},"source":"outreach",
  "states_of_interest":["00000000-0000-4000-8000-000000000001"],"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') ->> 'client_id')::uuid;
select t.ok((select code ~ '^[A-Z]{3,5}$' from public.clients where id = pg_temp.f('ABC')), 'the client code is made by the system: 3 to 5 capitals');
select t.ok((app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 ->> 'status') = 'prospect', 'a new client is a Prospect in its state');
select t.ok((app.client_view(pg_temp.f('ABC')) #>> '{identity,pan}') = 'ZZZCZ0001Z', 'its State Manager reads the PAN in full');

select t.as_user(pg_temp.f('SMA'));                                    -- the Assam State Manager types the same PAN
select t.ok(app.lookup_pan('ZZZCZ0001Z') ->> 'situation' = 'client', 'lookup: "Already registered with GrainVeda"');
select t.ok((app.lookup_pan('ZZZCZ0001Z') -> 'identity') ?& array['legal_name', 'pan_masked', 'entity_type', 'status', 'code']
            and (app.lookup_pan('ZZZCZ0001Z') #>> '{identity,pan_masked}') = 'ZZZCZ****Z'
            and position('ZZZCZ0001Z' in app.lookup_pan('ZZZCZ0001Z')::text) = 0
            and not ((app.lookup_pan('ZZZCZ0001Z') -> 'identity') ?| array['contact', 'gstin', 'states', 'pan']),
            'the shared identity only: legal name, masked PAN, type, status, code; no contact, GSTIN or state detail');
select t.fails($q$ select app.create_client('{"pan":"ZZZCZ0001Z","entity_type":"company","legal_name":"ABC Exim Limited","state_id":"00000000-0000-4000-8000-000000000002",
  "contact":{"name":"B","designation":"D","phone":"9000000002","email":"b@x.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000102"]}') $q$,
  'already registered with GrainVeda', 'a second State Manager cannot create a duplicate');
select t.fails($q$ insert into public.clients (name, code, type, state_id) values ('ABC Exim (again)', 'ABCX', 'exporter', '00000000-0000-4000-8000-000000000002') $q$,
  'permission denied', 'nor by a direct insert');
select t.ok((app.client_view(pg_temp.f('ABC')) ->> 'shared_only')::boolean and jsonb_array_length(app.client_view(pg_temp.f('ABC')) -> 'states') = 0,
            'another state''s State Manager opening the client: the shared identity only');
select t.ok((app.lookup_pan('ZZZCY0002Y', 'ABC Exim Limited') ->> 'similar')::boolean, 'a very similar name with another PAN: the soft warning');
insert into fx select 'ABC2', (app.create_client('{"pan":"ZZZCY0002Y","entity_type":"company","legal_name":"ABC Exim Limited","state_id":"00000000-0000-4000-8000-000000000002",
  "contact":{"name":"B. Das","designation":"Partner","phone":"9000000002","email":"b@abc2.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000102"]}') ->> 'client_id')::uuid;
select t.ok(pg_temp.f('ABC2') is not null, 'and is allowed (group companies have their own PAN)');

-- a business GrainVeda knows as a buyer: "Known to GrainVeda as a business"; it becomes a client on the same record
select t.as_service();
do $$ declare e uuid; begin
  insert into public.entities (legal_name, entity_type, pan_hash, pan_masked) values ('QWE Traders', 'firm', app.id_hash('pan', 'ZZZFQ0003Q'), 'ZZZFQ****Q') returning id into e;
  insert into public.entity_ids (entity_id, kind, value, hash, masked) values (e, 'pan', 'ZZZFQ0003Q', app.id_hash('pan', 'ZZZFQ0003Q'), 'ZZZFQ****Q');
  insert into public.entity_roles (entity_id, role) values (e, 'buyer');
  insert into fx values ('QWE', e);
end $$;
select t.as_user(t.u('02'));
select t.ok(app.lookup_pan('ZZZFQ0003Q') = '{"situation": "known", "similar": false}'::jsonb, 'known in another role: nothing about that role is shown');
insert into fx select 'QWEC', (app.create_client('{"pan":"ZZZFQ0003Q","entity_type":"firm","legal_name":"QWE Traders","state_id":"00000000-0000-4000-8000-000000000001",
  "contact":{"name":"Q","designation":"Partner","phone":"9000000003","email":"q@qwe.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') ->> 'client_id')::uuid;
select t.as_service();
select t.ok((select entity_id from public.clients where id = pg_temp.f('QWEC')) = pg_temp.f('QWE')
            and (select count(*) from public.entity_roles where entity_id = pg_temp.f('QWE')) = 2, 'the client role is added to the same entity');

-- 3 · numbers: where they are, where they are not ---------------------------------------------------------------------
select t.ok(not exists (select 1 from public.audit_log where position('ZZZCZ0001Z' in detail::text) > 0 or position('ZZZCY0002Y' in detail::text) > 0)
            and exists (select 1 from public.audit_log where action = 'client_created' and detail #>> '{pan,masked}' = 'ZZZCZ****Z' and length(detail #>> '{pan,hash}') = 64),
            'the audit log: the masked PAN and its keyed hash, never the number');
select t.ok(not exists (select 1 from public.change_log c where position('ZZZCZ0001Z' in to_jsonb(c)::text) > 0), 'the change log: no number');
select t.ok((select pan_hash from public.entities where legal_name = 'ABC Exim Ltd') <> encode(digest('pan:ZZZCZ0001Z', 'sha256'), 'hex'),
            'the fingerprint is keyed (not a plain hash anyone could recompute)');
select t.as_user(t.u('02'));
select t.fails('select count(*) from public.entity_ids', 'permission denied', 'the numbers'' table: closed to a State Manager');
select t.fails('select count(*) from public.entities', 'permission denied', 'the registry: closed (through functions only)');
select t.fails($q$ select app.id_hash('pan', 'ZZZCZ0001Z') $q$, 'permission denied', 'nobody computes fingerprints to guess numbers');
select t.as_user(t.u('03'));                                          -- a Client Manager of another client
select t.fails(format($q$ select app.client_view(%L) $q$, pg_temp.f('ABC')), 'not found', 'a Client Manager of another client: nothing');
select t.fails(format($q$ select app.client_identity(%L) $q$, pg_temp.f('ABC')), 'not found', 'not even the shared identity');
select t.fails($q$ select app.lookup_pan('ZZZCZ0001Z') $q$, 'only a State Manager', 'nor looks a PAN up');
select t.as_user(t.u('01'));
select t.ok((app.client_view(pg_temp.f('ABC')) #>> '{identity,pan}') = 'ZZZCZ0001Z', 'the admin reads the number in full');

-- 4 · the gates -------------------------------------------------------------------------------------------------------------
select t.as_service();
do $$ declare v uuid; begin
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000c03', '00000000-0000-4000-8000-000000000c03', 'ABC Client Manager', 'cm.abc64@example.com') returning id into v;
  insert into fx values ('CMA', v);
  insert into public.assignments (employee_id, lens, op_role, client_id) values (v, 'client', 'client_account', pg_temp.f('ABC'));
end $$;
select t.as_user(pg_temp.f('CMA'));
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, market_codes)
  values (%L, '00000000-0000-4000-8000-000000000101', 'KH26', 'Basti', '{procurement,qc,qr_activation}', '{domestic}') $q$, pg_temp.f('ABC')),
  'once the client is in Diagnostic', 'Prospect: no scope, not even a draft');
select t.ok(coalesce(app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 -> 'gates', 'null') = 'null'::jsonb and (app.client_view(pg_temp.f('ABC')) -> 'contact' ->> 'name') = 'A. Kumar',
            'the Client Manager reads his client''s record and its contacts (not the gates'' files)');
select t.ok((app.client_view(pg_temp.f('ABC')) #>> '{identity,pan}') is null, 'and not the PAN in full');

select t.as_user(t.u('02'));
select t.fails(format($q$ select app.client_move(%L, '00000000-0000-4000-8000-000000000001', 'diagnostic') $q$, pg_temp.f('ABC')),
  'Diagnostic needs gates 1 and 2: reg_office, reg_number, gstin, signatory, diagnostic_order, incorporation', 'the move says what is missing');
select t.ok((select jsonb_build_object('done', count(*) filter (where (it ->> 'done')::boolean), 'of', count(*))
               from jsonb_array_elements(app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 -> 'gates' -> 'gates') g, jsonb_array_elements(g -> 'items') it
              where (it ->> 'needed')::boolean and (g ->> 'gate')::int = 2) = '{"done": 0, "of": 6}', 'the checklist: Gate 2, 0 of 6 done');
select t.fails(format($q$ select app.save_client_details(%L, '00000000-0000-4000-8000-000000000001', '{"gstin":"05ZZZCZ0001Z1Z5"}') $q$, pg_temp.f('ABC')),
  'starts with 05, which is not Uttar Pradesh (09)', 'a GSTIN of another state is refused for this one');
select t.fails(format($q$ select app.save_client_details(%L, '00000000-0000-4000-8000-000000000001', '{"gstin":"09ZZZCY0002Y1Z5"}') $q$, pg_temp.f('ABC')),
  'must be this client''s PAN', 'a GSTIN of another PAN is refused');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"gstin":"09zzzcz0001z1z5","reg_office":{"address":"12 Civil Lines","city":"Gorakhpur","state":"Uttar Pradesh"},
  "reg_number":"U01100UP2025PTC123456","signatory":{"name":"A. Kumar","designation":"Director"}}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'diagnostic_order', '{"signed_on":"2026-10-20","amount":50000}');
select t.fails(format($q$ select pg_temp.doc(%L, '00000000-0000-4000-8000-000000000001', 'msa', '{"signed_on":"2026-10-20"}') $q$, pg_temp.f('ABC')),
  'the signed date and the term end date', 'the MSA asks its dates');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'incorporation');
select app.client_move(pg_temp.f('ABC'), pg_temp.f('UP'), 'diagnostic', 'diagnostic order signed');
select t.ok((app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 ->> 'status') = 'diagnostic', 'gates 1 and 2 done: Diagnostic');

select t.as_user(pg_temp.f('CMA'));
insert into fx select 'SD', id from (select gen_random_uuid() as id) x;
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, market_codes)
  values (pg_temp.f('SD'), pg_temp.f('ABC'), '00000000-0000-4000-8000-000000000101', 'KH26', 'Basti', '{procurement,qc,qr_activation}', '{domestic}');
select t.ok(exists (select 1 from public.scopes where id = pg_temp.f('SD') and status = 'draft'), 'Diagnostic: a draft scope may be prepared');
select t.ok(pg_temp.err(format($q$ update public.scopes set status = 'active' where id = %L $q$, pg_temp.f('SD'))) like '%client is not Active in this state (it is diagnostic)%',
            'but not activated: the server refuses it');

select t.as_user(t.u('02'));
select t.ok(not (pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'iec') ->> 'needed')::boolean
            and not (pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'rcmc') ->> 'needed')::boolean
            and not (pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'fssai') ->> 'needed')::boolean,
            'domestic only, no brand on the pack: no IEC, RCMC or FSSAI asked');
select t.as_user(pg_temp.f('CMA'));
insert into fx select 'SX', id from (select gen_random_uuid() as id) x;
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, market_codes)
  values (pg_temp.f('SX'), pg_temp.f('ABC'), '00000000-0000-4000-8000-000000000101', 'KH26', 'Bansi', '{procurement,qc,qr_activation}', '{domestic,export}');
select t.as_user(t.u('02'));
select t.ok((pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'iec') ->> 'needed')::boolean
            and (pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'rcmc') ->> 'needed')::boolean,
            'an export scope of rice: the IEC and the APEDA RCMC appear');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"brand_on_pack":true}');
select t.ok((pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'fssai') ->> 'needed')::boolean, 'its name on the pack: the FSSAI licence is asked');
select t.fails(format($q$ select app.client_kyc(%L, '00000000-0000-4000-8000-000000000001') $q$, pg_temp.f('ABC')),
  'KYC: first the gates'' items: msa, consent_addendum, signatory_authority, billing, fssai, iec, rcmc', 'the KYC tick waits for the files');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'msa', '{"signed_on":"2026-10-20","term_end":"2029-10-19"}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'consent_addendum', '{"signed_on":"2026-10-20"}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'signatory_authority');
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"billing":{"contact":"Accounts, ABC Exim","email":"accounts@abcexim.test"},
  "fssai":{"number":"10026999000001","expires_on":"2027-12-31"},"iec":"ZZZCZ0001Z","rcmc":{"number":"RCMC/APEDA/0001","expires_on":"2028-03-31"}}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'fssai', '{"expires_on":"2027-12-31"}');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'iec');
select pg_temp.doc(pg_temp.f('ABC'), pg_temp.f('UP'), 'rcmc', '{"expires_on":"2028-03-31"}');
select t.fails(format($q$ select app.client_move(%L, '00000000-0000-4000-8000-000000000001', 'active') $q$, pg_temp.f('ABC')),
  'Active needs every gate: kyc', 'Active waits for the KYC tick');
select app.client_kyc(pg_temp.f('ABC'), pg_temp.f('UP'));
select app.save_client_details(pg_temp.f('ABC'), pg_temp.f('UP'), '{"billing":{"contact":"Accounts team, ABC Exim","email":"accounts@abcexim.test"}}');
select t.ok((pg_temp.item(pg_temp.g(pg_temp.f('ABC')), 'kyc') ->> 'done') = 'false', 'a change before Active undoes the KYC tick');
select app.client_kyc(pg_temp.f('ABC'), pg_temp.f('UP'));
select t.ok((app.client_move(pg_temp.f('ABC'), pg_temp.f('UP'), 'active') ->> 'awaiting_approval')::boolean
            and (app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 ->> 'status') = 'diagnostic', 'the first Active waits for the admin''s approval');
select t.fails(format($q$ select app.decide_client_activation(%L, '00000000-0000-4000-8000-000000000001', true) $q$, pg_temp.f('ABC')),
  'approved by the admin', 'the State Manager cannot approve it');
select t.as_user(t.u('01'));
select t.ok(exists (select 1 from jsonb_array_elements(app.client_approvals()) a where (a ->> 'client_id')::uuid = pg_temp.f('ABC')), 'the admin''s queue shows it');
select t.fails(format($q$ select app.save_client_details(%L, '00000000-0000-4000-8000-000000000001', '{"billing":{"contact":"x","email":"x@y.test"}}') $q$, pg_temp.f('ABC')),
  'State Manager of this state', 'the admin fills no gate');
select app.decide_client_activation(pg_temp.f('ABC'), pg_temp.f('UP'), true, 'MSA and KYC seen');
select t.ok((app.client_view(pg_temp.f('ABC')) -> 'states' -> 0 ->> 'status') = 'active' and (select approved_at is not null from public.clients where id = pg_temp.f('ABC')),
            'approved: Active');
select t.as_user(pg_temp.f('CMA'));
select t.ok(pg_temp.err(format($q$ update public.scopes set status = 'active' where id = %L $q$, pg_temp.f('SD'))) not like '%client is not Active%',
            'Active: the scope''s activation is no longer refused for the client (its own checks follow)');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.save_client_details(%L, '00000000-0000-4000-8000-000000000001', '{"legal_name":"ABC Exim Private Ltd"}') $q$, pg_temp.f('ABC')),
  'changed by the admin', 'after Active the legal name is the admin''s');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.edit_client_identity(%L, '{"code":"ABCEX"}', 'rename the code please') $q$, pg_temp.f('ABC')),
  'once, before the client is Active', 'the code is not changed after Active');
select t.ok((app.edit_client_identity(pg_temp.f('ABC'), '{"legal_name":"ABC Exim Private Limited"}', 'name as on the certificate') ->> 'legal_name') = 'ABC Exim Private Limited',
            'the admin changes the national identity, with a reason');

-- 5 · existing clients: "PAN pending"; the code once ----------------------------------------------------------------------
select t.as_service();
select t.ok((select e.pan_pending and cs.status = 'active' and cs.legacy from public.clients c join public.entities e on e.id = c.entity_id
               join public.client_states cs on cs.client_id = c.id and cs.state_id = c.state_id
              where c.id = '00000000-0000-4000-8000-000000000201'), 'an existing test client: Active, with "PAN pending"');
select t.ok((select own_brand and legal_name = 'GrainVeda Private Limited' from public.entities e join public.clients c on c.entity_id = e.id
              where c.id = '00000000-0000-4000-8000-000000000201'), 'GrainVeda''s own client: GrainVeda Private Limited, own brand');
select t.as_user(t.u('02'));
select t.fails($q$ select app.set_client_pan('00000000-0000-4000-8000-000000000201', 'ZZZCZ0001Z', 'company') $q$,
  'belongs to another business', 'a PAN already in the registry is refused');
select t.ok((app.set_client_pan('00000000-0000-4000-8000-000000000201', 'ZZZCG0009G', 'company') ->> 'pan_pending') = 'false', 'the State Manager types the PAN once');
select t.fails($q$ select app.set_client_pan('00000000-0000-4000-8000-000000000201', 'ZZZCG0008G', 'company') $q$, 'already on file', 'and not twice');
select t.as_user(t.u('01'));
select t.ok((app.edit_client_identity(pg_temp.f('ABC2'), '{"code":"ABCLT"}', 'the client asked for this code') ->> 'code') = 'ABCLT', 'the admin edits a code before Active');
select t.fails(format($q$ select app.edit_client_identity(%L, '{"code":"ABCLM"}', 'and once more please') $q$, pg_temp.f('ABC2')),
  'once, before the client is Active', 'once');

-- 6 · who sees what --------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('SMK'));
select t.ok(not exists (select 1 from jsonb_array_elements(app.clients_page()) r where (r ->> 'client_id')::uuid = pg_temp.f('ABC')),
            'Uttarakhand''s State Manager does not list ABC Exim (it is not in his state)');
select t.as_service();
create temp table n201 as select count(*)::int as n from public.client_states where client_id = '00000000-0000-4000-8000-000000000201';
grant select on n201 to authenticated;
select t.as_user(t.u('04'));                                          -- the client's own login (client 201)
select t.ok((select array_agg(r ->> 'client_id') from jsonb_array_elements(app.clients_page()) r) = array['00000000-0000-4000-8000-000000000201'],
            'the client''s own login lists its own company only');
select t.ok(jsonb_array_length(app.client_view('00000000-0000-4000-8000-000000000201') -> 'states') = (select n from n201)
            and (app.client_view('00000000-0000-4000-8000-000000000201') #>> '{identity,pan}') is null,
            'and reads all its states, the numbers masked');
select t.fails(format($q$ select app.client_view(%L) $q$, pg_temp.f('ABC')), 'not found', 'and nothing of another client');
select t.as_user(t.u('01'));
select t.ok(jsonb_array_length(app.clients_page()) = (select count(*) from public.clients), 'the admin lists every client');
select t.as_service();
create temp table msa_path as select path as p from public.client_documents where client_id = pg_temp.f('ABC') and kind = 'msa' and superseded_at is null;
grant select on msa_path to authenticated;
select t.as_user(t.u('02'));
select t.ok(app.may_write_client_object(pg_temp.f('ABC')::text || '/' || gen_random_uuid()::text || '.pdf')
            and not app.may_write_client_object(pg_temp.f('ABC')::text || '/notes.txt'), 'the store: the State Manager uploads a PDF to the client''s folder');
select t.ok(app.may_read_client_file((select p from msa_path)), 'and reads the client''s documents');
select t.as_user(t.u('01'));
select t.ok(app.may_read_client_file((select p from msa_path)), 'the admin reads them');
select t.as_user(pg_temp.f('CMA'));
select t.ok(not app.may_write_client_object(pg_temp.f('ABC')::text || '/' || gen_random_uuid()::text || '.pdf')
            and not app.may_read_client_file((select p from msa_path)),
            'the Client Manager neither uploads nor reads the documents');
select t.as_user(t.u('04'));
select t.ok(not app.may_read_client_file((select p from msa_path)),
            'another client''s login reads none of them');
rollback;
