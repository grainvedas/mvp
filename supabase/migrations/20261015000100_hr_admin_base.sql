-- Migration 40 (Veda, 13 Oct 2026): the admin sets where the HR Admin is based.
-- Since migration 39 a person's base location is set by HR of that person's state, never by the person. The HR Admin's
-- own record had nobody: she may not set her own, an HR resource does not act on the HR Admin, and the admin only while
-- the HR Admin seat is vacant. Seen on staging (Minal, head office in Delhi). The admin, who appoints the HR Admin and
-- marks her as joined (migrations 35, 36), now also sets her base location. Nothing else changes: the admin still does
-- not set anyone else's while the seat is filled, and nobody sets their own. Additive: two functions replaced.

CREATE OR REPLACE FUNCTION app.set_base_location(p_employee uuid, p_state uuid, p_district text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; v_dist text := nullif(left(btrim(coalesce(p_district, '')), 60), '');
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = me then raise exception 'your own base location is set by HR' using errcode = '42501'; end if;
  if not (((app.is_hr() or (app.is_admin() and not app.hr_seat_filled())) and app.hr_may_manage_person(u.id))
          or (app.is_admin() and u.system_role = 'hr_admin' and u.status <> 'offboarded')) then   -- migration 40: the admin places the HR Admin
    raise exception 'only HR for this person''s state sets where they are based' using errcode = '42501'; end if;
  if p_state is null or not exists (select 1 from public.states where id = p_state) then raise exception 'choose a state' using errcode = '23514'; end if;
  if not app.hr_full() and not (p_state = any(app.my_hr_states())) then
    raise exception 'that state is not one of yours: ask the HR Admin' using errcode = '42501'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  perform set_config('app.org_fn', 'on', true);
  insert into public.employee_org (employee_id, updated_by, base_state_id, base_district) values (u.id, me, p_state, v_dist)
  on conflict (employee_id) do update set base_state_id = excluded.base_state_id, base_district = excluded.base_district,
                                          updated_by = me, updated_at = now();
  perform set_config('app.org_fn', '', true);
  if o.base_state_id is distinct from p_state or o.base_district is distinct from v_dist then
    perform app.audit('base_location_set', u.id, jsonb_build_object('name', u.display_name,
      'from', concat_ws(' · ', (select name from public.states where id = o.base_state_id), o.base_district),
      'to', concat_ws(' · ', (select name from public.states where id = p_state), v_dist)));
  end if;
  return jsonb_build_object('state_id', p_state, 'state_name', (select name from public.states where id = p_state), 'district', v_dist);
end $function$;

CREATE OR REPLACE FUNCTION app.person_geo(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org;
begin
  select * into u from public.app_users where id = p_employee;
  if u.id is null or not (u.id = me or app.is_admin() or (app.is_hr() and (app.hr_covers(u.id) or u.system_role in ('hr_admin', 'hr_resource')))
                          or (app.can_assign() and not u.external and u.status <> 'offboarded')) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  return jsonb_build_object(
    'state_id', o.base_state_id, 'state_name', (select name from public.states where id = o.base_state_id), 'district', o.base_district,
    'hr_states', case when u.system_role = 'hr_resource' then app.hr_states_of(u.id) end,
    'can_set_base', u.id <> me and not u.external
                    and (((app.is_hr() or (app.is_admin() and not app.hr_seat_filled())) and app.hr_may_manage_person(u.id))
                         or (app.is_admin() and u.system_role = 'hr_admin' and u.status <> 'offboarded')),
    'can_set_hr_states', u.system_role = 'hr_resource' and u.status <> 'offboarded'
                         and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())));
end $function$;
