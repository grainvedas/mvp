-- Migration 44 (Veda, 14 Oct 2026, "GrainVeda MVP — Follow-up: State Manager, Client Manager, HR, scopes and farmer IDs";
-- FIX_LIST item 39). Release 4 of the follow-up: the server gaps her tests found, the two farmer IDs, the farmer's history
-- and changes, the yield as a warning only, the ledger's working role, the HR decisions of 14 Oct, and a one-off fix of
-- the practice data. Her answers to the plan (14 Oct, "go with your recommendations"):
--   · a test person is MARKED as test data and hidden from every list, count and pool; nothing is deleted
--   · the State Manager is read-only on scope records too (K62 closed): he watches his state, he does not manage scopes
--   · the roster pool is the operational people BASED IN the scope's state (a person with no base location is not in it)
-- Additive: new tables, columns and functions; functions replaced from their current definitions, each substitution
-- asserted by the generator. No row of the ledger is changed; a correction is a new block that says why.

-- 0 · test data (G7, section 6 below) is a column every list below leaves out
alter table public.app_users add column if not exists test_data boolean not null default false;
alter table public.app_users add column if not exists test_data_note text;

-- =====================================================================================================================
-- 1 · who manages a scope (A1, K62): its client's Client Manager only. The State Manager WATCHES his state's scopes.
-- =====================================================================================================================
-- the state lens is no longer a manager of a place: rosters, records, flags, withdrawals are the Client Manager's
create or replace function app.manages_place(p_user uuid, p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app.eff_assignments(p_user) a
     where a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client) $$;

-- the State Manager reads every scope of his state (what he managed before, he now watches)
create or replace function app.watches_state(p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_state is not null and p_state = any (app.my_state_ids()) $$;
create or replace function app.watches_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select app.watches_state(s.state_id) from public.scopes s where s.id = p_scope), false) $$;

-- =====================================================================================================================
-- 2 · who may be put on a stage (A2): an operational employee based in the scope's state, or the Client Manager himself
-- =====================================================================================================================
-- null: may be put on a stage of this scope; otherwise why not
create or replace function app.stage_refusal(p_user uuid, p_scope uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare u public.app_users; sc public.scopes; base uuid;
begin
  select * into u from public.app_users where id = p_user;
  select * into sc from public.scopes where id = p_scope;
  if u.id is null or sc.id is null then return 'unknown person or scope'; end if;
  if u.external then return 'a client''s login holds no stage'; end if;
  if u.system_role = 'admin' then return 'an admin oversees and holds no stage'; end if;
  if u.system_role in ('hr_admin', 'hr_resource') then return 'HR holds no stage'; end if;
  -- a suspended or offboarded person: the assignment rules say so in their own words (assignments_guard)
  if exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = 'state') then
    return 'a State Manager holds no stage'; end if;
  if app.client_account_holder(u.id, sc.client_id) then return null; end if;      -- the Client Manager himself (Veda, 14 Oct)
  select o.base_state_id into base from public.employee_org o where o.employee_id = u.id;
  if base is null or base <> sc.state_id then
    return format('this person is not based in %s', coalesce((select name from public.states where id = sc.state_id), 'the scope''s state')); end if;
  return null;
end $$;

-- the roster's pool for one scope: the people who may be put on its stages (its Client Manager asks)
create or replace function app.roster_pool(p_scope uuid, p_q text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc public.scopes; v_q text := nullif(lower(btrim(p_q)), '');
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'the Client Manager of this scope''s client chooses its people' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'district', o.base_district,
             'me', u.id = app.current_user_id(),
             'stages', coalesce((select to_jsonb(a.stages) from public.assignments a
                                  where a.employee_id = u.id and a.active and a.lens = 'scope' and a.scope_id = sc.id), '[]'::jsonb))
           order by u.id <> app.current_user_id(), u.display_name)
      from (select u.* from public.app_users u left join public.employee_org o2 on o2.employee_id = u.id
             where not u.external and not u.test_data and u.system_role = 'operational' and u.status in ('invited', 'onboarding', 'active')
               and (v_q is null or lower(u.display_name) like '%' || v_q || '%')
               and (o2.base_state_id = sc.state_id or app.client_account_holder(u.id, sc.client_id))
             order by u.display_name limit 200) u
      left join public.employee_org o on o.employee_id = u.id
     where app.stage_refusal(u.id, sc.id) is null), '[]'::jsonb);
end $$;

-- =====================================================================================================================
-- 3 · activation (A3): every stage has a person and the crop is ready
-- =====================================================================================================================
create or replace function app.activation_missing(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'crop', coalesce((select to_jsonb(app.crop_missing(cr)) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope), '[]'::jsonb),
    'retired', coalesce((select cr.retired_at is not null from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope), false),
    'stages', to_jsonb(app.coverage_gaps(p_scope, null))) $$;

create or replace function app.scopes_staffed() returns trigger
language plpgsql security definer set search_path = public as $$
declare g public.stage_type[];
begin
  if auth.uid() is null then return new; end if;                          -- a person acting (not a seed or a migration)
  if new.status = 'active' and (tg_op = 'INSERT' or old.status = 'draft') then
    g := case when tg_op = 'INSERT' then new.chain else app.coverage_gaps(new.id, null) end;
    if cardinality(g) > 0 then
      raise exception 'every stage needs a person before the scope is activated; nobody yet at: %',
        (select string_agg(coalesce(d.label, x::text), ', ' order by array_position(new.chain, x))
           from unnest(g) x left join public.stage_definitions d on d.stage_type = x) using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger scopes_a3_staffed before insert or update on public.scopes for each row execute function app.scopes_staffed();

-- =====================================================================================================================
-- 4 · the Client Manager's view of people (A4): his client's people and the eligible pool of his state; never Admin or HR
-- =====================================================================================================================
create or replace function app.cm_limited() returns boolean
language sql stable security definer set search_path = public as $$
  select app.holds_op_role('client_account') and not app.holds_op_role('state_supervisor') and not app.is_hr() and not app.is_admin() $$;

