-- Migration 34 · ADMIN OVERSIGHT, and the farmer's two verifications (Veda, 10 October 2026).
-- The admin reads everything and does: states, the two seats, State Managers (the state lens), the sign-in code, the
-- ledger check, and HR while the HR Admin seat is empty (and on the HR Admin / admins always). Everything else the
-- admin may not do, and the SERVER refuses it whatever a screen shows. Each refusal has its control: the role that
-- owns the act still does it. Demo world: 01 admin · 02 State Manager UP · 03 Client Manager Prasaadam · 05 Procurement
-- · 06 QC · 07 QR sealer (scope 01) · 16 HR Admin · 17 HR · 18 an active employee nobody has assigned.
begin;
select t.as_service();

-- 1 · reads: everything ------------------------------------------------------------------------------------------------------
do $$
declare ctx jsonb;
begin
  perform t.as_user(t.u('01'));
  ctx := app.my_context();
  perform t.ok((ctx->'user'->'can'->>'oversee')::boolean and (ctx->'user'->'can'->>'admin')::boolean, 'context: the admin oversees');
  perform t.ok(jsonb_array_length(ctx->'scopes') = (select count(*) from public.scopes)
               and (select bool_and((s->>'whole')::boolean and not (s->>'manage')::boolean) from jsonb_array_elements(ctx->'scopes') s),
               'context: every scope, whole, managed by nobody here');
  perform t.ok(not (ctx->'user'->'can'->>'hr')::boolean and (ctx->'user'->'can'->>'hr_seat_filled')::boolean,
               'context: the HR Admin seat is filled, so HR is not on the admin''s menu');
  perform t.ok((select count(*) from public.farmers) > 0
               and (select count(*) from public.clients) >= 2 and (select count(*) from public.ledger) > 0
               and (select count(*) from public.slot_assignments) > 0 and (select count(*) from public.qr_seals) >= 0,
               'reads: records, farmers, clients, the ledger, every roster');
  perform t.ok(app.people_directory() is not null and app.people_directory()::text like '%Ravi Kumar%', 'reads: the people directory (who has access to what)');
  perform t.as_service();
end $$;

-- 2 · stage work: record, verify, seal, verdict, flag ----------------------------------------------------------------------
do $$
declare p uuid; q uuid; n int;
begin
  perform t.as_user(t.u('01'));
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
      values (%L, '00000000-0000-4000-8000-000000000201', 'procurement', %L, %L,
              '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') $q$, t.scope('01'), t.farmer('01'), t.u('01')),
      'may not create', 'stage work: the admin records nothing');
  perform t.as_user(t.u('05'));
  p := t.procure_as(t.scope('01'), t.farmer('01'), t.u('05'));
  perform t.ok(p is not null, 'control: the procurement operator records');
  perform t.as_user(t.u('01'));
  perform t.ok((select count(*) from public.footprints where id = p) = 1 and (select count(*) from public.ledger where footprint_id = p) >= 1,
               'reads: the admin sees the new record and its ledger block');
  perform t.fails(format('select app.verify_footprint(%L)', p), 'not', 'stage work: the admin verifies nothing');
  perform t.ok((select status from public.footprints where id = p) = 'pending', 'stage work: the record is still pending');
  update public.footprints set status = 'verified', verified_by = t.u('01') where id = p;
  get diagnostics n = row_count;
  perform t.ok(n = 0 and (select status from public.footprints where id = p) = 'pending', 'stage work: nor by writing the row');
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(p);
  perform t.ok((select status from public.footprints where id = p) = 'verified', 'control: the QC technician (next stage) verifies');

  -- a verdict override and a flag's resolution are the scope manager's
  perform t.as_user(t.u('01'));
  update public.qc_verdicts set export_verdict = 'pass' where footprint_id in (select id from public.footprints where scope_id = t.scope('01'));
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'stage work: the admin overrides no lab verdict');
  insert into public.flags (footprint_id, raised_by, text) values (p, t.u('01'), 'Admin asks: bags look wet') returning id into q;
  perform t.ok(q is not null, 'the admin may raise a flag (a question, not an act on the record)');
  update public.flags set status = 'resolved' where id = q;
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'stage work: the admin resolves no flag');
  perform t.as_user(t.u('03'));
  update public.flags set status = 'resolved' where id = q;
  get diagnostics n = row_count;
  perform t.ok(n = 1, 'control: the scope''s Client Manager resolves it');

  -- sealing
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.seal_source(%L)', p), 'may not create at stage qr_activation', 'stage work: the admin seals nothing');
  perform t.as_service();
