-- Migration 55 (Veda, 16 Oct 2026, "yes proceed": release 8 of the operator-stages plan, C3): the Warehouse.
-- Scope W (made here): Procurement (05) → Collection Batch (15) → Warehouse (10) → Milling (08) → QC (06) → QR (07).
-- Scope P (made here): Procurement (05) → Warehouse (10) → QC (06) → QR (07), sealed for the public page.
-- Scope 05 (Basti mill, no Warehouse): "stored but not recorded". 03 the Client Manager of client 201.
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
-- one person on some stages of a draft scope, the way the roster would (t.staff puts one person on all of them)
create or replace function pg_temp.put(p_scope uuid, p_user uuid, p_stages public.stage_type[]) returns void language plpgsql security definer as $$
declare a uuid; st public.stage_type;
begin
  perform set_config('app.assigning', 'on', true);
  insert into public.assignments (employee_id, lens, op_role, scope_id, stages, created_by)
  values (p_user, 'scope', 'operator', p_scope, p_stages, p_user) returning id into a;
  foreach st in array p_stages loop
    insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (p_user, p_scope, st, a) on conflict do nothing;
  end loop;
  perform set_config('app.assigning', '', true);
end $$;
-- the dates of practice records set back, the way only the database owner could (no trigger, no change log)
create or replace function pg_temp.age(p_fp uuid, p_days int) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.footprints set happened_on = happened_on - p_days, created_at = created_at - make_interval(days => p_days),
         captured_at = coalesce(captured_at, created_at) - make_interval(days => p_days) where id = p_fp;
  set local session_replication_role = origin;
end $$;
create or replace function pg_temp.age_insp(p_fp uuid, p_days int) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.warehouse_inspections set inspected_on = inspected_on - p_days where footprint_id = p_fp;
  set local session_replication_role = origin;
end $$;
-- a system check of a record, read by the Client Manager (then back to the service role)
create or replace function pg_temp.check(p_fp uuid, p_key text) returns boolean language plpgsql as $$
declare r boolean;
begin
  perform t.as_user(t.u('03'));
  select (x->>'ok')::boolean into r from jsonb_array_elements(app.system_checks(p_fp)) x where x->>'key' = p_key;
  perform t.as_service();
  return r;
end $$;
create or replace function pg_temp.wh(p_declared numeric, p_received numeric, p_extra jsonb default '{}') returns jsonb language sql immutable as $$
  select jsonb_build_object('declared_kg', p_declared, 'received_kg', p_received, 'condition', 'good', 'bags_in', 4,
                            'location', 'Bansi godown 2', 'stack', 'S-3') || p_extra $$;
create or replace function pg_temp.today() returns date language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;   -- app.today() is the server's
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 1 · Where the Warehouse sits in a chain -----------------------------------------------------------------------------
select t.ok(cardinality(app.chain_problems('{procurement,warehouse,qc,qr_activation}', '00000000-0000-4000-8000-000000000101')) = 0
            and cardinality(app.chain_problems('{procurement,village_batch,warehouse,milling,qc,qr_activation}', '00000000-0000-4000-8000-000000000101')) = 0
            and cardinality(app.chain_problems('{lot_inward,warehouse,milling,qc,qr_activation}', '00000000-0000-4000-8000-000000000101')) = 0,
            'the Warehouse right after the entry stage, or after the Collection Batch');
select t.ok('the warehouse comes right after the entry stage (or the Collection Batch)' = any (app.chain_problems('{procurement,qc,warehouse,qr_activation}', '00000000-0000-4000-8000-000000000101'))
            and 'the warehouse comes right after the entry stage (or the Collection Batch)' = any (app.chain_problems('{procurement,village_batch,milling,warehouse,qc,qr_activation}', '00000000-0000-4000-8000-000000000101')),
            'not after QC or after Milling');
select t.ok((select count(*) from public.stage_definitions) = 17
            and (select sort_order > (select sort_order from public.stage_definitions where stage_type = 'village_batch')
                    and sort_order < (select sort_order from public.stage_definitions where stage_type = 'milling')
                    and not is_processing from public.stage_definitions where stage_type = 'warehouse'),
            'the stage list has 17 stages: the Warehouse between the Collection Batch and Milling, not a processing stage');
