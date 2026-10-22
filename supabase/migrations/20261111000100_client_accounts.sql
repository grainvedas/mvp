-- Migration 67 (Phase 3, release 1 of Veda's combined brief of 19 Oct 2026: Parts A and B, with Phase 2's B4).
-- Client accounts: the client's owner, viewer and operator; one central rule for what a client account may write;
-- isolation between clients; a scope's delivery model and GI authorised-user number.
--
--   B4  (Phase 2, missed there) a scope's delivery model: managed (GrainVeda's people record), hybrid (the client's
--       people record and GrainVeda verifies), self_run (the client runs it and GrainVeda audits): scopes.delivery_model,
--       set by the Client Manager (app.set_scope_delivery); and, for a GI crop, the client's GI authorised-user number
--       for that crop with its file (app.set_scope_gi_user; the file in client-docs under <client>/scopes/<scope>/)
--   A1  three kinds of client account (public.client_accounts): the owner (made by the admin once the client's first
--       Active is approved; more than one allowed), the viewer (made by an owner for any of its scopes, or by the Client
--       Manager for one state's scopes only), the operator (made by the Client Manager; holds stages on Hybrid and
--       Self-run scopes of its own client only). A login is made as before (create-user, kind viewer): the creator
--       first says what the account is (app.prepare_client_account) and app.add_client_viewer makes exactly that
--   A2  every write from a client account is refused except its kind's list (app.client_may, asked by the trigger
--       a00_client_login_reads_only on every table it guards): the owner's buyer links (revoking one also while the
--       client is suspended), the client's written acceptance on a lab record, its viewers, its renewals, which viewers
--       may download internal copies; the operator's stage work; the viewer nothing. A record made by client staff says
--       so (footprints.client_staff) and is verified only by GrainVeda. Accounts: Active / Suspended / Removed, set by
--       whoever may make that account (the admin for owners), each change in the Audit log
--   A3  every existing client login becomes a viewer of all its client's scopes; the admin may promote one to owner
--   A4  a suspended client's owner reads and downloads only (revoking a buyer link excepted); an ended client's accounts
--       read and export (switched off after the lifetime period: release 5)
--   B   a client account sees only its own client, and a viewer only the scopes chosen for it (app.account_reaches):
--       the scopes it reads, its farmers, its client record's states, its notices
-- Additive: new columns, tables and functions; existing client logins get an account row (new rows only); replaced
-- from their own text, each change named: the trigger function of a00_client_login_reads_only, the evidence store's
-- upload rule, app.client_owner_of (now the owner only), app.views_scope_row, app.stage_refusal, app.assignments_guard,
-- app.roster_pool, app.add_client_viewer, app.may_internal_copy, app.client_farmers, app.client_view, app.clients_page,
-- app.client_identity, app.notify_client, app.propose_client_renewal, app.create_buyer_link, app.revoke_buyer_link,
-- app.may_write_client_object, app.may_read_client_file, app.manages_viewer, app.my_context.
select set_config('app.change_path', 'migration 67', true);

-- 1 · B4: the scope's delivery model and GI authorised-user number ----------------------------------------------------
alter table public.scopes add column if not exists delivery_model text not null default 'managed'
  check (delivery_model in ('managed', 'hybrid', 'self_run'));
alter table public.scopes add column if not exists gi_user_no text
  check (gi_user_no is null or length(btrim(gi_user_no)) between 2 and 40);
alter table public.scopes add column if not exists gi_user_file text
  check (gi_user_file is null or gi_user_file ~ '^[0-9a-f-]{36}/scopes/[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$');
alter table public.scopes add column if not exists gi_user_sha256 text check (gi_user_sha256 is null or gi_user_sha256 ~ '^[0-9a-f]{64}$');

-- the four columns change only through their functions (app.scope_settings set there, for that statement)
create or replace function app.scopes_settings_guard() returns trigger
language plpgsql as $$
begin
  if coalesce(current_setting('app.scope_settings', true), '') = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    if new.delivery_model <> 'managed' or new.gi_user_no is not null or new.gi_user_file is not null then
      raise exception 'delivery model and GI authorised user: set on the scope''s page once it is saved' using errcode = '42501'; end if;
    return new;
  end if;
  if new.delivery_model is distinct from old.delivery_model or new.gi_user_no is distinct from old.gi_user_no
     or new.gi_user_file is distinct from old.gi_user_file or new.gi_user_sha256 is distinct from old.gi_user_sha256 then
    raise exception 'delivery model and GI authorised user: set on the scope''s page by the Client Manager' using errcode = '42501'; end if;
  return new;
end $$;
create trigger scopes_a1f_settings before insert or update on public.scopes for each row execute function app.scopes_settings_guard();

-- 2 · A1: client accounts -------------------------------------------------------------------------------------------
create table if not exists public.client_accounts (
  user_id uuid primary key references public.app_users(id),
  client_id uuid not null references public.clients(id),
  kind text not null check (kind in ('owner', 'viewer', 'operator')),
  status text not null default 'active' check (status in ('active', 'suspended', 'removed')),
  -- what a viewer sees: its whole client, one state's scopes, or the scopes chosen (public.client_account_scopes)
  reach text not null default 'client' check (reach in ('client', 'state', 'scopes')),
  state_id uuid references public.states(id),
  internal_copies boolean not null default false,        -- a viewer may download internal copies (the owner allows it)
  made_by uuid references public.app_users(id),
  made_as text not null check (made_as in ('admin', 'owner', 'client_manager', 'migration')),
  created_at timestamptz not null default now(),
  status_reason text, status_by uuid references public.app_users(id), status_at timestamptz,
  check ((kind = 'viewer') or (reach = 'client' and state_id is null and not internal_copies)),
  check ((reach = 'state') = (state_id is not null)));
create index if not exists client_accounts_client on public.client_accounts (client_id);
create table if not exists public.client_account_scopes (
  user_id uuid not null references public.client_accounts(user_id),
  scope_id uuid not null references public.scopes(id),
  added_by uuid references public.app_users(id),
  added_at timestamptz not null default now(),
  primary key (user_id, scope_id));
-- what a creator has said the next login of that email is (app.prepare_client_account); used once by app.add_client_viewer
create table if not exists public.client_account_intents (
  id uuid primary key default gen_random_uuid(),
  email_key text not null,
  client_id uuid not null references public.clients(id),
  kind text not null check (kind in ('owner', 'viewer', 'operator')),
  reach text not null default 'client' check (reach in ('client', 'state', 'scopes')),
  state_id uuid references public.states(id),
  scope_ids uuid[] not null default '{}',
  internal_copies boolean not null default false,
  made_by uuid not null references public.app_users(id),
  made_as text not null,
  created_at timestamptz not null default now(),
  used_at timestamptz);
alter table public.client_accounts enable row level security;
alter table public.client_account_scopes enable row level security;
alter table public.client_account_intents enable row level security;
revoke all on public.client_accounts, public.client_account_scopes, public.client_account_intents from public, anon, authenticated;
create trigger zz_change_log after insert or update or delete on public.client_accounts for each row execute function app.log_change('user_id');
create trigger zz_change_log after insert or update or delete on public.client_account_scopes for each row execute function app.log_change('user_id');
create trigger zz_change_log after insert or update or delete on public.client_account_intents for each row execute function app.log_change('id');

-- 3 · A3: today's client logins become viewers of their whole client -------------------------------------------------------
insert into public.client_accounts (user_id, client_id, kind, status, reach, made_by, made_as, created_at)
select distinct on (u.id) u.id, a.client_id, 'viewer',
       case u.status when 'active' then 'active' when 'offboarded' then 'removed' else 'suspended' end,
       'client', u.created_by, 'migration', u.created_at
  from public.app_users u join public.assignments a on a.employee_id = u.id and a.lens = 'client' and a.op_role = 'client_viewer'
 where u.external
 order by u.id, a.active desc, a.created_at desc
on conflict (user_id) do nothing;

-- a client view given another way (the service role, a seed, a test of before): a viewer of the whole client, as A3
create or replace function app.assignments_client_account() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lens = 'client' and new.op_role = 'client_viewer'
     and exists (select 1 from public.app_users u where u.id = new.employee_id and u.external)
     and not exists (select 1 from public.client_accounts ca where ca.user_id = new.employee_id) then
    insert into public.client_accounts (user_id, client_id, kind, reach, made_by, made_as)
    values (new.employee_id, new.client_id, 'viewer', 'client', new.created_by, 'migration');
  end if;
  return new;
end $$;
create trigger assignments_z1_client_account after insert on public.assignments for each row execute function app.assignments_client_account();

-- 4 · who is who ------------------------------------------------------------------------------------------------------
create or replace function app.my_client_account() returns public.client_accounts
language sql stable security definer set search_path = public as $$
  select ca.* from public.client_accounts ca join public.app_users u on u.id = ca.user_id
   where ca.user_id = app.current_user_id() and ca.status = 'active' and u.status = 'active' and u.external
$$;
-- a client's owner (A1): the only client account with write rights beyond its stages
create or replace function app.client_owner_check(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select a.kind = 'owner' and a.client_id = p_client from app.my_client_account() a where a.user_id is not null), false)
$$;
-- any of the client's owners and viewers (reading the client's record, within what each reaches)
create or replace function app.client_reader_of(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select a.kind in ('owner', 'viewer') and a.client_id = p_client from app.my_client_account() a where a.user_id is not null), false)
$$;
-- B: does this account see this scope? an owner and a whole-client viewer: every scope of its client
create or replace function app.account_reaches(p_user uuid, p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_accounts ca join public.scopes s on s.id = p_scope and s.client_id = ca.client_id
                  where ca.user_id = p_user and ca.status = 'active' and ca.kind in ('owner', 'viewer')
                    and (ca.kind = 'owner' or ca.reach = 'client'
                         or (ca.reach = 'state' and s.state_id = ca.state_id)
                         or (ca.reach = 'scopes' and exists (select 1 from public.client_account_scopes x where x.user_id = ca.user_id and x.scope_id = s.id))))
$$;
-- the states an account's reach touches (its client record, its notices)
create or replace function app.account_states(p_user uuid, p_client uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array(
    select cs.state_id from public.client_states cs join public.client_accounts ca on ca.user_id = p_user and ca.client_id = cs.client_id
     where cs.client_id = p_client and ca.status = 'active'
       and (ca.kind = 'owner' or ca.reach = 'client' or (ca.reach = 'state' and cs.state_id = ca.state_id)
            or (ca.reach = 'scopes' and exists (select 1 from public.client_account_scopes x join public.scopes s on s.id = x.scope_id
                                                  where x.user_id = ca.user_id and s.state_id = cs.state_id)))), '{}')
