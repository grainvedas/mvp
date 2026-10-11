-- GrainVeda MVP · migration 38: onboarding at scale (10 → 100 → 200+ hires).
-- Veda's brief "GrainVeda MVP — Onboarding at scale", 11 Oct 2026; decisions "as recommended" the same day:
--   1 invites by email when a sender is set up, and always a one-time link HR can copy (no sender yet: links only)
--   2 reminders: in the app first; nudges and a daily digest by email, queued until a sender is set up
--   3 a named HR resource may be the Deputy for seating State Managers (flagged); the admin does not seat them
--   4 a bulk-imported joiner gets a sign-in when they accept the invite (a temporary password stays the fallback)
--   5 HR may record a statutory step as "received on paper" (flagged); then Mark as joined is allowed
--   6 open steps of people still joining move, once, to the later of their due date and (the push date + 3)
-- ADDITIVE: new tables, columns, indexes and functions; functions replaced where named. No row is deleted; no ledger
-- block is touched. activate_joiner gains a second argument (a reason), so its old one-argument form is dropped and
-- recreated (a function, not data).
--
-- What is where:
--   A  openings (a state's planned positions per role), people linked to them, counts and "waiting for their wave"
--   B  app.import_joiners: an Excel import, dry run then commit of the valid rows in one transaction, idempotent
--   C  invites: one-time links (hash stored, never the token), made and used through the `invite` server function
--   D  intended role on a person; one checklist template per role, picked automatically
--   E  HR owner per joiner; paged, filtered lists (joiners, people, audit); bulk acts, each logged per person;
--      reminder queue
--   F  several people on one assignment in one act; "ready to assign"; the Deputy for seating State Managers
--   G  Mark as joined: refused while a statutory step is open; needs a reason (flagged) while other steps are open
--   H  the admin may do the HR and IT steps on the HR Admin's own checklist (flagged); the one-off due-date move

-- ── A · openings ─────────────────────────────────────────────────────────────────────────────────────────────────
create table if not exists public.openings (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  state_id    uuid not null references public.states(id),
  role        text not null check (role in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other')),
  stage       public.stage_type,
  client_id   uuid references public.clients(id),
  scope_id    uuid references public.scopes(id),
  positions   int not null check (positions between 1 and 5000),
  target_join date,
  status      text not null default 'open' check (status in ('open', 'on_hold', 'closed')),
  title       text check (title is null or length(title) <= 120),
  note        text check (note is null or length(note) <= 500),
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint openings_stage_for_operator check (stage is null or role = 'operator'),
  constraint openings_operator_stage check (role <> 'operator' or stage is not null)
);
create index if not exists openings_state on public.openings (state_id, status);
alter table public.openings enable row level security;
grant select on public.openings to authenticated;
drop policy if exists openings_read on public.openings;
create policy openings_read on public.openings for select to authenticated using (app.acts_as_hr() or app.is_admin() or app.can_assign());

alter table public.employee_org
  add column if not exists opening_id     uuid references public.openings(id),
  add column if not exists intended_role  text,
  add column if not exists intended_stage public.stage_type,
  add column if not exists hr_owner       uuid references public.app_users(id),
  add column if not exists import_batch   text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'employee_org_intended_role_check') then
    alter table public.employee_org add constraint employee_org_intended_role_check
      check (intended_role is null or intended_role in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'employee_org_intended_stage_check') then
    alter table public.employee_org add constraint employee_org_intended_stage_check
      check (intended_stage is null or intended_role = 'operator');
  end if;
end $$;
create index if not exists employee_org_opening on public.employee_org (opening_id) where opening_id is not null;
create index if not exists employee_org_hr_owner on public.employee_org (hr_owner) where hr_owner is not null;

-- The opening, role and HR owner of a person are set by the functions below (their rules: vacancy, who may own), not by
-- a direct write through the API (employee_org is updatable by HR for the org facts).
create or replace function app.employee_org_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if coalesce(current_setting('app.org_fn', true), '') = 'on' or current_user in ('postgres', 'supabase_admin') then return new; end if;
  if tg_op = 'INSERT' then
    if new.opening_id is not null or new.intended_role is not null or new.intended_stage is not null or new.hr_owner is not null then
      raise exception 'the opening, the intended role and the HR owner are set through HR''s screens' using errcode = '42501'; end if;
  elsif (new.opening_id, new.intended_role, new.intended_stage, new.hr_owner) is distinct from
        (old.opening_id, old.intended_role, old.intended_stage, old.hr_owner) then
    raise exception 'the opening, the intended role and the HR owner are set through HR''s screens' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists employee_org_guard on public.employee_org;
create trigger employee_org_guard before insert or update on public.employee_org for each row execute function app.employee_org_guard();

-- ── D · one checklist template per role ─────────────────────────────────────────────────────────────────────────────
alter table public.onboarding_templates add column if not exists role text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'onboarding_templates_role_check') then
    alter table public.onboarding_templates add constraint onboarding_templates_role_check
      check (role is null or role in ('state_manager', 'client_manager', 'operator', 'export_manager', 'hr', 'other'));
  end if;
end $$;
create unique index if not exists onboarding_templates_one_per_role on public.onboarding_templates (role) where active and role is not null;

-- ── C · invites ─────────────────────────────────────────────────────────────────────────────────────────────────────
-- The token itself is never stored: only its SHA-256. It travels in the link's #fragment (never sent to a web server).
create table if not exists public.invites (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.app_users(id),
  token_hash  text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  channel     text not null default 'link' check (channel in ('link', 'email')),
  send_status text not null default 'not_sent' check (send_status in ('not_sent', 'sent', 'failed')),
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  sent_at     timestamptz,
  used_at     timestamptz,
  revoked_at  timestamptz
);
create index if not exists invites_employee on public.invites (employee_id, created_at desc);
alter table public.invites enable row level security;
revoke all on public.invites from anon, authenticated;
grant select (id, employee_id, channel, send_status, created_by, created_at, expires_at, sent_at, used_at, revoked_at) on public.invites to authenticated;
drop policy if exists invites_read on public.invites;
create policy invites_read on public.invites for select to authenticated using (app.acts_as_hr());

