-- Migration 65 (Phase 2, release 2 of Veda's combined brief of 19 Oct 2026: Part C and Part D). A client in several
-- states; its status per state (suspend, resume, end, return); the warnings before a licence or an agreement expires;
-- what the public pages say while a client is suspended or ended, and how long they stay live after its contract ends.
--
--   C   app.add_client_state: the State Manager of another state adds his state to a client already registered (the
--       client code stays; the state goes through its own gates; the national items are reused and show "on file").
--       The client's other State Managers, its owner (its login) and the admins are notified (public.notifications,
--       app.my_notifications, app.read_notifications). The State Manager of any of the client's states may give it a
--       Client Manager (app.may_assign); the Client Manager stays one per client, as today. A scope may be made in any
--       state of the client where it is Diagnostic or Active (app.client_scope_states, for the scope's form).
--   D   app.client_set_status: suspend (from Active), resume, end, return (Ended → Diagnostic: Gate 3 and the KYC tick
--       again), per state by its State Manager or the admin, nationally (every state) by the admin; a reason every time;
--       a status the admin set is moved back by the admin. While suspended: no new procurement or entry (work in progress
--       may finish to Packing), no sale, shipment or release (trigger a02_client_status); released pages stay live and say
--       "Verification paused". Ended: every scope of the client in that state reads only; the public pages say
--       "Verification ended on …" and stay live for the longer of best-before + 12 months and 24 months after the end.
--       Warnings, never an automatic suspension: app.client_expiries (the FSSAI licence per state, the RCMC and the MSA
--       nationally: 60 and 15 days ahead, and after expiry).
--   B5  the client's own login uploads a renewed licence or agreement (app.propose_client_renewal); the State Manager
--       accepts it (app.decide_client_renewal), which files it as the current document and moves the expiry.
-- Additive: new columns on public.client_states, new tables public.notifications and public.client_renewals, new
-- functions; replaced, each from its own text with the change named: app.public_lot_journey, app.public_pack,
-- app.buyer_view (the verification line), app.may_assign (a Client Manager by the State Manager of any of the client's
-- states), app.client_view and app.lookup_pan (the states one may add; the national documents "on file" for another
-- state), app.add_client_document (the national documents by the home state's State Manager),
-- app.may_read_client_file and app.may_write_client_object (the client's renewals).
select set_config('app.change_path', 'migration 65', true);

-- 1 · the status's columns ---------------------------------------------------------------------------------------------
alter table public.client_states add column if not exists ended_on date;                       -- the day the contract ended here
alter table public.client_states add column if not exists status_by_admin boolean not null default false;   -- set by the admin: moved back by the admin
alter table public.client_states add column if not exists status_reason text;

-- 2 · notifications: one row per person told ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.app_users(id),
  kind text not null check (kind in ('client_state_added', 'client_suspended', 'client_resumed', 'client_ended', 'client_returned',
                                     'client_renewal')),
  client_id uuid references public.clients(id),
  state_id uuid references public.states(id),
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists notifications_user on public.notifications (user_id, created_at desc);
alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;
create or replace function app.notifications_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'a notification is kept' using errcode = '42501'; end if;
  if (to_jsonb(new) - 'read_at') is distinct from (to_jsonb(old) - 'read_at') then
    raise exception 'a notification is only marked read' using errcode = '42501'; end if;
  return new;
end $$;
create trigger notifications_a0_guard before update or delete on public.notifications for each row execute function app.notifications_guard();

-- 3 · renewals the client's own login uploads, for its State Manager to accept ----------------------------------------
create table if not exists public.client_renewals (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  state_id uuid references public.states(id),                  -- the FSSAI licence's state; null for the RCMC and the MSA
  kind public.client_doc_kind not null check (kind in ('fssai', 'rcmc', 'msa')),
  path text not null unique,
  file_name text,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes bigint not null check (bytes > 0),
  signed_on date,
  term_end date,
  expires_on date,
  proposed_by uuid,
  proposed_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  accepted boolean,
  reason text,
  document_id uuid references public.client_documents(id)
);
alter table public.client_renewals enable row level security;
revoke all on public.client_renewals from anon, authenticated;
create trigger zz_change_log after insert or update or delete on public.client_renewals for each row execute function app.log_change('id');
create or replace function app.client_renewals_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'a renewal is kept' using errcode = '42501'; end if;
  if old.decided_at is not null then raise exception 'a renewal is decided once' using errcode = '42501'; end if;
  if (to_jsonb(new) - array['decided_by', 'decided_at', 'accepted', 'reason', 'document_id']) is distinct from
     (to_jsonb(old) - array['decided_by', 'decided_at', 'accepted', 'reason', 'document_id']) then
    raise exception 'a renewal''s file and dates are not changed' using errcode = '42501'; end if;
  return new;
end $$;
create trigger client_renewals_a0_guard before update or delete on public.client_renewals for each row execute function app.client_renewals_guard();

-- 4 · who is told ------------------------------------------------------------------------------------------------------
-- the client's State Managers (every state it is in), its owner (its login), the admins; never the person acting. The
-- owner's line carries no reason (a suspension's reason is GrainVeda's).
create or replace function app.notify_client(p_kind text, p_client uuid, p_state uuid, p_data jsonb) returns int
language plpgsql security definer set search_path = public as $$
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
       and a.lens = 'client' and a.op_role = 'client_viewer' and a.client_id = p_client),
  everyone as (
    select u, bool_or(owner) as owner from (select * from staff union all select * from owners) x
     where me is null or u <> me group by u)
  insert into public.notifications (user_id, kind, client_id, state_id, data)
  select e.u, p_kind, p_client, p_state, case when e.owner and not exists (select 1 from staff s where s.u = e.u) then p_data - 'reason' else p_data end
    from everyone e;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function app.my_notifications() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'client_id', n.client_id, 'state_id', n.state_id,
           'data', n.data, 'created_at', n.created_at, 'read', n.read_at is not null) order by n.read_at is not null, n.created_at desc), '[]'::jsonb)
    from (select * from public.notifications where user_id = app.current_user_id() order by created_at desc limit 50) n
