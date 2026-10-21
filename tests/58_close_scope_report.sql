-- Migration 63 (Phase 1, release 5 of Veda's combined brief of 19 Oct 2026: Part D, close a scope and the season report).
--   1  the closing check lists every blocker: records pending, lots waiting for the lab, open flags, kilograms left (each
--      lot), export shipments without a delivery, packs never released (per batch), a mass-balance difference
--   2  the Client Manager requests the close only when every blocker is cleared or answered with a reason; nobody else
--   3  the State Manager confirms (not the requester, not the Client Manager): the write-offs are written, the scope is
--      closed and read only, the final report is issued with its reference; the mass balance still adds up, sold ≤ procured
--   4  the report's two copies: the shareable one without a farmer's name or a price, the internal one for its readers;
--      its files stored once by the managers; "Verify this document" says Valid, then Superseded after a reopen and a
--      second close, Withdrawn when the State Manager takes one back; an interim report any time before the close
--   5  the billing count for the admin; the client's own login reads and downloads, and closes nothing
-- Scope 05 (Basti mill): Procurement (05) → QC (06) → Milling (08) → Packing (09) → Commercial (11) → Shipment (14) →
-- QR (07). 03 the Client Manager of client 201; 02 the State Manager of UP; 04 the client's login; 01 the admin.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.ins(p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('05'), '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
create or replace function pg_temp.grp(c jsonb, k text) returns jsonb language sql immutable as $$
  select g from jsonb_array_elements(c->'groups') g where g->>'key' = k $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-5521', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
update public.scopes set record_price = true where id = t.scope('05');

-- the season: 132 kg bought, QC 130, milled (80 head rice), 30 pouches of 1 kg packed, 5 sold, shipped and sealed
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
  format('{"input_kg":30,"packets":[{"sku_id":"%s","units":30,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('11')); select app.verify_footprint(pg_temp.f('K'));
insert into fx select 'D1', pg_temp.ins('commercial', pg_temp.f('K'), t.u('11'),
  format('{"buyer_id":"%s","market":"domestic","order_no":"PO-63-1","packs":[{"sku_id":"%s","units":5}],"price_per_kg":390,"currency":"INR"}', pg_temp.f('BUY'), pg_temp.f('SKU1'))::jsonb);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('D1'));
insert into fx select 'S1', pg_temp.ins('shipment', pg_temp.f('D1'), t.u('14'), jsonb_build_object('invoice_no', 'INV-63', 'vehicle_no', 'UP53AB1234',
  'lr_no', 'LR-63', 'dispatch_date', '2026-10-20', 'destination', 'Delhi', 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', 5)),
  'serials', t.codes(pg_temp.f('K'), 5)));
select t.as_service(); select t.attach(pg_temp.f('S1'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('S1'));
insert into fx select 'R1', pg_temp.ins('qr_activation', pg_temp.f('S1'), t.u('07'), '{}');
select app.seal_lot(pg_temp.f('R1'));
-- and a lot still to verify, a sample at the lab, an open flag
select t.as_service();
insert into fx select 'P2', t.procure(t.scope('05'), t.farmer('04'), 54, 2, 2, 11.8, 11.7, 11.9);
with r as (insert into public.qc_samples (code, footprint_id, scope_id, client_id, drawn_on, qty_kg, created_by)
  values ('S-63-2', pg_temp.f('M'), t.scope('05'), '00000000-0000-4000-8000-000000000201', current_date, 1, t.u('06')) returning id)
insert into fx select 'SAMPLE', id from r;
with r as (insert into public.flags (footprint_id, raised_by, text) values (pg_temp.f('D1'), t.u('03'), 'buyer asked about the bag weight') returning id)
insert into fx select 'FLAG', id from r;

-- 1 · the checklist ------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
create temp table ck as select app.close_checklist(t.scope('05')) as c;
grant select on ck to authenticated, anon;
select t.ok((select not (c->>'clear')::boolean from ck), '1: the checklist is not clear');
select t.ok((select jsonb_array_length(pg_temp.grp(c, 'pending')->'items') = 1 and pg_temp.grp(c, 'pending')->'items'->0->>'id' = pg_temp.f('P2')::text from ck),
            '1: the record pending verification');
select t.ok((select pg_temp.grp(c, 'lab_hold')->'items'->0->>'code' = 'S-63-2' from ck), '1: the lot waiting for the lab');
select t.ok((select pg_temp.grp(c, 'flags')->'items'->0->>'id' = pg_temp.f('FLAG')::text from ck), '1: the open flag');
select t.ok((select (select jsonb_object_agg(e->>'code', (e->>'kg')::numeric) from jsonb_array_elements(pg_temp.grp(c, 'kg')->'items') e)
                    = jsonb_build_object((select footprint_code from public.footprints where id = pg_temp.f('M')), 50,
                                         (select footprint_code from public.footprints where id = pg_temp.f('K')), 25) from ck),
            '1: the kilograms left: 50 kg at Milling, 25 kg at Packing (the sealed lot and the consumed ones are not listed)');
select t.ok((select pg_temp.grp(c, 'packs')->'items' @> '[{"released": 5, "held": 25, "void": 0}]' from ck),
            '1: the batch: 5 packs released, 25 packed but not released');
select t.ok((select (pg_temp.grp(c, 'balance')->>'ok')::boolean and (pg_temp.grp(c, 'pod')->>'ok')::boolean from ck), '1: no balance difference, no export shipment');

-- 2 · the request ----------------------------------------------------------------------------------------------------------
select t.fails(format($q$ select app.request_close(%L, '{}'::jsonb) $q$, t.scope('05')), 'checklist is not clear (pending, lab_hold, flags, kg, packs)',
               '2: refused while anything blocks, naming each blocker');
-- clear what takes clearing: the pending lot is verified, the sample's result is in
select t.as_user(t.u('06')); select app.verify_footprint(pg_temp.f('P2'));
select t.as_service(); update public.qc_samples set status = 'results_in', qc_footprint_id = pg_temp.f('Q') where id = pg_temp.f('SAMPLE');
select t.as_user(t.u('03'));
create temp table ans as select jsonb_build_object(
  'flags', jsonb_build_array(jsonb_build_object('id', pg_temp.f('FLAG'), 'reason', 'carried over: the buyer will reweigh at Delhi')),
  'kg', jsonb_build_array(jsonb_build_object('id', pg_temp.f('M'), 'reason', 'head rice kept for the next season''s seed trial'),
                          jsonb_build_object('id', pg_temp.f('K'), 'reason', 'packs given out as samples to buyers'),
                          jsonb_build_object('id', pg_temp.f('P2'), 'reason', 'too short')),
  'packs', jsonb_build_array(jsonb_build_object('batch_code', (select payload->>'batch_code' from public.footprints where id = pg_temp.f('K')),
                          'reason', 'samples to buyers, not for sale'))) as a;
grant select on ans to authenticated, anon;
select t.fails(format($q$ select app.request_close(%L, %L::jsonb) $q$, t.scope('05'), (select a from ans)), 'not clear (kg)',
               '2: a reason of fewer than 10 characters answers nothing');
update ans set a = jsonb_set(a, '{kg,2,reason}', '"the farmer took this lot back unsold"');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.request_close(%L, %L::jsonb) $q$, t.scope('05'), (select a from ans)), 'Client Manager of the scope requests',
               '2: the State Manager does not request');
