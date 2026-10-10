-- Migration 36 (Veda, 10 Oct 2026, "fix: the HR Admin cannot be activated"). Found on the practice system: the admin
-- gave the HR Admin seat to a person who had not joined yet; she had no HR access while Joining, there was no other HR
-- person, and the admin's "Mark as joined" was refused, so HR could never be switched on.
-- The rule: the admin marks the HR Admin seat holder as joined, and only her; a flagged audit line records it.
begin;
select t.as_service();

-- the practice system as found: the HR Admin seat held by a person still Joining, no other HR person
update public.app_users set status = 'onboarding' where id = t.u('16');
update public.app_users set status = 'offboarded', active = false where id = t.u('17');
-- a second HR person, Joining too (the admin may add one while the seat is in effect vacant)
insert into public.app_users (id, role, display_name, email, system_role, status)
values ('00000000-0000-4000-8000-000000000360', 'operator', 'Second HR Joiner', 'second.hr@test.in', 'hr_resource', 'invited');

select t.ok(not app.hr_seat_filled(), 'setup: an HR Admin who has not joined does not fill the seat');

-- 1 · while she is Joining she has no HR access, and cannot mark herself as joined ---------------------------------------
select t.as_user(t.u('16'));
select t.ok(not app.is_hr() and not app.acts_as_hr(), 'joining: the HR Admin has no HR access before she joins');
select t.fails($q$ select app.hr_pipeline() $q$, 'only HR', 'joining: she does not open HR · Joiners');
select t.fails($q$ select app.audit_feed() $q$, 'admin and the HR Admin', 'joining: nor the audit log');
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('16')), 'only HR marks', 'joining: she cannot mark herself as joined');
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('19')), 'only HR marks', 'joining: nor anyone else');

-- 2 · the admin: the button only on her page; the server refuses anyone else ----------------------------------------------
select t.as_user(t.u('01'));
select t.ok((app.joiner_detail(t.u('16'))->>'can_activate')::boolean, 'admin: "Mark as joined" is offered on the HR Admin''s joiner page');
select t.ok(not (app.joiner_detail(t.u('19'))->>'can_activate')::boolean, 'admin: not on an operational joiner''s page');
select t.ok(not (app.joiner_detail('00000000-0000-4000-8000-000000000360')->>'can_activate')::boolean, 'admin: not on another HR joiner''s page');
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('19')), 'only HR marks',
               'admin: calling activate_joiner for an operational joiner is refused by the server');
select t.fails($q$ select app.activate_joiner('00000000-0000-4000-8000-000000000360') $q$, 'only HR marks',
               'admin: and for another HR joiner (the seat holder only)');
select t.as_service();
select t.ok((select status = 'onboarding' from public.app_users where id = t.u('19'))
            and (select status = 'invited' from public.app_users where id = '00000000-0000-4000-8000-000000000360'),
            'admin: nothing changed for them');

-- 3 · the admin marks the HR Admin as joined: Active, one flagged audit line --------------------------------------------
select t.as_user(t.u('01'));
select t.ok(app.activate_joiner(t.u('16')) = 'active', 'admin: marks the HR Admin seat holder as joined');
select t.as_service();
select t.ok((select status = 'active' and active from public.app_users where id = t.u('16')), 'she is Active');
select t.ok((select action = 'hr_admin_activated_by_admin' and flagged and actor = t.u('01') and target = t.u('16')
                    and detail->>'from' = 'onboarding' and (detail->>'tasks_open')::int >= 0
               from public.audit_log order by id desc limit 1),
            'audit: a flagged line "the admin marked the HR Admin as joined", by the admin, about her');
select t.ok(app.hr_seat_filled(), 'the seat is filled now');
select t.as_user(t.u('01'));
select t.fails(format($q$ select app.activate_joiner(%L) $q$, t.u('16')), 'active already', 'admin: once only');

-- 4 · HR is switched on: her pages open; the admin's HR side is gone ------------------------------------------------------
select t.as_user(t.u('16'));
select t.ok(app.is_hr() and app.is_hr_admin(), 'HR Admin: HR access once she has joined');
select t.ok(jsonb_typeof(app.hr_pipeline()) is not null, 'HR Admin: HR · Joiners opens');
select t.ok(jsonb_array_length(app.people_directory()) > 0, 'HR Admin: People & access lists people');
select t.ok((select count(*) from jsonb_array_elements(app.audit_feed(50, true)) l
              where l->>'action' = 'hr_admin_activated_by_admin' and (l->>'flagged')::boolean) = 1,
            'HR Admin: the audit log shows the flagged line');
select t.ok(app.activate_joiner(t.u('19')) = 'active', 'control: the HR Admin marks the other joiners as joined');
select t.as_service();
select t.ok((select action = 'activated' and not flagged and actor = t.u('16') from public.audit_log order by id desc limit 1),
            'audit: HR''s own "marked as joined" stays an ordinary line');
select t.as_user(t.u('01'));
select t.ok(not app.acts_as_hr(), 'admin: no HR access any more');
select t.fails(format($q$ select app.joiner_detail(%L) $q$, '00000000-0000-4000-8000-000000000360'), 'not found', 'admin: joiner pages are HR''s again');
select t.ok((select not (p->'can'->>'reset_login')::boolean and not (p->'can'->>'suspend')::boolean and not (p->'can'->>'offboard')::boolean
                    and not (p->'can'->>'hr_record')::boolean from (select app.employee_profile(t.u('18')) p) x),
            'admin: on a person''s page no Reset password, Suspend, Offboard or HR record');
select t.ok((app.employee_profile(t.u('16'))->'can'->>'reset_login')::boolean, 'admin: the HR Admin''s password stays his to reset (migration 35)');

select t.as_service();
select t.ok((select count(*) from app.verify_ledger()) = 0, 'the ledger chain still verifies');
rollback;
