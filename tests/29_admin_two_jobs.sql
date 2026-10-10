-- Migration 35 · THE ADMIN HAS TWO JOBS (Veda, 10 Oct 2026): states, and the HR Admin seat. No override.
-- The State Manager seat is the HR Admin's. The admin sees people as numbers, not HR files. The public page says
-- whether every step was recorded and checked by different people.
-- Demo people: 01 admin · 02 State Manager (UP) · 03 Client Manager · 05 procurement · 06 QC · 07 QR · 16 HR Admin ·
-- 17 HR resource · 18 employee nobody has assigned · 19 joiner.
begin;
select t.as_service();

-- 1 · joiners and system roles ----------------------------------------------------------------------------------------------
do $$
declare j jsonb := jsonb_build_object('full_name', 'Two Jobs Joiner', 'personal_email', 'two.jobs@test.in', 'phone', '9876500070', 'join_date', app.today()::text);
        r jsonb;
begin
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.add_joiner(%L)', j || '{"system_role":"hr_resource"}'), 'only HR adds joiners now',
                  'joiners: with the HR Admin seat filled the admin adds nobody, not even an HR person');
  perform t.fails(format('select app.add_joiner(%L)', j || '{"system_role":"admin"}'), 'made only by the database owner',
                  'joiners: nobody adds an admin in the app (the admin neither)');
  perform t.fails(format('select app.set_system_role(%L, %L)', t.u('18'), 'hr_resource'), 'cannot give this system role',
                  'roles: the admin changes no system role while the seat is filled');
  perform t.as_user(t.u('16'));
  perform t.fails(format('select app.add_joiner(%L)', j || '{"system_role":"admin"}'), 'made only by the database owner',
                  'joiners: the HR Admin adds no admin');
  perform app.set_system_role(t.u('18'), 'hr_resource');
  perform app.set_system_role(t.u('18'), 'operational');
  perform t.ok((select system_role = 'operational' from public.app_users where id = t.u('18')), 'control: the HR Admin moves a person operational ↔ HR');
  r := app.add_joiner(j);
  perform t.ok(r is not null, 'control: the HR Admin adds an operational joiner');
  perform t.as_service();
end $$;

-- the seat empty (HR Admin away): the admin brings in the HR person, and only that person
do $$
declare j jsonb := jsonb_build_object('full_name', 'Seat Candidate', 'personal_email', 'seat.candidate@test.in', 'phone', '9876500071', 'join_date', app.today()::text);
        r jsonb;
begin
  update public.app_users set status = 'suspended', active = false where id = t.u('16');
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.add_joiner(%L)', j), 'only the person for the HR Admin seat',
                  'joiners: with the seat empty the admin still adds no operational person');
  perform t.fails(format('select app.add_joiner(%L)', j || '{"system_role":"admin"}'), 'made only by the database owner',
                  'joiners: nor an admin');
  r := app.add_joiner(j || '{"system_role":"hr_resource"}');
  perform t.ok(r is not null, 'control: with the seat empty the admin adds the person for the HR Admin seat');
  -- migration 36: the admin marks as joined only the HR Admin seat holder (tests/30_hr_admin_joined.sql), not this person yet
  perform t.fails(format('select app.activate_joiner(%L)', r->>'id'), 'only HR marks',
                  'joiners: but marks that person as joined only once she holds the HR Admin seat (migration 36)');
  perform t.as_service();
  update public.app_users set status = 'active', active = true where id = t.u('16');
end $$;

-- 2 · the State Manager seat: the HR Admin's -------------------------------------------------------------------------------
do $$
declare st uuid; r jsonb;
begin
  st := (select id from public.states order by name limit 1);
  perform t.as_user(t.u('01'));
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('18'), 'state', st, 'state_supervisor'), 'outside what you manage',
                  'seat: refused by the server, not only hidden');
  perform t.as_user(t.u('17'));
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('18'), 'state', st, 'state_supervisor'), 'outside what you manage',
                  'seat: nor an HR resource');
  perform t.as_user(t.u('16'));
  perform t.ok((app.my_context()->'user'->'can'->>'state_seat')::boolean, 'seat: the app is told the HR Admin seats State Managers');
  perform t.fails(format('select app.assign(%L, %L, %L, %L)', t.u('18'), 'client', '00000000-0000-4000-8000-000000000201', 'client_account'),
                  'outside what you manage', 'seat: the HR Admin gives nothing else (a client''s account stays the State Manager''s)');
  r := app.assign(t.u('18'), 'state', st, 'state_supervisor');
  perform t.ok(r->'assignment'->>'lens' = 'state', 'control: the HR Admin seats a State Manager');
  perform t.ok((app.employee_profile(t.u('19'))->'can'->>'assign')::boolean, 'seat: the HR Admin''s profile view offers Assign');
  perform t.as_user(t.u('01'));
  perform t.ok(not (app.employee_profile(t.u('18'))->'can'->>'assign')::boolean, 'seat: the admin''s does not');
  perform t.as_service();