create or replace function app.cm_seen_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  with m as materialized (
    select app.current_user_id() as me,
           coalesce((select array_agg(distinct a.client_id) from app.eff_assignments(app.current_user_id()) a
                      where a.lens = 'client' and a.op_role = 'client_account'), '{}') as clients),
  st as materialized (select coalesce(array_agg(distinct c.state_id), '{}') as ids from public.clients c, m where c.id = any (m.clients))
  select coalesce(array_agg(u.id), '{}') from public.app_users u, m, st
   where u.id = m.me
      or (not u.external and u.system_role = 'operational' and not u.test_data and (
            -- his client's people: anyone on his client or one of its scopes
            exists (select 1 from public.assignments a left join public.scopes sc on sc.id = a.scope_id
                     where a.employee_id = u.id and a.active and coalesce(a.client_id, sc.client_id) = any (m.clients)
                       and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state'))
            -- the eligible pool of his state: based there, working, no State Manager seat
            or (u.status in ('invited', 'onboarding', 'active')
                and exists (select 1 from public.employee_org o where o.employee_id = u.id and o.base_state_id = any (st.ids))
                and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state')))) $$;

-- may the signed-in person be offered "Assign" on this person (the list and the profile ask the server)
create or replace function app.may_offer_assign(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (app.is_hr_admin() or (app.can_assign() and not app.is_admin()))
       and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> app.current_user_id()
       and u.system_role not in ('admin', 'hr_admin', 'hr_resource') and not u.test_data
       and (not app.cm_limited() or (u.system_role = 'operational' and u.id = any (app.cm_seen_ids())
                                     and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state')))
       and (not app.sm_limited() or app.sm_sees(u.id))
      from public.app_users u where u.id = p_person), false) $$;

-- =====================================================================================================================
-- 5 · the working role a person signed in (D6): from the assignments that were open at that moment
-- =====================================================================================================================
create or replace function app.working_role_at(p_user uuid, p_at timestamptz) returns text
language sql stable security definer set search_path = public as $$
  select case
    when u.id is null then null
    when u.external then 'client_login'
    when u.system_role = 'admin' then 'admin'
    when u.system_role = 'hr_admin' then 'hr_admin'
    when u.system_role = 'hr_resource' then 'hr'
    else coalesce((
      select case when bool_or(a.lens = 'state') then 'state_manager'
                  when bool_or(a.op_role = 'client_account') then 'client_manager'
                  when bool_or(a.op_role = 'export_manager') then 'export_manager'
                  when bool_or(a.op_role = 'client_viewer') then 'client_view'
                  when bool_or(a.op_role = 'operator') then 'operator' end
        from public.assignments a
       where a.employee_id = u.id and a.created_at <= p_at and (a.ended_at is null or a.ended_at > p_at)), 'operational') end
    from public.app_users u where u.id = p_user $$;

-- =====================================================================================================================
-- 6 · test data (G7): marked, hidden from every list, count and pool; kept with every block that names it
-- =====================================================================================================================

create or replace function app.mark_test_person(p_user uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare u public.app_users;
begin
  if auth.uid() is not null and not app.is_admin() then
    raise exception 'only the admin marks test data' using errcode = '42501'; end if;
  select * into u from public.app_users where id = p_user;
  if u.id is null then raise exception 'person not found' using errcode = 'P0002'; end if;
  if u.status <> 'offboarded' then raise exception 'only a person who has left can be marked as test data' using errcode = '23514'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'say why' using errcode = '23514'; end if;
  if u.test_data then return; end if;
  update public.app_users set test_data = true, test_data_note = btrim(p_reason) where id = u.id;
  perform app.audit('marked_test_data', u.id, jsonb_build_object('name', u.display_name, 'reason', btrim(p_reason)), true);
end $$;

-- =====================================================================================================================
-- 7 · two farmer IDs (E1): the STATE farmer ID (F-UP-00001), one per person per state, given by the State Manager;
--     the CLIENT farmer ID (TCUP-F-0001), given when the Client Manager verifies
-- =====================================================================================================================
create table if not exists public.state_farmers (
  id         uuid primary key default gen_random_uuid(),
  state_id   uuid not null references public.states(id),
  code       text not null unique,
  created_by uuid references public.app_users(id),
  created_at timestamptz not null default now());
create table if not exists public.state_farmer_counters (state_id uuid primary key references public.states(id), last int not null default 0);
alter table public.state_farmers enable row level security;
alter table public.state_farmer_counters enable row level security;

alter table public.farmers add column if not exists state_farmer_id uuid references public.state_farmers(id);
create index if not exists farmers_state_farmer_idx on public.farmers (state_farmer_id);
-- readable by whoever reads one of its farmer records (the farmers rule decides)
create policy state_farmers_read on public.state_farmers for select to authenticated using (
  exists (select 1 from public.farmers f where f.state_farmer_id = state_farmers.id));
grant select on public.state_farmers to authenticated;
-- the farmer agrees that his state farmer ID may show on the public verify page (shown from Release 5)
alter table public.farmers add column if not exists public_id_consent boolean not null default false;

create or replace function app.new_state_farmer(p_state uuid, p_by uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare n int; sc text; v uuid;
begin
  select code into sc from public.states where id = p_state;
  if sc is null then raise exception 'the farmer''s state is not known' using errcode = '23514'; end if;
  insert into public.state_farmer_counters (state_id, last) values (p_state, 1)
  on conflict (state_id) do update set last = state_farmer_counters.last + 1 returning last into n;
  insert into public.state_farmers (state_id, code, created_by)
  values (p_state, format('F-%s-%s', sc, case when n < 100000 then lpad(n::text, 5, '0') else n::text end), p_by)
  returning id into v;
  return v;
end $$;

-- the state farmers this record may be the same person as: same phone (last ten digits), same state, a record not deactivated
create or replace function app.state_candidates(p_farmer uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', sf.id, 'code', sf.code,
           'records', (select jsonb_agg(jsonb_build_object('name', o.name, 'farmer_code', o.farmer_code, 'client', c.name, 'village', o.village) order by o.created_at)
                         from public.farmers o join public.clients c on c.id = o.client_id
                        where o.state_farmer_id = sf.id and o.status <> 'inactive')) order by sf.code), '[]'::jsonb)
    from public.farmers f
    join public.state_farmers sf on sf.state_id = app.farmer_home(f.state_id, f.client_id)
   where f.id = p_farmer
     and exists (select 1 from public.farmers o where o.state_farmer_id = sf.id and o.id <> f.id and o.status <> 'inactive'
                    and app.phone10(o.phone) = app.phone10(f.phone)) $$;

-- step 2 gives the state farmer ID: a new one, or the existing one of the same person (Veda, 14 Oct)
create or replace function app.farmers_state_id() returns trigger
language plpgsql security definer set search_path = public as $$
declare home uuid; cands uuid[]; link text := nullif(current_setting('app.state_link', true), '');
        why text := nullif(btrim(coalesce(current_setting('app.state_link_reason', true), '')), '');
begin
  if not (tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' and new.state_farmer_id is null) then return new; end if;
  home := app.farmer_home(new.state_id, new.client_id);
  select coalesce(array_agg((x->>'id')::uuid), '{}') into cands from jsonb_array_elements(app.state_candidates(new.id)) x;
  if link is not null and link <> 'new' then
    if not (link::uuid = any (cands)) then
      raise exception 'that state farmer has no record with this phone in this state' using errcode = '23514'; end if;
    new.state_farmer_id := link::uuid;
  elsif cardinality(cands) > 0 and link is null then
    if auth.uid() is null then new.state_farmer_id := cands[1];          -- a seed or the service: the same person
    else
      raise exception 'same phone as %: link this farmer to that state farmer, or say why they are not the same person',
        (select string_agg(code, ', ' order by code) from public.state_farmers where id = any (cands)) using errcode = '23514'; end if;
  else
    if link = 'new' and cardinality(cands) > 0 and why is null then
      raise exception 'say why this is not the same person as %', (select string_agg(code, ', ' order by code) from public.state_farmers where id = any (cands))
        using errcode = '23514'; end if;
    new.state_farmer_id := app.new_state_farmer(home, coalesce(app.current_user_id(), new.verified_by));
  end if;
  return new;
end $$;
create trigger farmers_z3_state_id before update on public.farmers for each row execute function app.farmers_state_id();

-- what the State Manager is offered at step 2: the state farmers with this phone in this state
create or replace function app.state_choice(p_farmer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.farmers;
begin
  select * into f from public.farmers where id = p_farmer;
  if f.id is null or not app.farmer_staff(app.current_user_id(), f.client_id, f.state_id) then
    raise exception 'the State Manager of the farmer''s state chooses' using errcode = '42501'; end if;
  return app.state_candidates(f.id);
end $$;

-- the State Manager's step 2 with his choice: p_link = the state farmer to link to; or p_reason = why it is a new person
create or replace function app.verify_farmer_state(p_farmer uuid, p_link uuid default null, p_reason text default null) returns public.farmers
language plpgsql security invoker set search_path = public as $$
declare r public.farmers;
begin
  perform set_config('app.state_link', case when p_link is not null then p_link::text when nullif(btrim(p_reason), '') is not null then 'new' else '' end, true);
  perform set_config('app.state_link_reason', coalesce(btrim(p_reason), ''), true);
  update public.farmers set status = 'active', verified_by = app.current_user_id()
   where id = p_farmer and status = 'under_review' returning * into r;
  if r.id is null then raise exception 'farmer not found or not waiting for verification' using errcode = 'P0002'; end if;
  return r;
end $$;

-- every farmer already verified by a State Manager gets his state farmer ID once (farmer 1 on the practice system);
-- the same phone in the same state is the same person unless the State Manager has said otherwise
create or replace function app.give_missing_state_ids(p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare f record; n int := 0; sf uuid;
begin
  perform set_config('app.state_id_backfill', p_reason, true);
  for f in select * from public.farmers where state_farmer_id is null and verified_at is not null and farmer_code is not null
            order by verified_at, created_at, id loop
    select o.state_farmer_id into sf from public.farmers o
     where o.state_farmer_id is not null and o.id <> f.id
       and app.farmer_home(o.state_id, o.client_id) = app.farmer_home(f.state_id, f.client_id)
       and app.phone10(o.phone) = app.phone10(f.phone)
       and not exists (select 1 from public.farmer_dup_reviews r where r.farmer_a = least(f.id, o.id) and r.farmer_b = greatest(f.id, o.id))
     order by o.verified_at limit 1;
    update public.farmers set state_farmer_id = coalesce(sf, app.new_state_farmer(app.farmer_home(f.state_id, f.client_id), f.verified_by))
     where id = f.id;
    n := n + 1;
  end loop;
  perform set_config('app.state_id_backfill', '', true);
  return n;
end $$;

-- =====================================================================================================================
-- 8 · changing a farmer after the Client Manager's verification (E4): a written reason, kept in the ledger
-- =====================================================================================================================
create or replace function app.change_farmer(p_farmer uuid, p jsonb, p_reason text) returns public.farmers
language plpgsql security invoker set search_path = public as $$
declare r public.farmers;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'say why you change this farmer' using errcode = '23514'; end if;
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.farmers set
    name = coalesce(nullif(btrim(p->>'name'), ''), name),
    guardian_name = coalesce(nullif(btrim(p->>'guardian_name'), ''), guardian_name),
    village = coalesce(nullif(btrim(p->>'village'), ''), village),
    district = coalesce(nullif(btrim(p->>'district'), ''), district),
    phone = coalesce(nullif(btrim(p->>'phone'), ''), phone),
    land_area_acres = coalesce(nullif(p->>'land_area_acres', '')::numeric, land_area_acres),
    gi_land_acres = case when p ? 'gi_land_acres' then nullif(p->>'gi_land_acres', '')::numeric else gi_land_acres end,
    photo_consent = coalesce((p->>'photo_consent')::boolean, photo_consent),
    public_id_consent = coalesce((p->>'public_id_consent')::boolean, public_id_consent),
    status = coalesce(nullif(p->>'status', '')::public.farmer_status, status),
    extra = case when p ? 'notes' then (case when nullif(btrim(p->>'notes'), '') is null then extra - 'notes'
                                              else extra || jsonb_build_object('notes', btrim(p->>'notes')) end) else extra end
   where id = p_farmer returning * into r;
  if r.id is null then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  return r;
end $$;

-- a change of GI land or mobile after the State Manager's verification, by someone else, waits for him to accept it
create table if not exists public.farmer_change_flags (
  id          uuid primary key default gen_random_uuid(),
  farmer_id   uuid not null references public.farmers(id),
  field       text not null check (field in ('gi_land_acres', 'phone')),
  before      text,
  after       text,
  reason      text,
  changed_by  uuid references public.app_users(id),
  changed_at  timestamptz not null default now(),
  accepted_by uuid references public.app_users(id),
  accepted_at timestamptz);
alter table public.farmer_change_flags enable row level security;
create policy farmer_change_flags_read on public.farmer_change_flags for select to authenticated using (
  exists (select 1 from public.farmers f where f.id = farmer_id));
grant select on public.farmer_change_flags to authenticated;

create or replace function app.accept_farmer_change(p_flag uuid) returns void
language plpgsql security definer set search_path = public as $$
declare fl public.farmer_change_flags; f public.farmers;
begin
  select * into fl from public.farmer_change_flags where id = p_flag;
  select * into f from public.farmers where id = fl.farmer_id;
  if fl.id is null or not app.farmer_staff(app.current_user_id(), f.client_id, f.state_id) then
    raise exception 'the State Manager of the farmer''s state accepts a change' using errcode = '42501'; end if;
  if fl.accepted_at is not null then return; end if;
  update public.farmer_change_flags set accepted_by = app.current_user_id(), accepted_at = now() where id = fl.id;
  perform app.audit('farmer_change_accepted', f.id, jsonb_build_object('name', f.name, 'farmer_code', f.farmer_code, 'field', fl.field,
    'before', fl.before, 'after', fl.after));
end $$;

-- the farmer's page: who drafted, who verified (Client Manager, then State Manager), and every later change (E3)
create or replace function app.farmer_history(p_farmer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.farmers;
begin
  select * into f from public.farmers where id = p_farmer;
  if f.id is null or not app.farmer_read(f.client_id, f.state_id) then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'farmer_code', f.farmer_code,
    'state_farmer_code', (select code from public.state_farmers where id = f.state_farmer_id),
    'drafted', jsonb_build_object('by', (select display_name from public.app_users where id = f.created_by), 'at', f.created_at,
                                  'role', app.working_role_at(f.created_by, f.created_at)),
    'client_verified', case when f.reviewed_at is not null then jsonb_build_object('by', (select display_name from public.app_users where id = f.reviewed_by), 'at', f.reviewed_at) end,
    'state_verified', case when f.verified_at is not null then jsonb_build_object('by', (select display_name from public.app_users where id = f.verified_by), 'at', f.verified_at) end,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('seq', l.seq, 'at', l.created_at, 'kind', coalesce(l.payload->>'kind', l.payload->>'act'),
               'by', u.display_name, 'role', app.working_role_at(l.actor, l.created_at),
               'before', l.payload->'before', 'after', l.payload->'after', 'reason', l.payload->>'reason',
               'farmer_code', l.payload->>'farmer_code', 'state_farmer_code', l.payload->>'state_farmer_code',
               'linked', l.payload->'linked') order by l.seq)
        from public.ledger l left join public.app_users u on u.id = l.actor
       where l.payload->>'farmer_id' = f.id::text), '[]'::jsonb),
    'open_changes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'field', c.field, 'before', c.before, 'after', c.after, 'reason', c.reason,
               'by', (select display_name from public.app_users where id = c.changed_by), 'at', c.changed_at) order by c.changed_at)
        from public.farmer_change_flags c where c.farmer_id = f.id and c.accepted_at is null), '[]'::jsonb),
    'can_accept', app.farmer_staff(app.current_user_id(), f.client_id, f.state_id));
end $$;

-- =====================================================================================================================
-- 9 · the yield (E6): above the expected yield is a WARNING, nothing to decide (Veda, 14 Oct). Thresholds come later.
-- =====================================================================================================================
create or replace function app.above_yield(p_state uuid, p_season text)
returns table (farmer_id uuid, crop_id uuid, sold_kg numeric, expected_kg numeric, ratio numeric)
language sql stable security definer set search_path = public as $$
  select distinct on (x.farmer_id) x.farmer_id, x.crop_id, x.sold_kg, x.expected_kg, round(x.sold_kg / x.expected_kg, 3)
    from app.season_sales(p_state, p_season) x
   where x.expected_kg > 0 and x.sold_kg > x.expected_kg
   order by x.farmer_id, x.sold_kg / x.expected_kg desc $$;

-- the records waiting for a state farmer ID that need the State Manager's decision (the same phone already in the state,
-- or two records waiting with the same phone)
create or replace function app.pending_duplicate(f public.farmers) returns boolean
language sql stable security definer set search_path = public as $$
  select f.status <> 'inactive' and f.state_farmer_id is null and (
    jsonb_array_length(app.state_candidates(f.id)) > 0
    or exists (select 1 from public.farmers o where o.id <> f.id and o.status <> 'inactive' and o.state_farmer_id is null
                 and app.farmer_home(o.state_id, o.client_id) = app.farmer_home(f.state_id, f.client_id)
                 and app.phone10(o.phone) = app.phone10(f.phone))) $$;

