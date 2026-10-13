-- Migration 43 (Veda, 13 Oct 2026, State Manager brief part D): the farmer register of a state. Ram is the demo UP State
-- Manager (302), the Client Manager of PRSDM 303, Procurement 305, the admin 301; 'AS' an Assam State Manager and 'DCM'
-- a Client Manager of DEMOX (the second UP client) are made below. Each check asks the database as the person would.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid);
grant select, insert on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and target = p_target $$;
create or replace function pg_temp.farmer(p uuid) returns public.farmers language sql stable security definer as $$
  select * from public.farmers where id = p $$;
create or replace function pg_temp.fp(p uuid) returns public.footprints language sql stable security definer as $$
  select * from public.footprints where id = p $$;
create or replace function pg_temp.reg(p jsonb) returns jsonb language sql as $$
  select app.farmer_register(jsonb_build_object('state', '00000000-0000-4000-8000-000000000001') || p) $$;
create or replace function pg_temp.row_of(r jsonb, p uuid) returns jsonb language sql immutable as $$
  select x from jsonb_array_elements(r->'rows') x where x->>'id' = p::text $$;

do $$ declare v uuid; begin
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000d01', '00000000-0000-4000-8000-000000000d01', 'Assam State Manager', 'sm.assam3@example.com') returning id into v;
  insert into fx values ('AS', v);
  insert into public.assignments (employee_id, lens, op_role, state_id) values (v, 'state', 'state_supervisor', '00000000-0000-4000-8000-000000000002');
  insert into public.app_users (id, auth_uid, display_name, email) values
    ('00000000-0000-4000-8000-000000000d02', '00000000-0000-4000-8000-000000000d02', 'Demox Client Manager', 'cm.demox@example.com') returning id into v;
  insert into fx values ('DCM', v);
  insert into public.assignments (employee_id, lens, op_role, client_id) values (v, 'client', 'client_account', '00000000-0000-4000-8000-000000000202');
end $$;

-- 1 · GI land: a draft may go without it; the Farmer ID may not ---------------------------------------------------------------
select t.as_user(t.u('03'));
do $$ declare f uuid; begin
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000201', 'Register One', 'Father', 'Bansi', 'Siddharthnagar', '+919870000001', 2) returning id into f;
  insert into fx values ('R1', f);
  perform t.ok(f is not null, 'D GI land: the Client Manager saves a draft without it');
end $$;
select t.fails(format($q$ update public.farmers set gi_land_acres = 3 where id = %L $q$, pg_temp.f('R1')), 'farmers_gi_land_within_land',
               'D GI land: not more than the farmer''s land');
select t.fails(format($q$ update public.farmers set gi_land_acres = 0 where id = %L $q$, pg_temp.f('R1')), 'check constraint',
               'D GI land: more than 0');
select app.submit_farmer(pg_temp.f('R1'));
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.verify_farmer(%L) $q$, pg_temp.f('R1')), 'the GI land (acres) is needed before the Farmer ID',
               'D GI land: Ram issues no Farmer ID without it');
do $$ begin
  update public.farmers set gi_land_acres = 1.5 where id = pg_temp.f('R1');
  perform t.ok((app.verify_farmer(pg_temp.f('R1'))).farmer_code is not null, 'D GI land: with it (Ram may fill it in at step 2) the Farmer ID is issued');
end $$;

-- 2 · a possible duplicate: the same phone in the same state on another client's record ---------------------------------------
select t.as_user(t.u('03'));
do $$ declare f uuid; begin
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres)
  values ('00000000-0000-4000-8000-000000000201', 'Shared Phone', 'Father', 'Itwa', 'Siddharthnagar', '+919870000002', 1, 1) returning id into f;
  insert into fx values ('D1', f);
  perform app.submit_farmer(f);
end $$;
select t.as_user(pg_temp.f('DCM'));
do $$ declare f uuid; begin
  insert into public.farmers (client_id, name, guardian_name, village, district, phone, land_area_acres, gi_land_acres)
  values ('00000000-0000-4000-8000-000000000202', 'Shared Phone Too', 'Father', 'Itwa', 'Siddharthnagar', '98700 00002', 1, 1) returning id into f;
  insert into fx values ('D2', f);
  perform t.ok(f is not null, 'D duplicate: the same phone on another client''s record is saved (flagged, not refused)');
end $$;
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.verify_farmer(%L) $q$, pg_temp.f('D1')), 'possible duplicate (same phone)',
               'D duplicate: Ram issues no Farmer ID while it is open');
do $$ declare r jsonb; begin
  r := pg_temp.reg('{"flag":"duplicate"}');
  perform t.ok(r->'total' = '2' and pg_temp.row_of(r, pg_temp.f('D1'))->'duplicates'->0->>'name' = 'Shared Phone Too',
               'D register: both records are flagged, each naming the other');
  perform t.ok((app.state_home('00000000-0000-4000-8000-000000000001')->'attention'->>'duplicates')::int >= 2, 'D overview: "Needs my action" counts them');