end $$;

-- 3 · farmers -------------------------------------------------------------------------------------------------------------------
do $$
declare d uuid; n int; res jsonb;
begin
  perform t.as_user(t.u('01'));
  perform t.fails($q$ insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
                      values ('00000000-0000-4000-8000-000000000201', 'draft', 'Admin Kisan', 'G', 'V', 'D', '+919000007001', 1) $q$,
                  'row-level security', 'farmers: the admin adds none');
  perform t.fails($q$ select app.import_farmers('00000000-0000-4000-8000-000000000201',
                      '[{"row":2,"name":"A","guardian_name":"G","village":"V","district":"D","phone":"9876507001","land_area_acres":"1"}]', false, null) $q$,
                  'no farmer access', 'farmers: nor imports any');
  perform t.as_user(t.u('05'));
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000201', 'draft', 'Oversight Kisan', 'Shri G', 'Bansi', 'Siddharthnagar', '+919000007002', 1) returning id into d;
  perform t.ok((select state_id from public.farmers where id = d) = (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201'),
               'farmers: a new farmer is in the client''s home state unless another is chosen');
  perform t.as_user(t.u('01'));
  update public.farmers set name = 'Changed by the admin' where id = d;
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'farmers: the admin edits no draft');
  perform t.fails(format('select app.submit_farmer(%L)', d), 'not a draft', 'farmers: the admin does not verify step 1');
  perform t.as_user(t.u('03'));
  perform app.submit_farmer(d);
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.verify_farmer(%L)', d), 'not waiting', 'farmers: the admin issues no Farmer ID');
  perform t.fails(format('select app.send_back_farmer(%L, %L)', d, 'no'), 'only a State Manager', 'farmers: the admin sends nobody back');
  perform t.as_user(t.u('03'));
  perform t.fails(format('select app.verify_farmer(%L)', d), 'State Manager', 'farmers: the Client Manager does not do step 2 as well');
  perform t.as_user(t.u('02'));
  perform t.ok((app.verify_farmer(d)).farmer_code is not null, 'control: the State Manager of the farmer''s state issues the Farmer ID');
  perform t.as_user(t.u('01'));
  update public.farmers set status = 'inactive' where id = d;
  get diagnostics n = row_count;
  perform t.ok(n = 0 and (select status from public.farmers where id = d) = 'active', 'farmers: the admin deactivates no farmer');
  perform t.as_user(t.u('02'));
  update public.farmers set status = 'inactive' where id = d;
  perform t.ok((select status from public.farmers where id = d) = 'inactive', 'control: the State Manager deactivates');
  perform t.as_service();
end $$;

-- the two steps are two people: a person holding both the client's account and the state does not do both
do $$
declare d uuid; a uuid;
begin
  insert into public.assignments (employee_id, lens, op_role, client_id) values (t.u('02'), 'client', 'client_account', '00000000-0000-4000-8000-000000000201')
  returning id into a;
  perform t.as_user(t.u('05'));
  insert into public.farmers (client_id, status, name, guardian_name, village, district, phone, land_area_acres)
  values ('00000000-0000-4000-8000-000000000201', 'draft', 'Two Hats', 'Shri G', 'Itwa', 'Siddharthnagar', '+919000007003', 1) returning id into d;
  perform t.as_user(t.u('02'));
  perform app.submit_farmer(d);
  perform t.fails(format('select app.verify_farmer(%L)', d), 'another person', 'farmers: step 2 is never by the person of step 1');
  perform t.as_service();
  delete from public.assignments where id = a;
exception when others then
  perform t.as_service();
  raise;
end $$;

