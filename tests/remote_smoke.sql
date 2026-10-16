-- READ-ONLY smoke check for a Supabase project after `db push` + seeds. Safe on production: no writes.
-- Run: psql "$SUPABASE_DB_URL" -f tests/remote_smoke.sql   (or paste into Dashboard → SQL Editor)
-- Every row must start with OK (46 rows; three of them, statement logging, the reminder round and the nightly check, say how the project is set up). The same file serves staging (demo seed expected) and production (demo
-- seed forbidden): the 'environment' row says which one it found, from app.environment() (migration 23).
-- API exposure of the `app` schema is not checked here: hosted Supabase keeps that setting in PostgREST's config, which
-- SQL cannot read. Prove it with tests/remote_api_check.ps1 (REST call with the public key).

with env as (
  select case when to_regprocedure('app.environment()') is null then 'unknown'
              else (xpath('/row/e/text()', query_to_xml('select app.environment() as e', false, true, '')))[1]::text end as e,
         -- a practice system that was emptied on purpose (scripts/staging_fresh_start.ps1 notes when): no demo rows are
         -- expected there, and the state, the crop and the client are made in the app
         case when to_regclass('public.app_meta') is null then null
              else (xpath('/row/v/text()', query_to_xml('select (select value from public.app_meta where key = ''fresh_start'') as v', false, true, '')))[1]::text end as fresh
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
select 'stage_definitions (17)', case when count(*) = 17 then 'OK' else 'GOT ' || count(*) end from public.stage_definitions
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
select 'seed: Kalanamak crop',   case when exists (select 1 from public.crops where code = 'KNM') then 'OK'
                                      when (select fresh from env) is not null
                                      then 'OK fresh start (' || (select fresh from env) || '): ' || (select count(*) from public.crops) || ' crop(s), made in the app'
                                      else 'NOT SEEDED' end
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
                                                when (select fresh from env) is not null
                                                 and not exists (select 1 from public.app_users where id::text like '00000000-0000-4000-8000-0000000003%')
                                                 and not exists (select 1 from public.scopes where id::text like '00000000-0000-4000-8000-0000000004%')
                                                then 'OK staging: fresh start, no demo data'
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
select 'the admin oversees',     case when to_regprocedure('app.platform_overview()') is null or to_regprocedure('app.hr_seat_filled()') is null
                                        or to_regprocedure('app.ledger_page(text, uuid, uuid, uuid, boolean, integer, integer)') is null
                                      then 'MISSING (push migration 34)'
                                      when exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'crops' and policyname = 'crops_admin')
                                        or not exists (select 1 from pg_trigger where tgname = 'farmers_z1_two_steps' and not tgisinternal)
                                        or position('<> ''admin''' in pg_get_functiondef(to_regprocedure('app.eff_assignments(uuid)'))) = 0
                                      then 'OLD: the admin still runs operations (push migration 34)'
                                      else 'OK oversight only; crops are the State Manager''s; farmers verified twice' end
union all
select 'joiner HR data',         case when to_regprocedure('app.record_id_number(uuid, uuid, text, text, text, text, text)') is null
                                        or to_regprocedure('app.scrub_numbers(text)') is null or to_regclass('public.employee_personal') is null
                                        or to_regclass('public.id_number_matches') is null
                                      then 'MISSING (push migration 37)'
                                      when (select count(*) from pg_indexes where schemaname = 'public' and indexname in
                                              ('employee_docs_pan_hmac_key', 'employee_docs_aadhaar_hmac_key', 'employee_docs_uan_hmac_key')) <> 3
                                        or not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'hr_docs_remove_unmasked')
                                        or has_function_privilege('authenticated', 'app.record_id_number(uuid, uuid, text, text, text, text, text)', 'execute')
                                        or exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'employee_docs'
                                                     and column_name ~ '^(pan|aadhaar|uan|account|bank_account)(_number)?$')
                                      then 'OLD or OPEN: duplicates not enforced, or the number recorder open to people (push migration 37)'
                                      else 'OK fingerprints only; duplicates refused; masked images removable' end