end $$;

-- 3 · HR acts and passwords --------------------------------------------------------------------------------------------------
do $$
declare p jsonb;
begin
  perform t.as_user(t.u('01'));
  perform t.ok(app.reset_login_allowed(t.u('16')), 'password: the admin resets the HR Admin''s (nobody else can)');
  perform t.ok(not app.reset_login_allowed(t.u('17')) and not app.reset_login_allowed(t.u('18')), 'password: not an HR person''s, not an employee''s');
  perform t.fails(format('select app.suspend_person(%L, %L)', t.u('16'), 'test'), 'not', 'HR acts: the admin no longer suspends the HR Admin (move the seat instead)');
  perform t.fails(format('select app.offboard_person(%L, %L, %L, %L, %L)', t.u('16'), current_date, 'x', '', ''), 'not',
                  'HR acts: nor offboards the HR Admin');
  p := app.employee_profile(t.u('16'));
  perform t.ok((p->'can'->>'reset_login')::boolean and not (p->'can'->>'suspend')::boolean and not (p->'can'->>'offboard')::boolean
               and not (p->'can'->>'hr_record')::boolean and not (p->'can'->>'set_role')::boolean,
               'HR acts: on the HR Admin''s page the admin is offered the password reset and nothing else');
  p := app.employee_profile(t.u('18'));
  perform t.ok(not (p->'can'->>'reset_login')::boolean and not (p->'can'->>'suspend')::boolean and not (p->'can'->>'hr_record')::boolean
               and jsonb_array_length(p->'exits') = 0, 'HR acts: on an employee''s page nothing, and no HR record or exit details');
  -- another admin (made outside the app, as break-glass does) gives a locked-out admin a new password; nobody else can
  perform t.as_service();
  update public.app_users set system_role = 'admin' where id = t.u('19');
  perform t.as_user(t.u('01'));
  perform t.ok(app.reset_login_allowed(t.u('19')), 'password: an admin resets another admin''s (My account says so)');
  perform t.fails(format('select app.suspend_person(%L, %L)', t.u('19'), 'test'), 'not', 'HR acts: but does not suspend another admin in the app');
  perform t.as_user(t.u('16'));
  perform t.ok(not app.reset_login_allowed(t.u('19')), 'password: the HR Admin cannot reset an admin''s');
  perform t.as_service();
  update public.app_users set system_role = 'operational' where id = t.u('19');
  perform t.as_user(t.u('16'));
  perform t.ok(not app.reset_login_allowed(t.u('01')), 'password: the HR Admin cannot reset the admin''s (no take-over of the admin seat)');
  perform t.as_user(t.u('17'));
  perform t.ok(not app.reset_login_allowed(t.u('01')) and not app.reset_login_allowed(t.u('16')), 'password: nor can an HR person (the admin''s or the HR Admin''s)');
  perform t.as_user(t.u('16'));
  perform t.ok((app.employee_profile(t.u('18'))->'can'->>'hr_record')::boolean and (app.employee_profile(t.u('18'))->'can'->>'suspend')::boolean,
               'control: the HR Admin is offered the HR record and Suspend');
  perform t.as_service();
end $$;

