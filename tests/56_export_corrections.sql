-- Migration 61 (Phase 1, release 3 of Veda's combined brief of 19 Oct 2026: release 2's corrections; the shown parts of the
-- season corrections E2.2 to E2.5; "do what is left as per best"):
--   C1.1/C1.2  a column per field, names not ids (mill, packing unit and its FSSAI licence, collection point), empty columns
--              left out, the raw values only in the internal copy, last, as "raw_values"
--   C1.3       prices only in the internal copy and only where the scope records prices
--   C1.4       packs counted by size; C3: staff and the buyer named in the shareable copy, the farmer and the agent not
--   E2.2       milling's floor loss without head rice, broken, husk and bran; the by-products in kg and %
--   E2.3       the public page: one line for all the purchases of a collection batch, the villages' shares
--   E2.4       the best-before date on the pack page; without the crop's shelf life Packing warns (61c: not mandatory)
--   E2.5       a lot closed as floor loss is its own line; the mass balance per stage, and a difference shown
-- Scope 06 (Bansi batch): Procurement (05) → Collection Batch (15) → QC (06) → QR (07). Scope 05 (Basti mill): Procurement (05)
-- → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) → QR (07). 03 the Client Manager of client 201;
-- 12 an operator of another client. Farmers 01 (Bansi) and 02 (Itwa), Siddharthnagar.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v;
end $$;
create or replace function pg_temp.lot(p_scope uuid, p_farmer uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'procurement', p_farmer, t.u('05'), p) returning id into v; return v; end $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$ select * from public.footprints where id = p $$;
-- the value of one column in the line of one record (the first such line), and the line after it
create or replace function pg_temp.col(e jsonb, p_col text) returns int language sql immutable as $$
  select (o - 1)::int from jsonb_array_elements_text(e->'columns') with ordinality c(k, o) where k = p_col $$;
create or replace function pg_temp.cell(e jsonb, p_code text, p_col text) returns jsonb language sql immutable as $$
  select r->pg_temp.col(e, p_col) from jsonb_array_elements(e->'rows') with ordinality x(r, i)
   where r->pg_temp.col(e, 'code') = to_jsonb(p_code) order by i limit 1 $$;
create or replace function pg_temp.line(e jsonb, p_code text, p_stage text) returns jsonb language sql immutable as $$
  select r from jsonb_array_elements(e->'rows') r where r->pg_temp.col(e, 'code') = to_jsonb(p_code) and r->pg_temp.col(e, 'stage') = to_jsonb(p_stage) $$;
create or replace function pg_temp.stage(b jsonb, p text) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(b) x where x->>'stage' = p $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.mills (client_id, name, place, ownership) values ('00000000-0000-4000-8000-000000000201', 'Hired mill', 'Basti', 'hired') returning id) insert into fx select 'MILL', id from r;
with r as (insert into public.packing_units (client_id, name, place, ownership, fssai_licence) values ('00000000-0000-4000-8000-000000000201', 'Basti packers', 'Basti', 'contract', '12345678901234') returning id) insert into fx select 'PU', id from r;
with r as (insert into public.collection_points (client_id, name, kind, district) values ('00000000-0000-4000-8000-000000000201', 'Bansi centre', 'centre', 'Siddharthnagar') returning id) insert into fx select 'CP', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 5, 'kg', 'jute', 'domestic', 'sticker') returning id) insert into fx select 'SKU5', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
create temp table names as select (select name from public.farmers where id = t.farmer('01')) as farmer1, (select name from public.farmers where id = t.farmer('02')) as farmer2,
                                  (select display_name from public.app_users where id = t.u('06')) as qc, (select display_name from public.app_users where id = t.u('08')) as miller;
grant select on names to authenticated, anon;
create or replace function pg_temp.qc(p_qty numeric, p_sample text) returns jsonb language sql stable as $$
  select jsonb_build_object('qty_kg', p_qty, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                            'lab_id', (select id from fx where k = 'LAB'), 'report_no', 'GGL/2026/' || p_sample,
                            'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', p_sample) $$;
