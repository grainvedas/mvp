-- Migration 60 (Phase 1, release 2 of Veda's combined brief, 19 Oct 2026, Part C: the exports); migration 61 corrected it
-- (the shareable copy names staff, not farmers; prices only where the scope records them; floor loss without by-products):
--   C1  the journey and the season are made on the server, in a shareable and an internal copy
--   C2  readable columns, a reading per column, codes not ids; the raw saved values only in the internal copy, last
--   C3  shares, GI and farm-verified, batch, packs and serial range, the lab, the same-person mark, the loss on the floor
--   C4  the internal copy: the scope's people and the client's own login; the shareable copy for anyone who sees the scope
--   C5  every export is in the Audit log
--   A5  the public lot page names the lab
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09); scope 01: Procurement (05) → QC (06) → QR (07).
-- 01 the admin, 03 the Client Manager of client 201, 04 its client login, 12 an operator of another client.
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
-- the value of one column in the row of one record
create or replace function pg_temp.cell(e jsonb, p_code text, p_col text) returns jsonb language sql immutable as $$
  select r->(select (o - 1)::int from jsonb_array_elements_text(e->'columns') with ordinality c(k, o) where k = p_col)
    from jsonb_array_elements(e->'rows') r
   where r->(select (o - 1)::int from jsonb_array_elements_text(e->'columns') with ordinality c(k, o) where k = 'code') = to_jsonb(p_code) $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';
update public.scopes set record_price = true where id = t.scope('05');      -- migration 61 (C1.3): prices only where the scope records them

with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
create temp table names as select (select name from public.farmers where id = t.farmer('05')) as farmer,
                                  (select display_name from public.app_users where id = t.u('03')) as cm,
                                  (select display_name from public.app_users where id = t.u('06')) as qc;
grant select on names to authenticated;