-- ── E · reminders (queued; sent by the `invite` server function when a mail sender is set up) ──────────────────────
create table if not exists public.message_queue (
  id          bigserial primary key,
  kind        text not null check (kind in ('nudge', 'digest')),
  employee_id uuid references public.app_users(id),
  to_user     uuid references public.app_users(id),
  task_id     uuid references public.onboarding_tasks(id),
  to_email    text,
  subject     text not null,
  body        text not null,
  dedupe_key  text not null unique,
  status      text not null default 'queued' check (status in ('queued', 'sent', 'failed', 'skipped')),
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index if not exists message_queue_status on public.message_queue (status, created_at);
alter table public.message_queue enable row level security;
revoke all on public.message_queue from anon, authenticated;

-- ── F · the Deputy for seating State Managers ──────────────────────────────────────────────────────────────────────
create table if not exists public.seat_deputies (
  seat         text primary key check (seat = 'state_managers'),
  employee_id  uuid not null references public.app_users(id),
  appointed_by uuid references public.app_users(id),
  appointed_at timestamptz not null default now()
);
alter table public.seat_deputies enable row level security;
grant select on public.seat_deputies to authenticated;
drop policy if exists seat_deputies_read on public.seat_deputies;
create policy seat_deputies_read on public.seat_deputies for select to authenticated using (app.acts_as_hr() or app.is_admin());

-- ── E3 · indexes for lists that grow ────────────────────────────────────────────────────────────────────────────────
create index if not exists onboarding_tasks_pending on public.onboarding_tasks (employee_id, due_on) where status = 'pending';
create index if not exists audit_log_id_flagged on public.audit_log (id desc) where flagged;
create index if not exists audit_log_action on public.audit_log (action, id desc);
create index if not exists app_users_join on public.app_users (status, join_date) where not external;


-- ── A · openings: the rules ────────────────────────────────────────────────────────────────────────────────────────
-- Does this person hold the assignment the opening was for? (an HR opening is filled by joining: HR has no assignment)
create or replace function app.fills_opening(p_employee uuid, o public.openings) returns boolean
language sql stable security definer set search_path = public as $$
  select case o.role
    when 'state_manager' then exists (select 1 from public.assignments a where a.employee_id = p_employee and a.active
                                         and a.lens = 'state' and a.state_id = o.state_id)
    when 'client_manager' then exists (select 1 from public.assignments a join public.clients c on c.id = a.client_id
                                         where a.employee_id = p_employee and a.active and a.lens = 'client' and a.op_role = 'client_account'
                                           and c.state_id = o.state_id and (o.client_id is null or a.client_id = o.client_id))
    when 'operator' then exists (select 1 from public.assignments a join public.scopes s on s.id = a.scope_id
                                   where a.employee_id = p_employee and a.active and a.lens = 'scope' and a.op_role = 'operator'
                                     and s.state_id = o.state_id and (o.scope_id is null or a.scope_id = o.scope_id)
                                     and (o.client_id is null or s.client_id = o.client_id))   -- at any stage: placed is placed
    when 'export_manager' then exists (select 1 from public.assignments a join public.scopes s on s.id = a.scope_id
                                   where a.employee_id = p_employee and a.active and a.lens = 'scope' and a.op_role = 'export_manager'
                                     and s.state_id = o.state_id and (o.scope_id is null or a.scope_id = o.scope_id)
                                     and (o.client_id is null or s.client_id = o.client_id))
    when 'hr' then true
    else exists (select 1 from public.assignments a where a.employee_id = p_employee and a.active) end
$$;

-- Is there anything to assign people to yet? (the state is always there; a client must exist; a scope must be active)
create or replace function app.opening_ready(o public.openings) returns boolean
language sql stable security definer set search_path = public as $$
  select case o.role
    when 'client_manager' then exists (select 1 from public.clients c where c.state_id = o.state_id and (o.client_id is null or c.id = o.client_id))
    when 'operator' then exists (select 1 from public.scopes s where s.status = 'active' and s.state_id = o.state_id
                                   and (o.scope_id is null or s.id = o.scope_id) and (o.client_id is null or s.client_id = o.client_id)
                                   and (o.stage is null or o.stage = any(s.chain)))
    when 'export_manager' then exists (select 1 from public.scopes s where s.status = 'active' and s.state_id = o.state_id
                                   and (o.scope_id is null or s.id = o.scope_id) and (o.client_id is null or s.client_id = o.client_id))
    else true end
$$;

-- People on an opening: joining (invited, onboarding), joined (active). Suspended and offboarded do not hold a position.
create or replace function app.opening_numbers(o public.openings) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'positions', o.positions,
    'joining', count(*) filter (where u.status in ('invited', 'onboarding')),
    'joined', count(*) filter (where u.status = 'active'),
    'assigned', count(*) filter (where u.status = 'active' and app.fills_opening(u.id, o)),
    'waiting_wave', count(*) filter (where u.status = 'active' and not app.fills_opening(u.id, o) and not app.opening_ready(o)),
    'ready', count(*) filter (where u.status = 'active' and not app.fills_opening(u.id, o) and app.opening_ready(o)),
    'vacant', case when o.status = 'closed' then 0
                   else greatest(o.positions - count(*) filter (where u.status in ('invited', 'onboarding', 'active')), 0) end)
    from public.employee_org e join public.app_users u on u.id = e.employee_id
   where e.opening_id = o.id
$$;

create or replace function app.opening_json(o public.openings) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'code', o.code, 'state_id', o.state_id, 'state_name', (select name from public.states where id = o.state_id),
           'role', o.role, 'stage', o.stage, 'client_id', o.client_id, 'client_name', (select name from public.clients where id = o.client_id),
           'scope_id', o.scope_id,
           'scope_name', (select cr.name || ' · ' || s.season_code || ' · ' || s.geography from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = o.scope_id),
           'target_join', o.target_join, 'status', o.status, 'title', o.title, 'note', o.note, 'created_at', o.created_at,
           'ready_target', app.opening_ready(o)) || app.opening_numbers(o)
$$;

-- HR makes and changes openings; the admin reads them (numbers only: no names are on an opening).
create or replace function app.save_opening(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
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
end $$;

create or replace function app.set_opening_status(p_opening uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.openings;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR plans openings' using errcode = '42501'; end if;
  if p_status not in ('open', 'on_hold', 'closed') then raise exception 'status: open, on hold or closed' using errcode = '23514'; end if;
  update public.openings set status = p_status, updated_at = now() where id = p_opening returning * into o;
  if o.id is null then raise exception 'unknown opening' using errcode = 'P0002'; end if;
  perform app.audit('opening_status', null, jsonb_build_object('opening', o.code, 'status', p_status));
  return app.opening_json(o);
end $$;

-- The Openings page and the admin's overview: per opening, per state, overall. Numbers only.
create or replace function app.openings_summary(p_state uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rows jsonb; keys text[] := array['positions', 'joining', 'joined', 'assigned', 'waiting_wave', 'ready', 'vacant'];
begin
  perform app.me_or_raise();
  if not (app.acts_as_hr() or app.is_admin()) then raise exception 'openings are for HR and the admin' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(app.opening_json(o) order by st.name, o.status = 'closed', o.role, o.code), '[]'::jsonb) into rows
    from public.openings o join public.states st on st.id = o.state_id
   where p_state is null or o.state_id = p_state;
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
                    where not u.external and u.system_role <> 'admin' and u.status in ('invited', 'onboarding', 'active') and e.opening_id is null),
    'can_plan', app.acts_as_hr(),
    'can_seat', app.is_hr_admin() or app.is_sm_deputy());
