-- Migration 62 (Phase 1, release 4 of Veda's combined brief of 19 Oct 2026: E2.1 "Only shipped packs are released").
--   1  a pack goes live only when a sealed shipment carries its code; the other packs of its batch stay "not released"
--   2  a shipment of packs records their codes, also a packed lot sold by kilograms in a scope without the details (they
--      weigh what is shipped); a second shipment's packs go live with its own seal
--   3  a lot whose shipment recorded no codes releases its batch's packs as "serials not recorded (old data)"
--   4  the lot page counts the packs that went live; the QR step's summary says how many go live and how many stay held;
--      the season export counts each batch's packs released, released without serials, held and void
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.ins(p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('05'), '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 5, 'kg', 'jute', 'domestic', 'sticker') returning id) insert into fx select 'SKU5', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
create or replace function pg_temp.ship(p_from uuid, p_lines jsonb, p_serials jsonb) returns uuid language sql as $$
  select pg_temp.ins('shipment', p_from, t.u('14'), jsonb_build_object('invoice_no', 'INV-' || left(md5(random()::text), 6), 'vehicle_no', 'UP53AB1234',
    'lr_no', 'LR-62', 'dispatch_date', '2026-10-20', 'destination', 'Delhi', 'packs', p_lines, 'serials', p_serials)) $$;
grant execute on function pg_temp.ship(uuid, jsonb, jsonb) to authenticated;

-- the chain up to Packing: 20 pouches of 1 kg and 8 jute bags of 5 kg (batch K), and 4 bags of 5 kg not from the pack list (batch K2)
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('01'), 132, 2, 1, 11.8, 11.7, 11.9);
select t.verify(pg_temp.f('P'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q', pg_temp.ins('qc', pg_temp.f('P'), t.u('06'), jsonb_build_object('qty_kg', 130, 'sample_qty_kg', 1,
  'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2), 'lab_id', pg_temp.f('LAB'),
  'report_no', 'GGL/2026/62', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-62'));
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":129,"head_rice_kg":80,"broken_kg":10,"husk_kg":30,"bran_kg":6}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins('packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":60,"packets":[{"sku_id":"%s","units":20,"size_kg":1},{"sku_id":"%s","units":8,"size_kg":5}]}', pg_temp.f('SKU1'), pg_temp.f('SKU5'))::jsonb);
insert into fx select 'K2', pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":20,"packets":[{"units":4,"size_kg":5}]}');
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K')); select app.verify_footprint(pg_temp.f('K2'));
select t.as_service();
create temp table kp as select serial, sku_id, footprint_id, row_number() over (partition by footprint_id, sku_id order by serial) as n from public.packs where footprint_id in (pg_temp.f('K'), pg_temp.f('K2'));
grant select on kp to authenticated, anon;
create or replace function pg_temp.s(p_fp text, p_sku text, p_n int) returns text language sql stable as $$
  select serial from kp where footprint_id = pg_temp.f(p_fp) and sku_id is not distinct from pg_temp.f(p_sku) and n = p_n $$;
create or replace function pg_temp.codes(p_fp text, p_sku text, p_from int, p_to int) returns jsonb language sql stable as $$
  select jsonb_agg(serial order by serial) from kp where footprint_id = pg_temp.f(p_fp) and sku_id is not distinct from pg_temp.f(p_sku) and n between p_from and p_to $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- the first order (5 pouches) and its shipment with their codes, sealed ---------------------------------------------------
select t.as_user(t.u('11'));
insert into fx select 'D1', pg_temp.ins('commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-62-1","packs":[{"sku_id":"%s","units":5}]}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D1'));
insert into fx select 'S1', pg_temp.ship(pg_temp.f('D1'), format('[{"sku_id":"%s","units":5}]', pg_temp.f('SKU1'))::jsonb, pg_temp.codes('K', 'SKU1', 1, 5));
select t.as_service(); select t.attach(pg_temp.f('S1'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('S1'));
insert into fx select 'R1', pg_temp.ins('qr_activation', pg_temp.f('S1'), t.u('07'), '{}');
create temp table seal1 as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal1 to anon, authenticated;

select t.as_anon();
select t.ok((select (j->>'released')::boolean and not (j->'pack'->>'old_data')::boolean and j->>'qr_code' = (select code from seal1)
               from (select app.public_pack(pg_temp.s('K', 'SKU1', 1)) j) x),
            '1: a pack the sealed shipment carries is live, with its lot''s record');
select t.ok((select not (j->>'released')::boolean and j ? 'crop' and not (j ? 'journey')
               from (select app.public_pack(pg_temp.s('K', 'SKU1', 6)) j) x)
            and (select not (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU5', 1)) j) x),
            '1: a pack of the same batch that was not shipped stays "Packed, not yet released" (E2.1: B0001-0150)');
select t.ok((select (j->'packs'->>'n')::int = 5 and not (j->'packs'->>'old_data')::boolean from (select app.public_lot_journey((select code from seal1)) j) x),
            '4: the lot page counts the 5 packs that went live, not the 28 of the batch');

-- a pack voided before it is sold says so; the second order's packs wait for their own seal --------------------------------
select t.as_user(t.u('09')); select app.void_pack(pg_temp.s('K', 'SKU1', 20), 'pouch torn at the store (test)');
select t.as_user(t.u('11'));
insert into fx select 'D2', pg_temp.ins('commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-62-2","packs":[{"sku_id":"%s","units":3}]}', pg_temp.f('BUY'), pg_temp.f('SKU5'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D2'));
select t.fails(format($$select pg_temp.ship(%L, %L, %L)$$, pg_temp.f('D2'), format('[{"sku_id":"%s","units":3}]', pg_temp.f('SKU5')), pg_temp.codes('K', 'SKU1', 1, 3)),
               'shipped already', '2: a code already shipped in another shipment is refused');
select t.fails(format($$select pg_temp.ship(%L, %L, %L)$$, pg_temp.f('D2'), format('[{"sku_id":"%s","units":3}]', pg_temp.f('SKU5')), jsonb_build_array(pg_temp.s('K', 'SKU1', 20))),
               'not a pack of this order''s batch (or void)', '2: a void pack is refused');
insert into fx select 'S2', pg_temp.ship(pg_temp.f('D2'), format('[{"sku_id":"%s","units":3}]', pg_temp.f('SKU5'))::jsonb, pg_temp.codes('K', 'SKU5', 1, 3));
select t.as_anon();
select t.ok((select not (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU5', 2)) j) x)
            and (select (j->'pack'->>'void')::boolean and not (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU1', 20)) j) x),
            '2: packs in a shipment not yet sealed are not live; a voided pack says it is void');
select t.as_user(t.u('07'));
select t.ok((select (c->'vars'->>'n')::int = 3 and (c->'vars'->>'old')::int = 0 and (c->'vars'->>'held')::int = 19
               from jsonb_array_elements(app.release_preview(pg_temp.f('S2'))->'checks') c where c->>'key' = 'packs'),
            '4: the QR step''s summary: 3 packs go live with this seal, 19 of the batch stay held (28 − 5 live − 3 − 1 void)');
select t.as_service(); select t.attach(pg_temp.f('S2'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('S2'));
insert into fx select 'R2', pg_temp.ins('qr_activation', pg_temp.f('S2'), t.u('07'), '{}');
select app.seal_lot(pg_temp.f('R2'));
select t.as_anon();
select t.ok((select (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU5', 2)) j) x)
            and (select not (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU5', 4)) j) x),
            '2: the second shipment''s packs go live with its own seal; the rest still wait');

-- 3 · a lot shipped by kilograms (packs not from the pack list) ------------------------------------------------------------
select t.as_user(t.u('11'));
insert into fx select 'D3', pg_temp.ins('commercial', pg_temp.f('K2'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-62-3","qty_kg":20}', pg_temp.f('BUY'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D3'));
-- 2 · (migration 62) a packed lot ordered by kilograms, in a scope without the details: the codes are still asked, and
-- they weigh what is shipped; the Shipment form shows the codes field wherever the lot is packed
create or replace function pg_temp.ship_kg(p_serials jsonb) returns uuid language sql as $$
  select pg_temp.ins('shipment', pg_temp.f('D3'), t.u('14'), jsonb_build_object('vehicle_or_container', 'UP53AB1234', 'dispatch_date', '2026-10-20',
    'destination', 'Delhi', 'shipped_kg', 20) || case when p_serials is null then '{}'::jsonb else jsonb_build_object('serials', p_serials) end) $$;
grant execute on function pg_temp.ship_kg(jsonb) to authenticated;
select t.fails('select pg_temp.ship_kg(null)', 'scan or type the codes of the packs loaded', '2: a packed lot sold by kilograms is shipped by its codes too');
select t.fails(format('select pg_temp.ship_kg(%L)', pg_temp.codes('K2', null, 1, 3)), 'the packs loaded weigh 15 kg, the shipment 20 kg',
               '2: the codes weigh what is shipped (3 bags of 5 kg are not 20 kg)');
select t.ok((select f->>'when_packed' = 'true' and not f ? 'shown_when' from public.stage_definitions d, jsonb_array_elements(d.form_schema) f
              where d.stage_type = 'shipment' and f->>'key' = 'serials'),
            '2: the Shipment form asks the codes wherever the lot is packed, not only where the scope asks the details');
insert into fx select 'S3', pg_temp.ship_kg(pg_temp.codes('K2', null, 1, 4));
select t.ok((select qty_out = 20 and (computed->>'serials_count')::int = 4 from public.footprints where id = pg_temp.f('S3')),
            '2: 4 bags of 5 kg by their codes: 20 kg shipped (no invoice asked where the scope asks no details)');
select t.as_service(); select t.attach(pg_temp.f('S3'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('S3'));
insert into fx select 'R3', pg_temp.ins('qr_activation', pg_temp.f('S3'), t.u('07'), '{}');
create temp table seal3 as select (app.seal_lot(pg_temp.f('R3'))).qr_code as code;
grant select on seal3 to anon, authenticated;
-- 3 · a shipment of before that recorded no codes (made so here by taking its codes away; test only)
select t.as_service();
set local session_replication_role = replica;
update public.footprints set payload = payload - 'serials' where id = pg_temp.f('S3');
set local session_replication_role = origin;
select t.as_anon();
select t.ok((select (j->>'released')::boolean and (j->'pack'->>'old_data')::boolean and j->>'qr_code' = (select code from seal3)
               from (select app.public_pack(pg_temp.s('K2', null, 1)) j) x),
            '3: a lot whose shipment recorded no codes: its packs say "Released, serials not recorded"; no serial is guessed');
select t.ok((select (j->'packs'->>'n')::int = 4 and (j->'packs'->>'old_data')::boolean from (select app.public_lot_journey((select code from seal3)) j) x)
            and (select not (j->>'released')::boolean from (select app.public_pack(pg_temp.s('K', 'SKU5', 4)) j) x),
            '3: and only its own batch: batch K''s held packs stay held');

-- 4 · the season counts each batch's packs ---------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table sx as select app.export_season(t.scope('05'), 'shareable') as e;
select t.ok((select (b->>'released')::int = 8 and (b->>'released_old')::int = 0 and (b->>'held')::int = 19 and (b->>'void')::int = 1
               from sx, jsonb_array_elements(e->'batches') b where b->>'batch_code' = (select payload->>'batch_code' from public.footprints where id = pg_temp.f('K')))
            and (select (b->>'released_old')::int = 4 and (b->>'held')::int = 0
               from sx, jsonb_array_elements(e->'batches') b where b->>'batch_code' = (select payload->>'batch_code' from public.footprints where id = pg_temp.f('K2'))),
            '4: the season: batch K 8 released, 19 held, 1 void; batch K2 4 released without serials');
rollback;
