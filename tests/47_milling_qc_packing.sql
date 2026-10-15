-- Migration 53 (Veda, 15 Oct 2026: the operator-stages brief, release 6: C4 Milling, C5 Quality Control, C6 Packing).
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201, 02 the State Manager of Uttar Pradesh. Kalanamak rice is crop 101.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$ select * from public.footprints where id = p $$;
create or replace function pg_temp.smp(p uuid) returns public.qc_samples language sql stable security definer as $$ select * from public.qc_samples where id = p $$;
create or replace function pg_temp.ins(p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values ('00000000-0000-4000-8000-000000000405', '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
update public.crops set shelf_life_days = 365, shelf_life_by_material = '{"pouch": 200}' where id = '00000000-0000-4000-8000-000000000101';
-- the lists (Part B): two mills (one dedicated to Kalanamak), another client's mill, a packing unit, packs, labs
with r as (insert into public.mills (client_id, name, place, ownership) values ('00000000-0000-4000-8000-000000000201', 'Hired mill', 'Basti', 'hired') returning id) insert into fx select 'MILL', id from r;
with r as (insert into public.mills (client_id, name, place, ownership, dedicated_crop_id) values ('00000000-0000-4000-8000-000000000201', 'Own Kalanamak mill', 'Basti', 'own', '00000000-0000-4000-8000-000000000101') returning id) insert into fx select 'DMILL', id from r;
with r as (insert into public.mills (client_id, name, place, ownership) values ('00000000-0000-4000-8000-000000000202', 'Other client mill', 'Basti', 'own') returning id) insert into fx select 'XMILL', id from r;
with r as (insert into public.packing_units (client_id, name, place, ownership, fssai_licence) values ('00000000-0000-4000-8000-000000000201', 'Basti packers', 'Basti', 'contract', '12345678901234') returning id) insert into fx select 'PU', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 500, 'g', 'jute', 'domestic', 'sticker') returning id) insert into fx select 'SKU500', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000202', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'XSKU', id from r;
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location) values ('00000000-0000-4000-8000-000000000001', 'Lucknow test lab', 'TC-1234', 'external', 'Lucknow') returning id) insert into fx select 'LAB', id from r;
with r as (insert into public.labs (state_id, name, kind, location) values ('00000000-0000-4000-8000-000000000001', 'Mill bench', 'in_house', 'Basti') returning id) insert into fx select 'INLAB', id from r;
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location) values ((select id from public.states where id <> '00000000-0000-4000-8000-000000000001' order by name limit 1), 'Other state lab', 'TC-9999', 'external', 'Patna') returning id) insert into fx select 'XLAB', id from r;
-- an EU profile for the crop (the State Manager's; activated with its source in the app: set here as active)
with r as (insert into public.market_profiles (crop_id, code, name, version, status, params, created_by)
           values ('00000000-0000-4000-8000-000000000101', 'eu', 'EU', 1, 'active', '[{"param":"aflatoxin_ppb","operator":"<=","limit":2}]', t.u('02')) returning id)
  insert into fx select 'EU', id from r;

-- 1 · The scope's settings ---------------------------------------------------------------------------------------------
select t.ok(not (select stage_details_required from public.scopes where id = t.scope('05')), 'the demo scopes do not ask the stage details (seed 09)');
select t.ok((select column_default from information_schema.columns where table_name = 'scopes' and column_name = 'stage_details_required') = 'true',
            'a scope made from now on asks them');
select t.as_user(t.u('08'));
update public.scopes set stage_details_required = true where id = t.scope('05');
select t.as_service();
select t.ok(not (select stage_details_required from public.scopes where id = t.scope('05')), 'an operator does not change it');
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true, market_codes = '{domestic,eu}' where id = t.scope('05');
select t.as_service();
select t.ok((select stage_details_required and market_codes = '{domestic,eu}' from public.scopes where id = t.scope('05')),
            'the Client Manager turns it on and names the markets the lab tests for (an active scope)');
select t.ok(exists (select 1 from jsonb_array_elements(app.scope_test_params(t.scope('05'))) x where x->>'param' = 'aflatoxin_ppb' and (x->>'from_profile')::boolean),
            'what QC tests: the crop''s tests and the market profiles'' (aflatoxin for the EU)');

-- the lot QC receives
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);                -- 200 kg
insert into fx select 'P2', t.procure(t.scope('05'), t.farmer('04'), 104, 2, 2, 11.8, 11.7, 11.9);               -- 100 kg, not verified
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));