end $$;

-- What an opening may name in a state: its clients and their scopes that are not closed. HR cannot read clients or scopes
-- (people records only); the opening form needs their names, nothing more.
create or replace function app.opening_targets(p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'openings are planned by HR' using errcode = '42501'; end if;
  return jsonb_build_object(
    'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name)
                           from public.clients c where c.state_id = p_state), '[]'::jsonb),
    'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'season_code', s.season_code, 'geography', s.geography,
                                                            'status', s.status, 'client_id', s.client_id, 'chain', s.chain)
                                         order by s.season_code, s.geography)
                          from public.scopes s where s.state_id = p_state and s.status <> 'closed'), '[]'::jsonb));
end $$;

-- Link people who are already in the system (added before openings, or without one) to an opening.
create or replace function app.link_to_opening(p_employees uuid[], p_opening uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.openings; u public.app_users; filled int; out jsonb := '[]'::jsonb; e uuid;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR links people to openings' using errcode = '42501'; end if;
  select * into o from public.openings where id = p_opening for update;
  if o.id is null then raise exception 'unknown opening' using errcode = 'P0002'; end if;
  if o.status = 'closed' then raise exception 'this opening is closed' using errcode = '23514'; end if;
  perform set_config('app.org_fn', 'on', true);
  foreach e in array coalesce(p_employees, '{}') loop
    select * into u from public.app_users where id = e and not external;
    select count(*) into filled from public.employee_org x join public.app_users y on y.id = x.employee_id
     where x.opening_id = o.id and y.status in ('invited', 'onboarding', 'active');
    if u.id is null or not app.hr_may_manage(u.system_role) then
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
end $$;

-- A person's intended role without an opening (an opening's people take the opening's role).
create or replace function app.set_intended_role(p_employee uuid, p_role text, p_stage public.stage_type default null) returns void
language plpgsql security definer set search_path = public as $$
declare u public.app_users;
begin
  perform app.me_or_raise();
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null or not (app.acts_as_hr() and app.hr_may_manage(u.system_role)) then
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
end $$;


-- ── A, D, E1 · Add joiner: an opening (or a role), the checklist for that role, an HR owner ─────────────────────────
-- As before (migration 37) and, new: p.opening_id (its role and stage follow; refused when the opening is not open or
-- is full), or p.intended_role / p.intended_stage without an opening; the template: the one given, else the active
-- template for the role, else the default; p.hr_owner (an active HR person; by default the HR person adding);
-- p.import_batch (the bulk import's batch). An opening for HR makes the person HR (system role) unless said otherwise.
create or replace function app.add_joiner(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); my_role public.system_role; v_role public.system_role;
        v_name text := btrim(coalesce(p->>'full_name', '')); v_email text := app.email_key(p->>'personal_email');
        v_phone text; v_join date; v_type public.employment_type; v_tpl uuid; v_id uuid; n int;
        op public.openings; v_irole text; v_istage public.stage_type; v_owner uuid; filled int;
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

  begin
    insert into public.app_users (display_name, email, phone, status, system_role, join_date, created_by)
    values (v_name, v_email, v_phone, 'invited', v_role, v_join, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email or phone already exists' using errcode = '23505';
  end;
  perform set_config('app.org_fn', 'on', true);
  insert into public.employee_org (employee_id, employment_type, designation_band, department, job_title, reports_to, buddy, updated_by, template_id,
                                   opening_id, intended_role, intended_stage, hr_owner, import_batch)
  values (v_id, v_type, nullif(btrim(p->>'designation_band'), ''), nullif(btrim(p->>'department'), ''), nullif(btrim(p->>'job_title'), ''),
          nullif(p->>'reports_to', '')::uuid, nullif(p->>'buddy', '')::uuid, me, v_tpl,
          op.id, v_irole, v_istage, v_owner, nullif(left(p->>'import_batch', 60), ''));
  perform set_config('app.org_fn', '', true);
  insert into public.employee_docs (employee_id) values (v_id);
  n := app.stamp_tasks(v_id, v_tpl, v_join, v_type);

  perform app.audit('identity_created', v_id, jsonb_build_object('name', v_name, 'system_role', v_role, 'employment_type', v_type,
                                                                 'join_date', v_join, 'tasks', n, 'opening', op.code, 'role', v_irole,
                                                                 'import_batch', nullif(p->>'import_batch', '')));
  if v_role = 'hr_resource' then
    -- an HR resource making another HR resource is allowed, and always flagged for the admin to see
    perform app.audit('hr_resource_created', v_id, jsonb_build_object('name', v_name, 'by_role', my_role), my_role = 'hr_resource');
  end if;
  return jsonb_build_object('id', v_id, 'tasks', n, 'status', 'invited');
end $$;

-- ── B · the bulk import ───────────────────────────────────────────────────────────────────────────────────────────
-- p_rows: [{ full_name, personal_email, phone, join_date (YYYY-MM-DD), employment_type, designation_band, department,
--            job_title, reports_to (an email), opening (a code) }]  — at most 1000.
-- Dry run: every row ready / warning / error / skipped, with reasons (codes the screen translates). Commit: the ready and
-- warning rows, one by one through app.add_joiner (so each is made exactly as Add joiner makes it), in ONE transaction;
-- a row that fails at that point is reported and the others are kept. A row whose email and phone are already one
-- person's is "already added" (skipped): uploading the same file again makes nobody twice.
create or replace function app.import_joiners(p_rows jsonb, p_dry_run boolean default true, p_batch text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); r jsonb; i int := 0; out jsonb := '[]'::jsonb; errs text[]; warns text[]; st text;
        v_email text; v_phone text; v_join date; v_type text; op public.openings; v_rep uuid; by_email uuid; by_phone uuid;
        seen_email text[] := '{}'; seen_phone text[] := '{}'; taken jsonb := '{}'::jsonb; filled int; made jsonb; row_out jsonb;
        n_ready int := 0; n_warn int := 0; n_err int := 0; n_skip int := 0; n_made int := 0; v_batch text;
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
                                  'reasons', to_jsonb(case when st = 'skipped' then array['imp.already_added'] else errs || warns end));
    if st = 'skipped' then row_out := row_out || jsonb_build_object('id', by_email); end if;

    if not coalesce(p_dry_run, true) and st in ('ready', 'warning') then
      begin
        made := app.add_joiner(jsonb_build_object('full_name', btrim(r->>'full_name'), 'personal_email', v_email, 'phone', v_phone,
                  'join_date', v_join, 'employment_type', v_type, 'designation_band', nullif(btrim(r->>'designation_band'), ''),
                  'department', nullif(btrim(r->>'department'), ''), 'job_title', nullif(btrim(r->>'job_title'), ''),
                  'reports_to', v_rep, 'opening_id', op.id, 'import_batch', v_batch));
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
end $$;


-- ── C · invites (the `invite` server function calls these) ──────────────────────────────────────────────────────────
-- Asked AS THE CALLER: whom may I invite? HR, for the joiners it manages who have not joined yet.
create or replace function app.invite_targets(p_employees uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); ok jsonb := '[]'::jsonb; skipped jsonb := '[]'::jsonb; u public.app_users; e uuid;
begin
  if not app.acts_as_hr() then raise exception 'only HR sends invites' using errcode = '42501'; end if;
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  foreach e in array coalesce(p_employees, '{}') loop
    select * into u from public.app_users where id = e and not external;
    if u.id is null or u.id = me or not app.hr_may_manage(u.system_role) then
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
end $$;

-- SERVICE KEY ONLY from here to use_invite: the server function holds the token; the database keeps its hash.
create or replace function app.record_invite(p_employee uuid, p_actor uuid, p_hash text, p_channel text default 'link', p_hours int default 72)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.invites;
begin
  if p_hash !~ '^[0-9a-f]{64}$' then raise exception 'bad token hash' using errcode = '22023'; end if;
  if not exists (select 1 from public.app_users where id = p_employee and status in ('invited', 'onboarding') and not external) then
    raise exception 'this person is not joining' using errcode = '23514'; end if;
  -- one live invite per person: a new one replaces the old
  update public.invites set revoked_at = now() where employee_id = p_employee and used_at is null and revoked_at is null;
  insert into public.invites (employee_id, token_hash, channel, created_by, expires_at)
  values (p_employee, p_hash, case when p_channel = 'email' then 'email' else 'link' end, p_actor,
          now() + make_interval(hours => least(greatest(coalesce(p_hours, 72), 1), 168)))
  returning * into v;
  perform app.audit_as(p_actor, 'invite_created', p_employee, jsonb_build_object('channel', v.channel, 'expires_at', v.expires_at));
  return jsonb_build_object('id', v.id, 'expires_at', v.expires_at);
end $$;

create or replace function app.mark_invite_sent(p_invite uuid, p_ok boolean) returns void
language sql security definer set search_path = public as $$
  update public.invites set send_status = case when p_ok then 'sent' else 'failed' end, sent_at = case when p_ok then now() end,
         channel = case when p_ok then 'email' else channel end
   where id = p_invite;
$$;

create or replace function app.invite_lookup(p_hash text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v public.invites; u public.app_users;
begin
  if p_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('state', 'not_found'); end if;
  select * into v from public.invites where token_hash = p_hash;
  if v.id is null then return jsonb_build_object('state', 'not_found'); end if;
  select * into u from public.app_users where id = v.employee_id;
  return jsonb_build_object('invite_id', v.id, 'employee_id', u.id, 'name', u.display_name, 'email', u.email,
    'login_id', case when u.auth_uid is not null and u.auth_uid <> u.id then u.auth_uid end,
    'state', case when v.used_at is not null then 'used' when v.revoked_at is not null then 'revoked'
                  when v.expires_at < now() then 'expired' when u.status not in ('invited', 'onboarding') or not u.active then 'inactive'
                  else 'ok' end);
end $$;

create or replace function app.use_invite(p_invite uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v public.invites;
begin
  update public.invites set used_at = now() where id = p_invite and used_at is null and revoked_at is null and expires_at >= now()
  returning * into v;
  if v.id is null then raise exception 'this invite cannot be used' using errcode = '23514'; end if;
  perform app.audit_as(v.employee_id, 'invite_accepted', v.employee_id, '{}'::jsonb);
end $$;

-- ── E5 · reminders: queued daily; sent by the `invite` server function when a mail sender is set up ───────────────
-- A joiner's own step: a nudge one day after it is due and another three days after (at most two per step).
-- An HR owner: one digest a day when any of their joiners has an overdue step. Nothing is queued for a person
-- without an email. Messages carry names and step titles only.
create or replace function app.queue_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; m int;
begin
  insert into public.message_queue (kind, employee_id, to_user, task_id, to_email, subject, body, dedupe_key)
  select 'nudge', u.id, u.id, t.id, u.email,
         'GrainVeda: a joining step is waiting',
         'Hello ' || split_part(u.display_name, ' ', 1) || ',' || chr(10) || chr(10) ||
         'Your joining step "' || t.title || '" was due on ' || to_char(t.due_on, 'DD Mon YYYY') || '.' || chr(10) ||
         'Open the GrainVeda app to finish it: {app}/onboarding' || chr(10) || chr(10) ||
         'नमस्ते, आपका जॉइनिंग चरण "' || t.title || '" बाकी है। GrainVeda ऐप खोलकर इसे पूरा करें।',
         'nudge:' || t.id || ':' || d.k
    from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id
    cross join (values (1), (3)) d(k)
   where t.status = 'pending' and t.owner = 'hire' and u.status in ('invited', 'onboarding') and not u.external
     and app.email_key(u.email) is not null and app.today() >= t.due_on + d.k
  on conflict (dedupe_key) do nothing;
  get diagnostics m = row_count; n := n + m;
  insert into public.message_queue (kind, to_user, to_email, subject, body, dedupe_key)
  select 'digest', h.id, h.email, 'GrainVeda: joiners with overdue steps (' || x.n || ')',
         'Hello ' || split_part(h.display_name, ' ', 1) || ',' || chr(10) || chr(10) ||
         x.n || ' of your joiners have overdue steps: ' || x.names || '.' || chr(10) ||
         'Open HR · Joiners, "Mine", "Overdue only": {app}/hr',
         'digest:' || h.id || ':' || app.today()
    from (select e.hr_owner, count(distinct u.id) as n, string_agg(distinct u.display_name, ', ') as names
            from public.employee_org e join public.app_users u on u.id = e.employee_id
            join public.onboarding_tasks t on t.employee_id = u.id and t.status = 'pending' and t.due_on < app.today()
           where e.hr_owner is not null and u.status in ('invited', 'onboarding', 'active') and not u.external
           group by e.hr_owner) x
    join public.app_users h on h.id = x.hr_owner and h.status = 'active' and app.email_key(h.email) is not null
  on conflict (dedupe_key) do nothing;
  get diagnostics m = row_count; n := n + m;
  return n;
end $$;

-- Asked AS THE CALLER (HR) by the server function before it sends: may this person start a sending round?
create or replace function app.may_send_messages() returns boolean
language sql stable security definer set search_path = public as $$ select app.acts_as_hr() $$;

-- SERVICE KEY ONLY: what to send, and what happened.
create or replace function app.messages_to_send(p_limit int default 50) returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'to_email', to_email, 'subject', subject, 'body', body) order by id), '[]'::jsonb)
    from (select * from public.message_queue where status = 'queued' and to_email is not null order by id
           limit least(greatest(coalesce(p_limit, 50), 1), 200)) q
$$;
create or replace function app.mark_message(p_id bigint, p_ok boolean, p_error text default null) returns void
language sql security definer set search_path = public as $$
  update public.message_queue set status = case when p_ok then 'sent' else 'failed' end, sent_at = case when p_ok then now() end,
         error = case when p_ok then null else left(p_error, 200) end
   where id = p_id;
$$;

-- What HR reads about the queue (numbers only)
create or replace function app.reminder_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not app.acts_as_hr() then null else jsonb_build_object(
    'queued', (select count(*) from public.message_queue where status = 'queued'),
    'sent_7d', (select count(*) from public.message_queue where status = 'sent' and sent_at > now() - interval '7 days'),
    'failed_7d', (select count(*) from public.message_queue where status = 'failed' and created_at > now() - interval '7 days')) end
$$;

-- ── E2, E3 · the joiners list, paged and filtered on the server ─────────────────────────────────────────────────────
-- p: { q, state, role, opening, status ('joining' | 'invited' | 'onboarding' | 'active'), owner ('mine' | 'none' | <id>),
--      overdue (true), waiting ('us' | 'joiner' | 'it'), limit (≤ 200), offset }
create or replace function app.joiners_page(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); v_q text := nullif(lower(btrim(p->>'q')), ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid; v_status text := nullif(p->>'status', '');
        v_owner text := nullif(p->>'owner', ''); v_overdue boolean := coalesce((p->>'overdue')::boolean, false);
        v_wait text := nullif(p->>'waiting', ''); v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
        v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0); res jsonb;
begin
  if not app.acts_as_hr() then raise exception 'only HR opens the pipeline' using errcode = '42501'; end if;
  with base as (
    select u.id, u.display_name, u.email, u.phone, u.status, u.system_role, u.join_date, u.auth_uid, u.created_at,
           o.employment_type, o.job_title, o.department, o.opening_id, o.intended_role, o.intended_stage, o.hr_owner,
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
  ), f as (
    select b.* from base b
     where (v_q is null or lower(b.display_name) like '%' || v_q || '%' or lower(coalesce(b.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(b.phone, '') like '%' || regexp_replace(v_q, '[^0-9]', '', 'g') || '%'))
       and (v_state is null or b.opening_state = v_state
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
                'state_name', (select name from public.states where id = f.opening_state),
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
end $$;

-- People & access, paged and filtered on the server; the same rows and the same visibility as app.people_directory.
-- p: { kind ('employees' | 'client_logins'), q, status, state, client, role, opening, owner, unassigned (true), limit, offset }
create or replace function app.people_page(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb;
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or lower(coalesce(v.email, '')) like '%' || v_q || '%'
            or (v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state))
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
end $$;

-- The audit log, paged. p: { flagged, action, q (a name), limit (≤ 200), offset }
create or replace function app.audit_page(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_flag boolean := coalesce((p->>'flagged')::boolean, false); v_action text := nullif(p->>'action', '');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
        v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0); res jsonb;
begin
  perform app.me_or_raise();
  if not (app.is_admin() or app.is_hr_admin()) then raise exception 'the audit log is for the admin and the HR Admin' using errcode = '42501'; end if;
  with f as (
    select l.*, a.display_name as actor_name, a.system_role as actor_role, coalesce(t.display_name, l.detail->>'name') as target_name
      from public.audit_log l left join public.app_users a on a.id = l.actor left join public.app_users t on t.id = l.target
     where (not v_flag or l.flagged) and (v_action is null or l.action = v_action)
       and (v_q is null or lower(coalesce(a.display_name, '')) like '%' || v_q || '%' or lower(coalesce(t.display_name, l.detail->>'name', '')) like '%' || v_q || '%')
  )
  select jsonb_build_object('total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'at', x.created_at, 'action', x.action, 'flagged', x.flagged, 'detail', x.detail,
             'actor', x.actor, 'actor_name', coalesce(x.actor_name, 'System'), 'actor_role', x.actor_role,
             'target', x.target, 'target_name', x.target_name) order by x.id desc)
       from (select * from f order by id desc limit v_limit offset v_offset) x), '[]'::jsonb),
    'actions', (select coalesce(jsonb_agg(distinct action), '[]'::jsonb) from public.audit_log),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $$;


-- ── G1 · Mark as joined: refused while a statutory step is open; a reason (flagged) while other steps are open ──────
drop function if exists app.activate_joiner(uuid);
create or replace function app.activate_joiner(p_employee uuid, p_reason text default null) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; by_admin boolean; v_stat text; n_open int; v_why text := btrim(coalesce(p_reason, ''));
begin
  select * into u from public.app_users where id = p_employee and not external;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  -- The admin marks one person as joined: the holder of the HR Admin seat, while she has not joined (until then the
  -- seat is in effect vacant and HR cannot act). Everyone else is HR's to mark, also while the seat is vacant.
  by_admin := app.is_admin() and u.system_role = 'hr_admin' and u.id <> me;
  if not by_admin and (not (app.is_hr() and app.hr_may_manage(u.system_role)) or u.id = me) then
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
end $$;

-- What the joiner page needs to say before the button is pressed
create or replace function app.activation_state(p_employee uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'statutory_open', coalesce((select jsonb_agg(t.title order by t.seq) from public.onboarding_tasks t
                                 where t.employee_id = p_employee and t.status = 'pending' and t.statutory), '[]'::jsonb),
    'open', (select count(*) from public.onboarding_tasks t where t.employee_id = p_employee and t.status = 'pending'))
$$;

-- Decision 5: a statutory step done on paper (e.g. the PF and gratuity forms signed by hand), recorded by HR. Flagged.
create or replace function app.record_on_paper(p_task uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); t public.onboarding_tasks; u public.app_users; n_open int;
begin
  select * into t from public.onboarding_tasks where id = p_task;
  if t.id is null then raise exception 'task not found' using errcode = 'P0002'; end if;
  select * into u from public.app_users where id = t.employee_id;
  if not ((((app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role)) or (app.is_admin() and u.system_role = 'hr_admin'))
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
end $$;

-- ── E4 · bulk acts on the joiners list: each person is done (and logged) on their own ──────────────────────────────
create or replace function app.complete_task_many(p_employees uuid[], p_code text, p_data jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid; t public.onboarding_tasks; out jsonb := '[]'::jsonb; n_ok int := 0;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR does HR steps' using errcode = '42501'; end if;
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  foreach e in array coalesce(p_employees, '{}') loop
    select * into t from public.onboarding_tasks where employee_id = e and code = p_code;
    if t.id is null or t.status <> 'pending' then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', case when t.id is null then 'no_such_step' else 'done_already' end);
    elsif t.owner = 'hire' then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', 'joiners_step');
    else
      begin
        perform app.complete_task(t.id, coalesce(p_data, '{}'::jsonb));
        perform app.audit('task_done', e, jsonb_build_object('task', t.title, 'bulk', true,
                          'name', (select display_name from public.app_users where id = e)));
        out := out || jsonb_build_object('id', e, 'ok', true); n_ok := n_ok + 1;
      exception when others then
        out := out || jsonb_build_object('id', e, 'ok', false, 'error', left(sqlerrm, 200));
      end;
    end if;
  end loop;
  return jsonb_build_object('done', n_ok, 'results', out);
end $$;

create or replace function app.update_joiner_many(p_employees uuid[], p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid; out jsonb := '[]'::jsonb; n_ok int := 0; allowed jsonb;
begin
  perform app.me_or_raise();
  if not app.acts_as_hr() then raise exception 'only HR edits joiners' using errcode = '42501'; end if;
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  -- for a group: the first day only (each person's own facts are edited on their page)
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into allowed from jsonb_each(coalesce(p, '{}'::jsonb))
   where key in ('first_day_date', 'first_day_time', 'first_day_place', 'first_day_ask_for', 'first_day_bring');
  foreach e in array coalesce(p_employees, '{}') loop
    begin
      perform app.update_joiner(e, allowed);
      perform app.audit('first_day_set', e, jsonb_build_object('name', (select display_name from public.app_users where id = e), 'bulk', true));
      out := out || jsonb_build_object('id', e, 'ok', true); n_ok := n_ok + 1;
    exception when others then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', left(sqlerrm, 200));
    end;
  end loop;
  return jsonb_build_object('done', n_ok, 'results', out);
end $$;

create or replace function app.set_hr_owner(p_employees uuid[], p_owner uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
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
    if u.id is null or not app.hr_may_manage(u.system_role) then
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
end $$;

create or replace function app.activate_many(p_employees uuid[], p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid; out jsonb := '[]'::jsonb; n_ok int := 0;
begin
  perform app.me_or_raise();
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  foreach e in array coalesce(p_employees, '{}') loop
    begin
      perform app.activate_joiner(e, p_reason);
      out := out || jsonb_build_object('id', e, 'ok', true); n_ok := n_ok + 1;
    exception when others then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', left(sqlerrm, 200));
    end;
  end loop;
  return jsonb_build_object('done', n_ok, 'results', out);
end $$;

-- ── F3 · the Deputy for seating State Managers (decision 3) ─────────────────────────────────────────────────────────
create or replace function app.is_sm_deputy() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.seat_deputies d join public.app_users u on u.id = d.employee_id
                  where d.seat = 'state_managers' and d.employee_id = app.current_user_id()
                    and u.status = 'active' and u.system_role = 'hr_resource')
$$;

create or replace function app.set_sm_deputy(p_employee uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); u public.app_users; old uuid;
begin
  if not (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())) then
    raise exception 'only the HR Admin names the deputy' using errcode = '42501'; end if;
  select employee_id into old from public.seat_deputies where seat = 'state_managers';
  if p_employee is null then
    delete from public.seat_deputies where seat = 'state_managers';
    perform app.audit('sm_deputy_cleared', old, jsonb_build_object('name', (select display_name from public.app_users where id = old)), true);
    return jsonb_build_object('deputy', null);
  end if;
  select * into u from public.app_users where id = p_employee;
  if u.id is null or u.status <> 'active' or u.system_role <> 'hr_resource' then
    raise exception 'the deputy must be an active HR person (not the HR Admin)' using errcode = '23514'; end if;
  insert into public.seat_deputies (seat, employee_id, appointed_by) values ('state_managers', u.id, me)
  on conflict (seat) do update set employee_id = excluded.employee_id, appointed_by = excluded.appointed_by, appointed_at = now();
  perform app.audit('sm_deputy_set', u.id, jsonb_build_object('name', u.display_name), true);
  return jsonb_build_object('deputy', jsonb_build_object('id', u.id, 'name', u.display_name));
end $$;

create or replace function app.sm_deputy() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when app.acts_as_hr() or app.is_admin() then (
    select jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'appointed_at', d.appointed_at)
      from public.seat_deputies d join public.app_users u on u.id = d.employee_id where d.seat = 'state_managers') end
$$;

-- ── F1, F2 · several people on one assignment; who is ready for it ─────────────────────────────────────────────────
create or replace function app.assign_many(p_employees uuid[], p_lens public.assignment_lens, p_target uuid, p_op_role public.op_role,
                                           p_stages public.stage_type[] default '{}', p_posting text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare e uuid; out jsonb := '[]'::jsonb; n_ok int := 0; r jsonb;
begin
  perform app.me_or_raise();
  if not app.may_assign(p_lens, p_op_role, p_target) then
    raise exception 'you cannot give this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if cardinality(coalesce(p_employees, '{}')) > 500 then raise exception 'at most 500 people at once' using errcode = '23514'; end if;
  foreach e in array coalesce(p_employees, '{}') loop
    begin
      r := app.assign(e, p_lens, p_target, p_op_role, p_stages, p_posting, null);
      out := out || jsonb_build_object('id', e, 'ok', true, 'warnings', r->'warnings'); n_ok := n_ok + 1;
    exception when others then
      out := out || jsonb_build_object('id', e, 'ok', false, 'error', left(sqlerrm, 200));
    end;
  end loop;
  return jsonb_build_object('done', n_ok, 'results', out);
end $$;

-- People who joined for this place and have not been given it: the opening's role, state, client, scope and stage.
create or replace function app.ready_to_assign(p_lens public.assignment_lens, p_target uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_state uuid; v_client uuid; sc public.scopes;
begin
  perform app.me_or_raise();
  if p_lens = 'state' then
    if not app.may_assign('state', 'state_supervisor', p_target) then raise exception 'not yours to assign' using errcode = '42501'; end if;
    v_state := p_target;
  elsif p_lens = 'client' then
    if not app.may_assign('client', 'client_account', p_target) then raise exception 'not yours to assign' using errcode = '42501'; end if;
    select state_id into v_state from public.clients where id = p_target; v_client := p_target;
  else
    if not app.may_assign('scope', 'operator', p_target) then raise exception 'not yours to assign' using errcode = '42501'; end if;
    select * into sc from public.scopes where id = p_target; v_state := sc.state_id; v_client := sc.client_id;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('employee_id', u.id, 'name', u.display_name, 'phone', u.phone, 'status', u.status,
             'role', o.role, 'stage', o.stage, 'opening_code', o.code, 'opening_id', o.id,
             'op_role', case o.role when 'state_manager' then 'state_supervisor' when 'client_manager' then 'client_account'
                                    when 'export_manager' then 'export_manager' else 'operator' end)
             order by o.code, u.display_name)
      from public.employee_org e join public.app_users u on u.id = e.employee_id join public.openings o on o.id = e.opening_id
     where u.status = 'active' and not u.external and o.status <> 'closed' and o.state_id = v_state
       and case p_lens
             when 'state' then o.role = 'state_manager'
             when 'client' then o.role = 'client_manager' and (o.client_id is null or o.client_id = v_client)
             else o.role in ('operator', 'export_manager') and (o.scope_id is null or o.scope_id = p_target)
                  and (o.client_id is null or o.client_id = v_client) and (o.stage is null or o.stage = any(sc.chain)) end
       and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = p_lens
                         and p_target in (a.scope_id, a.client_id, a.state_id))), '[]'::jsonb);
end $$;


-- ── replaced functions (patches of migration 37's definitions) ─────────────────────────────────────────────────

-- H2 · complete_task
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
  as_hr := (((app.is_admin() or app.is_hr()) and app.hr_may_manage(u.system_role))
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

-- H2, D, C, G · joiner_detail
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
  v_full := app.acts_as_hr();
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
    'can_manage', app.hr_may_manage(u.system_role) and u.id <> app.current_user_id(),
    -- "Mark as joined", exactly as app.activate_joiner decides it
    'can_activate', u.status in ('invited', 'onboarding') and u.id <> app.current_user_id()
                    and ((app.is_admin() and u.system_role = 'hr_admin') or (app.is_hr() and app.hr_may_manage(u.system_role))),
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
    'can_do_steps', (app.hr_may_manage(u.system_role) or (app.is_admin() and u.system_role = 'hr_admin')) and u.id <> app.current_user_id(),
    'can_invite', v_full and app.hr_may_manage(u.system_role) and u.id <> app.current_user_id() and u.status in ('invited', 'onboarding'));
end $function$;

-- F3 · may_assign
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
  if p_lens = 'state' then return app.is_hr_admin() or app.is_sm_deputy(); end if;   -- F3 (migration 38): or the named Deputy                  -- the HR Admin seats State Managers (Veda, 10 Oct)
  if p_lens = 'client' then
    if p_op_role = 'client_account' then                                      -- a client's account: by a supervisor of its home state
      return exists (select 1 from app.eff_assignments(me) a
                      where a.lens = 'state' and a.state_id = (select c.state_id from public.clients c where c.id = p_target));
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $function$;

-- F3 · assign
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

-- A · platform_overview
CREATE OR REPLACE FUNCTION app.platform_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not app.is_admin() then
    raise exception 'the platform overview is for the admin' using errcode = '42501'; end if;
  with live as (
    select distinct sa.scope_id, sa.stage_type, sa.user_id
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from public.scopes s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join public.scopes s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  managed as (
    select distinct a.client_id from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from public.scopes s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from public.scopes s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join public.scopes s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(q.n) from qr q join public.scopes s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           exists (select 1 from managed m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from public.scopes s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- Chain order, not registry order: each stage's step number in the chains of the active scopes that have it,
  -- averaged (every chain starts at its entry stage); the seal is always last. Stages of active chains are listed even
  -- with no record yet, so a stage nobody has reached shows as 0.
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from public.scopes s where s.status = 'active')
                     then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from public.scopes s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
  select jsonb_build_object(
    'clients', jsonb_build_object(
       'total', (select count(*) from cl),
       'active', (select count(*) from cl where scopes_active > 0),
       'dormant', (select count(*) from cl where scopes_active = 0),
       'without_manager', (select count(*) from cl where not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.state_name, cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from public.scopes s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from public.scopes s where s.crop_id = cr.id)) order by cr.name)
                  from public.crops cr), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from public.scopes where status = 'active'),
       'setup', (select count(*) from public.scopes where status = 'draft'),
       'closed', (select count(*) from public.scopes where status = 'closed'),
       'qr_issued', (select count(*) from public.qr_seals)),
    'attention', jsonb_build_object(
       'open_flags', (select count(*) from public.flags where status = 'open'),
       'farmers_step1', (select count(*) from public.farmers where status = 'draft'),
       'farmers_step2', (select count(*) from public.farmers where status = 'under_review'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join public.scopes s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', f.footprint_code, 'client', c.name) order by fl.created_at)
                  from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
                  where fl.status = 'open'), '[]')),
    'states', coalesce((select jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name, 'code', st.code,
                  'managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                                where a.active and a.lens = 'state' and a.state_id = st.id and u.status = 'active')) order by st.name)
                  from public.states st), '[]'),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp where pp.position is not null or pp.pending + pp.done > 0), '[]'),
    'volume_by_state', coalesce((select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object('id', st.id, 'name', st.name, 'kg', coalesce(sum(v.kg), 0), 'lots', coalesce(sum(v.lots), 0),
               'qr', coalesce((select sum(q.n) from qr q join public.scopes s2 on s2.id = q.scope_id where s2.state_id = st.id), 0)) as x
          from public.states st left join public.scopes s on s.state_id = st.id left join vol v on v.scope_id = s.id
         group by st.id, st.name) y), '[]'),
    'volume_by_crop', coalesce((select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object('id', cr.id, 'name', cr.name, 'unit', cr.primary_unit, 'kg', coalesce(sum(v.kg), 0), 'lots', coalesce(sum(v.lots), 0),
               'qr', coalesce((select sum(q.n) from qr q join public.scopes s2 on s2.id = q.scope_id where s2.crop_id = cr.id), 0)) as x
          from public.crops cr left join public.scopes s on s.crop_id = cr.id left join vol v on v.scope_id = s.id
         group by cr.id, cr.name, cr.primary_unit) y), '[]'),
    -- people, as numbers only: no HR file is read here (Veda, 10 Oct: "counts and charts, not personal HR records")
    -- A (migration 38): openings per state, numbers only
    'openings', (select jsonb_build_object('states', x->'states', 'total', x->'total', 'not_linked', x->'not_linked') from (select app.openings_summary() as x) y),
    'people', jsonb_build_object(
       'by_role', coalesce((select jsonb_object_agg(z.r, z.n) from (select system_role::text as r, count(*) as n from public.app_users
                              where not external and status <> 'offboarded' group by 1) z), '{}'),
       'by_status', coalesce((select jsonb_object_agg(z.s, z.n) from (select status::text as s, count(*) as n from public.app_users
                              where not external group by 1) z), '{}'),
       'client_logins', (select count(*) from public.app_users where external and status = 'active'),
       'state_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and u.status = 'active'),
       'client_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'),
       'stage_people', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                         where a.active and a.lens = 'scope' and u.status = 'active'),
       'unassigned', (select count(*) from public.app_users u where not u.external and u.status = 'active' and u.system_role = 'operational'
                       and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active)),
       'joining', (select count(*) from public.app_users where not external and status in ('invited', 'onboarding')),
       'checklist_pct', (select round(100.0 * count(*) filter (where t.status <> 'pending') / nullif(count(*), 0))
                           from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id
                          where u.status in ('invited', 'onboarding')),
       'left_90d', (select count(distinct e.employee_id) from public.employee_exits e where e.exit_date >= app.today() - 90)),
    'setup', jsonb_build_object(
       'states', (select count(*) from public.states),
       'hr_admin', app.hr_seat_filled(),
       'state_managers', (select count(distinct a.employee_id) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and u.status = 'active'))
  ) into r;
  return r;
