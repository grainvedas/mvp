-- Migration 64 (Phase 2, release 1 of Veda's combined brief of 19 Oct 2026: Part A and Part B). One legal entity, one
-- record, keyed on PAN; the ID checks; the client's three gates (Prospect, Diagnostic, Active) per state; the admin's
-- approval of the first activation; existing clients moved across with "PAN pending".
--
--   A1  public.entities: every business GrainVeda deals with; PAN is its key (a keyed fingerprint here, the number itself
--       only in public.entity_ids). public.entity_roles: client, sourcing partner, buyer (internal to GrainVeda).
--   A2  app.lookup_pan: "Already registered with GrainVeda" / "Known to GrainVeda as a business" / a similar name (a soft
--       warning). app.create_client refuses a second client for one PAN. PAN, GSTIN, CIN, LLPIN, FSSAI and IEC formats
--       are checked; the PAN's 4th letter against the entity type; a GSTIN against the PAN and the state's GST code.
--   A3  the numbers in full only in public.entity_ids (no grant: read through functions by the admin and the client's own
--       State Managers); masked everywhere else; audit lines and change-log lines carry a keyed hash, never a number.
--   A4  app.client_identity: what a State Manager of another state sees (legal name, masked PAN, entity type, registered
--       office city and state, overall status, client code); app.client_view: the full record, by who reads what.
--   B1–B3  the gates per state (public.client_states), their checklist (app.client_gates: "3 of 7 done"), the documents
--       (public.client_documents, bucket client-docs), the KYC tick, the moves, the admin's approval of the first Active.
--   B4  the scope: a scope is prepared only with its client in Diagnostic or Active in that state and activated only with
--       it Active; an export scope needs the IEC (and the APEDA RCMC for a scheduled crop: public.crops.apeda_scheduled).
--   B5  who fills what: the State Manager (his state), the admin (approval; national identity after Active), the Client
--       Manager (reads his state's record and the contacts), the client's own login (reads everything of its company).
-- Additive: new tables, columns and functions; public.clients keeps its rows and codes (no code is regenerated); direct
-- writes to public.clients by a signed-in person are refused from here on (the State Manager uses app.create_client).

-- 0 · the keyed fingerprint ------------------------------------------------------------------------------------------
-- The key is made here, once, and kept in a table nobody but the database owner reads (no grant to anon or
-- authenticated); app.id_hash is the only reader. A PAN has too few possibilities for a plain hash to hide it.
create table if not exists app.registry_secret (k bytea not null);
revoke all on app.registry_secret from public;
do $$ begin
  if not exists (select 1 from app.registry_secret) then
    -- pgcrypto is in "extensions" on a hosted project, in "public" on a plain database
    perform set_config('search_path', 'public, extensions', true);
    insert into app.registry_secret (k) values (gen_random_bytes(32));
  end if;
end $$;

create or replace function app.id_hash(p_kind text, p_value text) returns text
language sql stable security definer set search_path = public, extensions as $$
  select encode(hmac(convert_to(lower(p_kind) || ':' || upper(btrim(p_value)), 'UTF8'), (select k from app.registry_secret limit 1), 'sha256'), 'hex')
$$;

-- masked forms: a PAN as ABCDE****F, a GSTIN with its PAN part masked, any other number to its last four
create or replace function app.mask_id(p_kind text, p_value text) returns text
language sql immutable set search_path = public as $$
  select case
    when p_value is null then null
    when p_kind in ('pan', 'iec') and length(p_value) = 10 then left(p_value, 5) || '****' || right(p_value, 1)
    when p_kind = 'gstin' and length(p_value) = 15 then left(p_value, 7) || '****' || right(p_value, 4)
    when length(p_value) <= 4 then repeat('*', length(p_value))
    else repeat('*', least(length(p_value) - 4, 12)) || right(p_value, 4) end
$$;

-- 1 · types ------------------------------------------------------------------------------------------------------------
do $$ begin
  if to_regtype('public.entity_type') is null then
    create type public.entity_type as enum ('company', 'llp', 'firm', 'individual', 'trust', 'society', 'cooperative', 'huf', 'government');
  end if;
  if to_regtype('public.entity_role') is null then
    create type public.entity_role as enum ('client', 'sourcing_partner', 'buyer');
  end if;
  if to_regtype('public.client_status') is null then
    create type public.client_status as enum ('prospect', 'diagnostic', 'active', 'suspended', 'ended');
  end if;
  if to_regtype('public.id_kind') is null then
    create type public.id_kind as enum ('pan', 'gstin', 'cin', 'llpin', 'reg_no', 'iec', 'fssai', 'rcmc');
  end if;
  if to_regtype('public.client_doc_kind') is null then
    create type public.client_doc_kind as enum ('diagnostic_order', 'incorporation', 'msa', 'consent_addendum',
      'signatory_authority', 'fssai', 'iec', 'rcmc', 'gst_reason');
  end if;
end $$;

-- 2 · tables -----------------------------------------------------------------------------------------------------------
create table if not exists public.entities (
  id            uuid primary key default gen_random_uuid(),
  legal_name    text not null check (length(btrim(legal_name)) between 2 and 200),
  trade_name    text check (trade_name is null or length(btrim(trade_name)) between 1 and 200),
  entity_type   public.entity_type not null,
  pan_hash      text,                                   -- app.id_hash('pan', …); null while the PAN is pending
  pan_masked    text,
  pan_pending   boolean not null default false,
  reg_office    jsonb not null default '{}'::jsonb,     -- {address, city, state}
  own_brand     boolean not null default false,         -- Part F: "Own brand of GrainVeda"
  created_at    timestamptz not null default now(),
  created_by    uuid,
  check (pan_pending = (pan_hash is null))
);
create unique index if not exists entities_pan_once on public.entities (pan_hash) where pan_hash is not null;

create table if not exists public.entity_roles (
  entity_id  uuid not null references public.entities(id),
  role       public.entity_role not null,
  since      timestamptz not null default now(),
  primary key (entity_id, role)
);

-- the numbers themselves: no grant to anyone; read only through app.client_view (admin and the client's State Managers)
create table if not exists public.entity_ids (
  id          uuid primary key default gen_random_uuid(),
  entity_id   uuid not null references public.entities(id),
  kind        public.id_kind not null,
  state_id    uuid references public.states(id),      -- a GSTIN or an FSSAI licence is a state's; the rest national
  value       text not null,
  hash        text not null,
  masked      text not null,
  expires_on  date,
  current     boolean not null default true,
  created_at  timestamptz not null default now(),
  created_by  uuid
);
create unique index if not exists entity_ids_one_current on public.entity_ids (entity_id, kind, coalesce(state_id, '00000000-0000-0000-0000-000000000000'::uuid)) where current;
create unique index if not exists entity_ids_pan_once on public.entity_ids (hash) where current and kind = 'pan';
create unique index if not exists entity_ids_gstin_once on public.entity_ids (hash) where current and kind = 'gstin';

alter table public.clients add column if not exists entity_id uuid references public.entities(id);
alter table public.clients add column if not exists contact jsonb not null default '{}'::jsonb;          -- {name, designation, phone, email}
alter table public.clients add column if not exists states_of_interest uuid[] not null default '{}';
alter table public.clients add column if not exists crops_of_interest uuid[] not null default '{}';
alter table public.clients add column if not exists source text;                                        -- referral, outreach, event, inbound
alter table public.clients add column if not exists approved_at timestamptz;                            -- the admin's approval of the first Active
alter table public.clients add column if not exists approved_by uuid;
alter table public.clients add column if not exists code_edited boolean not null default false;         -- "editable once by Admin before Active"
alter table public.clients add column if not exists created_by uuid;

create table if not exists public.client_states (
  client_id                 uuid not null references public.clients(id),
  state_id                  uuid not null references public.states(id),
  status                    public.client_status not null default 'prospect',
  legacy                    boolean not null default false,   -- an existing test client kept Active with "PAN pending"
  gst_not_registered_reason text,
  signatory                 jsonb not null default '{}'::jsonb,  -- {name, designation}
  billing                   jsonb not null default '{}'::jsonb,  -- {contact, email}
  address                   jsonb not null default '{}'::jsonb,  -- the state's address {address, city}
  state_contact             jsonb not null default '{}'::jsonb,  -- {name, designation, phone, email}
  brand_on_pack             boolean not null default false,      -- the client's name on the pack as brand owner or marketer
  kyc_by                    uuid,
  kyc_at                    timestamptz,
  activation_requested_at   timestamptz,
  activation_requested_by   uuid,
  status_changed_at         timestamptz not null default now(),
  created_at                timestamptz not null default now(),
  created_by                uuid,
  primary key (client_id, state_id)
);

create table if not exists public.client_documents (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references public.clients(id),
  state_id     uuid references public.states(id),       -- null: a national document
  kind         public.client_doc_kind not null,
  path         text not null unique,                    -- bucket client-docs: "<client id>/<file id>.<ext>"
  file_name    text,
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bytes        bigint not null check (bytes > 0),
  signed_on    date,
  term_end     date,
  expires_on   date,
  amount       numeric check (amount is null or amount >= 0),
  created_at   timestamptz not null default now(),
  created_by   uuid,
  superseded_at timestamptz,
  superseded_by uuid
);
create unique index if not exists client_documents_one_current on public.client_documents (client_id, kind, coalesce(state_id, '00000000-0000-0000-0000-000000000000'::uuid)) where superseded_at is null;

create table if not exists public.client_status_events (
  id          bigserial primary key,
  client_id   uuid not null references public.clients(id),
  state_id    uuid references public.states(id),
  from_status public.client_status,
  to_status   public.client_status,
  act         text not null,                            -- created, migrated, diagnostic, requested, approved, declined, active, kyc
  reason      text,
  at          timestamptz not null default now(),
  by_user     uuid
);

alter table public.states add column if not exists gst_code text check (gst_code is null or gst_code ~ '^[0-9]{2}$');
alter table public.crops add column if not exists apeda_scheduled boolean not null default false;

-- every new table: functions only (no grant), the change log (a hash of the row, never its numbers), append-only events
do $$ declare t text; begin
  foreach t in array array['entities', 'entity_roles', 'entity_ids', 'client_states', 'client_documents', 'client_status_events'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
revoke all on sequence public.client_status_events_id_seq from anon, authenticated;
drop trigger if exists zz_change_log on public.entities;
create trigger zz_change_log after insert or update or delete on public.entities for each row execute function app.log_change('id');
drop trigger if exists zz_change_log on public.entity_roles;
create trigger zz_change_log after insert or update or delete on public.entity_roles for each row execute function app.log_change('entity_id', 'role');
drop trigger if exists zz_change_log on public.entity_ids;
create trigger zz_change_log after insert or update or delete on public.entity_ids for each row execute function app.log_change('id');
drop trigger if exists zz_change_log on public.client_states;
create trigger zz_change_log after insert or update or delete on public.client_states for each row execute function app.log_change('client_id', 'state_id');
drop trigger if exists zz_change_log on public.client_documents;
create trigger zz_change_log after insert or update or delete on public.client_documents for each row execute function app.log_change('id');
drop trigger if exists zz_change_log on public.client_status_events;
create trigger zz_change_log after insert or update or delete on public.client_status_events for each row execute function app.log_change('id');

create or replace function app.no_update_delete() returns trigger
language plpgsql set search_path = public as $$
begin raise exception '%: append-only', tg_table_name using errcode = '42501'; end $$;
drop trigger if exists client_status_events_append_only on public.client_status_events;
create trigger client_status_events_append_only before update or delete on public.client_status_events
  for each row execute function app.no_update_delete();
-- a number is never rewritten: a new one is a new row, the old one made "not current"
create or replace function app.entity_ids_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then raise exception 'entity_ids: a number is never deleted (a new one replaces it)' using errcode = '42501'; end if;
  if new.value is distinct from old.value or new.hash is distinct from old.hash or new.kind is distinct from old.kind
     or new.entity_id is distinct from old.entity_id or new.state_id is distinct from old.state_id or (old.current = false and new.current) then
    raise exception 'entity_ids: a number is never rewritten (a new one replaces it)' using errcode = '42501'; end if;
  return new;
end $$;
drop trigger if exists entity_ids_a0_guard on public.entity_ids;
create trigger entity_ids_a0_guard before update or delete on public.entity_ids for each row execute function app.entity_ids_guard();

-- 3 · the states' GST codes (the first two digits of a GSTIN) --------------------------------------------------------
create or replace function app.gst_code_for(p_name text) returns text
language sql immutable as $$
  select g.code from (values
  ('jammu and kashmir', '01'), ('himachal pradesh', '02'), ('punjab', '03'), ('chandigarh', '04'), ('uttarakhand', '05'),
  ('haryana', '06'), ('delhi', '07'), ('rajasthan', '08'), ('uttar pradesh', '09'), ('bihar', '10'), ('sikkim', '11'),
  ('arunachal pradesh', '12'), ('nagaland', '13'), ('manipur', '14'), ('mizoram', '15'), ('tripura', '16'), ('meghalaya', '17'),
  ('assam', '18'), ('west bengal', '19'), ('jharkhand', '20'), ('odisha', '21'), ('chhattisgarh', '22'), ('madhya pradesh', '23'),
  ('gujarat', '24'), ('dadra and nagar haveli and daman and diu', '26'), ('maharashtra', '27'), ('karnataka', '29'), ('goa', '30'),
  ('lakshadweep', '31'), ('kerala', '32'), ('tamil nadu', '33'), ('puducherry', '34'), ('andaman and nicobar islands', '35'),
  ('telangana', '36'), ('andhra pradesh', '37'), ('ladakh', '38')) as g(name, code) where g.name = lower(btrim(p_name))
$$;
update public.states set gst_code = app.gst_code_for(name) where gst_code is null;
-- a state added later (or by a seed) gets its code from its name; the admin sets it for any other
create or replace function app.states_gst_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.gst_code is null then new.gst_code := app.gst_code_for(new.name); end if;
  return new;
end $$;
drop trigger if exists states_a1_gst_code on public.states;
create trigger states_a1_gst_code before insert or update of name on public.states for each row execute function app.states_gst_code();

-- rice is an APEDA-scheduled product (its export needs the RCMC); the State Manager ticks it for any other crop
update public.crops set apeda_scheduled = true where (name ilike '%rice%' or name ilike '%paddy%') and not apeda_scheduled;

-- 4 · the checks ------------------------------------------------------------------------------------------------------
create or replace function app.pan_letter(p_type public.entity_type) returns text
language sql immutable as $$
  select case p_type when 'company' then 'C' when 'llp' then 'F' when 'firm' then 'F' when 'individual' then 'P'
    when 'trust' then 'T' when 'society' then 'A' when 'cooperative' then 'A' when 'huf' then 'H' when 'government' then 'G' end
$$;

create or replace function app.norm_id(p_value text) returns text
language sql immutable as $$ select nullif(upper(regexp_replace(coalesce(p_value, ''), '\s', '', 'g')), '') $$;

create or replace function app.check_pan(p_pan text, p_type public.entity_type) returns text
language plpgsql immutable set search_path = public as $$
declare v text := app.norm_id(p_pan);
begin
  if v is null or v !~ '^[A-Z]{5}[0-9]{4}[A-Z]$' then
    raise exception 'PAN: 5 letters, 4 digits, 1 letter (like ABCDE1234F)' using errcode = '22023'; end if;
  if p_type is not null and substr(v, 4, 1) <> app.pan_letter(p_type) then
    raise exception 'PAN: its 4th letter is % but a % has % there: choose the right type or check the PAN',
      substr(v, 4, 1), replace(p_type::text, '_', ' '), app.pan_letter(p_type) using errcode = '22023'; end if;
  return v;
end $$;

create or replace function app.check_gstin(p_gstin text, p_pan text, p_state uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := app.norm_id(p_gstin); v_code text; v_state text;
begin
  if v is null or v !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then
    raise exception 'GSTIN: 15 characters: the state''s 2 digits, the PAN, then 3 more (like 09ABCDE1234F1Z5)' using errcode = '22023'; end if;
  if p_pan is not null and substr(v, 3, 10) <> p_pan then
    raise exception 'GSTIN: characters 3 to 12 must be this client''s PAN' using errcode = '22023'; end if;
  select gst_code, name into v_code, v_state from public.states where id = p_state;
  if v_code is null then
    raise exception 'GSTIN: % has no GST state code yet (the admin sets it under States)', coalesce(v_state, 'this state') using errcode = '22023'; end if;
  if left(v, 2) <> v_code then
    raise exception 'GSTIN: it starts with %, which is not % (%)', left(v, 2), v_state, v_code using errcode = '22023'; end if;
  return v;
end $$;

create or replace function app.check_number(p_kind public.id_kind, p_value text) returns text
language plpgsql immutable set search_path = public as $$
declare v text := app.norm_id(p_value);
begin
  if v is null then raise exception '%: the number is empty', upper(p_kind::text) using errcode = '22023'; end if;
  if p_kind = 'cin' and v !~ '^[LU][0-9]{5}[A-Z]{2}[0-9]{4}[A-Z]{3}[0-9]{6}$' then
    raise exception 'CIN: 21 characters (like U01100UP2025PTC123456)' using errcode = '22023'; end if;
  if p_kind = 'llpin' and v !~ '^[A-Z]{3}-[0-9]{4}$' then
    raise exception 'LLPIN: 3 letters, a dash, 4 digits (like AAB-1234)' using errcode = '22023'; end if;
  if p_kind = 'fssai' and v !~ '^[0-9]{14}$' then
    raise exception 'FSSAI licence: 14 digits' using errcode = '22023'; end if;
  if p_kind = 'iec' and v !~ '^[A-Z0-9]{10}$' then
    raise exception 'IEC: 10 letters or digits' using errcode = '22023'; end if;
  if p_kind in ('reg_no', 'rcmc') and (length(v) < 3 or length(v) > 40) then
    raise exception '%: 3 to 40 characters', case p_kind when 'rcmc' then 'RCMC' else 'Registration number' end using errcode = '22023'; end if;
  return v;
end $$;

-- the core of a name, for "a business with a similar name exists": small letters, no punctuation, no Ltd/Pvt/…
create or replace function app.core_name(p_name text) returns text
language sql immutable as $$
  select btrim(regexp_replace(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9 ]', ' ', 'g'),
    '\m(private|pvt|limited|ltd|llp|the|co|company|corp|corporation|inc|india|and)\M', ' ', 'g'), ' ')
$$;
create or replace function app.similar_entity(p_name text, p_not uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.entities e
                  where e.id is distinct from p_not
                    and length(regexp_replace(app.core_name(p_name), '\s+', '', 'g')) >= 3
                    and regexp_replace(app.core_name(e.legal_name), '\s+', '', 'g') = regexp_replace(app.core_name(p_name), '\s+', '', 'g'))
$$;

-- a client code: 3 to 5 capitals made from the name, unique nationally (existing codes are never changed)
create or replace function app.new_client_code(p_name text) returns text
language plpgsql stable security definer set search_path = public as $$
declare w text[]; v_init text := ''; c text; cands text[] := '{}'; x text; w1 text; w2 text;
begin
  w := array(select ww from unnest(regexp_split_to_array(upper(regexp_replace(app.core_name(p_name), '[^a-z ]', ' ', 'g')), '\s+')) ww where ww <> '');
  if cardinality(w) = 0 then w := array['CLIENT']; end if;
  foreach x in array w loop v_init := v_init || left(x, 1); end loop;
  w1 := rpad(w[1], 5, 'X'); w2 := coalesce(w[2], w[1]);
  if length(v_init) between 3 and 5 then cands := cands || v_init; end if;
  if length(v_init) > 5 then cands := cands || left(v_init, 5) || left(v_init, 4) || left(v_init, 3); end if;
  cands := cands || (left(w1, 2) || left(w2, 1)) || left(w1, 3) || left(w1, 4) || left(w1, 5) || (left(w1, 2) || left(w2, 2)) || (left(w1, 3) || left(w2, 1));
  foreach c in array cands loop
    if c ~ '^[A-Z]{3,5}$' and not exists (select 1 from public.clients where code = c) then return c; end if;
  end loop;
  foreach x in array regexp_split_to_array('ABCDEFGHIJKLMNOPQRSTUVWXYZ', '') loop
    c := left(w1, 3) || x;
    if not exists (select 1 from public.clients where code = c) then return c; end if;
    c := left(w1, 2) || left(w2, 1) || x;
    if not exists (select 1 from public.clients where code = c) then return c; end if;
  end loop;
  loop
    c := left(w1, 2) || array_to_string(array(select chr(65 + floor(random() * 26)::int) from generate_series(1, 3)), '');
    if not exists (select 1 from public.clients where code = c) then return c; end if;
  end loop;
end $$;

-- 5 · who is who for a client -------------------------------------------------------------------------------------------
-- a State Manager of one of the client's states (the states it has a row in)
create or replace function app.sm_of_client(p_client uuid, p_state uuid default null) returns boolean
language sql stable security definer set search_path = public as $$
  select not app.is_admin() and not app.is_client_login() and exists (
    select 1 from public.client_states cs
     where cs.client_id = p_client and cs.state_id = any (app.my_state_ids()) and (p_state is null or cs.state_id = p_state))
$$;
-- the client's own login (the owner, for now its client_viewer: plan default 7) and its Client Manager
create or replace function app.client_owner_of(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app.eff_assignments(app.current_user_id()) a
                  where a.lens = 'client' and a.client_id = p_client and a.op_role = 'client_viewer')
$$;
create or replace function app.cm_of_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app.eff_assignments(app.current_user_id()) a
                  where a.lens = 'client' and a.client_id = p_client and a.op_role = 'client_account')
$$;

create or replace function app.cur_id(p_entity uuid, p_kind public.id_kind, p_state uuid default null) returns public.entity_ids
language sql stable security definer set search_path = public as $$
  select * from public.entity_ids where entity_id = p_entity and kind = p_kind and current
     and state_id is not distinct from p_state limit 1
$$;
create or replace function app.cur_doc(p_client uuid, p_kind public.client_doc_kind, p_state uuid default null) returns public.client_documents
language sql stable security definer set search_path = public as $$
  select * from public.client_documents where client_id = p_client and kind = p_kind and superseded_at is null
     and state_id is not distinct from p_state limit 1
$$;
create or replace function app.filled(p jsonb, variadic p_keys text[]) returns boolean
language sql immutable as $$
  select not exists (select 1 from unnest(p_keys) k where length(btrim(coalesce(p ->> k, ''))) = 0)
$$;

-- the client's overall status: the best of its states (Active if one is), its own while it has one state
create or replace function app.national_status(p_client uuid) returns public.client_status
language sql stable security definer set search_path = public as $$
  select coalesce((select status from public.client_states where client_id = p_client
                    order by case status when 'active' then 1 when 'diagnostic' then 2 when 'prospect' then 3 when 'suspended' then 4 else 5 end
                    limit 1), 'prospect'::public.client_status)
$$;

-- does an export scope exist, and does one export an APEDA-scheduled crop (then the IEC, the RCMC)
create or replace function app.client_exports(p_client uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'export', exists (select 1 from public.scopes s where s.client_id = p_client and s.status <> 'closed' and 'export' = any (s.market_codes)),
    'apeda', exists (select 1 from public.scopes s join public.crops cr on cr.id = s.crop_id
                      where s.client_id = p_client and s.status <> 'closed' and 'export' = any (s.market_codes) and cr.apeda_scheduled))
$$;

-- 6 · the gates: what each needs, for one state ("3 of 7 done") -------------------------------------------------------
create or replace function app.client_gates(p_client uuid, p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clients; e public.entities; cs public.client_states; ex jsonb; g1 jsonb; g2 jsonb; g3 jsonb;
        v_reg public.id_kind; d public.client_documents; i public.entity_ids; need_reg boolean; need_inc boolean;

begin
  select * into c from public.clients where id = p_client;
  select * into e from public.entities where id = c.entity_id;
  select * into cs from public.client_states where client_id = p_client and state_id = p_state;
  if c.id is null or cs.client_id is null then return null; end if;
  ex := app.client_exports(p_client);
  v_reg := case e.entity_type when 'company' then 'cin' when 'llp' then 'llpin' when 'cooperative' then 'reg_no' when 'society' then 'reg_no' end;
  need_reg := v_reg is not null;
  need_inc := e.entity_type in ('company', 'llp');

  g1 := jsonb_build_array(
    jsonb_build_object('key', 'pan', 'needed', true, 'done', not e.pan_pending),
    jsonb_build_object('key', 'legal_name', 'needed', true, 'done', length(btrim(e.legal_name)) >= 2),
    jsonb_build_object('key', 'entity_type', 'needed', true, 'done', e.entity_type is not null),
    jsonb_build_object('key', 'client_code', 'needed', true, 'done', c.code is not null),
    jsonb_build_object('key', 'contact', 'needed', true, 'done', app.filled(c.contact, 'name', 'designation', 'phone', 'email')),
    jsonb_build_object('key', 'states_of_interest', 'needed', true, 'done', cardinality(c.states_of_interest) > 0),
    jsonb_build_object('key', 'crops_of_interest', 'needed', true, 'done', cardinality(c.crops_of_interest) > 0));

  i := app.cur_id(e.id, 'gstin', p_state);
  g2 := jsonb_build_array(
    jsonb_build_object('key', 'reg_office', 'needed', true, 'done', app.filled(e.reg_office, 'address', 'city', 'state')),
    jsonb_build_object('key', 'reg_number', 'needed', need_reg, 'done', not need_reg or (app.cur_id(e.id, v_reg)).id is not null),
    jsonb_build_object('key', 'gstin', 'needed', true, 'done', i.id is not null or length(btrim(coalesce(cs.gst_not_registered_reason, ''))) >= 10),
    jsonb_build_object('key', 'signatory', 'needed', true, 'done', app.filled(cs.signatory, 'name', 'designation')),
    jsonb_build_object('key', 'diagnostic_order', 'needed', true,
      'done', (select d2.signed_on is not null and d2.amount is not null from app.cur_doc(p_client, 'diagnostic_order', p_state) d2) is true),
    jsonb_build_object('key', 'incorporation', 'needed', need_inc, 'done', not need_inc or (app.cur_doc(p_client, 'incorporation')).id is not null));

  g3 := jsonb_build_array(
    jsonb_build_object('key', 'msa', 'needed', true,
      'done', (select d2.signed_on is not null and d2.term_end is not null and d2.term_end >= app.today() from app.cur_doc(p_client, 'msa') d2) is true),
    jsonb_build_object('key', 'consent_addendum', 'needed', true,
      'done', (select d2.signed_on is not null from app.cur_doc(p_client, 'consent_addendum') d2) is true),
    jsonb_build_object('key', 'signatory_authority', 'needed', true, 'done', (app.cur_doc(p_client, 'signatory_authority')).id is not null),
    jsonb_build_object('key', 'billing', 'needed', true, 'done', app.filled(cs.billing, 'contact', 'email')),
    jsonb_build_object('key', 'fssai', 'needed', cs.brand_on_pack,
      'done', not cs.brand_on_pack or ((app.cur_id(e.id, 'fssai', p_state)).expires_on > app.today()
                                       and (app.cur_doc(p_client, 'fssai', p_state)).id is not null) is true),
    jsonb_build_object('key', 'iec', 'needed', (ex->>'export')::boolean,
      'done', not (ex->>'export')::boolean or ((app.cur_id(e.id, 'iec')).id is not null and (app.cur_doc(p_client, 'iec')).id is not null)),
    jsonb_build_object('key', 'rcmc', 'needed', (ex->>'apeda')::boolean,
      'done', not (ex->>'apeda')::boolean or ((app.cur_id(e.id, 'rcmc')).expires_on > app.today()
                                              and (app.cur_doc(p_client, 'rcmc')).id is not null) is true),
    jsonb_build_object('key', 'kyc', 'needed', true, 'done', cs.kyc_at is not null),
    jsonb_build_object('key', 'approval', 'needed', c.approved_at is null, 'done', c.approved_at is not null));

  return jsonb_build_object('client_id', p_client, 'state_id', p_state, 'status', cs.status, 'legacy', cs.legacy,
    'gates', jsonb_build_array(
      jsonb_build_object('gate', 1, 'items', g1),
      jsonb_build_object('gate', 2, 'items', g2),
      jsonb_build_object('gate', 3, 'items', g3)));
end $$;

-- a gate is done when every needed item is (gate 3 may leave out the KYC tick and the approval: they come last)
create or replace function app.gate_done(p_gates jsonb, p_gate int, p_except text[] default '{}') returns boolean
language sql immutable as $$
  select not exists (select 1 from jsonb_array_elements(p_gates -> 'gates') g, jsonb_array_elements(g -> 'items') it
                      where (g ->> 'gate')::int = p_gate and (it ->> 'needed')::boolean and not (it ->> 'done')::boolean
                        and not ((it ->> 'key') = any (p_except)))
$$;
create or replace function app.gate_missing(p_gates jsonb, p_upto int, p_except text[] default '{}') returns text
language sql immutable as $$
  select string_agg(it ->> 'key', ', ') from jsonb_array_elements(p_gates -> 'gates') g, jsonb_array_elements(g -> 'items') it
   where (g ->> 'gate')::int <= p_upto and (it ->> 'needed')::boolean and not (it ->> 'done')::boolean
     and not ((it ->> 'key') = any (p_except))
$$;

-- 7 · an audit line with numbers only as masks and keyed hashes --------------------------------------------------------
create or replace function app.id_trace(p_kind text, p_value text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_value is null then null
              else jsonb_build_object('masked', app.mask_id(p_kind, p_value), 'hash', app.id_hash(p_kind, p_value)) end
$$;

create or replace function app.client_event(p_client uuid, p_state uuid, p_from public.client_status, p_to public.client_status,
                                            p_act text, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.client_status_events (client_id, state_id, from_status, to_status, act, reason, by_user)
  values (p_client, p_state, p_from, p_to, p_act, p_reason, app.current_user_id());
end $$;

-- 8 · A2: "Already registered with GrainVeda" ------------------------------------------------------------------------
create or replace function app.client_identity(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clients; e public.entities; st public.states;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then return null; end if;
  -- A4: any State Manager (the shared identity), the admin, the client's own people
  if not (app.is_admin() or (cardinality(app.my_state_ids()) > 0 and not app.is_client_login())
          or app.client_owner_of(p_client) or app.cm_of_client(p_client)) then
    raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id;
  return jsonb_build_object('client_id', c.id, 'legal_name', e.legal_name, 'trade_name', e.trade_name, 'name', c.name,
    'pan_masked', e.pan_masked, 'pan_pending', e.pan_pending, 'entity_type', e.entity_type,
    'office_city', e.reg_office ->> 'city', 'office_state', e.reg_office ->> 'state',
    'status', app.national_status(c.id), 'code', c.code, 'own_brand', e.own_brand);
end $$;

create or replace function app.lookup_pan(p_pan text, p_name text default null, p_type public.entity_type default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v text; e public.entities; c uuid;
begin
  if not (app.is_admin() or (cardinality(app.my_state_ids()) > 0 and not app.is_client_login())) then
    raise exception 'only a State Manager registers a client' using errcode = '42501'; end if;
  v := app.check_pan(p_pan, p_type);
  select en.* into e from public.entity_ids i join public.entities en on en.id = i.entity_id
   where i.kind = 'pan' and i.current and i.hash = app.id_hash('pan', v);
  if e.id is null then
    return jsonb_build_object('situation', 'new', 'similar', p_name is not null and app.similar_entity(p_name));
  end if;
  select id into c from public.clients where entity_id = e.id limit 1;
  if c is not null then
    return jsonb_build_object('situation', 'client', 'identity', app.client_identity(c),
      'in_my_state', exists (select 1 from public.client_states cs where cs.client_id = c and cs.state_id = any (app.my_state_ids())));
  end if;
  -- known in another role: nothing about that role is shown (A1, A2)
  return jsonb_build_object('situation', 'known', 'similar', false);
end $$;

-- 9 · B1: a State Manager creates the client (Gate 1) -----------------------------------------------------------------
create or replace function app.create_client(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); v_state uuid := (p ->> 'state_id')::uuid; v_type public.entity_type;
        v_pan text; v_hash text; e public.entities; c public.clients; v_name text; v_trade text; v_contact jsonb;
        v_states uuid[]; v_crops uuid[]; v_similar boolean; v_ctype public.client_type;
begin
  if app.is_admin() or app.is_client_login() or not (v_state = any (app.my_state_ids())) then
    raise exception 'a client is created by the State Manager of the state it starts in' using errcode = '42501'; end if;
  v_type := nullif(p ->> 'entity_type', '')::public.entity_type;
  if v_type is null then raise exception 'entity type: choose one' using errcode = '22023'; end if;
  v_pan := app.check_pan(p ->> 'pan', v_type);
  v_hash := app.id_hash('pan', v_pan);
  v_name := btrim(coalesce(p ->> 'legal_name', ''));
  if length(v_name) < 2 or length(v_name) > 200 then raise exception 'legal name: as on the PAN or the certificate of incorporation' using errcode = '22023'; end if;
  v_trade := nullif(btrim(coalesce(p ->> 'trade_name', '')), '');
  v_contact := jsonb_build_object('name', btrim(coalesce(p #>> '{contact,name}', '')), 'designation', btrim(coalesce(p #>> '{contact,designation}', '')),
                                  'phone', btrim(coalesce(p #>> '{contact,phone}', '')), 'email', lower(btrim(coalesce(p #>> '{contact,email}', ''))));
  if not app.filled(v_contact, 'name', 'designation', 'phone', 'email') then
    raise exception 'primary contact: name, designation, phone and email' using errcode = '22023'; end if;
  if (v_contact ->> 'phone') !~ '^\+?[0-9 -]{10,15}$' then raise exception 'primary contact: a phone of 10 digits' using errcode = '22023'; end if;
  if (v_contact ->> 'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'primary contact: an email address' using errcode = '22023'; end if;
  v_states := array(select distinct x::uuid from jsonb_array_elements_text(coalesce(p -> 'states_of_interest', '[]'::jsonb)) x);
  if not (v_state = any (v_states)) then v_states := v_states || v_state; end if;
  if exists (select 1 from unnest(v_states) s where not exists (select 1 from public.states where id = s)) then
    raise exception 'states of interest: a state that exists' using errcode = '22023'; end if;
  v_crops := array(select distinct x::uuid from jsonb_array_elements_text(coalesce(p -> 'crops_of_interest', '[]'::jsonb)) x);
  if cardinality(v_crops) = 0 then raise exception 'crops of interest: at least one' using errcode = '22023'; end if;
  if exists (select 1 from unnest(v_crops) x where not exists (select 1 from public.crops cr where cr.id = x
               and cr.retired_at is null and (cr.state_id is null or cr.state_id = any (v_states)))) then
    raise exception 'crops of interest: from the crop registries of the states of interest' using errcode = '22023'; end if;
  if (p ->> 'source') is not null and (p ->> 'source') not in ('referral', 'outreach', 'event', 'inbound') then
    raise exception 'how they came to us: referral, outreach, event or inbound' using errcode = '22023'; end if;
  v_ctype := coalesce(nullif(p ->> 'client_type', '')::public.client_type, 'exporter');

  -- A2: one PAN, one entity; one entity, one client
  perform pg_advisory_xact_lock(hashtext('grainveda_registry'));
  select en.* into e from public.entity_ids i join public.entities en on en.id = i.entity_id
   where i.kind = 'pan' and i.current and i.hash = v_hash;
  if e.id is not null and exists (select 1 from public.clients where entity_id = e.id) then
    raise exception 'already registered with GrainVeda: add your state to this client instead' using errcode = '23505'; end if;
  v_similar := app.similar_entity(v_name, e.id);
  if e.id is null then
    insert into public.entities (legal_name, trade_name, entity_type, pan_hash, pan_masked, pan_pending, own_brand, created_by)
    values (v_name, v_trade, v_type, v_hash, app.mask_id('pan', v_pan), false, v_ctype = 'grainveda', me) returning * into e;
    insert into public.entity_ids (entity_id, kind, value, hash, masked, created_by)
    values (e.id, 'pan', v_pan, v_hash, app.mask_id('pan', v_pan), me);
  elsif e.entity_type <> v_type then
    raise exception 'PAN: this business is known as a %, not a %', replace(e.entity_type::text, '_', ' '), replace(v_type::text, '_', ' ') using errcode = '22023';
  end if;
  insert into public.entity_roles (entity_id, role) values (e.id, 'client') on conflict do nothing;
  insert into public.clients (state_id, name, code, type, entity_id, contact, states_of_interest, crops_of_interest, source, created_by)
  values (v_state, coalesce(v_trade, v_name), app.new_client_code(coalesce(v_trade, v_name)), v_ctype, e.id, v_contact, v_states, v_crops,
          nullif(p ->> 'source', ''), me) returning * into c;
  insert into public.client_states (client_id, state_id, status, created_by) values (c.id, v_state, 'prospect', me)
  on conflict (client_id, state_id) do nothing;
  perform app.client_event(c.id, v_state, null, 'prospect', 'created');
  perform app.audit('client_created', c.id, jsonb_build_object('code', c.code, 'legal_name', v_name, 'state_id', v_state,
    'pan', app.id_trace('pan', v_pan), 'entity_type', v_type, 'similar_name', v_similar), false);
  return jsonb_build_object('client_id', c.id, 'code', c.code, 'similar', v_similar);
end $$;

-- 10 · the record, by who reads it (A3, A4, B5) ------------------------------------------------------------------------
create or replace function app.client_view(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clients; e public.entities; v_admin boolean := app.is_admin(); v_owner boolean; v_cm boolean;
        v_sm_states uuid[]; v_full boolean; v_states jsonb; v_reg public.id_kind; v_nat jsonb; v_see uuid[];
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id;
  v_owner := app.client_owner_of(p_client);
  v_cm := app.cm_of_client(p_client);
  v_sm_states := case when app.is_client_login() then '{}'::uuid[]
                      else array(select cs.state_id from public.client_states cs where cs.client_id = p_client and cs.state_id = any (app.my_state_ids())) end;
  if not (v_admin or v_owner or v_cm or cardinality(v_sm_states) > 0) then
    -- a State Manager of another state: the shared identity only (A4); everyone else: nothing
    if cardinality(app.my_state_ids()) > 0 and not app.is_client_login() then
      return jsonb_build_object('identity', app.client_identity(p_client), 'shared_only', true, 'states', '[]'::jsonb,
                                'may', jsonb_build_object('add_state', true));
    end if;
    raise exception 'not found' using errcode = 'P0002';
  end if;
  v_full := v_admin or cardinality(v_sm_states) > 0;              -- A3: the numbers in full for these only
  v_see := case when v_admin or v_owner then array(select state_id from public.client_states where client_id = p_client)
                when cardinality(v_sm_states) > 0 then v_sm_states
                else array[c.state_id] end;                         -- the Client Manager: his client's state
  v_reg := case e.entity_type when 'company' then 'cin' when 'llp' then 'llpin' when 'cooperative' then 'reg_no' when 'society' then 'reg_no' end;

  v_nat := jsonb_build_object(
    'reg_number', case when v_reg is null then null else
      (select jsonb_build_object('kind', i.kind, 'masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, v_reg) i where i.id is not null) end,
    'iec', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, 'iec') i where i.id is not null),
    'rcmc', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end, 'expires_on', i.expires_on) from app.cur_id(e.id, 'rcmc') i where i.id is not null),
    'documents', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'file_name', d.file_name, 'path', d.path, 'sha256', d.sha256,
          'bytes', d.bytes, 'signed_on', d.signed_on, 'term_end', d.term_end, 'expires_on', d.expires_on, 'amount', d.amount,
          'created_at', d.created_at) order by d.kind), '[]'::jsonb)
         from public.client_documents d where d.client_id = p_client and d.state_id is null and d.superseded_at is null) end);

  select coalesce(jsonb_agg(jsonb_build_object(
      'state_id', cs.state_id, 'state', s.name, 'status', cs.status, 'legacy', cs.legacy,
      'gstin', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end) from app.cur_id(e.id, 'gstin', cs.state_id) i where i.id is not null),
      'gst_not_registered_reason', cs.gst_not_registered_reason,
      'signatory', case when v_cm and not v_full and not v_owner then '{}'::jsonb else cs.signatory end,
      'billing', cs.billing, 'address', cs.address, 'state_contact', cs.state_contact, 'brand_on_pack', cs.brand_on_pack,
      'fssai', (select jsonb_build_object('masked', i.masked, 'value', case when v_full then i.value end, 'expires_on', i.expires_on) from app.cur_id(e.id, 'fssai', cs.state_id) i where i.id is not null),
      'kyc_at', cs.kyc_at, 'kyc_by', (select display_name from public.app_users where id = cs.kyc_by),
      'activation_requested_at', cs.activation_requested_at,
      'gates', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then null else app.client_gates(p_client, cs.state_id) end,
      'documents', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
        (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'file_name', d.file_name, 'path', d.path, 'sha256', d.sha256,
            'bytes', d.bytes, 'signed_on', d.signed_on, 'expires_on', d.expires_on, 'amount', d.amount, 'created_at', d.created_at) order by d.kind), '[]'::jsonb)
           from public.client_documents d where d.client_id = p_client and d.state_id = cs.state_id and d.superseded_at is null) end,
      'events', case when v_cm and not (v_admin or v_owner or cardinality(v_sm_states) > 0) then '[]'::jsonb else
        (select coalesce(jsonb_agg(jsonb_build_object('act', ev.act, 'from', ev.from_status, 'to', ev.to_status, 'reason', ev.reason, 'at', ev.at,
            'by', (select display_name from public.app_users where id = ev.by_user)) order by ev.at desc, ev.id desc), '[]'::jsonb)
           from public.client_status_events ev where ev.client_id = p_client and ev.state_id = cs.state_id) end,
      'mine', cs.state_id = any (v_sm_states)) order by s.name), '[]'::jsonb)
    into v_states
    from public.client_states cs join public.states s on s.id = cs.state_id
   where cs.client_id = p_client and cs.state_id = any (v_see);

  return jsonb_build_object(
    'identity', app.client_identity(p_client) || jsonb_build_object('pan', case when v_full then (app.cur_id(e.id, 'pan')).value end,
      'reg_office', e.reg_office, 'approved_at', c.approved_at, 'code_edited', c.code_edited, 'type', c.type),
    'shared_only', false,
    'contact', c.contact, 'source', c.source,
    'states_of_interest', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb) from public.states s where s.id = any (c.states_of_interest)),
    'crops_of_interest', (select coalesce(jsonb_agg(jsonb_build_object('id', cr.id, 'name', cr.name) order by cr.name), '[]'::jsonb) from public.crops cr where cr.id = any (c.crops_of_interest)),
    'exports', app.client_exports(p_client),
    'national', v_nat,
    'states', v_states,
    'may', jsonb_build_object(
      'edit', cardinality(v_sm_states) > 0,
      'edit_states', to_jsonb(v_sm_states),
      'edit_identity', v_admin,
      'edit_code', v_admin and c.approved_at is null and not c.code_edited,
      'set_pan', e.pan_pending and (v_admin or cardinality(v_sm_states) > 0),
      'approve', v_admin,
      'full_numbers', v_full));
end $$;

-- 11 · B2/B3: the State Manager fills his state's gates and the national fields while the client is not yet Active ----
create or replace function app.put_id(p_entity uuid, p_kind public.id_kind, p_state uuid, p_value text, p_expires date default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old public.entity_ids; v_hash text := app.id_hash(p_kind::text, p_value);
begin
  old := app.cur_id(p_entity, p_kind, p_state);
  if old.id is not null and old.hash = v_hash and old.expires_on is not distinct from p_expires then return null; end if;
  if p_kind in ('pan', 'gstin') and exists (select 1 from public.entity_ids i where i.kind = p_kind and i.current and i.hash = v_hash and i.entity_id <> p_entity) then
    raise exception '%: this number belongs to another business in the registry', upper(p_kind::text) using errcode = '23505'; end if;
  if old.id is not null then update public.entity_ids set current = false where id = old.id; end if;
  insert into public.entity_ids (entity_id, kind, state_id, value, hash, masked, expires_on, created_by)
  values (p_entity, p_kind, p_state, p_value, v_hash, app.mask_id(p_kind::text, p_value), p_expires, app.current_user_id());
  return jsonb_build_object('kind', p_kind, 'old', case when old.id is null then null else jsonb_build_object('masked', old.masked, 'hash', old.hash) end,
    'new', jsonb_build_object('masked', app.mask_id(p_kind::text, p_value), 'hash', v_hash), 'expires_on', p_expires);
end $$;

create or replace function app.save_client_details(p_client uuid, p_state uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.clients; e public.entities; cs public.client_states; v_changes jsonb := '[]'::jsonb; x jsonb; v text;
        v_reg public.id_kind; v_pan text; v_after_active boolean; k text; v_nat_keys text[] := array['legal_name', 'trade_name',
        'reg_office', 'reg_number', 'contact', 'states_of_interest', 'crops_of_interest', 'source', 'iec', 'rcmc'];
        v_identity_keys text[] := array['legal_name', 'reg_number']; v_d date;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.sm_of_client(p_client, p_state) then
    raise exception 'the client''s details are filled by the State Manager of this state' using errcode = '42501'; end if;
  select * into e from public.entities where id = c.entity_id;
  select * into cs from public.client_states where client_id = p_client and state_id = p_state;
  if cs.status in ('suspended', 'ended') then raise exception 'this client is % in this state', cs.status using errcode = '23514'; end if;
  v_after_active := c.approved_at is not null;
  -- national identity (legal name, PAN, CIN …) is the admin's after the first Active (B5)
  for k in select jsonb_object_keys(p) loop
    if v_after_active and k = any (v_identity_keys) then
      raise exception 'after the client is Active its % is changed by the admin', replace(k, '_', ' ') using errcode = '42501'; end if;
  end loop;
  v_reg := case e.entity_type when 'company' then 'cin' when 'llp' then 'llpin' when 'cooperative' then 'reg_no' when 'society' then 'reg_no' end;

  -- national fields
  if p ? 'legal_name' then
    v := btrim(coalesce(p ->> 'legal_name', ''));
    if length(v) < 2 or length(v) > 200 then raise exception 'legal name: 2 to 200 characters' using errcode = '22023'; end if;
    if v <> e.legal_name then
      update public.entities set legal_name = v where id = e.id;
      if (select trade_name from public.entities where id = e.id) is null then update public.clients set name = v where id = c.id; end if;
      v_changes := v_changes || jsonb_build_object('field', 'legal_name', 'old', e.legal_name, 'new', v);
    end if;
  end if;
  if p ? 'trade_name' then
    v := nullif(btrim(coalesce(p ->> 'trade_name', '')), '');
    if v is distinct from e.trade_name then
      update public.entities set trade_name = v where id = e.id;
      update public.clients set name = coalesce(v, (select legal_name from public.entities where id = e.id)) where id = c.id;
      v_changes := v_changes || jsonb_build_object('field', 'trade_name', 'old', e.trade_name, 'new', v);
    end if;
  end if;
  if p ? 'reg_office' then
    x := jsonb_build_object('address', btrim(coalesce(p #>> '{reg_office,address}', '')), 'city', btrim(coalesce(p #>> '{reg_office,city}', '')),
                            'state', btrim(coalesce(p #>> '{reg_office,state}', '')));
    if x is distinct from e.reg_office then
      update public.entities set reg_office = x where id = e.id;
      v_changes := v_changes || jsonb_build_object('field', 'reg_office', 'old', e.reg_office, 'new', x);
    end if;
  end if;
  if p ? 'reg_number' then
    if v_reg is null then raise exception 'a % has no registration number here', replace(e.entity_type::text, '_', ' ') using errcode = '22023'; end if;
    x := app.put_id(e.id, v_reg, null, app.check_number(v_reg, p ->> 'reg_number'));
    if x is not null then v_changes := v_changes || (x || jsonb_build_object('field', 'reg_number')); end if;
  end if;
  if p ? 'contact' then
    x := jsonb_build_object('name', btrim(coalesce(p #>> '{contact,name}', '')), 'designation', btrim(coalesce(p #>> '{contact,designation}', '')),
                            'phone', btrim(coalesce(p #>> '{contact,phone}', '')), 'email', lower(btrim(coalesce(p #>> '{contact,email}', ''))));
    if not app.filled(x, 'name', 'designation', 'phone', 'email') then raise exception 'primary contact: name, designation, phone and email' using errcode = '22023'; end if;
    if x is distinct from c.contact then
      update public.clients set contact = x where id = c.id;
      v_changes := v_changes || jsonb_build_object('field', 'contact', 'old', c.contact, 'new', x);
    end if;
  end if;
  if p ? 'states_of_interest' then
    update public.clients set states_of_interest = array(select distinct s::uuid from jsonb_array_elements_text(p -> 'states_of_interest') s
                                                          where exists (select 1 from public.states where id = s::uuid)) where id = c.id;
    v_changes := v_changes || jsonb_build_object('field', 'states_of_interest');
  end if;
  if p ? 'crops_of_interest' then
    update public.clients set crops_of_interest = array(select distinct s::uuid from jsonb_array_elements_text(p -> 'crops_of_interest') s
                                                         where exists (select 1 from public.crops where id = s::uuid)) where id = c.id;
    v_changes := v_changes || jsonb_build_object('field', 'crops_of_interest');
  end if;
  if p ? 'source' then
    if nullif(p ->> 'source', '') is not null and (p ->> 'source') not in ('referral', 'outreach', 'event', 'inbound') then
      raise exception 'how they came to us: referral, outreach, event or inbound' using errcode = '22023'; end if;
    update public.clients set source = nullif(p ->> 'source', '') where id = c.id;
  end if;
  if p ? 'iec' then
    x := app.put_id(e.id, 'iec', null, app.check_number('iec', p ->> 'iec'));
    if x is not null then v_changes := v_changes || (x || jsonb_build_object('field', 'iec')); end if;
  end if;
  if p ? 'rcmc' then
    v_d := nullif(p #>> '{rcmc,expires_on}', '')::date;
    if v_d is null then raise exception 'RCMC: its expiry date' using errcode = '22023'; end if;
    x := app.put_id(e.id, 'rcmc', null, app.check_number('rcmc', p #>> '{rcmc,number}'), v_d);
    if x is not null then v_changes := v_changes || (x || jsonb_build_object('field', 'rcmc')); end if;
  end if;

  -- the state's fields
  if p ? 'gstin' then
    if nullif(p ->> 'gstin', '') is null then raise exception 'GSTIN: type it, or choose "Not registered in this state" with a reason' using errcode = '22023'; end if;
    v_pan := (app.cur_id(e.id, 'pan')).value;
    if v_pan is null then raise exception 'GSTIN: the client''s PAN first' using errcode = '22023'; end if;
    x := app.put_id(e.id, 'gstin', p_state, app.check_gstin(p ->> 'gstin', v_pan, p_state));
    if x is not null then
      update public.client_states set gst_not_registered_reason = null where client_id = p_client and state_id = p_state;
      v_changes := v_changes || (x || jsonb_build_object('field', 'gstin'));
    end if;
  end if;
  if p ? 'gst_not_registered_reason' then
    v := nullif(btrim(coalesce(p ->> 'gst_not_registered_reason', '')), '');
    if v is null or length(v) < 10 or length(v) > 300 then
      raise exception 'not registered for GST in this state: a reason of 10 to 300 characters' using errcode = '22023'; end if;
    if (app.cur_id(e.id, 'gstin', p_state)).id is not null then
      update public.entity_ids set current = false where id = (app.cur_id(e.id, 'gstin', p_state)).id;
    end if;
    update public.client_states set gst_not_registered_reason = v where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'gst_not_registered_reason', 'new', v);
  end if;
  if p ? 'signatory' then
    x := jsonb_build_object('name', btrim(coalesce(p #>> '{signatory,name}', '')), 'designation', btrim(coalesce(p #>> '{signatory,designation}', '')));
    if not app.filled(x, 'name', 'designation') then raise exception 'authorised signatory: name and designation' using errcode = '22023'; end if;
    update public.client_states set signatory = x where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'signatory', 'old', cs.signatory, 'new', x);
  end if;
  if p ? 'billing' then
    x := jsonb_build_object('contact', btrim(coalesce(p #>> '{billing,contact}', '')), 'email', lower(btrim(coalesce(p #>> '{billing,email}', ''))));
    if not app.filled(x, 'contact', 'email') or (x ->> 'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
      raise exception 'billing: a billing contact and an invoice email' using errcode = '22023'; end if;
    update public.client_states set billing = x where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'billing', 'old', cs.billing, 'new', x);
  end if;
  if p ? 'address' then
    x := jsonb_build_object('address', btrim(coalesce(p #>> '{address,address}', '')), 'city', btrim(coalesce(p #>> '{address,city}', '')));
    update public.client_states set address = x where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'address', 'old', cs.address, 'new', x);
  end if;
  if p ? 'state_contact' then
    x := jsonb_build_object('name', btrim(coalesce(p #>> '{state_contact,name}', '')), 'designation', btrim(coalesce(p #>> '{state_contact,designation}', '')),
                            'phone', btrim(coalesce(p #>> '{state_contact,phone}', '')), 'email', lower(btrim(coalesce(p #>> '{state_contact,email}', ''))));
    update public.client_states set state_contact = x where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'state_contact', 'old', cs.state_contact, 'new', x);
  end if;
  if p ? 'brand_on_pack' then
    update public.client_states set brand_on_pack = coalesce((p ->> 'brand_on_pack')::boolean, false) where client_id = p_client and state_id = p_state;
    v_changes := v_changes || jsonb_build_object('field', 'brand_on_pack', 'old', cs.brand_on_pack, 'new', coalesce((p ->> 'brand_on_pack')::boolean, false));
  end if;
  if p ? 'fssai' then
    v_d := nullif(p #>> '{fssai,expires_on}', '')::date;
    if v_d is null then raise exception 'FSSAI licence: its expiry date' using errcode = '22023'; end if;
    x := app.put_id(e.id, 'fssai', p_state, app.check_number('fssai', p #>> '{fssai,number}'), v_d);
    if x is not null then v_changes := v_changes || (x || jsonb_build_object('field', 'fssai')); end if;
  end if;

  if jsonb_array_length(v_changes) > 0 then
    -- a change before Active undoes the KYC tick: the State Manager checks the originals again
    update public.client_states set kyc_at = null, kyc_by = null
     where client_id = p_client and state_id = p_state and status <> 'active' and kyc_at is not null;
    perform app.audit('client_details', p_client, jsonb_build_object('state_id', p_state, 'changes', v_changes), false);
  end if;
  return app.client_gates(p_client, p_state);
end $$;

-- 12 · the documents: uploaded to "client-docs/<client id>/<file id>.<ext>", then recorded here ----------------------
create or replace function app.doc_is_national(p_kind public.client_doc_kind) returns boolean
language sql immutable as $$ select p_kind in ('incorporation', 'msa', 'consent_addendum', 'signatory_authority', 'iec', 'rcmc') $$;

create or replace function app.add_client_document(p_client uuid, p_state uuid, p_kind public.client_doc_kind, p_path text,
                                                   p_sha256 text, p_bytes bigint, p_file_name text default null, p_meta jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare old public.client_documents; d public.client_documents; v_state uuid; v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
begin
  if not app.sm_of_client(p_client, p_state) then
    raise exception 'the client''s documents are added by the State Manager of this state' using errcode = '42501'; end if;
  if exists (select 1 from public.client_states where client_id = p_client and state_id = p_state and status in ('suspended', 'ended')) then
    raise exception 'this client is suspended or ended in this state' using errcode = '23514'; end if;
  v_state := case when app.doc_is_national(p_kind) then null else p_state end;
  if p_path !~ ('^' || p_client::text || '/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$') then
    raise exception 'document: the file is stored as "<client>/<file id>.pdf" (or jpg, png, webp)' using errcode = '22023'; end if;
  if to_regclass('storage.objects') is not null then
    if not exists (select 1 from storage.objects o where o.bucket_id = 'client-docs' and o.name = p_path) then
      raise exception 'document: the file was not uploaded' using errcode = '22023'; end if;
  end if;
  if p_kind = 'diagnostic_order' and ((v_meta ->> 'signed_on') is null or (v_meta ->> 'amount') is null) then
    raise exception 'diagnostic order: its date and amount' using errcode = '22023'; end if;
  if p_kind = 'msa' and ((v_meta ->> 'signed_on') is null or (v_meta ->> 'term_end') is null) then
    raise exception 'Master Services Agreement: the signed date and the term end date' using errcode = '22023'; end if;
  if p_kind = 'consent_addendum' and (v_meta ->> 'signed_on') is null then
    raise exception 'Farmer Data and Consent Addendum: the signed date' using errcode = '22023'; end if;
  if p_kind in ('fssai', 'rcmc') and (v_meta ->> 'expires_on') is null then
    raise exception '%: its expiry date', case p_kind when 'fssai' then 'FSSAI licence' else 'RCMC' end using errcode = '22023'; end if;
  old := app.cur_doc(p_client, p_kind, v_state);
  if old.id is not null then
    update public.client_documents set superseded_at = now(), superseded_by = app.current_user_id() where id = old.id;
  end if;
  insert into public.client_documents (client_id, state_id, kind, path, file_name, sha256, bytes, signed_on, term_end, expires_on, amount, created_by)
  values (p_client, v_state, p_kind, p_path, left(p_file_name, 200), lower(p_sha256), p_bytes, nullif(v_meta ->> 'signed_on', '')::date,
          nullif(v_meta ->> 'term_end', '')::date, nullif(v_meta ->> 'expires_on', '')::date, nullif(v_meta ->> 'amount', '')::numeric, app.current_user_id())
  returning * into d;
  update public.client_states set kyc_at = null, kyc_by = null
   where client_id = p_client and status <> 'active' and kyc_at is not null and (v_state is null or state_id = v_state);
  perform app.audit('client_document', p_client, jsonb_build_object('state_id', v_state, 'kind', p_kind, 'sha256', d.sha256,
    'replaces', old.id, 'document_id', d.id), false);
  return to_jsonb(d);
end $$;

create or replace function app.client_doc_client(p_name text) returns uuid
language sql immutable as $$
  select case when p_name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|jpg|jpeg|png|webp)$' then split_part(p_name, '/', 1)::uuid end
$$;
create or replace function app.may_write_client_object(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.client_doc_client(p_name) is not null and app.sm_of_client(app.client_doc_client(p_name))
$$;
create or replace function app.may_read_client_file(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_documents d where d.path = p_name
                   and (app.is_admin() or app.client_owner_of(d.client_id)
                        or (d.state_id is null and app.sm_of_client(d.client_id))
                        or (d.state_id is not null and app.sm_of_client(d.client_id, d.state_id))))
$$;

-- 13 · the KYC tick, the moves, the admin's approval --------------------------------------------------------------------
create or replace function app.client_kyc(p_client uuid, p_state uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g jsonb; cs public.client_states;
begin
  if not app.sm_of_client(p_client, p_state) then
    raise exception 'the KYC tick is the State Manager''s of this state' using errcode = '42501'; end if;
  select * into cs from public.client_states where client_id = p_client and state_id = p_state;
  g := app.client_gates(p_client, p_state);
  if not (app.gate_done(g, 1) and app.gate_done(g, 2) and app.gate_done(g, 3, array['kyc', 'approval'])) then
    raise exception 'KYC: first the gates'' items: %', app.gate_missing(g, 3, array['kyc', 'approval']) using errcode = '23514'; end if;
  update public.client_states set kyc_at = now(), kyc_by = app.current_user_id() where client_id = p_client and state_id = p_state;
  perform app.client_event(p_client, p_state, cs.status, cs.status, 'kyc', 'documents checked against the originals');
  perform app.audit('client_kyc', p_client, jsonb_build_object('state_id', p_state), false);
  return app.client_gates(p_client, p_state);
end $$;

-- Prospect → Diagnostic (gates 1 and 2); Diagnostic → Active (gate 3; the first Active nationally waits for the admin)
create or replace function app.client_move(p_client uuid, p_state uuid, p_to public.client_status, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g jsonb; cs public.client_states; c public.clients;
begin
  if not app.sm_of_client(p_client, p_state) then
    raise exception 'the client''s status in a state is moved by that state''s State Manager' using errcode = '42501'; end if;
  select * into cs from public.client_states where client_id = p_client and state_id = p_state for update;
  select * into c from public.clients where id = p_client;
  g := app.client_gates(p_client, p_state);
  if p_to = 'diagnostic' then
    if cs.status <> 'prospect' then raise exception 'only a Prospect moves to Diagnostic (it is %)', cs.status using errcode = '23514'; end if;
    if not (app.gate_done(g, 1) and app.gate_done(g, 2)) then
      raise exception 'Diagnostic needs gates 1 and 2: %', app.gate_missing(g, 2) using errcode = '23514'; end if;
    update public.client_states set status = 'diagnostic', status_changed_at = now() where client_id = p_client and state_id = p_state;
    perform app.client_event(p_client, p_state, 'prospect', 'diagnostic', 'diagnostic', nullif(btrim(coalesce(p_reason, '')), ''));
  elsif p_to = 'active' then
    if cs.status <> 'diagnostic' then raise exception 'only a client in Diagnostic moves to Active (it is %)', cs.status using errcode = '23514'; end if;
    if not (app.gate_done(g, 1) and app.gate_done(g, 2) and app.gate_done(g, 3, array['approval'])) then
      raise exception 'Active needs every gate: %', app.gate_missing(g, 3, array['approval']) using errcode = '23514'; end if;
    if c.approved_at is null then
      -- B3: the first move to Active starts the contract and billing: the admin approves it
      update public.client_states set activation_requested_at = now(), activation_requested_by = app.current_user_id()
       where client_id = p_client and state_id = p_state;
      perform app.client_event(p_client, p_state, 'diagnostic', 'diagnostic', 'requested', nullif(btrim(coalesce(p_reason, '')), ''));
      perform app.audit('client_activation_requested', p_client, jsonb_build_object('state_id', p_state), false);
      return app.client_gates(p_client, p_state) || jsonb_build_object('awaiting_approval', true);
    end if;
    update public.client_states set status = 'active', status_changed_at = now(), activation_requested_at = null
     where client_id = p_client and state_id = p_state;
    perform app.client_event(p_client, p_state, 'diagnostic', 'active', 'active', nullif(btrim(coalesce(p_reason, '')), ''));
  else
    raise exception 'a client moves to Diagnostic or Active here (suspend and end come with the next release)' using errcode = '22023';
  end if;
  perform app.audit('client_status', p_client, jsonb_build_object('state_id', p_state, 'from', cs.status, 'to', p_to), false);
  return app.client_gates(p_client, p_state);
end $$;

create or replace function app.decide_client_activation(p_client uuid, p_state uuid, p_approve boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare g jsonb; cs public.client_states; c public.clients; v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if not app.is_admin() then raise exception 'the first activation of a client is approved by the admin' using errcode = '42501'; end if;
  select * into cs from public.client_states where client_id = p_client and state_id = p_state for update;
  select * into c from public.clients where id = p_client for update;
  if cs.activation_requested_at is null then raise exception 'no activation is waiting for this client in this state' using errcode = '23514'; end if;
  if not p_approve then
    if v_reason is null or length(v_reason) < 10 then raise exception 'declining: a reason of 10 characters or more' using errcode = '22023'; end if;
    update public.client_states set activation_requested_at = null, activation_requested_by = null where client_id = p_client and state_id = p_state;
    perform app.client_event(p_client, p_state, cs.status, cs.status, 'declined', v_reason);
    perform app.audit('client_activation_declined', p_client, jsonb_build_object('state_id', p_state, 'reason', v_reason), false);
    return app.client_gates(p_client, p_state);
  end if;
  g := app.client_gates(p_client, p_state);
  if not (app.gate_done(g, 1) and app.gate_done(g, 2) and app.gate_done(g, 3, array['approval'])) then
    raise exception 'not every gate is complete: %', app.gate_missing(g, 3, array['approval']) using errcode = '23514'; end if;
  update public.clients set approved_at = coalesce(approved_at, now()), approved_by = coalesce(approved_by, app.current_user_id()) where id = p_client;
  update public.client_states set status = 'active', status_changed_at = now(), activation_requested_at = null
   where client_id = p_client and state_id = p_state;
  perform app.client_event(p_client, p_state, cs.status, 'active', 'approved', v_reason);
  perform app.audit('client_activation_approved', p_client, jsonb_build_object('state_id', p_state), false);
  return app.client_gates(p_client, p_state);
end $$;

-- 14 · the admin: national identity after Active; the code once before; the PAN of a client that had none ----------
create or replace function app.edit_client_identity(p_client uuid, p jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.clients; e public.entities; v text; v_reason text := nullif(btrim(coalesce(p_reason, '')), ''); v_changes jsonb := '[]'::jsonb;
        x jsonb; v_reg public.id_kind; v_type public.entity_type;
begin
  if not app.is_admin() then raise exception 'the national identity is changed by the admin' using errcode = '42501'; end if;
  if v_reason is null or length(v_reason) < 10 then raise exception 'a reason of 10 characters or more' using errcode = '22023'; end if;
  select * into c from public.clients where id = p_client for update;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  select * into e from public.entities where id = c.entity_id for update;
  if p ? 'code' then
    v := upper(btrim(coalesce(p ->> 'code', '')));
    if c.approved_at is not null or c.code_edited then
      raise exception 'the client code is changed once, before the client is Active' using errcode = '23514'; end if;
    if v !~ '^[A-Z]{3,5}$' then raise exception 'client code: 3 to 5 capital letters' using errcode = '22023'; end if;
    if exists (select 1 from public.clients where code = v and id <> c.id) then raise exception 'client code: % is taken', v using errcode = '23505'; end if;
    if exists (select 1 from public.scopes where client_id = c.id) or exists (select 1 from public.farmers where client_id = c.id) then
      raise exception 'client code: it is already in this client''s scope or farmer codes' using errcode = '23514'; end if;
    update public.clients set code = v, code_edited = true where id = c.id;
    v_changes := v_changes || jsonb_build_object('field', 'code', 'old', c.code, 'new', v);
  end if;
  if p ? 'entity_type' then
    v_type := (p ->> 'entity_type')::public.entity_type;
    if not e.pan_pending then perform app.check_pan((app.cur_id(e.id, 'pan')).value, v_type); end if;
    update public.entities set entity_type = v_type where id = e.id;
    v_changes := v_changes || jsonb_build_object('field', 'entity_type', 'old', e.entity_type, 'new', v_type);
    e.entity_type := v_type;
  end if;
  if p ? 'pan' then
    v := app.check_pan(p ->> 'pan', e.entity_type);
    x := app.put_id(e.id, 'pan', null, v);
    if x is not null then
      update public.entities set pan_hash = app.id_hash('pan', v), pan_masked = app.mask_id('pan', v), pan_pending = false where id = e.id;
      v_changes := v_changes || (x || jsonb_build_object('field', 'pan'));
    end if;
  end if;
  if p ? 'legal_name' then
    v := btrim(coalesce(p ->> 'legal_name', ''));
    if length(v) < 2 or length(v) > 200 then raise exception 'legal name: 2 to 200 characters' using errcode = '22023'; end if;
    update public.entities set legal_name = v where id = e.id;
    if e.trade_name is null then update public.clients set name = v where id = c.id; end if;
    v_changes := v_changes || jsonb_build_object('field', 'legal_name', 'old', e.legal_name, 'new', v);
  end if;
  if p ? 'reg_number' then
    v_reg := case e.entity_type when 'company' then 'cin' when 'llp' then 'llpin' when 'cooperative' then 'reg_no' when 'society' then 'reg_no' end;
    if v_reg is null then raise exception 'a % has no registration number here', e.entity_type using errcode = '22023'; end if;
    x := app.put_id(e.id, v_reg, null, app.check_number(v_reg, p ->> 'reg_number'));
    if x is not null then v_changes := v_changes || (x || jsonb_build_object('field', 'reg_number')); end if;
  end if;
  perform app.audit('client_identity', p_client, jsonb_build_object('changes', v_changes, 'reason', v_reason), false);
  return app.client_identity(p_client);
end $$;

-- a client registered before PANs were asked ("PAN pending"): its State Manager or the admin types the PAN once
create or replace function app.set_client_pan(p_client uuid, p_pan text, p_type public.entity_type) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c public.clients; e public.entities; v text; x jsonb;
begin
  select * into c from public.clients where id = p_client for update;
  if c.id is null then raise exception 'not found' using errcode = 'P0002'; end if;
  if not (app.is_admin() or app.sm_of_client(p_client)) then
    raise exception 'the PAN is typed by the client''s State Manager or the admin' using errcode = '42501'; end if;
  select * into e from public.entities where id = c.entity_id for update;
  if not e.pan_pending then raise exception 'this client''s PAN is already on file (the admin changes it)' using errcode = '23514'; end if;
  v := app.check_pan(p_pan, p_type);
  perform pg_advisory_xact_lock(hashtext('grainveda_registry'));
  if exists (select 1 from public.entity_ids i where i.kind = 'pan' and i.current and i.hash = app.id_hash('pan', v)) then
    raise exception 'PAN: this number belongs to another business in the registry (the admin looks into it)' using errcode = '23505'; end if;
  x := app.put_id(e.id, 'pan', null, v);
  update public.entities set pan_hash = app.id_hash('pan', v), pan_masked = app.mask_id('pan', v), pan_pending = false, entity_type = p_type where id = e.id;
  perform app.audit('client_pan_set', p_client, jsonb_build_object('pan', x -> 'new', 'entity_type', p_type), false);
  return app.client_identity(p_client);
end $$;

-- 15 · the list for the Clients page, and the admin's queue ---------------------------------------------------------------
create or replace function app.clients_page() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_admin boolean := app.is_admin(); v_states uuid[] := case when app.is_client_login() then '{}'::uuid[] else app.my_state_ids() end;
begin
  return (select coalesce(jsonb_agg(r order by r ->> 'name'), '[]'::jsonb) from (
    select jsonb_build_object('client_id', c.id, 'name', c.name, 'legal_name', e.legal_name, 'code', c.code, 'pan_masked', e.pan_masked,
      'pan_pending', e.pan_pending, 'own_brand', e.own_brand, 'entity_type', e.entity_type, 'national_status', app.national_status(c.id),
      'states', (select coalesce(jsonb_agg(jsonb_build_object('state_id', cs.state_id, 'state', s.name, 'status', cs.status, 'legacy', cs.legacy,
                   'awaiting_approval', cs.activation_requested_at is not null,
                   'progress', case when v_admin or cs.state_id = any (v_states) then
                       (select jsonb_build_object('done', count(*) filter (where (it ->> 'done')::boolean), 'of', count(*))
                          from jsonb_array_elements(app.client_gates(c.id, cs.state_id) -> 'gates') g, jsonb_array_elements(g -> 'items') it
                         where (it ->> 'needed')::boolean) end) order by s.name), '[]'::jsonb)
                   from public.client_states cs join public.states s on s.id = cs.state_id
                  where cs.client_id = c.id and (v_admin or app.client_owner_of(c.id) or cs.state_id = any (v_states)
                                                 or (app.cm_of_client(c.id) and cs.state_id = c.state_id)))) as r
      from public.clients c join public.entities e on e.id = c.entity_id
     where v_admin or app.client_owner_of(c.id) or app.cm_of_client(c.id)
        or exists (select 1 from public.client_states cs where cs.client_id = c.id and cs.state_id = any (v_states))) q);
end $$;

create or replace function app.client_approvals() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not app.is_admin() then raise exception 'the admin''s queue' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('client_id', c.id, 'name', c.name, 'code', c.code, 'state_id', cs.state_id, 'state', s.name,
            'requested_at', cs.activation_requested_at, 'requested_by', (select display_name from public.app_users where id = cs.activation_requested_by))
            order by cs.activation_requested_at), '[]'::jsonb)
            from public.client_states cs join public.clients c on c.id = cs.client_id join public.states s on s.id = cs.state_id
           where cs.activation_requested_at is not null);
end $$;

-- 16 · B4: the scope follows its client's status in its state ---------------------------------------------------------
create or replace function app.scopes_client_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare st public.client_status; v_legacy boolean; e public.entities; v_apeda boolean;
begin
  if auth.uid() is null then return new; end if;                    -- seeds and migrations; a person acting is checked
  select cs.status, cs.legacy into st, v_legacy from public.client_states cs where cs.client_id = new.client_id and cs.state_id = new.state_id;
  if tg_op = 'INSERT' or new.client_id is distinct from old.client_id or new.state_id is distinct from old.state_id then
    if st is null then raise exception 'this client is not registered in this scope''s state' using errcode = '23514'; end if;
    if st not in ('diagnostic', 'active') then
      raise exception 'a scope is prepared once the client is in Diagnostic in this state (it is %)', st using errcode = '23514'; end if;
  end if;
  if new.status = 'active' and (tg_op = 'INSERT' or old.status = 'draft') then
    if st is distinct from 'active' then
      raise exception 'the client is not Active in this state (it is %): the State Manager completes its registration first', coalesce(st::text, 'not registered') using errcode = '23514'; end if;
    -- a kept test client (registered before the registry) is not asked its IEC until it is backfilled
    if 'export' = any (new.market_codes) and not coalesce(v_legacy, false) then
      select en.* into e from public.clients c join public.entities en on en.id = c.entity_id where c.id = new.client_id;
      if (app.cur_id(e.id, 'iec')).id is null or (app.cur_doc(new.client_id, 'iec')).id is null then
        raise exception 'an export scope needs the client''s IEC on file (Clients)' using errcode = '23514'; end if;
      select apeda_scheduled into v_apeda from public.crops where id = new.crop_id;
      if v_apeda and (coalesce((app.cur_id(e.id, 'rcmc')).expires_on, '-infinity'::date) <= app.today() or (app.cur_doc(new.client_id, 'rcmc')).id is null) then
        raise exception 'an export scope of an APEDA-scheduled crop needs the client''s APEDA RCMC on file and in date (Clients)' using errcode = '23514'; end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists scopes_a1b_client_gate on public.scopes;
create trigger scopes_a1b_client_gate before insert or update on public.scopes for each row execute function app.scopes_client_gate();

-- a scope is in one of its client's states (migration 41 said: its own state)
create or replace function app.scopes_place() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.state_id is null then
    select c.state_id into new.state_id from public.clients c where c.id = new.client_id;
  end if;
  if auth.uid() is not null
     and (tg_op = 'INSERT' or new.client_id is distinct from old.client_id or new.state_id is distinct from old.state_id)
     and not exists (select 1 from public.client_states cs where cs.client_id = new.client_id and cs.state_id = new.state_id) then
    raise exception 'a scope is in its client''s own state or a state added to the client (Clients)' using errcode = '42501'; end if;
  if auth.uid() is not null and (tg_op = 'INSERT' or new.crop_id is distinct from old.crop_id)
     and exists (select 1 from public.crops cr where cr.id = new.crop_id and cr.state_id is not null and cr.state_id <> new.state_id) then
    raise exception 'this crop belongs to another state' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' and new.state_id is distinct from old.state_id then
    raise exception 'a scope''s state is frozen after activation; open a new scope' using errcode = '42501';
  end if;
  return new;
end $$;

-- the states a client is in: its rows here, its home and its scopes' (migration 46's helper, kept)
create or replace function app.client_states(p_client uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct x), '{}') from (
    select state_id as x from public.clients where id = p_client
    union select state_id from public.client_states where client_id = p_client
    union select state_id from public.scopes where client_id = p_client) q where x is not null
$$;

create or replace function app.can_access_client(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from app.eff_assignments(app.current_user_id()) a
     where (a.lens = 'client' and a.client_id = p_client)
        or (a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                  or exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.state_id = a.state_id)
                                  or exists (select 1 from public.scopes s where s.client_id = p_client and s.state_id = a.state_id)))
        or (a.lens = 'scope' and exists (select 1 from public.scopes s where s.id = a.scope_id and s.client_id = p_client)))
$$;

create or replace function app.manages_client(p_user uuid, p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from app.eff_assignments(p_user) a
     where (a.lens = 'client' and a.op_role = 'client_account' and a.client_id = p_client)
        or (a.lens = 'state' and (a.state_id = (select c.state_id from public.clients c where c.id = p_client)
                                  or exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.state_id = a.state_id))))
$$;

-- the client rows a State Manager reads: the clients in his states
create or replace function app.client_in_my_states(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.state_id = any (app.my_state_ids()))
$$;
drop policy if exists clients_read_by_row on public.clients;
create policy clients_read_by_row on public.clients for select to authenticated
  using (app.is_admin() or state_id = any (app.my_state_ids()) or app.client_in_my_states(id));
-- from here a client is written through the functions above only
revoke insert, update, delete on public.clients from authenticated, anon;

-- 17 · existing clients: an entity each, "PAN pending"; a seed or a test (no person acting) gets the same ---------------
create or replace function app.clients_registry() returns trigger
language plpgsql security definer set search_path = public as $$
declare e public.entities;
begin
  if new.entity_id is not null then return new; end if;
  insert into public.entities (legal_name, trade_name, entity_type, pan_pending, own_brand)
  values (case when new.type = 'grainveda' then 'GrainVeda Private Limited' else new.name end,
          case when new.type = 'grainveda' then 'Prasaadam' end, 'company', true, new.type = 'grainveda')
  returning * into e;
  insert into public.entity_roles (entity_id, role) values (e.id, 'client') on conflict do nothing;
  new.entity_id := e.id;
  if cardinality(new.states_of_interest) = 0 then new.states_of_interest := array[new.state_id]; end if;
  return new;
end $$;
drop trigger if exists clients_a1_registry on public.clients;
create trigger clients_a1_registry before insert on public.clients for each row execute function app.clients_registry();

-- its home state: Active as a kept test client off production; on production a Prospect that goes through the gates
create or replace function app.clients_home_state() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_prod boolean := app.environment() = 'production';
begin
  -- a person creates a client through app.create_client (which writes its state itself); this is for seeds and tests
  if auth.uid() is not null or exists (select 1 from public.client_states where client_id = new.id) then return null; end if;
  insert into public.client_states (client_id, state_id, status, legacy)
  values (new.id, new.state_id, (case when v_prod then 'prospect' else 'active' end)::public.client_status, not v_prod)
  on conflict (client_id, state_id) do nothing;
  insert into public.client_status_events (client_id, state_id, to_status, act, reason)
  values (new.id, new.state_id, case when v_prod then 'prospect'::public.client_status else 'active' end, 'migrated',
          case when v_prod then 'registered before the registry: PAN pending, through the gates' else 'kept test client: Active with PAN pending' end);
  return null;
end $$;
drop trigger if exists clients_z1_home_state on public.clients;
create trigger clients_z1_home_state after insert on public.clients for each row execute function app.clients_home_state();

do $$ declare c record; e public.entities; v_prod boolean := app.environment() = 'production'; s uuid;
begin
  for c in select * from public.clients where entity_id is null order by created_at loop
    insert into public.entities (legal_name, trade_name, entity_type, pan_pending, own_brand, created_at)
    values (case when c.type = 'grainveda' then 'GrainVeda Private Limited' else c.name end,
            case when c.type = 'grainveda' then 'Prasaadam' end, 'company', true, c.type = 'grainveda', c.created_at)
    returning * into e;
    insert into public.entity_roles (entity_id, role, since) values (e.id, 'client', c.created_at) on conflict do nothing;
    update public.clients set entity_id = e.id,
           states_of_interest = array(select distinct x from unnest(array[c.state_id] || array(select sc.state_id from public.scopes sc where sc.client_id = c.id)) x),
           crops_of_interest = array(select distinct sc.crop_id from public.scopes sc where sc.client_id = c.id)
     where id = c.id;
    for s in select distinct x from unnest(array[c.state_id] || array(select sc.state_id from public.scopes sc where sc.client_id = c.id)) x where x is not null loop
      insert into public.client_states (client_id, state_id, status, legacy, created_at, status_changed_at)
      values (c.id, s, (case when v_prod then 'prospect' else 'active' end)::public.client_status, not v_prod, c.created_at, now())
      on conflict (client_id, state_id) do nothing;
      insert into public.client_status_events (client_id, state_id, to_status, act, reason)
      values (c.id, s, case when v_prod then 'prospect'::public.client_status else 'active' end, 'migrated',
              case when v_prod then 'registered before the registry: PAN pending, through the gates' else 'kept test client: Active with PAN pending' end);
    end loop;
  end loop;
end $$;

-- 18 · the documents' store ------------------------------------------------------------------------------------------
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage schema not present: client-docs bucket policies skipped';
    return;
  end if;
  insert into storage.buckets (id, name, public) values ('client-docs', 'client-docs', false) on conflict (id) do nothing;
  execute $p$drop policy if exists client_docs_read on storage.objects$p$;
  execute $p$drop policy if exists client_docs_upload on storage.objects$p$;
  execute $p$create policy client_docs_read on storage.objects for select to authenticated
    using (bucket_id = 'client-docs' and app.may_read_client_file(name))$p$;
  execute $p$create policy client_docs_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'client-docs' and app.may_write_client_object(name))$p$;
end $$;

-- 19 · grants: the functions above are the way in -------------------------------------------------------------------------
revoke execute on function app.id_hash(text, text), app.mask_id(text, text), app.pan_letter(public.entity_type), app.norm_id(text),
  app.check_pan(text, public.entity_type), app.check_gstin(text, text, uuid), app.check_number(public.id_kind, text), app.core_name(text),
  app.similar_entity(text, uuid), app.new_client_code(text), app.sm_of_client(uuid, uuid), app.client_owner_of(uuid), app.cm_of_client(uuid),
  app.cur_id(uuid, public.id_kind, uuid), app.cur_doc(uuid, public.client_doc_kind, uuid), app.filled(jsonb, text[]),
  app.national_status(uuid), app.client_exports(uuid), app.client_gates(uuid, uuid), app.gate_done(jsonb, int, text[]),
  app.gate_missing(jsonb, int, text[]), app.id_trace(text, text), app.client_event(uuid, uuid, public.client_status, public.client_status, text, text),
  app.put_id(uuid, public.id_kind, uuid, text, date), app.doc_is_national(public.client_doc_kind), app.client_doc_client(text),
  app.scopes_client_gate(), app.states_gst_code(), app.clients_registry(), app.clients_home_state(), app.no_update_delete(), app.entity_ids_guard()
  from public, anon, authenticated;
revoke execute on function app.lookup_pan(text, text, public.entity_type), app.create_client(jsonb), app.client_identity(uuid),
  app.client_view(uuid), app.save_client_details(uuid, uuid, jsonb),
  app.add_client_document(uuid, uuid, public.client_doc_kind, text, text, bigint, text, jsonb),
  app.client_kyc(uuid, uuid), app.client_move(uuid, uuid, public.client_status, text),
  app.decide_client_activation(uuid, uuid, boolean, text), app.edit_client_identity(uuid, jsonb, text),
  app.set_client_pan(uuid, text, public.entity_type), app.clients_page(), app.client_approvals(),
  app.may_write_client_object(text), app.may_read_client_file(text), app.client_in_my_states(uuid), app.gst_code_for(text)
  from public, anon;
revoke execute on function app.gst_code_for(text) from authenticated;
grant execute on function app.lookup_pan(text, text, public.entity_type), app.create_client(jsonb), app.client_identity(uuid),
  app.client_view(uuid), app.save_client_details(uuid, uuid, jsonb),
  app.add_client_document(uuid, uuid, public.client_doc_kind, text, text, bigint, text, jsonb),
  app.client_kyc(uuid, uuid), app.client_move(uuid, uuid, public.client_status, text),
  app.decide_client_activation(uuid, uuid, boolean, text), app.edit_client_identity(uuid, jsonb, text),
  app.set_client_pan(uuid, text, public.entity_type), app.clients_page(), app.client_approvals(),
  app.may_write_client_object(text), app.may_read_client_file(text), app.client_in_my_states(uuid)
  to authenticated;

notify pgrst, 'reload schema';
