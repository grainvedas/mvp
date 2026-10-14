-- =====================================================================================================================
-- Migration 46: the HR requirements list and staffing a scope (Veda, 14 Oct 2026, "GrainVeda MVP — HR requirements list
-- and staffing a scope"; it replaces section B of the follow-up brief).
--   A · requirements: a need for people raised once, by whoever owns it, with lines (role, stage, number, place,
--       needed-by, note) and their statuses; lines raised by themselves from a scope's empty stages and for a client
--       with no Client Manager; lines by hand from the Client Manager (his scope) and the State Manager (his state).
--   B · HR's queue: publish (one opening per scope, a line per stage, nothing retyped), return with a question, decline,
--       hold; corrections before publishing are logged; every status change is a line in the Audit log.
--   C · what the requester sees: each empty stage's line and status; "Ready to assign" people first in the pool.
--   D · openings say where they came from ("From requirement by …" / "Created by HR"); a manual opening may hold several
--       stages of a scope as one group. The openings made by hand before (UP-OPR-002 … 007) are left as they are:
--       "Created by HR".
--   E · one person may hold several stages of a scope, also two in a row (Veda's decision): a record may then be
--       verified by its own maker; the ledger marks it "same person, next stage", the public page says so in the
--       approved words, and the overview counts it per scope.
-- Additive only: new tables, columns, functions and triggers; nothing deleted or rewritten. Changes of migration 46 to
-- rows are declared to the change log ("migration 46").
-- =====================================================================================================================
select set_config('app.change_path', 'migration 46', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- 1 · requirements and their lines
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.requirements (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('scope', 'client', 'state')),
  state_id    uuid not null references public.states(id),
  client_id   uuid references public.clients(id),
  scope_id    uuid references public.scopes(id),
  raised_by   uuid references public.app_users(id),        -- null: raised by the system with nobody to name yet
  raised_at   timestamptz not null default now(),
  note        text
);
create unique index if not exists requirements_one_per_scope on public.requirements (scope_id) where kind = 'scope';
create unique index if not exists requirements_one_per_client on public.requirements (client_id) where kind = 'client';

create table if not exists public.requirement_lines (
  id             uuid primary key default gen_random_uuid(),
  requirement_id uuid not null references public.requirements(id),
  role           text not null check (role in ('client_manager', 'operator', 'export_manager', 'other')),
  stage          public.stage_type,
  positions      int not null check (positions between 1 and 500),
  posting        text,
  needed_by      date not null,
  note           text,
  auto           boolean not null default false,            -- raised by itself (an empty stage, a client with no manager)
  status         text not null default 'requested'
                 check (status in ('requested', 'returned', 'held', 'published', 'filled', 'withdrawn', 'declined')),
  status_reason  text,                                      -- HR's question, the reason to decline or hold, how it closed
  status_by      uuid references public.app_users(id),
  status_at      timestamptz not null default now(),
  opening_id     uuid references public.openings(id),
  created_by     uuid references public.app_users(id),
  created_at     timestamptz not null default now(),
  check (role <> 'operator' or stage is not null)
);
create index if not exists requirement_lines_req_idx on public.requirement_lines (requirement_id);
create index if not exists requirement_lines_open_idx on public.requirement_lines (status) where status in ('requested', 'returned', 'held', 'published');
alter table public.requirements enable row level security;
alter table public.requirement_lines enable row level security;
revoke all on public.requirements, public.requirement_lines from anon, authenticated;   -- read and written through the functions below

-- openings say where they came from, and a scope's opening groups its lines (D)
alter table public.openings add column if not exists source text not null default 'hr' check (source in ('hr', 'requirement'));
alter table public.openings add column if not exists requirement_line_id uuid references public.requirement_lines(id);
alter table public.openings add column if not exists requested_by uuid references public.app_users(id);
alter table public.openings add column if not exists group_id uuid;
alter table public.openings add column if not exists group_title text;

-- the change log covers the two new tables too (migration 45)
create trigger zz_change_log after insert or update or delete on public.requirements for each row execute function app.log_change('id');
create trigger zz_change_log after insert or update or delete on public.requirement_lines for each row execute function app.log_change('id');

-- ---------------------------------------------------------------------------------------------------------------------
-- 2 · who may do what with a requirement
-- ---------------------------------------------------------------------------------------------------------------------
-- HR of the line's state (her states; the HR Admin all)
create or replace function app.hr_of_state(p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(app.acts_as_hr(), false) and (app.hr_full() or p_state = any(app.my_hr_states())) $$;

-- the requester's side: the scope's Client Manager; the State Manager of the state; whoever raised it
create or replace function app.owns_requirement(r public.requirements) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and (
         r.raised_by = app.current_user_id()
      or (r.kind = 'scope' and app.runs_client(r.client_id))
      or (r.kind in ('client', 'state') and app.watches_state(r.state_id))) $$;

-- a status change, logged
create or replace function app.line_status(p_line uuid, p_status text, p_reason text, p_action text) returns public.requirement_lines
language plpgsql security definer set search_path = public as $$
declare l public.requirement_lines;
begin
  update public.requirement_lines set status = p_status, status_reason = p_reason, status_by = app.current_user_id(), status_at = now()
   where id = p_line returning * into l;
  perform app.audit(p_action, l.id, jsonb_build_object('role', l.role, 'stage', l.stage, 'positions', l.positions, 'status', p_status, 'reason', p_reason,
    'requirement', l.requirement_id), p_status in ('declined', 'held', 'returned', 'withdrawn'));
  return l;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3 · lines that raise themselves (A2)
-- ---------------------------------------------------------------------------------------------------------------------
-- a scope: one line per stage with nobody, raised when its Client Manager saves the People step (p_create), or by
-- itself once the scope is active; after that the lines follow the scope: a line closes by itself when its stage gets
-- a person ("filled from the pool"), or leaves the chain; a stage added to the chain, or left empty again, gets a line.
-- A stage whose line HR declined, or the requester withdrew, is not raised again by itself.
create or replace function app.sync_scope_requirement(p_scope uuid, p_create boolean default false) returns void
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; r public.requirements; gaps public.stage_type[]; l record; st public.stage_type; who uuid;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null then return; end if;
  select * into r from public.requirements where kind = 'scope' and scope_id = sc.id;
  if sc.status not in ('draft', 'active') then                -- a closed scope needs nobody: its open lines are withdrawn
    for l in select * from public.requirement_lines where requirement_id = r.id and status in ('requested', 'returned', 'held') loop
      perform app.line_status(l.id, 'withdrawn', 'the scope is closed', 'requirement_line_closed');
    end loop;
    return;
  end if;
  gaps := app.coverage_gaps(sc.id, null);
  if r.id is null then
    if cardinality(gaps) = 0 or not (p_create or sc.status = 'active') then return; end if;
    who := case when app.current_user_id() is not null and app.runs_client(sc.client_id) then app.current_user_id()
                else (select a.employee_id from public.assignments a where a.lens = 'client' and a.op_role = 'client_account'
                        and a.client_id = sc.client_id and a.active order by a.created_at limit 1) end;
    insert into public.requirements (kind, state_id, client_id, scope_id, raised_by) values ('scope', sc.state_id, sc.client_id, sc.id, who)
    returning * into r;
  end if;
  for l in select * from public.requirement_lines where requirement_id = r.id and auto and stage is not null
             and status in ('requested', 'returned', 'held', 'published') loop
    if not (l.stage = any(sc.chain)) then
      perform app.line_status(l.id, 'withdrawn', 'the chain no longer has this stage', 'requirement_line_closed');
    elsif not (l.stage = any(gaps)) then
      perform app.line_status(l.id, 'filled', 'filled from the pool', 'requirement_line_filled');
    end if;
  end loop;
  foreach st in array gaps loop
    if not exists (select 1 from public.requirement_lines x where x.requirement_id = r.id and x.auto and x.stage = st
                     and x.status in ('requested', 'returned', 'held', 'published', 'declined', 'withdrawn')
                     and not (x.status = 'withdrawn' and x.status_reason = 'the chain no longer has this stage')) then
      insert into public.requirement_lines (requirement_id, role, stage, positions, needed_by, auto, created_by)
      values (r.id, 'operator', st, 1, current_date + 14, true, r.raised_by);
      perform app.audit('requirement_line_raised', r.id, jsonb_build_object('stage', st, 'scope', sc.id, 'auto', true), false);
    end if;
  end loop;
end $$;

-- a client with no Client Manager: a line in the name of the State Manager of its state; closed when it has one
create or replace function app.sync_client_requirement(p_client uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c public.clients; r public.requirements; has_cm boolean; l record; sm uuid;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null or c.state_id is null then return; end if;
  has_cm := exists (select 1 from public.assignments a join public.app_users u on u.id = a.employee_id
                     where a.lens = 'client' and a.op_role = 'client_account' and a.client_id = c.id and a.active
                       and u.status in ('invited', 'onboarding', 'active'));
  select * into r from public.requirements where kind = 'client' and client_id = c.id;
  if has_cm then
    for l in select * from public.requirement_lines where requirement_id = r.id and auto and status in ('requested', 'returned', 'held', 'published') loop
      perform app.line_status(l.id, 'filled', 'a Client Manager was given', 'requirement_line_filled');
    end loop;
    return;
  end if;
  sm := (select a.employee_id from public.assignments a where a.lens = 'state' and a.state_id = c.state_id and a.active
          order by a.created_at limit 1);
  if r.id is null then
    insert into public.requirements (kind, state_id, client_id, raised_by) values ('client', c.state_id, c.id, sm) returning * into r;
  end if;
  if not exists (select 1 from public.requirement_lines x where x.requirement_id = r.id and x.auto
                   and x.status in ('requested', 'returned', 'held', 'published', 'declined', 'withdrawn')) then
    insert into public.requirement_lines (requirement_id, role, positions, needed_by, auto, created_by, note)
    values (r.id, 'client_manager', 1, current_date + 14, true, sm, 'Client Manager for ' || c.name);
    perform app.audit('requirement_line_raised', r.id, jsonb_build_object('client', c.name, 'role', 'client_manager', 'auto', true), false);
  end if;
end $$;

-- the lines follow what people do in the app; a seed or the service (no one signed in) does not raise them
create or replace function app.requirements_on_scope() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;          -- a seed or the service: the migration's sync covers what is there
  if tg_op = 'INSERT' or new.chain is distinct from old.chain or new.status is distinct from old.status then
    perform app.sync_scope_requirement(new.id);
  end if;
  return null;
end $$;
create trigger zy_requirements after insert or update on public.scopes for each row execute function app.requirements_on_scope();

create or replace function app.requirements_on_slot() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;          -- a seed or the service: the migration's sync covers what is there
  perform app.sync_scope_requirement(coalesce(new.scope_id, old.scope_id));
  return null;
end $$;
create trigger zy_requirements after insert or update or delete on public.slot_assignments for each row execute function app.requirements_on_slot();

create or replace function app.requirements_on_assignment() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;          -- a seed or the service: the migration's sync covers what is there
  if new.lens = 'scope' and new.scope_id is not null and (tg_op = 'INSERT' or new.active is distinct from old.active) then
    perform app.sync_scope_requirement(new.scope_id);
  elsif new.lens = 'client' and new.op_role = 'client_account' and (tg_op = 'INSERT' or new.active is distinct from old.active) then
    perform app.sync_client_requirement(new.client_id);
  end if;
  return null;
end $$;
create trigger zy_requirements after insert or update on public.assignments for each row execute function app.requirements_on_assignment();

create or replace function app.requirements_on_client() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;          -- a seed or the service: the migration's sync covers what is there
  perform app.sync_client_requirement(new.id);
  return null;
end $$;
create trigger zy_requirements after insert on public.clients for each row execute function app.requirements_on_client();

-- ---------------------------------------------------------------------------------------------------------------------
-- 4 · a line as people see it (C): the stored status, and while published, who is joining or ready against its opening
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.line_json(l public.requirement_lines) returns jsonb
language sql stable security definer set search_path = public as $$
  with o as (select * from public.openings where id = l.opening_id),
       p as (select u.id, u.display_name, u.status, u.join_date, coalesce(e.first_day_date, u.join_date) as joins_on
               from public.employee_org e join public.app_users u on u.id = e.employee_id
              where e.opening_id = l.opening_id and u.status in ('invited', 'onboarding', 'active')),
       ready as (select p.* from p, o where p.status = 'active' and not app.fills_opening(p.id, o)),
       joining as (select p.* from p where p.status in ('invited', 'onboarding'))
  select jsonb_build_object(
    'id', l.id, 'requirement_id', l.requirement_id, 'role', l.role, 'stage', l.stage, 'positions', l.positions, 'posting', l.posting,
    'needed_by', l.needed_by, 'note', l.note, 'auto', l.auto, 'status', l.status, 'reason', l.status_reason, 'status_at', l.status_at,
    'status_by', (select display_name from public.app_users where id = l.status_by),
    'opening', (select jsonb_build_object('id', o.id, 'code', o.code, 'group_title', o.group_title) from o),
    'shown', case when l.status <> 'published' then l.status
                  when exists (select 1 from ready) then 'ready'
                  when exists (select 1 from joining) then 'joining' else 'published' end,
    'ready', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', display_name) order by display_name) from ready), '[]'::jsonb),
    'joining', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'joins_on', joins_on) order by joins_on nulls last) from joining), '[]'::jsonb),
    'created_at', l.created_at,
    'overdue', l.status in ('requested', 'returned', 'held') and l.needed_by < current_date) $$;