end $$;
select t.as_user(pg_temp.f('AS'));
select t.fails(format($q$ select app.mark_not_duplicate(%L, %L, 'brothers') $q$, pg_temp.f('D1'), pg_temp.f('D2')), 'the State Manager of the farmers',
               'D duplicate: another state''s manager does not decide');
select t.as_user(t.u('03'));
select t.fails(format($q$ select app.mark_not_duplicate(%L, %L, 'brothers') $q$, pg_temp.f('D1'), pg_temp.f('D2')), 'the State Manager of the farmers',
               'D duplicate: nor the Client Manager');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.mark_not_duplicate(%L, %L, ' ') $q$, pg_temp.f('D1'), pg_temp.f('D2')), 'say why',
               'D duplicate: a reason is needed');
select t.fails(format($q$ select app.mark_not_duplicate(%L, %L, 'x') $q$, pg_temp.f('D1'), pg_temp.f('R1')), 'not a possible duplicate',
               'D duplicate: only two records that share a phone');
do $$ begin
  perform app.mark_not_duplicate(pg_temp.f('D2'), pg_temp.f('D1'), 'two brothers, one phone');
  perform t.ok(jsonb_array_length(app.open_duplicates(pg_temp.f('D1'))) = 0 and pg_temp.audits('farmer_duplicate_cleared', pg_temp.f('D2')) = 1,
               'D duplicate: Ram says they are different people; logged; no longer open');
  perform t.ok((app.verify_farmer(pg_temp.f('D1'))).farmer_code is not null, 'D duplicate: then the Farmer ID is issued');
end $$;
-- a deactivated record is no duplicate
select t.as_service();
do $$ declare a uuid; b uuid; begin
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000201', 'draft', 'Old Record', 'F', 'V', 'Siddharthnagar', '+919870000003', 1) returning id into a;
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000202', 'draft', 'New Record', 'F', 'V', 'Siddharthnagar', '+919870000003', 1) returning id into b;
  perform t.ok(jsonb_array_length(app.open_duplicates(b)) = 1, 'D duplicate: found across clients');
  update public.farmers set status = 'inactive', farmer_code = 'TEST-OLD-1' where id = a;
  perform t.ok(jsonb_array_length(app.open_duplicates(b)) = 0, 'D duplicate: a deactivated record is not one');
end $$;
-- Ram's other answer: he deactivates the record waiting for him (the register's "Deactivate this record")
do $$ declare a uuid; b uuid; begin
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000201', 'draft', 'Kept Record', 'F', 'V', 'Siddharthnagar', '+919870000004', 1) returning id into a;
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres, reviewed_by, reviewed_at)
  values ('00000000-0000-4000-8000-000000000202', 'under_review', 'Second Record', 'F', 'V', 'Siddharthnagar', '+919870000004', 1, pg_temp.f('DCM'), now()) returning id into b;
  insert into fx values ('K1', a), ('K2', b);
end $$;
select t.as_user(t.u('02'));
do $$ begin
  update public.farmers set status = 'inactive' where id = pg_temp.f('K2');
  perform t.ok((pg_temp.farmer(pg_temp.f('K2'))).status = 'inactive' and jsonb_array_length(app.open_duplicates(pg_temp.f('K1'))) = 0,
               'D duplicate: Ram deactivates the record waiting for him; the other is no longer flagged');
end $$;
select t.as_service();

-- 3 · the yield check at Procurement: GI land × yield per acre; a warning past it, a flag past 120 % -------------------------
do $$ begin
  update public.farmers set gi_land_acres = 0.10 where id = t.farmer('05');      -- 100 kg of Kalanamak expected this season
  update public.farmers set gi_land_acres = 0.09 where id = t.farmer('04');      -- 90 kg expected
end $$;
select t.as_user(t.u('05'));
do $$ declare p uuid; w text[]; r jsonb; begin
  p := t.procure_as(t.scope('01'), t.farmer('05'), t.u('05'));
  perform t.ok(not exists (select 1 from unnest((pg_temp.fp(p)).warnings) x where x like 'above the expected yield%'),
               format('D yield: a first lot within the expected yield (%s of 100 kg) draws no warning', (pg_temp.fp(p)).qty_out));
  p := t.procure_as(t.scope('01'), t.farmer('05'), t.u('05'));
  w := (pg_temp.fp(p)).warnings;
  perform t.ok(exists (select 1 from unnest(w) x where x like 'above the expected yield: % of 100 kg this season (0.10 acres of GI land)'),
               'D yield: the lot that passes it is saved with a warning that says by how much');
  r := app.preview_reconcile(t.scope('01'), 'procurement', null, '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}', t.farmer('05'));
  perform t.ok(r->'warnings' @> '["above the expected yield: 294 of 100 kg this season (0.10 acres of GI land)"]', 'D yield: the form''s preview says the same');
  p := t.procure_as(t.scope('01'), t.farmer('04'), t.u('05'));
  perform t.ok(exists (select 1 from unnest((pg_temp.fp(p)).warnings) x where x like 'above the expected yield%'),
               'D yield: 98 of 90 kg: warned');
