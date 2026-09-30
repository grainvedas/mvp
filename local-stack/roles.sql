-- Local stand-in for the roles a Supabase project already has. Never run against Supabase.
do $$ begin create role anon nologin noinherit;                 exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin noinherit;        exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin noinherit bypassrls; exception when duplicate_object then null; end $$;
do $$ begin create role authenticator login password 'authenticator' noinherit; exception when duplicate_object then null; end $$;
do $$ begin create role supabase_auth_admin login password 'auth_admin' createrole noinherit; exception when duplicate_object then null; end $$;
grant anon, authenticated, service_role to authenticator;
grant usage on schema public to anon, authenticated, service_role;
create schema if not exists auth authorization supabase_auth_admin;
grant usage on schema auth to anon, authenticated, service_role;
grant create, usage on schema public to supabase_auth_admin;
alter role supabase_auth_admin set search_path = auth;
