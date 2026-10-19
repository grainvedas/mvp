-- Migration 59 (Phase 1, release 1 of Veda's combined brief, 19 Oct 2026: Part A fixes, Part B the client login reads only):
--   A1  a pack before release: crop, batch code, date packed, nothing else; "not found" only for no pack at all
--   A2  a step recorded and checked by one person says so (public data, the journey)
--   A3  units for every reading (public page, journey, record)
--   A4  the check-in panel reads the bill of lading as it is now
--   A5  the lab's name and accreditation number; the "same report twice" rule with a lab from the list
--   A6  one file as two kinds of document: refused without a reason, kept with it
--   A8  old data marked; a typed batch code in use refused
--   B1  a client login writes nothing (tables, functions, files)
--   B2  what the client waits on; B3 its farmers, the phone masked; B4 a Client Manager sees no email, a phone only on his scopes
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → …; scope 01 (Siddharthnagar):
-- Procurement (05) → QC (06) → QR (07). 03 the Client Manager of client 201; 04 its client login; 16 the HR Admin.
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
-- refused by the server for who is asking: a privilege refusal or the rule's own words, never a typing mistake
create or replace function pg_temp.refused(p_sql text, p_name text) returns void language plpgsql as $$
declare msg text; st text;
begin
  begin execute p_sql;
  exception when others then
    msg := sqlerrm; st := sqlstate;
    if msg ilike '%does not exist%' or msg ilike '%syntax%' or st like '22%' then
      raise exception 'ASSERTION FAILED: % — a mistake in the test, not a refusal: %', p_name, msg; end if;
    raise notice 'ok   % (refused: %)', p_name, left(msg, 90); return;
  end;
  raise exception 'ASSERTION FAILED: % — accepted', p_name;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- a lab of the state, with its accreditation number
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
update public.scopes set qc_report_required = true where id = t.scope('05');

-- the chain of scope 05 up to packing
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
insert into fx select 'P2', t.procure(t.scope('05'), t.farmer('04'), 104, 2, 2, 11.8, 11.7, 11.9);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P')); select app.verify_footprint(pg_temp.f('P2'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  jsonb_build_object('qty_kg', 200, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                     'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/118', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-1'));

-- A5 · the lab ------------------------------------------------------------------------------------------------------------
select t.as_service();
select t.ok((select app.qc_lab(pg_temp.f('Q')) = jsonb_build_object('name', 'Gorakhpur Grain Lab', 'accreditation_no', 'TC-5521', 'kind', 'external', 'report_no', 'GGL/2026/118', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text)),
            'A5: the lab of a lab record: its name and accreditation number with the report');
select t.as_user(t.u('06'));
select t.fails(format($q$select pg_temp.ins(%L, 'qc', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('P2'), t.u('06'),
  jsonb_build_object('qty_kg', 100, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                     'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/118', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-2')),
  'the same report twice needs the same sample ID', 'A5: the same report of the same lab, picked from the list, on another lot with another sample: refused');
insert into fx select 'Q2', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P2'), t.u('06'),
  jsonb_build_object('qty_kg', 100, 'sample_qty_kg', 1, 'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', 2, 'foreign_matter_pct', 0.2),
                     'lab_id', pg_temp.f('LAB'), 'report_no', 'GGL/2026/118', 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-1'));
select t.ok(pg_temp.f('Q2') is not null, 'A5: the same report with the same sample ID stays allowed');
select t.as_user(t.u('03'));
select t.ok((select d->'lab'->>'accreditation_no' = 'TC-5521' and d->'lab'->>'name' = 'Gorakhpur Grain Lab' from (select app.footprint_detail(pg_temp.f('Q')) d) x),
            'A5: the record page has the lab and its accreditation number');
select t.ok((select s->'lab'->>'accreditation_no' = 'TC-5521' from jsonb_array_elements(app.lot_trace(pg_temp.f('Q'))->'steps') s where s->>'stage' = 'qc'),
            'A5: the journey has them too');

-- A3 · units ----------------------------------------------------------------------------------------------------------
select t.as_service();
select t.ok((select u->>'moisture_pct' = '%' and u->>'broken_pct' = '%' from (select app.param_units(t.scope('05')) u) x),
            'A3: each reading''s unit from the crop''s quality schema');
select t.as_user(t.u('03'));
select t.ok((select d->'units'->>'moisture_pct' = '%' from (select app.footprint_detail(pg_temp.f('Q')) d) x)
            and (select (app.lot_trace(pg_temp.f('Q'))->'units'->>'moisture_pct') = '%'),
            'A3: the record and the journey carry the units');

-- A6 · one file, two kinds of document ---------------------------------------------------------------------------------------
select t.as_user(t.u('06'));
select app.register_labelled_attachment(pg_temp.f('Q'), 'document', format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('Q'), 'aaaa'),
  repeat('ab', 32), 'lab_report');
select t.ok((select count(*) = 1 from public.attachments where sha256 = repeat('ab', 32)), 'A6: a lab report attached to the lab record');
select app.register_labelled_attachment(pg_temp.f('Q2'), 'document', format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('Q2'), 'eeee'),
  repeat('ab', 32), 'lab_report');
select t.ok((select count(*) = 1 from public.attachments where footprint_id = pg_temp.f('Q2') and sha256 = repeat('ab', 32)),
            'A6: the same lab report on another lot (the same kind) needs no reason');
select t.as_user(t.u('05'));
select t.fails(format($q$select app.register_labelled_attachment(%L, 'document', %L, %L, 'pod')$q$, pg_temp.f('P'),
  format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('P'), 'bbbb'), repeat('ab', 32)),
  'this exact file is already attached as lab report on', 'A6: the same file as a proof of delivery on another record: refused, naming the kind and the record');