-- 2 · C5 The sample, drawn first ---------------------------------------------------------------------------------------
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1,"counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3"}')$$, pg_temp.f('P')),
               'name the lab it goes to', 'the lab is named (from the state''s list)');
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1,"lab_id":"%s","counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3"}')$$, pg_temp.f('P'), pg_temp.f('XLAB')),
               'not one of this state''s labs', 'another state''s lab is refused');
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1,"lab_id":"%s"}')$$, pg_temp.f('P'), pg_temp.f('LAB')),
               'counter-sample', 'the retained counter-sample''s seal and where it is kept are asked');
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1,"lab_id":"%s","counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3","buyer_seal_no":"B-1"}')$$, pg_temp.f('P'), pg_temp.f('LAB')),
               'buyer''s sample names its seal number and who receives it', 'a buyer''s sample names who receives it');
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1,"lab_id":"%s","counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3"}')$$, pg_temp.f('P2'), pg_temp.f('LAB')),
               'verify the lot before drawing', 'a sample is drawn from a verified lot');
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":300,"lab_id":"%s","counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3"}')$$, pg_temp.f('P'), pg_temp.f('LAB')),
               'smaller than what is left', 'a sample is smaller than the lot');
insert into fx select 'S1', (app.draw_sample(pg_temp.f('P'), format('{"qty_kg":1,"lab_id":"%s","counter_seal_no":"CS-1","counter_stored_at":"QC shelf 3","buyer_seal_no":"B-77","buyer_recipient":"EU buyer"}', pg_temp.f('LAB'))::jsonb)).id;
insert into fx select 'S2', (app.draw_sample(pg_temp.f('P'), format('{"qty_kg":0.5,"lab_id":"%s","counter_seal_no":"CS-2","counter_stored_at":"QC shelf 3"}', pg_temp.f('INLAB'))::jsonb)).id;
select t.ok((pg_temp.smp(pg_temp.f('S1'))).code = (pg_temp.fp(pg_temp.f('P'))).footprint_code || '-S1' and (pg_temp.smp(pg_temp.f('S2'))).code like '%-S2',
            'the sample ID is the system''s: the lot''s code, -S1, -S2');
select t.ok((pg_temp.smp(pg_temp.f('S1'))).status = 'sent' and (pg_temp.smp(pg_temp.f('S1'))).keep_until = ((pg_temp.smp(pg_temp.f('S1'))).drawn_on + interval '12 months')::date,
            'sent to the lab, awaiting results; the counter-sample kept 12 months unless said');
select t.ok(jsonb_array_length(app.lot_samples(pg_temp.f('P'))) = 2, 'QC reads the lot''s samples');
select t.as_user(t.u('05'));
select t.fails(format($$select app.draw_sample(%L, '{"qty_kg":1}')$$, pg_temp.f('P')), 'drawn by Quality Control', 'Procurement does not draw it');
select t.ok(jsonb_array_length(app.lot_samples(pg_temp.f('P'))) = 0, 'Procurement does not read the samples');

-- 3 · C5 The QC record: the sample, the lab, the lab tests, a verdict per market -------------------------------------
select t.as_user(t.u('06'));
select t.fails($$select pg_temp.ins('qc', pg_temp.f('P'), t.u('06'), '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}')$$,
               'choose the sample drawn from this lot', 'the sample drawn first is named');
