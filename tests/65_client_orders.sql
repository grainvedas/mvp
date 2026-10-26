-- Migration 70 (Phase 3, release 3 of Veda's combined brief of 19 Oct 2026: Part D, with item 67's display fixes).
--   1  a client order is made by whoever holds Commercial in an active scope of the client and crop (or runs one, or the
--      admin); never by a client account, another client's person or someone without Commercial; its number and its
--      invoice are the client's only once
--   2  a part from Uttar Pradesh and a part from Assam (the same client and crop): the order's buyer, market and number
--      replace the form's; each pack keeps its batch and scope
--   3  a part is refused: another client's order, another crop, a cancelled order, the client not Active in the state, a
--      batch that failed the order's market, a batch of another GI or farm-verified status
--   4  one invoice: each shipment of a part carries the order's (filled in; another refused; none yet refused); fixed
--      once shipped
--   5  the order's page: one section per scope (UP and Assam), one invoice; each reader sees the sections of the scopes
--      he reaches, prices only where he may; another client's people and the public see nothing
--   6  cancelling: only while it has no part, with a reason; a cancelled order takes no part
--   7  the client's views: Across scopes and its export list the client order and name it on each part
--   8  item 67 (1): an older QC record's "Lab reference" is its lab in the client's scope view
--   9  the Commercial form offers the open orders a batch fits (and says why another does not); grants
--  10  found while checking: the farmer register's possible duplicates are read inside the database only
-- Scope 05 (Basti mill, Uttar Pradesh): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) →
-- Shipment (14) → QR (07). Scope N (Nagaon mill, Assam, made here): the same chain, Commercial Ravi Kumar (18), Shipment
-- the grading operator (10), QR the lot inward operator (13). 03 the Client Manager of client 201; 12 the other client's.
-- Fake, format-valid numbers only.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
create or replace function pg_temp.audited(p_action text, p_target uuid) returns boolean language sql security definer as $$
  select exists (select 1 from public.audit_log where action = p_action and target = p_target) $$;
create or replace function pg_temp.login(p uuid) returns void language sql security definer as $$ update public.app_users set auth_uid = p where id = p $$;
create or replace function pg_temp.tab(e jsonb, k text) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(e->'tables') x where x->>'key' = k $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- Assam: the client Active there; Nagaon mill, the same crop and chain as Basti mill, its people on its stages
insert into public.client_states (client_id, state_id, status, legacy) values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'active', true)
  on conflict (client_id, state_id) do update set status = 'active';
insert into fx values ('N', '00000000-0000-4000-8000-000000000488');
insert into public.scopes (id, client_id, state_id, crop_id, season_code, geography, chain, status, market_codes, tolerances, quality_params,
                           qc_report_required, record_price, procurement_details_required, stage_details_required)
select pg_temp.f('N'), s.client_id, '00000000-0000-4000-8000-000000000002', s.crop_id, s.season_code, 'Nagaon mill', s.chain, 'draft', s.market_codes,
       s.tolerances, s.quality_params, s.qc_report_required, s.record_price, s.procurement_details_required, s.stage_details_required
  from public.scopes s where s.id = t.scope('05');      -- Basti mill's settings
do $x$ declare a uuid; r record; begin
  perform set_config('app.assigning', 'on', true);
  for r in select * from (values ('procurement'::public.stage_type, t.u('05')), ('qc', t.u('06')), ('milling', t.u('08')), ('packing', t.u('09')),
                                  ('commercial', t.u('18')), ('shipment', t.u('10')), ('qr_activation', t.u('13'))) v(st, u) loop
    insert into public.assignments (employee_id, lens, op_role, scope_id, stages, created_by)
    values (r.u, 'scope', 'operator', pg_temp.f('N'), array[r.st], r.u) returning id into a;
    insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (r.u, pg_temp.f('N'), r.st, a);
  end loop;
  perform set_config('app.assigning', '', true);
end $x$;
update public.scopes set status = 'active' where id = pg_temp.f('N');