select t.fails(format($q$select app.register_attachment(%L, 'document', %L, %L, 'short')$q$, pg_temp.f('P'),
  format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('P'), 'cccc'), repeat('ab', 32)),
  'this exact file is already attached', 'A6: a reason of fewer than 10 characters is not a reason');
select app.register_labelled_attachment(pg_temp.f('P'), 'document', format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('P'), 'dddd'),
  repeat('ab', 32), 'pod', 'the lab sent one PDF covering report and receipt');
select t.as_service();
select t.ok((select dup_reason = 'the lab sent one PDF covering report and receipt' and label = 'pod' from public.attachments
              where footprint_id = pg_temp.f('P') and sha256 = repeat('ab', 32))
            and exists (select 1 from public.audit_log where action = 'same_file_attached' and detail->>'as' = 'lab_report'),
            'A6: with a reason it is attached; the reason is kept on it and in the Audit log');
select t.as_service();
insert into public.attachments (footprint_id, kind, storage_path, sha256, label, uploaded_by)
  values (pg_temp.f('Q'), 'photo', format('%s/%s/%s/%s.jpg', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('Q'), 'ffff'), repeat('cd', 32), 'loading_photo', t.u('06'));
select t.as_user(t.u('05'));
select t.ok(app.same_file_elsewhere(pg_temp.f('P'), repeat('cd', 32), 'photo') is null
            and app.same_file_elsewhere(pg_temp.f('P'), repeat('cd', 32), 'lab_report')->>'kind' = 'loading_photo',
            'A6: a photo is a photo (a loading photo and a photo of the bags need no reason); as a document it does');

