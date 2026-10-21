-- Migration 66 (Phase 2, release 3 of Veda's combined brief of 19 Oct 2026: Parts E, F and G).
--   1  E3: the FPO "ABFPO" is a client (its own brand) and registers as a sourcing partner on the same record (PAN);
--      ITC's Client Manager puts it on ITC's scope; who may set, who may read the scope's partners
--   2  E2: "Member of" ABFPO on ITC's farmer record; the procurement form's filter; nobody else's
--   3  E1: a farmer who consented to both clients (a record with each, one state farmer) is offered in both; one who
--      consented only to ABFPO is not offered to ITC and its procurement is refused; "Procured through" is one of the
--      scope's partners
--   4  E4: selling more than his land plausibly gives across both clients warns, with the total and the limit only
--   5  E5: ABFPO's login does not see ITC's procurement, nor ITC's login ABFPO's; the new tables are closed
--   6  E3/F: the public page says "Sourced through ABFPO" only once ABFPO agreed; "own brand" for GrainVeda's own lot
--   7  G2: farm-verified, set by the server; a lot not farm-verified (a forced value) never gets the GI badge
--   8  G1: every scope has an entry point; only farmer procurement is selectable
--   9  G3: a domestic buyer with a GSTIN is linked to the registry by its PAN, a foreign one by country and importer ID;
--      the same business for two clients is one entity; nobody in the app reads the link
-- Fake, format-valid numbers only (ZZZ…).
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.proc(p_scope uuid, p_client uuid, p_farmer uuid, p_by uuid, p_gross numeric, p_extra jsonb default '{}') returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (p_scope, p_client, 'procurement', p_farmer, p_by,
          jsonb_build_object('gross_kg', p_gross, 'bags', 2, 'tare_kg_per_bag', 1, 'moisture_pct', jsonb_build_array(12, 12, 12),
                             'collection_point_id', 'farm', 'gps_lat', 27.2, 'gps_lng', 83.0, 'delivered_by', 'farmer') || p_extra)
  returning id into v; return v; end $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ent(p_client uuid) returns uuid language sql stable security definer as $$ select entity_id from public.clients where id = p_client $$;
create or replace function pg_temp.warn(p_fp uuid) returns text language sql stable security definer as $$ select array_to_string(warnings, ' | ') from public.footprints where id = p_fp $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- two clients in Uttar Pradesh (kept Active as test clients), their people, a scope each, three farmer records
do $$ declare abf uuid; itc uuid; v uuid; sf1 uuid; sf2 uuid;
begin
  insert into public.clients (name, code, type, state_id) values ('AB Farmers Producer Co (test)', 'ABFP', 'fpo', '00000000-0000-4000-8000-000000000001') returning id into abf;
  insert into public.clients (name, code, type, state_id) values ('ITC Agri (test)', 'ITCA', 'exporter', '00000000-0000-4000-8000-000000000001') returning id into itc;
  insert into fx values ('ABF', abf), ('ITC', itc);
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000d01', '00000000-0000-4000-8000-000000000d01', 'ITC Client Manager', 'cm.itc66@example.com'),
    ('00000000-0000-4000-8000-000000000d02', '00000000-0000-4000-8000-000000000d02', 'ABFPO Client Manager', 'cm.abf66@example.com');
  insert into public.app_users (id, auth_uid, display_name, email, external) values
    ('00000000-0000-4000-8000-000000000d03', '00000000-0000-4000-8000-000000000d03', 'ABFPO (login)', 'abf66@example.com', true),
    ('00000000-0000-4000-8000-000000000d04', '00000000-0000-4000-8000-000000000d04', 'ITC (login)', 'itc66@example.com', true);
  insert into fx values ('CMI', '00000000-0000-4000-8000-000000000d01'), ('CMA', '00000000-0000-4000-8000-000000000d02'),
                        ('LABF', '00000000-0000-4000-8000-000000000d03'), ('LITC', '00000000-0000-4000-8000-000000000d04');
  insert into public.assignments (employee_id, lens, op_role, client_id) values
    ('00000000-0000-4000-8000-000000000d01', 'client', 'client_account', itc), ('00000000-0000-4000-8000-000000000d02', 'client', 'client_account', abf),
    ('00000000-0000-4000-8000-000000000d03', 'client', 'client_viewer', abf), ('00000000-0000-4000-8000-000000000d04', 'client', 'client_viewer', itc);
  insert into public.scopes (client_id, state_id, crop_id, season_code, geography, chain, status, market_codes, qc_report_required, stage_details_required)
  values (itc, '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000101', 'KH26', 'Bansi ITC', '{procurement,qc,qr_activation}', 'draft', '{domestic}', false, false)
  returning id into v; insert into fx values ('SI', v);
  insert into public.scopes (client_id, state_id, crop_id, season_code, geography, chain, status, market_codes, qc_report_required, stage_details_required)
  values (abf, '00000000-0000-4000-8000-000000000001', '00000000-0000-4000-8000-000000000101', 'KH26', 'Bansi ABF', '{procurement,qc,qr_activation}', 'draft', '{domestic}', false, false)
  returning id into v; insert into fx values ('SA', v);
  perform t.staff(pg_temp.f('SI')); perform t.staff(pg_temp.f('SA'));
  update public.scopes set status = 'active' where id in (pg_temp.f('SI'), pg_temp.f('SA'));
  insert into public.state_farmers (state_id, code) values ('00000000-0000-4000-8000-000000000001', 'F-UP-96601') returning id into sf1;
  insert into public.state_farmers (state_id, code) values ('00000000-0000-4000-8000-000000000001', 'F-UP-96602') returning id into sf2;
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, state_id, farm_lat, farm_lng, farmer_code)
  values (itc, 'draft', 'Shared Farmer', 'Father', 'Bansi', 'Siddharthnagar', '+919870006601', 2, 1, '00000000-0000-4000-8000-000000000001', 27.2, 83.0, 'ITCA-F-0001') returning id into v;
  insert into fx values ('FI1', v);
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, state_id, farm_lat, farm_lng, farmer_code)
  values (abf, 'draft', 'Shared Farmer', 'Father', 'Bansi', 'Siddharthnagar', '+919870006601', 2, 1, '00000000-0000-4000-8000-000000000001', 27.2, 83.0, 'ABFP-F-0001') returning id into v;
  insert into fx values ('FA1', v);
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, state_id, farm_lat, farm_lng, farmer_code)
  values (abf, 'draft', 'ABFPO Only Farmer', 'Father', 'Bansi', 'Siddharthnagar', '+919870006602', 2, 1, '00000000-0000-4000-8000-000000000001', 27.2, 83.0, 'ABFP-F-0002') returning id into v;
  insert into fx values ('FA2', v), ('SF1', sf1), ('SF2', sf2);
