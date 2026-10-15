-- GrainVeda MVP · migration 50: packs, proof and blocks (the operator-stages brief, release 3; decision G19).
-- Veda, 15 October 2026, "ok complete everything". This release (docs/FIX_LIST.md item 45):
--   G1      The batch code is the system's: TCUP-KNM-KH26-B0001 (client, crop, season, a number that never repeats). The
--           packing form no longer asks for it; codes typed before are kept (a repeated one is reported, not changed).
--   G8, D   One serial per pack (the batch code and a number), made by the packing save from its packs; labels = packs,
--           printed as a PDF from the browser; a reprint needs a reason; a pack can be voided with a reason; both logged.
--           Best-before = the date packed + the crop's shelf life.
--   G9/G10  Release (the QR stage) after a summary the person reads and confirms; its status Active, Under investigation
--   C9      or Recalled (with a reason, by the Client Manager or the State Manager); a recall shows on every pack.
--   D       A pack scanned before release says "Packed, not yet released". The public page shows no farmer names (the
--           district, the village and the season), the packs' dates and the release status. Every scan is counted
--           (time and code; no personal data; a fair-use cap per code and minute against bots).
--   C5      Lab proof: a lab record names the lab, the report number and its date; the report file is attached before it
--           is verified. The report's date is not in the future nor before the lot; a report number is used once per lab
--           unless the lots share the sample. (A scope can be set not to ask: the demo scopes.)
--   Blocks  GI and non-GI lots are not batched together; an export release by the Client Manager needs the client's
--           written acceptance attached; the public page never says "export passed" for it.
--   G12     Transit loss is recorded at delivery (app.confirm_delivery, the proof of delivery attached for export), not at
--           dispatch.
-- Additive only: no record is changed; packs, batch registrations and release statuses are new rows.
select set_config('app.change_path', 'migration 50', true);

alter type public.ledger_event add value if not exists 'delivery';

-- ---------------------------------------------------------------------------------------------------------------------
-- Settings: a scope asks for the lab report (the default); a crop's shelf life
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.scopes add column if not exists qc_report_required boolean not null default true;
alter table public.crops add column if not exists shelf_life_days int;
alter table public.crops add constraint crops_shelf_life_days_range check (shelf_life_days is null or shelf_life_days between 1 and 3650);
alter table public.attachments add column if not exists label text;
alter table public.attachments add constraint attachments_label_shape check (label is null or label in ('lab_report', 'acceptance', 'pod', 'loading_photo', 'document'));

-- Whether a scope asks for the lab report is set before activation, like its place and tolerances (an owner's
-- correction through the door can still change it).
create or replace function app.scopes_qc_report_frozen() returns trigger
language plpgsql security invoker set search_path = public as $$
begin
  if old.status <> 'draft' and new.qc_report_required is distinct from old.qc_report_required and current_user in ('authenticated', 'anon') then
    raise exception 'whether the lab report is asked is set before the scope is activated' using errcode = '42501'; end if;
  return new;
end $$;
drop trigger if exists scopes_a5_qc_report on public.scopes;
create trigger scopes_a5_qc_report before update of qc_report_required on public.scopes for each row execute function app.scopes_qc_report_frozen();

-- What the stage forms ask (the same edits are in seed 01, for a database built from nothing)
update public.stage_definitions set form_schema = (select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
                                                     from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'batch_code')
 where stage_type = 'packing';
update public.stage_definitions set form_schema = (select coalesce(jsonb_agg(x order by n), '[]'::jsonb)
                                                     from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'transit_loss_kg')
 where stage_type = 'shipment';
update public.stage_definitions set form_schema = form_schema || '[
  {"key": "lab_name", "type": "text", "label": "Lab", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "report_no", "type": "text", "label": "Report number", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "report_date", "type": "date", "label": "Report date", "section": "lab", "required": false, "required_when": "qc_report_required"},
  {"key": "sample_id", "type": "text", "label": "Sample ID", "section": "lab", "required": false},
  {"key": "report_file", "type": "attachment", "label": "Lab report (PDF or photo)", "accept": "document", "section": "lab", "required": false, "required_when": "qc_report_required", "label_as": "lab_report"}
]'::jsonb
 where stage_type = 'qc' and not (form_schema @> '[{"key": "report_no"}]');

-- ---------------------------------------------------------------------------------------------------------------------
-- G1 · batch codes from the system
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.batch_code_counters (series text primary key, last_seq int not null default 0);
alter table public.batch_code_counters enable row level security;
revoke all on public.batch_code_counters from anon, authenticated;

