-- READ-ONLY smoke check for a Supabase project after `db push` + seeds. Safe on production: no writes.
-- Run: psql "$SUPABASE_DB_URL" -f tests/remote_smoke.sql   (or paste into Dashboard → SQL Editor)
-- Every row must start with OK (30 rows). The same file serves staging (demo seed expected) and production (demo
-- seed forbidden): the 'environment' row says which one it found, from app.environment() (migration 23).
-- API exposure of the `app` schema is not checked here: hosted Supabase keeps that setting in PostgREST's config, which
-- SQL cannot read. Prove it with tests/remote_api_check.ps1 (REST call with the public key).

with env as (
  select case when to_regprocedure('app.environment()') is null then 'unknown'
              else (xpath('/row/e/text()', query_to_xml('select app.environment() as e', false, true, '')))[1]::text end as e
)
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
select 'environment',            case (select e from env) when 'production' then 'OK production' when 'staging' then 'OK staging (practice system)'
                                      else 'MISSING app.environment() (push migration 23)' end
union all
select 'demo data',              case when (select e from env) = 'production'
                                      then case when not exists (select 1 from public.app_users where id::text like '00000000-0000-4000-8000-0000000003%')
                                                 and not exists (select 1 from public.scopes where id::text like '00000000-0000-4000-8000-0000000004%')
                                                then 'OK production: no demo people or scopes'
                                                else 'DEMO DATA ON PRODUCTION: stop' end
                                      else case when (select count(*) from public.scopes where status = 'active' and id::text like '00000000-0000-4000-8000-0000000004%') = 6
                                                 and (select count(*) from public.farmers where status = 'active') >= 5
                                                then 'OK staging: 6 demo scopes, 5+ active farmers'
                                                else 'NOT SEEDED (run seeds 02–05)' end end
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
select 'phase 4 objects',        case when to_regclass('public.withdrawals') is not null and to_regclass('public.client_errors') is not null
                                        and to_regclass('public.app_meta') is not null
                                        and to_regprocedure('app.withdraw_footprint(uuid, text)') is not null
                                        and to_regprocedure('app.lot_markets(uuid)') is not null
                                        and to_regprocedure('app.reset_login_allowed(uuid)') is not null
                                        and to_regprocedure('app.check_ledger_now()') is not null
                                        and to_regprocedure('app.seal_source(uuid)') is not null
                                        and to_regprocedure('app.record_missing_evidence_blocks()') is not null
                                      then 'OK' else 'MISSING (push migrations 22–27)' end
union all
select 'phase 4 triggers',       case when (select count(*) from pg_trigger where not tgisinternal and tgname in
                                         ('footprints_a0_api_insert', 'footprints_a0_api_update', 'footprints_c0_insert_rules', 'footprints_c0_update_rules',
                                          'footprints_z1_split_on_save', 'scopes_a0_state_guard', 'farmers_z0_change_guard', 'farmers_ledger', 'flags_guard',
                                          'flags_ledger', 'attachments_guard', 'attachments_ledger', 'slots_guard', 'slots_ledger', 'app_users_ledger',
                                          'scopes_z0_slots_at_activation')) = 16
                                      then 'OK' else 'MISSING (push migrations 22–27)' end
union all
select 'ledger read by stage',   case when exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'ledger'
                                                    and policyname = 'ledger_read' and qual like '%can_see_footprint%')
                                      then 'OK' else 'OPEN: operators can read every block of their scope (push migration 25)' end
union all
select 'direct writes closed',   case when not has_table_privilege('authenticated', 'public.attachments', 'update')
                                        and not has_table_privilege('authenticated', 'public.qc_verdicts', 'insert')
                                        and not has_table_privilege('authenticated', 'public.withdrawals', 'insert')
                                        and not has_table_privilege('authenticated', 'public.client_errors', 'insert')
                                        and not has_table_privilege('authenticated', 'public.ledger', 'insert')
                                      then 'OK' else 'OPEN (push migrations 22–23)' end
union all
select 'evidence in the ledger', case when not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                                                        where t.typname = 'ledger_event' and e.enumlabel = 'evidence')
                                      then 'MISSING (push migration 26)'
                                      when exists (select 1 from public.attachments a where not exists
                                                    (select 1 from public.ledger l where l.event::text = 'evidence' and l.payload->>'attachment_id' = a.id::text))
                                      then 'CATCH-UP NEEDED: select app.record_missing_evidence_blocks();'
                                      else 'OK' end
union all
select 'public page data',       case when to_regprocedure('app.public_lot_journey(text)') is null then 'MISSING (push all migrations)'
                                      when position('computed' in pg_get_functiondef(to_regprocedure('app.public_lot_journey(text)'))) = 0
                                      then 'OK' else 'OPEN: the buyer''s name is sent to anyone who has the QR (push migration 28)' end