$$;

create or replace function app.read_notifications(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.notifications set read_at = now()
   where user_id = app.current_user_id() and read_at is null and id = any (coalesce(p_ids, '{}'::uuid[]));
  get diagnostics n = row_count;
  return n;
end $$;

-- 5 · C: a State Manager adds his state to a client already registered ------------------------------------------------
-- the states of his own that he may still add (none for the admin, a client's login or someone without a state)
create or replace function app.addable_states(p_client uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when app.is_admin() or app.is_client_login() then '[]'::jsonb else
    coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name) from public.states s
               where s.id = any (app.my_state_ids())
                 and not exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.state_id = s.id)), '[]'::jsonb) end
$$;

create or replace function app.add_client_state(p_client uuid, p_state uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); c public.clients; v_state text;
begin
  if app.is_admin() or app.is_client_login() or not (p_state = any (app.my_state_ids())) then
    raise exception 'a state is added to a client by that state''s State Manager' using errcode = '42501'; end if;
  select * into c from public.clients where id = p_client for update;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.client_states where client_id = p_client and state_id = p_state) then
    raise exception 'this client is already in this state' using errcode = '23505'; end if;
  select name into v_state from public.states where id = p_state;
  insert into public.client_states (client_id, state_id, status, created_by) values (p_client, p_state, 'prospect', me);
  if not (p_state = any (c.states_of_interest)) then
    update public.clients set states_of_interest = states_of_interest || p_state where id = p_client;
  end if;
  perform app.client_event(p_client, p_state, null, 'prospect', 'state_added');
  perform app.audit('client_state_added', p_client, jsonb_build_object('state_id', p_state, 'state', v_state), false);
  perform app.notify_client('client_state_added', p_client, p_state, jsonb_build_object('client', c.name, 'code', c.code, 'state', v_state,
    'by', (select display_name from public.app_users where id = me)));
  return app.client_view(p_client);
end $$;

