-- Migration 50 (Veda, 15 Oct 2026: the operator-stages brief, release 3, "packs, proof and blocks"). Scope 05 (Basti
-- mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) → QR (07). 03 the
-- Client Manager, 02 the State Manager. Scope 06 (Bansi batch) for the GI block.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
create temp table fxt (k text primary key, v text);
grant select, insert, update on fx, fxt to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.v(p text) returns text language sql stable as $$ select v from fxt where k = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$ select * from public.footprints where id = p $$;
create or replace function pg_temp.packs(p uuid, p_status text default 'packed') returns int language sql stable security definer as $$
  select count(*)::int from public.packs where footprint_id = p and status = p_status $$;
create or replace function pg_temp.scans(p text) returns int language sql stable security definer as $$ select count(*)::int from public.scans where code = p $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v;
end $$;
grant execute on function pg_temp.ins(uuid, public.stage_type, uuid, uuid, jsonb) to authenticated;
update public.crops set shelf_life_days = 365 where id = '00000000-0000-4000-8000-000000000101';

-- the chain up to Packing
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 199, 2, 2, 11.8, 11.7, 11.9);             -- 195 kg
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'), '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));

-- 0 · whether a scope asks for the lab report is set before activation ------------------------------------------------
select t.as_user(t.u('03'));
select t.fails($$update public.scopes set qc_report_required = true where id = t.scope('05')$$, 'set before the scope is activated',
               'an active scope''s lab-report setting is not changed from the app');
select t.as_user(t.u('09'));
-- 1 · G1: the batch code is the system's ------------------------------------------------------------------------------
select t.ok((app.preview_reconcile(t.scope('05'), 'packing', pg_temp.f('M'), '{"input_kg":130,"packets":[{"units":129,"size_kg":1}],"wastage_kg":1}'::jsonb)->>'ok')::boolean,
            'the packing form asks no batch code: the maths is shown without one (the save gives it)');
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  '{"input_kg":130,"packets":[{"units":100,"size_kg":1},{"units":58,"size_kg":0.5}],"wastage_kg":1,"batch_code":"MY-OWN-CODE"}');
insert into fxt select 'BC', (pg_temp.fp(pg_temp.f('K'))).payload->>'batch_code';
select t.ok(pg_temp.v('BC') ~ '^PRSDM-KNM-KH26-B[0-9]{4}$', 'the batch code is the system''s, not the one typed: ' || pg_temp.v('BC'));
update public.footprints set payload = payload || '{"batch_code": "CHANGED", "wastage_kg": 1}' where id = pg_temp.f('K');
select t.ok((pg_temp.fp(pg_temp.f('K'))).payload->>'batch_code' = pg_temp.v('BC'), 'a correction does not change it');

-- 2 · G8: one serial per pack; best-before from the crop's shelf life ---------------------------------------------------
select t.ok(pg_temp.packs(pg_temp.f('K')) = 158, 'one serial per pack: 100 + 58 = 158');
select t.as_service();
select t.ok((select bool_and(serial like pg_temp.v('BC') || '-%') and min(serial) = pg_temp.v('BC') || '-0001'
                    and bool_and(best_before = packed_on + 365) from public.packs where footprint_id = pg_temp.f('K')),
            'serials run from <batch>-0001; best-before = packed + 365 days');
select t.as_user(t.u('09'));
update public.footprints set payload = jsonb_set(payload, '{packets}', '[{"units":100,"size_kg":1},{"units":56,"size_kg":0.5}]') || '{"wastage_kg": 2}'
 where id = pg_temp.f('K');
select t.ok(pg_temp.packs(pg_temp.f('K')) = 156 and pg_temp.packs(pg_temp.f('K'), 'void') = 158,
            'corrected to 156 packs: 156 new serials, the 158 earlier ones void (never deleted)');
-- labels = packs: printed once; again only with a reason
select t.ok(jsonb_array_length(app.print_labels(pg_temp.f('K'))->'packs') = 156, 'the labels are the packs: 156');
select t.fails(format($$select app.print_labels(%L)$$, pg_temp.f('K')), 'printed before', 'a reprint needs a reason');
select t.ok((app.print_labels(pg_temp.f('K'), 'printer jammed on sheet 3')->>'reprint')::boolean, 'with a reason it is printed again, as a reprint');
select t.as_user(t.u('06'));
select t.fails(format($$select app.print_labels(%L)$$, pg_temp.f('K')), 'not found', 'QC does not print packing labels');
select t.as_user(t.u('09'));
insert into fxt select 'S1', (select min(serial) from public.packs where footprint_id = pg_temp.f('K') and status = 'packed');
select t.fails(format($$select app.void_pack(%L, 'torn')$$, pg_temp.v('S1')), 'at least 10 characters', 'a void needs a reason');
select app.void_pack(pg_temp.v('S1'), 'label torn at sealing');
select t.ok(pg_temp.packs(pg_temp.f('K')) = 155, 'a pack voided with its reason');

