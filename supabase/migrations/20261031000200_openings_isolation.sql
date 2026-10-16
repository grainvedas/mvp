-- Migration 56b (Veda, 16 Oct 2026: "check that one client data should not be visible to another client").
-- The release script of migration 56 ran app.isolation_probe() on the practice system and stopped before the app:
--   "A CLIENT CAN SEE ANOTHER CLIENT'S DATA: leaks=2 people=7 tables=40 calls=7440 own_rows=2147 clients=3 what=table:openings"
-- An opening that a scope's requirement made names its client and scope, its stages, positions and note. Since
-- migration 39 every Client Manager (app.can_assign) could read every opening of every client. The local tests had no
-- opening of a client at all, so the probe had nothing to find there (tests/50_client_isolation.sql now fills every
-- table it reads for both clients, and fails when a table has none).
--   1. openings_read: HR (her states), the admin, and a manager only for the openings of clients he may see (or
--      GrainVeda's own openings, of no client).
--   2. The probe also reads the tables that are open by column only (buyer_links: every column but the token's
--      fingerprint), and only the columns that are open; a buyer link's view is traced to its link's client.
-- Nothing else changes; no row is changed.
select set_config('app.change_path', 'migration 56b', true);

drop policy openings_read on public.openings;
create policy openings_read on public.openings for select to authenticated using (
  (app.acts_as_hr() and (app.hr_full() or state_id = any (app.my_hr_states()))) or app.is_admin()
  or (app.can_assign() and (coalesce(client_id, (select s.client_id from public.scopes s where s.id = scope_id)) is null
                            or app.can_access_client(coalesce(client_id, (select s.client_id from public.scopes s where s.id = scope_id))))));

CREATE OR REPLACE FUNCTION app.isolation_owner(p_table text, r jsonb)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    case when p_table = 'clients' then (r->>'id')::uuid end,
    (r->>'client_id')::uuid,
    (select s.client_id from public.scopes s where s.id = (r->>'scope_id')::uuid),
    (select f.client_id from public.footprints f where f.id = coalesce(r->>'footprint_id', r->>'seal_id')::uuid),
    (select fa.client_id from public.farmers fa where fa.id = (r->>'farmer_id')::uuid),
    (select f.client_id from public.attachments a join public.footprints f on f.id = a.footprint_id where a.id = (r->>'attachment_id')::uuid),
    (select q.client_id from public.requirements q where q.id = (r->>'requirement_id')::uuid),
    (select b.client_id from public.buyers b where b.id = (r->>'buyer_id')::uuid),
    (select l.client_id from public.buyer_links l where l.id = (r->>'link_id')::uuid),   -- migration 56b
    (select u.client_id from public.app_users u where u.id = coalesce(r->>'employee_id', r->>'user_id')::uuid),
    null::uuid) $function$;