end $$;
-- the two steps of verification are tests/38's: here the farmers are put Active with their state farmer IDs directly
set local session_replication_role = replica;
update public.farmers set status = 'active', state_farmer_id = pg_temp.f('SF1') where id in (pg_temp.f('FI1'), pg_temp.f('FA1'));
update public.farmers set status = 'active', state_farmer_id = pg_temp.f('SF2') where id = pg_temp.f('FA2');
set local session_replication_role = origin;
select t.as_user(t.u('02'));
select app.set_client_pan(pg_temp.f('ABF'), 'ZZZAQ0101Q', 'cooperative');      -- ABFPO's PAN, typed once (a test client of before)

-- 1 · E3: ABFPO, a client, registered as a sourcing partner on its own record ------------------------------------------
select t.as_user(pg_temp.f('CMI'));
create temp table reg as select app.register_sourcing_partner('ZZZAQ0101Q', 'cooperative', 'AB Farmers (typed again)') as r;
grant select on reg to authenticated, anon;
select t.ok((select (r ->> 'entity_id')::uuid = pg_temp.ent(pg_temp.f('ABF')) and not (r ->> 'new')::boolean and r ->> 'pan_masked' = 'ZZZAQ****Q' from reg),
            'E3: the PAN already known: the sourcing-partner role on the same record (one entity, two roles)');
select t.ok((select r ->> 'legal_name' from reg) <> 'AB Farmers (typed again)' and position('client' in (select r::text from reg)) = 0,
            'E3: its name as on record; nothing said of its other role');