-- 3 · the rest of the chain; Release after a summary; its status ------------------------------------------------------------
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
insert into fx select 'C', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'), '{"buyer":"Delhi Wholesaler","market":"domestic","qty_kg":128}');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('C'));
insert into fx select 'SH', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('C'), t.u('14'),
  '{"shipped_kg":128,"vehicle_or_container":"UP53 AT 1234","dispatch_date":"2026-10-15","destination":"Delhi"}');
-- a pack scanned before release
select t.as_anon();
select t.ok(app.public_pack('NO-SUCH-SERIAL') is null
            and not ((app.public_pack(pg_temp.v('BC') || '-0200'))->>'released')::boolean
            and (app.public_pack(pg_temp.v('BC') || '-0200'))->'pack'->>'batch_code' = pg_temp.v('BC'),
            'a pack scanned before release: "packed, not yet released", with its batch');
select app.record_scan(pg_temp.v('BC') || '-0200');
select t.as_service();
select t.ok(pg_temp.scans(pg_temp.v('BC') || '-0200') = 1, 'the scan is counted (time and code only)');
select t.as_user(t.u('07'));
select app.verify_footprint(pg_temp.f('SH'));
select t.ok(not (app.release_preview(pg_temp.f('SH'))->>'ready')::boolean is false
            and (select (c->>'ok')::boolean from jsonb_array_elements(app.release_preview(pg_temp.f('SH'))->'checks') c where c->>'key' = 'all_verified')
            and (select (c->'vars'->>'n')::int from jsonb_array_elements(app.release_preview(pg_temp.f('SH'))->'checks') c where c->>'key' = 'packs') = 155,
            'the summary before release: everything verified, 155 packs of the batch');
with s as (select * from app.seal_source(pg_temp.f('SH'))) insert into fxt select 'QR', qr_code from s union all select 'SEAL', footprint_id::text from s;
select t.as_anon();
select t.ok(((app.public_pack(pg_temp.v('BC') || '-0200'))->>'released')::boolean
            and (app.public_pack(pg_temp.v('BC') || '-0200'))->'release'->>'status' = 'active'
            and ((app.public_pack(pg_temp.v('BC') || '-0200'))->'packs'->>'n')::int = 155,
            'after release the pack shows the lot''s journey, active');
select t.ok(not exists (select 1 from jsonb_array_elements(app.public_lot_journey(pg_temp.v('QR'))->'journey') e where e->'farmer' ? 'name'),
            'the public page names no farmer (Part D)');
select t.as_user(t.u('05'));
select t.fails(format($$select app.set_release_status(%L, 'recalled', 'a test recall here')$$, pg_temp.v('SEAL')),
               'changes a release''s status', 'an operator does not recall');
select t.as_user(t.u('03'));
select t.fails(format($$select app.set_release_status(%L, 'recalled', 'short')$$, pg_temp.v('SEAL')),
               'at least 10 characters', 'a recall needs a reason');
select app.set_release_status(pg_temp.v('SEAL')::uuid, 'recalled', 'moisture complaint from Delhi buyer');
select t.fails(format($$select app.set_release_status(%L, 'active', 'it was fine after all')$$, pg_temp.v('SEAL')),
               'stays recalled', 'a recalled release stays recalled');
select t.as_anon();
select t.ok((app.public_pack(pg_temp.v('BC') || '-0300'))->'release'->>'status' = 'recalled'
            and (app.public_pack(pg_temp.v('BC') || '-0300'))->'release'->>'reason' = 'moisture complaint from Delhi buyer',
            'a recall shows on every pack of the batch, with its reason');

-- 4 · G12: transit loss at delivery --------------------------------------------------------------------------------------
select t.as_user(t.u('14'));
select t.fails(format($$select app.confirm_delivery(%L, 130, (now() at time zone 'Asia/Kolkata')::date)$$, pg_temp.f('SH')), 'between 0 and', 'more than was shipped is refused');
select app.confirm_delivery(pg_temp.f('SH'), 127.5, (now() at time zone 'Asia/Kolkata')::date, 'two packs damp');
select t.ok((select transit_loss_kg from public.deliveries where shipment_id = pg_temp.f('SH')) = 0.5, 'delivered 127.5 of 128 kg: 0.5 kg lost in transit, recorded at delivery');
select t.fails(format($$select app.confirm_delivery(%L, 127, (now() at time zone 'Asia/Kolkata')::date)$$, pg_temp.f('SH')), 'already', 'confirmed once');

-- 5 · C5: the lab report ----------------------------------------------------------------------------------------------------
select t.as_service();
update public.scopes set qc_report_required = true where id = t.scope('05');
insert into fx select 'P2', t.procure(t.scope('05'), t.farmer('04'), 126, 3, 2, 12, 12, 12);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P2'));
select t.fails(format($$select pg_temp.ins(t.scope('05'), 'qc', %L, t.u('06'), '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":11.8}}')$$, pg_temp.f('P2')),
               'report number and the report date are required', 'a lab record names the lab, the report number and its date');
