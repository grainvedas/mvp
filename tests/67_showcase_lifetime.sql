-- Migration 72 (Phase 3, release 5 of Veda's combined brief of 19 Oct 2026: Part E3, Part F and A4).
--   1  nothing is public until approved: the page, the badge
--   2  who approves: the client's owner (and the admin for an own-brand client); not a viewer, not the Client Manager,
--      not another client; published once, in the Audit log
--   3  the page: states, crops and seasons with their figures (tonnes traced, villages, GI-area share, lab pass rate);
--      own brand said; no price, no farmer's name or phone, no buyer's name; a partner only where it agreed; a recall shows
--   4  never active when it is not: a state suspended says so; every state suspended: "paused" on the page and the badge;
--      the owner may not approve while suspended, and may unpublish
--   5  ended: "Verification ended on …"; the accounts still read and export
--   6  the lifetime period (a short one, as a practice system may set; never in production): the accounts open nothing,
--      the page and the outputs' verify pages say only that verification ended; the round tells the owners 30 days
--      before and marks the accounts removed after
--   7  grants
-- The fixture of tests/66 (Basti mill in Uttar Pradesh, Nagaon mill in Assam, one client order from both, Basti mill's
-- shipment sealed). Fake, format-valid numbers only.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert, update on fx to authenticated, anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ins(p_scope uuid, p_stage public.stage_type, p_prev uuid, p_by uuid, p jsonb) returns uuid language plpgsql as $$
declare v uuid; begin
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', p_stage, p_prev, p_by, p) returning id into v; return v; end $$;
create or replace function pg_temp.audited(p_action text, p_target uuid) returns boolean language sql security definer as $$
  select exists (select 1 from public.audit_log where action = p_action and target = p_target) $$;
create or replace function pg_temp.login(p uuid) returns void language sql security definer as $$ update public.app_users set auth_uid = p where id = p $$;
create or replace function pg_temp.tab(e jsonb, k text) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(e->'tables') x where x->>'key' = k $$;
grant execute on all functions in schema pg_temp to authenticated, anon;
set local app.change_path = 'test setup';

-- Assam: the client Active there; Nagaon mill, the same crop and chain as Basti mill, its people on its stages
insert into public.client_states (client_id, state_id, status, legacy) values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'active', true)
  on conflict (client_id, state_id) do update set status = 'active';
insert into fx values ('N', '00000000-0000-4000-8000-000000000488');
insert into public.scopes (id, client_id, state_id, crop_id, season_code, geography, chain, status, market_codes, tolerances, quality_params,
                           qc_report_required, record_price, procurement_details_required, stage_details_required)
select pg_temp.f('N'), s.client_id, '00000000-0000-4000-8000-000000000002', s.crop_id, s.season_code, 'Nagaon mill', s.chain, 'draft', s.market_codes,
       s.tolerances, s.quality_params, s.qc_report_required, s.record_price, s.procurement_details_required, s.stage_details_required
  from public.scopes s where s.id = t.scope('05');      -- Basti mill's settings
do $x$ declare a uuid; r record; begin
  perform set_config('app.assigning', 'on', true);
  for r in select * from (values ('procurement'::public.stage_type, t.u('05')), ('qc', t.u('06')), ('milling', t.u('08')), ('packing', t.u('09')),
                                  ('commercial', t.u('18')), ('shipment', t.u('10')), ('qr_activation', t.u('13'))) v(st, u) loop
    insert into public.assignments (employee_id, lens, op_role, scope_id, stages, created_by)
    values (r.u, 'scope', 'operator', pg_temp.f('N'), array[r.st], r.u) returning id into a;
    insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (r.u, pg_temp.f('N'), r.st, a);
  end loop;
  perform set_config('app.assigning', '', true);
end $x$;
update public.scopes set status = 'active' where id = pg_temp.f('N');

with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000001', 'Gorakhpur Grain Lab', 'TC-7001', 'external', 'Gorakhpur') returning id)
insert into fx select 'LAB', id from r;
with r as (insert into public.labs (state_id, name, accreditation_no, kind, location)
           values ('00000000-0000-4000-8000-000000000002', 'Guwahati Grain Lab', 'TC-7002', 'external', 'Guwahati') returning id)