select t.fails($q$ select app.register_sourcing_partner('ZZZAQ0101Q', 'society', 'x') $q$, 'known as a cooperative', 'E3: the PAN''s type is checked against the record');
select t.fails($q$ select app.register_sourcing_partner('ZZZCQ0101Q', 'cooperative', 'x') $q$, '4th letter', 'E3: the PAN''s 4th letter by type');
select t.ok(exists (select 1 from jsonb_array_elements(app.sourcing_partners()) x where (x ->> 'entity_id')::uuid = pg_temp.ent(pg_temp.f('ABF'))),
            'E3: it is in the partners'' list');
select app.set_scope_partner(pg_temp.f('SI'), pg_temp.ent(pg_temp.f('ABF')), false);
select t.ok((app.scope_partners(pg_temp.f('SI')) -> 0 ->> 'name') = 'AB Farmers Producer Co (test)' and not (app.scope_partners(pg_temp.f('SI')) -> 0 ->> 'named_publicly')::boolean,
            'E3: ABFPO on ITC''s scope, not named publicly (the default)');
select t.as_user(pg_temp.f('CMA'));
select t.fails(format($q$ select app.set_scope_partner(%L, %L, true) $q$, pg_temp.f('SI'), pg_temp.ent(pg_temp.f('ABF'))), 'its Client Manager', 'E3: only ITC''s Client Manager sets ITC''s partners');
select t.fails(format($q$ select app.set_scope_partner(%L, %L, true) $q$, pg_temp.f('SA'), pg_temp.ent(pg_temp.f('ABF'))), 'not its own sourcing partner', 'E3: a client is not its own partner');
select t.fails(format($q$ select app.scope_partners(%L) $q$, pg_temp.f('SI')), 'not found', 'E5: ABFPO''s Client Manager reads nothing of ITC''s scope');
select t.as_user(pg_temp.f('LABF'));
select t.fails(format($q$ select app.scope_partners(%L) $q$, pg_temp.f('SI')), 'not found', 'E5: ABFPO''s login does not learn it sources for ITC');
select t.fails($q$ select app.sourcing_partners() $q$, 'GrainVeda', 'E5: a client''s login does not read the registry');
select t.fails($q$ select app.register_sourcing_partner('ZZZAQ0101Q', 'cooperative', 'x') $q$, 'State Manager or a Client Manager', 'E3: nor registers a partner');
select t.as_user(pg_temp.f('LITC'));
select t.ok((app.scope_partners(pg_temp.f('SI')) -> 0 ->> 'pan_masked') is null and jsonb_array_length(app.scope_partners(pg_temp.f('SI'))) = 1,
            'E3: ITC''s own login sees its scope''s partner (no PAN)');
select t.as_user(t.u('01'));
select t.fails($q$ select app.register_sourcing_partner('ZZZAQ0101Q', 'cooperative', 'x') $q$, 'State Manager or a Client Manager', 'E3: the admin registers nothing');

-- 2 · E2: "Member of" ------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('CMA'));
select t.fails(format($q$ select app.set_farmer_member(%L, %L) $q$, pg_temp.f('FI1'), pg_temp.ent(pg_temp.f('ABF'))), 'Client Manager of his client', 'E2: not another client''s farmer');
select t.as_user(pg_temp.f('CMI'));
select app.set_farmer_member(pg_temp.f('FI1'), pg_temp.ent(pg_temp.f('ABF')));
select t.ok((select array_agg(x ->> 'farmer_id') from jsonb_array_elements(app.scope_farmer_members(pg_temp.f('SI'))) x) = array[pg_temp.f('FI1')::text]
            and app.farmer_member(pg_temp.f('FI1')) = pg_temp.ent(pg_temp.f('ABF')), 'E2: ITC''s farmer is a member of ABFPO: the form''s filter "ABFPO members"');
select t.fails(format($q$ select app.set_farmer_member(%L, %L) $q$, pg_temp.f('FI1'), pg_temp.f('ITC')), 'registered as a sourcing partner', 'E2: a member of a registered FPO or aggregator only');

