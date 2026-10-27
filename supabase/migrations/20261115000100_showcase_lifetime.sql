-- Migration 72 (Phase 3, release 5 of Veda's combined brief of 19 Oct 2026: Part E3, Part F and A4; FIX_LIST item 71).
-- Veda, 27 Oct 2026: "proceed" (the defaults sent that day).
--
--   E3  The showcase page, Basic, at /verified/<client code>: the client's name; its verified states with their crops and
--       seasons and the headline figures (tonnes traced: the verified kilograms bought from farmers; villages; the
--       GI-area share: the kilograms of GI area and farm-verified; the lab pass rate: the QC records that passed at least
--       one market); "Verify any pack"; the active recall notices; a sourcing partner only where it agreed to be named.
--       Never a price, a farmer's name or phone, a buyer's name. Nothing is public until the client's owner approves it
--       (an own-brand client, which has no owner, by the admin); the owner (or, for an own-brand client, the admin)
--       unpublishes it with a reason, also while the client is suspended. Its words never look active when the client is
--       not: per state "Verification paused" / "Verification ended on …"; the banner says so when no state is Active.
--       An own-brand client's page and badge say "Operated by GrainVeda (own brand)". The badge (the host's /api/badge)
--       reads app.showcase_badge.
--   F   How long things stay live: the verify page of an output (an evidence pack, a season report) of a client whose
--       contract ended in its state says only that verification ended, once the longer of best-before + 12 months and 24
--       months after the end has passed (the pack and lot pages do so since migration 65). The showcase likewise.
--   A4  An ended client's accounts read and export for as long as its pages stay live (the longer of the two, over all
--       its states and packs); then they open nothing: enforced by the rules themselves (app.client_accounts_closed in
--       app.my_client_account, app.account_reaches, app.account_states, app.account_sees_farmer,
--       app.client_operator_for), and recorded by the daily round app.client_lifetime_round (the accounts marked removed
--       with the reason, in the Audit log), which tells the owners 30 days before (a notification). The periods are 24
--       and 12 months; a practice system may shorten them for a test (app.lifetime_months).
-- Additive: one new table (public.client_showcases), new functions, a wider list of notification kinds; replaced from
-- their own text, each change named: the five account rules above and app.public_document.
select set_config('app.change_path', 'migration 72', true);

-- 1 · the showcase's approval -----------------------------------------------------------------------------------------------
create table if not exists public.client_showcases (
  client_id uuid primary key references public.clients(id),
  status text not null check (status in ('published', 'unpublished')),
  published_by uuid references public.app_users(id), published_at timestamptz,
  unpublished_by uuid references public.app_users(id), unpublished_at timestamptz, unpublish_reason text,
  check (status <> 'published' or (published_at is not null and published_by is not null)),
  check (status <> 'unpublished' or (unpublished_at is not null and unpublish_reason is not null)));
alter table public.client_showcases enable row level security;
revoke all on public.client_showcases from anon, authenticated;
create or replace function app.client_showcases_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception 'a showcase''s approval is kept: unpublish it' using errcode = '42501'; end if;
  return new;
end $$;
drop trigger if exists client_showcases_a0_guard on public.client_showcases;
create trigger client_showcases_a0_guard before delete on public.client_showcases for each row execute function app.client_showcases_guard();
drop trigger if exists zz_change_log on public.client_showcases;
create trigger zz_change_log after insert or update or delete on public.client_showcases for each row execute function app.log_change('client_id');
comment on table public.client_showcases is 'Migration 72 (E3): a client''s showcase page, approved by its owner (an own-brand client: the admin); no row: never approved.';