-- 4 · clients, crops, scopes, rosters, assignments ----------------------------------------------------------------------------
do $$
declare n int; s uuid; cr uuid; r jsonb; other uuid;
begin
  -- clients: the State Manager's (tests/22 has the State Manager's side)
  perform t.as_user(t.u('01'));
  perform t.fails(format($q$ insert into public.clients (name, code, type, state_id) values ('Oversight Client', 'OVCL', 'fpo', %L) $q$,
                  (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201')),
                  'row-level security', 'clients: the admin creates none');
  update public.clients set name = 'Renamed by the admin' where id = '00000000-0000-4000-8000-000000000201';
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'clients: nor renames one');
  -- crops: the State Manager's now
  perform t.as_user(t.u('01'));
  perform t.fails($q$ insert into public.crops (name, code, primary_unit) values ('Admin Crop', 'ADMC', 'kg') $q$,
                  'row-level security', 'crops: the admin creates none');
  update public.crops set gi_tag = 'changed' where code = 'KNM';
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'crops: nor edits one (limits, stages)');
  perform t.as_user(t.u('03'));
  perform t.fails($q$ insert into public.crops (name, code, primary_unit) values ('CM Crop', 'CMCR', 'kg') $q$,
                  'row-level security', 'crops: nor a Client Manager');
  perform t.as_user(t.u('02'));
  insert into public.crops (name, code, primary_unit, quality_params, allowed_stages)
  values ('Makhana', 'MKHN', 'kg', '[{"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":14,"export_limit":12.5}]', '{milling}')
  returning id into cr;
  update public.crops set gi_tag = 'GI 666' where id = cr;
  perform t.ok((select gi_tag from public.crops where id = cr) = 'GI 666', 'control: the State Manager creates and edits a crop');

  -- scopes
  perform t.as_user(t.u('01'));
  perform t.fails(format($q$ insert into public.scopes (client_id, crop_id, state_id, season_code, geography, chain)
      values ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000101', %L, 'KH26', 'Admin scope', '{procurement,qc,qr_activation}') $q$,
      (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201')),
      'row-level security', 'scopes: the admin creates none');
  update public.scopes set geography = 'Renamed by the admin' where id = t.scope('01');
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'scopes: nor changes one (chain, activation)');
  perform t.fails(format($q$ insert into public.slot_assignments (user_id, scope_id, stage_type) values (%L, %L, 'procurement') $q$, t.u('18'), t.scope('01')),
                  'row-level security', 'roster: the admin puts nobody on a stage directly');

  -- assignments: the admin seats State Managers and nothing else
  perform t.fails(format('select app.assign(%L, %L, %L, %L, %L)', t.u('18'), 'scope', t.scope('01'), 'operator', '{procurement}'),
                  'outside what you manage', 'assign: the admin gives no scope assignment');
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('18'), 'client', '00000000-0000-4000-8000-000000000201', 'client_account'),
                  'outside what you manage', 'assign: nor a client''s account (the State Manager''s)');
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('01'), 'state', (select id from public.states order by name limit 1), 'state_supervisor'),
                  'outside what you manage', 'assign: the admin cannot seat himself (he gives nothing at all)');
  -- migration 35: the State Manager seat is the HR Admin's to give (Veda, 10 Oct); the admin gives nothing
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('18'), 'state', (select id from public.states order by name limit 1), 'state_supervisor'),
                  'outside what you manage', 'assign: the admin no longer seats a State Manager (migration 35)');
  perform t.as_service();
  other := (select id from public.states where id <> (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201') order by name limit 1);
  perform t.as_user(t.u('16'));
  r := app.assign(t.u('18'), 'state', other, 'state_supervisor');
  perform t.ok(r->'assignment'->>'lens' = 'state', 'control: the HR Admin seats a State Manager (the state lens)');
  perform t.as_service();
exception when others then
  perform t.as_service();
  raise;
end $$;

-- nobody gives an admin an assignment; one held from before grants nothing
do $$
declare a uuid; n int;
begin
  perform t.as_user(t.u('02'));
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('01'), 'client', '00000000-0000-4000-8000-000000000201', 'client_account'),
                  'holds no assignment', 'assign: a State Manager cannot give the admin an assignment either');
  perform t.as_service();
  perform set_config('app.assigning', 'on', true);
  insert into public.assignments (employee_id, lens, op_role, scope_id, stages) values (t.u('01'), 'scope', 'operator', t.scope('01'), '{procurement}') returning id into a;
  insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (t.u('01'), t.scope('01'), 'procurement', a);
  perform set_config('app.assigning', '', true);
  perform t.ok(not app.is_my_stage(t.u('01'), t.scope('01'), 'procurement') and not app.has_slot(t.u('01'), t.scope('01'), 'procurement'),
               'an assignment the admin holds (made before this rule) grants nothing');
  insert into public.assignments (employee_id, lens, op_role, state_id)
  values (t.u('01'), 'state', 'state_supervisor', (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201'));
  perform t.as_user(t.u('01'));
  perform t.ok(cardinality(app.my_state_ids()) = 0 and not app.i_verify_farmers('00000000-0000-4000-8000-000000000201'),
               'nor a state the admin holds: the admin is no State Manager by it');
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Through a state', 'THST', 'fpo',
                      (select state_id from public.clients where id = '00000000-0000-4000-8000-000000000201')) $q$,
                  'row-level security', 'and makes no client through it');
  perform t.as_service();
  perform set_config('app.assigning', 'on', true);
  perform t.as_user(t.u('01'));
  perform t.fails(format($q$ insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
      values (%L, '00000000-0000-4000-8000-000000000201', 'procurement', %L, %L,
              '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') $q$, t.scope('01'), t.farmer('01'), t.u('01')),
      'may not create', 'with it the admin still records nothing');
  perform t.as_service();
