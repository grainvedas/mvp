-- Migration 37 (Veda, 11 Oct 2026, "Joiner checklist and HR data improvements"). The id-numbers function (full number in,
-- HMAC + last 4 out) is stood in for by calling app.record_id_number as the database owner, exactly as the function calls
-- it with the service key; the function's own rules are tested in web/tests/id_numbers.test.ts, and the whole path, with
-- a search for the typed numbers in everything the stack wrote, in web/e2e/phase10.spec.ts.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.task(p_emp uuid, p_code text) returns uuid language sql stable security definer as $$
  select id from public.onboarding_tasks where employee_id = p_emp and code = p_code $$;
create or replace function pg_temp.docs(p uuid) returns public.employee_docs language sql stable security definer as $$ select * from public.employee_docs where employee_id = p $$;
create or replace function pg_temp.last_audit(p uuid) returns public.audit_log language sql stable security definer as $$
  select * from public.audit_log where target = p order by id desc limit 1 $$;
create or replace function pg_temp.mac(c text) returns text language sql immutable as $$ select repeat(c, 64) $$;

-- two joiners (HR resource Imran adds them), one added AFTER their join date (B1)
select t.as_user(t.u('17'));
insert into fx (k, j) values ('a', app.add_joiner(jsonb_build_object('full_name', 'Anil Late', 'personal_email', 'anil@test.in', 'phone', '9876501001',
  'join_date', (current_date - 8)::text, 'employment_type', 'full_time', 'reports_to', t.u('03')::text)));
insert into fx (k, j) values ('b', app.add_joiner(jsonb_build_object('full_name', 'Bina Second', 'personal_email', 'bina@test.in', 'phone', '9876501002',
  'join_date', (current_date + 20)::text, 'employment_type', 'full_time')));
update fx set id = (j->>'id')::uuid where k in ('a', 'b');
select t.as_service();
update public.app_users set auth_uid = id where id in (pg_temp.f('a'), pg_temp.f('b'));

-- B1 · nothing overdue on day one, whatever the join date ---------------------------------------------------------------------
select t.ok((select bool_and(due_on >= current_date + 3) from public.onboarding_tasks where employee_id = pg_temp.f('a')),
            'due dates: a joiner added 8 days after the join date has every step due in 3 days or later');
select t.ok((select (p->>'overdue')::int = 0 from jsonb_array_elements((select app.hr_pipeline() from (select t.as_user(t.u('17'))) x)) p where p->>'id' = pg_temp.f('a')::text),
            'due dates: and nothing overdue in the pipeline on day one');
select t.as_service();
select t.ok((select due_on = current_date + 20 - 7 from public.onboarding_tasks where employee_id = pg_temp.f('b') and code = 'offer_nda'),
            'due dates: a joiner added in good time keeps "join date − 7"');
select t.ok((select bool_and(due_offset_days is not null) from public.onboarding_tasks where employee_id = pg_temp.f('a')), 'due dates: each step keeps its offset');
select t.as_user(t.u('17'));
select app.update_joiner(pg_temp.f('b'), jsonb_build_object('join_date', (current_date + 40)::text));
select t.as_service();
select t.ok((select due_on = current_date + 40 - 7 from public.onboarding_tasks where employee_id = pg_temp.f('b') and code = 'offer_nda'),
            'due dates: a new join date moves the steps by their offset');
select t.as_user(t.u('17'));
select app.update_joiner(pg_temp.f('b'), jsonb_build_object('join_date', (current_date + 20)::text));
select t.as_service();

-- the template: Personal details right after Identity; the open checklist of the seeded joiner got it too (A3)
select t.ok((select string_agg(code, ',' order by seq) from public.template_tasks where template_id = '00000000-0000-4000-8000-000000000901')
            = 'offer_nda,identity,personal,bank,countersign,pf_gratuity,it_setup,buddy,goals',
            'template: Personal details is the third step of the Standard joining template');
