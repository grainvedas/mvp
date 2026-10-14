-- =====================================================================================================================
-- Migration 45: production safeguards (Veda, 14 October 2026, after the release of migration 44: "when in production
-- and in real time can such thing happen and not recorded? … ok go ahead").
--
-- What the database cannot stop on its own is its owner (the dashboard login, the service key). What it can do:
--   1 · a CHANGE LOG: every insert, update and delete on the tables that matter, with who (the person signed in, or the
--       database account), how (through the app, a server function, a correction, or directly), which columns, and
--       fingerprints of the row before and after (no values: no phone, no ID number is copied). Append-only and
--       hash-chained like the ledger, so a removed or edited line breaks the chain.
--   2 · ONE DOOR FOR CORRECTIONS: a correction of live data is requested by the admin in the app, approved by a second
--       person when two-person approval is on, then run by the owner inside app.open_correction / close_correction:
--       a ledger block signed by the person who asked, with the reason, and every change in between marked with it.
--       A change made behind the app outside that door shows as "direct" on the admin's Health page.
--   3 · THE LEDGER'S FINGERPRINT FOR AN OUTSIDE COPY: app.ledger_head() (the newest block and change-log line) and
--       app.anchor_check() (do earlier copies still match?), read by a daily GitHub job (scripts/anchor_ledger.mjs).
--       Rewriting the whole chain would no longer match the copies kept outside the database.
--   4 · the correcting block for the practice data of 14 Oct (block "activation reversed" named the Client Manager as
--       signer): app.practice_note_15oct(), run once by the release script on the practice system.
-- Additive only: new tables, functions, triggers; nothing deleted or rewritten. The ledger also refuses TRUNCATE now.
-- =====================================================================================================================

-- ---------------------------------------------------------------------------------------------------------------------
-- 1 · the change log
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.change_log (
  seq          bigserial primary key,
  at           timestamptz not null,
  table_name   text not null,
  row_id       text not null,
  op           text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
  db_role      text not null,                 -- the database account: authenticated, service_role, postgres, …
  app_user     uuid,                          -- the person signed in, if any
  path         text not null check (path in ('app', 'service', 'correction', 'declared', 'direct')),
  correction_id uuid,
  note         text,                          -- what a 'declared' change said it was (a migration, a seed)
  columns      text[] not null default '{}',  -- the columns an update changed
  before_hash  text,
  after_hash   text,
  prev_hash    text not null,
  hash         text not null
);
create index if not exists change_log_at_idx on public.change_log (at);
create index if not exists change_log_path_idx on public.change_log (path, at) where path in ('direct', 'declared', 'correction');
alter table public.change_log enable row level security;          -- no policy: read only through app.safeguards_report()
revoke all on public.change_log from anon, authenticated;
revoke all on sequence public.change_log_seq_seq from anon, authenticated;

create or replace function app.change_log_guard() returns trigger
language plpgsql as $$
begin
  raise exception 'the change log is append-only (% refused)', tg_op using errcode = '42501';
end $$;
create trigger change_log_no_update_delete before update or delete on public.change_log for each row execute function app.change_log_guard();
create trigger change_log_no_truncate before truncate on public.change_log for each statement execute function app.change_log_guard();
-- the ledger refused update and delete since migration 1; truncate now too
create trigger ledger_no_truncate before truncate on public.ledger for each statement execute function app.ledger_guard();

-- the corrections opened through the door (section 2); the change log marks the changes made inside one
create table if not exists public.corrections (
  id            uuid primary key default gen_random_uuid(),
  requested_by  uuid not null references public.app_users(id),
  requested_at  timestamptz not null default now(),
  reason        text not null check (length(btrim(reason)) >= 5),
  detail        text,
  status        text not null default 'requested' check (status in ('requested', 'approved', 'refused', 'open', 'done')),
  decided_by    uuid references public.app_users(id),
  decided_at    timestamptz,
  refused_why   text,
  opened_at     timestamptz,
  closed_at     timestamptz,
  rows_changed  int,
  about_seq     bigint                        -- a ledger block this correction explains, if any
);
alter table public.corrections enable row level security;
create policy corrections_read on public.corrections for select to authenticated
  using ((select app.is_admin()) or (select app.is_hr_admin()));
revoke insert, update, delete on public.corrections from anon, authenticated;

-- how a change came: a person in the app; a server function (service key, Auth); a correction opened through the door;
-- a change that declared itself (a migration, a seed: anyone with the keys can declare, so it is shown, not trusted);
-- or directly
create or replace function app.change_path() returns text
language sql stable security definer set search_path = public as $$
  select case
    when app.current_user_id() is not null then 'app'
    when nullif(current_setting('app.correction_id', true), '') is not null
         and exists (select 1 from public.corrections c where c.id::text = current_setting('app.correction_id', true) and c.status = 'open') then 'correction'
    when coalesce(nullif(current_setting('role', true), 'none'), session_user) in ('service_role', 'supabase_auth_admin') then 'service'
    when nullif(current_setting('app.change_path', true), '') is not null then 'declared'
    else 'direct' end $$;

-- written by a trigger on every logged table; the arguments name the row's key column(s)
create or replace function app.log_change() returns trigger
language plpgsql security definer set search_path = public, extensions, app set "TimeZone" to 'UTC' set "DateStyle" to 'ISO' as $$
declare o jsonb; n jsonb; rid text; cols text[] := '{}'; v_prev text; v_ts timestamptz := clock_timestamp();
        v_path text := app.change_path(); v_role text := coalesce(nullif(current_setting('role', true), 'none'), session_user);
        v_user uuid := app.current_user_id(); v_corr uuid; v_note text; v_bh text; v_ah text; v_hash text; i int;
begin
  if tg_op <> 'INSERT' then o := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then n := to_jsonb(new); end if;
  rid := '';
  for i in 0 .. tg_nargs - 1 loop
    rid := rid || case when i > 0 then '/' else '' end || coalesce(coalesce(n, o) ->> tg_argv[i], '');
  end loop;
  if tg_op = 'UPDATE' then
    select coalesce(array_agg(k order by k), '{}') into cols from jsonb_object_keys(n) k where (o -> k) is distinct from (n -> k);
    if cardinality(cols) = 0 then return null; end if;          -- nothing changed: nothing to log
  end if;
  if v_path = 'correction' then v_corr := current_setting('app.correction_id', true)::uuid; end if;
  if v_path = 'declared' then v_note := left(current_setting('app.change_path', true), 120); end if;
  v_bh := case when o is null then null else encode(digest(o::text, 'sha256'), 'hex') end;
  v_ah := case when n is null then null else encode(digest(n::text, 'sha256'), 'hex') end;
  -- one writer at a time: an unambiguous chain. The ledger's own lock, not a second one: a session that writes both (a
  -- lot saved, a farmer verified) would otherwise take the two in either order and two sessions could deadlock
  -- (tests/concurrency, 14 Oct 2026).
  perform pg_advisory_xact_lock(hashtext('grainveda_ledger'));
  select c.hash into v_prev from public.change_log c order by c.seq desc limit 1;
  v_prev := coalesce(v_prev, repeat('0', 64));
  v_hash := encode(digest(concat_ws('|', v_prev, tg_table_name, rid, tg_op, v_role, coalesce(v_user::text, ''), v_path, coalesce(v_corr::text, ''),
                                    coalesce(v_note, ''), array_to_string(cols, ','), coalesce(v_bh, ''), coalesce(v_ah, ''), v_ts::text), 'sha256'), 'hex');
  insert into public.change_log (at, table_name, row_id, op, db_role, app_user, path, correction_id, note, columns, before_hash, after_hash, prev_hash, hash)
  values (v_ts, tg_table_name, rid, tg_op, v_role, v_user, v_path, v_corr, v_note, cols, v_bh, v_ah, v_prev, v_hash);
  return null;
