-- GrainVeda MVP · migration 21: Phase 3 "field-ready" server pieces
--
-- 1. Nightly ledger check (PRD §9 tamper evidence, §12 edge check "nightly ledger check detects a manually altered
--    payload_hash"). app.run_ledger_check() runs app.verify_ledger() and records the result in public.ledger_checks.
--    It is scheduled with pg_cron at 02:00 IST when pg_cron is available (Supabase: yes; local Postgres: skipped with a
--    notice). The Edge Function `ledger-check` runs the same function on demand for an uptime monitor (HTTP 500 = alert).
-- 2. Offline capture (PRD §9): footprints.client_ref, a UUID the phone makes when the operator saves offline. A retried
--    sync of the same lot hits the unique index instead of creating a second lot.
-- 3. Lot trace for the ledger explorer and CSV/PDF export (F14): app.lot_trace(footprint) walks back to every origin
--    lot, including every source of a Village Batch, with who/when, QC, flags, evidence hashes and ledger blocks.
--    Managers and Client View only; never operators (they see one stage back, rule 9).

-- 1 · ledger checks -------------------------------------------------------------------------------------------------
create table public.ledger_checks (
  id             bigserial primary key,
  checked_at     timestamptz not null default now(),
  source         text not null default 'manual' check (source in ('nightly', 'manual', 'monitor', 'test')),
  blocks         bigint not null,
  ok             boolean not null,
  first_bad_seq  bigint,
  problem        text
);
alter table public.ledger_checks enable row level security;
create policy ledger_checks_read on public.ledger_checks for select to authenticated
  using (app.current_role() in ('admin', 'state_manager', 'client_manager'));
revoke insert, update, delete, truncate on public.ledger_checks from anon, authenticated;
grant select on public.ledger_checks to authenticated;

create or replace function app.run_ledger_check(p_source text default 'manual') returns public.ledger_checks
language plpgsql volatile security definer set search_path = public as $$
declare bad record; r public.ledger_checks;
begin
  select * into bad from app.verify_ledger() limit 1;
  insert into public.ledger_checks (source, blocks, ok, first_bad_seq, problem)
  values (p_source, (select count(*) from public.ledger), bad.seq is null, bad.seq, bad.problem)
  returning * into r;
  if bad.seq is not null then
    raise warning 'LEDGER CHECK FAILED at block %: %', bad.seq, bad.problem;   -- lands in the Postgres log
  end if;
  return r;
end $$;
revoke execute on function app.run_ledger_check(text) from public, anon, authenticated;
grant execute on function app.run_ledger_check(text) to service_role;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('grainveda-ledger-nightly', '30 20 * * *', $c$select app.run_ledger_check('nightly')$c$);  -- 02:00 IST
  else
    raise notice 'pg_cron not available: nightly ledger check not scheduled (use the ledger-check Edge Function)';
  end if;
exception when others then
  raise notice 'nightly ledger check not scheduled: %', sqlerrm;
end $$;

-- 2 · offline capture -----------------------------------------------------------------------------------------------
alter table public.footprints add column client_ref uuid;
create unique index footprints_client_ref_key on public.footprints (client_ref) where client_ref is not null;
comment on column public.footprints.client_ref is
  'UUID made on the phone for a save queued offline; makes a retried sync idempotent. Not part of the hashed snapshot.';

-- 3 · lot trace -----------------------------------------------------------------------------------------------------
create or replace function app.lot_trace(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_scope uuid; v_role public.user_role; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  v_role := app.current_role();
  if v_scope is null or v_role is null or v_role = 'operator' or not app.can_access_scope(v_scope) then
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
           'payload', f.payload, 'computed', f.computed, 'warnings', to_jsonb(f.warnings),
           'farmer', case when fa.id is null then null else jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village) end,
           'created_at', f.created_at, 'created_by', cu.display_name,
           'verified_at', f.verified_at, 'verified_by', vu.display_name,
           'qc', (select jsonb_build_object('domestic', q.domestic_verdict, 'export', q.export_verdict, 'readings', q.readings, 'override', q.override)
                    from public.qc_verdicts q where q.footprint_id = f.id),
           'seal', (select jsonb_build_object('qr_code', s.qr_code, 'sealed_at', s.sealed_at, 'ledger_hash', s.ledger_hash, 'batch_codes', to_jsonb(s.batch_codes))
                      from public.qr_seals s where s.footprint_id = f.id),
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

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb));
end $$;
revoke execute on function app.lot_trace(uuid) from public, anon, authenticated;
grant execute on function app.lot_trace(uuid) to authenticated;

notify pgrst, 'reload schema';