-- 4 · HR files: HR's; the admin only while the seat is empty --------------------------------------------------------------------
do $$
declare n_hr int; n_admin int; n_vacant int;
begin
  perform t.as_service();
  insert into public.employee_notes (employee_id, written_by, note) values (t.u('18'), t.u('16'), 'two jobs test note');
  perform t.as_user(t.u('16'));
  n_hr := (select count(*) from public.onboarding_tasks) + (select count(*) from public.employee_notes);
  perform t.as_user(t.u('01'));
  n_admin := (select count(*) from public.onboarding_tasks where employee_id <> t.u('01')) + (select count(*) from public.employee_notes)
           + (select count(*) from public.employee_docs where employee_id <> t.u('01')) + (select count(*) from public.employee_exits)
           + (select count(*) from public.employee_files where employee_id <> t.u('01'));
  perform t.ok(n_hr > 0 and n_admin = 0, 'HR files: the HR Admin reads checklists and notes; the admin reads no one''s HR file (' || n_hr || ' / ' || n_admin || ')');
  perform t.fails(format('select app.joiner_detail(%L)', t.u('19')), 'not found', 'HR files: nor a joiner''s page (as if there were none)');
  perform t.fails('select app.hr_pipeline()', 'only HR', 'HR files: nor the HR pipeline');
  perform t.as_service();
  update public.app_users set status = 'suspended', active = false where id = t.u('16');
  perform t.as_user(t.u('01'));
  n_vacant := (select count(*) from public.onboarding_tasks where employee_id <> t.u('01')) + (select count(*) from public.employee_notes);
  perform t.ok(n_vacant > 0, 'HR files: with the seat empty the admin reads them (to bring the HR person in)');
  perform t.as_service();
  update public.app_users set status = 'active', active = true where id = t.u('16');
end $$;

-- 5 · the dashboard: people as numbers, pipeline in chain order, trends --------------------------------------------------------
do $$
declare o jsonb; tr jsonb; pos jsonb;
begin
  perform t.as_user(t.u('01'));
  o := app.platform_overview();
  perform t.as_service();
  perform t.ok((o->'people'->>'joining')::int = (select count(*) from public.app_users where not external and status in ('invited', 'onboarding'))
               and (o->'people'->>'state_managers')::int = (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                                                              where a.active and a.lens = 'state' and u.status = 'active')
               and (o->'people'->'by_role'->>'admin')::int = (select count(*) from public.app_users where system_role = 'admin' and status <> 'offboarded' and not external),
               'overview: people as numbers, counted from the tables');
  perform t.ok(not (o->'people')::text ~ '(@|email|phone|pan|aadhaar)', 'overview: no name, email or number of a person in the people block');
  perform t.as_user(t.u('01'));
  tr := app.admin_trends(12);
  perform t.as_service();
  perform t.ok(jsonb_array_length(tr->'weeks') = 12, 'trends: twelve weeks');
  perform t.ok(round((select sum((c->>'total')::numeric) from jsonb_array_elements(tr->'kg_by_crop') c), 3)
               = round(coalesce((select sum(qty_out) from public.footprints where stage_type in ('procurement', 'lot_inward') and status <> 'superseded'), 0), 3),
               'trends: the crops'' volumes add up to everything procured');
  perform t.ok((select sum((w->>'qr')::int) from jsonb_array_elements(tr->'weeks') w) <= (select count(*) from public.qr_seals),
               'trends: QR codes per week never more than issued');
  perform t.as_user(t.u('16'));
  perform t.fails('select app.admin_trends(12)', 'for the admin', 'trends: for the admin only');
  perform t.as_service();
end $$;