select t.as_user(t.u('04'));
select t.fails(format($q$ select app.request_close(%L, %L::jsonb) $q$, t.scope('05'), (select a from ans)), 'Client Manager of the scope requests',
               '2: nor the client''s own login');
select t.as_user(t.u('03'));
select t.fails(format($q$ update public.scopes set status = 'closed' where id = %L $q$, t.scope('05')), 'through its close request',
               '2: a scope is not closed by a plain update');
insert into fx select 'C1', (app.request_close(t.scope('05'), (select a from ans), 'season over')->>'id')::uuid;
select t.ok((select status = 'requested' and jsonb_array_length(items->'kg') = 3 and items->'flags'->0->>'reason' like 'carried over%'
               from public.scope_closures where id = pg_temp.f('C1')), '2: the request keeps its answers');
select t.ok(exists (select 1 from public.ledger where scope_id = t.scope('05') and event = 'scope_close_request' and payload->>'closure_id' = pg_temp.f('C1')::text),
            '2: the request is a ledger block');
select t.fails(format($q$ select app.request_close(%L, %L::jsonb) $q$, t.scope('05'), (select a from ans)), 'already requested', '2: one request at a time');
select t.ok((app.scope_close_state(t.scope('05'))->'may'->>'confirm')::boolean = false and (app.scope_close_state(t.scope('05'))->'may'->>'withdraw')::boolean,
            '2: the Client Manager may withdraw, not confirm');

