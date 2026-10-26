-- Migration 69 (found on the practice system on 26 Oct 2026): the isolation probe in parts.
--   1  the parts together do exactly what the whole probe does: the same people, the same tables, the same number of
--      calls and of the person's own rows seen, the same leaks (none)
--   2  a leak put in on purpose (a table opened to all) is caught by a part, as by the whole probe
--   3  a part out of range is refused; the app's people and the public do not run it
begin;
select t.as_service();
set local app.change_path = 'test setup';
-- the two clients each have a lab of their own (the table the leak is planted in)
insert into public.labs (state_id, name, accreditation_no, kind, location, client_id) values
  ('00000000-0000-4000-8000-000000000001', 'Prasaadam own lab (test)', 'TC-6401', 'in_house', 'Basti', '00000000-0000-4000-8000-000000000201'),
  ('00000000-0000-4000-8000-000000000001', 'Demox own lab (test)', 'TC-6402', 'in_house', 'Deoria', '00000000-0000-4000-8000-000000000202');
create temp table whole as select app.isolation_probe(true, false) as j;
create temp table parts as select p, app.isolation_probe_part(p, 4, false) as j from generate_series(0, 3) p;

-- 1 · the parts are the whole ----------------------------------------------------------------------------------------------
select t.ok((select (j->>'people')::int > 5 and (j->>'calls')::int > 100 from whole), '1: the whole probe looked as several people and made its calls');
select t.ok((select sum((j->>'calls')::int) from parts) = (select (j->>'calls')::int from whole),
            '1: the parts make exactly the whole probe''s calls (' || (select j->>'calls' from whole) || '), each function in one part');
select t.ok((select sum((j->>'own_rows_seen')::int) from parts) = (select (j->>'own_rows_seen')::int from whole),
            '1: and see exactly its own rows, each person''s tables read in one part');
select t.ok((select bool_and((j->>'people')::int = (select (j->>'people')::int from whole)) from parts)
            and (select max((j->>'tables')::int) from parts) = (select (j->>'tables')::int from whole)
            and (select count(*) filter (where (j->>'calls')::int > 0) from parts) >= 2,
            '1: every part goes through every person; the tables are read in one part per person; the work is shared out');
select t.ok((select bool_and(j->'leaks' = '[]'::jsonb) from parts) and (select j->'leaks' = '[]'::jsonb from whole),
            '1: no leak, in the whole or in any part');
select t.ok((select bool_and((j->>'part')::int = p and (j->>'parts')::int = 4) from parts), '1: each part says which it is');

-- 2 · a leak put in on purpose is caught by a part --------------------------------------------------------------------------
alter policy labs_read on public.labs using (true);
select t.ok((select (app.isolation_probe(false, false))->'leaks' @> '[{"kind": "table", "what": "labs"}]'), '2: a table opened to all: the whole probe catches it');
select t.ok((select count(*) >= 1 from generate_series(0, 3) p where (app.isolation_probe_part(p, 4, false))->'leaks' @> '[{"kind": "table", "what": "labs"}]'),
            '2: and a part catches it');
alter policy labs_read on public.labs using (client_id is null or app.can_access_client(client_id));

-- 3 · out of range; who runs it --------------------------------------------------------------------------------------------
select t.fails('select app.isolation_probe_part(4, 4)', 'a part from 0 to parts - 1', '3: part 4 of 4 does not exist');
select t.fails('select app.isolation_probe_part(0, 0)', 'a part from 0 to parts - 1', '3: nor 0 parts');
select t.fails('select app.isolation_probe_part(-1, 4)', 'a part from 0 to parts - 1', '3: nor part -1');
select t.ok(not has_function_privilege('authenticated', 'app.isolation_probe_part(integer, integer, boolean)', 'execute')
            and not has_function_privilege('anon', 'app.isolation_probe_part(integer, integer, boolean)', 'execute'),
            '3: the app''s people and the public do not run it');
rollback;