union all
select 'onboarding at scale',     case when to_regclass('public.openings') is null or to_regclass('public.invites') is null
                                        or to_regclass('public.message_queue') is null or to_regclass('public.seat_deputies') is null
                                        or to_regprocedure('app.import_joiners(jsonb, boolean, text)') is null
                                        or to_regprocedure('app.joiners_page(jsonb)') is null or to_regprocedure('app.opening_targets(uuid)') is null
                                        or to_regprocedure('app.activate_joiner(uuid, text)') is null
                                      then 'MISSING (push migration 38)'
                                      when to_regprocedure('app.activate_joiner(uuid)') is not null
                                        or has_function_privilege('authenticated', 'app.record_invite(uuid, uuid, text, text, integer)', 'execute')
                                        or has_function_privilege('authenticated', 'app.invite_lookup(text)', 'execute')
                                        or has_column_privilege('authenticated', 'public.invites', 'token_hash', 'select')
                                        or not exists (select 1 from pg_trigger where tgname = 'employee_org_guard' and not tgisinternal)
                                        or (select count(*) from public.onboarding_templates where active and role is not null) < 4
                                      then 'OLD or OPEN: the invite functions or the token fingerprints open to people, no gate, or no role checklists (push migration 38)'
                                      else 'OK openings, import, invites (fingerprints only), gate on Mark as joined, role checklists' end
union all
select 'hr by geography',         case when to_regclass('public.hr_states') is null or to_regprocedure('app.hr_covers(uuid)') is null
                                        or to_regprocedure('app.set_base_location(uuid, uuid, text)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'employee_org' and column_name = 'base_state_id')
                                      then 'MISSING (push migration 39)'
                                      when not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'employee_docs' and qual like '%hr_covers%')
                                        or not exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'hr_docs_read' and qual like '%hr_covers_path%')
                                        or position('HR holds no seat' in pg_get_functiondef(to_regprocedure('app.assign(uuid, assignment_lens, uuid, op_role, stage_type[], text, date)'))) = 0
                                        or has_table_privilege('authenticated', 'public.hr_states', 'insert')
                                      then 'OLD or OPEN: HR not limited to its states, or HR may be seated (push migration 39)'
                                      else 'OK an HR resource works for her states; HR holds no seat' end
union all
select 'HR holds no seat',        case when to_regclass('public.hr_states') is null then 'MISSING (push migration 39)'
                                      when exists (select 1 from public.assignments a join public.app_users u on u.id = a.employee_id
                                                    where a.active and u.system_role in ('hr_admin', 'hr_resource'))
                                      then 'NOT OK: a seat is still held by ' || (select string_agg(distinct u.display_name, ', ') from public.assignments a join public.app_users u on u.id = a.employee_id
                                                           where a.active and u.system_role in ('hr_admin', 'hr_resource')) || ': the HR Admin ends it'
                                      else 'OK' end
union all
select 'state manager rules',     case when to_regprocedure('app.state_home(uuid)') is null or to_regprocedure('app.sm_sees(uuid)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'crops' and column_name = 'state_id')
                                      then 'MISSING (push migration 41)'
                                      when exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'crops' and policyname = 'crops_write')
                                        or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'scopes' and policyname = 'scopes_insert' and with_check like '%runs_client%')
                                        or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'farmers' and policyname = 'farmers_insert' and with_check like '%farmer_create%')
                                        or position('assert_assignable' in pg_get_functiondef(to_regprocedure('app.slots_assignment()'))) = 0
                                        or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'app_users' and policyname = 'users_read' and qual like '%sm_seen_ids%')
                                        or exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'client_errors' and qual like '%state_supervisor%')
                                      then 'OLD or OPEN: a State Manager still reaches past his own (push migration 41)'
                                      else 'OK crops have a state; scopes are built by the Client Manager; farmers by their own state; seats only for his people' end