-- 3 · the confirmation -----------------------------------------------------------------------------------------------------
select t.fails(format($q$ select app.confirm_close(%L) $q$, pg_temp.f('C1')), 'State Manager of the scope''s state confirms', '3: the Client Manager does not confirm');
select t.as_user(t.u('02'));
select t.ok((app.scope_close_state(t.scope('05'))->'may'->>'confirm')::boolean, '3: the State Manager may confirm');
create temp table conf as select app.confirm_close(pg_temp.f('C1')) as r;
grant select on conf to authenticated, anon;
select t.as_service();
select t.ok((select status = 'closed' from public.scopes where id = t.scope('05')), '3: the scope is closed');
select t.ok((select (r->>'version')::int = 1 and (r->>'written_off_kg')::numeric = 125 and r->'report'->>'ref' ~ '^GV-SR-[0-9]{6}$' from conf),
            '3: version 1, 125 kg written off (50 + 25 + 50), the final report''s reference');
select t.ok((select count(*) = 3 and bool_and(kind = 'written_off' and closure_id = pg_temp.f('C1') and reason like 'Written off at close: %')
               from public.lot_closures where scope_id = t.scope('05')), '3: each write-off is a lot closure of its own kind');
select t.ok((select count(*) = 3 from public.ledger where scope_id = t.scope('05') and event = 'write_off')
            and exists (select 1 from public.ledger where scope_id = t.scope('05') and event = 'scope_close' and (payload->>'version')::int = 1)
            and exists (select 1 from public.ledger where scope_id = t.scope('05') and event = 'report' and payload->>'act' = 'issued'),
            '3: each write-off, the close and the report are ledger blocks');
select t.ok((select bool_and((b->>'balanced')::boolean) and sum((b->>'written_off_kg')::numeric) = 125 from jsonb_array_elements(app.stage_balance_of(t.scope('05'))) b),
            '3: every stage still balances, the write-offs in their own column');
select t.ok((select (data_internal->'balance'->'check'->>'ok')::boolean and (data_internal->'balance'->'check'->>'sold_kg')::numeric = 5
                    and (data_internal->'balance'->'check'->>'procured_kg')::numeric = 180
               from public.reports where id = (select (r->'report'->>'id')::uuid from conf)), '3: the report checks sold (5 kg) ≤ procured (180 kg)');

-- after the close: read only; a recall stays possible
select t.as_user(t.u('03'));
select t.fails(format($q$ insert into public.flags (footprint_id, raised_by, text) values (%L, %L, 'late question') $q$, pg_temp.f('D1'), t.u('03')),
               'this scope is closed', '3: no flag on a closed scope');
select t.fails(format($q$ select app.void_pack(%L, 'torn in the store') $q$, (select serial from public.packs where footprint_id = pg_temp.f('K') order by serial desc limit 1)),
               'this scope is closed', '3: no pack voided');
select t.fails(format($q$ update public.scopes set record_price = false where id = %L $q$, t.scope('05')), 'this scope is closed', '3: its settings are read only');
select t.fails(format($q$ select app.generate_interim_report(%L) $q$, t.scope('05')), 'season is closed', '3: no interim report after the close');
select t.fails(format($q$ select t.procure(%L, t.farmer('01'), 50, 1, 1, 11.8, 11.7, 11.9) $q$, t.scope('05')), 'not active', '3: no new record');
select app.set_release_status(pg_temp.f('R1'), 'under_investigation', 'a buyer reported a torn bag at Delhi');
select t.as_service();
select t.ok((select status = 'under_investigation' from public.release_events where seal_id = pg_temp.f('R1') order by seq desc limit 1),
            '3: an investigation (and a recall) stays possible after the close');

