-- Migration 58 (release 11; Veda, 16 Oct 2026: "There should a mechanism to choose packs and in future there will be more
-- than 1 lakhs packs"; "carton size - cm sets them in the pack list"; on the HR Admin's screens "report to - it sees all
-- people which should not be the case", "department ... there should be drop down"; "proceed with 58"):
--   1  Cartons: the Client Manager sets packs per carton on a pack type; Packing makes the cartons by itself (the last
--      holds what is left); the labels; a pack voided opens its carton; a correction voids the cartons with the packs.
--   2  Orders: a sale sets aside the cartons chosen, then the oldest free ones, then packs of a partly free carton; never
--      another order's; the free cartons in runs.
--   3  Shipment: a carton's code stands for its packs; an opened carton, a pack in a scanned carton, a carton set aside
--      for another order are refused; the counts.
--   4  People: Reports to, the buddy and the department are the database's rule (a manager of the person's state, a
--      colleague of that state, the HR Admin's list); the choices; the import leaves out what is not allowed.
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201; 12 an operator of client 202; 16 the HR Admin, 17 an HR resource.
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
create or replace function pg_temp.batch() returns text language sql stable security definer as $$
  select batch_code from public.pack_batches where footprint_id = (select id from fx where k = 'K') $$;
create or replace function pg_temp.c(n int) returns text language sql stable as $$ select pg_temp.batch() || '-C' || lpad(n::text, 4, '0') $$;
create or replace function pg_temp.pk(n int) returns text language sql stable as $$ select pg_temp.batch() || '-' || lpad(n::text, 4, '0') $$;
create or replace function pg_temp.units(p uuid) returns text language sql stable security definer as $$
  select string_agg(case when u->>'kind' = 'carton' then right(u->>'code', 5) else 'p' || right(u->>'code', 4) end, ',' order by o)
    from public.footprints f, jsonb_array_elements(f.computed->'units') with ordinality as x(u, o) where f.id = p $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 1 · Cartons -----------------------------------------------------------------------------------------------------------
set local app.change_path = 'test setup';
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 5, 'kg', 'jute', 'domestic', 'tag') returning id) insert into fx select 'SKU5', id from r;
select t.as_user(t.u('03'));
update public.pack_skus set packs_per_carton = 20 where id = pg_temp.f('SKU1');
select t.ok((select packs_per_carton = 20 from public.pack_skus where id = pg_temp.f('SKU1')), 'the Client Manager sets packs per carton on a pack type of his list');
select t.fails(format('update public.pack_skus set packs_per_carton = 1001 where id = %L', pg_temp.f('SKU1')), 'packs_per_carton', 'a carton holds 1 to 1,000 packs');
select t.as_user(t.u('09'));
update public.pack_skus set packs_per_carton = 10 where id = pg_temp.f('SKU1');
select t.as_service();
select t.ok((select packs_per_carton = 20 from public.pack_skus where id = pg_temp.f('SKU1')), 'the packing operator does not change the pack list (it stays 20)');
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service(); select t.attach(pg_temp.f('Q'), 'lab_report');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":180,"broken_kg":5,"husk_kg":10,"bran_kg":4}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
-- a first packing record of 150 one-kilo pouches and 4 bags of 5 kg; corrected (in place) to 150 pouches and 2 bags
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":170,"packets":[{"sku_id":"%s","units":150,"size_kg":1},{"sku_id":"%s","units":4,"size_kg":5}]}', pg_temp.f('SKU1'), pg_temp.f('SKU5'))::jsonb);
select t.as_service();
select t.ok((select count(*) = 8 and sum(n) = 150 and count(*) filter (where n = 20) = 7 and max(code) filter (where n = 10) = pg_temp.c(8)
                    and bool_and(sku_id = pg_temp.f('SKU1')) and min(code) = pg_temp.c(1) and min(first_serial) = pg_temp.pk(1)
               from public.cartons where footprint_id = pg_temp.f('K')),
            'Packing makes the cartons by itself: 150 pouches in 7 cartons of 20 and the last of 10, codes <batch>-C0001 on');
select t.ok((select count(*) filter (where carton_code is not null) = 150 and count(*) filter (where carton_code is null) = 4
                    and bool_and(carton_code = pg_temp.c(2)) filter (where serial between pg_temp.pk(21) and pg_temp.pk(40))
               from public.packs where footprint_id = pg_temp.f('K')),
            'each pouch knows its carton (0021 to 0040 in C0002); the bags of a type without a carton size stay loose');
