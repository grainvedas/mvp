-- Migration 33: the once-a-day sign-in code. Built and tested here; switched OFF everywhere until a sender exists
-- (decision 5 Oct 2026). While it is off nothing is asked of anybody. When it is on, a login that has not passed
-- today's code is nobody: no rule lets it read or write anything.
begin;
select t.as_service();
create temp table fx (k text primary key, j jsonb);
grant select, insert, update on fx to authenticated;
create or replace function pg_temp.passes(p uuid) returns bigint language sql stable security definer as $$
  select count(*) from public.daily_code_passes where user_id = p $$;

-- 1 · off: the default --------------------------------------------------------------------------------------------------------
select t.ok(not app.daily_code_on() and not exists (select 1 from public.app_meta where key = 'daily_code'), 'off: it is off unless switched on');
select t.as_user(t.u('03'));
select t.ok(not (app.daily_code_state()->>'needed')::boolean and not (app.my_context()->>'needs_daily_code')::boolean
            and jsonb_array_length(app.my_context()->'scopes') = 7, 'off: nobody is asked for a code; everything works as before');
select t.fails($q$ select app.set_daily_code(true) $q$, 'only the admin', 'switch: only the admin');
select t.fails(format($q$ select app.issue_daily_code(%L) $q$, t.u('03')), 'permission denied', 'a signed-in person cannot draw a code (it returns the code in clear)');

-- 2 · switching on is refused while someone could never receive a code --------------------------------------------------------------
select t.as_user(t.u('01'));
insert into fx values ('try', app.set_daily_code(true));
select t.ok((select (j->>'ok')::boolean = false and (j->>'without_email')::int = 11 and j->'names' @> '["QC Technician"]' from fx where k = 'try'),
            'switch: refused while eleven people who sign in have no email, and it names them');
select t.as_service();
select t.ok(not app.daily_code_on(), 'switch: and it stays off');
update public.app_users set email = 'op' || right(id::text, 3) || '@test.in' where email is null;
select t.as_user(t.u('01'));
insert into fx values ('on', app.set_daily_code(true));
select t.ok((select (j->>'ok')::boolean and (j->>'on')::boolean from fx where k = 'on') and pg_temp.passes(t.u('01')) = 1,
            'switch: with an email for everyone it turns on, and the admin who turned it on is passed for today');
select t.ok(jsonb_array_length(app.my_context()->'scopes') >= 7, 'on: the admin goes on working today');
select t.as_service();
select t.ok((select action = 'daily_code_switched' and flagged and detail->>'on' = 'true' from public.audit_log order by id desc limit 1), 'switch: flagged in the audit log');

-- 3 · on: a login that has not passed today is nobody ---------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.ok((app.daily_code_state()->>'needed')::boolean and (app.daily_code_state()->>'email_hint') like 'g•••@%'
            and (app.my_context()->>'needs_daily_code')::boolean and (app.my_context()->'user'->>'display_name') = 'Prasaadam Client Manager',
            'on: the app is told a code is owed, and who is signing in');
select t.ok(jsonb_array_length(app.my_context()->'scopes') = 0 and (select count(*) from public.scopes) = 0 and (select count(*) from public.footprints) = 0
            and (select count(*) from public.farmers) = 0 and (select count(*) from public.assignments) = 0 and app.current_user_id() is null,
            'on: until then the password alone opens nothing');
select t.fails($q$ select app.people_directory() $q$, 'sign in first', 'on: no function either');
select t.fails($q$ select app.verify_daily_code('000000') $q$, 'expired', 'verify: with no code drawn there is nothing to match');

-- the server function draws the code with the service key (here: the service role)
select t.as_service();
insert into fx values ('code', app.issue_daily_code(t.u('03')));
select t.ok((select j->>'code' ~ '^[0-9]{6}$' and j->>'email' = 'grainvedas+clientmanager@gmail.com' and (j->>'minutes')::int = 10 from fx where k = 'code')
            and (select code_hash ~ '^[0-9a-f]{64}$' and code_hash not like '%' || (select j->>'code' from fx where k = 'code') || '%' and expires_at > now() + interval '9 minutes'
                   from public.daily_codes where user_id = t.u('03')),
            'draw: a six-digit code for that person''s email, valid ten minutes; only its hash is kept');