-- 4 · the report: two copies, files, verify ----------------------------------------------------------------------------------
create temp table rep as select (r->'report'->>'id')::uuid as id, r->'report'->>'ref' as ref, (select name from public.farmers where id = t.farmer('01')) as farmer from conf;
grant select on rep to authenticated, anon;
select t.as_user(t.u('04'));
select t.ok((select x->'data'->'cover'->>'client' is not null and x->>'copy' = 'shareable' from (select app.report_content((select id from rep), 'shareable') as x) y),
            '4: the client''s login reads the shareable copy');
select t.ok((select (x->'data')::text not like '%' || (select farmer from rep) || '%'
                    and x->'data'->'origin'->'farmer_list' = 'null'::jsonb and x->'data'->'sales'->0->'price_per_kg' = 'null'::jsonb
               from (select app.report_content((select id from rep), 'shareable') as x) y), '4: the shareable copy: no farmer''s name, no price');
select t.ok((select x->'data'->'origin'->'farmer_list'->0->>'name' = (select farmer from rep)
                    and (x->'data'->'sales'->0->>'price_per_kg')::numeric = 390
               from (select app.report_content((select id from rep), 'internal') as x) y), '4: the internal copy: the farmer list and the price (Record price is on)');
select t.ok((select x->'data'->'sales'->0->>'buyer' = 'Delhi Wholesale' and x->'data'->'sales'->0->>'packs' = '5 × 1 kg pouch'
                    and x->'data'->'sales'->0->'shipments'->0->>'sealed' ~ '^GV-' and jsonb_array_length(x->'data'->'chain'->0->'recorded_by') = 1
               from (select app.report_content((select id from rep), 'shareable') as x) y), '4: staff and the buyer are named in both');
select t.fails(format($q$ select app.register_report_file(%L, 'shareable', 'pdf', 'en', %L, 1000) $q$, (select id from rep), repeat('a', 64)),
               'stores a report''s files', '4: the client''s login stores no file');
select t.ok(not app.may_write_report_object((select id from rep) || '/shareable.en.pdf'), '4: nor puts one in the store');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.report_content(%L, 'internal') $q$, (select id from rep)), 'take the shareable copy', '4: the admin takes the shareable copy');
select t.as_user(t.u('02'));
select app.register_report_file((select id from rep), 'shareable', 'pdf', 'en', repeat('a', 64), 120000);
select app.register_report_file((select id from rep), 'internal', 'pdf', 'hi', repeat('b', 64), 130000);
select t.fails(format($q$ select app.register_report_file(%L, 'shareable', 'pdf', 'en', %L, 1000) $q$, (select id from rep), repeat('c', 64)),
               'stored already', '4: a file is stored once');
select t.ok(app.may_read_report_file((select id from rep) || '/internal.hi.pdf') and app.may_write_report_object((select id from rep) || '/internal.en.xlsx'), '4: the State Manager reads and writes its files');
select t.as_user(t.u('01'));
select t.ok(app.may_read_report_file((select id from rep) || '/shareable.en.pdf') and not app.may_read_report_file((select id from rep) || '/internal.hi.pdf'),
            '4: the admin reads the shareable file only');
select t.as_anon();
select t.ok((select d->>'status' = 'valid' and (d->>'final')::boolean and d->>'issued_to' is not null and jsonb_array_length(d->'files') = 2
                    and d->'files' @> jsonb_build_array(jsonb_build_object('copy', 'shareable', 'format', 'pdf', 'lang', 'en', 'sha256', repeat('a', 64)))
               from (select app.public_document((select ref from rep)) as d) x), '4: Verify this document: Valid, final, issued to the client, the files'' SHA-256');
select t.ok(app.public_document('GV-SR-999999') is null, '4: an unknown reference is nothing');