-- A8 · typed batch codes and old data -----------------------------------------------------------------------------------------
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":180,"broken_kg":5,"husk_kg":10,"bran_kg":4}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":150,"packets":[{"sku_id":"%s","units":150,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_service();
create temp table bc as select payload->>'batch_code' as code from public.footprints where id = pg_temp.f('K');
grant select on bc to authenticated, anon;
select t.fails(format($q$select pg_temp.ins(%L, 'packing', %L, %L, %L)$q$, t.scope('05'), pg_temp.f('M'), t.u('09'),
  format('{"input_kg":10,"batch_code":"%s","packets":[{"sku_id":"%s","units":10,"size_kg":1}]}', (select code from bc), pg_temp.f('SKU1'))),
  'is in use already', 'A8: a typed batch code that a batch has already is refused, whoever inserts it');
select t.ok(not app.has_old_batch_data(t.scope('05')), 'A8: a scope whose batch codes are all the system''s is not old data');
insert into public.pack_batches (batch_code, footprint_id, scope_id, typed) select 'TCUP-2026-KNM-001', pg_temp.f('M'), t.scope('05'), true;
select t.ok(app.has_old_batch_data(t.scope('05')), 'A8: a typed batch code of before marks the scope as old data');
update public.scopes set data_note = 'practice_old_data' where id = t.scope('05');
select t.as_user(t.u('03'));
select t.ok((select app.footprint_detail(pg_temp.f('K'))->>'data_note' = 'practice_old_data') and (select app.lot_trace(pg_temp.f('K'))->>'data_note' = 'practice_old_data'),
            'A8: the record and the journey say "Practice (old data)"');
select t.as_service(); update public.scopes set data_note = null where id = t.scope('05');

-- A1 · a pack before release -------------------------------------------------------------------------------------------------
create temp table cn as select c.name from public.crops c join public.scopes s on s.crop_id = c.id where s.id = t.scope('05');
grant select on cn to anon, authenticated;
select t.as_anon();
create temp table pp as select app.public_pack((select code from bc) || '-0001') as j;
select t.ok((select j = jsonb_build_object('released', false, 'crop', jsonb_build_object('name', (select name from cn)),
                       'pack', jsonb_build_object('serial', (select code from bc) || '-0001', 'batch_code', (select code from bc), 'packed_on', (j->'pack'->>'packed_on'), 'void', false, 'copy_warning', false,
                                                  'best_before', (j->'pack'->>'best_before')))                     -- migration 61 (E2.4)
                    and j->'pack'->>'packed_on' is not null from pp),
            'A1: a pack before release: the crop, the batch code, the date packed and its best-before date, nothing else');
select t.as_user(t.u('09')); select app.void_pack((select code from bc) || '-0003', 'pouch torn at the store (test)');
select t.as_anon();
select t.ok((select j = jsonb_build_object('released', false, 'crop', jsonb_build_object('name', (select name from cn)),
                       'pack', jsonb_build_object('serial', (select code from bc) || '-0003', 'batch_code', (select code from bc), 'packed_on', (j->'pack'->>'packed_on'), 'void', true, 'copy_warning', false,
                                                  'best_before', null))                                              -- migration 61: none on a voided pack
                    from (select app.public_pack((select code from bc) || '-0003') as j) x),
            'A1: a voided pack says it is voided, and nothing more');
select t.as_service();
select app.record_scan_at((select code from bc) || '-0004', 'New Delhi', 'DL', 'IN', 28.6139, 77.2090);
select app.record_scan_at((select code from bc) || '-0004', 'Rotterdam', 'ZH', 'NL', 51.9244, 4.4777);
select t.as_anon();
select t.ok((select (j->'pack'->>'copy_warning')::boolean and not (j->'pack' ? 'seller') and not (j ? 'season') from (select app.public_pack((select code from bc) || '-0004') as j) x),
            'A1: a code scanned far apart is warned of before release too, without the seller');
select t.ok(app.public_pack('NO-SUCH-CODE') is null and app.public_lot_journey((select code from bc) || '-0001') is null,
            'A1: no pack, no lot: nothing (the page then says "Code not found"); a pack serial is not a lot code');

-- A2, A3 public · a sealed lot of scope 01; its procurement checked in by the person who recorded it -----------------------------
select t.as_service();
select set_config('app.assigning', 'on', true);
update public.assignments set stages = stages || '{qc}'::public.stage_type[]
 where employee_id = t.u('05') and scope_id = t.scope('01') and active and not ('qc' = any (stages));
insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id)
select t.u('05'), t.scope('01'), 'qc', id from public.assignments where employee_id = t.u('05') and scope_id = t.scope('01') and active and lens = 'scope';
select set_config('app.assigning', '', true);
insert into fx select 'P1', t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
select t.as_user(t.u('05')); select app.verify_footprint(pg_temp.f('P1'));
select t.as_user(t.u('06'));
insert into fx select 'Q1', pg_temp.ins(t.scope('01'), 'qc', pg_temp.f('P1'), t.u('06'), '{"qty_kg":98,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_service(); select t.attach(pg_temp.f('Q1'), 'lab_report');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('Q1'));
insert into fx select 'R1', pg_temp.ins(t.scope('01'), 'qr_activation', pg_temp.f('Q1'), t.u('07'), '{}');
create temp table seal as select (app.seal_lot(pg_temp.f('R1'))).qr_code as code;
grant select on seal to anon, authenticated;
select t.as_anon();
create temp table pj as select app.public_lot_journey((select code from seal)) as j;
select t.ok((select bool_or((e->>'same_person')::boolean) filter (where e->>'stage' = 'procurement')
                    and not bool_or((e->>'same_person')::boolean) filter (where e->>'stage' = 'qc')
               from pj, jsonb_array_elements(j->'journey') e),
            'A2: the step recorded and checked by one person says so; the step checked by another does not');
select t.ok((select j->'units'->>'moisture_pct' = '%' from pj), 'A3: the public page has each reading''s unit');
select t.ok((select not (j ? 'same_person') from pj), 'A2: no lot-wide same-person line: it is per step');

-- A4 · a bill of lading added after the shipment was saved ------------------------------------------------------------------
select t.as_service();
insert into public.bills_of_lading (footprint_id, scope_id, bl_no, added_by) values (pg_temp.f('M'), t.scope('05'), 'MAEU0000123', t.u('03'));
select t.ok((select app.live_computed(f) @> '{"bl_pending": false, "bl_no": "MAEU0000123"}'
               from (select jsonb_populate_record(null::public.footprints, to_jsonb(pg_temp.fp(pg_temp.f('M'))) || '{"stage_type":"shipment"}') as f) y),
            'A4: a shipment whose bill of lading was added later is no longer "still to come"');
select t.ok((select app.live_computed(x.f) is not distinct from (x.f).computed from (select pg_temp.fp(pg_temp.f('Q')) as f) x),
            'A4: any other record shows its values as saved');

-- B1 · the client login writes nothing ----------------------------------------------------------------------------------------
select t.as_user(t.u('04'));
select t.ok(app.is_client_login(), 'B1: the client''s login is a client login');
select pg_temp.refused(format($q$insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload) values (%L, '00000000-0000-4000-8000-000000000201', 'procurement', %L, %L, '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}')$q$,
  t.scope('05'), t.farmer('05'), t.u('04')), 'B1: a record');
select pg_temp.refused(format($q$insert into public.flags (footprint_id, raised_by, text) values (%L, %L, 'this looks wrong to us')$q$, pg_temp.f('Q'), t.u('04')), 'B1: a flag (it was allowed before)');
select pg_temp.refused(format($q$select app.register_attachment(%L, 'document', %L, %L)$q$, pg_temp.f('Q'),
  format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('Q'), 'ffff'), repeat('cd', 32)), 'B1: a file (it was allowed before)');
