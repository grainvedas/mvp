-- Migration 51 (Veda, 15 Oct 2026: the operator-stages brief, release 4: Part B set-up lists, A14, A15). Client 201
-- (Prasaadam): its Client Manager 03, Procurement 05; 02 the State Manager of Uttar Pradesh; 12 an operator of another
-- client (202). Kalanamak rice is crop 101 (GI 280).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.n(p_sql text) returns bigint language plpgsql security definer as $$
declare v bigint; begin execute p_sql into v; return v; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
-- the place everyone here works in
insert into fx select 'UP', id from public.states where code = 'UP';
insert into fx select 'AS', id from public.states where code = 'AS';

-- 1 · Places ------------------------------------------------------------------------------------------------------------
select t.ok((select count(*) from public.places where state_id = pg_temp.f('UP') and block is null) = 75, 'Uttar Pradesh has its 75 districts on the list');
select t.ok(not exists (select 1 from public.places where state_id = pg_temp.f('AS')), 'a state with no list (Assam) has none: what is typed is accepted there');
insert into public.states (name, code) values ('Uttar Pradesh', 'UPX') returning id as x \gset
select t.ok((select count(*) from public.places where state_id = :'x') = 75, 'a state of that name made later (a fresh start) gets the list too');
select t.as_user(t.u('03'));
select app.add_place(pg_temp.f('UP'), 'siddharth nagar', 'Bansi', 'Itwa');
select t.ok((select count(*) from public.places where state_id = pg_temp.f('UP') and district = 'Siddharthnagar' and block = 'Bansi') = 2,
            'the Client Manager adds a block and a village to a listed district (written differently, it is the same district)');
select app.add_place(pg_temp.f('UP'), 'Siddharthnagar', ' bansi ', 'ITWA');
select t.ok((select count(*) from public.places where state_id = pg_temp.f('UP') and district = 'Siddharthnagar' and block is not null) = 2, 'the same village twice is one place');
select t.fails($$select app.add_place((select id from public.states where code = 'UP'), 'Nowhere', 'B', 'V')$$, 'not on the list', 'a district not on the list is not added by the Client Manager');
select t.as_user(t.u('12'));
select t.fails($$select app.add_place((select id from public.states where code = 'UP'), 'Basti', 'Harraiya', null)$$, 'places are added by', 'someone who registers no farmer here adds no place');
select t.as_user(t.u('02'));
select t.ok((app.add_place(pg_temp.f('UP'), 'Newdistrict Test', null, null)).district = 'Newdistrict Test', 'the State Manager adds a district');

-- 2 · The Client Manager's lists --------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
with r as (insert into public.collection_points (client_id, name, kind, district, block, village, lat, lng, created_by, created_at)
  values ('00000000-0000-4000-8000-000000000201', 'Bansi centre', 'centre', 'Siddharthnagar', 'Bansi', 'Bansi', 27.18, 82.93, t.u('05'), now() - interval '9 days')
  returning id) insert into fx select 'CP', id from r;
select t.ok((select created_by = t.u('03') and created_at > now() - interval '1 minute' from public.collection_points where id = pg_temp.f('CP')),
            'who added it, and when, is the server''s');
select t.fails($$insert into public.collection_points (client_id, name, kind, district, lat, lng) values ('00000000-0000-4000-8000-000000000201', 'Abroad', 'store', 'X', 51.5, -0.1)$$,
               'check constraint', 'a GPS point outside India is refused');
select t.fails($$insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'bansi centre', 'store', 'Siddharthnagar')$$,
               'duplicate key', 'one name once per client (written differently)');
update public.collection_points set client_id = '00000000-0000-4000-8000-000000000202', active = false where id = pg_temp.f('CP');
select t.ok((select client_id = '00000000-0000-4000-8000-000000000201' and not active from public.collection_points where id = pg_temp.f('CP')),
            'a point is retired (set inactive), never moved to another client');
select t.as_service();
update public.collection_points set client_id = '00000000-0000-4000-8000-000000000202' where id = pg_temp.f('CP');
select t.ok((select client_id = '00000000-0000-4000-8000-000000000201' from public.collection_points where id = pg_temp.f('CP')),
            'not even the service moves a list to another client');
select t.as_user(t.u('03'));
insert into public.mills (client_id, name, place, ownership, dedicated_crop_id) values
  ('00000000-0000-4000-8000-000000000201', 'Own mill', 'Bansi', 'own', '00000000-0000-4000-8000-000000000101'),
  ('00000000-0000-4000-8000-000000000201', 'Hired mill', 'Basti', 'hired', null);