-- =====================================================================================================================
-- 10 · the practice data of 14 Oct (section 0): the database owner runs this once on the practice system
-- =====================================================================================================================
create or replace function app.practice_fix_14oct() returns text
language plpgsql security definer set search_path = public as $$
declare out text[] := '{}'; sc public.scopes; n int; op public.openings; u public.app_users; actor uuid;
begin
  if app.environment() = 'production' then raise exception 'not on the production system' using errcode = '42501'; end if;
  -- 1 · the scope activated in a test with nobody on its stages goes back to draft, with a block that says why
  select s.* into sc from public.scopes s join public.clients c on c.id = s.client_id
   where c.code = 'TCUP' and s.season_code = 'KH26' and lower(btrim(s.geography)) = 'gkp' order by s.created_at limit 1;
  if sc.id is null then out := array_append(out, 'scope TCUP KH26 gkp: not found'::text);
  elsif sc.status <> 'active' then out := array_append(out, format('scope TCUP KH26 gkp: %s already, unchanged', sc.status)::text);
  elsif exists (select 1 from public.footprints where scope_id = sc.id) then out := array_append(out, 'scope TCUP KH26 gkp: has records, NOT changed'::text);
  else
    select coalesce((select a.employee_id from public.assignments a join public.app_users x on x.id = a.employee_id
                      where a.lens = 'client' and a.op_role = 'client_account' and a.client_id = sc.client_id order by a.active desc, a.created_at limit 1),
                    (select id from public.app_users where system_role = 'admin' order by created_at limit 1)) into actor;
    perform set_config('app.reverse_activation', 'on', true);
    update public.scopes set status = 'draft' where id = sc.id;
    perform set_config('app.reverse_activation', '', true);
    perform app.ledger_append(null, sc.id, 'supervisory', actor, jsonb_build_object('act', 'activation_reversed', 'scope_id', sc.id,
      'reason', 'Activation reversed: activated in a test with no staff (practice data, 14 Oct 2026; migration 44)'));
    out := array_append(out, 'scope TCUP KH26 gkp: back to draft, ledger block added'::text);
  end if;
  -- 2 · one State Manager per state: UP-SM-001 has 1 position
  select * into op from public.openings where code = 'UP-SM-001';
  if op.id is null then out := array_append(out, 'UP-SM-001: not found'::text);
  elsif op.positions = 1 then out := array_append(out, 'UP-SM-001: 1 position already'::text);
  else
    select count(*) into n from public.employee_org e join public.app_users x on x.id = e.employee_id
     where e.opening_id = op.id and x.status in ('invited', 'onboarding', 'active');
    if n > 1 then out := array_append(out, format('UP-SM-001: %s people on it, NOT changed', n)::text);
    else
      update public.openings set positions = 1 where id = op.id;
      perform app.audit('opening_changed', null, jsonb_build_object('opening', op.code, 'positions', 1, 'before', op.positions,
        'reason', 'one State Manager per state (Veda, 14 Oct 2026)'));
      out := array_append(out, format('UP-SM-001: %s -> 1 position', op.positions)::text);
    end if;
  end if;
  -- 3 · TEST Mine is test data
  select * into u from public.app_users where lower(email) = 'test.mine@example.com';
  if u.id is null then out := array_append(out, 'TEST Mine: not found'::text);
  elsif u.test_data then out := array_append(out, 'TEST Mine: marked already'::text);
  elsif u.status <> 'offboarded' then out := array_append(out, format('TEST Mine: status %s, NOT marked', u.status)::text);
  else perform app.mark_test_person(u.id, 'test data of 14 Oct 2026 (Veda)'); out := array_append(out, 'TEST Mine: marked as test data, hidden'::text); end if;
  return array_to_string(out, '; ');