select t.fails(format($$select pg_temp.ins(t.scope('05'), 'qc', %L, t.u('06'), jsonb_build_object('qty_kg',120,'sample_qty_kg',1,'readings',jsonb_build_object('moisture_pct',11.8),
                 'lab_name','Agri Lab Gorakhpur','report_no','R-1','report_date',((now() at time zone 'Asia/Kolkata')::date + 2)::text))$$, pg_temp.f('P2')),
               'in the future', 'a report dated ahead is refused');
insert into fx select 'Q2', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P2'), t.u('06'), jsonb_build_object('qty_kg',120,'sample_qty_kg',1,
  'readings',jsonb_build_object('moisture_pct',11.8,'broken_pct',2,'foreign_matter_pct',0.2),'lab_name','Agri Lab Gorakhpur','report_no','R-1','report_date',(now() at time zone 'Asia/Kolkata')::date));
select t.as_service();
insert into fx select 'P3', t.procure(t.scope('05'), t.farmer('03'), 126, 3, 2, 12, 12, 12);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P3'));
select t.fails(format($$select pg_temp.ins(t.scope('05'), 'qc', %L, t.u('06'), jsonb_build_object('qty_kg',120,'sample_qty_kg',1,'readings',jsonb_build_object('moisture_pct',11.8),
                 'lab_name','agri lab  gorakhpur','report_no','r-1','report_date',(now() at time zone 'Asia/Kolkata')::date))$$, pg_temp.f('P3')),
               'already', 'the same report of the same lab on a second lot is refused (written differently)');
select t.as_user(t.u('08'));
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('Q2')), 'lab report file', 'a lab record is verified only once its report file is attached');
create or replace function pg_temp.photo(p_fp uuid, p_label text) returns void language sql security definer as $f$
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by, label)
  select id, 'photo', format('%s/%s/%s/%s.jpg', client_id, scope_id, id, md5(random()::text)), md5(random()::text) || md5(random()::text), created_by, p_label
    from public.footprints where id = p_fp $f$;
select pg_temp.photo(pg_temp.f('Q2'), null);
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('Q2')), 'lab report file', 'a photo that is not named the lab report does not count');
select pg_temp.photo(pg_temp.f('Q2'), 'lab_report');   -- the report photographed counts
select app.verify_footprint(pg_temp.f('Q2'));
select t.ok((pg_temp.fp(pg_temp.f('Q2'))).status = 'verified', 'with the report attached it is verified');

-- 6 · Blocks: GI and non-GI not batched; an export release needs the client's acceptance ---------------------------------------
select t.as_service();
update public.crops set gi_districts = array['Siddharthnagar'] where id = '00000000-0000-4000-8000-000000000101';
update public.farmers set district = 'Lucknow' where id = '00000000-0000-4000-8000-000000000502';
insert into fx select 'G1', t.procure(t.scope('06'), t.farmer('01'), 126, 3, 2, 12, 12, 12);
insert into fx select 'G2', t.procure(t.scope('06'), t.farmer('02'), 126, 3, 2, 12, 12, 12);
select t.as_user(t.u('15'));
select app.verify_footprint(pg_temp.f('G1')); select app.verify_footprint(pg_temp.f('G2'));
select t.fails(format($$select pg_temp.ins(t.scope('06'), 'village_batch', %L, t.u('15'), jsonb_build_object('village','Bansi','source_footprint_ids',jsonb_build_array(%L, %L)))$$,
                      pg_temp.f('G1'), pg_temp.f('G1'), pg_temp.f('G2')),
               'GI and non-GI lots are not batched together', 'a GI lot and a non-GI lot are not batched together');
select t.as_service();
update public.farmers set district = 'Siddharthnagar' where id = '00000000-0000-4000-8000-000000000502';
-- an export release (override) by the Client Manager: only with the client's written acceptance
insert into fx select 'P4', t.procure(t.scope('03'), t.farmer('01'), 126, 3, 2, 12.4, 12.3, 12.5);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P4'));
insert into fx select 'Q4', pg_temp.ins(t.scope('03'), 'qc', pg_temp.f('P4'), t.u('06'), '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":12.4,"broken_pct":2,"foreign_matter_pct":0.2}}');
select t.as_user(t.u('03'));
select t.fails(format($$update public.qc_verdicts set override = jsonb_build_object('market','export','reason','buyer accepts 12.4 percent','authoriser',%L) where footprint_id = %L$$,
                      t.u('03'), pg_temp.f('Q4')), 'written acceptance', 'an export release needs the client''s written acceptance attached first');
select t.attach(pg_temp.f('Q4'), 'acceptance');
update public.qc_verdicts set override = jsonb_build_object('market','export','reason','buyer accepts 12.4 percent','authoriser',t.u('03')) where footprint_id = pg_temp.f('Q4');
select t.as_service();
select t.ok(app.export_allowed(pg_temp.f('Q4')) and (select export_verdict::text from public.qc_verdicts where footprint_id = pg_temp.f('Q4')) = 'fail',
            'with it, export is released; the lab verdict stays "fail" (never "passed")');
rollback;