insert into public.packing_units (client_id, name, place, ownership, fssai_licence) values ('00000000-0000-4000-8000-000000000201', 'Pack house', 'Gorakhpur', 'contract', '12345678901234');
select t.fails($$insert into public.packing_units (client_id, name, place, ownership, fssai_licence) values ('00000000-0000-4000-8000-000000000201', 'Bad', 'X', 'own', '12AB')$$,
               'check constraint', 'an FSSAI licence is 14 digits');
select t.fails($$insert into public.buyers (client_id, name, country, address) values ('00000000-0000-4000-8000-000000000201', 'Delhi Mart', 'IN', 'Okhla, New Delhi')$$,
               'check constraint', 'a domestic buyer has a GSTIN or an FSSAI licence');
insert into public.buyers (client_id, name, country, gstin, address) values ('00000000-0000-4000-8000-000000000201', 'Delhi Mart', 'IN', '07AAACD1234E1Z5', 'Okhla, New Delhi');
insert into public.buyers (client_id, name, country, importer_id, address, contact_email) values ('00000000-0000-4000-8000-000000000201', 'Amira Foods BV', 'NL', 'NL-IMP-77', 'Rotterdam', 'buy@amira.example');
insert into public.pack_skus (client_id, size, unit, material, market) values ('00000000-0000-4000-8000-000000000201', 500, 'g', 'pouch', 'domestic'),
  ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'vacuum', 'export'), ('00000000-0000-4000-8000-000000000201', 25, 'kg', 'jute', 'any');
select t.as_service();
select t.ok((select app.sku_kg(s) from public.pack_skus s where s.size = 500 and s.client_id = '00000000-0000-4000-8000-000000000201') = 0.5, 'a 500 g pack is 0.5 kg');
select t.as_user(t.u('03'));
select t.fails($$insert into public.pack_skus (client_id, size, unit, material, market) values ('00000000-0000-4000-8000-000000000201', 500, 'g', 'pouch', 'domestic')$$,
               'duplicate key', 'the same pack twice is refused');
select t.as_user(t.u('05'));
select t.ok((select count(*) from public.buyers where client_id = '00000000-0000-4000-8000-000000000201') = 2 and (select count(*) from public.mills) >= 2,
            'the client''s people read its lists');
select t.fails($$insert into public.mills (client_id, name, place, ownership) values ('00000000-0000-4000-8000-000000000201', 'Ops mill', 'X', 'own')$$,
               'row-level security', 'an operator keeps no list');
select t.as_user(t.u('12'));
select t.ok((select count(*) from public.buyers where client_id = '00000000-0000-4000-8000-000000000201') = 0, 'another client''s people see none of them');
select t.as_user(t.u('02'));
select t.fails($$insert into public.buyers (client_id, name, country, importer_id, address) values ('00000000-0000-4000-8000-000000000201', 'SM buyer', 'AE', 'X1', 'Dubai')$$,
               'row-level security', 'the State Manager keeps no client''s list');

-- 3 · Labs (the State Manager) ------------------------------------------------------------------------------------------
insert into public.labs (state_id, name, accreditation_no, kind, location) values (pg_temp.f('UP'), 'Gorakhpur Grain Lab', 'TC-1234', 'external', 'Gorakhpur');
select t.fails(format($$insert into public.labs (state_id, name, kind, location) values (%L, 'No accreditation', 'external', 'Lucknow')$$, pg_temp.f('UP')),
               'check constraint', 'an external lab names its accreditation');
select t.fails(format($$insert into public.labs (state_id, name, kind, location) values (%L, 'Assam lab', 'in_house', 'Guwahati')$$, pg_temp.f('AS')),
               'row-level security', 'he keeps the labs of his own state only');
select t.as_user(t.u('03'));
select t.fails(format($$insert into public.labs (state_id, name, kind, location) values (%L, 'CM lab', 'in_house', 'Bansi')$$, pg_temp.f('UP')),
               'row-level security', 'a Client Manager keeps no lab');
select t.ok((select count(*) from public.labs where name = 'Gorakhpur Grain Lab') = 1, 'everyone reads the labs');