end $$;

-- =====================================================================================================================
-- 11 · the farmer's rules, rewritten whole (migration 44)
-- =====================================================================================================================
-- who changes a farmer, and when a reason is needed (E4): after the Client Manager's verification (the client farmer ID),
-- its Client Manager or the State Manager of its state; every change then needs a written reason
create or replace function app.farmers_change_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); staff boolean; cm boolean; step boolean; content boolean;
begin
  if auth.uid() is null then return new; end if;                         -- service role, seeds, migrations
  if tg_op = 'INSERT' then
    new.created_at := now();
    return new;
  end if;
  new.created_at := old.created_at;
  if new.client_id is distinct from old.client_id or new.created_by is distinct from old.created_by then
    raise exception 'a farmer''s client and creator cannot be changed' using errcode = '42501'; end if;
  staff := coalesce(app.farmer_staff(me, new.client_id, old.state_id), false);   -- migration 41: the farmer's state
  cm := coalesce(app.client_account_holder(me, new.client_id), false);          -- migration 44: and its Client Manager
  if not staff then
    if old.status <> 'draft' and not cm then
      raise exception 'this farmer has been submitted: only its Client Manager or the State Manager of its state can change it now' using errcode = '42501'; end if;
    if new.status is distinct from old.status and new.status not in ('draft', 'under_review') then
      raise exception 'a farmer is activated or deactivated by a State Manager' using errcode = '42501'; end if;
  end if;
  -- migration 44: once the client farmer ID is given, every change says why (the steps themselves do not)
  step := (old.status = 'draft' and new.status = 'under_review') or (old.status = 'under_review' and new.status = 'draft')
          or (old.status = 'under_review' and new.status = 'active' and old.verified_at is null);
  content := row(new.name, new.guardian_name, new.village, new.district, app.phone_key(new.phone), new.land_area_acres, new.gi_land_acres,
                 new.photo_consent, new.public_id_consent, new.extra->'notes', new.state_id)
             is distinct from
             row(old.name, old.guardian_name, old.village, old.district, app.phone_key(old.phone), old.land_area_acres, old.gi_land_acres,
                 old.photo_consent, old.public_id_consent, old.extra->'notes', old.state_id);
  if old.farmer_code is not null and (content or (new.status is distinct from old.status and not step))
     and coalesce(btrim(current_setting('app.change_reason', true)), '') = '' then
    raise exception 'this farmer has a Farmer ID: say why you change it' using errcode = '23514'; end if;
  if old.status <> 'active' and new.status = 'active' and old.verified_at is null then
    new.verified_at := now();                                            -- first verification: the server's clock
  else
    new.verified_at := old.verified_at;
    if not (old.status <> 'active' and new.status = 'active') then new.verified_by := old.verified_by; end if;
  end if;
  return new;
end $$;

-- before the state farmer ID: the GI land (migration 43). The possible duplicate is now the State Manager's choice at
-- step 2 (app.farmers_state_id), no longer a refusal here.
create or replace function app.farmers_register_rules() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;                          -- a person acting (not a seed or a migration)
  if tg_op = 'UPDATE' and new.status = 'active' and old.status <> 'active' and old.verified_at is null then
    if new.gi_land_acres is null then
      raise exception 'the GI land (acres) is needed before the Farmer ID' using errcode = '23514'; end if;
  end if;
  return new;
end $$;

-- the ledger of a farmer (E2, E3): a block for each verification, and for every later change with its reason
create or replace function app.farmers_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare actor uuid := coalesce(app.current_user_id(), new.verified_by, new.reviewed_by); was jsonb := '{}'::jsonb; now_ jsonb := '{}'::jsonb;
        k text; why text := nullif(btrim(coalesce(current_setting('app.change_reason', true), '')), '');
        sf public.state_farmers; others int;