select pg_temp.refused(format($q$insert into storage.objects (bucket_id, name) values ('evidence', %L)$q$,
  format('%s/%s/%s/%s.pdf', '00000000-0000-4000-8000-000000000201', t.scope('05'), pg_temp.f('Q'), 'gggg')), 'B1: storing a file (it was allowed before)');
select pg_temp.refused(format('select app.verify_footprint(%L)', pg_temp.f('K')), 'B1: a check-in');
select pg_temp.refused(format($q$select app.return_footprint(%L, 'please weigh it again')$q$, pg_temp.f('K')), 'B1: a return');
select pg_temp.refused(format($q$select app.close_lot(%L, 'only floor sweepings left here')$q$, pg_temp.f('M')), 'B1: closing a lot');
select pg_temp.refused(format($q$select app.void_pack(%L, 'torn pouch at the store')$q$, (select code from bc) || '-0002'), 'B1: voiding a pack');
select pg_temp.refused(format('select app.print_labels(%L, null)', pg_temp.f('K')), 'B1: printing labels');
select pg_temp.refused(format($q$insert into public.bills_of_lading (footprint_id, scope_id, bl_no, added_by) values (%L, %L, 'MAEU0000999', %L)$q$, pg_temp.f('K'), t.scope('05'), t.u('04')), 'B1: a bill of lading, straight into its table');
update public.footprints set payload = payload || '{"note":"x"}' where id = pg_temp.f('K');
update public.farmers set village = 'Itwa' where id = t.farmer('05');
select pg_temp.refused($q$insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'X Traders', 'IN', 'Basti', '09AAACX1234E1Z5')$q$, 'B1: a buyer');
update public.scopes set season_end = '2027-03-31' where id = t.scope('05');
select t.as_service();
select t.ok(not ((pg_temp.fp(pg_temp.f('K'))).payload ? 'note') and (select village <> 'Itwa' from public.farmers where id = t.farmer('05'))
            and (select season_end is distinct from '2027-03-31'::date from public.scopes where id = t.scope('05')),
            'B1: an update of a record, a farmer or a scope changes nothing');
select t.ok((select count(*) = 0 from public.flags where raised_by = t.u('04')) and (select count(*) = 0 from public.attachments where uploaded_by = t.u('04')),
            'B1: nothing of the client login was stored');
-- what a client login may still do: read
select t.as_user(t.u('04'));
select t.ok((select app.footprint_detail(pg_temp.f('Q'))->'footprint'->>'id' = pg_temp.f('Q')::text), 'B1: it still reads a record');