-- the states a scope of this client may be made in (the scope's form): for whoever runs the client, its State Managers
-- and the admin; each with its status (a scope is prepared in Diagnostic or Active)
create or replace function app.client_scope_states(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (app.is_admin() or app.runs_client(p_client) or app.sm_of_client(p_client)) then
    raise exception 'not found' using errcode = 'P0002'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', cs.status) order by s.name), '[]'::jsonb)
            from public.client_states cs join public.states s on s.id = cs.state_id
           where cs.client_id = p_client and (app.is_admin() or app.runs_client(p_client) or cs.state_id = any (app.my_state_ids())));
end $$;

-- 6 · D: the status per state -------------------------------------------------------------------------------------------
-- p_to: suspended (from Active), active (resume, from Suspended), ended (from Prospect, Diagnostic, Active or Suspended),
-- diagnostic (return, from Ended: Gate 3 and the KYC tick again). p_state null: every state of the client (the admin).
create or replace function app.client_set_status(p_client uuid, p_state uuid, p_to public.client_status, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_admin boolean := app.is_admin(); v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); cs public.client_states;
        c public.clients; v_act text; v_from public.client_status[]; n int := 0; v_states text[] := '{}'; v_kind text;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if p_state is null and not v_admin then
    raise exception 'a client is suspended or ended in every state at once by the admin' using errcode = '42501'; end if;
  if p_state is not null and not (v_admin or app.sm_of_client(p_client, p_state)) then
    raise exception 'the client''s status in a state is changed by that state''s State Manager or the admin' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'status: a reason of 10 characters or more' using errcode = '22023'; end if;
  case p_to
    when 'suspended' then v_act := 'suspended'; v_from := array['active']::public.client_status[]; v_kind := 'client_suspended';
    when 'active' then v_act := 'resumed'; v_from := array['suspended']::public.client_status[]; v_kind := 'client_resumed';
    when 'ended' then v_act := 'ended'; v_from := array['prospect', 'diagnostic', 'active', 'suspended']::public.client_status[]; v_kind := 'client_ended';
    when 'diagnostic' then v_act := 'returned'; v_from := array['ended']::public.client_status[]; v_kind := 'client_returned';
    else raise exception 'status: suspend, resume, end or return' using errcode = '22023';
  end case;
  for cs in select * from public.client_states where client_id = p_client and (p_state is null or state_id = p_state) order by state_id for update loop
    if not (cs.status = any (v_from)) then
      if p_state is not null then
        raise exception 'status: a client % cannot be %', cs.status, v_act using errcode = '23514'; end if;
      continue;                                                       -- nationally: the states this applies to
    end if;
    if cs.status in ('suspended', 'ended') and cs.status_by_admin and not v_admin then
      raise exception 'the admin % this client here: the admin moves it back', cs.status using errcode = '42501'; end if;
    update public.client_states
       set status = p_to, status_changed_at = now(), status_by_admin = v_admin, status_reason = v_reason,
           ended_on = case when p_to = 'ended' then app.today() when p_to = 'diagnostic' then null else ended_on end,
           kyc_at = case when p_to = 'diagnostic' then null else kyc_at end,
           kyc_by = case when p_to = 'diagnostic' then null else kyc_by end,
           activation_requested_at = case when p_to in ('ended', 'diagnostic') then null else activation_requested_at end,
           activation_requested_by = case when p_to in ('ended', 'diagnostic') then null else activation_requested_by end
     where client_id = cs.client_id and state_id = cs.state_id;
    perform app.client_event(p_client, cs.state_id, cs.status, p_to, v_act, v_reason);
    v_states := v_states || (select name from public.states where id = cs.state_id);
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'status: no state of this client can be %', v_act using errcode = '23514'; end if;
  perform app.audit('client_status', p_client, jsonb_build_object('state_id', p_state, 'national', p_state is null, 'act', v_act, 'to', p_to,
    'states', to_jsonb(v_states), 'reason', v_reason), false);
  perform app.notify_client(v_kind, p_client, p_state, jsonb_build_object('client', c.name, 'code', c.code,
    'state', case when p_state is null then null else v_states[1] end, 'national', p_state is null,
    'by', (select display_name from public.app_users where id = app.current_user_id()), 'reason', v_reason));
  return app.client_view(p_client);
end $$;

-- the client's status in a scope's state decides what may still be written there
create or replace function app.client_status_of_scope(p_scope uuid) returns public.client_states
language sql stable security definer set search_path = public as $$
  select cs.* from public.scopes s join public.client_states cs on cs.client_id = s.client_id and cs.state_id = s.state_id where s.id = p_scope
$$;

-- Suspended: no new entry (procurement, lot inward), no sale, shipment or release; the work in progress finishes to
-- Packing (processing, QC, Packing, its packs and labels, the warehouse; verification of records already made). Ended:
-- the scope's records read only (as a closed scope; the proof of a delivery already shipped may still come).
create or replace function app.client_status_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); v_scope uuid; v_fp uuid; cs public.client_states; v_stage text;
begin
  if tg_table_name = 'footprints' then
    v_scope := (r ->> 'scope_id')::uuid;
  else
    v_fp := coalesce(r ->> 'shipment_id', r ->> 'footprint_id')::uuid;
    v_scope := coalesce((r ->> 'scope_id')::uuid, (select f.scope_id from public.footprints f where f.id = v_fp));
  end if;
  if v_scope is null then return case when tg_op = 'DELETE' then old else new end; end if;
  cs := app.client_status_of_scope(v_scope);
  if cs.status = 'ended' then
    if tg_op = 'INSERT' and ((tg_table_name = 'deliveries') or (tg_table_name = 'attachments' and r ->> 'label' = 'pod'))
       and app.awaits_pod(v_fp) then
      return new;
    end if;
    raise exception 'this client''s contract has ended in this state: its records are read only' using errcode = '42501';
  end if;
  if cs.status = 'suspended' and tg_op = 'INSERT' then
    v_stage := r ->> 'stage_type';
    if tg_table_name = 'footprints' and v_stage in ('procurement', 'lot_inward') then
      raise exception 'this client is suspended in this state: no new procurement (work in progress may finish to Packing)' using errcode = '23514'; end if;
    if (tg_table_name = 'footprints' and v_stage in ('commercial', 'shipment', 'qr_activation')) or tg_table_name = 'qr_seals' then
      raise exception 'this client is suspended in this state: no sale, shipment or release until it is resumed' using errcode = '23514'; end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
do $$
declare t text;
begin
  foreach t in array array['flags', 'attachments', 'deliveries', 'packs', 'cartons', 'label_prints', 'footprint_returns', 'qc_samples',
                           'sale_terms', 'export_documents', 'warehouse_inspections', 'warehouse_bags_out', 'net_weight_checks',
                           'withdrawals', 'lot_closures', 'qr_seals', 'pack_batches', 'footprints'] loop
    execute format('create trigger a02_client_status before insert or update or delete on public.%I for each row execute function app.client_status_guard()', t);
  end loop;
end $$;

-- an ended client's scopes read only (a person acting; seeds and migrations are not people)
create or replace function app.scopes_client_ended() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and exists (select 1 from public.client_states cs where cs.client_id = old.client_id and cs.state_id = old.state_id
                                                                              and cs.status = 'ended') then
    raise exception 'this client''s contract has ended in this state: its records are read only' using errcode = '42501'; end if;
  return new;
end $$;
create trigger scopes_a1c_client_ended before update on public.scopes for each row execute function app.scopes_client_ended();

