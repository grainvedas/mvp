-- Migration 54 (Veda, 16 Oct 2026: release 7 of the operator-stages plan and her four points): villages from the list, the
-- Collection Batch's collection point, the client's own labs, C7 Commercial, C8 Shipment, the faults of release 6.
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). Scope 06 (Bansi batch): Procurement (05) → Collection Batch (15) → QC (06) → QR (07). 03 the Client Manager of
-- client 201, 02 the State Manager of Uttar Pradesh. Kalanamak rice is crop 101.
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
create or replace function pg_temp.n(p_sql text) returns bigint language plpgsql as $$ declare r bigint; begin execute p_sql into r; return r; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
-- the lists: buyers, packs, a collection point, the EU and UAE profiles (the UAE stricter on aflatoxin)
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.buyers (client_id, name, country, address, importer_id) values ('00000000-0000-4000-8000-000000000201', 'Amira Foods BV', 'NL', 'Keizersgracht 1, Amsterdam', 'NL-IMP-77') returning id) insert into fx select 'BUYEU', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000202', 'Not our buyer', 'IN', 'Gorakhpur road, Basti', '09AAACN1234E1Z5') returning id) insert into fx select 'XBUY', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 500, 'g', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU500', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 5, 'kg', 'jute', 'domestic', 'sticker') returning id) insert into fx select 'SKU5', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'Bansi centre', 'centre', 'Siddharthnagar') returning id) insert into fx select 'CP', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'Itwa field point', 'field_point', 'Siddharthnagar') returning id) insert into fx select 'CP2', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000202', 'Not our point', 'centre', 'Siddharthnagar') returning id) insert into fx select 'XCP', id from r;
with r as (insert into public.market_profiles (crop_id, code, name, version, status, params, export_docs, created_by)
           values ('00000000-0000-4000-8000-000000000101', 'eu', 'EU', 1, 'active', '[{"param":"aflatoxin_ppb","operator":"<=","limit":2}]',
                   '{"Phytosanitary certificate","Health certificate"}', t.u('02')) returning id) insert into fx select 'EU', id from r;
with r as (insert into public.market_profiles (crop_id, code, name, version, status, params, created_by)
           values ('00000000-0000-4000-8000-000000000101', 'uae', 'UAE', 1, 'active', '[{"param":"aflatoxin_ppb","operator":"<=","limit":0.5}]', t.u('02')) returning id) insert into fx select 'UAE', id from r;