select t.ok((select bool_and(f->'shown_if' = '{"market": "export"}') from public.stage_definitions d, jsonb_array_elements(d.form_schema) f
              where d.stage_type = 'commercial' and f->>'key' in ('market_code', 'destination_country', 'incoterms'))
            and (select count(*) from public.stage_definitions d, jsonb_array_elements(d.form_schema) f
                  where d.stage_type = 'commercial' and f ? 'shown_if') = 3,
            'a domestic order no longer shows the export market, the destination country and the Incoterms');

-- 2 · A scope with a Warehouse: chosen when it is built ---------------------------------------------------------------
select t.as_user(t.u('03'));
with x as (insert into public.scopes (client_id, crop_id, season_code, geography, chain, status, stage_details_required)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'KH26', 'Bansi godown (test 49)',
          '{procurement,village_batch,warehouse,milling,qc,qr_activation}', 'draft', false) returning id)
insert into fx select 'W', id from x;
select t.ok((select warehouse_inspection_days from public.scopes where id = pg_temp.f('W')) = 15, 'a stored lot is inspected every 15 days unless its Client Manager says otherwise');
select t.as_service();
select pg_temp.put(pg_temp.f('W'), t.u('05'), '{procurement}');
select pg_temp.put(pg_temp.f('W'), t.u('15'), '{village_batch}');
select pg_temp.put(pg_temp.f('W'), t.u('10'), '{warehouse}');
select pg_temp.put(pg_temp.f('W'), t.u('08'), '{milling}');
select pg_temp.put(pg_temp.f('W'), t.u('06'), '{qc}');
select pg_temp.put(pg_temp.f('W'), t.u('07'), '{qr_activation}');
select t.as_user(t.u('03'));
update public.scopes set status = 'active', warehouse_inspection_days = 10 where id = pg_temp.f('W');
select t.ok((select status = 'active' and warehouse_inspection_days = 10 from public.scopes where id = pg_temp.f('W')), 'activated with every stage staffed; every 10 days');
select t.fails(format($$update public.scopes set warehouse_inspection_days = 0 where id = %L$$, pg_temp.f('W')), 'scopes_warehouse_inspection_days', 'the interval is 1 to 120 days');
select t.fails(format($$update public.scopes set chain = '{procurement,village_batch,milling,qc,qr_activation}' where id = %L$$, pg_temp.f('W')), 'frozen', 'the chain of an active scope stays as it was built');
select t.as_user(t.u('10'));
update public.scopes set warehouse_inspection_days = 99 where id = pg_temp.f('W');
select t.as_service();
select t.ok((select warehouse_inspection_days from public.scopes where id = pg_temp.f('W')) = 10, 'the Warehouse person does not change the interval');

-- the lots, and their Collection Batch
select t.as_user(t.u('05'));
insert into fx select 'L1', t.procure_as(pg_temp.f('W'), t.farmer('05'), t.u('05'));
insert into fx select 'L2', t.procure_as(pg_temp.f('W'), t.farmer('04'), t.u('05'));
insert into fx select 'L3', t.procure_as(pg_temp.f('W'), t.farmer('05'), t.u('05'));
insert into fx select 'L4', t.procure_as(pg_temp.f('W'), t.farmer('04'), t.u('05'));
select t.as_user(t.u('15'));
select app.verify_footprint(pg_temp.f('L1')); select app.verify_footprint(pg_temp.f('L2'));
select app.verify_footprint(pg_temp.f('L3')); select app.verify_footprint(pg_temp.f('L4'));
insert into fx select 'VB', pg_temp.ins(pg_temp.f('W'), 'village_batch', pg_temp.f('L1'), t.u('15'),
  format('{"source_footprint_ids":["%s","%s"]}', pg_temp.f('L1'), pg_temp.f('L2'))::jsonb);