create or replace function app.requirement_json(r public.requirements) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'kind', r.kind, 'state_id', r.state_id, 'state_name', (select name from public.states where id = r.state_id),
    'client_id', r.client_id, 'client_name', (select name from public.clients where id = r.client_id),
    'scope_id', r.scope_id,
    'scope_name', (select cr.name || ' · ' || s.season_code || ' · ' || s.geography from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = r.scope_id),
    'raised_by', (select display_name from public.app_users where id = r.raised_by), 'raised_at', r.raised_at,
    'mine', app.owns_requirement(r)) $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5 · the requester (A3, C)
-- ---------------------------------------------------------------------------------------------------------------------
-- p: {scope_id} (the Client Manager) or {state_id, client_id?} (the State Manager); lines: [{role, stage, positions,
-- posting, needed_by, note}]
create or replace function app.request_people(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); sc public.scopes; r public.requirements; x jsonb; v_role text; v_stage public.stage_type; v_pos int;
        v_need date; n int := 0; v_state uuid; v_client uuid;
begin
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'say how many people, for which role' using errcode = '23514'; end if;
  if nullif(p->>'scope_id', '') is not null then
    select * into sc from public.scopes where id = (p->>'scope_id')::uuid;
    if sc.id is null or not app.runs_client(sc.client_id) then
      raise exception 'the Client Manager of this scope''s client asks for its people' using errcode = '42501'; end if;
    if sc.status not in ('draft', 'active') then raise exception 'this scope is closed' using errcode = '23514'; end if;
    select * into r from public.requirements where kind = 'scope' and scope_id = sc.id;
    if r.id is null then
      insert into public.requirements (kind, state_id, client_id, scope_id, raised_by) values ('scope', sc.state_id, sc.client_id, sc.id, me) returning * into r;
    end if;
  else
    v_state := nullif(p->>'state_id', '')::uuid; v_client := nullif(p->>'client_id', '')::uuid;
    if v_state is null or not app.watches_state(v_state) then
      raise exception 'the State Manager of the state asks for its people' using errcode = '42501'; end if;
    if v_client is not null and not exists (select 1 from public.clients where id = v_client and state_id = v_state) then
      raise exception 'that client is not in this state' using errcode = '23514'; end if;
    insert into public.requirements (kind, state_id, client_id, raised_by, note) values ('state', v_state, v_client, me, nullif(left(btrim(p->>'note'), 300), ''))
    returning * into r;
  end if;
  for x in select * from jsonb_array_elements(p->'lines') loop
    v_role := x->>'role';
    v_stage := nullif(x->>'stage', '')::public.stage_type;
    begin v_pos := (x->>'positions')::int; exception when others then v_pos := null; end;
    begin v_need := coalesce(nullif(x->>'needed_by', '')::date, current_date + 14); exception when others then v_need := null; end;
    if v_pos is null or v_pos < 1 or v_pos > 500 then raise exception 'how many people: a number from 1 to 500' using errcode = '23514'; end if;
    if v_need is null or v_need < current_date then raise exception 'needed by: today or later' using errcode = '23514'; end if;
    if r.kind = 'scope' then
      if v_role not in ('operator', 'export_manager') then raise exception 'for a scope: operators or an export manager' using errcode = '23514'; end if;
      if v_role = 'operator' and (v_stage is null or not (v_stage = any(sc.chain))) then
        raise exception 'choose a stage of this scope''s chain' using errcode = '23514'; end if;
    else
      if v_role not in ('client_manager', 'operator', 'export_manager', 'other') then raise exception 'choose a role' using errcode = '23514'; end if;
      if v_role = 'operator' and v_stage is null then raise exception 'an operator needs the stage they will work at' using errcode = '23514'; end if;
    end if;
    if v_role <> 'operator' then v_stage := null; end if;
    insert into public.requirement_lines (requirement_id, role, stage, positions, posting, needed_by, note, created_by)
    values (r.id, v_role, v_stage, v_pos, nullif(left(btrim(x->>'posting'), 120), ''), v_need, nullif(left(btrim(x->>'note'), 300), ''), me);
    n := n + 1;
  end loop;
  perform app.audit('requirement_raised', r.id, jsonb_build_object('lines', n, 'kind', r.kind, 'scope', r.scope_id, 'state', r.state_id), false);
  return app.requirement_json(r) || jsonb_build_object('lines', n);
