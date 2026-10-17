-- Migration 56 (Veda, 16 Oct 2026: "also check that one client data should not be visible to another client"). Two
-- clients, each with a scope, a farmer, a farm-gate record, a buyer and its own lab; GrainVeda's shared lab. As every
-- person bound to a client, app.isolation_probe() reads every table the app reads and calls every app function that
-- takes one record's id with the other client's ids: nothing of the other client. Three leaks put in on purpose are each
-- caught (a table opened to all, a function that answers for any scope, a function that answers for any record). The
-- three leaks the probe found before migration 56 stay closed: another client's lab, a scope's activation list, the
-- roster pool naming another client's scope. The release script runs the probe read only; that is checked last.
-- Migration 56b: on the practice system the probe found a fourth (another client's openings, readable by every Client
-- Manager) that it could not find here: no client had an opening. Now every table the probe reads gets a row of each
-- client first, and the test fails on a table that has none.
begin;
select t.as_service();
set local app.change_path = 'test setup';
-- client 202: a scope staffed by 312, a farmer, a farm-gate record, a buyer, its lab
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status, stage_details_required, qc_report_required)
values ('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'KH26', 'Demox iso', '{procurement,qc,qr_activation}', 'draft', false, false);
select t.staff('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000312');
update public.scopes set status = 'active' where id = '00000000-0000-4000-8000-000000000499';
set local session_replication_role = replica;
insert into public.farmers (id, client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres, status, farmer_code)
values ('00000000-0000-4000-8000-000000000599', '00000000-0000-4000-8000-000000000202', 'Demox Farmer', 'F', 'Itwa', 'Siddharthnagar', '+919870099001', 2, 1, 'active', 'DEMOX-F-0001');
insert into public.footprints (id, scope_id, client_id, stage_type, farmer_id, created_by, payload, qty_in, qty_out, status, footprint_code)
values ('00000000-0000-4000-8000-000000000699', '00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000202', 'procurement', '00000000-0000-4000-8000-000000000599', '00000000-0000-4000-8000-000000000312', '{"gross_kg":100}', 100, 100, 'pending', 'DEMOX-KNM-KH26-P-0001'),
-- client 201: a farm-gate record of scope 401
       ('00000000-0000-4000-8000-000000000698', '00000000-0000-4000-8000-000000000401', '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'), '{"gross_kg":100}', 100, 100, 'pending', 'PRSDM-KNM-KH26-P-9901');
set local session_replication_role = origin;
insert into public.buyers (client_id, name, country, address, gstin) values
  ('00000000-0000-4000-8000-000000000202', 'Demox buyer 2', 'IN', 'x road', '09AAACN1234E1Z5'),
  ('00000000-0000-4000-8000-000000000201', 'Prasaadam buyer 1', 'IN', 'y road', '09AAACN1234E1Z6');
insert into public.labs (state_id, client_id, name, accreditation_no, kind, location)
select (select state_id from public.scopes where id = '00000000-0000-4000-8000-000000000401'), c, n, a, 'external', l
  from (values ('00000000-0000-4000-8000-000000000202'::uuid, 'Demox own lab', 'TC-9', 'Basti'),
               ('00000000-0000-4000-8000-000000000201'::uuid, 'Prasaadam own lab', 'TC-8', 'Basti'),
               (null, 'GrainVeda shared lab', 'TC-7', 'Lucknow')) v(c, n, a, l);

