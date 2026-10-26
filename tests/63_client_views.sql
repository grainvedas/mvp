-- Migration 68 (Phase 3, release 2 of Veda's combined brief of 19 Oct 2026: Parts C and E4, with item 65).
--   1  the portfolio: every scope the reader reaches, its figures (procured, in process, packed, sold, shipped, packs
--      released, scans, copy flags, open lab results, recalls, waiting on GrainVeda), by state and crop and in total
--   2  who reads it: the owner (both states), a viewer of one scope (that scope only), the Client Manager and the State
--      Manager (their scopes), the admin; never the client's own staff, another client's accounts or a stranger
--   3  one scope: the pipeline, lots and batches, QC per market with lab and report number, documents, reports, the
--      people on each stage by name and role only
--   4  across scopes: buyers and orders (the client's own prices only for those who may take the internal copy),
--      scans by city, copy flags, recalls, outputs
--   5  the farmers: the client's own; never a phone; names only in the internal copy
--   6  the exports: each view's tables from the same data; shareable by default (no price, no farmer name); internal
--      only for those allowed; every download in the Audit log
--   7  item 65: People → Client logins and the person's page say what a client account is
--   8  the isolation probe: a person's own row (an ended assignment to a client he no longer works for) is not a leak
-- Scope 05 (Basti mill, UP): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). Scope 07 (Nagaon, Assam) made active for a second state. 03 the Client Manager of client 201; 02 the UP
-- State Manager. Fake, format-valid numbers only.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ins(p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('05'), '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
create or replace function pg_temp.login(p uuid) returns void language sql security definer as $$ update public.app_users set auth_uid = p where id = p $$;
-- a table of an export by its key
create or replace function pg_temp.tab(e jsonb, k text) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(e->'tables') x where x->>'key' = k $$;
create or replace function pg_temp.col(e jsonb, k text, c text) returns int language sql immutable as $$
  select (o - 1)::int from jsonb_array_elements_text(pg_temp.tab(e, k)->'columns') with ordinality t(v, o) where v = c $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- the second state: Nagaon (Assam) active, with one procurement
insert into public.client_states (client_id, state_id, status, legacy) values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'active', true)
  on conflict (client_id, state_id) do update set status = 'active';
update public.scopes set status = 'active' where id = t.scope('07');

with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;

-- the chain on Basti mill: 132 kg procured, QC passed (with its lab and report), milled, 20 pouches of 1 kg packed; an
-- order of 5 pouches at ₹120/kg shipped with its codes and sealed; two scans; a copy flag; the lot recalled
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('01'), 132, 2, 1, 11.8, 11.7, 11.9);
select t.verify(pg_temp.f('P'), t.u('06'));
select t.as_user(t.u('06'));
insert into fx select 'Q', pg_temp.ins('qc', pg_temp.f('P'), t.u('06'), jsonb_build_object('qty_kg', 130, 'sample_qty_kg', 1,
  'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2), 'lab_id', pg_temp.f('LAB'),
  'report_no', 'GGL/2026/63', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-63'));
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":129,"head_rice_kg":80,"broken_kg":10,"husk_kg":30,"bran_kg":6}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins('packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":20,"packets":[{"sku_id":"%s","units":20,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
insert into fx select 'D1', pg_temp.ins('commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-63-1","packs":[{"sku_id":"%s","units":5}],"price_per_kg":120,"currency":"INR"}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D1'));
select t.as_service();
create temp table kp as select serial, row_number() over (order by serial) as n from public.packs where footprint_id = pg_temp.f('K');
grant select on kp to authenticated, anon;
select t.as_user(t.u('14'));
insert into fx select 'S1', pg_temp.ins('shipment', pg_temp.f('D1'), t.u('14'), jsonb_build_object('invoice_no', 'INV-63', 'vehicle_no', 'UP53AB1234',
  'lr_no', 'LR-63', 'dispatch_date', '2026-10-20', 'destination', 'Delhi', 'packs', format('[{"sku_id":"%s","units":5}]', pg_temp.f('SKU1'))::jsonb,
  'serials', (select jsonb_agg(serial order by serial) from kp where n <= 5)));
select t.as_service(); select t.attach(pg_temp.f('S1'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('S1'));
insert into fx select 'R1', pg_temp.ins('qr_activation', pg_temp.f('S1'), t.u('07'), '{}');
create temp table seal1 as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal1 to anon, authenticated;
select t.as_anon();
select app.record_scan_at((select serial from kp where n = 1), 'New Delhi', 'DL', 'IN', 28.6, 77.2);
select app.record_scan_at((select serial from kp where n = 2), 'New Delhi', 'DL', 'IN', 28.6, 77.2);
select app.record_scan_at((select code from seal1), 'Lucknow', 'UP', 'IN', 26.8, 80.9);
select t.as_service();
insert into public.scan_flags (serial, kind, footprint_id, scope_id, client_id) values ((select serial from kp where n = 1), 'many', pg_temp.f('K'), t.scope('05'), '00000000-0000-4000-8000-000000000201');
select t.as_user(t.u('03'));
select app.set_release_status(pg_temp.f('R1'), 'recalled', 'practice recall: wrong label (test)');
-- Assam: one procurement waiting for its check
select t.as_service();
select t.staff(t.scope('07'));
insert into fx select 'PA', t.procure(t.scope('07'), t.farmer('01'), 50, 1, 1, 11.5, 11.5, 11.5);

-- a failing lab result on Siddharthnagar (01), and a sample at the lab with no report yet
select t.staff(t.scope('01'));
insert into fx select 'P2', t.procure(t.scope('01'), t.farmer('01'), 40, 1, 1, 11.8, 11.7, 11.9);
select t.verify(pg_temp.f('P2'), t.u('06'));
select t.as_user(t.u('06'));
do $x$ declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', pg_temp.f('P2'), t.u('06'),
          jsonb_build_object('qty_kg', 38, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 19, 'broken_pct', 30, 'foreign_matter_pct', 3),
            'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/64', 'report_date', '2026-10-20', 'sample_id', 'S-64')) returning id into v;
  insert into fx values ('Q2', v);
end $x$;
select t.as_service();
insert into public.qc_samples (code, footprint_id, scope_id, client_id, drawn_on, qty_kg, lab_id, status, created_by)
values ('S-65', pg_temp.f('P2'), t.scope('01'), '00000000-0000-4000-8000-000000000201', '2026-10-21', 0.5, pg_temp.f('LAB'), 'sent', t.u('06'));

-- the accounts: an owner (made by the admin); its viewer of Basti mill only; a client's own staff (the Client Manager's);
-- the other client's owner
select t.as_user(t.u('01'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner63@prasaadam.test');
insert into fx select 'OWN', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Owner', 'owner63@prasaadam.test');
select app.prepare_client_account('00000000-0000-4000-8000-000000000202', 'owner', 'owner63@demox.test');
insert into fx select 'OWN2', app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Demox Owner', 'owner63@demox.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OWN')); select pg_temp.login(pg_temp.f('OWN2'));
select t.as_user(pg_temp.f('OWN'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'viewer', 'viewer63@prasaadam.test', 'scopes', null, array[t.scope('05')]);
insert into fx select 'VW', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Basti mill Viewer', 'viewer63@prasaadam.test');
select t.as_user(t.u('03'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'operator', 'staff63@prasaadam.test');
insert into fx select 'OP', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Staff', 'staff63@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('VW')); select pg_temp.login(pg_temp.f('OP'));

-- 1 · the portfolio -------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('OWN'));
create temp table pf as select app.client_portfolio('00000000-0000-4000-8000-000000000201') as j;
grant select on pf to authenticated, anon;
create or replace function pg_temp.sc(p uuid) returns jsonb language sql stable as $$
  select x from pf, jsonb_array_elements(pf.j->'scopes') x where (x->>'scope_id')::uuid = p $$;
grant execute on function pg_temp.sc(uuid) to authenticated, anon;
select t.ok((select (x->>'procured_kg')::numeric = 130 and (x->>'in_process_kg')::numeric = 60 and (x->>'packed_packs')::int = 20
               and (x->>'packed_kg')::numeric = 20 and (x->>'sold_kg')::numeric = 5 and (x->>'shipped_kg')::numeric = 5
               and (x->>'released_packs')::int = 5 from (select pg_temp.sc(t.scope('05')) x) y),
            '1: Basti mill: 130 kg procured, 60 kg in process (milled, not packed), 20 packs (20 kg) packed, 5 kg sold and shipped, 5 packs released');
select t.ok((select (x->>'scans')::int = 3 and (x->>'copy_flags')::int = 1 and (x->>'recalls')::int = 1 and (x->>'waiting')::int = 0
               from (select pg_temp.sc(t.scope('05')) x) y),
            '1: Basti mill: 3 scans (two packs and the lot), 1 open copy flag, 1 lot recalled, nothing waiting on GrainVeda');
select t.ok((select (x->>'lab_failed')::int = 1 and (x->>'lab_waiting')::int = 1 and (x->>'lab_open')::int = 2 and (x->>'waiting')::int = 2
               from (select pg_temp.sc(t.scope('01')) x) y),
            '1: Siddharthnagar: 2 open lab results (a failing one, a sample with no report); waiting: the record and the sample');
select t.as_service(); select t.attach(pg_temp.f('Q2'), 'acceptance');
select t.as_user(pg_temp.f('OWN'));
select t.ok((app.client_portfolio('00000000-0000-4000-8000-000000000201') -> 'scopes') @> jsonb_build_array(jsonb_build_object('scope_id', t.scope('01'), 'lab_failed', 0)),
            '1: the client''s written acceptance closes the failing result');
select t.ok((select (x->>'waiting')::int = 1 and (x->>'procured_kg')::numeric = 0 and x->>'state' = 'Assam' from (select pg_temp.sc(t.scope('07')) x) y),
            '1: Nagaon (Assam): a procurement waiting for its check, nothing procured yet');
select t.ok((select count(*) = 2 from pf, jsonb_array_elements(pf.j->'groups') g)
            and (select (g->>'scopes')::int = 6 and (g->>'procured_kg')::numeric = 169 and (g->>'packed_packs')::int = 20
                   from pf, jsonb_array_elements(pf.j->'groups') g where g->>'state' = 'Uttar Pradesh' and g->>'crop' = 'Kalanamak rice')
            and (select (g->>'scopes')::int = 1 from pf, jsonb_array_elements(pf.j->'groups') g where g->>'state' = 'Assam'),
            '1: by state and crop: Uttar Pradesh · Kalanamak rice (6 scopes, 169 kg procured, 20 packs), Assam · Joha rice (1 scope)');
select t.ok((select (j->'total'->>'scopes')::int = 7 and (j->'total'->>'procured_kg')::numeric = 169 and (j->'total'->>'scans')::int = 3
                    and (j->'total'->>'waiting')::int = 3 and j->'client'->>'code' = 'PRSDM' and (j->>'may_internal')::boolean from pf),
            '1: in total: 7 scopes, 169 kg, 3 scans, 3 waiting; the owner may take the internal copy');

-- 2 · who reads it ----------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('VW'));
select t.ok((select jsonb_array_length(j->'scopes') = 1 and j->'scopes'->0->>'scope_id' = t.scope('05')::text and not (j->>'may_internal')::boolean
               from (select app.client_portfolio('00000000-0000-4000-8000-000000000201') j) x),
            '2: the viewer of Basti mill: that scope only, no internal copy');
select t.fails(format('select app.client_scope_detail(%L)', t.scope('01')), 'not allowed to read this scope', '2: the viewer opens no other scope');
select t.as_user(t.u('02'));
select t.ok((select jsonb_array_length(j->'scopes') = 6 and not exists (select 1 from jsonb_array_elements(j->'scopes') x where x->>'state' = 'Assam')
               from (select app.client_portfolio('00000000-0000-4000-8000-000000000201') j) x),
            '2: the UP State Manager: the six UP scopes, not Assam''s');
select t.as_user(t.u('03'));
select t.ok(jsonb_array_length(app.client_portfolio('00000000-0000-4000-8000-000000000201') -> 'scopes') = 7, '2: the client''s Client Manager: its scopes in both states');
select t.as_user(t.u('01'));
select t.ok(jsonb_array_length(app.client_portfolio('00000000-0000-4000-8000-000000000201') -> 'scopes') = 7, '2: the admin: all');
select t.as_user(pg_temp.f('OP'));
select t.fails($$select app.client_portfolio('00000000-0000-4000-8000-000000000201')$$, 'not allowed to read this client''s portfolio', '2: the client''s own staff: no portfolio');
select t.fails(format('select app.client_scope_detail(%L)', t.scope('05')), 'not allowed to read this scope', '2: nor a scope''s view');
select t.as_user(pg_temp.f('OWN2'));
select t.fails($$select app.client_portfolio('00000000-0000-4000-8000-000000000201')$$, 'not allowed to read this client''s portfolio', '2: another client''s owner: refused');
select t.fails($$select app.client_across('00000000-0000-4000-8000-000000000201')$$, 'not allowed to read this client''s portfolio', '2: across scopes too');
select t.fails(format('select app.client_scope_detail(%L)', t.scope('05')), 'not allowed to read this scope', '2: and its scopes');
select t.fails($$select app.export_client_view('portfolio', '00000000-0000-4000-8000-000000000201')$$, 'not allowed to export', '2: and its exports');
select t.ok((select jsonb_array_length(j->'scopes') = 0 and (j->'total'->>'scopes')::int = 0
               from (select app.client_portfolio('00000000-0000-4000-8000-000000000202') j) x),
            '2: its own portfolio: its draft scope is not in it yet, nothing of the other');
select t.as_user(t.u('12'));
select t.fails($$select app.client_portfolio('00000000-0000-4000-8000-000000000201')$$, 'not allowed', '2: an operator of another client: refused');
select t.as_anon();
select t.fails($$select app.client_portfolio('00000000-0000-4000-8000-000000000201')$$, 'permission denied', '2: nobody signed in: refused');
select t.as_user(t.u('04'));
select t.ok((select jsonb_array_length(j->'scopes') = 7 and not (j->>'may_internal')::boolean from (select app.client_portfolio('00000000-0000-4000-8000-000000000201') j) x),
            '2: the client login of before (a viewer of the whole client): every scope, no internal copy');

-- 3 · one scope ---------------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('VW'));
create temp table sd as select app.client_scope_detail(t.scope('05')) as j;
grant select on sd to authenticated, anon;
select t.ok((select jsonb_array_length(j->'pipeline') = 7 and j->'pipeline'->0->>'stage' = 'procurement' and (j->'pipeline'->0->>'kg_out')::numeric = 130
                    and (j->'pipeline'->2->>'kg_waiting')::numeric = 60 from sd),
            '3: the pipeline by stage: 7 stages, 130 kg procured, 60 kg waiting at milling');
select t.ok((select j->'lots'->0->>'qr_code' = (select code from seal1) and j->'lots'->0->>'release' = 'recalled' and (j->'lots'->0->>'packs_live')::int = 5
                    and (j->'batches'->0->>'packs')::int = 20 and (j->'batches'->0->>'released')::int = 5 and (j->'batches'->0->>'held')::int = 15 from sd),
            '3: lots and batches: the lot (recalled), 5 packs live; its batch of 20, 5 released, 15 held');
select t.ok((select j->'qc'->0->>'lab' = 'Gorakhpur Grain Lab' and j->'qc'->0->>'report_no' = 'GGL/2026/63' and j->'qc'->0->>'domestic' = 'pass'
                    and j->'qc'->0->>'export' = 'pass' from sd),
            '3: QC per market, with its lab and report number');
select t.ok((select exists (select 1 from jsonb_array_elements(j->'documents') d where d->>'kind' = 'lab_report' and d->>'what' = 'GGL/2026/63') from sd),
            '3: the documents: the lab report');
select t.ok((select jsonb_array_length(j->'people') = 7 and not exists (select 1 from jsonb_array_elements(j->'people') x
                    where x ?| array['phone', 'email', 'id', 'user_id', 'system_role']) from sd),
            '3: the people on each stage: name and role only (no phone, no email, no id)');
select t.ok((select not (j->>'may_internal')::boolean and not (j->>'internal')::boolean from sd), '3: the viewer reads it without the internal copy');

-- 4 · across scopes; prices only for those who may take the internal copy ---------------------------------------------------------
select t.as_user(pg_temp.f('VW'));
create temp table ac_v as select app.client_across('00000000-0000-4000-8000-000000000201') as j;
grant select on ac_v to authenticated, anon;
select t.ok((select jsonb_array_length(j->'orders') = 1 and j->'orders'->0->>'buyer' = 'Delhi Wholesale' and j->'orders'->0->>'order_no' = 'PO-63-1'
                    and (j->'orders'->0->>'shipped_kg')::numeric = 5 and not (j->'orders'->0 ?| array['price_per_kg', 'total_value', 'currency']) from ac_v),
            '4: the viewer: the order (buyer, number, 5 kg shipped), no price');
select t.ok((select j->'buyers'->0->>'buyer' = 'Delhi Wholesale' and (j->'buyers'->0->>'orders')::int = 1 from ac_v)
            and (select (select sum((x->>'scans')::int) from jsonb_array_elements(j->'scans_by_city') x) = 3
                        and j->'scans_by_city'->0->>'city' = 'New Delhi' and (j->'scans_by_city'->0->>'scans')::int = 2 from ac_v)
            and (select jsonb_array_length(j->'copy_flags') = 1 and j->'recalls'->0->>'reason' = 'practice recall: wrong label (test)' from ac_v),
            '4: buyers, scans by city (New Delhi 2, Lucknow 1), the copy flag, the recall with its reason');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select (o->>'price_per_kg')::numeric = 120 and o->>'currency' = 'INR' and (o->>'total_value')::numeric = 600
               from (select app.client_across('00000000-0000-4000-8000-000000000201') -> 'orders' -> 0 o) x),
            '4: the owner: its own price (₹120/kg, ₹600)');
