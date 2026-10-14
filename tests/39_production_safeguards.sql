-- Migration 45 (Veda, 14 Oct 2026: "when in production … can such thing happen and not recorded?"): the change log,
-- the door for corrections, the fingerprint for an outside copy, the admin's safeguards report, and the correcting
-- block for the practice data of 14 Oct. 301 the admin ("Veda"), 316 the HR Admin, 303 a Client Manager, 302 the UP
-- State Manager. Each check asks the database as that person (or the owner, or the public key) would.
begin;
select t.as_service();
create temp table fx (k text primary key, id uuid, n bigint);
grant select, insert, update on fx to authenticated; grant select on fx to anon;
create or replace function pg_temp.f(p text) returns uuid language sql stable as $$ select id from fx where k = p $$;
create or replace function pg_temp.lines(p_path text, p_table text) returns int language sql stable security definer as $$
  select count(*)::int from public.change_log where path = p_path and table_name = p_table and seq > (select n from fx where k = 'START') $$;
create or replace function pg_temp.last_line() returns public.change_log language sql stable security definer as $$
  select * from public.change_log order by seq desc limit 1 $$;
create or replace function pg_temp.block(p_act text) returns public.ledger language sql stable security definer as $$
  select * from public.ledger where payload->>'act' = p_act order by seq desc limit 1 $$;
create or replace function pg_temp.corr(p uuid) returns public.corrections language sql stable security definer as $$
  select * from public.corrections where id = p $$;
insert into fx values ('START', null, coalesce((select max(seq) from public.change_log), 0));

-- 1 · the log is there, on the tables that matter, and cannot be read, changed or emptied from outside -----------------
select t.ok((select count(*) from pg_trigger where tgname = 'zz_change_log') = 21, 'the change log is written for 21 tables');
select t.ok((select count(*) from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'zz_change_log'
               and c.relname in ('farmers', 'app_users', 'scopes', 'footprints', 'assignments', 'openings', 'app_meta')) = 7,
            'among them farmers, people, scopes, lots, assignments, openings and the system settings');
select t.as_user(t.u('01'));
select t.fails('select count(*) from public.change_log', 'permission denied', 'the admin cannot read the log directly (only through the report)');
select t.as_anon();
select t.fails('select count(*) from public.change_log', 'permission denied', 'nor can the public key');
select t.as_service();

