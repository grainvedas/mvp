-- GrainVeda MVP · migration 48: the rules every stage follows, and the Client Manager's day.
-- Veda, 15 October 2026: "yes but with this i have one more prompt / combine both" and "ok complete everything" — the
-- operator-stages brief (Parts A–G) together with the Client Manager's home, menu and ledger (D3–D5). This is release 1
-- of the plan (docs/FIX_LIST.md item 43):
--   A1/G4   Return to sender, with a reason (10 characters or more). The record stays pending at its sender, nobody can
--           verify it, the sender corrects it (or, for a record that cannot be corrected in place, withdraws it and
--           records it again). "Verify with a condition" (Owner decides; the recommendation Veda accepted): the record is
--           verified and an open condition is raised on it, which blocks the QR seal until it is closed.
--   A9      An "on" date (when it happened) beside the time it was recorded.
--   A10/G14 A manager records (or verifies) at a stage he does not hold only with a written reason; the ledger marks it.
--   E4/G15  Record numbers name the scope: TCUP-KNM-KH26-GKP-P-0001. Every scope gets a short code (2–4 letters);
--           the ones already there get one from their place name. Old record numbers are never changed.
--   D3      app.my_actions(): what waits for the signed-in person (returned to me, to verify, corrections, farmers,
--           requirement lines, flags and conditions).
--   D5      app.client_ledger_page(): the Client Manager reads the ledger of his client.
--   Fix 1   The farmer's history names every line: lots of the farmer and good farming practice answered.
-- Additive only: no row is deleted; existing rows get only the new scope short codes.
select set_config('app.change_path', 'migration 48', true);

alter type public.ledger_event add value if not exists 'return';

-- ---------------------------------------------------------------------------------------------------------------------
-- E4 · the scope's short code, and record numbers that carry it
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.scopes add column if not exists short_code text;
alter table public.scopes add constraint scopes_short_code_shape check (short_code is null or short_code ~ '^[A-Z]{2,4}$');

-- Pure: a short code from a place name. The first letter, then the next consonants (no repeats, no H): "gkp" → GKP,
-- "Bansi" → BNS, "Siddharthnagar" → SDR. Fewer than two letters: the name's letters as they come.
create or replace function app.short_code_from(p_name text) returns text
language plpgsql immutable set search_path = public as $$
declare s text := upper(regexp_replace(coalesce(p_name, ''), '[^A-Za-z]', '', 'g')); out text := ''; c text; i int;
begin
  if s = '' then return 'SC'; end if;
  out := substr(s, 1, 1);
  for i in 2 .. length(s) loop
    exit when length(out) = 3;
    c := substr(s, i, 1);
    if c in ('A', 'E', 'I', 'O', 'U', 'H') or c = right(out, 1) then continue; end if;
    out := out || c;
  end loop;
  if length(out) < 2 then out := left(s || 'X', greatest(2, least(3, length(s)))); end if;
  return out;
end $$;

