-- Migration 71 (Phase 3, release 4 of Veda's combined brief of 19 Oct 2026: Part E1, the evidence pack).
--   1  sealing a shipment's lot issues its pack, and the client order's where the shipment is a part of one; the second
--      state's seal makes the order's version 2 and supersedes version 1 (kept)
--   2  the sections: header, origin, mass balance, quality, documents, chain, packs, verification
--   3  the shareable copy: no farmer's name, no price; the internal one: the farmers by name and the sale's price (the scope
--      records prices)
--   4  the order's pack: one section per scope, one invoice
--   5  a lot sealed with no shipment: the lot's own pack; a release on the client's written acceptance is said as such
--   6  on demand: who reads the whole scope and runs it (its Client Manager or State Manager, the admin); not the QC
--      technician, not Commercial, not a client account
--   7  who reads: the owner (every scope), the viewer of Basti mill (its shipment's pack, not the order's), not another
--      client; the internal copy only for those allowed
--   8  "Verify this document" (/d/<ref>) for a pack; a superseded version says by which; its files (PDF, JSON) and their SHA-256
--   9  the buyer link carries the shareable copy of its sale's pack (the order's)
--  10  the billing count; the season reports untouched by the packs; grants
-- The fixture of tests/65 (Basti mill in Uttar Pradesh, Nagaon mill in Assam, one client order from both). Fake,
-- format-valid numbers only.
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
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner71@prasaadam.test');
insert into fx select 'OWN', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Owner', 'owner71@prasaadam.test');
select app.prepare_client_account('00000000-0000-4000-8000-000000000202', 'owner', 'owner71@demox.test');
insert into fx select 'OWN2', app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Demox Owner', 'owner71@demox.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OWN')); select pg_temp.login(pg_temp.f('OWN2'));
select t.as_user(pg_temp.f('OWN'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'viewer', 'viewer71@prasaadam.test', 'scopes', null, array[t.scope('05')]);
insert into fx select 'VW', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Basti mill Viewer', 'viewer71@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('VW'));


update public.scopes set record_price = true where id = t.scope('05');    -- Basti mill records prices (the internal copy has them)

-- the order and its two parts, verified; Basti mill's and Nagaon mill's shipments under its invoice, verified ----------------
select t.as_user(t.u('11'));
insert into fx select 'O1', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'),
  'domestic', null, 'PO-71-1', 'INV-71-1')->>'id')::uuid;