select t.fails(format($$select pg_temp.ins('qc', pg_temp.f('P'), t.u('06'), '{"qty_kg":200,"sample_ref":"%s","readings":{"moisture_pct":11.8,"aflatoxin_ppb":3}}')$$, pg_temp.f('S2')),
               'is a lab test: it is read at an accredited external lab', 'a lab test is not read at an in-house lab');
insert into fx select 'Q', pg_temp.ins('qc', pg_temp.f('P'), t.u('06'),
  format('{"qty_kg":150,"sample_ref":"%s","readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2,"aflatoxin_ppb":3}}', pg_temp.f('S1'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('Q'))).computed @> format('{"sample_code": "%s", "lab": "Lucknow test lab", "sample_qty_kg": 1}', (pg_temp.smp(pg_temp.f('S1'))).code)::jsonb
            and (pg_temp.fp(pg_temp.f('Q'))).qty_out = 149, 'the sample''s quantity and lab come with it');
select t.ok((pg_temp.smp(pg_temp.f('S1'))).status = 'results_in' and (pg_temp.smp(pg_temp.f('S1'))).qc_footprint_id = pg_temp.f('Q'), 'the sample''s results are in');
select t.fails(format($$select pg_temp.ins('qc', pg_temp.f('P'), t.u('06'), '{"qty_kg":10,"sample_ref":"%s","readings":{"moisture_pct":11.8}}')$$, pg_temp.f('S1')),
               'are in already', 'a sample''s results are recorded once');
select t.ok((select string_agg(code || '=' || verdict, ',' order by code) from public.qc_profile_verdicts where footprint_id = pg_temp.f('Q')) = 'domestic=pass,eu=fail',
            'a verdict per market of the scope: Domestic PASS · EU FAIL (and none for a market the scope does not sell to)');
select t.ok((select failed = '["Aflatoxin B1"]'::jsonb from public.qc_profile_verdicts where footprint_id = pg_temp.f('Q') and code = 'eu'),
            'the market verdict names the test that failed');
select t.ok(jsonb_array_length(app.footprint_detail(pg_temp.f('Q'))->'profile_verdicts') = 2, 'the record page carries them');
-- an export release on the client's written acceptance names who accepted, their title and the date
insert into fx select 'S3', (app.draw_sample(pg_temp.f('P'), format('{"qty_kg":1,"lab_id":"%s","counter_seal_no":"CS-3","counter_stored_at":"QC shelf 3"}', pg_temp.f('LAB'))::jsonb)).id;
insert into fx select 'Q2', pg_temp.ins('qc', pg_temp.f('P'), t.u('06'),
  format('{"qty_kg":40,"sample_ref":"%s","readings":{"moisture_pct":12.5,"broken_pct":2,"foreign_matter_pct":0.2}}', pg_temp.f('S3'))::jsonb);
select t.as_service(); select t.attach(pg_temp.f('Q2'), 'acceptance');
select t.as_user(t.u('03'));
select t.fails(format($$update public.qc_verdicts set override = '{"market":"export","reason":"buyer accepts 12.5 %% moisture in writing","authoriser":"%s"}' where footprint_id = %L$$, t.u('03'), pg_temp.f('Q2')),
               'names the client''s authorising person, their title and the date', 'an export release names who accepted it, their title and the date');
update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'buyer accepts 12.5 % moisture in writing', 'authoriser', t.u('03'),
       'client_person', 'A. Buyer', 'client_title', 'Director', 'accepted_on', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD'))
 where footprint_id = pg_temp.f('Q2');