end $$;

-- the requester withdraws a line, or answers HR's question (the line then waits for HR again)
create or replace function app.requester_act(p_line uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.requirement_lines; r public.requirements; v_pos int; v_need date;
begin
  perform app.me_or_raise();
  select * into l from public.requirement_lines where id = p_line for update;
  if l.id is null then raise exception 'line not found' using errcode = 'P0002'; end if;
  select * into r from public.requirements where id = l.requirement_id;
  if not app.owns_requirement(r) then raise exception 'the person who asked (or the scope''s Client Manager, the state''s State Manager) acts on it' using errcode = '42501'; end if;
  if p_action = 'withdraw' then
    if l.status not in ('requested', 'returned', 'held') then raise exception 'this line is % already: it cannot be withdrawn', l.status using errcode = '23514'; end if;
    l := app.line_status(l.id, 'withdrawn', nullif(left(btrim(coalesce(p->>'reason', '')), 300), ''), 'requirement_line_withdrawn');
  elsif p_action = 'answer' then
    if l.status <> 'returned' then raise exception 'only a line HR returned is answered' using errcode = '23514'; end if;
    if length(btrim(coalesce(p->>'answer', ''))) < 2 then raise exception 'write your answer' using errcode = '23514'; end if;
    begin v_pos := coalesce(nullif(p->>'positions', '')::int, l.positions); exception when others then v_pos := null; end;
    begin v_need := coalesce(nullif(p->>'needed_by', '')::date, l.needed_by); exception when others then v_need := null; end;
    if v_pos is null or v_pos < 1 or v_pos > 500 then raise exception 'how many people: a number from 1 to 500' using errcode = '23514'; end if;
    if v_need is null then raise exception 'needed by: a date' using errcode = '23514'; end if;
    update public.requirement_lines set positions = v_pos, needed_by = v_need,
           posting = case when p ? 'posting' then nullif(left(btrim(p->>'posting'), 120), '') else posting end,
           note = coalesce(nullif(left(btrim(p->>'note'), 300), ''), note)
     where id = l.id;
    l := app.line_status(l.id, 'requested', 'answer: ' || left(btrim(p->>'answer'), 300), 'requirement_line_answered');
  else
    raise exception 'withdraw or answer' using errcode = '22023';
  end if;
  return app.line_json(l);
end $$;

-- a scope's requirement as its Client Manager (and the State Manager, HR, the admin) sees it on the People step
create or replace function app.scope_requirement(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.requirements; sc public.scopes;
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not (app.runs_client(sc.client_id) or app.watches_state(sc.state_id) or app.is_admin() or app.hr_of_state(sc.state_id)) then
    raise exception 'not your scope' using errcode = '42501'; end if;
  select * into r from public.requirements where kind = 'scope' and scope_id = p_scope;
  if r.id is null then return jsonb_build_object('requirement', null, 'lines', '[]'::jsonb, 'can_request', app.runs_client(sc.client_id)); end if;
  return jsonb_build_object('requirement', app.requirement_json(r),
    'lines', coalesce((select jsonb_agg(app.line_json(l) order by array_position(sc.chain, l.stage), l.created_at) from public.requirement_lines l where l.requirement_id = r.id), '[]'::jsonb),
    'can_request', app.runs_client(sc.client_id));
end $$;

-- the State Manager's state: its open requirements by client (C4), and its clients with no Client Manager
create or replace function app.state_requirements(p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform app.me_or_raise();
  if not (app.watches_state(p_state) or app.is_admin() or app.hr_of_state(p_state)) then
    raise exception 'not your state' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(app.requirement_json(r) || jsonb_build_object('lines',
             (select jsonb_agg(app.line_json(l) order by l.created_at) from public.requirement_lines l
               where l.requirement_id = r.id and l.status in ('requested', 'returned', 'held', 'published')))
           order by (select name from public.clients where id = r.client_id) nulls first, r.raised_at)
      from public.requirements r
     where r.state_id = p_state
       and exists (select 1 from public.requirement_lines l where l.requirement_id = r.id and l.status in ('requested', 'returned', 'held', 'published'))), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6 · HR's queue (B)
-- ---------------------------------------------------------------------------------------------------------------------
-- p: {state_id, client_id, scope_id, role, status, overdue}; status '' = the open ones (requested, returned, held)
create or replace function app.hr_requirements(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_status text := nullif(p->>'status', ''); rows jsonb;
begin
  perform app.me_or_raise();
  if not (app.acts_as_hr() or app.is_admin()) then raise exception 'the requirements list is HR''s' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.j order by x.state_name, x.client_name nulls first, x.scope_name nulls first, x.raised_at), '[]'::jsonb) into rows
    from (select app.requirement_json(r) || jsonb_build_object('lines', ls.lines) as j,
                 (select name from public.states where id = r.state_id) as state_name,
                 (select name from public.clients where id = r.client_id) as client_name,
                 (select s.geography from public.scopes s where s.id = r.scope_id) as scope_name, r.raised_at
            from public.requirements r
            cross join lateral (
              select jsonb_agg(app.line_json(l) order by l.created_at) as lines
                from public.requirement_lines l
               where l.requirement_id = r.id
                 and (case when v_status is null then l.status in ('requested', 'returned', 'held')
                           when v_status = 'all' then true else l.status = v_status end)
                 and (nullif(p->>'role', '') is null or l.role = p->>'role')
                 and (not coalesce((p->>'overdue')::boolean, false) or (l.status in ('requested', 'returned', 'held') and l.needed_by < current_date))) ls
           where ls.lines is not null
             and (app.is_admin() or app.hr_of_state(r.state_id))
             and (nullif(p->>'state_id', '') is null or r.state_id = (p->>'state_id')::uuid)
             and (nullif(p->>'client_id', '') is null or r.client_id = (p->>'client_id')::uuid)
             and (nullif(p->>'scope_id', '') is null or r.scope_id = (p->>'scope_id')::uuid)) x;
  return jsonb_build_object('groups', rows, 'can_act', app.acts_as_hr(), 'counts', app.hr_requirement_counts());
end $$;

-- the figure on HR's dashboard and the menu's badge: new lines waiting for HR, and the oldest's age in days
create or replace function app.hr_requirement_counts() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('new', count(*), 'lines', coalesce(sum(l.positions), 0),
           'oldest_days', coalesce(max(current_date - l.created_at::date), 0),
           'overdue', count(*) filter (where l.needed_by < current_date))
    from public.requirement_lines l join public.requirements r on r.id = l.requirement_id
   where l.status = 'requested' and (app.is_admin() or app.hr_of_state(r.state_id)) $$;

-- HR acts on one or more lines: publish (with corrections), return (a question), decline, hold (a reason)
-- p_changes: {"<line id>": {"positions": n, "needed_by": "…", "note": "…"}}
create or replace function app.decide_lines(p_lines uuid[], p_action text, p_reason text default null, p_changes jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); l public.requirement_lines; r public.requirements; sc public.scopes; ch jsonb; v_pos int; v_need date;
        o public.openings; v_code text; abbr text; n int; groups jsonb := '{}'::jsonb; g uuid; v_title text; done int := 0; out jsonb := '[]'::jsonb;
begin
  if not app.acts_as_hr() then raise exception 'only HR decides requirements' using errcode = '42501'; end if;
  if p_action not in ('publish', 'return', 'decline', 'hold') then raise exception 'publish, return, decline or hold' using errcode = '22023'; end if;
  if p_action <> 'publish' and length(btrim(coalesce(p_reason, ''))) < 3 then
    raise exception '%', case p_action when 'return' then 'write the question for the requester' else 'say why' end using errcode = '23514'; end if;
  if coalesce(cardinality(p_lines), 0) = 0 then raise exception 'choose the lines' using errcode = '23514'; end if;
  for l in select * from public.requirement_lines where id = any(p_lines) order by created_at for update loop
    select * into r from public.requirements where id = l.requirement_id;
    if not app.hr_of_state(r.state_id) then raise exception 'a line of a state that is not yours: ask the HR Admin' using errcode = '42501'; end if;
    if l.status not in ('requested', 'held') then raise exception 'a % line cannot be %', l.status,
        case p_action when 'publish' then 'published' when 'return' then 'returned' when 'decline' then 'declined' else 'held' end using errcode = '23514'; end if;
    if p_action = 'publish' then
      ch := coalesce(p_changes->(l.id::text), '{}'::jsonb);
      begin v_pos := coalesce(nullif(ch->>'positions', '')::int, l.positions); exception when others then v_pos := null; end;
      begin v_need := coalesce(nullif(ch->>'needed_by', '')::date, l.needed_by); exception when others then v_need := null; end;
      if v_pos is null or v_pos < 1 or v_pos > 500 then raise exception 'how many people: a number from 1 to 500' using errcode = '23514'; end if;
      if v_need is null then raise exception 'needed by: a date' using errcode = '23514'; end if;
      if v_pos <> l.positions or v_need <> l.needed_by or (ch ? 'note' and nullif(btrim(ch->>'note'), '') is distinct from l.note) then
        update public.requirement_lines set positions = v_pos, needed_by = v_need,
               note = case when ch ? 'note' then nullif(left(btrim(ch->>'note'), 300), '') else note end where id = l.id;
        perform app.audit('requirement_line_corrected', l.id, jsonb_build_object('positions', jsonb_build_array(l.positions, v_pos),
          'needed_by', jsonb_build_array(l.needed_by, v_need), 'note', ch->>'note'), false);
      end if;
      -- one opening per scope: the lines of one requirement published together share a group (its title: the scope)
      g := (groups->>(r.id::text))::uuid;
      if g is null then
        g := coalesce((select group_id from public.openings where requirement_line_id in (select id from public.requirement_lines where requirement_id = r.id) and group_id is not null limit 1),
                      gen_random_uuid());
        groups := groups || jsonb_build_object(r.id::text, g);
      end if;
      select * into sc from public.scopes where id = r.scope_id;
      v_title := case when sc.id is not null then (select cr.name from public.crops cr where cr.id = sc.crop_id) || ' · ' || sc.season_code || ' · ' || sc.geography
                      when r.client_id is not null then (select name from public.clients where id = r.client_id) else null end;
      abbr := case l.role when 'client_manager' then 'CM' when 'operator' then 'OPR' when 'export_manager' then 'EXM' else 'OTH' end;
      select count(*) into n from public.openings where state_id = r.state_id and role = l.role;
      loop
        n := n + 1;
        v_code := (select upper(code) from public.states where id = r.state_id) || '-' || abbr || '-' || lpad(n::text, 3, '0');
        exit when not exists (select 1 from public.openings where code = v_code);
      end loop;
      insert into public.openings (code, state_id, role, stage, client_id, scope_id, positions, target_join, status, title, note, created_by,
                                   source, requirement_line_id, requested_by, group_id, group_title)
      values (v_code, r.state_id, l.role, l.stage, r.client_id, r.scope_id, v_pos, v_need, 'open', v_title,
              (select note from public.requirement_lines where id = l.id), me, 'requirement', l.id, coalesce(l.created_by, r.raised_by), g, v_title)
      returning * into o;
      update public.requirement_lines set opening_id = o.id where id = l.id;
      perform app.audit('opening_created', null, jsonb_build_object('opening', o.code, 'role', o.role, 'stage', o.stage, 'positions', o.positions,
        'from_requirement', l.id, 'requested_by', (select display_name from public.app_users where id = o.requested_by)));
      l := app.line_status(l.id, 'published', null, 'requirement_line_published');
    elsif p_action = 'return' then
      l := app.line_status(l.id, 'returned', left(btrim(p_reason), 500), 'requirement_line_returned');
    elsif p_action = 'decline' then
      l := app.line_status(l.id, 'declined', left(btrim(p_reason), 500), 'requirement_line_declined');
    else
      l := app.line_status(l.id, 'held', left(btrim(p_reason), 500), 'requirement_line_held');
    end if;
    done := done + 1;
    out := out || app.line_json(l);
  end loop;
  if done <> cardinality(p_lines) then raise exception 'a line was not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('done', done, 'lines', out);
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- E · one person on two stages in a row (Veda's decision, 14 Oct 2026): the server allows it; it is shown, not refused
-- ---------------------------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.footprints_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        -- migration 46 (Veda, 14 Oct): one person may hold two stages in a row and then verifies his own record; the
        -- ledger marks it "same person, next stage", the public page says so, the overview counts it
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end$function$;

CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false;
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      step := step || jsonb_build_object('farmer', jsonb_build_object('name', fm.name, 'village', fm.village, 'district', fm.district,
                                            'photo', case when fm.photo_consent then fm.extra->>'photo_path' else null end));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', cur.payload->>'village', 'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('name', fa.name, 'village', fa.village, 'district', fa.district, 'qty_kg', src.qty_out)
                         order by fa.name)
          from public.footprints src join public.farmers fa on fa.id = src.farmer_id
         where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then
      step := step || jsonb_build_object('destination', cur.payload->>'destination', 'dispatched_on', cur.payload->>'dispatch_date'); end if;
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    -- migration 46: the same person recorded a step and checked it, or recorded the next one (the approved words)
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by and not cur.is_grade_lot) then
      v_same := true;
    end if;
    v_later_maker := cur.created_by;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    'same_person', v_same
  );