insert into fx select 'PU', pg_temp.part(t.scope('05'), 'KU', t.u('11'), 'O1', 6, '{"price_per_kg": 120, "currency": "INR"}');
select t.as_user(t.u('18'));
insert into fx select 'PA', pg_temp.part(pg_temp.f('N'), 'KA', t.u('18'), 'O1', 4);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('PU'));
insert into fx select 'SU', pg_temp.ship(t.scope('05'), 'PU', t.u('14'), 'KU', 6);
select t.as_user(t.u('10')); select app.verify_footprint(pg_temp.f('PA'));
insert into fx select 'SA', pg_temp.ship(pg_temp.f('N'), 'PA', t.u('10'), 'KA', 4);
select t.as_service(); select t.attach(pg_temp.f('SU'), 'loading_photo'); select t.attach(pg_temp.f('SA'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('SU'));
select t.as_user(t.u('13')); select app.verify_footprint(pg_temp.f('SA'));
select t.as_service();
create or replace function pg_temp.pack(p_kind text, p_id uuid, p_status text default 'valid') returns public.reports
language sql stable security definer as $$
  select r.* from public.reports r where r.kind = 'evidence_pack' and r.subject_kind = p_kind and r.subject_id = p_id and r.status = p_status
   order by r.version desc limit 1 $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 1 · sealing issues the packs ---------------------------------------------------------------------------------------------
select t.as_user(t.u('07'));
insert into fx select 'RU', pg_temp.ins(t.scope('05'), 'qr_activation', pg_temp.f('SU'), t.u('07'), '{}');
create temp table sealu as select (app.seal_lot(pg_temp.f('RU'))).qr_code as code;
grant select on sealu to authenticated, anon;
select t.as_service();
select t.ok((select r.ref ~ '^GV-EP-[0-9]{6}$' and r.version = 1 and r.auto and r.issued_by = t.u('07') and r.subject_code = (select footprint_code from public.footprints where id = pg_temp.f('SU'))
               and r.scope_ids = array[t.scope('05')] and r.final from pg_temp.pack('shipment', pg_temp.f('SU')) r),
            '1: Basti mill''s seal issued its shipment''s pack (GV-EP-…, version 1, automatic, by the sealer)');
select t.ok((select r.version = 1 and cardinality(r.scope_ids) = 2
                    and (select l->'header'->>'qr_code' is null from jsonb_array_elements(r.data_shareable->'scopes') x, jsonb_array_elements(x->'lots') l
                          where x->>'state' = 'Assam') from pg_temp.pack('order', pg_temp.f('O1')) r),
            '1: and the client order''s pack (version 1: both scopes, Assam''s shipment not sealed yet)');
select t.ok(exists (select 1 from public.ledger l where l.event = 'report' and l.payload->>'kind' = 'evidence_pack'
                      and l.payload->>'ref' = (select ref from pg_temp.pack('shipment', pg_temp.f('SU')))
                      and l.payload->>'data_hash' = (select data_hash from pg_temp.pack('shipment', pg_temp.f('SU')))),
            '1: each issue is a ledger block with the data''s SHA-256');
select t.as_user(t.u('13'));
insert into fx select 'RA', pg_temp.ins(pg_temp.f('N'), 'qr_activation', pg_temp.f('SA'), t.u('13'), '{}');
select app.seal_lot(pg_temp.f('RA'));
select t.as_service();
select t.ok((select r.version = 2 and cardinality(r.scope_ids) = 2 from pg_temp.pack('order', pg_temp.f('O1')) r)
            and (select r.version = 1 and r.superseded_by = (select id from pg_temp.pack('order', pg_temp.f('O1')))
                   from pg_temp.pack('order', pg_temp.f('O1'), 'superseded') r),
            '1: Nagaon mill''s seal made the order''s version 2; version 1 is kept, superseded by it');
select t.ok((select r.version = 1 from pg_temp.pack('shipment', pg_temp.f('SA')) r), '1: and its own shipment''s pack');

-- 2 · the sections (Basti mill's shipment, the internal copy) ----------------------------------------------------------------
create temp table ds as select data_internal as i, data_shareable as s from pg_temp.pack('shipment', pg_temp.f('SU'));
grant select on ds to authenticated, anon;
select t.ok((select i->>'kind' = 'shipment' and i->'header'->>'buyer' = 'Delhi Wholesale' and i->'header'->>'invoice_no' = 'INV-71-1'
                    and i->'header'->>'client_order' = (select code from public.client_orders where id = pg_temp.f('O1'))
                    and i->'header'->>'qr_code' = (select code from sealu) and i->'header'->>'state' = 'Uttar Pradesh' from ds),
            '2: header: the buyer, the order''s invoice, the client order, the seal''s QR code, the state');
select t.ok((select (i->'origin'->>'farmers')::int = 1 and (i->'origin'->'villages'->0->>'share_pct')::numeric = 100
                    and (i->'origin'->>'farm_verified_pct')::numeric = 100 and i->'origin'->>'gi_status' = 'unknown' from ds),
            '2: origin: one farmer, his village 100 %, farm-verified 100 %, GI not confirmed (no GI district set)');
select t.ok((select (i->'mass_balance'->>'procured_kg')::numeric = 130 and (i->'mass_balance'->>'sold_kg')::numeric = 6
                    and (i->'mass_balance'->>'shipped_kg')::numeric = 6 and (i->'mass_balance'->>'sold_within_procured')::boolean
                    and (select (x->>'outturn_pct')::numeric = 69.8 and (x->>'ceiling_pct')::numeric = 70 and not (x->>'over_ceiling')::boolean
                                and (x->>'by_products_kg')::numeric = 46
                           from jsonb_array_elements(i->'mass_balance'->'stages') x where x->>'stage' = 'milling') from ds),
            '2: mass balance: 130 kg procured, 6 sold and shipped (never above procured); milling 69.8 % against the 70 % ceiling, 46 kg of by-products');
select t.ok((select q->>'lab' = 'Gorakhpur Grain Lab' and q->>'accreditation_no' = 'TC-7001' and q->>'report_no' = 'GL/2026/701'
                    and q->>'domestic' = 'pass' and not (q->>'accepted')::boolean
               from ds, jsonb_array_elements(i->'quality') q),
            '2: quality: the lab, its accreditation, the report number, the verdict per market');
select t.ok((select i->'documents'->'shipment'->>'invoice_no' = 'INV-71-1'
                    and exists (select 1 from jsonb_array_elements(i->'documents'->'files') f where f->>'label' = 'loading_photo' and f->>'sha256' ~ '^[0-9a-f]{64}$')
               from ds),
            '2: documents: the shipment''s papers and the loading photo''s fingerprint');
select t.ok((select (select (x->>'records')::int = 1 and x->'recorded_by' ? 'Commercial Manager' and x->'verified_by' ? 'Shipment Operator'
                     from jsonb_array_elements(i->'chain') x where x->>'stage' = 'commercial')
                    and (select count(*) from jsonb_array_elements(i->'chain')) = 6 from ds),
            '2: chain: each of the six stages to the shipment, who recorded and who checked');
select t.ok((select (i->'packs'->>'count')::int = 6 and i->'packs'->'batches'->0->'ranges'->>0 like '%-0001 – 0006' and not (i->'packs'->>'old_data')::boolean from ds),
            '2: packs: the six pouches shipped, as one serial range');
select t.ok((select i->'verification'->'seal'->>'qr_code' = (select code from sealu) and jsonb_array_length(i->'verification'->'blocks') = 5 and (i->'verification'->>'procurement_blocks')::int >= 1
                    and (select bool_and(b->>'hash' ~ '^[0-9a-f]{64}$') from jsonb_array_elements(i->'verification'->'blocks') b) from ds),
            '2: verification: the seal and the ledger fingerprints of the key blocks');

-- 3 · the two copies -------------------------------------------------------------------------------------------------------
select t.ok((select i->'origin'->'farmer_list'->0->>'name' is not null and (i->'price'->>'price_per_kg')::numeric = 120 and (i->>'internal')::boolean from ds),
            '3: the internal copy: the farmers by name, the sale''s price (Basti mill records prices)');
select t.ok((select not (s->'origin' ? 'farmer_list') and not (s ? 'price') and not (s->>'internal')::boolean
                    and s::text not like '%' || (select name from public.farmers where id = t.farmer('01')) || '%'
                    and s::text not like '%' || right(regexp_replace((select phone from public.farmers where id = t.farmer('01')), '[^0-9]', '', 'g'), 10) || '%' from ds),
            '3: the shareable copy: no farmer''s name anywhere, no phone, no price');
select t.ok((select bool_and(r.data_shareable::text !~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' and r.data_internal::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-')
               from public.reports r where r.kind = 'evidence_pack'),
            '3: the shareable copy carries no internal ID (the internal copy has the scope''s)');
select t.ok((select not (x.data_internal ? 'price') from pg_temp.pack('shipment', pg_temp.f('SA')) x),
            '3: Nagaon mill''s pack has no price even internally: the scope records none');

-- 4 · the order's pack ------------------------------------------------------------------------------------------------------
select t.ok((select jsonb_array_length(r.data_shareable->'scopes') = 2 and r.data_shareable->'header'->>'invoice_no' = 'INV-71-1'
                    and (select array_agg(x->>'state' order by x->>'state') from jsonb_array_elements(r.data_shareable->'scopes') x) = array['Assam', 'Uttar Pradesh']
                    and (select sum((l->'mass_balance'->>'shipped_kg')::numeric) from jsonb_array_elements(r.data_shareable->'scopes') x,
                           jsonb_array_elements(x->'lots') l) = 10
               from pg_temp.pack('order', pg_temp.f('O1')) r),
            '4: the order''s pack: one invoice, one section per scope (Assam and Uttar Pradesh), 10 kg shipped');

-- 5 · a lot with no shipment; a release on the client's acceptance ----------------------------------------------------------
select t.as_service();
select t.staff(t.scope('01'));
insert into fx select 'P1', t.procure(t.scope('01'), t.farmer('01'), 52, 1, 1, 11.8, 11.7, 11.9);
select t.verify(pg_temp.f('P1'), t.u('05'));
select t.as_user(t.u('05'));
insert into fx select 'Q1', pg_temp.ins(t.scope('01'), 'qc', pg_temp.f('P1'), t.u('05'), jsonb_build_object('qty_kg', 50, 'sample_qty_kg', 1,
  'readings', jsonb_build_object('moisture_pct', 12.5, 'broken_pct', 4, 'foreign_matter_pct', 0.2), 'lab_id', pg_temp.f('LAB'),
  'report_no', 'GL/2026/711', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-711'));
select t.as_service();
update public.footprints set status = 'verified', verified_by = t.u('05'), verified_at = now() where id = pg_temp.f('Q1');
set local session_replication_role = replica;        -- test only: the client's written release of the export market, as the owner leaves it
update public.qc_verdicts set override = '{"market": "export", "by": "owner", "reason": "accepted in writing (test)"}' where footprint_id = pg_temp.f('Q1');
set local session_replication_role = origin;
select t.as_user(t.u('05'));
insert into fx select 'R1', pg_temp.ins(t.scope('01'), 'qr_activation', pg_temp.f('Q1'), t.u('05'), '{}');
select app.seal_lot(pg_temp.f('R1'));
select t.as_service();
select t.ok((select r.subject_kind = 'lot' and r.subject_code = (select qr_code from public.qr_seals where footprint_id = pg_temp.f('R1'))
                    and r.data_shareable->'header'->>'shipment' is null from pg_temp.pack('lot', pg_temp.f('R1')) r),
            '5: a lot sealed with no shipment: the lot''s own pack, named by its QR code');
select t.ok((select (q->>'accepted')::boolean and q->>'accepted_market' = 'export' from pg_temp.pack('lot', pg_temp.f('R1')) r,
               jsonb_array_elements(r.data_shareable->'quality') q),
            '5: the release on the client''s written acceptance is said as such (never "passed")');

-- 6 · on demand ------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table od as select app.issue_evidence_pack('shipment', pg_temp.f('SU')) as j;
grant select on od to authenticated, anon;
select t.ok((select (j->>'version')::int = 2 and j->>'kind' = 'evidence_pack' and not (j->>'auto')::boolean from od)
            and (app.evidence_packs('shipment', pg_temp.f('SU'))->>'may_issue')::boolean,
            '6: the Client Manager of Basti mill issues it again: version 2');
select t.as_service();
select t.ok((select status = 'superseded' from public.reports where kind = 'evidence_pack' and subject_id = pg_temp.f('SU') and version = 1), '6: version 1 is superseded, kept');
select t.as_user(t.u('06'));
select t.fails($q$select app.issue_evidence_pack('shipment', pg_temp.f('SU'))$q$, 'record not found', '6: the QC technician may not');
select t.as_user(t.u('11'));
select t.fails($q$select app.issue_evidence_pack('shipment', pg_temp.f('SU'))$q$, 'record not found',
               '6: nor Commercial in Basti mill (a pack is issued by who reads the whole scope and runs it)');
select t.as_user(pg_temp.f('OWN'));
select t.fails($q$select app.issue_evidence_pack('order', pg_temp.f('O1'))$q$, 'record not found', '6: nor the client''s owner (a client account makes no pack)');
select t.as_user(t.u('03'));
select t.fails($q$select app.issue_evidence_pack('shipment', pg_temp.f('PU'))$q$, 'an evidence pack is of', '6: a pack is of a sealed lot, a shipment or a client order');

-- 7 · who reads -------------------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('OWN'));
select t.ok((select jsonb_array_length(app.evidence_packs('order', pg_temp.f('O1'))->'packs') = 2
                    and (app.evidence_packs('order', pg_temp.f('O1'))->'packs'->0->>'internal_ok')::boolean
                    and not (app.evidence_packs('order', pg_temp.f('O1'))->>'may_issue')::boolean),
            '7: the owner reads the order''s packs (both versions), may take the internal copy, issues none');
select t.ok((select (app.report_content((select id from pg_temp.pack('order', pg_temp.f('O1'))), 'internal')->'data'->>'internal')::boolean),
            '7: and reads its internal copy');
select t.as_user(pg_temp.f('VW'));
select t.ok((select jsonb_array_length(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') = 2
                    and jsonb_array_length(app.evidence_packs('order', pg_temp.f('O1'))->'packs') = 0),
            '7: the viewer of Basti mill: its shipment''s packs, not the order''s (it does not see Assam)');
select t.fails(format($q$select app.report_content(%L, 'shareable')$q$, (select id from pg_temp.pack('order', pg_temp.f('O1')))), 'record not found',
               '7: nor its content');
select t.fails(format($q$select app.report_content(%L, 'internal')$q$, (select id from pg_temp.pack('shipment', pg_temp.f('SU')))), 'internal copy',
               '7: the viewer takes the shareable copy only');
select t.ok((select count(*) = 0 from jsonb_array_elements(app.client_scope_detail(t.scope('05'))->'reports') x where x->>'kind' = 'evidence_pack' and x->>'subject_kind' = 'order')
            and (select count(*) = 2 from jsonb_array_elements(app.client_scope_detail(t.scope('05'))->'reports') x where x->>'subject_kind' = 'shipment'),
            '7: the viewer''s scope view lists Basti mill''s shipment packs, not the order''s');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select count(*) = 2 from jsonb_array_elements(app.client_scope_detail(pg_temp.f('N'))->'reports') x where x->>'subject_kind' = 'order'
               and x->>'subject' = (select subject_code from pg_temp.pack('order', pg_temp.f('O1')))),
            '7: the owner''s scope view of Nagaon mill lists the order''s packs (an order''s pack is in each of its scopes)');
select t.as_user(t.u('03'));
select t.ok((select count(*) = 2 and bool_and((x->>'may_store')::boolean) from jsonb_array_elements(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') x),
            '7: the Client Manager stores its files');
select t.as_user(pg_temp.f('VW'));
select t.ok((select count(*) = 2 and bool_and(not (x->>'may_store')::boolean) from jsonb_array_elements(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') x),
            '7: the viewer does not');
select t.as_user(pg_temp.f('OWN2'));
select t.ok(jsonb_array_length(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') = 0, '7: another client''s owner: nothing');
select t.fails(format($q$select app.report_content(%L, 'shareable')$q$, (select id from pg_temp.pack('shipment', pg_temp.f('SU')))), 'record not found',
               '7: nor its content');

-- 8 · "Verify this document" --------------------------------------------------------------------------------------------------------
select t.as_service();
create temp table oc as select code from public.client_orders where id = pg_temp.f('O1');
grant select on oc to authenticated, anon;
select t.as_anon();
select t.ok((select j->>'kind' = 'evidence_pack' and j->>'subject_kind' = 'order' and j->>'status' = 'valid' and (j->>'scopes')::int = 2
                    and j->>'subject' = (select code from oc)
               from (select app.public_document((select ref from pg_temp.pack('order', pg_temp.f('O1'))))) x(j)),
            '8: the verify page of the order''s pack: valid, of the client order, two scopes');
select t.ok((select j->>'status' = 'superseded' and j->>'superseded_by' = (select ref from pg_temp.pack('order', pg_temp.f('O1')))
               from (select app.public_document((select ref from pg_temp.pack('order', pg_temp.f('O1'), 'superseded')))) x(j)),
            '8: version 1''s page: superseded, by version 2''s reference');

-- 8b · a pack's files: its PDF (English, Hindi) and its JSON, each copy; their SHA-256 on the verify page --------------------------
select t.as_user(t.u('01'));
select t.ok((select (app.register_report_file((select id from pg_temp.pack('order', pg_temp.f('O1'))), 'shareable', 'pdf', 'en', repeat('a', 64), 1000)->>'path')
                    like '%/shareable.en.pdf'),
            '8b: the order''s pack: its shareable PDF stored, its SHA-256 kept');
select app.register_report_file((select id from pg_temp.pack('order', pg_temp.f('O1'))), 'shareable', 'json', 'en', repeat('b', 64), 500);
select t.fails(format($q$select app.register_report_file(%L, 'internal', 'pdf', 'en', repeat('c', 64), 1200)$q$, (select id from pg_temp.pack('order', pg_temp.f('O1')))),
               'the internal copy is for the people', '8b: the admin stores no internal copy (it is for the people of the scopes)');
select t.as_service();
set local session_replication_role = replica;   -- test only: an internal file, as its readers would store it (no one here reads both states' internal copies)
update public.reports set files = files || jsonb_build_object('pdf_en_internal', jsonb_build_object('path', id || '/internal.en.pdf', 'sha256', repeat('c', 64), 'bytes', 1200))
 where id = (select id from pg_temp.pack('order', pg_temp.f('O1')));
set local session_replication_role = origin;
select t.as_user(t.u('01'));
select t.fails(format($q$select app.register_report_file(%L, 'shareable', 'xlsx', 'en', repeat('d', 64), 10)$q$, (select id from pg_temp.pack('order', pg_temp.f('O1')))),
               'its PDF or its JSON', '8b: a pack''s files are its PDF and its JSON');
select t.as_user(pg_temp.f('VW'));
select t.fails(format($q$select app.register_report_file(%L, 'shareable', 'pdf', 'hi', repeat('e', 64), 10)$q$, (select id from pg_temp.pack('shipment', pg_temp.f('SU')))),
               'stores a report', '8b: the viewer of Basti mill (who reads it) stores no file of it');
select t.as_anon();
select t.ok((select jsonb_array_length(j->'files') = 3 and exists (select 1 from jsonb_array_elements(j->'files') f where f->>'format' = 'json' and f->>'sha256' = repeat('b', 64))
               from (select app.public_document((select ref from pg_temp.pack('order', pg_temp.f('O1'))))) x(j)),
            '8b: the verify page lists the three files with their SHA-256, the JSON among them');
select t.fails(format($q$select app.may_read_report_file(%L)$q$, (select id from pg_temp.pack('order', pg_temp.f('O1'))) || '/shareable.en.json'),
               'permission denied', '8b: the store gives no file to someone not signed in');
select t.as_user(pg_temp.f('OWN'));
select t.ok(app.may_read_report_file((select id from pg_temp.pack('order', pg_temp.f('O1'))) || '/shareable.en.json')
            and not app.may_write_report_object((select id from pg_temp.pack('order', pg_temp.f('O1'))) || '/shareable.hi.json'),
            '8b: the client''s owner reads the JSON; a client account stores no file');

-- 9 · the buyer link ---------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table bl as select app.create_buyer_link(pg_temp.f('PU'), 30, 'evidence pack test') as j;
grant select on bl to authenticated, anon;
select t.as_anon();
create temp table bv as select app.buyer_view((select coalesce(j->>'token', j->>'url') from bl)) as j;
select t.ok((select (j->>'ok')::boolean and j->'content'->'evidence_pack'->>'ref' = (select ref from pg_temp.pack('order', pg_temp.f('O1')))
                    and not ((j->'content'->'evidence_pack'->'data')::text like '%farmer_list%') and not (j->'content'->'evidence_pack'->'data' ? 'price')
                    and jsonb_array_length(j->'content'->'evidence_pack'->'data'->'scopes') = 2
                    and j->'content'->'evidence_pack'->'files'->'pdf_en_shareable'->>'sha256' = repeat('a', 64)
                    and not (j->'content'->'evidence_pack'->'files' ? 'pdf_en_internal') from bv),
            '9: the buyer''s page carries the shareable copy of its sale''s pack (the client order''s): no names, no price; its shareable files'' SHA-256');

-- 10 · billing; the season reports; grants --------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select t.ok((select (x->>'evidence_packs')::int = 6 from jsonb_array_elements(app.reports_issued(1)) x where x->>'client_code' = 'PRSDM'),
            '10: the admin''s count of reports issued: 6 evidence packs this month for the client');
select t.as_user(t.u('03'));
create temp table sr as select app.generate_interim_report(t.scope('05')) as j;
grant select on sr to authenticated, anon;
select t.ok((select j->>'ref' ~ '^GV-SR-' and (j->>'version')::int = 1 from sr)
            and (select bool_and(x->>'kind' = 'season_report') from jsonb_array_elements(app.scope_reports(t.scope('05'))) x),
            '10: an interim season report is version 1 (the packs are not counted); the scope''s season reports list no pack');
select t.fails(format($q$select app.register_report_file(%L, 'shareable', 'json', 'en', repeat('d', 64), 10)$q$, (select j->>'id' from sr)),
               'a report file is', '10: a season report has no JSON file');
select t.as_service();
select t.ok((select status = 'valid' from pg_temp.pack('shipment', pg_temp.f('SU'))), '10: and it supersedes no pack');
select t.ok(not has_function_privilege('authenticated', 'app.ep_issue(text, uuid, uuid, boolean)', 'execute')
            and not has_function_privilege('authenticated', 'app.ep_lot_data(uuid, boolean)', 'execute')
            and not has_function_privilege('anon', 'app.evidence_packs(text, uuid)', 'execute')
            and has_function_privilege('authenticated', 'app.issue_evidence_pack(text, uuid)', 'execute')
            and not has_table_privilege('authenticated', 'public.reports', 'select'),
            '10: the data and the issue are the server''s; the screens are the way in');
rollback;