CREATE OR REPLACE FUNCTION app.isolation_probe(p_functions boolean DEFAULT true, p_read_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'app'
AS $function$
declare
  u record; t record; fn record; probe record;
  v_clients uuid[]; v_rows jsonb; v_res jsonb; v_base jsonb; v_txt text; r jsonb; v_owner uuid;
  leaks jsonb := '[]'::jsonb; own_seen int := 0; people int := 0; tables int := 0; calls int := 0; refused int := 0;
  cols text; ids jsonb := '[]'::jsonb; v_key text; v_done text[] := '{}';
  link_cols constant text[] := array['id', 'client_id', 'scope_id', 'footprint_id', 'seal_id', 'farmer_id', 'attachment_id',
                                     'requirement_id', 'buyer_id', 'employee_id', 'user_id', 'link_id'];   -- link_id: migration 56b
begin
  if current_user in ('authenticated', 'anon') then raise exception 'the isolation probe is run by the database owner' using errcode = '42501'; end if;
  -- from here the transaction writes nothing (a function that would write, called as someone, fails)
  if p_read_only then perform set_config('transaction_read_only', 'on', true); end if;
  -- the ids other clients' records go by: a few records of every stage, the scopes, farmers, the client's lists, files,
  -- samples, sales' terms and documents, people
  select coalesce(jsonb_agg(jsonb_build_object('kind', k, 'id', id, 'client', client_id)), '[]'::jsonb) into ids from (
    select 'footprint:' || stage_type as k, id, client_id from (
      select f.*, row_number() over (partition by f.client_id, f.stage_type order by f.created_at desc) n from public.footprints f) x where n <= 2
    union all select 'scope', id, client_id from public.scopes
    union all select 'farmer', id, client_id from (select fa.*, row_number() over (partition by client_id order by created_at desc) n from public.farmers fa) x where n <= 3
    union all select 'buyer', id, client_id from public.buyers
    union all select 'collection_point', id, client_id from public.collection_points
    union all select 'mill', id, client_id from public.mills
    union all select 'packing_unit', id, client_id from public.packing_units
    union all select 'pack_sku', id, client_id from public.pack_skus
    union all select 'lab', id, client_id from public.labs where client_id is not null
    union all select 'attachment', a.id, f.client_id from (select a.*, row_number() over (partition by a.footprint_id order by a.created_at) n from public.attachments a) a
                join public.footprints f on f.id = a.footprint_id where a.n = 1
    union all select 'sample', id, client_id from public.qc_samples
    union all select 'client', id, id from public.clients) z;

  for u in
    select au.id, au.auth_uid, au.role,
           array_remove(array(select distinct c from unnest(array[au.client_id]
             || array(select a.client_id from app.eff_assignments(au.id) a where a.client_id is not null)
             || array(select s.client_id from app.eff_assignments(au.id) a join public.scopes s on s.id = a.scope_id)) c), null) as clients
      from public.app_users au
     where au.active and coalesce(au.system_role, 'operational') = 'operational' and au.role <> 'admin' and au.role <> 'state_manager'
       and not exists (select 1 from app.eff_assignments(au.id) a where a.lens = 'state')
     order by au.id
  loop
    people := people + 1;
    v_clients := u.clients;
    -- 1 · the tables, as him
    for t in
      select c.relname, array(select a.attname::text from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                                and a.attname::text = any (link_cols)
                                and has_column_privilege('authenticated', c.oid, a.attname, 'select') order by a.attnum) as cs   -- migration 56b
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r' and has_any_column_privilege('authenticated', c.oid, 'select')   -- migration 56b
       order by c.relname
    loop
      if cardinality(t.cs) = 0 or t.cs = array['id'] or t.relname = 'app_users' or t.relname like 'employee\_%' then continue; end if;
      cols := (select string_agg(quote_ident(x), ', ') from unnest(t.cs) x);
      perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      begin
        execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I limit 5000) x', cols, t.relname) into v_rows;
      exception when others then v_rows := '[]'::jsonb;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      if people = 1 then tables := tables + 1; end if;
      for r in select * from jsonb_array_elements(v_rows) loop
        v_owner := app.isolation_owner(t.relname, r);
        if v_owner is null then continue; end if;
        if v_owner = any (v_clients) then own_seen := own_seen + 1;
        else leaks := leaks || jsonb_build_object('kind', 'table', 'what', t.relname, 'person', left(u.id::text, 8), 'role', u.role);
             exit;
        end if;
      end loop;
    end loop;

    -- 2 · the functions, as him, with other clients' ids: once for each kind of person (role and clients)
    v_key := u.role || ':' || coalesce(array_to_string(array(select x::text from unnest(v_clients) x order by 1), ','), '');
    if p_functions and not (v_key = any (v_done)) then
      v_done := v_done || v_key;
      for fn in
        select p.oid, n.nspname || '.' || p.proname as name, p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')
           and p.pronargs - p.pronargdefaults = 1 and p.proargtypes[0] = 'uuid'::regtype
           and p.prorettype <> 'trigger'::regtype
         order by 2
      loop
        -- what the function answers for an id that is nobody's: an answer like it is no data (a default, "pending")
        perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        begin
          execute format('select to_jsonb(%s($1))', fn.name) using gen_random_uuid() into v_base;
        exception when others then v_base := null;
        end;
        execute 'reset role';
        perform set_config('request.jwt.claims', '', true);
        for probe in select x->>'kind' as kind, (x->>'id')::uuid as id from jsonb_array_elements(ids) x
                      where not ((x->>'client')::uuid = any (v_clients)) loop
          calls := calls + 1;
          perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
          execute 'set local role authenticated';
          begin
            execute format('select to_jsonb(%s($1))', fn.name) using probe.id into v_res;
          exception when others then v_res := null; refused := refused + 1;
          end;
          execute 'reset role';
          perform set_config('request.jwt.claims', '', true);
          v_txt := coalesce(v_res::text, 'null');
          if v_res is distinct from v_base and v_txt not in ('null', '[]', '{}', 'false', '0', '""')
             and not (jsonb_typeof(v_res) = 'object' and not exists (select 1 from jsonb_each(v_res) e where e.value not in ('null'::jsonb, '[]'::jsonb, '{}'::jsonb, 'false'::jsonb, '0'::jsonb))) then
            leaks := leaks || jsonb_build_object('kind', 'function', 'what', fn.proname, 'with', probe.kind, 'person', left(u.id::text, 8), 'role', u.role);
          end if;
        end loop;
      end loop;
    end if;
  end loop;

  return jsonb_build_object('people', people, 'tables', tables, 'calls', calls, 'refused', refused, 'own_rows_seen', own_seen,
    'clients', (select count(*) from public.clients), 'daily_code', app.daily_code_on(),
    'leaks', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(leaks) x));
end $function$;

revoke execute on function app.isolation_owner(text, jsonb), app.isolation_probe(boolean, boolean) from public, anon, authenticated;