-- 3 · E1: consent per client, "Procured through" ----------------------------------------------------------------------------
select t.as_user(t.u('05'));                                          -- the procurement operator, on both scopes
select t.ok((select count(*) from public.farmers where id in (pg_temp.f('FI1'), pg_temp.f('FA1'), pg_temp.f('FA2')) and client_id = pg_temp.f('ITC')) = 1
            and (select count(*) from public.farmers where client_id = pg_temp.f('ABF') and id in (pg_temp.f('FA1'), pg_temp.f('FA2'))) = 2,
            'E1: ITC''s form offers its own farmer record (the shared farmer); ABFPO''s offers both of its own');
select t.fails(format($q$ select pg_temp.proc(%L, %L, %L, t.u('05'), 100) $q$, pg_temp.f('SI'), pg_temp.f('ITC'), pg_temp.f('FA2')),
               'not registered with this scope''s client', 'E1: a farmer who consented only to ABFPO cannot be bought from for ITC');
select t.fails(format($q$ select pg_temp.proc(%L, %L, %L, t.u('05'), 100, '{"procured_through":"%s"}') $q$, pg_temp.f('SI'), pg_temp.f('ITC'), pg_temp.f('FI1'), pg_temp.f('ITC')),
               'one of this scope''s sourcing partners', 'E3: "Procured through" only one of the scope''s partners');
select t.as_service();
update public.crops set gi_districts = '{Siddharthnagar}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('05'));
insert into fx select 'PA', pg_temp.proc(pg_temp.f('SA'), pg_temp.f('ABF'), pg_temp.f('FA1'), t.u('05'), 602);          -- 600 kg to ABFPO
select t.ok(coalesce(pg_temp.warn(pg_temp.f('PA')), '') not like '%above the expected yield%', 'E4: 600 kg of a plausible 1,000: no warning');
insert into fx select 'PI', pg_temp.proc(pg_temp.f('SI'), pg_temp.f('ITC'), pg_temp.f('FI1'), t.u('05'), 602,
  jsonb_build_object('procured_through', pg_temp.ent(pg_temp.f('ABF'))));                                                      -- and 600 kg to ITC

-- 4 · E4: the season across clients ---------------------------------------------------------------------------------------
select t.ok(pg_temp.warn(pg_temp.f('PI')) like '%above the expected yield: 1200 of 1000 kg this season (1.00 acres of GI land)%',
            'E4: 1,200 kg sold through GrainVeda this season, both clients together, against a plausible 1,000: a warning');
select t.ok(position('ABF' in pg_temp.warn(pg_temp.f('PI'))) = 0 and position('AB Farmers' in pg_temp.warn(pg_temp.f('PI'))) = 0,
            'E4: the total and the limit only: the other client is not named');
select t.ok(exists (select 1 from public.footprints where id = pg_temp.f('PI')), 'E4: a warning, never a refusal');
select t.ok((select payload ->> 'procured_through' from public.footprints where id = pg_temp.f('PI')) = pg_temp.ent(pg_temp.f('ABF'))::text,
            'E3: the procurement records "Procured through ABFPO"');

-- 5 · E5: no cross-client visibility ---------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('LABF'));
select t.ok((select count(*) from public.footprints where scope_id = pg_temp.f('SI')) = 0 and (select count(*) from public.footprints where id = pg_temp.f('PI')) = 0,
            'E5: ABFPO''s login does not see ITC''s procurement from its members');
select t.ok((select count(*) from public.footprints where id = pg_temp.f('PA')) = 1, 'E5: it sees its own');
select t.fails('select count(*) from public.scope_partners', 'permission denied', 'E5: the partners'' table is closed');
select t.fails('select count(*) from public.farmer_memberships', 'permission denied', 'E5: so are the memberships');
select t.as_user(pg_temp.f('LITC'));
select t.ok((select count(*) from public.scopes where id = pg_temp.f('SA')) = 0 and (select count(*) from public.footprints where scope_id = pg_temp.f('SA')) = 0,
            'E5: ITC''s login does not see ABFPO''s own-brand scope');
select t.as_user(pg_temp.f('CMI'));
select t.fails(format($q$ select app.scope_farmer_members(%L) $q$, pg_temp.f('SA')), 'not found', 'E5: nor ITC''s Client Manager ABFPO''s members');

