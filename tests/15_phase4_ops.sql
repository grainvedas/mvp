-- Migration 23: environment marker, field error log, markets a lot may be sold to, activity per day,
-- who may reset whose password, the withdrawn / replaces keys of the lot trace, and the ledger check on demand.
begin;
select t.as_service();

-- 1 · environment -------------------------------------------------------------------------------------------------
select t.ok(app.environment() = 'staging', 'environment: anything that is not marked production is staging');
select t.as_anon();
select t.ok(app.environment() = 'staging', 'environment: readable without a login (the sign-in page shows the practice strip)');
select t.fails($q$ select * from public.app_meta $q$, 'permission denied', 'environment: the table itself is not readable');
select t.as_user(t.u('01'));
select t.fails($q$ insert into public.app_meta values ('environment', 'production') $q$, 'permission denied', 'environment: not even the admin can flip it from the app');
select t.as_service();
insert into public.app_meta values ('environment', 'production');
select t.ok(app.environment() = 'production', 'environment: production once the marker row is written (by the production seed)');

-- 2 · field error log ---------------------------------------------------------------------------------------------
select t.as_anon();
select t.fails($q$ select app.report_client_error('error', 'x') $q$, 'permission denied', 'errors: an anonymous visitor cannot write to the error log');
select t.as_user(t.u('05'));
select t.ok(app.report_client_error('sync_refused', 'Milling: input (197) must equal rice + bran + loss (224)', null, '/work/abc/milling?draft=1', 'b1', true, 'Android'),
            'errors: an operator''s phone reports a refused sync');
select t.ok(not app.report_client_error('error', '   '), 'errors: an empty report is ignored');
select t.ok(app.report_client_error('nonsense', repeat('x', 900), repeat('y', 5000)), 'errors: an unknown kind is stored as error');
select t.ok((select count(*) from public.client_errors) = 0, 'errors: operators cannot read the log');
do $$ declare i int; n int := 0; begin
  for i in 1..40 loop if app.report_client_error('error', 'loop ' || i) then n := n + 1; end if; end loop;
  perform t.ok(n = 28, 'errors: a looping screen is cut off at 30 reports an hour (2 + 28 accepted, 12 dropped)');
end $$;
select t.as_user(t.u('01'));
select t.ok((select count(*) from public.client_errors) = 30, 'errors: the admin reads them');
select t.ok((select path = '/work/abc/milling' and role = 'operator' and user_id = t.u('05') and online from public.client_errors where kind = 'sync_refused'),
            'errors: who, role and screen are stamped by the server; the query string is dropped');
select t.ok((select length(message) = 500 and length(detail) = 2000 and kind = 'error' from public.client_errors where message like 'xxx%'),
            'errors: long text is trimmed');
select t.as_user(t.u('03'));
select t.ok((select count(*) from public.client_errors) = 0, 'errors: a Client Manager does not see them (admin and State Manager only)');
select t.as_service();

-- 3 · markets, 5 · activity, 7 · trace ------------------------------------------------------------------------------
do $$
declare p uuid; q uuid; m uuid; c1 uuid; j jsonb; act record; r public.footprints; c constant uuid := '00000000-0000-4000-8000-000000000201';
        s0 bigint; v0 bigint;