with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-7001', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000002', 'Guwahati Grain Lab', 'TC-7002', 'external', 'Guwahati') returning id)
insert into fx select 'LABA', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Kolkata Traders', 'IN', 'Burrabazar, Kolkata', '19AAACK1234E1Z5') returning id) insert into fx select 'BUY2', id from r;
with r as (insert into public.buyers (client_id, name, country, address) values ('00000000-0000-4000-8000-000000000201', 'Rotterdam Rice BV', 'NL', 'Maasvlakte, Rotterdam') returning id) insert into fx select 'EXB', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000202', 'Demox Buyer', 'IN', 'Okhla, New Delhi', '07AAACX1234E1Z5') returning id) insert into fx select 'XB', id from r;

-- a batch packed: procured (farm-verified or not), QC with its broken grains, milled, 20 pouches of 1 kg
create or replace function pg_temp.batch(p_scope uuid, p_tag text, p_fv boolean, p_broken numeric, p_lab uuid, p_pack_verifier uuid) returns uuid
language plpgsql as $$
declare v_p uuid; v_q uuid; v_m uuid; v_k uuid;
begin
  perform t.as_service();
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, farm_verified)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'),
          jsonb_build_object('gross_kg', 132, 'bags', 2, 'tare_kg_per_bag', 1, 'moisture_pct', jsonb_build_array(11.8, 11.7, 11.9),
            'collection_point_id', 'farm', 'gps_lat', 27.2, 'gps_lng', 83.0, 'delivered_by', 'farmer'), p_fv) returning id into v_p;
  perform t.verify(v_p, t.u('06'));
  perform t.as_user(t.u('06'));
  v_q := pg_temp.ins(p_scope, 'qc', v_p, t.u('06'), jsonb_build_object('qty_kg', 130, 'sample_qty_kg', 1,
    'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', p_broken, 'foreign_matter_pct', 0.2), 'lab_id', p_lab,
    'report_no', 'GL/2026/' || p_tag, 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-' || p_tag));
  perform t.as_user(t.u('08')); perform app.verify_footprint(v_q);
  v_m := pg_temp.ins(p_scope, 'milling', v_q, t.u('08'), '{"input_kg":129,"head_rice_kg":80,"broken_kg":10,"husk_kg":30,"bran_kg":6}');
  perform t.as_user(t.u('09')); perform app.verify_footprint(v_m);
  v_k := pg_temp.ins(p_scope, 'packing', v_m, t.u('09'),
    format('{"input_kg":20,"packets":[{"sku_id":"%s","units":20,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
  perform t.as_user(p_pack_verifier); perform app.verify_footprint(v_k);
  perform t.as_service();
  return v_k;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

insert into fx select 'KU', pg_temp.batch(t.scope('05'), '701', true, 2, pg_temp.f('LAB'), t.u('11'));     -- UP: passed both markets
insert into fx select 'KA', pg_temp.batch(pg_temp.f('N'), '702', true, 2, pg_temp.f('LABA'), t.u('18'));   -- Assam: passed both markets
insert into fx select 'KX', pg_temp.batch(t.scope('05'), '703', true, 4, pg_temp.f('LAB'), t.u('11'));     -- UP: domestic only (4 % broken)
insert into fx select 'KF', pg_temp.batch(t.scope('05'), '704', false, 2, pg_temp.f('LAB'), t.u('11'));    -- UP: not farm-verified
insert into fx select 'KU2', pg_temp.batch(t.scope('05'), '705', true, 2, pg_temp.f('LAB'), t.u('11'));    -- UP: for a second order
select t.as_service();
create temp table kp as select serial, footprint_id, row_number() over (partition by footprint_id order by serial) as n from public.packs
  where footprint_id in (select id from fx);
grant select on kp to authenticated, anon;
create or replace function pg_temp.codes(p_fp text, p_n int) returns jsonb language sql stable as $$
  select jsonb_agg(serial order by serial) from kp where footprint_id = pg_temp.f(p_fp) and n <= p_n $$;
create or replace function pg_temp.part(p_scope uuid, p_batch text, p_by uuid, p_order text, p_units int, p_extra jsonb default '{}'::jsonb) returns uuid
language sql as $$
  select pg_temp.ins(p_scope, 'commercial', pg_temp.f(p_batch), p_by,
    jsonb_build_object('client_order_id', pg_temp.f(p_order), 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', p_units))) || p_extra) $$;
create or replace function pg_temp.ship(p_scope uuid, p_part text, p_by uuid, p_batch text, p_units int, p_extra jsonb default '{}'::jsonb) returns uuid
language sql as $$
  select pg_temp.ins(p_scope, 'shipment', pg_temp.f(p_part), p_by, jsonb_build_object('vehicle_no', 'UP53AB1234', 'lr_no', 'LR-70',
    'dispatch_date', '2026-10-27', 'destination', 'Delhi', 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', p_units)),
    'serials', pg_temp.codes(p_batch, p_units)) || p_extra) $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- the client accounts: the owner (the admin's), a viewer of Basti mill only (the owner's); the other client's owner
select t.as_user(t.u('01'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner70@prasaadam.test');
insert into fx select 'OWN', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Owner', 'owner70@prasaadam.test');
select app.prepare_client_account('00000000-0000-4000-8000-000000000202', 'owner', 'owner70@demox.test');
insert into fx select 'OWN2', app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Demox Owner', 'owner70@demox.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OWN')); select pg_temp.login(pg_temp.f('OWN2'));
select t.as_user(pg_temp.f('OWN'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'viewer', 'viewer70@prasaadam.test', 'scopes', null, array[t.scope('05')]);
insert into fx select 'VW', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Basti mill Viewer', 'viewer70@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('VW'));

-- 1 · making an order ------------------------------------------------------------------------------------------------------
select t.as_user(t.u('11'));
select t.ok((select count(*) = 1 from jsonb_array_elements(app.client_order_choices()) x
              where x->>'client_id' = '00000000-0000-4000-8000-000000000201' and x->>'crop_id' = '00000000-0000-4000-8000-000000000101'
                and (x->'buyers') @> jsonb_build_array(jsonb_build_object('id', pg_temp.f('BUY'))) and (x->'markets') @> '[{"code":"domestic"},{"code":"export"}]'),
            '1: Commercial in Basti mill: he may make orders for the client and crop, with its buyers and its scopes'' markets');
insert into fx select 'O1', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'),
  'domestic', null, 'PO-70-1', 'INV-70-1', 'two mills, one lorry (test)')->>'id')::uuid;
select t.ok((select code ~ '^ORD-PRSDM-[0-9]{4}$' and market = 'domestic' and invoice_no = 'INV-70-1' and status = 'open' and created_by = t.u('11')
               from public.client_orders where id = pg_temp.f('O1')),
            '1: the order is made (ORD-PRSDM-0001: domestic, its invoice, open)');
select t.ok(pg_temp.audited('client_order_created', pg_temp.f('O1')),
            '1: and it is in the Audit log');
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', null, 'po-70-1')$q$,
               'is on another order', '1: the same order number twice is refused');
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', null, 'PO-70-9', 'inv-70-1')$q$,
               'one invoice per order', '1: an invoice already on another order is refused');
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('EXB'), 'export', '', 'EX-70-9')$q$,
               'destination country', '1: an export order names its destination country');
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('XB'), 'domestic', null, 'PO-70-8')$q$,
               'not one of this client', '1: a buyer of another client is refused');