-- every table the app reads gets a row of each client (16 Oct, staging: the probe found client B's openings readable by
-- client A's managers; the local data had no opening of any client, so there was nothing to find). Written as the
-- database owner without the triggers: the rows only have to exist, each traced to its client.
create function pg_temp.fill(p_client uuid, p_scope uuid, p_fp uuid, p_farmer uuid, p_user uuid, p_tag text) returns void language plpgsql as $f$
declare v_link uuid := gen_random_uuid(); v_state uuid := (select state_id from public.scopes where id = p_scope);
begin
  insert into public.openings (code, state_id, role, stage, positions, client_id, scope_id, source, title, note)
    values ('ISO-' || p_tag, v_state, 'operator', 'procurement', 1, p_client, p_scope, 'requirement', 'iso ' || p_tag, 'iso');
  insert into public.mills (client_id, name, place, ownership) values (p_client, 'iso mill ' || p_tag, 'Basti', 'own');
  insert into public.packing_units (client_id, name, place, ownership) values (p_client, 'iso unit ' || p_tag, 'Basti', 'own');
  insert into public.collection_points (client_id, name, kind, district) values (p_client, 'iso point ' || p_tag, 'centre', 'Basti');
  insert into public.lot_payments (footprint_id, client_id, scope_id) values (p_fp, p_client, p_scope);
  insert into public.sale_terms (footprint_id, client_id, scope_id) values (p_fp, p_client, p_scope);
  insert into public.qc_samples (code, footprint_id, scope_id, client_id, drawn_on, qty_kg, created_by) values ('ISO-S-' || p_tag, p_fp, p_scope, p_client, current_date, 1, p_user);
  insert into public.withdrawals (footprint_id, reason, withdrawn_by) values (p_fp, 'iso withdrawal ' || p_tag, p_user);
  insert into public.footprint_returns (footprint_id, scope_id, stage_type, reason, returned_by) values (p_fp, p_scope, 'procurement', 'iso return reason', p_user);
  insert into public.farmer_gap (farmer_id, crop_id) values (p_farmer, '00000000-0000-4000-8000-000000000101');
  insert into public.farmer_change_flags (farmer_id, field) values (p_farmer, 'phone');
  insert into public.deliveries (shipment_id, scope_id, received_kg, transit_loss_kg, received_on, confirmed_by) values (p_fp, p_scope, 1, 0, current_date, p_user);
  insert into public.lot_closures (footprint_id, scope_id, floor_loss_kg, reason, closed_by) values (p_fp, p_scope, 1, 'iso closure', p_user);
  insert into public.net_weight_checks (footprint_id, scope_id, serials, picked_by) values (p_fp, p_scope, array['ISO-P-' || p_tag], p_user);
  insert into public.scan_flags (serial, kind, footprint_id, scope_id, client_id) values ('ISO-' || p_tag, 'many', p_fp, p_scope, p_client);
  insert into public.buyer_links (id, token_hash, footprint_id, scope_id, client_id, created_by, expires_at)
    values (v_link, encode(digest('iso' || p_tag, 'sha256'), 'hex'), p_fp, p_scope, p_client, p_user, now() + interval '1 day');
  insert into public.buyer_link_views (link_id, what) values (v_link, 'open');
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by) values (p_fp, 'document', p_client || '/iso/' || p_tag, repeat('a', 64), p_user);
  insert into public.flags (footprint_id, raised_by, text) values (p_fp, p_user, 'iso flag');
  insert into public.export_documents (footprint_id, scope_id, doc, status, set_by) values (p_fp, p_scope, 'iso doc', 'applied', p_user);
  insert into public.qc_verdicts (footprint_id) values (p_fp);
  insert into public.pack_batches (batch_code, footprint_id, scope_id) values ('ISO-B-' || p_tag, p_fp, p_scope);
  insert into public.cartons (code, batch_code, footprint_id, scope_id, seq, first_serial, last_serial, n)       -- migration 58
    values ('ISO-B-' || p_tag || '-C0001', 'ISO-B-' || p_tag, p_fp, p_scope, 1, 'ISO-P-' || p_tag, 'ISO-P-' || p_tag, 1);
  insert into public.packs (serial, batch_code, footprint_id, scope_id, size_kg, packed_on) values ('ISO-P-' || p_tag, 'ISO-B-' || p_tag, p_fp, p_scope, 1, current_date);
  insert into public.pack_skus (client_id, size, unit, material, market) values (p_client, 7, 'kg', 'pouch', 'domestic');
  insert into public.bills_of_lading (footprint_id, scope_id, bl_no, added_by) values (p_fp, p_scope, 'ISOBL' || p_tag, p_user);
  insert into public.warehouse_inspections (footprint_id, scope_id, inspected_on, condition, inspected_by) values (p_fp, p_scope, current_date, 'good', p_user);
  insert into public.warehouse_bags_out (footprint_id, scope_id, out_on, bags, recorded_by) values (p_fp, p_scope, current_date, 1, p_user);
  insert into public.qr_seals (footprint_id, qr_code, sealed_by, ledger_hash) values (p_fp, 'GV-ISO' || p_tag, p_user, repeat('b', 64));
  insert into public.qc_profile_verdicts (footprint_id, profile_id, code, name, version, verdict) values (p_fp, gen_random_uuid(), 'iso', 'iso', 1, 'pass');