select t.fails(format($q$ select app.issue_daily_code(%L) $q$, t.u('03')), 'less than a minute ago', 'draw: not twice within a minute');
select t.fails($q$ select app.issue_daily_code('11111111-1111-4111-8111-111111111111') $q$, 'no such person', 'draw: not for a login that is nobody');

select t.as_user(t.u('03'));
select t.ok(not app.verify_daily_code(case when (select j->>'code' from fx where k = 'code') = '000000' then '111111' else '000000' end)
            and app.current_user_id() is null, 'verify: a wrong code opens nothing');
select t.as_user(t.u('06'));
select t.fails(format($q$ select app.verify_daily_code(%L) $q$, (select j->>'code' from fx where k = 'code')), 'expired', 'verify: one person''s code is nobody else''s');
select t.as_user(t.u('03'));
select t.ok(app.verify_daily_code(' ' || (select j->>'code' from fx where k = 'code') || ' '), 'verify: the right code (spaces forgiven) passes');
select t.ok(app.current_user_id() = t.u('03') and jsonb_array_length(app.my_context()->'scopes') = 7 and not (app.my_context()->>'needs_daily_code')::boolean
            and not (app.daily_code_state()->>'needed')::boolean, 'passed: everything is open again');
select t.fails(format($q$ select app.verify_daily_code(%L) $q$, (select j->>'code' from fx where k = 'code')), 'expired', 'verify: a code works once');

-- five wrong tries, an expired code
select t.as_service();
update public.daily_codes set issued_at = now() - interval '2 minutes' where true;
insert into fx values ('c5', app.issue_daily_code(t.u('05')));
select t.as_user(t.u('05'));
select t.ok(not app.verify_daily_code('1') and not app.verify_daily_code('2') and not app.verify_daily_code('3') and not app.verify_daily_code('4') and not app.verify_daily_code('5'),
            'verify: five wrong tries are counted');
select t.fails(format($q$ select app.verify_daily_code(%L) $q$, (select j->>'code' from fx where k = 'c5')), 'too many wrong tries', 'verify: after five, even the right code is refused: draw a new one');
select t.as_service();
insert into fx values ('c7', app.issue_daily_code(t.u('07')));
update public.daily_codes set expires_at = now() - interval '1 second' where user_id = t.u('07');
select t.as_user(t.u('07'));
select t.fails(format($q$ select app.verify_daily_code(%L) $q$, (select j->>'code' from fx where k = 'c7')), 'expired', 'verify: after ten minutes the code is dead');

-- 4 · once per calendar day ----------------------------------------------------------------------------------------------------------------
select t.as_service();
update public.daily_code_passes set day = day - 1 where user_id = t.u('03');
select t.as_user(t.u('03'));
select t.ok(app.current_user_id() is null and (app.daily_code_state()->>'needed')::boolean, 'next day: yesterday''s pass does not count');
-- records cannot be made in the name of someone who has not passed today, by anyone signed in
select t.as_user(t.u('01'));
select t.ok(app.is_my_stage(t.u('05'), t.scope('01'), 'procurement'), 'the code gates the LOGIN, not the person''s assignments (the service role still acts for them)');

-- 5 · off again ------------------------------------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails($q$ select app.set_daily_code(false) $q$, 'only the admin', 'switch: a manager cannot turn it off');
select t.as_user(t.u('01'));
insert into fx values ('off', app.set_daily_code(false));
select t.as_user(t.u('03'));
select t.ok(app.current_user_id() = t.u('03') and not (app.daily_code_state()->>'needed')::boolean, 'off again: nobody is asked');

rollback;
