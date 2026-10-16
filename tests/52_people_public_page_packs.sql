-- Migration 57 (release 10; Veda, 16 Oct 2026: "G20 - NO, client info should not be shared", the public page's same-person
-- line "should not appear", "rest all ok and proceed with 57"):
--   1  G20: a Client Manager does not see a person who works now for another client (pool, People, a person's page);
--      HR does; a person shared with his own client stays, without his other client's work.
--   2  G21 and the new public page: no same_person; each step "checked" only where true; the villages by share with
--      their farmers; each market's limits; an export's country only; a pack's scans.
--   3  Shipment: the pack codes for a domestic shipment too; app.order_pack_codes; the buyer's page (e-way bill, no vehicle).
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201; 12 an operator of client 202; 16 HR.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$ select * from public.footprints where id = p $$;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 1 · G20: another client's people ---------------------------------------------------------------------------------------
set local app.change_path = 'test setup';
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status, stage_details_required, qc_report_required)
values ('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'KH26', 'Demox iso', '{procurement,qc,qr_activation}', 'draft', false, false);
select t.staff('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000312');
update public.scopes set status = 'active' where id = '00000000-0000-4000-8000-000000000499';
-- the Procurement operator of client 201 (05) is lent to client 202's scope as well
insert into public.assignments (employee_id, lens, op_role, scope_id, stages)
values (t.u('05'), 'scope', 'operator', '00000000-0000-4000-8000-000000000499', '{procurement}');
select t.as_user(t.u('03'));
create temp table pool as select x from jsonb_array_elements(app.roster_pool('00000000-0000-4000-8000-000000000401')) x;
grant select, delete, insert on pool to authenticated;
select t.ok(not exists (select 1 from pool where x->>'id' = t.u('12')::text), 'the pool: a person who works now for another client is not offered');
select t.ok(not exists (select 1 from public.app_users where id = t.u('12')) and not exists (select 1 from public.employee_org where employee_id = t.u('12'))
            and not exists (select 1 from jsonb_array_elements(app.people_directory()) p where p->>'id' = t.u('12')::text),
            'People: not his name, not his record, not his directory line');
select t.fails(format('select app.employee_profile(%L)', t.u('12')), 'person not found', 'his page: not found');
select t.ok((select jsonb_array_length(x->'elsewhere') >= 1
                    and not exists (select 1 from jsonb_array_elements(x->'elsewhere') e where e->>'scope_id' = '00000000-0000-4000-8000-000000000499' or e ? 'other_client')
               from pool where x->>'id' = t.u('05')::text),
            'a person shared with his own client stays in the pool, with his own client''s work only (not the other client''s)');
select t.ok(not exists (select 1 from jsonb_array_elements(app.people_directory()) p where (p->>'elsewhere')::int > 0)
            and (app.employee_profile(t.u('05'))->>'elsewhere')::int = 0,
            'no count of work elsewhere for a Client Manager (it said there is another client)');
select t.as_user(t.u('16'));
select t.ok(exists (select 1 from jsonb_array_elements(app.people_directory()) p where p->>'id' = t.u('12')::text)
            and (select (p->>'elsewhere')::int from jsonb_array_elements(app.people_directory()) p where p->>'id' = t.u('05')::text) = 0
            and exists (select 1 from jsonb_array_elements(app.employee_profile(t.u('05'))->'assignments') a where a->>'scope_id' = '00000000-0000-4000-8000-000000000499'),
            'HR sees everyone and their work (HR staffs across clients)');
-- when his work for the other client ends, he is in the pool of the state again
select t.as_service();
update public.assignments set active = false where employee_id = t.u('12') and scope_id = '00000000-0000-4000-8000-000000000499';
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.roster_pool('00000000-0000-4000-8000-000000000401')) x where x->>'id' = t.u('12')::text),
            'once his work there ends, the free person of the state is offered again');
select t.as_service();
delete from public.assignments where employee_id = t.u('05') and scope_id = '00000000-0000-4000-8000-000000000499';

-- 2 · the chain to a sealed export lot and a domestic shipment --------------------------------------------------------
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.buyers (client_id, name, country, address, importer_id) values ('00000000-0000-4000-8000-000000000201', 'Amira Foods BV', 'NL', 'Keizersgracht 1, Amsterdam', 'NL-IMP-77') returning id) insert into fx select 'BUYEU', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.market_profiles (crop_id, code, name, version, status, params, export_docs, created_by)
           values ('00000000-0000-4000-8000-000000000101', 'eu', 'EU', 1, 'active', '[{"param":"aflatoxin_ppb","operator":"<=","limit":2}]',
                   '{"Phytosanitary certificate","Health certificate"}', t.u('02')) returning id) insert into fx select 'EU', id from r;