select t.ok((select count(*) = 1 from public.onboarding_tasks where employee_id = t.u('19') and kind = 'personal')
            and (select seq = 3 from public.onboarding_tasks where employee_id = t.u('19') and kind = 'personal'),
            'template: a checklist still open got the step as well, after Identity');

-- A1 · whose number: asked as the caller ------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('a'));
select t.ok((app.id_number_target(pg_temp.task(pg_temp.f('a'), 'identity'), 'pan')->>'employee_id')::uuid = pg_temp.f('a'), 'target: my own identity step takes my PAN');
select t.fails(format($q$ select app.id_number_target(%L, 'bank') $q$, pg_temp.task(pg_temp.f('a'), 'identity')), 'does not take that number', 'target: not a bank number on the identity step');
select t.fails(format($q$ select app.id_number_target(%L, 'pan') $q$, pg_temp.task(pg_temp.f('b'), 'identity')), 'not yours', 'target: nor on someone else''s step');
select t.fails(format($q$ select app.id_number_target(%L, 'uan') $q$, pg_temp.task(pg_temp.f('a'), 'countersign')), 'not yours', 'target: nor on HR''s step');
select t.as_user(t.u('17'));
select t.ok((app.id_number_target(pg_temp.task(pg_temp.f('a'), 'bank'), 'bank')->>'actor_id')::uuid = t.u('17'), 'target: HR may enter it for a joiner HR manages');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.id_number_target(%L, 'pan') $q$, pg_temp.task(pg_temp.f('a'), 'identity')), 'not yours', 'target: the admin may not (the HR Admin seat is filled)');
select t.as_user(t.u('05'));
select t.fails(format($q$ select app.id_number_target(%L, 'pan') $q$, pg_temp.task(pg_temp.f('a'), 'identity')), 'not yours', 'target: nor a colleague');

-- A1 · PAN, Aadhaar, UAN: a second person with the same number is refused ----------------------------------------------------
select t.as_service();
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('a'), 'identity'), pg_temp.f('a'), 'pan', pg_temp.mac('a'), '234F')->>'outcome') = 'saved', 'PAN: the first person''s is saved');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('a'), 'identity'), pg_temp.f('a'), 'pan', pg_temp.mac('a'), '234F')->>'outcome') = 'saved', 'PAN: the same person again is no duplicate');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('b'), 'identity'), pg_temp.f('b'), 'pan', pg_temp.mac('a'), '234F')->>'outcome') = 'refused', 'PAN: a second person with it is refused');
select t.ok((pg_temp.docs(pg_temp.f('b'))).pan_hmac is null and (pg_temp.docs(pg_temp.f('b'))).pan_last4 is null, 'PAN: and nothing of it is kept on the second record');
select t.ok((select action = 'id_number_refused' and flagged and actor = pg_temp.f('b') and (detail->>'matches')::uuid = pg_temp.f('a')
                    and detail->>'last4' = '234F' and not (detail ? 'hmac') from pg_temp.last_audit(pg_temp.f('b'))),
            'PAN: a flagged audit line names the match (last 4 only, no HMAC)');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('a'), 'identity'), pg_temp.f('a'), 'aadhaar', pg_temp.mac('b'), '9012')->>'outcome') = 'saved'
            and (app.record_id_number(pg_temp.task(pg_temp.f('b'), 'identity'), pg_temp.f('b'), 'aadhaar', pg_temp.mac('b'), '9012')->>'outcome') = 'refused',
            'Aadhaar: the same rule');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('a'), 'pf_gratuity'), pg_temp.f('a'), 'uan', pg_temp.mac('c'), '7788')->>'outcome') = 'saved'
            and (app.record_id_number(pg_temp.task(pg_temp.f('b'), 'pf_gratuity'), pg_temp.f('b'), 'uan', pg_temp.mac('c'), '7788')->>'outcome') = 'refused',
            'UAN: the same rule');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('b'), 'identity'), pg_temp.f('b'), 'aadhaar', pg_temp.mac('d'), '1111')->>'outcome') = 'saved'
            and (app.record_id_number(pg_temp.task(pg_temp.f('b'), 'pf_gratuity'), pg_temp.f('b'), 'uan', pg_temp.mac('c'), '7788')->>'outcome') = 'refused',
            'a different Aadhaar is fine; an Aadhaar and a UAN never collide (the function puts the kind into the HMAC)');
