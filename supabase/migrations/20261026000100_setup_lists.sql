-- GrainVeda MVP · migration 51: the set-up lists (the operator-stages brief, release 4: Part B; A14, A15). Veda,
-- 15 Oct 2026 (decision G19). docs/OPERATOR_STAGES_BRIEF.md Part B; docs/FIX_LIST.md item 46.
--   Lists kept by the Client Manager, per client: collection points, mills, packing units, buyers, the pack list (SKUs).
--   Kept by the State Manager: labs (per state), market profiles (per crop, versioned, with their source document),
--   places (districts are loaded for Uttar Pradesh; blocks and villages are added as farmers are registered).
--   The parameter library is GrainVeda's reference data, loaded here (the admin runs nothing: decision G16).
--   Crops: GI crop yes/no, GI blocks, shelf life per packing material, a reference photo.
--   Farmers: block, farm GPS, land record and GI authorised-user numbers; GPS and a listed district are required at the
--   Client Manager's verification for farmers registered from now on; the GI area per crop; a GPS far from the district's
--   other farmers is shown to the State Manager.
--   A14: the ledger banner says how many blocks were added since the last full check. A15: the roster pool lists free
--   people first, then people already on other scopes with their current work.
-- Additive only: nothing is deleted or rewritten. The stages start using the lists in releases 52 to 55.
select set_config('app.change_path', 'migration 51', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- Places: districts (per state), blocks and villages
-- ---------------------------------------------------------------------------------------------------------------
create table if not exists public.places (
  id          uuid primary key default gen_random_uuid(),
  state_id    uuid not null references public.states(id),
  district    text not null check (length(btrim(district)) between 2 and 80),
  block       text check (block is null or length(btrim(block)) between 2 and 80),
  village     text check (village is null or length(btrim(village)) between 2 and 80),
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  check (village is null or block is not null)
);
create unique index if not exists places_unique on public.places (state_id, app.norm_place(district), coalesce(app.norm_place(block), ''), coalesce(app.norm_place(village), ''));
alter table public.places enable row level security;
revoke all on public.places from anon, authenticated;
grant select on public.places to authenticated;
drop policy if exists places_read on public.places;
create policy places_read on public.places for select to authenticated using (true);   -- names of places, nothing personal
drop trigger if exists zz_change_log on public.places;
create trigger zz_change_log after insert or update or delete on public.places for each row execute function app.log_change('id');

-- The districts of Uttar Pradesh (75), for every state of that name: now, and when one is created (a fresh start).
create or replace function app.up_districts() returns text[] language sql immutable as $$
  select array['Agra','Aligarh','Ambedkar Nagar','Amethi','Amroha','Auraiya','Ayodhya','Azamgarh','Baghpat','Bahraich','Ballia',
    'Balrampur','Banda','Barabanki','Bareilly','Basti','Bhadohi','Bijnor','Budaun','Bulandshahr','Chandauli','Chitrakoot','Deoria',
    'Etah','Etawah','Farrukhabad','Fatehpur','Firozabad','Gautam Buddh Nagar','Ghaziabad','Ghazipur','Gonda','Gorakhpur','Hamirpur',
    'Hapur','Hardoi','Hathras','Jalaun','Jaunpur','Jhansi','Kannauj','Kanpur Dehat','Kanpur Nagar','Kasganj','Kaushambi','Kushinagar',
    'Lakhimpur Kheri','Lalitpur','Lucknow','Maharajganj','Mahoba','Mainpuri','Mathura','Mau','Meerut','Mirzapur','Moradabad',
    'Muzaffarnagar','Pilibhit','Pratapgarh','Prayagraj','Raebareli','Rampur','Saharanpur','Sambhal','Sant Kabir Nagar','Shahjahanpur',
    'Shamli','Shravasti','Siddharthnagar','Sitapur','Sonbhadra','Sultanpur','Unnao','Varanasi'] $$;
create or replace function app.seed_state_places(p_state uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; d text;
begin
  if not exists (select 1 from public.states s where s.id = p_state and app.norm_place(s.name) = app.norm_place('Uttar Pradesh')) then return 0; end if;
  foreach d in array app.up_districts() loop
    insert into public.places (state_id, district) values (p_state, d) on conflict do nothing;
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function app.states_seed_places() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform app.seed_state_places(new.id); return new; end $$;
drop trigger if exists states_z1_places on public.states;
create trigger states_z1_places after insert on public.states for each row execute function app.states_seed_places();
select app.seed_state_places(id) from public.states;

-- A district is on the state's list (a state with no list accepts what is typed).
create or replace function app.district_listed(p_state uuid, p_district text) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.places p where p.state_id = p_state and p.block is null)
      or exists (select 1 from public.places p where p.state_id = p_state and p.block is null and app.norm_place(p.district) = app.norm_place(p_district)) $$;

-- Blocks and villages are added by the people who register farmers there (and the State Manager); a district only by
-- the State Manager. The same place written differently is the same place.
create or replace function app.add_place(p_state uuid, p_district text, p_block text, p_village text) returns public.places
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.places; d text;
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not (p_state = any (app.my_state_ids())
          or exists (select 1 from public.clients c where app.farmer_create(c.id) and p_state = any (app.client_states(c.id)))) then
    raise exception 'places are added by the State Manager, the Client Manager or Procurement of this state' using errcode = '42501'; end if;
  select p.district into d from public.places p where p.state_id = p_state and p.block is null and app.norm_place(p.district) = app.norm_place(p_district);
  if d is null then
    if nullif(btrim(p_block), '') is not null or not (p_state = any (app.my_state_ids())) then
      raise exception 'the district % is not on the list of this state (the State Manager adds districts)', btrim(p_district) using errcode = '23514'; end if;
    insert into public.places (state_id, district, created_by) values (p_state, btrim(p_district), me) returning * into r;
    return r;
  end if;
  if nullif(btrim(p_block), '') is null then raise exception 'name the block' using errcode = '23514'; end if;
  insert into public.places (state_id, district, block, created_by) values (p_state, d, btrim(p_block), me) on conflict do nothing;
  if nullif(btrim(p_village), '') is null then
    select * into r from public.places p where p.state_id = p_state and app.norm_place(p.district) = app.norm_place(d)
       and app.norm_place(p.block) = app.norm_place(p_block) and p.village is null;
    return r;
  end if;
  insert into public.places (state_id, district, block, village, created_by)
  select p_state, d, p.block, btrim(p_village), me from public.places p
   where p.state_id = p_state and app.norm_place(p.district) = app.norm_place(d) and app.norm_place(p.block) = app.norm_place(p_block) and p.village is null
  on conflict do nothing;
  select * into r from public.places p where p.state_id = p_state and app.norm_place(p.district) = app.norm_place(d)
     and app.norm_place(p.block) = app.norm_place(p_block) and app.norm_place(p.village) = app.norm_place(p_village);
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- The Client Manager's lists (per client): written through the table, read by anyone who works for the client
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.valid_gps(p_lat numeric, p_lng numeric) returns boolean language sql immutable as $$
  select (p_lat is null and p_lng is null) or (p_lat between 6 and 37.5 and p_lng between 68 and 97.5) $$;   -- India

create table if not exists public.collection_points (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id),
  name        text not null check (length(btrim(name)) between 2 and 80),
  kind        text not null check (kind in ('centre', 'field_point', 'store')),
  district    text not null check (length(btrim(district)) between 2 and 80),
  block       text,
  village     text,
  lat         numeric(9,6),
  lng         numeric(9,6),
  active      boolean not null default true,
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  check (app.valid_gps(lat, lng))
);
create unique index if not exists collection_points_name on public.collection_points (client_id, lower(btrim(name)));

