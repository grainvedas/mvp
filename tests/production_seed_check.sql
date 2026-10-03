-- Runs on a scratch database built the way PRODUCTION is built: every migration, seeds/01_stage_definitions.sql and
-- seeds/production/10_reference.sql. No demo seed. Called by tests/run_local.sh and tests/run_local.ps1.
select t.ok(app.environment() = 'production', 'production: the project is marked production');
select t.ok((select count(*) from public.states) = 1 and (select count(*) from public.crops) = 1 and (select count(*) from public.clients) = 1,
            'production: one state, one crop, one client');
select t.ok((select count(*) from public.app_users) = 0 and (select count(*) from public.farmers) = 0
            and (select count(*) from public.scopes) = 0 and (select count(*) from public.footprints) = 0,
            'production: no demo people, farmers, scopes or lots');
select t.ok((select count(*) from public.stage_definitions) = 16, 'production: all 16 stage definitions are present');
select t.ok((select count(*) from public.ledger) = 0 and not exists (select 1 from app.verify_ledger()), 'production: the ledger starts empty and verifies');
select t.ok((select jsonb_array_length(quality_params) from public.crops where code = 'KNM') = 3, 'production: Kalanamak carries its three quality limits');
