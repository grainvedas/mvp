-- Test helpers (schema t). Plain SQL, no pgTAP. A failed assertion raises, which fails the file under ON_ERROR_STOP.
create schema if not exists t;

create or replace function t.ok(cond boolean, name text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ASSERTION FAILED: %', name; end if;
  raise notice 'ok   %', name;
end $$;

-- Expect the statement to fail with a message containing p_like.
create or replace function t.fails(p_sql text, p_like text, name text) returns void language plpgsql as $$
declare msg text;
begin
  begin
    execute p_sql;
  exception when others then
    msg := sqlerrm;
    if msg ilike '%' || p_like || '%' then raise notice 'ok   % (refused: %)', name, left(msg, 90); return; end if;
    raise exception 'ASSERTION FAILED: % — refused for a different reason: %', name, msg;
  end;
  raise exception 'ASSERTION FAILED: % — statement was accepted', name;
end $$;

-- Act as a given app_users.id (RLS + auth.uid()). Call inside a transaction; reset with t.as_service().
create or replace function t.as_user(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function t.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  execute 'set local role anon';
end $$;

create or replace function t.as_service() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Fixed ids from the demo seed
create or replace function t.u(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-0000000003' || p)::uuid $$;          -- users: '01' admin … '12' other-client op
create or replace function t.scope(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-0000000004' || p)::uuid $$;          -- '01' minimal, '02' grading, '03' market fork
create or replace function t.farmer(p text) returns uuid language sql immutable as $$
  select ('00000000-0000-4000-8000-0000000005' || p)::uuid $$;

-- Convenience: create a procurement lot as the field operator (service-role context, trigger-checked).
create or replace function t.procure(p_scope uuid, p_farmer uuid, p_gross numeric, p_bags int, p_tare numeric, p_m1 numeric, p_m2 numeric, p_m3 numeric)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'procurement', p_farmer, t.u('05'),
          jsonb_build_object('gross_kg', p_gross, 'bags', p_bags, 'tare_kg_per_bag', p_tare, 'moisture_pct', jsonb_build_array(p_m1, p_m2, p_m3)))
  returning id into v;
  return v;
end $$;

create or replace function t.verify(p_fp uuid, p_by uuid) returns void language sql as $$
  update public.footprints set status = 'verified', verified_by = p_by where id = p_fp
$$;

-- The test roles need the helper schema (test-only grant)
grant usage on schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;

create or replace function t.procure_as(p_scope uuid, p_farmer uuid, p_by uuid) returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into public.footprints (scope_id, client_id, stage_type, farmer_id, created_by, payload)
  values (p_scope, '00000000-0000-4000-8000-000000000201', 'procurement', p_farmer, p_by,
          '{"gross_kg":100,"bags":2,"tare_kg_per_bag":1,"moisture_pct":[12,12,12]}') returning id into v;
  return v;
end $$;
grant execute on all functions in schema t to anon, authenticated;