-- A free short code for a scope of this client, crop and season: the suggestion, else with a fourth letter.
create or replace function app.suggest_short_code(p_geography text, p_client uuid, p_crop uuid, p_season text, p_except uuid default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare base text := app.short_code_from(p_geography); cand text; k int;
  taken boolean;
begin
  cand := base;
  for k in 0 .. 26 loop
    if k > 0 then cand := left(base, 3) || chr(64 + k); end if;
    select exists (select 1 from public.scopes s where s.client_id = p_client and s.crop_id = p_crop and s.season_code = p_season
                     and s.short_code = cand and (p_except is null or s.id <> p_except)) into taken;
    if not taken then return cand; end if;
  end loop;
  raise exception 'no free short code for %', p_geography using errcode = '23505';
end $$;

do $$
declare s record;
begin
  for s in select id, geography, client_id, crop_id, season_code from public.scopes where short_code is null order by created_at, id loop
    update public.scopes set short_code = app.suggest_short_code(s.geography, s.client_id, s.crop_id, s.season_code, s.id) where id = s.id;
  end loop;
end $$;
create unique index if not exists scopes_short_code_key on public.scopes (client_id, crop_id, season_code, short_code) where short_code is not null;

-- Given on create when none is typed; changed only while no record number carries it.
create or replace function app.scopes_short_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.short_code := nullif(upper(btrim(coalesce(new.short_code, ''))), '');
  if tg_op = 'INSERT' then
    if new.short_code is null then
      new.short_code := app.suggest_short_code(new.geography, new.client_id, new.crop_id, new.season_code, new.id); end if;
    return new;
  end if;
  if new.short_code is distinct from old.short_code then
    if new.short_code is null then raise exception 'a scope needs a short code (2 to 4 letters)' using errcode = '23514'; end if;
    if old.short_code is not null and exists (select 1 from public.footprints f where f.scope_id = old.id
                                                and f.footprint_code like '%-' || old.short_code || '-%') then
      raise exception 'the short code % is in this scope''s record numbers already: it cannot change', old.short_code using errcode = '23514'; end if;
    if exists (select 1 from public.scopes s where s.id <> new.id and s.client_id = new.client_id and s.crop_id = new.crop_id
                 and s.season_code = new.season_code and s.short_code = new.short_code) then
      raise exception 'another scope of this client, crop and season has the short code %', new.short_code using errcode = '23505'; end if;
  end if;
  return new;
end $$;
drop trigger if exists scopes_a4_short_code on public.scopes;
create trigger scopes_a4_short_code before insert or update of short_code on public.scopes
  for each row execute function app.scopes_short_code();

-- ---------------------------------------------------------------------------------------------------------------------
-- A9 · the date it happened; A10 · a manager's reason
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.footprints add column if not exists happened_on date;
alter table public.footprints add column if not exists manager_reason text;
alter table public.footprints add constraint footprints_manager_reason_shape
  check (manager_reason is null or length(manager_reason) between 10 and 500);

-- "On": when the work was done (the person says; today by default). Never after it was recorded, at most 31 days
-- before, never before the lot it comes from. The time it was recorded stays the server's (captured_at / created_at).
create or replace function app.footprints_happened_on() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_rec date; v_prev date; p public.footprints; src uuid;
begin
  if tg_op = 'UPDATE' and new.happened_on is not distinct from old.happened_on then return new; end if;
  v_rec := (coalesce(new.captured_at, new.created_at, now()) at time zone 'Asia/Kolkata')::date;
  if new.happened_on is null then
    if tg_op = 'INSERT' then new.happened_on := v_rec; return new; end if;
    raise exception 'say on which date it happened' using errcode = '23514';
  end if;
  if auth.uid() is null then return new; end if;                          -- seeds, service
  if new.happened_on > v_rec then
    raise exception 'the date it happened (%) cannot be after the day it is recorded (%)', to_char(new.happened_on, 'DD Mon YYYY'), to_char(v_rec, 'DD Mon YYYY')
      using errcode = '23514'; end if;
  if new.happened_on < v_rec - 31 then
    raise exception 'the date it happened (%) is more than 31 days before it is recorded', to_char(new.happened_on, 'DD Mon YYYY') using errcode = '23514'; end if;
  for src in select new.prev_footprint_id where new.prev_footprint_id is not null and not new.is_grade_lot
             union select (x)::uuid from jsonb_array_elements_text(case when new.stage_type = 'village_batch'
                                                                         then coalesce(new.payload->'source_footprint_ids', '[]'::jsonb) else '[]'::jsonb end) x loop
    select * into p from public.footprints where id = src;
    v_prev := coalesce(p.happened_on, (coalesce(p.captured_at, p.created_at) at time zone 'Asia/Kolkata')::date);
    if v_prev is not null and new.happened_on < v_prev then
      raise exception 'it cannot have happened (%) before the lot it comes from (% on %)', to_char(new.happened_on, 'DD Mon YYYY'), p.footprint_code, to_char(v_prev, 'DD Mon YYYY')
        using errcode = '23514'; end if;
  end loop;
  return new;
end $$;
drop trigger if exists footprints_d1_happened_on on public.footprints;
create trigger footprints_d1_happened_on before insert or update of happened_on on public.footprints
  for each row execute function app.footprints_happened_on();

-- A manager who records at a stage he does not hold says why (A10/G14). The ledger block is 'supervisory' and carries
-- the reason. A record by the stage's own operator carries none. Grade lots are made by their run's save.
create or replace function app.footprints_manager_reason() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_reason text;
begin
  if auth.uid() is null or new.is_grade_lot then return new; end if;
  if app.manages_scope(new.created_by, new.scope_id) and not app.has_slot(new.created_by, new.scope_id, new.stage_type) then
    v_reason := btrim(coalesce(nullif(btrim(coalesce(new.manager_reason, '')), ''), current_setting('app.act_reason', true), ''));
    if length(v_reason) < 10 then
      raise exception 'a manager records at a stage he does not hold only with a written reason (at least 10 characters)' using errcode = '23514'; end if;
    new.manager_reason := left(v_reason, 500);
  else
    new.manager_reason := null;
  end if;
  return new;
end $$;
drop trigger if exists footprints_c1_manager_reason on public.footprints;
create trigger footprints_c1_manager_reason before insert on public.footprints
  for each row execute function app.footprints_manager_reason();

-- ---------------------------------------------------------------------------------------------------------------------
-- A1/G4 · returned to its sender
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.footprint_returns (
  id            uuid primary key default gen_random_uuid(),
  footprint_id  uuid not null references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  stage_type    public.stage_type not null,
  reason        text not null check (length(btrim(reason)) between 10 and 500),
  returned_by   uuid not null references public.app_users(id),
  returned_at   timestamptz not null default now(),
  status        text not null default 'open' check (status in ('open', 'corrected', 'withdrawn')),
  resolved_by   uuid references public.app_users(id),
  resolved_at   timestamptz
);
create unique index if not exists footprint_returns_one_open on public.footprint_returns (footprint_id) where status = 'open';
create index if not exists footprint_returns_scope on public.footprint_returns (scope_id, stage_type);
alter table public.footprint_returns enable row level security;
revoke all on public.footprint_returns from anon, authenticated;
grant select on public.footprint_returns to authenticated;
drop policy if exists footprint_returns_read on public.footprint_returns;
create policy footprint_returns_read on public.footprint_returns for select to authenticated
  using (app.can_see_footprint(scope_id, stage_type));                   -- the row's own columns (AGENTS.md)
drop trigger if exists zz_change_log on public.footprint_returns;
create trigger zz_change_log after insert or update or delete on public.footprint_returns
  for each row execute function app.log_change('id');

-- The next stage (or a manager of the scope) sends a pending record back to whoever recorded it, with the reason.
create or replace function app.return_footprint(p_fp uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; r public.footprint_returns;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.status <> 'pending' then
    raise exception 'only a record waiting for verification is returned (this one is %)', f.status using errcode = '23514'; end if;
  if (select d.is_gate from public.stage_definitions d where d.stage_type = f.stage_type) then
    raise exception 'a QR record is not returned' using errcode = '23514'; end if;
  if f.created_by = me then
    raise exception 'you recorded it: correct it yourself' using errcode = '23514'; end if;
  if not app.is_next_stage_user(me, f.scope_id, f.stage_type) then
    raise exception 'only the next stage (or a manager of this scope) returns a record' using errcode = '42501'; end if;
  if exists (select 1 from public.footprint_returns x where x.footprint_id = f.id and x.status = 'open') then
    raise exception 'it is returned already: it waits for its sender' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'say why it is returned (at least 10 characters)' using errcode = '23514'; end if;
  insert into public.footprint_returns (footprint_id, scope_id, stage_type, reason, returned_by)
  values (f.id, f.scope_id, f.stage_type, left(btrim(p_reason), 500), me) returning * into r;
  perform app.ledger_append(f.id, f.scope_id, 'return', me, jsonb_build_object(
    'act', 'returned', 'footprint_id', f.id, 'footprint_code', f.footprint_code, 'stage_type', f.stage_type,
    'reason', r.reason, 'to', f.created_by,
    'by_manager', not app.has_slot(me, f.scope_id, app.chain_next(f.scope_id, f.stage_type))));
  return to_jsonb(r);
end $$;

-- A returned record is corrected in place by its sender (or withdrawn, to be recorded again): the return is closed and
-- the ledger says how.
create or replace function app.footprints_returns_resolve() returns trigger
language plpgsql security definer set search_path = public as $$
declare r public.footprint_returns; v_how text;
begin
  select * into r from public.footprint_returns where footprint_id = new.id and status = 'open';
  if r.id is null then return new; end if;
  if new.status = 'superseded' and old.status <> 'superseded' then v_how := 'withdrawn';
  elsif old.status = 'pending' and new.status = 'pending'
        and (new.payload is distinct from old.payload or new.farmer_id is distinct from old.farmer_id
             or new.happened_on is distinct from old.happened_on) then v_how := 'corrected';
  else return new; end if;
  update public.footprint_returns set status = v_how, resolved_by = app.current_user_id(), resolved_at = now() where id = r.id;
  perform app.ledger_append(new.id, new.scope_id, 'return', coalesce(app.current_user_id(), new.created_by), jsonb_build_object(
    'act', v_how, 'footprint_id', new.id, 'footprint_code', new.footprint_code, 'stage_type', new.stage_type,
    'return_id', r.id, 'reason', r.reason));
  return new;
end $$;
drop trigger if exists footprints_z2_returns on public.footprints;
create trigger footprints_z2_returns after update on public.footprints
  for each row execute function app.footprints_returns_resolve();

-- ---------------------------------------------------------------------------------------------------------------------
-- Verify, with a reason (a manager) or with a condition (anyone who verifies)
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.flags add column if not exists kind text not null default 'flag';
alter table public.flags add constraint flags_kind_shape check (kind in ('flag', 'condition'));

create or replace function app.verify_record(p_fp uuid, p_reason text default null, p_condition text default null)
returns public.footprints language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.footprints; v_cond text := nullif(btrim(coalesce(p_condition, '')), '');
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  if v_cond is not null and length(v_cond) < 10 then
    raise exception 'write the condition (at least 10 characters)' using errcode = '23514'; end if;
  perform set_config('app.act_reason', left(btrim(coalesce(p_reason, '')), 500), true);
  perform set_config('app.act_condition', coalesce(left(v_cond, 500), ''), true);
  r := app.verify_footprint(p_fp);
  if v_cond is not null then
    insert into public.flags (footprint_id, raised_by, text, kind) values (r.id, me, left(v_cond, 500), 'condition');
  end if;
  perform set_config('app.act_reason', '', true);
  perform set_config('app.act_condition', '', true);
  return r;
end $$;

-- A manager who seals at a QR stage he does not hold: the same seal, with his reason (A10).
create or replace function app.seal_source_as_manager(p_source uuid, p_reason text) returns jsonb
language plpgsql security invoker set search_path = public as $$                 -- invoker: the seal's own RLS applies
declare v jsonb;
begin
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'a manager records at a stage he does not hold only with a written reason (at least 10 characters)' using errcode = '23514'; end if;
  perform set_config('app.act_reason', left(btrim(p_reason), 500), true);
  v := to_jsonb(app.seal_source(p_source));
  perform set_config('app.act_reason', '', true);
  return v;
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen48.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- E4: the series and the number carry the scope's short code (none: as before)

CREATE OR REPLACE FUNCTION app.next_footprint_code(p_scope uuid, p_stage stage_type, p_grade text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
declare v_seq int; v_client text; v_crop text; v_season text; v_stage text; v_series text; v_short text;
begin
  select c.code, cr.code, s.season_code, s.short_code into v_client, v_crop, v_season, v_short
    from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
    where s.id = p_scope;
  v_series := format('%s-%s-%s', v_client, v_crop, v_season) || coalesce('-' || v_short, '');   -- migration 48: the scope
  insert into public.footprint_counters (series, stage_type, last_seq) values (v_series, p_stage, 1)
  on conflict (series, stage_type) do update set last_seq = public.footprint_counters.last_seq + 1
  returning last_seq into v_seq;
  select code into v_stage from public.stage_definitions where stage_type = p_stage;
  return format('%s-%s-%s', v_series, v_stage, app.pad_seq(v_seq)) || format('%s',
                case when p_grade is null then '' else '-' || p_grade end);
end $function$;

-- A9/A10: the ledger snapshot carries the date it happened and a manager's reason (only when there is one)

CREATE OR REPLACE FUNCTION app.footprint_snapshot(f footprints)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select jsonb_build_object(
    'id', f.id, 'footprint_code', f.footprint_code, 'client_id', f.client_id, 'scope_id', f.scope_id,
    'stage_type', f.stage_type, 'prev_footprint_id', f.prev_footprint_id, 'farmer_id', f.farmer_id,
    'qty_in', f.qty_in, 'qty_out', f.qty_out, 'status', f.status, 'payload', f.payload, 'computed', f.computed,
    'warnings', to_jsonb(f.warnings), 'lot_closed', f.lot_closed, 'is_grade_lot', f.is_grade_lot, 'grade', f.grade,
    'split_into_grades', f.split_into_grades, 'supersedes_id', f.supersedes_id,
    'created_by', f.created_by, 'verified_by', f.verified_by, 'verified_at', f.verified_at, 'created_at', f.created_at,
    'captured_at', f.captured_at
  ) || jsonb_strip_nulls(jsonb_build_object('happened_on', f.happened_on, 'manager_reason', f.manager_reason))   -- migration 48
$function$;

-- A9: the sender may correct the date it happened, as the other entered values

CREATE OR REPLACE FUNCTION app.footprints_api_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare keep text[] := array['payload', 'farmer_id', 'split_into_grades', 'status', 'verified_by', 'verified_at', 'happened_on'];   -- migration 48: the date it happened
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if (to_jsonb(new) - keep) is distinct from (to_jsonb(old) - keep) then
    raise exception 'quantities, codes, dates and lot status are set by the server; only the entered values of a pending record can be corrected'
      using errcode = '42501';
  end if;
  if new.status is distinct from old.status then
    if not (old.status = 'pending' and new.status = 'verified') then
      raise exception 'a record''s status cannot be set directly: it is verified by the receiving stage and withdrawn by a manager (app.withdraw_footprint)'
        using errcode = '42501';
    end if;
    new.verified_at := now();
  elsif new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at then
    raise exception 'verified_by and verified_at are set by verification only' using errcode = '42501';
  end if;
  return new;
end $function$;

-- A1: a returned record is not verified until its sender has corrected it; A10: a manager verifies with a reason

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

-- the verification block carries the manager's reason and the condition, when there is one

CREATE OR REPLACE FUNCTION app.footprints_after_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid;
begin
  if old.status = 'pending' and new.status = 'verified' then
    v_actor := coalesce(app.current_user_id(), new.verified_by);
    perform app.ledger_append(new.id, new.scope_id,
      case when app.manages_scope(new.verified_by, new.scope_id)
            and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           then 'supervisory'::public.ledger_event else 'verify'::public.ledger_event end,
      v_actor, app.footprint_snapshot(new) || jsonb_strip_nulls(jsonb_build_object(                -- migration 48
        'verify_reason', nullif(current_setting('app.act_reason', true), ''), 'condition', nullif(current_setting('app.act_condition', true), ''))));
  end if;
  if new.status = 'superseded' and old.status <> 'superseded' then
    perform app.ledger_append(new.id, new.scope_id, 'supersede', app.current_user_id(), app.footprint_snapshot(new));
  end if;
  if new.lot_closed and not old.lot_closed then
    perform app.ledger_append(new.id, new.scope_id, 'close', app.current_user_id(),
      jsonb_build_object('id', new.id, 'lot_closed', true, 'available_kg', app.available_qty(new.id)));
  end if;
  return new;
end$function$;

-- A1: the sender withdraws his own returned record (to record it again); a manager any, as before

CREATE OR REPLACE FUNCTION app.withdraw_footprint(p_fp uuid, p_reason text)
 RETURNS footprints
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; r public.footprints; me uuid := app.current_user_id(); src uuid;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not app.i_manage_scope(f.scope_id)
     and not (f.created_by = me and exists (select 1 from public.footprint_returns x where x.footprint_id = f.id and x.status = 'open')) then
    raise exception 'only a manager can withdraw a record (or its sender, once it is returned)' using errcode = '42501'; end if;   -- migration 48
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  if f.status not in ('pending', 'verified') then
    raise exception 'only a pending or verified record can be withdrawn (this one is %)', f.status using errcode = '23514'; end if;

  insert into public.withdrawals (footprint_id, reason, withdrawn_by) values (f.id, btrim(p_reason), me);
  update public.footprints set status = 'superseded' where id = f.id returning * into r;   -- update rules: leaf, not sealed

  if f.stage_type = 'village_batch' then                               -- the batch had closed every source lot
    for src in select (x)::uuid from jsonb_array_elements_text(coalesce(f.payload->'source_footprint_ids', '[]'::jsonb)) x loop
      update public.footprints set lot_closed = false where id = src and lot_closed and status = 'verified';
    end loop;
  elsif f.prev_footprint_id is not null and not f.is_grade_lot then
    perform app.sync_lot_closed(f.prev_footprint_id);
  end if;

  perform app.ledger_append(f.id, f.scope_id, case when app.i_manage_scope(f.scope_id) then 'supervisory' else 'return' end::public.ledger_event, me,
    jsonb_build_object('act', 'withdraw', 'footprint_id', f.id, 'footprint_code', f.footprint_code,
                       'was', f.status, 'qty_out', f.qty_out, 'reason', btrim(p_reason)));
  return r;
end$function$;

-- Fix 1: every line of the farmer's history is named: his lots, and good farming practice answered

CREATE OR REPLACE FUNCTION app.farmer_history(p_farmer uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.farmers;
begin
  select * into f from public.farmers where id = p_farmer;
  if f.id is null or not app.farmer_read(f.client_id, f.state_id) then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'farmer_code', f.farmer_code,
    'state_farmer_code', (select code from public.state_farmers where id = f.state_farmer_id),
    'drafted', jsonb_build_object('by', (select display_name from public.app_users where id = f.created_by), 'at', f.created_at,
                                  'role', app.working_role_at(f.created_by, f.created_at)),
    'client_verified', case when f.reviewed_at is not null then jsonb_build_object('by', (select display_name from public.app_users where id = f.reviewed_by), 'at', f.reviewed_at) end,
    'state_verified', case when f.verified_at is not null then jsonb_build_object('by', (select display_name from public.app_users where id = f.verified_by), 'at', f.verified_at) end,
    'events', coalesce((                                                   -- migration 48: lots and practice answers too
      select jsonb_agg(e.j order by e.at, e.k)
        from (select l.created_at as at, l.seq::text as k,
                     jsonb_build_object('seq', l.seq, 'at', l.created_at,
                       'kind', coalesce(l.payload->>'kind', l.payload->>'act', case when l.footprint_id is not null then 'lot_' || l.event end),
                       'by', u.display_name, 'role', app.working_role_at(l.actor, l.created_at),
                       'before', l.payload->'before', 'after', l.payload->'after', 'reason', l.payload->>'reason',
                       'farmer_code', l.payload->>'farmer_code', 'state_farmer_code', l.payload->>'state_farmer_code',
                       'linked', l.payload->'linked', 'record', l.payload->>'footprint_code', 'stage', l.payload->>'stage_type',
                       'qty', l.payload->'qty_out') as j
                from public.ledger l left join public.app_users u on u.id = l.actor
               where l.payload->>'farmer_id' = f.id::text
              union all
              select a.created_at, 'a' || a.id::text,
                     jsonb_build_object('seq', 'a' || a.id::text, 'at', a.created_at, 'kind', 'practice_saved',
                       'by', u.display_name, 'role', app.working_role_at(a.actor, a.created_at),
                       'crop', a.detail->>'crop', 'filled', a.detail->'filled', 'of', a.detail->'of')
                from public.audit_log a left join public.app_users u on u.id = a.actor
               where a.action = 'farmer_gap_saved' and a.target = f.id) e), '[]'::jsonb),
    'open_changes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'field', c.field, 'before', c.before, 'after', c.after, 'reason', c.reason,
               'by', (select display_name from public.app_users where id = c.changed_by), 'at', c.changed_at) order by c.changed_at)
        from public.farmer_change_flags c where c.farmer_id = f.id and c.accepted_at is null), '[]'::jsonb),
    'can_accept', app.farmer_staff(app.current_user_id(), f.client_id, f.state_id));