select t.fails(format($q$ update public.employee_docs set pan_hmac = %L where employee_id = %L $q$, pg_temp.mac('a'), pg_temp.f('b')),
               'employee_docs_pan_hmac_key', 'PAN: the database itself refuses a second copy (two people at the same moment)');
select t.fails(format($q$ select app.record_id_number(%L, %L, 'pan', 'ABCDE1234F', '234F') $q$, pg_temp.task(pg_temp.f('b'), 'identity'), pg_temp.f('b')),
               'not an HMAC', 'record: a number instead of an HMAC is refused');
select t.fails(format($q$ select app.record_id_number(%L, %L, 'pan', %L, 'ABCDE1234F') $q$, pg_temp.task(pg_temp.f('b'), 'identity'), pg_temp.f('b'), pg_temp.mac('e')),
               'last 4 characters only', 'record: and anything longer than the last 4');

-- what each side sees of it
select t.as_user(pg_temp.f('b'));
select t.ok((select count(*) from public.id_number_matches) = 0, 'refused: the joiner cannot read whose number it is');
select t.ok(not (app.my_onboarding()::text ~ 'Anil'), 'refused: and my checklist does not say');
select t.ok(not (app.my_onboarding()->'checked'->>'pan')::boolean and (app.my_onboarding()->'checked'->>'aadhaar')::boolean, 'my checklist: which numbers are checked');
select t.as_user(t.u('17'));
select t.ok((select count(*) = 4 and bool_and(m->>'outcome' = 'refused' and m->>'matched_name' = 'Anil Late')
               from jsonb_array_elements(app.joiner_detail(pg_temp.f('b'))->'matches') m),
            'HR: the joiner page lists each refused number with the person it matches');
select t.ok((app.joiner_detail(pg_temp.f('a'))->'checked'->>'pan') = 'checked', 'HR: a number with an HMAC is "checked"');

-- a record from before migration 37: last 4 only, "not checked for duplicates" until the number is entered again
select t.as_service();
update public.employee_docs set pan_last4 = '567K', pan_hmac = null where employee_id = t.u('18');
select t.as_user(t.u('16'));
select t.ok((app.joiner_detail(t.u('18'))->'checked'->>'pan') = 'not_checked', 'before migration 37: shown as "not checked for duplicates"');

-- A1 · bank: saved, HR warned, HR may accept with a reason (flagged) ---------------------------------------------------------
select t.as_service();
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('a'), 'bank'), pg_temp.f('a'), 'bank', pg_temp.mac('f'), '4321', 'k1', 'SBIN0001234')->>'outcome') = 'saved', 'bank: saved');
select t.ok((app.record_id_number(pg_temp.task(pg_temp.f('b'), 'bank'), pg_temp.f('b'), 'bank', pg_temp.mac('f'), '4321', 'k1', 'SBIN0001234')->>'outcome') = 'warned',
            'bank: the same account on a second person gives a warning');
select t.ok((pg_temp.docs(pg_temp.f('b'))).bank_hmac = pg_temp.mac('f') and (pg_temp.docs(pg_temp.f('b'))).bank_ifsc = 'SBIN0001234', 'bank: and is saved');
select t.as_user(pg_temp.f('b'));
select t.fails(format($q$ select app.accept_shared_bank(%L, 'mine') $q$, (select id from public.id_number_matches where kind = 'bank' limit 1)), 'no such bank warning',
               'bank: the joiner neither sees nor accepts the warning');
