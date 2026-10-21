-- Migration 63 (Phase 1, release 5 of Veda's combined brief of 19 Oct 2026: Part D, close a scope and the season report,
-- with the closing check of E2.1 and E2.5; "ok continue"). The plan's defaults (19 Oct, "ok start"): the leftover above
-- the 2 % rule is written off at the close, each with a reason, approved by the State Manager's confirmation, each a ledger
-- block; a recall stays possible after the close; pages stay live (the lifetime rule is Phase 2); the client's own login
-- downloads every report, both copies, and closes nothing; the PDF is made in the browser (English and Hindi shaped).
--   D1  The Client Manager requests the close (app.request_close) with an answer for every blocker that takes one; the
--       State Manager of the scope's state confirms it (app.confirm_close), two people, each a ledger block. The checklist
--       (app.close_checklist): no record pending verification; no lot waiting for lab results; open flags resolved or
--       carried over with a reason; every remaining kilogram sold, shipped, sealed or written off with a reason; every
--       export shipment delivered or "awaiting POD" with a reason; each batch's packs never released written off with a
--       reason (E2.1); every stage's mass balance closed or its difference explained (E2.5). The close writes the
--       write-offs (lot closures of kind written_off), closes the scope and issues the final report. After it the scope's
--       records are read only (a01_closed_scope); a recall, a scan, a buyer link, a bill of lading and the proof of
--       delivery of a shipment carried over stay possible. The State Manager reopens with a reason (app.reopen_scope);
--       closing again issues a new version and the old one is "Superseded".
--   D2  "Report so far" (app.generate_interim_report), any time before the close, marked "Interim".
--   D3  The report's data (app.season_report_data) for both copies, kept as issued with its SHA-256 (reports); the app
--       writes the PDF (A4, English and Hindi) and the Excel file (one sheet per section) of each copy and stores them
--       (bucket reports, app.register_report_file: their SHA-256 in the ledger). "Verify this document": /d/<ref>
--       (app.public_document): the status, the date, who it was issued to, the files' SHA-256.
--   D4  The scope dashboard's "Season report" card (app.scope_close_state, app.scope_reports); the billing count of
--       reports issued per client per month (app.reports_issued, the admin).
-- Additive: new tables (scope_closures, reports), new columns of lot_closures (kind, closure_id), a sequence, new
-- functions; replaced: the scopes' guard (a signed-in person closes and reopens only through the functions), the mass
-- balance and the exports (a write-off is its own kind of closure), the lot's trace. No record changed.
select set_config('app.change_path', 'migration 63', true);

-- =====================================================================================================================
-- 1 · the tables: a close request and its answers; write-offs are lot closures of their own kind; issued reports
-- =====================================================================================================================
create table public.scope_closures (
  id             uuid primary key default gen_random_uuid(),
  scope_id       uuid not null references public.scopes(id),
  client_id      uuid not null references public.clients(id),
  status         text not null default 'requested' check (status in ('requested', 'confirmed', 'withdrawn', 'declined')),
  requested_by   uuid not null references public.app_users(id),
  requested_at   timestamptz not null default now(),
  note           text check (note is null or length(note) <= 500),
  items          jsonb not null default '{}'::jsonb,       -- the Client Manager's answers: write-offs, carried-over flags, awaiting POD, packs, balance
  checklist      jsonb not null default '{}'::jsonb,       -- the checklist as it stood at the request
  decided_by     uuid references public.app_users(id),
  decided_at     timestamptz,
  decided_reason text check (decided_reason is null or length(decided_reason) <= 500),
  version        integer,                                  -- the close's number for this scope, given at the confirmation
  report_id      uuid,
  reopened_by    uuid references public.app_users(id),
  reopened_at    timestamptz,
  reopen_reason  text check (reopen_reason is null or length(reopen_reason) <= 500));
create unique index scope_closures_one_open on public.scope_closures (scope_id) where status = 'requested';
create index scope_closures_scope on public.scope_closures (scope_id, requested_at);
comment on table public.scope_closures is 'Migration 63 (Part D1): a scope''s close, requested by its Client Manager and confirmed by the State Manager of its state; written only by app.request_close, app.decide_close_request, app.confirm_close and app.reopen_scope.';

alter table public.lot_closures add column kind text not null default 'floor_loss' check (kind in ('floor_loss', 'written_off'));
alter table public.lot_closures add column closure_id uuid references public.scope_closures(id);
comment on column public.lot_closures.kind is 'Migration 63: floor_loss = the 2 %-or-less rule (app.close_lot); written_off = kilograms written off with a reason at a scope''s close (app.confirm_close).';

create sequence public.report_ref_seq start 1;
create table public.reports (
  id             uuid primary key default gen_random_uuid(),
  ref            text not null unique check (ref ~ '^GV-SR-[0-9]{6,}$'),
  kind           text not null default 'season_report' check (kind = 'season_report'),
  scope_id       uuid not null references public.scopes(id),
  client_id      uuid not null references public.clients(id),
  final          boolean not null,
  version        integer not null check (version >= 1),
  status         text not null default 'valid' check (status in ('valid', 'superseded', 'withdrawn')),
  issued_at      timestamptz not null default now(),
  issued_by      uuid not null references public.app_users(id),
  issued_to      text not null,
  period_from    date,
  period_to      date,
  closure_id     uuid references public.scope_closures(id),
  data_hash      text not null check (data_hash ~ '^[0-9a-f]{64}$'),
  data_shareable jsonb not null,
  data_internal  jsonb not null,
  files          jsonb not null default '{}'::jsonb,       -- {"pdf_shareable": {"path", "sha256", "bytes", "at", "by"}, ...}
  superseded_by  uuid references public.reports(id),
  superseded_at  timestamptz,
  withdrawn_by   uuid references public.app_users(id),
  withdrawn_at   timestamptz,
  withdrawn_reason text);
create index reports_scope on public.reports (scope_id, issued_at);
create index reports_client_month on public.reports (client_id, issued_at);
comment on table public.reports is 'Migration 63 (Part D2–D4): issued season reports, final or interim; the data of both copies kept as issued, read only through app.report_content; written only by the report functions.';
alter table public.scope_closures add constraint scope_closures_report_fk foreign key (report_id) references public.reports(id);

alter table public.scope_closures enable row level security;
alter table public.reports enable row level security;
revoke all on public.scope_closures, public.reports from anon, authenticated;
revoke all on sequence public.report_ref_seq from anon, authenticated;
-- read through the functions only (a report's data holds the internal copy); nothing is written by the API
create policy scope_closures_read on public.scope_closures for select to authenticated using (app.sees_whole_scope(scope_id));
grant select on public.scope_closures to authenticated;

create trigger a00_client_login_reads_only before insert or update or delete on public.scope_closures
  for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.reports
  for each row execute function app.client_login_reads_only();
create trigger zz_change_log after insert or update or delete on public.scope_closures for each row execute function app.log_change('id');
create trigger zz_change_log after insert or update or delete on public.reports for each row execute function app.log_change('id');

-- =====================================================================================================================
-- 2 · who: the scope's State Manager (the Client Manager is app.manages_scope)
-- =====================================================================================================================
create or replace function app.sm_of_scope(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and not app.is_admin() and not app.is_client_login()
     and app.holds_op_role('state_supervisor')
     and exists (select 1 from public.scopes s where s.id = p_scope and s.state_id = any (app.my_state_ids())) $$;

-- the internal copy of a report: the internal copy's readers (migration 60) and the State Manager who confirms the close
create or replace function app.may_report_internal(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.may_internal_copy(p_scope) or app.sm_of_scope(p_scope) $$;

-- =====================================================================================================================
-- 3 · the closing check (D1.2 and E2.1, E2.5): what blocks the close, and which blocker an answer clears
-- =====================================================================================================================
create or replace function app.close_reason_ok(p_text text) returns boolean
language sql immutable as $$ select length(btrim(coalesce(p_text, ''))) between 10 and 250 $$;

-- the reason given for one blocker, if it is a reason (10 to 250 characters)
create or replace function app.close_answer(p_items jsonb, p_kind text, p_key text) returns text
language sql immutable as $$
  select btrim(a->>'reason') from jsonb_array_elements(case when jsonb_typeof(p_items->p_kind) = 'array' then p_items->p_kind else '[]'::jsonb end) a
   where coalesce(a->>'id', a->>'batch_code', a->>'stage') = p_key and app.close_reason_ok(a->>'reason') limit 1 $$;

create or replace function app.close_checklist_of(p_scope uuid, p_items jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc public.scopes; it jsonb := coalesce(p_items, '{}'::jsonb); g jsonb := '[]'::jsonb; v_last text;
        v_pending jsonb; v_lab jsonb; v_flags jsonb; v_kg jsonb; v_pod jsonb; v_packs jsonb; v_bal jsonb;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null then return null; end if;
  v_last := sc.chain[cardinality(sc.chain)]::text;
  -- answers by id: {"flags": [{"id", "reason"}], "kg": [...], "pod": [...], "packs": [{"batch_code", "reason"}], "balance": [{"stage", "reason"}]}

  -- 1 records pending verification (cleared only by verifying or returning them)
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'stage', f.stage_type,
           'since', coalesce(f.captured_at, f.created_at)) order by f.created_at), '[]'::jsonb)
    into v_pending from public.footprints f where f.scope_id = p_scope and f.status = 'pending';
  -- 2 lots waiting for lab results (a sample sent, no lab record yet)
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'code', q.code, 'drawn_on', q.drawn_on,
           'lot', (select f.footprint_code from public.footprints f where f.id = q.footprint_id)) order by q.drawn_on, q.code), '[]'::jsonb)
    into v_lab from public.qc_samples q where q.scope_id = p_scope and q.status = 'sent' and q.qc_footprint_id is null;
  -- 3 open flags and conditions: resolved, or carried over with a reason
  select coalesce(jsonb_agg(jsonb_build_object('id', fl.id, 'code', f.footprint_code, 'stage', f.stage_type, 'kind', fl.kind, 'text', fl.text,
           'reason', app.close_answer(it, 'flags', fl.id::text)) order by fl.created_at), '[]'::jsonb)
    into v_flags
    from public.flags fl join public.footprints f on f.id = fl.footprint_id
   where f.scope_id = p_scope and fl.status = 'open';
  -- 4 every remaining kilogram: sold, shipped, sealed, or written off with a reason (a lot's whole remainder)
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status = 'verified' and not f.split_into_grades
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  batched as (select distinct (x)::uuid as id from public.footprints b, jsonb_array_elements_text(coalesce(b.payload->'source_footprint_ids', '[]'::jsonb)) x
               where b.scope_id = p_scope and b.stage_type = 'village_batch' and b.status not in ('superseded', 'legacy')),
  lft as (
    select l.*, app.available_qty(l.id) as left_kg from live l
     where l.stage_type::text <> v_last and l.stage_type <> 'qr_activation'
       and not exists (select 1 from public.qr_seals q where q.footprint_id = l.id)
       and not exists (select 1 from public.lot_closures c where c.footprint_id = l.id)
       and l.id not in (select id from batched))
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'code', l.footprint_code, 'stage', l.stage_type,
           'kg', trim_scale(round(l.left_kg, 3)), 'reason', app.close_answer(it, 'kg', l.id::text)) order by l.created_at), '[]'::jsonb)
    into v_kg
    from lft l
   where l.left_kg > app.kg_tolerance();
  -- 5 every export shipment: its delivery confirmed, or "awaiting POD" with a reason
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'kg', f.qty_in, 'reason', app.close_answer(it, 'pod', f.id::text))
           order by f.created_at), '[]'::jsonb)
    into v_pod
    from public.footprints f join public.footprints c on c.id = f.prev_footprint_id
   where f.scope_id = p_scope and f.stage_type = 'shipment' and f.status = 'verified' and c.payload->>'market' = 'export'
     and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)
     and not exists (select 1 from public.deliveries d where d.shipment_id = f.id);
  -- 6 E2.1: each batch's packs released / packed but not released / void; packs never released are shipped, written off or voided
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', ps.batch_code, 'released', ps.released, 'old_data', ps.old_data,
           'held', ps.held, 'void', ps.void, 'reason', app.close_answer(it, 'packs', ps.batch_code)) order by ps.batch_code), '[]'::jsonb)
    into v_packs
    from app.scope_pack_states(p_scope) ps
   where ps.held > 0;
  -- 7 E2.5: every stage's mass balance; a difference is explained
  select coalesce(jsonb_agg(jsonb_build_object('stage', b->>'stage', 'difference_kg', b->'difference_kg', 'reason', app.close_answer(it, 'balance', b->>'stage'))
           order by (b->>'pos')::int), '[]'::jsonb)
    into v_bal
    from jsonb_array_elements(app.stage_balance_of(p_scope)) b
   where not (b->>'balanced')::boolean;

  g := jsonb_build_array(
    jsonb_build_object('key', 'pending', 'answerable', false, 'items', v_pending, 'ok', jsonb_array_length(v_pending) = 0),
    jsonb_build_object('key', 'lab_hold', 'answerable', false, 'items', v_lab, 'ok', jsonb_array_length(v_lab) = 0),
    jsonb_build_object('key', 'flags', 'answerable', true, 'items', v_flags,
      'ok', not exists (select 1 from jsonb_array_elements(v_flags) e where e->>'reason' is null)),
    jsonb_build_object('key', 'kg', 'answerable', true, 'items', v_kg,
      'ok', not exists (select 1 from jsonb_array_elements(v_kg) e where e->>'reason' is null)),
    jsonb_build_object('key', 'pod', 'answerable', true, 'items', v_pod,
      'ok', not exists (select 1 from jsonb_array_elements(v_pod) e where e->>'reason' is null)),
    jsonb_build_object('key', 'packs', 'answerable', true, 'items', v_packs,
      'ok', not exists (select 1 from jsonb_array_elements(v_packs) e where e->>'reason' is null)),
    jsonb_build_object('key', 'balance', 'answerable', true, 'items', v_bal,
      'ok', not exists (select 1 from jsonb_array_elements(v_bal) e where e->>'reason' is null)));
  return jsonb_build_object('scope_id', p_scope, 'status', sc.status, 'groups', g,
    'clear', not exists (select 1 from jsonb_array_elements(g) e where not (e->>'ok')::boolean),
    'checked_at', now());