grant execute on function pg_temp.qc(numeric, text) to authenticated;

-- =====================================================================================================================
-- 1 · Scope 06: two farmers' lots → a collection batch (re-weighed 3 kg less) → QC takes 243 kg → 4 kg closed as floor
--     loss → sealed
-- =====================================================================================================================
insert into fx select 'L1', pg_temp.lot(t.scope('06'), t.farmer('01'), '{"gross_kg":102,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12.2,12.1]}');
insert into fx select 'L2', pg_temp.lot(t.scope('06'), t.farmer('02'), '{"gross_kg":152,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12.2,12.1]}');
select t.verify(pg_temp.f('L1'), t.u('15')); select t.verify(pg_temp.f('L2'), t.u('15'));
select t.as_user(t.u('15'));
insert into fx select 'B', pg_temp.ins(t.scope('06'), 'village_batch', pg_temp.f('L1'), t.u('15'),
  jsonb_build_object('source_footprint_ids', jsonb_build_array(pg_temp.f('L1'), pg_temp.f('L2')), 'bags', 4, 'reweighed_kg', 247));
select t.as_service(); select t.verify(pg_temp.f('B'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q', pg_temp.ins(t.scope('06'), 'qc', pg_temp.f('B'), t.u('06'), pg_temp.qc(243, 'S-61A'));
select app.close_lot(pg_temp.f('B'), 'Practice (test): swept from the floor, not fit to mill');
select t.as_service(); select t.attach(pg_temp.f('Q'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'R', pg_temp.ins(t.scope('06'), 'qr_activation', pg_temp.f('Q'), t.u('07'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('R'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_service();
create temp table codes as select k, (select footprint_code from public.footprints where id = fx.id) as code from fx where k in ('L1', 'L2', 'B', 'Q', 'R');
grant select on codes to authenticated, anon;
create or replace function pg_temp.c(p text) returns text language sql stable as $$ select code from codes where k = p $$;
grant execute on function pg_temp.c(text) to authenticated, anon;

-- E2.5 · the mass balance, per stage ------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table bal as select app.stage_balance(t.scope('06')) as b;
select t.ok((select (x->>'kg_in')::numeric = 250 and (x->>'kg_out')::numeric = 247 and (x->>'floor_loss_kg')::numeric = 3 and (x->>'closed_kg')::numeric = 4
                    and (x->>'handed_on_kg')::numeric = 243 and (x->>'left_kg')::numeric = 0 and (x->>'difference_kg')::numeric = 0 and (x->>'balanced')::boolean
               from bal, pg_temp.stage(b, 'village_batch') x),
            'E2.5: the collection batch: 250 kg came in = 243 on to QC + 3 lost on re-weighing + 4 closed as floor loss + 0 left');
select t.ok((select (x->>'kg_in')::numeric = 250 and (x->>'handed_on_kg')::numeric = 250 and (x->>'balanced')::boolean from bal, pg_temp.stage(b, 'procurement') x)
            and (select (x->>'kg_in')::numeric = 243 and (x->>'other_kg')::numeric = 1 and (x->>'handed_on_kg')::numeric = 242 and (x->>'balanced')::boolean
                   from bal, pg_temp.stage(b, 'qc') x)
            and (select (x->>'last')::boolean and (x->>'handed_on_kg')::numeric = 242 and (x->>'balanced')::boolean from bal, pg_temp.stage(b, 'qr_activation') x),
            'E2.5: the farm gate (both lots went into the batch whole), QC (1 kg sample), the seal (the chain''s end): each closes');
select t.as_user(t.u('12'));
select t.fails(format('select app.stage_balance(%L)', t.scope('06')), 'not allowed to read this scope', 'another client''s person reads no balance');
select t.as_anon();
select t.fails(format('select app.stage_balance(%L)', t.scope('06')), 'permission denied', 'nor does anyone signed out');

-- C1.5/E2.5 · the closure is its own line in the journey and the season -------------------------------------------------
select t.as_user(t.u('03'));
create temp table jb as select app.export_journey(pg_temp.f('R'), 'shareable') as e;
select t.ok((select jsonb_array_length(e->'rows') = 6 from jb)
            and (select r->pg_temp.col(e, 'floor_loss_kg') = '4'::jsonb and r->pg_temp.col(e, 'recorded_by') = to_jsonb((select qc from names))
                        and r->pg_temp.col(e, 'note') = '"Practice (test): swept from the floor, not fit to mill"'::jsonb
                        and r->pg_temp.col(e, 'status') = '"closed"'::jsonb and r->pg_temp.col(e, 'step') = 'null'::jsonb
                   from jb, pg_temp.line(e, pg_temp.c('B'), 'floor_loss_closure') r),
            'E2.5: "Closed as floor loss": its own line after the batch, with the kilograms, when, by whom and why');
select t.ok((select (select array_agg(r->>pg_temp.col(e, 'code') order by i) from jsonb_array_elements(e->'rows') with ordinality x(r, i))
                    = array[pg_temp.c('L1'), pg_temp.c('L2'), pg_temp.c('B'), pg_temp.c('B'), pg_temp.c('Q'), pg_temp.c('R')] from jb),
            'E2.5: the lines read 100 + 150 kg in, the batch 247 kg, its 4 kg closed, QC 243 kg: the kilograms add up');
select t.ok((select pg_temp.cell(e, pg_temp.c('B'), 'floor_loss_kg') = '3'::jsonb and pg_temp.cell(e, pg_temp.c('B'), 'farmers') = '2'::jsonb
                    and pg_temp.cell(e, pg_temp.c('B'), 'villages') = '"Itwa 60.0 %; Bansi 40.0 %"'::jsonb from jb),
            'C1.2: the batch: its re-weighing loss, its farmers and villages with their shares');
create temp table sb as select app.export_season(t.scope('06'), 'shareable') as e;
select t.ok((select (e->'totals'->>'closed_kg')::numeric = 4 and (e->'totals'->>'floor_loss_kg')::numeric = 3 and (e->'totals'->>'differences')::int = 0
                    and (pg_temp.stage(e->'summary', 'village_batch')->>'closed_kg')::numeric = 4 and e->>'generated_by' is not null from sb),
            'C2/E2.5: the season''s summary: closed as floor loss apart from the floor loss, no difference; who made it');

-- E2.3 · the public page: every purchase of the batch, as one line ------------------------------------------------------
select t.as_anon();
create temp table pj as select app.public_lot_journey((select code from seal)) as j;
select t.ok((select j->'journey'->0->>'stage' = 'purchases' and (j->'journey'->0->>'qty_out_kg')::numeric = 250 and (j->'journey'->0->>'farmers_n')::int = 2
                    and j->'journey'->0->'villages' @> '[{"village": "Itwa", "qty_kg": 150, "share_pct": 60.0, "farmers": 1}, {"village": "Bansi", "qty_kg": 100, "share_pct": 40.0, "farmers": 1}]'
               from pj),
            'E2.3: "Bought from 2 farmers: 250 kg", with the villages'' shares (both purchases, not the one the batch points back to)');
select t.ok((select not exists (select 1 from jsonb_array_elements(j->'journey') s where s->>'stage' = 'procurement')
                    and (select (s->>'villages_n')::int = 2 and jsonb_array_length(s->'farmers') = 2 from jsonb_array_elements(j->'journey') s where s->>'stage' = 'village_batch')
                    and position((select farmer1 from names) in j::text) = 0 and position((select farmer2 from names) in j::text) = 0 from pj),
            'E2.3: the batch says 2 farmers from 2 villages; no single purchase line; no farmer''s name');

-- migration 61b (staging, 20 Oct): two villages whose names differ only in spelling ("bansi" and "Bansi", as typed) are
-- counted on the new lines as the page's heading counts them, and so in the export
select t.as_service();
set local session_replication_role = replica;                      -- a farmer's village typed another way (test only)
update public.farmers set village = 'bansi' where id = t.farmer('02');
set local session_replication_role = origin;
select t.as_anon();
select t.ok((select jsonb_array_length(j->'villages') = 2
                    and (select (s->>'villages_n')::int from jsonb_array_elements(j->'journey') s where s->>'stage' = 'village_batch') = 2
                    and jsonb_array_length(j->'journey'->0->'villages') = 2
               from (select app.public_lot_journey((select code from seal)) j) x),
            'E2.3 (61b): one page, one count: the heading, the batch line and the purchases line all say 2 villages');
select t.as_user(t.u('03'));
select t.ok((select pg_temp.cell(e, pg_temp.c('B'), 'villages') = '"bansi 60.0 %; Bansi 40.0 %"'::jsonb from (select app.export_journey(pg_temp.f('R'), 'shareable') e) x),
            'E2.3 (61b): the export counts them the same way');

-- C4 · the trace page: the scope's heading for the print, each step's parts and its closure --------------------------------
select t.as_user(t.u('03'));
select t.ok((select tr->'scope'->>'client' is not null and tr->'scope'->>'season' is not null
                    and (select (s->'closure'->>'kg')::numeric = 4 and (s->'parts'->>'floor_loss')::numeric = 3 from jsonb_array_elements(tr->'steps') s where s->>'stage' = 'village_batch')
               from (select app.lot_trace(pg_temp.f('R')) tr) x),
            'C4/E2.5: the trace names client, crop and season for its printed heading; the batch''s closure and floor loss');

-- =====================================================================================================================
-- 2 · Scope 05: a farm-gate lot with its place and agent → QC → milling (by-products) → packing by size → a sale to a
--     buyer → a shipment by lorry
-- =====================================================================================================================
select t.as_service();
update public.scopes set record_price = true where id = t.scope('05');      -- the price paid is recorded (the scope asks it)
insert into fx select 'P', pg_temp.lot(t.scope('05'), t.farmer('01'), jsonb_build_object('gross_kg', 306, 'bags', 3, 'tare_kg_per_bag', 2, 'moisture_pct', jsonb_build_array(12, 12.2, 12.1),
  'collection_point_id', pg_temp.f('CP'), 'gps_lat', 27.21, 'gps_lng', 82.95, 'delivered_by', 'agent', 'agent_name', 'Ramesh (agent)', 'condition', 'good',
  'harvest_date', '2026-10-01', 'price_per_quintal', 5217, 'payment_status', 'paid', 'payment_mode', 'upi', 'txn_ref', 'UTR-61-TEST'));
select t.verify(pg_temp.f('P'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q5', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'), pg_temp.qc(300, 'S-61B'));
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q5'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q5'), t.u('08'), jsonb_build_object('input_kg', 299, 'head_rice_kg', 190, 'broken_kg', 20,
  'husk_kg', 60, 'bran_kg', 26, 'mill_id', pg_temp.f('MILL'), 'line_clearance', 'fully_cleaned', 'mill_operator', 'Shyam (operator)', 'polish', 'medium'));
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));

-- E2.4 · the shelf life of the crop for the pack's material (61c: a warning, not a refusal) --------------------------------------------
select t.as_service();
create temp table crop as select c.id, c.shelf_life_days, c.shelf_life_by_material from public.crops c join public.scopes s on s.crop_id = c.id where s.id = t.scope('05');
update public.crops set shelf_life_days = null, shelf_life_by_material = '{"pouch": 300}' where id = (select id from crop);
create or replace function pg_temp.pack(p jsonb) returns uuid language sql as $$ select pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'), p) $$;
grant execute on function pg_temp.pack(jsonb) to authenticated;
select t.as_user(t.u('09'));
-- migration 61c (Veda, 20 Oct 2026: "DONT MAKE THIS MANDATORY"): Packing goes ahead without a shelf life, with a warning
create or replace function pg_temp.pv(p jsonb) returns jsonb language sql as $$
  select app.preview_reconcile(t.scope('05'), 'packing', pg_temp.f('M'), p, null, false, null, false) $$;
grant execute on function pg_temp.pv(jsonb) to authenticated;
select t.ok((select (r->>'ok')::boolean and r->'warnings' ? 'no shelf life is set for this crop and pack material (jute): these packs carry no best-before date (the State Manager sets it)'
               from (select pg_temp.pv(format('{"input_kg":188,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":100,"size_kg":1},{"sku_id":"%s","units":17,"size_kg":5}]}',
                                              pg_temp.f('PU'), pg_temp.f('SKU1'), pg_temp.f('SKU5'))::jsonb) r) x),
            'E2.4 (61c): no shelf life for jute bags of this crop: Packing goes ahead, with a warning that names the material');
select t.ok((select (r->>'ok')::boolean and r->'warnings' ? 'no shelf life is set for this crop: these packs carry no best-before date (the State Manager sets it)'
               from (select pg_temp.pv('{"input_kg":10,"packets":[{"units":10,"size_kg":1}]}') r) x),
            'E2.4 (61c): packs not from the list while the crop has no shelf life of its own: likewise');
select t.ok((select (r->>'ok')::boolean and not exists (select 1 from jsonb_array_elements_text(r->'warnings') w where w like 'no shelf life%')
               from (select pg_temp.pv(format('{"input_kg":100,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":100,"size_kg":1}]}', pg_temp.f('PU'), pg_temp.f('SKU1'))::jsonb) r) x),
            'E2.4: pouches, which have a shelf life, are packed without the warning');
select t.as_service();
update public.crops set shelf_life_days = 365, shelf_life_by_material = '{"jute": 270}' where id = (select id from crop);
select t.as_user(t.u('09'));
insert into fx select 'K', pg_temp.pack(format('{"input_kg":188,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":100,"size_kg":1},{"sku_id":"%s","units":17,"size_kg":5}]}',
                                               pg_temp.f('PU'), pg_temp.f('SKU1'), pg_temp.f('SKU5'))::jsonb);
select t.ok((select min(best_before) = min(packed_on) + 270 and max(best_before) = min(packed_on) + 365 from public.packs where footprint_id = pg_temp.f('K')),
            'E2.4: each pack''s best-before date: packed on + the shelf life of its material (jute 270 days, the crop 365)');
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
insert into fx select 'D', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-61","packs":[{"sku_id":"%s","units":10}],"price_per_kg":120,"currency":"INR"}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D'));
select t.as_service();
create temp table serd as select array_agg(serial order by serial) as s from (select serial from public.packs where footprint_id = pg_temp.f('K') and sku_id = pg_temp.f('SKU1') order by serial limit 10) x;
grant select on serd to authenticated;
select t.as_user(t.u('14'));
insert into fx select 'S', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('D'), t.u('14'),
  format('{"invoice_no":"INV-61","vehicle_no":"UP53AB1234","transporter":"Basti Roadways","driver_phone":"98390 12345","lr_no":"LR-61","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":10}]}',
         pg_temp.f('SKU1'))::jsonb || jsonb_build_object('serials', to_jsonb((select s from serd))));
select t.as_service();
insert into codes select k, (select footprint_code from public.footprints where id = fx.id) from fx where k in ('P', 'Q5', 'M', 'K', 'D', 'S');

-- C1/E2.2 · the season of scope 05, shareable, as the Client Manager -------------------------------------------------------
select t.as_user(t.u('03'));
create temp table s5 as select app.export_season(t.scope('05'), 'shareable') as e;
select t.ok((select pg_temp.cell(e, pg_temp.c('M'), 'head_rice_kg') = '190'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'broken_kg') = '20'::jsonb
                    and pg_temp.cell(e, pg_temp.c('M'), 'husk_kg') = '60'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'bran_kg') = '26'::jsonb
                    and pg_temp.cell(e, pg_temp.c('M'), 'husk_pct') = '20.1'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'head_rice_pct') = '63.5'::jsonb
                    and pg_temp.cell(e, pg_temp.c('M'), 'floor_loss_kg') = '3'::jsonb from s5),
            'E2.2: milling 299 kg: head rice 190 (63.5 %), broken 20, husk 60 (20.1 %), bran 26, each its own column; the floor loss 3 kg, not 109');