-- B2 · what the client waits on ----------------------------------------------------------------------------------------------
select t.ok((select jsonb_array_length(w->'pending') >= 1 and w ? 'lab_hold' and w ? 'open_flags'
                    and exists (select 1 from jsonb_array_elements(w->'pending') p where p->>'code' = (pg_temp.fp(pg_temp.f('K'))).footprint_code)
               from (select app.client_waiting() w) x),
            'B2: "Waiting on GrainVeda": the records not yet checked (the packing record), samples at the lab, open flags');

-- B3 · its farmers, the phone masked -----------------------------------------------------------------------------------------
select t.ok((select count(*) = 0 from public.farmers), 'B3: the client login no longer reads the farmers'' table (phones, fathers'' names)');
select t.ok((select count(*) = 5 and bool_and(e->>'phone' ~ '^••••••[0-9]{4}$') and not bool_or(e ? 'guardian_name')
                    and bool_and(e ? 'land_area_acres' and e ? 'gi_land_acres' and e ? 'farmer_code')
               from jsonb_array_elements(app.client_farmers()) e),
            'B3: its farmers through the function: name, ID, village, land and GI land; the phone masked; no father''s name');
select t.as_user(t.u('03'));
select t.ok((select count(*) >= 5 and bool_and(phone ~ '^\+91') from public.farmers where client_id = '00000000-0000-4000-8000-000000000201'),
            'B3: the Client Manager still reads his farmers in full');

-- B4 · a Client Manager: no email; a phone only of people on a stage of his scopes --------------------------------------------
select t.as_service();
select t.as_user(t.u('03'));
create temp table pg as select r from jsonb_array_elements(app.people_page('{"limit":200}')->'rows') r;
grant select on pg to authenticated;
select t.ok((select bool_and(r->>'email' is null) from pg where not (r->>'external')::boolean), 'B4: People & access shows the Client Manager no one''s email');
select t.ok((select r->>'phone' is not null from pg where r->>'id' = t.u('05')::text), 'B4: the phone of a person on a stage of his scope');
select t.as_service();
create temp table onmine as select distinct a.employee_id from public.assignments a
 where a.active and a.lens = 'scope' and cardinality(a.stages) > 0 and app.manages_scope(t.u('03'), a.scope_id);
create temp table withphone as select id from public.app_users where coalesce(phone, '') <> '' and not external;
grant select on onmine, withphone to authenticated;
select t.as_user(t.u('03'));
select t.ok((select count(*) filter (where r->>'phone' is not null) > 0 and count(*) filter (where r->>'phone' is null) > 0
                    and bool_and((r->>'phone' is not null) = ((r->>'id')::uuid in (select employee_id from onmine)))
               from pg where not (r->>'external')::boolean and (r->>'id')::uuid in (select id from withphone)),
            'B4: of the people he sees, a phone exactly for those on a stage of his scopes, none for the rest');
select t.ok((select (app.employee_profile(t.u('05'))->'identity'->>'email') is null), 'B4: no email on a person''s page either');
select t.fails('select email from public.app_users limit 1', 'permission denied', 'B4: email and phone are not readable from the table through the API');
select t.ok((select count(*) > 0 from public.app_users), 'B4: names stay readable (the screens show who did what)');
-- speed (found while testing): the page asks may_offer_assign_seen for its rows, which are within cm_seen_ids already;
-- what it offers is what app.may_offer_assign says, person by person
select t.as_service();
create function pg_temp.offer(p uuid) returns boolean language sql security definer set search_path = public as $$ select app.may_offer_assign(p) $$;
grant execute on function pg_temp.offer(uuid) to authenticated;
select t.as_user(t.u('03'));
select t.ok((select count(*) > 0 and count(*) filter (where (r->>'assignable')::boolean) > 0
                    and bool_and((r->>'assignable')::boolean = pg_temp.offer((r->>'id')::uuid)) from pg),
            'B4: People & access offers Assign exactly where app.may_offer_assign says so (asked once a page, not once a row)');
select t.as_user(t.u('16'));
select t.ok((select count(*) > 0 and bool_and(r->>'phone' is not null) from jsonb_array_elements(app.people_page('{"limit":200}')->'rows') r
              where not (r->>'external')::boolean and (r->>'id')::uuid in (select id from withphone)),
            'B4: HR still sees every phone (and email)');

rollback;