end $function$;

-- F3 · bootstrap_seats
CREATE OR REPLACE FUNCTION app.bootstrap_seats()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform app.me_or_raise();
  if not app.is_admin() then raise exception 'only the admin opens the seats' using errcode = '42501'; end if;
  return jsonb_build_object(
    'admins', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status,
                          'has_login', u.auth_uid is not null and u.auth_uid <> u.id) order by u.created_at)
                          from public.app_users u where u.system_role = 'admin' and u.status <> 'offboarded'), '[]'::jsonb),
    'hr_admin', (select jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status,
                          'has_login', u.auth_uid is not null and u.auth_uid <> u.id)
                   from public.app_users u where u.system_role = 'hr_admin' and u.status <> 'offboarded'),
    'hr_resources', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'email', u.email, 'status', u.status) order by u.display_name)
                                from public.app_users u where u.system_role = 'hr_resource' and u.status <> 'offboarded'), '[]'::jsonb),
    'candidates', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'system_role', u.system_role) order by u.display_name)
                              from public.app_users u where not u.external and u.system_role in ('operational', 'hr_resource')
                                and u.status in ('invited', 'onboarding', 'active')), '[]'::jsonb),
    'sm_deputy', app.sm_deputy(),
    'daily_code', jsonb_build_object('on', app.daily_code_on(),
      'without_email', (select count(*) from public.app_users u where u.active and app.email_key(u.email) is null)));