select t.as_user(t.u('17'));
insert into fx (k, id) select 'bm', (m->>'id')::uuid from jsonb_array_elements(app.joiner_detail(pg_temp.f('b'))->'matches') m where m->>'kind' = 'bank';
select t.ok((select (m->>'outcome') = 'warned' and m->>'matched_name' = 'Anil Late' and m->>'accepted_at' is null
               from jsonb_array_elements(app.joiner_detail(pg_temp.f('b'))->'matches') m where m->>'kind' = 'bank'),
            'bank: HR sees "also on Anil Late''s record"');
select t.fails(format($q$ select app.accept_shared_bank(%L, '  ') $q$, pg_temp.f('bm')), 'reason is required', 'bank: accepting needs a reason');
select app.accept_shared_bank(pg_temp.f('bm'), 'Husband and wife share a joint account 12345678901');
select t.as_service();
select t.ok((select action = 'bank_duplicate_accepted' and flagged and actor = t.u('17') and detail->>'reason' = 'Husband and wife share a joint account [number removed]'
               from pg_temp.last_audit(pg_temp.f('b'))),
            'bank: accepted, a flagged audit line with the reason (a number typed into it is taken out)');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.accept_shared_bank(%L, 'again') $q$, pg_temp.f('bm')), 'accepted already', 'bank: once');

-- A2 · card images ---------------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('a'));
select t.fails(format($q$ select app.register_hr_file(%L, 'aadhaar', %L, %L) $q$, pg_temp.f('a'), pg_temp.f('a')::text || '/card.jpg', repeat('a', 64)),
               'is not kept', 'images: a full Aadhaar card image is refused');
insert into fx (k, id) values ('img1', app.register_hr_file(pg_temp.f('a'), 'aadhaar_masked', pg_temp.f('a')::text || '/m1.jpg', repeat('b', 64), 'm1.jpg', pg_temp.task(pg_temp.f('a'), 'identity')));
insert into fx (k, id) values ('img2', app.register_hr_file(pg_temp.f('a'), 'aadhaar_masked', pg_temp.f('a')::text || '/m2.jpg', repeat('c', 64), 'm2.jpg', pg_temp.task(pg_temp.f('a'), 'identity')));
insert into storage.objects (bucket_id, name) values ('hr-docs', pg_temp.f('a')::text || '/m1.jpg'), ('hr-docs', pg_temp.f('a')::text || '/m2.jpg');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('a'), 'identity'), '{}')->>'ok')::boolean, 'identity: done with the numbers checked (a masked Aadhaar attached)');
select t.fails(format($q$ select app.confirm_masked(%L, true) $q$, pg_temp.f('img1')), 'only HR checks', 'images: the joiner does not judge their own image');
select t.as_user(t.u('17'));
select t.ok((app.confirm_masked(pg_temp.f('img1'), true)->>'delete')::boolean = false, 'images: HR finds the first masked');
select t.ok((app.confirm_masked(pg_temp.f('img2'), false)->>'delete')::boolean, 'images: and the second not masked');
select t.as_service();
select t.ok((select action = 'card_not_masked' and flagged and (detail->>'asked_again')::boolean from pg_temp.last_audit(pg_temp.f('a')))
            and (select count(*) from public.audit_log where target = pg_temp.f('a') and action = 'card_masked_confirmed' and not flagged) = 1,
            'images: both acts are in the audit log; "not masked" is flagged');
select t.ok((select status = 'pending' and note like 'asked again%' from public.onboarding_tasks where employee_id = pg_temp.f('a') and code = 'identity'),
            'images: the joiner is asked again (the identity step is open again)');