union all
select 'crop registry',           case when to_regprocedure('app.crop_registry()') is null or to_regclass('public.farmer_gap') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'crops' and column_name = 'recommended_chain')
                                      then 'MISSING (push migration 42)'
                                      when exists (select 1 from pg_constraint where conname = 'crops_code_key')
                                        or not exists (select 1 from pg_trigger where tgname = 'scopes_a2_crop_ready')
                                        or position('procurement_crop_checks' in pg_get_functiondef(to_regprocedure('app.check_new_footprint(footprints)'))) = 0
                                        or position('judge_typed' in pg_get_functiondef(to_regprocedure('app.derive_qc_verdict(footprints)'))) = 0
                                      then 'OLD (push migration 42)'
                                      else 'OK crops ready before use; typed limits; practice checked at procurement; codes per state' end
union all
select 'farmer register',         case when to_regprocedure('app.farmer_register(jsonb)') is null or to_regclass('public.farmer_dup_reviews') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'farmers' and column_name = 'gi_land_acres')
                                      then 'MISSING (push migration 43)'
                                      when not exists (select 1 from pg_trigger where tgname = 'farmers_z2_register_rules')
                                        or position('above the expected yield' in pg_get_functiondef(to_regprocedure('app.procurement_crop_checks(footprints, scopes)'))) = 0
                                      then 'OLD (push migration 43)'
                                      else 'OK GI land before the Farmer ID; duplicates by phone flagged; yield checked' end
union all
select 'rules and farmer ids',     case when to_regprocedure('app.stage_refusal(uuid, uuid)') is null or to_regclass('public.state_farmers') is null
                                        or to_regclass('public.farmer_change_flags') is null
                                      then 'MISSING (push migration 44)'
                                      when not exists (select 1 from pg_trigger where tgname = 'scopes_a3_staffed')
                                        or not exists (select 1 from pg_trigger where tgname = 'farmers_z3_state_id')
                                        or position('a2.lens' in pg_get_functiondef('app.manages_place(uuid, uuid, uuid)'::regprocedure)) > 0
                                        or position('''state''' in pg_get_functiondef('app.manages_place(uuid, uuid, uuid)'::regprocedure)) > 0
                                      then 'OLD (push migration 44)'
                                      else 'OK rosters by the Client Manager; every stage staffed before activation; two farmer IDs' end
union all
select 'production safeguards',    case when to_regclass('public.change_log') is null or to_regclass('public.corrections') is null
                                        or to_regprocedure('app.ledger_head()') is null
                                      then 'MISSING (push migration 45)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 21
                                        or not exists (select 1 from pg_trigger where tgname = 'change_log_no_update_delete')
                                        or not exists (select 1 from pg_trigger where tgname = 'ledger_no_truncate')
                                      then 'INCOMPLETE: a change-log trigger or a guard is missing'
                                      when exists (select 1 from app.verify_change_log())
                                      then 'CHANGE LOG BROKEN at line ' || (select seq from app.verify_change_log() limit 1)
                                      else 'OK change log on 21 tables, intact; corrections through one door; fingerprint for an outside copy' end
union all
select 'requirements',             case when to_regclass('public.requirements') is null or to_regclass('public.requirement_lines') is null
                                        or to_regprocedure('app.decide_lines(uuid[], text, text, jsonb)') is null
                                      then 'MISSING (push migration 46)'
                                      when (select count(*) from pg_trigger where tgname = 'zy_requirements') < 4
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'openings' and column_name = 'source')
                                        or position('own creator' in (select prosrc from pg_proc where oid = 'app.footprints_before_update()'::regprocedure)) > 0
                                      then 'INCOMPLETE: a requirements trigger, the openings'' source, or the two-stages rule is missing'
                                      else 'OK requirements and their lines; openings say where they came from; one person may verify at the next stage' end
union all
select 'farmer corrections',       case when to_regclass('public.farmer_proposals') is null
                                        or to_regprocedure('app.decide_farmer_proposal(uuid, boolean, text)') is null
                                      then 'MISSING (push migration 47)'
                                      else 'OK Procurement proposes a correction of a verified farmer; the Client Manager decides' end
union all
select 'operator template',        case when to_regclass('public.footprint_returns') is null
                                        or to_regprocedure('app.return_footprint(uuid, text)') is null
                                        or to_regprocedure('app.client_ledger_page(uuid, text, uuid, uuid, integer, integer)') is null
                                        or exists (select 1 from public.scopes where short_code is null)
                                      then 'MISSING (push migration 48)'
                                      else 'OK return to sender, the date it happened, a manager''s reason, record numbers that name the scope, the Client Manager''s ledger' end
