-- Migration 39: HR by geography, and a base location for everyone (Veda, 12 October 2026).
--
-- What Veda saw on the practice system: the HR Admin gave Neha, an HR resource who handles one state's onboarding, the
-- State Manager seat, because there was no other way to say "HR for this state". Her decisions:
--   1. An HR resource works only on the people of her states: she sees and acts on their records, joiners, openings
--      and HR files, and nobody else's. The HR Admin (and the admin while that seat is vacant) sees everyone.
--   2. "HR should never be the State Manager. HR can govern the state with regard to onboarding and other things."
--      An HR person holds no seat at all (no state, client or scope assignment); the database refuses one, and refuses
--      to make someone HR who holds a seat. (Before this, a State Manager seat let an HR resource give client accounts:
--      one person could both add people and give them access, against the rule "HR creates, a manager assigns".)
--   3. The seat Neha holds is ended by the HR Admin in the app; the staging script stops while any HR person holds one.
--   4. Every person has a base location: a state and a district, on their HR record. It grants nothing; for an HR
--      resource it decides whose records she may work on.
-- Additive: new table hr_states, two new columns, new functions, functions and read rules changed to ask about the
-- state. The base state is filled where the data leaves no doubt (an opening's state, or one state among a person's
-- seats); nothing is deleted or rewritten.

-- ── schema ─────────────────────────────────────────────────────────────────────────────────────────────────────────
create table public.hr_states (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.app_users(id),
  state_id    uuid not null references public.states(id),
  set_by      uuid references public.app_users(id),
  set_at      timestamptz not null default now(),
  ended_by    uuid references public.app_users(id),
  ended_at    timestamptz
);
comment on table public.hr_states is 'The states an HR resource works for (migration 39). Ended rows are kept: who covered what, when.';
create unique index hr_states_one_active on public.hr_states (employee_id, state_id) where ended_at is null;
create index hr_states_by_state on public.hr_states (state_id) where ended_at is null;
alter table public.hr_states enable row level security;
revoke insert, update, delete on public.hr_states from anon, authenticated;

alter table public.employee_org
  add column base_state_id uuid references public.states(id),
  add column base_district text check (base_district is null or char_length(base_district) between 1 and 60);
comment on column public.employee_org.base_state_id is 'Where the person is based (migration 39). Grants nothing; an HR resource works on the people based in her states.';
create index employee_org_base_state on public.employee_org (base_state_id);

-- ── who covers whom ────────────────────────────────────────────────────────────────────────────────────────────────
-- The caller's HR states (an active HR resource's; empty for everyone else).
create or replace function app.my_hr_states() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(h.state_id order by h.state_id), '{}')
    from public.hr_states h join public.app_users u on u.id = h.employee_id
   where h.employee_id = app.current_user_id() and h.ended_at is null and u.status = 'active' and u.system_role = 'hr_resource'
$$;

-- Sees and works on everyone: the HR Admin, and the admin (who acts as HR only while that seat is vacant).
create or replace function app.hr_full() returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or app.is_hr_admin()
$$;

-- Is this person within the caller's HR reach? The HR Admin and the admin: everyone. An HR resource: the people based
-- in her states. Anyone else: nobody (their rules are elsewhere).
create or replace function app.hr_covers(p_employee uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.hr_full()
      or (app.is_hr() and exists (select 1 from public.employee_org o
                                   where o.employee_id = p_employee and o.base_state_id = any(app.my_hr_states())))
$$;

-- The same for a file in the private store hr-docs (its first folder is the person's id).
create or replace function app.hr_covers_path(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  begin v := (storage.foldername(p_name))[1]::uuid; exception when others then return app.hr_full(); end;
  return app.hr_covers(v);
end $$;

-- HR may manage this person: by system role (who may manage whom, migration 35) and by state (migration 39).
create or replace function app.hr_may_manage_person(p_employee uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.hr_may_manage((select system_role from public.app_users where id = p_employee)) and app.hr_covers(p_employee)
$$;

-- For the screens: am I limited to some states, and which.
create or replace function app.hr_scope() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'full', app.hr_full() and app.acts_as_hr(),
    'hr', app.acts_as_hr(),
    'states', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name)
                          from public.states s where s.id = any(app.my_hr_states())), '[]'::jsonb))
$$;

-- An HR person's states, as names (for the Seats page and the profile).
create or replace function app.hr_states_of(p_employee uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'since', h.set_at) order by s.name), '[]'::jsonb)
    from public.hr_states h join public.states s on s.id = h.state_id
   where h.employee_id = p_employee and h.ended_at is null
$$;

-- ── setting them ───────────────────────────────────────────────────────────────────────────────────────────────────
-- The HR Admin gives an HR resource her states (the admin only while the HR Admin seat is vacant). The whole list is
-- given each time: states left out end (kept as history), new ones begin. One audit line with both lists.
create or replace function app.set_hr_states(p_employee uuid, p_states uuid[]) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; v_new uuid[]; v_old uuid[]; bad uuid;
begin
  if not (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())) then
    raise exception 'only the HR Admin gives an HR person her states' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.system_role <> 'hr_resource' then
    raise exception 'states are given to HR resources (the HR Admin works for every state)' using errcode = '23514'; end if;
  if u.status = 'offboarded' then raise exception 'this person has left' using errcode = '23514'; end if;
  select coalesce(array_agg(distinct x), '{}') into v_new from unnest(coalesce(p_states, '{}')) x where x is not null;
  select x into bad from unnest(v_new) x where not exists (select 1 from public.states s where s.id = x) limit 1;
  if bad is not null then raise exception 'unknown state' using errcode = '23514'; end if;
  select coalesce(array_agg(state_id), '{}') into v_old from public.hr_states where employee_id = u.id and ended_at is null;
  update public.hr_states set ended_at = now(), ended_by = me
   where employee_id = u.id and ended_at is null and not (state_id = any(v_new));
  insert into public.hr_states (employee_id, state_id, set_by)
  select u.id, x, me from unnest(v_new) x where not (x = any(v_old));
  if not (v_old @> v_new and v_new @> v_old) then
    perform app.audit('hr_states_set', u.id, jsonb_build_object('name', u.display_name,
      'from', (select coalesce(string_agg(name, ', ' order by name), '—') from public.states where id = any(v_old)),
      'to', (select coalesce(string_agg(name, ', ' order by name), '—') from public.states where id = any(v_new))));
  end if;
  return app.hr_states_of(u.id);
end $$;

-- A person's base location (state and district). HR within its reach; an HR resource only into one of her states.
create or replace function app.set_base_location(p_employee uuid, p_state uuid, p_district text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; v_dist text := nullif(left(btrim(coalesce(p_district, '')), 60), '');
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = me then raise exception 'your own base location is set by HR' using errcode = '42501'; end if;
  if not ((app.is_hr() or (app.is_admin() and not app.hr_seat_filled())) and app.hr_may_manage_person(u.id)) then
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
end $$;

-- A person's base location and, for an HR resource, her states: for the profile.
create or replace function app.person_geo(p_employee uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
    'can_set_base', u.id <> me and not u.external and (app.is_hr() or (app.is_admin() and not app.hr_seat_filled())) and app.hr_may_manage_person(u.id),
    'can_set_hr_states', u.system_role = 'hr_resource' and u.status <> 'offboarded'
                         and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())));
end $$;

-- The HR people with their states, for the HR Admin's Seats page.
create or replace function app.hr_people_states() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when app.acts_as_hr() or app.is_admin() then coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'system_role', u.system_role, 'status', u.status,
                                        'states', app.hr_states_of(u.id),
                                        'seats', (select count(*) from public.assignments a where a.employee_id = u.id and a.active))
                     order by u.system_role, u.display_name)
      from public.app_users u where u.system_role in ('hr_admin', 'hr_resource') and u.status <> 'offboarded' and not u.external), '[]'::jsonb)
  else '[]'::jsonb end
$$;


-- ── HR acts ask about the person's state: hr_may_manage(role) becomes hr_may_manage_person(id) ─────────────

CREATE OR REPLACE FUNCTION app.accept_shared_bank(p_match uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); m public.id_number_matches;
begin
  select * into m from public.id_number_matches where id = p_match;
  if m.id is null or m.kind <> 'bank' or m.outcome <> 'warned' then raise exception 'no such bank warning' using errcode = 'P0002'; end if;
  if not (app.acts_as_hr() and app.hr_may_manage_person(m.employee_id) and m.employee_id <> me) then
    raise exception 'only HR accepts a shared bank account' using errcode = '42501'; end if;
  if m.accepted_at is not null then raise exception 'accepted already' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.id_number_matches set accepted_at = now(), accepted_by = me, accept_reason = left(app.scrub_numbers(btrim(p_reason)), 500) where id = m.id;
  perform app.audit('bank_duplicate_accepted', m.employee_id, jsonb_build_object('last4', m.last4, 'matches', m.matched_employee,
          'matches_name', (select display_name from public.app_users where id = m.matched_employee), 'reason', left(app.scrub_numbers(btrim(p_reason)), 500)), true);
end $function$;