select t.as_user(t.u('06'));
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', null, 'PO-70-2')$q$,
               'you may not make an order', '1: the QC technician (no Commercial) may not');
select t.as_user(t.u('12'));
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', null, 'PO-70-2')$q$,
               'you may not make an order', '1: another client''s operator may not');
select t.as_user(pg_temp.f('OWN'));
select t.fails($q$select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', null, 'PO-70-2')$q$,
               'you may not make an order', '1: the client''s owner may not (a client account makes no order)');
select t.fails($q$insert into public.client_orders (code, client_id, crop_id, buyer_id, market, market_code, order_no, created_by)
                  values ('ORD-X', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'), 'domestic', 'domestic', 'PO-X', pg_temp.f('OWN'))$q$,
               'permission denied', '1: nor writes the table');
select t.as_user(t.u('03'));
insert into fx select 'O2', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('EXB'),
  'export', 'Netherlands', 'EX-70-1')->>'id')::uuid;
select t.ok((select market = 'export' and market_code = 'export' and destination_country = 'Netherlands' and invoice_no is null from public.client_orders where id = pg_temp.f('O2')),
            '1: the Client Manager (he runs Basti mill) makes an export order, no invoice yet');
select t.as_user(t.u('18'));
insert into fx select 'O3', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY2'),
  'domestic', null, 'PO-70-3', 'INV-70-3')->>'id')::uuid;