insert into fx select 'LABA', id from r;
with r as (insert into public.pack_skus (client_id, size, unit, material, market, label_type) values ('00000000-0000-4000-8000-000000000201', 1, 'kg', 'pouch', 'domestic', 'sticker') returning id) insert into fx select 'SKU1', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Delhi Wholesale', 'IN', 'Azadpur Mandi, Delhi', '07AAACD1234E1Z5') returning id) insert into fx select 'BUY', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000201', 'Kolkata Traders', 'IN', 'Burrabazar, Kolkata', '19AAACK1234E1Z5') returning id) insert into fx select 'BUY2', id from r;
with r as (insert into public.buyers (client_id, name, country, address) values ('00000000-0000-4000-8000-000000000201', 'Rotterdam Rice BV', 'NL', 'Maasvlakte, Rotterdam') returning id) insert into fx select 'EXB', id from r;
with r as (insert into public.buyers (client_id, name, country, address, gstin) values ('00000000-0000-4000-8000-000000000202', 'Demox Buyer', 'IN', 'Okhla, New Delhi', '07AAACX1234E1Z5') returning id) insert into fx select 'XB', id from r;

-- a batch packed: procured (farm-verified or not), QC with its broken grains, milled, 20 pouches of 1 kg
create or replace function pg_temp.batch(p_scope uuid, p_tag text, p_fv boolean, p_broken numeric, p_lab uuid, p_pack_verifier uuid) returns uuid
language plpgsql as $$
declare v_p uuid; v_q uuid; v_m uuid; v_k uuid;
begin
  perform t.as_service();
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload, farm_verified)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'procurement', t.farmer('01'), t.u('05'),
          jsonb_build_object('gross_kg', 132, 'bags', 2, 'tare_kg_per_bag', 1, 'moisture_pct', jsonb_build_array(11.8, 11.7, 11.9),
            'collection_point_id', 'farm', 'gps_lat', 27.2, 'gps_lng', 83.0, 'delivered_by', 'farmer'), p_fv) returning id into v_p;
  perform t.verify(v_p, t.u('06'));
  perform t.as_user(t.u('06'));
  v_q := pg_temp.ins(p_scope, 'qc', v_p, t.u('06'), jsonb_build_object('qty_kg', 130, 'sample_qty_kg', 1,
    'readings', jsonb_build_object('moisture_pct', 11.8, 'broken_pct', p_broken, 'foreign_matter_pct', 0.2), 'lab_id', p_lab,
    'report_no', 'GL/2026/' || p_tag, 'report_date', ((now() at time zone 'Asia/Kolkata')::date)::text, 'sample_id', 'S-' || p_tag));
  perform t.as_user(t.u('08')); perform app.verify_footprint(v_q);
  v_m := pg_temp.ins(p_scope, 'milling', v_q, t.u('08'), '{"input_kg":129,"head_rice_kg":80,"broken_kg":10,"husk_kg":30,"bran_kg":6}');
  perform t.as_user(t.u('09')); perform app.verify_footprint(v_m);
  v_k := pg_temp.ins(p_scope, 'packing', v_m, t.u('09'),
    format('{"input_kg":20,"packets":[{"sku_id":"%s","units":20,"size_kg":1}]}', pg_temp.f('SKU1'))::jsonb);
  perform t.as_user(p_pack_verifier); perform app.verify_footprint(v_k);
  perform t.as_service();
  return v_k;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