CREATE OR REPLACE FUNCTION app.activate_joiner(p_employee uuid, p_reason text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; by_admin boolean; v_stat text; n_open int; v_why text := btrim(coalesce(p_reason, ''));
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  -- The admin marks one person as joined: the holder of the HR Admin seat, while she has not joined (until then the
  -- seat is in effect vacant and HR cannot act). Everyone else is HR's to mark, also while the seat is vacant.
  by_admin := app.is_admin() and u.system_role = 'hr_admin' and u.id <> me;
  if not by_admin and (not (app.is_hr() and app.hr_may_manage_person(u.id)) or u.id = me) then
    raise exception 'only HR marks a joiner as joined' using errcode = '42501'; end if;
  if u.status not in ('invited', 'onboarding') then
    raise exception 'this person is % already', u.status using errcode = '23514'; end if;
  select string_agg(t.title, ', ' order by t.seq) into v_stat from public.onboarding_tasks t
   where t.employee_id = u.id and t.status = 'pending' and t.statutory;
  if v_stat is not null then
    raise exception 'a statutory step is still open: %. Finish it, or record it as received on paper', v_stat using errcode = '23514'; end if;
  select count(*) into n_open from public.onboarding_tasks t where t.employee_id = u.id and t.status = 'pending';
  if n_open > 0 and length(v_why) < 5 then
    raise exception 'steps are still open (%): give a reason to mark as joined now', n_open using errcode = '23514'; end if;
  update public.app_users set status = 'active' where id = u.id;
  perform app.audit(case when by_admin then 'hr_admin_activated_by_admin' else 'activated' end, u.id,
    jsonb_build_object('name', u.display_name, 'from', u.status, 'tasks_open', n_open), by_admin);
  if n_open > 0 then
    perform app.audit('activated_with_open_steps', u.id,
      jsonb_build_object('name', u.display_name, 'open', n_open, 'reason', left(app.scrub_numbers(v_why), 300)), true);
  end if;
  return 'active';
end $function$;

CREATE OR REPLACE FUNCTION app.add_hr_note(p_employee uuid, p_note text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise();
begin
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(p_employee)) then
    raise exception 'only HR writes HR notes' using errcode = '42501'; end if;
  insert into public.employee_notes (employee_id, note, written_by) values (p_employee, btrim(p_note), me);
end $function$;

CREATE OR REPLACE FUNCTION app.complete_task(p_task uuid, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; as_hr boolean; d jsonb := coalesce(p_data, '{}'::jsonb);
        g jsonb; n_open int;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  as_hr := (((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(u.id))
            -- H2 (migration 38): the admin does the HR and IT steps on the HR Admin's own checklist (nobody else can)
            or (app.is_admin() and u.system_role = 'hr_admin' and t.owner <> 'hire')) and u.id <> me;
  if not (as_hr or (t.employee_id = me and t.owner = 'hire')) then
    raise exception 'this task is not yours to complete' using errcode = '42501'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  if t.status = 'done' then raise exception 'this task is already done' using errcode = '23514'; end if;

  -- A1 (migration 37): numbers no longer come through here at all. They go to the id-numbers function, which keeps
  -- an HMAC and the last 4 (app.record_id_number); this step only checks that it was done. An app from before sends
  -- the last 4 here: refused, with words that say what to do. Nothing of what was sent is repeated in the answer.
  if d ?| array['pan_last4', 'aadhaar_last4', 'bank_last4', 'pf_uan_last4', 'pan', 'aadhaar', 'uan', 'account', 'bank_account'] then
    raise exception 'this version of the app is out of date: reload the page and enter the number again' using errcode = '23514'; end if;
  -- B2: a hire's step opens when the steps it depends on are done (HR is not held by it)
  if not as_hr and exists (select 1 from public.onboarding_tasks x
                            where x.employee_id = t.employee_id and x.code = any (t.depends_on) and x.status = 'pending') then
    raise exception 'this step opens after: %', (select string_agg(x.title, ', ' order by x.seq) from public.onboarding_tasks x
                            where x.employee_id = t.employee_id and x.code = any (t.depends_on) and x.status = 'pending')
      using errcode = '23514'; end if;

  case t.kind
    when 'sign' then
      if not as_hr and coalesce((d->>'acknowledged')::boolean, false) is not true then
        raise exception 'tick the box to say you have read and signed' using errcode = '23514'; end if;
    when 'identity' then
      -- A1/A2: the PAN or the Aadhaar was checked by the id-numbers function; a masked Aadhaar image is optional
      if not exists (select 1 from public.employee_docs x where x.employee_id = u.id and (x.pan_hmac is not null or x.aadhaar_hmac is not null)) then
        raise exception 'enter your PAN or your Aadhaar number first' using errcode = '23514'; end if;
    when 'personal' then
      -- A3: what the statutory forms need
      begin
        if coalesce(d->>'date_of_birth', '') = '' or (d->>'date_of_birth')::date > app.today() - 14 * 365 or (d->>'date_of_birth')::date < date '1930-01-01' then
          raise exception 'give your date of birth' using errcode = '23514'; end if;
      exception when invalid_datetime_format or datetime_field_overflow then
        raise exception 'give your date of birth' using errcode = '23514';
      end;
      if coalesce(d->>'relative_kind', '') not in ('father', 'spouse') or coalesce(btrim(d->>'relative_name'), '') = '' then
        raise exception 'give your father''s or your spouse''s name' using errcode = '23514'; end if;
      if coalesce(btrim(d->>'present_address'), '') = '' or coalesce(btrim(d->>'permanent_address'), '') = '' then
        raise exception 'give your present and your permanent address' using errcode = '23514'; end if;
      if coalesce(btrim(d->>'emergency_name'), '') = '' or coalesce(btrim(d->>'emergency_relation'), '') = ''
         or app.normalise_in_mobile(d->>'emergency_phone') is null then
        raise exception 'give an emergency contact: name, relation and a 10-digit mobile number' using errcode = '23514'; end if;
      insert into public.employee_personal (employee_id, date_of_birth, relative_kind, relative_name, present_address, permanent_address,
                                            emergency_name, emergency_relation, emergency_phone, updated_by, updated_at)
      values (u.id, (d->>'date_of_birth')::date, d->>'relative_kind', left(btrim(d->>'relative_name'), 120), left(btrim(d->>'present_address'), 500),
              left(btrim(d->>'permanent_address'), 500), left(btrim(d->>'emergency_name'), 120), left(btrim(d->>'emergency_relation'), 60),
              app.normalise_in_mobile(d->>'emergency_phone'), me, now())
      on conflict (employee_id) do update set date_of_birth = excluded.date_of_birth, relative_kind = excluded.relative_kind,
             relative_name = excluded.relative_name, present_address = excluded.present_address, permanent_address = excluded.permanent_address,
             emergency_name = excluded.emergency_name, emergency_relation = excluded.emergency_relation,
             emergency_phone = excluded.emergency_phone, updated_by = me, updated_at = now();
      -- the audit line says that it happened, never what was given
      perform app.audit('personal_details_saved', u.id, jsonb_build_object('name', u.display_name));
    when 'bank' then
      if coalesce(btrim(d->>'bank_name'), '') = '' then
        raise exception 'give the name of the bank' using errcode = '23514'; end if;
      if not exists (select 1 from public.employee_docs x where x.employee_id = u.id and x.bank_hmac is not null) then
        raise exception 'enter the account number first' using errcode = '23514'; end if;
      update public.employee_docs set bank_name = left(btrim(d->>'bank_name'), 120), updated_at = now() where employee_id = u.id;
    when 'nomination' then
      if coalesce(btrim(d->>'gratuity_nominee'), '') = '' or coalesce(btrim(d->>'nominee_relation'), '') = '' then
        raise exception 'the nominee''s name and relation are required' using errcode = '23514'; end if;
      update public.employee_docs set gratuity_nominee = btrim(d->>'gratuity_nominee'), nominee_relation = btrim(d->>'nominee_relation'),
             updated_at = now() where employee_id = u.id;
    when 'buddy' then
      if coalesce(d->>'buddy', '') = '' and (select buddy from public.employee_org where employee_id = u.id) is null then
        raise exception 'choose the buddy first' using errcode = '23514'; end if;
      if coalesce(d->>'buddy', '') <> '' then
        update public.employee_org set buddy = (d->>'buddy')::uuid, updated_by = me, updated_at = now() where employee_id = u.id;
      end if;
    when 'goals' then
      for g in select * from jsonb_array_elements(coalesce(d->'goals', '[]'::jsonb)) loop
        insert into public.employee_goals (employee_id, horizon, goal, set_by) values (u.id, (g->>'horizon')::int, btrim(g->>'goal'), me);
      end loop;
      if (select count(distinct horizon) from public.employee_goals where employee_id = u.id) < 3 then
        raise exception 'set at least one goal each for 30, 60 and 90 days' using errcode = '23514'; end if;
    else null;
  end case;

  update public.onboarding_tasks set status = 'done', done_at = now(), done_by = me, note = nullif(btrim(d->>'note'), '') where id = t.id;
  if app.is_admin() and u.system_role = 'hr_admin' then
    perform app.audit('hr_admin_task_by_admin', u.id, jsonb_build_object('name', u.display_name, 'task', t.title), true); end if;
  select count(*) into n_open from public.onboarding_tasks where employee_id = u.id and status = 'pending';
  -- Everything done: the joiner is active without HR having to press anything.
  if n_open = 0 and u.status = 'onboarding' then
    update public.app_users set status = 'active' where id = u.id;
    perform app.audit('activated', u.id, jsonb_build_object('name', u.display_name, 'from', 'onboarding', 'how', 'checklist complete'));
  end if;
  return jsonb_build_object('ok', true, 'open', n_open, 'status', (select status from public.app_users where id = u.id));
end $function$;

CREATE OR REPLACE FUNCTION app.confirm_masked(p_file uuid, p_masked boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); f public.employee_files; u public.app_users; reopened int := 0;
begin
  select * into f from public.employee_files where id = p_file;
  if f.id is null then raise exception 'file not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = f.employee_id;
  if not (app.acts_as_hr() and app.hr_may_manage_person(u.id) and u.id <> me) then
    raise exception 'only HR checks a card image' using errcode = '42501'; end if;
  if f.removed_at is not null then raise exception 'this image was deleted already' using errcode = '23514'; end if;
  update public.employee_files set masked = case when p_masked then 'yes' else 'no' end, masked_by = me, masked_at = now() where id = f.id;
  if p_masked then
    perform app.audit('card_masked_confirmed', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind));
  else
    update public.onboarding_tasks set status = 'pending', done_at = null, done_by = null,
           note = 'asked again: a masked Aadhaar (only the last 4 digits visible)'
     where employee_id = u.id and kind = 'identity' and status = 'done';
    get diagnostics reopened = row_count;
    perform app.audit('card_not_masked', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind,
            'asked_again', reopened > 0), true);
  end if;
  return jsonb_build_object('path', f.storage_path, 'delete', not p_masked);
end $function$;

CREATE OR REPLACE FUNCTION app.id_number_target(p_task uuid, p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; as_hr boolean;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  as_hr := app.acts_as_hr() and app.hr_may_manage_person(u.id) and u.id <> me;
  if not (as_hr or (t.employee_id = me and t.owner = 'hire')) then
    raise exception 'this step is not yours' using errcode = '42501'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  if t.status <> 'pending' then raise exception 'this step is done already' using errcode = '23514'; end if;
  if not ((p_kind in ('pan', 'aadhaar') and t.kind = 'identity') or (p_kind = 'bank' and t.kind = 'bank') or (p_kind = 'uan' and t.kind = 'nomination')) then
    raise exception 'this step does not take that number' using errcode = '23514'; end if;
  return jsonb_build_object('employee_id', u.id, 'actor_id', me);
end $function$;

CREATE OR REPLACE FUNCTION app.invite_targets(p_employees uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); ok jsonb := '[]'::jsonb; skipped jsonb := '[]'::jsonb; u public.app_users; e uuid;
begin
  if not app.acts_as_hr() then raise exception 'only HR sends invites' using errcode = '42501'; end if;
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  foreach e in array coalesce(p_employees, '{}') loop
    select * into u from public.app_users where id = e and not external;
    if u.id is null or u.id = me or not app.hr_may_manage_person(u.id) then
      skipped := skipped || jsonb_build_object('id', e, 'name', u.display_name, 'reason', 'not_allowed');
    elsif u.status not in ('invited', 'onboarding') then
      skipped := skipped || jsonb_build_object('id', e, 'name', u.display_name, 'reason', 'not_joining');
    elsif app.email_key(u.email) is null then
      skipped := skipped || jsonb_build_object('id', e, 'name', u.display_name, 'reason', 'no_email');
    else
      ok := ok || jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email);
    end if;
  end loop;
  return jsonb_build_object('actor', me, 'people', ok, 'skipped', skipped);
end $function$;

CREATE OR REPLACE FUNCTION app.joiner_detail(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; o public.employee_org; d public.employee_docs; tp public.onboarding_templates; j jsonb; v_full boolean;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  v_full := app.acts_as_hr() and app.hr_covers(u.id);   -- migration 39: an HR resource, for the people of her states
  -- H2: the admin also opens the HR Admin's page (her steps; not her HR file)
  if u.id is null or not (v_full or (app.is_admin() and u.system_role = 'hr_admin')) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  select * into d from public.employee_docs where employee_id = u.id;
  select * into tp from public.onboarding_templates
   where id = coalesce(o.template_id, (select id from public.onboarding_templates where is_default and active limit 1));
  j := jsonb_build_object(
    'person', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
               'system_role', u.system_role, 'join_date', u.join_date, 'created_at', u.created_at,
               'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
               'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
               'created_by', (select display_name from public.app_users where id = u.created_by)),
    'can_manage', app.hr_may_manage_person(u.id) and u.id <> app.current_user_id(),
    -- "Mark as joined", exactly as app.activate_joiner decides it
    'can_activate', u.status in ('invited', 'onboarding') and u.id <> app.current_user_id()
                    and ((app.is_admin() and u.system_role = 'hr_admin') or (app.is_hr() and app.hr_may_manage_person(u.id))),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to', o.reports_to, 'buddy', o.buddy,
             'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'docs', jsonb_build_object('pan_last4', d.pan_last4, 'aadhaar_last4', d.aadhaar_last4, 'bank_name', d.bank_name, 'bank_ifsc', d.bank_ifsc,
             'bank_last4', d.bank_last4, 'pf_uan_last4', d.pf_uan_last4, 'gratuity_nominee', d.gratuity_nominee,
             'nominee_relation', d.nominee_relation, 'form16_ref', d.form16_ref,
             'pan_card_seen_by', (select display_name from public.app_users where id = d.pan_card_seen_by), 'pan_card_seen_at', d.pan_card_seen_at),
    -- A1: per number, whether it was checked for duplicates ("not checked": entered before migration 37, last 4 only)
    'checked', jsonb_build_object(
       'pan', case when d.pan_hmac is not null then 'checked' when d.pan_last4 is not null then 'not_checked' end,
       'aadhaar', case when d.aadhaar_hmac is not null then 'checked' when d.aadhaar_last4 is not null then 'not_checked' end,
       'uan', case when d.uan_hmac is not null then 'checked' when d.pf_uan_last4 is not null then 'not_checked' end,
       'bank', case when d.bank_hmac is not null then 'checked' when d.bank_last4 is not null then 'not_checked' end),
    -- A1: numbers that matched another person's: refused (PAN, Aadhaar, UAN) or a warning to accept (bank)
    'matches', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'kind', m.kind, 'outcome', m.outcome, 'last4', m.last4,
               'matched_id', m.matched_employee, 'matched_name', (select display_name from public.app_users where id = m.matched_employee),
               'at', m.created_at, 'accepted_at', m.accepted_at, 'accept_reason', m.accept_reason,
               'accepted_by', (select display_name from public.app_users where id = m.accepted_by)) order by m.created_at desc)
               from public.id_number_matches m where m.employee_id = u.id), '[]'::jsonb),
    'personal', (select jsonb_build_object('date_of_birth', x.date_of_birth, 'relative_kind', x.relative_kind, 'relative_name', x.relative_name,
                   'present_address', x.present_address, 'permanent_address', x.permanent_address, 'emergency_name', x.emergency_name,
                   'emergency_relation', x.emergency_relation, 'emergency_phone', x.emergency_phone, 'updated_at', x.updated_at)
                   from public.employee_personal x where x.employee_id = u.id),
    'first_day', jsonb_build_object(
       'date', o.first_day_date, 'time', o.first_day_time, 'place', o.first_day_place, 'ask_for', o.first_day_ask_for, 'bring', o.first_day_bring,
       'default_date', u.join_date, 'default_time', tp.first_day_time, 'default_place', tp.first_day_place,
       'default_ask_for', tp.first_day_ask_for, 'default_bring', tp.first_day_bring),
    'files', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'kind', f.kind, 'file_name', f.file_name, 'storage_path', f.storage_path,
               'sha256', f.sha256, 'task_id', f.task_id, 'created_at', f.created_at, 'masked', f.masked, 'masked_at', f.masked_at,
               'masked_by', (select display_name from public.app_users where id = f.masked_by), 'removed_at', f.removed_at,
               'uploaded_by', (select display_name from public.app_users where id = f.uploaded_by)) order by f.created_at)
               from public.employee_files f where f.employee_id = u.id), '[]'::jsonb),
    'tasks', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'seq', t.seq, 'code', t.code, 'title', t.title, 'owner', t.owner,
               'due_on', t.due_on, 'statutory', t.statutory, 'kind', t.kind, 'status', t.status, 'done_at', t.done_at, 'note', t.note,
               'overdue', t.status = 'pending' and t.due_on < app.today(), 'depends_on', to_jsonb(t.depends_on),
               'done_by', (select display_name from public.app_users where id = t.done_by)) order by t.seq)
               from public.onboarding_tasks t where t.employee_id = u.id), '[]'::jsonb),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'note', n.note, 'at', n.created_at,
               'by', (select display_name from public.app_users where id = n.written_by)) order by n.created_at desc)
               from public.employee_notes n where n.employee_id = u.id), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'horizon', g.horizon, 'goal', g.goal) order by g.horizon, g.created_at)
               from public.employee_goals g where g.employee_id = u.id), '[]'::jsonb),
    'exits', coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason, 'final_settlement', e.final_settlement,
               'form16_ref', e.form16_ref, 'at', e.created_at) order by e.created_at desc)
               from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb),
    'assignments', (select count(*) from public.assignments a where a.employee_id = u.id and a.active)
  );
  if not v_full then j := j - 'docs' - 'checked' - 'matches' - 'personal' - 'files' - 'notes' - 'exits'; end if;
  return j || jsonb_build_object(
    'role', jsonb_build_object('role', o.intended_role, 'stage', o.intended_stage, 'opening_id', o.opening_id,
               'opening_code', (select code from public.openings where id = o.opening_id),
               'state_name', (select s.name from public.openings op join public.states s on s.id = op.state_id where op.id = o.opening_id)),
    'hr_owner', (select jsonb_build_object('id', h.id, 'name', h.display_name) from public.app_users h where h.id = o.hr_owner),
    'invite', (select jsonb_build_object('state', case when i.used_at is not null then 'accepted' when i.revoked_at is not null then 'replaced'
                  when i.expires_at < now() then 'expired' else i.send_status end, 'at', i.created_at, 'expires_at', i.expires_at)
                from public.invites i where i.employee_id = u.id order by (i.revoked_at is null) desc, i.created_at desc limit 1),
    'activation', app.activation_state(u.id),
    'can_do_steps', (app.hr_may_manage_person(u.id) or (app.is_admin() and u.system_role = 'hr_admin')) and u.id <> app.current_user_id(),
    'can_invite', v_full and app.hr_may_manage_person(u.id) and u.id <> app.current_user_id() and u.status in ('invited', 'onboarding'));