select t.ok((select (x->>'by_products_kg')::numeric = 106 and (x->>'floor_loss_kg')::numeric = 3 and (x->>'balanced')::boolean
               from s5, pg_temp.stage(e->'summary', 'milling') x)
            and (select (e->'totals'->'by_products'->>'husk_kg')::numeric = 60 and (e->'totals'->>'by_products_kg')::numeric = 106 from s5),
            'E2.2: the season''s summary and totals list the by-products apart from the losses');
select t.ok((select (x->>'left_kg')::numeric = 2 from s5, pg_temp.stage(e->'summary', 'milling') x)
            and (select bool_and((x->>'balanced')::boolean) from s5, jsonb_array_elements(e->'summary') x),
            'E2.5: every stage of the season closes (milling''s 2 kg not yet packed are "left")');
select t.ok((select pg_temp.cell(e, pg_temp.c('M'), 'mill') = '"Hired mill"'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'line_clearance') = '"fully_cleaned"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('K'), 'packing_unit') = '"Basti packers"'::jsonb and pg_temp.cell(e, pg_temp.c('K'), 'fssai_licence') = '"12345678901234"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('P'), 'collection_point') = '"Bansi centre"'::jsonb
                    and position(pg_temp.f('MILL')::text in e::text) = 0 and position(pg_temp.f('PU')::text in e::text) = 0 and position(pg_temp.f('BUY')::text in e::text) = 0 from s5),
            'C1.1: names, not ids: the mill, the packing unit and its FSSAI licence, the collection point; no id anywhere');