select t.as_service();
select t.ok((select override->>'client_person' = 'A. Buyer' from public.qc_verdicts where footprint_id = pg_temp.f('Q2')), 'then it is released, with the names kept');
select t.as_user(t.u('06'));
-- disposal of a counter-sample
select t.fails(format($$select app.dispose_sample(%L, 'gone')$$, pg_temp.f('S2')), 'at least 10 characters', 'a disposal says how and why');
select t.fails(format($$select app.dispose_sample(%L, 'spoilt by rain on the shelf')$$, pg_temp.f('S2')), 'only a manager disposes of it',
               'before its keep-until date only a manager disposes of it');
select t.as_user(t.u('03'));
select app.dispose_sample(pg_temp.f('S2'), 'spoilt by rain on the shelf');
select t.ok((pg_temp.smp(pg_temp.f('S2'))).status = 'disposed' and (pg_temp.smp(pg_temp.f('S2'))).disposed_by = t.u('03'), 'the disposal is recorded (by whom, when, why)');
select t.fails(format($$select app.dispose_sample(%L, 'spoilt by rain on the shelf')$$, pg_temp.f('S2')), 'disposed of already', 'once');

-- 4 · C4 Milling --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
select t.fails($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$,
               'say which mill', 'the mill is asked');
select t.fails(format($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"mill_id":"%s","mill_operator":"Ram","line_clearance":"fully_cleaned","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$, pg_temp.f('XMILL')),
               'not one of this client''s active mills', 'another client''s mill is refused');
select t.fails(format($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"mill_id":"%s","line_clearance":"fully_cleaned","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$, pg_temp.f('MILL')),
               'name the mill operator', 'the mill operator is named');
select t.fails(format($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"mill_id":"%s","mill_operator":"Ram","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$, pg_temp.f('MILL')),
               'say how the line was cleared', 'a hired mill says how the line was cleared');
select t.fails(format($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"mill_id":"%s","mill_operator":"Ram","line_clearance":"fully_cleaned","head_rice_kg":120,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$, pg_temp.f('MILL')),
               'more than the paddy in', 'the outputs are not more than the input (the loss is never below 0)');
select t.fails(format($$select pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":149,"sent_kg":140,"mill_id":"%s","mill_operator":"Ram","line_clearance":"fully_cleaned","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}')$$, pg_temp.f('MILL')),
               'received (149 kg) more than was sent', 'the mill receives no more than was sent');
select t.ok((app.preview_reconcile(t.scope('05'), 'milling', pg_temp.f('Q'), format('{"input_kg":149,"mill_id":"%s","mill_operator":"Ram","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11}', pg_temp.f('DMILL'))::jsonb)
             ->'computed'->>'line_clearance') = 'dedicated', 'a mill dedicated to the crop records "dedicated line" by itself');
select t.ok(exists (select 1 from jsonb_array_elements_text(
             app.preview_reconcile(t.scope('05'), 'milling', pg_temp.f('Q'), format('{"input_kg":149,"mill_id":"%s","mill_operator":"Ram","line_clearance":"same_crop","head_rice_kg":105,"broken_kg":8,"husk_kg":30,"bran_kg":5}', pg_temp.f('MILL'))::jsonb)
              ->'warnings') x where x = 'outturn 75.8 % is above the crop''s ceiling of 70 %: the State Manager is told'),
            'the mass-balance ceiling on recovery: told to the State Manager (not refused)');
insert into fx select 'M', pg_temp.ins('milling', pg_temp.f('Q'), t.u('08'),
  format('{"input_kg":149,"sent_kg":155,"mill_id":"%s","mill_operator":"Ram","line_clearance":"fully_cleaned","head_rice_kg":90,"broken_kg":8,"husk_kg":30,"bran_kg":11,"polish":"light"}', pg_temp.f('MILL'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('M'))).computed @> '{"loss_kg": 10, "recovery_pct": 65.77, "head_rice_pct": 60.40, "transit_loss_kg": 6, "mill": "Hired mill", "line_clearance": "fully_cleaned"}'
            and (pg_temp.fp(pg_temp.f('M'))).qty_out = 90, 'loss, recovery %, head-rice %, transit loss worked out; head rice goes forward');
select t.as_service();
select t.ok((select n from app.milling_range_mill('00000000-0000-4000-8000-000000000101', pg_temp.f('MILL')::text, null)) = 0,
            'the usual range is learned per mill (no verified run yet)');

-- 5 · C6 Packing --------------------------------------------------------------------------------------------------------
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
select t.fails(format($$select pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":89,"packets":[{"sku_id":"%s","units":80,"size_kg":1}]}')$$, pg_temp.f('SKU1')),
               'say where it was packed', 'the packing unit is asked');
select t.fails(format($$select pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":89,"packing_unit_id":"%s","packets":[{"units":80,"size_kg":1}]}')$$, pg_temp.f('PU')),
               'choose the packs from the client''s pack list', 'packs come from the pack list (no typed sizes)');
select t.fails(format($$select pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":89,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":80,"size_kg":1}]}')$$, pg_temp.f('PU'), pg_temp.f('XSKU')),
               'not on the client''s pack list', 'another client''s pack is refused');
select t.fails(format($$select pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":89,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":80,"size_kg":2}]}')$$, pg_temp.f('PU'), pg_temp.f('SKU1')),
               'keeps its own size', 'a pack keeps its own size');
select t.fails(format($$select pg_temp.ins('packing', pg_temp.f('M'), t.u('09'), '{"input_kg":89,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":80,"size_kg":1},{"sku_id":"%s","units":10,"size_kg":0.5}]}')$$, pg_temp.f('PU'), pg_temp.f('SKU1'), pg_temp.f('SKU500')),
               'more than 2 %): say why', 'wastage above 2 % needs a reason');
insert into fx select 'K', pg_temp.ins('packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":89,"packing_unit_id":"%s","packets":[{"sku_id":"%s","units":80,"size_kg":1},{"sku_id":"%s","units":10,"size_kg":0.5}],"wastage_reason":"one pouch roll jammed"}', pg_temp.f('PU'), pg_temp.f('SKU1'), pg_temp.f('SKU500'))::jsonb);
select t.ok((pg_temp.fp(pg_temp.f('K'))).computed @> '{"packed_kg": 85, "wastage_kg": 4, "wastage_pct": 4.49, "packing_unit": "Basti packers"}'
            and 'wastage 4.5 % is above 2 %: one pouch roll jammed' = any ((pg_temp.fp(pg_temp.f('K'))).warnings),
            'the wastage worked out, its reason on the record');
