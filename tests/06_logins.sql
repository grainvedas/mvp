-- Workstream D: who may write app_users (migration 10) and linking a login to its app_users row (migration 9).
begin;
select t.as_service();

-- ---------------------------------------------------------------------------
-- Migration 10: app_users write rules for signed-in callers (seed placeholders: auth_uid = id)
-- ---------------------------------------------------------------------------
select t.as_user(t.u('03'));   -- Client Manager, Prasaadam
select t.fails(format($q$ update public.app_users set role = 'admin' where id = %L $q$, t.u('03')),
               'your own role', 'guard: client manager cannot make themselves admin');
select t.fails(format($q$ update public.app_users set role = 'client_manager' where id = %L $q$, t.u('05')),
               'ranked below', 'guard: client manager cannot promote an operator to client manager');
select t.fails(format($q$ update public.app_users set auth_uid = gen_random_uuid() where id = %L $q$, t.u('05')),
               'login linking', 'guard: client manager cannot point a user at a login');
select t.fails($q$ insert into public.app_users (auth_uid, role, display_name, client_id)
                   values (gen_random_uuid(), 'operator', 'Planted', '00000000-0000-4000-8000-000000000201') $q$,
               'login linking', 'guard: a new user row cannot carry a login');
update public.app_users set active = false where id = t.u('08');
select t.ok((select not active from public.app_users where id = t.u('08')), 'guard: client manager can still deactivate an operator');

select t.as_user(t.u('01'));   -- Admin
update public.app_users set role = 'client_view' where id = t.u('12');
select t.ok((select role from public.app_users where id = t.u('12')) = 'client_view', 'guard: admin can change another user''s role');
select t.fails(format($q$ update public.app_users set active = false where id = %L $q$, t.u('01')),
               'your own role', 'guard: admin cannot deactivate themselves');

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

rollback;
