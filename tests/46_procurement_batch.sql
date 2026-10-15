-- Migration 52 (Veda, 15 Oct 2026: the operator-stages brief, release 5: C1 Procurement, C2 Collection Batch, A13).
-- Client 201 (Prasaadam): its Client Manager 03, Procurement 05, QC 06, Collection Batch 15; 12 an operator of client
-- 202. Scope 06 (Bansi batch: procurement -> collection batch -> QC -> QR); the demo farmers 01-05 (villages Bansi,
-- Itwa, Domariyaganj, Naugarh, Shohratgarh; district Siddharthnagar). Kalanamak rice is crop 101.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.n(p_sql text) returns bigint language plpgsql security definer as $$
declare v bigint; begin execute p_sql into v; return v; end $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql security definer as $$ select * from public.footprints where id = p $$;
-- a Procurement lot of scope 06 as its operator (05), with the payload given
create or replace function pg_temp.lot(p_farmer uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values ('00000000-0000-4000-8000-000000000406', '00000000-0000-4000-8000-000000000201', 'procurement', p_farmer, t.u('05'),
          '{"gross_kg":102,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12.2,12.1]}'::jsonb || p) returning id into v;
  return v; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
update public.farmers set gi_land_acres = 1.5 where id in (t.farmer('01'), t.farmer('02'), t.farmer('03'), t.farmer('04'));
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'Bansi centre', 'centre', 'Siddharthnagar') returning id)
  insert into fx select 'CP1', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'Itwa store', 'store', 'Siddharthnagar') returning id)
  insert into fx select 'CP2', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district, active) values ('00000000-0000-4000-8000-000000000201', 'Old centre', 'centre', 'Siddharthnagar', false) returning id)
  insert into fx select 'CPOLD', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000202', 'Other client point', 'centre', 'Basti') returning id)
  insert into fx select 'CPX', id from r;

-- 1 · The scope's settings -------------------------------------------------------------------------------------------
select t.ok(not (select procurement_details_required from public.scopes where id = t.scope('06')), 'the demo scopes do not ask where, GPS and who delivered (seed 09)');
select t.ok((select column_default from information_schema.columns where table_name = 'scopes' and column_name = 'procurement_details_required') = 'true',
            'a scope made from now on asks them');
select t.ok(not (select record_price from public.scopes where id = t.scope('06')), 'price and payment are not recorded unless the Client Manager turns it on');
update public.scopes set procurement_details_required = true where id = t.scope('06');

-- 2 · C1 Procurement: where, GPS, who delivered -----------------------------------------------------------------------
select t.as_user(t.u('05'));
select t.fails($$select pg_temp.lot(t.farmer('01'), '{"gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer"}')$$, 'say where the lot was weighed', 'where the lot was weighed is asked');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","delivered_by":"farmer"}')$$, pg_temp.f('CP1')), 'the GPS of where the lot was weighed is required', 'its GPS is asked');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0}')$$, pg_temp.f('CP1')), 'say who delivered the lot', 'who delivered it is asked');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"agent"}')$$, pg_temp.f('CP1')), 'name the agent', 'an agent is named');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer"}')$$, pg_temp.f('CPX')),
               'not one of this client''s active points', 'another client''s collection point is refused');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer"}')$$, pg_temp.f('CPOLD')),
               'not one of this client''s active points', 'a retired collection point is refused');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":51.5,"gps_lng":-0.1,"delivered_by":"farmer"}')$$, pg_temp.f('CP1')),
               'two numbers in India', 'a GPS point outside India is refused');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer","condition":"wet"}')$$, pg_temp.f('CP1')),
               'good, damp, pest or mixed', 'the condition is one tap from four');
insert into fx select 'L1', pg_temp.lot(t.farmer('01'), jsonb_build_object('collection_point_id', pg_temp.f('CP1'), 'gps_lat', 27.21, 'gps_lng', 82.95,
                                          'delivered_by', 'agent', 'agent_name', 'Ramesh (agent)', 'condition', 'good', 'harvest_date', '2026-10-01'));
select t.ok((pg_temp.fp(pg_temp.f('L1'))).qty_out = 100 and (pg_temp.fp(pg_temp.f('L1'))).payload->>'delivered_by' = 'agent',
            'with all of them the lot is saved (net 100 kg)');