end $function$;

-- the stage form says when its reader records or verifies as a manager (a reason is asked), and the short code

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
    'scope', jsonb_build_object('id', sc.id, 'season_code', sc.season_code, 'geography', sc.geography, 'status', sc.status, 'short_code', sc.short_code,
               'chain', to_jsonb(sc.chain), 'tolerances', sc.tolerances,
               'client', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.clients where id = sc.client_id),
               'crop', (select jsonb_build_object('id', id, 'name', name, 'code', code, 'gi_tag', gi_tag, 'primary_unit', primary_unit)
                          from public.crops where id = sc.crop_id)),
    'stage', (select to_jsonb(d) from public.stage_definitions d where d.stage_type = p_stage),
    'position', idx,
    'prev_stage', (select jsonb_build_object('stage_type', d.stage_type, 'label', d.label, 'handoff_checks', d.handoff_checks)
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

-- the record page: its returns, and whether the reader may return it

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
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $function$;

-- the ledger pages show a block's reason (a manager's, a return's, a condition)

CREATE OR REPLACE FUNCTION app.ledger_page(p_event text DEFAULT NULL::text, p_client uuid DEFAULT NULL::uuid, p_scope uuid DEFAULT NULL::uuid, p_actor uuid DEFAULT NULL::uuid, p_manager_acts boolean DEFAULT false, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); total bigint; rows jsonb;
begin
  if me is null or not app.is_admin() then raise exception 'the whole ledger is for the admin' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, f.created_by as fp_maker, f.is_grade_lot as fp_grade_lot,
           (select pf.created_by from public.footprints pf where pf.id = f.prev_footprint_id) as prev_maker, coalesce(f.client_id, s.client_id) as client_id, coalesce(l.scope_id, f.scope_id) as the_scope
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id)
     where (p_event is null or l.event::text = p_event)
       and (p_actor is null or l.actor = p_actor)
       and (not coalesce(p_manager_acts, false) or (l.event = 'supervisory' and l.footprint_id is not null))),
  m as (select * from b where (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role,
            'note', coalesce(m.payload->>'manager_reason', m.payload->>'verify_reason', m.payload->>'condition', m.payload->>'reason'),   -- migration 48
            'stage_role', case when m.stage_type is null then null when m.event in ('create', 'supervisory') then m.stage_type::text
                               when m.event = 'seal' or m.stage_type = 'qr_activation' then 'qr_activation'
                               when m.event = 'verify' then coalesce(app.chain_next(m.the_scope, m.stage_type)::text, m.stage_type::text) end,
            'same_person', coalesce((m.event = 'verify' and m.fp_maker = m.actor and m.stage_type <> 'qr_activation')
                           or (m.event = 'create' and m.prev_maker = m.actor and not coalesce(m.fp_grade_lot, false)), false))
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset);
end $function$;