-- 4 · The parameter library and market profiles --------------------------------------------------------------------------
select t.ok((select count(*) from public.quality_param_library where grp = 'safety' and done_by = 'lab') = 3, 'the library: the brief''s safety tests are lab tests');
select t.fails($$insert into public.quality_param_library (param, name, done_by, grp) values ('x_test', 'X', 'lab', 'basic')$$, 'permission denied', 'nobody writes the library from the app');
select t.ok((select status = 'active' and version = 1 and params @> '[{"param": "moisture_pct", "operator": "<=", "limit": 12}]'
               and export_docs @> '{"Lab report"}' from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'export'),
            'Kalanamak''s export profile carries the crop''s export limits and documents (version 1, active)');
select t.ok((select params @> '[{"param": "moisture_pct", "limit": 13}]' from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'domestic'),
            'and its domestic profile the domestic limits');
select t.fails($$select app.save_market_profile('{"crop_id": "00000000-0000-4000-8000-000000000101", "code": "eu", "params": [{"param": "moisture_pct"}]}')$$,
               'the State Manager', 'a Client Manager keeps no market profile');
select t.as_user(t.u('02'));
select t.fails($$select app.save_market_profile('{"crop_id": "00000000-0000-4000-8000-000000000101", "code": "eu", "params": [{"param": "colour_x", "operator": "<=", "limit": 1}]}')$$,
               'not in the parameter library', 'a parameter outside the library is refused');
select t.fails($$select app.save_market_profile('{"crop_id": "00000000-0000-4000-8000-000000000101", "code": "eu", "params": [{"param": "aflatoxin_ppb", "operator": "<="}]}')$$,
               'an operator and a number limit', 'a number needs its limit');
insert into fx select 'EU', id from app.save_market_profile('{"crop_id": "00000000-0000-4000-8000-000000000101", "code": "eu", "name": "EU",
  "params": [{"param": "moisture_pct", "operator": "<=", "limit": 12}, {"param": "aflatoxin_ppb", "operator": "<=", "limit": 2}, {"param": "aroma", "pass": ["A"]}],
  "export_docs": ["Phytosanitary certificate", "Certificate of origin", "Lab report", "EUR.1"]}');
select t.fails($$select app.activate_market_profile((select id from fx where k = 'EU'))$$, 'attach the document', 'a profile is activated only with the document its limits come from');
select t.fails(format($$select app.register_reference_file(%L, 'profile_source', 'crop/00000000-0000-4000-8000-000000000999/0123456789abcdef.pdf', repeat('a', 64), 'EU 2023/915.pdf')$$,
                      '00000000-0000-4000-8000-000000000101'), 'not filed under this crop', 'a file is filed under its own crop');
insert into fx select 'SRC', id from app.register_reference_file('00000000-0000-4000-8000-000000000101', 'profile_source',
  'crop/00000000-0000-4000-8000-000000000101/0123456789abcdef.pdf', repeat('b', 64), 'EU 2023-915 contaminants.pdf');
select app.save_market_profile(jsonb_build_object('id', pg_temp.f('EU'), 'source_file_id', pg_temp.f('SRC'), 'source_note', 'Regulation (EU) 2023/915'));
select t.ok((app.activate_market_profile(pg_temp.f('EU'))).status = 'active', 'with its document the EU profile is active');
insert into fx select 'EX2', id from app.save_market_profile(jsonb_build_object('id', (select id from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'export' and status = 'active'),
  'params', '[{"param": "moisture_pct", "operator": "<=", "limit": 11.5}]'::jsonb));
select t.ok((select version = 2 and status = 'draft' from public.market_profiles where id = pg_temp.f('EX2'))
            and (select params @> '[{"limit": 12}]' and status = 'active' from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'export' and version = 1),
            'changing an active profile makes version 2 as a draft; version 1 stays in use');
select t.fails(format($$select app.save_market_profile(jsonb_build_object('crop_id', %L, 'code', 'export', 'params', '[]'::jsonb))$$, '00000000-0000-4000-8000-000000000101'),
               'a draft of this profile already', 'one draft at a time');
select app.save_market_profile(jsonb_build_object('id', pg_temp.f('EX2'), 'source_file_id', pg_temp.f('SRC')));
select app.activate_market_profile(pg_temp.f('EX2'));
select t.ok((select status from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'export' and version = 1) = 'retired'
            and (select count(*) from public.market_profiles where crop_id = '00000000-0000-4000-8000-000000000101' and code = 'export') = 2,
            'activating version 2 retires version 1 (kept, never deleted)');