$$;
-- B: which of the client's farmers an account sees: an owner and a whole-client viewer all; a state's viewer that state's
-- farmers and those who sold into its scopes; a viewer of chosen scopes those who sold into them
create or replace function app.account_sees_farmer(p_user uuid, p_farmer uuid, p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_accounts ca
                  where ca.user_id = p_user and ca.client_id = p_client and ca.status = 'active' and ca.kind in ('owner', 'viewer')
                    and (ca.kind = 'owner' or ca.reach = 'client' or (ca.reach = 'state' and p_state = ca.state_id)
                         or exists (select 1 from public.footprints f where f.farmer_id = p_farmer and f.client_id = p_client
                                      and app.account_reaches(p_user, f.scope_id))))
$$;
-- a client operator for this scope: an active operator of the scope's client, on a Hybrid or Self-run scope (A1)
create or replace function app.client_operator_for(p_user uuid, p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_accounts ca join public.scopes s on s.id = p_scope and s.client_id = ca.client_id
                  where ca.user_id = p_user and ca.kind = 'operator' and ca.status = 'active' and s.delivery_model in ('hybrid', 'self_run'))
$$;
-- may this account download internal copies? the owner; a viewer the owner allowed. An operator never (A1)
create or replace function app.client_internal_ok() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select a.kind = 'owner' or (a.kind = 'viewer' and a.internal_copies) from app.my_client_account() a where a.user_id is not null), false)
$$;
-- A4: the owner acts while the client is Active in the state concerned (or, for an act of the whole client, in one state)
create or replace function app.client_owner_active(p_client uuid, p_state uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.status = 'active'
                   and (p_state is null or cs.state_id = p_state))
$$;

-- A1: "at or after the client's first activation": Active (or suspended since) in a state; a client of before kept Active counts
create or replace function app.client_was_activated(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.status in ('active', 'suspended'))
$$;

-- A2: THE ONE RULE. May the signed-in client account do this act? (Not a client account: the question is not asked.)
--   owner     buyer_link (create), buyer_link_revoke (also while suspended), acceptance, manage_viewers, renewal,
--             viewer_internal, showcase (release 5)
--   operator  stage (its stages' work; which stage and scope is the stage rules' own question)
--   viewer    nothing
create or replace function app.client_may(p_act text, p_client uuid default null, p_state uuid default null) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare a public.client_accounts;
begin
  a := app.my_client_account();
  if a.user_id is null then return false; end if;
  if p_client is not null and a.client_id <> p_client then return false; end if;
  if a.kind = 'owner' then
    if p_act = 'buyer_link_revoke' then return true; end if;
    if p_act not in ('buyer_link', 'acceptance', 'manage_viewers', 'renewal', 'viewer_internal', 'showcase') then return false; end if;
    return app.client_owner_active(a.client_id, p_state);
  end if;
  if a.kind = 'operator' then return p_act = 'stage'; end if;
  return false;
end $$;

-- 5 · A2: the trigger on every guarded table asks the one rule -----------------------------------------------------------
-- An operator's stage work writes these tables (a save makes its packs, cartons, links and ledger rows as the caller);
-- an owner's act writes buyer_links or attachments inside its own function, which names the act (app.client_act).
create or replace function app.client_table_act(p_table text) returns text
language sql immutable as $$
  select case when p_table in ('footprints', 'footprint_returns', 'footprint_links', 'attachments', 'flags', 'corrections', 'qr_seals',
                               'qc_verdicts', 'qc_samples', 'lot_payments', 'sale_terms', 'bills_of_lading', 'deliveries', 'export_documents',
                               'label_prints', 'release_events', 'lot_closures', 'net_weight_checks', 'warehouse_inspections',
                               'warehouse_bags_out', 'packs', 'cartons', 'farmers', 'farmer_gap', 'farmer_proposals') then 'stage' end
$$;

-- 6 · footprints: made by client staff (A2.5) ------------------------------------------------------------------------------
alter table public.footprints add column if not exists client_staff boolean not null default false;
create or replace function app.footprints_client_staff() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.client_staff := coalesce(app.is_client_login(), false);
    return new;
  end if;
  new.client_staff := old.client_staff;                               -- the server's; never changed
  -- GrainVeda's verification is still required: a record by client staff is verified by GrainVeda's people
  if new.status = 'verified' and old.status is distinct from 'verified' and old.client_staff and app.is_client_login() then
    raise exception 'a record made by the client''s own staff is verified by GrainVeda' using errcode = '42501'; end if;
  return new;
end $$;
create trigger footprints_a05_client_staff before insert or update on public.footprints for each row execute function app.footprints_client_staff();

-- 7 · B4: setting the delivery model and the GI authorised user ---------------------------------------------------------------
create or replace function app.set_scope_delivery(p_scope uuid, p_model text, p_reason text default null) returns public.scopes
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; v_old text;
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.can_access_scope(p_scope) then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.runs_client(sc.client_id) or app.is_client_login() then
    raise exception 'delivery model: set by the scope''s Client Manager' using errcode = '42501'; end if;
  if sc.status = 'closed' then raise exception 'this scope is closed: its season has ended' using errcode = '42501'; end if;
  if p_model not in ('managed', 'hybrid', 'self_run') then raise exception 'delivery model: managed, hybrid or self-run' using errcode = '22023'; end if;
  if p_model = sc.delivery_model then return sc; end if;
  if sc.status <> 'draft' and length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'delivery model: say why it changes (10 characters or more)' using errcode = '23514'; end if;
  if p_model = 'managed' and exists (select 1 from public.assignments a join public.client_accounts ca on ca.user_id = a.employee_id and ca.kind = 'operator'
                                      where a.active and a.lens = 'scope' and a.scope_id = sc.id) then
    raise exception 'delivery model: the client''s own staff still hold stages here: end their stages first' using errcode = '23514'; end if;
  v_old := sc.delivery_model;
  perform set_config('app.scope_settings', 'on', true);
  update public.scopes set delivery_model = p_model where id = sc.id returning * into sc;
  perform set_config('app.scope_settings', '', true);
  perform app.audit('scope_delivery_model', sc.id, jsonb_build_object('from', v_old, 'to', p_model, 'reason', nullif(btrim(coalesce(p_reason, '')), '')));
  return sc;
end $$;

create or replace function app.set_scope_gi_user(p_scope uuid, p_number text, p_path text default null, p_sha256 text default null) returns public.scopes
language plpgsql security definer set search_path = public as $$
declare sc public.scopes; v_no text := nullif(btrim(coalesce(p_number, '')), '');
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.can_access_scope(p_scope) then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.runs_client(sc.client_id) or app.is_client_login() then
    raise exception 'GI authorised user: set by the scope''s Client Manager' using errcode = '42501'; end if;
  if sc.status = 'closed' then raise exception 'this scope is closed: its season has ended' using errcode = '42501'; end if;
  if not (select cr.gi_crop from public.crops cr where cr.id = sc.crop_id) then
    raise exception 'GI authorised user: only for a GI crop' using errcode = '23514'; end if;
  if v_no is not null and (length(v_no) < 2 or length(v_no) > 40) then
    raise exception 'GI authorised user: the registration number (2 to 40 characters)' using errcode = '23514'; end if;
  if p_path is not null then
    if p_path !~ ('^' || sc.client_id::text || '/scopes/' || sc.id::text || '/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$') then
      raise exception 'document: the file is stored as "<client>/scopes/<scope>/<file id>.pdf" (or jpg, png, webp)' using errcode = '22023'; end if;
    if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'document: its fingerprint (SHA-256) is required' using errcode = '22023'; end if;
    if to_regclass('storage.objects') is not null and not exists (select 1 from storage.objects o where o.bucket_id = 'client-docs' and o.name = p_path) then
      raise exception 'document: the file was not uploaded' using errcode = '22023'; end if;
  end if;
  if v_no is null and p_path is not null then raise exception 'GI authorised user: the number with its file' using errcode = '23514'; end if;
  perform set_config('app.scope_settings', 'on', true);
  update public.scopes set gi_user_no = v_no,
         gi_user_file = case when v_no is null then null when p_path is not null then p_path else gi_user_file end,
         gi_user_sha256 = case when v_no is null then null when p_path is not null then lower(p_sha256) else gi_user_sha256 end
   where id = sc.id returning * into sc;
  perform set_config('app.scope_settings', '', true);
  perform app.audit('scope_gi_user', sc.id, jsonb_build_object('number', v_no is not null, 'file', sc.gi_user_file is not null));
  return sc;
end $$;

-- the GI authorised-user file: written by the scope's Client Manager, read by whoever reads the whole scope
create or replace function app.scope_doc_scope(p_name text) returns uuid
language sql immutable as $$
  select case when p_name ~ '^[0-9a-f-]{36}/scopes/[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$' then split_part(p_name, '/', 3)::uuid end
$$;
create or replace function app.may_write_scope_doc(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.scopes s where s.id = app.scope_doc_scope(p_name) and split_part(p_name, '/', 1) = s.client_id::text
                   and app.runs_client(s.client_id) and not app.is_client_login() and s.status <> 'closed')
$$;
create or replace function app.may_read_scope_doc(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.scopes s where s.id = app.scope_doc_scope(p_name) and s.gi_user_file = p_name and app.sees_whole_scope(s.id))
$$;

-- 8 · A1: making a client account ------------------------------------------------------------------------------------------
-- The creator says first what the account is; the login is then made as before (create-user, kind viewer), and
-- app.add_client_viewer makes exactly what was said, once, within the hour.
create or replace function app.check_viewer_reach(p_client uuid, p_reach text, p_state uuid, p_scopes uuid[], p_as text) returns void
language plpgsql stable security definer set search_path = public as $$
declare v_states uuid[];
begin
  if p_reach not in ('client', 'state', 'scopes') then raise exception 'what the viewer sees: the whole client, one state or chosen scopes' using errcode = '22023'; end if;
  if p_reach = 'state' and not exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.state_id = p_state) then
    raise exception 'viewer: one of the client''s states' using errcode = '22023'; end if;
  if p_reach = 'scopes' then
    if coalesce(cardinality(p_scopes), 0) = 0 then raise exception 'viewer: choose at least one scope' using errcode = '23514'; end if;
    if exists (select 1 from unnest(p_scopes) x where not exists (select 1 from public.scopes s where s.id = x and s.client_id = p_client)) then
      raise exception 'viewer: only this client''s scopes' using errcode = '23514'; end if;
    v_states := array(select distinct s.state_id from public.scopes s where s.id = any (p_scopes));
  end if;
  -- B5: a Client Manager never makes an account that sees another state's data: one state, or scopes of one state
  if p_as = 'client_manager' and (p_reach = 'client' or (p_reach = 'scopes' and cardinality(v_states) > 1)) then
    raise exception 'a viewer made by the Client Manager sees one state''s scopes: choose the state, or scopes of one state' using errcode = '23514'; end if;
