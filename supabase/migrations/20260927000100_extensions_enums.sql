-- GrainVeda MVP · Phase 0 · migration 1: extensions, schemas, enums
-- Source of truth: PRD §5 (domain model), §8 (data model). Run order matters.

create extension if not exists pgcrypto;   -- digest() for the ledger hash chain
create extension if not exists "uuid-ossp";

-- Application logic lives in schema `app`; tables live in `public` so PostgREST exposes them.
create schema if not exists app;
grant usage on schema app to authenticated, anon, service_role;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.user_role as enum (
  'admin',            -- GrainVeda platform owner
  'state_manager',    -- GrainVeda regional staff
  'client_manager',   -- GrainVeda employee assigned to one client
  'client_view',      -- client's own read-only login
  'operator'          -- stage operator; which stage(s) come from slot_assignments
);

create type public.client_type as enum ('exporter', 'fpo', 'brand', 'grainveda');

-- Every stage type the platform knows. One row per value in stage_definitions.
create type public.stage_type as enum (
  'procurement', 'lot_inward', 'village_batch',
  'milling', 'sorting', 'grading', 'drying', 'popping', 'cleaning', 'blanching',
  'cold_storage', 'packing',
  'qc', 'commercial', 'shipment', 'qr_activation'
);

create type public.scope_status     as enum ('draft', 'active', 'closed');
create type public.farmer_status    as enum ('draft', 'under_review', 'active', 'inactive');
create type public.footprint_status as enum ('pending', 'verified', 'closed', 'superseded', 'legacy');
create type public.verdict          as enum ('pass', 'fail', 'pending');
create type public.market           as enum ('domestic', 'export');
create type public.flag_status      as enum ('open', 'resolved', 'dismissed');
create type public.attachment_kind  as enum ('photo', 'document');
create type public.ledger_event     as enum (
  'create', 'verify', 'seal', 'override', 'supervisory', 'close', 'supersede', 'scope_activate'
);

-- Numeric tolerance for reconciliation equalities (kg). Scope-level tolerances override warnings, not this.
create or replace function app.kg_tolerance() returns numeric
language sql immutable as $$ select 0.01::numeric $$;