begin
  if old.status = 'draft' and new.status = 'under_review' and new.farmer_code is not null then
    -- step 1: the Client Manager verifies; the client farmer ID (given now, or kept from before a send-back)
    perform app.ledger_append(null, null, 'supervisory', actor,
      jsonb_build_object('kind', 'farmer_verified_client', 'step', 1, 'farmer_id', new.id, 'farmer_code', new.farmer_code,
                         'client_id', new.client_id, 'again', old.farmer_code is not null,
                         'name', new.name, 'guardian_name', new.guardian_name, 'village', new.village, 'district', new.district,
                         'land_area_acres', new.land_area_acres, 'gi_land_acres', new.gi_land_acres));
  elsif old.state_farmer_id is null and new.state_farmer_id is not null then
    select * into sf from public.state_farmers where id = new.state_farmer_id;
    select count(*) into others from public.farmers where state_farmer_id = sf.id and id <> new.id;
    if new.status = old.status then
      -- given once to a farmer verified before migration 44
      perform app.ledger_append(null, null, 'supervisory', actor,
        jsonb_build_object('kind', 'state_farmer_id_given', 'farmer_id', new.id, 'farmer_code', new.farmer_code,
                           'state_farmer_code', sf.code, 'state_id', sf.state_id, 'linked', others > 0,
                           'reason', coalesce(nullif(current_setting('app.state_id_backfill', true), ''), 'state farmer IDs introduced')));
    else
      -- step 2: the State Manager verifies the location; the state farmer ID (new, or the same person's)
      perform app.ledger_append(null, null, 'supervisory', actor,
        jsonb_build_object('kind', 'farmer_verified_state', 'step', 2, 'farmer_id', new.id, 'farmer_code', new.farmer_code,
                           'client_id', new.client_id, 'state_farmer_code', sf.code, 'state_id', sf.state_id, 'linked', others > 0,
                           'reason', nullif(btrim(coalesce(current_setting('app.state_link_reason', true), '')), ''),
                           'name', new.name, 'village', new.village, 'district', new.district,
                           'land_area_acres', new.land_area_acres, 'gi_land_acres', new.gi_land_acres, 'photo_consent', new.photo_consent));
    end if;
  elsif old.farmer_code is null and new.farmer_code is not null then
    -- a farmer verified the old way (code issued at activation without a state farmer ID): as before migration 44
    perform app.ledger_append(null, null, 'supervisory', actor,
      jsonb_build_object('kind', 'farmer_verified', 'farmer_id', new.id, 'farmer_code', new.farmer_code, 'client_id', new.client_id,
                         'name', new.name, 'guardian_name', new.guardian_name, 'village', new.village, 'district', new.district,
                         'land_area_acres', new.land_area_acres, 'photo_consent', new.photo_consent));
  elsif old.farmer_code is not null then
    foreach k in array array['name', 'guardian_name', 'village', 'district', 'land_area_acres', 'gi_land_acres', 'photo_consent',
                             'public_id_consent', 'status'] loop
      if to_jsonb(new)->k is distinct from to_jsonb(old)->k then
        was := was || jsonb_build_object(k, to_jsonb(old)->k);
        now_ := now_ || jsonb_build_object(k, to_jsonb(new)->k);
      end if;
    end loop;
    if app.phone_key(new.phone) is distinct from app.phone_key(old.phone) then   -- the number itself stays out of the ledger
      was := was || jsonb_build_object('phone', 'changed'); now_ := now_ || jsonb_build_object('phone', 'changed');
    end if;
    if new.extra->'notes' is distinct from old.extra->'notes' then
      was := was || jsonb_build_object('notes', 'changed'); now_ := now_ || jsonb_build_object('notes', 'changed');
    end if;
    if now_ <> '{}'::jsonb then
      perform app.ledger_append(null, null, 'supervisory', actor,
        jsonb_build_object('kind', 'farmer_changed', 'farmer_id', new.id, 'farmer_code', new.farmer_code, 'before', was, 'after', now_,
                           'reason', why));
    end if;
    -- E4: GI land or mobile changed after the State Manager's verification, by someone else: he accepts it on the register
    if old.verified_at is not null and app.current_user_id() is not null
       and not app.farmer_staff(app.current_user_id(), new.client_id, new.state_id) then
      if new.gi_land_acres is distinct from old.gi_land_acres then
        insert into public.farmer_change_flags (farmer_id, field, before, after, reason, changed_by)
        values (new.id, 'gi_land_acres', old.gi_land_acres::text, new.gi_land_acres::text, why, app.current_user_id()); end if;
      if app.phone_key(new.phone) is distinct from app.phone_key(old.phone) then
        insert into public.farmer_change_flags (farmer_id, field, before, after, reason, changed_by)
        values (new.id, 'phone', '••' || right(app.phone_key(old.phone), 4), '••' || right(app.phone_key(new.phone), 4), why, app.current_user_id()); end if;
    end if;
  end if;
  return new;
end $$;

-- =====================================================================================================================
-- 12 · the register (migration 43, reworked): flags to decide (possible duplicate, no GI land, changed after
--      verification) and a warning (above the expected yield); both IDs; rows open the farmer's page
-- =====================================================================================================================
-- p: {state, season?, client?, district?, status?, flag? (duplicate | no_gi_land | changed | above_yield), q?, limit?, offset?}
create or replace function app.farmer_register(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare st uuid := app.uuid_or_null(p->>'state'); season text; lim int; off int; res jsonb;
begin
  if app.current_user_id() is null or st is null or not (app.is_admin() or st = any (app.my_state_ids())) then
    raise exception 'the farmer register of a state is for its State Manager' using errcode = '42501'; end if;
  season := coalesce(nullif(p->>'season', ''), app.state_season(st));
  lim := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200);
  off := greatest(coalesce((p->>'offset')::int, 0), 0);
  with fa as (
    select f.*, c.name as client_name, sf.code as state_farmer_code
      from public.farmers f join public.clients c on c.id = f.client_id left join public.state_farmers sf on sf.id = f.state_farmer_id
     where app.farmer_home(f.state_id, f.client_id) = st),
  pend as (
    select f.id,
           app.state_candidates(f.id) as cands,
           (select jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'farmer_code', o.farmer_code, 'client', o.client_name) order by o.name)
              from fa o where o.id <> f.id and o.status <> 'inactive' and o.state_farmer_id is null and app.phone10(o.phone) = app.phone10(f.phone)) as others
      from fa f where f.status <> 'inactive' and f.state_farmer_id is null),
  dup as (select * from pend where jsonb_array_length(cands) > 0 or others is not null),
  chg as (select c.farmer_id, count(*) as n from public.farmer_change_flags c where c.accepted_at is null group by c.farmer_id),
  sales as (select x.farmer_id, sum(x.sold_kg) as sold_kg, sum(x.expected_kg) as expected_kg,
                   max(case when x.expected_kg > 0 then x.sold_kg / x.expected_kg end) as ratio
              from app.season_sales(st, season) x group by x.farmer_id),
  rg as (
    select fa.*, d.cands, d.others, s.sold_kg, s.expected_kg, s.ratio, coalesce(g.n, 0) as changes,
           array_remove(array[case when d.id is not null then 'duplicate' end,
                              case when fa.gi_land_acres is null and fa.status <> 'inactive' then 'no_gi_land' end,
                              case when g.n > 0 then 'changed' end], null) as flags,
           array_remove(array[case when s.ratio > 1 then 'above_yield' end], null) as warnings
      from fa left join dup d on d.id = fa.id left join sales s on s.farmer_id = fa.id left join chg g on g.farmer_id = fa.id),
  m as (
    select * from rg r
     where (nullif(p->>'client', '') is null or r.client_id = app.uuid_or_null(p->>'client'))
       and (nullif(p->>'district', '') is null or lower(btrim(r.district)) = lower(btrim(p->>'district')))
       and (nullif(p->>'status', '') is null or r.status::text = p->>'status')
       and (nullif(p->>'flag', '') is null or (p->>'flag') = any (r.flags) or (p->>'flag') = any (r.warnings))
       and (nullif(p->>'q', '') is null or r.name ilike '%' || (p->>'q') || '%' or r.village ilike '%' || (p->>'q') || '%'
            or coalesce(r.farmer_code, '') ilike '%' || (p->>'q') || '%' or coalesce(r.state_farmer_code, '') ilike '%' || (p->>'q') || '%'))
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = st),
    'season', season,
    'seasons', coalesce((select jsonb_agg(distinct s.season_code) from public.scopes s where s.state_id = st), '[]'),
    'total', (select count(*) from m),
    'can_decide', st = any (app.my_state_ids()),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'farmer_code', m.farmer_code, 'state_farmer_code', m.state_farmer_code, 'name', m.name, 'guardian_name', m.guardian_name,
        'village', m.village, 'district', m.district, 'client', m.client_name, 'client_id', m.client_id, 'status', m.status,
        'phone_last4', right(app.phone_key(m.phone), 4),                   -- never the whole number on this screen
        'land_area_acres', m.land_area_acres, 'gi_land_acres', m.gi_land_acres,
        'sold_kg', m.sold_kg, 'expected_kg', m.expected_kg, 'ratio', round(m.ratio, 3),
        'flags', to_jsonb(m.flags), 'warnings', to_jsonb(m.warnings), 'changes', m.changes,
        'candidates', coalesce(m.cands, '[]'::jsonb), 'duplicates', coalesce(m.others, '[]'::jsonb)) order by m.name, m.id)
       from (select * from m order by m.name, m.id limit lim offset off) m), '[]'),
    'cards', jsonb_build_object(
       'farmers', (select count(*) from rg),
       'active', (select count(*) from rg where status = 'active'),
       'under_review', (select count(*) from rg where status = 'under_review'),
       'draft', (select count(*) from rg where status = 'draft'),
       'inactive', (select count(*) from rg where status = 'inactive'),
       'state_ids', (select count(distinct state_farmer_id) from rg where state_farmer_id is not null),
       'gi_acres', coalesce((select round(sum(gi_land_acres), 2) from rg where status = 'active'), 0),
       'land_acres', coalesce((select round(sum(land_area_acres), 2) from rg where status = 'active'), 0),
       'sold_kg', coalesce((select round(sum(sold_kg), 1) from rg), 0),
       'expected_kg', coalesce((select round(sum(expected_kg), 1) from rg where sold_kg is not null), 0),
       'selling', (select count(*) from rg where sold_kg > 0),
       'above_yield', (select count(*) from rg where 'above_yield' = any (warnings)),
       'duplicates', (select count(*) from rg where 'duplicate' = any (flags)),
       'changed', (select count(*) from rg where 'changed' = any (flags)),
       'no_gi_land', (select count(*) from rg where 'no_gi_land' = any (flags)),
       'by_district', coalesce((select jsonb_agg(x order by x.farmers desc, x.district) from (
          select initcap(lower(btrim(district))) as district, count(*) as farmers, coalesce(round(sum(sold_kg), 1), 0) as sold_kg,
                 coalesce(round(sum(gi_land_acres), 2), 0) as gi_acres
            from rg where status <> 'inactive' group by 1 order by 2 desc, 1 limit 12) x), '[]')),
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(distinct jsonb_build_object('id', client_id, 'name', client_name)) from rg), '[]'),
       'districts', coalesce((select jsonb_agg(distinct initcap(lower(btrim(district)))) from rg), '[]')),
    'limit', lim, 'offset', off) into res;
  return res;
end $$;