CREATE OR REPLACE FUNCTION app.state_ledger_page(p_state uuid, p_event text, p_client uuid, p_scope uuid, p_actor uuid, p_limit integer, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); total bigint; rows jsonb; signers jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'the ledger of a state is for its State Manager' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, f.created_by as fp_maker, f.is_grade_lot as fp_grade_lot,
           (select pf.created_by from public.footprints pf where pf.id = f.prev_footprint_id) as prev_maker,
           coalesce(f.client_id, s.client_id, app.uuid_or_null(l.payload->>'client_id'), fa.client_id) as client_id,
           s.id as the_scope,
           coalesce(s.state_id, fa.state_id, (select c.state_id from public.clients c where c.id = app.uuid_or_null(l.payload->>'client_id')),
                    app.uuid_or_null(l.payload->>'state_id')) as state_id
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id, app.uuid_or_null(l.payload->>'scope_id'))
      left join public.farmers fa on fa.id = app.uuid_or_null(l.payload->>'farmer_id')),
  m as (select * from b where b.state_id = p_state
          and (p_event is null or b.event::text = p_event) and (p_actor is null or b.actor = p_actor)
          and (p_client is null or b.client_id = p_client) and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name) order by u.display_name)
                     from app_users u where u.id in (select b.actor from b where b.state_id = p_state)), '[]'),   -- migration 42
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role,
            'note', coalesce(m.payload->>'manager_reason', m.payload->>'verify_reason', m.payload->>'condition', m.payload->>'reason'),   -- migration 48
            'stage_role', case when m.stage_type is null then null when m.event in ('create', 'supervisory') then m.stage_type::text
                               when m.event = 'seal' or m.stage_type = 'qr_activation' then 'qr_activation'
                               when m.event = 'verify' then coalesce(app.chain_next(m.the_scope, m.stage_type)::text, m.stage_type::text) end,
            'same_person', coalesce((m.event = 'verify' and m.fp_maker = m.actor and m.stage_type <> 'qr_activation')
                           or (m.event = 'create' and m.prev_maker = m.actor and not coalesce(m.fp_grade_lot, false)), false))
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, signers, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset,
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from public.clients c
                             where c.state_id = p_state or exists (select 1 from public.scopes s where s.client_id = c.id and s.state_id = p_state)), '[]'),
       'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_id', s.client_id)
                             order by cr.name, s.season_code) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.state_id = p_state), '[]'),
       'actors', signers),
    -- the chain is checked whole: the last check of the whole ledger, without a button to run one
    'check', (select jsonb_build_object('checked_at', k.checked_at, 'ok', k.ok, 'blocks', k.blocks, 'first_bad_seq', k.first_bad_seq, 'source', k.source)
                from public.ledger_checks k order by k.checked_at desc limit 1));