end $f$;
set local session_replication_role = replica;
select pg_temp.fill('00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000699', '00000000-0000-4000-8000-000000000599', '00000000-0000-4000-8000-000000000312', 'D2');
select pg_temp.fill('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000401', '00000000-0000-4000-8000-000000000698', t.farmer('01'), t.u('05'), 'P1');
-- client 202 has a Client Manager too (Ravi, given the client's account)
insert into public.assignments (employee_id, lens, op_role, client_id) values (t.u('18'), 'client', 'client_account', '00000000-0000-4000-8000-000000000202');
set local session_replication_role = origin;
-- every table the probe reads has a row of each client (a new table without one fails here: give it a row above)
create function pg_temp.iso_rows(p_rel text) returns jsonb language plpgsql as $f$
declare v jsonb; cols text;
begin
  select string_agg(quote_ident(a.attname), ', ') into cols from pg_attribute a
   where a.attrelid = ('public.' || quote_ident(p_rel))::regclass and a.attnum > 0 and not a.attisdropped
     and a.attname::text = any (array['id', 'client_id', 'scope_id', 'footprint_id', 'seal_id', 'farmer_id', 'attachment_id', 'requirement_id', 'buyer_id', 'employee_id', 'user_id', 'link_id']);
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I) x', cols, p_rel) into v;
  return v;
end $f$;
create temp table cov as
select c.relname, (select count(*) from jsonb_array_elements(x.rows) r where app.isolation_owner(c.relname, r) = '00000000-0000-4000-8000-000000000201') as a,
       (select count(*) from jsonb_array_elements(x.rows) r where app.isolation_owner(c.relname, r) = '00000000-0000-4000-8000-000000000202') as b
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  cross join lateral (select pg_temp.iso_rows(c.relname) as rows) x
 where n.nspname = 'public' and c.relkind = 'r' and has_any_column_privilege('authenticated', c.oid, 'select')
   and c.relname <> 'app_users' and c.relname not like 'employee\_%'
   and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                and a.attname::text = any (array['client_id', 'scope_id', 'footprint_id', 'seal_id', 'farmer_id', 'attachment_id', 'requirement_id', 'buyer_id', 'link_id']));
select t.ok((select count(*) >= 30 from cov) and not exists (select 1 from cov where a = 0 or b = 0),
            'every table the probe reads (' || (select count(*) from cov) || ') has rows of both clients (none without: ' || coalesce((select string_agg(relname, ', ') from cov where a = 0 or b = 0), '-') || ')');

-- 1 · The probe: nothing of the other client ---------------------------------------------------------------------------
create temp table pr as select app.isolation_probe(true, false) as j;
select t.ok((select j->'leaks' = '[]'::jsonb from pr), 'no person bound to a client sees anything of the other client (' || (select j->>'leaks' from pr) || ')');
select t.ok((select (j->>'clients')::int = 2 and (j->>'people')::int >= 10 and (j->>'tables')::int >= 30 and (j->>'calls')::int > 1000
                    and (j->>'own_rows_seen')::int > 0 from pr),
            'it looked as everyone bound to a client, at every table and with the other client''s ids, and saw their own rows');