select t.as_user(t.u('09'));
update public.footprints set payload = format('{"input_kg":160,"packets":[{"sku_id":"%s","units":150,"size_kg":1},{"sku_id":"%s","units":2,"size_kg":5}]}',
                                              pg_temp.f('SKU1'), pg_temp.f('SKU5'))::jsonb where id = pg_temp.f('K');
select t.as_service();
select t.ok((select count(*) filter (where status = 'void') = 8 and count(*) filter (where status = 'packed') = 8
                    and min(code) filter (where status = 'packed') = pg_temp.c(9) and max(code) filter (where status = 'packed') = pg_temp.c(16)
               from public.cartons where footprint_id = pg_temp.f('K')),
            'a correction voids the cartons with the packs and makes new ones (C0009 to C0016), never deleting');
select t.ok((select count(*) = 150 from public.packs pk join public.cartons c on c.code = pk.carton_code
              where pk.footprint_id = pg_temp.f('K') and pk.status = 'packed' and c.status = 'packed'),
            'the 150 new pouches are in the new cartons');
-- from here the cartons are C0009 (n 1) to C0016 (n 8); pg_temp.c counts from the first new one
create or replace function pg_temp.c(n int) returns text language sql stable as $$ select pg_temp.batch() || '-C' || lpad((n + 8)::text, 4, '0') $$;
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
-- labels
select t.as_user(t.u('09'));
create temp table lab as select app.carton_labels(pg_temp.f('K')) as j;
grant select on lab to authenticated;
select t.ok((select jsonb_array_length(j->'cartons') = 8 and j->'cartons'->0->>'code' = pg_temp.c(1) and (j->'cartons'->0->>'n')::int = 20
                    and j->'cartons'->7->>'last_serial' like '%-0304' and j->'cartons'->0->>'sku' is not null and j->'cartons'->0->>'packed_on' is not null
                    and j->>'crop' is not null from lab),
            'the carton labels: each carton''s code, pack type, packs and code range, the packing day');
select t.as_user(t.u('11'));
select t.fails(format('select app.carton_labels(%L)', pg_temp.f('K')), 'labels are printed at Packing', 'another stage does not print them');
select t.as_user(t.u('12'));
select t.fails(format('select app.carton_labels(%L)', pg_temp.f('K')), 'record not found', 'another client''s person: not found');
select t.ok((select count(*) = 0 from public.cartons), 'another client''s person reads no carton');

-- 2 · Orders ------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true, record_price = false where id = t.scope('05');
select t.as_user(t.u('11'));
create temp table av as select app.available_cartons(pg_temp.f('K')) as j;
grant select, delete, insert on av to authenticated;
select t.ok((select jsonb_array_length(j) = 1 and (j->0->>'cartons')::int = 8 and (j->0->>'packs')::int = 150 and (j->0->>'per_carton')::int = 20
                    and jsonb_array_length(j->0->'runs') = 1 and j->0->'runs'->0->>'from' = pg_temp.c(1) and j->0->'runs'->0->>'to' = pg_temp.c(8) from av),
            'the free cartons, per pack type, in runs: one run C0009 to C0016, 8 cartons, 150 pouches');
insert into fx select 'D', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-201","packs":[{"sku_id":"%s","units":45}]}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
select t.ok(pg_temp.units(pg_temp.f('D')) = 'C0009,C0010,p0304,p0303,p0302,p0301,p0300' or pg_temp.units(pg_temp.f('D')) like 'C0009,C0010,p%',
            'an order of 45 with nothing chosen: the two oldest cartons, then 5 pouches of the smallest carton');
select t.ok((select count(*) = 5 from jsonb_array_elements((pg_temp.fp(pg_temp.f('D'))).computed->'units') u join public.packs pk on pk.serial = u->>'code'
              where pk.carton_code = pg_temp.c(8)),
            '(the 5 pouches come from the last carton, of 10)');