select t.ok((select pg_temp.cell(e, pg_temp.c('K'), 'packs_by_size') = '"17 × 5 kg jute, 100 × 1 kg pouch"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('K'), 'best_before') = to_jsonb(((select min(packed_on) from public.packs where footprint_id = pg_temp.f('K')) + 270)::text) from s5)
            and (select b->>'by_size' = '17 × 5 kg jute, 100 × 1 kg pouch' from s5, jsonb_array_elements(e->'batches') b),
            'C1.4/E2.4: packs counted by size, and the earliest best-before date, on the record and the batch');
select t.ok((select pg_temp.cell(e, pg_temp.c('P'), 'gross_kg') = '306'::jsonb and pg_temp.cell(e, pg_temp.c('P'), 'bags') = '3'::jsonb
                    and pg_temp.cell(e, pg_temp.c('P'), 'moisture_readings') = '"12 / 12.2 / 12.1"'::jsonb and pg_temp.cell(e, pg_temp.c('P'), 'delivered_by') = '"agent"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('S'), 'invoice_no') = '"INV-61"'::jsonb and pg_temp.cell(e, pg_temp.c('S'), 'lr_no') = '"LR-61"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('S'), 'vehicle_no') is not null and pg_temp.cell(e, pg_temp.c('D'), 'order_no') = '"PO-61"'::jsonb from s5),
            'C1.2: a column per field: gross, bags, the three moisture readings, who delivered; invoice, LR, vehicle; the order');