select t.ok((select not (j::text ~* 'demox|prasaadam|itwa|\+91') from pr), 'its answer names tables and functions, never a row');
-- the leak the probe found on the practice system (16 Oct): another client's openings, for a Client Manager
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.openings where code = 'ISO-P1') = 1 and (select count(*) from public.openings where code = 'ISO-D2') = 0,
            'a Client Manager reads his client''s openings, not another client''s');
select t.as_user(t.u('18'));
select t.ok((select count(*) from public.openings where code = 'ISO-D2') = 1 and (select count(*) from public.openings where code = 'ISO-P1') = 0,
            'and the other client''s Client Manager the other way round');
select t.as_user(t.u('16'));
select t.ok((select count(*) from public.openings where code in ('ISO-D2', 'ISO-P1')) = 2, 'HR reads both (their state''s openings)');
select t.as_service();
select t.as_user(t.u('03'));
select t.fails('select app.isolation_probe()', 'permission denied', 'the app''s people do not run it');
select t.as_anon();
select t.fails('select app.isolation_probe()', 'permission denied', 'nor does the public');
select t.as_service();

-- 2 · Leaks put in on purpose are caught ---------------------------------------------------------------------------------
-- a table opened to everyone
alter policy labs_read on public.labs using (true);
select t.ok((select (app.isolation_probe(false, false))->'leaks' @> '[{"kind": "table", "what": "labs"}]'), 'a table opened to all: caught');
alter policy labs_read on public.labs using (client_id is null or app.can_access_client(client_id));
-- openings readable by every manager again (as before migration 56b)
alter policy openings_read on public.openings using (app.acts_as_hr() or app.is_admin() or app.can_assign());
select t.ok((select (app.isolation_probe(false, false))->'leaks' @> '[{"kind": "table", "what": "openings"}]'), 'another client''s openings for any manager: caught');
alter policy openings_read on public.openings using (
  (app.acts_as_hr() and (app.hr_full() or state_id = any (app.my_hr_states()))) or app.is_admin()
  or (app.can_assign() and (coalesce(client_id, (select s.client_id from public.scopes s where s.id = scope_id)) is null
                            or app.can_access_client(coalesce(client_id, (select s.client_id from public.scopes s where s.id = scope_id))))));
-- a scope's activation list for anyone (as before migration 56)
do $$ declare d text := pg_get_functiondef('app.activation_missing(uuid)'::regprocedure); g text;
begin
  g := 'case when app.can_access_client((select s.client_id from public.scopes s where s.id = p_scope)) or app.acts_as_hr() then ';
  if position(g in d) = 0 or position(' end $function$' in d) = 0 then raise exception 'activation_missing: the guard is not where the test expects it'; end if;
  execute replace(replace(d, g, ''), ' end $function$', ' $function$');
end $$;
select t.ok((select (app.isolation_probe(true, false))->'leaks' @> '[{"kind": "function", "what": "activation_missing", "with": "scope"}]'),
            'a function that answers for any scope: caught');
-- a function that answers for any record
create function app.zz_leak(p uuid) returns jsonb language sql stable security definer set search_path = public as
  $$ select to_jsonb(f.footprint_code) from public.footprints f where f.id = p $$;
grant execute on function app.zz_leak(uuid) to authenticated;
select t.ok((select (app.isolation_probe(true, false))->'leaks' @> '[{"kind": "function", "what": "zz_leak"}]'), 'a function that answers for any record: caught');
rollback;

