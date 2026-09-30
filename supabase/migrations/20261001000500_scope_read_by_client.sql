-- GrainVeda MVP · migration 18: managers can read back a scope they just created (bug found by the Phase 1 E2E test)
--
-- scopes_read (migration 5) calls app.can_access_scope(id), which looks the scope up by id. Inside INSERT … RETURNING
-- that lookup cannot see the row being inserted yet, so the RETURNING row fails the SELECT policy and the whole insert
-- is refused ("new row violates row-level security policy") — a Client Manager could not create a draft scope from the
-- app. This extra permissive policy decides from the row's own client_id, which needs no lookup of the new row.
-- It grants nothing new: it is the manager / client-view half of can_access_scope, restated on the row's columns.

create policy scopes_read_by_client on public.scopes for select to authenticated
  using (app.can_manage_client(client_id) or (app.current_role() = 'client_view' and client_id = app.my_client_id()));