create table if not exists public.mills (
  id                 uuid primary key default gen_random_uuid(),
  client_id          uuid not null references public.clients(id),
  name               text not null check (length(btrim(name)) between 2 and 80),
  place              text not null check (length(btrim(place)) between 2 and 120),
  lat                numeric(9,6),
  lng                numeric(9,6),
  ownership          text not null check (ownership in ('own', 'hired')),
  dedicated_crop_id  uuid references public.crops(id),           -- "dedicated to this crop": which crop, or none
  active             boolean not null default true,
  created_by         uuid references public.app_users(id),
  created_at         timestamptz not null default now(),
  check (app.valid_gps(lat, lng))
);
create unique index if not exists mills_name on public.mills (client_id, lower(btrim(name)));

create table if not exists public.packing_units (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id),
  name          text not null check (length(btrim(name)) between 2 and 80),
  place         text not null check (length(btrim(place)) between 2 and 120),
  ownership     text not null check (ownership in ('own', 'contract')),
  fssai_licence text check (fssai_licence is null or fssai_licence ~ '^[0-9]{14}$'),
  active        boolean not null default true,
  created_by    uuid references public.app_users(id),
  created_at    timestamptz not null default now()
);
create unique index if not exists packing_units_name on public.packing_units (client_id, lower(btrim(name)));

create table if not exists public.buyers (
  id             uuid primary key default gen_random_uuid(),
  client_id      uuid not null references public.clients(id),
  name           text not null check (length(btrim(name)) between 2 and 120),
  country        text not null check (country ~ '^[A-Z]{2}$'),            -- ISO 3166-1 alpha-2 (IN for domestic)
  gstin          text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z0-9]{13}$'),
  importer_id    text check (importer_id is null or length(btrim(importer_id)) between 2 and 60),
  address        text not null check (length(btrim(address)) between 5 and 300),
  fssai_licence  text check (fssai_licence is null or fssai_licence ~ '^[0-9]{14}$'),
  contact_name   text check (contact_name is null or length(btrim(contact_name)) between 2 and 80),
  contact_email  text check (contact_email is null or contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  contact_phone  text check (contact_phone is null or contact_phone ~ '^\+?[0-9 ]{8,16}$'),
  active         boolean not null default true,
  created_by     uuid references public.app_users(id),
  created_at     timestamptz not null default now(),
  check (country <> 'IN' or gstin is not null or fssai_licence is not null)   -- a domestic buyer: a GSTIN or an FSSAI licence
);
create unique index if not exists buyers_name on public.buyers (client_id, lower(btrim(name)), country);

create table if not exists public.pack_skus (
  id          uuid primary key default gen_random_uuid(),
  client_id   uuid not null references public.clients(id),
  size        numeric(10,3) not null check (size > 0),
  unit        text not null check (unit in ('kg', 'g')),
  material    text not null check (material in ('pouch', 'jute', 'pp_bag', 'vacuum', 'carton', 'other')),
  market      text not null check (market in ('domestic', 'export', 'any')),
  label_type  text not null default 'sticker' check (label_type in ('sticker', 'printed', 'tag')),
  active      boolean not null default true,
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now()
);
create unique index if not exists pack_skus_unique on public.pack_skus (client_id, size, unit, material, market);
create or replace function app.sku_kg(s public.pack_skus) returns numeric language sql immutable as $$
  select case when s.unit = 'g' then s.size / 1000 else s.size end $$;