select t.as_user(t.u('03'));
update public.scopes set market_codes = '{domestic,export,eu}' where id = t.scope('05');
select t.as_service();
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2,"aflatoxin_ppb":1}}');
select t.as_service(); select t.attach(pg_temp.f('Q'), 'lab_report');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":150,"broken_kg":10,"husk_kg":30,"bran_kg":9}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":150,"packets":[{"sku_id":"%s","units":150,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true, record_price = true where id = t.scope('05');
select t.as_user(t.u('11'));
insert into fx select 'D', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-101","packs":[{"sku_id":"%s","units":30}],"price_per_kg":120,"currency":"INR"}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
insert into fx select 'E', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"export","market_code":"eu","destination_country":"Netherlands","order_no":"EX-77","packs":[{"sku_id":"%s","units":40}],"price_per_kg":2.5,"currency":"USD","incoterms":"FOB"}',
         pg_temp.f('BUYEU'), pg_temp.f('SKU1'))::jsonb);
select t.as_service(); select t.attach(pg_temp.f('E'), 'export_doc');
select t.as_user(t.u('11'));
select app.set_export_doc(pg_temp.f('E'), 'Phytosanitary certificate', 'received', (select id from public.attachments where footprint_id = pg_temp.f('E') and label = 'export_doc' limit 1));
select app.set_export_doc(pg_temp.f('E'), 'Health certificate', 'not_required', null, 'the buyer waives it in the contract');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D')); select app.verify_footprint(pg_temp.f('E'));
select t.as_service();
create temp table ser as select (select array_agg(serial order by serial) from (select serial from public.packs where footprint_id = (select id from fx where k = 'K') order by serial limit 40) x) as e,
                                (select array_agg(serial order by serial) from (select serial from public.packs where footprint_id = (select id from fx where k = 'K') order by serial offset 40 limit 30) x) as d;
grant select on ser to authenticated, anon;

-- 3 · Shipment: the pack codes ------------------------------------------------------------------------------------------
select t.as_user(t.u('14'));
create temp table oc as select app.order_pack_codes(pg_temp.f('D')) as j;
grant select on oc to authenticated;
select t.ok((select jsonb_array_length(j) = 150 and not exists (select 1 from jsonb_array_elements(j) p where p->>'shipped_in' is not null or (p->>'void')::boolean)
                    and (select p->>'sku' from jsonb_array_elements(j) p limit 1) is not null from oc),
            'the order''s packs, for the phone to check each code: all 150 of its batch, none shipped, none void, each with its pack type');