insert into fx select 'L2', pg_temp.lot(t.farmer('02'), jsonb_build_object('collection_point_id', pg_temp.f('CP1'), 'gps_lat', 27.21, 'gps_lng', 82.95, 'delivered_by', 'family',
                                          'moisture_pct', jsonb_build_array(11.0, 13.0, 12.0), 'gross_kg', 202, 'bags', 2));
select t.ok('the moisture readings are 2.0 points apart (more than 1.5): read them again' = any ((pg_temp.fp(pg_temp.f('L2'))).warnings),
            'readings far apart are a warning, not a refusal');
insert into fx select 'L3', pg_temp.lot(t.farmer('01'), jsonb_build_object('collection_point_id', pg_temp.f('CP1'), 'gps_lat', 27.21, 'gps_lng', 82.95, 'delivered_by', 'farmer',
                                          'moisture_pct', jsonb_build_array(16.0, 16.2, 16.1)));
select t.ok(exists (select 1 from unnest((pg_temp.fp(pg_temp.f('L3'))).warnings) x where x like 'moisture 16.1 % is above the crop''s limit of %'),
            'above the crop''s moisture limit is a warning, not a refusal');
insert into fx select 'L4', pg_temp.lot(t.farmer('03'), jsonb_build_object('collection_point_id', 'farm', 'gps_lat', 27.3, 'gps_lng', 83.1, 'delivered_by', 'farmer'));
select t.ok((pg_temp.fp(pg_temp.f('L4'))).payload->>'collection_point_id' = 'farm' and (pg_temp.fp(pg_temp.f('L4'))).computed->>'collection_point' = 'farm', 'a lot weighed at the farm');
select t.ok((pg_temp.fp(pg_temp.f('L1'))).computed->>'collection_point' = 'Bansi centre', 'the record carries the name of the point it was weighed at');
insert into fx select 'L5', pg_temp.lot(t.farmer('04'), jsonb_build_object('collection_point_id', pg_temp.f('CP2'), 'gps_lat', 27.3, 'gps_lng', 83.1, 'delivered_by', 'farmer'));
select t.ok((app.preview_reconcile(t.scope('06'), 'procurement', null, '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', t.farmer('05'))->>'error')
              like 'procurement: say where the lot was weighed%', 'the form''s preview says the same before saving');

-- 3 · C1 Price and payment, kept apart ---------------------------------------------------------------------------------
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer","price_per_quintal":3500}')$$, pg_temp.f('CP1')),
               'does not record price and payment', 'no price where the scope does not record it');
update public.scopes set record_price = true where id = t.scope('06');            -- an operator: not his to change
select t.as_service();
select t.ok(not (select record_price from public.scopes where id = t.scope('06')), 'Procurement does not turn price recording on');
select t.as_user(t.u('03'));
update public.scopes set record_price = true where id = t.scope('06');            -- the Client Manager, on an active scope
select t.as_service();
select t.ok((select record_price and status = 'active' from public.scopes where id = t.scope('06')), 'the Client Manager turns it on for an active scope');
select t.as_user(t.u('05'));
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer","price_per_quintal":3500,"payment_status":"paid","payment_mode":"upi"}')$$, pg_temp.f('CP1')),
               'give the transaction ID', 'a payment by UPI or bank names its transaction ID');
select t.fails(format($$select pg_temp.lot(t.farmer('01'), '{"collection_point_id":"%s","gps_lat":27.2,"gps_lng":83.0,"delivered_by":"farmer","price_per_quintal":3500,"payment_status":"paid","payment_mode":"bank","txn_ref":"A/C 1234 5678"}')$$, pg_temp.f('CP1')),
               'never an account number', 'a transaction ID is letters or digits, nothing else');
insert into fx select 'LP', pg_temp.lot(t.farmer('02'), jsonb_build_object('collection_point_id', pg_temp.f('CP1'), 'gps_lat', 27.2, 'gps_lng', 83.0, 'delivered_by', 'farmer',
                                          'price_per_quintal', 3500, 'payment_status', 'paid', 'payment_mode', 'upi', 'txn_ref', 'UPI-TEST-0001'));
select t.ok(not ((pg_temp.fp(pg_temp.f('LP'))).payload ?| array['price_per_quintal', 'payment_status', 'payment_mode', 'txn_ref']),
            'the price and payment are not in the record');