select t.as_user(pg_temp.f('a'));
delete from storage.objects where bucket_id = 'hr-docs' and name = pg_temp.f('a')::text || '/m2.jpg';
select t.as_service();
select t.ok((select count(*) from storage.objects where name = pg_temp.f('a')::text || '/m2.jpg') = 1, 'images: the joiner cannot delete it (the policy lets nothing through)');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.note_file_removed(%L) $q$, pg_temp.f('img2')), 'still in the store', 'images: not marked deleted while it is still there');
delete from storage.objects where bucket_id = 'hr-docs' and name = pg_temp.f('a')::text || '/m1.jpg';
select t.as_service();
select t.ok((select count(*) from storage.objects where name = pg_temp.f('a')::text || '/m1.jpg') = 1, 'images: HR cannot delete an image found masked (the storage policy)');
select t.as_user(t.u('17'));
delete from storage.objects where bucket_id = 'hr-docs' and name = pg_temp.f('a')::text || '/m2.jpg';
select app.note_file_removed(pg_temp.f('img2'));
select t.as_service();
select t.ok((select count(*) from storage.objects where name = pg_temp.f('a')::text || '/m2.jpg') = 0
            and (select removed_at is not null and removed_by = t.u('17') from public.employee_files where id = pg_temp.f('img2'))
            and (select action = 'hr_file_removed' and flagged from pg_temp.last_audit(pg_temp.f('a'))),
            'images: the image is gone, its record stays (who, when), a flagged audit line');
select t.as_user(pg_temp.f('a'));
select t.ok((select count(*) from jsonb_array_elements(app.my_onboarding()->'files') x where x->>'id' = pg_temp.f('img2')::text) = 0, 'images: the joiner no longer sees the deleted one');
select t.as_user(t.u('17'));
select app.record_card_seen(pg_temp.f('b'));
select t.ok((app.joiner_detail(pg_temp.f('b'))->'docs'->>'pan_card_seen_by') = 'Imran (HR)', '"PAN card seen": by whom and when, instead of a file');
select t.as_user(t.u('05'));
select t.fails(format($q$ select app.record_card_seen(%L) $q$, pg_temp.f('b')), 'only HR records', '"PAN card seen": HR only');

-- A3 · Personal details ----------------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('a'));
select t.fails(format($q$ select app.complete_task(%L, '{"date_of_birth":"2030-01-01"}') $q$, pg_temp.task(pg_temp.f('a'), 'personal')), 'date of birth', 'personal: a date of birth in the future is refused');
select t.fails(format($q$ select app.complete_task(%L, '{"date_of_birth":"not a date"}') $q$, pg_temp.task(pg_temp.f('a'), 'personal')), 'date of birth', 'personal: and one that is not a date');
select t.fails(format($q$ select app.complete_task(%L, '{"date_of_birth":"1998-02-03","relative_kind":"spouse","relative_name":"Meena","present_address":"Bansi","permanent_address":"Bansi","emergency_name":"Meena","emergency_relation":"Wife","emergency_phone":"123"}') $q$, pg_temp.task(pg_temp.f('a'), 'personal')),
               'emergency contact', 'personal: the emergency contact needs a mobile number');
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('a'), 'personal'), '{"date_of_birth":"1998-02-03","relative_kind":"spouse","relative_name":"Meena","present_address":"Ward 2, Bansi","permanent_address":"Ward 2, Bansi","emergency_name":"Meena","emergency_relation":"Wife","emergency_phone":"98765 43210"}')->>'ok')::boolean,
            'personal: saved');
select t.ok((select date_of_birth = '1998-02-03' and relative_kind = 'spouse' and emergency_phone = '+919876543210' from public.employee_personal), 'personal: the joiner reads their own');
select t.as_service();
select t.ok((select detail = jsonb_build_object('name', 'Anil Late') from public.audit_log where target = pg_temp.f('a') and action = 'personal_details_saved'),
            'personal: the audit line says it was saved, never what');
select t.as_user(t.u('17'));
select t.ok((app.joiner_detail(pg_temp.f('a'))->'personal'->>'relative_name') = 'Meena', 'personal: HR reads it');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.employee_personal) = 0, 'personal: a manager does not');