-- 6 · the public page tells the truth about who checked the lot --------------------------------------------------------------
do $$
declare p uuid; q uuid; qr uuid; seal public.qr_seals; j jsonb;
begin
  -- a lot recorded and checked by different people at every step
  p := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2},"lab_ref":"LAB-29"}')
  returning id into q;
  perform t.verify(q, t.u('07'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr, t.u('07'));
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok((j->>'independent')::boolean, 'public page: a lot handled by different people at every step says so');
  perform t.ok(position(t.u('06')::text in j::text) = 0, 'public page: no person''s id is sent with it');
  perform t.as_service();

  -- the same chain where a manager recorded the first step without holding it (a supervisory act)
  p := t.procure_as(t.scope('01'), t.farmer('02'), t.u('03'));
  perform t.ok((select event from public.ledger where footprint_id = p order by seq limit 1) = 'supervisory', 'setup: the manager''s record is a supervisory block');
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          jsonb_build_object('qty_kg', (select qty_out from public.footprints where id = p), 'sample_qty_kg', 0.5,
                             'readings', '{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}'::jsonb, 'lab_ref', 'LAB-29b'))
  returning id into q;
  perform t.verify(q, t.u('07'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr, t.u('07'));
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok(not (j->>'independent')::boolean, 'public page: a lot with a supervisory step does not claim each step was checked by the next person');
  perform t.as_service();

  -- the case reported on staging (GV-9DB7C336D205, before migration 34): one person recorded two steps in a row
  -- (here the procurement person also holds QC on this scope; on staging it was the admin, who then could do every stage)
  insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id)
  select t.u('05'), t.scope('01'), 'qc', a.id from public.assignments a where a.employee_id = t.u('05') and a.scope_id = t.scope('01') and a.active;
  p := t.procure(t.scope('01'), t.farmer('02'), 120, 1, 2.5, 11.9, 11.8, 12.0);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, (select created_by from public.footprints where id = p),
          jsonb_build_object('qty_kg', (select qty_out from public.footprints where id = p), 'sample_qty_kg', 0.5,
                             'readings', '{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}'::jsonb, 'lab_ref', 'LAB-29c'))
  returning id into q;
  perform t.verify(q, t.u('07'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr, t.u('07'));
  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  perform t.ok(not (j->>'independent')::boolean, 'public page: a lot where one person recorded two steps in a row does not claim the next person checked it');
  perform t.as_service();
end $$;

-- 7 · the pipeline, now that there are records: chain order, verified quantity --------------------------------------------
do $$
declare o jsonb; pos jsonb;
begin
  perform t.as_user(t.u('01'));
  o := app.platform_overview();
  perform t.as_service();
  select jsonb_agg(p->>'stage_type' order by ord) into pos from jsonb_array_elements(o->'pipeline') with ordinality as x(p, ord);
  perform t.ok(jsonb_array_length(o->'pipeline') >= 5
               and (select bool_and((a->>'position')::numeric <= (b->>'position')::numeric)
                      from jsonb_array_elements(o->'pipeline') with ordinality x(a, i)
                      join jsonb_array_elements(o->'pipeline') with ordinality y(b, k) on k = i + 1),
               'pipeline: rows ordered by their place in the chains, not by the registry (' || pos::text || ')');
  perform t.ok((pos->>0) = 'procurement' and (pos->>(jsonb_array_length(pos) - 1)) = 'qr_activation', 'pipeline: the entry stage first, the seal last');
  -- the demo chains put Quality Control before Milling and Packing; the registry has Milling (40) and Packing (120)
  -- before QC (130), which is what the overview showed on 10 Oct
  perform t.ok((select ord from jsonb_array_elements_text(pos) with ordinality x(st, ord) where st = 'qc')
               < (select ord from jsonb_array_elements_text(pos) with ordinality x(st, ord) where st = 'milling')
               and (select ord from jsonb_array_elements_text(pos) with ordinality x(st, ord) where st = 'qc')
               < (select ord from jsonb_array_elements_text(pos) with ordinality x(st, ord) where st = 'packing'),
               'pipeline: Quality Control before Milling and Packing, as in the chains (not the registry order)');
  perform t.ok((select bool_and(p ? 'kg_done') from jsonb_array_elements(o->'pipeline') p)
               and (select (p->>'kg_done')::numeric > 0 from jsonb_array_elements(o->'pipeline') p where p->>'stage_type' = 'procurement'),
               'pipeline: verified quantity per stage');
end $$;

-- 8 · "Report a problem" (Help page): a person's own report lands in the list the admin reads on Health ----------------
select t.as_user(t.u('05'));   -- an operator
select t.ok(app.report_client_error('report', 'The milling screen shows the wrong lot', null, '/help?x=1', 'dev', true, 'test'),
            'help: an operator reports a problem');
select t.ok(not app.report_client_error('report', '   ', null, '/help', 'dev', true, 'test'), 'help: an empty report is not stored');
select t.as_user(t.u('01'));
select t.ok((select kind = 'report' and path = '/help' and role = 'operator' from public.client_errors
              where message = 'The milling screen shows the wrong lot'),
            'help: the admin reads it as a report (not an error), the query string left out');
select t.as_service();

select t.ok((select count(*) from app.verify_ledger()) = 0, 'the ledger chain still verifies');
rollback;