-- 1 · Labs: the client's own beside the state's ------------------------------------------------------------------------
select t.as_user(t.u('03'));
with r as (insert into public.labs (client_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000201', 'Our contract lab', 'TC-5555', 'external', 'Gorakhpur') returning id)
  insert into fx select 'CLAB', id from r;
select t.as_service();
select t.ok((select state_id = '00000000-0000-4000-8000-000000000001' from public.labs where id = pg_temp.f('CLAB')), 'the Client Manager adds a lab of his client; it takes the client''s state');
select t.as_user(t.u('03'));
select t.fails($$insert into public.labs (state_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000001', 'A state lab', 'TC-1', 'external', 'Lucknow')$$,
               'row-level security', 'the state''s list stays the State Manager''s');
select t.as_user(t.u('06'));
select t.fails($$insert into public.labs (client_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000201', 'QC''s own', 'TC-2', 'external', 'Basti')$$,
               'row-level security', 'an operator does not add labs');
select t.as_user(t.u('02'));
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000001', 'State test lab', 'TC-7777', 'external', 'Lucknow') returning id)
  insert into fx select 'SLAB', id from r;
select t.as_service();
with r as (insert into public.labs (client_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000202', 'Their lab', 'TC-8888', 'external', 'Basti') returning id)
  insert into fx select 'XLAB', id from r;
select t.ok(app.lab_for_scope(pg_temp.f('CLAB'), t.scope('05')) and app.lab_for_scope(pg_temp.f('SLAB'), t.scope('05')) and not app.lab_for_scope(pg_temp.f('XLAB'), t.scope('05')),
            'QC may send to the state''s labs and the client''s own, not another client''s');
select t.as_user(t.u('03'));
select t.fails(format($$update public.labs set client_id = null where id = %L$$, pg_temp.f('CLAB')), 'stays with whoever keeps it', 'a client''s lab does not become the state''s');

-- 2 · Villages from the list ---------------------------------------------------------------------------------------------
select t.as_user(t.u('05'));
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000201', 'Typed Village', 'Father', 'Bansi Nayi Basti', 'Siddharthnagar', '+919870054001', 2, 1, 27.2, 83.0) returning id) insert into fx select 'F1', id from r;
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, block, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000201', 'Listed Village', 'Father', 'itwa', 'Siddharthnagar', 'Bansi', '+919870054002', 2, 1, 27.2, 83.0) returning id) insert into fx select 'F2', id from r;
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, block, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000201', 'Wrong Block', 'Father', 'Itwa', 'Siddharthnagar', 'Domariyaganj', '+919870054003', 2, 1, 27.2, 83.0) returning id) insert into fx select 'F3', id from r;
select t.as_user(t.u('03'));
select t.fails(format($$select app.submit_farmer(%L)$$, pg_temp.f('F1')), 'is not on the list of district', 'a village typed but not on the list: the farmer is not verified');
select t.fails(format($$select app.submit_farmer(%L)$$, pg_temp.f('F3')), 'is not on the list of district', 'the village is of its block');
select app.submit_farmer(pg_temp.f('F2'));
select t.ok((select status from public.farmers where id = pg_temp.f('F2')) = 'under_review', 'a village on the list (however it is written) passes');
select app.add_place('00000000-0000-4000-8000-000000000001', 'Siddharthnagar', 'Bansi', 'Bansi Nayi Basti');
select app.submit_farmer(pg_temp.f('F1'));
select t.ok((select status from public.farmers where id = pg_temp.f('F1')) = 'under_review', 'once the Client Manager has added it to the list, it passes');

-- 3 · The Collection Batch names its collection point ----------------------------------------------------------------
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true where id = t.scope('06');
select t.as_service();
create or replace function pg_temp.lot(p_farmer uuid, p_cp text) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (t.scope('06'), '00000000-0000-4000-8000-000000000201', 'procurement', p_farmer, t.u('05'),
          jsonb_build_object('gross_kg', 104, 'bags', 2, 'tare_kg_per_bag', 2, 'moisture_pct', jsonb_build_array(12, 12, 12))
          || case when p_cp is null then '{}'::jsonb else jsonb_build_object('collection_point_id', p_cp) end) returning id into v;
  return v;
end $$;
grant execute on function pg_temp.lot(uuid, text) to authenticated;
select t.as_user(t.u('05'));
insert into fx select 'B1', pg_temp.lot(t.farmer('05'), pg_temp.f('CP')::text);
insert into fx select 'B2', pg_temp.lot(t.farmer('04'), pg_temp.f('CP')::text);
insert into fx select 'B3', pg_temp.lot(t.farmer('05'), 'farm');
select t.as_user(t.u('15'));
select app.verify_footprint(pg_temp.f('B1')); select app.verify_footprint(pg_temp.f('B2')); select app.verify_footprint(pg_temp.f('B3'));
select t.fails(format($$select pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B1'), t.u('15'), '{"source_footprint_ids":["%s","%s"]}')$$, pg_temp.f('B1'), pg_temp.f('B2')),
               'choose the collection point', 'the batch names its collection point (the scope asks the details)');
select t.fails(format($$select pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B1'), t.u('15'), '{"collection_point_id":"%s","source_footprint_ids":["%s","%s"]}')$$, pg_temp.f('XCP'), pg_temp.f('B1'), pg_temp.f('B2')),
               'not one of this client''s active points', 'another client''s point is refused');
select t.fails(format($$select pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B1'), t.u('15'), '{"collection_point_id":"%s","source_footprint_ids":["%s","%s"]}')$$, pg_temp.f('CP2'), pg_temp.f('B1'), pg_temp.f('B2')),
               'not weighed at this collection point', 'its lots are the point''s it names');
select t.fails(format($$select pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B1'), t.u('15'), '{"collection_point_id":"farm","source_footprint_ids":["%s"]}')$$, pg_temp.f('B1')),
               'not weighed at this collection point', 'a lot weighed at a point is not batched "at the farm"');
insert into fx select 'VB', pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B1'), t.u('15'),
  format('{"collection_point_id":"%s","source_footprint_ids":["%s","%s"]}', pg_temp.f('CP'), pg_temp.f('B1'), pg_temp.f('B2'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('VB'))).computed->>'collection_point' = 'Bansi centre' and (pg_temp.fp(pg_temp.f('VB'))).qty_out = 200,
            'the batch of the point it names: its name on the record');
select t.ok(exists (select 1 from jsonb_array_elements(app.system_checks(pg_temp.f('VB'))) x where x->>'key' = 'villages_from_lots' and (x->>'ok')::boolean)
            and not exists (select 1 from jsonb_array_elements(app.system_checks(pg_temp.f('VB'))) x where x->>'key' = 'village_named'),
            'the system check: villages taken from the lots (no more "village named": found in release 6''s checks)');
insert into fx select 'VBF', pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('B3'), t.u('15'), format('{"collection_point_id":"farm","source_footprint_ids":["%s"]}', pg_temp.f('B3'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('VBF'))).computed->>'collection_point' = 'farm', 'lots weighed at the farm make a batch "at the farm"');
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = false where id = t.scope('06');

-- 4 · The chain to the packs (scope 05; the details asked from Commercial on) -----------------------------------------
select t.as_user(t.u('03'));
update public.scopes set market_codes = '{domestic,export,eu,uae}' where id = t.scope('05');
select t.as_service();
select t.ok(exists (select 1 from jsonb_array_elements(app.scope_test_params(t.scope('05'))) x
                     where x->>'param' = 'aflatoxin_ppb' and x->'limits' @> '[{"market": "EU", "operator": "<=", "limit": 2}, {"market": "UAE", "operator": "<=", "limit": 0.5}]'),
            'a market profile''s own test carries its limits for the form (no more "<= undefined": found in release 6''s checks)');
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);                -- 200 kg
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2,"aflatoxin_ppb":1}}');
select t.ok((select string_agg(code || '=' || verdict, ',' order by code) from public.qc_profile_verdicts where footprint_id = pg_temp.f('Q'))
            = 'domestic=pass,eu=pass,export=pass,uae=fail', 'QC: Domestic, Export and EU pass, the UAE (aflatoxin 0.5) fails');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":150,"broken_kg":10,"husk_kg":30,"bran_kg":9}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":150,"packets":[{"sku_id":"%s","units":130,"size_kg":1},{"sku_id":"%s","units":30,"size_kg":0.5}],"wastage_reason":"jammed roll, swept"}', pg_temp.f('SKU1'), pg_temp.f('SKU500'))::jsonb);
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
select t.ok((select jsonb_agg(x->>'left' order by x->>'size_kg' desc) from jsonb_array_elements(app.packs_left(pg_temp.f('K'))) x) = '["130", "30"]'::jsonb,
            'what is left of the packs, per pack type');
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true, record_price = true where id = t.scope('05');

-- 5 · C7 Commercial ------------------------------------------------------------------------------------------------------
select t.as_user(t.u('11'));
create or replace function pg_temp.sale(p jsonb) returns uuid language sql as $$ select pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'), p) $$;
grant execute on function pg_temp.sale(jsonb) to authenticated;
select t.fails(format($$select pg_temp.sale('{"buyer":"Typed Buyer","market":"domestic","order_no":"PO-1","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('SKU1')),
               'choose the buyer from the client''s list', 'the buyer is from the client''s list');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-1","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('XBUY'), pg_temp.f('SKU1')),
               'not one of this client''s active buyers', 'another client''s buyer is refused');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('BUY'), pg_temp.f('SKU1')),
               'give the order or contract number', 'the order number is asked');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-1","qty_kg":10}')$$, pg_temp.f('BUY')),
               'choose the packs', 'packs by type where the batch was packed from the pack list');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-1","packs":[{"sku_id":"%s","units":200}]}')$$, pg_temp.f('BUY'), pg_temp.f('SKU1')),
               'only 130 packs of 1 kg pouch are left', 'no more packs than are left');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-1","packs":[{"sku_id":"%s","units":2}]}')$$, pg_temp.f('BUY'), pg_temp.f('SKU5')),
               'not in this lot', 'a pack type the batch has not');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-1","packs":[{"sku_id":"%s","units":2.5}]}')$$, pg_temp.f('BUY'), pg_temp.f('SKU1')),
               'whole number', 'whole packs');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"export","order_no":"EX-1","destination_country":"UAE","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('BUYEU'), pg_temp.f('SKU1')),
               'choose the export market', 'an export sale names its market''s profile');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"export","market_code":"uae","order_no":"EX-1","destination_country":"UAE","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('BUYEU'), pg_temp.f('SKU1')),
               'has not passed QC for UAE', 'only to a market whose profile the batch passed');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"export","market_code":"eu","order_no":"EX-1","packs":[{"sku_id":"%s","units":10}]}')$$, pg_temp.f('BUYEU'), pg_temp.f('SKU1')),
               'name the destination country', 'the destination country is asked');
