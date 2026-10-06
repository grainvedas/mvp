-- GrainVeda MVP · migration 31: identity layer, part 1 of 3 (tables and the move of the existing people)
--
-- Until now a person was created by the manager above them and carried one role, one client and a list of states
-- (admin → State Manager → Client Manager → operators). From here on:
--   1. A person is created ONCE, by HR, as an identity (public.app_users stays the table: every record points at it).
--   2. Access is given separately, as assignments. A person has 0..n of them. An assignment looks through one of
--      three lenses: one scope (with the stages held there), one client (all its scopes, in every state), or one
--      state (every scope in it, whatever the client). What a person may see is the UNION of their assignments.
--   3. Org facts (designation, employment type, reports-to) describe a person and grant nothing.
--   4. Only two things grant access: the system role (admin, HR admin, HR resource, operational) and assignments.
--
-- app_users.role / client_id / state_ids are kept, but as a SUMMARY written by the database from the assignments
-- (so lists, exports and old queries still read sensibly). No access rule reads them after migration 32.
--
-- Names: the spec's `employee` is app_users, `system_role` is a column on it, `assignment` is public.assignments.
-- The functional names of the manager lenses are client_account and state_supervisor, so they are not confused
-- with the designation rung "Manager" kept in employee_org.

-- 1 · types ----------------------------------------------------------------------------------------------------------
create type public.employee_status as enum ('invited', 'onboarding', 'active', 'suspended', 'offboarded');
create type public.system_role     as enum ('admin', 'hr_admin', 'hr_resource', 'operational');
create type public.employment_type as enum ('full_time', 'intern', 'contract', 'consultant');
create type public.assignment_lens as enum ('scope', 'client', 'state');
create type public.op_role         as enum ('operator', 'export_manager', 'client_account', 'client_viewer', 'state_supervisor');
create type public.task_owner      as enum ('hire', 'hr', 'it');
create type public.task_status     as enum ('pending', 'done');

-- 2 · the person ------------------------------------------------------------------------------------------------------
alter table public.app_users
  add column status      public.employee_status not null default 'active',
  add column system_role public.system_role     not null default 'operational',
  add column external    boolean not null default false,     -- a client's own read-only login: not an employee, no HR record
  add column join_date   date,
  add column created_by  uuid references public.app_users(id);
alter table public.app_users alter column role set default 'operator';
-- A person without any assignment is a valid state now ("a manager will assign you soon").
alter table public.app_users drop constraint app_users_client_required;

update public.app_users set status = 'suspended' where not active;
update public.app_users set system_role = 'admin' where role = 'admin';
update public.app_users set external = true where role = 'client_view';

-- Exactly one HR Admin seat. An offboarded holder leaves it vacant (then only the admin can appoint).
create unique index app_users_one_hr_admin on public.app_users ((true)) where system_role = 'hr_admin' and status <> 'offboarded';
create index app_users_status on public.app_users (status);

-- 3 · the scope gets its own state --------------------------------------------------------------------------------------
-- Client and state are two independent lenses: a client may work in several states, so the state is a fact of the
-- scope, not of the client. clients.state_id stays as the client's home state (who may edit the client record).
alter table public.scopes
  add column state_id   uuid references public.states(id),
  add column season_end date;                    -- optional: assignments on this scope lapse after this day
update public.scopes s set state_id = c.state_id from public.clients c where c.id = s.client_id;
alter table public.scopes alter column state_id set not null;
create index scopes_state on public.scopes (state_id);

create or replace function app.scopes_place() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.state_id is null then
    select c.state_id into new.state_id from public.clients c where c.id = new.client_id;
  end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' and new.state_id is distinct from old.state_id then
    raise exception 'a scope''s state is frozen after activation; open a new scope' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger scopes_a1_place before insert or update on public.scopes
  for each row execute function app.scopes_place();