select t.as_service();
select t.ok(not exists (select 1 from public.ledger where footprint_id = pg_temp.f('LP') and payload::text ~ '(3500|UPI-TEST|price_per_quintal)'),
            'nor in its ledger block');
select t.ok((select amount = 3500 and status = 'paid' and mode = 'upi' and txn_ref = 'UPI-TEST-0001' from public.lot_payments where footprint_id = pg_temp.f('LP')),
            'they are kept apart: 100 kg at ₹3,500 a quintal is ₹3,500');
select t.as_user(t.u('05'));
select t.ok((select count(*) from public.lot_payments where footprint_id = pg_temp.f('LP')) = 1, 'the person who recorded it reads it');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.lot_payments where footprint_id = pg_temp.f('LP')) = 1, 'the client''s Client Manager reads it');
select t.as_user(t.u('06'));
select t.ok((select count(*) from public.lot_payments where footprint_id = pg_temp.f('LP')) = 0, 'the next stages do not');
select t.as_user(t.u('12'));
select t.ok((select count(*) from public.lot_payments) = 0, 'another client''s people do not');
select t.as_user(t.u('05'));
insert into fx select 'LQ', pg_temp.lot(t.farmer('02'), jsonb_build_object('collection_point_id', pg_temp.f('CP1'), 'gps_lat', 27.2, 'gps_lng', 83.0, 'delivered_by', 'farmer',
                                          'price_per_quintal', 3400, 'payment_status', 'pending'));
select app.save_lot_payment(pg_temp.f('LQ'), '{"payment_status":"paid","payment_mode":"cash"}');
select t.ok((select status = 'paid' and mode = 'cash' and price_per_quintal = 3400 from public.lot_payments where footprint_id = pg_temp.f('LQ')),
            'paid later (cash, no transaction ID), the price kept');
select t.as_user(t.u('06'));
select t.fails(format($$select app.save_lot_payment(%L, '{"payment_status":"paid","payment_mode":"cash"}')$$, pg_temp.f('LQ')),
               'records its payment', 'QC records no payment');
select t.as_service();
update public.scopes set record_price = false where id = t.scope('06');

-- 4 · C1 The farmer card -------------------------------------------------------------------------------------------------
select t.as_service();
update public.crops set gi_districts = '{Siddharthnagar}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_user(t.u('05'));
select t.ok((app.farmer_card(t.farmer('01'), t.scope('06'))) @> '{"gi_area": "inside", "gi_land_acres": 1.5}'
            and (app.farmer_card(t.farmer('01'), t.scope('06'))->>'sold_kg')::numeric >= 200,
            'the farmer card: GI land, what he sold this season, GI area');
select t.ok((app.farmer_card(t.farmer('01'), t.scope('06'))->>'expected_kg') is not null and (app.farmer_card(t.farmer('01'), t.scope('06'))->'gap') ? 'required',
            'and what his GI land should give, and his practice');
select t.as_user(t.u('12'));
select t.fails(format($$select app.farmer_card(%L, %L)$$, t.farmer('01'), t.scope('06')), 'farmer not found', 'another client''s people see no card');