create or replace function app.next_batch_code(p_scope uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_series text; v_seq int;
begin
  select format('%s-%s-%s', c.code, cr.code, s.season_code) into v_series
    from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id where s.id = p_scope;
  insert into public.batch_code_counters as k (series, last_seq) values (v_series, 1)
  on conflict (series) do update set last_seq = k.last_seq + 1 returning k.last_seq into v_seq;
  return v_series || '-B' || app.pad_seq(v_seq);
end $$;

create table if not exists public.pack_batches (
  batch_code   text primary key,
  footprint_id uuid not null unique references public.footprints(id),
  scope_id     uuid not null references public.scopes(id),
  last_serial  int not null default 0,
  typed        boolean not null default false,          -- a code typed before migration 50
  created_at   timestamptz not null default now()
);
alter table public.pack_batches enable row level security;
revoke all on public.pack_batches from anon, authenticated;
grant select on public.pack_batches to authenticated;
drop policy if exists pack_batches_read on public.pack_batches;
create policy pack_batches_read on public.pack_batches for select to authenticated using (app.can_access_scope(scope_id));
drop trigger if exists zz_change_log on public.pack_batches;
create trigger zz_change_log after insert or update or delete on public.pack_batches for each row execute function app.log_change('batch_code');

-- A packing record gets its code from the system (a person's typed code is replaced); a correction keeps it.
create or replace function app.footprints_batch_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage_type <> 'packing' then return new; end if;
  if tg_op = 'INSERT' then
    if auth.uid() is not null or coalesce(btrim(new.payload->>'batch_code'), '') = '' then
      new.payload := coalesce(new.payload, '{}'::jsonb) || jsonb_build_object('batch_code', app.next_batch_code(new.scope_id));
    end if;
  elsif new.payload->>'batch_code' is distinct from old.payload->>'batch_code' then
    new.payload := new.payload || jsonb_build_object('batch_code', old.payload->>'batch_code');
  end if;
  return new;
end $$;
drop trigger if exists footprints_a1_batch_code on public.footprints;
create trigger footprints_a1_batch_code before insert or update of payload on public.footprints
  for each row execute function app.footprints_batch_code();

-- ---------------------------------------------------------------------------------------------------------------------
-- G8 / D · one serial per pack
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.packs (
  serial       text primary key,
  batch_code   text not null references public.pack_batches(batch_code),
  footprint_id uuid not null references public.footprints(id),        -- the packing record
  scope_id     uuid not null references public.scopes(id),
  size_kg      numeric(10,3) not null check (size_kg > 0),
  packed_on    date not null,
  best_before  date,
  status       text not null default 'packed' check (status in ('packed', 'void')),
  void_reason  text,
  voided_by    uuid references public.app_users(id),
  voided_at    timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists packs_footprint on public.packs (footprint_id);
alter table public.packs enable row level security;
revoke all on public.packs from anon, authenticated;
grant select on public.packs to authenticated;
drop policy if exists packs_read on public.packs;
create policy packs_read on public.packs for select to authenticated using (app.can_see_footprint(scope_id, 'packing'));
drop trigger if exists zz_change_log on public.packs;
create trigger zz_change_log after insert or update or delete on public.packs for each row execute function app.log_change('serial');

create table if not exists public.label_prints (
  id           uuid primary key default gen_random_uuid(),
  footprint_id uuid not null references public.footprints(id),
  labels       int not null check (labels >= 0),
  reprint      boolean not null,
  reason       text,
  printed_by   uuid not null references public.app_users(id),
  printed_at   timestamptz not null default now()
);
alter table public.label_prints enable row level security;
revoke all on public.label_prints from anon, authenticated;
drop trigger if exists zz_change_log on public.label_prints;
create trigger zz_change_log after insert or update or delete on public.label_prints for each row execute function app.log_change('id');

-- The packs of a packing record, from its packets [{units, size_kg}]: new serials; the earlier ones of a corrected or
-- withdrawn record are voided (never deleted).
create or replace function app.make_packs(p_fp uuid, p_reason text) returns int
language plpgsql security definer set search_path = public as $$
declare f public.footprints; pk jsonb; i int; n int := 0; v_on date; v_bb date; v_shelf int; b public.pack_batches; v_total int;
begin
  select * into f from public.footprints where id = p_fp;
  update public.packs set status = 'void', void_reason = coalesce(p_reason, 'record corrected'), voided_by = app.current_user_id(), voided_at = now()
   where footprint_id = f.id and status = 'packed';
  if f.status = 'superseded' then return 0; end if;
  insert into public.pack_batches (batch_code, footprint_id, scope_id) values (f.payload->>'batch_code', f.id, f.scope_id)
  on conflict (batch_code) do nothing;
  select * into b from public.pack_batches where footprint_id = f.id;
  if b.batch_code is null then return 0; end if;                    -- a typed code that another record already carries
  select coalesce(sum((x->>'units')::int), 0) into v_total from jsonb_array_elements(coalesce(f.payload->'packets', '[]'::jsonb)) x;
  if v_total > 20000 then raise exception 'at most 20000 packs in one packing record (% given)', v_total using errcode = '23514'; end if;
  v_on := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  select cr.shelf_life_days into v_shelf from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = f.scope_id;
  v_bb := case when v_shelf is null then null else v_on + v_shelf end;
  for pk in select x from jsonb_array_elements(coalesce(f.payload->'packets', '[]'::jsonb)) x loop
    for i in 1 .. coalesce((pk->>'units')::int, 0) loop
      update public.pack_batches set last_serial = last_serial + 1 where batch_code = b.batch_code returning * into b;
      insert into public.packs (serial, batch_code, footprint_id, scope_id, size_kg, packed_on, best_before)
      values (b.batch_code || '-' || lpad(b.last_serial::text, greatest(4, length(b.last_serial::text)), '0'), b.batch_code, f.id, f.scope_id,
              (pk->>'size_kg')::numeric, v_on, v_bb);
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

create or replace function app.footprints_packs() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.stage_type <> 'packing' then return new; end if;
  if tg_op = 'INSERT' then perform app.make_packs(new.id, null);
  elsif new.status = 'superseded' and old.status <> 'superseded' then perform app.make_packs(new.id, 'record withdrawn');
  elsif new.payload->'packets' is distinct from old.payload->'packets' or new.happened_on is distinct from old.happened_on then
    perform app.make_packs(new.id, 'record corrected');
  end if;
  return new;
end $$;
drop trigger if exists footprints_z5_packs on public.footprints;
create trigger footprints_z5_packs after insert or update on public.footprints for each row execute function app.footprints_packs();

-- Packing records already there: their typed batch codes registered (the first of a repeated code), their packs made.
do $$
declare f record;
begin
  for f in select id, payload->>'batch_code' as code, scope_id from public.footprints
            where stage_type = 'packing' and status not in ('superseded', 'legacy') and coalesce(payload->>'batch_code', '') <> '' order by created_at loop
    insert into public.pack_batches (batch_code, footprint_id, scope_id, typed) values (f.code, f.id, f.scope_id, true) on conflict do nothing;
    if exists (select 1 from public.pack_batches where footprint_id = f.id) then perform app.make_packs(f.id, null); end if;
  end loop;
end $$;


-- Labels = packs: the serials of a packing record for printing. The first print needs no reason; a reprint does.
create or replace function app.print_labels(p_fp uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; v_re boolean; v_n int; sc public.scopes; cr public.crops; cl public.clients;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) or f.stage_type <> 'packing' then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.is_my_stage(me, f.scope_id, 'packing') then
    raise exception 'labels are printed at Packing (or by a manager of this scope)' using errcode = '42501'; end if;
  v_re := exists (select 1 from public.label_prints where footprint_id = f.id);
  if v_re and length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception 'these labels were printed before: say why they are printed again' using errcode = '23514'; end if;
  select count(*) into v_n from public.packs where footprint_id = f.id and status = 'packed';
  insert into public.label_prints (footprint_id, labels, reprint, reason, printed_by) values (f.id, v_n, v_re, nullif(btrim(coalesce(p_reason, '')), ''), me);
  perform app.audit(case when v_re then 'labels_reprinted' else 'labels_printed' end, f.id,
    jsonb_build_object('record', f.footprint_code, 'labels', v_n, 'reason', nullif(btrim(coalesce(p_reason, '')), '')), v_re);
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  select * into cl from public.clients where id = sc.client_id;
  return jsonb_build_object('batch_code', f.payload->>'batch_code', 'crop', cr.name, 'gi_tag', cr.gi_tag, 'gi_status', app.lot_gi_status(f.id),
    'season', sc.season_code, 'geography', sc.geography, 'client', cl.name, 'reprint', v_re,
    'packs', coalesce((select jsonb_agg(jsonb_build_object('serial', p.serial, 'size_kg', p.size_kg, 'packed_on', p.packed_on, 'best_before', p.best_before)
                         order by p.serial) from public.packs p where p.footprint_id = f.id and p.status = 'packed'), '[]'::jsonb));
end $$;

-- A pack is voided (torn label, a pack opened) with a reason; never deleted.
create or replace function app.void_pack(p_serial text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); p public.packs;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null or me is null or not app.can_see_footprint(p.scope_id, 'packing') then raise exception 'pack not found' using errcode = 'P0002'; end if;
  if not app.is_my_stage(me, p.scope_id, 'packing') then raise exception 'a pack is voided at Packing (or by a manager of this scope)' using errcode = '42501'; end if;
  if p.status = 'void' then raise exception 'this pack is void already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'say why the pack is void (at least 10 characters)' using errcode = '23514'; end if;
  update public.packs set status = 'void', void_reason = left(btrim(p_reason), 300), voided_by = me, voided_at = now() where serial = p.serial returning * into p;
  perform app.audit('pack_voided', p.footprint_id, jsonb_build_object('serial', p.serial, 'reason', p.void_reason), true);
  return to_jsonb(p);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C9 · Release: a summary first, then the seal; a status afterwards
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.release_events (
  id          uuid primary key default gen_random_uuid(),
  seq         bigserial,                               -- the order of events within one transaction
  seal_id     uuid not null references public.qr_seals(footprint_id),
  status      text not null check (status in ('active', 'under_investigation', 'recalled')),
  reason      text,
  by_user     uuid references public.app_users(id),
  at          timestamptz not null default now()
);
create index if not exists release_events_seal on public.release_events (seal_id, seq desc);
alter table public.release_events enable row level security;
revoke all on public.release_events from anon, authenticated;
drop trigger if exists zz_change_log on public.release_events;
create trigger zz_change_log after insert or update or delete on public.release_events for each row execute function app.log_change('id');

create or replace function app.release_status(p_seal uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('status', e.status, 'reason', e.reason, 'at', e.at,
                     'by', (select display_name from public.app_users where id = e.by_user))
                     from public.release_events e where e.seal_id = p_seal order by e.seq desc limit 1),
                  jsonb_build_object('status', 'active')) $$;

create or replace function app.qr_seals_release() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.release_events (seal_id, status, by_user) values (new.footprint_id, 'active', new.sealed_by);
  return new;
end $$;
drop trigger if exists qr_seals_z1_release on public.qr_seals;
create trigger qr_seals_z1_release after insert on public.qr_seals for each row execute function app.qr_seals_release();
insert into public.release_events (seal_id, status, by_user, at)
select q.footprint_id, 'active', q.sealed_by, q.sealed_at from public.qr_seals q
 where not exists (select 1 from public.release_events e where e.seal_id = q.footprint_id);

-- The packing records in a lot (walking its sources), and the seals downstream of a packing record.
create or replace function app.lot_packings(p_fp uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  with recursive up(id, depth) as (select p_fp, 0 union all
    select l.parent_id, u.depth + 1 from up u join public.footprint_links l on l.child_id = u.id where u.depth < 64)
  select distinct u.id from up u join public.footprints f on f.id = u.id where f.stage_type = 'packing' $$;
create or replace function app.packing_seals(p_packing uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  with recursive down(id, depth) as (select p_packing, 0 union all
    select l.child_id, d.depth + 1 from down d join public.footprint_links l on l.parent_id = d.id
      join public.footprints c on c.id = l.child_id and c.status not in ('superseded', 'legacy') where d.depth < 64)
  select distinct q.footprint_id from down d join public.qr_seals q on q.footprint_id = d.id $$;

-- What the person releasing reads before he confirms (G9: no one-click seal).
create or replace function app.release_preview(p_source uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; cur public.footprints; hops int := 0; out jsonb := '[]'::jsonb; v_unver text; v_flags text; vd record;
  v_market text; v_docs text[]; v_have int; sc public.scopes; cr public.crops;
begin
  select * into f from public.footprints where id = p_source;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id; select * into cr from public.crops where id = sc.crop_id;
  cur := f;
  loop
    if cur.status <> 'verified' then v_unver := concat_ws(', ', v_unver, cur.footprint_code); end if;
    if exists (select 1 from public.flags fl where fl.footprint_id = cur.id and fl.status = 'open') then v_flags := concat_ws(', ', v_flags, cur.footprint_code); end if;
    if cur.stage_type = 'commercial' then v_market := cur.payload->>'market'; end if;
    exit when cur.prev_footprint_id is null or hops > 64;
    select * into cur from public.footprints where id = cur.prev_footprint_id; hops := hops + 1;
  end loop;
  select * into vd from app.resolve_market_verdict(f.id);
  out := out || jsonb_build_array(jsonb_build_object('key', 'all_verified', 'ok', v_unver is null, 'vars', jsonb_build_object('codes', coalesce(v_unver, ''))));
  out := out || jsonb_build_array(jsonb_build_object('key', 'no_open_flags_chain', 'ok', v_flags is null, 'vars', jsonb_build_object('codes', coalesce(v_flags, ''))));
  out := out || jsonb_build_array(jsonb_build_object('key', 'lab_verdict', 'ok', not (vd.domestic = 'pending' and vd.export = 'pending'),
           'vars', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'released', vd.override is not null)));
  out := out || jsonb_build_array(jsonb_build_object('key', 'gi', 'ok', true, 'vars', jsonb_build_object('status', app.lot_gi_status(f.id))));
  out := out || jsonb_build_array(jsonb_build_object('key', 'farmers', 'ok', true, 'vars', jsonb_build_object('n',
           (select count(distinct e.farmer_id) from app.lot_sources(f.id) s join public.footprints e on e.id = s.entry_id))));
  out := out || jsonb_build_array(jsonb_build_object('key', 'packs', 'ok', true, 'vars', jsonb_build_object(
           'batches', coalesce((select string_agg(pb.batch_code, ', ') from app.lot_packings(f.id) x join public.pack_batches pb on pb.footprint_id = x), ''),
           'n', (select count(*) from public.packs p where p.footprint_id in (select app.lot_packings(f.id)) and p.status = 'packed'))));
  if v_market = 'export' then
    v_docs := coalesce(cr.export_docs, '{}');
    select count(*) into v_have from public.attachments a where a.footprint_id = f.id;
    out := out || jsonb_build_array(jsonb_build_object('key', 'export_documents', 'ok', v_have >= greatest(cardinality(v_docs), 1),
             'vars', jsonb_build_object('n', v_have, 'm', greatest(cardinality(v_docs), 1), 'docs', array_to_string(v_docs, ', '))));
  end if;
  return jsonb_build_object('checks', out, 'ready', not exists (select 1 from jsonb_array_elements(out) c where not (c->>'ok')::boolean),
    'source', jsonb_build_object('code', f.footprint_code, 'stage', f.stage_type, 'kg', app.available_qty(f.id)), 'market', v_market);
end $$;

-- Active / Under investigation / Recalled, with a reason, by the client's Client Manager or the state's State Manager.
create or replace function app.set_release_status(p_seal uuid, p_status text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); q public.qr_seals; f public.footprints; sc public.scopes; v_now text;
begin
  select * into q from public.qr_seals where footprint_id = p_seal;
  select * into f from public.footprints where id = q.footprint_id;
  select * into sc from public.scopes where id = f.scope_id;
  if q.footprint_id is null or me is null or not app.can_access_scope(sc.id) then raise exception 'release not found' using errcode = 'P0002'; end if;
  if not (app.client_account_holder(me, sc.client_id) or exists (select 1 from app.eff_assignments(me) a where a.lens = 'state' and a.state_id = sc.state_id)) then
    raise exception 'the Client Manager of the client (or the State Manager of the state) changes a release''s status' using errcode = '42501'; end if;
  if p_status not in ('active', 'under_investigation', 'recalled') then raise exception 'active, under_investigation or recalled' using errcode = '22023'; end if;
  v_now := app.release_status(q.footprint_id)->>'status';
  if v_now = p_status then raise exception 'the release is % already', replace(p_status, '_', ' ') using errcode = '23514'; end if;
  if v_now = 'recalled' then raise exception 'a recalled release stays recalled' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'say why (at least 10 characters)' using errcode = '23514'; end if;
  insert into public.release_events (seal_id, status, reason, by_user) values (q.footprint_id, p_status, left(btrim(p_reason), 500), me);
  perform app.ledger_append(f.id, f.scope_id, 'supervisory', me, jsonb_build_object('act', 'release_' || p_status, 'footprint_id', f.id,
    'footprint_code', f.footprint_code, 'qr_code', q.qr_code, 'from', v_now, 'to', p_status, 'reason', left(btrim(p_reason), 500)));
  return app.release_status(q.footprint_id);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- D · a pack scanned; every scan counted (no personal data)
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.scans (
  id    bigserial primary key,
  code  text not null check (length(code) <= 80),
  kind  text not null check (kind in ('lot', 'pack')),
  at    timestamptz not null default now()
);
create index if not exists scans_code_at on public.scans (code, at desc);
alter table public.scans enable row level security;
revoke all on public.scans from anon, authenticated;

create or replace function app.record_scan(p_code text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_kind text;
begin
  if p_code is null or length(p_code) > 80 then return; end if;
  v_kind := case when exists (select 1 from public.packs where serial = p_code) then 'pack'
                 when exists (select 1 from public.qr_seals where qr_code = p_code) then 'lot' end;
  if v_kind is null then return; end if;
  -- fair use: a code scanned more than 60 times in a minute is a machine; it is answered, not counted
  if (select count(*) from public.scans where code = p_code and at > now() - interval '1 minute') >= 60 then return; end if;
  insert into public.scans (code, kind) values (p_code, v_kind);
end $$;

-- The public answer for a pack: before release "packed, not yet released"; after it, the lot's journey with the
-- pack's dates and the release's status (a recall on every pack).
create or replace function app.public_pack(p_serial text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.packs; v_seal uuid; q public.qr_seals; sc public.scopes; cr public.crops; v_pack jsonb;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null then return null; end if;
  select * into sc from public.scopes where id = p.scope_id; select * into cr from public.crops where id = sc.crop_id;
  v_pack := jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'size_kg', p.size_kg, 'packed_on', p.packed_on,
              'best_before', p.best_before, 'void', p.status = 'void');
  select s into v_seal from app.packing_seals(p.footprint_id) s limit 1;
  if v_seal is null or p.status = 'void' then
    return jsonb_build_object('pack', v_pack, 'released', false,
      'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code, 'geography', sc.geography,
      'gi_status', app.lot_gi_status(p.footprint_id));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C5 · the lab report, once per lab unless the lots share the sample
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.report_no_taken(p_lab text, p_no text, p_sample text, p_except uuid) returns text
language sql stable security definer set search_path = public as $$
  select f.footprint_code from public.footprints f
   where f.stage_type = 'qc' and f.status not in ('superseded', 'legacy') and f.id is distinct from p_except
     and lower(btrim(f.payload->>'report_no')) = lower(btrim(p_no)) and app.norm_place(f.payload->>'lab_name') is not distinct from app.norm_place(p_lab)
     and (p_sample is null or btrim(p_sample) = '' or coalesce(lower(btrim(f.payload->>'sample_id')), '') <> lower(btrim(p_sample)))
   limit 1 $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- G12 · delivery: what arrived, the transit loss, the proof
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.deliveries (
  shipment_id     uuid primary key references public.footprints(id),
  scope_id        uuid not null references public.scopes(id),
  received_kg     numeric(12,3) not null check (received_kg >= 0),
  transit_loss_kg numeric(12,3) not null check (transit_loss_kg >= 0),
  received_on     date not null,
  note            text,
  confirmed_by    uuid not null references public.app_users(id),
  confirmed_at    timestamptz not null default now()
);
alter table public.deliveries enable row level security;
revoke all on public.deliveries from anon, authenticated;
grant select on public.deliveries to authenticated;
drop policy if exists deliveries_read on public.deliveries;
create policy deliveries_read on public.deliveries for select to authenticated using (app.can_see_footprint(scope_id, 'shipment'));
drop trigger if exists zz_change_log on public.deliveries;
create trigger zz_change_log after insert or update or delete on public.deliveries for each row execute function app.log_change('shipment_id');

create or replace function app.confirm_delivery(p_shipment uuid, p_received_kg numeric, p_received_on date, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; v_market text; d public.deliveries; v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select * into f from public.footprints where id = p_shipment;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, 'shipment') or f.stage_type <> 'shipment' then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.is_my_stage(me, f.scope_id, 'shipment') then raise exception 'the delivery is confirmed at Shipment (or by a manager of this scope)' using errcode = '42501'; end if;
  if f.status not in ('pending', 'verified') then raise exception 'this shipment is %', f.status using errcode = '23514'; end if;
  if exists (select 1 from public.deliveries where shipment_id = f.id) then raise exception 'the delivery is confirmed already' using errcode = '23505'; end if;
  if p_received_kg is null or p_received_kg < 0 or p_received_kg > f.qty_in + app.kg_tolerance() then
    raise exception 'what arrived is between 0 and the % kg shipped', f.qty_in using errcode = '23514'; end if;
  if p_received_on is null or p_received_on > v_today or p_received_on < coalesce(f.happened_on, (f.created_at at time zone 'Asia/Kolkata')::date) then
    raise exception 'the delivery date is between the dispatch and today' using errcode = '23514'; end if;
  select c.payload->>'market' into v_market from public.footprints c where c.id = f.prev_footprint_id;
  if v_market = 'export' and not exists (select 1 from public.attachments a where a.footprint_id = f.id and a.label = 'pod') then
    raise exception 'for export, the proof of delivery is attached first' using errcode = '23514'; end if;
  insert into public.deliveries (shipment_id, scope_id, received_kg, transit_loss_kg, received_on, note, confirmed_by)
  values (f.id, f.scope_id, p_received_kg, greatest(f.qty_in - p_received_kg, 0), p_received_on, nullif(left(btrim(coalesce(p_note, '')), 300), ''), me)
  returning * into d;
  perform app.ledger_append(f.id, f.scope_id, 'delivery', me, jsonb_build_object('act', 'delivered', 'footprint_id', f.id, 'footprint_code', f.footprint_code,
    'received_kg', d.received_kg, 'transit_loss_kg', d.transit_loss_kg, 'received_on', d.received_on, 'note', d.note));
  return to_jsonb(d);
end $$;

-- A file registered with what it is (the lab report, the client's acceptance, the proof of delivery, a loading photo).
create or replace function app.register_labelled_attachment(p_footprint uuid, p_kind public.attachment_kind, p_path text, p_sha256 text, p_label text)
returns public.attachments language plpgsql set search_path = public as $$
declare r public.attachments;
begin
  if p_label is not null and p_label not in ('lab_report', 'acceptance', 'pod', 'loading_photo', 'document') then
    raise exception 'unknown kind of document' using errcode = '22023'; end if;
  r := app.register_attachment(p_footprint, p_kind, p_path, p_sha256);       -- as the caller: the insert's own rules apply
  return app.set_attachment_label(r.id, p_label);
end $$;
-- Only the person who just registered the file names it, once.
create or replace function app.set_attachment_label(p_attachment uuid, p_label text) returns public.attachments
language plpgsql security definer set search_path = public as $$
declare r public.attachments;
begin
  update public.attachments set label = p_label
   where id = p_attachment and uploaded_by = app.current_user_id() and label is null returning * into r;
  if r.id is null then raise exception 'attachment not found' using errcode = 'P0002'; end if;
  return r;
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen50.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- Blocks: GI and non-GI lots are not batched together

CREATE OR REPLACE FUNCTION app.check_new_footprint(p_new footprints)
 RETURNS footprints
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints := p_new; sc public.scopes; def public.stage_definitions; prev public.footprints; src uuid; expected_prev public.stage_type;
begin
  select * into sc from public.scopes where id = f.scope_id;
  if sc.id is null then raise exception 'unknown scope' using errcode = '23503'; end if;
  if sc.status <> 'active' then raise exception 'scope is not active' using errcode = '42501'; end if;
  f.client_id := sc.client_id;                                        -- stamped from the scope, never trusted from the client

  select * into def from public.stage_definitions where stage_type = f.stage_type;
  if def.stage_type is null then raise exception 'unknown stage type %', f.stage_type using errcode = '23514'; end if;
  if app.chain_index(f.scope_id, f.stage_type) is null then
    raise exception 'stage % is not in this scope''s chain', f.stage_type using errcode = '23514'; end if;

  if f.status not in ('pending','legacy') then
    raise exception 'a footprint is created as pending; verification is a separate act' using errcode = '23514'; end if;
  if f.verified_by is not null or f.verified_at is not null then
    raise exception 'verified_by/verified_at are set by verification, not at create' using errcode = '23514'; end if;

  -- Creator must hold the slot (isMyStage) or be a gateway role.
  if not app.is_my_stage(f.created_by, f.scope_id, f.stage_type) then
    raise exception 'user % may not create at stage % in this scope', f.created_by, f.stage_type using errcode = '42501'; end if;

  -- Rule 1 / 2: predecessor coupling.
  if def.is_first then
    if f.prev_footprint_id is not null then raise exception 'first stage has no predecessor' using errcode = '23514'; end if;
  else
    if f.prev_footprint_id is null then raise exception 'prev_footprint_id is required for stage %', f.stage_type using errcode = '23514'; end if;
    select * into prev from public.footprints where id = f.prev_footprint_id;
    if prev.scope_id <> f.scope_id then raise exception 'predecessor must be in the same scope' using errcode = '23514'; end if;
    if prev.lot_closed then raise exception 'predecessor lot is closed' using errcode = '23514'; end if;
    if prev.status in ('superseded','legacy') then raise exception 'predecessor is % and cannot be built on', prev.status using errcode = '23514'; end if;

    if f.is_grade_lot then
      if prev.stage_type <> 'grading' or not prev.split_into_grades or prev.is_grade_lot then
        raise exception 'a grade lot must be coupled to a grading run that was split' using errcode = '23514'; end if;
      if f.created_by <> prev.created_by and not app.manages_scope(f.created_by, f.scope_id) then
        raise exception 'grade lots are created by the grading run''s creator' using errcode = '42501'; end if;
    else
      expected_prev := app.chain_prev(f.scope_id, f.stage_type);
      if prev.stage_type <> expected_prev then
        raise exception 'predecessor of % must be % (got %)', f.stage_type, expected_prev, prev.stage_type using errcode = '23514'; end if;
      if prev.split_into_grades then
        raise exception 'a split grading run is not a source; use its grade lots' using errcode = '23514'; end if;
      if prev.status <> 'verified' then
        raise exception 'predecessor must be verified before the next stage builds on it' using errcode = '23514'; end if;
    end if;
  end if;

  -- Aggregates (village_batch): every source is a verified predecessor-stage lot in this scope.
  if def.aggregates then
    if not (f.payload ? 'source_footprint_ids' and jsonb_typeof(f.payload->'source_footprint_ids') = 'array') then
      raise exception 'village_batch requires payload.source_footprint_ids' using errcode = '23514'; end if;
    for src in select (x)::uuid from jsonb_array_elements_text(f.payload->'source_footprint_ids') x loop
      select * into prev from public.footprints where id = src;
      if prev.id is null or prev.scope_id <> f.scope_id or prev.stage_type <> app.chain_prev(f.scope_id, f.stage_type)
         or prev.status <> 'verified' or prev.lot_closed then
        raise exception 'village_batch source % is not a verified, open predecessor lot in this scope', src using errcode = '23514'; end if;
    end loop;
    if f.prev_footprint_id <> (f.payload->'source_footprint_ids'->>0)::uuid then
      raise exception 'village_batch prev_footprint_id must be the first source' using errcode = '23514'; end if;
    -- migration 50: GI and non-GI lots are kept apart (a lot whose GI is not confirmed may join either)
    if exists (select 1 from jsonb_array_elements_text(f.payload->'source_footprint_ids') x where app.lot_gi_status((x)::uuid) = 'gi')
       and exists (select 1 from jsonb_array_elements_text(f.payload->'source_footprint_ids') x where app.lot_gi_status((x)::uuid) = 'non_gi') then
      raise exception 'GI and non-GI lots are not batched together (%)', (select string_agg(s.footprint_code || ' ' || replace(app.lot_gi_status(s.id), '_', '-'), ', ')
        from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(f.payload->'source_footprint_ids') x)) using errcode = '23514'; end if;
  end if;

  -- Procurement: farmer must be active and belong to the client.
  if f.stage_type = 'procurement' then
    if not exists (select 1 from public.farmers fm where fm.id = f.farmer_id and fm.client_id = f.client_id and fm.status = 'active') then
      raise exception 'procurement requires an active farmer of this client' using errcode = '23514'; end if;
  end if;

  -- Reconciliation (rules 3, 7) → canonical quantities.
  f := app.reconcile(f, sc);
  if f.stage_type = 'procurement' then f := app.procurement_crop_checks(f, sc); end if;   -- migration 42

  -- Availability: cannot take more than the predecessor still holds (aggregates take whole sources, checked above).
  if f.prev_footprint_id is not null and not def.aggregates then
    if f.qty_in > app.available_qty(f.prev_footprint_id) + app.kg_tolerance() then
      raise exception 'qty_in % exceeds available % on predecessor', f.qty_in, app.available_qty(f.prev_footprint_id) using errcode = '23514'; end if;
  end if;

  return f;
end$function$;

-- C5: the lab, the report number and its date; once per lab unless the lots share the sample

CREATE OR REPLACE FUNCTION app.reconcile(f footprints, p_scope scopes)
 RETURNS footprints
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  p jsonb := f.payload; c jsonb := '{}'::jsonb; w text[] := '{}';
  tol jsonb := p_scope.tolerances;
  v_in numeric; v_out numeric; a numeric; b numeric; d numeric; e numeric; s numeric; pk jsonb;
  prev public.footprints;
  v_ceiling numeric; v_learn int; v_rng record; v_pct numeric;   -- migration 49
  v_rdate date; v_taken text; v_on date;                          -- migration 50
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;

  case f.stage_type
    when 'procurement' then
      a := app.req_num(p, 'gross_kg'); b := app.req_num(p, 'bags'); d := app.req_num(p, 'tare_kg_per_bag');
      if not (p ? 'moisture_pct' and jsonb_typeof(p->'moisture_pct') = 'array' and jsonb_array_length(p->'moisture_pct') = 3) then
        raise exception 'payload.moisture_pct must be an array of 3 readings' using errcode = '23514';
      end if;
      select avg(x::numeric), min(x::numeric), max(x::numeric) into a, b, d
        from jsonb_array_elements_text(p->'moisture_pct') x;   -- reuse vars: a=avg b=min d=max
      v_in := app.req_num(p, 'gross_kg') - app.req_num(p, 'bags') * app.req_num(p, 'tare_kg_per_bag');
      if v_in <= 0 then raise exception 'net weight must be positive (gross - bags x tare)' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('net_kg', v_in, 'moisture_avg', round(a, 2), 'moisture_min', b, 'moisture_max', d);
      if f.farmer_id is null then raise exception 'procurement requires farmer_id' using errcode = '23514'; end if;

    when 'lot_inward' then
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'weighed_kg');
      if b <= 0 then raise exception 'weighed_kg must be positive' using errcode = '23514'; end if;
      if coalesce(p->>'source_type', '') = '' or coalesce(p->>'source_name', '') = '' then
        raise exception 'payload.source_type and source_name are required' using errcode = '23514'; end if;
      perform app.req_num(p, 'moisture_pct');
      v_in := b; v_out := b;
      c := jsonb_build_object('variance_kg', a - b, 'variance_pct', case when a > 0 then round((a - b) / a * 100, 2) else null end);
      if a > 0 and abs(a - b) / a * 100 > app.opt_num(tol, 'lot_inward_variance_pct', 2) then
        w := array_append(w, 'declared vs weighed variance exceeds tolerance'); end if;

    when 'village_batch' then
      -- aggregates: qty_in = Σ qty_out of the source procurement lots (validated in the insert trigger)
      select coalesce(sum(s.qty_out), 0) into v_in
        from public.footprints s
        where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_in <= 0 then raise exception 'village_batch needs payload.source_footprint_ids with quantity' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('source_count', jsonb_array_length(p->'source_footprint_ids'));

    when 'milling' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'rice_kg'); b := app.req_num(p, 'bran_kg'); d := app.req_num(p, 'loss_kg');
      if not app.approx_eq(v_in, a + b + d) then
        raise exception 'milling: input (%) must equal rice + bran + loss (%)', v_in, a + b + d using errcode = '23514'; end if;
      v_out := a;
      c := jsonb_build_object('yield_pct', round(a / nullif(v_in, 0) * 100, 2), 'bran_kg', b, 'loss_kg', d);
      -- migration 49 (A7/G5): no fixed threshold. Above the crop's ceiling (70 % unless set) the State Manager is told;
      -- once the crop has its own verified runs (10 unless set), outside their usual range (mean ± 2 SD) is warned.
      if v_in > 0 then
        v_pct := round(a / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        select * into v_rng from app.milling_range(p_scope.crop_id, p_scope.client_id, f.id);
        if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
          w := array_append(w, format('outturn %s %% is outside the usual range of this crop (%s to %s %%, from %s verified runs)', v_pct,
                 round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
      end if;

    when 'sorting' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'reject_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;                                          -- clean output is DERIVED, never entered
      if v_out < 0 then raise exception 'sorting: reject + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('clean_kg', v_out, 'reject_kg', a, 'loss_kg', d, 'reject_reasons', coalesce(p->'reject_reasons', '[]'::jsonb));

    when 'grading' then
      if f.is_grade_lot then
        -- child grade lot: quantity given directly, coupled to the grading run (validated in trigger)
        v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
        c := jsonb_build_object('grade', f.grade);
      else
        v_in := app.req_num(p, 'input_kg');
        a := app.req_num(p, 'grade_a_kg'); b := app.req_num(p, 'grade_b_kg'); d := app.req_num(p, 'grade_c_kg');
        e := app.req_num(p, 'reject_kg'); s := app.req_num(p, 'loss_kg');
        if not app.approx_eq(v_in, a + b + d + e + s) then
          raise exception 'grading: A + B + C + reject + loss (%) must equal input (%)', a + b + d + e + s, v_in using errcode = '23514'; end if;
        v_out := a + b + d;
        c := jsonb_build_object('grade_split', jsonb_build_object('A', a, 'B', b, 'C', d), 'reject_kg', e, 'loss_kg', s);
      end if;

    when 'drying' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'moisture_in_pct'); b := app.req_num(p, 'moisture_out_pct');
      v_out := app.req_num(p, 'output_kg');
      if b >= 100 or a >= 100 then raise exception 'moisture must be below 100%%' using errcode = '23514'; end if;
      e := v_in * (100 - a) / (100 - b);                              -- dry-matter expected output
      c := jsonb_build_object('expected_out_kg', round(e, 3), 'water_removed_kg', round(v_in - e, 3),
                              'grain_loss_kg', round(greatest(e - v_out, 0), 3));
      if v_out > e * 1.01 + app.kg_tolerance() then w := array_append(w, 'output exceeds dry-matter expectation'); end if;  -- 1% weighing noise
      if e - v_out > greatest(e * 0.02, app.kg_tolerance()) then w := array_append(w, 'grain loss beyond moisture removal'); end if;

    when 'popping' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg'); a := app.req_num(p, 'pop_rate_pct');
      c := jsonb_build_object('pop_rate_pct', a, 'weight_yield_pct', round(v_out / nullif(v_in, 0) * 100, 2));
      if a < app.opt_num(tol, 'pop_rate_min_pct', 80) then w := array_append(w, 'pop rate below threshold'); end if;

    when 'blanching' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg');
      c := jsonb_build_object('water_uptake_kg', round(v_out - v_in, 3));   -- output > input is valid here

    when 'cleaning' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'foreign_matter_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;
      if v_out < 0 then raise exception 'cleaning: foreign matter + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('foreign_matter_kg', a, 'loss_kg', d);

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg'); d := app.req_num(p, 'wastage_kg');
      -- migration 50 (G1): the save gives the batch code (trigger footprints_a1_batch_code); the preview has none yet
      if coalesce(p->>'batch_code', '') = '' and f.id is not null then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      if not app.approx_eq(v_in, v_out + d) then
        raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', d, 'batch_code', p->>'batch_code');

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg'); a := app.req_num(p, 'sample_qty_kg');
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);
      -- migration 50 (C5): the scope asks for the lab report (the default): the lab, its number and date; the file comes
      -- before verification. The date: not ahead of today, not before the lot existed. A number once per lab, unless
      -- the lots share the sample.
      if p_scope.qc_report_required then
        if coalesce(btrim(p->>'lab_name'), '') = '' or coalesce(btrim(p->>'report_no'), '') = '' or coalesce(p->>'report_date', '') = '' then
          raise exception 'qc: the lab, the report number and the report date are required' using errcode = '23514'; end if;
        begin v_rdate := (p->>'report_date')::date; exception when others then
          raise exception 'qc: the report date is a date' using errcode = '23514'; end;
        if v_rdate > (now() at time zone 'Asia/Kolkata')::date then
          raise exception 'qc: the report date (%) is in the future', to_char(v_rdate, 'DD Mon YYYY') using errcode = '23514'; end if;
        v_on := coalesce(prev.happened_on, (coalesce(prev.captured_at, prev.created_at) at time zone 'Asia/Kolkata')::date);
        if prev.id is not null and v_rdate < v_on then
          raise exception 'qc: the report date (%) is before the lot it tests (% on %)', to_char(v_rdate, 'DD Mon YYYY'), prev.footprint_code, to_char(v_on, 'DD Mon YYYY')
            using errcode = '23514'; end if;
        v_taken := app.report_no_taken(p->>'lab_name', p->>'report_no', p->>'sample_id', f.id);
        if v_taken is not null then
          raise exception 'qc: report % of this lab is on % already (the same report twice needs the same sample ID)', btrim(p->>'report_no'), v_taken
            using errcode = '23505'; end if;
        c := c || jsonb_build_object('lab_name', btrim(p->>'lab_name'), 'report_no', btrim(p->>'report_no'), 'report_date', v_rdate);
      end if;

    when 'commercial' then
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');

    when 'shipment' then
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);

    when 'qr_activation' then
      if prev.id is null then raise exception 'qr_activation needs a predecessor' using errcode = '23514'; end if;
      v_in := app.available_qty(prev.id); v_out := v_in;              -- takes whatever remains of the final lot
      if v_in <= 0 then raise exception 'qr_activation: final quantity must be recorded and positive' using errcode = '23514'; end if;
      c := jsonb_build_object('final_kg', v_in);

    else
      raise exception 'no reconciliation rule for stage %', f.stage_type using errcode = '23514';
  end case;

  -- Rule 3: output never exceeds input, except blanching.
  if v_out > v_in + app.kg_tolerance() and f.stage_type <> 'blanching' then
    raise exception '% : output (%) exceeds input (%)', f.stage_type, v_out, v_in using errcode = '23514';
  end if;

  f.qty_in := round(v_in, 3); f.qty_out := round(v_out, 3); f.computed := c; f.warnings := w;
  return f;
end $function$;

-- C5: a lab record is verified once its report file is attached (when the scope asks for it)

CREATE OR REPLACE FUNCTION app.footprints_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- migration 50 (C5): the lab report file before verification, where the scope asks for the report
      if old.stage_type = 'qc' and (select s.qc_report_required from public.scopes s where s.id = old.scope_id)
         and not exists (select 1 from public.attachments a where a.footprint_id = old.id and (a.kind = 'document' or a.label = 'lab_report')) then
        raise exception 'qc: the lab report file is attached before the lab record is verified' using errcode = '23514'; end if;
      -- migration 48 (A1): returned to its sender, it waits for the correction
      if exists (select 1 from public.footprint_returns r where r.footprint_id = old.id and r.status = 'open') then
        raise exception 'this record was returned to its sender: it is verified after the correction' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        -- migration 46 (Veda, 14 Oct): one person may hold two stages in a row and then verifies his own record; the
        -- ledger marks it "same person, next stage", the public page says so, the overview counts it
        -- migration 48 (A10/G14): a manager who does not hold the receiving stage verifies only with a written reason
        if auth.uid() is not null and app.manages_scope(new.verified_by, new.scope_id)
           and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           and length(btrim(coalesce(current_setting('app.act_reason', true), ''))) < 10 then
          raise exception 'a manager verifies at a stage he does not hold only with a written reason (at least 10 characters)' using errcode = '23514'; end if;
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end$function$;

-- Blocks: an export release by the Client Manager needs the client's written acceptance attached

CREATE OR REPLACE FUNCTION app.qc_verdicts_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_scope uuid;
begin
  if new.domestic_verdict <> old.domestic_verdict or new.export_verdict <> old.export_verdict
     or new.readings <> old.readings or new.judged <> old.judged then
    raise exception 'derived verdicts and readings are immutable; only override may be set' using errcode = '42501';
  end if;
  if new.override is distinct from old.override then
    if old.override is not null then raise exception 'an override cannot be changed or removed' using errcode = '42501'; end if;
    if coalesce(new.override->>'reason', '') = '' or coalesce(new.override->>'authoriser', '') = ''
       or coalesce(new.override->>'market', '') not in ('domestic','export') then
      raise exception 'override needs market, reason and authoriser' using errcode = '23514'; end if;
    select scope_id into v_scope from public.footprints where id = new.footprint_id;
    if not app.manages_scope((new.override->>'authoriser')::uuid, v_scope) then
      raise exception 'override authoriser must be client_manager or above' using errcode = '42501'; end if;
    -- migration 50: the client's written acceptance, attached to the lab record first
    if new.override->>'market' = 'export' and auth.uid() is not null
       and not exists (select 1 from public.attachments a where a.footprint_id = new.footprint_id and a.label = 'acceptance') then
      raise exception 'an export release needs the client''s written acceptance attached to the lab record first' using errcode = '23514'; end if;
    new.override := new.override || jsonb_build_object('at', now());
    perform app.ledger_append(new.footprint_id, (select scope_id from public.footprints where id = new.footprint_id),
      'override', coalesce(app.current_user_id(), (new.override->>'authoriser')::uuid),
      jsonb_build_object('footprint_id', new.footprint_id, 'override', new.override,
                         'domestic_verdict', new.domestic_verdict, 'export_verdict', new.export_verdict));
  end if;
  return new;
end$function$;

-- D: the public page shows no farmer names; it shows the packs' dates and the release's status

CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false;
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      -- migration 50 (Part D): the village and the district, never the farmer's name or photo
      step := step || jsonb_build_object('farmer', jsonb_build_object('village', fm.village, 'district', fm.district));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', cur.payload->>'village', 'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.village, g.qty_kg)
          from (select fa.name, fa.village, fa.district, sum(src.qty_out) as qty_kg                -- migration 49: one line a farmer
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then
      step := step || jsonb_build_object('destination', cur.payload->>'destination', 'dispatched_on', cur.payload->>'dispatch_date'); end if;
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    -- migration 46: the same person recorded a step and checked it, or recorded the next one (the approved words)
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by and not cur.is_grade_lot) then
      v_same := true;
    end if;
    v_later_maker := cur.created_by;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    'same_person', v_same,
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before))
                from public.packs p where p.footprint_id in (select app.lot_packings(seal.footprint_id)) and p.status = 'packed')
  );