insert into fx select 'VB2', pg_temp.ins(pg_temp.f('W'), 'village_batch', pg_temp.f('L3'), t.u('15'), format('{"source_footprint_ids":["%s"]}', pg_temp.f('L3'))::jsonb);
insert into fx select 'VB3', pg_temp.ins(pg_temp.f('W'), 'village_batch', pg_temp.f('L4'), t.u('15'), format('{"source_footprint_ids":["%s"]}', pg_temp.f('L4'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('VB'))).qty_out = 196, 'the batch: 196 kg');
select t.as_user(t.u('08'));
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('VB')), 'may not verify a village_batch record', 'Milling does not check the batch in: the Warehouse is between');
select t.as_user(t.u('10'));
select app.verify_footprint(pg_temp.f('VB')); select app.verify_footprint(pg_temp.f('VB2')); select app.verify_footprint(pg_temp.f('VB3'));
select t.ok((pg_temp.fp(pg_temp.f('VB'))).status = 'verified', 'the Warehouse checks the batch in');

-- 3 · Arrival: sent and received, the difference, a reason, the flag ---------------------------------------------------
select t.as_user(t.u('08'));
select t.fails(format($$select pg_temp.ins(%L, 'milling', %L, t.u('08'), '{"input_kg":196,"head_rice_kg":150,"broken_kg":10,"husk_kg":30,"bran_kg":6}')$$, pg_temp.f('W'), pg_temp.f('VB')),
               'predecessor of milling must be warehouse', 'Milling does not take the batch past the Warehouse');