end $function$;

CREATE OR REPLACE FUNCTION app.ledger_page(p_event text DEFAULT NULL::text, p_client uuid DEFAULT NULL::uuid, p_scope uuid DEFAULT NULL::uuid, p_actor uuid DEFAULT NULL::uuid, p_manager_acts boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); total bigint; rows jsonb;
begin
  if me is null or not app.is_admin() then raise exception 'the whole ledger is for the admin' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, f.created_by as fp_maker, f.is_grade_lot as fp_grade_lot,
           (select pf.created_by from public.footprints pf where pf.id = f.prev_footprint_id) as prev_maker, coalesce(f.client_id, s.client_id) as client_id, coalesce(l.scope_id, f.scope_id) as the_scope
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id)
     where (p_event is null or l.event::text = p_event)
       and (p_actor is null or l.actor = p_actor)
       and (not coalesce(p_manager_acts, false) or (l.event = 'supervisory' and l.footprint_id is not null))),
  m as (select * from b where (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role,
            'stage_role', case when m.stage_type is null then null when m.event in ('create', 'supervisory') then m.stage_type::text
                               when m.event = 'seal' or m.stage_type = 'qr_activation' then 'qr_activation'
                               when m.event = 'verify' then coalesce(app.chain_next(m.the_scope, m.stage_type)::text, m.stage_type::text) end,
            'same_person', coalesce((m.event = 'verify' and m.fp_maker = m.actor and m.stage_type <> 'qr_activation')
                           or (m.event = 'create' and m.prev_maker = m.actor and not coalesce(m.fp_grade_lot, false)), false))
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset);
end $function$;