end $$;

-- walk the chain (like app.verify_ledger): the first line that does not follow, or nothing
create or replace function app.verify_change_log() returns table (seq bigint, problem text)
language plpgsql stable security definer set search_path = public, extensions, app set "TimeZone" to 'UTC' set "DateStyle" to 'ISO' as $$
declare r record; v_prev text := repeat('0', 64); v_calc text;
begin
  for r in select * from public.change_log order by change_log.seq loop
    if r.prev_hash <> v_prev then return query select r.seq, 'prev_hash mismatch'; return; end if;
    v_calc := encode(digest(concat_ws('|', r.prev_hash, r.table_name, r.row_id, r.op, r.db_role, coalesce(r.app_user::text, ''), r.path,
                                      coalesce(r.correction_id::text, ''), coalesce(r.note, ''), array_to_string(r.columns, ','),
                                      coalesce(r.before_hash, ''), coalesce(r.after_hash, ''), r.at::text), 'sha256'), 'hex');
    if v_calc <> r.hash then return query select r.seq, 'hash mismatch'; return; end if;
    v_prev := r.hash;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 2 · the door for corrections
-- ---------------------------------------------------------------------------------------------------------------------
-- two-person approval: on when app_meta says so (the owner turns it on once a second approver exists)
create or replace function app.two_person_corrections() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_meta where key = 'two_person_corrections'), 'off') = 'on' $$;