-- 7 · the public pages: "Verification paused", "Verification ended on …", and how long they stay live ---------------------
create or replace function app.client_verification(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case cs.status when 'suspended' then jsonb_build_object('status', 'paused')
                        when 'ended' then jsonb_build_object('status', 'ended', 'ended_on', cs.ended_on) end
    from app.client_status_of_scope(p_scope) cs
$$;

-- Part F: a released page stays live for the longer of best-before + 12 months and 24 months after the contract ended
create or replace function app.public_verification(p_scope uuid, p_best_before date, p_page jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; v_until date; v_ended date;
begin
  if p_page is null then return null; end if;
  v := app.client_verification(p_scope);
  if v is null then return p_page; end if;
  if v ->> 'status' = 'ended' then
    v_ended := (v ->> 'ended_on')::date;
    v_until := greatest((v_ended + interval '24 months')::date, coalesce((p_best_before + interval '12 months')::date, '-infinity'::date));
    v := v || jsonb_build_object('live_until', v_until);
    if app.today() > v_until then
      return jsonb_build_object('expired', true, 'verification', v,
        'crop', jsonb_build_object('name', (select cr.name from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope)));
    end if;
  end if;
  return p_page || jsonb_build_object('verification', v);
end $$;

-- 8 · the functions replaced, each from its text as migration 64 left it, with the change named -----------------------
-- the journey page: "Verification paused" / "ended on …"; expired after the lifetime rule (Part D, Part F)
CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false; v_mkt text; v_dest text;   -- v_mkt, v_dest: migration 57
        v_src uuid[]; v_buy jsonb;                                                                              -- migration 61 (E2.3)
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
      -- migration 50 (Part D): the village and the district, never the farmer's name or photo
      step := step || jsonb_build_object('farmer', jsonb_build_object('village', fm.village, 'district', fm.district));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id))
                   || jsonb_build_object('lab', (select case when l->>'name' is null then null
                        else jsonb_build_object('name', l->>'name', 'accreditation_no', l->>'accreditation_no') end
                        from (select app.qc_lab(cur.id) as l) x))                                       -- migration 60 (A5 on the public page)
                   || jsonb_build_object('markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name,
                        'verdict', pv.verdict, 'failed', pv.failed,
                        'limits', (select mp.params from public.market_profiles mp where mp.id = pv.profile_id))   -- migration 57
                        order by pv.created_at, pv.code), '[]'::jsonb)
                        from public.qc_profile_verdicts pv where pv.footprint_id = cur.id));                      -- migration 53
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'warehouse' then step := step || jsonb_build_object('days_in_storage', app.storage_days(cur.id)); end if;   -- migration 55
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', coalesce(cur.payload->>'village',      -- migration 52: from the lots
             app.batch_villages(cur.id)),                    -- migration 52b: the villages only, through a helper
        'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.village, g.qty_kg)
          from (select fa.name, fa.village, fa.district, sum(src.qty_out) as qty_kg                -- migration 49: one line a farmer
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb),
        -- migration 61 (E2.3): "2 farmers from 2 villages", the real counts
        'villages_n', (select count(distinct (fa.village, fa.district)) from public.footprints src join public.farmers fa on fa.id = src.farmer_id   -- migration 61b
                        where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)));
    end if;
    if cur.stage_type = 'shipment' then   -- migration 57: an export's country; nothing of a domestic dispatch's place
      select coalesce(o.payload->>'market', 'domestic'), o.payload->>'destination_country' into v_mkt, v_dest      -- the order's own words
        from public.footprints o where o.id = cur.prev_footprint_id and o.stage_type = 'commercial';
      step := step || jsonb_build_object('dispatched_on', cur.payload->>'dispatch_date',
        'destination', case when v_mkt = 'export' then coalesce(v_dest, cur.payload->>'destination') end);   -- before 54: the typed place
    end if;
    -- migration 57 (G21): checked by someone other than who recorded it (the public page says so only where true)
    step := step || jsonb_build_object('checked', cur.stage_type <> 'qr_activation' and cur.verified_by is not null
              and cur.verified_by <> cur.created_by
              and not exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory'),
              -- migration 59 (A2, Veda's brief of 19 Oct): the step recorded and checked by one person says so
              'same_person', cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by);
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
    -- migration 61 (E2.3, Veda's brief of 19 Oct 2026): a collection batch was bought from several farmers. One line for
    -- all the purchases ("Bought from 2 farmers: 250 kg", the villages' shares; never a name), not only the one its
    -- record points back to; each purchase still counts for "checked by another person".
    if cur.stage_type = 'village_batch' and jsonb_array_length(coalesce(cur.payload->'source_footprint_ids', '[]'::jsonb)) > 0 then
      v_src := array(select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x);
      select jsonb_build_object('stage', 'purchases', 'code', cur.footprint_code || ':purchases',
               'qty_in_kg', sum(src.qty_out), 'qty_out_kg', sum(src.qty_out), 'verified_at', max(src.verified_at),
               'created_at', min(src.created_at), 'captured_at', min(coalesce(src.captured_at, src.created_at)),
               'farmers_n', count(distinct src.farmer_id), 'purchases_n', count(*),
               'checked', bool_and(src.verified_by is not null and src.verified_by <> src.created_by
                          and not exists (select 1 from public.ledger l where l.footprint_id = src.id and l.event = 'supervisory')),
               'same_person', bool_or(src.verified_by is not null and src.verified_by = src.created_by))
        into v_buy from public.footprints src where src.id = any(v_src);
      v_buy := v_buy || jsonb_build_object('villages', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'farmers', g.n, 'qty_kg', g.kg,
                 'share_pct', round(g.kg / nullif((v_buy->>'qty_out_kg')::numeric, 0) * 100, 1)) order by g.kg desc, g.village)
          from (select fa.village, fa.district, count(distinct fa.id) as n, sum(src.qty_out) as kg                    -- migration 61b: as the heading counts
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id = any(v_src) group by fa.village, fa.district) g), '[]'::jsonb));
      steps := jsonb_build_array(v_buy) || steps;
      if (v_buy->>'same_person')::boolean or not (v_buy->>'checked')::boolean
         or exists (select 1 from public.footprints src where src.id = any(v_src) and src.created_by = cur.created_by) then
        v_independent := false; end if;
      if (v_buy->>'same_person')::boolean
         or exists (select 1 from public.footprints src where src.id = any(v_src) and src.created_by = cur.created_by) then
        v_same := true; end if;
      exit;
    end if;
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  -- migration 65 (Part D): the client's status in the scope's state; an ended client's page lives for the longer of
  -- best-before + 12 months and 24 months after the end (app.public_verification)
  return app.public_verification(v_scope.id, (select max(p.best_before) from app.lot_released_packs(seal.footprint_id) r join public.packs p on p.serial = r.serial),
   jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    -- migration 57 (G21): no same_person here (the ledger keeps it); the villages by share, with their farmers
    'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct, 'farmers', y.n)
                                  order by y.pct desc, y.village)
                 from (select fv.village, fv.district, round(sum(s.share) * 100, 1) as pct, count(distinct e.farmer_id) as n
                         from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id
                         join public.farmers fv on fv.id = e.farmer_id group by fv.village, fv.district) y), '[]'::jsonb),
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    'units', app.param_units(v_scope.id),                                                                 -- migration 59 (A3)
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    -- migration 62 (E2.1): the packs this lot made live (its shipments' codes), not every pack of its batches
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before),
                     'old_data', coalesce(bool_or(r.old_data), false))
                from app.lot_released_packs(seal.footprint_id) r join public.packs p on p.serial = r.serial)
  ));