-- =====================================================================================================================
-- 16 · functions changed from their current definitions (each change marked "migration 44")
-- =====================================================================================================================
-- sees_scope_row: the State Manager reads his state's scopes (he no longer manages them)
CREATE OR REPLACE FUNCTION app.sees_scope_row(p_scope uuid, p_client uuid, p_state uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.is_admin() or app.manages_scope_row(p_client, p_state) or app.views_scope_row(p_scope, p_client)
      or exists (select 1 from app.eff_assignments(app.current_user_id()) a where a.lens = 'scope' and a.scope_id = p_scope)
      or app.watches_state(p_state)   -- migration 44: the State Manager watches (asked last: a stage's own person is answered first)
$function$;

-- sees_whole_scope: the same, whole
CREATE OR REPLACE FUNCTION app.sees_whole_scope(p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.is_admin() or coalesce((select app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id) or app.watches_state(s.state_id)   -- migration 44
                     from public.scopes s where s.id = p_scope), false)
$function$;

-- my_context: a scope of his state is whole to the State Manager, but not his to manage
CREATE OR REPLACE FUNCTION app.my_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; me uuid;
begin
  select * into u from public.app_users where auth_uid = auth.uid() and active;
  if u.id is null then
    return jsonb_build_object('user', null, 'slots', '[]'::jsonb, 'scopes', '[]'::jsonb, 'assignments', '[]'::jsonb);
  end if;
  me := app.current_user_id();                              -- null while today's sign-in code is still owed
  return jsonb_build_object(
    'user', jsonb_build_object('id', u.id, 'role', u.role, 'system_role', u.system_role, 'status', u.status, 'external', u.external,
             'display_name', u.display_name, 'email', u.email, 'phone', u.phone, 'join_date', u.join_date,
             'client_id', u.client_id, 'client_name', (select name from public.clients where id = u.client_id),
             'state_ids', to_jsonb(u.state_ids),
             'can', jsonb_build_object('admin', app.is_admin(), 'hr', app.is_hr() or (app.is_admin() and not app.hr_seat_filled()),
                                       'hr_admin', app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled()),
                                       'audit', app.is_hr_admin() or app.is_admin(), 'oversee', app.is_admin(), 'hr_seat_filled', app.hr_seat_filled(),
                                       'assign', app.can_assign(), 'state_lens', app.is_admin() or app.holds_op_role('state_supervisor'),
                                       'state_seat', app.is_hr_admin(),
                                       'state_manager', app.sm_limited(), 'build_scope', not app.is_admin() and app.holds_op_role('client_account'))),
    'needs_daily_code', me is null,
    'onboarding', (select jsonb_build_object('total', count(*), 'open', count(*) filter (where t.status = 'pending'))
                     from public.onboarding_tasks t where t.employee_id = u.id),
    'assignments', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'lens', a.lens, 'op_role', a.op_role, 'scope_id', a.scope_id,
               'client_id', coalesce(a.client_id, s.client_id), 'state_id', coalesce(a.state_id, s.state_id),
               'client_name', c.name, 'state_name', st.name, 'stages', to_jsonb(a.stages), 'posting', a.posting,
               'season_code', a.season_code, 'ends_on', a.ends_on,
               'label', case a.lens when 'scope' then format('%s · %s · %s', cr.name, s.season_code, s.geography)
                                    when 'client' then c.name else st.name end)
               order by a.lens, c.name, st.name, s.geography)
        from app.eff_assignments(me) a
        left join public.scopes s on s.id = a.scope_id
        left join public.crops cr on cr.id = s.crop_id
        left join public.clients c on c.id = coalesce(a.client_id, s.client_id)
        left join public.states st on st.id = coalesce(a.state_id, s.state_id)), '[]'::jsonb),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', sa.scope_id, 'stage_type', sa.stage_type, 'stage_label', d.label,
               'scope_label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_name', c.name,
               'chain', to_jsonb(s.chain), 'scope_status', s.status) order by s.geography, d.sort_order)
        from public.slot_assignments sa
        join app.eff_assignments(me) a on a.id = sa.assignment_id
        join public.scopes s on s.id = sa.scope_id
        join public.crops cr on cr.id = s.crop_id
        join public.clients c on c.id = s.client_id
        join public.stage_definitions d on d.stage_type = sa.stage_type), '[]'::jsonb),
    'scopes', coalesce((
      select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client_id', s.client_id, 'client_name', c.name,
               'crop_name', cr.name, 'season_code', s.season_code, 'geography', s.geography, 'status', s.status,
               'chain', to_jsonb(s.chain), 'state_id', s.state_id, 'state_name', st.name,
               'manage', app.manages_scope_row(s.client_id, s.state_id), 'build', app.runs_client(s.client_id),
               'whole', app.is_admin() or app.manages_scope_row(s.client_id, s.state_id) or app.views_scope_row(s.id, s.client_id) or app.watches_state(s.state_id))
               order by c.name, s.season_code, s.geography)
        from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
        join public.states st on st.id = s.state_id
       where app.sees_scope_row(s.id, s.client_id, s.state_id)), '[]'::jsonb)
  );
end $function$;

-- assignment_visible: the State Manager sees his state's rosters
CREATE OR REPLACE FUNCTION app.assignment_visible(a assignments)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select a.employee_id = app.current_user_id() or app.is_admin() or app.is_hr()
      or (a.lens = 'scope' and (app.i_manage_scope(a.scope_id) or app.watches_scope(a.scope_id)))   -- migration 44
      or (a.lens = 'client' and app.can_manage_client(a.client_id))
      or (a.lens = 'state' and a.state_id = any(app.my_state_ids()))
$function$;

-- assign: a stage goes only to an operational person based in the scope's state, or to its Client Manager himself
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
  if p_employee = me and not (p_lens = 'scope' and app.runs_client((select s.client_id from public.scopes s where s.id = p_target))) then
    raise exception 'you cannot assign yourself' using errcode = '42501'; end if;   -- migration 44: a Client Manager may take a stage himself
  if p_lens = 'scope' and app.stage_refusal(p_employee, p_target) is not null then   -- migration 44 (A2)
    raise exception '%', app.stage_refusal(p_employee, p_target) using errcode = '42501'; end if;
  if app.user_is_admin(p_employee) then
    raise exception 'an admin oversees and holds no assignment' using errcode = '42501'; end if;
  -- Veda, 12 Oct 2026: "HR should never be the State Manager. HR can govern the state wrt onboarding" (migration 39)
  if exists (select 1 from public.app_users where id = p_employee and system_role in ('hr_admin', 'hr_resource')) then
    raise exception 'HR holds no seat: an HR person works for states as HR (HR states), not as a manager or operator' using errcode = '42501'; end if;
  if app.sm_limited() and not app.sm_sees(p_employee) then   -- migration 41
    raise exception 'this person is not in your state: a State Manager gives seats to the people of his own state' using errcode = '42501'; end if;
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

-- set_stages: no new stage for a person the roster may not hold
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
  return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(app.coverage_gaps(a.scope_id)));
end $function$;

-- end_assignment: the Client Manager may take himself off a stage
CREATE OR REPLACE FUNCTION app.end_assignment(p_assignment uuid, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); a public.assignments; gaps public.stage_type[] := '{}';
begin
  select * into a from public.assignments where id = p_assignment;
  if a.id is null then raise exception 'assignment not found' using errcode = 'P0002'; end if;
  if not app.may_assign(a.lens, a.op_role, coalesce(a.scope_id, a.client_id, a.state_id)) then
    raise exception 'you cannot end this assignment: it is outside what you manage' using errcode = '42501'; end if;
  if not a.active then raise exception 'this assignment has already ended' using errcode = '23514'; end if;
  if a.employee_id = me and not app.is_admin() and not (a.lens = 'scope' and app.i_manage_scope(a.scope_id)) then   -- migration 44
    raise exception 'you cannot end your own assignment' using errcode = '42501'; end if;
  update public.assignments set active = false, end_reason = coalesce(nullif(btrim(p_reason), ''), 'ended') where id = a.id;
  if a.lens = 'scope' then
    delete from public.slot_assignments where assignment_id = a.id;
    gaps := array(select g from unnest(app.coverage_gaps(a.scope_id)) g where g = any(a.stages));
  end if;
  select * into a from public.assignments where id = a.id;
  return jsonb_build_object('assignment', to_jsonb(a), 'gaps', to_jsonb(gaps));
end $function$;