end $$;

-- the checklist on the screen: whoever reads the whole scope (the Client Manager, the State Manager, the client's own login)
create or replace function app.close_checklist(p_scope uuid, p_items jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.sees_whole_scope(p_scope) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  return app.close_checklist_of(p_scope, p_items);
end $$;

-- the answers kept with a request: only those that clear a blocker of the checklist, trimmed
create or replace function app.close_answers(p_check jsonb) returns jsonb
language sql immutable as $$
  select jsonb_object_agg(g->>'key', (select coalesce(jsonb_agg(
           case when g->>'key' = 'packs' then jsonb_build_object('batch_code', e->>'batch_code', 'reason', e->>'reason', 'held', e->'held')
                when g->>'key' = 'balance' then jsonb_build_object('stage', e->>'stage', 'reason', e->>'reason', 'difference_kg', e->'difference_kg')
                else jsonb_build_object('id', e->>'id', 'code', e->>'code', 'reason', e->>'reason', 'kg', e->'kg') end), '[]'::jsonb)
                                       from jsonb_array_elements(g->'items') e where e->>'reason' is not null))
    from jsonb_array_elements(p_check->'groups') g where (g->>'answerable')::boolean $$;

-- =====================================================================================================================
-- 4 · request (the Client Manager), withdraw or decline, confirm (the State Manager), reopen (the State Manager)
-- =====================================================================================================================
create or replace function app.request_close(p_scope uuid, p_items jsonb, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); sc public.scopes; ck jsonb; r public.scope_closures; v_blk text;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or me is null or not app.sees_whole_scope(p_scope) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if app.is_client_login() or not app.manages_scope(me, p_scope) then
    raise exception 'the Client Manager of the scope requests its close' using errcode = '42501'; end if;
  if sc.status <> 'active' then raise exception 'only an active scope is closed (this one is %)', sc.status using errcode = '23514'; end if;
  if exists (select 1 from public.scope_closures c where c.scope_id = p_scope and c.status = 'requested') then
    raise exception 'a close of this scope is already requested: the State Manager confirms or declines it' using errcode = '23505'; end if;
  ck := app.close_checklist_of(p_scope, p_items);
  if not (ck->>'clear')::boolean then
    select string_agg(g->>'key', ', ') into v_blk from jsonb_array_elements(ck->'groups') g where not (g->>'ok')::boolean;
    raise exception 'close: the checklist is not clear (%)', v_blk using errcode = '23514'; end if;
  insert into public.scope_closures (scope_id, client_id, requested_by, note, items, checklist)
  values (p_scope, sc.client_id, me, nullif(left(btrim(coalesce(p_note, '')), 500), ''), coalesce(app.close_answers(ck), '{}'::jsonb), ck)
  returning * into r;
  perform app.ledger_append(null, p_scope, 'scope_close_request', me, jsonb_build_object('act', 'requested', 'closure_id', r.id,
    'scope_id', p_scope, 'answers', r.items, 'note', r.note));
  perform app.audit('scope_close_requested', p_scope, jsonb_build_object('closure_id', r.id), false);
  return to_jsonb(r) - 'checklist';
end $$;

create or replace function app.decide_close_request(p_closure uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.scope_closures; v_act text;
begin
  select * into r from public.scope_closures where id = p_closure;
  if r.id is null or me is null or not app.sees_whole_scope(r.scope_id) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if r.status <> 'requested' then raise exception 'this close request is %', r.status using errcode = '23514'; end if;
  if app.sm_of_scope(r.scope_id) then v_act := 'declined';
  elsif app.manages_scope(me, r.scope_id) and not app.is_client_login() then v_act := 'withdrawn';
  else raise exception 'the Client Manager withdraws a close request, the State Manager declines it' using errcode = '42501'; end if;
  if not app.close_reason_ok(p_reason) then raise exception 'close: say why (10 to 250 characters)' using errcode = '23514'; end if;
  update public.scope_closures set status = v_act, decided_by = me, decided_at = now(), decided_reason = btrim(p_reason)
   where id = r.id returning * into r;
  perform app.ledger_append(null, r.scope_id, 'scope_close_request', me, jsonb_build_object('act', v_act, 'closure_id', r.id,
    'scope_id', r.scope_id, 'reason', r.decided_reason));
  perform app.audit('scope_close_' || v_act, r.scope_id, jsonb_build_object('closure_id', r.id, 'reason', r.decided_reason), false);
  return to_jsonb(r) - 'checklist';
end $$;

create or replace function app.confirm_close(p_closure uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.scope_closures; sc public.scopes; ck jsonb; w jsonb; f public.footprints;
        v_left numeric; v_blk text; v_version int; v_rep jsonb; v_off numeric := 0; v_lc public.lot_closures;
begin
  select * into r from public.scope_closures where id = p_closure for update;
  if r.id is null or me is null or not app.sees_whole_scope(r.scope_id) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.sm_of_scope(r.scope_id) then raise exception 'the State Manager of the scope''s state confirms its close' using errcode = '42501'; end if;
  if me = r.requested_by then raise exception 'close: the request and its confirmation are two people''s' using errcode = '42501'; end if;
  if r.status <> 'requested' then raise exception 'this close request is %', r.status using errcode = '23514'; end if;
  select * into sc from public.scopes where id = r.scope_id for update;
  if sc.status <> 'active' then raise exception 'only an active scope is closed (this one is %)', sc.status using errcode = '23514'; end if;
  -- the checklist again, with the request's answers: anything new since the request blocks
  ck := app.close_checklist_of(r.scope_id, r.items);
  if not (ck->>'clear')::boolean then
    select string_agg(g->>'key', ', ') into v_blk from jsonb_array_elements(ck->'groups') g where not (g->>'ok')::boolean;
    raise exception 'close: something changed since the request (%): decline it and request again', v_blk using errcode = '23514'; end if;
  -- the kilograms written off: the whole remainder of each lot, as it stood at the request
  for w in select x from jsonb_array_elements(coalesce(r.items->'kg', '[]'::jsonb)) x loop
    select * into f from public.footprints where id = (w->>'id')::uuid and scope_id = r.scope_id;
    v_left := app.available_qty(f.id);
    if f.id is null or abs(v_left - (w->>'kg')::numeric) > greatest(app.kg_tolerance(), 0.001) then
      raise exception 'close: % has % kg left, the request wrote off % kg: decline it and request again',
        f.footprint_code, trim_scale(round(v_left, 3)), w->>'kg' using errcode = '23514'; end if;
    insert into public.lot_closures (footprint_id, scope_id, floor_loss_kg, reason, closed_by, kind, closure_id)
    values (f.id, f.scope_id, v_left, 'Written off at close: ' || (w->>'reason'), me, 'written_off', r.id) returning * into v_lc;
    perform app.sync_lot_closed(f.id);
    perform app.ledger_append(f.id, f.scope_id, 'write_off', me, jsonb_build_object('act', 'written_off', 'closure_id', r.id,
      'footprint_id', f.id, 'footprint_code', f.footprint_code, 'kg', v_left, 'reason', w->>'reason', 'requested_by', r.requested_by));
    v_off := v_off + v_left;
  end loop;
  select coalesce(max(version), 0) + 1 into v_version from public.scope_closures where scope_id = r.scope_id and status = 'confirmed';
  update public.scope_closures set status = 'confirmed', decided_by = me, decided_at = now(), version = v_version
   where id = r.id returning * into r;
  perform set_config('app.scope_close', 'on', true);
  update public.scopes set status = 'closed' where id = r.scope_id;
  perform set_config('app.scope_close', 'off', true);
  perform app.ledger_append(null, r.scope_id, 'scope_close', me, jsonb_build_object('act', 'closed', 'closure_id', r.id, 'scope_id', r.scope_id,
    'version', v_version, 'requested_by', r.requested_by, 'confirmed_by', me, 'written_off_kg', v_off, 'answers', r.items));
  perform app.audit('scope_closed', r.scope_id, jsonb_build_object('closure_id', r.id, 'version', v_version, 'written_off_kg', v_off), false);
  v_rep := app.issue_report(r.scope_id, true, r.id);
  update public.scope_closures set report_id = (v_rep->>'id')::uuid where id = r.id;
  return jsonb_build_object('closure_id', r.id, 'version', v_version, 'written_off_kg', v_off, 'report', v_rep);
end $$;

create or replace function app.reopen_scope(p_scope uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); sc public.scopes; r public.scope_closures;
begin
  select * into sc from public.scopes where id = p_scope for update;
  if sc.id is null or me is null or not app.sees_whole_scope(p_scope) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.sm_of_scope(p_scope) then raise exception 'only the State Manager of the scope''s state reopens it' using errcode = '42501'; end if;
  if sc.status <> 'closed' then raise exception 'only a closed scope is reopened' using errcode = '23514'; end if;
  if not app.close_reason_ok(p_reason) then raise exception 'close: say why (10 to 250 characters)' using errcode = '23514'; end if;
  select * into r from public.scope_closures where scope_id = p_scope and status = 'confirmed' and reopened_at is null
   order by version desc limit 1;
  perform set_config('app.scope_reopen', 'on', true);
  update public.scopes set status = 'active' where id = p_scope;
  perform set_config('app.scope_reopen', 'off', true);
  if r.id is not null then
    update public.scope_closures set reopened_by = me, reopened_at = now(), reopen_reason = btrim(p_reason) where id = r.id;
  end if;
  perform app.ledger_append(null, p_scope, 'scope_reopen', me, jsonb_build_object('act', 'reopened', 'scope_id', p_scope,
    'closure_id', r.id, 'version', r.version, 'reason', btrim(p_reason)));
  perform app.audit('scope_reopened', p_scope, jsonb_build_object('closure_id', r.id, 'reason', btrim(p_reason)), false);
  return jsonb_build_object('scope_id', p_scope, 'status', 'active', 'closure_id', r.id);
end $$;

-- =====================================================================================================================
-- 5 · read-only after the close (D1.3): the tables of the scope's records refuse writes; the exceptions are a recall,
-- a scan and its copy check, a buyer link, a bill of lading, and the proof of delivery of a shipment carried over as
-- "awaiting POD" (its delivery confirmed later). New records are refused already ("scope is not active").
-- =====================================================================================================================
create or replace function app.awaits_pod(p_shipment uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.footprints f
      join public.scope_closures c on c.scope_id = f.scope_id and c.status = 'confirmed' and c.reopened_at is null
     where f.id = p_shipment and exists (select 1 from jsonb_array_elements(coalesce(c.items->'pod', '[]'::jsonb)) e where e->>'id' = f.id::text)) $$;

create or replace function app.closed_scope_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := to_jsonb(case when tg_op = 'DELETE' then old else new end); v_scope uuid; v_fp uuid;
begin
  v_fp := coalesce(r->>'shipment_id', r->>'footprint_id')::uuid;
  v_scope := coalesce((r->>'scope_id')::uuid, (select f.scope_id from public.footprints f where f.id = v_fp));
  if v_scope is not null and exists (select 1 from public.scopes s where s.id = v_scope and s.status = 'closed') then
    if tg_op = 'INSERT' and ((tg_table_name = 'deliveries') or (tg_table_name = 'attachments' and r->>'label' = 'pod'))
       and app.awaits_pod(v_fp) then
      return new;
    end if;
    raise exception 'this scope is closed: its records are read only (the State Manager may reopen it)' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

do $$
declare t text;
begin
  foreach t in array array['flags', 'attachments', 'deliveries', 'packs', 'cartons', 'label_prints', 'footprint_returns', 'qc_samples',
                           'sale_terms', 'export_documents', 'warehouse_inspections', 'warehouse_bags_out', 'net_weight_checks',
                           'withdrawals', 'lot_closures', 'qr_seals', 'pack_batches'] loop
    execute format('create trigger a01_closed_scope before insert or update or delete on public.%I for each row execute function app.closed_scope_guard()', t);
  end loop;
end $$;
create trigger a01_closed_scope before update or delete on public.footprints for each row execute function app.closed_scope_guard();

-- =====================================================================================================================
-- 6 · the season report's data (D3), from the records: the shareable copy (no farmer's name or phone, no price, no id)
-- or the internal one. The figures come from the same rules as the exports (app.export_record, app.stage_balance_of,
-- app.scope_pack_states); the app writes them down (PDF and Excel, English and Hindi), it works nothing out.
-- =====================================================================================================================
create or replace function app.season_report_data(p_scope uuid, p_internal boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc public.scopes; v_shares jsonb; recs jsonb; v_head jsonb; v_bal jsonb; v_states jsonb; v_codes text[];
        v_headline jsonb; v_balance jsonb; v_origin jsonb; v_quality jsonb; v_packing jsonb; v_sales jsonb; v_qr jsonb;
        v_chain jsonb; v_ledger jsonb; v_open jsonb; v_period jsonb;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null then return null; end if;
  -- a source's share of the season (as the season export)
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status <> 'superseded'
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id))
  select coalesce(jsonb_object_agg(e.id::text, e.qty_out / nullif(tot.kg, 0)) filter (where e.id is not null), '{}'::jsonb) into v_shares
    from (select sum(qty_out) as kg from live where stage_type in ('procurement', 'lot_inward')) tot
    left join live e on e.stage_type in ('procurement', 'lot_inward');
  -- every live record, in chain order, as the exports write it (this copy's columns only)
  select coalesce(jsonb_agg(app.export_record(f.id, p_internal, (v_shares->>f.id::text)::numeric) || jsonb_build_object('_id', f.id)
           order by array_position(sc.chain, f.stage_type), coalesce(f.captured_at, f.created_at), f.footprint_code), '[]'::jsonb)
    into recs
    from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
     and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id);
  v_head := app.export_scope_head(p_scope);
  v_bal := app.stage_balance_of(p_scope);
  select coalesce(jsonb_agg(to_jsonb(ps) order by ps.batch_code), '[]'::jsonb) into v_states from app.scope_pack_states(p_scope) ps;
  select coalesce(array_agg(p.serial), '{}') || coalesce((select array_agg(q.qr_code) from public.qr_seals q join public.footprints f on f.id = q.footprint_id
                                                          where f.scope_id = p_scope), '{}')
    into v_codes from public.packs p where p.scope_id = p_scope;
  select jsonb_build_object('from', min(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date)),
                            'to', max(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date)))
    into v_period from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy');

  -- headline figures
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ent as (select l.*, app.entry_gi(l.id) as gi from live l where l.stage_type in ('procurement', 'lot_inward')),
  vil as (select distinct fa.village, fa.district from ent e join public.farmers fa on fa.id = e.farmer_id),
  qc as (select l.id, v.domestic_verdict as d, v.export_verdict as x, v.override->>'market' as acc
           from live l join public.qc_verdicts v on v.footprint_id = l.id where l.stage_type = 'qc')
  select jsonb_build_object(
      'procured_kg', (select coalesce(sum(qty_out), 0) from ent),
      'packed_kg', (select coalesce(sum(qty_out), 0) from live where stage_type = 'packing'),
      'sold_kg', (select coalesce(sum(qty_out), 0) from live where stage_type = 'commercial'),
      'shipped_kg', (select coalesce(sum(qty_in), 0) from live where stage_type = 'shipment'),
      'farmers', (select count(distinct farmer_id) from ent),
      'villages', (select count(*) from vil),
      'gi_pct', (select round(100 * coalesce(sum(qty_out) filter (where gi = 'gi'), 0) / nullif(sum(qty_out), 0), 1) from ent),
      'farm_verified_pct', (select round(100 * coalesce(sum(qty_out) filter (where stage_type = 'procurement'), 0) / nullif(sum(qty_out), 0), 1) from ent),
      'qc', jsonb_build_array(
        (select jsonb_build_object('market', 'domestic', 'lots', count(*), 'passed', count(*) filter (where d = 'pass'),
                  'failed', count(*) filter (where d = 'fail' and acc is distinct from 'domestic'),
                  'accepted', count(*) filter (where acc = 'domestic'), 'pending', count(*) filter (where d = 'pending'),
                  'pass_pct', round(100.0 * count(*) filter (where d = 'pass') / nullif(count(*) filter (where d <> 'pending'), 0), 1)) from qc),
        (select jsonb_build_object('market', 'export', 'lots', count(*), 'passed', count(*) filter (where x = 'pass'),
                  'failed', count(*) filter (where x = 'fail' and acc is distinct from 'export'),
                  'accepted', count(*) filter (where acc = 'export'), 'pending', count(*) filter (where x = 'pending'),
                  'pass_pct', round(100.0 * count(*) filter (where x = 'pass') / nullif(count(*) filter (where x <> 'pending'), 0), 1)) from qc)),
      'packs_released', (select coalesce(sum((s->>'released')::int), 0) from jsonb_array_elements(v_states) s),
      'packs_released_old', (select coalesce(sum((s->>'old_data')::int), 0) from jsonb_array_elements(v_states) s),
      'packs_held', (select coalesce(sum((s->>'held')::int), 0) from jsonb_array_elements(v_states) s),
      'scans', (select count(*) from public.scans s where s.code = any (v_codes)),
      'copy_flags', (select count(*) from public.scan_flags f where f.scope_id = p_scope),
      'recalls', (select count(*) from public.release_events e join public.footprints f on f.id = e.seal_id
                   where f.scope_id = p_scope and e.status = 'recalled'),
      'sealed_lots', (select count(*) from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope))
    into v_headline;

  -- mass balance: per stage, milling's parts, and sold never above procured (checked here and printed)
  select jsonb_build_object('stages', v_bal,
      'milling', (select jsonb_build_object('in_kg', coalesce(sum((r->>'qty_in_kg')::numeric), 0),
                    'head_rice_kg', coalesce(sum((r->>'head_rice_kg')::numeric), 0), 'broken_kg', coalesce(sum((r->>'broken_kg')::numeric), 0),
                    'husk_kg', coalesce(sum((r->>'husk_kg')::numeric), 0), 'bran_kg', coalesce(sum((r->>'bran_kg')::numeric), 0),
                    'floor_loss_kg', coalesce(sum((r->>'floor_loss_kg')::numeric), 0), 'records', count(*))
                  from jsonb_array_elements(recs) r where r->>'stage' = 'milling'),
      'written_off_kg', (select coalesce(sum(c.floor_loss_kg), 0) from public.lot_closures c where c.scope_id = p_scope and c.kind = 'written_off'),
      'check', jsonb_build_object('procured_kg', v_headline->'procured_kg', 'sold_kg', v_headline->'sold_kg',
                 'ok', (v_headline->>'sold_kg')::numeric <= (v_headline->>'procured_kg')::numeric + app.kg_tolerance()),
      'differences', (select count(*) from jsonb_array_elements(v_bal) b where not (b->>'balanced')::boolean))
    into v_balance;

  -- origin: villages and districts with their share; farmers; GI and farm-verified; the farmer list in the internal copy only
  with live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
                   and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)
                   and f.stage_type in ('procurement', 'lot_inward')),
  tot as (select nullif(sum(qty_out), 0) as kg from live)
  select jsonb_build_object(
      'villages', coalesce((select jsonb_agg(v order by (v->>'kg')::numeric desc, v->>'village') from (
          select jsonb_build_object('village', fa.village, 'district', fa.district, 'kg', sum(l.qty_out),
                   'pct', round(100 * sum(l.qty_out) / (select kg from tot), 1), 'farmers', count(distinct l.farmer_id)) as v
            from live l left join public.farmers fa on fa.id = l.farmer_id
           group by fa.village, fa.district) x), '[]'::jsonb),
      'farmers', (select count(distinct farmer_id) from live),
      'gi_pct', v_headline->'gi_pct', 'farm_verified_pct', v_headline->'farm_verified_pct',
      'farmer_list', case when p_internal then coalesce((select jsonb_agg(v order by v->>'code') from (
          select jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village, 'district', fa.district,
                   'kg', sum(l.qty_out), 'lots', count(*)) as v
            from live l join public.farmers fa on fa.id = l.farmer_id group by fa.id, fa.farmer_code, fa.name, fa.village, fa.district) x), '[]'::jsonb) end)
    into v_origin;

  -- quality: each lab record with its verdicts (a release on the client's acceptance said as such), readings, lab, report, file
  select coalesce(jsonb_agg(jsonb_build_object('code', r->'code', 'on', coalesce(r->'happened_on', r->'recorded_at'),
           'domestic', r->'qc_domestic', 'export', r->'qc_export', 'accepted', v.override->>'market',
           'readings', coalesce(r->'readings', '{}'::jsonb),
           'lab', r->'lab', 'lab_accreditation', r->'lab_accreditation', 'report_no', r->'report_no', 'report_date', r->'report_date',
           'sample', r->'sample_code', 'files', r->'evidence_sha256') order by r->>'code'), '[]'::jsonb)
    into v_quality
    from jsonb_array_elements(recs) r left join public.qc_verdicts v on v.footprint_id = (r->>'_id')::uuid
   where r->>'stage' = 'qc';

  -- packing: per batch, its packs by size, serial range, dates, the net weight check, the wastage
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packing', pf.footprint_code, 'packs', b.n, 'void', b.v,
           'first', b.first, 'last', b.last, 'by_size', b.by_size, 'packed_on', b.packed_on,
           'best_before', case when b.no_bb > 0 then 'not_recorded' else b.bb::text end,
           'net_weight', (select n.result from public.net_weight_checks n where n.footprint_id = pf.id order by n.checked_at desc nulls last limit 1),
           'wastage_kg', pf.computed->'wastage_kg', 'wastage_pct', pf.computed->'wastage_pct') order by b.batch_code), '[]'::jsonb)
    into v_packing
    from (select p.batch_code, min(p.footprint_id::text)::uuid as fp, count(*) filter (where p.status <> 'void') as n,
                 count(*) filter (where p.status = 'void') as v, min(p.serial) as first, max(p.serial) as last,
                 min(p.packed_on) as packed_on, min(p.best_before) filter (where p.status <> 'void') as bb,
                 count(*) filter (where p.status <> 'void' and p.best_before is null) as no_bb,
                 (select string_agg(x.n || ' × ' || x.label, ', ' order by x.size desc, x.label)
                    from (select count(*) as n, coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg') as label,
                                 max(k2.size_kg) as size
                            from public.packs k2 left join public.pack_skus sk on sk.id = k2.sku_id
                           where k2.batch_code = p.batch_code and k2.status <> 'void'
                           group by coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg')) x) as by_size
            from public.packs p where p.scope_id = p_scope group by p.batch_code) b
    left join public.footprints pf on pf.id = b.fp;

  -- sales and shipments: per order, its shipments, delivery and proof of delivery; prices only in the internal copy, only if recorded
  select coalesce(jsonb_agg(jsonb_build_object('code', c->'code', 'on', coalesce(c->'happened_on', c->'recorded_at'),
           'buyer', c->'buyer', 'market', c->'market', 'country', c->'destination_country', 'order_no', c->'order_no',
           'packs', (select string_agg((l->>'units') || ' × ' || coalesce(app.sku_name(k), '?'), ', ' order by k.size desc nulls last)
                       from public.footprints cf, jsonb_array_elements(case when jsonb_typeof(cf.payload->'packs') = 'array' then cf.payload->'packs' else '[]'::jsonb end) l
                       left join public.pack_skus k on k.id::text = l->>'sku_id'
                      where cf.id = (c->>'_id')::uuid),
           'kg', c->'qty_out_kg', 'incoterms', c->'incoterms',
           'price_per_kg', c->'price_per_kg', 'currency', c->'currency', 'total_value', c->'total_value',
           'shipments', coalesce((select jsonb_agg(jsonb_build_object('code', s->'code', 'kg', s->'qty_in_kg', 'invoice_no', s->'invoice_no',
                 'dispatch_date', s->'dispatch_date', 'destination', s->'destination', 'container_no', s->'container_no', 'bl_no', s->'bl_no',
                 'delivered_on', d.received_on, 'received_kg', d.received_kg, 'transit_loss_kg', d.transit_loss_kg,
                 'pod', case when c->>'market' <> 'export' then 'not_needed'
                             when exists (select 1 from public.attachments a where a.footprint_id = (s->>'_id')::uuid and a.label = 'pod') then 'attached'
                             else 'awaiting' end,
                 'sealed', (select q.qr_code from public.footprints qf join public.qr_seals q on q.footprint_id = qf.id
                             where qf.prev_footprint_id = (s->>'_id')::uuid and qf.stage_type = 'qr_activation' and qf.status not in ('superseded', 'legacy') limit 1))
                 order by s->>'code')
               from jsonb_array_elements(recs) s left join public.deliveries d on d.shipment_id = (s->>'_id')::uuid
              where s->>'stage' = 'shipment'
                and (select f.prev_footprint_id from public.footprints f where f.id = (s->>'_id')::uuid) = (c->>'_id')::uuid), '[]'::jsonb))
           order by c->>'code'), '[]'::jsonb)
    into v_sales
    from jsonb_array_elements(recs) c where c->>'stage' = 'commercial';

  -- QR: packs released per batch; scans by city; copy flags; investigations and recalls with their outcome
  select jsonb_build_object('batches', v_states,
      'scans_by_city', coalesce((select jsonb_agg(jsonb_build_object('city', city, 'country', country, 'scans', n) order by n desc, city)
                                  from (select coalesce(s.city, '') as city, coalesce(s.country, '') as country, count(*) as n
                                          from public.scans s where s.code = any (v_codes) group by 1, 2) x), '[]'::jsonb),
      'copy_flags', coalesce((select jsonb_agg(jsonb_build_object('serial', f.serial, 'kind', f.kind, 'status', f.status,
                                'raised_at', f.raised_at, 'decided_at', f.decided_at, 'reason', f.reason) order by f.raised_at)
                                from public.scan_flags f where f.scope_id = p_scope), '[]'::jsonb),
      'releases', coalesce((select jsonb_agg(jsonb_build_object('qr_code', q.qr_code, 'status', e.status, 'reason', e.reason, 'at', e.at)
                                order by e.at)
                              from public.release_events e join public.qr_seals q on q.footprint_id = e.seal_id
                              join public.footprints f on f.id = e.seal_id
                             where f.scope_id = p_scope and e.status <> 'active'), '[]'::jsonb))
    into v_qr;

  -- chain and integrity: per stage, who recorded and verified, same person, returns, flags and warnings, manager recordings
  select coalesce(jsonb_agg(jsonb_build_object('stage', ch.stage, 'pos', ch.pos,
           'records', (select count(*) from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'recorded_by', (select coalesce(jsonb_agg(distinct u.display_name), '[]'::jsonb) from public.footprints f join public.app_users u on u.id = f.created_by
                            where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'verified_by', (select coalesce(jsonb_agg(distinct u.display_name), '[]'::jsonb) from public.footprints f join public.app_users u on u.id = f.verified_by
                            where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'same_person', (select count(*) from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage
                            and f.status not in ('superseded', 'legacy') and ch.stage <> 'qr_activation' and f.verified_by = f.created_by),
           'returns', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'reason', r.reason, 'status', r.status) order by r.returned_at), '[]'::jsonb)
                        from public.footprint_returns r join public.footprints f on f.id = r.footprint_id
                       where r.scope_id = p_scope and f.stage_type = ch.stage),
           'flags', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'kind', fl.kind, 'text', fl.text, 'status', fl.status) order by fl.created_at), '[]'::jsonb)
                      from public.flags fl join public.footprints f on f.id = fl.footprint_id where f.scope_id = p_scope and f.stage_type = ch.stage),
           'warnings', (select coalesce(sum(cardinality(f.warnings)), 0) from public.footprints f
                         where f.scope_id = p_scope and f.stage_type = ch.stage and f.status not in ('superseded', 'legacy')),
           'manager_records', (select coalesce(jsonb_agg(jsonb_build_object('code', f.footprint_code, 'reason', f.manager_reason) order by f.created_at), '[]'::jsonb)
                                from public.footprints f where f.scope_id = p_scope and f.stage_type = ch.stage and f.manager_reason is not null))
           order by ch.pos), '[]'::jsonb)
    into v_chain
    from unnest(sc.chain) with ordinality ch(stage, pos);

  -- the ledger: the last full check; the scope's blocks, the first and the last
  select jsonb_build_object(
      'last_check', (select jsonb_build_object('at', c.checked_at, 'ok', c.ok, 'blocks', c.blocks, 'problem', c.problem)
                       from public.ledger_checks c order by c.checked_at desc limit 1),
      'blocks', (select count(*) from public.ledger l where l.scope_id = p_scope),
      'first_hash', (select l.hash from public.ledger l where l.scope_id = p_scope order by l.seq limit 1),
      'last_hash', (select l.hash from public.ledger l where l.scope_id = p_scope order by l.seq desc limit 1))
    into v_ledger;

  -- open items now (a final report adds what the close carried over)
  select jsonb_build_object(
      'flags', coalesce((select jsonb_agg(jsonb_build_object('code', f.footprint_code, 'kind', fl.kind, 'text', fl.text) order by fl.created_at)
                          from public.flags fl join public.footprints f on f.id = fl.footprint_id where f.scope_id = p_scope and fl.status = 'open'), '[]'::jsonb),
      'awaiting_pod', coalesce((select jsonb_agg(s->'code' order by s->>'code') from jsonb_array_elements(v_sales) c, jsonb_array_elements(c->'shipments') s
                                 where s->>'pod' = 'awaiting' or (c->>'market' = 'export' and s->>'delivered_on' is null)), '[]'::jsonb),
      'pending', (select count(*) from public.footprints f where f.scope_id = p_scope and f.status = 'pending'),
      'lab_hold', (select count(*) from public.qc_samples q where q.scope_id = p_scope and q.status = 'sent' and q.qc_footprint_id is null),
      'packs_held', v_headline->'packs_held')
    into v_open;

  return jsonb_build_object('copy', case when p_internal then 'internal' else 'shareable' end,
    'cover', v_head || jsonb_build_object('scope_code', sc.short_code, 'gi_earned', coalesce((v_headline->>'gi_pct')::numeric, 0) > 0,
               'districts', (select coalesce(jsonb_agg(distinct v->>'district') filter (where v->>'district' is not null), '[]'::jsonb)
                               from jsonb_array_elements(v_origin->'villages') v),
               'delivery_model', null, 'period_from', v_period->'from', 'period_to', v_period->'to'),
    'units', app.param_units(p_scope),
    'headline', v_headline, 'balance', v_balance, 'origin', v_origin, 'quality', v_quality, 'packing', v_packing,
    'sales', v_sales, 'qr', v_qr, 'chain', v_chain, 'ledger', v_ledger, 'open_items', v_open);
