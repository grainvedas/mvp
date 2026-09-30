-- Phase 1 backend (migrations 15–16): B1 preview = save, B2 chain problems, B3 stage_form, B4 farmers + import,
-- B6 evidence, B7 frozen crop limits, my_context, footprint_detail. All as signed-in users unless stated.
begin;
select t.as_service();

-- ===========================================================================================================
-- B1. preview_reconcile shows exactly what the save stores, and writes nothing
-- ===========================================================================================================
do $$
declare pv jsonb; fp uuid; r public.footprints; n_ledger bigint; n_fp bigint; n_cnt bigint;
begin
  select count(*) into n_ledger from public.ledger; select count(*) into n_fp from public.footprints;
  select coalesce(sum(last_seq), 0) into n_cnt from public.footprint_counters;
  perform t.as_user(t.u('05'));
  pv := app.preview_reconcile(t.scope('01'), 'procurement', null,
          '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}', t.farmer('02'));
  perform t.ok((pv->>'ok')::boolean and (pv->>'qty_out')::numeric = 147.5, 'B1 preview: procurement net 147.5 kg');
  perform t.as_service();
  perform t.ok((select count(*) from public.ledger) = n_ledger and (select count(*) from public.footprints) = n_fp
               and (select coalesce(sum(last_seq), 0) from public.footprint_counters) = n_cnt,
               'B1 preview writes nothing (no ledger block, record or footprint code used)');
  perform t.as_user(t.u('05'));
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('02'), t.u('05'),
          '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[11.9,11.8,12.0]}') returning * into r;
  perform t.ok(r.qty_in = (pv->>'qty_in')::numeric and r.qty_out = (pv->>'qty_out')::numeric
               and r.computed = pv->'computed' and to_jsonb(r.warnings) = pv->'warnings',
               'B1 review = save: saved qty_in, qty_out, computed and warnings equal the preview');
  pv := app.preview_reconcile(t.scope('01'), 'procurement', null, '{"gross_kg":5,"bags":3,"tare_kg_per_bag":2,"moisture_pct":[12,12,12]}', t.farmer('02'));
  perform t.ok(not (pv->>'ok')::boolean and pv->>'error' like '%net weight must be positive%', 'B1 preview returns the exact refusal');
  perform t.as_user(t.u('06'));
  pv := app.preview_reconcile(t.scope('01'), 'procurement', null, '{"gross_kg":150,"bags":1,"tare_kg_per_bag":2.5,"moisture_pct":[12,12,12]}', t.farmer('02'));
  perform t.ok(not (pv->>'ok')::boolean and pv->>'error' like '%may not create%', 'B1 preview enforces isMyStage for the caller');
  perform t.as_user(t.u('12'));
  pv := app.preview_reconcile(t.scope('01'), 'procurement', null, '{}', t.farmer('02'));
  perform t.ok(pv->>'error' = 'no access to this scope', 'B1 preview: another client''s operator gets no access');
  perform t.as_service();
end $$;

-- Preview = save for a processing stage (milling on scope 03)
do $$
declare p uuid; q uuid; pv jsonb; r public.footprints;
begin
  p := t.procure(t.scope('03'), t.farmer('05'), 199, 2, 2, 11.8, 11.7, 11.9);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.verify(q, t.u('08'));
  perform t.as_user(t.u('08'));
  pv := app.preview_reconcile(t.scope('03'), 'milling', q, '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}');
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), '00000000-0000-4000-8000-000000000201', 'milling', q, t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}')
  returning * into r;
  perform t.ok(r.qty_out = (pv->>'qty_out')::numeric and to_jsonb(r.warnings) = pv->'warnings' and r.computed = pv->'computed',
               'B1 review = save for milling, including the yield warning');
  perform t.ok((pv->>'available_on_prev')::numeric = 194, 'B1 preview reports what the predecessor still holds (194 kg before this run)');
  perform t.as_service();
end $$;

-- ===========================================================================================================
-- B2. check_chain returns every problem; activation still refuses with the first
-- ===========================================================================================================
select t.as_user(t.u('03'));
select t.ok(app.check_chain('{procurement,milling,qr_activation}', '00000000-0000-4000-8000-000000000101') = array['qc is mandatory in every chain'],
            'B2 missing QC reported');