select t.ok((select count(*) from public.packs where footprint_id = pg_temp.f('K') and status = 'packed') = 90
            and (select count(*) from public.packs where footprint_id = pg_temp.f('K') and sku_id = pg_temp.f('SKU1') and best_before = packed_on + 200) = 80
            and (select count(*) from public.packs where footprint_id = pg_temp.f('K') and sku_id = pg_temp.f('SKU500') and best_before = packed_on + 365) = 10,
            'best-before by the pack''s material (pouch 200 days), else the crop''s shelf life');
-- the net weight check (packs of 5 kg or less)
select t.as_user(t.u('11'));
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('K')), 'net weight check', 'Commercial does not verify before the packs are weighed');
select t.as_user(t.u('06'));
select t.fails(format($$select app.pick_net_weight(%L)$$, pg_temp.f('K')), 'not found', 'QC does not weigh the packs (it does not see them)');
select t.as_user(t.u('09'));
create temp table nw as select (app.pick_net_weight(pg_temp.f('K'))).serials as s;
grant select on nw to authenticated;
select t.ok((select cardinality(s) from nw) = 5 and (select serials from public.net_weight_checks where footprint_id = pg_temp.f('K')) = (select s from nw)
            and (app.pick_net_weight(pg_temp.f('K'))).serials = (select s from nw), 'the system picks 5 packs, once');