end $$;

-- 5 · HR: the admin's while the HR Admin seat is empty; HR's once it is filled -------------------------------------------
do $$
declare r jsonb; j jsonb := jsonb_build_object('full_name', 'Oversight Joiner', 'personal_email', 'oversight.joiner@test.in', 'join_date', app.today()::text);
        n int;
begin
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.add_joiner(%L)', j), 'HR adds joiners', 'HR: with the seat filled the admin adds no joiner');
  perform t.fails(format('select app.suspend_person(%L, %L)', t.u('18'), 'test'), 'not', 'HR: nor suspends an employee');
  perform t.fails(format('select app.activate_joiner(%L)', t.u('19')), 'only HR marks', 'HR: nor marks a joiner as joined');
  perform t.ok(app.reset_login_allowed(t.u('16')) and not app.reset_login_allowed(t.u('18')), 'HR: the admin still resets the HR Admin, not an employee');
  insert into public.onboarding_templates (name) values ('Admin template');
  get diagnostics n = row_count;
  perform t.ok(false, 'HR: the admin writes no checklist template (row was accepted)');
exception
  when sqlstate 'P0001' then raise;
  when others then
    perform t.ok(sqlerrm ~ 'row-level security|permission', 'HR: the admin writes no checklist template (refused: ' || left(sqlerrm, 60) || ')');
    perform t.as_user(t.u('17'));
    r := app.add_joiner(j);
    perform t.ok(r is not null, 'control: HR adds the joiner');
    perform t.as_service();
end $$;

do $$
declare r jsonb; j jsonb := jsonb_build_object('full_name', 'Vacant Seat Joiner', 'personal_email', 'vacant.seat@test.in', 'join_date', app.today()::text);
begin
  -- the HR Admin away (suspended): the seat is empty, HR falls back to the admin
  update public.app_users set status = 'suspended', active = false where id = t.u('16');
  perform t.as_user(t.u('01'));
  perform t.ok((app.my_context()->'user'->'can'->>'hr')::boolean, 'HR: with the seat empty the admin has HR on the menu again');
  perform t.fails(format('select app.add_joiner(%L)', j), 'only the person for the HR Admin seat',
                  'HR: with the seat empty the admin still adds no operational person (migration 35)');
  r := app.add_joiner(j || jsonb_build_object('system_role', 'hr_resource'));
  perform t.ok(r is not null, 'HR: with the seat empty the admin adds the person for the HR Admin seat');
  perform t.as_service();
  update public.app_users set status = 'active', active = true where id = t.u('16');
end $$;