-- slots_assignment: a roster row written directly follows the same rule
CREATE OR REPLACE FUNCTION app.slots_assignment()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- migration 41: a seat inserted directly (not through app.assign) follows the same person rules
    if auth.uid() is not null and coalesce(current_setting('app.assigning', true), '') <> 'on' then
      perform app.assert_assignable(new.user_id);
      if app.stage_refusal(new.user_id, new.scope_id) is not null then   -- migration 44 (A2)
        raise exception '%', app.stage_refusal(new.user_id, new.scope_id) using errcode = '42501'; end if;
    end if;
    insert into public.assignments (employee_id, lens, op_role, scope_id, created_by, stages)
    values (new.user_id, 'scope', 'operator', new.scope_id, app.current_user_id(), array[new.stage_type]) returning * into a;
  end if;
  new.assignment_id := a.id;
  return new;
end $function$;

-- ready_to_assign: ready to assign on a scope: only who its roster may hold
CREATE OR REPLACE FUNCTION app.ready_to_assign(p_lens assignment_lens, p_target uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
       and (p_lens <> 'scope' or app.stage_refusal(u.id, p_target) is null)   -- migration 44
       and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = p_lens
                         and p_target in (a.scope_id, a.client_id, a.state_id))), '[]'::jsonb);
end $function$;

-- people_page: the Client Manager's list; test data hidden; whether "Assign" is offered
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
       and (full_view or u.external or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))   -- migration 41
       and (full_view or u.external or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids())))   -- migration 44 (A4)
       and not u.test_data                                                                                            -- migration 44 (G7)
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
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active),
             'assignable', app.may_offer_assign(f.id)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

-- people_directory: the same
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
     where (not u.external and (full_view or u.status <> 'offboarded') and (full_view or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))
            and (full_view or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids()))) and not u.test_data   -- migration 44
            and (not app.is_hr() or app.hr_full() or u.id = app.current_user_id() or o.base_state_id = any(app.my_hr_states())))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $function$;

-- employee_profile: the same, for one person
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
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded' and (not app.sm_limited() or app.sm_sees(u.id)) and (not app.cm_limited() or u.id = any (app.cm_seen_ids())) and not u.test_data)))
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
      'assign', app.may_offer_assign(u.id),   -- migration 44
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;

-- joiners_page: test data hidden
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
     where not u.external and u.system_role <> 'admin' and not u.test_data   -- migration 44
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

-- hr_pipeline: test data hidden
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
         where not u.external and app.hr_covers(u.id) and not u.test_data   -- migration 44
           and (u.status in ('invited', 'onboarding') or (u.status = 'active' and tk.total > tk.done))
      ) x), '[]'::jsonb);
end $function$;

-- farmers_two_steps: the client farmer ID is given at step 1 (the Client Manager); step 2 is recognised by the State Manager's verification
CREATE OR REPLACE FUNCTION app.farmers_two_steps()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); st text;
begin
  if tg_op = 'INSERT' then
    new.state_id := coalesce(new.state_id, (select c.state_id from public.clients c where c.id = new.client_id));
    if auth.uid() is not null then new.reviewed_by := null; new.reviewed_at := null; end if;   -- a person cannot pre-verify
  end if;
  if new.state_id is not null and (tg_op = 'INSERT' or new.state_id is distinct from old.state_id)
     and not (new.state_id = any (app.client_states(new.client_id))) then
    raise exception 'a farmer''s state must be one the client works in' using errcode = '23514'; end if;
  if auth.uid() is null then return new; end if;                         -- service role, seeds, migrations
  if tg_op = 'INSERT' then
    if new.status <> 'draft' then
      raise exception 'a farmer is added as a draft: the Client Manager verifies it' using errcode = '42501'; end if;
    return new;
  end if;

  if new.state_id is null and old.state_id is not null then
    raise exception 'a farmer''s state cannot be left blank' using errcode = '23514'; end if;   -- migration 41
  if new.state_id is distinct from old.state_id and old.status <> 'draft' then
    raise exception 'a farmer''s state is chosen before the Client Manager verifies' using errcode = '42501'; end if;
  if new.reviewed_by is distinct from old.reviewed_by or new.reviewed_at is distinct from old.reviewed_at then
    if not (old.status = 'draft' and new.status = 'under_review') and not (old.status = 'under_review' and new.status = 'draft') then
      raise exception 'the first verification is recorded by the server' using errcode = '42501'; end if;
  end if;

  -- step 1: the Client Manager verifies
  if old.status = 'draft' and new.status = 'under_review' then
    if me is null or not app.client_account_holder(me, new.client_id) then
      raise exception 'the Client Manager of this client verifies a farmer first' using errcode = '42501'; end if;
    new.reviewed_by := me; new.reviewed_at := now();
    if new.farmer_code is null then new.farmer_code := app.next_farmer_code(new.client_id); end if;   -- migration 44: the client farmer ID
  end if;
  -- sent back: step 1 has to be done again
  if old.status = 'under_review' and new.status = 'draft' then
    new.reviewed_by := null; new.reviewed_at := null;
  end if;
  -- step 2: the State Manager of the farmer's state checks the location and issues the Farmer ID
  -- migration 41: on EVERY route to a first Farmer ID (not only from under review), and with no state the client's
  if new.status = 'active' and old.status <> 'active' and old.verified_at is null then   -- migration 44: the client ID now comes at step 1
    if old.status <> 'under_review' then
      raise exception 'the Client Manager has not verified this farmer yet' using errcode = '42501'; end if;
    st := null;
    if true then
      if not app.state_supervisor_of(new.verified_by, coalesce(new.state_id, app.client_home(new.client_id))) then
        select name into st from public.states where id = coalesce(new.state_id, app.client_home(new.client_id));
        raise exception 'only the State Manager of % verifies this farmer''s location', coalesce(st, 'the farmer''s state') using errcode = '42501'; end if;
      if new.reviewed_by is null then
        raise exception 'the Client Manager has not verified this farmer yet' using errcode = '42501'; end if;
      if new.reviewed_by = new.verified_by then
        raise exception 'the second verification is by another person than the first' using errcode = '42501'; end if;
    end if;
  end if;
  -- a farmer once verified and later deactivated is reactivated by the State Manager of its state only
  if new.status = 'active' and old.status <> 'active' and old.verified_at is not null
     and not app.state_supervisor_of(new.verified_by, coalesce(new.state_id, app.client_home(new.client_id))) then
    raise exception 'a farmer is activated or deactivated by the State Manager of its state' using errcode = '42501'; end if;
  return new;
end $function$;

-- state_home: possible duplicates waiting for his choice, changes to accept; the yield is a warning
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
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'status', s.status) order by s.status, c.name)
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

-- state_ledger_page: the role the signer held then (D6)
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
    select l.*, f.footprint_code, f.stage_type,
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
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role)
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

-- ledger_page: the role the signer held then (D6)
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
    select l.*, f.footprint_code, f.stage_type, coalesce(f.client_id, s.client_id) as client_id, coalesce(l.scope_id, f.scope_id) as the_scope
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
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role)
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset);
end $function$;

-- save_opening: one State Manager per state
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
  if v_role = 'state_manager' and v_pos > 1 then   -- migration 44 (G3, Veda 14 Oct)
    raise exception 'one State Manager per state: a State Manager opening has 1 position' using errcode = '23514'; end if;

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

-- openings_summary: closed openings are left out of every total
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
               select jsonb_object_agg(k, (select coalesce(sum((r->>k)::int), 0) from jsonb_array_elements(rows) r where r->>'state_id' = s.sid::text and r->>'status' <> 'closed'))
                 from unnest(keys) k) order by s.sname)
        from (select distinct (r->>'state_id')::uuid as sid, r->>'state_name' as sname from jsonb_array_elements(rows) r) s), '[]'::jsonb),
    'total', (select jsonb_object_agg(k, (select coalesce(sum((r->>k)::int), 0) from jsonb_array_elements(rows) r where r->>'status' <> 'closed')) from unnest(keys) k),   -- migration 44 (G5)
    -- people joining or joined who are on no opening (added before openings, or without one)
    'not_linked', (select count(*) from public.app_users u left join public.employee_org e on e.employee_id = u.id
                    where not u.external and u.system_role <> 'admin' and u.status in ('invited', 'onboarding', 'active') and e.opening_id is null
                      and (not app.is_hr() or app.hr_covers(u.id))),
    'can_plan', app.acts_as_hr(),
    'can_seat', app.is_hr_admin() or app.is_sm_deputy());
end $function$;