end $$;

create or replace function app.prepare_client_account(p_client uuid, p_kind text, p_email text, p_reach text default 'client',
                                                      p_state uuid default null, p_scopes uuid[] default '{}', p_internal boolean default false)
returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); v_as text; v_email text := app.email_key(p_email); v_id uuid; c public.clients;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid email is required: it is the sign-in' using errcode = '23514'; end if;
  if p_kind = 'owner' then
    if not app.is_admin() then raise exception 'a client owner is made by the admin' using errcode = '42501'; end if;
    if not app.client_was_activated(p_client) then raise exception 'a client owner is made once the client''s first Active is approved' using errcode = '23514'; end if;
    v_as := 'admin';
  elsif p_kind = 'viewer' then
    if app.client_owner_check(p_client) then
      if not app.client_may('manage_viewers', p_client) then
        raise exception 'this client is not active: an owner''s acts are paused' using errcode = '42501'; end if;
      v_as := 'owner';
    elsif app.cm_of_client(p_client) and not app.is_client_login() then v_as := 'client_manager';
    else raise exception 'a viewer is made by the client''s owner or its Client Manager' using errcode = '42501'; end if;
    perform app.check_viewer_reach(p_client, p_reach, p_state, p_scopes, v_as);
    if p_internal and v_as <> 'owner' then raise exception 'only the client''s owner allows internal copies' using errcode = '42501'; end if;
  elsif p_kind = 'operator' then
    if not app.cm_of_client(p_client) or app.is_client_login() then
      raise exception 'a client operator is made by the client''s Client Manager' using errcode = '42501'; end if;
    v_as := 'client_manager';
  else
    raise exception 'a client account is an owner, a viewer or an operator' using errcode = '22023';
  end if;
  update public.client_account_intents set used_at = now() where email_key = v_email and made_by = me and used_at is null;   -- one at a time
  insert into public.client_account_intents (email_key, client_id, kind, reach, state_id, scope_ids, internal_copies, made_by, made_as)
  values (v_email, p_client, p_kind, case when p_kind = 'viewer' then p_reach else 'client' end,
          case when p_kind = 'viewer' and p_reach = 'state' then p_state end,
          case when p_kind = 'viewer' and p_reach = 'scopes' then p_scopes else '{}' end,
          p_kind = 'viewer' and coalesce(p_internal, false), me, v_as)
  returning id into v_id;
  return v_id;
end $$;

-- 9 · A2.3: an account's status, a viewer's reach, internal copies, promotion to owner ---------------------------------------
-- who may act on an account: the admin on owners; an owner on its client's viewers; the Client Manager on the viewers
-- and operators he made
create or replace function app.may_manage_account(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case ca.kind
                            when 'owner' then app.is_admin()
                            when 'viewer' then app.is_admin() or (app.client_owner_check(ca.client_id) and app.client_may('manage_viewers', ca.client_id))
                                               or (ca.made_as in ('client_manager', 'migration') and app.cm_of_client(ca.client_id) and not app.is_client_login())
                            when 'operator' then app.cm_of_client(ca.client_id) and not app.is_client_login() end
                     from public.client_accounts ca where ca.user_id = p_user and ca.user_id <> app.current_user_id()), false)
$$;

create or replace function app.set_client_account_status(p_user uuid, p_status text, p_reason text) returns public.client_accounts
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); ca public.client_accounts; v_old text;
begin
  select * into ca from public.client_accounts where user_id = p_user;
  if ca.user_id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.may_manage_account(p_user) then raise exception 'this account is managed by whoever made it (the admin for owners)' using errcode = '42501'; end if;
  if p_status not in ('active', 'suspended', 'removed') then raise exception 'an account is active, suspended or removed' using errcode = '22023'; end if;
  if ca.status = 'removed' then raise exception 'a removed account stays removed: make a new one' using errcode = '23514'; end if;
  if p_status = ca.status then return ca; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'say why (at least 5 characters)' using errcode = '23514'; end if;
  v_old := ca.status;
  update public.client_accounts set status = p_status, status_reason = left(btrim(p_reason), 300), status_by = me, status_at = now()
   where user_id = p_user returning * into ca;
  update public.app_users set status = case p_status when 'active' then 'active' when 'suspended' then 'suspended' else 'offboarded' end::public.employee_status
   where id = p_user;
  if p_status = 'removed' then
    update public.assignments set active = false, end_reason = 'client account removed: ' || left(btrim(p_reason), 200) where employee_id = p_user and active;
  end if;
  perform app.audit('client_account_status', p_user, jsonb_build_object('client_id', ca.client_id, 'kind', ca.kind, 'from', v_old, 'to', p_status, 'reason', left(btrim(p_reason), 300)));
  return ca;
end $$;

create or replace function app.set_client_viewer(p_user uuid, p_reach text, p_state uuid default null, p_scopes uuid[] default '{}') returns public.client_accounts
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); ca public.client_accounts; v_as text;
begin
  select * into ca from public.client_accounts where user_id = p_user;
  if ca.user_id is null or ca.kind <> 'viewer' then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.may_manage_account(p_user) or ca.status = 'removed' then raise exception 'this account is managed by whoever made it' using errcode = '42501'; end if;
  v_as := case when app.client_owner_check(ca.client_id) or app.is_admin() then 'owner' else 'client_manager' end;
  perform app.check_viewer_reach(ca.client_id, p_reach, p_state, p_scopes, v_as);
  delete from public.client_account_scopes where user_id = p_user;
  update public.client_accounts set reach = p_reach, state_id = case when p_reach = 'state' then p_state end where user_id = p_user returning * into ca;
  if p_reach = 'scopes' then
    insert into public.client_account_scopes (user_id, scope_id, added_by) select p_user, x, me from unnest(p_scopes) x on conflict do nothing;
  end if;
  perform app.audit('client_account_reach', p_user, jsonb_build_object('client_id', ca.client_id, 'reach', p_reach, 'state_id', ca.state_id,
                                                                    'scopes', case when p_reach = 'scopes' then to_jsonb(p_scopes) end));
  return ca;
end $$;

create or replace function app.set_viewer_internal(p_user uuid, p_allowed boolean) returns public.client_accounts
language plpgsql security definer set search_path = public as $$
declare ca public.client_accounts;
begin
  perform app.me_or_raise();
  select * into ca from public.client_accounts where user_id = p_user;
  if ca.user_id is null or ca.kind <> 'viewer' then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.client_owner_check(ca.client_id) then raise exception 'only the client''s owner allows internal copies' using errcode = '42501'; end if;
  if not app.client_may('viewer_internal', ca.client_id) then raise exception 'this client is not active: an owner''s acts are paused' using errcode = '42501'; end if;
  update public.client_accounts set internal_copies = coalesce(p_allowed, false) where user_id = p_user returning * into ca;
  perform app.audit('client_account_internal', p_user, jsonb_build_object('client_id', ca.client_id, 'allowed', ca.internal_copies));
  return ca;
end $$;

-- A3: the admin promotes a viewer to owner (the whole client)
create or replace function app.make_client_owner(p_user uuid) returns public.client_accounts
language plpgsql security definer set search_path = public as $$
declare ca public.client_accounts;
begin
  perform app.me_or_raise();
  if not app.is_admin() then raise exception 'a client owner is made by the admin' using errcode = '42501'; end if;
  select * into ca from public.client_accounts where user_id = p_user;
  if ca.user_id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if ca.kind <> 'viewer' or ca.status <> 'active' then raise exception 'an active viewer is promoted to owner' using errcode = '23514'; end if;
  if not app.client_was_activated(ca.client_id) then
    raise exception 'a client owner is made once the client''s first Active is approved' using errcode = '23514'; end if;
  delete from public.client_account_scopes where user_id = p_user;
  update public.client_accounts set kind = 'owner', reach = 'client', state_id = null, internal_copies = false where user_id = p_user returning * into ca;
  perform app.audit('client_account_owner', p_user, jsonb_build_object('client_id', ca.client_id));
  return ca;
end $$;

-- the accounts of a client, for whoever may see them: the admin (all), the owner (its client's), the Client Manager
-- (his client's); never another client's; a viewer and an operator see none (B1)
create or replace function app.client_accounts_of(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := app.is_admin(); v_owner boolean := app.client_owner_check(p_client); v_cm boolean := app.cm_of_client(p_client) and not app.is_client_login();
begin
  if not (v_admin or v_owner or v_cm) then raise exception 'not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', ca.user_id, 'name', u.display_name, 'email', case when v_admin or v_owner or v_cm then u.email end,
        'kind', ca.kind, 'status', ca.status, 'reach', ca.reach, 'state_id', ca.state_id, 'state', (select name from public.states where id = ca.state_id),
        'scopes', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'label', format('%s · %s · %s', cr.name, s.season_code, s.geography)) order by s.geography), '[]'::jsonb)
                     from public.client_account_scopes x join public.scopes s on s.id = x.scope_id join public.crops cr on cr.id = s.crop_id where x.user_id = ca.user_id),
        'internal_copies', ca.internal_copies, 'made_as', ca.made_as, 'created_at', ca.created_at, 'status_reason', ca.status_reason,
        'has_login', u.auth_uid is not null,
        'stages', case when ca.kind = 'operator' then (select coalesce(jsonb_agg(jsonb_build_object('scope_id', a.scope_id, 'stages', to_jsonb(a.stages))), '[]'::jsonb)
                                                       from public.assignments a where a.employee_id = ca.user_id and a.active and a.lens = 'scope') end,
        'may', jsonb_build_object('manage', app.may_manage_account(ca.user_id),
                                  'internal', ca.kind = 'viewer' and v_owner and app.client_may('viewer_internal', p_client),
                                  'promote', ca.kind = 'viewer' and v_admin and ca.status = 'active'))
        order by ca.kind, u.display_name)
      from public.client_accounts ca join public.app_users u on u.id = ca.user_id
     where ca.client_id = p_client and (v_admin or v_owner or ca.kind in ('viewer', 'operator'))), '[]'::jsonb),
    'may', jsonb_build_object('owner', v_admin and app.client_was_activated(p_client),
                              'viewer', (v_owner and app.client_may('manage_viewers', p_client)) or v_cm,
                              'viewer_whole_client', v_owner, 'operator', v_cm, 'internal', v_owner),
    'states', (select coalesce(jsonb_agg(jsonb_build_object('id', cs.state_id, 'name', st.name, 'status', cs.status) order by st.name), '[]'::jsonb)
                 from public.client_states cs join public.states st on st.id = cs.state_id where cs.client_id = p_client),
    'scopes', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'state_id', s.state_id, 'status', s.status, 'delivery_model', s.delivery_model,
                                                           'label', format('%s · %s · %s', cr.name, s.season_code, s.geography)) order by s.geography), '[]'::jsonb)
                 from public.scopes s join public.crops cr on cr.id = s.crop_id where s.client_id = p_client));