end $function$;

-- a pack's page: the same, by the pack's own best-before date
CREATE OR REPLACE FUNCTION app.public_pack(p_serial text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.packs; v_seal uuid; q public.qr_seals; sc public.scopes; cr public.crops; v_pack jsonb;
        v_rel jsonb;                                                                                        -- migration 62
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null then return null; end if;
  select * into sc from public.scopes where id = p.scope_id; select * into cr from public.crops where id = sc.crop_id;
  v_pack := jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'size_kg', p.size_kg, 'packed_on', p.packed_on,
              'best_before', p.best_before, 'void', p.status = 'void',
              'copy_warning', app.scan_warning(p.serial), 'seller', (select c.name from public.clients c where c.id = sc.client_id),   -- migration 56
              'carton', p.carton_code,                                                                                         -- migration 58
              -- migration 57: how often this pack was scanned and the first place (a city, never a person)
              'scans', (select jsonb_build_object('n', count(*),
                          'first_city', (select f.city from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1),
                          'first_country', (select f.country from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1))
                          from public.scans x where x.code = p.serial));
  -- migration 62 (E2.1): live only when a sealed shipment carries it (or, for records of before, its lot's shipment
  -- recorded no codes: "Released, serials not recorded (old data)"); never because another pack of its batch was sealed
  v_rel := app.pack_release(p.serial);
  v_seal := case when v_rel->>'state' in ('released', 'old_data') then (v_rel->>'seal')::uuid end;
  if v_seal is null or p.status = 'void' then
    -- migration 59 (A1): before release, the crop, the batch code and the date packed; nothing else (a voided pack says so; a copied code is warned of, without the seller)
    return app.public_verification(sc.id, p.best_before, jsonb_build_object('released', false,   -- migration 65
      'pack', jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'packed_on', p.packed_on, 'void', p.status = 'void',
                                 'best_before', case when p.status <> 'void' then p.best_before end,   -- migration 61 (E2.4)
                                 'copy_warning', app.scan_warning(p.serial)),
      'crop', jsonb_build_object('name', cr.name)));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_verification(sc.id, p.best_before, app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack || jsonb_build_object('old_data', v_rel->>'state' = 'old_data'),   -- migration 62
                                                                   'released', true));
end $function$;

-- the buyer's link: the same line (the link keeps its own expiry)
CREATE OR REPLACE FUNCTION app.buyer_view(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.buyer_links;
begin
  l := app.buyer_link_of(p_token);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  insert into public.buyer_link_views (link_id, what) values (l.id, 'open');
  return jsonb_build_object('ok', true, 'expires_at', l.expires_at, 'content', app.buyer_content(l.footprint_id),
    'verification', app.client_verification((select f.scope_id from public.footprints f where f.id = l.footprint_id)));   -- migration 65
end $function$;

-- Part C: a Client Manager is given by the State Manager of any of the client's states (one per client, as today)
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
                      where a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_target)
                                                   or exists (select 1 from public.client_states cs where cs.client_id = p_target and cs.state_id = a.state_id)));   -- migration 65
    end if;
    return app.manages_client(me, p_target);                                  -- the client's own login
  end if;
  return app.manages_scope(me, p_target);                                     -- a scope: by whoever manages it