union all
select 'capture time, verdict preview', case when exists (select 1 from information_schema.columns
                                                    where table_schema = 'public' and table_name = 'footprints' and column_name = 'captured_at')
                                        and exists (select 1 from pg_trigger where not tgisinternal and tgname = 'footprints_d0_capture_time')
                                        and to_regprocedure('app.preview_verdict(uuid, jsonb)') is not null
                                      then 'OK' else 'MISSING (push migration 29)' end
union all
select 'a new client can be read back', case when exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'clients'
                                                           and policyname = 'clients_read_by_row' and cmd = 'SELECT')
                                      then 'OK' else 'MISSING: nobody can add a client from the screen (push migration 30)' end
union all
select 'identity layer objects',  case when to_regclass('public.assignments') is not null and to_regclass('public.audit_log') is not null
                                        and to_regclass('public.employee_org') is not null and to_regclass('public.onboarding_tasks') is not null
                                        and to_regprocedure('app.add_joiner(jsonb)') is not null and to_regprocedure('app.manages_scope(uuid, uuid)') is not null
                                        and to_regprocedure('app.offboard_person(uuid, date, text, text, text)') is not null
                                        and exists (select 1 from pg_trigger where not tgisinternal and tgname = 'audit_log_no_change')
                                        and exists (select 1 from public.onboarding_templates where is_default)
                                      then 'OK' else 'MISSING (push migrations 31–33)' end
union all
select 'people moved to assignments', case when to_regclass('public.assignments') is null then 'MISSING (push migrations 31–33)' else
                                      (xpath('/row/r/text()', query_to_xml($q$
                                        select case
                                          when exists (select 1 from public.slot_assignments sa where not exists
                                                        (select 1 from public.assignments a where a.id = sa.assignment_id and a.active))
                                            then 'BROKEN: a stage is held without a live assignment'
                                          when exists (select 1 from public.app_users u where u.role = 'state_manager' and not exists
                                                        (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = 'state'))
                                            or exists (select 1 from public.app_users u where u.role = 'client_manager' and not exists
                                                        (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.op_role = 'client_account'))
                                            or exists (select 1 from public.app_users u where u.role = 'admin' and u.system_role <> 'admin')
                                            then 'BROKEN: a person''s summary role has no assignment behind it'
                                          else 'OK ' || (select count(*) from public.assignments where active) || ' live assignments' end as r$q$, false, true, '')))[1]::text end
union all
select 'the two seats',          case when to_regclass('public.assignments') is null then 'MISSING (push migrations 31–33)' else
                                      (xpath('/row/r/text()', query_to_xml($q$
                                        select case when (select count(*) from public.app_users where system_role = 'admin' and status = 'active') = 0
                                                      and (select count(*) from public.app_users) > 0 then 'NO ACTIVE ADMIN'
                                                    else 'OK ' || (select count(*) from public.app_users where system_role = 'admin' and status = 'active') || ' admin, HR Admin seat '
                                                         || case when exists (select 1 from public.app_users where system_role = 'hr_admin' and status <> 'offboarded')
                                                                 then 'filled' else 'VACANT (the admin appoints under System → Seats)' end end as r$q$, false, true, '')))[1]::text end
union all
select 'manager rules ask about the scope', case when to_regprocedure('app.withdraw_footprint(uuid, text)') is null then 'MISSING (push all migrations)'
                                      when position('is_gateway_role' in pg_get_functiondef(to_regprocedure('app.withdraw_footprint(uuid, text)'))) = 0
                                       and position('is_gateway_role' in pg_get_functiondef(to_regprocedure('app.qc_verdicts_guard()'))) = 0
                                      then 'OK' else 'OLD: a manager of one client is a manager wherever they hold a stage (push migration 32)' end
union all
select 'people written only by their actions', case when not has_table_privilege('authenticated', 'public.app_users', 'insert')
                                        and to_regclass('public.assignments') is not null
                                        and not has_table_privilege('authenticated', 'public.assignments', 'insert')
                                        and not has_table_privilege('authenticated', 'public.assignments', 'update')
                                        and not has_table_privilege('authenticated', 'public.audit_log', 'insert')
                                        and not has_table_privilege('authenticated', 'public.employee_docs', 'update')
                                        and not has_function_privilege('authenticated', 'app.issue_daily_code(uuid)', 'execute')
                                      then 'OK' else 'OPEN (push migrations 31–33)' end
union all
select 'once-a-day sign-in code', case when to_regprocedure('app.daily_code_on()') is null then 'MISSING (push migration 32)'
                                      when (xpath('/row/r/text()', query_to_xml('select app.daily_code_on() as r', false, true, '')))[1]::text = 'true'
                                      then 'OK ON: every sign-in needs today''s code (a sender must be working)'
                                      else 'OK off (decision 5 Oct 2026: until a sender exists)' end
union all
select 'nightly ledger check',   case when to_regclass('cron.job') is null then 'NO pg_cron: see RUNSHEET_phase3 step 5'
                                      when (xpath('/row/n/text()', query_to_xml(
                                              'select count(*) as n from cron.job where jobname = ''grainveda-ledger-nightly''', false, true, '')))[1]::text::int = 1
                                      then 'OK' else 'NOT SCHEDULED' end;