end $$;

-- 10 · A2: the owner's own acts: the client's written acceptance on a lab record -------------------------------------------
create or replace function app.add_client_acceptance(p_fp uuid, p_path text, p_sha256 text) returns public.attachments
language plpgsql security definer set search_path = public as $$
declare me uuid := app.me_or_raise(); f public.footprints; r public.attachments;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.client_owner_check(f.client_id) then raise exception 'the client''s acceptance is uploaded by its owner' using errcode = '42501'; end if;
  if not app.client_may('acceptance', f.client_id, (select state_id from public.scopes where id = f.scope_id)) then
    raise exception 'this client is not active in this state: an owner''s acts are paused' using errcode = '42501'; end if;
  if f.stage_type <> 'qc' then raise exception 'the client''s acceptance is attached to the lab record' using errcode = '23514'; end if;
  if coalesce(p_sha256, '') !~* '^[0-9a-f]{64}$' then raise exception 'document: its fingerprint (SHA-256) is required' using errcode = '22023'; end if;
  if to_regclass('storage.objects') is not null and not exists (select 1 from storage.objects o where o.bucket_id = 'evidence' and o.name = p_path) then
    raise exception 'document: the file was not uploaded' using errcode = '22023'; end if;
  perform set_config('app.client_act', 'acceptance', true);
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by, label)
  values (f.id, 'document', p_path, lower(p_sha256), me, 'acceptance') returning * into r;
  perform set_config('app.client_act', '', true);
  perform app.audit('client_acceptance', f.id, jsonb_build_object('code', f.footprint_code, 'attachment', r.id));
  return r;
end $$;

-- the evidence store: a client account stores a file only for its act (an operator on a record of its stages; an owner
-- on its client's lab record, for the acceptance)
create or replace function app.client_may_evidence(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.footprints f join public.scopes s on s.id = f.scope_id
                  where f.id::text = split_part(p_name, '/', 3) and f.client_id::text = split_part(p_name, '/', 1) and f.scope_id::text = split_part(p_name, '/', 2)
                    and ((app.client_may('stage', f.client_id) and app.acts_in_scope(f.scope_id))
                         or (f.stage_type = 'qc' and app.client_owner_check(f.client_id) and app.client_may('acceptance', f.client_id, s.state_id))))
$$;

do $$
begin
  if to_regclass('storage.objects') is null then raise notice 'storage schema not present: evidence upload rule left as it was'; return; end if;
  execute $p$alter policy evidence_upload on storage.objects with check (
    (bucket_id = 'evidence') and (not app.is_client_login() or app.client_may_evidence(name)) and exists (select 1 from public.footprints f
      where (f.id)::text = (storage.foldername(objects.name))[3] and (f.client_id)::text = (storage.foldername(objects.name))[1]
        and (f.scope_id)::text = (storage.foldername(objects.name))[2] and app.can_see_footprint(f.scope_id, f.stage_type)))$p$;
end $$;

-- 5b · the functions replaced, each from its text as migration 66 left it, with the change named ------------------------
-- A2: the trigger on every guarded table asks the one rule (before: every write of a client login refused)
CREATE OR REPLACE FUNCTION app.client_login_reads_only()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if app.is_client_login() then
    -- migration 67 (A2): an operator's stage work; an owner's act, named by its own function (app.client_act)
    if app.client_table_act(tg_table_name) = 'stage' and app.client_may('stage') then
      return case when tg_op = 'DELETE' then old else new end; end if;
    if tg_table_name = 'buyer_links' and coalesce(current_setting('app.client_act', true), '') in ('buyer_link', 'buyer_link_revoke') then
      return case when tg_op = 'DELETE' then old else new end; end if;
    if tg_table_name = 'attachments' and tg_op = 'INSERT' and coalesce(current_setting('app.client_act', true), '') = 'acceptance' then
      if to_jsonb(new) ->> 'label' = 'acceptance' then return new; end if; end if;
    raise exception 'a client login reads only: it cannot change records, files, flags or lists' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $function$;

-- A1: the client's owner (before: any of its client logins)
CREATE OR REPLACE FUNCTION app.client_owner_of(p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.client_owner_check(p_client)                                  -- migration 67 (A1)
$function$;

-- B: a client viewer sees only the scopes it reaches
CREATE OR REPLACE FUNCTION app.views_scope_row(p_scope uuid, p_client uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client
            and app.account_reaches(a.employee_id, p_scope))                                   -- migration 67 (B)
        or (a.lens = 'scope' and a.op_role = 'export_manager' and a.scope_id = p_scope))
$function$;

-- A1: a client operator holds stages on its own client's Hybrid or Self-run scopes
CREATE OR REPLACE FUNCTION app.stage_refusal(p_user uuid, p_scope uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; sc public.scopes; base uuid;
begin
  select * into u from public.app_users where id = p_user;
  select * into sc from public.scopes where id = p_scope;
  if u.id is null or sc.id is null then return 'unknown person or scope'; end if;
  if u.external then                                                                             -- migration 67 (A1)
    if app.client_operator_for(u.id, sc.id) then return null; end if;
    if exists (select 1 from public.client_accounts ca where ca.user_id = u.id and ca.kind = 'operator' and ca.client_id = sc.client_id) then
      return 'the client''s own staff hold stages only on a Hybrid or Self-run scope'; end if;
    return 'a client''s login holds no stage'; end if;
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
end $function$;

-- A1: a client operator's stages on a scope (the only assignment of a client account besides its client view)
CREATE OR REPLACE FUNCTION app.assignments_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare u public.app_users; sc public.scopes;
begin
  if tg_op = 'INSERT' then
    select * into u from public.app_users where id = new.employee_id;
    if u.id is null then raise exception 'unknown person' using errcode = '23503'; end if;
    if u.status in ('suspended', 'offboarded') then
      raise exception 'a % person cannot be given an assignment', u.status using errcode = '42501'; end if;
    if u.external and new.op_role <> 'client_viewer'
       and not (new.lens = 'scope' and new.op_role = 'operator' and app.client_operator_for(new.employee_id, new.scope_id)) then   -- migration 67
      raise exception 'a client login can only view its own client' using errcode = '42501'; end if;
    if u.external and new.lens = 'client' and exists (select 1 from public.client_accounts ca where ca.user_id = u.id and ca.kind = 'operator') then
      raise exception 'a client operator holds stages, not the client view' using errcode = '42501'; end if;      -- migration 67
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
end $function$;

-- A2.5: a client operator is in the pool of its own client's Hybrid and Self-run scopes only
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
             'elsewhere', app.work_elsewhere(u.id, sc.id),                                       -- migration 51 (A15)
             'ready_for', rf.stage, 'ready_opening', rf.code,      -- migration 46: joined on an opening of this scope, not placed yet
             'stages', coalesce((select to_jsonb(a.stages) from public.assignments a
                                  where a.employee_id = u.id and a.active and a.lens = 'scope' and a.scope_id = sc.id), '[]'::jsonb))
           order by rf.stage is null, jsonb_array_length(app.work_elsewhere(u.id, sc.id)) > 0, u.id <> app.current_user_id(), u.display_name)
      from (select u.* from public.app_users u left join public.employee_org o2 on o2.employee_id = u.id
             where (not u.external or app.client_operator_for(u.id, sc.id)) and not u.test_data and u.system_role = 'operational' and u.status in ('invited', 'onboarding', 'active')
               and (v_q is null or lower(u.display_name) like '%' || v_q || '%')
               and (o2.base_state_id = sc.state_id or app.client_account_holder(u.id, sc.client_id) or app.client_operator_for(u.id, sc.id))
               -- migration 57 (G20): not a person who works now for another client, unless he works for this one too
               and (not app.busy_for_other_client(u.id) or app.client_account_holder(u.id, sc.client_id)
                    or exists (select 1 from public.assignments a3 join public.scopes s3 on s3.id = a3.scope_id
                                where a3.employee_id = u.id and a3.active and s3.client_id = sc.client_id))
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

-- A1: the login of a client account is exactly what its creator said (app.prepare_client_account)
CREATE OR REPLACE FUNCTION app.add_client_viewer(p_client uuid, p_name text, p_email text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); v_id uuid; v_email text := app.email_key(p_email); it public.client_account_intents;
begin
  -- migration 67 (A1): who may make it was asked when the creator said what it is
  if btrim(coalesce(p_name, '')) = '' then raise exception 'a name is required' using errcode = '23514'; end if;
  if v_email is null or v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'a valid email is required: it is the sign-in' using errcode = '23514'; end if;
  select * into it from public.client_account_intents i
   where i.email_key = v_email and i.client_id = p_client and i.made_by = me and i.used_at is null and i.created_at > now() - interval '1 hour'
   order by i.created_at desc limit 1;
  if it.id is null then
    raise exception 'client account: say first what it is (owner, viewer or operator) and what it sees' using errcode = '42501'; end if;
  begin
    insert into public.app_users (display_name, email, status, external, created_by)
    values (btrim(p_name), v_email, 'active', true, me) returning id into v_id;
  exception when unique_violation then
    raise exception 'a person with this email already exists' using errcode = '23505';
  end;
  insert into public.client_accounts (user_id, client_id, kind, reach, state_id, internal_copies, made_by, made_as)
  values (v_id, p_client, it.kind, it.reach, it.state_id, it.internal_copies, me, it.made_as);
  insert into public.client_account_scopes (user_id, scope_id, added_by) select v_id, x, me from unnest(it.scope_ids) x;
  if it.kind in ('owner', 'viewer') then                                       -- reading through the client view; what it reaches: client_accounts
    insert into public.assignments (employee_id, lens, op_role, client_id, created_by) values (v_id, 'client', 'client_viewer', p_client, me);
  end if;
  update public.client_account_intents set used_at = now() where id = it.id;
  perform app.audit('client_login_created', v_id, jsonb_build_object('name', btrim(p_name), 'client_id', p_client, 'kind', it.kind, 'reach', it.reach));
  return v_id;
end $function$;

-- A1: internal copies for the client's owner and the viewers it allowed; never a client operator
CREATE OR REPLACE FUNCTION app.may_internal_copy(p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.current_user_id() is not null
     and ((app.acts_in_scope(p_scope) and not app.is_client_login())
          or (app.is_client_login() and app.sees_whole_scope(p_scope) and app.client_internal_ok()))   -- migration 67 $function$;

-- B: a viewer sees the farmers of what it reaches
CREATE OR REPLACE FUNCTION app.client_farmers(p_q text DEFAULT NULL::text, p_ids uuid[] DEFAULT NULL::uuid[], p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); v_clients uuid[]; v_q text := nullif(lower(btrim(p_q)), '');
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct a.client_id), '{}') into v_clients from app.eff_assignments(me) a
   where a.lens = 'client' and a.op_role = 'client_viewer';
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'farmer_code', f.farmer_code, 'name', f.name, 'village', f.village,
           'district', f.district, 'block', f.block, 'status', f.status, 'land_area_acres', f.land_area_acres, 'gi_land_acres', f.gi_land_acres,
           'phone', case when coalesce(f.phone, '') = '' then null else '••••••' || right(regexp_replace(f.phone, '[^0-9]', '', 'g'), 4) end)
           order by f.name, f.farmer_code)
      from (select * from public.farmers f where f.client_id = any (v_clients)
              and app.account_sees_farmer(me, f.id, f.client_id, f.state_id)                     -- migration 67 (B)
              and (p_ids is null or f.id = any (p_ids))
              and (v_q is null or lower(f.name) like '%' || v_q || '%' or lower(coalesce(f.farmer_code, '')) like '%' || v_q || '%'
                   or lower(coalesce(f.village, '')) like '%' || v_q || '%')
             order by f.name, f.farmer_code limit least(greatest(coalesce(p_limit, 200), 1), 500)) f), '[]'::jsonb);