end $function$;

-- the record: the states one may add (Part C); the national documents "on file" for a State Manager of another than the home state (A4)
CREATE OR REPLACE FUNCTION app.client_view(p_client uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare c public.clients; e public.entities; v_admin boolean := app.is_admin(); v_owner boolean; v_cm boolean;
        v_sm_states uuid[]; v_full boolean; v_states jsonb; v_reg public.id_kind; v_nat jsonb; v_see uuid[];
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id;
  v_owner := app.client_owner_of(p_client);
  v_cm := app.cm_of_client(p_client);
  v_sm_states := case when app.is_client_login() then '{}'::uuid[]
                      else array(select cs.state_id from public.client_states cs where cs.client_id = p_client and cs.state_id = any (app.my_state_ids())) end;
  if not (v_admin or v_owner or v_cm or cardinality(v_sm_states) > 0) then
    -- a State Manager of another state: the shared identity only (A4); everyone else: nothing
    if cardinality(app.my_state_ids()) > 0 and not app.is_client_login() then
      return jsonb_build_object('identity', app.client_identity(p_client), 'shared_only', true, 'states', '[]'::jsonb,
                                'may', jsonb_build_object('add_state', true, 'add_states', app.addable_states(p_client)));   -- migration 65
    end if;
    raise exception 'not found' using errcode = 'P0002';
  end if;
  v_full := v_admin or cardinality(v_sm_states) > 0;              -- A3: the numbers in full for these only
  v_see := case when v_admin or v_owner then array(select state_id from public.client_states where client_id = p_client)
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
      'renew', v_owner));
end $function$;

-- "Already registered with GrainVeda": and the states of his own he may add (Part C)
CREATE OR REPLACE FUNCTION app.lookup_pan(p_pan text, p_name text DEFAULT NULL::text, p_type entity_type DEFAULT NULL::entity_type)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v text; e public.entities; c uuid;
begin
  if not (app.is_admin() or (cardinality(app.my_state_ids()) > 0 and not app.is_client_login())) then
    raise exception 'only a State Manager registers a client' using errcode = '42501'; end if;
  v := app.check_pan(p_pan, p_type);
  select en.* into e from public.entity_ids i join public.entities en on en.id = i.entity_id
   where i.kind = 'pan' and i.current and i.hash = app.id_hash('pan', v);
  if e.id is null then
    return jsonb_build_object('situation', 'new', 'similar', p_name is not null and app.similar_entity(p_name));
  end if;
  select id into c from public.clients where entity_id = e.id limit 1;
  if c is not null then
    return jsonb_build_object('situation', 'client', 'identity', app.client_identity(c),
      'in_my_state', exists (select 1 from public.client_states cs where cs.client_id = c and cs.state_id = any (app.my_state_ids())),
      'add_states', app.addable_states(c));   -- migration 65
  end if;
  -- known in another role: nothing about that role is shown (A1, A2)
  return jsonb_build_object('situation', 'known', 'similar', false);
end $function$;