-- 3 · The leaks found before migration 56 stay closed ---------------------------------------------------------------------
begin;
select t.as_service();
set local app.change_path = 'test setup';
insert into public.scopes (id, client_id, crop_id, season_code, geography, chain, status, stage_details_required, qc_report_required)
values ('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000202', '00000000-0000-4000-8000-000000000101', 'KH26', 'Demox iso', '{procurement,qc,qr_activation}', 'draft', false, false);
select t.staff('00000000-0000-4000-8000-000000000499', '00000000-0000-4000-8000-000000000312');
update public.scopes set status = 'active' where id = '00000000-0000-4000-8000-000000000499';
insert into public.labs (state_id, client_id, name, accreditation_no, kind, location)
select (select state_id from public.scopes where id = '00000000-0000-4000-8000-000000000401'), c, n, a, 'external', l
  from (values ('00000000-0000-4000-8000-000000000202'::uuid, 'Demox own lab', 'TC-9', 'Basti'),
               ('00000000-0000-4000-8000-000000000201'::uuid, 'Prasaadam own lab', 'TC-8', 'Basti'),
               (null, 'GrainVeda shared lab', 'TC-7', 'Lucknow')) v(c, n, a, l);
select t.ok((select base_state_id from public.employee_org where employee_id = t.u('12')) = (select state_id from public.scopes where id = '00000000-0000-4000-8000-000000000401'),
            '312 works in the state of scope 401 too, so its roster pool lists him');
select t.as_user(t.u('12'));
select t.ok((select string_agg(name, ',' order by name) from public.labs where name in ('Demox own lab', 'Prasaadam own lab', 'GrainVeda shared lab'))
            = 'Demox own lab,GrainVeda shared lab', 'a lab: his client''s and GrainVeda''s shared one, not the other client''s');
select t.ok(app.activation_missing('00000000-0000-4000-8000-000000000401') is null, 'another client''s scope: no activation list');
select t.as_user(t.u('03'));
select t.ok((select string_agg(name, ',' order by name) from public.labs where name in ('Demox own lab', 'Prasaadam own lab', 'GrainVeda shared lab'))
            = 'GrainVeda shared lab,Prasaadam own lab', 'and the other way round');
select t.ok(app.activation_missing('00000000-0000-4000-8000-000000000401') is not null, 'his own scope: its activation list');
create temp table pool as select x from jsonb_array_elements(app.roster_pool('00000000-0000-4000-8000-000000000401')) x;
grant select on pool to authenticated;
-- migration 57 (G20, Veda: "client info should not be shared"): before, the pool listed him with his work said, not
-- named ("Milling for another client (active)"); now a person who works for another client is not in the pool at all
select t.ok(not exists (select 1 from pool where x->>'id' = t.u('12')::text)
            and not exists (select 1 from pool where (x->'elsewhere')::text ~* 'demox|Demo Exporter|499|other_client'),
            'the roster pool: a person who works now for another client is not offered (nor his work said)');
select t.ok(not exists (select 1 from public.app_users where id = t.u('12')) and not exists (select 1 from public.employee_org where employee_id = t.u('12'))
            and not exists (select 1 from jsonb_array_elements(app.people_directory()) p where p->>'id' = t.u('12')::text),
            'nor is he in People: his name, his record, his directory line');
select t.as_user(t.u('16'));
select t.ok(exists (select 1 from jsonb_array_elements(app.people_directory()) p where p->>'id' = t.u('12')::text),
            'HR sees him (HR staffs across clients)');
select t.as_user(t.u('03'));
select t.ok((select jsonb_array_length(x->'elsewhere') >= 3 and not exists (select 1 from jsonb_array_elements(x->'elsewhere') e where not (e ? 'client' and e ? 'label' and e ? 'scope_id'))
               from pool where x->>'id' = t.u('05')::text),
            'his own client''s other scopes are still named (the Procurement operator''s)');
rollback;

-- 4 · Run as the release script runs it: read only ------------------------------------------------------------------------
begin;
select t.as_service();
select t.ok((app.isolation_probe())->'leaks' = '[]'::jsonb, 'the probe, as the release script runs it');
select t.ok(current_setting('transaction_read_only') = 'on', 'it leaves its transaction read only');
select t.fails($$insert into public.buyers (client_id, name, country, address) values ('00000000-0000-4000-8000-000000000201', 'x', 'IN', 'y')$$,
               'read-only transaction', 'so nothing can be written in it');
rollback;