select t.ok(pg_temp.n($q$select count(*) from public.audit_log where action = 'market_profile_activated' and detail->>'source_sha256' = repeat('b', 64)$q$) = 2 or exists (select 1 from public.audit_log where action = 'market_profile_activated' and detail->>'source_sha256' = repeat('b', 64)),
            'the activation is in the audit log with its source document''s fingerprint');

-- 5 · Crops: GI crop, shelf life per material, reference photo ----------------------------------------------------------
select t.ok((select gi_crop from public.crops where id = '00000000-0000-4000-8000-000000000101'), 'a crop with a GI number is a GI crop');
insert into public.crops (name, code, state_id, gi_tag) values ('Plain rice', 'PLR', pg_temp.f('UP'), null) returning id as plain \gset
select t.ok(not (select gi_crop from public.crops where id = :'plain'), 'one without is not');
select t.fails(format($$update public.crops set gi_districts = '{Basti}' where id = %L$$, :'plain'), 'no GI area', 'a crop that is not a GI crop has no GI area');
select t.as_service();
alter table public.crops disable trigger crops_a1_gi;                 -- a crop of before migration 51: districts, no GI number
update public.crops set gi_districts = '{Basti}' where id = :'plain';
alter table public.crops enable trigger crops_a1_gi;
select t.as_user(t.u('02'));
select set_config('t45.plain', :'plain', false);
do $$ begin
  update public.crops set yield_per_acre_kg = 1100 where id = current_setting('t45.plain')::uuid;
  perform t.ok((select yield_per_acre_kg from public.crops where id = current_setting('t45.plain')::uuid) = 1100, 'such a crop of before is not refused for another change');
exception when sqlstate '23514' then perform t.ok(false, 'such a crop of before is not refused for another change');
end $$;
select t.fails(format($$update public.crops set gi_districts = '{Basti,Gonda}' where id = %L$$, :'plain'), 'no GI area', 'its GI area is not changed without a GI number');
select t.as_service();
update public.crops set gi_districts = '{}' where id = :'plain';
select t.as_user(t.u('02'));
select t.as_service();   -- the demo crop has no state (a State Manager of its state would set these)
update public.crops set shelf_life_days = 365, shelf_life_by_material = '{"jute": 270}' where id = '00000000-0000-4000-8000-000000000101';
select t.ok(app.shelf_life_for('00000000-0000-4000-8000-000000000101', 'jute') = 270 and app.shelf_life_for('00000000-0000-4000-8000-000000000101', 'pouch') = 365,
            'shelf life per material, else the crop''s');
select t.fails($$update public.crops set shelf_life_by_material = '{"glass": 10}' where id = '00000000-0000-4000-8000-000000000101'$$, 'check constraint', 'a material from the list only');
select t.fails($$update public.crops set reference_photo_id = (select id from fx where k = 'SRC') where id = '00000000-0000-4000-8000-000000000101'$$,
               'the reference photo is a photo', 'the reference photo is a photo of this crop, not a document');
insert into public.crops (name, code, state_id) values ('Kept rice', 'KPR', pg_temp.f('UP')) returning id as kept \gset
insert into public.reference_files (crop_id, kind, storage_path, sha256, file_name, uploaded_by)
values (:'kept', 'crop_photo', 'crop/' || :'kept' || '/0123456789abcdef.jpg', repeat('c', 64), 'photo.jpg', t.u('02'));
select t.as_user(t.u('01'));
select t.ok(pg_temp.n(format('select count(*) from public.market_profiles where crop_id = %L', :'plain')) = 2, 'a new crop carries its two profiles');
select app.remove_crop(:'plain', 'added by mistake');
select t.as_service();
select t.ok(not exists (select 1 from public.crops where id = :'plain') and not exists (select 1 from public.market_profiles where crop_id = :'plain'),
            'the admin still removes an unused crop: its carried profiles go with it');
select t.as_user(t.u('01'));
select t.fails(format($$select app.remove_crop(%L, 'added by mistake')$$, :'kept'), 'retire it instead', 'a crop with documents filed is in use: retired, never removed');
select t.as_service();

-- 6 · Farmers: GPS and a listed district at the Client Manager's verification; GI area; the GPS check ---------------
select t.as_user(t.u('05'));
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres)
  values ('00000000-0000-4000-8000-000000000201', 'Gps Missing', 'Father', 'Itwa', 'Siddharthnagar', '+919870051001', 2, 1) returning id) insert into fx select 'N1', id from r;
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng)
  values ('00000000-0000-4000-8000-000000000201', 'Typed District', 'Father', 'Itwa', 'Sidharth Ngr', '+919870051002', 2, 1, 27.2, 83.0) returning id) insert into fx select 'N2', id from r;
