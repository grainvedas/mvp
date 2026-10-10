-- Migration 30: a State Manager creates a client (and, until migration 34, the admin) and get the row back (INSERT … RETURNING under RLS).
-- Before it: "new row violates row-level security policy for table clients" for both, though both may create one.
begin;
select t.as_service();
do $$
declare r public.clients; n int;
begin
  -- Migration 34: clients are the State Manager's; the admin reads them all and creates none.
  perform t.as_user(t.u('01'));                                         -- admin
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Admin Client', 'ADMC', 'exporter', '00000000-0000-4000-8000-000000000002') $q$,
    'row-level security', 'oversight: the admin cannot create a client');
  perform t.as_service();
  insert into public.clients (name, code, type, state_id) values ('Returning Exports', 'RTEX', 'exporter', '00000000-0000-4000-8000-000000000002')
    returning * into r;
  perform t.as_user(t.u('01'));
  perform t.ok((select count(*) from public.clients where id = r.id) = 1, 'admin sees every client, in any state');
  update public.clients set name = 'Renamed by the admin' where id = r.id;
  perform t.ok((select name from public.clients where id = r.id) = 'Returning Exports', 'oversight: the admin cannot rename a client');

  perform t.as_user(t.u('02'));                                         -- State Manager of Uttar Pradesh
  perform t.ok((select count(*) from public.clients where id = r.id) = 0, 'a State Manager does not see a client of another state');
  insert into public.clients (name, code, type, state_id) values ('Returning FPO', 'RTFP', 'fpo', '00000000-0000-4000-8000-000000000001')
    returning * into r;
  perform t.ok(r.id is not null, 'State Manager creates a client in the own state and reads it back');
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Nope', 'NOPE', 'fpo', '00000000-0000-4000-8000-000000000002') $q$,
    'row-level security', 'a State Manager cannot create a client in another state');
  update public.clients set name = 'Returning FPO Ltd' where id = r.id returning * into r;
  perform t.ok(r.name = 'Returning FPO Ltd', 'State Manager renames the own state''s client and reads it back');

  -- the new rule opens nothing to the client's own people or to another client's
  perform t.as_user(t.u('03'));                                         -- Client Manager of another client
  select count(*) into n from public.clients;
  perform t.ok(n = 1, 'a Client Manager still sees the own client only');
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Nope', 'NOPE', 'fpo', '00000000-0000-4000-8000-000000000001') $q$,
    'row-level security', 'a Client Manager cannot create a client');
  perform t.as_user(t.u('05'));                                         -- operator
  perform t.ok((select count(*) from public.clients) = 1, 'an operator still sees the own client only');
  perform t.as_service();
  update public.app_users set active = false where id = t.u('02');
  perform t.as_user(t.u('02'));                                         -- the State Manager, deactivated
  perform t.ok((select count(*) from public.clients) = 0, 'a deactivated State Manager sees no client');
  perform t.as_service();
end $$;
rollback;