select t.as_user(t.u('06'));
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('06'), pg_temp.wh(196, 196))$$, pg_temp.f('W'), pg_temp.f('VB')), 'may not create at stage warehouse', 'only the Warehouse person records the arrival');
select t.as_user(t.u('10'));
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(0, 190))$$, pg_temp.f('W'), pg_temp.f('VB')), 'what was sent is more than 0 kg', 'what was sent');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 0))$$, pg_temp.f('W'), pg_temp.f('VB')), 'what was received is more than 0 kg', 'what was received');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 197))$$, pg_temp.f('W'), pg_temp.f('VB')), 'more than was sent', 'not more received than was sent');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 190))$$, pg_temp.f('W'), pg_temp.f('VB')), 'say why 6 kg less', 'a difference needs its reason');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 190, '{"discrepancy_reason":"dry"}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'at least 5 characters', 'a reason of 5 characters or more');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 196, '{"condition":"fine"}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'good, damp, pest or mixed', 'the condition on arrival from the list');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 196, '{"bags_in":2.5}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'whole number, 1 or more', 'bags in: a whole number');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 196, '{"bags_in":0}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'whole number, 1 or more', 'bags in: at least 1');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(196, 196, '{"location":" "}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'name the warehouse or location', 'the location');
select t.fails(format($$select pg_temp.ins(%L, 'warehouse', %L, t.u('10'), pg_temp.wh(250, 240, '{"discrepancy_reason":"dried in the sun"}'))$$, pg_temp.f('W'), pg_temp.f('VB')), 'exceeds available', 'not more sent than the batch holds');
insert into fx select 'WH', pg_temp.ins(pg_temp.f('W'), 'warehouse', pg_temp.f('VB'), t.u('10'), pg_temp.wh(196, 190, '{"discrepancy_reason":"dried in the sun on the way"}'));
select t.ok((pg_temp.fp(pg_temp.f('WH'))).qty_in = 196 and (pg_temp.fp(pg_temp.f('WH'))).qty_out = 190
            and (pg_temp.fp(pg_temp.f('WH'))).computed @> '{"discrepancy_kg": 6, "discrepancy_pct": 3.06, "condition": "good", "bags_in": 4, "location": "Bansi godown 2", "stack": "S-3"}',
            'stored: 196 kg sent, 190 received, 6 kg (3.06 %) less, its place and stack, 4 bags');
select t.ok((pg_temp.fp(pg_temp.f('WH'))).footprint_code like '%-WH-%', 'a stored lot''s code says WH');
select t.ok(exists (select 1 from unnest((pg_temp.fp(pg_temp.f('WH'))).warnings) w where w like 'the warehouse received 6 kg (3.1 %) less than was sent%'), 'the record says it is flagged');
select t.as_service();
select t.ok((select count(*) from public.flags where footprint_id = pg_temp.f('WH') and status = 'open' and kind = 'flag'
               and text like 'Warehouse: received 190% kg, 3.06 % less than was sent (196% kg); more than 2 %. Reason given: dried in the sun on the way') = 1
            and (select raised_by from public.flags where footprint_id = pg_temp.f('WH')) = t.u('10'),
            'above 2 % a flag for the manager, in the name of who recorded it, with the reason');
update public.footprints set payload = payload || '{"note":"re-weighed"}' where id = pg_temp.f('WH');
select t.ok((select count(*) from public.flags where footprint_id = pg_temp.f('WH')) = 1, 'raised once');
select t.ok(not pg_temp.check(pg_temp.f('WH'), 'wh_difference') and pg_temp.check(pg_temp.f('WH'), 'wh_inspections'), 'the system checks: the difference above the limit; inspections not overdue');
select t.as_user(t.u('03'));
select t.ok((select x->'vars' from jsonb_array_elements(app.system_checks(pg_temp.f('WH'))) x where x->>'key' = 'wh_difference') = '{"kg": "6", "pct": "3.06"}',
            'its figures as people read them (6 kg, 3.06 %: found in the pictures, "6.000 kg, 3.00 %")');
select t.as_service();
select t.as_user(t.u('10'));
insert into fx select 'WH2', pg_temp.ins(pg_temp.f('W'), 'warehouse', pg_temp.f('VB2'), t.u('10'), pg_temp.wh(98, 97, '{"discrepancy_reason":"moisture lost", "bags_in": 2}'));
insert into fx select 'WH3', pg_temp.ins(pg_temp.f('W'), 'warehouse', pg_temp.f('VB3'), t.u('10'), pg_temp.wh(98, 98, '{"bags_in": 2}') - 'stack');
select t.as_service();
select t.ok((select count(*) from public.flags where footprint_id in (pg_temp.f('WH2'), pg_temp.f('WH3'))) = 0
            and pg_temp.check(pg_temp.f('WH2'), 'wh_difference') and pg_temp.check(pg_temp.f('WH3'), 'wh_difference'),
            'within 2 % (1 kg of 98) no flag; the same weight needs no reason');
select t.ok(not ((pg_temp.fp(pg_temp.f('WH3'))).computed ? 'stack') and ((pg_temp.fp(pg_temp.f('WH3'))).computed->>'discrepancy_kg')::numeric = 0, 'the stack may be left out');

-- 4 · Inspections: who, when, what was found; due and overdue -----------------------------------------------------------
select t.as_user(t.u('06'));
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'good')$$, pg_temp.f('WH')), 'record not found', 'QC does not inspect a stored lot');
select t.as_user(t.u('08'));
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'good')$$, pg_temp.f('WH')), 'inspected by the Warehouse or a manager', 'nor Milling');
select t.as_user(t.u('10'));
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'good')$$, pg_temp.f('VB')), 'is of a lot in the warehouse', 'a batch is not inspected here');
select t.fails(format($$select app.record_inspection(%L, pg_temp.today() - 1, 'good')$$, pg_temp.f('WH')), 'between the lot''s arrival', 'not before it arrived');
select t.fails(format($$select app.record_inspection(%L, pg_temp.today() + 1, 'good')$$, pg_temp.f('WH')), 'between the lot''s arrival', 'not tomorrow');
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'fine')$$, pg_temp.f('WH')), 'good, minor deterioration', 'the condition from the list');
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'minor')$$, pg_temp.f('WH')), 'say what was found', 'anything but good: what was found');
select app.record_inspection(pg_temp.f('WH'), pg_temp.today(), 'good');
select t.as_service();
select t.ok((app.inspection_state(pg_temp.f('WH'))) @> jsonb_build_object('interval_days', 10, 'last_on', pg_temp.today(), 'next_due', pg_temp.today() + 10, 'state', 'ok', 'last_condition', 'good'),
            'inspected today: the next in 10 days');
