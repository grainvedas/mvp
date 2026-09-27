-- GrainVeda MVP · Phase 0 · migration 2: core tables (PRD §8 "Core entities")
-- Tenant boundary: clients. Operational boundary: scopes. Everything is addressed client → scope → stage.

create table public.states (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code        text not null unique check (code ~ '^[A-Z]{2,4}$'),
  created_at  timestamptz not null default now()
);

create table public.crops (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  code            text not null unique check (code ~ '^[A-Z]{2,5}$'),
  gi_tag          text,
  origin          text,
  primary_unit    text not null default 'kg',
  -- Structured quality limits. No free text. Each element:
  -- {"param":"moisture_pct","label":"Moisture","unit":"%","operator":"<=","domestic_limit":13,"export_limit":12}
  -- operator ∈ '<=', '>=', 'between' (limits are [lo,hi] arrays for 'between')
  quality_params  jsonb not null default '[]'::jsonb,
  -- Processing stages valid for this crop. Entry stages, qc, commercial, shipment, qr are always allowed.
  allowed_stages  public.stage_type[] not null default '{}',
  created_at      timestamptz not null default now(),
  constraint crops_quality_params_is_array check (jsonb_typeof(quality_params) = 'array')
);

create table public.clients (
  id          uuid primary key default gen_random_uuid(),
  state_id    uuid not null references public.states(id),
  name        text not null,
  code        text not null unique check (code ~ '^[A-Z0-9]{2,6}$'),
  type        public.client_type not null,
  created_at  timestamptz not null default now()
);

-- One row per stage type: the single stage registry (replaces ALL_STAGES + STAGE_REGISTRY + PROCESSING_STAGE_CONFIGS).
create table public.stage_definitions (
  stage_type          public.stage_type primary key,
  code                text not null unique,               -- short code used in footprint_code
  label               text not null,
  is_first            boolean not null default false,     -- skips steps 2–3 (no predecessor)
  is_gate             boolean not null default false,     -- QR: steps 2–3 become whole-chain re-walk, 7 seals
  splits_forward      boolean not null default false,     -- one source → many records
  aggregates          boolean not null default false,     -- many sources → one record
  allows_exceed_input boolean not null default false,     -- blanching only
  yield_alarm         boolean not null default false,     -- generic yield < threshold warning applies
  is_processing       boolean not null default false,     -- crop.allowed_stages governs it
  form_schema         jsonb not null default '[]'::jsonb, -- rendered by the generic 8-step component
  handoff_checks      jsonb not null default '[]'::jsonb, -- tick-list written at step 8, read at next step 3
  sort_order          int  not null default 0
);

create table public.scopes (
  id            uuid primary key default gen_random_uuid(),
  client_id     uuid not null references public.clients(id),
  crop_id       uuid not null references public.crops(id),
  season_code   text not null check (season_code ~ '^[A-Z]{2}[0-9]{2}$'),  -- e.g. KH26
  geography     text not null,
  chain         public.stage_type[] not null default '{}',   -- ordered; frozen at activation (decision D1)
  status        public.scope_status not null default 'draft',
  -- Scope-level tolerances that drive warnings (not hard rejections)
  tolerances    jsonb not null default '{"yield_warn_pct":70,"pop_rate_min_pct":80,"lot_inward_variance_pct":2,"auto_close_kg":2}'::jsonb,
  activated_at  timestamptz,
  created_at    timestamptz not null default now(),
  unique (client_id, crop_id, season_code, geography)
);

create table public.app_users (
  id            uuid primary key default gen_random_uuid(),
  auth_uid      uuid unique,                      -- auth.users.id in Supabase; null until the login is provisioned
  role          public.user_role not null,
  display_name  text not null,
  phone         text,
  email         text,
  state_ids     uuid[] not null default '{}',     -- state_manager only
  client_id     uuid references public.clients(id), -- client_manager, client_view, operator
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint app_users_client_required check (
    role in ('admin','state_manager') or client_id is not null
  )
);

-- Many slots per user; a user may hold slots in several scopes (replaces single-slot .find model).
create table public.slot_assignments (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.app_users(id) on delete cascade,
  scope_id    uuid not null references public.scopes(id) on delete cascade,
  stage_type  public.stage_type not null,
  created_at  timestamptz not null default now(),
  unique (user_id, scope_id, stage_type)
);

create table public.farmers (
  id             uuid primary key default gen_random_uuid(),
  farmer_code    text unique,                       -- issued only on State Manager verification
  client_id      uuid not null references public.clients(id),
  scope_ids      uuid[] not null default '{}',
  status         public.farmer_status not null default 'draft',
  -- six required fields
  name           text not null,
  guardian_name  text not null,
  village        text not null,
  district       text not null,
  phone          text not null,
  land_area_acres numeric(8,2) not null check (land_area_acres >= 0),
  -- optional block
  extra          jsonb not null default '{}'::jsonb,
  photo_consent  boolean not null default false,
  created_by     uuid references public.app_users(id),
  verified_by    uuid references public.app_users(id),
  verified_at    timestamptz,
  created_at     timestamptz not null default now(),
  constraint farmers_active_has_code check (status <> 'active' or farmer_code is not null)
);

-- Sequence for footprint codes, per client-crop-season series and stage (two geographies in one season share a series,
-- so codes stay unique across scopes).
create table public.footprint_counters (
  series      text not null,                 -- '<CLIENT>-<CROP>-<SEASON>'
  stage_type  public.stage_type not null,
  last_seq    int not null default 0,
  primary key (series, stage_type)
);

create index on public.clients (state_id);
create index on public.scopes (client_id);
create index on public.slot_assignments (scope_id, stage_type);
create index on public.slot_assignments (user_id);
create index on public.farmers (client_id, status);