select app.set_viewer_internal(pg_temp.f('VW'), true);
select t.as_user(pg_temp.f('VW'));
select t.ok((select (o->>'price_per_kg')::numeric = 120 from (select app.client_across('00000000-0000-4000-8000-000000000201') -> 'orders' -> 0 o) x)
            and (app.client_scope_detail(t.scope('05')) ->> 'may_internal')::boolean,
            '4: a viewer the owner allowed: the price too');
select t.as_user(pg_temp.f('OWN'));
select app.set_viewer_internal(pg_temp.f('VW'), false);

-- 5 · the farmers --------------------------------------------------------------------------------------------------------------------
select t.as_service();
create temp table fc as select (select farmer_code from public.farmers where id = t.farmer('01')) as one,
  (select count(*) from public.farmers where client_id = '00000000-0000-4000-8000-000000000201') as all_n;
grant select on fc to authenticated, anon;
select t.as_user(pg_temp.f('VW'));
select t.ok((select jsonb_array_length(pg_temp.tab(e, 'farmers')->'rows') = 1
                    and pg_temp.tab(e, 'farmers')->'rows'->0->>0 = (select one from fc)
                    and pg_temp.col(e, 'farmers', 'name') is null
                    and pg_temp.col(e, 'farmers', 'phone') is null and pg_temp.col(e, 'farmers', 'farmer_code') = 0
               from (select app.export_client_view('farmers', '00000000-0000-4000-8000-000000000201') e) x),
            '5: the viewer''s farmers: the one who sold into Basti mill; the farmer ID, village, land; no name, no phone');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select pg_temp.col(e, 'farmers', 'name') = 1 and pg_temp.col(e, 'farmers', 'phone') is null
                    and jsonb_array_length(pg_temp.tab(e, 'farmers')->'rows') = (select all_n from fc)
                    and jsonb_array_length(pg_temp.tab(e, 'farmers')->'rows') > 1
               from (select app.export_client_view('farmers', '00000000-0000-4000-8000-000000000201', null, 'internal') e) x),
            '5: the owner''s internal copy: every farmer of the client, with the names; never a phone');