select t.as_user(t.u('03'));
select app.record_inspection(pg_temp.f('WH'), pg_temp.today(), 'minor', 'a few damp bags at the bottom of the stack');
select t.as_service();
select t.ok((select count(*) from public.warehouse_inspections where footprint_id = pg_temp.f('WH')) = 2
            and (select inspected_by from public.warehouse_inspections where footprint_id = pg_temp.f('WH') and condition = 'minor') = t.u('03')
            and (app.inspection_state(pg_temp.f('WH'))->>'last_condition') = 'minor',
            'the Client Manager inspects too; who and what was found are kept');
select t.ok((select count(*) from public.audit_log where action = 'warehouse_inspection' and target = pg_temp.f('WH')) = 2
            and (select count(*) from public.change_log where table_name = 'warehouse_inspections') >= 2,
            'each inspection in the Audit log and the change log');
select t.as_user(t.u('10'));
select t.fails(format($$insert into public.warehouse_inspections (footprint_id, scope_id, inspected_on, condition, inspected_by) values (%L, %L, pg_temp.today(), 'good', t.u('10'))$$, pg_temp.f('WH'), pg_temp.f('W')),
               'permission denied', 'nobody writes an inspection past its function');
select t.ok((select count(*) from public.warehouse_inspections where footprint_id = pg_temp.f('WH')) = 2, 'the Warehouse person reads its inspections');
select t.as_user(t.u('12'));
select t.ok((select count(*) from public.warehouse_inspections) = 0, 'another client''s operator reads none');
-- arrived 20 days ago, last inspected 9 days ago: due tomorrow
select t.as_service();
select pg_temp.age(pg_temp.f('WH'), 20); select pg_temp.age_insp(pg_temp.f('WH'), 9);
select t.ok(app.storage_days(pg_temp.f('WH')) = 20 and app.inspection_state(pg_temp.f('WH'))->>'state' = 'due', '20 days in storage; inspected 9 days ago: due');
select t.as_user(t.u('10'));
select t.ok(exists (select 1 from jsonb_array_elements(app.my_actions()->'inspections') x where x->>'id' = pg_temp.f('WH')::text and x->>'state' = 'due'),
            'the Warehouse person''s "Needs my action": an inspection due');
select t.as_service(); select pg_temp.age_insp(pg_temp.f('WH'), 3);
select t.ok(app.inspection_state(pg_temp.f('WH'))->>'state' = 'overdue' and not pg_temp.check(pg_temp.f('WH'), 'wh_inspections'), '12 days since: overdue; the system check says so');
select t.as_user(t.u('10'));
select t.ok(exists (select 1 from jsonb_array_elements(app.my_actions()->'inspections') x where x->>'id' = pg_temp.f('WH')::text and x->>'state' = 'overdue')
            and not exists (select 1 from jsonb_array_elements(app.my_actions()->'inspections') x where x->>'id' = pg_temp.f('WH2')::text),
            'overdue in "Needs my action"; a lot that arrived today is not');
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.my_actions()->'inspections') x where x->>'id' = pg_temp.f('WH')::text), 'and in the Client Manager''s');
select t.as_user(t.u('08'));
select t.ok(jsonb_array_length(app.my_actions()->'inspections') = 0, 'not in Milling''s');
select t.as_user(t.u('10'));
select app.record_inspection(pg_temp.f('WH'), pg_temp.today(), 'pest', 'weevils in two bags; fumigation asked');
select t.as_service();
select t.ok(app.inspection_state(pg_temp.f('WH'))->>'state' = 'ok' and app.inspection_state(pg_temp.f('WH'))->>'last_condition' = 'pest', 'inspected again: no longer overdue; pest found is kept');