end $function$;

-- D5: the Client Manager reads the ledger of his client (as the State Manager reads his state's)

CREATE OR REPLACE FUNCTION app.client_ledger_page(p_client uuid, p_event text, p_scope uuid, p_actor uuid, p_limit integer, p_offset integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); total bigint; rows jsonb; signers jsonb;
begin
  if me is null or not (app.is_admin() or app.client_account_holder(me, p_client)) then
    raise exception 'the ledger of a client is for its Client Manager' using errcode = '42501'; end if;
  p_limit := least(greatest(coalesce(p_limit, 100), 1), 500);
  p_offset := greatest(coalesce(p_offset, 0), 0);
  with b as (
    select l.*, f.footprint_code, f.stage_type, f.created_by as fp_maker, f.is_grade_lot as fp_grade_lot,
           (select pf.created_by from public.footprints pf where pf.id = f.prev_footprint_id) as prev_maker,
           coalesce(f.client_id, s.client_id, app.uuid_or_null(l.payload->>'client_id'), fa.client_id) as client_id,
           s.id as the_scope,
           coalesce(s.state_id, fa.state_id, (select c.state_id from public.clients c where c.id = app.uuid_or_null(l.payload->>'client_id')),
                    app.uuid_or_null(l.payload->>'state_id')) as state_id
      from public.ledger l
      left join public.footprints f on f.id = l.footprint_id
      left join public.scopes s on s.id = coalesce(l.scope_id, f.scope_id, app.uuid_or_null(l.payload->>'scope_id'))
      left join public.farmers fa on fa.id = app.uuid_or_null(l.payload->>'farmer_id')),
  m as (select * from b where b.client_id = p_client
          and (p_event is null or b.event::text = p_event) and (p_actor is null or b.actor = p_actor)
          and (p_scope is null or b.the_scope = p_scope))
  select (select count(*) from m),
         coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name) order by u.display_name)
                     from app_users u where u.id in (select b.actor from b where b.client_id = p_client)), '[]'),
         coalesce((select jsonb_agg(jsonb_build_object(
            'seq', m.seq, 'event', m.event, 'created_at', m.created_at, 'hash', m.hash, 'prev_hash', m.prev_hash,
            'footprint_id', m.footprint_id, 'record', m.footprint_code, 'stage_type', m.stage_type,
            'what', coalesce(m.payload->>'kind', m.payload->>'act', m.payload->>'event', m.payload->>'action'),
            'about', coalesce(m.payload->>'name', m.payload->>'user_name', m.payload->>'person'),
            'client', c.name, 'scope', case when sc.id is null then null else format('%s · %s · %s', cr.name, sc.season_code, sc.geography) end,
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_working_role', app.working_role_at(m.actor, m.created_at), 'actor_summary_role', u.role,
            'note', coalesce(m.payload->>'manager_reason', m.payload->>'verify_reason', m.payload->>'condition', m.payload->>'reason'),   -- migration 48
            'stage_role', case when m.stage_type is null then null when m.event in ('create', 'supervisory') then m.stage_type::text
                               when m.event = 'seal' or m.stage_type = 'qr_activation' then 'qr_activation'
                               when m.event = 'verify' then coalesce(app.chain_next(m.the_scope, m.stage_type)::text, m.stage_type::text) end,
            'same_person', coalesce((m.event = 'verify' and m.fp_maker = m.actor and m.stage_type <> 'qr_activation')
                           or (m.event = 'create' and m.prev_maker = m.actor and not coalesce(m.fp_grade_lot, false)), false))
            order by m.seq desc)
           from (select * from m order by m.seq desc limit p_limit offset p_offset) m
           left join public.clients c on c.id = m.client_id
           left join public.scopes sc on sc.id = m.the_scope
           left join public.crops cr on cr.id = sc.crop_id
           left join public.app_users u on u.id = m.actor), '[]')
    into total, signers, rows;
  return jsonb_build_object('total', total, 'rows', rows, 'limit', p_limit, 'offset', p_offset,
    'filters', jsonb_build_object(
       'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name)) from public.clients c where c.id = p_client), '[]'),
       'scopes', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'label', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'client_id', s.client_id)
                             order by cr.name, s.season_code) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.client_id = p_client), '[]'),
       'actors', signers),
    -- the chain is checked whole: the last check of the whole ledger, without a button to run one
    'check', (select jsonb_build_object('checked_at', k.checked_at, 'ok', k.ok, 'blocks', k.blocks, 'first_bad_seq', k.first_bad_seq, 'source', k.source)
                from public.ledger_checks k order by k.checked_at desc limit 1));