union all
select 'trust numbers',            case when to_regclass('public.footprint_links') is null
                                        or to_regprocedure('app.system_checks(uuid)') is null
                                        or to_regprocedure('app.incoming_lots(uuid, public.stage_type)') is null
                                        or exists (select 1 from public.stage_definitions where stage_type = 'procurement' and jsonb_array_length(physical_checks) = 0)
                                      then 'MISSING (push migration 49)'
                                      else 'OK the system checks what it knows, people tick what they see; what is left of a lot; lineage, farmers and GI; thresholds from the crop' end
union all
select 'packs and release',        case when to_regclass('public.packs') is null
                                        or to_regclass('public.release_events') is null
                                        or to_regclass('public.deliveries') is null
                                        or to_regprocedure('app.public_pack(text)') is null
                                        or to_regprocedure('app.release_preview(uuid)') is null
                                        or exists (select 1 from public.stage_definitions where stage_type = 'packing' and form_schema @> '[{"key": "batch_code"}]')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'qc' and form_schema @> '[{"key": "report_no"}]')
                                      then 'MISSING (push migration 50)'
                                      else 'OK batch codes from the system, one label per pack, the summary before release, recall on every pack, lab proof, delivery' end
union all
select 'setup lists',              case when to_regclass('public.places') is null
                                        or to_regclass('public.collection_points') is null or to_regclass('public.buyers') is null
                                        or to_regclass('public.labs') is null or to_regclass('public.market_profiles') is null
                                        or to_regprocedure('app.add_place(uuid, text, text, text)') is null
                                        or to_regprocedure('app.ledger_status()') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'farmers' and column_name = 'farm_lat')
                                      then 'MISSING (push migration 51)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 41
                                        -- (read through query_to_xml: the tables are named only once the row above has found them)
                                        or (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.quality_param_library', false, true, '')))[1]::text::int < 11
                                        or (xpath('/row/n/text()', query_to_xml('select count(*) as n from public.crops c where not exists (select 1 from public.market_profiles m where m.crop_id = c.id and m.code = ''domestic'' and m.status = ''active'')', false, true, '')))[1]::text::int > 0
                                      then 'NOT OK (the lists are there; the change log, the library or a crop''s carried profile is missing)'
                                      else 'OK places, the Client Manager''s lists, labs, market profiles with their sources, farm GPS, the ledger banner' end
union all
select 'procurement batch',        case when to_regclass('public.lot_payments') is null
                                        or to_regprocedure('app.save_lot_payment(uuid, jsonb)') is null
                                        or to_regprocedure('app.farmer_card(uuid, uuid)') is null
                                        or to_regprocedure('app.lot_forward(uuid)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scopes' and column_name = 'record_price')
                                      then 'MISSING (push migration 52)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 42
                                        or not exists (select 1 from pg_trigger where tgname = 'footprints_a00_payment')
                                        or not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'lot_payments')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'village_batch' and label like 'Collection Batch%')
                                      then 'NOT OK (the payments table is there; its change log, its trigger, its read rule or the Collection Batch form is missing)'
                                      else 'OK where/GPS/who delivered, price and payment kept apart, the farmer card, the Collection Batch of one place, the journey forward' end
union all
select 'milling qc packing',       case when to_regclass('public.qc_samples') is null or to_regclass('public.net_weight_checks') is null
                                        or to_regclass('public.lot_closures') is null or to_regclass('public.qc_profile_verdicts') is null
                                        or to_regprocedure('app.draw_sample(uuid, jsonb)') is null or to_regprocedure('app.close_lot(uuid, text)') is null
                                        or to_regprocedure('app.record_net_weights(uuid, jsonb)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scopes' and column_name = 'stage_details_required')
                                      then 'MISSING (push migration 53)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 46
                                        or not exists (select 1 from pg_trigger where tgname = 'footprints_z7_sample')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'milling' and form_schema @> '[{"key": "head_rice_kg"}]')
                                      then 'NOT OK (the tables are there; their change log, the sample trigger or the new milling form is missing)'
                                      else 'OK the mill and its line clearance, head rice and broken, close a lot; the sample drawn first, a verdict per market; packs from the list, the net weight check' end