-- B2 · dependencies: none by default; a template may set them; HR is not held -----------------------------------------------
select t.as_user(pg_temp.f('b'));
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('b'), 'bank'), '{"bank_name":"State Bank"}')->>'ok')::boolean, 'dependencies: bank details before identity (no dependency by default)');
select t.as_service();
insert into public.onboarding_templates (id, name, first_day_time, first_day_place, first_day_ask_for, first_day_bring)
values ('00000000-0000-4000-8000-000000000903', 'With order', '09:30', 'Gate 2, KIPM, Gorakhpur', 'Asha at reception', 'Two photos');
insert into public.template_tasks (template_id, seq, code, title, owner, due_offset_days, kind, depends_on) values
  ('00000000-0000-4000-8000-000000000903', 1, 'identity', 'Identity', 'hire', -7, 'identity', '{}'),
  ('00000000-0000-4000-8000-000000000903', 2, 'pf_gratuity', 'Nomination', 'hire', -3, 'nomination', '{identity}'),
  ('00000000-0000-4000-8000-000000000903', 3, 'countersign', 'Countersign', 'hr', -3, 'countersign', '{identity}');
select t.as_user(t.u('17'));
insert into fx (k, j) values ('c', app.add_joiner(jsonb_build_object('full_name', 'Chitra Ordered', 'personal_email', 'chitra@test.in', 'phone', '9876501003',
  'join_date', (current_date + 10)::text, 'template_id', '00000000-0000-4000-8000-000000000903')));
update fx set id = (j->>'id')::uuid where k = 'c';
select t.as_service();
update public.app_users set auth_uid = id where id = pg_temp.f('c');
select t.as_user(pg_temp.f('c'));
select t.fails(format($q$ select app.complete_task(%L, '{"gratuity_nominee":"X","nominee_relation":"Y"}') $q$, pg_temp.task(pg_temp.f('c'), 'pf_gratuity')),
               'opens after: Identity', 'dependencies: a step the template makes wait is refused until the other is done');
select t.ok((select (x->'depends_on')->>0 = 'identity' from jsonb_array_elements(app.my_onboarding()->'tasks') x where x->>'code' = 'pf_gratuity'), 'dependencies: the joiner is told which');
select t.as_user(t.u('17'));
select t.ok((app.complete_task(pg_temp.task(pg_temp.f('c'), 'countersign'), '{}')->>'ok')::boolean, 'dependencies: HR is not held by them');

-- B4 · B5 · B6 · what the joiner reads -------------------------------------------------------------------------------------------
select t.as_user(pg_temp.f('c'));
select t.ok((app.my_onboarding()->>'system_role') = 'operational' and (app.my_onboarding()->'hr_admin'->>'name') = 'Asha (HR Admin)',
            'joiner: my system role, and the HR Admin to contact');
select t.ok((select x->>'date' = (current_date + 10)::text and x->>'time' = '09:30' and x->>'ask_for' = 'Asha at reception' and x->>'bring' = 'Two photos'
               from (select app.my_onboarding()->'first_day' x) y),
            'first day: the template''s defaults, on the join date');
select t.as_user(t.u('17'));
select app.update_joiner(pg_temp.f('c'), jsonb_build_object('first_day_time', '10:00', 'first_day_place', 'Head office, Gorakhpur'));
select t.as_user(pg_temp.f('c'));
select t.ok((select x->>'time' = '10:00' and x->>'place' = 'Head office, Gorakhpur' and x->>'bring' = 'Two photos'
               from (select app.my_onboarding()->'first_day' x) y),
            'first day: what HR sets for this joiner comes first; the rest stays the template''s');

-- A1.5 · a number typed into a problem report never reaches client_errors ---------------------------------------------------
select app.report_client_error('report', 'My PAN ABCDE1234F and Aadhaar 2345 6789 0123 were refused', 'account 001122334455', '/onboarding');
select t.as_service();
select t.ok((select message = 'My PAN [number removed] and Aadhaar [number removed] were refused' and detail = 'account [number removed]'
               from public.client_errors order by at desc limit 1),
            'problem reports: numbers are taken out before they are stored');
select t.ok((select count(*) from public.client_errors where message ~ '[0-9]{9}|ABCDE1234F' or detail ~ '[0-9]{9}') = 0, 'problem reports: none is left');

select t.ok((select count(*) from app.verify_ledger()) = 0, 'the ledger chain still verifies');
rollback;
