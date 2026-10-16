-- Migration 56 (Veda, 16 Oct 2026, "proceed with 56": release 9 of the operator-stages plan, Part F and D5–D6): a sale or
-- a shipment shared with its buyer through a link (what it shows and never shows, expiry, revocation, every view
-- logged), and every scan of a pack logged with its approximate place, copy detection, its flags and the public warning.
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201; 12 an operator of client 202.
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
create temp table tok (k text primary key, v text);
grant select, insert on tok to authenticated, anon;
create or replace function pg_temp.tok(p text) returns text language sql stable as $$ select v from tok where k = p $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- the lists and the chain to two sales and their shipments (as tests/48 builds them)
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.buyers (client_id, name, country, address, importer_id) values ('00000000-0000-4000-8000-000000000201', 'Amira Foods BV', 'NL', 'Keizersgracht 1, Amsterdam', 'NL-IMP-77') returning id) insert into fx select 'BUYEU', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.market_profiles (crop_id, code, name, version, status, params, export_docs, created_by)
           values ('00000000-0000-4000-8000-000000000101', 'eu', 'EU', 1, 'active', '[{"param":"aflatoxin_ppb","operator":"<=","limit":2}]',
                   '{"Phytosanitary certificate","Health certificate"}', t.u('02')) returning id) insert into fx select 'EU', id from r;
select t.as_user(t.u('03'));
update public.scopes set market_codes = '{domestic,export,eu}' where id = t.scope('05');
select t.as_service();
insert into fx select 'P', t.procure(t.scope('05'), t.farmer('05'), 204, 2, 2, 11.8, 11.7, 11.9);
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P'));
insert into fx select 'Q', pg_temp.ins(t.scope('05'), 'qc', pg_temp.f('P'), t.u('06'),
  '{"qty_kg":200,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2,"aflatoxin_ppb":1}}');
select t.as_service(); select t.attach(pg_temp.f('Q'), 'lab_report');
select t.as_user(t.u('08')); select app.verify_footprint(pg_temp.f('Q'));
insert into fx select 'M', pg_temp.ins(t.scope('05'), 'milling', pg_temp.f('Q'), t.u('08'), '{"input_kg":199,"head_rice_kg":150,"broken_kg":10,"husk_kg":30,"bran_kg":9}');
select t.as_user(t.u('09')); select app.verify_footprint(pg_temp.f('M'));
insert into fx select 'K', pg_temp.ins(t.scope('05'), 'packing', pg_temp.f('M'), t.u('09'),
  format('{"input_kg":150,"packets":[{"sku_id":"%s","units":150,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
select t.as_user(t.u('03'));
update public.scopes set stage_details_required = true, record_price = true where id = t.scope('05');
select t.as_user(t.u('11'));
insert into fx select 'D', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-101","packs":[{"sku_id":"%s","units":30}],"price_per_kg":120,"currency":"INR"}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
insert into fx select 'E', pg_temp.ins(t.scope('05'), 'commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"export","market_code":"eu","destination_country":"Netherlands","order_no":"EX-77","packs":[{"sku_id":"%s","units":40}],"price_per_kg":2.5,"currency":"USD","incoterms":"FOB"}',
         pg_temp.f('BUYEU'), pg_temp.f('SKU1'))::jsonb);
select t.as_service(); select t.attach(pg_temp.f('E'), 'export_doc');
select t.as_user(t.u('11'));
select app.set_export_doc(pg_temp.f('E'), 'Phytosanitary certificate', 'received', (select id from public.attachments where footprint_id = pg_temp.f('E') and label = 'export_doc' limit 1));
select app.set_export_doc(pg_temp.f('E'), 'Health certificate', 'not_required', null, 'the buyer waives it in the contract');
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D')); select app.verify_footprint(pg_temp.f('E'));
insert into fx select 'SD', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('D'), t.u('14'),
  format('{"invoice_no":"INV-1","vehicle_no":"UP53AB1234","transporter":"Basti Roadways","lr_no":"LR-1","dispatch_date":"2026-10-16","destination":"Delhi","packs":[{"sku_id":"%s","units":30}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_service();
create temp table ser as select array_agg(serial order by serial) as s from (select serial from public.packs where footprint_id = (select id from fx where k = 'K') order by serial limit 40) x;
grant select on ser to authenticated, anon;
select t.as_user(t.u('14'));
insert into fx select 'SE', pg_temp.ins(t.scope('05'), 'shipment', pg_temp.f('E'), t.u('14'),
  jsonb_build_object('invoice_no', 'EXP-1', 'container_no', 'MSKU1234567', 'seal_no', 'SL-9911', 'shipping_bill_no', '1234567', 'dispatch_date', '2026-10-16',
                     'destination', 'Rotterdam', 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', 40)), 'serials', to_jsonb((select s from ser))));
select t.as_service(); select t.attach(pg_temp.f('SE'), 'loading_photo'); select t.attach(pg_temp.f('P'), 'document');
select t.ok((pg_temp.fp(pg_temp.f('SE'))).qty_out = 40 and (pg_temp.fp(pg_temp.f('SD'))).qty_out = 30, 'the chain to two sales and their shipments');

-- 1 · A link: who makes it, for what, for how long --------------------------------------------------------------------
select t.as_user(t.u('11'));
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('E')), 'made by the Client Manager', 'Commercial does not share with the buyer');
select t.as_user(t.u('12'));
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('SE')), 'record not found', 'nor another client''s person');
select t.as_user(t.u('03'));
select t.fails(format($$select app.create_buyer_link(%L)$$, pg_temp.f('P')), 'of a sale or a shipment', 'a link is of a sale or a shipment');
select t.fails(format($$select app.create_buyer_link(%L, 0)$$, pg_temp.f('SE')), '1 to 90 days', 'it lasts at least a day');
select t.fails(format($$select app.create_buyer_link(%L, 91)$$, pg_temp.f('SE')), '1 to 90 days', 'and at most 90');
insert into tok select 'SE', (app.create_buyer_link(pg_temp.f('SE'), 30, 'for Amira'))->>'token';
insert into tok select 'D', (app.create_buyer_link(pg_temp.f('D'), 7))->>'token';
select t.as_service();
select t.ok(pg_temp.tok('SE') ~ '^[0-9a-f]{48}$'
            and (select token_hash = encode(digest(pg_temp.tok('SE'), 'sha256'), 'hex') and buyer_id = pg_temp.f('BUYEU') and expires_at > now() + interval '29 days'
                   from public.buyer_links where footprint_id = pg_temp.f('SE'))
            and not exists (select 1 from information_schema.columns where table_name = 'buyer_links' and column_name ilike '%token' ),
            'the token is given once; only its fingerprint is kept, with the buyer and the expiry');