select t.fails(format($$select app.record_net_weights(%L, '{}')$$, pg_temp.f('K')), 'weigh pack', 'every pack picked is weighed');
select app.record_net_weights(pg_temp.f('K'), (select jsonb_object_agg(x, case when p.size_kg = 1 then 980 else 480 end) from unnest((select s from nw)) x join public.packs p on p.serial = x));
select t.ok((select result from public.net_weight_checks where footprint_id = pg_temp.f('K')) = 'fail', 'a pack short beyond the allowed error fails (1 kg: 15 g)');
select t.as_user(t.u('11'));
select t.fails(format($$select app.verify_footprint(%L)$$, pg_temp.f('K')), 'net weight check', 'a failed check holds the record');
select t.as_user(t.u('09'));
select app.record_net_weights(pg_temp.f('K'), (select jsonb_object_agg(x, case when p.size_kg = 1 then 995 else 492 end) from unnest((select s from nw)) x join public.packs p on p.serial = x));
select t.ok((select result from public.net_weight_checks where footprint_id = pg_temp.f('K')) = 'pass', 'weighed again: within the allowed error');
select t.ok((app.footprint_detail(pg_temp.f('K'))->'net_weight'->'check'->>'result') = 'pass' and (app.footprint_detail(pg_temp.f('K'))->'net_weight'->>'needed')::boolean,
            'the record page shows the check');
select t.as_user(t.u('11'));
select app.verify_footprint(pg_temp.f('K'));
select t.ok((pg_temp.fp(pg_temp.f('K'))).status = 'verified', 'then Commercial verifies it');
select t.as_service();
select t.ok(app.short_allowed_g(500) = 15 and app.short_allowed_g(5000) = 75 and app.short_allowed_g(25000) = 250,
            'the allowed error follows the Legal Metrology schedule (500 g: 15 g; 5 kg: 75 g; 25 kg: 250 g)');

-- 6 · C4 Close a lot with the rest as floor loss -----------------------------------------------------------------------
select t.as_user(t.u('11'));
select t.fails(format($$select app.close_lot(%L, 'floor sweepings')$$, pg_temp.f('M')), 'not found', 'Commercial does not close the mill''s lot (it does not see it)');
select t.as_user(t.u('08'));
select t.fails(format($$select app.close_lot(%L, 'floor sweepings')$$, pg_temp.f('M')), 'closed by the next stage or a manager', 'nor the mill that made it');
select t.as_user(t.u('09'));
select t.fails(format($$select app.close_lot(%L, 'x')$$, pg_temp.f('M')), 'at least 5 characters', 'a closure says why');
select app.close_lot(pg_temp.f('M'), 'floor sweepings after the run');
select t.ok((select floor_loss_kg from public.lot_closures where footprint_id = pg_temp.f('M')) = 1 and app.available_qty(pg_temp.f('M')) = 0
            and (pg_temp.fp(pg_temp.f('M'))).lot_closed, 'the 1 kg left is floor loss; nothing is left; the lot is closed');
select t.fails(format($$select app.close_lot(%L, 'floor sweepings after the run')$$, pg_temp.f('M')), 'closed already', 'once');
select t.as_user(t.u('08'));
select t.fails(format($$select app.close_lot(%L, 'floor sweepings after the run')$$, pg_temp.f('Q')), 'nothing is left of this lot',
               'a lot with nothing left is closed already');
select t.as_user(t.u('06'));
select t.fails(format($$select app.close_lot(%L, 'floor sweepings after the run')$$, pg_temp.f('P')), 'only a lot with 2 % or less left',
               'a lot with more than 2 % left is not closed this way (50 of 200 kg)');

-- 7 · The public page: the verdict per market, names and verdicts only ---------------------------------------------------
select t.ok(position('computed' in pg_get_functiondef('app.public_lot_journey(text)'::regprocedure)) = 0,
            'the public page still reads nothing of a record''s worked-out values');

select t.as_service();
rollback;