select t.ok((select pg_temp.cell(e, pg_temp.c('D'), 'buyer') = '"Delhi Wholesale"'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'recorded_by') = to_jsonb((select miller from names))
                    and position((select farmer1 from names) in e::text) = 0 and position('Ramesh (agent)' in e::text) = 0 and position('98390' in e::text) = 0
                    and position('5217' in e::text) = 0 and position('UTR-61-TEST' in e::text) = 0 and not (e->'columns' ? 'raw_values') from s5),
            'C3: the shareable copy names the buyer and the staff; no farmer, agent or driver''s phone, no price, no raw values');
select t.ok((select not (e->'columns' ?| array['vessel', 'container_no', 'port_loading', 'bl_no', 'source_name', 'water_removed_kg']) from s5),
            'C1.2: a column no record fills is left out (no vessel or container for a lorry)');

-- C1.3 · prices only in the internal copy, and only where the scope records prices ----------------------------------------
select t.as_service(); update public.scopes set record_price = false where id = t.scope('05');   -- then the Client Manager turns it off
select t.as_user(t.u('03'));
create temp table i5 as select app.export_season(t.scope('05'), 'internal') as e;
select t.ok((select not (e->'columns' ?| array['price_per_quintal', 'payment_ref', 'price_per_kg', 'total_value']) and position('5217' in e::text) = 0
                    and position('UTR-61-TEST' in e::text) = 0 and position('"price_per_kg"' in e::text) = 0
                    and e->'columns'->>-1 = 'raw_values' and pg_temp.cell(e, pg_temp.c('P'), 'farmer_name') = to_jsonb((select farmer1 from names))
                    and pg_temp.cell(e, pg_temp.c('P'), 'agent_name') = '"Ramesh (agent)"'::jsonb and pg_temp.cell(e, pg_temp.c('S'), 'driver_phone') is not null from i5),
            'C1.3: the scope does not record prices (any more): the internal copy has the farmer, the agent, the driver''s phone and the raw values, but no price');