select t.ok((select count(*) from public.audit_log where action = 'buyer_link_created') = 2, 'each link in the Audit log');
select t.as_user(t.u('03'));
select t.fails('select token_hash from public.buyer_links', 'permission denied', 'nobody reads a link''s fingerprint');
select t.ok((select count(*) from public.buyer_links) = 2, 'the Client Manager reads his links');
select t.as_user(t.u('11'));
select t.ok((select count(*) from public.buyer_links) = 0 and app.buyer_links_of(pg_temp.f('SE')) = '[]'::jsonb, 'an operator does not');
select t.as_user(t.u('12'));
select t.ok((select count(*) from public.buyer_links) = 0, 'nor another client''s person');

-- 2 · What the buyer sees, and never sees ----------------------------------------------------------------------------
select t.as_anon();
create temp table bv as select app.buyer_view(pg_temp.tok('SE')) as j;
select t.ok((select (j->>'ok')::boolean and j->'content'->>'kind' = 'shipment' and j->'content'->'order'->>'order_no' = 'EX-77'
                    and j->'content'->'order'->>'buyer' = 'Amira Foods BV' and (j->'content'->'order'->>'kg')::numeric = 40 from bv),
            'the buyer opens his shipment: the order, his buyer name, 40 kg');
select t.ok((select jsonb_array_length(j->'content'->'shipments') = 1 and j->'content'->'shipments'->0->>'container_no' = 'MSKU1234567'
                    and j->'content'->'shipments'->0->>'seal_no' = 'SL-9911' and j->'content'->'shipments'->0->>'invoice_no' = 'EXP-1' from bv),
            'the shipment''s papers');
select t.ok((select j->'content'->'lab'->0->'markets' @> '[{"name": "EU", "verdict": "pass"}]' and j->'content'->'lab'->0->'readings' ? 'aflatoxin_ppb' from bv),
            'the lab result per market, with the readings');