insert into fx select 'KU', pg_temp.batch(t.scope('05'), '701', true, 2, pg_temp.f('LAB'), t.u('11'));     -- UP: passed both markets
insert into fx select 'KA', pg_temp.batch(pg_temp.f('N'), '702', true, 2, pg_temp.f('LABA'), t.u('18'));   -- Assam: passed both markets
insert into fx select 'KX', pg_temp.batch(t.scope('05'), '703', true, 4, pg_temp.f('LAB'), t.u('11'));     -- UP: domestic only (4 % broken)
insert into fx select 'KF', pg_temp.batch(t.scope('05'), '704', false, 2, pg_temp.f('LAB'), t.u('11'));    -- UP: not farm-verified
insert into fx select 'KU2', pg_temp.batch(t.scope('05'), '705', true, 2, pg_temp.f('LAB'), t.u('11'));    -- UP: for a second order
select t.as_service();
create temp table kp as select serial, footprint_id, row_number() over (partition by footprint_id order by serial) as n from public.packs
  where footprint_id in (select id from fx);
grant select on kp to authenticated, anon;
create or replace function pg_temp.codes(p_fp text, p_n int) returns jsonb language sql stable as $$
  select jsonb_agg(serial order by serial) from kp where footprint_id = pg_temp.f(p_fp) and n <= p_n $$;