CREATE OR REPLACE FUNCTION app.state_ledger_page(p_state uuid, p_event text, p_client uuid, p_scope uuid, p_actor uuid, p_limit integer, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); total bigint; rows jsonb; signers jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'the ledger of a state is for its State Manager' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, f.created_by as fp_maker, f.is_grade_lot as fp_grade_lot,
           (select pf.created_by from public.footprints pf where pf.id = f.prev_footprint_id) as prev_maker,
           coalesce(f.client_id, s.client_id, app.uuid_or_null(l.payload->>'client_id'), fa.client_id) as client_id,
           s.id as the_scope,
           coalesce(s.state_id, fa.state_id, (select c.state_id from public.clients c where c.id = app.uuid_or_null(l.payload->>'client_id')),
                    app.uuid_or_null(l.payload->>'state_id')) as state_id
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id, app.uuid_or_null(l.payload->>'scope_id'))
      left join public.farmers fa on fa.id = app.uuid_or_null(l.payload->>'farmer_id')),
  m as (select * from b where b.state_id = p_state
          and (p_event is null or b.event::text = p_event) and (p_actor is null or b.actor = p_actor)
          and (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name) order by u.display_name)
                     from app_users u where u.id in (select b.actor from b where b.state_id = p_state)), '[]'),   -- migration 42
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role,
            'stage_role', case when m.stage_type is null then null when m.event in ('create', 'supervisory') then m.stage_type::text
                               when m.event = 'seal' or m.stage_type = 'qr_activation' then 'qr_activation'
                               when m.event = 'verify' then coalesce(app.chain_next(m.the_scope, m.stage_type)::text, m.stage_type::text) end,
            'same_person', coalesce((m.event = 'verify' and m.fp_maker = m.actor and m.stage_type <> 'qr_activation')
                           or (m.event = 'create' and m.prev_maker = m.actor and not coalesce(m.fp_grade_lot, false)), false))
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, signers, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset,
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from public.clients c
                             where c.state_id = p_state or exists (select 1 from public.scopes s where s.client_id = c.id and s.state_id = p_state)), '[]'),
       'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_id', s.client_id)
                             order by cr.name, s.season_code) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.state_id = p_state), '[]'),
       'actors', signers),
    -- the chain is checked whole: the last check of the whole ledger, without a button to run one
    'check', (select jsonb_build_object('checked_at', k.checked_at, 'ok', k.ok, 'blocks', k.blocks, 'first_bad_seq', k.first_bad_seq, 'source', k.source)
                from public.ledger_checks k order by k.checked_at desc limit 1));
