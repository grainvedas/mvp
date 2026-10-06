-- Migration 33: the joiner's checklist. Who ticks what, what each task needs, what is kept of identity numbers
-- (the last four characters only), who reads HR records, and how a joiner becomes active.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.today() returns date language sql stable security definer as $$ select app.today() $$;
create or replace function pg_temp.task(p_emp uuid, p_code text) returns uuid language sql stable security definer as $$
  select id from public.onboarding_tasks where employee_id = p_emp and code = p_code $$;
create or replace function pg_temp.status_of(p uuid) returns text language sql stable security definer as $$ select status::text from public.app_users where id = p $$;
create or replace function pg_temp.docs_of(p uuid) returns public.employee_docs language sql stable security definer as $$ select * from public.employee_docs where employee_id = p $$;

select t.as_user(t.u('17'));
insert into fx (k, j) values ('j', app.add_joiner(jsonb_build_object('full_name', 'Nisha New', 'personal_email', 'nisha@test.in',
  'join_date', (pg_temp.today() + 7)::text, 'employment_type', 'full_time', 'job_title', 'QC Associate', 'reports_to', t.u('03')::text)));
update fx set id = (j->>'id')::uuid where k = 'j';
select t.as_service();
update public.app_users set auth_uid = id where id = pg_temp.f('j');          -- the login the server function would make

-- 1 · first sign-in ---------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('j'));
select t.ok((app.my_context()->'user'->>'status') = 'invited' and (app.my_context()->'onboarding'->>'total')::int = 8
            and jsonb_array_length(app.my_context()->'scopes') = 0,
            'invited: the joiner can sign in; my_context shows a checklist and no scope');
select t.ok(app.mark_first_login() = 'onboarding' and app.mark_first_login() = 'onboarding', 'first sign-in: invited becomes onboarding (asking twice changes nothing more)');
select t.ok((app.my_onboarding()->>'days_to_join')::int = 7 and jsonb_array_length(app.my_onboarding()->'tasks') = 8
            and (app.my_onboarding()->'org'->>'job_title') = 'QC Associate' and (app.my_onboarding()->'reports_to'->>'name') = 'Prasaadam Client Manager'
            and (select count(*) from jsonb_array_elements(app.my_onboarding()->'tasks') x where x->>'owner' = 'hire') = 4,
            'my checklist: countdown, eight tasks (four of them mine), my job and who I report to');

-- 2 · the hire's own tasks -----------------------------------------------------------------------------------------------------
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('j'), 'offer_nda')), 'tick the box', 'sign: must be acknowledged');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'offer_nda'), '{"acknowledged":true}')->>'open')::int = 7, 'sign: acknowledged, done');
select t.fails(format($q$ select app.complete_task(%L, '{"acknowledged":true}') $q$, pg_temp.task(pg_temp.f('j'), 'offer_nda')), 'already done', 'a task is done once');

select t.fails(format($q$ select app.complete_task(%L, '{"pan_last4":"ABCDE1234F"}') $q$, pg_temp.task(pg_temp.f('j'), 'identity')),
               'last four characters only', 'identity: a full PAN is refused, not cut and stored');
select t.fails(format($q$ select app.complete_task(%L, '{"aadhaar_last4":"123412341234"}') $q$, pg_temp.task(pg_temp.f('j'), 'identity')),
               'last four digits only', 'identity: so is a full Aadhaar number');
select t.fails(format($q$ select app.complete_task(%L, '{"pan_last4":"234F"}') $q$, pg_temp.task(pg_temp.f('j'), 'identity')),
               'attach a photo or scan', 'identity: the card itself must be attached first');
select t.fails(format($q$ select app.register_hr_file(%L, 'pan', %L, %L, 'pan.jpg') $q$, t.u('06'), t.u('06')::text || '/pan.jpg', repeat('a', 64)),
               'not allowed to add a document', 'documents: nobody files a document under another person');
select t.fails(format($q$ select app.register_hr_file(%L, 'pan', %L, %L, 'pan.jpg') $q$, pg_temp.f('j'), t.u('06')::text || '/pan.jpg', repeat('a', 64)),
               '<person>/<file>', 'documents: nor into another person''s folder');