-- 5 · Bags out ------------------------------------------------------------------------------------------------------
select t.as_user(t.u('06'));
select t.fails(format($$select app.record_bags_out(%L, 1, pg_temp.today())$$, pg_temp.f('WH')), 'record not found', 'QC does not record bags out');
select t.as_user(t.u('04'));
select t.fails(format($$select app.record_bags_out(%L, 1, pg_temp.today())$$, pg_temp.f('WH')), 'bags out are recorded by the Warehouse, the stage that takes the lot', 'the client''s viewer sees the lot but records no bags');
select t.fails(format($$select app.record_inspection(%L, pg_temp.today(), 'good')$$, pg_temp.f('WH')), 'inspected by the Warehouse or a manager', 'nor inspections');
select t.as_user(t.u('10'));
select t.fails(format($$select app.record_bags_out(%L, 0, pg_temp.today())$$, pg_temp.f('WH')), 'whole number, 1 or more', 'at least one bag');
select t.fails(format($$select app.record_bags_out(%L, 1, pg_temp.today() + 1)$$, pg_temp.f('WH')), 'between the lot''s arrival', 'not tomorrow');
select t.fails(format($$select app.record_bags_out(%L, 5, pg_temp.today())$$, pg_temp.f('WH')), 'only 4 bags of 4', 'not more than came in');
select t.fails(format($$select app.record_bags_out(%L, 1, pg_temp.today())$$, pg_temp.f('VB')), 'of a lot in the warehouse', 'of a stored lot only');
select app.record_bags_out(pg_temp.f('WH'), 3, pg_temp.today() - 1, 'to the mill');
select t.as_user(t.u('08'));
select t.fails(format($$select app.record_bags_out(%L, 2, pg_temp.today())$$, pg_temp.f('WH')), 'only 1 bags of 4', 'what is left');
select app.record_bags_out(pg_temp.f('WH'), 1, pg_temp.today());
select t.ok(((app.footprint_detail(pg_temp.f('WH'))->'warehouse')) @> '{"bags_in": 4, "bags_out": 4, "days": 20}' and jsonb_array_length((app.footprint_detail(pg_temp.f('WH'))->'warehouse')->'moves') = 2
            and ((app.footprint_detail(pg_temp.f('WH'))->'warehouse')->'moves'->0->>'by') = 'Grading Operator',
            'the stage that takes it (Milling) records bags out too: 4 of 4 out, who and when');
select t.ok((app.footprint_detail(pg_temp.f('WH'))->'warehouse'->>'days')::int = 20 and jsonb_array_length(app.footprint_detail(pg_temp.f('WH'))->'warehouse'->'inspections') = 3,
            'the record page has the days, the bags and the inspections');

-- 6 · Milling takes from the Warehouse ------------------------------------------------------------------------------------
select t.as_user(t.u('08'));
select app.verify_footprint(pg_temp.f('WH'));
insert into fx select 'M', pg_temp.ins(pg_temp.f('W'), 'milling', pg_temp.f('WH'), t.u('08'), '{"input_kg":190,"head_rice_kg":140,"broken_kg":15,"husk_kg":28,"bran_kg":7}');
select t.ok((pg_temp.fp(pg_temp.f('M'))).qty_in = 190, 'Milling takes the 190 kg the Warehouse received');
select t.as_service();
select t.ok(app.storage_days(pg_temp.f('WH')) = 20 and app.inspection_state(pg_temp.f('WH'))->>'state' = 'done', 'all of it taken: 20 days in storage; no more inspections due');
select pg_temp.age(pg_temp.f('WH2'), 30);
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('WH2')); select t.as_service();
select t.ok(app.storage_days(pg_temp.f('WH2')) = 30 and app.inspection_state(pg_temp.f('WH2'))->>'state' = 'overdue', 'still in storage: the days go on');

-- 7 · Stored but not recorded (a scope without a Warehouse) ---------------------------------------------------------------
insert into fx select 'P5', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P5'));
insert into fx select 'Q5', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P5'), t.u('06'),
  '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q5'));
select t.as_user(t.u('03'));
select t.ok(not exists (select 1 from jsonb_array_elements(app.my_actions()->'stored_unrecorded') x where x->>'id' = pg_temp.f('Q5')::text), 'checked in today: not yet');
select t.as_service();
set local session_replication_role = replica;
update public.footprints set verified_at = verified_at - interval '16 days' where id = pg_temp.f('Q5');
update public.footprints set verified_at = verified_at - interval '16 days' where id = pg_temp.f('WH2');
set local session_replication_role = origin;
select t.as_user(t.u('03'));
select t.ok(exists (select 1 from jsonb_array_elements(app.my_actions()->'stored_unrecorded') x where x->>'id' = pg_temp.f('Q5')::text and (x->>'days')::int = 16),
            'waiting 16 days for Milling in a scope without a Warehouse: "stored but not recorded" for the Client Manager');