select t.ok((select j->'content'->'documents' @> '[{"doc": "Phytosanitary certificate", "status": "received"}, {"doc": "Health certificate", "status": "not_required"}]' from bv),
            'the export documents and their state');
select t.ok((select (select string_agg(x->>'label', ',' order by x->>'label') from jsonb_array_elements(j->'content'->'files') x) = 'export_doc,lab_report,loading_photo' from bv),
            'the files he may open: the lab report, the export document, the loading photo (not the farm-gate document)');
select t.ok((select j->'content'->'origin'->'villages'->0 ? 'share_pct' and (j->'content'->'origin'->>'farmers')::int = 1
                    and not exists (select 1 from jsonb_array_elements(j->'content'->'chain') x where x->>'stage' = 'procurement') from bv),
            'where it came from: villages by share, how many farmers; no farm-gate record');
select t.as_service();
select t.ok((select j::text not ilike '%price%' and not jsonb_path_exists(j, 'strict $.** ? (@ == 120 || @ == 2.5 || @ == "INR" || @ == "USD")')
                    and j::text not ilike '%currency%'
                    and j::text not like '%PO-101%' and j::text not like '%Delhi Wholesale%'
                    and j::text not like '%' || (select name from public.farmers where id = t.farmer('05')) || '%' from bv),
            'never a price, never the other buyer''s order, never a farmer''s name');
select t.ok((select not (j->'content'->'chain' @> '[{"qty_out_kg": 150}]') and j::text not like '%"qty_%' from bv), 'no quantity of the stages before his sale');
select t.ok((select count(*) from public.buyer_link_views v join public.buyer_links l on l.id = v.link_id where l.footprint_id = pg_temp.f('SE') and v.what = 'open') = 1,
            'the open is logged');
select t.as_anon();
select t.ok(app.buyer_log(pg_temp.tok('SE'), 'evidence') and not app.buyer_log(pg_temp.tok('SE'), 'something'), 'the evidence pack downloaded is logged (only that)');
select t.fails(format($$select app.buyer_file(%L, gen_random_uuid())$$, pg_temp.tok('SE')), 'permission denied', 'a file is fetched only through the buyer-file function');
-- the function (service role): a file of the page, and nothing else
select t.as_service();
create temp table bf_args as select pg_temp.tok('SE') as tok,
  (select id from public.attachments where footprint_id = pg_temp.f('SE') and label = 'loading_photo') as photo,
  (select id from public.attachments where footprint_id = pg_temp.f('P') limit 1) as farm_doc;
grant select on bf_args to service_role;
reset role; set local role service_role;
create temp table bf as select app.buyer_file(tok, photo) as a, app.buyer_file(tok, farm_doc) as b, app.buyer_file('0123', photo) as c from bf_args;
reset role;
select t.as_service();
select t.ok((select a->>'ok' = 'true' and a->>'path' is not null and a->>'sha256' is not null from bf), 'the loading photo: where it is kept');
select t.ok((select b->>'problem' = 'file' and c->>'problem' = 'link' from bf), 'not a file of another record, not with a wrong token');
select t.as_service();
select t.ok((select string_agg(what, ',' order by id) from public.buyer_link_views v where v.link_id = (select id from public.buyer_links where footprint_id = pg_temp.f('SE')))
            = 'open,evidence,file', 'every view logged: open, evidence pack, a file');
-- a sale's link shows its shipments; the other sale is not in it
select t.as_anon();
select t.ok((select c->>'kind' = 'commercial' and jsonb_array_length(c->'shipments') = 1 and c->'shipments'->0->>'invoice_no' = 'INV-1'
                    and c->'documents' = '[]'::jsonb and c::text not like '%EX-77%' and c::text not like '%Amira%'
               from (select app.buyer_view(pg_temp.tok('D'))->'content' c) x), 'a sale''s link: its shipments; nothing of the other buyer''s order');
select t.ok((app.buyer_view('not-a-token'))->>'ok' = 'false' and (app.buyer_view(repeat('a', 48)))->>'ok' = 'false', 'a wrong token opens nothing');

-- 3 · Expiry and revocation, the Client Manager's list ------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok((select x->>'state' = 'active' and (x->>'views')::int = 3 and x->>'note' = 'for Amira' and jsonb_array_length(x->'log') = 3
               from jsonb_array_elements(app.buyer_links_of(pg_temp.f('SE'))) x), 'the Client Manager sees the link, its state and every view');
