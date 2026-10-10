-- Migration 14: the only `app` functions anon / authenticated can execute are the named ones.
-- A new function is closed by default; opening it means adding it here AND granting it in a migration.
begin;
select t.as_service();

create temp table allowed (role_name text, proname text);
insert into allowed values
  ('anon', 'public_lot_journey'), ('anon', 'phone_key'), ('anon', 'email_key'),
  ('authenticated', 'public_lot_journey'), ('authenticated', 'phone_key'), ('authenticated', 'email_key'),
  ('authenticated', 'verify_footprint'), ('authenticated', 'seal_lot'), ('authenticated', 'incoming_records'),
  ('authenticated', 'pipeline_summary'), ('authenticated', 'resolve_market_verdict'), ('authenticated', 'available_qty'),
  ('authenticated', 'verify_ledger'),
  ('authenticated', 'current_role'), ('authenticated', 'current_user_id'), ('authenticated', 'my_state_ids'),
  ('authenticated', 'my_client_id'), ('authenticated', 'can_access_scope'), ('authenticated', 'can_access_client'),
  ('authenticated', 'can_manage_client'), ('authenticated', 'can_see_footprint'), ('authenticated', 'farmer_access'),
  ('authenticated', 'is_my_stage'),
  -- Phase 1 API (migrations 15–17)
  ('authenticated', 'preview_reconcile'), ('authenticated', 'preview_verdict'), ('authenticated', 'check_chain'), ('authenticated', 'stage_form'),
  ('authenticated', 'import_farmers'), ('authenticated', 'my_context'), ('authenticated', 'footprint_detail'),
  ('authenticated', 'submit_farmer'), ('authenticated', 'send_back_farmer'), ('authenticated', 'verify_farmer'),
  ('authenticated', 'register_attachment'), ('authenticated', 'normalise_in_mobile'), ('authenticated', 'preview_correction'), ('authenticated', 'split_grades'),
  ('authenticated', 'lot_trace'),
  -- Phase 4 (migration 22)
  ('authenticated', 'withdraw_footprint'),
  -- Phase 4 (migration 23)
  ('anon', 'environment'), ('authenticated', 'environment'), ('authenticated', 'lot_markets'), ('authenticated', 'scope_activity'),
  ('authenticated', 'reset_login_allowed'), ('authenticated', 'report_client_error'), ('authenticated', 'check_ledger_now'),
  -- migration 34: the admin's dashboard and the whole ledger (both refuse anyone but the admin)
  ('authenticated', 'platform_overview'), ('authenticated', 'ledger_page'), ('authenticated', 'hr_seat_filled'), ('authenticated', 'acts_as_hr'), ('authenticated', 'admin_trends'),
  -- Phase 4 (migration 24)
  ('authenticated', 'seal_source'),
  -- Identity layer (migration 32): helpers the access policies evaluate as the caller; each answers only about the caller
  ('authenticated', 'is_admin'), ('authenticated', 'is_hr'), ('authenticated', 'is_hr_admin'), ('authenticated', 'hr_may_manage'),
  ('authenticated', 'holds_op_role'), ('authenticated', 'can_assign'), ('authenticated', 'i_manage_scope'),
  ('authenticated', 'manages_scope_row'), ('authenticated', 'sees_scope_row'), ('authenticated', 'sees_whole_scope'),
  ('authenticated', 'acts_in_scope'), ('authenticated', 'farmer_write'), ('authenticated', 'i_verify_farmers'),
  ('authenticated', 'manages_viewer'),
  -- Identity layer (migration 33): onboarding, assignment, lifecycle, the screens' reads, the sign-in code
  ('authenticated', 'add_joiner'), ('authenticated', 'note_invite_sent'), ('authenticated', 'note_login_reset'), ('authenticated', 'add_client_viewer'),
  ('authenticated', 'mark_first_login'), ('authenticated', 'activate_joiner'), ('authenticated', 'my_onboarding'),
  ('authenticated', 'register_hr_file'), ('authenticated', 'complete_task'), ('authenticated', 'reopen_task'),
  ('authenticated', 'add_hr_note'), ('authenticated', 'set_goals'), ('authenticated', 'update_joiner'),
  ('authenticated', 'hr_pipeline'), ('authenticated', 'joiner_detail'),
  ('authenticated', 'assignment_warnings'), ('authenticated', 'assign'), ('authenticated', 'set_stages'),
  ('authenticated', 'end_preview'), ('authenticated', 'end_assignment'), ('authenticated', 'reassign'),
  ('authenticated', 'suspend_person'), ('authenticated', 'reinstate_person'), ('authenticated', 'offboard_preview'),
  ('authenticated', 'offboard_person'), ('authenticated', 'rehire_person'), ('authenticated', 'set_system_role'),
  ('authenticated', 'appoint_hr_admin'),
  ('authenticated', 'people_directory'), ('authenticated', 'employee_profile'), ('authenticated', 'scope_roster'),
  ('authenticated', 'state_overview'), ('authenticated', 'bootstrap_seats'), ('authenticated', 'audit_feed'),
  ('authenticated', 'daily_code_state'), ('authenticated', 'verify_daily_code'), ('authenticated', 'set_daily_code'),
  -- migration 37: numbers (the id-numbers function asks as the caller whose number it is; recording is service-key only),
  -- card images (HR's masked yes / no, the image deleted, "PAN card seen"), a shared bank account accepted
  ('authenticated', 'id_number_target'), ('authenticated', 'accept_shared_bank'), ('authenticated', 'confirm_masked'),
  ('authenticated', 'note_file_removed'), ('authenticated', 'may_remove_hr_file'), ('authenticated', 'record_card_seen');

do $$
declare r record; leaks text := '';
begin
  for r in
    select rl.rolname, p.proname, pg_get_function_identity_arguments(p.oid) as args
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      cross join (values ('anon'), ('authenticated')) rl(rolname)
     where n.nspname = 'app' and p.prokind = 'f'
       and has_function_privilege(rl.rolname, p.oid, 'execute')
       and not exists (select 1 from allowed a where a.role_name = rl.rolname and a.proname = p.proname)
  loop
    leaks := leaks || format('%s can execute app.%s(%s); ', r.rolname, r.proname, r.args);
  end loop;
  perform t.ok(leaks = '', 'api surface: no app function callable beyond the allowlist ' || leaks);
end $$;

select t.ok(not has_function_privilege('anon', 'app.ledger_append(uuid, uuid, public.ledger_event, uuid, jsonb)', 'execute'),
            'api surface: anon cannot write the ledger');
select t.ok(not has_function_privilege('authenticated', 'app.ledger_append(uuid, uuid, public.ledger_event, uuid, jsonb)', 'execute'),
            'api surface: signed-in users cannot write the ledger directly');
select t.ok(not has_function_privilege('authenticated', 'app.next_farmer_code(uuid)', 'execute'),
            'api surface: signed-in users cannot burn Farmer IDs');
select t.ok(not has_function_privilege('authenticated', 'app.issue_daily_code(uuid)', 'execute')
            and not has_function_privilege('authenticated', 'app.audit(text, uuid, jsonb, boolean)', 'execute')
            and not has_function_privilege('authenticated', 'app.eff_assignments(uuid)', 'execute')
            and not has_function_privilege('authenticated', 'app.manages_scope(uuid, uuid)', 'execute'),
            'api surface: signed-in users cannot draw a sign-in code, write the audit log, or ask about another person''s access');
select t.ok(has_function_privilege('anon', 'app.public_lot_journey(text)', 'execute'),
            'api surface: the public verify page still works for anonymous visitors');

-- The app still works through the granted surface after the revoke: T1 as signed-in users.
do $$
declare p uuid; q uuid; qr uuid; seal public.qr_seals;
begin
  p := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qc', p, t.u('06'),
          '{"qty_kg":147.5,"sample_qty_kg":0.5,"readings":{"moisture_pct":11.9,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.as_user(t.u('07'));
  perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('01'), '00000000-0000-4000-8000-000000000201', 'qr_activation', q, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr);
  perform t.ok(seal.qr_code like 'GV-%', 'api surface: T1 still seals as signed-in users (triggers run as owner)');
  perform t.as_anon();
  perform t.ok(app.public_lot_journey(seal.qr_code) is not null, 'api surface: anonymous journey read still works');
  perform t.as_service();
end $$;

rollback;
