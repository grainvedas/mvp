-- GrainVeda MVP · migration 25: who may read the ledger, and who may act, as part of the record
--
-- Found in the Phase 4 pre-go-live run (direct API calls as each role, PRD §9 "Authorisation").
--
-- 1. LEDGER READ. The ledger_read policy let anyone who can open a scope read every block of that scope, and a block
--    carries the snapshot of the record it describes. An operator sees only the own stage and the stage behind it
--    (PRD §5.5 thumb rule), but through the ledger a procurement operator could read the Commercial record of the same
--    scope: buyer name and price, and the lab readings. Reproduced on the test build: 1 footprint visible in the
--    table, 11 ledger blocks, among them buyer and price. The screens never showed it (the record page reads the ledger
--    through app.footprint_detail, which checks the record), so this was an API-only leak.
--    Now: an operator reads only the blocks of records the operator can see; managers and Client View read the blocks
--    of scopes they can open; blocks without a scope (farmers, users) stay with the admin.
--
-- 2. ASSIGNMENTS. A manager could give a person a stage but never take it away (no DELETE privilege on
--    slot_assignments), so a wrong assignment could only be undone by deactivating the person everywhere. DELETE is
--    granted; the slots_write policy already limits it to managers of the scope's client.
--    Who may record and verify at a stage decides what the ledger later says, so from activation on every assignment
--    given or removed is a ledger block, and activation itself records who held which stage that day.
--
-- 3. PEOPLE. Creating a user, changing a user's role, client, states, name or active flag, and removing a user row
--    (service role only) is a ledger block, admin-only to read like farmer blocks. Phone numbers and e-mail addresses
--    never enter the ledger.

-- 1 · ledger read ------------------------------------------------------------------------------------------------------
drop policy if exists ledger_read on public.ledger;
create policy ledger_read on public.ledger for select to authenticated
  using (case app.current_role()
           when 'admin' then true
           when 'operator' then footprint_id is not null and exists (
             select 1 from public.footprints f where f.id = ledger.footprint_id and app.can_see_footprint(f.scope_id, f.stage_type))
           else scope_id is not null and app.can_access_scope(scope_id)   -- managers, Client View; no role: can_access_scope is false
         end);

-- 2 · assignments ------------------------------------------------------------------------------------------------------
grant delete on public.slot_assignments to authenticated;

create or replace function app.slots_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare s public.slot_assignments; st public.scope_status;
begin
  if tg_op = 'DELETE' then s := old; else s := new; end if;
  select status into st from public.scopes where id = s.scope_id;
  if st is null or st = 'draft' then return null; end if;               -- a draft is still being set up: nothing has flowed
  perform app.ledger_append(null, s.scope_id, 'supervisory', app.current_user_id(),
    jsonb_build_object('act', case when tg_op = 'DELETE' then 'slot_removed' else 'slot_assigned' end,
                       'scope_id', s.scope_id, 'stage_type', s.stage_type, 'user_id', s.user_id,
                       'user_name', (select u.display_name from public.app_users u where u.id = s.user_id)));
  return null;
end $$;
create trigger slots_ledger after insert or delete on public.slot_assignments
  for each row execute function app.slots_ledger();

-- An assignment names a person and a stage of the scope; it is given and removed, never rewritten.
create or replace function app.slots_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_chain public.stage_type[];
begin
  if tg_op = 'UPDATE' then
    raise exception 'an assignment is given or removed, not changed' using errcode = '42501';
  end if;
  select s.chain into v_chain from public.scopes s where s.id = new.scope_id;
  if not (new.stage_type = any(v_chain)) then
    raise exception 'stage % is not in this scope''s chain', new.stage_type using errcode = '23514';
  end if;
  if current_user in ('authenticated', 'anon') then new.created_at := now(); end if;
  return new;
end $$;

create or replace function app.scopes_slots_at_activation() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'draft' and new.status = 'active' then
    perform app.ledger_append(null, new.id, 'supervisory', app.current_user_id(),
      jsonb_build_object('act', 'slots_at_activation', 'scope_id', new.id,
        'slots', coalesce((select jsonb_agg(jsonb_build_object('stage_type', sa.stage_type, 'user_id', sa.user_id, 'user_name', u.display_name)
                                            order by array_position(new.chain, sa.stage_type), u.display_name)
                             from public.slot_assignments sa join public.app_users u on u.id = sa.user_id
                            where sa.scope_id = new.id), '[]'::jsonb)));
  end if;
  return null;
end $$;
-- z: after scopes_ledger, so the scope_activate block comes first
create trigger scopes_z0_slots_at_activation after update on public.scopes
  for each row execute function app.scopes_slots_at_activation();

-- 3 · people -----------------------------------------------------------------------------------------------------------
create or replace function app.app_users_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
declare was jsonb := '{}'::jsonb; now_ jsonb := '{}'::jsonb; k text;
begin
  if tg_op = 'INSERT' then
    perform app.ledger_append(null, null, 'supervisory', app.current_user_id(),
      jsonb_build_object('kind', 'user_created', 'user_id', new.id, 'name', new.display_name, 'role', new.role,
                         'client_id', new.client_id, 'state_ids', to_jsonb(new.state_ids), 'active', new.active));
    return null;
  elsif tg_op = 'DELETE' then                                           -- service role only (a create-user call undone)
    perform app.ledger_append(null, null, 'supervisory', app.current_user_id(),
      jsonb_build_object('kind', 'user_removed', 'user_id', old.id, 'name', old.display_name, 'role', old.role, 'client_id', old.client_id));
    return null;
  end if;
  foreach k in array array['display_name', 'role', 'client_id', 'state_ids', 'active'] loop
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
create trigger app_users_ledger after insert or update or delete on public.app_users
  for each row execute function app.app_users_ledger();

create trigger slots_guard before insert or update on public.slot_assignments
  for each row execute function app.slots_guard();

revoke execute on function app.slots_ledger(), app.slots_guard(), app.scopes_slots_at_activation(), app.app_users_ledger()
  from public, anon, authenticated;
notify pgrst, 'reload schema';