select t.as_service();
insert into fx select 'LSE', id from public.buyer_links where footprint_id = pg_temp.f('SE');
select t.as_user(t.u('12'));
select t.fails(format($$select app.revoke_buyer_link(%L, 'not mine to keep')$$, pg_temp.f('LSE')),
               'not found', 'another client''s person does not revoke it');
select t.as_user(t.u('03'));
select t.fails(format($$select app.revoke_buyer_link(%L, 'no')$$, (select id from public.buyer_links where footprint_id = pg_temp.f('SE'))), 'say why', 'revoked with a reason');
select app.revoke_buyer_link((select id from public.buyer_links where footprint_id = pg_temp.f('SE')), 'sent to the wrong person');
select t.fails(format($$select app.revoke_buyer_link(%L, 'sent to the wrong person')$$, (select id from public.buyer_links where footprint_id = pg_temp.f('SE'))), 'revoked already', 'once');
select t.as_anon();
select t.ok((app.buyer_view(pg_temp.tok('SE')))->>'ok' = 'false', 'a revoked link opens nothing');
select t.as_service();
update public.buyer_links set expires_at = now() - interval '1 minute' where footprint_id = pg_temp.f('D');
select t.as_anon();
select t.ok((app.buyer_view(pg_temp.tok('D')))->>'ok' = 'false', 'an expired link opens nothing');
select t.as_user(t.u('03'));
select t.ok((select string_agg(x->>'state', ',') from jsonb_array_elements(app.buyer_links_of(pg_temp.f('SE')) || app.buyer_links_of(pg_temp.f('D'))) x) = 'revoked,expired',
            'the list says revoked and expired');

-- 4 · Scans: where, and copy detection ------------------------------------------------------------------------------------
select t.as_anon();
select t.ok((app.record_scan_at((select s[1] from ser), 'New Delhi', 'DL', 'in', 28.6139, 77.2090)) = '{"counted": true, "copy_warning": false}', 'a scan in Delhi: counted, no warning');
select t.as_service();
select t.ok((select city = 'New Delhi' and country = 'IN' and lat = 28.6 and lng = 77.2 from public.scans where code = (select s[1] from ser) order by id desc limit 1)
            and not exists (select 1 from information_schema.columns where table_name = 'scans' and column_name ~ 'ip|address|user|agent'),
            'its city and country, the point rounded to about 10 km; nothing of the person');
select t.as_anon();
select t.ok((app.record_scan_at((select s[1] from ser), 'Noida', 'UP', 'IN', 28.5355, 77.3910))->>'copy_warning' = 'false', 'near by (20 km): nothing');
select t.ok((app.record_scan_at((select s[1] from ser), 'Rotterdam', 'ZH', 'NL', 51.9244, 4.4777))->>'copy_warning' = 'true', 'the same code in Rotterdam: the warning');
select t.ok((app.public_pack((select s[1] from ser)))->'pack'->>'copy_warning' = 'true' and (app.public_pack((select s[1] from ser)))->'pack'->>'seller' = 'GrainVeda (Prasaadam trade scope)',
            'the pack''s public page says so, and names the seller');
select t.as_service();
select t.ok((select count(*) = 1 and bool_and(kind = 'far_apart' and status = 'open' and (detail->>'km')::numeric > 6000 and scope_id = t.scope('05')
                     and detail->'places' @> '[{"city": "Rotterdam", "country": "NL"}]')
               from public.scan_flags where serial = (select s[1] from ser)), 'one flag: far apart, the two places and the distance');
