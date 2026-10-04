-- GrainVeda MVP · migration 30: an admin or a State Manager can read back a client they just created
-- (reported by Veda from the deployed app, 5 Oct 2026: Clients → Create → "Not allowed for your role or stage.")
--
-- clients_read (migration 5) calls app.can_access_client(id), which looks the client up by id. Inside
-- INSERT … RETURNING that lookup cannot see the row being inserted yet, so the RETURNING row fails the SELECT policy and
-- the whole insert is refused ("new row violates row-level security policy for table clients"). The app asks for the
-- row back, so no client could be created from the screen by anybody: the demo clients come from a seed, and no test
-- created one the way the screen does. The same fault was found on scopes in Phase 1 and fixed there (migration 18);
-- clients was not looked at then.
--
-- This extra permissive policy decides from the row's own columns, which needs no lookup of the new row. It grants
-- nothing new: it is the admin / State Manager half of app.can_access_client, restated on the row (app.current_role()
-- is null for a person who is not active, as in can_access_client). The client's own people (client_manager,
-- client_view, operator) keep reading their client through clients_read; they cannot create one.
--
-- Read rules of every table were looked through on 5 Oct for the same pattern (a policy that looks up its own row by
-- id): scopes (fixed in migration 18) and clients were the only two.

create policy clients_read_by_row on public.clients for select to authenticated
  using (app.current_role() = 'admin'
      or (app.current_role() = 'state_manager' and state_id = any(app.my_state_ids())));
