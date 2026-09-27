-- LOCAL ONLY. Emulates the parts of Supabase the migrations depend on (auth.uid(), the anon/authenticated/service_role roles).
-- Never apply this to a Supabase project — it already has all of this.

do $$ begin create role anon nologin;          exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- Supabase's auth.uid() reads request.jwt.claims -> sub. Tests set that claim with:
--   set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';
create or replace function auth.uid() returns uuid
language sql stable as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'
$$;

grant usage on schema public to anon, authenticated, service_role;

-- The columns of Supabase's auth.users that migration 9 (login linking) reads. Supabase stores phones without the '+'.
create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique,
  phone               text unique,
  email_confirmed_at  timestamptz,
  phone_confirmed_at  timestamptz,
  created_at          timestamptz not null default now()
);
