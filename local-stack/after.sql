-- Grants a Supabase project applies by default and the local stack must copy. Never run against Supabase.
-- (Execute rights on `app` functions come from the migrations themselves: migration 14 closes the schema.)
grant usage on schema app to anon, authenticated, service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
notify pgrst, 'reload schema';
