-- READ-ONLY smoke check for a Supabase project after `db push` + seeds. Safe on production: no writes.
-- Run: psql "$SUPABASE_DB_URL" -f tests/remote_smoke.sql   (or paste into Dashboard → SQL Editor)
-- Every row must say OK (16 rows).
-- API exposure of the `app` schema is not checked here: hosted Supabase keeps that setting in PostgREST's config, which
-- SQL cannot read. Prove it with tests/remote_api_check.ps1 (REST call with the public key).

select 'extensions'            as check_, case when count(*) = 2 then 'OK' else 'MISSING' end as result
  from pg_extension where extname in ('pgcrypto','uuid-ossp')
union all
select 'schema app',            case when exists (select 1 from pg_namespace where nspname = 'app') then 'OK' else 'MISSING' end
union all
select 'tables (15)',           case when count(*) = 15 then 'OK' else 'GOT ' || count(*) end
  from information_schema.tables where table_schema = 'public'
    and table_name in ('states','crops','clients','stage_definitions','scopes','app_users','slot_assignments','farmers',
                       'footprint_counters','footprints','qc_verdicts','qr_seals','flags','attachments','ledger')
union all
select 'RLS on every table',    case when count(*) = 0 then 'OK' else 'OFF ON ' || string_agg(relname, ',') end
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
union all
select 'stage_definitions (16)', case when count(*) = 16 then 'OK' else 'GOT ' || count(*) end from public.stage_definitions
union all
select 'ledger guard trigger',   case when exists (select 1 from pg_trigger where tgname = 'ledger_no_update_delete') then 'OK' else 'MISSING' end
union all
select 'footprint triggers',     case when (select count(*) from pg_trigger where tgrelid = 'public.footprints'::regclass and not tgisinternal
                                       and tgname in ('footprints_before_insert','footprints_after_insert','footprints_before_update',
                                                      'footprints_after_update','footprints_no_delete','footprints_actor_guard',
                                                      'footprints_correction_guard','footprints_grade_lot_verifies_run')) = 8
                                      then 'OK' else 'MISSING (push all migrations)' end
union all
select 'ledger chain intact',    case when not exists (select 1 from app.verify_ledger()) then 'OK' else 'BROKEN' end
union all
select 'seed: Kalanamak crop',   case when exists (select 1 from public.crops where code = 'KNM') then 'OK' else 'NOT SEEDED' end
union all
select 'seed: 6 active scopes',  case when count(*) = 6 then 'OK' else 'GOT ' || count(*) end from public.scopes where status = 'active'
union all
select 'seed: 5 active farmers', case when count(*) = 5 then 'OK' else 'GOT ' || count(*) end from public.farmers where status = 'active'
union all
select 'api surface closed',     case when not has_function_privilege('anon', 'app.ledger_append(uuid, uuid, public.ledger_event, uuid, jsonb)', 'execute')
                                        and not has_function_privilege('authenticated', 'app.ledger_append(uuid, uuid, public.ledger_event, uuid, jsonb)', 'execute')
                                      then 'OK' else 'OPEN: anyone can write the ledger (push migration 14)' end
union all
select 'auth.uid mapping',       case when count(*) = 0 then 'OK' else count(*) || ' users still on placeholder auth_uid' end
  from public.app_users u where u.auth_uid = u.id
union all
select 'public journey rpc',     case when app.public_lot_journey('GV-NONE') is null then 'OK' else '?' end
union all
select 'phase 3 objects',        case when to_regclass('public.ledger_checks') is not null
                                        and exists (select 1 from information_schema.columns where table_schema = 'public'
                                                     and table_name = 'footprints' and column_name = 'client_ref')
                                        and to_regprocedure('app.lot_trace(uuid)') is not null
                                        and to_regprocedure('app.run_ledger_check(text)') is not null
                                      then 'OK' else 'MISSING (push migration 21)' end
union all
select 'nightly ledger check',   case when to_regclass('cron.job') is null then 'NO pg_cron: see RUNSHEET_phase3 step 5'
                                      when (xpath('/row/n/text()', query_to_xml(
                                              'select count(*) as n from cron.job where jobname = ''grainveda-ledger-nightly''', false, true, '')))[1]::text::int = 1
                                      then 'OK' else 'NOT SCHEDULED' end;