select t.ok(app.register_hr_file(pg_temp.f('j'), 'pan', pg_temp.f('j')::text || '/pan.jpg', repeat('a', 64), 'pan.jpg', pg_temp.task(pg_temp.f('j'), 'identity')) is not null,
            'documents: the joiner registers a file in their own folder');
-- the store itself (migration 32, bucket hr-docs): a person puts a file into their own folder and cannot open it again
insert into storage.objects (bucket_id, name) values ('hr-docs', pg_temp.f('j')::text || '/pan.jpg');
select t.ok(true, 'store: the joiner uploads into their own folder');
select t.fails(format($q$ insert into storage.objects (bucket_id, name) values ('hr-docs', %L) $q$, t.u('06')::text || '/pan.jpg'),
               'row-level security', 'store: not into another person''s folder');
select t.ok((select count(*) from storage.objects where bucket_id = 'hr-docs') = 0, 'store: the uploader cannot open the file again');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'identity'), '{"pan_last4":"234f","aadhaar_last4":"9012"}')->>'open')::int = 6, 'identity: done');
select t.ok((select pan_last4 = '234F' and aadhaar_last4 = '9012' from pg_temp.docs_of(pg_temp.f('j'))), 'identity: the last four characters are what is kept');

select t.fails(format($q$ select app.complete_task(%L, '{"bank_name":"State Bank","bank_ifsc":"SBIN123","bank_last4":"4321"}') $q$, pg_temp.task(pg_temp.f('j'), 'bank')),
               'IFSC looks wrong', 'bank: a malformed IFSC is refused');
select t.fails(format($q$ select app.complete_task(%L, '{"bank_name":"State Bank","bank_ifsc":"SBIN0001234","bank_last4":"00112233445"}') $q$, pg_temp.task(pg_temp.f('j'), 'bank')),
               'last four digits only', 'bank: a full account number is refused');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'bank'), '{"bank_name":"State Bank","bank_ifsc":"sbin0001234","bank_last4":"4321"}')->>'open')::int = 5, 'bank: done');
select t.fails(format($q$ select app.complete_task(%L, '{"gratuity_nominee":"Asha Devi"}') $q$, pg_temp.task(pg_temp.f('j'), 'pf_gratuity')),
               'name and relation', 'nomination: needs the nominee and the relation');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'pf_gratuity'), '{"gratuity_nominee":"Asha Devi","nominee_relation":"Mother","pf_uan_last4":"7788"}')->>'open')::int = 4, 'nomination: done');

-- HR's and IT's tasks are not the hire's to tick
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('j'), 'countersign')), 'not yours to complete', 'the hire cannot tick an HR task');
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('j'), 'it_setup')), 'not yours to complete', 'nor an IT task');
select t.fails(format($q$ select app.activate_joiner(%L) $q$, pg_temp.f('j')), 'only HR marks', 'nor mark themselves as joined');
-- and nobody else's checklist is theirs
select t.fails(format($q$ select app.complete_task(%L, '{"acknowledged":true}') $q$, pg_temp.task(t.u('19'), 'identity')), 'not yours to complete', 'nor touch another joiner''s task');
select t.ok((select count(*) from public.onboarding_tasks) = 8 and (select count(*) from public.employee_docs) = 1 and (select count(*) from public.employee_files) = 1,
            'privacy: a joiner reads their own tasks, details and file list, and nobody else''s');
select t.ok((select count(*) from public.employee_notes) = 0 and (select count(*) from public.audit_log) = 0, 'privacy: no HR notes, no audit log');

-- 3 · what others may read ----------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));   -- a manager who assigns: sees the person and the org facts, never the HR record
select t.ok((select count(*) from storage.objects where bucket_id = 'hr-docs') = 0, 'privacy: a manager cannot open a document in the store');
select t.ok((select count(*) from public.app_users where id = pg_temp.f('j')) = 1 and (select count(*) from public.employee_org where employee_id = pg_temp.f('j')) = 1,
            'privacy: a manager sees the joiner in the pool, with the org facts');