end $function$;

-- the stage form says whether the scope asks for the lab report (the form marks its fields required)

CREATE OR REPLACE FUNCTION app.stage_form(p_scope uuid, p_stage stage_type)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; me uuid := app.current_user_id(); idx int; prev_t public.stage_type; next_t public.stage_type;
begin
  if me is null or not app.can_access_scope(p_scope) then
    raise exception 'no access to this scope' using errcode = '42501'; end if;
  select * into sc from public.scopes where id = p_scope;
  idx := app.chain_index(p_scope, p_stage);
  if idx is null then raise exception 'stage % is not in this scope''s chain', p_stage using errcode = '23514'; end if;
  prev_t := case when idx > 1 then sc.chain[idx - 1] end;
  next_t := sc.chain[idx + 1];
  return jsonb_build_object(
    'scope', jsonb_build_object('id', sc.id, 'season_code', sc.season_code, 'geography', sc.geography, 'status', sc.status, 'short_code', sc.short_code, 'qc_report_required', sc.qc_report_required,
               'chain', to_jsonb(sc.chain), 'tolerances', sc.tolerances,
               'client', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.clients where id = sc.client_id),
               'crop', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'gi_tag', gi_tag, 'primary_unit', primary_unit)
                          from public.crops where id = sc.crop_id)),
    'stage', (select to_jsonb(d) from public.stage_definitions d where d.stage_type = p_stage),
    'position', idx,
    'prev_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label, 'handoff_checks', d.handoff_checks, 'physical_checks', d.physical_checks)
                     from public.stage_definitions d where d.stage_type = prev_t),
    'next_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label)
                     from public.stage_definitions d where d.stage_type = next_t),
    'quality_params', coalesce(sc.quality_params, (select quality_params from public.crops where id = sc.crop_id)),
    'can_create', app.is_my_stage(me, p_scope, p_stage),
    'can_verify_incoming', prev_t is not null and (app.i_manage_scope(p_scope) or app.has_slot(me, p_scope, p_stage)),
    -- migration 48 (A10): a manager at a stage he does not hold gives a reason
    'records_as_manager', app.is_my_stage(me, p_scope, p_stage) and app.manages_scope(me, p_scope) and not app.has_slot(me, p_scope, p_stage),
    'verifies_as_manager', prev_t is not null and app.i_manage_scope(p_scope) and not app.has_slot(me, p_scope, p_stage)
  );