insert into fx select 'D', pg_temp.sale(format('{"buyer_id":"%s","market":"domestic","order_no":"PO-101","sale_route":"own_brand","packs":[{"sku_id":"%s","units":30},{"sku_id":"%s","units":4}],"price_per_kg":120,"currency":"INR"}',
  pg_temp.f('BUY'), pg_temp.f('SKU1'), pg_temp.f('SKU500'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('D'))).qty_out = 32 and (pg_temp.fp(pg_temp.f('D'))).computed @> '{"buyer": "Delhi Wholesale", "order_no": "PO-101", "market": "domestic", "sale_route": "own_brand"}'
            and jsonb_array_length((pg_temp.fp(pg_temp.f('D'))).computed->'packs') = 2, 'a domestic order: the buyer''s name, the packs by type, the kilograms worked out (30 × 1 kg + 4 × 500 g)');
select t.ok(not ((pg_temp.fp(pg_temp.f('D'))).payload ? 'price_per_kg') and not exists (select 1 from public.ledger where payload::text ilike '%price_per_kg%')
            and (select total_value = 3840 and currency = 'INR' from public.sale_terms where footprint_id = pg_temp.f('D')),
            'the price is kept apart (never in the record or its ledger block); the total value worked out');
insert into fx select 'E', pg_temp.sale(format('{"buyer_id":"%s","market":"export","market_code":"eu","destination_country":"Netherlands","order_no":"EX-77","packs":[{"sku_id":"%s","units":40}],"price_per_kg":2.5,"currency":"USD","incoterms":"FOB"}',
  pg_temp.f('BUYEU'), pg_temp.f('SKU1'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('E'))).computed @> '{"market_code": "eu", "market_name": "EU", "destination_country": "Netherlands", "buyer_country": "NL"}',
            'an export order: its profile, the destination');
