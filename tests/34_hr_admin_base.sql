-- Migration 40 (Veda, 13 Oct 2026): the admin sets where the HR Admin is based (on staging nobody could: Minal, head
-- office in Delhi). Asha (316) is the HR Admin, Imran (317) an HR resource for Uttar Pradesh, Veda (301) the admin.
begin;
select t.as_service();
create or replace function pg_temp.org(p uuid) returns public.employee_org language sql stable security definer as $$
  select * from public.employee_org where employee_id = p $$;
create or replace function pg_temp.audits(p_action text, p_target uuid) returns int language sql stable security definer as $$
  select count(*)::int from public.audit_log where action = p_action and target = p_target $$;
\set AS '''00000000-0000-4000-8000-000000000002'''
create temp table n0 as select pg_temp.audits('base_location_set', t.u('16')) as n;
grant select on n0 to authenticated;

-- 1 · the admin places the HR Admin -------------------------------------------------------------------------------------
select t.as_user(t.u('01'));
select t.ok((select (app.person_geo(t.u('16'))->>'can_set_base')::boolean), 'admin: offered to set where the HR Admin is based');
select t.ok((select app.set_base_location(t.u('16'), :AS, 'Guwahati') is not null), 'admin: sets the HR Admin''s base location');
select t.ok((select o.base_state_id = :AS::uuid and o.base_district = 'Guwahati' from pg_temp.org(t.u('16')) o), 'the HR Admin is now based in Assam · Guwahati');
select t.ok(pg_temp.audits('base_location_set', t.u('16')) = (select n from n0) + 1, 'logged as "set where this person is based"');

-- 2 · nothing else opens --------------------------------------------------------------------------------------------------
select t.ok(not (select (app.person_geo(t.u('06'))->>'can_set_base')::boolean), 'admin: not offered for anyone else while the HR Admin seat is filled');
select t.fails(format($q$ select app.set_base_location(%L, %L) $q$, t.u('06'), :AS), 'only HR', 'admin: refused for an operational person');
select t.fails(format($q$ select app.set_base_location(%L, %L) $q$, t.u('17'), :AS), 'only HR', 'admin: refused for an HR resource');
select t.as_user(t.u('16'));
select t.ok(not (select (app.person_geo(t.u('16'))->>'can_set_base')::boolean), 'the HR Admin: not offered her own');
select t.fails(format($q$ select app.set_base_location(%L, %L) $q$, t.u('16'), :AS), 'your own base location', 'the HR Admin: refused her own');
select t.ok((select (app.person_geo(t.u('06'))->>'can_set_base')::boolean), 'the HR Admin: still sets everyone else''s');
select t.as_user(t.u('17'));
select t.fails(format($q$ select app.set_base_location(%L, %L) $q$, t.u('16'), :AS), 'only HR', 'an HR resource: refused for the HR Admin');
select t.as_user(t.u('06'));
select t.fails(format($q$ select app.set_base_location(%L, %L) $q$, t.u('16'), :AS), 'only HR', 'an operational person: refused');
rollback;