end $function$;

-- A1/B: the owner as before; a viewer reads its client's record for the states it reaches; who may manage the accounts
CREATE OR REPLACE FUNCTION app.client_view(p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.clients; e public.entities; v_admin boolean := app.is_admin(); v_owner boolean; v_cm boolean; v_reader boolean;
        v_sm_states uuid[]; v_full boolean; v_states jsonb; v_reg public.id_kind; v_nat jsonb; v_see uuid[];
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id;
  v_owner := app.client_owner_of(p_client);
  v_reader := app.client_reader_of(p_client) and not v_owner;                    -- migration 67 (B)
  v_cm := app.cm_of_client(p_client);
  v_sm_states := case when app.is_client_login() then '{}'::uuid[]
                      else array(select cs.state_id from public.client_states cs where cs.client_id = p_client and cs.state_id = any (app.my_state_ids())) end;
  if not (v_admin or v_owner or v_reader or v_cm or cardinality(v_sm_states) > 0) then
    -- a State Manager of another state: the shared identity only (A4); everyone else: nothing
    if cardinality(app.my_state_ids()) > 0 and not app.is_client_login() then
      return jsonb_build_object('identity', app.client_identity(p_client), 'shared_only', true, 'states', '[]'::jsonb,
                                'may', jsonb_build_object('add_state', true, 'add_states', app.addable_states(p_client)));   -- migration 65
    end if;
    raise exception 'not found' using errcode = 'P0002';
  end if;
  v_full := v_admin or cardinality(v_sm_states) > 0;              -- A3: the numbers in full for these only
  v_see := case when v_admin or v_owner then array(select state_id from public.client_states where client_id = p_client)
                when v_reader then app.account_states(app.current_user_id(), p_client)   -- migration 67 (B)
                when cardinality(v_sm_states) > 0 then v_sm_states
                else array[c.state_id] end;                         -- the Client Manager: his client's state
  v_reg := case e.entity_type when 'company' then 'cin' when 'llp' then 'llpin' when 'cooperative' then 'reg_no' when 'society' then 'reg_no' end;

  v_nat := jsonb_build_object(
    'reg_number', case when v_reg is null then null else
      (select jsonb_build_object('kind', i.kind, 'masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, v_reg) i where i.id is not null) end,
    'iec', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, 'iec') i where i.id is not null),
    'rcmc', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end, 'expires_on', i.expires_on) from app.cur_id(e.id, 'rcmc') i where i.id is not null),
    'documents', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'file_name', d.file_name, 'sha256', d.sha256,
          'path', case when v_admin or v_owner or c.state_id = any (v_sm_states) then d.path end,   -- migration 65: else "on file"
          'bytes', d.bytes, 'signed_on', d.signed_on, 'term_end', d.term_end, 'expires_on', d.expires_on, 'amount', d.amount,
          'created_at', d.created_at) order by d.kind), '[]'::jsonb)
         from public.client_documents d where d.client_id = p_client and d.state_id is null and d.superseded_at is null) end);

  select coalesce(jsonb_agg(jsonb_build_object(
      'state_id', cs.state_id, 'state', s.name, 'status', cs.status, 'legacy', cs.legacy,
      'gstin', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, 'gstin', cs.state_id) i where i.id is not null),
      'gst_not_registered_reason', cs.gst_not_registered_reason,
      'signatory', case when v_cm and not v_full and not v_owner then '{}'::jsonb else cs.signatory end,
      'billing', cs.billing, 'address', cs.address, 'state_contact', cs.state_contact, 'brand_on_pack', cs.brand_on_pack,
      'fssai', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end, 'expires_on', i.expires_on) from app.cur_id(e.id, 'fssai', cs.state_id) i where i.id is not null),
      'ended_on', cs.ended_on, 'status_reason', cs.status_reason, 'status_by_admin', cs.status_by_admin,   -- migration 65
      'kyc_at', cs.kyc_at, 'kyc_by', (select display_name from public.app_users where id = cs.kyc_by),
      'activation_requested_at', cs.activation_requested_at,
      'gates', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then null else app.client_gates(p_client, cs.state_id) end,
      'documents', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
        (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'file_name', d.file_name, 'path', d.path, 'sha256', d.sha256,
            'bytes', d.bytes, 'signed_on', d.signed_on, 'expires_on', d.expires_on, 'amount', d.amount, 'created_at', d.created_at) order by d.kind), '[]'::jsonb)
           from public.client_documents d where d.client_id = p_client and d.state_id = cs.state_id and d.superseded_at is null) end,
      'events', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
        (select coalesce(jsonb_agg(jsonb_build_object('act', ev.act, 'from', ev.from_status, 'to', ev.to_status, 'reason', ev.reason, 'at', ev.at,
            'by', (select display_name from public.app_users where id = ev.by_user)) order by ev.at desc, ev.id desc), '[]'::jsonb)
           from public.client_status_events ev where ev.client_id = p_client and ev.state_id = cs.state_id) end,
      'mine', cs.state_id = any (v_sm_states)) order by s.name), '[]'::jsonb)
    into v_states
    from public.client_states cs join public.states s on s.id = cs.state_id
   where cs.client_id = p_client and cs.state_id = any (v_see);

  return jsonb_build_object(
    'identity', app.client_identity(p_client) || jsonb_build_object('pan', case when v_full then (app.cur_id(e.id, 'pan')).value end,
      'reg_office', e.reg_office, 'approved_at', c.approved_at, 'code_edited', c.code_edited, 'type', c.type),
    'shared_only', false,
    'contact', c.contact, 'source', c.source,
    'states_of_interest', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb) from public.states s where s.id = any (c.states_of_interest)),
    'crops_of_interest', (select coalesce(jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name) order by cr.name), '[]'::jsonb) from public.crops cr where cr.id = any (c.crops_of_interest)),
    'exports', app.client_exports(p_client),
    'national', v_nat,
    'states', v_states,
    'may', jsonb_build_object(
      'edit', cardinality(v_sm_states) > 0,
      'edit_states', to_jsonb(v_sm_states),
      'edit_identity', v_admin,
      'edit_code', v_admin and c.approved_at is null and not c.code_edited,
      'set_pan', e.pan_pending and (v_admin or cardinality(v_sm_states) > 0),
      'approve', v_admin,
      'full_numbers', v_full,
      'add_states', app.addable_states(p_client),                      -- migration 65
      'set_status', v_admin or cardinality(v_sm_states) > 0,
      'national_docs', c.state_id = any (v_sm_states),
      'renew', v_owner and app.client_may('renewal', p_client),            -- migration 67 (A4)
      'accounts', v_admin or v_owner or (v_cm and not app.is_client_login())));
end $function$;

-- B: a client account lists its own client, with the states it reaches
CREATE OR REPLACE FUNCTION app.clients_page()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_admin boolean := app.is_admin(); v_states uuid[] := case when app.is_client_login() then '{}'::uuid[] else app.my_state_ids() end;
begin
  return (select coalesce(jsonb_agg(r order by r ->> 'name'), '[]'::jsonb) from (
    select jsonb_build_object('client_id', c.id, 'name', c.name, 'legal_name', e.legal_name, 'code', c.code, 'pan_masked', e.pan_masked,
      'pan_pending', e.pan_pending, 'own_brand', e.own_brand, 'entity_type', e.entity_type, 'national_status', app.national_status(c.id),
      'states', (select coalesce(jsonb_agg(jsonb_build_object('state_id', cs.state_id, 'state', s.name, 'status', cs.status, 'legacy', cs.legacy,
                   'awaiting_approval', cs.activation_requested_at is not null,
                   'progress', case when v_admin or cs.state_id = any (v_states) then
                       (select jsonb_build_object('done', count(*) filter (where (it ->> 'done')::boolean), 'of', count(*))
                          from jsonb_array_elements(app.client_gates(c.id, cs.state_id) -> 'gates') g, jsonb_array_elements(g -> 'items') it
                         where (it ->> 'needed')::boolean) end) order by s.name), '[]'::jsonb)
                   from public.client_states cs join public.states s on s.id = cs.state_id
                  where cs.client_id = c.id and (v_admin or cs.state_id = any (app.account_states(app.current_user_id(), c.id)) or cs.state_id = any (v_states)
                                                 or (app.cm_of_client(c.id) and cs.state_id = c.state_id)))) as r
      from public.clients c join public.entities e on e.id = c.entity_id
     where v_admin or app.client_reader_of(c.id) or app.cm_of_client(c.id)
        or exists (select 1 from public.client_states cs where cs.client_id = c.id and cs.state_id = any (v_states))) q);
end $function$;

