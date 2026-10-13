-- Migration 42 (Veda, 13 Oct 2026, "GrainVeda MVP — State Manager role", part C; FIX_LIST item 37): the crop registry.
-- Release 2 of three. Her answers of 13 Oct:
--   · a crop belongs to one state; the same crop grown in another state is that state's own entry → the code is unique
--     within a state, not across the country
--   · a crop is READY when it has a unit, a yield per acre, at least one quality limit and a recommended chain; a scope
--     is activated only with a ready crop (harvest window, GAP list and export documents are optional)
--   · quality limits are typed: a number (≤, ≥, between), a grade picked from a list (the passing grades marked) or
--     yes/no; the lab's verdict follows the type
--   · good farming practice (GAP) is answered on the farmer's record, per crop; at Procurement a REQUIRED item missing
--     refuses the lot, an optional one is saved with a warning on the lot
--   · procurement outside the crop's harvest window is saved with a warning
--   · the crop's processing stages become its recommended chain (the Client Manager starts from it)
--   · the admin may REMOVE a crop added by mistake only while nothing uses it; a crop in use is RETIRED (kept, hidden
--     from new scopes); the admin may correct the state of a crop nothing uses yet. Every act in the Audit log.
-- Also: the ledger of a state lists everyone who signed its blocks in its "Signed by" filter (it listed only the
-- people the State Manager may see). Additive: new columns, a table, functions and rules; no row is rewritten.

-- 1 · the crop's new fields ------------------------------------------------------------------------------------------------
alter table public.crops add column if not exists yield_per_acre_kg numeric
  check (yield_per_acre_kg is null or (yield_per_acre_kg > 0 and yield_per_acre_kg < 100000));
alter table public.crops add column if not exists recommended_chain public.stage_type[] not null default '{}';
alter table public.crops add column if not exists gap_items jsonb not null default '[]'::jsonb
  check (jsonb_typeof(gap_items) = 'array');
alter table public.crops add column if not exists harvest_from smallint check (harvest_from between 1 and 12);
alter table public.crops add column if not exists harvest_to smallint check (harvest_to between 1 and 12);
alter table public.crops add constraint crops_harvest_both check ((harvest_from is null) = (harvest_to is null));
alter table public.crops add column if not exists export_docs text[] not null default '{}'
  check (array_position(export_docs, '') is null and cardinality(export_docs) <= 30);
alter table public.crops add column if not exists retired_at timestamptz;
alter table public.crops add column if not exists retired_by uuid references public.app_users(id);
alter table public.crops add column if not exists retire_reason text;

-- the code is unique within a state (and among crops that have no state yet)
alter table public.crops drop constraint if exists crops_code_key;
create unique index if not exists crops_state_code_uidx on public.crops (state_id, code) nulls not distinct;