select t.ok((select created_by = t.u('18') from public.client_orders where id = pg_temp.f('O3')), '1: Commercial in Nagaon mill (Assam) makes one too');

-- 2 · a part from each state --------------------------------------------------------------------------------------------------
select t.as_user(t.u('11'));
insert into fx select 'PU', pg_temp.part(t.scope('05'), 'KU', t.u('11'), 'O1', 6,
  jsonb_build_object('buyer_id', pg_temp.f('BUY2'), 'market', 'export', 'order_no', 'WRONG-1', 'price_per_kg', 120, 'currency', 'INR'));
select t.ok((select f.payload->>'buyer_id' = pg_temp.f('BUY')::text and f.payload->>'market' = 'domestic' and f.payload->>'order_no' = 'PO-70-1'
                    and f.computed->>'client_order' = (select code from public.client_orders where id = pg_temp.f('O1'))
                    and f.computed->>'client_order_id' = pg_temp.f('O1')::text and f.qty_out = 6
               from public.footprints f where f.id = pg_temp.f('PU')),
            '2: Basti mill''s part: the order''s buyer, market and number replace the form''s; 6 pouches, 6 kg; it names its order');
select t.as_user(t.u('18'));
insert into fx select 'PA', pg_temp.part(pg_temp.f('N'), 'KA', t.u('18'), 'O1', 4, '{"price_per_kg": 118, "currency": "INR"}');
select t.ok((select f.computed->>'client_order_id' = pg_temp.f('O1')::text and f.scope_id = pg_temp.f('N') and f.qty_out = 4
               from public.footprints f where f.id = pg_temp.f('PA')),
            '2: Nagaon mill''s part (Assam): 4 pouches of its own batch');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('PU'));
select t.as_user(t.u('10')); select app.verify_footprint(pg_temp.f('PA'));
select t.as_service();
select t.ok((select count(*) = 2 and count(distinct scope_id) = 2 from app.order_parts(pg_temp.f('O1'))), '2: the order has two parts, in two scopes');
select t.ok((select bool_and(p.scope_id = (select f.scope_id from public.footprints f where f.id = x.prev_footprint_id)) from app.order_parts(pg_temp.f('O1')) x
               join public.packs p on p.footprint_id = x.prev_footprint_id),
            '2: each pack keeps its batch and its scope');

-- 3 · the parts refused --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('11'));
select t.fails($q$select pg_temp.part(t.scope('05'), 'KX', t.u('11'), 'O2', 2)$q$, 'has not passed QC for the market',
               '3: a batch that failed the export market is refused for the export order');
insert into fx select 'PX', pg_temp.part(t.scope('05'), 'KX', t.u('11'), 'O3', 1);
select t.ok((select x.computed->>'client_order_id' = pg_temp.f('O3')::text from public.footprints x where x.id = pg_temp.f('PX')),
            '3: the same batch is a part of a domestic order (it passed domestic)');
select t.fails($q$select pg_temp.part(t.scope('05'), 'KF', t.u('11'), 'O1', 2)$q$, 'same GI status and farm-verified status',
               '3: a batch not farm-verified (so non-GI) is refused for an order of farm-verified batches (GI not confirmed: the crop names no GI district here)');
select t.ok(pg_temp.err($q$select pg_temp.part(t.scope('05'), 'KF', t.u('11'), 'O1', 2)$q$) like '%(the order: GI not confirmed, farm-verified; this batch: non-GI, not farm-verified)%',
            '3: and the refusal says both statuses');