select t.ok(app.check_chain('{milling,milling,qr_activation}', '00000000-0000-4000-8000-000000000101')
            @> array['chain must start with procurement or lot_inward', 'qc is mandatory in every chain', 'a stage type may appear only once per chain'],
            'B2 several problems reported at once');
select t.ok(cardinality(app.check_chain('{procurement,qc,milling,commercial,qr_activation}', '00000000-0000-4000-8000-000000000101')) = 0,
            'B2 a valid chain has no problems');
select t.ok(app.check_chain('{procurement,popping,qc,qr_activation}', '00000000-0000-4000-8000-000000000101')
            = array['stage popping is not allowed for this crop'], 'B2 crop-specific stage rule reported');
select t.as_service();

-- ===========================================================================================================
-- B7. Crop limits frozen per scope
-- ===========================================================================================================
select t.ok((select quality_params from public.scopes where id = t.scope('01')) =
            (select quality_params from public.crops where id = '00000000-0000-4000-8000-000000000101'),
            'B7 active scopes carry a copy of the crop limits');
update public.crops set quality_params = jsonb_set(quality_params, '{0,export_limit}', '11')
 where id = '00000000-0000-4000-8000-000000000101';
do $$
declare p uuid; q uuid;
begin
  p := t.procure(t.scope('01'), t.farmer('03'), 180, 1, 2, 11.9, 11.9, 11.9);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":178,"sample_qty_kg":1,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.ok((select export_verdict from public.qc_verdicts where footprint_id = q) = 'pass',
               'B7 a crop edit mid-season does not change verdicts in an active scope (11.9 <= frozen 12)');
end $$;
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status)
values ('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101',
        'KH26', 'New scope after edit', '{procurement,qc,qr_activation}', 'active');
select t.ok((select quality_params->0->>'export_limit' from public.scopes where id = '00000000-0000-4000-8000-000000000499') = '11',
            'B7 a scope activated after the edit takes the new limit');
select t.fails($q$ update public.scopes set quality_params = '[]' where id = t.scope('01') $q$, 'frozen', 'B7 limits of an active scope cannot be edited');

-- ===========================================================================================================
-- B3. stage_form, my_context, footprint_detail
-- ===========================================================================================================
select t.as_user(t.u('06'));
select t.ok((app.stage_form(t.scope('01'), 'qc'))->'prev_stage'->>'stage_type' = 'procurement'
        and (app.stage_form(t.scope('01'), 'qc'))->'next_stage'->>'stage_type' = 'qr_activation'
        and ((app.stage_form(t.scope('01'), 'qc'))->>'can_create')::boolean
        and ((app.stage_form(t.scope('01'), 'qc'))->>'can_verify_incoming')::boolean
        and jsonb_array_length((app.stage_form(t.scope('01'), 'qc'))->'quality_params') = 3,
        'B3 stage_form: QC on scope 01 knows prev, next, rights and 3 crop limits');
select t.ok(jsonb_array_length((app.stage_form(t.scope('01'), 'qc'))->'prev_stage'->'handoff_checks') = 4,
            'B3 stage_form carries the previous stage''s handoff tick-list');
select t.ok(not ((app.stage_form(t.scope('01'), 'procurement'))->>'can_create')::boolean,
            'B3 stage_form: QC technician may not create at procurement');
select t.as_user(t.u('12'));
select t.fails($q$ select app.stage_form(t.scope('01'), 'qc') $q$, 'no access', 'B3 stage_form: other client refused');
select t.ok(jsonb_array_length((app.my_context())->'slots') = 0 and (app.my_context())->'user'->>'role' = 'operator',
            'my_context: an operator with no slots gets an empty slot list');
select t.as_user(t.u('05'));
select t.ok(jsonb_array_length((app.my_context())->'slots') = 5, 'my_context: procurement operator has 5 slots');
select t.as_user(t.u('03'));
select t.ok(jsonb_array_length((app.my_context())->'scopes') = 7, 'my_context: client manager sees the client''s 7 scopes (6 seeded + 1 above)');
select t.as_user(t.u('06'));
select t.ok(jsonb_array_length((app.footprint_detail((select id from public.footprints where stage_type = 'procurement'
         and scope_id = t.scope('01') and status = 'verified' limit 1)))->'ledger') >= 2,
        'footprint_detail: QC technician sees the procurement record with its ledger blocks');