select t.as_service(); update public.scopes set record_price = true where id = t.scope('05');
select t.as_user(t.u('03'));
create temp table i5p as select app.export_season(t.scope('05'), 'internal') as e;
select t.ok((select pg_temp.cell(e, pg_temp.c('P'), 'price_per_quintal') = '5217'::jsonb and pg_temp.cell(e, pg_temp.c('P'), 'payment_ref') = '"UTR-61-TEST"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('D'), 'price_per_kg') = '120'::jsonb and pg_temp.cell(e, pg_temp.c('D'), 'currency') = '"INR"'::jsonb from i5p)
            and (select position('5217' in e::text) = 0 and position('UTR-61-TEST' in e::text) = 0 from (select app.export_season(t.scope('05'), 'shareable') e) x),
            'C1.3: with "Record price" ticked: the prices and the transaction ID in the internal copy; never in the shareable one');

-- E2.4 · the pack page shows the best-before date; records of before say it was not recorded --------------------------------
select t.as_service();
create temp table pk1 as select serial, (packed_on + 365)::text as bb from public.packs where footprint_id = pg_temp.f('K') and sku_id = pg_temp.f('SKU1') order by serial limit 1;
grant select on pk1 to anon;
select t.as_anon();
select t.ok((select j->'pack'->>'best_before' = (select bb from pk1) and not (j->>'released')::boolean
               from (select app.public_pack((select serial from pk1)) j) x),
            'E2.4: a pack before release shows its best-before date');
select t.as_service();
set local session_replication_role = replica;                      -- a record of before migration 50's shelf life (test only)
update public.packs set best_before = null where footprint_id = pg_temp.f('K');
set local session_replication_role = origin;
select t.as_user(t.u('03'));
select t.ok((select pg_temp.cell(e, pg_temp.c('K'), 'best_before') = '"not_recorded"'::jsonb from (select app.export_season(t.scope('05'), 'shareable') e) x),
            'E2.4: packs of before without one: "not recorded (old data)", never a guessed date');

-- E2.5 · a forced difference shows ---------------------------------------------------------------------------------------
select t.as_service();
set local session_replication_role = replica;                      -- a record that holds more than came in (test only)
update public.footprints set qty_out = qty_out + 5 where id = pg_temp.f('B');
set local session_replication_role = origin;
select t.as_user(t.u('03'));
select t.ok((select (x->>'difference_kg')::numeric = 5 and not (x->>'balanced')::boolean from pg_temp.stage(app.stage_balance(t.scope('06')), 'village_batch') x)
            and (select (e->'totals'->>'differences')::int = 1 from (select app.export_season(t.scope('06'), 'shareable') e) x),
            'E2.5: 5 kg that cannot be accounted for show as a difference, in the balance and in the season''s totals');

rollback;