select t.as_service();
insert into fx values ('OX', gen_random_uuid());
insert into public.client_orders (id, code, client_id, crop_id, buyer_id, market, market_code, order_no, created_by)
values (pg_temp.f('OX'), 'ORD-DEMOX-0001', '00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', pg_temp.f('XB'), 'domestic', 'domestic', 'PO-X-1', t.u('12'));
insert into fx values ('OC', gen_random_uuid());
insert into public.client_orders (id, code, client_id, crop_id, buyer_id, market, market_code, order_no, created_by)
values (pg_temp.f('OC'), 'ORD-PRSDM-0901', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000102', pg_temp.f('BUY'), 'domestic', 'domestic', 'PO-70-C', t.u('11'));
select t.as_user(t.u('11'));
select t.fails($q$select pg_temp.part(t.scope('05'), 'KU2', t.u('11'), 'OX', 1)$q$, 'that client order is not one of this client', '3: another client''s order is refused');
select t.fails($q$select pg_temp.part(t.scope('05'), 'KU2', t.u('11'), 'OC', 1)$q$, 'for another crop', '3: an order of another crop is refused');
select t.as_service();
update public.client_states set status = 'diagnostic' where client_id = '00000000-0000-4000-8000-000000000201' and state_id = '00000000-0000-4000-8000-000000000002';
select t.as_user(t.u('18'));
select t.fails($q$select pg_temp.part(pg_temp.f('N'), 'KA', t.u('18'), 'O3', 1)$q$, 'not Active in this scope''s state',
               '3: the client not Active in Assam: no part there');
select t.as_service();
update public.client_states set status = 'active' where client_id = '00000000-0000-4000-8000-000000000201' and state_id = '00000000-0000-4000-8000-000000000002';

-- 4 · one invoice ---------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('14'));
insert into fx select 'SU', pg_temp.ship(t.scope('05'), 'PU', t.u('14'), 'KU', 6);
select t.ok((select payload->>'invoice_no' = 'INV-70-1' and computed->>'invoice_no' = 'INV-70-1' from public.footprints where id = pg_temp.f('SU')),
            '4: Basti mill''s shipment carries the order''s invoice (filled in)');
select t.as_user(t.u('10'));
select t.fails($q$select pg_temp.ship(pg_temp.f('N'), 'PA', t.u('10'), 'KA', 4, '{"invoice_no": "INV-OTHER"}')$q$, 'has one invoice, INV-70-1',
               '4: Nagaon mill''s shipment with another invoice is refused');
insert into fx select 'SA', pg_temp.ship(pg_temp.f('N'), 'PA', t.u('10'), 'KA', 4, '{"invoice_no": "inv-70-1"}');
select t.ok((select payload->>'invoice_no' = 'INV-70-1' from public.footprints where id = pg_temp.f('SA')), '4: with the same invoice it saves: one invoice for both states');
select t.as_service(); select t.attach(pg_temp.f('SU'), 'loading_photo'); select t.attach(pg_temp.f('SA'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('SU'));
select t.as_user(t.u('13')); select app.verify_footprint(pg_temp.f('SA'));
select t.as_user(t.u('11'));
select t.fails($q$select app.client_order_invoice(pg_temp.f('O1'), 'INV-70-2')$q$, 'the invoice is fixed once a part has shipped',
               '4: the invoice of an order that shipped is fixed');
-- the export order: no invoice yet → its shipment is refused; set on the order, it ships
insert into fx select 'PE', pg_temp.part(t.scope('05'), 'KU2', t.u('11'), 'O2', 3);
select t.ok((select payload->>'market_code' = 'export' and payload->>'destination_country' = 'Netherlands' from public.footprints where id = pg_temp.f('PE')),
            '4: the export order''s part takes its market and destination');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('PE'));
