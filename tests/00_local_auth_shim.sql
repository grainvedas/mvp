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
  raw_app_meta_data   jsonb not null default '{}'::jsonb,   -- set only by the service role (migration 23 reads grainveda_login)
  created_at          timestamptz not null default now()
);

-- Minimal stand-in for Supabase Storage (buckets, objects, foldername), so the evidence-bucket policies in migration 16
-- are created and tested locally. Only the columns the policies read.
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table if not exists storage.buckets (id text primary key, name text not null, public boolean not null default false);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text not null,
  owner uuid default auth.uid(), created_at timestamptz not null default now()
);
alter table storage.objects enable row level security;
grant select, insert on storage.objects to authenticated;
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select (string_to_array(name, '/'))[1 : greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)]
$$;