select t.as_anon();
select app.record_scan_at((select s[1] from ser), 'Mumbai', 'MH', 'IN', 19.07, 72.87);
select t.as_service();
select t.ok((select count(*) from public.scan_flags where serial = (select s[1] from ser)) = 1, 'one open flag per pack and kind');
-- many scans of one pack in a day; a machine (60 in a minute) is answered, not counted
insert into public.scans (code, kind, at) select (select s[2] from ser), 'pack', now() - interval '2 hours' from generate_series(1, 50);
select t.as_anon();
select t.ok((app.record_scan_at((select s[2] from ser)))->>'copy_warning' = 'true', 'the 51st scan in a day: the warning');
select t.as_service();
select t.ok(exists (select 1 from public.scan_flags where serial = (select s[2] from ser) and kind = 'many' and (detail->>'scans_24h')::int = 51), 'a flag: many scans');
insert into public.scans (code, kind, at) select (select s[3] from ser), 'pack', now() from generate_series(1, 60);
select t.as_anon();
select t.ok((app.record_scan_at((select s[3] from ser), 'Kyoto', null, 'JP', 35.0, 135.7))->>'counted' = 'false', 'a machine at it (60 a minute): answered, not counted');
select app.record_scan((select s[4] from ser));
select t.ok((app.record_scan_at('NOT-A-CODE'))->>'counted' = 'false', 'a code that is no pack: nothing');
select t.as_service();
select t.ok((select count(*) from public.scans where code = (select s[4] from ser) and city is null) = 1, 'the scan of before (no place) still counts');
-- the crop's limits
update public.crops set thresholds = coalesce(thresholds, '{}'::jsonb) || '{"copy_distance_km": 20000}' where id = '00000000-0000-4000-8000-000000000101';
select t.as_anon();
select app.record_scan_at((select s[5] from ser), 'New Delhi', 'DL', 'IN', 28.6, 77.2);
select app.record_scan_at((select s[5] from ser), 'Rotterdam', 'ZH', 'NL', 51.9, 4.5);
select t.as_service();
select t.ok(not exists (select 1 from public.scan_flags where serial = (select s[5] from ser)), 'the distance is the crop''s (here 20,000 km: no flag)');

-- 5 · The flags: who sees them, who decides ------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok(jsonb_array_length(app.scan_flags_list()) = 2 and (app.my_actions()->>'scan_flags')::int = 2
            and (select x->'scans'->0 ? 'city' and not (x->'scans'->0 ? 'lat') from jsonb_array_elements(app.scan_flags_list()) x where x->>'kind' = 'far_apart'),
            'the Client Manager sees the two flags, with the scans'' places (not the points), in "Needs my action"');
select t.as_user(t.u('11'));
select t.ok(app.scan_flags_list() = '[]'::jsonb and (select count(*) from public.scan_flags) = 0, 'an operator does not');
select t.fails(format($$select app.decide_scan_flag(%L, 'cleared', 'looked at the photos')$$, (select id from public.scan_flags where kind = 'far_apart')), 'not found', 'nor decides');
select t.as_user(t.u('12'));
select t.ok(app.scan_flags_list() = '[]'::jsonb, 'nor another client''s person');
select t.as_user(t.u('03'));
select t.fails(format($$select app.decide_scan_flag(%L, 'cleared', 'ok')$$, (select id from public.scan_flags where kind = 'far_apart')), 'say why', 'decided with a reason');
select t.fails(format($$select app.decide_scan_flag(%L, 'maybe', 'looked at the photos')$$, (select id from public.scan_flags where kind = 'far_apart')), 'cleared or confirmed', 'cleared or confirmed');
select app.decide_scan_flag((select id from public.scan_flags where kind = 'far_apart'), 'cleared', 'the buyer took one pack to Rotterdam on a visit');
select t.as_service();
select t.ok(not app.scan_warning((select s[1] from ser)), 'cleared: the warning goes');
select t.as_user(t.u('03'));
select app.decide_scan_flag((select id from public.scan_flags where kind = 'many'), 'confirmed', 'the same code printed on a copied label in a market');
select t.as_service();
select t.ok(app.scan_warning((select s[2] from ser)), 'confirmed a copy: the warning stays');
select t.as_user(t.u('03'));
select t.fails(format($$select app.decide_scan_flag(%L, 'cleared', 'changed my mind')$$, (select id from public.scan_flags where kind = 'many')), 'decided already', 'decided once');
select t.as_service();
select t.ok((select count(*) from public.audit_log where action in ('scan_flag_cleared', 'scan_flag_confirmed')) = 2
            and (select count(*) from public.change_log where table_name = 'scan_flags') >= 4, 'each decision in the Audit log and the change log');
update public.crops set thresholds = thresholds - 'copy_distance_km' where id = '00000000-0000-4000-8000-000000000101';
select t.as_anon();
select t.ok((app.record_scan_at((select s[1] from ser), 'Rotterdam', 'ZH', 'NL', 51.92, 4.48))->>'copy_warning' = 'true', 'a far scan after a clear opens a new flag');
rollback;