select t.fails($q$select pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('PE'), t.u('14'), jsonb_build_object('container_no', 'MSKU1234567', 'seal_no', 'SL-70',
                  'shipping_bill_no', '1234567', 'dispatch_date', '2026-10-27', 'destination', 'Rotterdam',
                  'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', 3)), 'serials', pg_temp.codes('KU2', 3)))$q$,
               'has no invoice number yet', '4: an order with no invoice yet ships nothing');
select t.as_user(t.u('03'));
select t.ok((app.client_order_invoice(pg_temp.f('O2'), 'EXP/70/1')->>'invoice_no') = 'EXP/70/1'
            and pg_temp.audited('client_order_invoice', pg_temp.f('O2')),
            '4: the Client Manager sets its invoice (in the Audit log)');
select t.as_user(t.u('09'));
select t.fails($q$select app.client_order_invoice(pg_temp.f('O2'), 'EXP/70/2')$q$, 'order not found', '4: the packer may not set an invoice');

-- 5 · the order's page ------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
create temp table d1 as select app.client_order_detail(pg_temp.f('O1')) as j;
grant select on d1 to authenticated, anon;
select t.ok((select jsonb_array_length(j->'sections') = 2 and j->>'invoice_no' = 'INV-70-1' and (j->>'qty_kg')::numeric = 10 and (j->>'shipped_kg')::numeric = 10
                    and j->>'gi_status' = 'unknown' and (j->>'farm_verified')::boolean and (j->>'hidden_parts')::int = 0
                    and (select array_agg(s->>'state' order by s->>'state') from jsonb_array_elements(j->'sections') s) = array['Assam', 'Uttar Pradesh']
               from d1),
            '5: the admin: one order, one invoice, two sections (Assam and Uttar Pradesh), 10 kg sold and shipped, farm-verified (GI not confirmed)');
select t.ok((select (p->>'batch_code') is not null and p->'shipments'->0->>'invoice_no' = 'INV-70-1' and (p->>'qty_kg')::numeric = 4
               from d1, jsonb_array_elements(j->'sections') s, jsonb_array_elements(s->'parts') p where s->>'state' = 'Assam'),
            '5: Assam''s section: its batch, 4 kg, its shipment under the order''s invoice');
select t.as_user(t.u('11'));
select t.ok((select jsonb_array_length(j->'sections') = 1 and j->'sections'->0->>'state' = 'Uttar Pradesh' and (j->>'hidden_parts')::int = 1
                    and (j->>'may_edit')::boolean and not (j->>'may_cancel')::boolean and not (j->>'may_invoice')::boolean
                    and j->'sections'->0->'parts'->0->>'price_per_kg' = '120.00'
               from (select app.client_order_detail(pg_temp.f('O1')) j) x),
            '5: Basti mill''s Commercial: his section only (one part elsewhere, not shown), his price; the order cannot be cancelled, its invoice is fixed');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select jsonb_array_length(j->'sections') = 2 and (select bool_and(p ? 'price_per_kg') from jsonb_array_elements(j->'sections') s, jsonb_array_elements(s->'parts') p)
                    and not (j->>'may_edit')::boolean
               from (select app.client_order_detail(pg_temp.f('O1')) j) x),
            '5: the client''s owner: both sections, with its prices; nothing to change');
select t.as_user(pg_temp.f('VW'));
select t.ok((select jsonb_array_length(j->'sections') = 1 and j->'sections'->0->>'state' = 'Uttar Pradesh'
                    and not exists (select 1 from jsonb_array_elements(j->'sections') s, jsonb_array_elements(s->'parts') p where p ? 'price_per_kg')
               from (select app.client_order_detail(pg_temp.f('O1')) j) x),
            '5: the viewer of Basti mill: that section only, no price');
select t.ok((select jsonb_array_length(app.client_orders_list()->'orders') = 3) and not (app.client_orders_list()->>'may_make')::boolean,
            '5: and lists the three orders with a part in Basti mill (not the empty one), with nothing to make');