-- who may approve another person's request: an active admin or the HR Admin (not the one who asked)
create or replace function app.may_approve_corrections(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_users u where u.id = p_user and u.status = 'active' and not u.external
                   and u.system_role in ('admin', 'hr_admin')) $$;

-- the admin asks, in the app
create or replace function app.request_correction(p_reason text, p_detail text default null) returns public.corrections
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.corrections;
begin
  if not coalesce(app.is_admin(), false) then
    raise exception 'only the admin asks for a correction of live data' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'say why the data must be corrected' using errcode = '23514'; end if;
  insert into public.corrections (requested_by, reason, detail) values (me, btrim(p_reason), nullif(btrim(coalesce(p_detail, '')), ''))
  returning * into r;
  perform app.audit('correction_requested', r.id, jsonb_build_object('reason', r.reason), true);
  return r;
end $$;

-- a second person approves or refuses it, in the app
create or replace function app.decide_correction(p_id uuid, p_approve boolean, p_why text default null) returns public.corrections
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.corrections;
begin
  select * into r from public.corrections where id = p_id for update;
  if r.id is null then raise exception 'correction not found' using errcode = 'P0002'; end if;
  if not app.may_approve_corrections(me) then
    raise exception 'only the admin or the HR Admin decides a correction' using errcode = '42501'; end if;
  if r.requested_by = me then
    raise exception 'a second person decides: you asked for this correction' using errcode = '42501'; end if;
  if r.status <> 'requested' then raise exception 'this correction is % already', r.status using errcode = '23514'; end if;
  if not p_approve and length(btrim(coalesce(p_why, ''))) < 3 then
    raise exception 'say why it is refused' using errcode = '23514'; end if;
  update public.corrections set status = case when p_approve then 'approved' else 'refused' end, decided_by = me, decided_at = now(),
         refused_why = case when p_approve then null else btrim(p_why) end
   where id = p_id returning * into r;
  perform app.audit(case when p_approve then 'correction_approved' else 'correction_refused' end, r.id,
                    jsonb_build_object('reason', r.reason, 'why', r.refused_why), true);
  return r;
end $$;

-- the owner runs it: only from the database owner's own session (never through the API), for a request that is
-- approved (or, while two-person approval is off, requested). A ledger block signed by the person who asked; every
-- change until close_correction() is marked with this correction in the change log.
create or replace function app.open_correction(p_id uuid) returns public.corrections
language plpgsql security definer set search_path = public as $$
declare r public.corrections;
begin
  if auth.uid() is not null or coalesce(nullif(current_setting('role', true), 'none'), session_user) in ('authenticated', 'anon', 'service_role') then
    raise exception 'a correction is opened only by the database owner' using errcode = '42501'; end if;
  if nullif(current_setting('app.correction_id', true), '') is not null then
    raise exception 'another correction is open in this session: close it first' using errcode = '23514'; end if;
  select * into r from public.corrections where id = p_id for update;
  if r.id is null then raise exception 'correction not found' using errcode = 'P0002'; end if;
  if not (r.status = 'approved' or (r.status = 'requested' and not app.two_person_corrections())) then
    raise exception 'this correction is % (two-person approval %): it cannot be opened', r.status,
      case when app.two_person_corrections() then 'on' else 'off' end using errcode = '23514'; end if;
  update public.corrections set status = 'open', opened_at = now() where id = p_id returning * into r;
  perform app.ledger_append(null, null, 'supervisory', r.requested_by, jsonb_build_object('act', 'correction_opened', 'correction_id', r.id,
    'reason', r.reason, 'detail', r.detail, 'approved_by', r.decided_by, 'about_seq', r.about_seq));
  perform set_config('app.correction_id', r.id::text, false);      -- the rest of this session, until close_correction()
  return r;
end $$;

create or replace function app.close_correction() returns public.corrections
language plpgsql security definer set search_path = public as $$
declare r public.corrections; v uuid := nullif(current_setting('app.correction_id', true), '')::uuid; n int;
begin
  if v is null then raise exception 'no correction is open in this session' using errcode = '23514'; end if;
  select count(*) into n from public.change_log where correction_id = v;
  update public.corrections set status = 'done', closed_at = now(), rows_changed = n where id = v and status = 'open' returning * into r;
  perform set_config('app.correction_id', '', false);
  if r.id is null then raise exception 'the correction is not open' using errcode = '23514'; end if;
  perform app.ledger_append(null, null, 'supervisory', r.requested_by, jsonb_build_object('act', 'correction_closed', 'correction_id', r.id, 'rows_changed', n));
  return r;