end $function$;


-- ---------------------------------------------------------------------------------------------------------------------
-- D3 · what waits for me (every role; the Client Manager's home shows it first)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.my_actions() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id();
begin
  if me is null then raise exception 'not authenticated' using errcode = '42501'; end if;
  return jsonb_build_object(
    -- my records sent back to me
    'returned', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'stage', f.stage_type, 'scope_id', f.scope_id,
               'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'reason', r.reason,
               'by', (select u.display_name from public.app_users u where u.id = r.returned_by), 'at', r.returned_at,
               'in_place', not (f.stage_type in ('qc', 'village_batch') or f.is_grade_lot or f.split_into_grades
                                or exists (select 1 from public.footprints c where c.prev_footprint_id = f.id and c.status not in ('superseded', 'legacy'))))
             order by r.returned_at)
        from public.footprint_returns r
        join public.footprints f on f.id = r.footprint_id
        join public.scopes s on s.id = f.scope_id join public.crops cr on cr.id = s.crop_id
       where r.status = 'open' and f.created_by = me), '[]'::jsonb),
    -- records waiting at the stages I hold (my verification), returned ones apart
    'to_verify', coalesce((
      select jsonb_agg(x order by x->>'scope', (x->>'pos')::int) from (
        select jsonb_build_object('scope_id', sa.scope_id, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
                 'stage', sa.stage_type, 'from_stage', app.chain_prev(sa.scope_id, sa.stage_type), 'pos', app.chain_index(sa.scope_id, sa.stage_type),
                 'n', (select count(*) from public.footprints f
                        where f.scope_id = sa.scope_id and f.stage_type = app.chain_prev(sa.scope_id, sa.stage_type) and f.status = 'pending'
                          and not exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'))) as x
          from (select distinct scope_id, stage_type from public.slot_assignments where user_id = me) sa
          join public.scopes s on s.id = sa.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
         where app.has_slot(me, sa.scope_id, sa.stage_type) and app.chain_prev(sa.scope_id, sa.stage_type) is not null) y
       where (x->>'n')::int > 0), '[]'::jsonb),
    -- corrections of verified farmers proposed by Procurement, for the clients whose account I hold
    'proposals', (select count(*) from public.farmer_proposals p where p.status = 'requested' and app.client_account_holder(me, p.client_id)),
    -- farmers added (drafts) waiting for the Client Manager's verification
    'farmers_to_verify', (select count(*) from public.farmers fm where fm.status = 'draft' and app.client_account_holder(me, fm.client_id)),
    -- requirement lines HR returned to me with a question
    'requirement_lines', (select count(*) from public.requirement_lines l join public.requirements q on q.id = l.requirement_id
                           where l.status = 'returned' and app.owns_requirement(q)),
    -- open flags and conditions on records of the scopes I manage
    'flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
               where fl.status = 'open' and fl.kind = 'flag' and app.manages_scope(me, f.scope_id)),
    'conditions', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                    where fl.status = 'open' and fl.kind = 'condition' and app.manages_scope(me, f.scope_id))
  );
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Every new function is closed by hand, then opened to whom it is for (AGENTS.md)
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.short_code_from(text) from public, anon, authenticated;
revoke execute on function app.suggest_short_code(text, uuid, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function app.scopes_short_code() from public, anon, authenticated;
revoke execute on function app.footprints_happened_on() from public, anon, authenticated;
revoke execute on function app.footprints_manager_reason() from public, anon, authenticated;
revoke execute on function app.footprints_returns_resolve() from public, anon, authenticated;
revoke execute on function app.return_footprint(uuid, text) from public, anon, authenticated;
revoke execute on function app.verify_record(uuid, text, text) from public, anon, authenticated;
revoke execute on function app.seal_source_as_manager(uuid, text) from public, anon, authenticated;
revoke execute on function app.my_actions() from public, anon, authenticated;
revoke execute on function app.client_ledger_page(uuid, text, uuid, uuid, integer, integer) from public, anon, authenticated;
grant execute on function app.suggest_short_code(text, uuid, uuid, text, uuid) to authenticated;
grant execute on function app.return_footprint(uuid, text) to authenticated;
grant execute on function app.verify_record(uuid, text, text) to authenticated;
grant execute on function app.seal_source_as_manager(uuid, text) to authenticated;
grant execute on function app.my_actions() to authenticated;
grant execute on function app.client_ledger_page(uuid, text, uuid, uuid, integer, integer) to authenticated;