begin
  -- what the scope's ledger already holds today (the seed's stage assignments are supervisory blocks since migration 25)
  select coalesce(sum(a.saved), 0), coalesce(sum(a.supervisory), 0) into s0, v0
    from app.scope_activity(t.scope('03'), 14) a where a.day = (now() at time zone 'Asia/Kolkata')::date;
  p := t.procure(t.scope('03'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);
  perform t.verify(p, t.u('06'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'qc', p, t.u('06'), '{"qty_kg":120,"sample_qty_kg":1,"readings":{"moisture_pct":12.1,"broken_pct":2,"foreign_matter_pct":0.2}}') returning id into q;
  perform t.verify(q, t.u('08'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (t.scope('03'), c, 'milling', q, t.u('08'), '{"input_kg":119,"rice_kg":80,"bran_kg":30,"loss_kg":9}') returning id into m;

  perform t.as_user(t.u('11'));                                         -- Commercial operator: sees milling, not QC
  perform t.ok((select count(*) from public.footprints where id = q) = 0, 'markets: the Commercial operator cannot read the QC record (thumb rule)');
  j := app.lot_markets(m);
  perform t.ok((j->>'has_qc')::boolean and j->>'domestic' = 'pass' and j->>'export' = 'fail' and not (j->>'export_allowed')::boolean
               and j->'markets' = '["domestic"]'::jsonb, 'markets: T3 a 12.1% lot is domestic-only: export is not offered');
  perform t.as_user(t.u('05'));
  perform t.fails(format('select app.lot_markets(%L)', m), 'record not found', 'markets: an operator who cannot see the lot gets nothing');
  perform t.as_user(t.u('12'));
  perform t.fails(format('select app.lot_markets(%L)', m), 'record not found', 'markets: nor does another client''s user');
  perform t.as_user(t.u('03'));
  update public.qc_verdicts set override = jsonb_build_object('market', 'export', 'reason', 'Buyer accepts 12.1% with re-drying', 'authoriser', t.u('03')) where footprint_id = q;
  perform t.as_user(t.u('11'));
  j := app.lot_markets(m);
  perform t.ok((j->>'export_allowed')::boolean and (j->>'overridden')::boolean and j->>'export' = 'fail' and j->'markets' = '["domestic", "export"]'::jsonb,
               'markets: T3 after the manager''s override export is offered; the derived FAIL is still shown');

  -- activity
  perform t.as_user(t.u('03'));
  select * into act from app.scope_activity(t.scope('03'), 14) limit 1;
  perform t.ok(act.day = (now() at time zone 'Asia/Kolkata')::date and act.saved = s0 + 3 and act.supervisory = v0 + 1,
               'activity: today (IST) on this scope: 3 more saves and 1 more supervisory act (the override), from the ledger');
  perform t.as_user(t.u('12'));
  perform t.ok((select count(*) from app.scope_activity(t.scope('03'), 14)) = 0, 'activity: another client''s user gets nothing');

  -- trace shows a withdrawal and what replaces what
  perform t.as_user(t.u('03'));
  perform app.withdraw_footprint(m, 'bran weight typed as 30, was 20');
  perform t.as_user(t.u('08'));
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload, supersedes_id)
  values (t.scope('03'), c, 'milling', q, t.u('08'), '{"input_kg":119,"rice_kg":90,"bran_kg":20,"loss_kg":9}', m) returning * into r;
  perform t.as_user(t.u('04'));
  j := app.lot_trace(r.id);
  perform t.ok((select e->'replaces'->>'reason' = 'bran weight typed as 30, was 20' and e->'replaces'->>'by' = 'Prasaadam Client Manager'
                       and (e->'replaces'->>'qty_out_kg')::numeric = 80
                  from jsonb_array_elements(j->'steps') e where e->>'id' = r.id::text),
               'trace: the replacement names the withdrawn record, its reason and who withdrew it');
  j := app.lot_trace(m);
  perform t.ok((select e->'withdrawn'->>'reason' = 'bran weight typed as 30, was 20' and e->>'status' = 'superseded'
                  from jsonb_array_elements(j->'steps') e where e->>'id' = m::text),
               'trace: the withdrawn record itself can still be traced, marked withdrawn');
  perform t.as_service();
end $$;

-- 6 · who may reset whose password ----------------------------------------------------------------------------------
-- Migration 32: credentials belong to HR. The admin resets anyone but himself; HR within its reach; a client's own
-- login by whoever manages that client. A manager no longer resets the people working under them: one person may
-- work for two clients, and a reset is a way in.
do $$
declare other_cm uuid;
begin
  insert into public.app_users (role, display_name, email, client_id) values ('client_manager', 'Other CM', 'other.cm@test', '00000000-0000-4000-8000-000000000202')
  returning id into other_cm;
  perform t.as_user(t.u('01'));
  perform t.ok(app.reset_login_allowed(t.u('02')) and app.reset_login_allowed(t.u('05')) and app.reset_login_allowed(t.u('16'))
               and not app.reset_login_allowed(t.u('01')),
               'reset: the admin may reset anyone but himself');
  perform t.as_user(t.u('16'));
  perform t.ok(app.reset_login_allowed(t.u('05')) and app.reset_login_allowed(t.u('03')) and app.reset_login_allowed(t.u('02'))
               and app.reset_login_allowed(t.u('17')),
               'reset: the HR Admin may reset operational people (managers included) and HR resources');
  perform t.ok(not app.reset_login_allowed(t.u('01')) and not app.reset_login_allowed(t.u('16')) and not app.reset_login_allowed(t.u('04')),
               'reset: but not the admin, not herself, and not a client''s own login');
  perform t.as_user(t.u('17'));
  perform t.ok(app.reset_login_allowed(t.u('05')) and app.reset_login_allowed(other_cm)
               and not app.reset_login_allowed(t.u('16')) and not app.reset_login_allowed(t.u('01')) and not app.reset_login_allowed(t.u('17')),
               'reset: an HR resource may reset operational people; not the HR Admin, the admin or himself');
  perform t.as_user(t.u('02'));
  perform t.ok(app.reset_login_allowed(t.u('04')), 'reset: a State Manager may reset the client login of a client homed in his state');
  perform t.ok(not app.reset_login_allowed(t.u('03')) and not app.reset_login_allowed(t.u('05')) and not app.reset_login_allowed(other_cm)
               and not app.reset_login_allowed(t.u('01')) and not app.reset_login_allowed(t.u('02')),
               'reset: but no employee any more: not the managers or operators in his state, not the admin, not himself');
  perform t.as_user(t.u('03'));
  perform t.ok(app.reset_login_allowed(t.u('04')), 'reset: a Client Manager may reset his client''s own login');
  perform t.ok(not app.reset_login_allowed(t.u('05')) and not app.reset_login_allowed(t.u('02')) and not app.reset_login_allowed(t.u('01'))
               and not app.reset_login_allowed(other_cm) and not app.reset_login_allowed(t.u('12')) and not app.reset_login_allowed(t.u('03')),
               'reset: not his operators, the State Manager, the admin, another Client Manager, another client''s operator, or himself');
  perform t.as_user(other_cm);
  perform t.ok(not app.reset_login_allowed(t.u('04')), 'reset: another client''s manager cannot reset this client''s login');
  perform t.as_user(t.u('05'));
  perform t.ok(not app.reset_login_allowed(t.u('06')) and not app.reset_login_allowed(t.u('05')), 'reset: an operator resets nobody');
  perform t.as_user(t.u('04'));
  perform t.ok(not app.reset_login_allowed(t.u('05')), 'reset: Client View resets nobody');
  perform t.as_service();
end $$;

-- 8 · ledger check on demand -----------------------------------------------------------------------------------------
do $$
declare a public.ledger_checks; b public.ledger_checks; n bigint := (select count(*) from public.ledger);
begin
  perform t.as_user(t.u('05'));
  perform t.fails($q$ select app.check_ledger_now() $q$, 'only the admin or a State Manager', 'ledger check now: an operator cannot run it');
  perform t.as_user(t.u('03'));
  perform t.fails($q$ select app.check_ledger_now() $q$, 'only the admin or a State Manager', 'ledger check now: nor a Client Manager');
  perform t.as_anon();
  perform t.fails($q$ select app.check_ledger_now() $q$, 'permission denied', 'ledger check now: nor an anonymous visitor');
  perform t.as_user(t.u('02'));
  a := app.check_ledger_now();
  perform t.ok(a.ok and a.source = 'manual' and a.blocks = n and n > 0,
               'ledger check now: a State Manager runs it; the whole chain is walked (not only the blocks he may read) and the result recorded');
  perform t.as_user(t.u('01'));
  b := app.check_ledger_now();
  perform t.ok(b.id = a.id and (select count(*) from public.ledger_checks) = 1,
               'ledger check now: a second request within a minute returns the last result instead of walking the chain again');
  perform t.as_service();
end $$;

rollback;