-- 4 · assignments -----------------------------------------------------------------------------------------------------
create table public.assignments (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.app_users(id) on delete cascade,
  lens         public.assignment_lens not null,
  op_role      public.op_role not null,
  scope_id     uuid references public.scopes(id) on delete cascade,
  client_id    uuid references public.clients(id),
  state_id     uuid references public.states(id),
  stages       public.stage_type[] not null default '{}',     -- kept by the database from slot_assignments
  posting      text,                                          -- where the person is posted (free text)
  season_code  text,
  ends_on      date,                                          -- lapses on its own after this day (season end)
  active       boolean not null default true,
  created_by   uuid references public.app_users(id),
  created_at   timestamptz not null default now(),
  ended_at     timestamptz,
  ended_by     uuid references public.app_users(id),
  end_reason   text,
  constraint assignments_shape check (
       (lens = 'scope'  and scope_id is not null and client_id is null and state_id is null and op_role in ('operator', 'export_manager'))
    or (lens = 'client' and client_id is not null and scope_id is null and state_id is null and op_role in ('client_account', 'client_viewer'))
    or (lens = 'state'  and state_id is not null and scope_id is null and client_id is null and op_role = 'state_supervisor')),
  constraint assignments_end check ((active and ended_at is null) or (not active and ended_at is not null))
);
-- One live assignment per person and place: more stages on the same scope are the same assignment, not a second one.
create unique index assignments_one_scope  on public.assignments (employee_id, scope_id)  where active and lens = 'scope';
create unique index assignments_one_client on public.assignments (employee_id, client_id) where active and lens = 'client';
create unique index assignments_one_state  on public.assignments (employee_id, state_id)  where active and lens = 'state';
create index assignments_employee on public.assignments (employee_id) where active;
create index assignments_scope    on public.assignments (scope_id) where active;
create index assignments_client   on public.assignments (client_id) where active;
create index assignments_state    on public.assignments (state_id) where active;

-- A stage held on a scope stays a slot_assignments row (the proven integrity code reads it); every row now belongs
-- to an assignment.
alter table public.slot_assignments add column assignment_id uuid references public.assignments(id) on delete cascade;