-- the chain of scope 05: two farm-gate lots, one through QC, milling and packing
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
insert into fx select 'P2', t.procure(t.scope('05'), t.farmer('04'), 104, 2, 2, 11.8, 11.7, 11.9);
insert into public.lot_payments (footprint_id, client_id, scope_id, price_per_quintal, amount, status, mode, txn_ref, recorded_by)
select pg_temp.f('P'), '00000000-0000-4000-8000-000000000201', t.scope('05'), 5217, 10434, 'paid', 'upi', 'UTR-55-TEST', t.u('05');
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P')); select app.verify_footprint(pg_temp.f('P2'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  jsonb_build_object('qty_kg', 200, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                     'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/155', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-55'));
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":170,"broken_kg":5,"husk_kg":15,"bran_kg":6}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":150,"packets":[{"sku_id":"%s","units":150,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_service();
create temp table codes as select k, (select footprint_code from public.footprints where id = fx.id) as code from fx where k in ('P', 'P2', 'Q', 'M', 'K');
create temp table bc as select payload->>'batch_code' as code from public.footprints where id = pg_temp.f('K');
grant select on codes, bc to authenticated, anon;
create or replace function pg_temp.c(p text) returns text language sql stable as $$ select code from codes where k = p $$;
grant execute on function pg_temp.c(text) to authenticated, anon;
select count(*) as audit_before from public.audit_log where action = 'export_downloaded' \gset

-- C1–C3 · the journey, shareable, as the Client Manager -------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table js as select app.export_journey(pg_temp.f('K'), 'shareable') as e;
select t.ok((select e->>'kind' = 'journey' and e->>'copy' = 'shareable' and e->'lot'->>'code' = pg_temp.c('K') and e->'scope'->>'client' is not null from js),
            'C1: the journey of a lot, shareable, with its heading');
select t.ok((select not (e->'columns' ?| array['farmer_name', 'agent_name', 'driver_phone', 'price_per_quintal', 'payment_status', 'payment_ref',
                                               'price_per_kg', 'currency', 'total_value', 'raw_values', 'entered_values']) from js),
            'C1: the shareable copy has no column for a farmer''s name, a price, a payment or the raw saved values');
select t.ok((select position((select farmer from names) in e::text) = 0 and position('5217' in e::text) = 0 and position('UTR-55-TEST' in e::text) = 0 from js),
            'C1: and none of them reaches the browser: no farmer''s name, no price, no payment reference');
select t.ok((select pg_temp.cell(e, pg_temp.c('Q'), 'recorded_by') = to_jsonb((select qc from names)) from js),
            'C3 (migration 61, the brief''s words): the shareable copy names the staff who recorded each step');
select t.ok((select e->'columns' @> '["code","stage","share_pct","gi_status","farm_verified","floor_loss_kg","head_rice_kg","broken_kg","husk_kg","bran_kg","lab","lab_accreditation","report_no","batch_code","packs","packs_by_size","serials","r:moisture_pct"]'::jsonb from js),
            'C2/C3: readable columns, a reading per column; shares, GI, farm-verified, by-products, floor loss, lab, batch, packs by size, serials');
select t.ok((select e->'units'->>'moisture_pct' = '%' from js), 'C2: each reading''s unit comes with the export');
select t.ok((select pg_temp.cell(e, pg_temp.c('P'), 'share_pct') = '100.0'::jsonb and pg_temp.cell(e, pg_temp.c('P'), 'farm_verified') = '"yes"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('P'), 'farmer_code') is not null and jsonb_typeof(pg_temp.cell(e, pg_temp.c('P'), 'gi_status')) = 'string' from js),
            'C3: the farm-gate lot: its share of the lot (100 %), farm-verified, the farmer''s code, its GI status');
select t.ok((select pg_temp.cell(e, pg_temp.c('Q'), 'lab') = '"Gorakhpur Grain Lab"'::jsonb and pg_temp.cell(e, pg_temp.c('Q'), 'lab_accreditation') = '"TC-5521"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('Q'), 'r:moisture_pct') = '11.8'::jsonb from js),
            'C3: the QC step: the lab, its accreditation number, the reading in its column');
select t.ok((select pg_temp.cell(e, pg_temp.c('M'), 'floor_loss_kg') = '3'::jsonb and pg_temp.cell(e, pg_temp.c('M'), 'husk_kg') = '15'::jsonb
                    and pg_temp.cell(e, pg_temp.c('P'), 'floor_loss_kg') = 'null'::jsonb from js),
            'E2.2: the floor loss of the mill is its input less head rice, broken, husk and bran (3 kg, not 29); none at the farm gate');
select t.ok((select pg_temp.cell(e, pg_temp.c('K'), 'packs') = '150'::jsonb and pg_temp.cell(e, pg_temp.c('K'), 'batch_code') = to_jsonb((select code from bc))
                    and pg_temp.cell(e, pg_temp.c('K'), 'serials') = to_jsonb((select code from bc) || '-0001 to ' || (select code from bc) || '-0150') from js),
            'C3: the packing step: batch code, 150 packs, the serial range');
select t.ok((select coalesce(pg_temp.cell(e, pg_temp.c('Q'), 'same_person'), 'null'::jsonb) = 'null'::jsonb and jsonb_array_length(e->'rows') = 4
                    and (select bool_and(jsonb_array_length(r) = jsonb_array_length(e->'columns')) from jsonb_array_elements(e->'rows') r) from js),
            'C3: no same-person mark where another checked it (since migration 61 a column empty in every row is left out); one row per step, every row as long as the heading');

-- C2/C4 · the internal copy ----------------------------------------------------------------------------------------------------
create temp table ji as select app.export_journey(pg_temp.f('K'), 'internal') as e;
select t.ok((select e->'columns' ?& array['farmer_name', 'recorded_by', 'verified_by', 'price_per_quintal', 'payment_ref'] and e->'columns'->>-1 = 'raw_values' from ji),
            'C2: the internal copy has the names and prices, and the raw saved values in its last column');
select t.ok((select pg_temp.cell(e, pg_temp.c('P'), 'farmer_name') = to_jsonb((select farmer from names))
                    and pg_temp.cell(e, pg_temp.c('P'), 'price_per_quintal') = '5217'::jsonb and pg_temp.cell(e, pg_temp.c('P'), 'payment_ref') = '"UTR-55-TEST"'::jsonb
                    and pg_temp.cell(e, pg_temp.c('Q'), 'recorded_by') = to_jsonb((select qc from names)) from ji),
            'C2: the farmer''s name, the price paid and its reference, who recorded each step');
select t.ok(app.may_internal_copy(t.scope('05')), 'C4: the Client Manager may take the internal copy');
select t.as_user(t.u('04'));
select t.ok(not app.may_internal_copy(t.scope('05')), 'C4: a client viewer takes no internal copy until the client''s owner allows it (migration 67)');
select t.as_service(); update public.client_accounts set internal_copies = true where user_id = t.u('04');   -- the owner's act (tests/62)
select t.as_user(t.u('04'));
select t.ok((select e->>'copy' = 'internal' from (select app.export_journey(pg_temp.f('K'), 'internal') e) x) and app.may_internal_copy(t.scope('05')),
            'C4: so may the client''s own login');
select t.as_user(t.u('01'));
select t.ok((select e->>'copy' = 'shareable' from (select app.export_journey(pg_temp.f('K'), 'shareable') e) x) and not app.may_internal_copy(t.scope('05')),
            'C4: the admin, who oversees and holds no part of the scope, takes the shareable copy');
select t.fails(format('select app.export_journey(%L, %L)', pg_temp.f('K'), 'internal'), 'the internal copy is for the people of this scope',
               'C4: and is refused the internal copy');
select t.fails(format('select app.export_journey(%L, %L)', pg_temp.f('K'), 'everything'), 'shareable or an internal copy', 'C1: a copy is shareable or internal, nothing else');
select t.as_user(t.u('12'));
select t.fails(format('select app.export_journey(%L, %L)', pg_temp.f('K'), 'shareable'), 'not allowed to trace this lot', 'C4: another client''s person gets nothing');
select t.fails(format('select app.export_season(%L, %L)', t.scope('05'), 'shareable'), 'not allowed to export this scope', 'C4: nor its season');

-- C1/C3 · the season --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table ss as select app.export_season(t.scope('05'), 'shareable') as e;
select t.ok((select e->>'kind' = 'season' and jsonb_array_length(e->'rows') = (select count(*) from public.footprints where scope_id = t.scope('05'))
                    and not (e->'columns' ? 'farmer_name') and position((select farmer from names) in e::text) = 0 and position('5217' in e::text) = 0 from ss),
            'C1: the season: every record of the scope, shareable: no name, no price');
select t.ok((select (s->>'records')::int >= 2 and (s->>'kg_out')::numeric > 0 from ss, jsonb_array_elements(e->'summary') s where s->>'stage' = 'procurement')
            and (select (s->>'floor_loss_kg')::numeric = 3 and (s->>'by_products_kg')::numeric = 26 from ss, jsonb_array_elements(e->'summary') s where s->>'stage' = 'milling'),
            'C3/E2.2: the summary per stage, in the chain''s order: records, kg, by-products apart from the floor loss');
select t.ok((select (e->'totals'->>'farmers')::int >= 2 and (e->'totals'->>'kg_in')::numeric = (select sum(qty_out) from public.footprints where scope_id = t.scope('05') and stage_type = 'procurement')
                    and (e->'totals'->>'packs')::int >= 150 and e->'totals' ? 'gi_pct' and e->'totals' ? 'farm_verified_kg' from ss),
            'C3: the season''s totals: farmers, kg in, GI share, farm-verified kg, packs');
select t.ok((select b->>'first' = (select code from bc) || '-0001' and b->>'last' = (select code from bc) || '-0150' and (b->>'packs')::int = 150
               from ss, jsonb_array_elements(e->'batches') b where b->>'batch_code' = (select code from bc)),
            'C3: each batch with its pack count and serial range');
select t.ok((select round(sum((r->>(select (o - 1)::int from jsonb_array_elements_text(e->'columns') with ordinality c(k, o) where k = 'share_pct'))::numeric), 0) = 100
               from ss, jsonb_array_elements(e->'rows') r where r->>(select (o - 1)::int from jsonb_array_elements_text(e->'columns') with ordinality c(k, o) where k = 'share_pct') is not null),
            'C3: the farm-gate shares of the season add up to 100 %');
select t.as_user(t.u('04'));
select t.ok((select e->>'copy' = 'internal' and e->'columns' ? 'farmer_name' from (select app.export_season(t.scope('05'), 'internal') e) x),
            'C4: the client''s own login takes the season''s internal copy');
select t.as_user(t.u('01'));
select t.fails(format('select app.export_season(%L, %L)', t.scope('05'), 'internal'), 'the internal copy is for the people of this scope', 'C4: the admin does not');

-- C5 · every export in the Audit log ----------------------------------------------------------------------------------------------
select t.as_service();
select t.ok((select count(*) from public.audit_log where action = 'export_downloaded') - :audit_before = 6
            and exists (select 1 from public.audit_log where action = 'export_downloaded' and actor = t.u('04') and detail->>'kind' = 'season' and detail->>'copy' = 'internal')
            and exists (select 1 from public.audit_log where action = 'export_downloaded' and actor = t.u('03') and target = pg_temp.f('K') and detail->>'copy' = 'shareable' and (detail->>'rows')::int = 4),
            'C5: each export is in the Audit log: who, which, which copy, how many rows; a refused one is not');

-- C2 · the times and a withdrawn record, as the old journey CSV had them (faults of 4 Oct: when the work was done, when the
-- server got it; the withdrawal with its reason) -----------------------------------------------------------------------------
with r as (insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, captured_at)
           select scope_id, client_id, stage_type, farmer_id, created_by, payload, now() - interval '3 days' from public.footprints where id = pg_temp.f('P2')
           returning id)
insert into fx select 'P3', id from r;
insert into codes select 'P3', footprint_code from public.footprints where id = pg_temp.f('P3');
select t.as_user(t.u('03')); select app.withdraw_footprint(pg_temp.f('P2'), 'weighed twice (test)');
create temp table sw as select app.export_season(t.scope('05'), 'shareable') as e;
select t.ok((select pg_temp.cell(e, pg_temp.c('P3'), 'recorded_at') = to_jsonb(to_char((now() - interval '3 days') at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'))
                    and pg_temp.cell(e, pg_temp.c('P3'), 'received_at') = to_jsonb(to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI')) from sw),
            'C2: when the work was done (kept on the phone three days) and when the server got it, both in IST');
select t.ok((select pg_temp.cell(e, pg_temp.c('P2'), 'withdrawn') #>> '{}' like '%: weighed twice (test)' from sw),
            'C2: a withdrawn record says when and why (who: the internal copy''s Audit, not the shareable copy)');
select t.as_service();

-- A5 · the public lot page names the lab ---------------------------------------------------------------------------------------------
insert into fx select 'P1', t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P1'));
insert into fx select 'Q1', pg_temp.ins(t.scope('01'), 'qc', pg_temp.f('P1'), t.u('06'),
  jsonb_build_object('qty_kg', 98, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                     'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/156', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-56'));
select t.as_service(); select t.attach(pg_temp.f('Q1'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q1'));
insert into fx select 'R1', pg_temp.ins(t.scope('01'), 'qr_activation', pg_temp.f('Q1'), t.u('07'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_anon();
select t.ok((select e->'lab' = '{"name": "Gorakhpur Grain Lab", "accreditation_no": "TC-5521"}'::jsonb
               from jsonb_array_elements(app.public_lot_journey((select code from seal))->'journey') e where e->>'stage' = 'qc'),
            'A5: the public lot page names the lab and its accreditation number (nothing else of it)');
select t.fails(format('select app.export_journey(%L, %L)', pg_temp.f('R1'), 'shareable'), 'permission denied', 'C1: the exports are for signed-in people only');

rollback;