end $function$;

CREATE OR REPLACE FUNCTION app.assignment_warnings(p_employee uuid, p_lens assignment_lens, p_target uuid, p_op_role op_role, p_stages stage_type[] DEFAULT '{}'::stage_type[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare w jsonb := '[]'::jsonb; u public.app_users; sc public.scopes; r record; i int; v_chain public.stage_type[]; v_held public.stage_type[]; v_new public.stage_type[];
begin
  select * into u from public.app_users where id = p_employee;
  if u.status in ('invited', 'onboarding') then
    w := w || jsonb_build_object('code', 'not_active_yet', 'status', u.status); end if;
  if u.auth_uid is null or u.auth_uid = u.id then
    w := w || jsonb_build_object('code', 'no_login'); end if;
  if p_lens = 'scope' then
    select * into sc from public.scopes where id = p_target;
    -- an operational role in two places at once: another state, or another place in the same season
    for r in select s.geography, st.name as state_name, s.state_id, c.name as client_name
               from public.assignments a join public.scopes s on s.id = a.scope_id
               join public.states st on st.id = s.state_id join public.clients c on c.id = s.client_id
              where a.employee_id = p_employee and a.active and a.lens = 'scope' and s.id <> sc.id and s.status <> 'closed'
                and (s.state_id <> sc.state_id or (s.geography <> sc.geography and s.season_code = sc.season_code)) loop
      w := w || jsonb_build_object('code', case when r.state_id <> sc.state_id then 'other_state' else 'other_place' end,
                                   'place', r.geography, 'state', r.state_name, 'client', r.client_name);
    end loop;
    -- migration 46 (Veda, 14 Oct): one person may hold several stages, also two in a row. Two in a row: at the second
    -- he verifies his own records of the first (allowed, marked in the ledger). The stages he holds here already count.
    v_chain := sc.chain;
    v_held := coalesce((select a.stages from public.assignments a where a.employee_id = p_employee and a.active and a.lens = 'scope'
                          and a.scope_id = sc.id limit 1), '{}');
    v_new := (select coalesce(array_agg(distinct x), '{}') from unnest(coalesce(p_stages, '{}') || v_held) x);
    for i in 1 .. coalesce(array_length(v_chain, 1), 1) - 1 loop
      if v_chain[i] = any(v_new) and v_chain[i + 1] = any(v_new) and v_chain[i + 1] <> 'qr_activation' then
        w := w || jsonb_build_object('code', 'adjacent_stages', 'first', v_chain[i], 'second', v_chain[i + 1], 'name', u.display_name);
      end if;
    end loop;
    if cardinality(v_new) > 1 and not exists (select 1 from jsonb_array_elements(w) x where x->>'code' = 'adjacent_stages') then
      w := w || jsonb_build_object('code', 'several_stages', 'name', u.display_name,
                                   'stages', (select to_jsonb(array_agg(c.st order by c.i)) from unnest(v_chain) with ordinality c(st, i) where c.st = any(v_new)));
    end if;
  end if;
  return w;
end $function$;

CREATE OR REPLACE FUNCTION app.set_stages(p_assignment uuid, p_stages stage_type[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); a public.assignments; sc public.scopes; st public.stage_type; v_new public.stage_type[];
begin
  select * into a from public.assignments where id = p_assignment;
  if a.id is null or not a.active or a.lens <> 'scope' then raise exception 'assignment not found' using errcode = 'P0002'; end if;
  if not app.may_assign(a.lens, a.op_role, a.scope_id) then
    raise exception 'you do not manage this scope' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = a.scope_id;
  select coalesce(array_agg(x order by array_position(sc.chain, x)), '{}') into v_new
    from (select distinct unnest(coalesce(p_stages, '{}')) as x) q;
  foreach st in array v_new loop
    if not (st = any(sc.chain)) then raise exception 'stage % is not in this scope''s chain', st using errcode = '23514'; end if;
  end loop;
  if exists (select 1 from unnest(v_new) x where not (x = any (a.stages))) and app.stage_refusal(a.employee_id, a.scope_id) is not null then
    raise exception '%', app.stage_refusal(a.employee_id, a.scope_id) using errcode = '42501'; end if;   -- migration 44 (A2)
  if a.op_role = 'operator' and cardinality(v_new) = 0 then
    raise exception 'an operator holds at least one stage: end the assignment instead' using errcode = '23514'; end if;
  if v_new = a.stages then return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(app.coverage_gaps(a.scope_id))); end if;

  perform set_config('app.assigning', 'on', true);
  delete from public.slot_assignments where assignment_id = a.id and not (stage_type = any(v_new));
  foreach st in array v_new loop
    if not (st = any(a.stages)) then
      insert into public.slot_assignments (user_id, scope_id, stage_type, assignment_id) values (a.employee_id, a.scope_id, st, a.id);
    end if;
  end loop;
  update public.assignments set stages = v_new where id = a.id;
  perform set_config('app.assigning', '', true);
  perform app.audit('stages_changed', a.employee_id, jsonb_build_object('assignment_id', a.id, 'scope_id', a.scope_id,
    'before', to_jsonb(a.stages), 'after', to_jsonb(v_new)));
  select * into a from public.assignments where id = a.id;
  -- migration 46: a stage given on the roster says, as a new assignment does, what is worth a second look (two in a row)
  return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(app.coverage_gaps(a.scope_id)),
    'warnings', app.assignment_warnings(a.employee_id, 'scope', a.scope_id, a.op_role, v_new));
end $function$;


-- ---------------------------------------------------------------------------------------------------------------------
-- C, D · the pool puts first who HR got ready for this scope; openings say where they came from
-- ---------------------------------------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.roster_pool(p_scope uuid, p_q text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; v_q text := nullif(lower(btrim(p_q)), '');
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'the Client Manager of this scope''s client chooses its people' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'district', o.base_district,
             'me', u.id = app.current_user_id(),
             'ready_for', rf.stage, 'ready_opening', rf.code,      -- migration 46: joined on an opening of this scope, not placed yet
             'stages', coalesce((select to_jsonb(a.stages) from public.assignments a
                                  where a.employee_id = u.id and a.active and a.lens = 'scope' and a.scope_id = sc.id), '[]'::jsonb))
           order by rf.stage is null, u.id <> app.current_user_id(), u.display_name)
      from (select u.* from public.app_users u left join public.employee_org o2 on o2.employee_id = u.id
             where not u.external and not u.test_data and u.system_role = 'operational' and u.status in ('invited', 'onboarding', 'active')
               and (v_q is null or lower(u.display_name) like '%' || v_q || '%')
               and (o2.base_state_id = sc.state_id or app.client_account_holder(u.id, sc.client_id))
             order by u.display_name limit 200) u
      left join public.employee_org o on o.employee_id = u.id
      left join lateral (select op.stage, op.code from public.openings op
                          where op.id = o.opening_id and u.status = 'active' and op.status <> 'closed' and op.role = 'operator'
                            and op.state_id = sc.state_id and op.stage = any(sc.chain)
                            and (op.scope_id = sc.id or (op.scope_id is null and (op.client_id is null or op.client_id = sc.client_id)))
                            and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = 'scope'
                                              and a.scope_id = sc.id and op.stage = any(a.stages))) rf on true
     where app.stage_refusal(u.id, sc.id) is null), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.opening_json(o openings)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('id', o.id, 'code', o.code, 'state_id', o.state_id, 'state_name', (select name from public.states where id = o.state_id),
           'role', o.role, 'stage', o.stage, 'client_id', o.client_id, 'client_name', (select name from public.clients where id = o.client_id),
           'scope_id', o.scope_id,
           'scope_name', (select cr.name || ' · ' || s.season_code || ' · ' || s.geography from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = o.scope_id),
           'target_join', o.target_join, 'status', o.status, 'title', o.title, 'note', o.note, 'created_at', o.created_at,
           'ready_target', app.opening_ready(o),
           'source', o.source, 'requested_by_name', (select display_name from public.app_users where id = o.requested_by),
           'requirement_line_id', o.requirement_line_id, 'group_id', o.group_id, 'group_title', o.group_title) || app.opening_numbers(o)