-- One rule for all five: read by whoever works for the client; written (added, changed, retired) by its Client Manager.
-- Nothing is deleted: a row no longer used is set inactive. Who added it, and when, is the server's.
create or replace function app.client_list_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.created_by := app.current_user_id(); new.created_at := now(); end if;
  else
    new.client_id := old.client_id; new.created_by := old.created_by; new.created_at := old.created_at;
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['collection_points', 'mills', 'packing_units', 'buyers', 'pack_skus'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (app.can_access_client(client_id))', t || '_read', t);
    execute format('drop policy if exists %I on public.%I', t || '_insert', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (app.runs_client(client_id))', t || '_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_update', t);
    execute format('create policy %I on public.%I for update to authenticated using (app.runs_client(client_id)) with check (app.runs_client(client_id))', t || '_update', t);
    execute format('drop trigger if exists %I on public.%I', t || '_a0_guard', t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function app.client_list_guard()', t || '_a0_guard', t);
    execute format('drop trigger if exists zz_change_log on public.%I', t);
    execute format('create trigger zz_change_log after insert or update or delete on public.%I for each row execute function app.log_change(''id'')', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Labs (the State Manager, per state)
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.labs (
  id                uuid primary key default gen_random_uuid(),
  state_id          uuid not null references public.states(id),
  name              text not null check (length(btrim(name)) between 2 and 120),
  accreditation_no  text check (accreditation_no is null or length(btrim(accreditation_no)) between 3 and 40),
  kind              text not null check (kind in ('external', 'in_house')),
  location          text not null check (length(btrim(location)) between 2 and 120),
  active            boolean not null default true,
  created_by        uuid references public.app_users(id),
  created_at        timestamptz not null default now(),
  check (kind = 'in_house' or accreditation_no is not null)              -- an external lab names its accreditation
);
create unique index if not exists labs_name on public.labs (state_id, lower(btrim(name)));
alter table public.labs enable row level security;
revoke all on public.labs from anon, authenticated;
grant select, insert, update on public.labs to authenticated;
drop policy if exists labs_read on public.labs;
create policy labs_read on public.labs for select to authenticated using (true);
drop policy if exists labs_insert on public.labs;
create policy labs_insert on public.labs for insert to authenticated
  with check (app.holds_op_role('state_supervisor') and state_id = any (app.my_state_ids()));
drop policy if exists labs_update on public.labs;
create policy labs_update on public.labs for update to authenticated
  using (app.holds_op_role('state_supervisor') and state_id = any (app.my_state_ids()))
  with check (state_id = any (app.my_state_ids()));
create or replace function app.state_list_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is not null then new.created_by := app.current_user_id(); new.created_at := now(); end if;
  else
    new.state_id := old.state_id; new.created_by := old.created_by; new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists labs_a0_guard on public.labs;
create trigger labs_a0_guard before insert or update on public.labs for each row execute function app.state_list_guard();
drop trigger if exists zz_change_log on public.labs;
create trigger zz_change_log after insert or update or delete on public.labs for each row execute function app.log_change('id');

-- ---------------------------------------------------------------------------------------------------------------------
-- The parameter library (GrainVeda's reference data; a crop's quality schema picks from it)
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.quality_param_library (
  param      text primary key check (param ~ '^[a-z][a-z0-9_]{1,40}$'),
  name       text not null,
  unit       text,
  type       text not null default 'number' check (type in ('number', 'grade', 'yesno')),
  method     text,
  done_by    text not null check (done_by in ('in_house', 'lab', 'either')),
  grp        text not null check (grp in ('basic', 'authenticity', 'safety')),
  sort_order int not null default 0
);
alter table public.quality_param_library enable row level security;
revoke all on public.quality_param_library from anon, authenticated;
grant select on public.quality_param_library to authenticated;
drop policy if exists qpl_read on public.quality_param_library;
create policy qpl_read on public.quality_param_library for select to authenticated using (true);
drop trigger if exists zz_change_log on public.quality_param_library;
create trigger zz_change_log after insert or update or delete on public.quality_param_library for each row execute function app.log_change('param');
-- The brief's starting set for Kalanamak (C5); the names and methods are the usual ones, the limits come from the
-- labs and buyers through the market profiles, never from here.
insert into public.quality_param_library (param, name, unit, type, method, done_by, grp, sort_order) values
  ('moisture_pct',        'Moisture',                         '%',     'number', 'Moisture meter / oven (IS 4333)',      'in_house', 'basic', 10),
  ('broken_pct',          'Broken grains',                    '%',     'number', 'Visual count, 100 g sample',           'in_house', 'basic', 20),
  ('foreign_matter_pct',  'Foreign matter',                   '%',     'number', 'Visual, by weight',                    'in_house', 'basic', 30),
  ('damaged_pct',         'Damaged or discoloured grains',    '%',     'number', 'Visual, by weight',                    'in_house', 'basic', 40),
  ('admixture_pct',       'Admixture of other varieties',     '%',     'number', 'Grain morphology / DNA (lab)',         'either',   'authenticity', 50),
  ('grain_length_mm',     'Grain length',                     'mm',    'number', 'Calliper, 20 grains',                  'either',   'authenticity', 60),
  ('aroma',               'Aroma',                            null,    'grade',  'Sensory panel / 2-AP (lab)',           'either',   'authenticity', 70),
  ('live_insects',        'Live insects',                     null,    'yesno',  'Visual',                               'in_house', 'basic', 80),
  ('pesticide_residues',  'Pesticide residues (multi-residue)', 'mg/kg', 'number', 'LC-MS/MS and GC-MS/MS multi-residue', 'lab',      'safety', 90),
  ('aflatoxin_ppb',       'Aflatoxin B1',                     'µg/kg', 'number', 'HPLC',                                 'lab',      'safety', 100),
  ('heavy_metals',        'Heavy metals (lead, cadmium, arsenic)', 'mg/kg', 'number', 'ICP-MS',                          'lab',      'safety', 110)
on conflict (param) do nothing;
-- Any parameter a crop already uses is in the library too (nothing a crop measures is outside it).
insert into public.quality_param_library (param, name, unit, type, done_by, grp, sort_order)
select distinct on (q->>'param') q->>'param', coalesce(q->>'label', q->>'param'), q->>'unit',
       case when q->>'type' in ('grade', 'yesno') then q->>'type' else 'number' end, 'either', 'basic', 500
  from public.crops c, jsonb_array_elements(c.quality_params) q
 where q->>'param' ~ '^[a-z][a-z0-9_]{1,40}$'
on conflict (param) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------
-- Reference files: a market profile's source document, a crop's reference photo (private store "reference")
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.reference_files (
  id           uuid primary key default gen_random_uuid(),
  crop_id      uuid not null references public.crops(id),
  kind         text not null check (kind in ('profile_source', 'crop_photo')),
  storage_path text not null unique check (storage_path ~ '^crop/[0-9a-f-]{36}/[0-9a-f]{16}\.[a-z0-9]{1,5}$'),
  sha256       text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  file_name    text,
  uploaded_by  uuid not null references public.app_users(id),
  uploaded_at  timestamptz not null default now()
);
alter table public.reference_files enable row level security;
revoke all on public.reference_files from anon, authenticated;
grant select on public.reference_files to authenticated;
drop policy if exists reference_files_read on public.reference_files;
create policy reference_files_read on public.reference_files for select to authenticated using (true);
drop trigger if exists zz_change_log on public.reference_files;
create trigger zz_change_log after insert or update or delete on public.reference_files for each row execute function app.log_change('id');

create or replace function app.manages_crop(p_crop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  -- the same as who may change the crop (crops_update): a State Manager, for a crop of his state or one with no state yet
  select app.holds_op_role('state_supervisor') and exists (select 1 from public.crops c where c.id = p_crop
           and (c.state_id is null or c.state_id = any (app.my_state_ids()))) $$;

create or replace function app.register_reference_file(p_crop uuid, p_kind text, p_path text, p_sha256 text, p_name text) returns public.reference_files
language plpgsql security definer set search_path = public as $$
declare r public.reference_files;
begin
  if not app.manages_crop(p_crop) then raise exception 'the State Manager of the crop''s state keeps its documents' using errcode = '42501'; end if;
  if split_part(p_path, '/', 2) <> p_crop::text then raise exception 'the file is not filed under this crop' using errcode = '22023'; end if;
  insert into public.reference_files (crop_id, kind, storage_path, sha256, file_name, uploaded_by)
  values (p_crop, p_kind, p_path, lower(p_sha256), left(btrim(coalesce(p_name, '')), 120), app.current_user_id())
  on conflict (storage_path) do update set storage_path = excluded.storage_path returning * into r;
  perform app.audit('reference_file', r.id, jsonb_build_object('crop', p_crop, 'kind', p_kind, 'sha256', r.sha256, 'name', r.file_name), false);
  return r;
end $$;

do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'storage schema not present: reference bucket policies skipped (local build)';
    return;
  end if;
  insert into storage.buckets (id, name, public) values ('reference', 'reference', false) on conflict (id) do nothing;
  execute $p$drop policy if exists reference_read on storage.objects$p$;
  execute $p$drop policy if exists reference_upload on storage.objects$p$;
  execute $p$create policy reference_read on storage.objects for select to authenticated using (bucket_id = 'reference')$p$;
  execute $p$create policy reference_upload on storage.objects for insert to authenticated
    with check (bucket_id = 'reference' and (storage.foldername(name))[1] = 'crop'
                and app.manages_crop(((storage.foldername(name))[2])::uuid))$p$;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Market profiles (per crop, versioned; the State Manager): parameters with limits, export documents, source document
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.market_profiles (
  id             uuid primary key default gen_random_uuid(),
  crop_id        uuid not null references public.crops(id),
  code           text not null check (code ~ '^[a-z][a-z0-9_]{1,20}$'),       -- domestic, export, eu, gcc, usa …
  name           text not null check (length(btrim(name)) between 2 and 60),
  version        int not null check (version >= 1),
  status         text not null default 'draft' check (status in ('draft', 'active', 'retired')),
  params         jsonb not null default '[]'::jsonb check (jsonb_typeof(params) = 'array'),
  export_docs    text[] not null default '{}',
  source_file_id uuid references public.reference_files(id),
  source_note    text,
  supersedes_id  uuid references public.market_profiles(id),
  created_by     uuid references public.app_users(id),
  created_at     timestamptz not null default now(),
  activated_at   timestamptz,
  activated_by   uuid references public.app_users(id),
  unique (crop_id, code, version)
);
create unique index if not exists market_profiles_one_active on public.market_profiles (crop_id, code) where status = 'active';
alter table public.market_profiles enable row level security;
revoke all on public.market_profiles from anon, authenticated;
grant select on public.market_profiles to authenticated;
drop policy if exists market_profiles_read on public.market_profiles;
create policy market_profiles_read on public.market_profiles for select to authenticated using (true);
drop trigger if exists zz_change_log on public.market_profiles;
create trigger zz_change_log after insert or update or delete on public.market_profiles for each row execute function app.log_change('id');

-- A parameter list is well formed: each parameter is in the library, once; a number has an operator and a limit; a
-- grade the grades that pass; a yes/no the answer that passes.
create or replace function app.profile_params_problems(p jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; seen text[] := '{}'; t text; lib public.quality_param_library;
begin
  if jsonb_typeof(p) <> 'array' then return 'the parameters are a list'; end if;
  for x in select * from jsonb_array_elements(p) loop
    select * into lib from public.quality_param_library where param = x->>'param';
    if lib.param is null then return format('%s is not in the parameter library', coalesce(x->>'param', '?')); end if;
    if lib.param = any (seen) then return format('%s is listed twice', lib.name); end if;
    seen := seen || lib.param;
    t := lib.type;
    if t = 'number' and (coalesce(x->>'operator', '') not in ('<=', '>=', '<', '>') or coalesce(jsonb_typeof(x->'limit'), '') <> 'number') then
      return format('%s needs an operator and a number limit', lib.name); end if;
    if t = 'grade' and (coalesce(jsonb_typeof(x->'pass'), '') <> 'array' or coalesce(jsonb_array_length(case when jsonb_typeof(x->'pass') = 'array' then x->'pass' end), 0) = 0) then
      return format('%s needs the grades that pass', lib.name); end if;
    if t = 'yesno' and coalesce(jsonb_typeof(x->'pass'), '') <> 'boolean' then return format('%s needs the answer that passes', lib.name); end if;
  end loop;
  return null;
end $$;

-- Save a profile: a draft is changed in place; an active one gets a new draft version (the active one stays in use
-- until the new version is activated; a scope keeps the version it started with, from release 53).
create or replace function app.save_market_profile(p jsonb) returns public.market_profiles
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); cur public.market_profiles; r public.market_profiles; v_crop uuid; v_code text; v_problem text;
begin
  if nullif(p->>'id', '') is not null then
    select * into cur from public.market_profiles where id = (p->>'id')::uuid;
    if cur.id is null then raise exception 'market profile not found' using errcode = 'P0002'; end if;
    v_crop := cur.crop_id; v_code := cur.code;
  else
    v_crop := (p->>'crop_id')::uuid; v_code := lower(btrim(p->>'code'));
  end if;
  if not app.manages_crop(v_crop) then raise exception 'the State Manager of the crop''s state keeps its market profiles' using errcode = '42501'; end if;
  v_problem := app.profile_params_problems(coalesce(p->'params', cur.params, '[]'::jsonb));
  if v_problem is not null then raise exception 'market profile: %', v_problem using errcode = '23514'; end if;
  if cur.id is not null and cur.status = 'draft' then
    update public.market_profiles set name = coalesce(nullif(btrim(p->>'name'), ''), name), params = coalesce(p->'params', params),
           export_docs = coalesce(array(select btrim(x) from jsonb_array_elements_text(p->'export_docs') x where btrim(x) <> ''), export_docs),
           source_file_id = coalesce(nullif(p->>'source_file_id', '')::uuid, source_file_id), source_note = coalesce(nullif(btrim(p->>'source_note'), ''), source_note)
     where id = cur.id returning * into r;
    return r;
  end if;
  if exists (select 1 from public.market_profiles m where m.crop_id = v_crop and m.code = v_code and m.status = 'draft') then
    raise exception 'there is a draft of this profile already: change that one' using errcode = '23505'; end if;
  insert into public.market_profiles (crop_id, code, name, version, params, export_docs, source_file_id, source_note, supersedes_id, created_by)
  values (v_crop, v_code, coalesce(nullif(btrim(p->>'name'), ''), cur.name, initcap(v_code)),
          coalesce((select max(m.version) from public.market_profiles m where m.crop_id = v_crop and m.code = v_code), 0) + 1,
          coalesce(p->'params', cur.params, '[]'::jsonb),
          coalesce(array(select btrim(x) from jsonb_array_elements_text(p->'export_docs') x where btrim(x) <> ''), cur.export_docs, '{}'),
          coalesce(nullif(p->>'source_file_id', '')::uuid, cur.source_file_id), coalesce(nullif(btrim(p->>'source_note'), ''), cur.source_note),
          (select m.id from public.market_profiles m where m.crop_id = v_crop and m.code = v_code and m.status = 'active'), me)
  returning * into r;
  return r;
end $$;

-- Activate a draft: it needs its parameters and the source document it comes from (the FSSAI standard, the importer's
-- specification, the destination's rule). The version it replaces is retired, never deleted.
create or replace function app.activate_market_profile(p_id uuid) returns public.market_profiles
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); r public.market_profiles;
begin
  select * into r from public.market_profiles where id = p_id;
  if r.id is null then raise exception 'market profile not found' using errcode = 'P0002'; end if;
  if not app.manages_crop(r.crop_id) then raise exception 'the State Manager of the crop''s state keeps its market profiles' using errcode = '42501'; end if;
  if r.status <> 'draft' then raise exception 'only a draft is activated (this one is %)', r.status using errcode = '23514'; end if;
  if jsonb_array_length(r.params) = 0 then raise exception 'market profile: list the parameters it tests' using errcode = '23514'; end if;
  if r.source_file_id is null then raise exception 'market profile: attach the document the limits come from' using errcode = '23514'; end if;
  update public.market_profiles set status = 'retired' where crop_id = r.crop_id and code = r.code and status = 'active';
  update public.market_profiles set status = 'active', activated_at = now(), activated_by = me where id = r.id returning * into r;
  perform app.audit('market_profile_activated', r.id, jsonb_build_object('crop', r.crop_id, 'code', r.code, 'version', r.version,
    'source_sha256', (select f.sha256 from public.reference_files f where f.id = r.source_file_id)), false);
  return r;
end $$;

-- Every crop has two profiles carried over from its limits: Domestic and Export general (version 1, active, the source
-- being "the crop's limits"), so nothing that judges today changes. While the State Manager has not made a version of
-- his own, they follow the crop's limits; from his first version on, the profile is his.
create or replace function app.carried_profile_params(c public.crops, p_market text) returns jsonb
language sql stable as $$
  select coalesce((select jsonb_agg(case when q->>'type' in ('grade', 'yesno') then jsonb_build_object('param', q->>'param', 'pass', q->(p_market || '_pass'))
                                         else jsonb_build_object('param', q->>'param', 'operator', coalesce(q->>'operator', '<='), 'limit', q->(p_market || '_limit')) end)
                     from jsonb_array_elements(c.quality_params) q
                    where (coalesce(q->>'type', 'number') = 'number' and jsonb_typeof(q->(p_market || '_limit')) = 'number')
                       or (q->>'type' in ('grade', 'yesno') and q ? (p_market || '_pass'))), '[]'::jsonb) $$;
create or replace function app.carry_crop_profiles(p_crop uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c public.crops; m record;
begin
  select * into c from public.crops where id = p_crop;
  for m in select * from (values ('domestic', 'Domestic'), ('export', 'Export (general)')) as v(code, name) loop
    if not exists (select 1 from public.market_profiles x where x.crop_id = c.id and x.code = m.code) then
      insert into public.market_profiles (crop_id, code, name, version, status, params, export_docs, source_note, activated_at)
      values (c.id, m.code, m.name, 1, 'active', app.carried_profile_params(c, m.code), case when m.code = 'export' then c.export_docs else '{}' end,
              'Carried over from the crop''s limits', now());
    else
      update public.market_profiles x set params = app.carried_profile_params(c, m.code),
             export_docs = case when m.code = 'export' then c.export_docs else x.export_docs end
       where x.crop_id = c.id and x.code = m.code and x.version = 1 and x.status = 'active' and x.created_by is null and x.source_file_id is null
         and not exists (select 1 from public.market_profiles y where y.crop_id = c.id and y.code = m.code and y.version > 1);
    end if;
  end loop;
end $$;
create or replace function app.crops_carry_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
begin perform app.carry_crop_profiles(new.id); return new; end $$;
drop trigger if exists crops_z5_profiles on public.crops;
create trigger crops_z5_profiles after insert or update of quality_params, export_docs on public.crops
  for each row execute function app.crops_carry_profiles();
select app.carry_crop_profiles(id) from public.crops;
-- A crop removed by the admin (added by mistake, never used) takes its two carried profiles with it: they are the
-- crop's own limits, nothing anyone made (app.crop_in_use refuses the removal when there is more).
create or replace function app.crops_drop_carried() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.market_profiles where crop_id = old.id and created_by is null and source_file_id is null and version = 1;
  return old;
end $$;
drop trigger if exists crops_b0_carried on public.crops;
create trigger crops_b0_carried before delete on public.crops for each row execute function app.crops_drop_carried();

-- ---------------------------------------------------------------------------------------------------------------------
-- Crops: GI crop, GI blocks, shelf life per material, reference photo
-- ---------------------------------------------------------------------------------------------------------------------
-- A GI crop is one with a GI registration number (gi_tag); a crop without one has no GI checks at all.
alter table public.crops add column if not exists gi_crop boolean generated always as (gi_tag is not null and btrim(gi_tag) <> '') stored;
alter table public.crops add column if not exists gi_blocks text[] not null default '{}';
alter table public.crops add column if not exists shelf_life_by_material jsonb not null default '{}'::jsonb;
create or replace function app.shelf_life_ok(p jsonb) returns boolean language sql immutable as $$
  select jsonb_typeof(p) = 'object' and coalesce((select bool_and(k in ('pouch', 'jute', 'pp_bag', 'vacuum', 'carton', 'other')
           and jsonb_typeof(v) = 'number' and (v #>> '{}')::numeric between 1 and 3650) from jsonb_each(p) as e(k, v)), true) $$;
alter table public.crops add constraint crops_shelf_life_by_material_shape check (app.shelf_life_ok(shelf_life_by_material));
alter table public.crops add column if not exists reference_photo_id uuid references public.reference_files(id);
-- A non-GI crop has no GI checks at all: its lots are "not a GI crop", never "GI".
create or replace function app.crops_gi_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- (gi_crop is computed after this trigger: the GI number is read directly)
  -- asked when the GI number or the GI area is set or changed: a crop already there is not refused for another change
  if coalesce(btrim(new.gi_tag), '') = '' and (cardinality(new.gi_districts) > 0 or cardinality(new.gi_blocks) > 0)
     and (tg_op = 'INSERT' or new.gi_tag is distinct from old.gi_tag or new.gi_districts is distinct from old.gi_districts or new.gi_blocks is distinct from old.gi_blocks) then
    raise exception 'a crop that is not a GI crop (no GI registration number) has no GI area' using errcode = '23514'; end if;
  if new.reference_photo_id is not null and (tg_op = 'INSERT' or new.reference_photo_id is distinct from old.reference_photo_id)
     and not exists (select 1 from public.reference_files f where f.id = new.reference_photo_id and f.crop_id = new.id and f.kind = 'crop_photo') then
    raise exception 'the reference photo is a photo filed under this crop' using errcode = '23514'; end if;
  return new;
end $$;
drop trigger if exists crops_a1_gi on public.crops;
create trigger crops_a1_gi before insert or update on public.crops for each row execute function app.crops_gi_guard();

-- The best-before of a pack: its material's shelf life when the crop has one, else the crop's (release 53 uses it).
create or replace function app.shelf_life_for(p_crop uuid, p_material text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce((c.shelf_life_by_material->>p_material)::int, c.shelf_life_days) from public.crops c where c.id = p_crop $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Farmers: block, farm GPS, land record and GI authorised-user numbers
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.farmers add column if not exists block text;
alter table public.farmers add column if not exists farm_lat numeric(9,6);
alter table public.farmers add column if not exists farm_lng numeric(9,6);
alter table public.farmers add column if not exists land_record_no text;
alter table public.farmers add column if not exists gi_user_no text;
-- Farmers registered from now on need their farm's GPS and a district from the list before the Client Manager verifies
-- them; those already there are asked to add the GPS (Needs my action), nothing is refused for them.
alter table public.farmers add column if not exists location_required boolean;
update public.farmers set location_required = false where location_required is null;
alter table public.farmers alter column location_required set default true;
alter table public.farmers alter column location_required set not null;
alter table public.farmers add constraint farmers_gps_shape check (app.valid_gps(farm_lat, farm_lng) and ((farm_lat is null) = (farm_lng is null)));
alter table public.farmers add constraint farmers_block_shape check (block is null or length(btrim(block)) between 2 and 80);
alter table public.farmers add constraint farmers_land_record_shape check (land_record_no is null or length(btrim(land_record_no)) between 1 and 40);
alter table public.farmers add constraint farmers_gi_user_shape check (gi_user_no is null or length(btrim(gi_user_no)) between 2 and 40);

create or replace function app.farmers_location_rules() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_state uuid;
begin
  if auth.uid() is null then return new; end if;                          -- service role, seeds, migrations
  if tg_op = 'INSERT' then new.location_required := true; return new; end if;
  new.location_required := old.location_required;
  if old.status = 'draft' and new.status = 'under_review' and new.location_required then
    if new.farm_lat is null then
      raise exception 'add the farm''s GPS location before the farmer is verified' using errcode = '23514'; end if;
    v_state := coalesce(new.state_id, (select c.state_id from public.clients c where c.id = new.client_id));
    if v_state is not null and not app.district_listed(v_state, new.district) then
      raise exception 'the district % is not on the list of the farmer''s state: pick it from the list', new.district using errcode = '23514'; end if;
  end if;
  return new;
end $$;
drop trigger if exists farmers_z4_location on public.farmers;
create trigger farmers_z4_location before insert or update on public.farmers for each row execute function app.farmers_location_rules();

-- The farmer's GI area, per GI crop of his client's scopes: inside, outside (accepted with a warning, marked) or unknown.
create or replace function app.farmer_gi_area(p_farmer uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(distinct jsonb_build_object('crop_id', cr.id, 'crop', cr.name,
           'status', case when cardinality(cr.gi_districts) = 0 then 'unknown'
                          when app.norm_place(fm.district) in (select app.norm_place(x) from unnest(cr.gi_districts) x) then 'inside'
                          else 'outside' end)), '[]'::jsonb)
    from public.farmers fm join public.scopes s on s.client_id = fm.client_id join public.crops cr on cr.id = s.crop_id
   where fm.id = p_farmer and cr.gi_crop and app.farmer_read(fm.client_id, fm.state_id) $$;

-- The farm's GPS against the district's other farmers: more than 60 km from their middle point is shown to the State
-- Manager at his verification (the district's own boundary is not in the system; this is the check that is).
create or replace function app.farmer_gps_check(p_farmer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare fm public.farmers; v_lat numeric; v_lng numeric; n int; km numeric;
begin
  select * into fm from public.farmers where id = p_farmer;
  if fm.id is null or not app.farmer_read(fm.client_id, fm.state_id) then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  if fm.farm_lat is null then return jsonb_build_object('status', 'missing'); end if;
  select percentile_cont(0.5) within group (order by o.farm_lat), percentile_cont(0.5) within group (order by o.farm_lng), count(*)
    into v_lat, v_lng, n
    from public.farmers o
   where o.id <> fm.id and o.farm_lat is not null and coalesce(o.state_id, fm.state_id) is not distinct from fm.state_id
     and app.norm_place(o.district) = app.norm_place(fm.district) and o.status <> 'inactive';
  if n < 3 then return jsonb_build_object('status', 'not_enough', 'n', n); end if;
  km := round((6371 * 2 * asin(sqrt(power(sin(radians(fm.farm_lat - v_lat) / 2), 2)
               + cos(radians(v_lat)) * cos(radians(fm.farm_lat)) * power(sin(radians(fm.farm_lng - v_lng) / 2), 2))))::numeric, 1);
  return jsonb_build_object('status', case when km > 60 then 'far' else 'near' end, 'km', km, 'n', n);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- A14: the ledger banner: the last full check and the blocks added since
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.ledger_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.ledger_checks; v_now bigint;
begin
  if app.current_user_id() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into c from public.ledger_checks where source <> 'test' order by checked_at desc, id desc limit 1;
  select count(*) into v_now from public.ledger;
  return jsonb_build_object('checked_at', c.checked_at, 'ok', c.ok, 'blocks', c.blocks, 'source', c.source,
    'blocks_now', v_now, 'added_since', greatest(v_now - coalesce(c.blocks, 0), 0));
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- A15: people holding stages on more than one scope (the State Manager's overview counts them)
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.work_elsewhere(p_user uuid, p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('scope_id', s.id, 'label', s.season_code || ' · ' || s.geography, 'status', s.status,
           'client', c.name, 'stages', to_jsonb(a.stages)) order by s.season_code, s.geography), '[]'::jsonb)
    from public.assignments a join public.scopes s on s.id = a.scope_id join public.clients c on c.id = s.client_id
   where a.employee_id = p_user and a.active and a.lens = 'scope' and a.scope_id is distinct from p_scope
     and (a.ends_on is null or a.ends_on >= app.today()) and s.status in ('draft', 'active') and cardinality(a.stages) > 0 $$;

create or replace function app.multi_scope_people(p_state uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (app.is_admin() or p_state = any (app.my_state_ids())) then raise exception 'no access to this state' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'scopes', x.n) order by x.n desc, x.name)
    from (select u.id, u.display_name as name, count(distinct a.scope_id) as n
            from public.assignments a join public.scopes s on s.id = a.scope_id join public.app_users u on u.id = a.employee_id
           where a.active and a.lens = 'scope' and cardinality(a.stages) > 0 and s.state_id = p_state and s.status in ('draft', 'active')
             and (a.ends_on is null or a.ends_on >= app.today()) and not u.test_data
           group by u.id, u.display_name having count(distinct a.scope_id) > 1) x), '[]'::jsonb);
end $$;


-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen51.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- A15: the roster pool lists free people first, then those already on other scopes, with their current work

CREATE OR REPLACE FUNCTION app.roster_pool(p_scope uuid, p_q text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes; v_q text := nullif(lower(btrim(p_q)), '');
begin
  perform app.me_or_raise();
  select * into sc from public.scopes where id = p_scope;
  if sc.id is null or not app.runs_client(sc.client_id) then
    raise exception 'the Client Manager of this scope''s client chooses its people' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.display_name, 'status', u.status, 'district', o.base_district,
             'me', u.id = app.current_user_id(),
             'elsewhere', app.work_elsewhere(u.id, sc.id),                                       -- migration 51 (A15)
             'ready_for', rf.stage, 'ready_opening', rf.code,      -- migration 46: joined on an opening of this scope, not placed yet
             'stages', coalesce((select to_jsonb(a.stages) from public.assignments a
                                  where a.employee_id = u.id and a.active and a.lens = 'scope' and a.scope_id = sc.id), '[]'::jsonb))
           order by rf.stage is null, jsonb_array_length(app.work_elsewhere(u.id, sc.id)) > 0, u.id <> app.current_user_id(), u.display_name)
      from (select u.* from public.app_users u left join public.employee_org o2 on o2.employee_id = u.id
             where not u.external and not u.test_data and u.system_role = 'operational' and u.status in ('invited', 'onboarding', 'active')
               and (v_q is null or lower(u.display_name) like '%' || v_q || '%')
               and (o2.base_state_id = sc.state_id or app.client_account_holder(u.id, sc.client_id))
             order by u.display_name limit 200) u
      left join public.employee_org o on o.employee_id = u.id
      left join lateral (select op.stage, op.code from public.openings op
                          where op.id = o.opening_id and u.status = 'active' and op.status <> 'closed' and op.role = 'operator'
                            and op.state_id = sc.state_id and op.stage = any(sc.chain)
                            and (op.scope_id = sc.id or (op.scope_id is null and (op.client_id is null or op.client_id = sc.client_id)))
                            and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active and a.lens = 'scope'
                                              and a.scope_id = sc.id and op.stage = any(a.stages))) rf on true
     where app.stage_refusal(u.id, sc.id) is null), '[]'::jsonb);
end $function$;

-- Farmers: the new details are changed through the one door (with a reason once the farmer has an ID)

CREATE OR REPLACE FUNCTION app.change_farmer(p_farmer uuid, p jsonb, p_reason text)
 RETURNS farmers
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare r public.farmers;
begin
  if coalesce(btrim(p_reason), '') = '' then raise exception 'say why you change this farmer' using errcode = '23514'; end if;
  perform set_config('app.change_reason', btrim(p_reason), true);
  update public.farmers set
    name = coalesce(nullif(btrim(p->>'name'), ''), name),
    guardian_name = coalesce(nullif(btrim(p->>'guardian_name'), ''), guardian_name),
    village = coalesce(nullif(btrim(p->>'village'), ''), village),
    district = coalesce(nullif(btrim(p->>'district'), ''), district),
    block = case when p ? 'block' then nullif(btrim(p->>'block'), '') else block end,                       -- migration 51
    farm_lat = case when p ? 'farm_lat' then nullif(p->>'farm_lat', '')::numeric else farm_lat end,
    farm_lng = case when p ? 'farm_lng' then nullif(p->>'farm_lng', '')::numeric else farm_lng end,
    land_record_no = case when p ? 'land_record_no' then nullif(btrim(p->>'land_record_no'), '') else land_record_no end,
    gi_user_no = case when p ? 'gi_user_no' then nullif(btrim(p->>'gi_user_no'), '') else gi_user_no end,
    phone = coalesce(nullif(btrim(p->>'phone'), ''), phone),
    land_area_acres = coalesce(nullif(p->>'land_area_acres', '')::numeric, land_area_acres),
    gi_land_acres = case when p ? 'gi_land_acres' then nullif(p->>'gi_land_acres', '')::numeric else gi_land_acres end,
    photo_consent = coalesce((p->>'photo_consent')::boolean, photo_consent),
    public_id_consent = coalesce((p->>'public_id_consent')::boolean, public_id_consent),
    status = coalesce(nullif(p->>'status', '')::public.farmer_status, status),
    extra = case when p ? 'notes' then (case when nullif(btrim(p->>'notes'), '') is null then extra - 'notes'
                                              else extra || jsonb_build_object('notes', btrim(p->>'notes')) end) else extra end
   where id = p_farmer returning * into r;
  if r.id is null then raise exception 'farmer not found' using errcode = 'P0002'; end if;
  return r;
end $function$;

CREATE OR REPLACE FUNCTION app.farmers_change_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); staff boolean; cm boolean; step boolean; content boolean;
begin
  if auth.uid() is null then return new; end if;                         -- service role, seeds, migrations
  if tg_op = 'INSERT' then
    new.created_at := now();
    return new;
  end if;
  new.created_at := old.created_at;
  if new.client_id is distinct from old.client_id or new.created_by is distinct from old.created_by then
    raise exception 'a farmer''s client and creator cannot be changed' using errcode = '42501'; end if;
  staff := coalesce(app.farmer_staff(me, new.client_id, old.state_id), false);   -- migration 41: the farmer's state
  cm := coalesce(app.client_account_holder(me, new.client_id), false);          -- migration 44: and its Client Manager
  if not staff then
    if old.status <> 'draft' and not cm then
      raise exception 'this farmer has been submitted: only its Client Manager or the State Manager of its state can change it now' using errcode = '42501'; end if;
    if new.status is distinct from old.status and new.status not in ('draft', 'under_review') then
      raise exception 'a farmer is activated or deactivated by a State Manager' using errcode = '42501'; end if;
  end if;
  -- migration 44: once the client farmer ID is given, every change says why (the steps themselves do not)
  step := (old.status = 'draft' and new.status = 'under_review') or (old.status = 'under_review' and new.status = 'draft')
          or (old.status = 'under_review' and new.status = 'active' and old.verified_at is null);
  content := row(new.name, new.guardian_name, new.village, new.district, app.phone_key(new.phone), new.land_area_acres, new.gi_land_acres,
                 new.photo_consent, new.public_id_consent, new.extra->'notes', new.state_id,
                 new.block, new.farm_lat, new.farm_lng, new.land_record_no, new.gi_user_no)                        -- migration 51
             is distinct from
             row(old.name, old.guardian_name, old.village, old.district, app.phone_key(old.phone), old.land_area_acres, old.gi_land_acres,
                 old.photo_consent, old.public_id_consent, old.extra->'notes', old.state_id,
                 old.block, old.farm_lat, old.farm_lng, old.land_record_no, old.gi_user_no);
  if old.farmer_code is not null and (content or (new.status is distinct from old.status and not step))
     and coalesce(btrim(current_setting('app.change_reason', true)), '') = '' then
    raise exception 'this farmer has a Farmer ID: say why you change it' using errcode = '23514'; end if;
  if old.status <> 'active' and new.status = 'active' and old.verified_at is null then
    new.verified_at := now();                                            -- first verification: the server's clock
  else
    new.verified_at := old.verified_at;
    if not (old.status <> 'active' and new.status = 'active') then new.verified_by := old.verified_by; end if;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app.farmer_values(f farmers)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
  select jsonb_build_object('name', f.name, 'guardian_name', f.guardian_name, 'village', f.village, 'district', f.district,
    'phone', f.phone, 'land_area_acres', f.land_area_acres, 'gi_land_acres', f.gi_land_acres, 'notes', f.extra->>'notes',
    'block', f.block, 'farm_lat', f.farm_lat, 'farm_lng', f.farm_lng, 'land_record_no', f.land_record_no, 'gi_user_no', f.gi_user_no)   -- migration 51 $function$;

-- Needs my action: verified farmers of my clients without their farm's GPS (asked to add it)

CREATE OR REPLACE FUNCTION app.my_actions()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- migration 51 (Part B): farmers whose farm has no GPS yet, for their Client Manager
    'farmers_without_gps', (select count(*) from public.farmers fm where fm.status in ('under_review', 'active') and fm.farm_lat is null
                             and app.client_account_holder(me, fm.client_id)),
    -- requirement lines HR returned to me with a question
    'requirement_lines', (select count(*) from public.requirement_lines l join public.requirements q on q.id = l.requirement_id
                           where l.status = 'returned' and app.owns_requirement(q)),
    -- open flags and conditions on records of the scopes I manage
    'flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
               where fl.status = 'open' and fl.kind = 'flag' and app.manages_scope(me, f.scope_id)),
    'conditions', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                    where fl.status = 'open' and fl.kind = 'condition' and app.manages_scope(me, f.scope_id)),
    -- migration 49 (A7): milling runs of the last 60 days above their crop's ceiling, in the State Manager's states
    'outturn_review', (select count(*) from public.footprints f join public.scopes s on s.id = f.scope_id
                        where f.stage_type = 'milling' and f.status in ('pending', 'verified') and f.created_at > now() - interval '60 days'
                          and exists (select 1 from unnest(f.warnings) w where w like 'outturn % above the crop''s ceiling%')
                          and exists (select 1 from app.eff_assignments(me) a where a.lens = 'state' and a.state_id = s.state_id))
  );
end $function$;

-- A crop the State Manager filed documents or market profiles for is in use (the admin retires it, never removes it)

CREATE OR REPLACE FUNCTION app.crop_in_use(p_crop uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.scopes where crop_id = p_crop) or exists (select 1 from public.farmer_gap where crop_id = p_crop)
      or exists (select 1 from public.reference_files where crop_id = p_crop)                                   -- migration 51
      or exists (select 1 from public.market_profiles where crop_id = p_crop and (created_by is not null or source_file_id is not null)) $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- The API: every new function closed, then granted by name
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.up_districts() from public, anon, authenticated;
revoke execute on function app.seed_state_places(uuid) from public, anon, authenticated;
revoke execute on function app.states_seed_places() from public, anon, authenticated;
revoke execute on function app.district_listed(uuid, text) from public, anon, authenticated;
revoke execute on function app.add_place(uuid, text, text, text) from public, anon, authenticated;
revoke execute on function app.valid_gps(numeric, numeric) from public, anon, authenticated;
revoke execute on function app.sku_kg(public.pack_skus) from public, anon, authenticated;
revoke execute on function app.client_list_guard() from public, anon, authenticated;
revoke execute on function app.state_list_guard() from public, anon, authenticated;
revoke execute on function app.manages_crop(uuid) from public, anon, authenticated;
revoke execute on function app.register_reference_file(uuid, text, text, text, text) from public, anon, authenticated;
revoke execute on function app.profile_params_problems(jsonb) from public, anon, authenticated;
revoke execute on function app.save_market_profile(jsonb) from public, anon, authenticated;
revoke execute on function app.activate_market_profile(uuid) from public, anon, authenticated;
revoke execute on function app.shelf_life_ok(jsonb) from public, anon, authenticated;
revoke execute on function app.crops_gi_guard() from public, anon, authenticated;
revoke execute on function app.shelf_life_for(uuid, text) from public, anon, authenticated;
revoke execute on function app.farmers_location_rules() from public, anon, authenticated;
revoke execute on function app.farmer_gi_area(uuid) from public, anon, authenticated;
revoke execute on function app.farmer_gps_check(uuid) from public, anon, authenticated;
revoke execute on function app.ledger_status() from public, anon, authenticated;
revoke execute on function app.work_elsewhere(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.multi_scope_people(uuid) from public, anon, authenticated;
grant execute on function app.add_place(uuid, text, text, text) to authenticated;
grant execute on function app.register_reference_file(uuid, text, text, text, text) to authenticated;
grant execute on function app.save_market_profile(jsonb) to authenticated;
grant execute on function app.activate_market_profile(uuid) to authenticated;
grant execute on function app.farmer_gi_area(uuid) to authenticated;
grant execute on function app.farmer_gps_check(uuid) to authenticated;
grant execute on function app.ledger_status() to authenticated;
grant execute on function app.multi_scope_people(uuid) to authenticated;
-- used inside read and write rules and checks
grant execute on function app.valid_gps(numeric, numeric) to authenticated;
grant execute on function app.shelf_life_ok(jsonb) to authenticated;
grant execute on function app.manages_crop(uuid) to authenticated;
revoke execute on function app.carried_profile_params(public.crops, text) from public, anon, authenticated;
revoke execute on function app.carry_crop_profiles(uuid) from public, anon, authenticated;
revoke execute on function app.crops_carry_profiles() from public, anon, authenticated;
revoke execute on function app.crops_drop_carried() from public, anon, authenticated;