select t.as_user(pg_temp.f('OWN2'));
select t.fails($q$select app.client_order_detail(pg_temp.f('O1'))$q$, 'order not found', '5: the other client''s owner: nothing');
select t.ok(jsonb_array_length(app.client_orders_list()->'orders') = 0, '5: and lists none of them');
select t.as_user(t.u('12'));
select t.fails($q$select app.client_order_detail(pg_temp.f('O1'))$q$, 'order not found', '5: the other client''s operator: nothing');
select t.ok((select count(*) = 0 from public.client_orders where client_id = '00000000-0000-4000-8000-000000000201'), '5: nor any row of the table');
select t.as_anon();
select t.fails($q$select app.client_order_detail(pg_temp.f('O1'))$q$, 'permission denied', '5: the public: no way in');

-- 6 · cancelling ---------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('18'));
select t.fails($q$select app.client_order_cancel(pg_temp.f('O1'), 'changed our mind (test)')$q$, 'has parts', '6: an order with parts is not cancelled');
insert into fx select 'O4', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY2'),
  'domestic', null, 'PO-70-4')->>'id')::uuid;
select t.fails($q$select app.client_order_cancel(pg_temp.f('O4'), 'short')$q$, 'say why', '6: a cancel says why');
select t.ok((app.client_order_cancel(pg_temp.f('O4'), 'buyer withdrew the order (test)')->>'status') = 'cancelled'
            and pg_temp.audited('client_order_cancelled', pg_temp.f('O4')),
            '6: an order with no part is cancelled, with its reason, in the Audit log');
select t.fails($q$select pg_temp.part(pg_temp.f('N'), 'KA', t.u('18'), 'O4', 1)$q$, 'was cancelled', '6: a cancelled order takes no part');
select t.ok((select app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY2'),
  'domestic', null, 'PO-70-4') ? 'code'), '6: its number is free again for a new order');

-- 7 · the client's views ------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('OWN'));
create temp table ax as select app.client_across('00000000-0000-4000-8000-000000000201') as j;
grant select on ax to authenticated, anon;
select t.ok((select (x->>'parts')::int = 2 and (x->>'scopes')::int = 2 and x->>'invoice_no' = 'INV-70-1' and (x->>'qty_kg')::numeric = 10
               from ax, jsonb_array_elements(j->'client_orders') x where x->>'order_no' = 'PO-70-1'),
            '7: Across scopes lists the client order: two parts in two scopes, one invoice, 10 kg');
select t.ok((select count(*) = 2 from ax, jsonb_array_elements(j->'orders') x where x->>'client_order' = (select code from public.client_orders where id = pg_temp.f('O1'))),
            '7: and each of its parts names it');
select t.ok((select jsonb_array_length(pg_temp.tab(e, 'client_orders')->'rows') = 3
                    and pg_temp.tab(e, 'client_orders')->'columns' @> '["invoice_no", "scopes", "parts"]'
                    and pg_temp.tab(e, 'orders')->'columns' @> '["client_order"]'
               from (select app.export_client_view('across', '00000000-0000-4000-8000-000000000201', null, 'shareable') e) x),
            '7: the export of across scopes has the client orders (3 with parts) and each part''s order');
select t.as_user(pg_temp.f('VW'));
select t.ok((select jsonb_array_length(j->'client_orders') = 3 and (select bool_and((x->>'scopes')::int = 1) from jsonb_array_elements(j->'client_orders') x)
               from (select app.client_across('00000000-0000-4000-8000-000000000201') j) y),
            '7: the viewer of Basti mill: the orders with a part there, counting only that scope');

-- 8 · item 67 (1): the lab reference ------------------------------------------------------------------------------------------------
select t.as_service();
set local session_replication_role = replica;      -- test only: a record as an older form left it (lab reference, no lab of the list)
update public.footprints set payload = (payload - 'lab_id') || '{"lab_ref": "Basti Agri Lab / BAL-118"}'::jsonb
 where id = (select prev_footprint_id from public.footprints where id = (select prev_footprint_id from public.footprints where id = pg_temp.f('KU2')));
set local session_replication_role = origin;
select t.as_user(pg_temp.f('OWN'));
select t.ok((select count(*) = 1 from jsonb_array_elements(app.client_scope_detail(t.scope('05'))->'qc') q where q->>'lab' = 'Basti Agri Lab / BAL-118'),
            '8: an older QC record''s "Lab reference" is its lab in the scope view (item 67)');

