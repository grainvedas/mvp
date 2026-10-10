-- Workstream D: who may write app_users (migration 10) and linking a login to its app_users row (migration 9).
begin;
select t.as_service();

-- ---------------------------------------------------------------------------
-- Who may write app_users directly (migration 10, replaced by migrations 31–32). Seed placeholders: auth_uid = id.
-- People are made by HR onboarding; status, system role and access change through their own functions. What is left
-- to a direct write is a person's name, phone and email, and only for the admin, HR and (client logins) the client's manager.
-- ---------------------------------------------------------------------------
select t.as_user(t.u('03'));   -- Client Manager, Prasaadam
update public.app_users set role = 'admin' where id = t.u('03');
update public.app_users set system_role = 'admin' where id = t.u('03');
update public.app_users set display_name = 'Renamed' where id = t.u('05');
update public.app_users set active = false where id = t.u('08');
select t.as_service();
select t.ok((select role = 'client_manager' and system_role = 'operational' from public.app_users where id = t.u('03')),
            'guard: a client manager cannot make themselves admin (no row is theirs to update)');
select t.ok((select display_name = 'Procurement Op (field)' from public.app_users where id = t.u('05'))
            and (select active from public.app_users where id = t.u('08')),
            'guard: a client manager no longer edits or deactivates the people working under them');
select t.as_user(t.u('03'));
select t.fails($q$ insert into public.app_users (role, display_name, client_id)
                   values ('operator', 'Planted', '00000000-0000-4000-8000-000000000201') $q$,
               'permission denied', 'guard: nobody inserts a person directly any more');

select t.as_user(t.u('16'));   -- HR Admin (since migration 34 the admin no longer edits operational people once this seat is filled)
select t.fails(format($q$ update public.app_users set role = 'client_view' where id = %L $q$, t.u('12')),
               'only name, phone and email', 'guard: not even HR sets a role by hand: it follows from assignments');
select t.fails(format($q$ update public.app_users set system_role = 'hr_admin' where id = %L $q$, t.u('12')),
               'only name, phone and email', 'guard: nor a system role (app.set_system_role, app.appoint_hr_admin)');
select t.fails(format($q$ update public.app_users set auth_uid = gen_random_uuid() where id = %L $q$, t.u('05')),
               'only name, phone and email', 'guard: nor point a person at a login');
update public.app_users set display_name = 'Mill Operator (Basti)' where id = t.u('08');
select t.ok((select display_name from public.app_users where id = t.u('08')) = 'Mill Operator (Basti)', 'guard: the HR Admin corrects a name');
select t.fails(format($q$ update public.app_users set active = false where id = %L $q$, t.u('08')),
               'only name, phone and email', 'guard: nor a status');