-- B: the client's owner and viewers read its identity
CREATE OR REPLACE FUNCTION app.client_identity(p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.clients; e public.entities; st public.states;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then return null; end if;
  -- A4: any State Manager (the shared identity), the admin, the client's own people
  if not (app.is_admin() or (cardinality(app.my_state_ids()) > 0 and not app.is_client_login())
          or app.client_reader_of(p_client) or app.cm_of_client(p_client)) then
    raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id;
  return jsonb_build_object('client_id', c.id, 'legal_name', e.legal_name, 'trade_name', e.trade_name, 'name', c.name,
    'pan_masked', e.pan_masked, 'pan_pending', e.pan_pending, 'entity_type', e.entity_type,
    'office_city', e.reg_office ->> 'city', 'office_state', e.reg_office ->> 'state',
    'status', app.national_status(c.id), 'code', c.code, 'own_brand', e.own_brand);
end $function$;

-- B: a client account is told of the states it reaches
CREATE OR REPLACE FUNCTION app.notify_client(p_kind text, p_client uuid, p_state uuid, p_data jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); n int;
begin
  with staff as (
    select distinct a.employee_id as u, false as owner
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'
       and a.lens = 'state' and a.state_id in (select cs.state_id from public.client_states cs where cs.client_id = p_client)
    union
    select u.id, false from public.app_users u where u.system_role = 'admin' and u.status = 'active'),
  owners as (
    select distinct a.employee_id as u, true as owner
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'
       and a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client
       and (p_state is null or p_state = any (app.account_states(a.employee_id, p_client)))),        -- migration 67 (B)
  everyone as (
    select u, bool_or(owner) as owner from (select * from staff union all select * from owners) x
     where me is null or u <> me group by u)
  insert into public.notifications (user_id, kind, client_id, state_id, data)
  select e.u, p_kind, p_client, p_state, case when e.owner and not exists (select 1 from staff s where s.u = e.u) then p_data - 'reason' else p_data end
    from everyone e;
  get diagnostics n = row_count;
  return n;
end $function$;

-- A4: an owner's renewal is paused while the client is not active there
CREATE OR REPLACE FUNCTION app.propose_client_renewal(p_client uuid, p_state uuid, p_kind client_doc_kind, p_path text, p_sha256 text, p_bytes bigint, p_file_name text DEFAULT NULL::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_meta jsonb := coalesce(p_meta, '{}'::jsonb); v_state uuid; r public.client_renewals; c public.clients;
begin
  if not app.client_owner_of(p_client) then raise exception 'a renewal is uploaded by the client''s own login' using errcode = '42501'; end if;
  if not app.client_may('renewal', p_client, case when p_kind = 'fssai' then p_state end) then                -- migration 67 (A4)
    raise exception 'this client is not active: an owner''s acts are paused' using errcode = '42501'; end if;
  if p_kind not in ('fssai', 'rcmc', 'msa') then raise exception 'renewal: the FSSAI licence, the RCMC or the MSA' using errcode = '22023'; end if;
  v_state := case when p_kind = 'fssai' then p_state end;
  if p_kind = 'fssai' and not exists (select 1 from public.client_states where client_id = p_client and state_id = v_state) then
    raise exception 'renewal: the FSSAI licence of one of the client''s states' using errcode = '22023'; end if;
  if p_path !~ ('^' || p_client::text || '/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$') then
    raise exception 'document: the file is stored as "<client>/<file id>.pdf" (or jpg, png, webp)' using errcode = '22023'; end if;
  if to_regclass('storage.objects') is not null then
    if not exists (select 1 from storage.objects o where o.bucket_id = 'client-docs' and o.name = p_path) then
      raise exception 'document: the file was not uploaded' using errcode = '22023'; end if;
  end if;
  if p_kind in ('fssai', 'rcmc') and nullif(v_meta ->> 'expires_on', '') is null then
    raise exception '%: its expiry date', case p_kind when 'fssai' then 'FSSAI licence' else 'RCMC' end using errcode = '22023'; end if;
  if p_kind = 'msa' and (nullif(v_meta ->> 'signed_on', '') is null or nullif(v_meta ->> 'term_end', '') is null) then
    raise exception 'Master Services Agreement: the signed date and the term end date' using errcode = '22023'; end if;
  insert into public.client_renewals (client_id, state_id, kind, path, file_name, sha256, bytes, signed_on, term_end, expires_on, proposed_by)
  values (p_client, v_state, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_bytes, nullif(v_meta ->> 'signed_on', '')::date,
          nullif(v_meta ->> 'term_end', '')::date, nullif(v_meta ->> 'expires_on', '')::date, app.current_user_id())
  returning * into r;
  select * into c from public.clients where id = p_client;
  perform app.audit('client_renewal_proposed', p_client, jsonb_build_object('renewal_id', r.id, 'kind', p_kind, 'state_id', v_state, 'sha256', r.sha256), false);
  perform app.notify_client('client_renewal', p_client, v_state, jsonb_build_object('client', c.name, 'code', c.code, 'kind', p_kind,
    'state', (select name from public.states where id = v_state), 'by', (select display_name from public.app_users where id = app.current_user_id())));
  return to_jsonb(r);
end $function$;

-- A1/A4: the client's owner makes a buyer link too, while the client is active in the scope's state
CREATE OR REPLACE FUNCTION app.create_buyer_link(p_fp uuid, p_days integer DEFAULT 30, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare me uuid := app.current_user_id(); f public.footprints; v_token text; l public.buyer_links; v_buyer uuid;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type not in ('commercial', 'shipment') then raise exception 'a buyer link is of a sale or a shipment' using errcode = '23514'; end if;
  if not app.manages_scope(me, f.scope_id) or app.is_client_login() then                                   -- migration 67 (A1)
    if not app.client_owner_check(f.client_id) then
      raise exception 'a buyer link is made by the Client Manager or a manager of the scope' using errcode = '42501'; end if;
    if not app.client_may('buyer_link', f.client_id, (select s.state_id from public.scopes s where s.id = f.scope_id)) then
      raise exception 'this client is not active in this state: an owner''s acts are paused' using errcode = '42501'; end if;
    perform set_config('app.client_act', 'buyer_link', true);
  end if;
  if f.status not in ('pending', 'verified') then raise exception 'this record is %', f.status using errcode = '23514'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then raise exception 'buyer link: it lasts 1 to 90 days' using errcode = '23514'; end if;
  v_buyer := nullif(coalesce(f.computed->>'buyer_id', (select s.computed->>'buyer_id' from public.footprints s where s.id = f.prev_footprint_id)), '')::uuid;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.buyer_links (token_hash, footprint_id, scope_id, client_id, buyer_id, note, created_by, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), f.id, f.scope_id, f.client_id, v_buyer, nullif(left(btrim(coalesce(p_note, '')), 200), ''),
          me, now() + make_interval(days => p_days))
  returning * into l;
  perform set_config('app.client_act', '', true);
  perform app.audit('buyer_link_created', f.id, jsonb_build_object('code', f.footprint_code, 'link', l.id, 'expires_at', l.expires_at), false);
  return jsonb_build_object('id', l.id, 'token', v_token, 'expires_at', l.expires_at);
end $function$;

-- A1/A4: the client's owner revokes a buyer link, also while the client is suspended
CREATE OR REPLACE FUNCTION app.revoke_buyer_link(p_link uuid, p_reason text)
 RETURNS buyer_links
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); l public.buyer_links;
begin
  select * into l from public.buyer_links where id = p_link;
  if l.id is null or me is null or not (app.manages_scope(me, l.scope_id) or (app.client_owner_check(l.client_id) and app.client_may('buyer_link_revoke', l.client_id))) then raise exception 'buyer link not found' using errcode = 'P0002'; end if;
  if l.revoked_at is not null then raise exception 'this buyer link is revoked already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'buyer link: say why it is revoked (at least 5 characters)' using errcode = '23514'; end if;
  perform set_config('app.client_act', 'buyer_link_revoke', true);                                -- migration 67
  update public.buyer_links set revoked_at = now(), revoked_by = me, revoke_reason = left(btrim(p_reason), 300) where id = l.id returning * into l;
  perform set_config('app.client_act', '', true);
  perform app.audit('buyer_link_revoked', l.footprint_id, jsonb_build_object('link', l.id), false);
  return l;
end $function$;

-- A1: the client's owner reads its buyer links
CREATE OR REPLACE FUNCTION app.buyer_links_of(p_fp uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'note', l.note, 'created_at', l.created_at, 'expires_at', l.expires_at,
           'revoked_at', l.revoked_at, 'revoke_reason', l.revoke_reason, 'by', u.display_name,
           'state', case when l.revoked_at is not null then 'revoked' when l.expires_at <= now() then 'expired' else 'active' end,
           'views', (select count(*) from public.buyer_link_views v where v.link_id = l.id),
           'last_view', (select max(v.at) from public.buyer_link_views v where v.link_id = l.id),
           'log', (select coalesce(jsonb_agg(jsonb_build_object('at', v.at, 'what', v.what) order by v.at desc), '[]'::jsonb)
                     from (select * from public.buyer_link_views v where v.link_id = l.id order by v.at desc limit 20) v))
           order by l.created_at desc), '[]'::jsonb)
    from public.buyer_links l left join public.app_users u on u.id = l.created_by
   where l.footprint_id = p_fp and (app.manages_scope(app.current_user_id(), l.scope_id) or app.client_owner_check(l.client_id))   -- migration 67 $function$;