-- reopen (the State Manager), an interim report, close again: the first final report is Superseded
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.reopen_scope(%L, 'a late correction of the milling record') $q$, t.scope('05')), 'only the State Manager', '4: the Client Manager does not reopen');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.reopen_scope(%L, 'late') $q$, t.scope('05')), 'say why', '4: a reopen needs a reason');
select app.reopen_scope(t.scope('05'), 'a late correction of the milling record');
select t.ok((select status = 'active' from public.scopes where id = t.scope('05')), '4: reopened');
select t.ok((select reopened_by = t.u('02') and reopen_reason like 'a late correction%' from public.scope_closures where id = pg_temp.f('C1')), '4: the close keeps who reopened it and why');
select t.as_user(t.u('03'));
create temp table interim as select app.generate_interim_report(t.scope('05')) as r;
grant select on interim to authenticated, anon;
select t.ok((select not (r->>'final')::boolean and (r->>'version')::int = 1 from interim), '4: an interim report before the close: interim 1');
select t.ok(app.public_document((select ref from rep))->>'status' = 'valid', '4: the final report stays valid until the next close');
insert into fx select 'C2', (app.request_close(t.scope('05'), jsonb_build_object('packs', (select a->'packs' from ans), 'flags', (select a->'flags' from ans)))->>'id')::uuid;
select t.as_user(t.u('02'));
create temp table conf2 as select app.confirm_close(pg_temp.f('C2')) as r;
grant select on conf2 to authenticated, anon;
select t.ok((select (r->>'version')::int = 2 and (r->'report'->>'version')::int = 2 from conf2), '4: the second close: version 2');
select t.as_anon();
select t.ok((select d->>'status' = 'superseded' and d->>'superseded_by' = (select r->'report'->>'ref' from conf2)
               from (select app.public_document((select ref from rep)) as d) x), '4: the first final report shows Superseded, by the second');
select t.ok((select app.public_document(r->>'ref')->>'status' = 'superseded' from interim), '4: the interim report too');
select t.as_user(t.u('02'));
select app.withdraw_report((select (r->'report'->>'id')::uuid from conf2), 'the milling figures were entered twice');
select t.as_anon();
select t.ok(app.public_document((select r->'report'->>'ref' from conf2))->>'status' = 'withdrawn', '4: a withdrawn report says Withdrawn');

-- 5 · the billing count; the client's login ---------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select t.ok((select sum((x->>'final')::int) = 2 and sum((x->>'interim')::int) = 1 from jsonb_array_elements(app.reports_issued()) x),
            '5: the admin reads the reports issued per client per month: 2 final, 1 interim');
select t.as_user(t.u('03'));
select t.fails('select app.reports_issued()', 'the admin reads', '5: nobody else');
select t.as_user(t.u('04'));
select t.ok((select jsonb_array_length(app.scope_reports(t.scope('05'))) = 3), '5: the client''s login lists every report');
select t.ok((select not (s->'may'->>'reopen')::boolean and not (s->'may'->>'request')::boolean and (s->'may'->>'internal')::boolean
               from (select app.scope_close_state(t.scope('05')) as s) x), '5: it may read the internal copy, and closes or reopens nothing');
select t.fails(format($q$ select app.reopen_scope(%L, 'the client wants to reopen') $q$, t.scope('05')), 'only the State Manager', '5: nor reopens');

-- 6 · export shipment without delivery, and a balance difference, block until answered (made directly, as old data) ----------
select t.as_service();
set local session_replication_role = replica;
update public.scopes set status = 'active' where id = t.scope('05');
update public.footprints set payload = payload || '{"market":"export"}' where id = pg_temp.f('D1');
update public.footprints set qty_out = qty_out + 7 where id = pg_temp.f('P2');
set local session_replication_role = origin;
select t.as_user(t.u('03'));
create temp table ck2 as select app.close_checklist(t.scope('05')) as c;
grant select on ck2 to authenticated, anon;
select t.ok((select pg_temp.grp(c, 'pod')->'items'->0->>'id' = pg_temp.f('S1')::text and not (pg_temp.grp(c, 'pod')->>'ok')::boolean from ck2),
            '6: an export shipment without its delivery blocks');
select t.ok((select not (pg_temp.grp(c, 'balance')->>'ok')::boolean and pg_temp.grp(c, 'balance')->'items' @> '[{"stage": "procurement"}]' from ck2),
            '6: a stage whose kilograms do not add up blocks');
select t.ok((select (pg_temp.grp(c, 'pod')->>'ok')::boolean and (pg_temp.grp(c, 'balance')->>'ok')::boolean
               from (select app.close_checklist(t.scope('05'), jsonb_build_object(
                       'pod', jsonb_build_array(jsonb_build_object('id', pg_temp.f('S1'), 'reason', 'awaiting POD from the importer')),
                       'balance', jsonb_build_array(jsonb_build_object('stage', 'procurement', 'reason', 'old record typed 7 kg high, explained')))) as c) x),
            '6: each is answered with a reason');
rollback;