end $$;

-- what a confirmed close decided (a final report's "Open items" and "Closed"): who, when, the answers, the write-offs
create or replace function app.closure_summary(p_closure uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('version', c.version,
           'requested_by', (select u.display_name from public.app_users u where u.id = c.requested_by), 'requested_at', c.requested_at,
           'confirmed_by', (select u.display_name from public.app_users u where u.id = c.decided_by), 'confirmed_at', c.decided_at,
           'note', c.note, 'answers', c.items,
           'written_off', coalesce((select jsonb_agg(jsonb_build_object('code', f.footprint_code, 'stage', f.stage_type, 'kg', lc.floor_loss_kg,
                             'reason', lc.reason) order by f.footprint_code)
                             from public.lot_closures lc join public.footprints f on f.id = lc.footprint_id where lc.closure_id = c.id), '[]'::jsonb))
    from public.scope_closures c where c.id = p_closure $$;

-- =====================================================================================================================
-- 7 · issuing a report: its reference from a counter, its version, the data of both copies kept as issued, a ledger block;
-- a final report supersedes every report of the scope still valid, an interim one the interim ones
-- =====================================================================================================================
create or replace function app.issue_report(p_scope uuid, p_final boolean, p_closure uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := app.current_user_id(); sc public.scopes; v_ref text; v_ver int; d_int jsonb; d_sh jsonb; v_cl jsonb; r public.reports;
        v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select * into sc from public.scopes where id = p_scope;
  if p_final then
    select version into v_ver from public.scope_closures where id = p_closure and scope_id = p_scope and status = 'confirmed';
    if v_ver is null then raise exception 'a final report follows a confirmed close' using errcode = '23514'; end if;
  else
    select coalesce(max(version), 0) + 1 into v_ver from public.reports where scope_id = p_scope and not final;
  end if;
  v_ref := 'GV-SR-' || lpad(nextval('public.report_ref_seq')::text, 6, '0');
  d_int := app.season_report_data(p_scope, true);
  d_sh := app.season_report_data(p_scope, false);
  if p_final then
    v_cl := app.closure_summary(p_closure);
    d_int := d_int || jsonb_build_object('closure', v_cl);
    d_sh := d_sh || jsonb_build_object('closure', v_cl);
  end if;
  insert into public.reports (ref, scope_id, client_id, final, version, issued_by, issued_to, period_from, period_to, closure_id,
                              data_hash, data_shareable, data_internal)
  values (v_ref, p_scope, sc.client_id, p_final, v_ver, me, (select c.name from public.clients c where c.id = sc.client_id),
          (d_int->'cover'->>'period_from')::date, v_today, p_closure,
          encode(digest(d_int::text, 'sha256'), 'hex'), d_sh, d_int)
  returning * into r;
  update public.reports set status = 'superseded', superseded_by = r.id, superseded_at = now()
   where scope_id = p_scope and id <> r.id and status = 'valid' and (p_final or not final);
  perform app.ledger_append(null, p_scope, 'report', me, jsonb_build_object('act', 'issued', 'report_id', r.id, 'ref', r.ref,
    'final', r.final, 'version', r.version, 'data_hash', r.data_hash, 'scope_id', p_scope, 'closure_id', p_closure));
  perform app.audit('report_issued', p_scope, jsonb_build_object('ref', r.ref, 'final', r.final, 'version', r.version), false);
  return jsonb_build_object('id', r.id, 'ref', r.ref, 'final', r.final, 'version', r.version, 'issued_at', r.issued_at, 'status', r.status);
end $$;

-- D2: "Report so far", any time before the close, by the Client Manager or the State Manager
create or replace function app.generate_interim_report(p_scope uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); sc public.scopes;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or me is null or not app.sees_whole_scope(p_scope) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if app.is_client_login() or not (app.manages_scope(me, p_scope) or app.sm_of_scope(p_scope)) then
    raise exception 'the Client Manager or the State Manager makes a report' using errcode = '42501'; end if;
  if sc.status = 'closed' then raise exception 'report: the season is closed: its final report is issued' using errcode = '23514'; end if;
  if sc.status <> 'active' then raise exception 'only an active scope has a report' using errcode = '23514'; end if;
  return app.issue_report(p_scope, false, null);
end $$;

-- =====================================================================================================================
-- 8 · reading a report, its files, the list, the close's state
-- =====================================================================================================================
create or replace function app.report_head(r public.reports) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', r.id, 'ref', r.ref, 'scope_id', r.scope_id, 'final', r.final, 'version', r.version, 'status', r.status,
           'issued_at', r.issued_at, 'issued_by', (select u.display_name from public.app_users u where u.id = r.issued_by),
           'issued_to', r.issued_to, 'period_from', r.period_from, 'period_to', r.period_to, 'data_hash', r.data_hash,
           'superseded_by', (select s.ref from public.reports s where s.id = r.superseded_by), 'superseded_at', r.superseded_at,
           'withdrawn_at', r.withdrawn_at, 'withdrawn_reason', r.withdrawn_reason) $$;

create or replace function app.report_content(p_report uuid, p_copy text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.reports;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or app.current_user_id() is null or not app.sees_whole_scope(r.scope_id) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if p_copy is null or p_copy not in ('shareable', 'internal') then raise exception 'a report is a shareable or an internal copy' using errcode = '22023'; end if;
  if p_copy = 'internal' and not app.may_report_internal(r.scope_id) then
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy' using errcode = '42501'; end if;
  perform app.audit('report_read', r.scope_id, jsonb_build_object('ref', r.ref, 'copy', p_copy), false);
  return jsonb_build_object('report', app.report_head(r), 'copy', p_copy,
    'data', case when p_copy = 'internal' then r.data_internal else r.data_shareable end);
end $$;

-- who may put a report's files: whoever issued it, the scope's Client Manager or State Manager (not the client's login)
create or replace function app.may_write_report_file(p_report uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.reports r where r.id = p_report and r.status <> 'withdrawn'
                   and app.current_user_id() is not null and not app.is_client_login()
                   and (r.issued_by = app.current_user_id() or app.manages_scope(app.current_user_id(), r.scope_id) or app.sm_of_scope(r.scope_id))) $$;

-- the store's rule for a new file: "<report id>/<copy>.<format>", by who may write the report's files (the internal copy by its readers)
create or replace function app.may_write_report_object(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare r public.reports;
begin
  if p_name !~ '^[0-9a-f-]{36}/(shareable|internal)\.(en|hi)\.(pdf|xlsx)$' then return false; end if;
  select * into r from public.reports where id = split_part(p_name, '/', 1)::uuid;
  if r.id is null or not app.may_write_report_file(r.id) then return false; end if;
  return p_name like '%/shareable.%' or app.may_report_internal(r.scope_id);
end $$;

-- who may read a stored file: "<report id>/shareable.pdf" by whoever reads the whole scope, "internal.*" by the internal readers
create or replace function app.may_read_report_file(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare v_id uuid; v_file text; r public.reports;
begin
  if p_name !~ '^[0-9a-f-]{36}/(shareable|internal)\.(en|hi)\.(pdf|xlsx)$' then return false; end if;
  v_id := split_part(p_name, '/', 1)::uuid; v_file := split_part(p_name, '/', 2);
  select * into r from public.reports where id = v_id;
  if r.id is null or app.current_user_id() is null or not app.sees_whole_scope(r.scope_id) then return false; end if;
  return v_file like 'shareable.%' or app.may_report_internal(r.scope_id);
end $$;

create or replace function app.register_report_file(p_report uuid, p_copy text, p_format text, p_lang text, p_sha256 text, p_bytes bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.reports; v_key text; v_path text;
begin
  select * into r from public.reports where id = p_report for update;
  if r.id is null or me is null or not app.sees_whole_scope(r.scope_id) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.may_write_report_file(r.id) then raise exception 'report: the Client Manager or the State Manager stores a report''s files' using errcode = '42501'; end if;
  if p_copy not in ('shareable', 'internal') or p_format not in ('pdf', 'xlsx') or p_lang not in ('en', 'hi') then
    raise exception 'a report file is a PDF or an Excel file of one copy, in English or Hindi' using errcode = '22023'; end if;
  if p_copy = 'internal' and not app.may_report_internal(r.scope_id) then raise exception 'the internal copy is for the people of this scope' using errcode = '42501'; end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes is null or p_bytes <= 0 then raise exception 'a file''s SHA-256 and size' using errcode = '22023'; end if;
  v_key := p_format || '_' || p_lang || '_' || p_copy;
  v_path := r.id || '/' || p_copy || '.' || p_lang || '.' || p_format;
  if r.files ? v_key then raise exception 'report: this file is stored already' using errcode = '23505'; end if;
  update public.reports set files = files || jsonb_build_object(v_key, jsonb_build_object('path', v_path, 'sha256', p_sha256, 'bytes', p_bytes,
           'at', now(), 'by', (select u.display_name from public.app_users u where u.id = me)))
   where id = r.id returning * into r;
  perform app.ledger_append(null, r.scope_id, 'report', me, jsonb_build_object('act', 'file', 'report_id', r.id, 'ref', r.ref,
    'copy', p_copy, 'format', p_format, 'lang', p_lang, 'sha256', p_sha256, 'bytes', p_bytes));
  return app.report_head(r) || jsonb_build_object('path', v_path);
end $$;

-- a download is logged (Part C: every download), then the app asks the store for the file
create or replace function app.note_report_download(p_report uuid, p_copy text, p_format text, p_lang text) returns text
language plpgsql security definer set search_path = public as $$
declare r public.reports; v_key text := p_format || '_' || p_lang || '_' || p_copy;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or app.current_user_id() is null or not app.may_read_report_file(r.id || '/' || p_copy || '.' || p_lang || '.' || p_format) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not r.files ? v_key then raise exception 'report: this file is not stored yet' using errcode = 'P0002'; end if;
  perform app.audit('report_downloaded', r.scope_id, jsonb_build_object('ref', r.ref, 'copy', p_copy, 'format', p_format, 'lang', p_lang), false);
  return r.files->v_key->>'path';
end $$;

create or replace function app.scope_reports(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_int boolean;
begin
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.sees_whole_scope(p_scope) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  v_int := app.may_report_internal(p_scope);
  return coalesce((select jsonb_agg(app.report_head(r) || jsonb_build_object('files',
             (select coalesce(jsonb_object_agg(k, jsonb_build_object('sha256', v->>'sha256', 'bytes', v->'bytes', 'at', v->'at')), '{}'::jsonb)
                from jsonb_each(r.files) e(k, v) where k like '%_shareable' or v_int))
           order by r.issued_at desc) from public.reports r where r.scope_id = p_scope), '[]'::jsonb);
end $$;

create or replace function app.scope_close_state(p_scope uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); sc public.scopes; v_cm boolean; v_sm boolean; v_open public.scope_closures;
begin
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or me is null or not app.sees_whole_scope(p_scope) then raise exception 'record not found' using errcode = 'P0002'; end if;
  v_cm := app.manages_scope(me, p_scope) and not app.is_client_login();
  v_sm := app.sm_of_scope(p_scope);
  select * into v_open from public.scope_closures where scope_id = p_scope and status = 'requested';
  return jsonb_build_object('status', sc.status,
    'request', case when v_open.id is null then null else jsonb_build_object('id', v_open.id, 'requested_at', v_open.requested_at,
                 'requested_by', (select u.display_name from public.app_users u where u.id = v_open.requested_by),
                 'note', v_open.note, 'answers', v_open.items, 'mine', v_open.requested_by = me) end,
    'closures', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'version', c.version,
                   'requested_at', c.requested_at, 'requested_by', (select u.display_name from public.app_users u where u.id = c.requested_by),
                   'decided_at', c.decided_at, 'decided_by', (select u.display_name from public.app_users u where u.id = c.decided_by),
                   'decided_reason', c.decided_reason, 'reopened_at', c.reopened_at, 'reopen_reason', c.reopen_reason,
                   'reopened_by', (select u.display_name from public.app_users u where u.id = c.reopened_by)) order by c.requested_at desc)
                 from public.scope_closures c where c.scope_id = p_scope and c.status <> 'requested'), '[]'::jsonb),
    'may', jsonb_build_object('request', v_cm and sc.status = 'active' and v_open.id is null,
             'withdraw', v_cm and v_open.id is not null, 'confirm', v_sm and v_open.id is not null and v_open.requested_by <> me,
             'decline', v_sm and v_open.id is not null, 'reopen', v_sm and sc.status = 'closed',
             'interim', (v_cm or v_sm) and sc.status = 'active', 'internal', app.may_report_internal(p_scope),
             'store_files', v_cm or v_sm, 'withdraw_report', v_sm));
end $$;

-- a report taken back (it was wrong): the State Manager, with a reason; the verify page says "Withdrawn"
create or replace function app.withdraw_report(p_report uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.reports;
begin
  select * into r from public.reports where id = p_report for update;
  if r.id is null or me is null or not app.sees_whole_scope(r.scope_id) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.sm_of_scope(r.scope_id) then raise exception 'only the State Manager of the scope''s state withdraws a report' using errcode = '42501'; end if;
  if r.status = 'withdrawn' then raise exception 'this report is withdrawn already' using errcode = '23514'; end if;
  if not app.close_reason_ok(p_reason) then raise exception 'close: say why (10 to 250 characters)' using errcode = '23514'; end if;
  update public.reports set status = 'withdrawn', withdrawn_by = me, withdrawn_at = now(), withdrawn_reason = btrim(p_reason)
   where id = r.id returning * into r;
  perform app.ledger_append(null, r.scope_id, 'report', me, jsonb_build_object('act', 'withdrawn', 'report_id', r.id, 'ref', r.ref,
    'reason', r.withdrawn_reason));
  perform app.audit('report_withdrawn', r.scope_id, jsonb_build_object('ref', r.ref, 'reason', r.withdrawn_reason), false);
  return app.report_head(r);
end $$;

-- "Verify this document": anyone with the reference; the status, the date, who it was issued to, the files' SHA-256
create or replace function app.public_document(p_ref text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
           'issued_at', r.issued_at, 'issued_to', r.issued_to, 'period_from', r.period_from, 'period_to', r.period_to,
           'crop', cr.name, 'season', s.season_code, 'geography', s.geography, 'state', st.name,
           'superseded_by', (select x.ref from public.reports x where x.id = r.superseded_by), 'superseded_at', r.superseded_at,
           'withdrawn_at', r.withdrawn_at,
           'files', coalesce((select jsonb_agg(jsonb_build_object('copy', split_part(k, '_', 3), 'format', split_part(k, '_', 1), 'lang', split_part(k, '_', 2),
                                'sha256', v->>'sha256', 'bytes', v->'bytes') order by k) from jsonb_each(r.files) e(k, v)), '[]'::jsonb))
    from public.reports r join public.scopes s on s.id = r.scope_id join public.crops cr on cr.id = s.crop_id
    left join public.states st on st.id = s.state_id
   where r.ref = upper(btrim(p_ref)) $$;

-- D4: the billing count, reports issued per client per month (GrainVeda: the admin)
create or replace function app.reports_issued(p_months integer default 12) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_admin() then raise exception 'the admin reads the reports issued' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('month', m, 'client', c.name, 'client_code', c.code, 'final', fin, 'interim', intr,
                     'total', fin + intr) order by m desc, c.name)
                     from (select to_char(r.issued_at at time zone 'Asia/Kolkata', 'YYYY-MM') as m, r.client_id,
                                  count(*) filter (where r.final) as fin, count(*) filter (where not r.final) as intr
                             from public.reports r
                            where r.issued_at >= date_trunc('month', now() at time zone 'Asia/Kolkata') - make_interval(months => greatest(p_months, 1) - 1)
                            group by 1, 2) x join public.clients c on c.id = x.client_id), '[]'::jsonb);
end $$;

-- the private store of report files (where Supabase Storage is: the live project and the local stand-in)
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage schema not present: reports bucket policies skipped';
    return;
  end if;
  insert into storage.buckets (id, name, public) values ('reports', 'reports', false) on conflict (id) do nothing;
  execute $p$drop policy if exists reports_read on storage.objects$p$;
  execute $p$drop policy if exists reports_upload on storage.objects$p$;
  execute $p$create policy reports_read on storage.objects for select to authenticated
    using (bucket_id = 'reports' and app.may_read_report_file(name))$p$;
  execute $p$create policy reports_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'reports' and app.may_write_report_object(name))$p$;
end $$;

-- =====================================================================================================================
-- 9 · replaced: the scopes' guard; the mass balance, the exports and the trace know a write-off
-- =====================================================================================================================
CREATE OR REPLACE FUNCTION app.scopes_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_op = 'INSERT' and new.status = 'active' then
    perform app.validate_chain(new.chain, new.crop_id);
    new.activated_at := coalesce(new.activated_at, now());
  elsif tg_op = 'UPDATE' then
    if old.status = 'draft' and new.status = 'active' then
      perform app.validate_chain(new.chain, new.crop_id);
      new.activated_at := coalesce(new.activated_at, now());
    elsif old.status <> 'draft' then
      if new.chain is distinct from old.chain or new.crop_id <> old.crop_id or new.client_id <> old.client_id
         or new.season_code <> old.season_code then
        raise exception 'scope chain/crop/client/season are frozen after activation; open a new scope' using errcode = '42501';
      end if;
      -- migration 63 (Part D1): a signed-in person closes a scope only through its close request and reopens it only as
      -- its State Manager, with a reason; a closed scope's settings are read only
      if old.status = 'closed' and new.status <> 'closed' and auth.uid() is not null
         and coalesce(current_setting('app.scope_reopen', true), '') <> 'on' then
        raise exception 'a closed scope is reopened only by its State Manager, with a reason' using errcode = '42501';
      end if;
      if old.status <> 'closed' and new.status = 'closed' and auth.uid() is not null
         and coalesce(current_setting('app.scope_close', true), '') <> 'on' then
        raise exception 'close: a scope is closed through its close request: the Client Manager asks, the State Manager confirms' using errcode = '42501';
      end if;
      if old.status = 'closed' and new.status = 'closed' and auth.uid() is not null
         and (to_jsonb(new) - 'status') is distinct from (to_jsonb(old) - 'status') then
        raise exception 'this scope is closed: its records are read only (the State Manager may reopen it)' using errcode = '42501';
      end if;
    end if;
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION app.stage_balance_of(p_scope uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with sc as (select s.*, s.chain[cardinality(s.chain)]::text as last_stage from public.scopes s where s.id = p_scope),
  live as (select f.*, app.record_parts(f) as m from public.footprints f
            where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')),
  batched as (select distinct (x)::uuid as id from live b, jsonb_array_elements_text(coalesce(b.payload->'source_footprint_ids', '[]'::jsonb)) x
               where b.stage_type = 'village_batch'),
  rec as (
    select l.*, case when cl.kind = 'written_off' then 0 else coalesce(cl.floor_loss_kg, 0) end as closed_kg,
           case when cl.kind = 'written_off' then cl.floor_loss_kg else 0 end as off_kg,                     -- migration 63
           case when l.split_into_grades then 0
                when l.stage_type::text = (select last_stage from sc) or l.id in (select id from batched) then l.qty_out
                else coalesce((select sum(c.qty_in + (c.m->>'transit_up')::numeric) from live c
                                where c.prev_footprint_id = l.id and c.stage_type <> 'village_batch'), 0) end as handed,
           case when l.split_into_grades or cl.footprint_id is not null or l.id in (select id from batched)
                     or l.stage_type::text = (select last_stage from sc) then 0
                else greatest(app.available_qty(l.id) - coalesce((select sum((c.m->>'transit_up')::numeric) from live c
                                                                   where c.prev_footprint_id = l.id), 0), 0) end as left_kg
      from live l left join public.lot_closures cl on cl.footprint_id = l.id),
  agg as (
    select r.stage_type::text as stage, count(*) as n, count(*) filter (where r.status = 'pending') as pending,
           count(*) filter (where r.status in ('verified', 'closed')) as verified,
           coalesce(sum((r.m->>'in')::numeric + (r.m->>'transit_up')::numeric) filter (where not r.is_grade_lot), 0) as kg_in,
           coalesce(sum(r.qty_out) filter (where not r.is_grade_lot), 0) as kg_out,
           coalesce(sum((r.m->>'by_products')::numeric) filter (where not r.is_grade_lot), 0) as byp,
           coalesce(sum((r.m->>'other')::numeric) filter (where not r.is_grade_lot), 0) as oth,
           coalesce(sum((r.m->>'floor_loss')::numeric) filter (where not r.is_grade_lot and r.stage_type not in ('procurement', 'lot_inward')), 0) as floor,
           coalesce(sum((r.m->>'transit_in')::numeric + (r.m->>'transit_up')::numeric) filter (where not r.is_grade_lot), 0) as transit,
           coalesce(sum(r.closed_kg) filter (where r.stage_type::text <> (select last_stage from sc)), 0) as closed,
           coalesce(sum(r.off_kg) filter (where r.stage_type::text <> (select last_stage from sc)), 0) as off_kg,
           coalesce(sum(r.handed), 0) as handed, coalesce(sum(r.left_kg), 0) as left_kg
      from rec r group by r.stage_type)
  select coalesce(jsonb_agg(jsonb_build_object('stage', ch.stage, 'pos', ch.pos,
           'records', coalesce(a.n, 0), 'pending', coalesce(a.pending, 0), 'verified', coalesce(a.verified, 0),
           'kg_in', round(coalesce(a.kg_in, 0), 3), 'kg_out', round(coalesce(a.kg_out, 0), 3),
           'by_products_kg', round(coalesce(a.byp, 0), 3), 'other_kg', round(coalesce(a.oth, 0), 3),
           'floor_loss_kg', round(coalesce(a.floor, 0), 3), 'transit_loss_kg', round(coalesce(a.transit, 0), 3),
           'closed_kg', round(coalesce(a.closed, 0), 3), 'written_off_kg', round(coalesce(a.off_kg, 0), 3), 'handed_on_kg', round(coalesce(a.handed, 0), 3), 'left_kg', round(coalesce(a.left_kg, 0), 3),
           'last', ch.stage::text = (select last_stage from sc),
           'difference_kg', round(coalesce(a.kg_in - (a.handed + a.byp + a.oth + a.floor + a.transit + a.closed + a.off_kg + a.left_kg), 0), 3),
           'balanced', abs(coalesce(a.kg_in - (a.handed + a.byp + a.oth + a.floor + a.transit + a.closed + a.off_kg + a.left_kg), 0))
                         <= app.kg_tolerance() * greatest(coalesce(a.n, 0), 1))
           order by ch.pos), '[]'::jsonb)
    from sc, unnest(sc.chain) with ordinality ch(stage, pos)
    left join agg a on a.stage = ch.stage::text $function$;
CREATE OR REPLACE FUNCTION app.export_record(p_fp uuid, p_internal boolean, p_share numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; fa public.farmers; q public.qc_verdicts; s public.qr_seals; v_lab jsonb; r jsonb; v_entry boolean;
        lp public.lot_payments; st public.sale_terms; c jsonb; p jsonb; m jsonb; v_price boolean; v_in numeric; pu public.packing_units;
        pk record; v_mill boolean; v_buyer text;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null then return null; end if;
  select * into fa from public.farmers where id = f.farmer_id;
  select * into q from public.qc_verdicts where footprint_id = f.id;
  select * into s from public.qr_seals where footprint_id = f.id;
  select * into st from public.sale_terms where footprint_id = f.id;
  select coalesce(sc.record_price, false) into v_price from public.scopes sc where sc.id = f.scope_id;
  v_lab := app.qc_lab(f.id);
  c := coalesce(app.live_computed(f), '{}'::jsonb); p := coalesce(f.payload, '{}'::jsonb); m := app.record_parts(f);
  v_entry := f.stage_type in ('procurement', 'lot_inward');
  v_mill := f.stage_type = 'milling';
  v_in := nullif(f.qty_in, 0);
  select * into pu from public.packing_units u where u.id::text = p->>'packing_unit_id';
  select coalesce(b.name, app.exp_txt(c, 'buyer'), app.exp_txt(p, 'buyer')) into v_buyer
    from (select 1) x left join public.buyers b on b.id::text = p->>'buyer_id';
  select count(*) filter (where k.status <> 'void') as n, min(k.serial) as first, max(k.serial) as last,
         min(k.best_before) filter (where k.status <> 'void') as bb,
         count(*) filter (where k.status <> 'void' and k.best_before is null) as no_bb,
         (select string_agg(x.n || ' × ' || x.label, ', ' order by x.size desc, x.label)
            from (select count(*) as n, coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg') as label,
                         max(k2.size_kg) as size
                    from public.packs k2 left join public.pack_skus sk on sk.id = k2.sku_id
                   where k2.footprint_id = f.id and k2.status <> 'void'
                   group by coalesce(app.sku_name(sk), rtrim(to_char(k2.size_kg, 'FM999999990.###'), '.') || ' kg')) x) as by_size
    into pk from public.packs k where k.footprint_id = f.id;
  -- when, who, how much
  r := jsonb_build_object(
    'code', f.footprint_code, 'stage', f.stage_type, 'status', f.status, 'happened_on', f.happened_on,
    'recorded_at', to_char(coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'verified_at', to_char(f.verified_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'recorded_by', (select u.display_name from public.app_users u where u.id = f.created_by),
    'verified_by', (select u.display_name from public.app_users u where u.id = f.verified_by),
    'same_person', case when f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by then 'yes' end,
    'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out);
  -- E2.2: the by-products in kg and as a % of the input, each its own column; the floor loss without them
  r := r || jsonb_build_object(
    'head_rice_kg', case when v_mill then c->'head_rice_kg' end,
    'head_rice_pct', case when v_mill and c ? 'head_rice_kg' then round((c->>'head_rice_kg')::numeric / v_in * 100, 1) end,
    'broken_kg', case when v_mill then c->'broken_kg' end,
    'broken_pct', case when v_mill and c ? 'broken_kg' then round((c->>'broken_kg')::numeric / v_in * 100, 1) end,
    'husk_kg', case when v_mill then c->'husk_kg' end,
    'husk_pct', case when v_mill and c ? 'husk_kg' then round((c->>'husk_kg')::numeric / v_in * 100, 1) end,
    'bran_kg', case when v_mill then c->'bran_kg' end,
    'bran_pct', case when v_mill and c ? 'bran_kg' then round((c->>'bran_kg')::numeric / v_in * 100, 1) end,
    'recovery_pct', case when v_mill then coalesce(c->'recovery_pct', c->'yield_pct') end,
    'reject_kg', case when f.stage_type in ('sorting', 'grading') then c->'reject_kg' end,
    'foreign_matter_kg', case when f.stage_type = 'cleaning' then c->'foreign_matter_kg' end,
    'sample_kg', case when f.stage_type = 'qc' then c->'sample_qty_kg' end,
    'water_removed_kg', case when f.stage_type = 'drying' then c->'water_removed_kg' end,
    'floor_loss_kg', case when not (v_entry or f.is_grade_lot) then (m->>'floor_loss')::numeric end,
    'floor_loss_pct', case when not (v_entry or f.is_grade_lot) then round((m->>'floor_loss')::numeric / v_in * 100, 2) end,
    'transit_loss_kg', case when c ? 'transit_loss_kg' then c->'transit_loss_kg' end);
  -- where it came from: the farm or the source, the share, GI, the bags and the moisture readings
  r := r || jsonb_build_object(
    'farmer_code', fa.farmer_code, 'village', fa.village, 'district', fa.district,
    'share_pct', case when p_share is not null then round(p_share * 100, 1) end,
    'gi_status', case when v_entry then app.entry_gi(f.id) end,
    'farm_verified', case f.stage_type when 'procurement' then 'yes' when 'lot_inward' then 'no' end,
    'source_type', case when f.stage_type = 'lot_inward' then app.exp_txt(p, 'source_type') end,
    'source_name', case when f.stage_type = 'lot_inward' then app.exp_txt(p, 'source_name') end,
    'gross_kg', case when f.stage_type = 'procurement' then p->'gross_kg' end,
    'bags', case when f.stage_type in ('procurement', 'village_batch', 'lot_inward') then p->'bags' end,
    'tare_kg_per_bag', case when f.stage_type = 'procurement' then p->'tare_kg_per_bag' end,
    'moisture_readings', case when jsonb_typeof(p->'moisture_pct') = 'array'
                              then (select string_agg(x, ' / ' order by o) from jsonb_array_elements_text(p->'moisture_pct') with ordinality t(x, o)) end,
    'moisture_avg', case when f.stage_type in ('procurement', 'village_batch') then c->'moisture_avg' end,
    'collection_point', case when f.stage_type in ('procurement', 'village_batch') then app.exp_txt(c, 'collection_point') end,
    'harvest_date', app.exp_txt(p, 'harvest_date'), 'condition', app.exp_txt(p, 'condition'),
    'delivered_by', case when f.stage_type = 'procurement' then app.exp_txt(p, 'delivered_by') end,
    'farmers', case when f.stage_type = 'village_batch' then c->'farmers' end,
    -- migration 61b: from the batch's lots, by the village and district as recorded (as the public page counts them)
    'villages', case when f.stage_type = 'village_batch' then
                  (select string_agg(g.village || ' ' || round(g.kg / nullif(f.qty_in, 0) * 100, 1) || ' %', '; ' order by g.kg desc, g.village)
                     from (select fv.village, fv.district, sum(sf.qty_out) as kg
                             from public.footprints sf join public.farmers fv on fv.id = sf.farmer_id
                            where sf.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)
                            group by fv.village, fv.district) g) end);
  -- milling, the lab, packing
  r := r || jsonb_build_object(
    'mill', case when v_mill then app.exp_txt(c, 'mill') end,
    'mill_operator', case when v_mill then app.exp_txt(p, 'mill_operator') end,
    'polish', case when v_mill then app.exp_txt(p, 'polish') end,
    'line_clearance', case when v_mill then app.exp_txt(c, 'line_clearance') end,
    'grade', f.grade, 'qc_domestic', q.domestic_verdict, 'qc_export', q.export_verdict, 'readings', coalesce(q.readings, '{}'::jsonb),
    'sample_code', case when f.stage_type = 'qc' then app.exp_txt(c, 'sample_code') end,
    'lab', v_lab->>'name', 'lab_accreditation', v_lab->>'accreditation_no', 'report_no', v_lab->>'report_no', 'report_date', v_lab->>'report_date',
    'packing_unit', pu.name, 'fssai_licence', pu.fssai_licence,
    'batch_code', coalesce((select string_agg(distinct k.batch_code, ' ') from public.packs k where k.footprint_id = f.id),
                           case when f.stage_type = 'packing' then p->>'batch_code' end),
    'packs', nullif(pk.n, 0), 'packs_by_size', pk.by_size,
    'serials', case when pk.first is not null then pk.first || ' to ' || pk.last end,
    'best_before', case when pk.n > 0 and pk.no_bb > 0 then 'not_recorded' when pk.bb is not null then pk.bb::text end);
  -- the order and the shipment
  r := r || jsonb_build_object(
    'market', case when f.stage_type in ('commercial', 'shipment') then coalesce(app.exp_txt(c, 'market'), app.exp_txt(p, 'market')) end,
    'buyer', case when f.stage_type in ('commercial', 'shipment') then v_buyer end,
    'destination_country', app.exp_txt(p, 'destination_country'), 'order_no', app.exp_txt(p, 'order_no'),
    'incoterms', coalesce(app.exp_txt(p, 'incoterms'), st.incoterms),
    'invoice_no', coalesce(app.exp_txt(p, 'invoice_no'), app.exp_txt(c, 'invoice_no')), 'dispatch_date', app.exp_txt(p, 'dispatch_date'),
    'destination', app.exp_txt(p, 'destination'), 'transporter', app.exp_txt(p, 'transporter'), 'vehicle_no', app.exp_txt(p, 'vehicle_no'),
    'lr_no', app.exp_txt(p, 'lr_no'), 'container_no', app.exp_txt(p, 'container_no'), 'seal_no', app.exp_txt(p, 'seal_no'),
    'vessel', app.exp_txt(p, 'vessel'), 'port_loading', app.exp_txt(p, 'port_loading'), 'port_discharge', app.exp_txt(p, 'port_discharge'),
    'eway_bill_no', app.exp_txt(p, 'eway_bill_no'), 'shipping_bill_no', app.exp_txt(p, 'shipping_bill_no'),
    'bl_no', coalesce(app.exp_txt(c, 'bl_no'), app.exp_txt(p, 'bl_no')));
  -- the seal and the record's integrity
  r := r || jsonb_build_object(
    'qr_code', s.qr_code, 'sealed_at', to_char(s.sealed_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'open_flags', (select nullif(count(*), 0) from public.flags fl where fl.footprint_id = f.id and fl.status = 'open'),
    'evidence_sha256', (select string_agg(a.sha256, ' ' order by a.created_at) from public.attachments a where a.footprint_id = f.id),
    'ledger_blocks', (select count(*) from public.ledger l where l.footprint_id = f.id),
    'last_block_hash', (select l.hash from public.ledger l where l.footprint_id = f.id order by l.seq desc limit 1),
    'warnings', nullif(array_to_string(f.warnings, ' | '), ''),
    'withdrawn', (select to_char(w.withdrawn_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || ': ' || w.reason
                    from public.withdrawals w where w.footprint_id = f.id),
    'replaces', (select o.footprint_code || ' (' || o.qty_out || ' kg)' || coalesce(': ' || w.reason, '')
                   from public.footprints o left join public.withdrawals w on w.footprint_id = o.id where o.id = f.supersedes_id),
    'lot_closed', case when f.lot_closed then 'yes' end,
    'received_at', to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    -- E2.5: closed as floor loss (the 2 %-or-less rule): its own line in the table
    'closure', (select jsonb_build_object('kg', lc.floor_loss_kg, 'kind', lc.kind, 'at', to_char(lc.closed_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
                         'by', (select u.display_name from public.app_users u where u.id = lc.closed_by), 'reason', lc.reason)
                  from public.lot_closures lc where lc.footprint_id = f.id));
  if p_internal then
    select * into lp from public.lot_payments where footprint_id = f.id;
    r := r || jsonb_build_object(
      'farmer_name', fa.name,
      'agent_name', case when f.stage_type = 'procurement' then app.exp_txt(p, 'agent_name') end,
      'driver_phone', app.exp_txt(p, 'driver_phone'),
      -- C1.3: the raw values; without their prices where the scope does not record prices
      'raw_values', case when v_price then p else coalesce((select jsonb_object_agg(e.k, e.v) from jsonb_each(p) e(k, v)
                                                             where e.k !~ '^(price|payment|txn|total_value|currency|amount|rate)'), '{}'::jsonb) end);
    if v_price then
      r := r || jsonb_build_object(
        'price_per_quintal', coalesce(lp.price_per_quintal, (p->>'price_per_quintal')::numeric),
        'payment_status', coalesce(lp.status, app.exp_txt(p, 'payment_status')), 'payment_ref', coalesce(lp.txn_ref, app.exp_txt(p, 'txn_ref')),
        'price_per_kg', coalesce(st.price_per_kg, case when f.stage_type = 'commercial' then (p->>'price_per_kg')::numeric end),
        'currency', coalesce(st.currency, case when f.stage_type = 'commercial' then app.exp_txt(p, 'currency') end),
        'total_value', st.total_value);
    end if;
  end if;
  return r;
end $function$;
CREATE OR REPLACE FUNCTION app.export_table(p_ids uuid[], p_internal boolean, p_shares jsonb, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare recs jsonb[]; rkeys text[]; keys text[]; keep text[]; lines jsonb[] := '{}'; rows jsonb := '[]'::jsonb; r jsonb; i int := 0; one jsonb;
        core constant text[] := array['step', 'code', 'stage', 'status', 'recorded_at', 'qty_in_kg', 'qty_out_kg', 'floor_loss_kg'];
begin
  select coalesce(array_agg(app.export_record(u.id, p_internal, (p_shares->>u.id::text)::numeric) order by u.ord), '{}')
    into recs from unnest(coalesce(p_ids, '{}'::uuid[])) with ordinality u(id, ord);
  select coalesce(array_agg(distinct k order by k), '{}') into rkeys
    from unnest(recs) x, jsonb_object_keys(coalesce(x->'readings', '{}'::jsonb)) k;
  keys := array['step', 'code', 'stage', 'status', 'happened_on', 'recorded_at', 'verified_at', 'recorded_by', 'verified_by', 'same_person',
                'qty_in_kg', 'qty_out_kg', 'head_rice_kg', 'head_rice_pct', 'broken_kg', 'broken_pct', 'husk_kg', 'husk_pct', 'bran_kg', 'bran_pct',
                'recovery_pct', 'reject_kg', 'foreign_matter_kg', 'sample_kg', 'water_removed_kg', 'floor_loss_kg', 'floor_loss_pct', 'transit_loss_kg', 'written_off_kg',
                'note', 'farmer_code', 'farmer_name', 'village', 'district', 'share_pct', 'gi_status', 'farm_verified', 'source_type', 'source_name',
                'gross_kg', 'bags', 'tare_kg_per_bag', 'moisture_readings', 'moisture_avg', 'collection_point', 'harvest_date', 'condition',
                'delivered_by', 'agent_name', 'farmers', 'villages', 'mill', 'mill_operator', 'polish', 'line_clearance',
                'grade', 'qc_domestic', 'qc_export']::text[]
       || array(select 'r:' || k from unnest(rkeys) k)
       || array['sample_code', 'lab', 'lab_accreditation', 'report_no', 'report_date', 'packing_unit', 'fssai_licence', 'batch_code', 'packs',
                'packs_by_size', 'serials', 'best_before', 'market', 'buyer', 'destination_country', 'order_no', 'incoterms', 'price_per_quintal',
                'payment_status', 'payment_ref', 'price_per_kg', 'currency', 'total_value', 'invoice_no', 'dispatch_date', 'destination',
                'transporter', 'vehicle_no', 'driver_phone', 'lr_no', 'container_no', 'seal_no', 'vessel', 'port_loading', 'port_discharge',
                'eway_bill_no', 'shipping_bill_no', 'bl_no', 'qr_code', 'sealed_at', 'open_flags', 'evidence_sha256', 'ledger_blocks',
                'last_block_hash', 'warnings', 'withdrawn', 'replaces', 'lot_closed', 'received_at', 'data_note', 'raw_values']::text[];
  if not p_internal then   -- never a column of the shareable copy, whatever a record holds
    keys := array(select k from unnest(keys) with ordinality t(k, o)
                   where k not in ('farmer_name', 'agent_name', 'driver_phone', 'price_per_quintal', 'payment_status', 'payment_ref',
                                   'price_per_kg', 'currency', 'total_value', 'raw_values') order by o);
  end if;
  foreach r in array recs loop
    i := i + 1;
    lines := array_append(lines, (r - 'readings' - 'closure')
               || coalesce((select jsonb_object_agg('r:' || e.k, e.v) from jsonb_each(coalesce(r->'readings', '{}'::jsonb)) e(k, v)), '{}'::jsonb)
               || jsonb_build_object('step', i, 'data_note', p_note));
    if jsonb_typeof(r->'closure') = 'object' then
      -- migration 63: a write-off at the scope's close is its own kind of line, its kilograms in their own column
      lines := array_append(lines, jsonb_build_object('code', r->'code',
                 'stage', case when r->'closure'->>'kind' = 'written_off' then 'written_off' else 'floor_loss_closure' end, 'status', 'closed',
                 'recorded_at', r->'closure'->'at', 'recorded_by', r->'closure'->'by',
                 case when r->'closure'->>'kind' = 'written_off' then 'written_off_kg' else 'floor_loss_kg' end, r->'closure'->'kg',
                 'note', r->'closure'->'reason', 'data_note', p_note));
    end if;
  end loop;
  keep := array(select k from unnest(keys) with ordinality t(k, o)
                 where k = any(core) or exists (select 1 from unnest(lines) l where nullif(l->>k, '') is not null) order by o);
  foreach r in array lines loop
    select jsonb_agg(r->k order by o) into one from unnest(keep) with ordinality t(k, o);
    rows := rows || jsonb_build_array(one);
  end loop;
  return jsonb_build_object('columns', to_jsonb(keep), 'rows', rows);
end $function$;
CREATE OR REPLACE FUNCTION app.lot_trace(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_scope uuid; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501';
  end if;

  with recursive up(id, depth) as (
      select p_fp, 0
    union
      select par.id, up.depth + 1
        from up join public.footprints f on f.id = up.id
        cross join lateral (
          select f.prev_footprint_id as id where f.prev_footprint_id is not null
          union
          select (x)::uuid from jsonb_array_elements_text(
            case when f.stage_type = 'village_batch' then coalesce(f.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x
        ) par
       where up.depth < 64
  )
  select jsonb_agg(jsonb_build_object(
           'id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'stage_label', sd.label, 'status', f.status,
           'prev_id', f.prev_footprint_id, 'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out, 'grade', f.grade,
           'payload', f.payload, 'computed', app.live_computed(f), 'warnings', to_jsonb(f.warnings),          -- migration 59 (A4)
           'lab', app.qc_lab(f.id),                                                                            -- migration 59 (A5)
           'same_person', f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by,
           'parts', app.record_parts(f),                                                                     -- migration 61 (E2.2)
           'closure', (select jsonb_build_object('kg', lc.floor_loss_kg, 'kind', lc.kind, 'at', lc.closed_at, 'reason', lc.reason,   -- migrations 61, 63
                          'by', (select u.display_name from public.app_users u where u.id = lc.closed_by))
                         from public.lot_closures lc where lc.footprint_id = f.id),
           'farmer', case when fa.id is null then null else jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village) end,
           'created_at', f.created_at, 'captured_at', coalesce(f.captured_at, f.created_at), 'created_by', cu.display_name,
           'verified_at', f.verified_at, 'verified_by', vu.display_name,
           'qc', (select jsonb_build_object('domestic', q.domestic_verdict, 'export', q.export_verdict, 'readings', q.readings, 'override', q.override)
                    from public.qc_verdicts q where q.footprint_id = f.id),
           'seal', (select jsonb_build_object('qr_code', s.qr_code, 'sealed_at', s.sealed_at, 'ledger_hash', s.ledger_hash, 'batch_codes', to_jsonb(s.batch_codes))
                      from public.qr_seals s where s.footprint_id = f.id),
           'withdrawn', (select jsonb_build_object('reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                           from public.withdrawals w left join public.app_users wu on wu.id = w.withdrawn_by where w.footprint_id = f.id),
           'replaces', (select jsonb_build_object('code', o.footprint_code, 'qty_out_kg', o.qty_out, 'reason', w.reason, 'by', wu.display_name, 'at', w.withdrawn_at)
                          from public.footprints o left join public.withdrawals w on w.footprint_id = o.id
                          left join public.app_users wu on wu.id = w.withdrawn_by where o.id = f.supersedes_id),
           'flags', coalesce((select jsonb_agg(jsonb_build_object('text', fl.text, 'status', fl.status, 'at', fl.created_at) order by fl.created_at)
                                from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
           'evidence', coalesce((select jsonb_agg(jsonb_build_object('kind', a.kind, 'sha256', a.sha256, 'at', a.created_at) order by a.created_at)
                                   from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
           'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash, 'at', l.created_at) order by l.seq)
                                 from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
         ) order by f.created_at, f.footprint_code)
    into steps
    from (select distinct id from up) u
    join public.footprints f on f.id = u.id
    left join public.stage_definitions sd on sd.stage_type = f.stage_type
    left join public.farmers fa on fa.id = f.farmer_id
    left join public.app_users cu on cu.id = f.created_by
    left join public.app_users vu on vu.id = f.verified_by;

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb),
    'units', app.param_units(v_scope),                                                                    -- migration 59 (A3)
    'data_note', (select s.data_note from public.scopes s where s.id = v_scope),                          -- migration 59 (A8)
    'scope', app.export_scope_head(v_scope));                                                             -- migration 61 (C4)
end$function$;

-- =====================================================================================================================
-- 10 · the API: closed by hand, opened by name
-- =====================================================================================================================
revoke execute on function app.sm_of_scope(uuid), app.may_report_internal(uuid), app.close_reason_ok(text), app.close_answer(jsonb, text, text),
  app.close_checklist_of(uuid, jsonb), app.close_checklist(uuid, jsonb), app.close_answers(jsonb), app.request_close(uuid, jsonb, text),
  app.decide_close_request(uuid, text), app.confirm_close(uuid), app.reopen_scope(uuid, text), app.awaits_pod(uuid), app.closed_scope_guard(),
  app.season_report_data(uuid, boolean), app.closure_summary(uuid), app.issue_report(uuid, boolean, uuid), app.generate_interim_report(uuid),
  app.report_head(public.reports), app.report_content(uuid, text), app.may_write_report_file(uuid), app.may_read_report_file(text), app.may_write_report_object(text),
  app.register_report_file(uuid, text, text, text, text, bigint), app.note_report_download(uuid, text, text, text), app.scope_reports(uuid),
  app.scope_close_state(uuid), app.withdraw_report(uuid, text), app.public_document(text), app.reports_issued(integer)
  from public, anon, authenticated;
grant execute on function app.close_checklist(uuid, jsonb), app.request_close(uuid, jsonb, text), app.decide_close_request(uuid, text),
  app.confirm_close(uuid), app.reopen_scope(uuid, text), app.generate_interim_report(uuid), app.report_content(uuid, text),
  app.register_report_file(uuid, text, text, text, text, bigint), app.note_report_download(uuid, text, text, text), app.scope_reports(uuid),
  app.scope_close_state(uuid), app.withdraw_report(uuid, text), app.public_document(text), app.reports_issued(integer)
  to authenticated;
grant execute on function app.public_document(text) to anon;
-- the store's rules ask these for the signed-in person
grant execute on function app.may_read_report_file(text), app.may_write_report_object(text) to authenticated;