-- 2 · typed quality limits ---------------------------------------------------------------------------------------------------
-- What is wrong with a list of quality limits (empty when nothing). Asked when the list is written, not of old rows.
create or replace function app.quality_params_problems(qp jsonb) returns text[]
language plpgsql immutable set search_path = public as $$
declare p jsonb; t text; seen text[] := '{}'; out text[] := '{}'; k text; opts jsonb; lim jsonb; w text;
begin
  if qp is null or jsonb_typeof(qp) <> 'array' then return array['quality limits must be a list']; end if;
  for p in select * from jsonb_array_elements(qp) loop
    if jsonb_typeof(p) <> 'object' then out := out || 'a quality limit must be an object'; continue; end if;
    k := p->>'param';
    if k is null or k !~ '^[a-z][a-z0-9_]{0,39}$' then out := out || format('quality limit key "%s": small letters, digits and _', coalesce(k, '')); continue; end if;
    if k = any (seen) then out := out || format('quality limit "%s" twice', k); end if;
    seen := seen || k;
    if coalesce(btrim(p->>'label'), '') = '' then out := out || format('quality limit "%s" has no label', k); end if;
    t := coalesce(p->>'type', 'number');
    if t = 'number' then
      if coalesce(p->>'operator', '') not in ('<=', '>=', 'between') then out := out || format('quality limit "%s": rule ≤, ≥ or between', k); end if;
      foreach w in array array['domestic_limit', 'export_limit'] loop
        lim := p->w;
        if p->>'operator' = 'between' then
          if lim is null or jsonb_typeof(lim) <> 'array' or jsonb_array_length(lim) <> 2
             or jsonb_typeof(lim->0) <> 'number' or jsonb_typeof(lim->1) <> 'number' or (lim->>0)::numeric > (lim->>1)::numeric then
            out := out || format('quality limit "%s": %s must be two numbers, low to high', k, replace(w, '_', ' ')); end if;
        elsif lim is null or jsonb_typeof(lim) <> 'number' then
          out := out || format('quality limit "%s": %s must be a number', k, replace(w, '_', ' '));
        end if;
      end loop;
    elsif t = 'grade' then
      opts := p->'options';
      if opts is null or jsonb_typeof(opts) <> 'array' or jsonb_array_length(opts) < 2
         or exists (select 1 from jsonb_array_elements(opts) o where jsonb_typeof(o) <> 'string' or btrim(o #>> '{}') = '')
         or (select count(distinct o #>> '{}') from jsonb_array_elements(opts) o) <> jsonb_array_length(opts) then
        out := out || format('quality limit "%s": at least two different grades', k);
      else
        foreach w in array array['domestic_pass', 'export_pass'] loop
          lim := p->w;
          if lim is null or jsonb_typeof(lim) <> 'array' or jsonb_array_length(lim) = 0
             or exists (select 1 from jsonb_array_elements(lim) g where not (opts @> jsonb_build_array(g))) then
            out := out || format('quality limit "%s": %s must be one or more of its grades', k, replace(w, '_', ' ')); end if;
        end loop;
      end if;
    elsif t = 'yesno' then
      if jsonb_typeof(p->'domestic_pass') is distinct from 'boolean' or jsonb_typeof(p->'export_pass') is distinct from 'boolean' then
        out := out || format('quality limit "%s": say which answer passes, yes or no', k); end if;
    else
      out := out || format('quality limit "%s": type number, grade or yes/no', k);
    end if;
  end loop;
  return out;
end $$;

-- One reading judged by its limit: {value, domestic, export}. A number as before; a grade passes when it is one of the
-- passing grades; yes/no passes when it is the passing answer. Nothing read: pending.
create or replace function app.judge_typed(prm jsonb, readings jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare t text := coalesce(prm->>'type', 'number'); k text := prm->>'param'; v numeric; g text; b boolean; raw jsonb;
begin
  raw := coalesce(readings, '{}'::jsonb) -> k;
  if t = 'grade' then
    g := nullif(btrim(raw #>> '{}'), '');
    return jsonb_build_object('param', k, 'value', g,
      'domestic', case when g is null or prm->'domestic_pass' is null then 'pending' when prm->'domestic_pass' @> jsonb_build_array(g) then 'pass' else 'fail' end,
      'export',   case when g is null or prm->'export_pass' is null then 'pending' when prm->'export_pass' @> jsonb_build_array(g) then 'pass' else 'fail' end);
  elsif t = 'yesno' then
    b := case when jsonb_typeof(raw) = 'boolean' then (raw #>> '{}')::boolean
              when lower(raw #>> '{}') in ('yes', 'true', 'y') then true
              when lower(raw #>> '{}') in ('no', 'false', 'n') then false end;
    return jsonb_build_object('param', k, 'value', b,
      'domestic', case when b is null or jsonb_typeof(prm->'domestic_pass') <> 'boolean' then 'pending' when b = (prm->>'domestic_pass')::boolean then 'pass' else 'fail' end,
      'export',   case when b is null or jsonb_typeof(prm->'export_pass') <> 'boolean' then 'pending' when b = (prm->>'export_pass')::boolean then 'pass' else 'fail' end);
  end if;
  v := app.opt_num(readings, k, null);
  return jsonb_build_object('param', k, 'value', v,
    'domestic', app.judge_param(v, prm->>'operator', prm->'domestic_limit'),
    'export', app.judge_param(v, prm->>'operator', prm->'export_limit'));
end $$;

-- 3 · good farming practice: the crop's list, the farmer's answers -----------------------------------------------------------
create or replace function app.gap_items_problems(items jsonb) returns text[]
language plpgsql immutable set search_path = public as $$
declare i jsonb; k text; seen text[] := '{}'; out text[] := '{}'; t text;
begin
  if items is null or jsonb_typeof(items) <> 'array' then return array['the practice list must be a list']; end if;
  if jsonb_array_length(items) > 40 then out := out || 'at most 40 practices'; end if;
  for i in select * from jsonb_array_elements(items) loop
    k := i->>'key';
    if k is null or k !~ '^[a-z][a-z0-9_]{0,39}$' then out := out || format('practice key "%s": small letters, digits and _', coalesce(k, '')); continue; end if;
    if k = any (seen) then out := out || format('practice "%s" twice', k); end if;
    seen := seen || k;
    if coalesce(btrim(i->>'label'), '') = '' then out := out || format('practice "%s" has no label', k); end if;
    t := coalesce(i->>'type', '');
    if t not in ('date', 'yesno', 'number', 'text', 'choice') then out := out || format('practice "%s": type date, yes/no, number, text or choice', k); end if;
    if t = 'choice' and (jsonb_typeof(i->'options') is distinct from 'array' or jsonb_array_length(i->'options') < 2) then
      out := out || format('practice "%s": a choice needs at least two options', k); end if;
    if i ? 'required' and jsonb_typeof(i->'required') <> 'boolean' then out := out || format('practice "%s": required is yes or no', k); end if;
  end loop;
  return out;
end $$;

-- What a crop still lacks to be used for a scope (empty: ready)
create or replace function app.crop_missing(c public.crops) returns text[]
language sql stable set search_path = public as $$
  select array_remove(array[
    case when coalesce(btrim(c.primary_unit), '') = '' then 'unit' end,
    case when c.yield_per_acre_kg is null then 'yield' end,
    case when jsonb_array_length(coalesce(c.quality_params, '[]'::jsonb)) = 0 then 'limits' end,
    case when cardinality(c.recommended_chain) = 0 then 'chain' end], null) $$;

-- every crop write: its lists are well formed (checked when they are written; old rows are not judged)
create or replace function app.crops_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text[];
begin
  if tg_op = 'INSERT' or new.quality_params is distinct from old.quality_params then
    p := app.quality_params_problems(new.quality_params);
    if cardinality(p) > 0 then raise exception '%', p[1] using errcode = '23514'; end if;
  end if;
  if tg_op = 'INSERT' or new.gap_items is distinct from old.gap_items then
    p := app.gap_items_problems(new.gap_items);
    if cardinality(p) > 0 then raise exception '%', p[1] using errcode = '23514'; end if;
  end if;
  if new.code !~ '^[A-Z]{2,5}$' then raise exception 'a crop code is 2 to 5 capitals' using errcode = '23514'; end if;
  return new;
end $$;
create trigger crops_a1_check before insert or update on public.crops for each row execute function app.crops_check();

-- the recommended chain is a chain this crop may have (asked after the row is written, so its own stages count)
create or replace function app.crops_chain_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare p text[];
begin
  if cardinality(new.recommended_chain) > 0 and (tg_op = 'INSERT' or new.recommended_chain is distinct from old.recommended_chain
                                                   or new.allowed_stages is distinct from old.allowed_stages) then
    p := app.chain_problems(new.recommended_chain, new.id);
    if cardinality(p) > 0 then raise exception 'recommended chain: %', p[1] using errcode = '23514'; end if;
  end if;
  return null;
end $$;
create constraint trigger crops_z1_chain_check after insert or update on public.crops
  for each row execute function app.crops_chain_check();

create table if not exists public.farmer_gap (
  farmer_id  uuid not null references public.farmers(id),
  crop_id    uuid not null references public.crops(id),
  answers    jsonb not null default '{}'::jsonb check (jsonb_typeof(answers) = 'object'),
  updated_by uuid references public.app_users(id),
  updated_at timestamptz not null default now(),
  primary key (farmer_id, crop_id));
alter table public.farmer_gap enable row level security;
create policy farmer_gap_read on public.farmer_gap for select to authenticated using (
  exists (select 1 from public.farmers f where f.id = farmer_id and app.farmer_read(f.client_id, f.state_id)));
grant select on public.farmer_gap to authenticated;
-- written only by app.save_farmer_gap (no insert or update rule for anyone)

-- the farmer's answers for one crop: the whole set, checked against the crop's list; empties dropped. Who: those who add
-- the client's farmers (its Client Manager, Procurement, Village Batch). Logged.
create or replace function app.save_farmer_gap(p_farmer uuid, p_crop uuid, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); fm public.farmers; cr public.crops; i jsonb; k text; v jsonb; clean jsonb := '{}'::jsonb; t text;
begin
  select * into fm from public.farmers where id = p_farmer;
  if me is null or fm.id is null or not app.farmer_read(fm.client_id, fm.state_id) then
    raise exception 'farmer not found' using errcode = 'P0002'; end if;
  if not app.farmer_create(fm.client_id) then
    raise exception 'good farming practice is filled in by the Client Manager (or at Procurement)' using errcode = '42501'; end if;
  select * into cr from public.crops where id = p_crop;
  if cr.id is null then raise exception 'crop not found' using errcode = 'P0002'; end if;
  if cr.retired_at is not null then raise exception 'this crop is retired' using errcode = '23514'; end if;
  if cr.state_id is not null and cr.state_id is distinct from coalesce(fm.state_id, app.client_home(fm.client_id)) then
    raise exception 'this crop belongs to another state' using errcode = '23514'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then raise exception 'answers must be an object' using errcode = '23514'; end if;
  for k, v in select * from jsonb_each(p_answers) loop
    select x into i from jsonb_array_elements(cr.gap_items) x where x->>'key' = k;
    if i is null then raise exception 'practice "%" is not in this crop''s list', k using errcode = '23514'; end if;
    if v is null or jsonb_typeof(v) = 'null' or btrim(v #>> '{}') = '' then continue; end if;
    t := i->>'type';
    if t = 'date' and not ((v #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$') then raise exception '"%": a date (YYYY-MM-DD)', i->>'label' using errcode = '23514'; end if;
    if t = 'yesno' and jsonb_typeof(v) <> 'boolean' then raise exception '"%": yes or no', i->>'label' using errcode = '23514'; end if;
    if t = 'number' and not ((v #>> '{}') ~ '^-?\d+(\.\d+)?$') then raise exception '"%": a number', i->>'label' using errcode = '23514'; end if;
    if t = 'choice' and not (i->'options' @> jsonb_build_array(v #>> '{}')) then raise exception '"%": one of its options', i->>'label' using errcode = '23514'; end if;
    if t = 'text' and length(v #>> '{}') > 200 then raise exception '"%": at most 200 characters', i->>'label' using errcode = '23514'; end if;
    clean := clean || jsonb_build_object(k, case when t = 'number' then to_jsonb((v #>> '{}')::numeric) when t = 'yesno' then v else to_jsonb(btrim(v #>> '{}')) end);
  end loop;
  insert into public.farmer_gap (farmer_id, crop_id, answers, updated_by, updated_at) values (fm.id, cr.id, clean, me, now())
  on conflict (farmer_id, crop_id) do update set answers = excluded.answers, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  perform app.audit('farmer_gap_saved', fm.id, jsonb_build_object('name', fm.name, 'farmer_code', fm.farmer_code,
    'crop', cr.name, 'filled', (select count(*) from jsonb_object_keys(clean)), 'of', jsonb_array_length(cr.gap_items)));
  return jsonb_build_object('answers', clean, 'missing', app.gap_missing(cr.gap_items, clean));
end $$;

-- the practices not answered: {required: [labels], optional: [labels]}
create or replace function app.gap_missing(items jsonb, answers jsonb) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'required', coalesce(jsonb_agg(i->>'label' order by n) filter (where coalesce((i->>'required')::boolean, false)), '[]'::jsonb),
    'optional', coalesce(jsonb_agg(i->>'label' order by n) filter (where not coalesce((i->>'required')::boolean, false)), '[]'::jsonb))
  from jsonb_array_elements(coalesce(items, '[]'::jsonb)) with ordinality as x(i, n)
  where not (coalesce(answers, '{}'::jsonb) ? (i->>'key')) $$;

-- 4 · at Procurement: the farmer's practice for this crop, and the harvest window ---------------------------------------------
create or replace function app.procurement_crop_checks(f public.footprints, sc public.scopes) returns public.footprints
language plpgsql stable security definer set search_path = public as $$
declare cr public.crops; ans jsonb; miss jsonb; m int; inside boolean;
begin
  select * into cr from public.crops where id = sc.crop_id;
  if jsonb_array_length(coalesce(cr.gap_items, '[]'::jsonb)) > 0 then
    select g.answers into ans from public.farmer_gap g where g.farmer_id = f.farmer_id and g.crop_id = cr.id;
    miss := app.gap_missing(cr.gap_items, ans);
    if jsonb_array_length(miss->'required') > 0 then
      raise exception 'good farming practice not complete for this farmer (%): %', cr.name,
        (select string_agg(x, ', ') from jsonb_array_elements_text(miss->'required') x) using errcode = '23514'; end if;
    if jsonb_array_length(miss->'optional') > 0 then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), 'good farming practice not filled: '
        || (select string_agg(x, ', ') from jsonb_array_elements_text(miss->'optional') x)); end if;
  end if;
  if cr.harvest_from is not null then
    m := extract(month from (coalesce(f.captured_at, now()) at time zone 'Asia/Kolkata'))::int;
    inside := case when cr.harvest_from <= cr.harvest_to then m between cr.harvest_from and cr.harvest_to
                   else m >= cr.harvest_from or m <= cr.harvest_to end;
    if not inside then
      f.warnings := array_append(coalesce(f.warnings, '{}'::text[]), format('outside the harvest window (%s–%s)',
        to_char(make_date(2000, cr.harvest_from, 1), 'Mon'), to_char(make_date(2000, cr.harvest_to, 1), 'Mon'))); end if;
  end if;
  return f;
end $$;

-- 5 · a scope's crop: not retired; ready when the scope is activated ---------------------------------------------------------
create or replace function app.scopes_crop_ready() returns trigger
language plpgsql security definer set search_path = public as $$
declare cr public.crops; miss text[];
begin
  if auth.uid() is null then return new; end if;                     -- a person acting (not a seed or a migration)
  select * into cr from public.crops where id = new.crop_id;
  if cr.id is null then return new; end if;                          -- the foreign key answers that
  if cr.retired_at is not null and (tg_op = 'INSERT' or new.crop_id is distinct from old.crop_id
                                    or (old.status = 'draft' and new.status = 'active')) then
    raise exception 'this crop is retired' using errcode = '23514'; end if;
  if new.status = 'active' and (tg_op = 'INSERT' or old.status = 'draft') then
    miss := app.crop_missing(cr);
    if cardinality(miss) > 0 then
      raise exception 'this crop is not ready: % (the State Manager completes it under Crops)', array_to_string(miss, ', ') using errcode = '23514'; end if;
  end if;
  return new;
end $$;
create trigger scopes_a2_crop_ready before insert or update on public.scopes for each row execute function app.scopes_crop_ready();

-- 6 · what a crop is used by ---------------------------------------------------------------------------------------------------
create or replace function app.crop_use(p_crop uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'scopes_active', (select count(*) from public.scopes s where s.crop_id = p_crop and s.status = 'active'),
    'scopes_setup', (select count(*) from public.scopes s where s.crop_id = p_crop and s.status = 'draft'),
    'scopes_closed', (select count(*) from public.scopes s where s.crop_id = p_crop and s.status not in ('active', 'draft')),
    'farmers_gap', (select count(*) from public.farmer_gap g where g.crop_id = p_crop)) $$;

-- the registry as the Crops page shows it: every crop (a State Manager: his states' and those with no state), its state,
-- whether it is ready and what it lacks, what uses it
create or replace function app.crop_registry() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); mine uuid[];
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  mine := case when app.sm_limited() then app.my_state_ids() end;
  return coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object(
            'state_name', st.name, 'missing', to_jsonb(app.crop_missing(c)), 'ready', cardinality(app.crop_missing(c)) = 0 and c.retired_at is null,
            'use', app.crop_use(c.id), 'retired_by_name', u.display_name)
          order by c.retired_at is not null, c.name, st.name)
     from public.crops c left join public.states st on st.id = c.state_id left join public.app_users u on u.id = c.retired_by
    where mine is null or c.state_id is null or c.state_id = any (mine)), '[]'::jsonb);
end $$;

-- 7 · the admin's three acts on a crop added by mistake (Veda, 13 Oct) ---------------------------------------------------------
create or replace function app.crop_in_use(p_crop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.scopes where crop_id = p_crop) or exists (select 1 from public.farmer_gap where crop_id = p_crop) $$;

create or replace function app.remove_crop(p_crop uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare cr public.crops;
begin
  if app.current_user_id() is null or not app.is_admin() then
    raise exception 'only the admin removes a crop' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into cr from public.crops where id = p_crop for update;
  if cr.id is null then raise exception 'crop not found' using errcode = 'P0002'; end if;
  if app.crop_in_use(p_crop) then
    raise exception 'this crop is in use (a scope or a farmer''s practice): retire it instead' using errcode = '23514'; end if;
  perform app.audit('crop_removed', cr.id, jsonb_build_object('name', cr.name, 'code', cr.code,
    'state', (select name from public.states where id = cr.state_id), 'reason', btrim(p_reason)), true);
  delete from public.crops where id = p_crop;
end $$;

create or replace function app.retire_crop(p_crop uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare cr public.crops;
begin
  if app.current_user_id() is null or not app.is_admin() then
    raise exception 'only the admin retires a crop' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into cr from public.crops where id = p_crop for update;
  if cr.id is null then raise exception 'crop not found' using errcode = 'P0002'; end if;
  if cr.retired_at is not null then raise exception 'this crop is already retired' using errcode = '23514'; end if;
  update public.crops set retired_at = now(), retired_by = app.current_user_id(), retire_reason = btrim(p_reason) where id = p_crop;
  perform app.audit('crop_retired', cr.id, jsonb_build_object('name', cr.name, 'code', cr.code,
    'state', (select name from public.states where id = cr.state_id), 'reason', btrim(p_reason)), true);
end $$;

create or replace function app.correct_crop_state(p_crop uuid, p_state uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare cr public.crops;
begin
  if app.current_user_id() is null or not app.is_admin() then
    raise exception 'only the admin corrects a crop''s state' using errcode = '42501'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'a reason is required' using errcode = '23514'; end if;
  select * into cr from public.crops where id = p_crop for update;
  if cr.id is null then raise exception 'crop not found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.states where id = p_state) then raise exception 'state not found' using errcode = 'P0002'; end if;
  if cr.state_id is not distinct from p_state then raise exception 'the crop is already of this state' using errcode = '23514'; end if;
  if app.crop_in_use(p_crop) then
    raise exception 'this crop is in use (a scope or a farmer''s practice): its state stays' using errcode = '23514'; end if;
  perform set_config('app.crop_state_fix', 'on', true);
  update public.crops set state_id = p_state where id = p_crop;
  perform set_config('app.crop_state_fix', 'off', true);
  perform app.audit('crop_state_corrected', cr.id, jsonb_build_object('name', cr.name, 'code', cr.code,
    'from', coalesce((select name from public.states where id = cr.state_id), ''), 'to', (select name from public.states where id = p_state),
    'reason', btrim(p_reason)), true);
end $$;



-- 8 · functions brought up to these rules (their current definitions, changed where marked) -----------------------

CREATE OR REPLACE FUNCTION app.judge_readings(p_scope uuid, p_readings jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare qp jsonb; prm jsonb; jt jsonb; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select coalesce(s.quality_params, c.quality_params) into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = p_scope;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    jt := app.judge_typed(prm, p_readings);                     -- migration 42: a number, a grade or yes/no
    dv := (jt->>'domestic')::public.verdict; ev := (jt->>'export')::public.verdict;
    judged := judged || jt;
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  return jsonb_build_object('domestic', dom, 'export', exp, 'judged', judged);
end $function$;

CREATE OR REPLACE FUNCTION app.derive_qc_verdict(f footprints)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare qp jsonb; prm jsonb; jt jsonb; dv public.verdict; ev public.verdict;
        dom public.verdict := 'pass'; exp public.verdict := 'pass'; judged jsonb := '[]'::jsonb;
begin
  select coalesce(s.quality_params, c.quality_params) into qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = f.scope_id;
  if qp is null or jsonb_array_length(qp) = 0 then dom := 'pending'; exp := 'pending'; end if;
  for prm in select * from jsonb_array_elements(coalesce(qp, '[]'::jsonb)) loop
    jt := app.judge_typed(prm, f.payload->'readings');                     -- migration 42: a number, a grade or yes/no
    dv := (jt->>'domestic')::public.verdict; ev := (jt->>'export')::public.verdict;
    judged := judged || jt;
    if dv = 'fail' then dom := 'fail'; elsif dv = 'pending' and dom <> 'fail' then dom := 'pending'; end if;
    if ev = 'fail' then exp := 'fail'; elsif ev = 'pending' and exp <> 'fail' then exp := 'pending'; end if;
  end loop;
  insert into public.qc_verdicts (footprint_id, domestic_verdict, export_verdict, readings, judged)
  values (f.id, dom, exp, coalesce(f.payload->'readings', '{}'::jsonb), judged);
end $function$;

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

CREATE OR REPLACE FUNCTION app.crops_state_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null and tg_op = 'UPDATE' and coalesce(current_setting('app.crop_state_fix', true), '') <> 'on'
     and old.state_id is not null and new.state_id is distinct from old.state_id then
    raise exception 'a crop''s state is set once' using errcode = '42501'; end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.crops_audit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare k text[];
begin
  if app.current_user_id() is null then return new; end if;
  if tg_op = 'INSERT' then
    perform app.audit('crop_added', new.id, jsonb_build_object('name', new.name, 'code', new.code,
      'state', (select name from public.states where id = new.state_id)));
    return new;
  end if;
  if old.state_id is null and new.state_id is not null and coalesce(current_setting('app.crop_state_fix', true), '') <> 'on' then
    perform app.audit('crop_state_set', new.id, jsonb_build_object('name', new.name, 'code', new.code,
      'from', '', 'to', (select name from public.states where id = new.state_id)));
  end if;
  select coalesce(array_agg(key order by key), '{}') into k
    from jsonb_each(to_jsonb(new)) n where key not in ('state_id', 'created_at', 'retired_at', 'retired_by', 'retire_reason') and n.value is distinct from to_jsonb(old) -> key;
  if cardinality(k) > 0 then
    perform app.audit('crop_changed', new.id, jsonb_build_object('name', new.name, 'code', new.code, 'fields', to_jsonb(k)));
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.state_home(p_state uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); r jsonb;
begin
  if me is null or not (app.is_admin() or p_state = any (app.my_state_ids())) then
    raise exception 'no access to this state' using errcode = '42501'; end if;
  if not exists (select 1 from public.states where id = p_state) then raise exception 'state not found' using errcode = 'P0002'; end if;
  with sc as (select s.* from public.scopes s where s.state_id = p_state),
  live as (
    select distinct sa.scope_id, sa.stage_type
      from public.slot_assignments sa
      join public.assignments a on a.id = sa.assignment_id
      join public.app_users u on u.id = sa.user_id
     where a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active' and u.system_role <> 'admin'
       and sa.scope_id in (select id from sc)),
  gaps as (
    select s.id as scope_id, s.client_id, x.st as stage_type
      from sc s cross join lateral unnest(s.chain) as x(st)
     where s.status = 'active' and not exists (select 1 from live l where l.scope_id = s.id and l.stage_type = x.st)),
  vol as (
    select f.scope_id, sum(f.qty_out) as kg, count(*) as lots
      from public.footprints f
     where f.stage_type in ('procurement', 'lot_inward') and f.status <> 'superseded' and f.scope_id in (select id from sc)
     group by f.scope_id),
  qr as (
    select f.scope_id, count(*) as n from public.qr_seals q join public.footprints f on f.id = q.footprint_id
     where f.scope_id in (select id from sc) group by f.scope_id),
  waiting as (
    select f.scope_id, count(*) as n from public.footprints f
     where f.status = 'pending' and f.scope_id in (select id from sc) group by f.scope_id),
  people as (
    select x.client_id, count(distinct x.employee_id) as n from (
      select a.client_id, a.employee_id from public.assignments a join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'client' and u.status = 'active' and u.system_role <> 'admin'
      union
      select s.client_id, a.employee_id from public.assignments a join sc s on s.id = a.scope_id
        join public.app_users u on u.id = a.employee_id
       where a.active and a.lens = 'scope' and u.status = 'active' and u.system_role <> 'admin') x group by x.client_id),
  mgr as (
    select a.client_id, string_agg(distinct u.display_name, ', ') as names
      from public.assignments a join public.app_users u on u.id = a.employee_id
     where a.active and a.lens = 'client' and a.op_role = 'client_account' and u.status = 'active'
       and (a.ends_on is null or a.ends_on >= app.today())
     group by a.client_id),
  cl as (
    select c.id, c.name, c.code, c.type, c.state_id, st.name as state_name,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'active') as scopes_active,
           (select count(*) from sc s where s.client_id = c.id and s.status = 'draft') as scopes_setup,
           (select count(*) from sc s where s.client_id = c.id) as scopes_total,
           coalesce((select sum(v.kg) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as kg,
           coalesce((select sum(v.lots) from vol v join sc s on s.id = v.scope_id where s.client_id = c.id), 0) as lots,
           coalesce((select sum(q.n) from qr q join sc s on s.id = q.scope_id where s.client_id = c.id), 0) as qr,
           coalesce((select p.n from people p where p.client_id = c.id), 0) as people,
           (select count(*) from gaps g where g.client_id = c.id) as unstaffed,
           coalesce((select sum(w.n) from waiting w join sc s on s.id = w.scope_id where s.client_id = c.id), 0) as waiting,
           (select m.names from mgr m where m.client_id = c.id) as managers,
           exists (select 1 from mgr m where m.client_id = c.id) as has_manager
      from public.clients c left join public.states st on st.id = c.state_id
     where c.state_id = p_state or exists (select 1 from sc s where s.client_id = c.id)),
  fw as (
    select f.id, f.name, f.village, f.client_id, c.name as client
      from public.farmers f join public.clients c on c.id = f.client_id
     where f.status = 'under_review' and f.reviewed_by is not null and coalesce(f.state_id, c.state_id) = p_state),
  fl as (
    select fl.id, fl.text, fl.created_at, fl.footprint_id, f.footprint_code, c.name as client
      from public.flags fl join public.footprints f on f.id = fl.footprint_id join public.clients c on c.id = f.client_id
     where fl.status = 'open' and f.scope_id in (select id from sc)),
  pipe as (
    select d.stage_type, d.label, d.sort_order,
           count(f.id) filter (where f.status = 'pending') as pending,
           count(f.id) filter (where f.status in ('verified', 'closed')) as done,
           coalesce(sum(f.qty_out) filter (where f.status = 'pending'), 0) as kg_pending,
           coalesce(sum(f.qty_out) filter (where f.status in ('verified', 'closed')), 0) as kg_done,
           min(coalesce(f.captured_at, f.created_at)) filter (where f.status = 'pending') as oldest_pending
      from public.stage_definitions d
      left join public.footprints f on f.stage_type = d.stage_type and f.status <> 'superseded'
           and exists (select 1 from sc s where s.id = f.scope_id and s.status = 'active')
     group by d.stage_type, d.label, d.sort_order),
  -- chain order, as on the admin's pipeline: each stage's average step in the active chains of the state; the seal last
  pipe_pos as (
    select p.*, case when p.stage_type = 'qr_activation' and exists (select 1 from sc s where s.status = 'active') then 1000
                     else (select round(avg(array_position(s.chain, p.stage_type) - 1), 2)
                             from sc s where s.status = 'active' and p.stage_type = any (s.chain)) end as position
      from pipe p)
  select jsonb_build_object(
    'state', (select jsonb_build_object('id', id, 'name', name, 'code', code) from public.states where id = p_state),
    'managers', coalesce((select jsonb_agg(u.display_name order by u.display_name) from public.assignments a join public.app_users u on u.id = a.employee_id
                           where a.active and a.lens = 'state' and a.state_id = p_state and u.status = 'active'), '[]'),
    'clients', jsonb_build_object(
       'total', (select count(*) from cl where cl.state_id = p_state),
       'active', (select count(*) from cl where cl.state_id = p_state and scopes_active > 0),
       'without_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'list', coalesce((select jsonb_agg(to_jsonb(cl) order by cl.name) from cl), '[]')),
    'crops', jsonb_build_object(
       'total', (select count(*) from public.crops where state_id = p_state),
       'state_not_set', (select count(*) from public.crops where state_id is null),
       'ready', (select count(*) from public.crops cr where cr.state_id = p_state and cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name, 'code', cr.code,
                  'scopes_active', (select count(*) from sc s where s.crop_id = cr.id and s.status = 'active'),
                  'scopes_total', (select count(*) from sc s where s.crop_id = cr.id),
                  'ready', cr.retired_at is null and cardinality(app.crop_missing(cr)) = 0, 'missing', to_jsonb(app.crop_missing(cr))) order by cr.name)
                  from public.crops cr where cr.state_id = p_state), '[]')),
    'scopes', jsonb_build_object(
       'active', (select count(*) from sc where status = 'active'),
       'setup', (select count(*) from sc where status = 'draft'),
       'closed', (select count(*) from sc where status = 'closed'),
       'qr_issued', coalesce((select sum(n) from qr), 0),
       'list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', s.id, 'client', c.name, 'crop', cr.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'status', s.status) order by s.status, c.name)
                  from sc s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id), '[]')),
    'farmers', jsonb_build_object(
       'total', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id where coalesce(f.state_id, c.state_id) = p_state),
       'active', (select count(*) from public.farmers f join public.clients c on c.id = f.client_id
                   where coalesce(f.state_id, c.state_id) = p_state and f.status = 'active')),
    'attention', jsonb_build_object(
       'no_manager', (select count(*) from cl where cl.state_id = p_state and not has_manager),
       'no_manager_list', coalesce((select jsonb_agg(jsonb_build_object('id', cl.id, 'name', cl.name, 'code', cl.code) order by cl.name)
                                      from cl where cl.state_id = p_state and not has_manager), '[]'),
       'farmers_waiting', (select count(*) from fw),
       'farmers_list', coalesce((select jsonb_agg(to_jsonb(fw) order by fw.client, fw.name) from (select * from fw order by client, name limit 50) fw), '[]'),
       'unstaffed', (select count(*) from gaps),
       'unstaffed_list', coalesce((select jsonb_agg(jsonb_build_object('scope_id', g.scope_id, 'client_id', c.id, 'client', c.name,
                  'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography), 'stage_type', g.stage_type, 'stage', d.label)
                  order by c.name, s.geography, d.sort_order)
                  from gaps g join sc s on s.id = g.scope_id join public.clients c on c.id = s.client_id
                  join public.crops cr on cr.id = s.crop_id join public.stage_definitions d on d.stage_type = g.stage_type), '[]'),
       'open_flags', (select count(*) from fl),
       'flags_list', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'created_at', fl.created_at,
                  'footprint_id', fl.footprint_id, 'record', fl.footprint_code, 'client', fl.client) order by fl.created_at) from fl), '[]')),
    'pipeline', coalesce((select jsonb_agg(to_jsonb(pp) order by pp.position nulls last, pp.sort_order) from pipe_pos pp
                           where pp.position is not null or pp.pending + pp.done > 0), '[]')
  ) into r;
  return r;
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
    select l.*, f.footprint_code, f.stage_type,
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
            'actor', m.actor, 'actor_name', u.display_name, 'actor_role', u.system_role, 'actor_summary_role', u.role)
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

-- 9 · closed by default; opened by name ----------------------------------------------------------------------------------
revoke execute on function app.quality_params_problems(jsonb) from public, anon, authenticated;
revoke execute on function app.judge_typed(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function app.gap_items_problems(jsonb) from public, anon, authenticated;
revoke execute on function app.crop_missing(public.crops) from public, anon, authenticated;
revoke execute on function app.crops_check() from public, anon, authenticated;
revoke execute on function app.crops_chain_check() from public, anon, authenticated;
revoke execute on function app.save_farmer_gap(uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function app.gap_missing(jsonb, jsonb) from public, anon, authenticated;
revoke execute on function app.procurement_crop_checks(public.footprints, public.scopes) from public, anon, authenticated;
revoke execute on function app.scopes_crop_ready() from public, anon, authenticated;
revoke execute on function app.crop_use(uuid) from public, anon, authenticated;
revoke execute on function app.crop_registry() from public, anon, authenticated;
revoke execute on function app.crop_in_use(uuid) from public, anon, authenticated;
revoke execute on function app.remove_crop(uuid, text) from public, anon, authenticated;
revoke execute on function app.retire_crop(uuid, text) from public, anon, authenticated;
revoke execute on function app.correct_crop_state(uuid, uuid, text) from public, anon, authenticated;

grant execute on function app.save_farmer_gap(uuid, uuid, jsonb) to authenticated;
grant execute on function app.crop_registry() to authenticated;
grant execute on function app.remove_crop(uuid, text) to authenticated;
grant execute on function app.retire_crop(uuid, text) to authenticated;
grant execute on function app.correct_crop_state(uuid, uuid, text) to authenticated;