select t.as_user(t.u('01'));   -- Admin (migration 35: edits no person's row at all while the HR Admin seat is filled)
update public.app_users set display_name = 'Renamed by himself', active = false where id = t.u('01');
select t.ok((select display_name <> 'Renamed by himself' and active from public.app_users where id = t.u('01')),
            'admin two jobs (migration 35): the admin edits no person''s row, his own included (nothing is written)');
update public.app_users set display_name = 'Renamed by the admin' where id = t.u('08');
select t.ok((select display_name from public.app_users where id = t.u('08')) = 'Mill Operator (Basti)',
            'oversight (migration 34): with the HR Admin seat filled the admin no longer edits an operational person');
select t.as_user(t.u('17'));   -- HR resource
update public.app_users set display_name = 'Mill Operator' where id = t.u('08');
update public.app_users set display_name = 'Not Veda' where id = t.u('01');
update public.app_users set display_name = 'Not Asha' where id = t.u('16');
select t.as_service();
select t.ok((select display_name from public.app_users where id = t.u('08')) = 'Mill Operator'
            and (select display_name from public.app_users where id = t.u('01')) = 'Veda (Admin)'
            and (select display_name from public.app_users where id = t.u('16')) = 'Asha (HR Admin)',
            'guard: an HR resource corrects an operational person''s name, not the admin''s, not the HR Admin''s');

-- The service role (scripts, seeds) keeps the old switch: off means suspended. And a summary column is never hand-set.
update public.app_users set active = false where id = t.u('08');
select t.ok((select status = 'suspended' and not active from public.app_users where id = t.u('08')), 'status: the old "active" switch, off, is a suspension');
select t.fails(format($q$ update public.app_users set role = 'client_view' where id = %L $q$, t.u('12')),
               'summary of the person''s assignments', 'summary: role, client and states cannot be set by hand, by anyone');

-- ---------------------------------------------------------------------------
-- Migration 9: unique phone and email, normalised
-- ---------------------------------------------------------------------------
select t.as_service();
update public.app_users set email = 'veda.admin@grainveda.test' where id = t.u('01');
update public.app_users set email = 'cm@prasaadam.test'         where id = t.u('03');
update public.app_users set email = 'view@prasaadam.test'       where id = t.u('04');
select t.fails(format($q$ update public.app_users set phone = '+91 00000 00005' where id = %L $q$, t.u('06')),
               'app_users_phone_key', 'unique: the same phone in another format is refused');
select t.fails(format($q$ update public.app_users set email = ' VEDA.Admin@grainveda.test' where id = %L $q$, t.u('02')),
               'app_users_email_key', 'unique: the same email in another case is refused');

-- ---------------------------------------------------------------------------
-- Migration 9: linking (as Supabase Auth would write auth.users, no JWT)
-- ---------------------------------------------------------------------------
-- The logins below stand for logins made by the service role (create-user, bootstrap, demo script): since migration 23
-- only those carry app_metadata.grainveda_login and can claim a row. A public sign-up is tested at the end.
alter table auth.users alter column raw_app_meta_data set default '{"grainveda_login": true}';
insert into auth.users (id, email) values ('10000000-0000-4000-8000-000000000001', 'veda.admin@grainveda.test');
select t.ok((select auth_uid from public.app_users where id = t.u('01')) = t.u('01'), 'link: an unconfirmed email does not link');
update auth.users set email_confirmed_at = now() where id = '10000000-0000-4000-8000-000000000001';
select t.ok((select auth_uid from public.app_users where id = t.u('01')) = '10000000-0000-4000-8000-000000000001',
            'link: confirming the email links the admin row');
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
select t.ok(app.current_role() = 'admin', 'link: app.current_role() is admin for the new login');
select t.as_service();

insert into auth.users (id, phone, phone_confirmed_at) values ('10000000-0000-4000-8000-000000000002', '910000000005', now());
select t.ok((select auth_uid from public.app_users where id = t.u('05')) = '10000000-0000-4000-8000-000000000002',
            'link: confirmed phone 910000000005 links the procurement operator stored as +910000000005');

insert into auth.users (id, phone) values ('10000000-0000-4000-8000-000000000003', '910000000006');
select t.ok((select auth_uid from public.app_users where id = t.u('06')) = t.u('06'), 'link: an unconfirmed phone does not link');

update auth.users set email = 'view@prasaadam.test', email_confirmed_at = now() where id = '10000000-0000-4000-8000-000000000002';
select t.ok((select auth_uid from public.app_users where id = t.u('04')) = t.u('04')
            and (select count(*) from public.app_users where auth_uid = '10000000-0000-4000-8000-000000000002') = 1,
            'link: a linked login never takes a second row');

insert into auth.users (id, phone, phone_confirmed_at) values ('10000000-0000-4000-8000-000000000004', '910000000008', now());
select t.ok((select auth_uid from public.app_users where id = t.u('08')) = t.u('08'), 'link: an inactive user is not linked');

insert into auth.users (id, phone, phone_confirmed_at, email, email_confirmed_at)
values ('10000000-0000-4000-8000-000000000005', '910000000007', now(), 'cm@prasaadam.test', now());
select t.ok((select auth_uid from public.app_users where id = t.u('07')) = t.u('07')
            and (select auth_uid from public.app_users where id = t.u('03')) = t.u('03'),
            'link: phone and email matching two different users links neither');

update public.app_users set email = 'veda.new@grainveda.test' where id = t.u('01');
insert into auth.users (id, email, email_confirmed_at) values ('10000000-0000-4000-8000-000000000006', 'veda.new@grainveda.test', now());
select t.ok((select auth_uid from public.app_users where id = t.u('01')) = '10000000-0000-4000-8000-000000000001',
            'link: a row linked to an existing login is never re-linked');

delete from auth.users where id = '10000000-0000-4000-8000-000000000002';
insert into auth.users (id, phone, phone_confirmed_at) values ('10000000-0000-4000-8000-000000000007', '910000000005', now());
select t.ok((select auth_uid from public.app_users where id = t.u('05')) = '10000000-0000-4000-8000-000000000007',
            'link: after its login is deleted, the row links to the next confirmed login');

-- ---------------------------------------------------------------------------
-- Migration 23: a public sign-up can never claim a user row
-- ---------------------------------------------------------------------------
update public.app_users set email = 'ghost.manager@grainveda.test' where id = t.u('02');      -- State Manager row with no login yet
insert into auth.users (id, email, email_confirmed_at, raw_app_meta_data)
values ('10000000-0000-4000-8000-000000000008', 'ghost.manager@grainveda.test', now(), '{"provider":"email","providers":["email"]}');
select t.ok((select auth_uid from public.app_users where id = t.u('02')) = t.u('02'),
            'link: a public sign-up with a user''s e-mail does not become that user, even confirmed (before: it did)');
select set_config('request.jwt.claims', '{"sub":"10000000-0000-4000-8000-000000000008","role":"authenticated"}', true);
select t.ok(app.current_role() is null, 'link: that sign-up has no role at all');
select t.as_service();
insert into auth.users (id, phone, phone_confirmed_at, raw_app_meta_data)
values ('10000000-0000-4000-8000-000000000009', '910000000009', now(), '{"grainveda_login": true}');
select t.ok((select auth_uid from public.app_users where id = t.u('09')) = '10000000-0000-4000-8000-000000000009',
            'link: a login made by the service role still links');

rollback;