-- 6 · the exports ----------------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('VW'));
select t.fails($$select app.export_client_view('across', '00000000-0000-4000-8000-000000000201', null, 'internal')$$, 'take the shareable copy', '6: the viewer takes no internal copy');
select t.fails(format($$select app.export_client_view('scope', null, %L, 'internal')$$, t.scope('05')), 'take the shareable copy', '6: of a scope neither');
select t.fails($$select app.export_client_view('everything', '00000000-0000-4000-8000-000000000201')$$, 'a view is the portfolio', '6: four views only');
select t.fails($$select app.export_client_view('portfolio', '00000000-0000-4000-8000-000000000201', null, 'secret')$$, 'shareable or an internal copy', '6: two copies only');
select t.ok((select e->>'copy' = 'shareable' and pg_temp.col(e, 'orders', 'price_per_kg') is null and pg_temp.col(e, 'orders', 'buyer') is not null
                    and jsonb_array_length(pg_temp.tab(e, 'orders')->'rows') = 1 and (select count(*) from jsonb_array_elements(e->'tables')) = 6
               from (select app.export_client_view('across', '00000000-0000-4000-8000-000000000201') e) x),
            '6: across scopes, shareable by default: six tables, the order without its price');
select t.ok((select (pg_temp.tab(e, 'scopes')->'rows'->0->>pg_temp.col(e, 'scopes', 'procured_kg'))::numeric = 130
                    and jsonb_array_length(pg_temp.tab(e, 'scopes')->'rows') = 1
               from (select app.export_client_view('portfolio', '00000000-0000-4000-8000-000000000201') e) x),
            '6: the portfolio''s export is the screen''s data: its one scope, 130 kg');