end $function$;


-- ── D · a checklist per role: State Manager, Client Manager, Operator, HR, each a copy of the default to start with ──
-- (HR changes them under HR → Templates; a person's checklist is the template of their role, else the default)
do $$
declare d uuid; nt uuid; r text; nm text;
begin
  select id into d from public.onboarding_templates where is_default and active limit 1;
  if d is null then return; end if;
  foreach r in array array['state_manager', 'client_manager', 'operator', 'hr'] loop
    if not exists (select 1 from public.onboarding_templates where role = r) then
      nm := 'Standard · ' || case r when 'state_manager' then 'State Manager' when 'client_manager' then 'Client Manager'
                                    when 'operator' then 'Operator' else 'HR' end;
      insert into public.onboarding_templates (name, is_default, active, role, first_day_time, first_day_place, first_day_ask_for, first_day_bring)
      select nm, false, true, r, first_day_time, first_day_place, first_day_ask_for, first_day_bring from public.onboarding_templates where id = d
      returning id into nt;
      insert into public.template_tasks (template_id, seq, code, title, owner, due_offset_days, statutory, kind, depends_on)
      select nt, seq, code, title, owner, due_offset_days, statutory, kind, depends_on from public.template_tasks where template_id = d;
    end if;
  end loop;
end $$;

-- ── H7 · decision 6: once, open steps of people still joining move to the later of their due date and today + 3 ────
do $$
declare r record;
begin
  for r in select u.id, u.display_name, count(*) as k
             from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id
            where t.status = 'pending' and u.status in ('invited', 'onboarding') and t.due_on < app.today() + 3
            group by u.id, u.display_name loop
    update public.onboarding_tasks set due_on = app.today() + 3
     where employee_id = r.id and status = 'pending' and due_on < app.today() + 3;
    insert into public.audit_log (actor, action, target, detail)
    values (null, 'due_dates_recalculated', r.id, jsonb_build_object('name', r.display_name, 'steps', r.k, 'to', app.today() + 3, 'by', 'migration 38'));
  end loop;
end $$;

-- ── E5 · the daily reminder round (09:00 India time), where pg_cron is there (the hosted projects) ─────────────────
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.unschedule(jobid) from cron.job where jobname = 'grainveda-reminders';
    perform cron.schedule('grainveda-reminders', '30 3 * * *', 'select app.queue_reminders()');
  end if;
exception when others then
  raise notice 'reminders not scheduled (pg_cron): %', sqlerrm;
end $$;

-- ── who may call what ─────────────────────────────────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  -- for people (HR, managers, the admin): each function checks who is asking
  foreach f in array array[
    'app.save_opening(jsonb)', 'app.set_opening_status(uuid, text)', 'app.openings_summary(uuid)', 'app.opening_targets(uuid)', 'app.link_to_opening(uuid[], uuid)',
    'app.set_intended_role(uuid, text, public.stage_type)', 'app.import_joiners(jsonb, boolean, text)', 'app.invite_targets(uuid[])',
    'app.may_send_messages()', 'app.reminder_state()', 'app.joiners_page(jsonb)', 'app.people_page(jsonb)', 'app.audit_page(jsonb)',
    'app.activate_joiner(uuid, text)', 'app.activation_state(uuid)', 'app.record_on_paper(uuid, text)',
    'app.complete_task_many(uuid[], text, jsonb)', 'app.update_joiner_many(uuid[], jsonb)', 'app.set_hr_owner(uuid[], uuid)',
    'app.activate_many(uuid[], text)', 'app.set_sm_deputy(uuid)', 'app.sm_deputy()',
    'app.assign_many(uuid[], public.assignment_lens, uuid, public.op_role, public.stage_type[], text)',
    'app.ready_to_assign(public.assignment_lens, uuid)', 'app.is_sm_deputy()'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  -- helpers read inside other functions only
  foreach f in array array['app.fills_opening(uuid, public.openings)', 'app.opening_ready(public.openings)',
    'app.opening_numbers(public.openings)', 'app.opening_json(public.openings)', 'app.employee_org_guard()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  -- SERVICE KEY ONLY: the invite server function and the reminder round
  foreach f in array array['app.record_invite(uuid, uuid, text, text, integer)', 'app.mark_invite_sent(uuid, boolean)',
    'app.invite_lookup(text)', 'app.use_invite(uuid)', 'app.queue_reminders()', 'app.messages_to_send(integer)',
    'app.mark_message(bigint, boolean, text)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