select t.ok((select count(*) from public.employee_docs) = 0 and (select count(*) from public.employee_files) = 0 and (select count(*) from public.onboarding_tasks) = 0
            and (select count(*) from public.employee_notes) = 0,
            'privacy: but no identity details, no documents, no checklist, no HR notes');
select t.fails(format($q$ select app.joiner_detail(%L) $q$, pg_temp.f('j')), 'person not found', 'privacy: nor the joiner page');
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('j'), 'countersign')), 'not yours to complete', 'privacy: nor tick anything');
select t.as_user(t.u('05'));   -- a colleague
select t.ok((select count(*) from storage.objects where bucket_id = 'hr-docs') = 0, 'privacy: nor can a colleague');
select t.ok((select count(*) from public.app_users where id = pg_temp.f('j')) = 0 and (select count(*) from public.employee_org where employee_id = pg_temp.f('j')) = 0 and (select count(*) from public.employee_docs) = 0,
            'privacy: a colleague sees nothing of the joiner at all');

-- 4 · HR's side ----------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.ok((select count(*) from storage.objects where bucket_id = 'hr-docs') = 1, 'store: HR opens the document');
select t.ok((select (p->>'pct')::int = 50 and p->>'blocked_by' = 'hr' and p->>'next_task' = 'Countersign contract & NDA' and (p->>'days_to_join')::int = 7
               from jsonb_array_elements(app.hr_pipeline()) p where p->>'id' = pg_temp.f('j')::text),
            'pipeline: four of eight done is 50 %, and the next step is waiting on HR');
select t.ok((select p->>'blocked_by' = 'hire' from jsonb_array_elements(app.hr_pipeline()) p where p->>'id' = t.u('19')::text),
            'pipeline: the seeded joiner is waiting on herself');
select t.ok((app.joiner_detail(pg_temp.f('j'))->'docs'->>'pan_last4') = '234F' and jsonb_array_length(app.joiner_detail(pg_temp.f('j'))->'files') = 1
            and (app.joiner_detail(pg_temp.f('j'))->'person'->>'created_by') = 'Imran (HR)',
            'joiner page: HR reads the masked details and the file list');
select app.add_hr_note(pg_temp.f('j'), 'Laptop to be couriered to Gorakhpur');
select t.ok((app.joiner_detail(pg_temp.f('j'))->'notes'->0->>'note') like 'Laptop%', 'joiner page: HR notes are kept');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'countersign'), '{"note":"signed by Asha"}')->>'open')::int = 3, 'HR ticks its own task');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'it_setup'), '{}')->>'open')::int = 2, 'and IT''s, on IT''s behalf');
select t.fails(format($q$ select app.complete_task(%L, '{}') $q$, pg_temp.task(pg_temp.f('j'), 'buddy')), 'choose the buddy', 'buddy: someone must be chosen');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('j'), 'buddy'), jsonb_build_object('buddy', t.u('06')))->>'open')::int = 1, 'buddy: chosen, done');
select t.fails(format($q$ select app.complete_task(%L, '{"goals":[{"horizon":30,"goal":"Shadow two QC runs"}]}') $q$, pg_temp.task(pg_temp.f('j'), 'goals')),
               '30, 60 and 90', 'goals: one for each of 30, 60 and 90 days');
select t.ok(pg_temp.status_of(pg_temp.f('j')) = 'onboarding', 'still onboarding while a task is open');
insert into fx (k, j) values ('last', app.complete_task(pg_temp.task(pg_temp.f('j'), 'goals'),
  '{"goals":[{"horizon":30,"goal":"Shadow two QC runs"},{"horizon":60,"goal":"Run QC alone"},{"horizon":90,"goal":"Train the next joiner"}]}'));
select t.ok((select (j->>'open')::int = 0 and j->>'status' = 'active' from fx where k = 'last'), 'checklist complete: the joiner is ACTIVE without anyone pressing a button');
select t.as_service();
select t.ok((select count(*) from public.audit_log where target = pg_temp.f('j') and action = 'activated' and detail->>'how' = 'checklist complete') = 1
            and (select count(*) from public.audit_log where target = pg_temp.f('j') and action = 'first_login') = 1,
            'audit: first sign-in and activation are on record');