end $$;

-- a release script's correction while there is one admin and two-person approval is off: the request is made in the
-- admin's name (named by email, or the only active admin) and opened at once. Refused when two-person approval is on.
create or replace function app.owner_correction(p_reason text, p_detail text default null, p_admin_email text default null,
                                                p_about_seq bigint default null) returns public.corrections
language plpgsql security definer set search_path = public as $$
declare a uuid; r public.corrections;
begin
  if auth.uid() is not null or coalesce(nullif(current_setting('role', true), 'none'), session_user) in ('authenticated', 'anon', 'service_role') then
    raise exception 'a correction is opened only by the database owner' using errcode = '42501'; end if;
  if app.two_person_corrections() then
    raise exception 'two-person approval is on: the admin asks in the app, a second person approves, then open_correction()' using errcode = '23514'; end if;
  if p_admin_email is not null then
    select id into a from public.app_users where lower(email) = lower(p_admin_email) and system_role = 'admin' and status = 'active';
  elsif (select count(*) from public.app_users where system_role = 'admin' and status = 'active') = 1 then
    select id into a from public.app_users where system_role = 'admin' and status = 'active';
  end if;
  if a is null then raise exception 'name the admin in whose name this correction is made' using errcode = '23514'; end if;
  insert into public.corrections (requested_by, reason, detail, about_seq) values (a, btrim(p_reason), p_detail, p_about_seq) returning * into r;
  insert into public.audit_log (actor, action, target, detail, flagged)
  values (a, 'correction_requested', r.id, jsonb_build_object('reason', r.reason, 'by', 'release script, in the admin''s name'), true);
  return app.open_correction(r.id);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3 · the fingerprint for an outside copy (read by the daily GitHub job with the public key: hashes reveal nothing)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.ledger_head() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'environment', app.environment(),
    'ledger', (select jsonb_build_object('seq', l.seq, 'hash', l.hash) from public.ledger l order by l.seq desc limit 1),
    'change_log', (select jsonb_build_object('seq', c.seq, 'hash', c.hash) from public.change_log c order by c.seq desc limit 1),
    'at', now()) $$;

-- earlier copies: [{"kind":"ledger"|"change_log","seq":n,"hash":"…"}, …] (at most 400); the first that no longer matches
create or replace function app.anchor_check(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; h text; n int := 0;
begin
  if jsonb_typeof(p) <> 'array' or jsonb_array_length(p) > 400 then
    raise exception 'a list of at most 400 copies' using errcode = '22023'; end if;
  for x in select * from jsonb_array_elements(p) loop
    if x->>'kind' = 'ledger' then select l.hash into h from public.ledger l where l.seq = (x->>'seq')::bigint;
    elsif x->>'kind' = 'change_log' then select c.hash into h from public.change_log c where c.seq = (x->>'seq')::bigint;
    else raise exception 'kind: ledger or change_log' using errcode = '22023'; end if;
    if h is distinct from x->>'hash' then
      return jsonb_build_object('ok', false, 'checked', n, 'kind', x->>'kind', 'seq', (x->>'seq')::bigint,
                                'problem', case when h is null then 'missing' else 'different' end);
    end if;
    n := n + 1; h := null;
  end loop;
  return jsonb_build_object('ok', true, 'checked', n);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4 · what the admin sees (Health → Safeguards)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.safeguards_report(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare bad record; since timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365)));
