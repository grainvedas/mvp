-- GrainVeda MVP · Phase 0 · migration 5: row-level security (PRD §9 tenant isolation, §4 permissions)
-- Principle: RLS decides what a user SEES and may ATTEMPT; triggers (migration 4) decide what a save may CONTAIN.
-- Service role bypasses RLS but not triggers.

alter table public.states            enable row level security;
alter table public.crops             enable row level security;
alter table public.clients           enable row level security;
alter table public.stage_definitions enable row level security;
alter table public.scopes            enable row level security;
alter table public.app_users         enable row level security;
alter table public.slot_assignments  enable row level security;
alter table public.farmers           enable row level security;
alter table public.footprint_counters enable row level security;
alter table public.footprints        enable row level security;
alter table public.qc_verdicts       enable row level security;
alter table public.qr_seals          enable row level security;
alter table public.flags             enable row level security;
alter table public.attachments       enable row level security;
alter table public.ledger            enable row level security;

grant select on all tables in schema public to authenticated;
grant insert, update on public.scopes, public.app_users, public.slot_assignments, public.farmers,
                       public.footprints, public.qc_verdicts, public.flags, public.attachments to authenticated;
grant insert, update on public.states, public.crops, public.clients, public.stage_definitions to authenticated;
-- ledger: SELECT only, for everyone. INSERT happens inside security-definer functions.
revoke insert, update, delete on public.ledger from authenticated, anon;
-- public verify page: anon reads sealed lots through the view in migration 6, nothing else
revoke all on all tables in schema public from anon;

grant execute on function app.verify_footprint(uuid) to authenticated;
grant execute on function app.seal_lot(uuid, uuid) to authenticated;
grant execute on function app.resolve_market_verdict(uuid) to authenticated;
grant execute on function app.available_qty(uuid) to authenticated;
grant execute on function app.verify_ledger() to authenticated;

-- state ids of the current JWT's user (state_manager)
create or replace function app.my_state_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce((select state_ids from public.app_users where auth_uid = auth.uid() and active), '{}')
$$;

-- ---------------------------------------------------------------------------
-- Reference data: readable by every authenticated user; writable by admin only.
-- ---------------------------------------------------------------------------
create policy states_read on public.states for select to authenticated using (true);
create policy states_admin on public.states for all to authenticated
  using (app.current_role() = 'admin') with check (app.current_role() = 'admin');

create policy crops_read on public.crops for select to authenticated using (true);
create policy crops_admin on public.crops for all to authenticated
  using (app.current_role() = 'admin') with check (app.current_role() = 'admin');

create policy stage_defs_read on public.stage_definitions for select to authenticated using (true);
create policy stage_defs_admin on public.stage_definitions for all to authenticated
  using (app.current_role() = 'admin') with check (app.current_role() = 'admin');

-- ---------------------------------------------------------------------------
-- Clients: visible to those who can access them; admin and state_manager (own state) may create.
-- ---------------------------------------------------------------------------
create policy clients_read on public.clients for select to authenticated using (app.can_access_client(id));
create policy clients_write on public.clients for insert to authenticated
  with check (app.current_role() = 'admin'
           or (app.current_role() = 'state_manager' and state_id = any(app.my_state_ids())));
create policy clients_update on public.clients for update to authenticated
  using (app.current_role() = 'admin'
      or (app.current_role() = 'state_manager' and state_id = any(app.my_state_ids())));

-- ---------------------------------------------------------------------------
-- Scopes: read if accessible; create/update by client_manager of that client, state_manager of that state, admin.
-- ---------------------------------------------------------------------------
create or replace function app.can_manage_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.app_users u join public.clients c on c.id = p_client
    where u.auth_uid = auth.uid() and u.active and (
         u.role = 'admin'
      or (u.role = 'state_manager' and c.state_id = any(u.state_ids))
      or (u.role = 'client_manager' and u.client_id = p_client))
  )
$$;

create policy scopes_read   on public.scopes for select to authenticated using (app.can_access_scope(id));
create policy scopes_insert on public.scopes for insert to authenticated with check (app.can_manage_client(client_id));
create policy scopes_update on public.scopes for update to authenticated using (app.can_manage_client(client_id));

-- ---------------------------------------------------------------------------
-- Users and slots: managers see their client's users; operators see only themselves.
-- ---------------------------------------------------------------------------
create or replace function app.my_client_id() returns uuid
language sql stable security definer set search_path = public as $$
  select client_id from public.app_users where auth_uid = auth.uid() and active
$$;

