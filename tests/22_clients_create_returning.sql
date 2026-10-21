-- Migration 30: a State Manager creates a client (and, until migration 34, the admin) and get the row back (INSERT … RETURNING under RLS).
-- Before it: "new row violates row-level security policy for table clients" for both, though both may create one.
-- Migration 64 (Phase 2, the registry): nobody writes public.clients directly any more; the State Manager creates a client
-- through app.create_client (PAN first) and changes it through app.save_client_details (tests/59).
begin;
select t.as_service();
do $$
declare r public.clients; n int;
begin
  -- Migration 34: clients are the State Manager's; the admin reads them all and creates none.
  perform t.as_user(t.u('01'));                                         -- admin
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Admin Client', 'ADMC', 'exporter', '00000000-0000-4000-8000-000000000002') $q$,
    'permission denied', 'oversight: the admin cannot create a client');
  perform t.as_service();
  insert into public.clients (name, code, type, state_id) values ('Returning Exports', 'RTEX', 'exporter', '00000000-0000-4000-8000-000000000002')
    returning * into r;
  perform t.as_user(t.u('01'));
  perform t.ok((select count(*) from public.clients where id = r.id) = 1, 'admin sees every client, in any state');
  perform t.fails(format($q$ update public.clients set name = 'Renamed by the admin' where id = %L $q$, r.id), 'permission denied', 'oversight: the admin cannot rename a client');

  perform t.as_user(t.u('02'));                                         -- State Manager of Uttar Pradesh
  perform t.ok((select count(*) from public.clients where id = r.id) = 0, 'a State Manager does not see a client of another state');
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Returning FPO', 'RTFP', 'fpo', '00000000-0000-4000-8000-000000000001') $q$,
    'permission denied', 'migration 64: a State Manager does not insert a client directly either');
  r.id := (app.create_client(jsonb_build_object('pan', 'ZZZAR0022R', 'entity_type', 'cooperative',
    'legal_name', 'Returning FPO', 'state_id', '00000000-0000-4000-8000-000000000001', 'client_type', 'fpo',
    'contact', jsonb_build_object('name', 'R', 'designation', 'Secretary', 'phone', '9000000022', 'email', 'r@fpo.test'),
    'crops_of_interest', jsonb_build_array('00000000-0000-4000-8000-000000000101'))) ->> 'client_id')::uuid;
  select * into r from public.clients where id = r.id;
  perform t.ok(r.id is not null and r.code ~ '^[A-Z]{3,5}$', 'State Manager creates a client in the own state (app.create_client) and reads it back');
  perform t.fails($q$ select app.create_client('{"pan":"ZZZAR0023R","entity_type":"cooperative","legal_name":"Nope","state_id":"00000000-0000-4000-8000-000000000002",
    "contact":{"name":"N","designation":"N","phone":"9000000023","email":"n@n.test"},"crops_of_interest":["00000000-0000-4000-8000-000000000101"]}') $q$,
    'State Manager of the state it starts in', 'a State Manager cannot create a client in another state');
  perform app.save_client_details(r.id, '00000000-0000-4000-8000-000000000001', '{"legal_name":"Returning FPO Ltd"}');
  select * into r from public.clients where id = r.id;
  perform t.ok(r.name = 'Returning FPO Ltd', 'State Manager renames the own state''s client and reads it back');

  -- the new rule opens nothing to the client's own people or to another client's
  perform t.as_user(t.u('03'));                                         -- Client Manager of another client
  select count(*) into n from public.clients;
  perform t.ok(n = 1, 'a Client Manager still sees the own client only');
  perform t.fails($q$ insert into public.clients (name, code, type, state_id) values ('Nope', 'NOPE', 'fpo', '00000000-0000-4000-8000-000000000001') $q$,
    'permission denied', 'a Client Manager cannot create a client');
  perform t.as_user(t.u('05'));                                         -- operator
  perform t.ok((select count(*) from public.clients) = 1, 'an operator still sees the own client only');
  perform t.as_service();
  update public.app_users set active = false where id = t.u('02');
  perform t.as_user(t.u('02'));                                         -- the State Manager, deactivated
  perform t.ok((select count(*) from public.clients) = 0, 'a deactivated State Manager sees no client');
  perform t.as_service();
end $$;
rollback;