-- 5 · C2 Collection Batch ----------------------------------------------------------------------------------------------
select t.as_service();
update public.footprints set status = 'verified', verified_by = t.u('15') where id in (pg_temp.f('L1'), pg_temp.f('L2'), pg_temp.f('L3'), pg_temp.f('L4'), pg_temp.f('L5'));
create or replace function pg_temp.batch(p_ids uuid[], p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values ('00000000-0000-4000-8000-000000000406', '00000000-0000-4000-8000-000000000201', 'village_batch', p_ids[1], t.u('15'),
          jsonb_build_object('source_footprint_ids', to_jsonb(p_ids)) || p) returning id into v;
  return v; end $$;
grant execute on function pg_temp.batch(uuid[], jsonb) to authenticated;
select t.as_user(t.u('15'));
select t.fails(format($$select pg_temp.batch(array[%L, %L]::uuid[], '{}')$$, pg_temp.f('L1'), pg_temp.f('L5')), 'from different collection points',
               'lots from two collection points are not one batch (refused, naming them)');
select t.fails(format($$select pg_temp.batch(array[%L, %L]::uuid[], '{}')$$, pg_temp.f('L1'), pg_temp.f('L4')), 'at the farm',
               'nor a lot weighed at the farm with one weighed at a point');
select t.fails(format($$select pg_temp.batch(array[%L, %L]::uuid[], '{"single_origin": true}')$$, pg_temp.f('L1'), pg_temp.f('L2')), 'a single-origin batch is from one village',
               'a single-origin batch refuses a second village');
select t.fails(format($$select pg_temp.batch(array[%L, %L, %L]::uuid[], '{"reweighed_kg": 999}')$$, pg_temp.f('L1'), pg_temp.f('L2'), pg_temp.f('L3')), 'more than the lots',
               'a re-weighed total above the lots is refused');
insert into fx select 'B1', pg_temp.batch(array[pg_temp.f('L1'), pg_temp.f('L2'), pg_temp.f('L3')], '{"bags": 6, "reweighed_kg": 390}');
select t.ok((pg_temp.fp(pg_temp.f('B1'))).computed @> '{"total_kg": 400, "farmers": 2, "collection_point": "Bansi centre", "loss_kg": 10}'
            and (pg_temp.fp(pg_temp.f('B1'))).qty_out = 390,
            'two villages at one point: 400 kg from the lots, two farmers (one sold twice), 10 kg less on re-weighing');
select t.ok((pg_temp.fp(pg_temp.f('B1'))).computed->'villages' @> '[{"village": "Bansi", "kg": 200, "share_pct": 50.0}, {"village": "Itwa", "kg": 200, "share_pct": 50.0}]',
            'the villages and their shares come from the lots');
select t.ok(((pg_temp.fp(pg_temp.f('B1'))).computed->>'moisture_avg')::numeric = 13.05, 'the moisture is the weighted average of the lots');
select t.ok('the batch weighs 10.0 kg (2.5 %) less than its lots' = any ((pg_temp.fp(pg_temp.f('B1'))).warnings), 'a loss above 1 % on re-weighing is a warning');

-- 6 · A13 Where a lot went -----------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.lot_forward(pg_temp.f('L1'))->'steps') s
                     where s->>'code' = (pg_temp.fp(pg_temp.f('B1'))).footprint_code and (s->>'kg_taken')::numeric = 100 and (s->>'depth')::int = 1),
            'from a farmer''s lot, the journey forward names the batch it went into and the kilograms taken');
select t.ok(jsonb_array_length(app.lot_forward(pg_temp.f('B1'))->'steps') = 0, 'a batch nothing was built on has nowhere to go yet');
select t.as_user(t.u('12'));
select t.fails(format($$select app.lot_forward(%L)$$, pg_temp.f('L1')), 'not allowed to trace this lot', 'another client''s people do not trace it');

-- 7 · The parameter library's duplicate (found on staging) ------------------------------------------------------------
select t.as_service();
insert into public.quality_param_library (param, name, unit, type, done_by, grp, sort_order) values ('moisture_x', 'moisture ', '%', 'number', 'either', 'basic', 85);
select app.mark_library_aliases();
select t.ok((select alias_of from public.quality_param_library where param = 'moisture_x') = 'moisture_pct',
            'a test with the name of a library test is marked as the same test (one "Moisture (%)" in the lists)');
select t.ok(app.profile_params_problems('[{"param":"moisture_x","operator":"<=","limit":14}]') is null, 'a limit written with its key keeps working');

-- 8 · Migration 52b: the public page names a batch's villages without reading what the record worked out --------------
select t.ok(position('computed' in pg_get_functiondef('app.public_lot_journey(text)'::regprocedure)) = 0,
            'the public page reads nothing of a record''s worked-out values (smoke rule "public page data")');
select t.ok(string_to_array(app.batch_villages(pg_temp.f('B1')), ', ') @> array['Bansi', 'Itwa'] and app.batch_villages(pg_temp.f('L1')) is null,
            'a Collection Batch''s villages for the public page: their names, nothing else; none for a farmer''s lot');
select t.ok(not has_function_privilege('anon', 'app.batch_villages(uuid)', 'execute') and not has_function_privilege('authenticated', 'app.batch_villages(uuid)', 'execute'),
            'the helper is not open to the API');

select t.as_service();
rollback;