create or replace function pg_temp.part(p_scope uuid, p_batch text, p_by uuid, p_order text, p_units int, p_extra jsonb default '{}'::jsonb) returns uuid
language sql as $$
  select pg_temp.ins(p_scope, 'commercial', pg_temp.f(p_batch), p_by,
    jsonb_build_object('client_order_id', pg_temp.f(p_order), 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', p_units))) || p_extra) $$;
create or replace function pg_temp.ship(p_scope uuid, p_part text, p_by uuid, p_batch text, p_units int, p_extra jsonb default '{}'::jsonb) returns uuid
language sql as $$
  select pg_temp.ins(p_scope, 'shipment', pg_temp.f(p_part), p_by, jsonb_build_object('vehicle_no', 'UP53AB1234', 'lr_no', 'LR-70',
    'dispatch_date', '2026-10-27', 'destination', 'Delhi', 'packs', jsonb_build_array(jsonb_build_object('sku_id', pg_temp.f('SKU1'), 'units', p_units)),
    'serials', pg_temp.codes(p_batch, p_units)) || p_extra) $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- the client accounts: the owner (the admin's), a viewer of Basti mill only (the owner's); the other client's owner
select t.as_user(t.u('01'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'owner', 'owner72@prasaadam.test');
insert into fx select 'OWN', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Prasaadam Owner', 'owner72@prasaadam.test');
select app.prepare_client_account('00000000-0000-4000-8000-000000000202', 'owner', 'owner72@demox.test');
insert into fx select 'OWN2', app.add_client_viewer('00000000-0000-4000-8000-000000000202', 'Demox Owner', 'owner72@demox.test');
select t.as_service(); select pg_temp.login(pg_temp.f('OWN')); select pg_temp.login(pg_temp.f('OWN2'));
select t.as_user(pg_temp.f('OWN'));
select app.prepare_client_account('00000000-0000-4000-8000-000000000201', 'viewer', 'viewer72@prasaadam.test', 'scopes', null, array[t.scope('05')]);
insert into fx select 'VW', app.add_client_viewer('00000000-0000-4000-8000-000000000201', 'Basti mill Viewer', 'viewer72@prasaadam.test');
select t.as_service(); select pg_temp.login(pg_temp.f('VW'));


update public.scopes set record_price = true where id = t.scope('05');    -- Basti mill records prices (the internal copy has them)

-- the order and its two parts, verified; Basti mill's and Nagaon mill's shipments under its invoice, verified ----------------
select t.as_user(t.u('11'));
insert into fx select 'O1', (app.client_order_new('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', pg_temp.f('BUY'),
  'domestic', null, 'PO-71-1', 'INV-71-1')->>'id')::uuid;
insert into fx select 'PU', pg_temp.part(t.scope('05'), 'KU', t.u('11'), 'O1', 6, '{"price_per_kg": 120, "currency": "INR"}');
select t.as_user(t.u('18'));
insert into fx select 'PA', pg_temp.part(pg_temp.f('N'), 'KA', t.u('18'), 'O1', 4);
select t.as_user(t.u('14')); select app.verify_footprint(pg_temp.f('PU'));
insert into fx select 'SU', pg_temp.ship(t.scope('05'), 'PU', t.u('14'), 'KU', 6);
select t.as_user(t.u('10')); select app.verify_footprint(pg_temp.f('PA'));
insert into fx select 'SA', pg_temp.ship(pg_temp.f('N'), 'PA', t.u('10'), 'KA', 4);
select t.as_service(); select t.attach(pg_temp.f('SU'), 'loading_photo'); select t.attach(pg_temp.f('SA'), 'loading_photo');
select t.as_user(t.u('07')); select app.verify_footprint(pg_temp.f('SU'));
select t.as_user(t.u('13')); select app.verify_footprint(pg_temp.f('SA'));
select t.as_service();
create or replace function pg_temp.pack(p_kind text, p_id uuid, p_status text default 'valid') returns public.reports
language sql stable security definer as $$
  select r.* from public.reports r where r.kind = 'evidence_pack' and r.subject_kind = p_kind and r.subject_id = p_id and r.status = p_status
   order by r.version desc limit 1 $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

select t.as_user(t.u('07'));
insert into fx select 'RU', pg_temp.ins(t.scope('05'), 'qr_activation', pg_temp.f('SU'), t.u('07'), '{}');
create temp table sealu as select (app.seal_lot(pg_temp.f('RU'))) as s;
grant select on sealu to authenticated, anon;
select t.as_service();
create temp table kg as select round(sum(qty_out) / 1000, 2) as t from public.footprints
 where client_id = '00000000-0000-4000-8000-000000000201' and stage_type = 'procurement' and status = 'verified'
   and scope_id in (select id from public.scopes where status in ('active', 'closed'));
grant select on kg to authenticated, anon;
create temp table td as select app.today() as d;
grant select on td to authenticated, anon;
create temp table fn as select name, right(regexp_replace(phone, '[^0-9]', '', 'g'), 10) as phone from public.farmers where id = t.farmer('01');
grant select on fn to authenticated, anon;
create or replace function pg_temp.audited_n(p_action text) returns bigint language sql security definer as $$
  select count(*) from public.audit_log where action = p_action $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 1 · nothing public until approved -----------------------------------------------------------------------------------------
select t.as_anon();
select t.ok(app.public_showcase('PRSDM') is null and app.showcase_badge('PRSDM')->>'status' = 'none' and app.public_showcase('NOSUCH') is null,
            '1: nothing public until the owner approves: no page, the badge says none');

-- 2 · who approves ----------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('VW'));
select t.fails($q$select app.showcase_publish('00000000-0000-4000-8000-000000000201')$q$, 'owner approves', '2: the viewer of Basti mill may not approve');
select t.as_user(t.u('03'));
select t.fails($q$select app.showcase_publish('00000000-0000-4000-8000-000000000201')$q$, 'owner approves', '2: nor the Client Manager');
select t.ok((select not (j->>'may_publish')::boolean and j->>'status' = 'never' and (j->'preview'->>'name') is not null
               from (select app.showcase_of('00000000-0000-4000-8000-000000000201') as j) x),
            '2: the Client Manager reads its state and the preview');
select t.as_user(t.u('01'));
select t.ok((app.showcase_of('00000000-0000-4000-8000-000000000201')->>'may_publish')::boolean
            and not (app.showcase_of('00000000-0000-4000-8000-000000000202')->>'may_publish')::boolean,
            '2: the admin may approve an own-brand client''s page (GrainVeda''s own), not another client''s');
select t.as_user(pg_temp.f('OWN2'));
select t.fails($q$select app.showcase_publish('00000000-0000-4000-8000-000000000201')$q$, 'record not found', '2: nor another client''s owner');
select t.fails($q$select app.showcase_of('00000000-0000-4000-8000-000000000201')$q$, 'record not found', '2: who reads not even its state');
select t.as_user(pg_temp.f('OWN'));
select t.ok((select (j->>'may_publish')::boolean from (select app.showcase_of('00000000-0000-4000-8000-000000000201') as j) x), '2: the owner may approve');
create temp table pub as select app.showcase_publish('00000000-0000-4000-8000-000000000201') as j;
grant select on pub to authenticated, anon;
select t.ok((select j->>'status' = 'published' and not (j->>'may_publish')::boolean and (j->>'may_unpublish')::boolean from pub)
            and pg_temp.audited_n('showcase_published') = 1, '2: the owner approves: published, in the Audit log');
select t.fails($q$select app.showcase_publish('00000000-0000-4000-8000-000000000201')$q$, 'published already', '2: once');

-- 3 · the page ---------------------------------------------------------------------------------------------------------------
select t.as_anon();
create temp table pg as select app.public_showcase('prsdm') as j;
select t.ok((select j->>'code' = 'PRSDM' and (j->>'own_brand')::boolean and not (j->>'expired')::boolean
                    and j->'verification'->>'status' = 'active' and jsonb_array_length(j->'states') = 2 from pg),
            '3: published: the page (its code in any case), own brand, two states, active');
select t.ok((select (j->'totals'->>'tonnes')::numeric = (select t from kg) and (j->'totals'->>'villages')::int >= 1
                    and (j->'totals'->>'lab_pass_pct')::numeric = 100
                    and exists (select 1 from jsonb_array_elements(j->'states') s, jsonb_array_elements(s->'crops') c
                                 where s->>'state' = 'Assam' and c->>'crop' is not null and c->>'season' = 'KH26' and (c->>'tonnes')::numeric > 0) from pg),
            '3: the figures: tonnes traced (the verified kilograms bought), villages, the lab pass rate; per state, crop and season');
select t.ok((select j::text not like '%' || (select name from fn) || '%'
                    and j::text not like '%' || (select phone from fn) || '%'
                    and j::text not like '%Delhi Wholesale%' and j::text not like '%Kolkata Traders%'
                    and j::text !~* 'price|inr|currency' from pg),
            '3: no farmer''s name or phone, no buyer''s name, no price');
select t.as_user(t.u('03'));
select app.set_release_status((select (s).footprint_id from sealu), 'recalled', 'practice recall: moisture complaint');
select t.as_anon();
select t.ok((select jsonb_array_length(j->'recalls') = 1 and j->'recalls'->0->>'qr_code' = (select (s).qr_code from sealu)
                    and j->'recalls'->0->>'reason' = 'practice recall: moisture complaint' from (select app.public_showcase('PRSDM') as j) x),
            '3: a recall shows, with its QR code and reason');
select t.as_service();
create temp table pe as select gen_random_uuid() as named, gen_random_uuid() as quiet;
insert into public.entities (id, legal_name, trade_name, entity_type, pan_pending) select named, 'Named Partner FPO Ltd', 'Named Partner FPO', 'cooperative', true from pe;
insert into public.entities (id, legal_name, trade_name, entity_type, pan_pending) select quiet, 'Quiet Partner FPO Ltd', 'Quiet Partner FPO', 'cooperative', true from pe;
insert into public.scope_partners (scope_id, entity_id, named_publicly) select t.scope('05'), named, true from pe;
insert into public.scope_partners (scope_id, entity_id, named_publicly) select t.scope('05'), quiet, false from pe;
select t.as_anon();
select t.ok((select j->'partners' = '["Named Partner FPO"]'::jsonb and j::text not like '%Quiet Partner%' from (select app.public_showcase('PRSDM') as j) x),
            '3: a sourcing partner only where it agreed to be named');

-- 4 · never active when it is not --------------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000002', 'suspended', 'practice: Assam contract issue');
select t.as_anon();
select t.ok((select j->'verification'->>'status' = 'active'
                    and (select s->>'status' from jsonb_array_elements(j->'states') s where s->>'state' = 'Assam') = 'paused'
                    and (select s->>'status' from jsonb_array_elements(j->'states') s where s->>'state' = 'Uttar Pradesh') = 'active'
               from (select app.public_showcase('PRSDM') as j) x),
            '4: one state suspended: that state says paused, the page stays active (Uttar Pradesh is)');
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'suspended', 'practice: every state paused');
select t.as_anon();
select t.ok((select j->'verification'->>'status' = 'paused' from (select app.public_showcase('PRSDM') as j) x)
            and app.showcase_badge('PRSDM')->>'status' = 'paused' and (app.showcase_badge('PRSDM')->>'own_brand')::boolean,
            '4: every state suspended: "paused" on the page and the badge (own brand said)');
select t.as_user(pg_temp.f('OWN'));
create temp table unp as select app.showcase_unpublish('00000000-0000-4000-8000-000000000201', 'practice: taken down while paused') as j;
grant select on unp to authenticated, anon;
select t.ok((select j->>'status' = 'unpublished' and j->>'unpublish_reason' = 'practice: taken down while paused' from unp)
            and pg_temp.audited_n('showcase_unpublished') = 1, '4: the owner unpublishes while suspended (with a reason, in the Audit log)');
select t.fails($q$select app.showcase_publish('00000000-0000-4000-8000-000000000201')$q$, 'while the client is Active',
               '4: and may not approve again while suspended');
select t.as_anon();
select t.ok(app.public_showcase('PRSDM') is null and app.showcase_badge('PRSDM')->>'status' = 'none', '4: unpublished: nothing public');
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'active', 'practice: every state resumed');
select t.as_user(pg_temp.f('OWN'));
select t.fails($q$select app.showcase_unpublish('00000000-0000-4000-8000-000000000201', 'again')$q$, 'not published', '4: unpublished once');
select app.showcase_publish('00000000-0000-4000-8000-000000000201');
select t.fails($q$select app.showcase_unpublish('00000000-0000-4000-8000-000000000201', 'no')$q$, 'at least 5 characters', '4: a reason');