select t.as_user(pg_temp.f('j'));
select t.ok((app.my_onboarding()->'buddy'->>'name') = 'QC Technician' and jsonb_array_length(app.my_onboarding()->'goals') = 3,
            'day one: the joiner reads who their buddy is and their 30-60-90 goals');

-- 5 · reopening, moving the join date, activating early -------------------------------------------------------------------------------
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.reopen_task(%L, '') $q$, pg_temp.task(pg_temp.f('j'), 'bank')), 'reason is required', 'reopen: needs a reason');
select app.reopen_task(pg_temp.task(pg_temp.f('j'), 'bank'), 'account closed');
select t.ok((select x->>'status' = 'pending' and x->>'note' = 'reopened: account closed' from jsonb_array_elements(app.joiner_detail(pg_temp.f('j'))->'tasks') x where x->>'code' = 'bank')
            and pg_temp.status_of(pg_temp.f('j')) = 'active', 'reopen: the task is open again; the person stays active');
select t.ok((select count(*) from jsonb_array_elements(app.hr_pipeline()) p where p->>'id' = pg_temp.f('j')::text) = 1, 'reopen: and is back in the pipeline');

select app.update_joiner(t.u('19'), jsonb_build_object('join_date', (pg_temp.today() + 15)::text, 'job_title', 'Senior Quality Associate'));
select t.ok((select (x->>'due_on')::date = pg_temp.today() + 8 from jsonb_array_elements(app.joiner_detail(t.u('19'))->'tasks') x where x->>'code' = 'identity')
            and (app.joiner_detail(t.u('19'))->'org'->>'job_title') = 'Senior Quality Associate',
            'join date moved: the open tasks move with it (ten days later)');
select t.ok(app.activate_joiner(t.u('19')) = 'active', 'HR can mark a joiner as joined with tasks still open');
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('19')), 'active already', 'once');
select t.as_user(t.u('19'));
select t.ok((app.my_context()->'user'->>'status') = 'active' and (app.my_context()->'onboarding'->>'open')::int = 7, 'joined early: active, with seven tasks still on the list');

-- 6 · templates ----------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('17'));   -- an HR resource reads templates, does not change them
select t.ok((select count(*) from public.template_tasks) = 8, 'templates: HR reads the standard checklist');
update public.template_tasks set due_offset_days = 99 where code = 'goals';
select t.as_service();
select t.ok((select due_offset_days = 3 from public.template_tasks where code = 'goals'), 'templates: an HR resource cannot change it');
select t.as_user(t.u('16'));   -- the HR Admin can
update public.template_tasks set due_offset_days = 5 where code = 'goals';
insert into public.onboarding_templates (id, name) values ('00000000-0000-4000-8000-000000000902', 'Interns');
insert into public.template_tasks (template_id, seq, code, title, owner, due_offset_days, kind) values
  ('00000000-0000-4000-8000-000000000902', 1, 'offer_nda', 'Sign internship letter', 'hire', -3, 'sign'),
  ('00000000-0000-4000-8000-000000000902', 2, 'it_setup', 'Accounts', 'it', 0, 'it');
insert into fx (k, j) values ('i', app.add_joiner(jsonb_build_object('full_name', 'Short Intern', 'personal_email', 'short@test.in',
  'join_date', pg_temp.today()::text, 'employment_type', 'intern', 'template_id', '00000000-0000-4000-8000-000000000902')));
select t.as_service();
select t.ok((select due_offset_days = 5 from public.template_tasks where code = 'goals' and template_id = '00000000-0000-4000-8000-000000000901')
            and (select count(*) = 2 from public.onboarding_tasks where employee_id = (select (j->>'id')::uuid from fx where k = 'i')),
            'templates: the HR Admin edits the standard one and builds another; a joiner gets the tasks of the template chosen');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.onboarding_templates) = 0, 'templates: not readable outside HR');

rollback;