union all
select 'commercial shipment',      case when to_regclass('public.sale_terms') is null or to_regclass('public.export_documents') is null
                                        or to_regclass('public.bills_of_lading') is null
                                        or to_regprocedure('app.packs_left(uuid)') is null or to_regprocedure('app.set_export_doc(uuid, text, text, uuid, text)') is null
                                        or to_regprocedure('app.add_bill_of_lading(uuid, text)') is null or to_regprocedure('app.lab_for_scope(uuid, uuid)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'labs' and column_name = 'client_id')
                                      then 'MISSING (push migration 54)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 49
                                        or not exists (select 1 from pg_trigger where tgname = 'footprints_a01_sale_terms')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'commercial' and form_schema @> '[{"key": "buyer_id"}]')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'village_batch' and form_schema @> '[{"key": "collection_point_id"}]')
                                      then 'NOT OK (the tables are there; their change log, the price trigger, or the new Commercial or Collection Batch form is missing)'
                                      when exists (select 1 from public.ledger where payload ? 'price_per_kg')
                                      then 'NOT OK (a sale price is in the ledger)'
                                      else 'OK buyers from the list, packs by type, the price kept apart, export documents; the export papers, pack codes and the bill of lading; a batch of one collection point; client labs; villages from the list' end
union all
select 'warehouse',                case when to_regclass('public.warehouse_inspections') is null or to_regclass('public.warehouse_bags_out') is null
                                        or to_regprocedure('app.record_inspection(uuid, date, text, text)') is null
                                        or to_regprocedure('app.record_bags_out(uuid, integer, date, text)') is null
                                        or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scopes' and column_name = 'warehouse_inspection_days')
                                      then 'MISSING (push migration 55)'
                                      when (select count(*) from pg_trigger where tgname = 'zz_change_log') < 51
                                        or not exists (select 1 from pg_trigger where tgname = 'footprints_z9_warehouse_flag')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'warehouse' and form_schema @> '[{"key": "received_kg"}]')
                                        or not exists (select 1 from public.stage_definitions where stage_type = 'commercial' and form_schema @> '[{"key": "incoterms", "shown_if": {"market": "export"}}]')
                                      then 'NOT OK (the tables are there; their change log, the flag trigger, the Warehouse stage or the Commercial form is missing)'
                                      else 'OK the Warehouse: sent and received, a reason and a flag above 2 %, inspections due and overdue, bags out, days in storage; stored but not recorded' end
union all
select 'statement logging',        case when exists (select 1 from pg_extension where extname = 'pgaudit')
                                        and exists (select 1 from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                                                     where r.rolname = 'postgres' and array_to_string(s.setconfig, ',') ~ 'pgaudit\.log=[^,]*(write|all)')
                                      then 'OK the database owner''s writes are logged (pgaudit)'
                                      when exists (select 1 from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                                                     where r.rolname = 'postgres' and array_to_string(s.setconfig, ',') ~ 'log_statement=(mod|all)')
                                      then 'OK the database owner''s writes are logged (log_statement)'
                                      else 'NOT SET: the database owner''s writes are not logged (docs/PRODUCTION_SAFEGUARDS.md, step 4)' end
union all
select 'reminder round',          case when to_regclass('cron.job') is null then 'NO pg_cron: reminders are queued when HR opens the Joiners list'
                                      when (xpath('/row/n/text()', query_to_xml(
                                              'select count(*) as n from cron.job where jobname = ''grainveda-reminders''', false, true, '')))[1]::text::int = 1
                                      then 'OK' else 'NOT SCHEDULED' end
union all
select 'nightly ledger check',   case when to_regclass('cron.job') is null then 'NO pg_cron: see RUNSHEET_phase3 step 5'
                                      when (xpath('/row/n/text()', query_to_xml(
                                              'select count(*) as n from cron.job where jobname = ''grainveda-ledger-nightly''', false, true, '')))[1]::text::int = 1
                                      then 'OK' else 'NOT SCHEDULED' end;