select t.ok((select (select count(*) from jsonb_array_elements(e->'tables')) = 7 and e->'scope'->>'label' = 'Kalanamak rice · KH26 · Basti mill'
                    and jsonb_array_length(pg_temp.tab(e, 'people')->'rows') = 7 and pg_temp.col(e, 'people', 'phone') is null
               from (select app.export_client_view('scope', null, t.scope('05')) e) x),
            '6: one scope''s export: seven tables (pipeline, lots, batches, QC, documents, reports, people)');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select pg_temp.col(e, 'orders', 'price_per_kg') is not null and e->>'generated_by' = 'Prasaadam Owner'
               from (select app.export_client_view('across', '00000000-0000-4000-8000-000000000201', null, 'internal') e) x),
            '6: the owner''s internal copy carries the price, and who made it');
select t.as_service();
select t.ok((select count(*) = 6 from public.audit_log where action = 'export_downloaded' and detail ->> 'kind' = 'client_view')
            and exists (select 1 from public.audit_log where action = 'export_downloaded' and detail ->> 'view' = 'across' and detail ->> 'copy' = 'internal'
                          and actor = pg_temp.f('OWN') and target = '00000000-0000-4000-8000-000000000201')
            and not exists (select 1 from public.audit_log where action = 'export_downloaded' and detail ->> 'kind' = 'client_view' and actor = pg_temp.f('OWN2')),
            '6: every download in the Audit log (who, which view, which copy); a refused one is not');