select t.as_user(t.u('12'));
select t.fails($q$ select app.footprint_detail((select id from public.footprints limit 1)) $q$, 'record not found',
               'footprint_detail: other client gets "not found"');
select t.as_service();

-- ===========================================================================================================
-- B4. Farmers: workflow, phone uniqueness, Excel import
-- ===========================================================================================================
select t.fails($q$ insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
                   values ('00000000-0000-4000-8000-000000000201', 'draft', 'Copy', 'X', 'Y', 'Z', '91 9000 000 001', 1) $q$,
               'farmers_client_phone_key', 'farmers: one phone per client, compared by digits');

select t.as_user(t.u('05'));
insert into public.farmers (id, client_id, status, name, guardian_name, village, district, phone, land_area_acres)
values ('00000000-0000-4000-8000-000000000581', '00000000-0000-4000-8000-000000000201', 'draft', 'Rampati', 'Shri Lallan',
        'Bansi', 'Siddharthnagar', '+919000000081', 2);
select t.ok((app.submit_farmer('00000000-0000-4000-8000-000000000581')).status = 'under_review', 'farmers: operator submits a draft');
select t.fails($q$ select app.verify_farmer('00000000-0000-4000-8000-000000000581') $q$, 'only a State Manager', 'farmers: operator cannot verify');
select t.fails($q$ select app.send_back_farmer('00000000-0000-4000-8000-000000000581', 'x') $q$, 'only a State Manager', 'farmers: operator cannot send back');
select t.as_user(t.u('02'));
select t.fails($q$ select app.send_back_farmer('00000000-0000-4000-8000-000000000581', '  ') $q$, 'reason is required', 'farmers: send back needs a reason');
select t.ok((app.send_back_farmer('00000000-0000-4000-8000-000000000581', 'Photo of land record missing')).extra->>'sent_back_reason'
            = 'Photo of land record missing', 'farmers: State Manager sends back with a reason');
select t.as_user(t.u('05'));
select t.ok((app.submit_farmer('00000000-0000-4000-8000-000000000581')).extra ? 'sent_back_reason' = false, 'farmers: resubmission clears the reason');
select t.as_user(t.u('02'));
select t.ok((app.verify_farmer('00000000-0000-4000-8000-000000000581')).farmer_code = 'PRSDM-F-0006', 'farmers: State Manager verification issues PRSDM-F-0006');

select t.as_user(t.u('05'));
do $$
declare res jsonb;
  bad jsonb := '[{"row":2,"name":"A","guardian_name":"G","village":"V","district":"D","phone":"9876500001","land_area_acres":"1.5"},
                 {"row":3,"name":"","guardian_name":"G","village":"V","district":"D","phone":"9876500002","land_area_acres":"1"},
                 {"row":4,"name":"C","guardian_name":"G","village":"V","district":"D","phone":"12345","land_area_acres":"1"},
                 {"row":5,"name":"D","guardian_name":"G","village":"V","district":"D","phone":"+91 98765 00001","land_area_acres":"1"},
                 {"row":6,"name":"E","guardian_name":"G","village":"V","district":"D","phone":"09876500005","land_area_acres":"two"}]';
  good jsonb := '[{"row":2,"name":"Phoolmati","guardian_name":"Shri Ram","village":"Itwa","district":"Siddharthnagar","phone":"9876500011","land_area_acres":"1.25","aadhaar_last4":"1234"},
                  {"row":3,"name":"Bechan","guardian_name":"Shri Shyam","village":"Bansi","district":"Siddharthnagar","phone":"+91 98765 00012","land_area_acres":"3"}]';
