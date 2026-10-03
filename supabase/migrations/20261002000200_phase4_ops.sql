-- GrainVeda MVP · migration 23: Phase 4 "live season" server pieces
--
-- 1. Login linking hardened. Migration 9 links a CONFIRMED login to the user row with the same phone or email. On a
--    project where public sign-up is open and e-mail auto-confirm is on, a visitor who signs up with the e-mail of a
--    user row that has no login (not yet, or no longer) became that user: reproduced on the local stack, as "admin".
--    Now only a login created by the service role (it carries app_metadata.grainveda_login = true, which a person
--    signing up cannot set) can claim a row. The Auth setting "allow new users to sign up" must still be OFF in
--    production (tests/remote_auth_settings.mjs checks it); this is the second lock.
--    Body re-created MECHANICALLY from migration 9 (script) with one condition added.
-- 2. app.environment(): 'production' on the production project, 'staging' anywhere else. Demo seeds and the scripts
--    that create demo data refuse to run on production; the app shows a "practice system" strip elsewhere.
-- 3. public.client_errors + app.report_client_error(): errors that happen on operators' phones reach the admin
--    (PRD §9 observability "error tracking") without a third-party service. Rate-limited, trimmed, 90 days kept.
-- 4. app.lot_markets(lot): which markets a lot may be sold to, for the Commercial screen (PRD §12 T3 "domestic-only lot
--    is hidden from export sale"). An operator cannot walk back to the QC record himself (thumb rule), so the server
--    answers for a lot he can see.
-- 5. app.scope_activity(scope, days): saves, verifications, seals and supervisory acts per day, from the ledger
--    (PRD §9 "per-scope activity metrics").
-- 6. app.reset_login_allowed(user): may the caller reset this user's password? Decided by a real, no-op UPDATE of the
--    row as the caller, so the users_update policy and the app_users guard (migration 10) are the one rule.
-- 7. app.lot_trace(): each step now also says whether it was withdrawn, and which withdrawn record it replaces.
--    Body re-created MECHANICALLY from migration 21 (script) with two keys added.
-- 8. app.check_ledger_now(): the admin or a State Manager runs the ledger check from the Health page (the nightly job
--    and the uptime monitor keep using app.run_ledger_check, service role only). At most one chain walk a minute.

-- 1 · login linking --------------------------------------------------------------------------------------------------
create or replace function app.link_login() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_phone text; v_email text; v_rows uuid[];
begin
  begin
    v_phone := case when new.phone_confirmed_at is not null then app.phone_key(new.phone) end;
    v_email := case when new.email_confirmed_at is not null then app.email_key(new.email) end;
    if v_phone is null and v_email is null then return null; end if;
    -- migration 23: only a login made by the service role (create-user, reset, bootstrap, demo script) can claim a row.
    -- app_metadata is never writable by the person signing up, so a public sign-up can no longer become a user.
    if coalesce(new.raw_app_meta_data->>'grainveda_login', '') <> 'true' then return null; end if;
    if exists (select 1 from public.app_users where auth_uid = new.id) then return null; end if;   -- one login, one row

    select array_agg(u.id) into v_rows
      from public.app_users u
     where u.active
       and ((v_phone is not null and app.phone_key(u.phone) = v_phone)
         or (v_email is not null and app.email_key(u.email) = v_email))
       and (u.auth_uid is null or u.auth_uid = u.id
            or not exists (select 1 from auth.users a where a.id = u.auth_uid));

    if cardinality(v_rows) = 1 then
      -- re-checked under the row lock, so two logins confirming at once cannot both take the row
      update public.app_users u set auth_uid = new.id
       where u.id = v_rows[1]
         and (u.auth_uid is null or u.auth_uid = u.id
              or not exists (select 1 from auth.users a where a.id = u.auth_uid));
    elsif cardinality(v_rows) > 1 then
      raise warning 'login % matches % app users by phone/email; not linked', new.id, cardinality(v_rows);
    end if;
  exception when others then
    raise warning 'login linking failed for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;

-- 2 · environment ----------------------------------------------------------------------------------------------------
create table public.app_meta (
  key    text primary key,
  value  text not null
);
alter table public.app_meta enable row level security;                -- no policies: read through app.environment() only
revoke all on public.app_meta from anon, authenticated;

create or replace function app.environment() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select value from public.app_meta where key = 'environment'), 'staging')
$$;