begin
  if not (coalesce(app.is_admin(), false) or coalesce(app.is_hr_admin(), false)) then
    raise exception 'only the admin (or the HR Admin, to decide corrections) reads the safeguards' using errcode = '42501'; end if;
  select * into bad from app.verify_change_log() limit 1;
  return jsonb_build_object(
    'change_log', jsonb_build_object('lines', (select count(*) from public.change_log), 'intact', bad.seq is null,
                                     'first_bad', bad.seq, 'problem', bad.problem),
    'days', extract(day from now() - since)::int,
    'by_path', (select coalesce(jsonb_object_agg(path, n), '{}') from (select path, count(*) n from public.change_log where at >= since group by path) x),
    'behind_app', (select coalesce(jsonb_agg(jsonb_build_object('seq', c.seq, 'at', c.at, 'table', c.table_name, 'op', c.op, 'db_role', c.db_role,
                                    'path', c.path, 'note', c.note, 'columns', c.columns, 'correction_id', c.correction_id) order by c.seq desc), '[]')
                   from (select * from public.change_log where at >= since and path in ('direct', 'declared', 'correction') order by seq desc limit 50) c),
    'direct_count', (select count(*) from public.change_log where at >= since and path = 'direct'),
    'declared_count', (select count(*) from public.change_log where at >= since and path = 'declared'),
    'two_person', app.two_person_corrections(),
    'corrections', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'reason', c.reason, 'detail', c.detail, 'status', c.status,
                       'requested_by', (select display_name from public.app_users where id = c.requested_by), 'requested_at', c.requested_at,
                       'mine', c.requested_by = app.current_user_id(),
                       'decided_by', (select display_name from public.app_users where id = c.decided_by), 'decided_at', c.decided_at,
                       'refused_why', c.refused_why, 'rows_changed', c.rows_changed, 'closed_at', c.closed_at) order by c.requested_at desc), '[]')
                    from (select * from public.corrections order by requested_at desc limit 30) c),
    'can_request', coalesce(app.is_admin(), false),
    'can_decide', app.may_approve_corrections(app.current_user_id()),
    'head', app.ledger_head());
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 5 · the practice data of 14 Oct: block "activation reversed" named the Client Manager; a correcting block in the
--     admin's name says what it was. Practice system only; once.
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.practice_note_15oct() returns text
language plpgsql security definer set search_path = public as $$
declare b public.ledger; r public.corrections;
begin
  if app.environment() = 'production' then raise exception 'not on the production system' using errcode = '42501'; end if;
  select * into b from public.ledger where payload->>'act' = 'activation_reversed' order by seq limit 1;
  if b.seq is null then return 'no activation_reversed block: nothing to explain'; end if;
  if exists (select 1 from public.corrections where about_seq = b.seq) then return format('block %s: explained already', b.seq); end if;
  r := app.owner_correction(
    format('Block %s ("activation reversed", signed in the Client Manager''s name) was the practice-data correction of 14 Oct 2026 '
           || '(migration 44), decided by Veda and run by the release script; the Client Manager did not act.', b.seq),
    'practice data; correcting block added by migration 45 (Veda, 14 Oct 2026)', null, b.seq);
  r := app.close_correction();
  return format('block %s: explained (correction %s, signed by the admin)', b.seq, r.id);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 6 · the tables whose changes are logged (from now on)
-- ---------------------------------------------------------------------------------------------------------------------
do $$
declare t record;
begin
  for t in select * from (values
      ('farmers', 'id'), ('farmer_gap', 'farmer_id,crop_id'), ('farmer_change_flags', 'id'), ('state_farmers', 'id'),
      ('app_users', 'id'), ('employee_org', 'employee_id'), ('employee_personal', 'employee_id'), ('hr_states', 'id'),
      ('seat_deputies', 'seat'), ('assignments', 'id'), ('slot_assignments', 'id'), ('openings', 'id'),
      ('scopes', 'id'), ('clients', 'id'), ('crops', 'id'), ('states', 'id'),
      ('footprints', 'id'), ('qc_verdicts', 'footprint_id'), ('withdrawals', 'footprint_id'), ('qr_seals', 'footprint_id'),
      ('app_meta', 'key')) as x(tab, keys) loop
    execute format('create trigger zz_change_log after insert or update or delete on public.%I for each row execute function app.log_change(%s)',
                   t.tab, (select string_agg(quote_literal(k), ', ') from unnest(string_to_array(t.keys, ',')) k));
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 7 · who may call what
-- ---------------------------------------------------------------------------------------------------------------------
revoke all on function app.change_log_guard(), app.change_path(), app.log_change(), app.verify_change_log(), app.open_correction(uuid), app.close_correction(),
  app.owner_correction(text, text, text, bigint), app.practice_note_15oct(), app.two_person_corrections(), app.may_approve_corrections(uuid)
  from public, anon, authenticated;
revoke all on function app.request_correction(text, text), app.decide_correction(uuid, boolean, text), app.safeguards_report(int),
  app.ledger_head(), app.anchor_check(jsonb) from public;
grant execute on function app.request_correction(text, text), app.decide_correction(uuid, boolean, text), app.safeguards_report(int) to authenticated;
grant execute on function app.ledger_head(), app.anchor_check(jsonb) to anon, authenticated;