end $$;
select t.as_user(t.u('02'));
do $$ declare r jsonb; begin
  r := pg_temp.reg('{}');
  perform t.ok(pg_temp.row_of(r, t.farmer('05'))->'flags' @> '["over_yield"]' and (pg_temp.row_of(r, t.farmer('05'))->>'ratio')::numeric > 1.9,
               'D register: past 120 % the farmer is flagged, with his share of the expected yield');
  perform t.ok(not (pg_temp.row_of(r, t.farmer('04'))->'flags' @> '["over_yield"]') and (pg_temp.row_of(r, t.farmer('04'))->>'ratio')::numeric between 1 and 1.2,
               'D register: past 100 % but within 120 %: warned on the lot, not flagged');
  perform t.ok((app.state_home('00000000-0000-4000-8000-000000000001')->'attention'->>'over_yield')::int = 1, 'D overview: one farmer past 120 % needs his look');
  perform t.ok((r->'cards'->>'over_yield')::int = 1 and (r->'cards'->>'selling')::int >= 2 and (r->'cards'->>'sold_kg')::numeric > 0, 'D register: the cards count them');
end $$;

-- 4 · the register: his state only, the phone masked, filters, paging ---------------------------------------------------------
do $$ declare r jsonb; begin
  r := pg_temp.reg('{"q":"Register One"}');
  perform t.ok(r->'total' = '1' and pg_temp.row_of(r, pg_temp.f('R1'))->>'phone_last4' = '0001', 'D register: the phone shows its last four digits');
  perform t.ok(position('9870000001' in r::text) = 0 and not (pg_temp.row_of(r, pg_temp.f('R1')) ? 'phone'), 'D register: never the whole number');
  r := pg_temp.reg('{"flag":"no_gi_land"}');
  perform t.ok((r->>'total')::int >= 3 and not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'gi_land_acres' is not null),
               'D register: the farmers still without GI land');
  r := pg_temp.reg(format('{"client":"%s"}', '00000000-0000-4000-8000-000000000202')::jsonb);
  perform t.ok(not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'client_id' <> '00000000-0000-4000-8000-000000000202'), 'D register: by client');
  r := pg_temp.reg('{"limit":2}');
  perform t.ok(jsonb_array_length(r->'rows') = 2 and (r->>'total')::int > 2 and r->>'season' = 'KH26', 'D register: paged by the server, for the season');
  perform t.ok(jsonb_array_length(r->'cards'->'by_district') >= 1, 'D register: by district');
end $$;
select t.as_user(pg_temp.f('AS'));
select t.fails($q$ select app.farmer_register('{"state":"00000000-0000-4000-8000-000000000001"}') $q$, 'for its State Manager', 'D register: not another state''s');
select t.as_user(t.u('03'));
select t.fails($q$ select app.farmer_register('{"state":"00000000-0000-4000-8000-000000000001"}') $q$, 'for its State Manager', 'D register: not the Client Manager''s');
select t.as_user(t.u('01'));
select t.ok((pg_temp.reg('{}')->>'total')::int > 0, 'D register: the admin reads it');

-- 5 · the spreadsheet import takes GI land --------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
do $$ declare r jsonb; begin
  r := app.import_farmers('00000000-0000-4000-8000-000000000201',
         '[{"row":2,"name":"Imp A","guardian_name":"G","village":"V","district":"D","phone":"9870000011","land_area_acres":"2","gi_land_acres":"3"},
           {"row":3,"name":"Imp B","guardian_name":"G","village":"V","district":"D","phone":"9870000012","land_area_acres":"2","gi_land_acres":"x"}]', true);
  perform t.ok(r->'errors' @> '[{"row":2,"field":"gi_land_acres"},{"row":3,"field":"gi_land_acres"}]', 'D import: GI land more than the land, or not a number, is named');
  r := app.import_farmers('00000000-0000-4000-8000-000000000201',
         '[{"row":2,"name":"Imp C","guardian_name":"G","village":"V","district":"D","phone":"9870000013","land_area_acres":"2","gi_land_acres":"1.25"}]', false);
  perform t.ok((r->>'inserted')::int = 1 and (select gi_land_acres from public.farmers where name = 'Imp C') = 1.25
               and not ((select extra from public.farmers where name = 'Imp C') ? 'gi_land_acres'), 'D import: GI land is kept on the farmer, not in the extras');
end $$;

select t.as_service();
rollback;