select t.fails(format($q$select pg_temp.ins(%L, 'shipment', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('D'), t.u('14'),
  format('{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":30}]}', pg_temp.f('SKU1'))),
  'scan or type the codes of the packs loaded', 'a domestic shipment of packs: the codes loaded are asked');
select t.fails(format($q$select pg_temp.ins(%L, 'shipment', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('D'), t.u('14'),
  format('{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","serials":null,"packs":[{"sku_id":"%s","units":30}]}', pg_temp.f('SKU1'))),
  'scan or type the codes of the packs loaded', 'codes sent as nothing at all: asked, in plain words');
insert into fx select 'SD', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('D'), t.u('14'),
  format('{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","transporter":"Basti Roadways","driver_phone":"9839012345","lr_no":"LR-1","eway_bill_no":"123456789012","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":30}]}', pg_temp.f('SKU1'))::jsonb
  || jsonb_build_object('serials', to_jsonb((select d from ser))));
select t.ok((pg_temp.fp(pg_temp.f('SD'))).computed @> '{"market": "domestic", "serials_count": 30}', 'with its 30 codes the domestic shipment is saved');
select t.ok((select count(*) = 30 and bool_and(p->>'shipped_in' = (pg_temp.fp(pg_temp.f('SD'))).footprint_code)
               from jsonb_array_elements(app.order_pack_codes(pg_temp.f('E'))) p where p->>'shipped_in' is not null),
            'another order of the same batch sees those 30 as shipped, in which shipment');
select t.ok(not exists (select 1 from jsonb_array_elements(app.order_pack_codes(pg_temp.f('D'), pg_temp.f('SD'))) p where p->>'shipped_in' is not null),
            'a correction of that shipment does not count its own codes as shipped');
select t.fails(format('select app.order_pack_codes(%L)', pg_temp.f('K')), 'record not found', 'only of an order (a sale)');
select t.as_user(t.u('12'));
select t.fails(format('select app.order_pack_codes(%L)', pg_temp.f('D')), 'record not found', 'another client''s person: not found');
select t.fails(format('select app.order_pack_codes(%L)', gen_random_uuid()), 'record not found', 'the same answer as for an unknown record');
select t.as_user(t.u('14'));
insert into fx select 'SE', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('E'), t.u('14'),
  jsonb_build_object('invoice_no', 'EXP-1', 'container_no', 'MSKU1234567', 'seal_no', 'SL-9911', 'shipping_bill_no', '1234567', 'dispatch_date', '2026-10-16',
                     'destination', 'Rotterdam port, berth 7', 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', 40)), 'serials', to_jsonb((select e from ser))));
-- the buyer's page: a domestic shipment's e-way bill and lorry receipt, not the vehicle (nor the driver)
select t.as_service();
select t.ok((select s->>'eway_bill_no' = '123456789012' and s->>'lr_no' = 'LR-1' and not (s ? 'vehicle_no') and not (s ? 'driver_phone')
               from jsonb_array_elements(app.buyer_content(pg_temp.f('SD'))->'shipments') s),
            'the buyer''s page of a domestic shipment: the e-way bill and the LR, no vehicle number, no driver''s phone');

-- 4 · Sealed: the public page ------------------------------------------------------------------------------------------
select t.attach(pg_temp.f('SE'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('SE'));
insert into fx select 'QR', pg_temp.ins(t.scope('05'), 'qr_activation', pg_temp.f('SE'), t.u('07'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('QR'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_anon();
create temp table pj as select app.public_lot_journey((select code from seal)) as j;
select t.ok((select not (j ? 'same_person') from pj), 'G21: the public data never says one person recorded and checked a step');
select t.ok((select bool_and((e->>'checked')::boolean) filter (where e->>'stage' in ('procurement', 'qc', 'milling', 'packing', 'commercial', 'shipment'))
                    and bool_and(not (e->>'checked')::boolean) filter (where e->>'stage' = 'qr_activation')
               from pj, jsonb_array_elements(j->'journey') e),
            'each step says it was checked by another person (here all were); the seal is the last step');
select t.ok((select jsonb_array_length(j->'villages') = 1 and (j->'villages'->0->>'share_pct')::numeric = 100 and (j->'villages'->0->>'farmers')::int = 1
                    and j->'villages'->0->>'village' is not null and not (j->'villages'->0 ? 'name') from pj),
            'the villages by share, with how many farmers (no name)');
select t.ok((select e->>'destination' = 'Netherlands' and e->>'dispatched_on' = '2026-10-16' from pj, jsonb_array_elements(j->'journey') e where e->>'stage' = 'shipment')
            and (select position('berth 7' in j::text) = 0 from pj),
            'an export: the country of the order, not the place typed on the shipment');
select t.ok((select m->'limits' @> '[{"param": "aflatoxin_ppb", "operator": "<=", "limit": 2}]'
               from pj, jsonb_array_elements(j->'journey') e, jsonb_array_elements(e->'markets') m where e->>'stage' = 'qc' and m->>'name' = 'EU'),
            'each market''s limits beside the lab readings');
select t.ok((select position('9839012345' in j::text) = 0 and position('UP53AB1234' in j::text) = 0 and position('Amira' in j::text) = 0 from pj),
            'nothing of the papers, the driver or the buyer');
-- a pack's scans
select app.record_scan_at((select e[1] from ser), 'Gorakhpur', 'UP', 'IN', 26.76, 83.37);
select app.record_scan_at((select e[1] from ser), 'Lucknow', 'UP', 'IN', 26.85, 80.95);
select app.record_scan_at((select e[1] from ser));
select t.ok((select p->'pack'->'scans' = '{"n": 3, "first_city": "Gorakhpur", "first_country": "IN"}'::jsonb from (select app.public_pack((select e[1] from ser)) p) x),
            'a pack: how often it was scanned and the first place (a city, nothing about anyone)');
select t.ok((select (p->'pack'->'scans'->>'n')::int = 0 and p->'pack'->'scans'->>'first_city' is null from (select app.public_pack((select e[2] from ser)) p) x),
            'a pack never scanned: none');
-- a lot where one person recorded and checked a step: not said, and that step is not marked checked
select t.as_service();
set local session_replication_role = replica;   -- the test only: past the record's guards
update public.footprints set verified_by = created_by where id = pg_temp.f('M');
set local session_replication_role = origin;
select t.as_anon();
select t.ok((select not (j ? 'same_person') and not (j->>'independent')::boolean
                    and (select not (e->>'checked')::boolean from jsonb_array_elements(j->'journey') e where e->>'stage' = 'milling')
                    and (select (e->>'checked')::boolean from jsonb_array_elements(j->'journey') e where e->>'stage' = 'packing')
               from (select app.public_lot_journey((select code from seal)) j) x),
            'one person recorded and checked the milling: the page is not told so; only that step is not marked checked');
rollback;