create policy users_read on public.app_users for select to authenticated
  using (auth_uid = auth.uid()
      or app.current_role() = 'admin'
      or (app.current_role() = 'state_manager' and client_id in (select id from public.clients where state_id = any(app.my_state_ids())))
      or (app.current_role() in ('client_manager','client_view') and client_id = app.my_client_id()));
create policy users_insert on public.app_users for insert to authenticated
  with check (
       app.current_role() = 'admin'
    or (app.current_role() = 'state_manager' and role in ('client_manager','client_view','operator') and app.can_manage_client(client_id))
    or (app.current_role() = 'client_manager' and role in ('client_view','operator') and app.can_manage_client(client_id)));
create policy users_update on public.app_users for update to authenticated
  using (app.current_role() = 'admin' or (client_id is not null and app.can_manage_client(client_id)));

create policy slots_read on public.slot_assignments for select to authenticated
  using (user_id = app.current_user_id() or app.can_access_scope(scope_id));
create policy slots_write on public.slot_assignments for all to authenticated
  using (app.can_manage_client((select client_id from public.scopes where id = scope_id)))
  with check (app.can_manage_client((select client_id from public.scopes where id = scope_id)));

-- ---------------------------------------------------------------------------
-- Farmers: only procurement / village_batch operators (plus managers) see and write them; client_view reads.
-- ---------------------------------------------------------------------------
create or replace function app.farmer_access(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.app_users u
    where u.auth_uid = auth.uid() and u.active and (
         app.is_gateway_role(u.role) and app.can_access_client(p_client)
      or (u.role = 'client_view' and u.client_id = p_client)
      or (u.role = 'operator' and u.client_id = p_client and exists (
            select 1 from public.slot_assignments sa join public.scopes s on s.id = sa.scope_id
            where sa.user_id = u.id and s.client_id = p_client and sa.stage_type in ('procurement','village_batch'))))
  )
$$;

create policy farmers_read on public.farmers for select to authenticated using (app.farmer_access(client_id));
create policy farmers_insert on public.farmers for insert to authenticated
  with check (app.farmer_access(client_id) and app.current_role() <> 'client_view');
create policy farmers_update on public.farmers for update to authenticated
  using (app.farmer_access(client_id) and app.current_role() <> 'client_view');

-- counters are touched only inside the security-definer insert trigger; no direct access
revoke all on public.footprint_counters from authenticated, anon;

-- ---------------------------------------------------------------------------
-- Footprints: strict scope isolation. Operators see their own stage + the stage directly behind it.
-- ---------------------------------------------------------------------------
create or replace function app.can_see_footprint(p_scope uuid, p_stage public.stage_type) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.app_users u
    where u.auth_uid = auth.uid() and u.active and (
         (app.is_gateway_role(u.role) or u.role = 'client_view') and app.can_access_scope(p_scope)
      or (u.role = 'operator' and exists (
            select 1 from public.slot_assignments sa
            where sa.user_id = u.id and sa.scope_id = p_scope
              and (sa.stage_type = p_stage or app.chain_prev(p_scope, sa.stage_type) = p_stage))))
  )
$$;

create policy footprints_read on public.footprints for select to authenticated
  using (app.can_see_footprint(scope_id, stage_type));
create policy footprints_insert on public.footprints for insert to authenticated
  with check (created_by = app.current_user_id() and app.is_my_stage(app.current_user_id(), scope_id, stage_type));
create policy footprints_update on public.footprints for update to authenticated
  using (app.can_see_footprint(scope_id, stage_type) and app.current_role() <> 'client_view');

create policy qc_verdicts_read on public.qc_verdicts for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
create policy qc_verdicts_override on public.qc_verdicts for update to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_manage_client(f.client_id)));

create policy qr_seals_read on public.qr_seals for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_access_scope(f.scope_id)));

create policy flags_read on public.flags for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
create policy flags_insert on public.flags for insert to authenticated
  with check (raised_by = app.current_user_id()
          and exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
create policy flags_update on public.flags for update to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_manage_client(f.client_id)));

create policy attachments_read on public.attachments for select to authenticated
  using (exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));
create policy attachments_insert on public.attachments for insert to authenticated
  with check (uploaded_by = app.current_user_id()
          and exists (select 1 from public.footprints f where f.id = footprint_id and app.can_see_footprint(f.scope_id, f.stage_type)));

create policy ledger_read on public.ledger for select to authenticated
  using (scope_id is null and app.current_role() = 'admin' or app.can_access_scope(scope_id));
