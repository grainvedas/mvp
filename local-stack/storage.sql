-- Local stand-in for the tables of Supabase Storage that the evidence policies (migration 16) read and write.
-- Never run against Supabase: it already has the real ones. Applied by local-stack/up.sh BEFORE the migrations, so
-- migration 16 creates the `evidence` bucket and its two policies here exactly as it does on the live project.
-- The bytes are kept by local-stack/storage.mjs, which does its INSERT / SELECT on storage.objects as the caller.
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;
create table if not exists storage.buckets (id text primary key, name text not null, public boolean not null default false);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id), name text not null,
  owner uuid, created_at timestamptz not null default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant select, insert on storage.objects to authenticated;
grant all on storage.objects, storage.buckets to service_role;
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select (string_to_array(name, '/'))[1 : greatest(array_length(string_to_array(name, '/'), 1) - 1, 0)]
$$;