-- B4: the GI authorised-user file of a scope (its Client Manager)
CREATE OR REPLACE FUNCTION app.may_write_client_object(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.may_write_scope_doc(p_name) or app.client_doc_client(p_name) is not null and   -- migration 67
         (app.sm_of_client(app.client_doc_client(p_name)) or app.client_owner_of(app.client_doc_client(p_name)))   -- migration 65
$function$;

-- B4: the GI authorised-user file of a scope (whoever reads the whole scope)
CREATE OR REPLACE FUNCTION app.may_read_client_file(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.may_read_scope_doc(p_name)                                                  -- migration 67
      or exists (select 1 from public.client_documents d where d.path = p_name
                   and (app.is_admin() or app.client_owner_of(d.client_id)
                        or (d.state_id is null and app.sm_of_client(d.client_id, (select c.state_id from public.clients c where c.id = d.client_id)))   -- migration 65
                        or (d.state_id is not null and app.sm_of_client(d.client_id, d.state_id))))
      or exists (select 1 from public.client_renewals r where r.path = p_name                                      -- migration 65
                   and (app.is_admin() or app.client_owner_of(r.client_id)
                        or app.sm_of_client(r.client_id, coalesce(r.state_id, (select c.state_id from public.clients c where c.id = r.client_id)))))
$function$;

-- A1/B1: the Client Manager sees his client's operators; an owner its client's accounts (and no other client's)
CREATE OR REPLACE FUNCTION app.manages_viewer(p_person uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.assignments a
                  where a.employee_id = p_person and a.active and a.lens = 'client'
                    and app.manages_client(app.current_user_id(), a.client_id))
      or exists (select 1 from public.client_accounts ca where ca.user_id = p_person                    -- migration 67
                    and ((ca.kind = 'operator' and app.cm_of_client(ca.client_id) and not app.is_client_login())
                         or app.client_owner_check(ca.client_id)))
$function$;

-- A1: the signed-in client account: its kind, client and reach
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
             'client_account', (select jsonb_build_object('kind', ca.kind, 'client_id', ca.client_id, 'client_name', c2.name, 'reach', ca.reach,   -- migration 67
                                  'internal_copies', ca.internal_copies, 'status', ca.status)
                                  from public.client_accounts ca join public.clients c2 on c2.id = ca.client_id where ca.user_id = u.id),
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

-- B4: the season report names the scope's delivery model (before: "not recorded")
CREATE OR REPLACE FUNCTION app.season_report_data(p_scope uuid, p_internal boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; v_shares jsonb; recs jsonb; v_head jsonb; v_bal jsonb; v_states jsonb; v_codes text[];
        v_headline jsonb; v_balance jsonb; v_origin jsonb; v_quality jsonb; v_packing jsonb; v_sales jsonb; v_qr jsonb;
        v_chain jsonb; v_ledger jsonb; v_open jsonb; v_period jsonb;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null then return null; end if;
  -- a source's share of the season (as the season export)
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status <> 'superseded'
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id))
  select coalesce(jsonb_object_agg(e.id::text, e.qty_out / nullif(tot.kg, 0)) filter (where e.id is not null), '{}'::jsonb) into v_shares
    from (select sum(qty_out) as kg from live where stage_type in ('procurement', 'lot_inward')) tot
    left join live e on e.stage_type in ('procurement', 'lot_inward');
  -- every live record, in chain order, as the exports write it (this copy's columns only)
  select coalesce(jsonb_agg(app.export_record(f.id, p_internal, (v_shares->>f.id::text)::numeric) || jsonb_build_object('_id', f.id)
           order by array_position(sc.chain, f.stage_type), coalesce(f.captured_at, f.created_at), f.footprint_code), '[]'::jsonb)
    into recs
    from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
     and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id);
  v_head := app.export_scope_head(p_scope);
  v_bal := app.stage_balance_of(p_scope);
  select coalesce(jsonb_agg(to_jsonb(ps) order by ps.batch_code), '[]'::jsonb) into v_states from app.scope_pack_states(p_scope) ps;
  select coalesce(array_agg(p.serial), '{}') || coalesce((select array_agg(q.qr_code) from public.qr_seals q join public.footprints f on f.id = q.footprint_id
                                                          where f.scope_id = p_scope), '{}')
    into v_codes from public.packs p where p.scope_id = p_scope;
  select jsonb_build_object('from', min(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date)),
                            'to', max(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date)))
    into v_period from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy');

  -- headline figures
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ent as (select l.*, app.entry_gi(l.id) as gi from live l where l.stage_type in ('procurement', 'lot_inward')),
  vil as (select distinct fa.village, fa.district from ent e join public.farmers fa on fa.id = e.farmer_id),
  qc as (select l.id, v.domestic_verdict as d, v.export_verdict as x, v.override->>'market' as acc
           from live l join public.qc_verdicts v on v.footprint_id = l.id where l.stage_type = 'qc')
  select jsonb_build_object(
      'procured_kg', (select coalesce(sum(qty_out), 0) from ent),
      'packed_kg', (select coalesce(sum(qty_out), 0) from live where stage_type = 'packing'),
      'sold_kg', (select coalesce(sum(qty_out), 0) from live where stage_type = 'commercial'),
      'shipped_kg', (select coalesce(sum(qty_in), 0) from live where stage_type = 'shipment'),
      'farmers', (select count(distinct farmer_id) from ent),
      'villages', (select count(*) from vil),
      'gi_pct', (select round(100 * coalesce(sum(qty_out) filter (where gi = 'gi'), 0) / nullif(sum(qty_out), 0), 1) from ent),
      'farm_verified_pct', (select round(100 * coalesce(sum(qty_out) filter (where stage_type = 'procurement'), 0) / nullif(sum(qty_out), 0), 1) from ent),
      'qc', jsonb_build_array(
        (select jsonb_build_object('market', 'domestic', 'lots', count(*), 'passed', count(*) filter (where d = 'pass'),
                  'failed', count(*) filter (where d = 'fail' and acc is distinct from 'domestic'),
                  'accepted', count(*) filter (where acc = 'domestic'), 'pending', count(*) filter (where d = 'pending'),
                  'pass_pct', round(100.0 * count(*) filter (where d = 'pass') / nullif(count(*) filter (where d <> 'pending'), 0), 1)) from qc),
        (select jsonb_build_object('market', 'export', 'lots', count(*), 'passed', count(*) filter (where x = 'pass'),
                  'failed', count(*) filter (where x = 'fail' and acc is distinct from 'export'),
                  'accepted', count(*) filter (where acc = 'export'), 'pending', count(*) filter (where x = 'pending'),
                  'pass_pct', round(100.0 * count(*) filter (where x = 'pass') / nullif(count(*) filter (where x <> 'pending'), 0), 1)) from qc)),
      'packs_released', (select coalesce(sum((s->>'released')::int), 0) from jsonb_array_elements(v_states) s),
      'packs_released_old', (select coalesce(sum((s->>'old_data')::int), 0) from jsonb_array_elements(v_states) s),
      'packs_held', (select coalesce(sum((s->>'held')::int), 0) from jsonb_array_elements(v_states) s),
      'scans', (select count(*) from public.scans s where s.code = any (v_codes)),
      'copy_flags', (select count(*) from public.scan_flags f where f.scope_id = p_scope),
      'recalls', (select count(*) from public.release_events e join public.footprints f on f.id = e.seal_id
                   where f.scope_id = p_scope and e.status = 'recalled'),
      'sealed_lots', (select count(*) from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope))
    into v_headline;

  -- mass balance: per stage, milling's parts, and sold never above procured (checked here and printed)
  select jsonb_build_object('stages', v_bal,
      'milling', (select jsonb_build_object('in_kg', coalesce(sum((r->>'qty_in_kg')::numeric), 0),
                    'head_rice_kg', coalesce(sum((r->>'head_rice_kg')::numeric), 0), 'broken_kg', coalesce(sum((r->>'broken_kg')::numeric), 0),
                    'husk_kg', coalesce(sum((r->>'husk_kg')::numeric), 0), 'bran_kg', coalesce(sum((r->>'bran_kg')::numeric), 0),
                    'floor_loss_kg', coalesce(sum((r->>'floor_loss_kg')::numeric), 0), 'records', count(*))
                  from jsonb_array_elements(recs) r where r->>'stage' = 'milling'),
      'written_off_kg', (select coalesce(sum(c.floor_loss_kg), 0) from public.lot_closures c where c.scope_id = p_scope and c.kind = 'written_off'),
      'check', jsonb_build_object('procured_kg', v_headline->'procured_kg', 'sold_kg', v_headline->'sold_kg',
                 'ok', (v_headline->>'sold_kg')::numeric <= (v_headline->>'procured_kg')::numeric + app.kg_tolerance()),
      'differences', (select count(*) from jsonb_array_elements(v_bal) b where not (b->>'balanced')::boolean))
    into v_balance;

  -- origin: villages and districts with their share; farmers; GI and farm-verified; the farmer list in the internal copy only
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)
                   and f.stage_type in ('procurement', 'lot_inward')),
  tot as (select nullif(sum(qty_out), 0) as kg from live)
  select jsonb_build_object(
      'villages', coalesce((select jsonb_agg(v order by (v->>'kg')::numeric desc, v->>'village') from (
          select jsonb_build_object('village', fa.village, 'district', fa.district, 'kg', sum(l.qty_out),
                   'pct', round(100 * sum(l.qty_out) / (select kg from tot), 1), 'farmers', count(distinct l.farmer_id)) as v
            from live l left join public.farmers fa on fa.id = l.farmer_id
           group by fa.village, fa.district) x), '[]'::jsonb),
      'farmers', (select count(distinct farmer_id) from live),
      'gi_pct', v_headline->'gi_pct', 'farm_verified_pct', v_headline->'farm_verified_pct',
      'farmer_list', case when p_internal then coalesce((select jsonb_agg(v order by v->>'code') from (
          select jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village, 'district', fa.district,
                   'kg', sum(l.qty_out), 'lots', count(*)) as v
            from live l join public.farmers fa on fa.id = l.farmer_id group by fa.id, fa.farmer_code, fa.name, fa.village, fa.district) x), '[]'::jsonb) end)
    into v_origin;

  -- quality: each lab record with its verdicts (a release on the client's acceptance said as such), readings, lab, report, file
  select coalesce(jsonb_agg(jsonb_build_object('code', r->'code', 'on', coalesce(r->'happened_on', r->'recorded_at'),
           'domestic', r->'qc_domestic', 'export', r->'qc_export', 'accepted', v.override->>'market',
           'readings', coalesce(r->'readings', '{}'::jsonb),
           'lab', r->'lab', 'lab_accreditation', r->'lab_accreditation', 'report_no', r->'report_no', 'report_date', r->'report_date',
           'sample', r->'sample_code', 'files', r->'evidence_sha256') order by r->>'code'), '[]'::jsonb)
    into v_quality
    from jsonb_array_elements(recs) r left join public.qc_verdicts v on v.footprint_id = (r->>'_id')::uuid
   where r->>'stage' = 'qc';

  -- packing: per batch, its packs by size, serial range, dates, the net weight check, the wastage
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packing', pf.footprint_code, 'packs', b.n, 'void', b.v,
           'first', b.first, 'last', b.last, 'by_size', b.by_size, 'packed_on', b.packed_on,
           'best_before', case when b.no_bb > 0 then 'not_recorded' else b.bb::text end,
           'net_weight', (select n.result from public.net_weight_checks n where n.footprint_id = pf.id order by n.checked_at desc nulls last limit 1),
           'wastage_kg', pf.computed->'wastage_kg', 'wastage_pct', pf.computed->'wastage_pct') order by b.batch_code), '[]'::jsonb)
    into v_packing
    from (select p.batch_code, min(p.footprint_id::text)::uuid as fp, count(*) filter (where p.status <> 'void') as n,
                 count(*) filter (where p.status = 'void') as v, min(p.serial) as first, max(p.serial) as last,
                 min(p.packed_on) as packed_on, min(p.best_before) filter (where p.status <> 'void') as bb,
                 count(*) filter (where p.status <> 'void' and p.best_before is null) as no_bb,
                 (select string_agg(x.n || ' × ' || x.label, ', ' order by x.size desc, x.label)
                    from (select count(*) as n, coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg') as label,
                                 max(k2.size_kg) as size
                            from public.packs k2 left join public.pack_skus sk on sk.id = k2.sku_id
                           where k2.batch_code = p.batch_code and k2.status <> 'void'
                           group by coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg')) x) as by_size
            from public.packs p where p.scope_id = p_scope group by p.batch_code) b
    left join public.footprints pf on pf.id = b.fp;

  -- sales and shipments: per order, its shipments, delivery and proof of delivery; prices only in the internal copy, only if recorded
  select coalesce(jsonb_agg(jsonb_build_object('code', c->'code', 'on', coalesce(c->'happened_on', c->'recorded_at'),
           'buyer', c->'buyer', 'market', c->'market', 'country', c->'destination_country', 'order_no', c->'order_no',
           'packs', (select string_agg((l->>'units') || ' × ' || coalesce(app.sku_name(k), '?'), ', ' order by k.size desc nulls last)
                       from public.footprints cf, jsonb_array_elements(case when jsonb_typeof(cf.payload->'packs') = 'array' then cf.payload->'packs' else '[]'::jsonb end) l
                       left join public.pack_skus k on k.id::text = l->>'sku_id'
                      where cf.id = (c->>'_id')::uuid),
           'kg', c->'qty_out_kg', 'incoterms', c->'incoterms',
           'price_per_kg', c->'price_per_kg', 'currency', c->'currency', 'total_value', c->'total_value',
           'shipments', coalesce((select jsonb_agg(jsonb_build_object('code', s->'code', 'kg', s->'qty_in_kg', 'invoice_no', s->'invoice_no',
                 'dispatch_date', s->'dispatch_date', 'destination', s->'destination', 'container_no', s->'container_no', 'bl_no', s->'bl_no',
                 'delivered_on', d.received_on, 'received_kg', d.received_kg, 'transit_loss_kg', d.transit_loss_kg,
                 'pod', case when c->>'market' <> 'export' then 'not_needed'
                             when exists (select 1 from public.attachments a where a.footprint_id = (s->>'_id')::uuid and a.label = 'pod') then 'attached'
                             else 'awaiting' end,
                 'sealed', (select q.qr_code from public.footprints qf join public.qr_seals q on q.footprint_id = qf.id
                             where qf.prev_footprint_id = (s->>'_id')::uuid and qf.stage_type = 'qr_activation' and qf.status not in ('superseded', 'legacy') limit 1))
                 order by s->>'code')
               from jsonb_array_elements(recs) s left join public.deliveries d on d.shipment_id = (s->>'_id')::uuid
              where s->>'stage' = 'shipment'
                and (select f.prev_footprint_id from public.footprints f where f.id = (s->>'_id')::uuid) = (c->>'_id')::uuid), '[]'::jsonb))
           order by c->>'code'), '[]'::jsonb)
    into v_sales
    from jsonb_array_elements(recs) c where c->>'stage' = 'commercial';

  -- QR: packs released per batch; scans by city; copy flags; investigations and recalls with their outcome
  select jsonb_build_object('batches', v_states,
      'scans_by_city', coalesce((select jsonb_agg(jsonb_build_object('city', city, 'country', country, 'scans', n) order by n desc, city)
                                  from (select coalesce(s.city, '') as city, coalesce(s.country, '') as country, count(*) as n
                                          from public.scans s where s.code = any (v_codes) group by 1, 2) x), '[]'::jsonb),
      'copy_flags', coalesce((select jsonb_agg(jsonb_build_object('serial', f.serial, 'kind', f.kind, 'status', f.status,
                                'raised_at', f.raised_at, 'decided_at', f.decided_at, 'reason', f.reason) order by f.raised_at)
                                from public.scan_flags f where f.scope_id = p_scope), '[]'::jsonb),
      'releases', coalesce((select jsonb_agg(jsonb_build_object('qr_code', q.qr_code, 'status', e.status, 'reason', e.reason, 'at', e.at)
                                order by e.at)
                              from public.release_events e join public.qr_seals q on q.footprint_id = e.seal_id
                              join public.footprints f on f.id = e.seal_id
                             where f.scope_id = p_scope and e.status <> 'active'), '[]'::jsonb))
    into v_qr;

  -- chain and integrity: per stage, who recorded and verified, same person, returns, flags and warnings, manager recordings
  select coalesce(jsonb_agg(jsonb_build_object('stage', ch.stage, 'pos', ch.pos,
           'records', (select count(*) from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'recorded_by', (select coalesce(jsonb_agg(distinct u.display_name), '[]'::jsonb) from public.footprints f join public.app_users u on u.id = f.created_by
                            where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'verified_by', (select coalesce(jsonb_agg(distinct u.display_name), '[]'::jsonb) from public.footprints f join public.app_users u on u.id = f.verified_by
                            where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'same_person', (select count(*) from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage
                            and f.status not in ('superseded', 'legacy') and ch.stage <> 'qr_activation' and f.verified_by = f.created_by),
           'returns', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'reason', r.reason, 'status', r.status) order by r.returned_at), '[]'::jsonb)
                        from public.footprint_returns r join public.footprints f on f.id = r.footprint_id
                       where r.scope_id = p_scope and f.stage_type = ch.stage),
           'flags', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'kind', fl.kind, 'text', fl.text, 'status', fl.status) order by fl.created_at), '[]'::jsonb)
                      from public.flags fl join public.footprints f on f.id = fl.footprint_id where f.scope_id = p_scope and f.stage_type = ch.stage),
           'warnings', (select coalesce(sum(cardinality(f.warnings)), 0) from public.footprints f
                         where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'manager_records', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'reason', f.manager_reason) order by f.created_at), '[]'::jsonb)
                                from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage and f.manager_reason is not null))
           order by ch.pos), '[]'::jsonb)
    into v_chain
    from unnest(sc.chain) with ordinality ch(stage, pos);

  -- the ledger: the last full check; the scope's blocks, the first and the last
  select jsonb_build_object(
      'last_check', (select jsonb_build_object('at', c.checked_at, 'ok', c.ok, 'blocks', c.blocks, 'problem', c.problem)
                       from public.ledger_checks c order by c.checked_at desc limit 1),
      'blocks', (select count(*) from public.ledger l where l.scope_id = p_scope),
      'first_hash', (select l.hash from public.ledger l where l.scope_id = p_scope order by l.seq limit 1),
      'last_hash', (select l.hash from public.ledger l where l.scope_id = p_scope order by l.seq desc limit 1))
    into v_ledger;

  -- open items now (a final report adds what the close carried over)
  select jsonb_build_object(
      'flags', coalesce((select jsonb_agg(jsonb_build_object('code', f.footprint_code, 'kind', fl.kind, 'text', fl.text) order by fl.created_at)
                          from public.flags fl join public.footprints f on f.id = fl.footprint_id where f.scope_id = p_scope and fl.status = 'open'), '[]'::jsonb),
      'awaiting_pod', coalesce((select jsonb_agg(s->'code' order by s->>'code') from jsonb_array_elements(v_sales) c, jsonb_array_elements(c->'shipments') s
                                 where s->>'pod' = 'awaiting' or (c->>'market' = 'export' and s->>'delivered_on' is null)), '[]'::jsonb),
      'pending', (select count(*) from public.footprints f where f.scope_id = p_scope and f.status = 'pending'),
      'lab_hold', (select count(*) from public.qc_samples q where q.scope_id = p_scope and q.status = 'sent' and q.qc_footprint_id is null),
      'packs_held', v_headline->'packs_held')
    into v_open;

  return jsonb_build_object('copy', case when p_internal then 'internal' else 'shareable' end,
    'cover', v_head || jsonb_build_object('scope_code', sc.short_code, 'gi_earned', coalesce((v_headline->>'gi_pct')::numeric, 0) > 0,
               'districts', (select coalesce(jsonb_agg(distinct v->>'district') filter (where v->>'district' is not null), '[]'::jsonb)
                               from jsonb_array_elements(v_origin->'villages') v),
               'delivery_model', sc.delivery_model /* migration 67 (B4) */, 'period_from', v_period->'from', 'period_to', v_period->'to'),
    'units', app.param_units(p_scope),
    'headline', v_headline, 'balance', v_balance, 'origin', v_origin, 'quality', v_quality, 'packing', v_packing,
    'sales', v_sales, 'qr', v_qr, 'chain', v_chain, 'ledger', v_ledger, 'open_items', v_open);