select t.fails(format($q$select pg_temp.ins(%L, 'commercial', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-202","packs":[{"sku_id":"%s","units":40}],"cartons":["%s"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'), pg_temp.c(1))),
  'not a free carton of this lot', 'a carton another order has set aside cannot be chosen');
select t.fails(format($q$select pg_temp.ins(%L, 'commercial', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-202","packs":[{"sku_id":"%s","units":40}],"cartons":["%s"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'), pg_temp.c(8))),
  'not a free carton of this lot', 'nor a carton partly set aside');
select t.fails(format($q$select pg_temp.ins(%L, 'commercial', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-202","packs":[{"sku_id":"%s","units":10}],"cartons":["%s"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'), pg_temp.c(5))),
  'the cartons chosen hold more packs of', 'a carton of 20 for an order of 10: refused (a carton goes whole)');
select t.fails(format($q$select pg_temp.ins(%L, 'commercial', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-202","packs":[{"sku_id":"%s","units":40}],"cartons":["NOPE-C0001"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'))),
  'not a free carton of this lot', 'a code that is no carton of this lot');
insert into fx select 'E', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-202","packs":[{"sku_id":"%s","units":40}],"cartons":["%s"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'), lower(pg_temp.c(5)))::jsonb);
select t.ok(pg_temp.units(pg_temp.f('E')) = 'C0013,C0011', 'an order of 40 choosing C0013 (typed in small letters): C0013, then the oldest free one, C0011');
delete from av; insert into av select app.available_cartons(pg_temp.f('K'));
select t.ok((select (j->0->>'cartons')::int = 3 and jsonb_array_length(j->0->'runs') = 2
                    and j->0->'runs'->0->>'from' = pg_temp.c(4) and j->0->'runs'->0->>'to' = pg_temp.c(4)
                    and j->0->'runs'->1->>'from' = pg_temp.c(6) and j->0->'runs'->1->>'to' = pg_temp.c(7) from av),
            'free now: C0012 alone and C0014 to C0015 (C0016, partly set aside, is not offered)');
select t.ok((select (j->0->>'cartons')::int = 5 from (select app.available_cartons(pg_temp.f('K'), pg_temp.f('E')) j) x),
            'a correction of an order sees its own cartons as free');
-- a pack voided opens its carton: not offered, not chosen, not scanned whole
select t.as_user(t.u('09'));
select app.void_pack(pg_temp.pk(290), 'pouch torn when stacking');
select t.ok((select status = 'opened' from public.cartons where code = pg_temp.c(7)), 'a pouch voided in C0015 opens the carton');
select t.as_user(t.u('11'));
select t.ok((select (j->0->>'cartons')::int = 2 from (select app.available_cartons(pg_temp.f('K'))) x(j)), 'an opened carton is no longer offered');
select t.fails(format($q$select pg_temp.ins(%L, 'commercial', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-203","packs":[{"sku_id":"%s","units":20}],"cartons":["%s"]}', pg_temp.f('BUY'), pg_temp.f('SKU1'), pg_temp.c(7))),
  'not a free carton of this lot', 'nor chosen');
-- a lot without cartons: no units, as before

select t.fails(format('select app.available_cartons(%L)', pg_temp.f('D')), 'record not found', 'available cartons: of a packing record only');
select t.as_user(t.u('12'));
select t.fails(format('select app.available_cartons(%L)', pg_temp.f('K')), 'record not found', 'another client''s person: not found');

-- 3 · Shipment ----------------------------------------------------------------------------------------------------------
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D')); select app.verify_footprint(pg_temp.f('E'));
create temp table oc as select app.order_pack_codes(pg_temp.f('D')) as j;
grant select on oc to authenticated;
select t.ok((select count(*) = 7 and sum((u->>'n')::int) = 45 and count(*) filter (where u->>'kind' = 'carton') = 2
                    and bool_and(u->>'first_serial' is not null and u->>'last_serial' is not null) filter (where u->>'kind' = 'carton')
                    and bool_and(u->>'sku' is not null and not (u->>'void')::boolean and u->>'shipped_in' is null)
               from oc, jsonb_array_elements(j) u),
            'what the phone checks against: 2 cartons (each with its range) and 5 pouches, 45 in all');
create temp table sp as select array[pg_temp.c(1), pg_temp.c(2)] || (select array_agg(u->>'code') from jsonb_array_elements((pg_temp.fp(pg_temp.f('D'))).computed->'units') u where u->>'kind' = 'pack') as s;
grant select on sp to authenticated;
create or replace function pg_temp.ship(p_serials text[]) returns uuid language sql as $$
  select pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('D'), t.u('14'),
    format('{"invoice_no":"INV-9","vehicle_no":"UP53AB1234","lr_no":"LR-9","eway_bill_no":"123456789099","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":45}]}', pg_temp.f('SKU1'))::jsonb
    || jsonb_build_object('serials', to_jsonb(p_serials))) $$;
grant execute on function pg_temp.ship(text[]) to authenticated;
select t.fails(format('select pg_temp.ship(%L::text[])', (select s from sp) || pg_temp.pk(160)), 'a pack code is there twice', 'a carton and a pouch in it: there twice');
select t.fails(format('select pg_temp.ship(%L::text[])', (select s[2:7] from sp) || pg_temp.c(7)), 'carton ' || pg_temp.c(7) || ' was opened', 'an opened carton: its packs one by one');
select t.fails(format('select pg_temp.ship(%L::text[])', (select s[2:7] from sp) || pg_temp.c(3)), pg_temp.c(3) || ' not set aside for this order', 'a carton set aside for another order: refused, the carton named');
select t.fails(format('select pg_temp.ship(%L::text[])', (select s[2:7] from sp) || pg_temp.c(4)), 'not set aside for this order', 'a free carton not of this order: refused');
select t.fails(format('select pg_temp.ship(%L::text[])', (select s[1:6] from sp)), 'do not match the packs shipped', 'a pouch short: the count does not match');
insert into fx select 'SD', pg_temp.ship((select s from sp));
select t.ok((pg_temp.fp(pg_temp.f('SD'))).computed @> '{"serials_count": 45, "cartons_count": 2}', '2 cartons and 5 pouches scanned: 45 packs shipped, 2 cartons');
select t.ok((select count(*) = 7 and count(*) filter (where u->>'shipped_in' = (pg_temp.fp(pg_temp.f('SD'))).footprint_code) = 7
               from jsonb_array_elements(app.order_pack_codes(pg_temp.f('D'))) u),
            'the order''s cartons and pouches are shipped, in which shipment');
select t.ok((select count(*) = 2 and bool_and(u->>'shipped_in' is null) from jsonb_array_elements(app.order_pack_codes(pg_temp.f('E'))) u),
            'the other order''s two cartons are not');
-- with the cartons spelt in small letters and a pouch of a carton scanned elsewhere
select t.fails(format($q$select pg_temp.ins(%L, 'shipment', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('E'), t.u('14'),
  format('{"invoice_no":"INV-10","vehicle_no":"UP53AB1234","lr_no":"LR-10","eway_bill_no":"123456789098","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":40}]}', pg_temp.f('SKU1'))::jsonb
  || jsonb_build_object('serials', jsonb_build_array(pg_temp.c(5), pg_temp.c(3), pg_temp.pk(160)))),
  pg_temp.pk(160) || ' shipped already', 'a pouch of a carton shipped on another order: shipped already, named');
select t.as_service();
-- the public pack page names its carton
select t.as_anon();
-- migration 59 (A1): before release a pack's page shows the crop, the batch and the date packed only, not its carton
select t.ok(not (app.public_pack(pg_temp.pk(160))->'pack' ? 'carton') and app.public_pack(pg_temp.pk(301))->'pack'->>'batch_code' = pg_temp.batch(),
            'a pack''s public data before release: no carton, the batch code');
select t.as_service();

-- 4 · People: Reports to, the buddy, the department ----------------------------------------------------------------------
set local app.change_path = 'test setup';
-- a manager based in Assam, a colleague in Assam, an associate of UP with an email
insert into public.app_users (id, display_name, role, status, system_role, email) values
  ('00000000-0000-4000-8000-000000000391', 'Assam Manager', 'operator', 'active', 'operational', 'asm@test.in'),
  ('00000000-0000-4000-8000-000000000392', 'Assam Colleague', 'operator', 'active', 'operational', 'asc@test.in');
insert into public.employee_org (employee_id, designation_band, base_state_id) values
  ('00000000-0000-4000-8000-000000000391', 'Manager', '00000000-0000-4000-8000-000000000002'),
  ('00000000-0000-4000-8000-000000000392', 'Associate', '00000000-0000-4000-8000-000000000002');
update public.app_users set email = 'op05@test.in' where id = t.u('05');
select t.ok((select count(*) = 2 from public.employee_org where base_state_id = '00000000-0000-4000-8000-000000000002'),
            'the service''s own writes (seeds, migrations) are not a person''s choice: left alone');
select t.as_user(t.u('16'));
create temp table ch as select app.org_choices('00000000-0000-4000-8000-000000000001') as j;
grant select on ch to authenticated;
select t.ok((select string_agg(m->>'name', ', ' order by m->>'name') from ch, jsonb_array_elements(j->'managers') m)
            = 'Asha (HR Admin), Prasaadam Client Manager, UP State Manager, Veda (Admin)',
            'Reports to, for a person of UP: the managers of UP (band Manager or above, or a seat) and head office; not the operators, not Assam');
select t.ok((select bool_and(m->>'seat' is not null or m->>'band' in ('Manager', 'Senior Manager', 'Head')) from ch, jsonb_array_elements(j->'managers') m)
            and (select m->>'seat' = 'state_manager' and m->>'state' = 'Uttar Pradesh' from ch, jsonb_array_elements(j->'managers') m where m->>'name' = 'UP State Manager'),
            'each with the band, the seat and the state the screen shows');
select t.ok((select count(*) filter (where b->>'name' = 'Procurement Op (field)') = 1 and count(*) filter (where b->>'name' like 'Assam%') = 0
                    and count(*) filter (where b->>'name' like 'Veda%') = 0 and count(*) filter (where b->>'name' = 'Prasaadam Client View') = 0
               from ch, jsonb_array_elements(j->'buddies') b),
            'the buddy: colleagues of UP (not Assam, not the admin, not the client''s viewer)');
select t.ok((select j->'departments' ->> 0 = 'Operations' and jsonb_array_length(j->'departments') = 9 from ch), 'the departments: the list, in its order');
select t.ok((select count(*) filter (where m->>'name' = 'Assam Manager') = 1 and count(*) filter (where m->>'name' = 'UP State Manager') = 0
               from jsonb_array_elements(app.org_choices('00000000-0000-4000-8000-000000000002')->'managers') m),
            'for a person of Assam: Assam''s managers, not UP''s');
-- the database keeps the rule, whoever writes
select t.fails(format($q$select app.update_joiner(%L, '{"reports_to": "%s"}')$q$, t.u('18'), t.u('05')), 'reports to: choose a manager', 'Reports to an associate: refused');
select t.fails(format($q$select app.update_joiner(%L, '{"reports_to": "%s"}')$q$, t.u('18'), '00000000-0000-4000-8000-000000000391'), 'reports to: choose a manager', 'Reports to a manager of another state: refused');
select t.fails(format($q$select app.update_joiner(%L, '{"reports_to": "%s"}')$q$, t.u('03'), t.u('03')), 'reports to: choose a manager', 'nor to oneself');
select t.fails(format($q$select app.update_joiner(%L, '{"buddy": "%s"}')$q$, t.u('18'), '00000000-0000-4000-8000-000000000392'), 'buddy: choose a colleague', 'a buddy of another state: refused');
select t.fails(format($q$select app.update_joiner(%L, '{"department": "Marketing"}')$q$, t.u('18')), 'department: choose one from the list', 'a department not on the list: refused');
select app.update_joiner(t.u('18'), jsonb_build_object('reports_to', t.u('02'), 'buddy', t.u('06'), 'department', 'quality'));
select t.ok((select reports_to = t.u('02') and buddy = t.u('06') and department = 'Quality' from public.employee_org where employee_id = t.u('18')),
            'the State Manager, a colleague, "quality": saved, in the list''s spelling');
select app.update_joiner(t.u('17'), '{"job_title": "HR Executive"}');
select t.ok((select department = 'People' and job_title = 'HR Executive' from public.employee_org where employee_id = t.u('17')),
            'a department typed before stays until someone changes it');
select t.fails($q$ update public.employee_org set department = 'Nowhere' where employee_id = '00000000-0000-4000-8000-000000000318' $q$, '', 'the API cannot get around it');
-- a new joiner
select t.fails(format($q$select app.add_joiner(%L)$q$, jsonb_build_object('full_name', 'Nita New', 'personal_email', 'nita@test.in', 'phone', '9876500071',
  'join_date', (current_date + 10)::text, 'employment_type', 'full_time', 'base_state_id', '00000000-0000-4000-8000-000000000001', 'reports_to', t.u('05'))),
  'reports to: choose a manager', 'Add joiner: the same rule');
insert into fx select 'J', (app.add_joiner(jsonb_build_object('full_name', 'Nita New', 'personal_email', 'nita@test.in', 'phone', '9876500071',
  'join_date', (current_date + 10)::text, 'employment_type', 'full_time', 'base_state_id', '00000000-0000-4000-8000-000000000001',
  'reports_to', t.u('03'), 'department', 'Field Procurement'))->>'id')::uuid;
select t.ok((select reports_to = t.u('03') and department = 'Field Procurement' from public.employee_org where employee_id = pg_temp.f('J')), 'Add joiner: a Client Manager of UP and a department of the list');
-- the departments list
select t.as_user(t.u('17'));
select t.fails($q$select app.set_department('Seed Production')$q$, 'departments are kept by the HR Admin', 'an HR resource does not change the list');
select t.as_user(t.u('03'));
select t.fails($q$select app.set_department('Seed Production')$q$, 'departments are kept by the HR Admin', 'nor a Client Manager');
select t.fails($q$select app.org_choices(null)$q$, 'only HR of the person''s state', 'the choices are HR''s');
select t.as_user(t.u('01'));
select t.fails($q$select app.set_department('Seed Production')$q$, 'departments are kept by the HR Admin', 'nor the admin while the HR Admin seat is filled');
select t.as_user(t.u('16'));
select t.fails($q$select app.set_department('X')$q$, '2 to 60 characters', 'a name of 2 to 60 characters');
select app.set_department('Seed Production');
select app.set_department('seed production', false);
select t.ok((select not active from public.departments where name = 'Seed Production') and (select count(*) = 1 from public.departments where lower(name) = 'seed production')
            and exists (select 1 from public.audit_log where action = 'department_set' and detail->>'name' = 'Seed Production'),
            'the HR Admin adds a department and retires it (one row, whatever the case; in the Audit log)');
select t.ok(not (app.org_choices(null)->'departments' ? 'Seed Production'), 'a retired department is not offered');
select t.fails(format($q$select app.update_joiner(%L, '{"department": "Seed Production"}')$q$, t.u('18')), 'department: choose one from the list', 'nor accepted');
-- an HR resource works by state
select t.as_service();
update public.app_users set status = 'active' where id = t.u('17');
select t.as_user(t.u('16'));
select app.set_hr_states(t.u('17'), array['00000000-0000-4000-8000-000000000001']::uuid[]);
select t.as_user(t.u('17'));
select t.ok(jsonb_array_length(app.org_choices('00000000-0000-4000-8000-000000000001')->'managers') >= 3, 'an HR resource of UP: the choices for UP');
select t.fails($q$select app.org_choices('00000000-0000-4000-8000-000000000002')$q$, 'only HR of the person''s state', 'not for Assam');
-- the import: a manager or a department not allowed is left out, said
select t.as_user(t.u('16'));
create temp table imp as select app.import_joiners(jsonb_build_array(
  jsonb_build_object('full_name', 'Imp One', 'personal_email', 'imp1@test.in', 'phone', '9000011101', 'join_date', (current_date + 10)::text,
                     'employment_type', 'full_time', 'state', 'up', 'reports_to', 'op05@test.in', 'department', 'Marketing'),
  jsonb_build_object('full_name', 'Imp Two', 'personal_email', 'imp2@test.in', 'phone', '9000011102', 'join_date', (current_date + 10)::text,
                     'employment_type', 'full_time', 'state', 'up', 'reports_to', 'grainvedas+clientmanager@gmail.com', 'department', 'warehouse & logistics')), false) as j;
grant select on imp to authenticated;
select t.ok((select x->'reasons' ? 'imp.reports_to_not_manager' and x->'reasons' ? 'imp.department_unknown' from imp, jsonb_array_elements(j->'rows') x where (x->>'row')::int = 1),
            'the import: an associate as manager and an unknown department are warned of');
select t.as_service();   -- migration 59 (B4): email is read by the service, not through the API
select t.ok((select o.reports_to is null and o.department is null from public.employee_org o join public.app_users u on u.id = o.employee_id where u.email = 'imp1@test.in')
            and (select o.reports_to = t.u('03') and o.department = 'Warehouse & Logistics' from public.employee_org o join public.app_users u on u.id = o.employee_id where u.email = 'imp2@test.in'),
            'and left out; a manager of the state and a listed department (any case) are kept');
rollback;