-- 5 · ended ------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select app.client_set_status('00000000-0000-4000-8000-000000000201', null, 'ended', 'practice: the contract ended');
select t.as_anon();
select t.ok((select j->'verification'->>'status' = 'ended' and (j->'verification'->>'ended_on')::date = (select d from td) and not (j->>'expired')::boolean
               from (select app.public_showcase('PRSDM') as j) x)
            and app.showcase_badge('PRSDM')->>'ended_on' = (select d from td)::text,
            '5: every state ended: "Verification ended on" today, on the page and the badge');
select t.as_user(pg_temp.f('OWN'));
select t.ok(jsonb_array_length(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') = 1
            and (app.showcase_of('00000000-0000-4000-8000-000000000201')->>'live_until')::date >= ((select d from td) + interval '24 months')::date,
            '5: the owner still reads (24 months after the end at least)');
select t.ok((select count(*) > 0 from jsonb_array_elements((app.client_portfolio('00000000-0000-4000-8000-000000000201'))->'scopes')),
            '5: and its portfolio');

-- 6 · the lifetime period --------------------------------------------------------------------------------------------------
select t.as_service();
select set_config('app.lifetime_months_after_end', '1', true), set_config('app.lifetime_months_after_best_before', '-1200', true);
set local session_replication_role = replica;          -- test only: the contract ended 10 days after a month ago
update public.client_states set ended_on = ((select d from td) - interval '1 month' + interval '10 days')::date where client_id = '00000000-0000-4000-8000-000000000201';
set local session_replication_role = origin;
select t.ok(app.client_live_until('00000000-0000-4000-8000-000000000201') between (select d from td) + 1 and (select d from td) + 30
            and not app.client_accounts_closed('00000000-0000-4000-8000-000000000201'), '6: a short period: the end of it within 30 days, the accounts open');
create temp table r1 as select app.client_lifetime_round() as j;
create temp table r2 as select app.client_lifetime_round() as j;
select t.ok((select (j->>'told')::int = 1 from r1) and (select (j->>'told')::int = 0 from r2)
            and exists (select 1 from public.notifications n where n.user_id = pg_temp.f('OWN') and n.kind = 'client_accounts_closing'
                          and n.data->>'on' = app.client_live_until('00000000-0000-4000-8000-000000000201')::text),
            '6: the round tells the owner (once) the day the accounts close, 30 days or less before');
select t.as_user(pg_temp.f('OWN'));
select t.ok(exists (select 1 from jsonb_array_elements(app.my_notifications()) n where n->>'kind' = 'client_accounts_closing'), '6: the owner reads it');
select t.as_service();
set local session_replication_role = replica;
update public.client_states set ended_on = ((select d from td) - interval '1 month' - interval '1 day')::date where client_id = '00000000-0000-4000-8000-000000000201';
set local session_replication_role = origin;
select t.ok(app.client_accounts_closed('00000000-0000-4000-8000-000000000201'), '6: the period passed: the accounts are closed');
select t.as_user(pg_temp.f('OWN'));
select t.ok(jsonb_array_length(app.evidence_packs('shipment', pg_temp.f('SU'))->'packs') = 0 and not app.client_owner_check('00000000-0000-4000-8000-000000000201'),
            '6: the owner reads nothing, is no owner any more (the rules, before the round)');
select t.fails($q$select app.client_portfolio('00000000-0000-4000-8000-000000000201')$q$, 'not allowed', '6: nor its portfolio');
select t.as_service();
select t.ok(not app.account_reaches(pg_temp.f('VW'), t.scope('05')) and not app.account_reaches(pg_temp.f('OWN'), t.scope('05')),
            '6: the viewer and the owner reach no scope');
select t.as_anon();
select t.ok((select (j->>'expired')::boolean and not (j ? 'states') and j->'verification'->>'status' = 'ended' from (select app.public_showcase('PRSDM') as j) x),
            '6: the page says only that verification ended');
select t.ok((select (j->>'expired')::boolean and jsonb_array_length(j->'files') = 0 and not (j ? 'issued_to')
               from (select app.public_document((select ref from pg_temp.pack('shipment', pg_temp.f('SU'))))) x(j)),
            '6: the evidence pack''s verify page likewise');
select t.as_service();
create temp table r3 as select app.client_lifetime_round() as j;
create temp table r4 as select app.client_lifetime_round() as j;
select t.ok((select (j->>'closed')::int >= 2 from r3)
            and not exists (select 1 from public.client_accounts where client_id = '00000000-0000-4000-8000-000000000201' and status <> 'removed')
            and (select bool_and(status_reason like 'the lifetime period ended on%') from public.client_accounts where client_id = '00000000-0000-4000-8000-000000000201')
            and pg_temp.audited_n('client_accounts_closed') = 1 and (select (j->>'closed')::int = 0 from r4),
            '6: the round marks them removed with the reason, in the Audit log, once');
select t.as_user(pg_temp.f('OWN2'));
select t.ok(app.client_owner_check('00000000-0000-4000-8000-000000000202'), '6: another client''s owner is untouched');
select t.as_service();
insert into public.app_meta (key, value) values ('environment', 'production') on conflict (key) do update set value = excluded.value;
select t.ok(app.months_after('end') = 24 and app.months_after('best_before') = 12 and not app.client_accounts_closed('00000000-0000-4000-8000-000000000201'),
            '6: production never takes a shortened period');

-- 7 · grants -----------------------------------------------------------------------------------------------------------------
select t.ok(has_function_privilege('anon', 'app.public_showcase(text)', 'execute') and has_function_privilege('anon', 'app.showcase_badge(text)', 'execute')
            and not has_function_privilege('anon', 'app.showcase_of(uuid)', 'execute')
            and not has_function_privilege('authenticated', 'app.showcase_data(uuid)', 'execute')
            and not has_function_privilege('authenticated', 'app.client_lifetime_round()', 'execute')
            and not has_function_privilege('authenticated', 'app.client_live_until(uuid)', 'execute')
            and not has_table_privilege('authenticated', 'public.client_showcases', 'select')
            and exists (select 1 from pg_trigger where tgname = 'zz_change_log' and tgrelid = 'public.client_showcases'::regclass),
            '7: the page and the badge are public; the data, the round and the table the server''s');
rollback;