end$function$;

-- the record page: its packs, its delivery, its release's status

CREATE OR REPLACE FUNCTION app.footprint_detail(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; vd record; name_of jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  return jsonb_build_object(
    'footprint', to_jsonb(f),
    'stage_label', (select label from public.stage_definitions where stage_type = f.stage_type),
    'created_by_name', (select display_name from public.app_users where id = f.created_by),
    'verified_by_name', (select display_name from public.app_users where id = f.verified_by),
    'farmer', (select jsonb_build_object('name', name, 'farmer_code', farmer_code, 'village', village,
                 'state_farmer_code', (select sf.code from public.state_farmers sf where sf.id = farmers.state_farmer_id))   -- migration 44
                 from public.farmers where id = f.farmer_id),
    'prev', (select jsonb_build_object('id', p.id, 'footprint_code', p.footprint_code, 'stage_type', p.stage_type)
               from public.footprints p where p.id = f.prev_footprint_id),
    'available_kg', app.available_qty(f.id),
    'qc', (select to_jsonb(v) from public.qc_verdicts v where v.footprint_id = f.id),
    'market_verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'seal', (select to_jsonb(q) from public.qr_seals q where q.footprint_id = f.id),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'status', fl.status, 'created_at', fl.created_at,
               'raised_by_name', (select display_name from public.app_users where id = fl.raised_by), 'kind', fl.kind) order by fl.created_at)
               from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'status', r.status, 'returned_at', r.returned_at,
               'returned_by_name', (select display_name from public.app_users where id = r.returned_by),
               'resolved_at', r.resolved_at, 'resolved_by_name', (select display_name from public.app_users where id = r.resolved_by)) order by r.returned_at)
               from public.footprint_returns r where r.footprint_id = f.id), '[]'::jsonb),                       -- migration 48
    'can_return', f.status = 'pending' and f.created_by is distinct from app.current_user_id()
                  and not coalesce((select d.is_gate from public.stage_definitions d where d.stage_type = f.stage_type), false)
                  and app.is_next_stage_user(app.current_user_id(), f.scope_id, f.stage_type)
                  and not exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'),
    'packs', case when f.stage_type = 'packing' then jsonb_build_object('batch_code', f.payload->>'batch_code',          -- migration 50
               'packed', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'packed'),
               'void', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'void'),
               'prints', (select count(*) from public.label_prints lp where lp.footprint_id = f.id),
               'best_before', (select min(best_before) from public.packs p where p.footprint_id = f.id and p.status = 'packed')) end,
    'delivery', (select to_jsonb(d) || jsonb_build_object('confirmed_by_name', (select display_name from public.app_users where id = d.confirmed_by))
                   from public.deliveries d where d.shipment_id = f.id),
    'release', case when exists (select 1 from public.qr_seals q where q.footprint_id = f.id) then app.release_status(f.id) end,
    'farmers', app.lot_farmers(f.id),                                                                         -- migration 49
    'gi_status', app.lot_gi_status(f.id),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.footprint_code, 'stage', p.stage_type, 'kg', l.kg,
                 'how', l.how, 'from_older', l.from_older) order by p.footprint_code)
                 from public.footprint_links l join public.footprints p on p.id = l.parent_id where l.child_id = f.id), '[]'::jsonb),
    'system_checks', app.system_checks(f.id),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $function$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Every new function is closed by hand, then opened to whom it is for (AGENTS.md)
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.next_batch_code(uuid) from public, anon, authenticated;
revoke execute on function app.footprints_batch_code() from public, anon, authenticated;
revoke execute on function app.make_packs(uuid, text) from public, anon, authenticated;
revoke execute on function app.footprints_packs() from public, anon, authenticated;
revoke execute on function app.print_labels(uuid, text) from public, anon, authenticated;
revoke execute on function app.void_pack(text, text) from public, anon, authenticated;
revoke execute on function app.release_status(uuid) from public, anon, authenticated;
revoke execute on function app.qr_seals_release() from public, anon, authenticated;
revoke execute on function app.lot_packings(uuid) from public, anon, authenticated;
revoke execute on function app.packing_seals(uuid) from public, anon, authenticated;
revoke execute on function app.release_preview(uuid) from public, anon, authenticated;
revoke execute on function app.set_release_status(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.record_scan(text) from public, anon, authenticated;
revoke execute on function app.public_pack(text) from public, anon, authenticated;
revoke execute on function app.report_no_taken(text, text, text, uuid) from public, anon, authenticated;
revoke execute on function app.confirm_delivery(uuid, numeric, date, text) from public, anon, authenticated;
revoke execute on function app.register_labelled_attachment(uuid, public.attachment_kind, text, text, text) from public, anon, authenticated;
revoke execute on function app.set_attachment_label(uuid, text) from public, anon, authenticated;
grant execute on function app.print_labels(uuid, text) to authenticated;
grant execute on function app.void_pack(text, text) to authenticated;
grant execute on function app.release_preview(uuid) to authenticated;
grant execute on function app.set_release_status(uuid, text, text) to authenticated;
grant execute on function app.record_scan(text) to anon, authenticated;
grant execute on function app.public_pack(text) to anon, authenticated;
grant execute on function app.confirm_delivery(uuid, numeric, date, text) to authenticated;
grant execute on function app.register_labelled_attachment(uuid, public.attachment_kind, text, text, text) to authenticated;
grant execute on function app.set_attachment_label(uuid, text) to authenticated;   -- only one's own file, once
revoke execute on function app.scopes_qc_report_frozen() from public, anon, authenticated;