$function$;

CREATE OR REPLACE FUNCTION app.state_home(p_state uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'no access to this state' using errcode = '42501'; end if;
  if not exists (select 1 from public.states where id = p_state) then raise exception 'state not found' using errcode = 'P0002'; end if;
  with sc as (select s.* from public.scopes s where s.state_id = p_state),
  live as (
    select distinct sa.scope_id, sa.stage_type
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'
       and sa.scope_id in (select id from sc)),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from sc s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' and f.scope_id in (select id from sc)
     group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id
     where f.scope_id in (select id from sc) group by f.scope_id),
  waiting as (
    select f.scope_id, count(*) as n from public.footprints f
     where f.status = 'pending' and f.scope_id in (select id from sc) group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join sc s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  mgr as (
    select a.client_id, string_agg(distinct u.display_name, ', ') as names
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())
     group by a.client_id),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'draft') as scopes_setup,
           (select count(*) from sc s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(v.lots) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as lots,
           coalesce((select sum(q.n) from qr q join sc s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           coalesce((select sum(w.n) from waiting w join sc s on s.id = w.scope_id where s.client_id = c.id), 0) as waiting,
           (select m.names from mgr m where m.client_id = c.id) as managers,
           exists (select 1 from mgr m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id
     where c.state_id = p_state or exists (select 1 from sc s where s.client_id = c.id)),
  fw as (
    select f.id, f.name, f.village, f.client_id, c.name as client
      from public.farmers f join public.clients c on c.id = f.client_id
     where f.status = 'under_review' and f.reviewed_by is not null and coalesce(f.state_id, c.state_id) = p_state),
  fl as (
    select fl.id, fl.text, fl.created_at, fl.footprint_id, f.footprint_code, c.name as client
      from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
     where fl.status = 'open' and f.scope_id in (select id from sc)),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from sc s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- chain order, as on the admin's pipeline: each stage's average step in the active chains of the state; the seal last
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from sc s where s.status = 'active') then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from sc s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = p_state),
    'managers', coalesce((select jsonb_agg(u.display_name order by u.display_name) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and a.state_id = p_state and u.status = 'active'), '[]'),
    'clients', jsonb_build_object(
       'total', (select count(*) from cl where cl.state_id = p_state),
       'active', (select count(*) from cl where cl.state_id = p_state and scopes_active > 0),
       'without_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops where state_id = p_state),
       'state_not_set', (select count(*) from public.crops where state_id is null),
       'ready', (select count(*) from public.crops cr where cr.state_id = p_state and cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from sc s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from sc s where s.crop_id = cr.id),
                  'ready', cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0, 'missing', to_jsonb(app.crop_missing(cr))) order by cr.name)
                  from public.crops cr where cr.state_id = p_state), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from sc where status = 'active'),
       'setup', (select count(*) from sc where status = 'draft'),
       'closed', (select count(*) from sc where status = 'closed'),
       'qr_issued', coalesce((select sum(n) from qr), 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client', c.name, 'crop', cr.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'status', s.status,
                  'same_person', app.same_person_counts(s.id)) order by s.status, c.name)
                  from sc s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id), '[]')),
    'farmers', jsonb_build_object(
       'total', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id where coalesce(f.state_id, c.state_id) = p_state),
       'active', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id
                   where coalesce(f.state_id, c.state_id) = p_state and f.status = 'active')),
    'attention', jsonb_build_object(
       'no_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'no_manager_list', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'name', cl.name, 'code', cl.code) order by cl.name)
                                      from cl where cl.state_id = p_state and not has_manager), '[]'),
       'farmers_waiting', (select count(*) from fw),
       'farmers_list', coalesce((select jsonb_agg(to_jsonb(fw) order by fw.client, fw.name) from (select * from fw order by client, name limit 50) fw), '[]'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join sc s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'open_flags', (select count(*) from fl),
       -- migration 43: the farmer register's two flags for him
       'duplicates', (select count(*) from public.farmers f where app.farmer_home(f.state_id, f.client_id) = p_state and app.pending_duplicate(f)),   -- migration 44
       'changes', (select count(distinct c.farmer_id) from public.farmer_change_flags c join public.farmers f on f.id = c.farmer_id
                    where c.accepted_at is null and app.farmer_home(f.state_id, f.client_id) = p_state),
       'above_yield', (select count(*) from app.above_yield(p_state, app.state_season(p_state))),   -- a warning, not his to decide
       'no_gi_land', (select count(*) from public.farmers f where app.farmer_home(f.state_id, f.client_id) = p_state
                        and f.status <> 'inactive' and f.gi_land_acres is null),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', fl.footprint_code, 'client', fl.client) order by fl.created_at) from fl), '[]')),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp
                           where pp.position is not null or pp.pending + pp.done > 0), '[]')
  ) into r;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION app.scope_roster(p_scope uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes;
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.sees_whole_scope(p_scope) then raise exception 'no access to this scope' using errcode = '42501'; end if;
  return jsonb_build_object(
    'scope', jsonb_build_object('id', sc.id, 'status', sc.status, 'season_code', sc.season_code, 'geography', sc.geography, 'season_end', sc.season_end,
               'client_id', sc.client_id, 'client_name', (select name from public.clients where id = sc.client_id),
               'crop_name', (select name from public.crops where id = sc.crop_id),
               'state_id', sc.state_id, 'state_name', (select name from public.states where id = sc.state_id)),
    'can_manage', app.i_manage_scope(p_scope),
    'same_person', app.same_person_counts(p_scope),           -- migration 46
    'gaps', to_jsonb(app.coverage_gaps(p_scope)),
    'stages', coalesce((
      select jsonb_agg(jsonb_build_object('stage', c.st, 'position', c.i, 'label', d.label,
               'holders', coalesce((
                 select jsonb_agg(jsonb_build_object('assignment_id', a.id, 'employee_id', u.id, 'name', u.display_name, 'status', u.status,
                          'posting', a.posting, 'since', sa.created_at, 'lapsed', a.ends_on is not null and a.ends_on < app.today())
                          order by u.display_name)
                   from public.slot_assignments sa join public.assignments a on a.id = sa.assignment_id
                   join public.app_users u on u.id = sa.user_id
                  where sa.scope_id = sc.id and sa.stage_type = c.st and a.active), '[]'::jsonb)) order by c.i)
        from unnest(sc.chain) with ordinality as c(st, i) join public.stage_definitions d on d.stage_type = c.st), '[]'::jsonb),
    'managers', coalesce((
      select jsonb_agg(jsonb_build_object('employee_id', u.id, 'name', u.display_name, 'op_role', a.op_role, 'status', u.status) order by a.op_role, u.display_name)
        from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and ((a.lens = 'client' and a.client_id = sc.client_id) or (a.lens = 'state' and a.state_id = sc.state_id)
                           or (a.lens = 'scope' and a.scope_id = sc.id and a.op_role = 'export_manager'))), '[]'::jsonb));
end $function$;


-- ---------------------------------------------------------------------------------------------------------------------
-- 7 · the People step saved (A2): the scope's empty stages become lines of its requirement
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.save_people_step(p_scope uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc public.scopes;
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'the Client Manager of this scope''s client saves its People step' using errcode = '42501'; end if;
  if sc.status not in ('draft', 'active') then raise exception 'this scope is closed' using errcode = '23514'; end if;
  perform app.sync_scope_requirement(sc.id, true);
  return app.scope_requirement(sc.id);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 8 · one person on two stages in a row (E): how often a record was checked by its own maker, or built on by him
-- ---------------------------------------------------------------------------------------------------------------------
-- verified_own: records verified by the person who made them (the seal is its sealer's own act: not counted);
-- made_on_own: records made on a lot the same person recorded at the stage before (a grade lot is its run's: not counted)
create or replace function app.same_person_counts(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'verified_own', count(*) filter (where f.status = 'verified' and f.verified_by = f.created_by and f.stage_type <> 'qr_activation'),
    'made_on_own', count(*) filter (where p.created_by = f.created_by and not f.is_grade_lot))
    from public.footprints f left join public.footprints p on p.id = f.prev_footprint_id
   where f.scope_id = p_scope and f.status in ('pending', 'verified') $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 9 · a new opening by hand for several stages of one scope at once (D): one opening per stage, one group
-- ---------------------------------------------------------------------------------------------------------------------
-- p: as app.save_opening, with "stages": [..] for an operator opening of a scope; one stage, or none: app.save_opening
create or replace function app.save_openings(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare st text; made jsonb := '[]'::jsonb; one jsonb; g uuid := gen_random_uuid(); v_title text; sc public.scopes;
begin
  if jsonb_typeof(p->'stages') <> 'array' or jsonb_array_length(p->'stages') <= 1 or nullif(p->>'id', '') is not null then
    return jsonb_build_array(app.save_opening((p - 'stages') || case when jsonb_typeof(p->'stages') = 'array' and jsonb_array_length(p->'stages') = 1
                                                                      then jsonb_build_object('stage', p->'stages'->>0) else '{}'::jsonb end));
  end if;
  if coalesce(p->>'role', '') <> 'operator' or nullif(p->>'scope_id', '') is null then
    raise exception 'several stages at once: an operator opening of one scope' using errcode = '23514'; end if;
  select * into sc from public.scopes where id = (p->>'scope_id')::uuid;
  v_title := coalesce(nullif(left(btrim(p->>'title'), 120), ''),
                      (select cr.name from public.crops cr where cr.id = sc.crop_id) || ' · ' || sc.season_code || ' · ' || sc.geography);
  for st in select distinct x from jsonb_array_elements_text(p->'stages') x loop
    one := app.save_opening((p - 'stages') || jsonb_build_object('stage', st));
    update public.openings set group_id = g, group_title = v_title where id = (one->>'id')::uuid;
    made := made || app.opening_json((select o from public.openings o where o.id = (one->>'id')::uuid));
  end loop;
  return made;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 10 · who may call what
-- ---------------------------------------------------------------------------------------------------------------------
revoke all on function app.hr_of_state(uuid), app.owns_requirement(public.requirements), app.line_status(uuid, text, text, text),
  app.sync_scope_requirement(uuid, boolean), app.sync_client_requirement(uuid), app.requirements_on_scope(), app.requirements_on_slot(),
  app.requirements_on_assignment(), app.requirements_on_client(), app.line_json(public.requirement_lines), app.requirement_json(public.requirements),
  app.hr_requirement_counts(), app.same_person_counts(uuid)
  from public, anon, authenticated;
revoke all on function app.request_people(jsonb), app.requester_act(uuid, text, jsonb), app.scope_requirement(uuid), app.state_requirements(uuid),
  app.hr_requirements(jsonb), app.decide_lines(uuid[], text, text, jsonb), app.save_people_step(uuid), app.save_openings(jsonb) from public, anon;
grant execute on function app.request_people(jsonb), app.requester_act(uuid, text, jsonb), app.scope_requirement(uuid), app.state_requirements(uuid),
  app.hr_requirements(jsonb), app.decide_lines(uuid[], text, text, jsonb), app.save_people_step(uuid), app.save_openings(jsonb) to authenticated;
grant execute on function app.hr_requirement_counts() to authenticated;   -- the HR menu's badge (its own states only)

-- ---------------------------------------------------------------------------------------------------------------------
-- 11 · what is there already: the scopes being staffed (a saved draft, an active scope) and the clients with no Client
-- Manager get their requirement now; the openings made by hand before (UP-OPR-002 … 007 on staging) stay as they are,
-- "Created by HR" (source 'hr', the column's default)
-- ---------------------------------------------------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select id from public.scopes where status in ('draft', 'active') order by created_at loop
    perform app.sync_scope_requirement(r.id, true);
  end loop;
  for r in select id from public.clients where state_id is not null order by created_at loop
    perform app.sync_client_requirement(r.id);
  end loop;
end $$;