select t.ok((select count(*) = 0 from information_schema.routine_privileges where routine_schema = 'app' and grantee in ('anon', 'PUBLIC')
               and routine_name in ('client_portfolio', 'client_scope_detail', 'client_across', 'export_client_view'))
            and not has_function_privilege('authenticated', 'app.cv_scope_data(uuid, boolean)', 'execute')
            and not has_function_privilege('authenticated', 'app.cv_across_data(uuid, boolean)', 'execute')
            and not has_function_privilege('authenticated', 'app.cv_farmers_data(uuid, boolean)', 'execute'),
            '6: the screens and the export are the only way in; the data functions (which take "internal") are closed');

-- 7 · item 65: what a client account is, where it shows ------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok((select r->'client_account'->>'kind' = 'operator' and r->'client_account'->>'client_name' = 'GrainVeda (Prasaadam trade scope)'
               from jsonb_array_elements(app.people_page('{"kind":"client_logins","limit":50}') -> 'rows') r where (r->>'id')::uuid = pg_temp.f('OP')),
            '7: People → Client logins: the client''s staff says so');
select t.as_user(t.u('01'));
select t.ok((app.employee_profile(pg_temp.f('OWN')) -> 'identity' -> 'client_account' ->> 'kind') = 'owner'
            and (app.employee_profile(t.u('04')) -> 'identity' -> 'client_account' ->> 'kind') = 'viewer'
            and (app.employee_profile(t.u('03')) -> 'identity' -> 'client_account') = 'null'::jsonb,
            '7: the person''s page: an owner is an owner, a viewer a viewer; an employee is no client account');
-- 8 · the isolation probe: a person's own ended assignment is his own row ----------------------------------------------------
select t.as_service();
insert into public.app_users (id, auth_uid, display_name, email) values
  ('00000000-0000-4000-8000-000000000e63', '00000000-0000-4000-8000-000000000e63', 'Former Basti mill Operator (test)', 'former63@example.com');
select t.staff(t.scope('05'), '00000000-0000-4000-8000-000000000e63');
select set_config('app.assigning', 'on', true);
delete from public.slot_assignments where user_id = '00000000-0000-4000-8000-000000000e63';
update public.assignments set active = false, ended_at = now() where employee_id = '00000000-0000-4000-8000-000000000e63';
select set_config('app.assigning', '', true);
select t.ok((select not exists (select 1 from public.assignments where employee_id = '00000000-0000-4000-8000-000000000e63' and active)), '8: his only assignment has ended');
select t.ok((select not (j->'leaks' @> jsonb_build_array(jsonb_build_object('person', '00000000', 'what', 'assignments')))
                    and not exists (select 1 from jsonb_array_elements(j->'leaks') x where x->>'what' = 'assignments')
               from (select app.isolation_probe(false, false) j) x),
            '8: the probe reads his own ended assignment as his own, not as another client''s leak');

rollback;