-- the national documents are kept by the home state's State Manager; another state reuses them "on file"
CREATE OR REPLACE FUNCTION app.add_client_document(p_client uuid, p_state uuid, p_kind client_doc_kind, p_path text, p_sha256 text, p_bytes bigint, p_file_name text DEFAULT NULL::text, p_meta jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare old public.client_documents; d public.client_documents; v_state uuid; v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
begin
  if not app.sm_of_client(p_client, p_state) then
    raise exception 'the client''s documents are added by the State Manager of this state' using errcode = '42501'; end if;
  if exists (select 1 from public.client_states where client_id = p_client and state_id = p_state and status in ('suspended', 'ended')) then
    raise exception 'this client is suspended or ended in this state' using errcode = '23514'; end if;
  v_state := case when app.doc_is_national(p_kind) then null else p_state end;
  -- migration 65 (Part C): the national items are reused by the states added later, "on file"
  if v_state is null and not app.sm_of_client(p_client, (select c.state_id from public.clients c where c.id = p_client)) then
    raise exception 'the national documents are kept by the State Manager of the client''s home state (here they are on file)' using errcode = '42501'; end if;
  if p_path !~ ('^' || p_client::text || '/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$') then
    raise exception 'document: the file is stored as "<client>/<file id>.pdf" (or jpg, png, webp)' using errcode = '22023'; end if;
  if to_regclass('storage.objects') is not null then
    if not exists (select 1 from storage.objects o where o.bucket_id = 'client-docs' and o.name = p_path) then
      raise exception 'document: the file was not uploaded' using errcode = '22023'; end if;
  end if;
  if p_kind = 'diagnostic_order' and ((v_meta ->> 'signed_on') is null or (v_meta ->> 'amount') is null) then
    raise exception 'diagnostic order: its date and amount' using errcode = '22023'; end if;
  if p_kind = 'msa' and ((v_meta ->> 'signed_on') is null or (v_meta ->> 'term_end') is null) then
    raise exception 'Master Services Agreement: the signed date and the term end date' using errcode = '22023'; end if;
  if p_kind = 'consent_addendum' and (v_meta ->> 'signed_on') is null then
    raise exception 'Farmer Data and Consent Addendum: the signed date' using errcode = '22023'; end if;
  if p_kind in ('fssai', 'rcmc') and (v_meta ->> 'expires_on') is null then
    raise exception '%: its expiry date', case p_kind when 'fssai' then 'FSSAI licence' else 'RCMC' end using errcode = '22023'; end if;
  old := app.cur_doc(p_client, p_kind, v_state);
  if old.id is not null then
    update public.client_documents set superseded_at = now(), superseded_by = app.current_user_id() where id = old.id;
  end if;
  insert into public.client_documents (client_id, state_id, kind, path, file_name, sha256, bytes, signed_on, term_end, expires_on, amount, created_by)
  values (p_client, v_state, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_bytes, nullif(v_meta ->> 'signed_on', '')::date,
          nullif(v_meta ->> 'term_end', '')::date, nullif(v_meta ->> 'expires_on', '')::date, nullif(v_meta ->> 'amount', '')::numeric, app.current_user_id())
  returning * into d;
  update public.client_states set kyc_at = null, kyc_by = null
   where client_id = p_client and status <> 'active' and kyc_at is not null and (v_state is null or state_id = v_state);
  perform app.audit('client_document', p_client, jsonb_build_object('state_id', v_state, 'kind', p_kind, 'sha256', d.sha256,
    'replaces', old.id, 'document_id', d.id), false);
  return to_jsonb(d);
end $function$;

-- the store: a national file by the home state's State Manager; a renewal by the client's login and its State Managers
CREATE OR REPLACE FUNCTION app.may_read_client_file(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.client_documents d where d.path = p_name
                   and (app.is_admin() or app.client_owner_of(d.client_id)
                        or (d.state_id is null and app.sm_of_client(d.client_id, (select c.state_id from public.clients c where c.id = d.client_id)))   -- migration 65
                        or (d.state_id is not null and app.sm_of_client(d.client_id, d.state_id))))
      or exists (select 1 from public.client_renewals r where r.path = p_name                                      -- migration 65
                   and (app.is_admin() or app.client_owner_of(r.client_id)
                        or app.sm_of_client(r.client_id, coalesce(r.state_id, (select c.state_id from public.clients c where c.id = r.client_id)))))
$function$;

-- the store: the client's own login uploads a renewal
CREATE OR REPLACE FUNCTION app.may_write_client_object(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select app.client_doc_client(p_name) is not null and (app.sm_of_client(app.client_doc_client(p_name)) or app.client_owner_of(app.client_doc_client(p_name)))   -- migration 65
$function$;


-- 9 · warnings before a licence or an agreement expires (60 and 15 days ahead, and after) --------------------------------
-- the FSSAI licence of each state; the RCMC and the MSA once per client. For the admin every client; for a State Manager
-- the clients of his states (Active, Diagnostic or Suspended there). Never an automatic suspension.
create or replace function app.client_expiries() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := app.is_admin(); v_states uuid[] := case when app.is_client_login() then '{}'::uuid[] else app.my_state_ids() end;
begin
  if not v_admin and cardinality(v_states) = 0 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('client_id', x.client_id, 'name', x.name, 'code', x.code, 'state_id', x.state_id, 'state', x.state,
            'kind', x.kind, 'expires_on', x.d, 'days_left', x.d - app.today(),
            'level', case when x.d < app.today() then 'expired' when x.d - app.today() <= 15 then 'd15' else 'd60' end)
            order by x.d, x.name, x.kind), '[]'::jsonb)
    from (
      select c.id as client_id, c.name, c.code, cs.state_id, s.name as state, 'fssai' as kind, (app.cur_id(c.entity_id, 'fssai', cs.state_id)).expires_on as d
        from public.client_states cs join public.clients c on c.id = cs.client_id join public.states s on s.id = cs.state_id
       where cs.status in ('diagnostic', 'active', 'suspended') and (v_admin or cs.state_id = any (v_states))
      union all
      select c.id, c.name, c.code, null, null, k.kind,
             case k.kind when 'rcmc' then (app.cur_id(c.entity_id, 'rcmc')).expires_on else (app.cur_doc(c.id, 'msa')).term_end end
        from public.clients c cross join (values ('rcmc'), ('msa')) k(kind)
       where exists (select 1 from public.client_states cs where cs.client_id = c.id and cs.status in ('diagnostic', 'active', 'suspended')
                        and (v_admin or cs.state_id = any (v_states)))) x
   where x.d is not null and x.d - app.today() <= 60);
end $$;

-- 10 · B5: the client's own login uploads a renewed licence or agreement; its State Manager accepts it -------------------
create or replace function app.propose_client_renewal(p_client uuid, p_state uuid, p_kind public.client_doc_kind, p_path text,
                                                      p_sha256 text, p_bytes bigint, p_file_name text default null, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_meta jsonb := coalesce(p_meta, '{}'::jsonb); v_state uuid; r public.client_renewals; c public.clients;
begin
  if not app.client_owner_of(p_client) then raise exception 'a renewal is uploaded by the client''s own login' using errcode = '42501'; end if;
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
end $$;

-- the renewals waiting, for the client's State Managers (an FSSAI licence: its state's) and its own login
create or replace function app.client_renewals(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner boolean := app.client_owner_of(p_client);
begin
  if not (app.is_admin() or v_owner or app.sm_of_client(p_client)) then raise exception 'not found' using errcode = 'P0002'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'kind', r.kind, 'state_id', r.state_id, 'state', s.name, 'file_name', r.file_name,
            'path', r.path, 'signed_on', r.signed_on, 'term_end', r.term_end, 'expires_on', r.expires_on, 'proposed_at', r.proposed_at,
            'decided_at', r.decided_at, 'accepted', r.accepted, 'reason', r.reason,
            'may_decide', r.decided_at is null and not app.is_admin() and not v_owner
                          and app.sm_of_client(p_client, coalesce(r.state_id, (select c.state_id from public.clients c where c.id = p_client))))
            order by r.decided_at is not null, r.proposed_at desc), '[]'::jsonb)
            from public.client_renewals r left join public.states s on s.id = r.state_id
           where r.client_id = p_client
             and (app.is_admin() or v_owner or r.state_id is null or app.sm_of_client(p_client, r.state_id)));