select t.ok((select jsonb_agg(x->>'left' order by x->>'size_kg' desc) from jsonb_array_elements(app.packs_left(pg_temp.f('K'))) x) = '["60", "26"]'::jsonb,
            'the batch shows what is left after the two orders');
select t.fails(format($$select pg_temp.sale('{"buyer_id":"%s","market":"domestic","order_no":"PO-2","packs":[{"sku_id":"%s","units":61}]}')$$, pg_temp.f('BUY'), pg_temp.f('SKU1')),
               'only 60 packs', 'a third order: no more than is left');
select t.fails($$select pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'), '{"input_kg":1,"packets":[{"units":1,"size_kg":1}],"price_per_kg":5}')$$,
               'recorded at Commercial', 'a price is recorded at Commercial only');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.sale_terms where footprint_id in (pg_temp.f('D'), pg_temp.f('E'))) = 2, 'the Client Manager reads the sale terms');
select t.ok((app.footprint_detail(pg_temp.f('E'))->'sale_terms'->>'incoterms') = 'FOB', 'on the record page too');
select t.as_user(t.u('14'));
select t.ok((select count(*) from public.sale_terms) = 0 and app.footprint_detail(pg_temp.f('E'))->'sale_terms' = 'null'::jsonb, 'Shipment does not read the price');
select t.as_user(t.u('11'));
select t.ok(exists (select 1 from jsonb_array_elements(app.system_checks(pg_temp.f('D'))) x where x->>'key' = 'buyer_market' and (x->>'ok')::boolean),
            'the system check reads the buyer from the list');