-- 5 · audit log (append-only) -----------------------------------------------------------------------------------------
create table public.audit_log (
  id          bigserial primary key,
  actor       uuid references public.app_users(id),          -- null: the system (a migration, a seed, the service key)
  action      text not null,
  target      uuid,                                          -- the person the action is about
  detail      jsonb not null default '{}'::jsonb,
  flagged     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index audit_log_at on public.audit_log (created_at desc);
create index audit_log_target on public.audit_log (target);
create index audit_log_flagged on public.audit_log (created_at desc) where flagged;

create or replace function app.audit_log_guard() returns trigger language plpgsql as $$
begin
  raise exception 'the audit log is append-only (% refused)', tg_op using errcode = '42501';
end $$;
create trigger audit_log_no_change before update or delete on public.audit_log
  for each row execute function app.audit_log_guard();
create trigger audit_log_no_truncate before truncate on public.audit_log
  for each statement execute function app.audit_log_guard();

create or replace function app.audit(p_action text, p_target uuid, p_detail jsonb default '{}'::jsonb, p_flagged boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor, action, target, detail, flagged)
  values (app.current_user_id(), p_action, p_target, coalesce(p_detail, '{}'::jsonb), coalesce(p_flagged, false));
end $$;

-- 6 · HR records --------------------------------------------------------------------------------------------------------
-- Org facts: descriptive only. Nothing here is read by an access rule.
create table public.employee_org (
  employee_id      uuid primary key references public.app_users(id) on delete cascade,
  employment_type  public.employment_type not null default 'full_time',
  designation_band text,
  department       text,
  job_title        text,
  reports_to       uuid references public.app_users(id),
  buddy            uuid references public.app_users(id),
  updated_by       uuid references public.app_users(id),
  updated_at       timestamptz not null default now()
);

-- Identity and statutory details. Decision 5 Oct 2026 (Veda): only the LAST FOUR characters of a number are kept;
-- the document itself is a file in the private store `hr-docs`, which only HR and the admin can open.
create table public.employee_docs (
  employee_id      uuid primary key references public.app_users(id) on delete cascade,
  pan_last4        text check (pan_last4 ~ '^[0-9A-Z]{4}$'),
  aadhaar_last4    text check (aadhaar_last4 ~ '^[0-9]{4}$'),
  bank_name        text,
  bank_ifsc        text check (bank_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
  bank_last4       text check (bank_last4 ~ '^[0-9]{4}$'),
  pf_uan_last4     text check (pf_uan_last4 ~ '^[0-9]{4}$'),
  gratuity_nominee text,
  nominee_relation text,
  form16_ref       text,
  updated_at       timestamptz not null default now()
);

create table public.employee_files (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.app_users(id) on delete cascade,
  kind          text not null check (kind in ('offer_letter', 'nda', 'pan', 'aadhaar', 'bank_proof', 'contract', 'pf_form', 'form16', 'other')),
  storage_path  text not null unique,              -- hr-docs/<employee>/<file>
  file_name     text,
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  task_id       uuid,
  uploaded_by   uuid references public.app_users(id),
  created_at    timestamptz not null default now()
);
create index employee_files_employee on public.employee_files (employee_id);

create table public.employee_notes (
  id           bigserial primary key,
  employee_id  uuid not null references public.app_users(id) on delete cascade,
  note         text not null check (btrim(note) <> ''),
  written_by   uuid references public.app_users(id),
  created_at   timestamptz not null default now()
);
create index employee_notes_employee on public.employee_notes (employee_id);

create table public.employee_exits (
  id                bigserial primary key,
  employee_id       uuid not null references public.app_users(id) on delete cascade,
  exit_date         date not null,
  reason            text,
  final_settlement  text,
  form16_ref        text,
  recorded_by       uuid references public.app_users(id),
  created_at        timestamptz not null default now()
);
create index employee_exits_employee on public.employee_exits (employee_id);

create table public.employee_goals (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.app_users(id) on delete cascade,
  horizon      int not null check (horizon in (30, 60, 90)),
  goal         text not null check (btrim(goal) <> ''),
  set_by       uuid references public.app_users(id),
  created_at   timestamptz not null default now()
);
create index employee_goals_employee on public.employee_goals (employee_id);

-- 7 · onboarding ----------------------------------------------------------------------------------------------------------
create table public.onboarding_templates (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (btrim(name) <> ''),
  is_default  boolean not null default false,
  active      boolean not null default true,
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now()
);
create unique index onboarding_templates_one_default on public.onboarding_templates ((true)) where is_default;

-- kind tells the app which small form the task is: sign (read and acknowledge, a signed copy may be attached),
-- identity (PAN and Aadhaar), bank, countersign, nomination (PF and gratuity), it, buddy, goals, other.
create table public.template_tasks (
  id               uuid primary key default gen_random_uuid(),
  template_id      uuid not null references public.onboarding_templates(id) on delete cascade,
  seq              int not null check (seq > 0),
  code             text not null check (code ~ '^[a-z0-9_]{2,40}$'),
  title            text not null check (btrim(title) <> ''),
  owner            public.task_owner not null,
  due_offset_days  int not null check (due_offset_days between -90 and 365),   -- relative to the join date
  statutory        boolean not null default false,                             -- full-time employees only
  kind             text not null default 'other'
                     check (kind in ('sign', 'identity', 'bank', 'countersign', 'nomination', 'it', 'buddy', 'goals', 'other')),
  unique (template_id, seq),
  unique (template_id, code)
);

create table public.onboarding_tasks (
  id           uuid primary key default gen_random_uuid(),
  employee_id  uuid not null references public.app_users(id) on delete cascade,
  seq          int not null,
  code         text not null,
  title        text not null,
  owner        public.task_owner not null,
  due_on       date not null,
  statutory    boolean not null default false,
  kind         text not null default 'other',
  status       public.task_status not null default 'pending',
  done_at      timestamptz,
  done_by      uuid references public.app_users(id),
  note         text,
  created_at   timestamptz not null default now(),
  unique (employee_id, code)
);
create index onboarding_tasks_employee on public.onboarding_tasks (employee_id, seq);

-- The standard joining checklist (reference data: needed on production too). Timing is relative to the join date.
insert into public.onboarding_templates (id, name, is_default) values
  ('00000000-0000-4000-8000-000000000901', 'Standard joining', true);
insert into public.template_tasks (template_id, seq, code, title, owner, due_offset_days, statutory, kind) values
  ('00000000-0000-4000-8000-000000000901', 1, 'offer_nda',   'Sign offer letter & NDA',              'hire', -7, false, 'sign'),
  ('00000000-0000-4000-8000-000000000901', 2, 'identity',    'Upload identity (PAN / Aadhaar)',      'hire', -7, false, 'identity'),
  ('00000000-0000-4000-8000-000000000901', 3, 'bank',        'Add bank details',                     'hire', -5, false, 'bank'),
  ('00000000-0000-4000-8000-000000000901', 4, 'countersign', 'Countersign contract & NDA',           'hr',   -5, false, 'countersign'),
  ('00000000-0000-4000-8000-000000000901', 5, 'pf_gratuity', 'PF & gratuity nomination (Form 2 / F)', 'hire', -3, true,  'nomination'),
  ('00000000-0000-4000-8000-000000000901', 6, 'it_setup',    'Provision laptop & accounts',          'it',   -2, false, 'it'),
  ('00000000-0000-4000-8000-000000000901', 7, 'buddy',       'Assign & introduce buddy',             'hr',    0, false, 'buddy'),
  ('00000000-0000-4000-8000-000000000901', 8, 'goals',       'Set 30-60-90 goals',                   'hr',    3, false, 'goals');

-- 8 · the once-a-day sign-in code (built, switched OFF: app_meta 'daily_code' = 'on' turns it on) ------------------------
create table public.daily_codes (
  user_id     uuid primary key references public.app_users(id) on delete cascade,
  code_hash   text not null,
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  attempts    int not null default 0
);
create table public.daily_code_passes (
  user_id    uuid not null references public.app_users(id) on delete cascade,
  day        date not null,
  passed_at  timestamptz not null default now(),
  primary key (user_id, day)
);

-- 9 · the existing people become assignments ---------------------------------------------------------------------------
-- Done BEFORE the triggers below exist, so the move itself writes no ledger blocks and no per-row audit noise.
insert into public.assignments (employee_id, lens, op_role, state_id)
  select u.id, 'state', 'state_supervisor', s
    from public.app_users u cross join lateral unnest(u.state_ids) s
   where u.role = 'state_manager' and exists (select 1 from public.states st where st.id = s);
insert into public.assignments (employee_id, lens, op_role, client_id)
  select u.id, 'client', 'client_account', u.client_id from public.app_users u
   where u.role = 'client_manager' and u.client_id is not null;
insert into public.assignments (employee_id, lens, op_role, client_id)
  select u.id, 'client', 'client_viewer', u.client_id from public.app_users u
   where u.role = 'client_view' and u.client_id is not null;
insert into public.assignments (employee_id, lens, op_role, scope_id, season_code, stages)
  select sa.user_id, 'scope', 'operator', sa.scope_id, s.season_code,
         array_agg(sa.stage_type order by array_position(s.chain, sa.stage_type))
    from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
   group by sa.user_id, sa.scope_id, s.season_code;
-- A stage row is otherwise never changed, only given or removed (migration 25, app.slots_guard). This one write says
-- which assignment each existing row belongs to; the guard is put aside for it and is back in the next statement.
-- (On a database that already has stage rows, which is every database but a new one, the migration stops here
-- without this.)
alter table public.slot_assignments disable trigger slots_guard;
update public.slot_assignments sa set assignment_id = a.id
  from public.assignments a
 where a.lens = 'scope' and a.employee_id = sa.user_id and a.scope_id = sa.scope_id;
alter table public.slot_assignments enable trigger slots_guard;
alter table public.slot_assignments alter column assignment_id set not null;

insert into public.audit_log (actor, action, target, detail)
  select null, case when u.system_role = 'admin' then 'bootstrap_seed' else 'migrated' end, u.id,
         jsonb_build_object('name', u.display_name, 'was_role', u.role, 'system_role', u.system_role, 'status', u.status,
                            'assignments', (select count(*) from public.assignments a where a.employee_id = u.id))
    from public.app_users u order by u.created_at;

-- 10 · the person: status, summary, guards ------------------------------------------------------------------------------
-- active (may sign in and be recognised) follows status. The old "active" switch still works for the service role
-- and for scripts: off means suspended, on means active.
create or replace function app.app_users_status_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.role = 'admin' then new.system_role := 'admin'; end if;            -- rows written the old way (seeds, bootstrap)
    if new.role = 'client_view' then new.external := true; end if;
    if new.active is false and new.status in ('invited', 'onboarding', 'active') then new.status := 'suspended'; end if;
  else
    if new.status is not distinct from old.status and new.active is distinct from old.active then
      new.status := case when new.active then 'active'::public.employee_status else 'suspended'::public.employee_status end;
    end if;
    -- role, client and states are written by the database from the assignments (trigger depth > 1), never by hand.
    if pg_trigger_depth() = 1 and (new.role is distinct from old.role or new.client_id is distinct from old.client_id
                                   or new.state_ids is distinct from old.state_ids) then
      raise exception 'role, client and states are a summary of the person''s assignments: give or end an assignment instead'
        using errcode = '42501';
    end if;
    -- The root seat is never locked out.
    if old.system_role = 'admin' and old.status = 'active' and (new.system_role <> 'admin' or new.status <> 'active')
       and not exists (select 1 from public.app_users o where o.id <> old.id and o.system_role = 'admin' and o.status = 'active') then
      raise exception 'the last active admin cannot be suspended, offboarded or given another role' using errcode = '42501';
    end if;
  end if;
  if new.external and new.system_role <> 'operational' then
    raise exception 'a client login cannot hold a system role' using errcode = '23514'; end if;
  new.active := new.status in ('invited', 'onboarding', 'active');
  return new;
end $$;
create trigger app_users_b0_status_sync before insert or update on public.app_users
  for each row execute function app.app_users_status_sync();

-- Direct writes from the app (the REST API as a signed-in person). People are created by HR onboarding and their
-- status, system role and access change through their own actions (migration 33), each with its own check and audit
-- line. What may still be edited directly, by those the update policy lets through: name, phone, email.
create or replace function app.app_users_api_guard() returns trigger
language plpgsql set search_path = public as $$
declare editable text[] := array['display_name', 'phone', 'email'];
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    raise exception 'people are added through HR onboarding (Add joiner), not written directly' using errcode = '42501';
  end if;
  if (to_jsonb(new) - editable) is distinct from (to_jsonb(old) - editable) then
    raise exception 'only name, phone and email can be edited here; status, system role and access change through their own actions'
      using errcode = '42501';
  end if;
  return new;
end $$;
create trigger app_users_a1_api_guard before insert or update on public.app_users
  for each row execute function app.app_users_api_guard();

-- The old guard decided who may create or change whom by role rank. That is now decided by the update policy and the
-- lifecycle functions; what stays here is the one rule that is about the login itself.
create or replace function app.app_users_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;
  if (tg_op = 'INSERT' and new.auth_uid is not null) or (tg_op = 'UPDATE' and new.auth_uid is distinct from old.auth_uid) then
    raise exception 'auth_uid is set by login linking, not by hand' using errcode = '42501'; end if;
  return new;
end $$;

-- The main ledger keeps recording that a person was created, renamed, suspended or given a system role. The summary
-- columns are no longer listed: what a person may do is recorded where it is given (assignments, stages).
create or replace function app.app_users_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare was jsonb := '{}'::jsonb; now_ jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then
    perform app.ledger_append(null, null, 'supervisory', app.current_user_id(),
      jsonb_build_object('kind', 'user_created', 'user_id', new.id, 'name', new.display_name, 'role', new.role,
                         'system_role', new.system_role, 'status', new.status, 'external', new.external,
                         'client_id', new.client_id, 'state_ids', to_jsonb(new.state_ids), 'active', new.active));
    return null;
  elsif tg_op = 'DELETE' then                                           -- service role only (a create call undone)
    perform app.ledger_append(null, null, 'supervisory', app.current_user_id(),
      jsonb_build_object('kind', 'user_removed', 'user_id', old.id, 'name', old.display_name, 'role', old.role, 'client_id', old.client_id));
    return null;
  end if;
  foreach k in array array['display_name', 'status', 'system_role', 'active'] loop
    if to_jsonb(new)->k is distinct from to_jsonb(old)->k then
      was := was || jsonb_build_object(k, to_jsonb(old)->k);
      now_ := now_ || jsonb_build_object(k, to_jsonb(new)->k);
    end if;
  end loop;
  if (new.phone is distinct from old.phone) or (new.email is distinct from old.email) then   -- the values stay out of the ledger
    was := was || jsonb_build_object('sign_in', 'changed'); now_ := now_ || jsonb_build_object('sign_in', 'changed');
  end if;
  if now_ <> '{}'::jsonb then
    perform app.ledger_append(null, null, 'supervisory', app.current_user_id(),
      jsonb_build_object('kind', 'user_changed', 'user_id', new.id, 'name', new.display_name, 'before', was, 'after', now_));
  end if;
  return null;
end $$;

-- The summary on the person's row, from their live assignments.
create or replace function app.refresh_user_summary(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare u public.app_users; v_role public.user_role; v_client uuid; v_states uuid[]; n int;
begin
  select * into u from public.app_users where id = p_user;
  if u.id is null then return; end if;
  select coalesce(array_agg(x.s order by x.s), '{}') into v_states
    from (select distinct a.state_id as s from public.assignments a
           where a.employee_id = p_user and a.active and a.lens = 'state') x;
  select count(*), min(x.c::text)::uuid into n, v_client
    from (select a.client_id as c from public.assignments a where a.employee_id = p_user and a.active and a.lens = 'client'
          union
          select s.client_id from public.assignments a join public.scopes s on s.id = a.scope_id
           where a.employee_id = p_user and a.active and a.lens = 'scope') x;
  if n <> 1 then v_client := null; end if;
  v_role := case
    when u.system_role = 'admin' then 'admin'
    when cardinality(v_states) > 0 then 'state_manager'
    when exists (select 1 from public.assignments a where a.employee_id = p_user and a.active and a.op_role = 'client_account') then 'client_manager'
    when u.external then 'client_view'
    else 'operator' end;
  if v_role in ('admin', 'state_manager') then v_client := null; end if;
  update public.app_users set role = v_role, client_id = v_client, state_ids = v_states
   where id = p_user and (role, client_id, state_ids) is distinct from (v_role, v_client, v_states);
end $$;

-- A row written the old way by a seed, a script or the service key (never by a signed-in person: the guard above
-- refuses those) says "state_manager of these states" or "client_manager of this client". That becomes assignments.
create or replace function app.app_users_adopt_legacy() returns trigger
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  if auth.uid() is null then
    if new.role = 'state_manager' then
      foreach s in array new.state_ids loop
        insert into public.assignments (employee_id, lens, op_role, state_id) values (new.id, 'state', 'state_supervisor', s);
      end loop;
    elsif new.role = 'client_manager' and new.client_id is not null then
      insert into public.assignments (employee_id, lens, op_role, client_id) values (new.id, 'client', 'client_account', new.client_id);
    elsif new.role = 'client_view' and new.client_id is not null then
      insert into public.assignments (employee_id, lens, op_role, client_id) values (new.id, 'client', 'client_viewer', new.client_id);
    end if;
    if new.system_role = 'admin' then
      insert into public.audit_log (actor, action, target, detail)
      values (null, 'bootstrap_seed', new.id, jsonb_build_object('name', new.display_name, 'system_role', 'admin'));
    end if;
  end if;
  perform app.refresh_user_summary(new.id);
  return null;
end $$;
create trigger app_users_z0_adopt_legacy after insert on public.app_users
  for each row execute function app.app_users_adopt_legacy();

-- The system role is part of the summary (admin), so a change of it refreshes the summary too.
create or replace function app.app_users_summary_on_role() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.refresh_user_summary(new.id);
  return null;
end $$;
create trigger app_users_z1_summary after update of system_role, external on public.app_users
  for each row when (old.system_role is distinct from new.system_role or old.external is distinct from new.external)
  execute function app.app_users_summary_on_role();

-- 11 · assignments: guard, summary, audit, ledger ------------------------------------------------------------------------
create or replace function app.assignments_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare u public.app_users; sc public.scopes;
begin
  if tg_op = 'INSERT' then
    select * into u from public.app_users where id = new.employee_id;
    if u.id is null then raise exception 'unknown person' using errcode = '23503'; end if;
    if u.status in ('suspended', 'offboarded') then
      raise exception 'a % person cannot be given an assignment', u.status using errcode = '42501'; end if;
    if u.external and new.op_role <> 'client_viewer' then
      raise exception 'a client login can only view its own client' using errcode = '42501'; end if;
    if not u.external and new.op_role = 'client_viewer' then
      raise exception 'the client view is for a client''s own login, not for an employee' using errcode = '42501'; end if;
    if new.lens = 'scope' then
      select * into sc from public.scopes where id = new.scope_id;
      if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
      if sc.status = 'closed' then raise exception 'this scope is closed: its season has ended' using errcode = '42501'; end if;
      new.season_code := sc.season_code;
      new.ends_on := coalesce(new.ends_on, sc.season_end);
    end if;
    if auth.uid() is not null then
      new.created_at := now();
      new.created_by := coalesce(app.current_user_id(), new.created_by);
    end if;
    new.active := true; new.ended_at := null; new.ended_by := null; new.end_reason := null;
    return new;
  end if;

  -- Forward-only: an assignment is given and ended, never rewritten and never reopened.
  if new.employee_id <> old.employee_id or new.lens <> old.lens or new.op_role <> old.op_role
     or new.scope_id is distinct from old.scope_id or new.client_id is distinct from old.client_id
     or new.state_id is distinct from old.state_id or new.created_by is distinct from old.created_by
     or new.created_at <> old.created_at or new.season_code is distinct from old.season_code then
    raise exception 'an assignment is given or ended, not changed: end it and give a new one' using errcode = '42501';
  end if;
  if not old.active then
    raise exception 'an ended assignment is history: it cannot be changed or reopened' using errcode = '42501';
  end if;
  if not new.active then
    new.ended_at := coalesce(new.ended_at, now());
    new.ended_by := coalesce(new.ended_by, app.current_user_id());
    new.end_reason := coalesce(nullif(btrim(new.end_reason), ''), 'ended');
  end if;
  return new;
end $$;
create trigger assignments_guard before insert or update on public.assignments
  for each row execute function app.assignments_guard();

create or replace function app.assignments_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_scope public.scopes; v_what jsonb; v_name text;
begin
  perform app.refresh_user_summary(new.employee_id);
  select display_name into v_name from public.app_users where id = new.employee_id;
  if new.lens = 'scope' then select * into v_scope from public.scopes where id = new.scope_id; end if;
  v_what := jsonb_build_object('assignment_id', new.id, 'lens', new.lens, 'op_role', new.op_role, 'scope_id', new.scope_id,
                               'client_id', new.client_id, 'state_id', new.state_id, 'name', v_name);

  if tg_op = 'INSERT' then
    if coalesce(current_setting('app.assigning', true), '') <> 'on' then           -- app.assign writes one line with the stages
      perform app.audit('assigned', new.employee_id, v_what || jsonb_build_object('stages', to_jsonb(new.stages), 'posting', new.posting));
    end if;
  elsif old.active and not new.active then
    perform app.audit(case when new.end_reason like 'reassigned%' then 'reassigned' else 'revoked' end, new.employee_id,
      v_what || jsonb_build_object('stages', to_jsonb(new.stages), 'reason', new.end_reason));
  end if;

  -- The main ledger: who was given, or lost, the power to manage or to see a whole scope. (Stages held on a scope
  -- are recorded one by one by slot_assignments, as before.)
  if new.lens in ('client', 'state') or (new.op_role = 'export_manager' and v_scope.status <> 'draft') then
    if tg_op = 'INSERT' then
      perform app.ledger_append(null, new.scope_id, 'supervisory', app.current_user_id(),
        v_what || jsonb_build_object('act', 'assignment_given', 'user_id', new.employee_id));
    elsif old.active and not new.active then
      perform app.ledger_append(null, new.scope_id, 'supervisory', app.current_user_id(),
        v_what || jsonb_build_object('act', 'assignment_ended', 'user_id', new.employee_id, 'reason', new.end_reason));
    end if;
  end if;
  return null;
end $$;
create trigger assignments_after after insert or update on public.assignments
  for each row execute function app.assignments_after();

-- 12 · stages belong to an assignment ---------------------------------------------------------------------------------------
-- A stage given the old way (a row written straight into slot_assignments by a manager, a seed or a test) gets its
-- assignment made for it: giving someone a stage on a scope IS assigning them to that scope.
create or replace function app.slots_assignment() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.assignments;
begin
  if new.assignment_id is not null then
    select * into a from public.assignments where id = new.assignment_id;
    if a.id is null or not a.active or a.lens <> 'scope' or a.employee_id <> new.user_id or a.scope_id <> new.scope_id then
      raise exception 'that stage does not belong to this assignment' using errcode = '23514'; end if;
    return new;
  end if;
  select * into a from public.assignments
   where employee_id = new.user_id and scope_id = new.scope_id and lens = 'scope' and active;
  if a.id is null then
    insert into public.assignments (employee_id, lens, op_role, scope_id, created_by, stages)
    values (new.user_id, 'scope', 'operator', new.scope_id, app.current_user_id(), array[new.stage_type]) returning * into a;
  end if;
  new.assignment_id := a.id;
  return new;
end $$;
create trigger slots_a0_assignment before insert on public.slot_assignments
  for each row execute function app.slots_assignment();

create or replace function app.slots_sync_assignment() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_id uuid := case when tg_op = 'DELETE' then old.assignment_id else new.assignment_id end;
        a public.assignments; v_stages public.stage_type[];
begin
  if coalesce(current_setting('app.assigning', true), '') = 'on' then return null; end if;   -- app.assign sets them itself
  select * into a from public.assignments where id = v_id;
  if a.id is null or not a.active then return null; end if;
  select coalesce(array_agg(sa.stage_type order by array_position(s.chain, sa.stage_type)), '{}') into v_stages
    from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
   where sa.assignment_id = v_id;
  if cardinality(v_stages) = 0 and a.op_role = 'operator' then
    update public.assignments set active = false, end_reason = 'no stage left' where id = v_id;
  elsif v_stages is distinct from a.stages then
    update public.assignments set stages = v_stages where id = v_id;
    if tg_op = 'DELETE' or a.stages <> '{}' then
      perform app.audit('stages_changed', a.employee_id,
        jsonb_build_object('assignment_id', a.id, 'scope_id', a.scope_id, 'before', to_jsonb(a.stages), 'after', to_jsonb(v_stages)));
    end if;
  end if;
  return null;
end $$;
create trigger slots_z0_sync_assignment after insert or delete on public.slot_assignments
  for each row execute function app.slots_sync_assignment();

-- A season that has ended: closing the scope ends every assignment on it (and removes the stages held there).
create or replace function app.scopes_close_assignments() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status <> 'closed' and new.status = 'closed' then
    update public.assignments set active = false, end_reason = 'season ended' where scope_id = new.id and active;
    delete from public.slot_assignments where scope_id = new.id;
  end if;
  return null;
end $$;
create trigger scopes_z1_close_assignments after update on public.scopes
  for each row execute function app.scopes_close_assignments();

-- The summary of the people who were here before this migration, derived once now the way it is derived from here
-- on (an operator who holds no stage belongs to no client: the pool). The guard that refuses a hand edit of the
-- summary is put aside for this one statement.
alter table public.app_users disable trigger app_users_b0_status_sync;
do $$ declare r record; begin
  for r in select id from public.app_users loop perform app.refresh_user_summary(r.id); end loop;
end $$;
alter table public.app_users enable trigger app_users_b0_status_sync;

-- 13 · new tables: closed until migration 32 opens what each role may read ---------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['assignments', 'audit_log', 'employee_org', 'employee_docs', 'employee_files', 'employee_notes',
                           'employee_exits', 'employee_goals', 'onboarding_templates', 'template_tasks', 'onboarding_tasks',
                           'daily_codes', 'daily_code_passes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.audit_log_id_seq, public.employee_notes_id_seq, public.employee_exits_id_seq from anon, authenticated;

-- 14 · new functions are closed (migration 15 explains why): none of these is called from outside the database -------
revoke execute on function
  app.scopes_place(), app.audit_log_guard(), app.audit(text, uuid, jsonb, boolean), app.app_users_status_sync(),
  app.app_users_api_guard(), app.refresh_user_summary(uuid), app.app_users_adopt_legacy(), app.app_users_summary_on_role(),
  app.assignments_guard(), app.assignments_after(), app.slots_assignment(), app.slots_sync_assignment(),
  app.scopes_close_assignments()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
