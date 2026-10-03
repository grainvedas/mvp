-- GrainVeda MVP · PRODUCTION seed: the reference rows a real season starts from. No demo people, farmers or scopes.
-- Run ONCE on the production project, after every migration and supabase/seeds/01_stage_definitions.sql:
--   supabase db query --linked -f supabase/seeds/production/10_reference.sql
-- Idempotent. After it: scripts/bootstrap_admin.mjs creates the first admin; everything else is made in the app
-- (State Managers, the Client Manager, scopes, operators, farmers).

-- 1. This project is production: demo seeds and demo scripts now refuse to run here, and the app drops the
--    "practice system" strip. There is no way back from the app; only a database owner can remove the row.
insert into public.app_meta (key, value) values ('environment', 'production')
on conflict (key) do update set value = excluded.value;

-- 2. State, crop (limits as agreed in PRD §12: moisture 13 % domestic / 12 % export), GrainVeda's own trade client.
insert into public.states (id, name, code) values
  ('00000000-0000-4000-8000-000000000001', 'Uttar Pradesh', 'UP')
on conflict (id) do nothing;

insert into public.crops (id, name, code, gi_tag, origin, primary_unit, quality_params, allowed_stages) values
  ('00000000-0000-4000-8000-000000000101', 'Kalanamak rice', 'KNM', 'GI 280', 'Eastern UP Terai belt (Siddharthnagar)', 'kg',
   '[{"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":13,"export_limit":12},
     {"param":"broken_pct","label":"Broken grains","unit":"%","operator":"<=","domestic_limit":5,"export_limit":3},
     {"param":"foreign_matter_pct","label":"Foreign matter","unit":"%","operator":"<=","domestic_limit":1,"export_limit":0.5}]',
   '{milling,sorting,grading,drying,cleaning,cold_storage,packing}')
on conflict (id) do nothing;

insert into public.clients (id, state_id, name, code, type) values
  ('00000000-0000-4000-8000-000000000201', '00000000-0000-4000-8000-000000000001', 'GrainVeda (Prasaadam trade scope)', 'PRSDM', 'grainveda')
on conflict (id) do nothing;

select 'production reference seed applied' as result, app.environment() as environment,
       (select count(*) from public.states) as states, (select count(*) from public.crops) as crops,
       (select count(*) from public.clients) as clients, (select count(*) from public.app_users) as users,
       (select count(*) from public.farmers) as farmers, (select count(*) from public.scopes) as scopes;