-- scopes_state_guard: the database owner may put a practice scope back to draft (section 10)
CREATE OR REPLACE FUNCTION app.scopes_state_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;
    if old.status = 'active' and new.status = 'draft' and coalesce(current_setting('app.reverse_activation', true), '') = 'on'
       and current_user not in ('authenticated', 'anon') then
      new.activated_at := null; return new;                              -- migration 44: the owner's correction of practice data
    end if;
    if old.status = 'active' and new.status = 'draft' then
      raise exception 'an active scope cannot go back to draft; close it and open a new scope' using errcode = '42501'; end if;
    if old.status <> 'draft' and (new.tolerances is distinct from old.tolerances or new.geography is distinct from old.geography) then
      raise exception 'a scope''s place and tolerances are frozen after activation; open a new scope' using errcode = '42501'; end if;
    if old.activated_at is not null then
      new.activated_at := old.activated_at;
    elsif current_user in ('authenticated', 'anon') then
      new.activated_at := null;                                          -- scopes_guard stamps now() at activation
    end if;
  elsif current_user in ('authenticated', 'anon') then
    new.created_at := now();
    new.activated_at := null;
  end if;
  return new;
end $function$;

-- footprint_detail: a record names both farmer IDs
CREATE OR REPLACE FUNCTION app.footprint_detail(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; vd record; name_of jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  return jsonb_build_object(
    'footprint', to_jsonb(f),
    'stage_label', (select label from public.stage_definitions where stage_type = f.stage_type),
    'created_by_name', (select display_name from public.app_users where id = f.created_by),
    'verified_by_name', (select display_name from public.app_users where id = f.verified_by),
    'farmer', (select jsonb_build_object('name', name, 'farmer_code', farmer_code, 'village', village,
                 'state_farmer_code', (select sf.code from public.state_farmers sf where sf.id = farmers.state_farmer_id))   -- migration 44
                 from public.farmers where id = f.farmer_id),
    'prev', (select jsonb_build_object('id', p.id, 'footprint_code', p.footprint_code, 'stage_type', p.stage_type)
               from public.footprints p where p.id = f.prev_footprint_id),
    'available_kg', app.available_qty(f.id),
    'qc', (select to_jsonb(v) from public.qc_verdicts v where v.footprint_id = f.id),
    'market_verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'seal', (select to_jsonb(q) from public.qr_seals q where q.footprint_id = f.id),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'status', fl.status, 'created_at', fl.created_at,
               'raised_by_name', (select display_name from public.app_users where id = fl.raised_by)) order by fl.created_at)
               from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $function$;

-- incoming_records: who may see the list is asked once, not for every lot (the same answer: every row has this scope and stage)
CREATE OR REPLACE FUNCTION app.incoming_records(p_scope uuid, p_stage stage_type)
 RETURNS SETOF footprints
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select f.*
  from public.footprints f
  where f.scope_id = p_scope
    and f.stage_type = app.chain_prev(p_scope, p_stage)
    and f.status in ('pending','verified')
    and f.lot_closed = false
    and f.split_into_grades = false
    and app.available_qty(f.id) > 0
    and (auth.uid() is null or (select app.can_see_footprint(p_scope, app.chain_prev(p_scope, p_stage))))   -- service role: unfiltered; asked once (migration 44)
  order by f.created_at
$function$;


-- =====================================================================================================================
-- 13 · rules on tables
-- =====================================================================================================================
-- a roster row is written only by the scope's Client Manager (the state lens no longer manages: section 1)
-- (slots_write already asks app.i_manage_scope, which now means the Client Manager)
-- assignments on a scope of his state stay readable to the State Manager
drop policy assignments_read on public.assignments;
create policy assignments_read on public.assignments for select to authenticated using (
  (employee_id = app.current_user_id()) or app.is_admin() or (app.is_hr() and app.hr_covers(employee_id))
  or ((lens = 'scope') and (app.i_manage_scope(scope_id) or app.watches_scope(scope_id)))
  or ((lens = 'client') and app.can_manage_client(client_id))
  or ((lens = 'state') and (state_id = any (app.my_state_ids()))));

-- A4: a Client Manager reads his client's people and the eligible pool of his state; a test person is nobody's but the admin's
drop policy users_read on public.app_users;
create policy users_read on public.app_users for select to authenticated using (
  (auth_uid = auth.uid()) or (select app.is_admin())
  or (not test_data and (
       ((not external) and (((select app.is_hr()) and ((select app.hr_full()) or (id = (select app.current_user_id()))
                                                      or (system_role = any (array['hr_admin'::system_role, 'hr_resource'::system_role])) or app.hr_covers(id)))
                            or ((select app.can_assign()) and (status <> 'offboarded'::employee_status)
                                and ((not (select app.sm_limited())) or (id in (select unnest(app.sm_seen_ids()))))
                                and ((not (select app.cm_limited())) or (id in (select unnest(app.cm_seen_ids())))))))
       or (external and app.manages_viewer(id)))));

drop policy employee_org_read on public.employee_org;
create policy employee_org_read on public.employee_org for select to authenticated using (
  (employee_id = (select app.current_user_id())) or (select app.is_admin()) or ((select app.is_hr()) and app.hr_covers(employee_id))
  or ((select app.can_assign()) and ((not (select app.sm_limited())) or (employee_id in (select unnest(app.sm_seen_ids()))))
      and ((not (select app.cm_limited())) or (employee_id in (select unnest(app.cm_seen_ids()))))));

-- the farmer's history reads the ledger by farmer: an index, no row changed
create index if not exists ledger_farmer_idx on public.ledger ((payload->>'farmer_id')) where payload ? 'farmer_id';

-- =====================================================================================================================
-- 14 · who may call what
-- =====================================================================================================================
revoke execute on function app.watches_state(uuid), app.watches_scope(uuid), app.stage_refusal(uuid, uuid), app.roster_pool(uuid, text),
  app.activation_missing(uuid), app.scopes_staffed(), app.cm_limited(), app.cm_seen_ids(), app.may_offer_assign(uuid),
  app.working_role_at(uuid, timestamptz), app.mark_test_person(uuid, text), app.new_state_farmer(uuid, uuid), app.state_candidates(uuid),
  app.farmers_state_id(), app.verify_farmer_state(uuid, uuid, text), app.give_missing_state_ids(text), app.change_farmer(uuid, jsonb, text),
  app.accept_farmer_change(uuid), app.farmer_history(uuid), app.above_yield(uuid, text), app.pending_duplicate(public.farmers),
  app.practice_fix_14oct(), app.state_choice(uuid) from public, anon, authenticated;
-- helpers the rules evaluate as the caller (each answers about the caller)
grant execute on function app.watches_state(uuid), app.watches_scope(uuid), app.cm_limited(), app.cm_seen_ids() to authenticated;
-- what the screens ask
grant execute on function app.roster_pool(uuid, text), app.activation_missing(uuid), app.verify_farmer_state(uuid, uuid, text),
  app.change_farmer(uuid, jsonb, text), app.accept_farmer_change(uuid), app.farmer_history(uuid), app.state_choice(uuid) to authenticated;
-- app.mark_test_person, app.give_missing_state_ids and app.practice_fix_14oct: the database owner only

-- =====================================================================================================================
-- 15 · data, once
-- =====================================================================================================================
-- G2 (Veda, 14 Oct): open steps of every checklist get their due date again by today's rule (join date + the step's
-- offset, never sooner than today + 3); each person's line in the Audit log
do $$
declare r record;
begin
  for r in select u.id, u.display_name, count(*) as k
             from public.onboarding_tasks t join public.app_users u on u.id = t.employee_id
            where t.status = 'pending' and u.status <> 'offboarded'
              and t.due_on is distinct from greatest(coalesce(u.join_date + t.due_offset_days, t.due_on), app.today() + 3)
            group by u.id, u.display_name loop
    update public.onboarding_tasks t set due_on = greatest(coalesce(u.join_date + t.due_offset_days, t.due_on), app.today() + 3)
      from public.app_users u
     where u.id = t.employee_id and t.employee_id = r.id and t.status = 'pending'
       and t.due_on is distinct from greatest(coalesce(u.join_date + t.due_offset_days, t.due_on), app.today() + 3);
    insert into public.audit_log (actor, action, target, detail)
    values (null, 'due_dates_recalculated', r.id, jsonb_build_object('name', r.display_name, 'steps', r.k, 'by', 'migration 44',
            'rule', 'join date + the step''s offset, not before today + 3'));
  end loop;
end $$;

-- E1: every farmer a State Manager has verified gets his state farmer ID (each with a ledger block)
do $$ begin perform app.give_missing_state_ids('state farmer IDs introduced (migration 44, Veda 14 Oct 2026)'); end $$;