end $$;

create or replace function app.decide_client_renewal(p_renewal uuid, p_accept boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.client_renewals; c public.clients; e public.entities; old public.client_documents; d public.client_documents;
        i public.entity_ids; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_sm_state uuid;
begin
  select * into r from public.client_renewals where id = p_renewal for update;
  if r.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into c from public.clients where id = r.client_id;
  v_sm_state := coalesce(r.state_id, c.state_id);
  if not app.sm_of_client(r.client_id, v_sm_state) then
    raise exception 'a renewal is accepted by the State Manager of the licence''s state (the MSA and the RCMC: the client''s home state)' using errcode = '42501'; end if;
  if r.decided_at is not null then raise exception 'this renewal was decided already' using errcode = '23514'; end if;
  if not p_accept then
    if v_reason is null or length(v_reason) < 10 then raise exception 'declining: a reason of 10 characters or more' using errcode = '22023'; end if;
    update public.client_renewals set decided_by = app.current_user_id(), decided_at = now(), accepted = false, reason = v_reason where id = r.id;
    perform app.audit('client_renewal_declined', r.client_id, jsonb_build_object('renewal_id', r.id, 'kind', r.kind, 'reason', v_reason), false);
    return app.client_renewals(r.client_id);
  end if;
  select * into e from public.entities where id = c.entity_id;
  if r.kind in ('fssai', 'rcmc') then
    i := app.cur_id(e.id, r.kind::text::public.id_kind, r.state_id);
    if i.id is null then raise exception 'renewal: the number is not on file yet: the State Manager types it first (Details)' using errcode = '23514'; end if;
    perform app.put_id(e.id, r.kind::text::public.id_kind, r.state_id, i.value, r.expires_on);   -- the same number, its new expiry
  end if;
  old := app.cur_doc(r.client_id, r.kind, r.state_id);
  if old.id is not null then
    update public.client_documents set superseded_at = now(), superseded_by = app.current_user_id() where id = old.id;
  end if;
  insert into public.client_documents (client_id, state_id, kind, path, file_name, sha256, bytes, signed_on, term_end, expires_on, created_by)
  values (r.client_id, r.state_id, r.kind, r.path, r.file_name, r.sha256, r.bytes, r.signed_on, r.term_end, r.expires_on, app.current_user_id())
  returning * into d;
  update public.client_renewals set decided_by = app.current_user_id(), decided_at = now(), accepted = true, reason = v_reason, document_id = d.id where id = r.id;
  perform app.audit('client_renewal_accepted', r.client_id, jsonb_build_object('renewal_id', r.id, 'kind', r.kind, 'state_id', r.state_id,
    'document_id', d.id, 'replaces', old.id, 'expires_on', coalesce(r.expires_on, r.term_end)), false);
  return app.client_renewals(r.client_id);
end $$;

-- 11 · grants: the functions above are the way in -----------------------------------------------------------------------
revoke execute on function app.notifications_guard(), app.client_renewals_guard(), app.notify_client(text, uuid, uuid, jsonb),
  app.addable_states(uuid), app.client_status_of_scope(uuid), app.client_status_guard(), app.scopes_client_ended(),
  app.client_verification(uuid), app.public_verification(uuid, date, jsonb)
  from public, anon, authenticated;
revoke execute on function app.my_notifications(), app.read_notifications(uuid[]), app.add_client_state(uuid, uuid), app.client_scope_states(uuid),
  app.client_set_status(uuid, uuid, public.client_status, text), app.client_expiries(),
  app.propose_client_renewal(uuid, uuid, public.client_doc_kind, text, text, bigint, text, jsonb), app.client_renewals(uuid),
  app.decide_client_renewal(uuid, boolean, text)
  from public, anon;
grant execute on function app.my_notifications(), app.read_notifications(uuid[]), app.add_client_state(uuid, uuid), app.client_scope_states(uuid),
  app.client_set_status(uuid, uuid, public.client_status, text), app.client_expiries(),
  app.propose_client_renewal(uuid, uuid, public.client_doc_kind, text, text, bigint, text, jsonb), app.client_renewals(uuid),
  app.decide_client_renewal(uuid, boolean, text)
  to authenticated;
-- the replaced public pages keep their grants (create or replace keeps them); said again for a reader
grant execute on function app.public_lot_journey(text), app.public_pack(text), app.buyer_view(text) to anon, authenticated;

notify pgrst, 'reload schema';