-- the export documents
select t.ok((select string_agg(x->>'doc', ',') from jsonb_array_elements(app.footprint_detail(pg_temp.f('E'))->'export_docs') x) = 'Phytosanitary certificate,Health certificate'
            and app.footprint_detail(pg_temp.f('D'))->'export_docs' = 'null'::jsonb, 'the export documents come from the market profile (none for domestic)');
select t.ok(exists (select 1 from jsonb_array_elements(app.system_checks(pg_temp.f('E'))) x where x->>'key' = 'export_docs' and not (x->>'ok')::boolean),
            'the system check: documents still to come');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D')); select app.verify_footprint(pg_temp.f('E'));
select t.fails(format($$select app.set_export_doc(%L, 'Health certificate', 'applied')$$, pg_temp.f('E')), 'kept by Commercial', 'Shipment does not keep the documents');
create or replace function pg_temp.ship(p_from uuid, p jsonb) returns uuid language sql as $$ select pg_temp.ins(t.scope('05'), 'shipment', p_from, t.u('14'), p) $$;
grant execute on function pg_temp.ship(uuid, jsonb) to authenticated;
select t.as_service();
create temp table ser as select array_agg(serial order by serial) as s from (select serial from public.packs where footprint_id = (select id from fx where k = 'K') and sku_id = (select id from fx where k = 'SKU1') order by serial limit 40) x;
insert into public.packs (serial, batch_code, footprint_id, scope_id, size_kg, packed_on, sku_id)        -- a real pack of another batch
  select 'OTHER-BATCH-0001', batch_code, pg_temp.f('P'), scope_id, size_kg, packed_on, sku_id from public.packs where serial = (select s[40] from ser);
grant select on ser to authenticated;
select t.as_user(t.u('14'));
create or replace function pg_temp.export_ship(p_serials text[]) returns jsonb language sql stable as $$
  select jsonb_build_object('invoice_no', 'EXP-1', 'container_no', 'MSKU 123456-7', 'seal_no', 'SL-9911', 'shipping_bill_no', '1234567', 'dispatch_date', to_char(now(), 'YYYY-MM-DD'),
                            'destination', 'Rotterdam', 'packs', jsonb_build_array(jsonb_build_object('sku_id', (select id from fx where k = 'SKU1'), 'units', 40)),
                            'serials', to_jsonb(p_serials)) $$;
grant execute on function pg_temp.export_ship(text[]) to authenticated;
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s from ser)))$$, pg_temp.f('E')),
               'export documents of order', 'an export shipment waits for the documents');