end $function$;


-- the owner reads its client's buyer links and their views (to revoke one); nobody else beyond the scope's managers
alter policy buyer_links_read on public.buyer_links using (app.i_manage_scope(scope_id) or app.client_owner_check(client_id));
alter policy buyer_link_views_read on public.buyer_link_views using (exists (select 1 from public.buyer_links l
  where l.id = buyer_link_views.link_id and (app.i_manage_scope(l.scope_id) or app.client_owner_check(l.client_id))));

-- 11 · grants: the functions above are the way in -------------------------------------------------------------------------
revoke execute on function app.scopes_settings_guard(), app.assignments_client_account(), app.my_client_account(), app.client_owner_check(uuid), app.client_reader_of(uuid),
  app.account_reaches(uuid, uuid), app.account_states(uuid, uuid), app.account_sees_farmer(uuid, uuid, uuid, uuid),
  app.client_operator_for(uuid, uuid), app.client_internal_ok(),
  app.client_owner_active(uuid, uuid), app.client_was_activated(uuid), app.client_may(text, uuid, uuid), app.client_table_act(text), app.footprints_client_staff(),
  app.scope_doc_scope(text), app.may_write_scope_doc(text), app.may_read_scope_doc(text), app.check_viewer_reach(uuid, text, uuid, uuid[], text),
  app.may_manage_account(uuid), app.client_may_evidence(text)
  from public, anon, authenticated;
grant execute on function app.client_may_evidence(text), app.may_write_scope_doc(text), app.may_read_scope_doc(text),
  app.client_owner_check(uuid) to authenticated;          -- the store's and the buyer links' read rules ask them as the caller (about the caller only)
revoke execute on function app.set_scope_delivery(uuid, text, text), app.set_scope_gi_user(uuid, text, text, text),
  app.prepare_client_account(uuid, text, text, text, uuid, uuid[], boolean), app.set_client_account_status(uuid, text, text),
  app.set_client_viewer(uuid, text, uuid, uuid[]), app.set_viewer_internal(uuid, boolean), app.make_client_owner(uuid),
  app.client_accounts_of(uuid), app.add_client_acceptance(uuid, text, text)
  from public, anon;
grant execute on function app.set_scope_delivery(uuid, text, text), app.set_scope_gi_user(uuid, text, text, text),
  app.prepare_client_account(uuid, text, text, text, uuid, uuid[], boolean), app.set_client_account_status(uuid, text, text),
  app.set_client_viewer(uuid, text, uuid, uuid[]), app.set_viewer_internal(uuid, boolean), app.make_client_owner(uuid),
  app.client_accounts_of(uuid), app.add_client_acceptance(uuid, text, text)
  to authenticated;

notify pgrst, 'reload schema';