-- 9 · the Commercial form; grants ---------------------------------------------------------------------------------------------------
select t.as_user(t.u('11'));
create temp table op as select app.client_orders_open_for(t.scope('05'), pg_temp.f('KX')) as j;
grant select on op to authenticated, anon;
select t.ok((select (x->>'fits')::boolean from op, jsonb_array_elements(j) x where x->>'order_no' = 'PO-70-3')
            and (select not (x->>'fits')::boolean and x->>'why' = 'market' from op, jsonb_array_elements(j) x where x->>'order_no' = 'EX-70-1'),
            '9: the form offers the open orders: a domestic one the batch fits; the export one it does not (its market)');
select t.ok((select x->>'why' = 'gi' from jsonb_array_elements(app.client_orders_open_for(t.scope('05'), pg_temp.f('KF'))) x where x->>'order_no' = 'PO-70-1'),
            '9: a batch not farm-verified: "not the order''s GI status"');
select t.ok(not exists (select 1 from jsonb_array_elements(app.client_orders_open_for(t.scope('05'), null)) x where x->>'status' <> 'open'),
            '9: a cancelled order is not offered');
select t.ok((app.order_of_part(pg_temp.f('PU'))->>'invoice_no') = 'INV-70-1', '9: the Shipment form reads a part''s order and its invoice');
select t.as_user(t.u('06'));
select t.ok(jsonb_array_length(app.client_orders_open_for(t.scope('05'), pg_temp.f('KU'))) = 0, '9: the QC technician is offered none (not his stage)');
select t.as_service();
select t.ok(not has_function_privilege('authenticated', 'app.order_part_payload(jsonb, public.footprints, public.scopes)', 'execute')
            and not has_function_privilege('authenticated', 'app.may_make_order(uuid, uuid)', 'execute')
            and not has_function_privilege('authenticated', 'app.order_parts(uuid)', 'execute')
            and has_function_privilege('authenticated', 'app.client_order_detail(uuid)', 'execute')
            and not has_function_privilege('anon', 'app.client_order_new(uuid, uuid, uuid, text, text, text, text, text)', 'execute')
            and not has_table_privilege('authenticated', 'public.client_orders', 'insert')
            and not has_table_privilege('authenticated', 'public.client_orders', 'update'),
            '9: the rules are the server''s own; the screens are the way in; the table is read only');
select t.ok(exists (select 1 from public.change_log where table_name = 'client_orders'), '9: the orders are in the change log');
select t.ok((select jsonb_array_length(j->'leaks') = 0 from (select app.isolation_probe(true, false) j) x), '9: the isolation probe: no leak with client orders in place');

-- 10 · found while checking: the farmer register's possible duplicates, read inside the database only -------------------
select t.as_service();
insert into fx values ('FA', gen_random_uuid()), ('FB', gen_random_uuid());
insert into public.farmers (id, client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, status)
values (pg_temp.f('FA'), '00000000-0000-4000-8000-000000000201', 'Shared Phone One', 'G', 'Itwa', 'Siddharthnagar', '+919870099777', 2, 1, 'under_review'),
       (pg_temp.f('FB'), '00000000-0000-4000-8000-000000000202', 'Shared Phone Two', 'G', 'Itwa', 'Siddharthnagar', '+919870099777', 2, 1, 'under_review');
select t.ok(jsonb_array_length(app.open_duplicates(pg_temp.f('FA'))) = 1, '10: the rule inside the database still finds the other client''s record with the same phone');
select t.as_user(t.u('03'));
select t.fails($q$select app.open_duplicates(pg_temp.f('FA'))$q$, 'permission denied',
               '10: the Client Manager asking for his farmer''s duplicates by hand reads no other client''s farmer (closed)');
select t.as_user(t.u('12'));
select t.fails($q$select app.open_duplicates(pg_temp.f('FA'))$q$, 'permission denied', '10: nor another client''s operator');
rollback;