end $function$;

CREATE OR REPLACE FUNCTION app.link_to_opening(p_employees uuid[], p_opening uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.openings; u public.app_users; filled int; out jsonb := '[]'::jsonb; e uuid;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR links people to openings' using errcode = '42501'; end if;
  select * into o from public.openings where id = p_opening for update;
  if o.id is null then raise exception 'unknown opening' using errcode = 'P0002'; end if;
  if o.status = 'closed' then raise exception 'this opening is closed' using errcode = '23514'; end if;
  if not app.hr_full() and not (o.state_id = any(app.my_hr_states())) then
    raise exception 'this opening is not in your states' using errcode = '42501'; end if;
  perform set_config('app.org_fn', 'on', true);
  foreach e in array coalesce(p_employees, '{}') loop
    select * into u from public.app_users where id = e and not external;
    select count(*) into filled from public.employee_org x join public.app_users y on y.id = x.employee_id
     where x.opening_id = o.id and y.status in ('invited', 'onboarding', 'active');
    if u.id is null or not app.hr_may_manage_person(u.id) then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', 'not_allowed');
    elsif u.status not in ('invited', 'onboarding', 'active') then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', 'not_working');
    elsif exists (select 1 from public.employee_org x where x.employee_id = u.id and x.opening_id = o.id) then
      out := out || jsonb_build_object('id', e, 'ok', true, 'already', true);
    elsif filled >= o.positions then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', 'opening_full');
    else
      insert into public.employee_org (employee_id, updated_by) values (u.id, app.current_user_id()) on conflict (employee_id) do nothing;
      update public.employee_org set opening_id = o.id, intended_role = o.role, intended_stage = o.stage, updated_at = now() where employee_id = u.id;
      perform app.audit('opening_linked', u.id, jsonb_build_object('name', u.display_name, 'opening', o.code));
      out := out || jsonb_build_object('id', e, 'ok', true);
    end if;
  end loop;
  perform set_config('app.org_fn', '', true);
  return jsonb_build_object('opening', app.opening_json(o), 'results', out);
end $function$;

CREATE OR REPLACE FUNCTION app.may_manage_person(p_employee uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee;
  if me is null or u.id is null or u.id = me then return false; end if;
  if u.external then return app.manages_viewer(u.id); end if;
  return (app.is_admin() or app.is_hr()) and app.hr_may_manage_person(u.id);
end $function$;

CREATE OR REPLACE FUNCTION app.may_remove_hr_file(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.acts_as_hr() and exists (
    select 1 from public.employee_files f join public.app_users u on u.id = f.employee_id
     where f.storage_path = p_name and f.masked = 'no' and f.removed_at is null
       and app.hr_may_manage_person(u.id) and u.id <> app.current_user_id())
$function$;

CREATE OR REPLACE FUNCTION app.note_file_removed(p_file uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); f public.employee_files; u public.app_users;
begin
  select * into f from public.employee_files where id = p_file;
  if f.id is null then raise exception 'file not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = f.employee_id;
  if not (app.acts_as_hr() and app.hr_may_manage_person(u.id) and u.id <> me) then
    raise exception 'only HR deletes a card image' using errcode = '42501'; end if;
  if f.masked is distinct from 'no' then raise exception 'only an image HR found not masked is deleted' using errcode = '23514'; end if;
  if f.removed_at is not null then return; end if;
  if exists (select 1 from storage.objects o where o.bucket_id = 'hr-docs' and o.name = f.storage_path) then
    raise exception 'the image is still in the store: delete it first' using errcode = '23514'; end if;
  update public.employee_files set removed_at = now(), removed_by = me where id = f.id;
  perform app.audit('hr_file_removed', u.id, jsonb_build_object('name', u.display_name, 'file', f.file_name, 'kind', f.kind,
          'why', 'not masked'), true);
end $function$;

CREATE OR REPLACE FUNCTION app.record_card_seen(p_employee uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not (app.acts_as_hr() and app.hr_may_manage_person(u.id) and u.id <> me) then
    raise exception 'only HR records a card as seen' using errcode = '42501'; end if;
  insert into public.employee_docs (employee_id) values (u.id) on conflict (employee_id) do nothing;
  update public.employee_docs set pan_card_seen_by = me, pan_card_seen_at = now(), updated_at = now() where employee_id = u.id;
  perform app.audit('pan_card_seen', u.id, jsonb_build_object('name', u.display_name));
end $function$;

CREATE OR REPLACE FUNCTION app.record_on_paper(p_task uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; n_open int;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  if not ((((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(u.id)) or (app.is_admin() and u.system_role = 'hr_admin'))
          and u.id <> me) then
    raise exception 'only HR records a step as received on paper' using errcode = '42501'; end if;
  if not t.statutory then raise exception 'only a statutory step is recorded as received on paper' using errcode = '23514'; end if;
  if t.status <> 'pending' then raise exception 'this step is done already' using errcode = '23514'; end if;
  if u.status in ('suspended', 'offboarded') then raise exception 'this person is %', u.status using errcode = '42501'; end if;
  update public.onboarding_tasks set status = 'done', done_at = now(), done_by = me,
         note = left('received on paper by HR' || coalesce(': ' || nullif(app.scrub_numbers(btrim(p_note)), ''), ''), 300)
   where id = t.id;
  perform app.audit('statutory_on_paper', u.id, jsonb_build_object('name', u.display_name, 'task', t.title), true);
  select count(*) into n_open from public.onboarding_tasks where employee_id = u.id and status = 'pending';
  if n_open = 0 and u.status = 'onboarding' then
    update public.app_users set status = 'active' where id = u.id;
    perform app.audit('activated', u.id, jsonb_build_object('name', u.display_name, 'from', 'onboarding', 'how', 'checklist complete'));
  end if;
  return jsonb_build_object('ok', true, 'open', n_open, 'status', (select status from public.app_users where id = u.id));
end $function$;

CREATE OR REPLACE FUNCTION app.register_hr_file(p_employee uuid, p_kind text, p_path text, p_sha256 text, p_file_name text DEFAULT NULL::text, p_task uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); v_id uuid;
begin
  if not (p_employee = me or ((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(p_employee))) then
    raise exception 'not allowed to add a document for this person' using errcode = '42501'; end if;
  if p_path is distinct from format('%s/%s', p_employee, split_part(p_path, '/', 2)) or split_part(p_path, '/', 2) = '' then
    raise exception 'document path must be <person>/<file>' using errcode = '23514'; end if;
  -- A2 (11 Oct 2026): a full PAN or Aadhaar card image shows the whole number: only a masked Aadhaar is kept
  if p_kind in ('pan', 'aadhaar') then
    raise exception 'a photo of a full PAN or Aadhaar card is not kept: upload the masked Aadhaar (only the last 4 digits visible)' using errcode = '23514'; end if;
  if p_task is not null and not exists (select 1 from public.onboarding_tasks t where t.id = p_task and t.employee_id = p_employee) then
    raise exception 'that task belongs to someone else' using errcode = '23514'; end if;
  insert into public.employee_files (employee_id, kind, storage_path, file_name, sha256, task_id, uploaded_by)
  values (p_employee, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_task, me) returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION app.reopen_task(p_task uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(t.employee_id)) then
    raise exception 'only HR reopens a task' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  update public.onboarding_tasks set status = 'pending', done_at = null, done_by = null, note = 'reopened: ' || btrim(p_reason) where id = p_task;
end $function$;

CREATE OR REPLACE FUNCTION app.reset_login_allowed(p_target uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); tgt public.app_users;
begin
  if me is null or p_target is null or p_target = me then return false; end if;      -- your own: change it yourself
  select * into tgt from public.app_users where id = p_target;
  if tgt.id is null or tgt.status = 'offboarded' then return false; end if;
  -- the admin: the HR Admin's and another admin's password (nobody else may reset them), and HR's work while the seat is empty
  if app.is_admin() and not tgt.external and (tgt.system_role in ('hr_admin', 'admin') or app.hr_may_manage_person(tgt.id)) then return true; end if;
  if tgt.external then
    return exists (select 1 from public.assignments a
                    where a.employee_id = tgt.id and a.active and a.lens = 'client' and app.manages_client(me, a.client_id));
  end if;
  return app.is_hr() and app.hr_may_manage_person(tgt.id);
end $function$;

CREATE OR REPLACE FUNCTION app.set_goals(p_employee uuid, p_goals jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); g jsonb; n int := 0;
begin
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(p_employee)) then
    raise exception 'only HR sets goals' using errcode = '42501'; end if;
  delete from public.employee_goals where employee_id = p_employee;
  for g in select * from jsonb_array_elements(coalesce(p_goals, '[]'::jsonb)) loop
    if coalesce(btrim(g->>'goal'), '') <> '' then
      insert into public.employee_goals (employee_id, horizon, goal, set_by) values (p_employee, (g->>'horizon')::int, btrim(g->>'goal'), me);
      n := n + 1;
    end if;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION app.set_hr_owner(p_employees uuid[], p_owner uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare e uuid; u public.app_users; out jsonb := '[]'::jsonb; n_ok int := 0; v_name text;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR shares out the work' using errcode = '42501'; end if;
  if p_owner is not null then
    select display_name into v_name from public.app_users where id = p_owner and status = 'active' and system_role in ('hr_admin', 'hr_resource');
    if v_name is null then raise exception 'the HR owner must be an active HR person' using errcode = '23514'; end if;
  end if;
  perform set_config('app.org_fn', 'on', true);
  foreach e in array coalesce(p_employees, '{}') loop
    select * into u from public.app_users where id = e and not external;
    if u.id is null or not app.hr_may_manage_person(u.id) then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', 'not_allowed');
    else
      insert into public.employee_org (employee_id, updated_by) values (u.id, app.current_user_id()) on conflict (employee_id) do nothing;
      update public.employee_org set hr_owner = p_owner, updated_at = now() where employee_id = u.id;
      perform app.audit('hr_owner_set', u.id, jsonb_build_object('name', u.display_name, 'owner', v_name));
      out := out || jsonb_build_object('id', e, 'ok', true); n_ok := n_ok + 1;
    end if;
  end loop;
  perform set_config('app.org_fn', '', true);
  return jsonb_build_object('done', n_ok, 'results', out);
end $function$;

CREATE OR REPLACE FUNCTION app.set_intended_role(p_employee uuid, p_role text, p_stage stage_type DEFAULT NULL::stage_type)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or not (app.acts_as_hr() and app.hr_may_manage_person(u.id)) then
    raise exception 'only HR sets a person''s role' using errcode = '42501'; end if;
  if exists (select 1 from public.employee_org where employee_id = u.id and opening_id is not null) then
    raise exception 'this person is on an opening: the role is the opening''s' using errcode = '23514'; end if;
  if p_role is not null and p_role not in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other') then
    raise exception 'unknown role' using errcode = '23514'; end if;
  perform set_config('app.org_fn', 'on', true);
  insert into public.employee_org (employee_id, updated_by) values (u.id, app.current_user_id()) on conflict (employee_id) do nothing;
  update public.employee_org set intended_role = p_role, intended_stage = case when p_role = 'operator' then p_stage end, updated_at = now()
   where employee_id = u.id;
  perform set_config('app.org_fn', '', true);
  perform app.audit('intended_role_set', u.id, jsonb_build_object('name', u.display_name, 'role', p_role, 'stage', p_stage));
end $function$;

CREATE OR REPLACE FUNCTION app.update_joiner(p_employee uuid, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; v_join date; delta int;
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if not ((app.is_admin() or app.is_hr()) and app.hr_may_manage_person(u.id)) then
    raise exception 'only HR edits a person''s record' using errcode = '42501'; end if;
  insert into public.employee_org (employee_id, updated_by) values (u.id, me) on conflict (employee_id) do nothing;
  update public.employee_org set
    employment_type  = coalesce(nullif(p->>'employment_type', '')::public.employment_type, employment_type),
    designation_band = case when p ? 'designation_band' then nullif(btrim(p->>'designation_band'), '') else designation_band end,
    department       = case when p ? 'department' then nullif(btrim(p->>'department'), '') else department end,
    job_title        = case when p ? 'job_title' then nullif(btrim(p->>'job_title'), '') else job_title end,
    reports_to       = case when p ? 'reports_to' then nullif(p->>'reports_to', '')::uuid else reports_to end,
    buddy            = case when p ? 'buddy' then nullif(p->>'buddy', '')::uuid else buddy end,
    -- B6: the first day, as HR sets it for this joiner (empty: the template's default, or the join date)
    first_day_date   = case when p ? 'first_day_date' then nullif(p->>'first_day_date', '')::date else first_day_date end,
    first_day_time   = case when p ? 'first_day_time' then nullif(left(btrim(p->>'first_day_time'), 40), '') else first_day_time end,
    first_day_place  = case when p ? 'first_day_place' then nullif(left(btrim(p->>'first_day_place'), 300), '') else first_day_place end,
    first_day_ask_for = case when p ? 'first_day_ask_for' then nullif(left(btrim(p->>'first_day_ask_for'), 120), '') else first_day_ask_for end,
    first_day_bring  = case when p ? 'first_day_bring' then nullif(left(btrim(p->>'first_day_bring'), 300), '') else first_day_bring end,
    updated_by = me, updated_at = now()
  where employee_id = u.id;
  if coalesce(p->>'join_date', '') <> '' then
    v_join := (p->>'join_date')::date;
    if u.join_date is distinct from v_join then
      delta := v_join - coalesce(u.join_date, v_join);
      update public.app_users set join_date = v_join where id = u.id;
      -- B1: a step made from a template keeps its offset: the later of (new join date + offset) and (date added + 3)
      update public.onboarding_tasks set due_on = case when due_offset_days is null then due_on + delta
                                                       else greatest(v_join + due_offset_days, created_at::date + 3) end
       where employee_id = u.id and status = 'pending';
    end if;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION app.note_invite_sent(p_employee uuid, p_how text DEFAULT 'password'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise();
begin
  if not ((app.is_admin() and not app.hr_seat_filled()) or (app.is_hr() and app.hr_covers(p_employee)) or app.manages_viewer(p_employee)) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  perform app.audit('invite_sent', p_employee, jsonb_build_object('how', left(coalesce(p_how, 'password'), 40)));
end $function$;

CREATE OR REPLACE FUNCTION app.add_joiner(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); my_role public.system_role; v_role public.system_role;
        v_name text := btrim(coalesce(p->>'full_name', '')); v_email text := app.email_key(p->>'personal_email');
        v_phone text; v_join date; v_type public.employment_type; v_tpl uuid; v_id uuid; n int;
        op public.openings; v_irole text; v_istage public.stage_type; v_owner uuid; filled int;
        v_bstate uuid; v_bdist text; v_mine uuid[] := app.my_hr_states();
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  if my_role is null or my_role not in ('admin', 'hr_admin', 'hr_resource') then
    raise exception 'only HR adds a joiner' using errcode = '42501'; end if;

  -- the opening (or the role) first: an HR opening makes an HR person
  if nullif(p->>'opening_id', '') is not null then
    select * into op from public.openings where id = (p->>'opening_id')::uuid for update;
    if op.id is null then raise exception 'unknown opening' using errcode = '23514'; end if;
    if op.status <> 'open' then raise exception 'this opening is not open (%)', replace(op.status, '_', ' ') using errcode = '23514'; end if;
    select count(*) into filled from public.employee_org e join public.app_users u on u.id = e.employee_id
     where e.opening_id = op.id and u.status in ('invited', 'onboarding', 'active');
    if filled >= op.positions then
      raise exception 'this opening is full (% of % positions)', filled, op.positions using errcode = '23514'; end if;
    v_irole := op.role; v_istage := op.stage;
  else
    v_irole := nullif(p->>'intended_role', '');
    if v_irole is not null and v_irole not in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other') then
      raise exception 'unknown role' using errcode = '23514'; end if;
    v_istage := case when v_irole = 'operator' then nullif(p->>'intended_stage', '')::public.stage_type end;
  end if;

  v_role := coalesce(nullif(p->>'system_role', ''), case when v_irole = 'hr' then 'hr_resource' else 'operational' end)::public.system_role;
  -- An admin is never made in the app: the database owner runs the break-glass script (docs/OPERATIONS.md).
  if v_role = 'admin' then
    raise exception 'not allowed here: an admin is made only by the database owner (break-glass script)' using errcode = '42501'; end if;
  -- The admin adds one kind of person: the one for the HR Admin seat, and only while that seat is empty.
  if my_role = 'admin' and app.hr_seat_filled() then
    raise exception 'only HR adds joiners now: the HR Admin seat is filled' using errcode = '42501'; end if;
  if my_role = 'admin' and v_role not in ('hr_resource', 'hr_admin') then
    raise exception 'only HR adds joiners: the admin adds only the person for the HR Admin seat (system role HR)' using errcode = '42501'; end if;
  -- the HR Admin seat is the admin's to give
  if v_role = 'hr_admin' and my_role <> 'admin' then
    raise exception 'only the admin gives the % seat', v_role using errcode = '42501'; end if;
  if v_role = 'hr_admin' and exists (select 1 from public.app_users where system_role = 'hr_admin' and status <> 'offboarded') then
    raise exception 'the HR Admin seat is taken: there is exactly one' using errcode = '23514'; end if;

  if v_name = '' then raise exception 'full name is required' using errcode = '23514'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid personal email is required: it is the sign-in' using errcode = '23514'; end if;
  -- A4 (11 Oct 2026): phone is required; it is the field staff's main identifier
  if coalesce(btrim(p->>'phone'), '') = '' then raise exception 'phone is required' using errcode = '23514'; end if;
  v_phone := app.normalise_in_mobile(p->>'phone');
  if v_phone is null then raise exception 'phone must be a 10-digit Indian mobile number' using errcode = '23514'; end if;
  begin v_join := (p->>'join_date')::date; exception when others then v_join := null; end;
  if v_join is null then raise exception 'join date is required' using errcode = '23514'; end if;
  begin v_type := coalesce(nullif(p->>'employment_type', ''), 'full_time')::public.employment_type;
  exception when others then raise exception 'unknown employment type' using errcode = '23514'; end;
  -- D: the checklist for the role
  v_tpl := coalesce(nullif(p->>'template_id', '')::uuid,
                    (select id from public.onboarding_templates where role = v_irole and active limit 1),
                    (select id from public.onboarding_templates where is_default and active limit 1));
  if v_tpl is null or not exists (select 1 from public.onboarding_templates where id = v_tpl and active) then
    raise exception 'no onboarding template: make one under HR → Templates' using errcode = '23514'; end if;
  -- E1: the HR owner (by default the HR person adding)
  v_owner := coalesce(nullif(p->>'hr_owner', '')::uuid, case when my_role in ('hr_admin', 'hr_resource') then me end);
  if v_owner is not null and not exists (select 1 from public.app_users where id = v_owner and status = 'active'
                                             and system_role in ('hr_admin', 'hr_resource')) then
    raise exception 'the HR owner must be an active HR person' using errcode = '23514'; end if;
  -- where the person is based (migration 39): given, else the opening's state, else the one state an HR resource has
  v_bstate := coalesce(nullif(p->>'base_state_id', '')::uuid, op.state_id,
                       case when my_role = 'hr_resource' and cardinality(v_mine) = 1 then v_mine[1] end);
  if v_bstate is not null and not exists (select 1 from public.states where id = v_bstate) then
    raise exception 'unknown state' using errcode = '23514'; end if;
  v_bdist := nullif(left(btrim(coalesce(p->>'base_district', '')), 60), '');
  if my_role = 'hr_resource' then
    if op.id is not null and not (op.state_id = any(v_mine)) then
      raise exception 'this opening is not in your states' using errcode = '42501'; end if;
    if v_bstate is null then raise exception 'choose the state where this person is based' using errcode = '23514'; end if;
    if not (v_bstate = any(v_mine)) then
      raise exception 'that state is not one of yours: ask the HR Admin' using errcode = '42501'; end if;
  end if;

  begin
    insert into public.app_users (display_name, email, phone, status, system_role, join_date, created_by)
    values (v_name, v_email, v_phone, 'invited', v_role, v_join, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email or phone already exists' using errcode = '23505';
  end;
  perform set_config('app.org_fn', 'on', true);
  insert into public.employee_org (employee_id, employment_type, designation_band, department, job_title, reports_to, buddy, updated_by, template_id,
                                   opening_id, intended_role, intended_stage, hr_owner, import_batch, base_state_id, base_district)
  values (v_id, v_type, nullif(btrim(p->>'designation_band'), ''), nullif(btrim(p->>'department'), ''), nullif(btrim(p->>'job_title'), ''),
          nullif(p->>'reports_to', '')::uuid, nullif(p->>'buddy', '')::uuid, me, v_tpl,
          op.id, v_irole, v_istage, v_owner, nullif(left(p->>'import_batch', 60), ''), v_bstate, v_bdist);
  perform set_config('app.org_fn', '', true);
  insert into public.employee_docs (employee_id) values (v_id);
  n := app.stamp_tasks(v_id, v_tpl, v_join, v_type);

  perform app.audit('identity_created', v_id, jsonb_build_object('name', v_name, 'system_role', v_role, 'employment_type', v_type,
                                                                 'join_date', v_join, 'tasks', n, 'opening', op.code, 'role', v_irole,
                                                                 'import_batch', nullif(p->>'import_batch', ''),
                                                                 'based', (select name from public.states where id = v_bstate)));
  if v_role = 'hr_resource' then
    -- an HR resource making another HR resource is allowed, and always flagged for the admin to see
    perform app.audit('hr_resource_created', v_id, jsonb_build_object('name', v_name, 'by_role', my_role), my_role = 'hr_resource');
  end if;
  return jsonb_build_object('id', v_id, 'tasks', n, 'status', 'invited');
end $function$;

CREATE OR REPLACE FUNCTION app.import_joiners(p_rows jsonb, p_dry_run boolean DEFAULT true, p_batch text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); r jsonb; i int := 0; out jsonb := '[]'::jsonb; errs text[]; warns text[]; st text;
        v_email text; v_phone text; v_join date; v_type text; op public.openings; v_rep uuid; by_email uuid; by_phone uuid;
        seen_email text[] := '{}'; seen_phone text[] := '{}'; taken jsonb := '{}'::jsonb; filled int; made jsonb; row_out jsonb;
        n_ready int := 0; n_warn int := 0; n_err int := 0; n_skip int := 0; n_made int := 0; v_batch text;
        v_bstate uuid; v_full boolean := app.hr_full(); v_mine uuid[] := app.my_hr_states();
begin
  if not app.acts_as_hr() then raise exception 'only HR imports joiners' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows must be a list' using errcode = '22023'; end if;
  if jsonb_array_length(p_rows) > 1000 then raise exception 'at most 1000 rows per file' using errcode = '23514'; end if;
  v_batch := coalesce(nullif(left(btrim(p_batch), 60), ''), 'import-' || to_char(now() at time zone 'Asia/Kolkata', 'YYYYMMDD-HH24MISS'));

  for r in select value from jsonb_array_elements(p_rows) loop
    i := i + 1; errs := '{}'; warns := '{}'; op := null; v_rep := null;
    if coalesce(btrim(r->>'full_name'), '') = '' then errs := array_append(errs, 'imp.no_name'::text); end if;
    v_email := app.email_key(r->>'personal_email');
    if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then errs := array_append(errs, 'imp.bad_email'::text); v_email := null; end if;
    if coalesce(btrim(r->>'phone'), '') = '' then errs := array_append(errs, 'imp.no_phone'::text); v_phone := null;
    else v_phone := app.normalise_in_mobile(r->>'phone'); if v_phone is null then errs := array_append(errs, 'imp.bad_phone'::text); end if; end if;
    begin v_join := nullif(btrim(r->>'join_date'), '')::date; exception when others then v_join := null; end;
    if v_join is null then errs := array_append(errs, 'imp.bad_date'::text);
    elsif v_join < app.today() - 60 or v_join > app.today() + 366 then errs := array_append(errs, 'imp.date_range'::text);
    elsif v_join < app.today() then warns := array_append(warns, 'imp.date_past'::text); end if;
    v_type := coalesce(nullif(lower(regexp_replace(btrim(r->>'employment_type'), '[\s-]+', '_', 'g')), ''), 'full_time');
    if v_type not in ('full_time', 'intern', 'contract', 'consultant') then errs := array_append(errs, 'imp.bad_type'::text); end if;
    if coalesce(btrim(r->>'opening'), '') = '' then warns := array_append(warns, 'imp.no_opening'::text);
    else
      select * into op from public.openings where upper(code) = upper(btrim(r->>'opening'));
      if op.id is null then errs := array_append(errs, 'imp.opening_unknown'::text);
      elsif op.status <> 'open' then errs := array_append(errs, 'imp.opening_not_open'::text);
      end if;
    end if;
    if coalesce(btrim(r->>'reports_to'), '') <> '' then
      select id into v_rep from public.app_users where app.email_key(email) = app.email_key(r->>'reports_to') and not external
        and status in ('invited', 'onboarding', 'active');
      if v_rep is null then warns := array_append(warns, 'imp.reports_to_unknown'::text); end if;
    end if;
    -- where the person is based (migration 39): the row's state (name or code), else the opening's
    v_bstate := null;
    if coalesce(btrim(r->>'state'), '') <> '' then
      select id into v_bstate from public.states where lower(name) = lower(btrim(r->>'state')) or upper(code) = upper(btrim(r->>'state')) limit 1;
      if v_bstate is null then errs := array_append(errs, 'imp.state_unknown'::text); end if;
    end if;
    if v_bstate is null and coalesce(btrim(r->>'state'), '') = '' then
      v_bstate := coalesce(op.state_id, case when not v_full and cardinality(v_mine) = 1 then v_mine[1] end); end if;
    if not v_full then
      if (op.id is not null and not (op.state_id = any(v_mine))) or (v_bstate is not null and not (v_bstate = any(v_mine))) then
        errs := array_append(errs, 'imp.not_your_state'::text);
      elsif v_bstate is null and coalesce(btrim(r->>'state'), '') = '' then
        errs := array_append(errs, 'imp.no_state'::text); end if;
    end if;

    -- in the system already?
    by_email := null; by_phone := null;
    if v_email is not null then select id into by_email from public.app_users where app.email_key(email) = v_email; end if;
    if v_phone is not null then select id into by_phone from public.app_users where app.phone_key(phone) = app.phone_key(v_phone); end if;
    st := null;
    if by_email is not null and by_email = by_phone then st := 'skipped';                       -- the same person: added before
    else
      if by_email is not null then errs := array_append(errs, 'imp.email_taken'::text); end if;
      if by_phone is not null then errs := array_append(errs, 'imp.phone_taken'::text); end if;
    end if;
    -- twice in this file?
    if st is null and v_email is not null and v_email = any(seen_email) then errs := array_append(errs, 'imp.email_twice'::text); end if;
    if st is null and v_phone is not null and app.phone_key(v_phone) = any(seen_phone) then errs := array_append(errs, 'imp.phone_twice'::text); end if;
    -- room on the opening, counting the rows above
    if st is null and op.id is not null and op.status = 'open' and cardinality(errs) = 0 then
      select count(*) into filled from public.employee_org e join public.app_users u on u.id = e.employee_id
       where e.opening_id = op.id and u.status in ('invited', 'onboarding', 'active');
      -- the rows above in this file: in a dry run counted here; in a commit they are already made, so counted above
      if coalesce(p_dry_run, true) then filled := filled + coalesce((taken->>op.id::text)::int, 0); end if;
      if filled >= op.positions then errs := array_append(errs, 'imp.opening_full'::text);
      else taken := jsonb_set(taken, array[op.id::text], to_jsonb(coalesce((taken->>op.id::text)::int, 0) + 1)); end if;
    end if;
    if v_email is not null then seen_email := seen_email || v_email; end if;
    if v_phone is not null then seen_phone := seen_phone || app.phone_key(v_phone); end if;

    st := coalesce(st, case when cardinality(errs) > 0 then 'error' when cardinality(warns) > 0 then 'warning' else 'ready' end);
    row_out := jsonb_build_object('row', i, 'name', btrim(coalesce(r->>'full_name', '')), 'email', v_email, 'opening', op.code,
                                  'role', op.role, 'stage', op.stage, 'status', st,
                                  'state', (select name from public.states where id = v_bstate),
                                  'reasons', to_jsonb(case when st = 'skipped' then array['imp.already_added'] else errs || warns end));
    if st = 'skipped' then row_out := row_out || jsonb_build_object('id', by_email); end if;

    if not coalesce(p_dry_run, true) and st in ('ready', 'warning') then
      begin
        made := app.add_joiner(jsonb_build_object('full_name', btrim(r->>'full_name'), 'personal_email', v_email, 'phone', v_phone,
                  'join_date', v_join, 'employment_type', v_type, 'designation_band', nullif(btrim(r->>'designation_band'), ''),
                  'department', nullif(btrim(r->>'department'), ''), 'job_title', nullif(btrim(r->>'job_title'), ''),
                  'reports_to', v_rep, 'opening_id', op.id, 'import_batch', v_batch,
                  'base_state_id', v_bstate, 'base_district', nullif(left(btrim(coalesce(r->>'district', '')), 60), '')));
        row_out := row_out || jsonb_build_object('id', made->>'id', 'created', true);
        n_made := n_made + 1;
      exception when others then
        row_out := row_out || jsonb_build_object('status', 'error', 'reasons', jsonb_build_array('imp.failed'), 'detail', left(sqlerrm, 200));
        st := 'error';
      end;
    end if;
    case st when 'ready' then n_ready := n_ready + 1; when 'warning' then n_warn := n_warn + 1;
            when 'skipped' then n_skip := n_skip + 1; else n_err := n_err + 1; end case;
    out := out || row_out;
  end loop;

  if not coalesce(p_dry_run, true) then
    perform app.audit('joiners_imported', null, jsonb_build_object('batch', v_batch, 'rows', i, 'created', n_made,
                                                                   'skipped', n_skip, 'errors', n_err));
  end if;
  return jsonb_build_object('batch', v_batch, 'dry_run', coalesce(p_dry_run, true), 'rows', out,
    'counts', jsonb_build_object('rows', i, 'ready', n_ready, 'warning', n_warn, 'error', n_err, 'skipped', n_skip, 'created', n_made));
end $function$;

CREATE OR REPLACE FUNCTION app.joiners_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); v_q text := nullif(lower(btrim(p->>'q')), ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid; v_status text := nullif(p->>'status', '');
        v_owner text := nullif(p->>'owner', ''); v_overdue boolean := coalesce((p->>'overdue')::boolean, false);
        v_wait text := nullif(p->>'waiting', ''); v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
        v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0); res jsonb;
        v_full boolean := app.hr_full(); v_mine uuid[] := app.my_hr_states();
begin
  if not app.acts_as_hr() then raise exception 'only HR opens the pipeline' using errcode = '42501'; end if;
  with base as (
    select u.id, u.display_name, u.email, u.phone, u.status, u.system_role, u.join_date, u.auth_uid, u.created_at,
           o.employment_type, o.job_title, o.department, o.opening_id, o.intended_role, o.intended_stage, o.hr_owner,
           o.base_state_id, o.base_district,
           op.code as opening_code, op.state_id as opening_state,
           tk.total, tk.done, tk.overdue,
           -- whose turn: everyone with a step due by today; if nobody's is due yet, whoever has the next step
           case when cardinality(tk.due) > 0 then tk.due else array_remove(array[tk.next_owner], null) end as waiting
      from public.app_users u
      left join public.employee_org o on o.employee_id = u.id
      left join public.openings op on op.id = o.opening_id
      cross join lateral (
        select count(*) as total, count(*) filter (where t.status = 'done') as done,
               count(*) filter (where t.status = 'pending' and t.due_on < app.today()) as overdue,
               coalesce(array_agg(distinct t.owner::text) filter (where t.status = 'pending' and t.due_on <= app.today()), '{}') as due,
               (array_agg(t.owner::text order by t.due_on, t.seq) filter (where t.status = 'pending'))[1] as next_owner
          from public.onboarding_tasks t where t.employee_id = u.id) tk
     where not u.external and u.system_role <> 'admin'
       and (u.status in ('invited', 'onboarding') or (u.status = 'active' and tk.total > tk.done))
       and (v_full or o.base_state_id = any(v_mine))
  ), f as (
    select b.* from base b
     where (v_q is null or lower(b.display_name) like '%' || v_q || '%' or lower(coalesce(b.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(b.phone, '') like '%' || regexp_replace(v_q, '[^0-9]', '', 'g') || '%'))
       and (v_state is null or b.opening_state = v_state or b.base_state_id = v_state
            or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                        where a.employee_id = b.id and a.active and v_state in (a.state_id, s.state_id, c.state_id)))
       and (v_role is null or b.intended_role = v_role)
       and (v_open is null or b.opening_id = v_open)
       and (v_status is null or (v_status = 'joining' and b.status in ('invited', 'onboarding')) or b.status::text = v_status)
       and (v_owner is null or (v_owner = 'mine' and b.hr_owner = me) or (v_owner = 'none' and b.hr_owner is null)
            or (v_owner not in ('mine', 'none') and b.hr_owner::text = v_owner))
       and (not v_overdue or b.overdue > 0)
       and (v_wait is null or (v_wait = 'us' and 'hr' = any(b.waiting)) or (v_wait = 'joiner' and 'hire' = any(b.waiting))
            or (v_wait = 'it' and 'it' = any(b.waiting)))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'stats', (select jsonb_build_object('joining', count(*) filter (where status in ('invited', 'onboarding')),
                       'on_us', count(*) filter (where 'hr' = any(waiting) or 'it' = any(waiting)),
                       'on_them', count(*) filter (where 'hire' = any(waiting)),
                       'overdue', count(*) filter (where overdue > 0),
                       'mine', count(*) filter (where hr_owner = me)) from base),
    'rows', coalesce((select jsonb_agg(x.j order by x.joining desc, x.join_date nulls last, x.display_name) from (
       select f.status in ('invited', 'onboarding') as joining, f.join_date, f.display_name,
              jsonb_build_object('id', f.id, 'name', f.display_name, 'email', f.email, 'phone', f.phone, 'status', f.status,
                'system_role', f.system_role, 'join_date', f.join_date,
                'days_to_join', case when f.join_date is null then null else f.join_date - app.today() end,
                'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
                'employment_type', f.employment_type, 'job_title', f.job_title, 'department', f.department,
                'role', f.intended_role, 'stage', f.intended_stage, 'opening_id', f.opening_id, 'opening_code', f.opening_code,
                'state_name', (select name from public.states where id = coalesce(f.base_state_id, f.opening_state)),
                'district', f.base_district,
                'hr_owner', f.hr_owner, 'hr_owner_name', (select display_name from public.app_users where id = f.hr_owner),
                'total', f.total, 'done', f.done, 'overdue', f.overdue,
                'pct', case when f.total > 0 then round(f.done * 100.0 / f.total) else 100 end,
                'waiting_on', to_jsonb(f.waiting),
                'next_task', nx.title, 'next_due', nx.due_on, 'blocked_by', nx.owner,
                'invite', (select jsonb_build_object('state', case when i.used_at is not null then 'accepted' when i.revoked_at is not null then 'replaced'
                                   when i.expires_at < now() then 'expired' else i.send_status end, 'at', i.created_at, 'expires_at', i.expires_at)
                             from public.invites i where i.employee_id = f.id order by (i.revoked_at is null) desc, i.created_at desc limit 1)) as j
         from f
         left join lateral (select t.owner, t.title, t.due_on from public.onboarding_tasks t
                             where t.employee_id = f.id and t.status = 'pending' order by t.due_on, t.seq limit 1) nx on true
        order by (f.status in ('invited', 'onboarding')) desc, f.join_date nulls last, f.display_name
        limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION app.people_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb; v_limited boolean := app.is_hr() and not app.hr_full(); v_mine uuid[] := app.my_hr_states();
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner, o.base_state_id, o.base_district
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
       and (not v_limited or u.id = me or o.base_state_id = any(v_mine))
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or lower(coalesce(v.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state)
            or v.base_state_id = v_state)
       and (v_client is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
                                         where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_client in (a.client_id, s.client_id)))
       and (v_role is null or v.intended_role = v_role)
       and (v_open is null or v.opening_id = v_open)
       and (v_owner is null or (v_owner = 'mine' and v.hr_owner = me) or (v_owner not in ('mine', 'none') and v.hr_owner::text = v_owner)
            or (v_owner = 'none' and v.hr_owner is null))
       and (not v_unass or not exists (select 1 from public.assignments a where a.employee_id = v.id and a.active))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'counts', (select jsonb_build_object('employees', count(*) filter (where not external), 'client_logins', count(*) filter (where external)) from vis),
    'rows', coalesce((select jsonb_agg(x.j order by x.external, x.display_name) from (
      select f.external, f.display_name, jsonb_build_object(
             'id', f.id, 'name', f.display_name, 'email', f.email, 'phone', f.phone, 'status', f.status, 'system_role', f.system_role,
             'external', f.external, 'join_date', f.join_date, 'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
             'role', f.intended_role, 'stage', f.intended_stage,
             'opening_code', (select code from public.openings where id = f.opening_id),
             'base', jsonb_build_object('state_id', f.base_state_id, 'state_name', (select name from public.states where id = f.base_state_id),
                                        'district', f.base_district),
             'org', jsonb_build_object('employment_type', f.employment_type, 'designation_band', f.designation_band,
                      'department', f.department, 'job_title', f.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = f.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = f.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', (select count(*) from public.assignments a where a.employee_id = f.id and a.active and not app.assignment_visible(a)),
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION app.people_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare full_view boolean;
begin
  perform app.me_or_raise();
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status, 'system_role', u.system_role,
             'external', u.external, 'join_date', u.join_date, 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
             'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band,
                      'department', o.department, 'job_title', o.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = o.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)),
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active))
           order by u.external, u.display_name)
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where (not u.external and (full_view or u.status <> 'offboarded')
            and (not app.is_hr() or app.hr_full() or u.id = app.current_user_id() or o.base_state_id = any(app.my_hr_states())))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.hr_pipeline()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if app.me_or_raise() is null or not app.acts_as_hr() then
    raise exception 'only HR opens the pipeline' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(row_ order by (x.status = 'active'), x.join_date nulls last, x.name)
      from (
        select u.status, u.join_date, u.display_name as name,
               jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
                 'system_role', u.system_role, 'join_date', u.join_date,
                 'days_to_join', case when u.join_date is null then null else u.join_date - app.today() end,
                 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
                 'employment_type', o.employment_type, 'job_title', o.job_title, 'department', o.department,
                 'total', tk.total, 'done', tk.done, 'overdue', tk.overdue,
                 'pct', case when tk.total > 0 then round(tk.done * 100.0 / tk.total) else 100 end,
                 'blocked_by', nx.owner, 'next_task', nx.title, 'next_due', nx.due_on,
                 -- everyone who has a task due by today: a joiner and HR can both be holding things up at once
                 'waiting_on', coalesce((select jsonb_agg(distinct t.owner) from public.onboarding_tasks t
                                          where t.employee_id = u.id and t.status = 'pending' and t.due_on <= app.today()), '[]'::jsonb)) as row_
          from public.app_users u
          left join public.employee_org o on o.employee_id = u.id
          cross join lateral (
            select count(*) as total, count(*) filter (where t.status = 'done') as done,
                   count(*) filter (where t.status = 'pending' and t.due_on < app.today()) as overdue
              from public.onboarding_tasks t where t.employee_id = u.id) tk
          left join lateral (
            select t.owner, t.title, t.due_on from public.onboarding_tasks t
             where t.employee_id = u.id and t.status = 'pending' order by t.due_on, t.seq limit 1) nx on true
         where not u.external and app.hr_covers(u.id)
           and (u.status in ('invited', 'onboarding') or (u.status = 'active' and tk.total > tk.done))
      ) x), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.openings_summary(p_state uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare rows jsonb; keys text[] := array['positions', 'joining', 'joined', 'assigned', 'waiting_wave', 'ready', 'vacant'];
begin
  perform app.me_or_raise();
  if not (app.acts_as_hr() or app.is_admin()) then raise exception 'openings are for HR and the admin' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(app.opening_json(o) order by st.name, o.status = 'closed', o.role, o.code), '[]'::jsonb) into rows
    from public.openings o join public.states st on st.id = o.state_id
   where (p_state is null or o.state_id = p_state)
     and (not app.is_hr() or app.hr_full() or o.state_id = any(app.my_hr_states()));
  return jsonb_build_object(
    'openings', rows,
    'states', coalesce((
      select jsonb_agg(jsonb_build_object('state_id', s.sid, 'state_name', s.sname) || (
               select jsonb_object_agg(k, (select coalesce(sum((r->>k)::int), 0) from jsonb_array_elements(rows) r where r->>'state_id' = s.sid::text))
                 from unnest(keys) k) order by s.sname)
        from (select distinct (r->>'state_id')::uuid as sid, r->>'state_name' as sname from jsonb_array_elements(rows) r) s), '[]'::jsonb),
    'total', (select jsonb_object_agg(k, (select coalesce(sum((r->>k)::int), 0) from jsonb_array_elements(rows) r)) from unnest(keys) k),
    -- people joining or joined who are on no opening (added before openings, or without one)
    'not_linked', (select count(*) from public.app_users u left join public.employee_org e on e.employee_id = u.id
                    where not u.external and u.system_role <> 'admin' and u.status in ('invited', 'onboarding', 'active') and e.opening_id is null
                      and (not app.is_hr() or app.hr_covers(u.id))),
    'can_plan', app.acts_as_hr(),
    'can_seat', app.is_hr_admin() or app.is_sm_deputy());
end $function$;

CREATE OR REPLACE FUNCTION app.save_opening(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); o public.openings; v_state uuid; v_role text; v_stage public.stage_type; v_client uuid; v_scope uuid;
        sc public.scopes; v_pos int; v_code text; abbr text; n int; filled int;
begin
  if not app.acts_as_hr() then raise exception 'only HR plans openings' using errcode = '42501'; end if;
  if nullif(p->>'id', '') is not null then
    select * into o from public.openings where id = (p->>'id')::uuid for update;
    if o.id is null then raise exception 'unknown opening' using errcode = 'P0002'; end if;
  end if;
  v_state := coalesce(nullif(p->>'state_id', '')::uuid, o.state_id);
  v_role := coalesce(nullif(p->>'role', ''), o.role);
  v_stage := case when p ? 'stage' then nullif(p->>'stage', '')::public.stage_type else o.stage end;
  v_client := case when p ? 'client_id' then nullif(p->>'client_id', '')::uuid else o.client_id end;
  v_scope := case when p ? 'scope_id' then nullif(p->>'scope_id', '')::uuid else o.scope_id end;
  begin v_pos := coalesce(nullif(p->>'positions', '')::int, o.positions); exception when others then v_pos := null; end;
  if v_state is null or not exists (select 1 from public.states where id = v_state) then raise exception 'choose a state' using errcode = '23514'; end if;
  if not app.hr_full() and (not (v_state = any(app.my_hr_states())) or (o.id is not null and not (o.state_id = any(app.my_hr_states())))) then
    raise exception 'that state is not one of yours: ask the HR Admin' using errcode = '42501'; end if;
  if v_role is null or v_role not in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other') then
    raise exception 'choose a role' using errcode = '23514'; end if;
  if v_role <> 'operator' then v_stage := null; end if;
  if v_role = 'operator' and v_stage is null then raise exception 'an operator opening needs the stage they will work at' using errcode = '23514'; end if;
  if v_role in ('state_manager', 'hr', 'other') then v_client := null; v_scope := null; end if;
  if v_role = 'client_manager' then v_scope := null; end if;
  if v_client is not null and not exists (select 1 from public.clients where id = v_client and state_id = v_state) then
    raise exception 'that client is not in this state' using errcode = '23514'; end if;
  if v_scope is not null then
    select * into sc from public.scopes where id = v_scope;
    if sc.id is null or sc.state_id <> v_state then raise exception 'that scope is not in this state' using errcode = '23514'; end if;
    if v_client is not null and sc.client_id <> v_client then raise exception 'that scope is not the client''s' using errcode = '23514'; end if;
    if v_stage is not null and not (v_stage = any(sc.chain)) then raise exception 'that stage is not in this scope''s chain' using errcode = '23514'; end if;
    v_client := sc.client_id;
  end if;
  if v_pos is null or v_pos < 1 or v_pos > 5000 then raise exception 'positions: a number from 1 to 5000' using errcode = '23514'; end if;

  if o.id is null then
    abbr := case v_role when 'state_manager' then 'SM' when 'client_manager' then 'CM' when 'operator' then 'OPR'
                        when 'export_manager' then 'EXM' when 'hr' then 'HR' else 'OTH' end;
    select count(*) into n from public.openings where state_id = v_state and role = v_role;
    loop
      n := n + 1;
      v_code := (select upper(code) from public.states where id = v_state) || '-' || abbr || '-' || lpad(n::text, 3, '0');
      exit when not exists (select 1 from public.openings where code = v_code);
    end loop;
    insert into public.openings (code, state_id, role, stage, client_id, scope_id, positions, target_join, status, title, note, created_by)
    values (v_code, v_state, v_role, v_stage, v_client, v_scope, v_pos, nullif(p->>'target_join', '')::date, 'open',
            nullif(left(btrim(p->>'title'), 120), ''), nullif(left(btrim(p->>'note'), 500), ''), me)
    returning * into o;
    perform app.audit('opening_created', null, jsonb_build_object('opening', o.code, 'role', o.role, 'stage', o.stage, 'positions', o.positions));
  else
    -- people already on the opening keep their role: its role and place do not change under them
    select count(*) into filled from public.employee_org e join public.app_users u on u.id = e.employee_id
     where e.opening_id = o.id and u.status in ('invited', 'onboarding', 'active');
    if filled > 0 and (v_role is distinct from o.role or v_state is distinct from o.state_id or v_stage is distinct from o.stage) then
      raise exception 'people are already on this opening: its state, role and stage stay as they are' using errcode = '23514'; end if;
    if v_pos < filled then raise exception 'there are already % people on this opening' , filled using errcode = '23514'; end if;
    update public.openings set state_id = v_state, role = v_role, stage = v_stage, client_id = v_client, scope_id = v_scope, positions = v_pos,
           target_join = case when p ? 'target_join' then nullif(p->>'target_join', '')::date else target_join end,
           title = case when p ? 'title' then nullif(left(btrim(p->>'title'), 120), '') else title end,
           note = case when p ? 'note' then nullif(left(btrim(p->>'note'), 500), '') else note end,
           updated_at = now()
     where id = o.id returning * into o;
    perform app.audit('opening_changed', null, jsonb_build_object('opening', o.code, 'positions', o.positions));
  end if;
  return app.opening_json(o);
end $function$;

CREATE OR REPLACE FUNCTION app.set_opening_status(p_opening uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o public.openings;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR plans openings' using errcode = '42501'; end if;
  if p_status not in ('open', 'on_hold', 'closed') then raise exception 'status: open, on hold or closed' using errcode = '23514'; end if;
  if not app.hr_full() and not exists (select 1 from public.openings x where x.id = p_opening and x.state_id = any(app.my_hr_states())) then
    raise exception 'that opening is not in your states' using errcode = '42501'; end if;
  update public.openings set status = p_status, updated_at = now() where id = p_opening returning * into o;
  if o.id is null then raise exception 'unknown opening' using errcode = 'P0002'; end if;
  perform app.audit('opening_status', null, jsonb_build_object('opening', o.code, 'status', p_status));
  return app.opening_json(o);
end $function$;

CREATE OR REPLACE FUNCTION app.opening_targets(p_state uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'openings are planned by HR' using errcode = '42501'; end if;
  if not app.hr_full() and not (p_state = any(app.my_hr_states())) then
    raise exception 'that state is not one of yours: ask the HR Admin' using errcode = '42501'; end if;
  return jsonb_build_object(
    'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name)
                           from public.clients c where c.state_id = p_state), '[]'::jsonb),
    'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'season_code', s.season_code, 'geography', s.geography,
                                                            'status', s.status, 'client_id', s.client_id, 'chain', s.chain)
                                         order by s.season_code, s.geography)
                          from public.scopes s where s.state_id = p_state and s.status <> 'closed'), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION app.assign(p_employee uuid, p_lens assignment_lens, p_target uuid, p_op_role op_role, p_stages stage_type[] DEFAULT '{}'::stage_type[], p_posting text DEFAULT NULL::text, p_ends_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); a public.assignments; sc public.scopes; st public.stage_type; v_stages public.stage_type[] := '{}';
        w jsonb;
begin
  if not app.may_assign(p_lens, p_op_role, p_target) then
    raise exception 'you cannot give this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if p_employee = me then
    raise exception 'you cannot assign yourself' using errcode = '42501'; end if;
  if app.user_is_admin(p_employee) then
    raise exception 'an admin oversees and holds no assignment' using errcode = '42501'; end if;
  -- Veda, 12 Oct 2026: "HR should never be the State Manager. HR can govern the state wrt onboarding" (migration 39)
  if exists (select 1 from public.app_users where id = p_employee and system_role in ('hr_admin', 'hr_resource')) then
    raise exception 'HR holds no seat: an HR person works for states as HR (HR states), not as a manager or operator' using errcode = '42501'; end if;
  if exists (select 1 from public.assignments x where x.employee_id = p_employee and x.active and x.lens = p_lens
                and p_target in (x.scope_id, x.client_id, x.state_id)) then
    raise exception 'this person is already assigned here: change the stages, or end that assignment first' using errcode = '23514'; end if;

  if p_lens = 'scope' then
    select * into sc from public.scopes where id = p_target;
    if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
    select coalesce(array_agg(x order by array_position(sc.chain, x)), '{}') into v_stages
      from (select distinct unnest(coalesce(p_stages, '{}')) as x) q;
    foreach st in array v_stages loop
      if not (st = any(sc.chain)) then raise exception 'stage % is not in this scope''s chain', st using errcode = '23514'; end if;
    end loop;
    if p_op_role = 'operator' and cardinality(v_stages) = 0 then
      raise exception 'choose at least one stage for an operator' using errcode = '23514'; end if;
  elsif cardinality(coalesce(p_stages, '{}')) > 0 then
    raise exception 'stages belong to a scope assignment' using errcode = '23514';
  end if;

  w := app.assignment_warnings(p_employee, p_lens, p_target, p_op_role, v_stages);
  perform set_config('app.assigning', 'on', true);
  insert into public.assignments (employee_id, lens, op_role, scope_id, client_id, state_id, stages, posting, ends_on, created_by)
  values (p_employee, p_lens, p_op_role,
          case when p_lens = 'scope' then p_target end, case when p_lens = 'client' then p_target end, case when p_lens = 'state' then p_target end,
          v_stages, nullif(btrim(p_posting), ''), p_ends_on, me)
  returning * into a;
  foreach st in array v_stages loop
    insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (p_employee, p_target, st, a.id);
  end loop;
  perform set_config('app.assigning', '', true);

  perform app.audit('assigned', p_employee, jsonb_build_object('assignment_id', a.id, 'lens', a.lens, 'op_role', a.op_role,
    'scope_id', a.scope_id, 'client_id', a.client_id, 'state_id', a.state_id, 'stages', to_jsonb(a.stages), 'posting', a.posting,
    'name', (select display_name from public.app_users where id = p_employee), 'warnings', w));
  -- F3 (migration 38): a State Manager seated by the Deputy, not the HR Admin, is flagged
  if p_lens = 'state' and not app.is_hr_admin() then
    perform app.audit('state_seated_by_deputy', p_employee, jsonb_build_object('state_id', p_target,
      'name', (select display_name from public.app_users where id = p_employee)), true); end if;
  return jsonb_build_object('assignment', to_jsonb(a), 'warnings', w);
end $function$;

CREATE OR REPLACE FUNCTION app.set_system_role(p_employee uuid, p_role system_role)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; my_role public.system_role;
begin
  select system_role into my_role from public.app_users where id = me and status = 'active';
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.id = me then raise exception 'you cannot change your own system role' using errcode = '42501'; end if;
  if p_role = 'hr_admin' or u.system_role = 'hr_admin' then
    raise exception 'the HR Admin seat is given under System → Seats' using errcode = '42501'; end if;
  if not ((my_role = 'hr_admin' or (my_role = 'admin' and not app.hr_seat_filled()))
          and u.system_role in ('operational', 'hr_resource') and p_role in ('operational', 'hr_resource')) then
    raise exception 'you cannot give this system role' using errcode = '42501'; end if;
  if u.system_role = p_role then return; end if;
  if p_role = 'hr_resource' and exists (select 1 from public.assignments a where a.employee_id = u.id and a.active) then
    raise exception 'this person holds a seat: end it first (HR holds no seat)' using errcode = '23514'; end if;
  if u.system_role = 'hr_resource' then           -- no longer HR: her states end with it
    update public.hr_states set ended_at = now(), ended_by = me where employee_id = u.id and ended_at is null;
  end if;
  update public.app_users set system_role = p_role where id = u.id;
  perform app.audit('system_role_changed', u.id, jsonb_build_object('name', u.display_name, 'from', u.system_role, 'to', p_role),
                    p_role = 'admin' or u.system_role = 'admin');
end $function$;

CREATE OR REPLACE FUNCTION app.appoint_hr_admin(p_employee uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; prev public.app_users;
begin
  if not app.is_admin() then raise exception 'only the admin appoints the HR Admin' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or u.status in ('suspended', 'offboarded') then raise exception 'choose an employee who is not suspended or offboarded' using errcode = '23514'; end if;
  if u.system_role = 'admin' then raise exception 'the admin holds the root seat already' using errcode = '23514'; end if;
  if u.system_role = 'hr_admin' then return; end if;
  if exists (select 1 from public.assignments a where a.employee_id = u.id and a.active) then
    raise exception 'this person holds a seat: it is ended first (HR holds no seat)' using errcode = '23514'; end if;
  -- (her HR states are kept: as HR Admin she works for every state; should the seat move on, she has them again)
  select * into prev from public.app_users where system_role = 'hr_admin' and status <> 'offboarded';
  if prev.id is not null then update public.app_users set system_role = 'hr_resource' where id = prev.id; end if;
  update public.app_users set system_role = 'hr_admin' where id = u.id;
  perform app.audit('hr_admin_appointed', u.id, jsonb_build_object('name', u.display_name, 'previous', prev.display_name), true);
end $function$;

CREATE OR REPLACE FUNCTION app.may_assign(p_lens assignment_lens, p_op_role op_role, p_target uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id();
begin
  if me is null then return false; end if;
  if app.is_admin() then return false; end if;                                -- the admin gives nothing (migration 35)
  if p_lens = 'state' then return app.is_hr_admin() or (app.is_sm_deputy() and p_target = any(app.my_hr_states())); end if;   -- migration 39: the Deputy, in her states   -- F3 (migration 38): or the named Deputy                  -- the HR Admin seats State Managers (Veda, 10 Oct)
  if p_lens = 'client' then
    if p_op_role = 'client_account' then                                      -- a client's account: by a supervisor of its home state
      return exists (select 1 from app.eff_assignments(me) a
                      where a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_target));
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $function$;

CREATE OR REPLACE FUNCTION app.employee_profile(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; full_view boolean; hr_ok boolean;
begin
  select * into u from public.app_users where id = p_employee;
  full_view := app.is_admin() or (app.is_hr() and (app.hr_full() or app.hr_covers(p_employee)));
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded')))
                          or (u.external and (app.is_admin() or app.manages_viewer(u.id)))) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  hr_ok := app.may_manage_person(u.id);
  return jsonb_build_object(
    'identity', jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'phone', u.phone, 'status', u.status,
                  'external', u.external, 'join_date', u.join_date, 'created_at', u.created_at,
                  'has_login', u.auth_uid is not null and u.auth_uid <> u.id),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'system_role', u.system_role,
    'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                               from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(app.assignment_json(a) order by a.ended_at desc)
                           from public.assignments a where a.employee_id = u.id and not a.active and app.assignment_visible(a)), '[]'::jsonb),
    'elsewhere', (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)),
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', (app.is_hr_admin() or (app.can_assign() and not app.is_admin())) and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> me and u.system_role not in ('admin', 'hr_admin', 'hr_resource'),
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

CREATE OR REPLACE FUNCTION app.employee_org_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(current_setting('app.org_fn', true), '') = 'on' or current_user in ('postgres', 'supabase_admin') then return new; end if;
  if tg_op = 'INSERT' then
    if new.opening_id is not null or new.intended_role is not null or new.intended_stage is not null or new.hr_owner is not null
       or new.base_state_id is not null or new.base_district is not null then
      raise exception 'the opening, the intended role, the HR owner and the base location are set through HR''s screens' using errcode = '42501'; end if;
  elsif (new.opening_id, new.intended_role, new.intended_stage, new.hr_owner, new.base_state_id, new.base_district) is distinct from
        (old.opening_id, old.intended_role, old.intended_stage, old.hr_owner, old.base_state_id, old.base_district) then
    raise exception 'the opening, the intended role, the HR owner and the base location are set through HR''s screens' using errcode = '42501';
  end if;
  return new;
end $function$;


-- ── read rules: an HR resource reads the people of her states ────────────────────────────────────────────────────
create policy hr_states_read on public.hr_states for select to authenticated
  using (employee_id = app.current_user_id() or app.acts_as_hr() or app.is_admin());

drop policy users_read on public.app_users;
create policy users_read on public.app_users for select to authenticated using (
  (auth_uid = auth.uid()) or app.is_admin()
  or ((not external) and ((app.is_hr() and (app.hr_full() or id = app.current_user_id() or system_role in ('hr_admin', 'hr_resource')
                                            or app.hr_covers(id)))
                          or (app.can_assign() and status <> 'offboarded')))
  or (external and app.manages_viewer(id)));
drop policy users_update on public.app_users;
create policy users_update on public.app_users for update to authenticated using (
  (app.is_admin() and (not external) and app.hr_may_manage(system_role))
  or ((not external) and app.is_hr() and app.hr_may_manage(system_role) and app.hr_covers(id))
  or (external and app.manages_viewer(id)));

drop policy employee_org_read on public.employee_org;
create policy employee_org_read on public.employee_org for select to authenticated using (
  employee_id = app.current_user_id() or app.is_admin() or (app.is_hr() and app.hr_covers(employee_id)) or app.can_assign());
drop policy employee_org_insert on public.employee_org;
create policy employee_org_insert on public.employee_org for insert to authenticated with check (
  (app.is_admin() or app.is_hr()) and app.hr_may_manage((select u.system_role from public.app_users u where u.id = employee_org.employee_id))
  and app.hr_covers(employee_id));
drop policy employee_org_update on public.employee_org;
create policy employee_org_update on public.employee_org for update to authenticated using (
  (app.is_admin() or app.is_hr()) and app.hr_may_manage((select u.system_role from public.app_users u where u.id = employee_org.employee_id))
  and app.hr_covers(employee_id));

drop policy employee_docs_read on public.employee_docs;
create policy employee_docs_read on public.employee_docs for select to authenticated
  using (employee_id = app.current_user_id() or (app.acts_as_hr() and app.hr_covers(employee_id)));
drop policy employee_files_read on public.employee_files;
create policy employee_files_read on public.employee_files for select to authenticated
  using (employee_id = app.current_user_id() or (app.acts_as_hr() and app.hr_covers(employee_id)));
drop policy employee_goals_read on public.employee_goals;
create policy employee_goals_read on public.employee_goals for select to authenticated
  using (employee_id = app.current_user_id() or (app.acts_as_hr() and app.hr_covers(employee_id)));
drop policy onboarding_tasks_read on public.onboarding_tasks;
create policy onboarding_tasks_read on public.onboarding_tasks for select to authenticated
  using (employee_id = app.current_user_id() or (app.acts_as_hr() and app.hr_covers(employee_id)));
drop policy employee_personal_read on public.employee_personal;
create policy employee_personal_read on public.employee_personal for select to authenticated
  using (employee_id = app.current_user_id() or (app.acts_as_hr() and app.hr_covers(employee_id)));
drop policy employee_notes_read on public.employee_notes;
create policy employee_notes_read on public.employee_notes for select to authenticated using (app.acts_as_hr() and app.hr_covers(employee_id));
drop policy employee_exits_read on public.employee_exits;
create policy employee_exits_read on public.employee_exits for select to authenticated using (app.acts_as_hr() and app.hr_covers(employee_id));
drop policy id_number_matches_read on public.id_number_matches;
create policy id_number_matches_read on public.id_number_matches for select to authenticated using (app.acts_as_hr() and app.hr_covers(employee_id));
drop policy invites_read on public.invites;
create policy invites_read on public.invites for select to authenticated using (app.acts_as_hr() and app.hr_covers(employee_id));

drop policy assignments_read on public.assignments;
create policy assignments_read on public.assignments for select to authenticated using (
  (employee_id = app.current_user_id()) or app.is_admin() or (app.is_hr() and app.hr_covers(employee_id))
  or ((lens = 'scope') and app.i_manage_scope(scope_id)) or ((lens = 'client') and app.can_manage_client(client_id))
  or ((lens = 'state') and (state_id = any (app.my_state_ids()))));

drop policy openings_read on public.openings;
create policy openings_read on public.openings for select to authenticated using (
  (app.acts_as_hr() and (app.hr_full() or state_id = any(app.my_hr_states()))) or app.is_admin() or app.can_assign());

drop policy hr_docs_read on storage.objects;
create policy hr_docs_read on storage.objects for select to authenticated
  using (bucket_id = 'hr-docs' and app.acts_as_hr() and app.hr_covers_path(name));
drop policy hr_docs_upload on storage.objects;
create policy hr_docs_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'hr-docs' and ((storage.foldername(name))[1] = app.current_user_id()::text
                                         or (app.acts_as_hr() and app.hr_covers_path(name))));

-- ── the first fill of the base state, where the data leaves no doubt ───────────────────────────────────────────────
do $$
declare n_open int; n_seat int;
begin
  update public.employee_org e set base_state_id = op.state_id
    from public.openings op where op.id = e.opening_id and e.base_state_id is null;
  get diagnostics n_open = row_count;
  with seats as (
    select a.employee_id, array_agg(distinct coalesce(a.state_id, sc.state_id, c.state_id)) as st
      from public.assignments a left join public.scopes sc on sc.id = a.scope_id left join public.clients c on c.id = a.client_id
     where a.active group by a.employee_id)
  update public.employee_org e set base_state_id = s.st[1]
    from seats s where s.employee_id = e.employee_id and e.base_state_id is null and cardinality(s.st) = 1 and s.st[1] is not null;
  get diagnostics n_seat = row_count;
  if n_open + n_seat > 0 then
    insert into public.audit_log (actor, action, detail)
    values (null, 'base_locations_filled', jsonb_build_object('from_openings', n_open, 'from_seats', n_seat, 'migration', 39));
  end if;
end $$;

-- ── who may call what ─────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array['app.hr_scope()', 'app.set_hr_states(uuid, uuid[])', 'app.set_base_location(uuid, uuid, text)',
                           'app.person_geo(uuid)', 'app.hr_people_states()',
                           -- read inside the read rules, so callable by people (each answers about the caller only)
                           'app.my_hr_states()', 'app.hr_full()', 'app.hr_covers(uuid)', 'app.hr_covers_path(text)',
                           'app.hr_may_manage_person(uuid)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  revoke execute on function app.hr_states_of(uuid) from public, anon, authenticated;
end $$;