select t.ok(not exists (select 1 from jsonb_array_elements(app.my_actions()->'stored_unrecorded') x where x->>'id' in (pg_temp.f('VB2')::text, pg_temp.f('WH2')::text)),
            'a scope with a Warehouse records its storage: not listed');
select t.as_user(t.u('08'));
select t.ok(jsonb_array_length(app.my_actions()->'stored_unrecorded') = 0, 'an operator does not get the list');
select t.as_user(t.u('08'));
insert into fx select 'M5', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q5'), t.u('08'), '{"input_kg":50,"head_rice_kg":38,"broken_kg":3,"husk_kg":7,"bran_kg":2}');
select t.as_user(t.u('03'));
select t.ok(not exists (select 1 from jsonb_array_elements(app.my_actions()->'stored_unrecorded') x where x->>'id' = pg_temp.f('Q5')::text), 'once Milling has taken some: no longer listed');

-- 8 · Days in storage on the public page --------------------------------------------------------------------------------
select t.as_user(t.u('03'));
with x as (insert into public.scopes (client_id, crop_id, season_code, geography, chain, status, stage_details_required, qc_report_required)
  values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', 'KH26', 'Itwa godown (test 49)',
          '{procurement,warehouse,qc,qr_activation}', 'draft', false, false) returning id)
insert into fx select 'PS', id from x;
select t.as_service();
select pg_temp.put(pg_temp.f('PS'), t.u('05'), '{procurement}');
select pg_temp.put(pg_temp.f('PS'), t.u('10'), '{warehouse}');
select pg_temp.put(pg_temp.f('PS'), t.u('06'), '{qc}');
select pg_temp.put(pg_temp.f('PS'), t.u('07'), '{qr_activation}');
select t.as_user(t.u('03'));
update public.scopes set status = 'active' where id = pg_temp.f('PS');
select t.as_user(t.u('05'));
insert into fx select 'PL', t.procure_as(pg_temp.f('PS'), t.farmer('05'), t.u('05'));
select t.as_user(t.u('10'));
select app.verify_footprint(pg_temp.f('PL'));
insert into fx select 'PW', pg_temp.ins(pg_temp.f('PS'), 'warehouse', pg_temp.f('PL'), t.u('10'), pg_temp.wh(98, 98, '{"bags_in": 2}'));
select t.as_service(); select pg_temp.age(pg_temp.f('PW'), 5);
select t.as_user(t.u('06'));
select app.verify_footprint(pg_temp.f('PW'));
insert into fx select 'PQ', pg_temp.ins(pg_temp.f('PS'), 'qc', pg_temp.f('PW'), t.u('06'),
  '{"qty_kg":98,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_user(t.u('07'));
select app.verify_footprint(pg_temp.f('PQ'));
insert into fx select 'PR', pg_temp.ins(pg_temp.f('PS'), 'qr_activation', pg_temp.f('PQ'), t.u('07'), '{}');
select t.as_service();
create temp table qr as select (app.seal_lot(pg_temp.f('PR'), t.u('07'))).qr_code;
grant select on qr to anon;
select t.as_anon();
select t.ok((select x->>'days_in_storage' from jsonb_array_elements(app.public_lot_journey((select qr_code from qr))->'journey') x where x->>'stage' = 'warehouse') = '5',
            'the public page: 5 days in storage');
select t.ok(not exists (select 1 from jsonb_array_elements(app.public_lot_journey((select qr_code from qr))->'journey') x where x ? 'location' or x ? 'discrepancy_reason'),
            'not where it is kept, nor the reason of a difference');
select t.as_service();
select t.ok(position('computed' in pg_get_functiondef('app.public_lot_journey(text)'::regprocedure)) = 0, 'the public journey still reads no worked-out values');
rollback;