begin
  res := app.import_farmers('00000000-0000-4000-8000-000000000201', bad, true);
  perform t.ok(not (res->>'ok')::boolean and jsonb_array_length(res->'errors') = 4
               and (select array_agg(distinct (e->>'row')::int order by (e->>'row')::int) from jsonb_array_elements(res->'errors') e) = array[3,4,5,6],
               'B4 import dry run names the bad rows 3, 4, 5 (duplicate phone in file), 6: ' || (res->'errors')::text);
  res := app.import_farmers('00000000-0000-4000-8000-000000000201', bad, false);
  perform t.ok((res->>'inserted')::int = 0 and not exists (select 1 from public.farmers where phone = '+919876500001'),
               'B4 a real run with errors imports nothing');
  res := app.import_farmers('00000000-0000-4000-8000-000000000201', good, true);
  perform t.ok((res->>'ok')::boolean and (res->>'inserted')::int = 0, 'B4 clean dry run: ok, nothing written');
  res := app.import_farmers('00000000-0000-4000-8000-000000000201', good, false);
  perform t.ok((res->>'inserted')::int = 2, 'B4 clean file imports 2 farmers');
  perform t.ok((select count(*) from public.farmers where phone in ('+919876500011', '+919876500012') and status = 'under_review'
                and created_by = t.u('05') and extra->>'imported' = 'true') = 2,
               'B4 imported farmers are under review, created by the importer, phones normalised to +91');
  perform t.ok((select extra->>'aadhaar_last4' from public.farmers where phone = '+919876500011') = '1234',
               'B4 extra columns kept in extra');
  res := app.import_farmers('00000000-0000-4000-8000-000000000201',
           '[{"row":2,"name":"X","guardian_name":"G","village":"V","district":"D","phone":"9000000001","land_area_acres":"1"}]', true);
  perform t.ok(res->'errors'->0->>'message' = 'a farmer with this phone is already registered', 'B4 duplicate of an existing farmer reported');
end $$;
select t.as_user(t.u('06'));
select t.fails($q$ select app.import_farmers('00000000-0000-4000-8000-000000000201', '[{"name":"x"}]', true) $q$,
               'no farmer access', 'B4 QC technician cannot import farmers');
select t.as_user(t.u('04'));
select t.fails($q$ select app.import_farmers('00000000-0000-4000-8000-000000000201', '[{"name":"x"}]', true) $q$,
               'no farmer access', 'B4 client view cannot import farmers');
select t.as_service();

-- ===========================================================================================================
-- B6. Evidence: attachments registered only on the right path; storage policies follow record visibility
-- ===========================================================================================================
do $$
declare fp public.footprints; path text; other text;
begin
  select * into fp from public.footprints where stage_type = 'procurement' and scope_id = t.scope('01') and status = 'verified' limit 1;
  path := format('%s/%s/%s/photo-1.jpg', fp.client_id, fp.scope_id, fp.id);
  other := format('%s/%s/%s/photo-1.jpg', '00000000-0000-4000-8000-000000000202', fp.scope_id, fp.id);
  perform t.as_user(t.u('05'));
  perform t.fails(format($q$ select app.register_attachment(%L, 'photo', %L, repeat('a', 64)) $q$, fp.id, other),
                  'evidence path must be', 'B6 attachment on a wrong path refused');
  perform t.ok((app.register_attachment(fp.id, 'photo', path, repeat('A', 64))).sha256 = repeat('a', 64),
               'B6 attachment registered with lower-case SHA-256 by the record''s operator');
  perform t.ok((select uploaded_by from public.attachments where storage_path = path) = t.u('05'), 'B6 uploader stamped');
  insert into storage.objects (bucket_id, name) values ('evidence', path);
  perform t.ok(true, 'B6 storage: operator uploads to the record''s folder');
  perform t.fails(format($q$ insert into storage.objects (bucket_id, name) values ('evidence', %L) $q$, other),
                  'row-level security', 'B6 storage: upload to another client''s folder refused');
  perform t.as_user(t.u('06'));
  perform t.ok((select count(*) from storage.objects where name = path) = 1, 'B6 storage: QC technician (next stage) can read the photo');
  perform t.as_user(t.u('12'));
  perform t.ok((select count(*) from storage.objects where name = path) = 0, 'B6 storage: other client cannot read the photo');
  perform t.as_service();
end $$;

rollback;