-- 6 · E3/F: the public page ------------------------------------------------------------------------------------------------
select t.as_service(); select t.verify(pg_temp.f('PI'), t.u('05'));        -- one person holds ITC's stages (t.staff): marked, as allowed
select t.as_user(t.u('05'));
insert into fx select 'QI', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (pg_temp.f('QI'), pg_temp.f('SI'), pg_temp.f('ITC'), 'qc', pg_temp.f('PI'), t.u('05'), '{"qty_kg":590,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select app.verify_footprint(pg_temp.f('QI'));
insert into fx select 'RI', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (pg_temp.f('RI'), pg_temp.f('SI'), pg_temp.f('ITC'), 'qr_activation', pg_temp.f('QI'), t.u('05'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('RI'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_anon();
select t.ok((select app.public_lot_journey(code) -> 'sourced_through' from seal) = '[]'::jsonb, 'E3: ABFPO has not agreed: the public page does not name it');
select t.ok((select app.public_lot_journey(code) #>> '{client,own_brand}' from seal) = 'false' and (select app.public_lot_journey(code) ->> 'farm_verified' from seal) = 'true',
            'F: ITC''s lot is not "own brand"; G2: farm-verified');
select t.ok((select app.public_lot_journey(code) ->> 'gi_status' from seal) = 'gi', 'G2: farm-verified and from the GI area: GI');
select t.as_user(pg_temp.f('CMI'));
select app.set_scope_partner(pg_temp.f('SI'), pg_temp.ent(pg_temp.f('ABF')), true);
select t.as_anon();
select t.ok((select app.public_lot_journey(code) -> 'sourced_through' from seal) = '["AB Farmers Producer Co (test)"]'::jsonb,
            'E3: "Partner agrees to be named publicly": "Sourced through AB Farmers Producer Co (test)"');
select t.ok(position('Shared Farmer' in (select app.public_lot_journey(code)::text from seal)) = 0, 'E3: and still no farmer''s name');
select t.as_user(pg_temp.f('CMI'));
select t.fails(format($q$ select app.remove_scope_partner(%L, %L, 'no') $q$, pg_temp.f('SI'), pg_temp.ent(pg_temp.f('ABF'))), 'reason of 10', 'E3: a partner is removed with a reason');

-- F: GrainVeda's own brand on its public page (client 201, a lot of scope 01)
select t.as_service();
insert into fx select 'P1', t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
select t.verify(pg_temp.f('P1'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q1', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (pg_temp.f('Q1'), t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', pg_temp.f('P1'), t.u('06'), '{"qty_kg":98,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service(); select t.attach(pg_temp.f('Q1'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q1'));
insert into fx select 'R1', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (pg_temp.f('R1'), t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', pg_temp.f('Q1'), t.u('07'), '{}');
create temp table seal1 as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal1 to anon, authenticated;
select t.as_anon();
select t.ok((select app.public_lot_journey(code) #>> '{client,own_brand}' from seal1) = 'true', 'F: GrainVeda''s own lot: "Operated by GrainVeda (own brand)"');

-- 7 · G2: farm-verified, and the GI badge -----------------------------------------------------------------------------------
select t.as_user(t.u('05'));
insert into fx select 'PF', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, farmer_id, created_by, payload, farm_verified)
values (pg_temp.f('PF'), t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'),
        '{"gross_kg":50,"bags":1,"tare_kg_per_bag":1,"moisture_pct":[12,12,12],"collection_point_id":"farm","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer"}', false);
select t.as_service();
select t.ok((select farm_verified from public.footprints where id = pg_temp.f('PF')), 'G2: a person''s record is farm-verified (the server sets it)');
select t.as_user(t.u('05'));
select t.fails(format($q$ update public.footprints set farm_verified = false where id = %L $q$, pg_temp.f('PF')), 'set by the server', 'G2: and nobody changes it');
select t.as_service();
insert into fx select 'PX', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, farmer_id, created_by, payload, farm_verified)       -- the forced value
values (pg_temp.f('PX'), t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'),
        '{"gross_kg":50,"bags":1,"tare_kg_per_bag":1,"moisture_pct":[12,12,12],"collection_point_id":"farm","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer"}', false);
select t.ok(app.lot_gi_status(pg_temp.f('PF')) = 'gi' and app.lot_gi_status(pg_temp.f('PX')) = 'non_gi',
            'G2: the same farmer, the same GI area: farm-verified is GI; not farm-verified (forced) never gets the GI badge');
select t.ok(not app.lot_farm_verified(pg_temp.f('PX')) and app.lot_farm_verified(pg_temp.f('PF')), 'G2: the flag of each lot');
select t.verify(pg_temp.f('PX'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'QX', id from (select gen_random_uuid() as id) x;
insert into public.footprints (id, scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
values (pg_temp.f('QX'), t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', pg_temp.f('PX'), t.u('06'), '{"qty_kg":47,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service();
select t.ok(not app.lot_farm_verified(pg_temp.f('QX')) and app.lot_gi_status(pg_temp.f('QX')) = 'non_gi', 'G2: the flag travels to the next record; still no GI');

-- 8 · G1: the entry point ---------------------------------------------------------------------------------------------------
select t.ok((select bool_and(entry_point = 'farmer_procurement') from public.scopes), 'G1: every scope: farmer procurement');
select t.as_user(pg_temp.f('CMI'));
select t.fails(format($q$ insert into public.scopes (client_id, crop_id, season_code, geography, chain, market_codes, entry_point)
  values (%L, '00000000-0000-4000-8000-000000000101', 'RB27', 'Bansi', '{procurement,qc,qr_activation}', '{domestic}', 'received_lot') $q$, pg_temp.f('ITC')),
  'only farmer procurement for now', 'G1: "received lot" is not selectable yet');
select t.fails(format($q$ update public.scopes set entry_point = 'received_lot' where id = %L $q$, pg_temp.f('SI')), 'only farmer procurement', 'G1: nor set later');

-- 9 · G3: buyers linked to the registry ---------------------------------------------------------------------------------------
insert into public.buyers (client_id, name, country, address, gstin) values (pg_temp.f('ITC'), 'AB Farmers (as a buyer)', 'IN', 'Bansi, Siddharthnagar', '09ZZZAQ0101Q1Z5');
insert into public.buyers (client_id, name, country, address, importer_id) values (pg_temp.f('ITC'), 'QWE Trading LLC', 'AE', 'Jebel Ali, Dubai', 'IMP-0077');
select t.fails('select count(*) from public.buyer_entities', 'permission denied', 'G3: the link is closed to everyone in the app');
select t.as_user(pg_temp.f('CMA'));
insert into public.buyers (client_id, name, country, address, importer_id) values (pg_temp.f('ABF'), 'QWE Trading', 'AE', 'Dubai', 'imp- 0077');
insert into public.buyers (client_id, name, country, address, gstin) values (pg_temp.f('ABF'), 'Delhi Wholesale (test)', 'IN', 'Azadpur Mandi, Delhi', '07ZZZCD7001D1Z5');
select t.as_service();
select t.ok((select be.entity_id from public.buyer_entities be join public.buyers b on b.id = be.buyer_id where b.gstin = '09ZZZAQ0101Q1Z5') = pg_temp.ent(pg_temp.f('ABF')),
            'G3: a domestic buyer with a GSTIN: linked by its PAN (here ABFPO itself: "this buyer is also a client")');
select t.ok((select count(distinct be.entity_id) = 1 and count(*) = 2 from public.buyer_entities be join public.buyers b on b.id = be.buyer_id where b.country = 'AE'),
            'G3: a foreign importer: by country and importer ID; the same importer for two clients is one entity');
select t.ok((select e.pan_masked = 'ZZZCD****D' and exists (select 1 from public.entity_roles r where r.entity_id = e.id and r.role = 'buyer')
               from public.buyer_entities be join public.buyers b on b.id = be.buyer_id join public.entities e on e.id = be.entity_id where b.name = 'Delhi Wholesale (test)'),
            'G3: a business new to the registry is made from the GSTIN''s PAN, with the role buyer');
select t.as_user(t.u('02'));
select t.ok(app.lookup_pan('ZZZCD7001D') = '{"situation": "known", "similar": false}'::jsonb, 'G3: and is "Known to GrainVeda as a business" (nothing of the role)');
select t.as_user(pg_temp.f('CMI'));
select t.ok(not exists (select 1 from public.buyers where client_id = pg_temp.f('ABF')), 'G3: ITC''s Client Manager reads none of ABFPO''s buyers');
rollback;