-- 6 · the dashboard and the whole ledger: the admin's, and nobody else's ---------------------------------------------------
do $$
declare o jsonb; l jsonb; total bigint;
begin
  perform t.as_user(t.u('01'));
  o := app.platform_overview();
  perform t.as_service();
  perform t.ok((o->'clients'->>'total')::int = (select count(*) from public.clients)
               and (o->'clients'->>'active')::int + (o->'clients'->>'dormant')::int = (select count(*) from public.clients),
               'overview: clients = active + dormant = every client');
  perform t.ok((o->'scopes'->>'active')::int = (select count(*) from public.scopes where status = 'active')
               and (o->'scopes'->>'qr_issued')::int = (select count(*) from public.qr_seals),
               'overview: active scopes and QR codes issued, as counted in the tables');
  perform t.ok((o->'attention'->>'open_flags')::int = (select count(*) from public.flags where status = 'open')
               and (o->'attention'->>'unstaffed')::int = jsonb_array_length(o->'attention'->'unstaffed_list'),
               'overview: open flags; the number of stages with nobody equals the stages it names');
  perform t.ok(not exists (select 1 from jsonb_array_elements(o->'attention'->'unstaffed_list') g
                            where (g->>'client_id')::uuid is distinct from (select s.client_id from public.scopes s where s.id = (g->>'scope_id')::uuid)),
               'overview: each stage with nobody names its client by id (a client card shows its own)');
  perform t.ok((select sum((c->>'scopes_total')::int) from jsonb_array_elements(o->'clients'->'list') c) = (select count(*) from public.scopes),
               'overview: the client cards add up to every scope');
  perform t.ok(round((select sum((c->>'kg')::numeric) from jsonb_array_elements(o->'clients'->'list') c), 3)
               = round(coalesce((select sum(qty_out) from public.footprints where stage_type in ('procurement', 'lot_inward') and status <> 'superseded'), 0), 3),
               'overview: volume procured on the cards = the entry stages'' quantity out');
  perform t.ok((o->'setup'->>'hr_admin')::boolean and (o->'setup'->>'states')::int = (select count(*) from public.states),
               'overview: the setup checklist reads the seat and the states');

  perform t.as_user(t.u('01'));
  l := app.ledger_page();
  perform t.as_service();
  total := (select count(*) from public.ledger);
  perform t.ok((l->>'total')::bigint = total and jsonb_array_length(l->'rows') = least(total, 100), 'ledger: every block is counted, one page of 100');
  perform t.ok((l->'rows'->0->>'seq')::bigint = (select max(seq) from public.ledger), 'ledger: newest first');
  perform t.as_user(t.u('01'));
  l := app.ledger_page('verify');
  perform t.as_service();
  perform t.ok((l->>'total')::bigint = (select count(*) from public.ledger where event = 'verify'), 'ledger: filter by event');
  perform t.as_user(t.u('01'));
  l := app.ledger_page(null, null, null, null, true);
  perform t.as_service();
  perform t.ok((l->>'total')::bigint = (select count(*) from public.ledger where event = 'supervisory' and footprint_id is not null),
               'ledger: "manager acts on records" only');
  perform t.as_user(t.u('01'));
  l := app.ledger_page(null, null, t.scope('01'), null, false, 5, 0);
  perform t.as_service();
  perform t.ok(jsonb_array_length(l->'rows') <= 5 and (l->>'total')::bigint
               = (select count(*) from public.ledger lg left join public.footprints f on f.id = lg.footprint_id where coalesce(lg.scope_id, f.scope_id) = t.scope('01')),
               'ledger: filter by scope, with a page size');
  perform t.as_user(t.u('02'));
  perform t.fails('select app.platform_overview()', 'for the admin', 'overview: a State Manager does not get it');
  perform t.fails('select app.ledger_page()', 'for the admin', 'ledger: nor the whole ledger');
  perform t.as_user(t.u('16'));
  perform t.fails('select app.ledger_page()', 'for the admin', 'ledger: nor the HR Admin');
  perform t.as_service();
end $$;

-- 7 · what stays the admin's ---------------------------------------------------------------------------------------------------
do $$
declare s uuid;
begin
  perform t.as_user(t.u('01'));
  insert into public.states (name, code) values ('Bihar', 'BR') returning id into s;
  perform t.ok(s is not null, 'kept: the admin creates a state');
  perform t.ok((app.check_ledger_now()).ok, 'kept: the admin runs the ledger check');
  perform t.as_service();
end $$;

select t.ok(not exists (select 1 from app.verify_ledger()), 'the ledger chain still verifies after all of the above');
rollback;
