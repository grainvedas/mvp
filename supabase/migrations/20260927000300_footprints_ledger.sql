-- GrainVeda MVP · Phase 0 · migration 3: footprints (the universal stage record), verdicts, seals, flags, ledger
-- Sacred stamps (PRD §5.6): scope_id, client_id, qty_in, qty_out, prev_footprint_id — NOT NULL and immutable.

create table public.footprints (
  id                  uuid primary key default gen_random_uuid(),
  footprint_code      text not null unique,             -- <CLIENT>-<CROP>-<SEASON>-<STAGE>-<SEQ>[-<GRADE>]
  client_id           uuid not null references public.clients(id),
  scope_id            uuid not null references public.scopes(id),
  stage_type          public.stage_type not null,
  prev_footprint_id   uuid references public.footprints(id),   -- null only for is_first stages
  farmer_id           uuid references public.farmers(id),      -- procurement only
  qty_in              numeric(12,3) not null check (qty_in  >= 0),
  qty_out             numeric(12,3) not null check (qty_out >= 0),
  status              public.footprint_status not null default 'pending',
  payload             jsonb not null default '{}'::jsonb,       -- stage-specific fields, validated per stage
  computed            jsonb not null default '{}'::jsonb,       -- derived numbers the trigger writes (water removed, spoilage…)
  warnings            text[] not null default '{}',             -- soft flags (yield, pop rate, variance)
  lot_closed          boolean not null default false,
  is_grade_lot        boolean not null default false,
  grade               text check (grade is null or grade in ('A','B','C')),
  split_into_grades   boolean not null default false,
  supersedes_id       uuid references public.footprints(id),
  created_by          uuid not null references public.app_users(id),
  verified_by         uuid references public.app_users(id),
  verified_at         timestamptz,
  created_at          timestamptz not null default now(),
  constraint footprints_grade_lot_shape check (
    (is_grade_lot = false and grade is null) or (is_grade_lot = true and grade is not null and stage_type = 'grading')
  ),
  constraint footprints_verified_shape check (
    status not in ('verified','closed') or (verified_by is not null and verified_at is not null)
  )
);

create index on public.footprints (scope_id, stage_type, status);
create index on public.footprints (prev_footprint_id);
create index on public.footprints (client_id);
create index on public.footprints (farmer_id);

create table public.qc_verdicts (
  footprint_id       uuid primary key references public.footprints(id),
  domestic_verdict   public.verdict not null default 'pending',
  export_verdict     public.verdict not null default 'pending',
  readings           jsonb not null default '{}'::jsonb,   -- {"moisture_pct": 12.1, ...}
  judged             jsonb not null default '[]'::jsonb,   -- per-param result the trigger writes
  -- Client-level override only. {"market":"export","reason":"...","authoriser":"<app_users.id>","at":"..."}
  override           jsonb,
  created_at         timestamptz not null default now()
);

create table public.qr_seals (
  footprint_id   uuid primary key references public.footprints(id),   -- the qr_activation footprint
  qr_code        text not null unique,
  batch_codes    text[] not null default '{}',
  sealed_by      uuid not null references public.app_users(id),
  sealed_at      timestamptz not null default now(),
  ledger_hash    text not null                                          -- hash of the seal block; shown on verify page
);

create table public.flags (
  id            uuid primary key default gen_random_uuid(),
  footprint_id  uuid not null references public.footprints(id),
  raised_by     uuid not null references public.app_users(id),
  text          text not null,
  status        public.flag_status not null default 'open',
  created_at    timestamptz not null default now()
);
create index on public.flags (footprint_id, status);

create table public.attachments (
  id            uuid primary key default gen_random_uuid(),
  footprint_id  uuid not null references public.footprints(id),
  kind          public.attachment_kind not null,
  storage_path  text not null,
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  uploaded_by   uuid not null references public.app_users(id),
  created_at    timestamptz not null default now()
);

-- Append-only, hash-chained. Written only by triggers. No role may UPDATE or DELETE (enforced twice: grants + trigger).
create table public.ledger (
  seq           bigserial primary key,
  footprint_id  uuid references public.footprints(id),
  scope_id      uuid references public.scopes(id),
  event         public.ledger_event not null,
  actor         uuid,                          -- app_users.id
  payload       jsonb not null,                -- snapshot that was hashed
  payload_hash  text not null,
  prev_hash     text not null,
  hash          text not null unique,
  created_at    timestamptz not null default now()
);
create index on public.ledger (footprint_id);
create index on public.ledger (scope_id);