select t.as_user(t.u('11'));
select t.fails(format($$select app.set_export_doc(%L, 'Health certificate', 'received')$$, pg_temp.f('E')), 'has its file', 'a received document has its file');
select t.fails(format($$select app.set_export_doc(%L, 'Health certificate', 'not_required', null, 'no')$$, pg_temp.f('E')), 'say why', 'not required: say why');
select t.fails(format($$select app.set_export_doc(%L, 'Fumigation certificate', 'applied')$$, pg_temp.f('E')), 'not on the list', 'only the market''s documents');
select t.as_service(); select t.attach(pg_temp.f('E'), 'export_doc');
select t.as_user(t.u('11'));
select app.set_export_doc(pg_temp.f('E'), 'Phytosanitary certificate', 'applied');
select app.set_export_doc(pg_temp.f('E'), 'Health certificate', 'not_required', null, 'the buyer waives it in the contract');
select t.as_user(t.u('14'));
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s from ser)))$$, pg_temp.f('E')),
               'Phytosanitary certificate', 'applied for is not enough: named in the refusal');
select t.as_user(t.u('11'));
select app.set_export_doc(pg_temp.f('E'), 'Phytosanitary certificate', 'received', (select id from public.attachments where footprint_id = pg_temp.f('E') and label = 'export_doc' limit 1));
select t.ok(exists (select 1 from jsonb_array_elements(app.system_checks(pg_temp.f('E'))) x where x->>'key' = 'export_docs' and (x->>'ok')::boolean)
            and (select count(*) from public.export_documents where footprint_id = pg_temp.f('E')) = 2, 'then the documents are complete');

-- 6 · C8 Shipment --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('14'));
select t.fails(format($$select pg_temp.ship(%L, '{"vehicle_no":"UP53AB1234","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":20}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'give the invoice number', 'the invoice number is asked');
select t.fails(format($$select pg_temp.ship(%L, '{"invoice_no":"INV-1","vehicle_no":"UP 53","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":20}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'vehicle number reads like', 'the vehicle number''s format');
select t.fails(format($$select pg_temp.ship(%L, '{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":20}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'LR (lorry receipt)', 'domestic: the LR number');
select t.fails(format($$select pg_temp.ship(%L, '{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","lr_no":"LR-1","eway_bill_no":"12345","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":20}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'e-way bill number is 12 digits', 'the e-way bill''s format');
select t.fails(format($$select pg_temp.ship(%L, '{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":31}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'only 30 packs', 'no more than the order');
insert into fx select 'SD1', pg_temp.ship(pg_temp.f('D'), format('{"invoice_no":"INV-1","vehicle_no":"up-53 ab 1234","transporter":"Basti Roadways","driver_phone":"98390 12345","lr_no":"LR-1","eway_bill_no":"1234 5678 9012","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":20}]}', pg_temp.f('SKU1'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('SD1'))).qty_out = 20 and (pg_temp.fp(pg_temp.f('SD1'))).computed @> '{"market": "domestic", "invoice_no": "INV-1"}', 'a partial domestic shipment: 20 of the order''s packs');
insert into fx select 'SD2', pg_temp.ship(pg_temp.f('D'), format('{"invoice_no":"INV-2","vehicle_no":"UP53AB1235","lr_no":"LR-2","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":10},{"sku_id":"%s","units":4}]}', pg_temp.f('SKU1'), pg_temp.f('SKU500'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('SD2'))).qty_out = 12 and app.available_qty(pg_temp.f('D')) = 0, 'the rest of the order in a second shipment');
select t.fails(format($$select pg_temp.ship(%L, '{"invoice_no":"INV-3","vehicle_no":"UP53AB1236","lr_no":"LR-3","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":1}]}')$$, pg_temp.f('D'), pg_temp.f('SKU1')),
               'is closed', 'nothing more of a shipped order (it closes when all of it is shipped)');
-- export
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s from ser)) || '{"container_no":"MSK1234"}')$$, pg_temp.f('E')),
               '4 letters and 7 digits', 'the container number''s format');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s from ser)) - 'seal_no')$$, pg_temp.f('E')),
               'container seal number', 'the seal number');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s from ser)) - 'shipping_bill_no')$$, pg_temp.f('E')),
               'shipping bill number', 'the shipping bill');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship('{}'))$$, pg_temp.f('E')),
               'scan or type the codes', 'export: the packs loaded are scanned');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s[1:39] || s[1] from ser)))$$, pg_temp.f('E')),
               'there twice', 'a code scanned twice');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s[1:39] || 'NOT-A-PACK'::text from ser)))$$, pg_temp.f('E')),
               'not a pack of this order''s batch', 'a code that is not of the batch');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s[1:39] || 'OTHER-BATCH-0001'::text from ser)))$$, pg_temp.f('E')),
               'not a pack of this order''s batch', 'a real pack of another batch is refused');