-- 3 · field error log ------------------------------------------------------------------------------------------------
create table public.client_errors (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  user_id  uuid references public.app_users(id),
  role     public.user_role,
  kind     text not null check (kind in ('error', 'rejection', 'boundary', 'sync_refused')),
  message  text not null,
  detail   text,
  path     text,
  build    text,
  online   boolean,
  agent    text
);
create index client_errors_at on public.client_errors (at desc);
alter table public.client_errors enable row level security;
create policy client_errors_read on public.client_errors for select to authenticated
  using (app.current_role() in ('admin', 'state_manager'));
revoke all on public.client_errors from anon, authenticated;
grant select on public.client_errors to authenticated;

create or replace function app.report_client_error(
  p_kind text, p_message text, p_detail text default null, p_path text default null,
  p_build text default null, p_online boolean default null, p_agent text default null
) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := app.current_user_id();
begin
  if me is null or coalesce(btrim(p_message), '') = '' then return false; end if;
  if (select count(*) from public.client_errors e where e.user_id = me and e.at > now() - interval '1 hour') >= 30 then
    return false;                                                       -- a looping screen must not fill the table
  end if;
  delete from public.client_errors where at < now() - interval '90 days';
  insert into public.client_errors (user_id, role, kind, message, detail, path, build, online, agent)
  values (me, app.current_role(),
          case when p_kind in ('error', 'rejection', 'boundary', 'sync_refused') then p_kind else 'error' end,
          left(p_message, 500), left(p_detail, 2000), left(split_part(coalesce(p_path, ''), '?', 1), 200),
          left(p_build, 40), p_online, left(p_agent, 300));
  return true;
end $$;

-- 4 · markets a lot may be sold to ------------------------------------------------------------------------------------
create or replace function app.lot_markets(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; vd record; ok_export boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  ok_export := app.export_allowed(f.id);
  return jsonb_build_object(
    'has_qc', vd.qc_footprint_id is not null, 'domestic', vd.domestic, 'export', vd.export,
    'overridden', vd.override is not null, 'export_allowed', ok_export,
    'markets', to_jsonb(case when ok_export then array['domestic', 'export'] else array['domestic'] end));
end $$;

-- 5 · activity per day (IST days: the field's calendar) ---------------------------------------------------------------
create or replace function app.scope_activity(p_scope uuid, p_days int default 14)
returns table (day date, saved bigint, verified bigint, sealed bigint, supervisory bigint)
language sql stable security invoker set search_path = public as $$
  select (l.created_at at time zone 'Asia/Kolkata')::date,
         count(*) filter (where l.event = 'create'),
         count(*) filter (where l.event = 'verify'),
         count(*) filter (where l.event = 'seal'),
         count(*) filter (where l.event in ('supervisory', 'override', 'supersede'))
    from public.ledger l
   where l.scope_id = p_scope and l.created_at >= now() - make_interval(days => least(greatest(coalesce(p_days, 14), 1), 90))
   group by 1 order by 1 desc
$$;

-- 6 · password reset permission ----------------------------------------------------------------------------------------
create or replace function app.reset_login_allowed(p_target uuid) returns boolean
language plpgsql volatile security invoker set search_path = public as $$
begin
  if p_target is null or p_target = app.current_user_id() then return false; end if;   -- your own: change it yourself
  update public.app_users set display_name = display_name where id = p_target;
  return found;
exception when insufficient_privilege then
  return false;
end $$;

-- 7 · lot trace --------------------------------------------------------------------------------------------------------
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

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb));
end $$;

-- 8 · ledger check on demand -------------------------------------------------------------------------------------------
create or replace function app.check_ledger_now() returns public.ledger_checks
language plpgsql volatile security definer set search_path = public as $$
declare r public.ledger_checks;
begin
  if coalesce(app.current_role() in ('admin', 'state_manager'), false) is not true then
    raise exception 'only the admin or a State Manager may run the ledger check' using errcode = '42501';
  end if;
  select * into r from public.ledger_checks where checked_at > now() - interval '60 seconds' order by checked_at desc limit 1;
  if r.id is not null then return r; end if;                 -- a full walk of the chain: at most once a minute
  return app.run_ledger_check('manual');
end $$;

-- API surface (migration 14 rule)
revoke execute on function app.environment(), app.lot_markets(uuid), app.scope_activity(uuid, int), app.reset_login_allowed(uuid),
  app.report_client_error(text, text, text, text, text, boolean, text), app.check_ledger_now()
  from public, anon, authenticated;
grant execute on function app.environment() to anon, authenticated;
grant execute on function app.lot_markets(uuid), app.scope_activity(uuid, int), app.reset_login_allowed(uuid),
  app.report_client_error(text, text, text, text, text, boolean, text), app.check_ledger_now() to authenticated;
notify pgrst, 'reload schema';