with r as (insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, farm_lat, farm_lng, block)
  values ('00000000-0000-4000-8000-000000000201', 'Outside Farmer', 'Father', 'Gosaiganj', 'Lucknow', '+919870051003', 2, 1, 26.76, 81.12, 'Gosaiganj') returning id) insert into fx select 'N3', id from r;
select t.as_user(t.u('03'));
select t.fails(format($$select app.submit_farmer(%L)$$, pg_temp.f('N1')), 'GPS location', 'a farmer registered now is verified only with the farm''s GPS');
select t.fails(format($$select app.submit_farmer(%L)$$, pg_temp.f('N2')), 'not on the list', 'and with a district from the list');
select app.submit_farmer(pg_temp.f('N3'));
select t.ok((select status from public.farmers where id = pg_temp.f('N3')) = 'under_review', 'with both, the Client Manager verifies');
select t.as_service();
update public.farmers set location_required = false where id = pg_temp.f('N1');      -- as the migration leaves the farmers already there
select t.as_user(t.u('03'));
select app.submit_farmer(pg_temp.f('N1'));
select t.ok((select status from public.farmers where id = pg_temp.f('N1')) = 'under_review', 'a farmer registered before is not refused for his missing GPS');
select t.as_service();                                                -- the crop is the State Manager's (crops_update)
update public.crops set gi_districts = '{Siddharthnagar,Basti}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('03'));
select t.ok(app.farmer_gi_area(pg_temp.f('N3')) @> '[{"crop": "Kalanamak rice", "status": "outside"}]', 'a farmer of Lucknow is outside Kalanamak''s GI area (accepted, marked)');
select t.ok(app.farmer_gi_area(t.farmer('01')) @> '[{"status": "inside"}]', 'one of Siddharthnagar is inside');
select t.ok((app.my_actions()->>'farmers_without_gps')::int >= 1, 'the Client Manager is asked to add the GPS of his farmers that have none');
select app.change_farmer(t.farmer('01'), '{"farm_lat": 27.21, "farm_lng": 82.95, "block": "Bansi"}', 'GPS taken at the farm');
select t.ok((select farm_lat = 27.21 and block = 'Bansi' from public.farmers where id = t.farmer('01')), 'the GPS is added through the one door, with a reason');
select t.as_service();
update public.farmers set farm_lat = 27.2 + n * 0.01, farm_lng = 83.0, district = 'Lucknow' from generate_series(1, 3) n
 where id in (t.farmer('02'), t.farmer('03'), t.farmer('04')) and right(id::text, 1)::int = n + 1;
select t.as_user(t.u('02'));
select t.ok(app.farmer_gps_check(pg_temp.f('N3'))->>'status' = 'far', 'a farm far (about 50 km and more) from the district''s other farms is shown to the State Manager');

-- 7 · A14 the ledger banner; A15 people on several scopes ----------------------------------------------------------------
select t.as_service();
insert into public.ledger_checks (source, blocks, ok) values ('nightly', 3, true);
select count(*) as nblocks from public.ledger \gset
select t.as_user(t.u('03'));
select t.ok((app.ledger_status()->>'added_since')::bigint = :nblocks - 3, 'the banner says how many blocks were added since the last full check');
select t.fails($$select app.work_elsewhere(t.u('06'), t.scope('01'))$$, 'permission denied', 'work elsewhere is read through the roster pool only (not an API of its own)');
select t.as_service();
select t.ok(jsonb_array_length(app.work_elsewhere(t.u('06'), t.scope('01'))) >= 1, 'QC''s work on the other scopes is listed');
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.roster_pool(t.scope('01'))) e where e ? 'elsewhere'), 'the roster pool carries each person''s work elsewhere');
select t.as_user(t.u('02'));
select t.ok(exists (select 1 from jsonb_array_elements(app.multi_scope_people(pg_temp.f('UP'))) e where (e->>'scopes')::int > 1),
            'the State Manager''s overview counts the people on more than one scope');
select t.as_user(t.u('03'));
select t.fails(format($$select app.multi_scope_people(%L)$$, pg_temp.f('UP')), 'no access', 'a Client Manager does not read the state''s count');

select t.as_service();
rollback;