-- 2 · how long things stay live (F, A4) ---------------------------------------------------------------------------------------
-- the periods: 24 months after the contract's end, 12 months after best-before. A practice system may shorten them for a
-- test (the session's app.lifetime_months_after_end / app.lifetime_months_after_best_before); production never.
create or replace function app.lifetime_months(p_after text) returns int
language sql stable security definer set search_path = public as $$
  select case when app.environment() = 'production' then null
              else nullif(current_setting(case p_after when 'end' then 'app.lifetime_months_after_end' else 'app.lifetime_months_after_best_before' end, true), '')::int end
$$;
create or replace function app.months_after(p_after text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(app.lifetime_months(p_after), case p_after when 'end' then 24 else 12 end)
$$;

-- a client's pages and accounts live until: null while a state of it is not ended; else the longer of 24 months after its
-- last end and 12 months after its packs' last best-before
create or replace function app.client_live_until(p_client uuid) returns date
language sql stable security definer set search_path = public as $$
  select case when not exists (select 1 from public.client_states cs where cs.client_id = p_client)
                or exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.status <> 'ended') then null
              else greatest(
                (select (max(coalesce(cs.ended_on, app.today())) + make_interval(months => app.months_after('end')))::date
                   from public.client_states cs where cs.client_id = p_client),
                coalesce((select (max(p.best_before) + make_interval(months => app.months_after('best_before')))::date
                            from public.packs p join public.footprints f on f.id = p.footprint_id
                           where f.client_id = p_client and p.status <> 'void'), '-infinity'::date)) end
$$;
-- have its accounts closed? cheap for a client still in contract (the first test), and for the first months after the end
create or replace function app.client_accounts_closed(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.client_states cs where cs.client_id = p_client)
     and not exists (select 1 from public.client_states cs where cs.client_id = p_client and cs.status <> 'ended')
     and app.today() > (select (max(coalesce(cs.ended_on, app.today())) + make_interval(months => app.months_after('end')))::date
                          from public.client_states cs where cs.client_id = p_client)
     and app.today() > coalesce(app.client_live_until(p_client), 'infinity'::date)
$$;

-- an output's verify page (F): the scope's state ended, and the longer of the two periods (its packs' best-before) passed
create or replace function app.output_expired(r public.reports) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare cs public.client_states; v_until date;
begin
  cs := app.client_status_of_scope(r.scope_id);
  if cs.status is distinct from 'ended' then return false; end if;
  v_until := greatest((coalesce(cs.ended_on, app.today()) + make_interval(months => app.months_after('end')))::date,
                      coalesce((select (max(p.best_before) + make_interval(months => app.months_after('best_before')))::date
                                  from public.packs p join public.footprints f on f.id = p.footprint_id
                                 where f.scope_id = any (coalesce(r.scope_ids, array[r.scope_id])) and p.status <> 'void'), '-infinity'::date));
  return app.today() > v_until;
end $$;

-- 3 · the showcase's content (E3) -----------------------------------------------------------------------------------------
-- verification as a client: per state; the banner: Active where one state is, paused where none is but one is suspended,
-- else ended on the last end
create or replace function app.client_verification_all(p_client uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'status', case when bool_or(cs.status = 'active') then 'active' when bool_or(cs.status = 'suspended') then 'paused' else 'ended' end,
    'ended_on', case when bool_and(cs.status = 'ended') then max(coalesce(cs.ended_on, app.today())) end)
    from public.client_states cs where cs.client_id = p_client and cs.status in ('active', 'suspended', 'ended')
$$;

create or replace function app.showcase_data(p_client uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (select cl.id, cl.code, cl.name, coalesce(e.own_brand, false) as own_brand
               from public.clients cl left join public.entities e on e.id = cl.entity_id where cl.id = p_client),
  st as (select cs.state_id, cs.status, cs.ended_on, s2.name as state from public.client_states cs join public.states s2 on s2.id = cs.state_id
          where cs.client_id = p_client and cs.status in ('active', 'suspended', 'ended')),
  sc as (select s.id, s.state_id, s.season_code, cr.name as crop, cr.gi_tag from public.scopes s join public.crops cr on cr.id = s.crop_id
          where s.client_id = p_client and s.status in ('active', 'closed') and s.state_id in (select state_id from st)),
  buy as (select f.scope_id, f.id, coalesce(f.qty_out, 0) as kg, f.farm_verified, app.entry_gi(f.id) as gi, fm.village, fm.district
            from public.footprints f left join public.farmers fm on fm.id = f.farmer_id
           where f.scope_id in (select id from sc) and f.stage_type in ('procurement', 'lot_inward') and f.status = 'verified'),
  lab as (select f.scope_id, (v.domestic_verdict = 'pass' or v.export_verdict = 'pass') as passed,
                 (v.domestic_verdict <> 'pending' or v.export_verdict <> 'pending') as decided
            from public.footprints f join public.qc_verdicts v on v.footprint_id = f.id
           where f.scope_id in (select id from sc) and f.stage_type = 'qc' and f.status = 'verified'),
  fig as (select sc.state_id, sc.crop, sc.season_code, max(sc.gi_tag) as gi_tag,
                 round(coalesce((select sum(b.kg) from buy b where b.scope_id = any (array_agg(sc.id))), 0) / 1000, 2) as tonnes,
                 (select count(distinct (b.village, b.district)) from buy b where b.scope_id = any (array_agg(sc.id)) and b.village is not null) as villages,
                 (select round(100.0 * coalesce(sum(b.kg) filter (where b.gi = 'gi' and b.farm_verified), 0) / nullif(sum(b.kg), 0), 1)
                    from buy b where b.scope_id = any (array_agg(sc.id))) as gi_pct,
                 (select round(100.0 * count(*) filter (where l.passed) / nullif(count(*) filter (where l.decided), 0), 1)
                    from lab l where l.scope_id = any (array_agg(sc.id))) as lab_pass_pct
            from sc group by sc.state_id, sc.crop, sc.season_code)
  select jsonb_build_object(
    'code', c.code, 'name', c.name, 'own_brand', c.own_brand,
    'verification', app.client_verification_all(p_client),
    'totals', jsonb_build_object(
      'tonnes', round(coalesce((select sum(kg) from buy), 0) / 1000, 2),
      'villages', (select count(distinct (village, district)) from buy where village is not null),
      'gi_pct', (select round(100.0 * coalesce(sum(kg) filter (where gi = 'gi' and farm_verified), 0) / nullif(sum(kg), 0), 1) from buy),
      'lab_pass_pct', (select round(100.0 * count(*) filter (where passed) / nullif(count(*) filter (where decided), 0), 1) from lab),
      'states', (select count(*) from st), 'crops', (select count(distinct crop) from sc)),
    'states', coalesce((select jsonb_agg(jsonb_build_object('state', st.state,
                 'status', case st.status when 'active' then 'active' when 'suspended' then 'paused' else 'ended' end,
                 'ended_on', case when st.status = 'ended' then st.ended_on end,
                 'crops', coalesce((select jsonb_agg(jsonb_build_object('crop', f.crop, 'gi_tag', f.gi_tag, 'season', f.season_code,
                              'tonnes', f.tonnes, 'villages', f.villages, 'gi_pct', f.gi_pct, 'lab_pass_pct', f.lab_pass_pct)
                              order by f.crop, f.season_code) from fig f where f.state_id = st.state_id), '[]'::jsonb))
                 order by st.state) from st), '[]'::jsonb),
    'recalls', coalesce((select jsonb_agg(jsonb_build_object('qr_code', q.qr_code, 'crop', cr.name, 'season', s.season_code,
                 'at', (app.release_status(q.footprint_id)->>'at')::timestamptz, 'reason', app.release_status(q.footprint_id)->>'reason')
                 order by (app.release_status(q.footprint_id)->>'at') desc)
                 from public.qr_seals q join public.footprints f on f.id = q.footprint_id join public.scopes s on s.id = f.scope_id
                 join public.crops cr on cr.id = s.crop_id
                where f.client_id = p_client and app.release_status(q.footprint_id)->>'status' = 'recalled'), '[]'::jsonb),
    'partners', coalesce((select jsonb_agg(distinct coalesce(e.trade_name, e.legal_name))
                 from public.scope_partners sp join public.entities e on e.id = sp.entity_id
                where sp.scope_id in (select id from sc) and sp.named_publicly and sp.removed_at is null), '[]'::jsonb))
    from c
$$;

-- 4 · the public page and the badge --------------------------------------------------------------------------------------
-- the page: nothing unless the owner approved it; after the lifetime period only that verification ended
create or replace function app.public_showcase(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clients; v_own boolean; v jsonb;
begin
  select * into c from public.clients where code = upper(btrim(coalesce(p_code, '')));
  if c.id is null or not exists (select 1 from public.client_showcases x where x.client_id = c.id and x.status = 'published') then return null; end if;
  v_own := coalesce((select e.own_brand from public.entities e where e.id = c.entity_id), false);
  if coalesce(app.today() > app.client_live_until(c.id), false) then
    return jsonb_build_object('code', c.code, 'name', c.name, 'own_brand', v_own, 'expired', true,
      'verification', app.client_verification_all(c.id));
  end if;
  return app.showcase_data(c.id) || jsonb_build_object('expired', false);
end $$;

-- the badge's words: what the page would say, or that there is no page
create or replace function app.showcase_badge(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('code', p->>'code', 'name', p->>'name', 'own_brand', (p->>'own_brand')::boolean,
                     'status', p->'verification'->>'status', 'ended_on', p->'verification'->>'ended_on')
                     from (select app.public_showcase(p_code) as p) x where p is not null),
                  jsonb_build_object('status', 'none'))
$$;

-- 5 · approving and unpublishing ------------------------------------------------------------------------------------------
-- who: the client's owner, while the client is Active in a state (A4: an owner's acts pause while it is suspended); an
-- own-brand client (no owner) the admin. Unpublishing: the owner at any time (like revoking a buyer link), or the admin
-- for an own-brand client
create or replace function app.client_own_brand(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select e.own_brand from public.clients c join public.entities e on e.id = c.entity_id where c.id = p_client), false)
$$;
create or replace function app.may_publish_showcase(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and app.client_was_activated(p_client)
     and ((app.client_owner_check(p_client) and app.client_owner_active(p_client, null))
          or (app.is_admin() and app.client_own_brand(p_client) and app.client_owner_active(p_client, null)))
$$;
create or replace function app.may_unpublish_showcase(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null
     and (app.client_owner_check(p_client) or (app.is_admin() and app.client_own_brand(p_client)))
$$;

create or replace function app.showcase_publish(p_client uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); c public.clients;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null or me is null or not (app.client_reader_of(p_client) or app.can_access_client(p_client)) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not coalesce(app.may_publish_showcase(p_client), false) then
    raise exception 'showcase: the client''s owner approves it, while the client is Active (an own-brand client: the admin)' using errcode = '42501'; end if;
  if exists (select 1 from public.client_showcases where client_id = p_client and status = 'published') then
    raise exception 'showcase: it is published already' using errcode = '23514'; end if;
  insert into public.client_showcases (client_id, status, published_by, published_at)
  values (p_client, 'published', me, now())
  on conflict (client_id) do update set status = 'published', published_by = me, published_at = now(),
     unpublished_by = null, unpublished_at = null, unpublish_reason = null;
  perform app.audit('showcase_published', p_client, jsonb_build_object('code', c.code), false);
  return app.showcase_of(p_client);
end $$;

create or replace function app.showcase_unpublish(p_client uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); c public.clients;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null or me is null or not (app.client_reader_of(p_client) or app.can_access_client(p_client)) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if not coalesce(app.may_unpublish_showcase(p_client), false) then
    raise exception 'showcase: the client''s owner unpublishes it (an own-brand client: the admin)' using errcode = '42501'; end if;
  if not exists (select 1 from public.client_showcases where client_id = p_client and status = 'published') then
    raise exception 'showcase: it is not published' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'showcase: say why it is unpublished (at least 5 characters)' using errcode = '23514'; end if;
  update public.client_showcases set status = 'unpublished', unpublished_by = me, unpublished_at = now(), unpublish_reason = left(btrim(p_reason), 300)
   where client_id = p_client;
  perform app.audit('showcase_unpublished', p_client, jsonb_build_object('code', c.code, 'reason', left(btrim(p_reason), 300)), false);
  return app.showcase_of(p_client);
end $$;

-- the showcase for the client's people and GrainVeda's: its state, who may act, and a preview of the page
create or replace function app.showcase_of(p_client uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.clients; x public.client_showcases;
begin
  select * into c from public.clients where id = p_client;
  if c.id is null or app.current_user_id() is null or not (app.client_reader_of(p_client) or app.can_access_client(p_client)) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into x from public.client_showcases where client_id = p_client;
  return jsonb_build_object('client_id', c.id, 'code', c.code, 'status', coalesce(x.status, 'never'),
    'published_at', x.published_at, 'published_by', (select u.display_name from public.app_users u where u.id = x.published_by),
    'unpublished_at', x.unpublished_at, 'unpublish_reason', x.unpublish_reason,
    'unpublished_by', (select u.display_name from public.app_users u where u.id = x.unpublished_by),
    'may_publish', coalesce(app.may_publish_showcase(p_client), false) and x.status is distinct from 'published',
    'may_unpublish', coalesce(app.may_unpublish_showcase(p_client), false) and x.status = 'published',
    'live_until', app.client_live_until(p_client),
    'preview', app.showcase_data(p_client));
end $$;

-- 6 · the lifetime round (A4): the owners told 30 days before; the accounts marked removed after ----------------------------
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check check (kind in ('client_state_added', 'client_suspended',
  'client_resumed', 'client_ended', 'client_returned', 'client_renewal', 'client_accounts_closing'));

create or replace function app.client_lifetime_round() returns jsonb
language plpgsql security definer set search_path = public as $$
declare c record; n_told int := 0; n_closed int := 0; n int;
begin
  for c in select cl.id, cl.code, cl.name, app.client_live_until(cl.id) as until from public.clients cl
            where exists (select 1 from public.client_states cs where cs.client_id = cl.id)
              and not exists (select 1 from public.client_states cs where cs.client_id = cl.id and cs.status <> 'ended') loop
    if c.until is null then continue; end if;
    if app.today() > c.until then
      update public.client_accounts set status = 'removed', status_at = now(), status_by = null,
             status_reason = 'the lifetime period ended on ' || to_char(c.until, 'YYYY-MM-DD')
       where client_id = c.id and status in ('active', 'suspended');
      get diagnostics n = row_count;
      if n > 0 then
        n_closed := n_closed + n;
        perform app.audit_as(null, 'client_accounts_closed', c.id, jsonb_build_object('code', c.code, 'accounts', n, 'live_until', c.until), false);
      end if;
    elsif app.today() >= c.until - 30 then
      insert into public.notifications (user_id, kind, client_id, data)
      select ca.user_id, 'client_accounts_closing', c.id, jsonb_build_object('client', c.name, 'code', c.code, 'on', c.until)
        from public.client_accounts ca
       where ca.client_id = c.id and ca.kind = 'owner' and ca.status = 'active'
         and not exists (select 1 from public.notifications x where x.user_id = ca.user_id and x.kind = 'client_accounts_closing'
                           and x.client_id = c.id and x.data->>'on' = c.until::text);
      get diagnostics n = row_count;
      n_told := n_told + n;
    end if;
  end loop;
  return jsonb_build_object('told', n_told, 'closed', n_closed);
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('grainveda-client-lifetime', '45 20 * * *', 'select app.client_lifetime_round()');   -- 02:15 IST
  else
    raise notice 'pg_cron not available: the client lifetime round is not scheduled (the rules close the accounts on their own)';
  end if;
exception when others then
  raise notice 'the client lifetime round is not scheduled: %', sqlerrm;
end $$;

-- 8 · the functions replaced, each from its text as migration 71 left it, with the change named ---------------------------
-- A4: an ended client's accounts open nothing once its pages' lifetime has passed
CREATE OR REPLACE FUNCTION app.my_client_account()
 RETURNS client_accounts
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select ca.* from public.client_accounts ca join public.app_users u on u.id = ca.user_id
   where ca.user_id = app.current_user_id() and ca.status = 'active' and u.status = 'active' and u.external
     and not app.client_accounts_closed(ca.client_id) /* migration 72 (A4) */
$function$;

-- A4: likewise, the scopes an account reaches
CREATE OR REPLACE FUNCTION app.account_reaches(p_user uuid, p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.client_accounts ca join public.scopes s on s.id = p_scope and s.client_id = ca.client_id
                  where ca.user_id = p_user and ca.status = 'active' and ca.kind in ('owner', 'viewer')
                    and not app.client_accounts_closed(ca.client_id) /* migration 72 (A4) */
                    and (ca.kind = 'owner' or ca.reach = 'client'
                         or (ca.reach = 'state' and s.state_id = ca.state_id)
                         or (ca.reach = 'scopes' and exists (select 1 from public.client_account_scopes x where x.user_id = ca.user_id and x.scope_id = s.id))))
$function$;

-- A4: likewise, the states an account touches
CREATE OR REPLACE FUNCTION app.account_states(p_user uuid, p_client uuid)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(array(
    select cs.state_id from public.client_states cs join public.client_accounts ca on ca.user_id = p_user and ca.client_id = cs.client_id
     where cs.client_id = p_client and ca.status = 'active'
       and not app.client_accounts_closed(ca.client_id) /* migration 72 (A4) */
       and (ca.kind = 'owner' or ca.reach = 'client' or (ca.reach = 'state' and cs.state_id = ca.state_id)
            or (ca.reach = 'scopes' and exists (select 1 from public.client_account_scopes x join public.scopes s on s.id = x.scope_id
                                                  where x.user_id = ca.user_id and s.state_id = cs.state_id)))), '{}')
$function$;

-- A4: likewise, the farmers an account sees
CREATE OR REPLACE FUNCTION app.account_sees_farmer(p_user uuid, p_farmer uuid, p_client uuid, p_state uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.client_accounts ca
                  where ca.user_id = p_user and ca.client_id = p_client and ca.status = 'active' and ca.kind in ('owner', 'viewer')
                    and not app.client_accounts_closed(ca.client_id) /* migration 72 (A4) */
                    and (ca.kind = 'owner' or ca.reach = 'client' or (ca.reach = 'state' and p_state = ca.state_id)
                         or exists (select 1 from public.footprints f where f.farmer_id = p_farmer and f.client_id = p_client
                                      and app.account_reaches(p_user, f.scope_id))))
$function$;

-- A4: likewise, a client operator
CREATE OR REPLACE FUNCTION app.client_operator_for(p_user uuid, p_scope uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.client_accounts ca join public.scopes s on s.id = p_scope and s.client_id = ca.client_id
                  where ca.user_id = p_user and ca.kind = 'operator' and ca.status = 'active'
                    and not app.client_accounts_closed(ca.client_id) /* migration 72 (A4) */ and s.delivery_model in ('hybrid', 'self_run'))
$function$;

-- F: an output's verify page, after the lifetime period of an ended client: only that verification ended
CREATE OR REPLACE FUNCTION app.public_document(p_ref text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when app.output_expired(r) then jsonb_build_object('ref', r.ref, 'kind', r.kind, 'version', r.version, 'status', r.status,   -- migration 72 (F)
           'expired', true, 'subject_kind', r.subject_kind, 'subject', r.subject_code, 'verification', app.client_verification(r.scope_id), 'files', '[]'::jsonb)
         else jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
           'issued_at', r.issued_at, 'issued_to', r.issued_to, 'period_from', r.period_from, 'period_to', r.period_to,
           'crop', cr.name, 'season', s.season_code, 'geography', s.geography, 'state', st.name,
           'superseded_by', (select x.ref from public.reports x where x.id = r.superseded_by), 'superseded_at', r.superseded_at,
           'withdrawn_at', r.withdrawn_at,
           'subject_kind', r.subject_kind, 'subject', r.subject_code, 'scopes', coalesce(cardinality(r.scope_ids), 1),   -- migration 71
           'files', coalesce((select jsonb_agg(jsonb_build_object('copy', split_part(k, '_', 3), 'format', split_part(k, '_', 1), 'lang', split_part(k, '_', 2),
                                'sha256', v->>'sha256', 'bytes', v->'bytes') order by k) from jsonb_each(r.files) e(k, v)), '[]'::jsonb)) end
    from public.reports r join public.scopes s on s.id = r.scope_id join public.crops cr on cr.id = s.crop_id
    left join public.states st on st.id = s.state_id
   where r.ref = upper(btrim(p_ref)) $function$;


-- 9 · grants ----------------------------------------------------------------------------------------------------------------
revoke execute on function app.lifetime_months(text), app.months_after(text), app.client_live_until(uuid), app.client_accounts_closed(uuid),
  app.output_expired(public.reports), app.client_verification_all(uuid), app.showcase_data(uuid), app.client_own_brand(uuid),
  app.may_publish_showcase(uuid), app.may_unpublish_showcase(uuid), app.client_lifetime_round(), app.client_showcases_guard()
  from public, anon, authenticated;
revoke execute on function app.public_showcase(text), app.showcase_badge(text) from public;
grant execute on function app.public_showcase(text), app.showcase_badge(text) to anon, authenticated;
revoke execute on function app.showcase_publish(uuid), app.showcase_unpublish(uuid, text), app.showcase_of(uuid) from public, anon;
grant execute on function app.showcase_publish(uuid), app.showcase_unpublish(uuid, text), app.showcase_of(uuid) to authenticated;