select t.fails(format($$select pg_temp.ship(%L, pg_temp.export_ship((select s[1:39] from ser)))$$, pg_temp.f('E')),
               'do not match the packs shipped', 'the codes match the packs shipped');
insert into fx select 'SE', pg_temp.ship(pg_temp.f('E'), pg_temp.export_ship((select s from ser)));
select t.ok((pg_temp.fp(pg_temp.f('SE'))).computed @> '{"market": "export", "serials_count": 40, "container_no": "MSKU1234567", "bl_pending": true}',
            'the export shipment: its 40 pack codes, the container, "BL pending"');
-- the release stage verifies it once its loading photo is there
select t.as_user(t.u('07'));
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('SE')), 'loading photo', 'an export shipment is verified with its loading photo');
select t.as_service(); select t.attach(pg_temp.f('SE'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('SE'));
select t.ok((pg_temp.fp(pg_temp.f('SE'))).status = 'verified', 'with the photo it is verified');
-- the bill of lading, later
select t.as_user(t.u('11'));
select t.fails(format($$select app.add_bill_of_lading(%L, 'MAEU123456789')$$, pg_temp.f('SE')), 'not found', 'Commercial does not add it (it does not see the shipment)');
select t.as_user(t.u('14'));
select t.fails(format($$select app.add_bill_of_lading(%L, 'x')$$, pg_temp.f('SE')), '4 to 30 letters or digits', 'its format');
select app.add_bill_of_lading(pg_temp.f('SE'), 'MAEU123456789');
select t.ok((app.footprint_detail(pg_temp.f('SE'))->'bill_of_lading'->>'bl_no') = 'MAEU123456789'
            and exists (select 1 from public.ledger where footprint_id = pg_temp.f('SE') and payload->>'act' = 'bill_of_lading'), 'the bill of lading is added, in the ledger');
select t.fails(format($$select app.add_bill_of_lading(%L, 'MAEU999')$$, pg_temp.f('SE')), 'already', 'once');
select t.fails(format($$select app.add_bill_of_lading(%L, 'MAEU123456789')$$, pg_temp.f('SD1')), 'belongs to an export shipment', 'a domestic shipment has none');

-- 7 · The scope without the details: as before ----------------------------------------------------------------------
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = false where id = t.scope('05');
select t.as_user(t.u('11'));
insert into fx select 'OLD', pg_temp.sale('{"buyer":"Typed Buyer","market":"domestic","qty_kg":5}');
select t.ok((pg_temp.fp(pg_temp.f('OLD'))).computed = '{"buyer": "Typed Buyer", "market": "domestic"}'::jsonb and (pg_temp.fp(pg_temp.f('OLD'))).qty_out = 5,
            'a scope that does not ask the details sells as before (a typed buyer, kilograms)');
select t.ok((select markets ? 'export' and jsonb_array_length(profiles) = 4 from (select app.lot_markets(pg_temp.f('K')) j) x, lateral (select j->'markets' as markets, j->'profiles' as profiles) y),
            'the markets a lot can go to name its profiles');
rollback;