-- 2 · how each change came ------------------------------------------------------------------------------------------------
-- directly (the owner's session)
update public.clients set name = name || ' ' where code = 'PRSDM';
select t.ok(pg_temp.lines('direct', 'clients') = 1, 'a change by the database owner, behind the app, is logged as direct');
select t.ok((pg_temp.last_line()).db_role = 'postgres' and (pg_temp.last_line()).columns = '{name}'
            and (pg_temp.last_line()).before_hash is not null and (pg_temp.last_line()).after_hash is not null,
            'with the database account, the column changed and fingerprints of the row before and after');
update public.clients set name = name where code = 'PRSDM';
select t.ok(pg_temp.lines('direct', 'clients') = 1, 'an update that changes nothing is not logged');
-- through the app (a person signed in)
select t.as_user(t.u('03'));
select app.change_farmer(t.farmer('01'), jsonb_build_object('village', 'Bansi (app)'), 'test of the change log');
select t.as_service();
select t.ok(pg_temp.lines('app', 'farmers') = 1 and (pg_temp.last_line()).app_user = t.u('03') and (pg_temp.last_line()).db_role = 'authenticated',
            'a change by a person signed in is logged as through the app, with that person');
-- a server function (service key)
create or replace function pg_temp.server_fn() returns void language sql security definer as $$
  update public.clients set name = name || '.' where code = 'PRSDM' $$;
set local role service_role;
select pg_temp.server_fn();                                                 -- as create-user does: a definer function
reset role;
select t.ok(pg_temp.lines('service', 'clients') = 1, 'a change by a server function (the service key) is logged as service');
-- a change that declares itself (a migration): shown with what it said, not trusted
select set_config('app.change_path', 'migration 99 (test)', true);
update public.clients set name = name || '.' where code = 'PRSDM';
select set_config('app.change_path', '', true);
select t.ok(pg_temp.lines('declared', 'clients') = 1 and (pg_temp.last_line()).note = 'migration 99 (test)',
            'a change that declares itself a migration is logged as declared, with what it said');
-- a correction id set by hand (no correction open) does not make a change a correction
select set_config('app.correction_id', gen_random_uuid()::text, true);
update public.clients set name = name || '.' where code = 'PRSDM';
select set_config('app.correction_id', '', true);
select t.ok(pg_temp.lines('direct', 'clients') = 2, 'a correction id set by hand, with no correction open, is still direct');
-- no values: a farmer's phone changed directly leaves no phone in the log
update public.farmers set phone = '+919999912345' where id = t.farmer('01');
select t.ok(position('99999' in (select to_jsonb(c)::text from public.change_log c order by seq desc limit 1)) = 0
            and (pg_temp.last_line()).columns = '{phone}', 'the log keeps the column name and fingerprints, never the phone');
-- inserts and deletes of every kind of row
insert into public.app_meta (key, value) values ('test_key_39', 'x');
delete from public.app_meta where key = 'test_key_39';
select t.ok((select count(*) from public.change_log where table_name = 'app_meta' and row_id = 'test_key_39' and op in ('INSERT', 'DELETE')) = 2,
            'an insert and a delete (of a system setting) are logged with the row''s key');
insert into public.farmer_gap (farmer_id, crop_id, answers) values (t.farmer('02'), '00000000-0000-4000-8000-000000000101', '{}')
  on conflict do nothing;
select t.ok(exists (select 1 from public.change_log where table_name = 'farmer_gap' and row_id like '%/%'), 'a row with a two-part key is logged with both parts');

-- 3 · the chain ---------------------------------------------------------------------------------------------------------
select t.ok(not exists (select 1 from app.verify_change_log()), 'the change log chain is intact');
select t.fails('update public.change_log set path = ''app'' where seq = (select max(seq) from public.change_log)', 'append-only', 'a log line cannot be changed');
select t.fails('delete from public.change_log where seq = (select max(seq) from public.change_log)', 'append-only', 'nor deleted');
select t.fails('truncate public.change_log', 'append-only', 'nor the log emptied');
select t.fails('truncate public.ledger cascade', 'append-only', 'nor the ledger emptied (it refused update and delete already)');
-- the owner who switches the guard off and edits a line is found by the walk
savepoint tamper;
alter table public.change_log disable trigger change_log_no_update_delete;
update public.change_log set path = 'app' where seq = (select min(seq) from public.change_log where seq > (select n from fx where k = 'START'));
select t.ok((select problem from app.verify_change_log() limit 1) = 'hash mismatch', 'a line edited with the guard switched off is found (hash mismatch)');
rollback to savepoint tamper;
savepoint tamper2;
alter table public.change_log disable trigger change_log_no_update_delete;
delete from public.change_log where seq = (select min(seq) from public.change_log where seq > (select n from fx where k = 'START'));
select t.ok((select problem from app.verify_change_log() limit 1) = 'prev_hash mismatch', 'a line removed with the guard switched off is found');
rollback to savepoint tamper2;
select t.ok(not exists (select 1 from app.verify_change_log()), 'intact again after the tests');

-- 4 · the door for corrections --------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails($q$ select app.request_correction('fix a farmer''s village') $q$, 'only the admin', 'a Client Manager cannot ask for a correction');
select t.as_user(t.u('01'));
select t.fails($q$ select app.request_correction('no') $q$, 'say why', 'a correction needs a reason');
insert into fx (k, id) select 'C1', (app.request_correction('Farmer 1''s village was typed wrong at import', 'farmers 01: village')).id;
select t.ok((pg_temp.corr(pg_temp.f('C1'))).status = 'requested', 'the admin asks: requested');
select t.fails(format($q$ select app.decide_correction(%L, true) $q$, pg_temp.f('C1')), 'a second person', 'the admin cannot approve his own request');
select t.fails(format($q$ select app.open_correction(%L) $q$, pg_temp.f('C1')), 'permission denied', 'nor open it from the app (not his to call)');
select t.as_user(t.u('02'));
select t.fails(format($q$ select app.decide_correction(%L, true) $q$, pg_temp.f('C1')), 'only the admin or the HR Admin', 'the State Manager cannot decide');
select t.as_user(t.u('16'));
select t.fails(format($q$ select app.decide_correction(%L, false) $q$, pg_temp.f('C1')), 'say why', 'a refusal needs a reason');
select app.decide_correction(pg_temp.f('C1'), true);
select t.ok((pg_temp.corr(pg_temp.f('C1'))).status = 'approved' and (pg_temp.corr(pg_temp.f('C1'))).decided_by = t.u('16'),
            'the HR Admin approves it: approved, by her');
select t.fails(format($q$ select app.decide_correction(%L, true) $q$, pg_temp.f('C1')), 'approved already', 'it is decided once');
select t.ok((select count(*) from public.audit_log where target = pg_temp.f('C1') and action in ('correction_requested', 'correction_approved') and flagged) = 2,
            'asking and approving are flagged lines in the audit log');
-- through the API with the service key: refused
select t.as_service();
grant usage on schema t to service_role; grant select on fx to service_role;                                  -- the test helpers only (rolled back)
set local role service_role;
select t.fails(format($q$ select app.open_correction(%L) $q$, pg_temp.f('C1')), 'only by the database owner', 'a server function (service key) cannot open a correction');
reset role;
-- the owner opens it: a block in the asker's name; every change marked; closed with the count
select app.open_correction(pg_temp.f('C1'));
select t.ok((pg_temp.block('correction_opened')).actor = t.u('01')
            and (pg_temp.block('correction_opened')).payload->>'approved_by' = t.u('16')::text
            and (pg_temp.block('correction_opened')).payload->>'reason' like 'Farmer 1%',
            'opening writes a ledger block signed by the admin who asked, with the reason and who approved');
select t.fails(format($q$ select app.open_correction(%L) $q$, pg_temp.f('C1')), 'another correction is open', 'one correction at a time in a session');
update public.farmers set village = 'Bansi Khurd' where id = t.farmer('01');
select t.ok((pg_temp.last_line()).path = 'correction' and (pg_temp.last_line()).correction_id = pg_temp.f('C1'),
            'a change made while it is open is logged as that correction');
select app.close_correction();
select t.ok((pg_temp.corr(pg_temp.f('C1'))).status = 'done' and (pg_temp.corr(pg_temp.f('C1'))).rows_changed = 1
            and (pg_temp.block('correction_closed')).payload->>'rows_changed' = '1', 'closing writes the count of changes, in the ledger too');
update public.farmers set village = 'Bansi' where id = t.farmer('01');
select t.ok((pg_temp.last_line()).path = 'direct', 'after closing, a change is direct again');
select t.fails('select app.close_correction()', 'no correction is open', 'nothing to close twice');
-- a refused request cannot be opened
select t.as_user(t.u('01'));
insert into fx (k, id) select 'C2', (app.request_correction('A second request, to be refused')).id;
select t.as_user(t.u('16'));
select app.decide_correction(pg_temp.f('C2'), false, 'not needed');
select t.as_service();
select t.fails(format($q$ select app.open_correction(%L) $q$, pg_temp.f('C2')), 'refused', 'a refused correction cannot be opened');
-- two-person approval on: a request must be approved first; the release scripts' shortcut is refused
select t.as_user(t.u('01'));
insert into fx (k, id) select 'C3', (app.request_correction('A third request, not yet approved')).id;
select t.as_service();
insert into public.app_meta (key, value) values ('two_person_corrections', 'on') on conflict (key) do update set value = 'on';
select t.fails(format($q$ select app.open_correction(%L) $q$, pg_temp.f('C3')), 'two-person approval on', 'two-person approval on: an unapproved request cannot be opened');
select t.fails($q$ select app.owner_correction('a script''s correction') $q$, 'two-person approval is on', 'nor can a script open one in the admin''s name');
update public.app_meta set value = 'off' where key = 'two_person_corrections';
select app.open_correction(pg_temp.f('C3'));
select app.close_correction();
select t.ok((pg_temp.corr(pg_temp.f('C3'))).status = 'done', 'two-person approval off: the owner may open a request as it is (one admin, no second approver yet)');
-- the release scripts' shortcut: in the only admin's name
select t.ok((app.owner_correction('A release script''s correction, in the admin''s name')).requested_by = t.u('01'), 'a script opens a correction in the only admin''s name');
select app.close_correction();
select t.fails($q$ select app.owner_correction('another one', null, 'nobody@example.com') $q$, 'name the admin', 'an email that is not an active admin''s is refused');

-- 5 · the correcting block for the practice data of 14 Oct ---------------------------------------------------------------
select t.ok(app.practice_note_15oct() like 'no activation_reversed block%', 'with no "activation reversed" block, nothing to explain');
select app.ledger_append(null, t.scope('01'), 'supervisory', t.u('03'), jsonb_build_object('act', 'activation_reversed', 'scope_id', t.scope('01'),
  'reason', 'Activation reversed: activated in a test with no staff (practice data, 14 Oct 2026; migration 44)'));
insert into fx (k, n) values ('B29', (select max(seq) from public.ledger));
select t.ok(app.practice_note_15oct() like 'block%explained (correction%signed by the admin)', 'the correcting block is added');
select t.ok((pg_temp.block('correction_opened')).actor = t.u('01') and ((pg_temp.block('correction_opened')).payload->>'about_seq')::bigint = (select n from fx where k = 'B29')
            and (pg_temp.block('correction_opened')).payload->>'reason' like '%the Client Manager did not act%',
            'signed by the admin, naming the block it explains, saying the Client Manager did not act');
select t.ok(app.practice_note_15oct() like '%explained already', 'run again: explained already, no second block');
savepoint prod;
insert into public.app_meta (key, value) values ('environment', 'production') on conflict (key) do update set value = 'production';
select t.fails('select app.practice_note_15oct()', 'not on the production system', 'the practice note refuses production');
rollback to savepoint prod;

-- 6 · the fingerprint for an outside copy, with the public key -------------------------------------------------------------
select t.as_anon();
select t.ok((app.ledger_head()->'ledger'->>'seq')::bigint = (select n from fx where k = 'B29') + 2
            and length(app.ledger_head()->'ledger'->>'hash') = 64 and length(app.ledger_head()->'change_log'->>'hash') = 64,
            'the public key reads the newest block''s and log line''s fingerprints (and nothing else)');
select t.ok((app.anchor_check(jsonb_build_array(app.ledger_head()->'ledger' || '{"kind":"ledger"}', app.ledger_head()->'change_log' || '{"kind":"change_log"}')))->>'ok' = 'true',
            'copies that still match: ok');
select t.ok((app.anchor_check(jsonb_build_array(jsonb_build_object('kind', 'ledger', 'seq', 1, 'hash', repeat('a', 64)))))->>'problem' = 'different',
            'a copy that no longer matches: different, with its number');
select t.ok((app.anchor_check(jsonb_build_array(jsonb_build_object('kind', 'change_log', 'seq', 999999999, 'hash', repeat('a', 64)))))->>'problem' = 'missing',
            'a line that is gone: missing');
select t.fails($q$ select app.anchor_check((select jsonb_agg(jsonb_build_object('kind','ledger','seq',g,'hash','x')) from generate_series(1, 401) g)) $q$,
               'at most 400', 'at most 400 copies at a time');
select t.fails($q$ select app.safeguards_report() $q$, 'permission denied', 'the public key cannot read the safeguards report');
select t.fails($q$ select app.request_correction('from the public key') $q$, 'permission denied', 'nor ask for a correction');

-- 7 · the admin's report ------------------------------------------------------------------------------------------------
select t.as_user(t.u('03'));
select t.fails('select app.safeguards_report()', 'only the admin', 'a Client Manager cannot read the safeguards');
select t.as_user(t.u('01'));
select t.ok((app.safeguards_report()->'change_log'->>'intact')::boolean, 'the admin''s report: the change log is intact');
select t.ok((app.safeguards_report()->>'direct_count')::int >= 5 and (app.safeguards_report()->>'declared_count')::int >= 1,
            'it counts the changes made directly and those that declared themselves');
select t.ok(jsonb_array_length(app.safeguards_report()->'behind_app') between 1 and 50
            and (app.safeguards_report()->'behind_app'->0) ? 'db_role' and not ((app.safeguards_report()->'behind_app'->0) ? 'before_hash'),
            'it lists changes behind the app (at most 50): when, table, account, columns, no fingerprints or values');
select t.ok(jsonb_array_length(app.safeguards_report()->'corrections') >= 4 and (app.safeguards_report()->>'can_request')::boolean,
            'it lists the corrections; the admin may ask for one');
select t.as_user(t.u('16'));
select t.ok((app.safeguards_report()->>'can_decide')::boolean and not (app.safeguards_report()->>'can_request')::boolean,
            'the HR Admin reads it to decide corrections, and asks for none');
select t.as_service();
rollback;
