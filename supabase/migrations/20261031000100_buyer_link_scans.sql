-- GrainVeda MVP · migration 56: the buyer link, scans and copy detection, one client's data kept from another (release 9
-- of the operator-stages plan, the last; Veda, 16 Oct 2026, "proceed with 56"):
--   Part F  a Client Manager shares one sale or shipment with its buyer through a secure link: the lab results and their
--           reports, the export documents, the way the lot came (stages and dates, villages by share, never a farmer's
--           name, never another buyer's volumes or any price), and an evidence pack to download. The link expires, can be
--           revoked, and every view is logged for the client. The content is kept apart from the way in, so a buyer's
--           login can later replace the link.
--   D5–D6   every scan of a pack is logged with the time and the approximate place the host saw (city, region, country,
--           a point rounded to about 10 km; never the address, the person or the precise place); a pack's code scanned in
--           places far apart, or far more often than a pack is, opens a flag for the Client Manager and the State
--           Manager, and the pack's public page says so until they clear it.
--   Veda    "check that one client data should not be visible to another client": app.isolation_probe() looks at every
--           table and every one-record function as every person bound to a client, with the other clients' records;
--           the places it found are closed here (the client's own labs, a scope's activation list, the roster pool's
--           work on other clients' scopes).
-- Also: an export sale asks its market and destination as required fields (they were marked optional on the form).
select set_config('app.change_path', 'migration 56', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- 1 · One client's data is not another's: the places the probe found
-- ---------------------------------------------------------------------------------------------------------------------
-- A client's own lab is read by the people of that client (and those who oversee it), not by every signed-in person.
drop policy if exists labs_read on public.labs;
create policy labs_read on public.labs for select to authenticated
  using (client_id is null or app.can_access_client(client_id));

-- ---------------------------------------------------------------------------------------------------------------------
-- 2 · Scans: where (approximately), and copy detection
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.scans add column if not exists city text check (city is null or length(city) <= 80);
alter table public.scans add column if not exists region text check (region is null or length(region) <= 80);
alter table public.scans add column if not exists country text check (country is null or country ~ '^[A-Z]{2}$');
alter table public.scans add column if not exists lat numeric(4,1) check (lat is null or lat between -90 and 90);
alter table public.scans add column if not exists lng numeric(4,1) check (lng is null or lng between -180 and 180);

-- A pack's code that looks copied: scanned in places far apart, or far more often than a pack is. One open flag per pack
-- and kind; the Client Manager or the State Manager clears it (the scans were genuine) or confirms it (a copy).
create table if not exists public.scan_flags (
  id           uuid primary key default gen_random_uuid(),
  serial       text not null,
  kind         text not null check (kind in ('far_apart', 'many')),
  footprint_id uuid not null references public.footprints(id),
  scope_id     uuid not null references public.scopes(id),
  client_id    uuid not null references public.clients(id),
  detail       jsonb not null default '{}'::jsonb,
  status       text not null default 'open' check (status in ('open', 'cleared', 'confirmed')),
  raised_at    timestamptz not null default now(),
  decided_by   uuid references public.app_users(id),
  decided_at   timestamptz,
  reason       text check (reason is null or length(reason) <= 500)
);
create unique index if not exists scan_flags_one_open on public.scan_flags (serial, kind) where status = 'open';
create index if not exists scan_flags_scope on public.scan_flags (scope_id, status);
alter table public.scan_flags enable row level security;
revoke all on public.scan_flags from anon, authenticated;
grant select on public.scan_flags to authenticated;
drop policy if exists scan_flags_read on public.scan_flags;
create policy scan_flags_read on public.scan_flags for select to authenticated
  using (app.i_manage_scope(scope_id));
drop trigger if exists zz_change_log on public.scan_flags;
create trigger zz_change_log after insert or update or delete on public.scan_flags for each row execute function app.log_change('id');

-- Distance in km between two points (the haversine formula; the points are rounded to about 10 km anyway)
create or replace function app.km_between(a_lat numeric, a_lng numeric, b_lat numeric, b_lng numeric) returns numeric
language sql immutable as $$
  select round((2 * 6371 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
         + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))))::numeric, 0) $$;

-- Is this pack's code under a copy flag (open, or confirmed a copy)? What its public page says.
create or replace function app.scan_warning(p_serial text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.scan_flags f where f.serial = p_serial and f.status in ('open', 'confirmed')) $$;

-- A scan with where the host saw it from. Counted unless a machine is at it (60 a minute); for a pack, the copy check.
-- The limits are the crop's (thresholds: copy_distance_km 300 within copy_window_days 30; copy_scans_per_day 50).
create or replace function app.record_scan_at(p_code text, p_city text default null, p_region text default null,
  p_country text default null, p_lat numeric default null, p_lng numeric default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_kind text; p public.packs; cr public.crops; v_lat numeric; v_lng numeric; v_far record; v_n int;
        v_km numeric; v_days int; v_many int;
begin
  if p_code is null or length(p_code) > 80 then return jsonb_build_object('counted', false); end if;
  select * into p from public.packs where serial = p_code;
  v_kind := case when p.serial is not null then 'pack' when exists (select 1 from public.qr_seals where qr_code = p_code) then 'lot' end;
  if v_kind is null then return jsonb_build_object('counted', false); end if;
  if (select count(*) from public.scans where code = p_code and at > now() - interval '1 minute') >= 60 then
    return jsonb_build_object('counted', false, 'copy_warning', v_kind = 'pack' and app.scan_warning(p_code)); end if;
  v_lat := case when p_lat between -90 and 90 and p_lng between -180 and 180 then round(p_lat, 1) end;
  v_lng := case when v_lat is not null then round(p_lng, 1) end;
  insert into public.scans (code, kind, city, region, country, lat, lng)
  values (p_code, v_kind, nullif(left(btrim(coalesce(p_city, '')), 80), ''), nullif(left(btrim(coalesce(p_region, '')), 80), ''),
          case when upper(btrim(coalesce(p_country, ''))) ~ '^[A-Z]{2}$' then upper(btrim(p_country)) end, v_lat, v_lng);
  if v_kind = 'pack' then
    select c.* into cr from public.scopes s join public.crops c on c.id = s.crop_id where s.id = p.scope_id;
    v_km := app.opt_num(cr.thresholds, 'copy_distance_km', 300);
    v_days := app.opt_num(cr.thresholds, 'copy_window_days', 30)::int;
    v_many := app.opt_num(cr.thresholds, 'copy_scans_per_day', 50)::int;
    -- far apart: this scan's place and an earlier one more than v_km apart within the window
    if v_lat is not null then
      select s.city, s.country, s.at, app.km_between(v_lat, v_lng, s.lat, s.lng) as km into v_far
        from public.scans s
       where s.code = p_code and s.lat is not null and s.at > now() - make_interval(days => v_days)
       order by app.km_between(v_lat, v_lng, s.lat, s.lng) desc limit 1;
      if v_far.km > v_km and not exists (select 1 from public.scan_flags f where f.serial = p_code and f.kind = 'far_apart' and f.status = 'open') then
        insert into public.scan_flags (serial, kind, footprint_id, scope_id, client_id, detail)
        select p.serial, 'far_apart', p.footprint_id, p.scope_id, s.client_id,
               jsonb_build_object('km', v_far.km, 'limit_km', v_km,
                 'places', jsonb_build_array(jsonb_build_object('city', v_far.city, 'country', v_far.country, 'at', v_far.at),
                                             jsonb_build_object('city', nullif(btrim(coalesce(p_city, '')), ''), 'country', upper(nullif(btrim(coalesce(p_country, '')), '')), 'at', now())))
          from public.scopes s where s.id = p.scope_id;
      end if;
    end if;
    -- far more often than a pack is scanned
    select count(*) into v_n from public.scans where code = p_code and at > now() - interval '1 day';
    if v_n > v_many and not exists (select 1 from public.scan_flags f where f.serial = p_code and f.kind = 'many' and f.status = 'open') then
      insert into public.scan_flags (serial, kind, footprint_id, scope_id, client_id, detail)
      select p.serial, 'many', p.footprint_id, p.scope_id, s.client_id, jsonb_build_object('scans_24h', v_n, 'limit', v_many)
        from public.scopes s where s.id = p.scope_id;
    end if;
  end if;
  return jsonb_build_object('counted', true, 'copy_warning', v_kind = 'pack' and app.scan_warning(p_code));
end $$;

-- The flags the person manages, with the pack's last scans (time and approximate place only)
create or replace function app.scan_flags_list(p_status text default 'open') returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'serial', f.serial, 'kind', f.kind, 'detail', f.detail, 'status', f.status,
           'raised_at', f.raised_at, 'reason', f.reason, 'decided_at', f.decided_at,
           'batch_code', p.batch_code, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
           'scans', (select coalesce(jsonb_agg(jsonb_build_object('at', x.at, 'city', x.city, 'region', x.region, 'country', x.country) order by x.at desc), '[]'::jsonb)
                       from (select * from public.scans sc where sc.code = f.serial order by sc.at desc limit 20) x))
           order by f.raised_at desc), '[]'::jsonb)
    from public.scan_flags f join public.packs p on p.serial = f.serial
    join public.scopes s on s.id = f.scope_id join public.crops cr on cr.id = s.crop_id
   where (p_status = 'all' or f.status = p_status) and app.manages_scope(app.current_user_id(), f.scope_id) $$;

-- Cleared (the scans were genuine: the public warning goes) or confirmed (a copy: the warning stays), with a reason
create or replace function app.decide_scan_flag(p_flag uuid, p_outcome text, p_reason text) returns public.scan_flags
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.scan_flags;
begin
  select * into f from public.scan_flags where id = p_flag;
  if f.id is null or me is null or not app.manages_scope(me, f.scope_id) then raise exception 'scan flag not found' using errcode = 'P0002'; end if;
  if f.status <> 'open' then raise exception 'this scan flag is decided already' using errcode = '23514'; end if;
  if p_outcome not in ('cleared', 'confirmed') then raise exception 'a scan flag is cleared or confirmed' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then raise exception 'scan flag: say why (at least 10 characters)' using errcode = '23514'; end if;
  update public.scan_flags set status = p_outcome, decided_by = me, decided_at = now(), reason = left(btrim(p_reason), 500)
   where id = f.id returning * into f;
  perform app.audit('scan_flag_' || p_outcome, f.footprint_id, jsonb_build_object('serial', f.serial, 'kind', f.kind), false);
  return f;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- 3 · Part F: a sale or a shipment shared with its buyer
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.buyer_links (
  id            uuid primary key default gen_random_uuid(),
  token_hash    text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  footprint_id  uuid not null references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  client_id     uuid not null references public.clients(id),
  buyer_id      uuid references public.buyers(id),
  note          text check (note is null or length(note) <= 200),
  created_by    uuid not null references public.app_users(id),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  revoked_at    timestamptz,
  revoked_by    uuid references public.app_users(id),
  revoke_reason text check (revoke_reason is null or length(revoke_reason) <= 300)
);
create index if not exists buyer_links_fp on public.buyer_links (footprint_id);
alter table public.buyer_links enable row level security;
revoke all on public.buyer_links from anon, authenticated;
grant select (id, footprint_id, scope_id, client_id, buyer_id, note, created_by, created_at, expires_at, revoked_at, revoked_by, revoke_reason)
  on public.buyer_links to authenticated;
drop policy if exists buyer_links_read on public.buyer_links;
create policy buyer_links_read on public.buyer_links for select to authenticated
  using (app.i_manage_scope(scope_id));
drop trigger if exists zz_change_log on public.buyer_links;
create trigger zz_change_log after insert or update or delete on public.buyer_links for each row execute function app.log_change('id');

create table if not exists public.buyer_link_views (
  id        bigserial primary key,
  link_id   uuid not null references public.buyer_links(id),
  at        timestamptz not null default now(),
  what      text not null check (what in ('open', 'evidence', 'file')),
  file_id   uuid references public.attachments(id)
);
create index if not exists buyer_link_views_link on public.buyer_link_views (link_id, at desc);
drop trigger if exists zz_change_log on public.buyer_link_views;
create trigger zz_change_log after insert or update or delete on public.buyer_link_views for each row execute function app.log_change('id');
alter table public.buyer_link_views enable row level security;
revoke all on public.buyer_link_views from anon, authenticated;
grant select on public.buyer_link_views to authenticated;
drop policy if exists buyer_link_views_read on public.buyer_link_views;
create policy buyer_link_views_read on public.buyer_link_views for select to authenticated
  using (exists (select 1 from public.buyer_links l where l.id = link_id and app.i_manage_scope(l.scope_id)));

-- The records a lot came from (through the links of mass balance), the lot itself included
create or replace function app.lot_upstream(p_fp uuid) returns setof uuid
language sql stable security definer set search_path = public as $$
  with recursive up(id, depth) as (
    select p_fp, 0
    union
    select coalesce(l.parent_id, f.prev_footprint_id), up.depth + 1
      from up join public.footprints f on f.id = up.id
      left join public.footprint_links l on l.child_id = up.id
     where up.depth < 64 and coalesce(l.parent_id, f.prev_footprint_id) is not null)
  select distinct id from up $$;

-- What a buyer sees of one sale (and its shipments) or one shipment: no price, no other buyer, no farmer's name, no
-- quantity of the stages before the sale. Kept apart from the way in (the link today, a buyer's login later).
create or replace function app.buyer_content(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; sale public.footprints; sc public.scopes; cr public.crops; cl public.clients;
        v_ships uuid[]; v_pack uuid; v_up uuid[]; v_seal uuid; q public.qr_seals; v_files jsonb := '[]'::jsonb; r jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or f.stage_type not in ('commercial', 'shipment') then return null; end if;
  if f.stage_type = 'commercial' then sale := f;
  else select * into sale from public.footprints where id = f.prev_footprint_id; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  select * into cl from public.clients where id = sc.client_id;
  v_ships := case when f.stage_type = 'shipment' then array[f.id]
                  else array(select s.id from public.footprints s where s.prev_footprint_id = sale.id and s.stage_type = 'shipment'
                               and s.status in ('pending', 'verified') order by s.created_at) end;
  v_pack := sale.prev_footprint_id;
  v_up := array(select app.lot_upstream(v_pack));
  select s into v_seal from app.packing_seals(v_pack) s limit 1;
  select * into q from public.qr_seals where footprint_id = v_seal;
  -- the files a buyer may open: the lab reports and client acceptances up the chain, the sale's export documents, the
  -- shipments' loading photos, bills of lading and proofs of delivery
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'label', a.label, 'record', x.footprint_code, 'sha256', a.sha256, 'at', a.created_at)
           order by a.created_at), '[]'::jsonb) into v_files
    from public.attachments a join public.footprints x on x.id = a.footprint_id
   where (a.footprint_id = any (v_up) and x.stage_type = 'qc' and a.label in ('lab_report', 'acceptance'))
      or (a.id in (select e.attachment_id from public.export_documents e where e.footprint_id = sale.id and e.status = 'received'))
      or (a.footprint_id = any (v_ships) and a.label in ('loading_photo', 'pod', 'bill_of_lading'));
  return jsonb_build_object(
    'kind', f.stage_type, 'code', f.footprint_code, 'generated_at', now(),
    'seller', cl.name,
    'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code,
    'gi_status', app.lot_gi_status(v_pack),
    'order', jsonb_build_object('code', sale.footprint_code, 'order_no', sale.computed->>'order_no', 'buyer', sale.computed->>'buyer',
               'buyer_country', sale.computed->>'buyer_country', 'market', sale.computed->>'market', 'market_name', sale.computed->>'market_name',
               'destination_country', sale.computed->>'destination_country', 'packs', sale.computed->'packs', 'kg', sale.qty_out,
               'on', sale.happened_on),
    'shipments', coalesce((select jsonb_agg(jsonb_build_object('code', s.footprint_code, 'on', coalesce(s.payload->>'dispatch_date', s.happened_on::text),
                   'destination', s.payload->>'destination', 'invoice_no', s.payload->>'invoice_no', 'market', s.computed->>'market',
                   'vehicle_no', s.payload->>'vehicle_no', 'transporter', s.payload->>'transporter', 'lr_no', s.payload->>'lr_no',
                   'container_no', s.computed->>'container_no', 'seal_no', s.payload->>'seal_no', 'shipping_bill_no', s.payload->>'shipping_bill_no',
                   'vessel', s.payload->>'vessel', 'port_loading', s.payload->>'port_loading', 'port_discharge', s.payload->>'port_discharge',
                   'bl_no', coalesce((select b.bl_no from public.bills_of_lading b where b.footprint_id = s.id), s.payload->>'bl_no'),
                   'packs', s.computed->'packs', 'kg', s.qty_out, 'pack_codes', s.computed->'serials_count',
                   'delivery', (select jsonb_build_object('on', d.received_on, 'received_kg', d.received_kg, 'note', d.note)
                                  from public.deliveries d where d.shipment_id = s.id order by d.confirmed_at desc limit 1)) order by s.created_at)
                   from public.footprints s where s.id = any (v_ships)), '[]'::jsonb),
    'lab', coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'on', x.happened_on, 'lab', x.computed->>'lab',
                   'report_no', x.payload->>'report_no', 'report_date', x.payload->>'report_date', 'readings', v.readings,
                   'domestic', v.domestic_verdict, 'export', v.export_verdict,
                   'released_on_acceptance', v.override is not null,
                   'markets', (select coalesce(jsonb_agg(jsonb_build_object('name', pv.name, 'verdict', pv.verdict, 'failed', pv.failed) order by pv.code), '[]'::jsonb)
                                 from public.qc_profile_verdicts pv where pv.footprint_id = x.id)) order by x.created_at)
                   from public.footprints x join public.qc_verdicts v on v.footprint_id = x.id
                  where x.id = any (v_up) and x.status in ('pending', 'verified')), '[]'::jsonb),
    'documents', case when sale.computed->>'market' = 'export' then app.export_docs_of(sale.id) else '[]'::jsonb end,
    'chain', coalesce((select jsonb_agg(jsonb_build_object('stage', x.stage_type, 'code', x.footprint_code, 'on', x.happened_on,
                   'verified', x.status = 'verified') order by x.created_at)
                   from public.footprints x where x.id = any (v_up) and x.stage_type <> 'procurement'), '[]'::jsonb),
    'origin', jsonb_build_object(
                   'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct)
                                  order by y.pct desc, y.village)
                     from (select fm.village, fm.district, round(sum(s.share) * 100, 1) as pct
                             from app.lot_sources(v_pack) s join public.footprints e on e.id = s.entry_id
                             join public.farmers fm on fm.id = e.farmer_id group by fm.village, fm.district) y), '[]'::jsonb),
                   'farmers', (select count(distinct e.farmer_id) from app.lot_sources(v_pack) s join public.footprints e on e.id = s.entry_id),
                   'shares_note', 'documented proportions by mass balance, not physical identity'),
    'release', case when v_seal is null then null else app.release_status(v_seal) end,
    'qr_code', q.qr_code,
    'files', v_files);
end $$;

-- A link: the token once (never kept; only its fingerprint), its expiry (1 to 90 days, 30 unless said)
create or replace function app.create_buyer_link(p_fp uuid, p_days int default 30, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare me uuid := app.current_user_id(); f public.footprints; v_token text; l public.buyer_links; v_buyer uuid;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type not in ('commercial', 'shipment') then raise exception 'a buyer link is of a sale or a shipment' using errcode = '23514'; end if;
  if not app.manages_scope(me, f.scope_id) then
    raise exception 'a buyer link is made by the Client Manager or a manager of the scope' using errcode = '42501'; end if;
  if f.status not in ('pending', 'verified') then raise exception 'this record is %', f.status using errcode = '23514'; end if;
  if p_days is null or p_days < 1 or p_days > 90 then raise exception 'buyer link: it lasts 1 to 90 days' using errcode = '23514'; end if;
  v_buyer := nullif(coalesce(f.computed->>'buyer_id', (select s.computed->>'buyer_id' from public.footprints s where s.id = f.prev_footprint_id)), '')::uuid;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.buyer_links (token_hash, footprint_id, scope_id, client_id, buyer_id, note, created_by, expires_at)
  values (encode(digest(v_token, 'sha256'), 'hex'), f.id, f.scope_id, f.client_id, v_buyer, nullif(left(btrim(coalesce(p_note, '')), 200), ''),
          me, now() + make_interval(days => p_days))
  returning * into l;
  perform app.audit('buyer_link_created', f.id, jsonb_build_object('code', f.footprint_code, 'link', l.id, 'expires_at', l.expires_at), false);
  return jsonb_build_object('id', l.id, 'token', v_token, 'expires_at', l.expires_at);
end $$;

create or replace function app.revoke_buyer_link(p_link uuid, p_reason text) returns public.buyer_links
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); l public.buyer_links;
begin
  select * into l from public.buyer_links where id = p_link;
  if l.id is null or me is null or not app.manages_scope(me, l.scope_id) then raise exception 'buyer link not found' using errcode = 'P0002'; end if;
  if l.revoked_at is not null then raise exception 'this buyer link is revoked already' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'buyer link: say why it is revoked (at least 5 characters)' using errcode = '23514'; end if;
  update public.buyer_links set revoked_at = now(), revoked_by = me, revoke_reason = left(btrim(p_reason), 300) where id = l.id returning * into l;
  perform app.audit('buyer_link_revoked', l.footprint_id, jsonb_build_object('link', l.id), false);
  return l;
end $$;

-- The links of a sale or shipment, with their views (for the managers of its scope)
create or replace function app.buyer_links_of(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'note', l.note, 'created_at', l.created_at, 'expires_at', l.expires_at,
           'revoked_at', l.revoked_at, 'revoke_reason', l.revoke_reason, 'by', u.display_name,
           'state', case when l.revoked_at is not null then 'revoked' when l.expires_at <= now() then 'expired' else 'active' end,
           'views', (select count(*) from public.buyer_link_views v where v.link_id = l.id),
           'last_view', (select max(v.at) from public.buyer_link_views v where v.link_id = l.id),
           'log', (select coalesce(jsonb_agg(jsonb_build_object('at', v.at, 'what', v.what) order by v.at desc), '[]'::jsonb)
                     from (select * from public.buyer_link_views v where v.link_id = l.id order by v.at desc limit 20) v))
           order by l.created_at desc), '[]'::jsonb)
    from public.buyer_links l left join public.app_users u on u.id = l.created_by
   where l.footprint_id = p_fp and app.manages_scope(app.current_user_id(), l.scope_id) $$;

-- The link a token opens, if it is live
create or replace function app.buyer_link_of(p_token text) returns public.buyer_links
language sql stable security definer set search_path = public, extensions as $$
  select l.* from public.buyer_links l
   where p_token ~ '^[0-9a-f]{48}$' and l.token_hash = encode(digest(p_token, 'sha256'), 'hex')
     and l.revoked_at is null and l.expires_at > now() $$;

-- The buyer's page: the content, each open logged. A token that is wrong, expired or revoked says only that.
create or replace function app.buyer_view(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l public.buyer_links;
begin
  l := app.buyer_link_of(p_token);
  if l.id is null then return jsonb_build_object('ok', false); end if;
  insert into public.buyer_link_views (link_id, what) values (l.id, 'open');
  return jsonb_build_object('ok', true, 'expires_at', l.expires_at, 'content', app.buyer_content(l.footprint_id));
end $$;

-- The evidence pack downloaded (logged)
create or replace function app.buyer_log(p_token text, p_what text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare l public.buyer_links;
begin
  l := app.buyer_link_of(p_token);
  if l.id is null or p_what is distinct from 'evidence' then return false; end if;
  insert into public.buyer_link_views (link_id, what) values (l.id, 'evidence');
  return true;
end $$;

-- A file of the buyer's page: where it is kept, if the link is live and the file is one of the page's (for the
-- buyer-file function, which signs a short download; the service role only). Logged.
create or replace function app.buyer_file(p_token text, p_file uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l public.buyer_links; c jsonb; a public.attachments;
begin
  l := app.buyer_link_of(p_token);
  if l.id is null then return jsonb_build_object('ok', false, 'problem', 'link'); end if;
  c := app.buyer_content(l.footprint_id);
  if not exists (select 1 from jsonb_array_elements(c->'files') x where x->>'id' = p_file::text) then
    return jsonb_build_object('ok', false, 'problem', 'file'); end if;
  select * into a from public.attachments where id = p_file;
  insert into public.buyer_link_views (link_id, what, file_id) values (l.id, 'file', a.id);
  return jsonb_build_object('ok', true, 'path', a.storage_path, 'sha256', a.sha256, 'label', a.label);
end $$;
-- ---------------------------------------------------------------------------------------------------------------------
-- One client's data is never another client's (Veda, 16 Oct 2026: "check that one client data should not be visible to
-- another client"). app.isolation_probe() looks, as every person bound to a client (an operator, a Client Manager, a
-- client's viewer; not the admin, HR or a State Manager, who see across clients by design), at:
--   1. every table the app reads: each row it shows him is traced to the client it belongs to (its client, scope,
--      record, farmer, person, file or requirement); a row of another client is a leak;
--   2. every app function he may call with one record's id: called with the ids of other clients' records (records of
--      each stage, scopes, farmers, buyers, the client's lists, files, samples); an answer that carries data is a leak (a
--      refusal, nothing, an empty list, or what it answers for an id that is nobody's, is not).
-- People are GrainVeda's workforce, not a client's data: the people of a state are seen by its Client Managers for
-- staffing (the roster pool), whichever client they work for now (their work on another client's scope is not named).
-- So the people tables (app_users, employee_*) are not counted here; HR's own rules keep them (tests 25-33).
-- It writes nothing of its own; the release script runs it in a transaction set read only and rolled back, so a
-- function that would write fails there. Only the database owner runs it. Its answer names tables, functions and
-- counts, never the contents of a row.
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.isolation_owner(p_table text, r jsonb) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce(
    case when p_table = 'clients' then (r->>'id')::uuid end,
    (r->>'client_id')::uuid,
    (select s.client_id from public.scopes s where s.id = (r->>'scope_id')::uuid),
    (select f.client_id from public.footprints f where f.id = coalesce(r->>'footprint_id', r->>'seal_id')::uuid),
    (select fa.client_id from public.farmers fa where fa.id = (r->>'farmer_id')::uuid),
    (select f.client_id from public.attachments a join public.footprints f on f.id = a.footprint_id where a.id = (r->>'attachment_id')::uuid),
    (select q.client_id from public.requirements q where q.id = (r->>'requirement_id')::uuid),
    (select b.client_id from public.buyers b where b.id = (r->>'buyer_id')::uuid),
    (select u.client_id from public.app_users u where u.id = coalesce(r->>'employee_id', r->>'user_id')::uuid),
    null::uuid) $$;

create or replace function app.isolation_probe(p_functions boolean default true, p_read_only boolean default true) returns jsonb
language plpgsql volatile set search_path = public, app as $$
declare
  u record; t record; fn record; probe record;
  v_clients uuid[]; v_rows jsonb; v_res jsonb; v_base jsonb; v_txt text; r jsonb; v_owner uuid;
  leaks jsonb := '[]'::jsonb; own_seen int := 0; people int := 0; tables int := 0; calls int := 0; refused int := 0;
  cols text; ids jsonb := '[]'::jsonb; v_key text; v_done text[] := '{}';
  link_cols constant text[] := array['id', 'client_id', 'scope_id', 'footprint_id', 'seal_id', 'farmer_id', 'attachment_id',
                                     'requirement_id', 'buyer_id', 'employee_id', 'user_id'];
begin
  if current_user in ('authenticated', 'anon') then raise exception 'the isolation probe is run by the database owner' using errcode = '42501'; end if;
  -- from here the transaction writes nothing (a function that would write, called as someone, fails)
  if p_read_only then perform set_config('transaction_read_only', 'on', true); end if;
  -- the ids other clients' records go by: a few records of every stage, the scopes, farmers, the client's lists, files,
  -- samples, sales' terms and documents, people
  select coalesce(jsonb_agg(jsonb_build_object('kind', k, 'id', id, 'client', client_id)), '[]'::jsonb) into ids from (
    select 'footprint:' || stage_type as k, id, client_id from (
      select f.*, row_number() over (partition by f.client_id, f.stage_type order by f.created_at desc) n from public.footprints f) x where n <= 2
    union all select 'scope', id, client_id from public.scopes
    union all select 'farmer', id, client_id from (select fa.*, row_number() over (partition by client_id order by created_at desc) n from public.farmers fa) x where n <= 3
    union all select 'buyer', id, client_id from public.buyers
    union all select 'collection_point', id, client_id from public.collection_points
    union all select 'mill', id, client_id from public.mills
    union all select 'packing_unit', id, client_id from public.packing_units
    union all select 'pack_sku', id, client_id from public.pack_skus
    union all select 'lab', id, client_id from public.labs where client_id is not null
    union all select 'attachment', a.id, f.client_id from (select a.*, row_number() over (partition by a.footprint_id order by a.created_at) n from public.attachments a) a
                join public.footprints f on f.id = a.footprint_id where a.n = 1
    union all select 'sample', id, client_id from public.qc_samples
    union all select 'client', id, id from public.clients) z;

  for u in
    select au.id, au.auth_uid, au.role,
           array_remove(array(select distinct c from unnest(array[au.client_id]
             || array(select a.client_id from app.eff_assignments(au.id) a where a.client_id is not null)
             || array(select s.client_id from app.eff_assignments(au.id) a join public.scopes s on s.id = a.scope_id)) c), null) as clients
      from public.app_users au
     where au.active and coalesce(au.system_role, 'operational') = 'operational' and au.role <> 'admin' and au.role <> 'state_manager'
       and not exists (select 1 from app.eff_assignments(au.id) a where a.lens = 'state')
     order by au.id
  loop
    people := people + 1;
    v_clients := u.clients;
    -- 1 · the tables, as him
    for t in
      select c.relname, array(select a.attname::text from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                                and a.attname::text = any (link_cols) order by a.attnum) as cs
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'select')
       order by c.relname
    loop
      if cardinality(t.cs) = 0 or t.cs = array['id'] or t.relname = 'app_users' or t.relname like 'employee\_%' then continue; end if;
      cols := (select string_agg(quote_ident(x), ', ') from unnest(t.cs) x);
      perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      begin
        execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (select %s from public.%I limit 5000) x', cols, t.relname) into v_rows;
      exception when others then v_rows := '[]'::jsonb;
      end;
      execute 'reset role';
      perform set_config('request.jwt.claims', '', true);
      if people = 1 then tables := tables + 1; end if;
      for r in select * from jsonb_array_elements(v_rows) loop
        v_owner := app.isolation_owner(t.relname, r);
        if v_owner is null then continue; end if;
        if v_owner = any (v_clients) then own_seen := own_seen + 1;
        else leaks := leaks || jsonb_build_object('kind', 'table', 'what', t.relname, 'person', left(u.id::text, 8), 'role', u.role);
             exit;
        end if;
      end loop;
    end loop;

    -- 2 · the functions, as him, with other clients' ids: once for each kind of person (role and clients)
    v_key := u.role || ':' || coalesce(array_to_string(array(select x::text from unnest(v_clients) x order by 1), ','), '');
    if p_functions and not (v_key = any (v_done)) then
      v_done := v_done || v_key;
      for fn in
        select p.oid, n.nspname || '.' || p.proname as name, p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'app' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')
           and p.pronargs - p.pronargdefaults = 1 and p.proargtypes[0] = 'uuid'::regtype
           and p.prorettype <> 'trigger'::regtype
         order by 2
      loop
        -- what the function answers for an id that is nobody's: an answer like it is no data (a default, "pending")
        perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        begin
          execute format('select to_jsonb(%s($1))', fn.name) using gen_random_uuid() into v_base;
        exception when others then v_base := null;
        end;
        execute 'reset role';
        perform set_config('request.jwt.claims', '', true);
        for probe in select x->>'kind' as kind, (x->>'id')::uuid as id from jsonb_array_elements(ids) x
                      where not ((x->>'client')::uuid = any (v_clients)) loop
          calls := calls + 1;
          perform set_config('request.jwt.claims', json_build_object('sub', u.auth_uid, 'role', 'authenticated')::text, true);
          execute 'set local role authenticated';
          begin
            execute format('select to_jsonb(%s($1))', fn.name) using probe.id into v_res;
          exception when others then v_res := null; refused := refused + 1;
          end;
          execute 'reset role';
          perform set_config('request.jwt.claims', '', true);
          v_txt := coalesce(v_res::text, 'null');
          if v_res is distinct from v_base and v_txt not in ('null', '[]', '{}', 'false', '0', '""')
             and not (jsonb_typeof(v_res) = 'object' and not exists (select 1 from jsonb_each(v_res) e where e.value not in ('null'::jsonb, '[]'::jsonb, '{}'::jsonb, 'false'::jsonb, '0'::jsonb))) then
            leaks := leaks || jsonb_build_object('kind', 'function', 'what', fn.proname, 'with', probe.kind, 'person', left(u.id::text, 8), 'role', u.role);
          end if;
        end loop;
      end loop;
    end if;
  end loop;

  return jsonb_build_object('people', people, 'tables', tables, 'calls', calls, 'refused', refused, 'own_rows_seen', own_seen,
    'clients', (select count(*) from public.clients), 'daily_code', app.daily_code_on(),
    'leaks', (select coalesce(jsonb_agg(distinct x), '[]'::jsonb) from jsonb_array_elements(leaks) x));
end $$;
revoke execute on function app.isolation_owner(text, jsonb), app.isolation_probe(boolean, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------
-- 4 · An export sale asks its market's profile and its destination (the save asked them; the form called them optional)
-- ---------------------------------------------------------------------------------------------------------------------
update public.stage_definitions d
   set form_schema = (select jsonb_agg(case when f->>'key' in ('market_code', 'destination_country') then f || '{"required": true}'::jsonb else f end
                                       order by n)
                        from jsonb_array_elements(d.form_schema) with ordinality as x(f, n))
 where d.stage_type = 'commercial' and exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'market_code' and f ? 'shown_if');

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen56.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- A scope's activation list: for the people of its client (and HR, who staffs it), not for another client's people
CREATE OR REPLACE FUNCTION app.activation_missing(p_scope uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when app.can_access_client((select s.client_id from public.scopes s where s.id = p_scope)) or app.acts_as_hr() then jsonb_build_object(
    'crop', coalesce((select to_jsonb(app.crop_missing(cr)) from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope), '[]'::jsonb),
    'retired', coalesce((select cr.retired_at is not null from public.scopes s join public.crops cr on cr.id = s.crop_id where s.id = p_scope), false),
    'stages', to_jsonb(app.coverage_gaps(p_scope, null))) end $function$;

-- The roster pool: a person's work on another client's scope is said, not named (its client, crop, season and place)
CREATE OR REPLACE FUNCTION app.work_elsewhere(p_user uuid, p_scope uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(case when app.can_access_client(s.client_id) or app.acts_as_hr()
           then jsonb_build_object('scope_id', s.id, 'label', s.season_code || ' · ' || s.geography, 'status', s.status,
                                   'client', c.name, 'stages', to_jsonb(a.stages))
           else jsonb_build_object('other_client', true, 'status', s.status, 'stages', to_jsonb(a.stages)) end   -- migration 56
           order by s.season_code, s.geography), '[]'::jsonb)
    from public.assignments a join public.scopes s on s.id = a.scope_id join public.clients c on c.id = s.client_id
   where a.employee_id = p_user and a.active and a.lens = 'scope' and a.scope_id is distinct from p_scope
     and (a.ends_on is null or a.ends_on >= app.today()) and s.status in ('draft', 'active') and cardinality(a.stages) > 0 $function$;

-- A scan is counted with where the host saw it (through app.record_scan_at); without a place, as before
CREATE OR REPLACE FUNCTION app.record_scan(p_code text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- migration 56: one way in for every scan (fair use, the count, copy detection), here without a place
  perform app.record_scan_at(p_code);
end $function$;

-- A pack's public page says when its code looks copied, and names the seller
CREATE OR REPLACE FUNCTION app.public_pack(p_serial text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p public.packs; v_seal uuid; q public.qr_seals; sc public.scopes; cr public.crops; v_pack jsonb;
begin
  select * into p from public.packs where serial = p_serial;
  if p.serial is null then return null; end if;
  select * into sc from public.scopes where id = p.scope_id; select * into cr from public.crops where id = sc.crop_id;
  v_pack := jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'size_kg', p.size_kg, 'packed_on', p.packed_on,
              'best_before', p.best_before, 'void', p.status = 'void',
              'copy_warning', app.scan_warning(p.serial), 'seller', (select c.name from public.clients c where c.id = sc.client_id));   -- migration 56
  select s into v_seal from app.packing_seals(p.footprint_id) s limit 1;
  if v_seal is null or p.status = 'void' then
    return jsonb_build_object('pack', v_pack, 'released', false,
      'crop', jsonb_build_object('name', cr.name, 'gi_tag', cr.gi_tag, 'origin', cr.origin), 'season', sc.season_code, 'geography', sc.geography,
      'gi_status', app.lot_gi_status(p.footprint_id));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $function$;

-- "Needs my action": pack codes that look copied, for the managers of their scope
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
    -- migration 56 (D6): pack codes that look copied, for the managers of their scope
    'scan_flags', (select count(*) from public.scan_flags sf where sf.status = 'open' and app.manages_scope(me, sf.scope_id)),
    -- open flags and conditions on records of the scopes I manage
    'flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
               where fl.status = 'open' and fl.kind = 'flag' and app.manages_scope(me, f.scope_id)),
    'conditions', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                    where fl.status = 'open' and fl.kind = 'condition' and app.manages_scope(me, f.scope_id)),
    -- migration 49 (A7): milling runs of the last 60 days above their crop's ceiling, in the State Manager's states
    'outturn_review', (select count(*) from public.footprints f join public.scopes s on s.id = f.scope_id
                        where f.stage_type = 'milling' and f.status in ('pending', 'verified') and f.created_at > now() - interval '60 days'
                          and exists (select 1 from unnest(f.warnings) w where w like 'outturn % above the crop''s ceiling%')
                          and exists (select 1 from app.eff_assignments(me) a where a.lens = 'state' and a.state_id = s.state_id)),
    -- migration 55 (C3): lots in the warehouse whose inspection is due or overdue, for who keeps them
    'inspections', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
               'state', i->>'state', 'next_due', i->>'next_due') order by i->>'next_due', f.footprint_code)
        from public.footprints f join public.scopes s on s.id = f.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
        cross join lateral app.inspection_state(f.id) i
       where f.stage_type = 'warehouse' and f.status in ('pending', 'verified') and i->>'state' in ('due', 'overdue')
         and app.keeps_warehouse(me, f.scope_id)), '[]'::jsonb),
    -- migration 55 (C3): in a scope without a Warehouse, a lot waiting for Milling longer than the crop's
    -- stored_unrecorded_days (15) with nothing taken: stored, but not recorded. For the scope's managers.
    'stored_unrecorded', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.footprint_code, 'scope', format('%s · %s · %s', cr.name, s.season_code, s.geography),
               'days', app.today() - (f.verified_at at time zone 'Asia/Kolkata')::date) order by f.verified_at)
        from public.footprints f join public.scopes s on s.id = f.scope_id and s.status = 'active' join public.crops cr on cr.id = s.crop_id
       where 'milling' = any (s.chain) and not ('warehouse' = any (s.chain))
         and f.stage_type = app.chain_prev(s.id, 'milling') and f.status = 'verified' and not coalesce(f.lot_closed, false)
         and f.verified_at < now() - make_interval(days => app.opt_num(cr.thresholds, 'stored_unrecorded_days', 15)::int)
         and not exists (select 1 from public.footprints c where c.prev_footprint_id = f.id and c.status not in ('superseded', 'legacy'))
         and app.manages_scope(me, s.id)), '[]'::jsonb)
  );
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.km_between(numeric, numeric, numeric, numeric), app.scan_warning(text),
  app.record_scan_at(text, text, text, text, numeric, numeric), app.scan_flags_list(text), app.decide_scan_flag(uuid, text, text),
  app.lot_upstream(uuid), app.buyer_content(uuid), app.create_buyer_link(uuid, integer, text), app.revoke_buyer_link(uuid, text),
  app.buyer_links_of(uuid), app.buyer_link_of(text), app.buyer_view(text), app.buyer_log(text, text), app.buyer_file(text, uuid)
  from public, anon, authenticated;
grant execute on function app.record_scan_at(text, text, text, text, numeric, numeric) to anon, authenticated;   -- the public page (through the host)
grant execute on function app.buyer_view(text), app.buyer_log(text, text) to anon, authenticated;                -- the buyer's page
grant execute on function app.buyer_file(text, uuid) to service_role;                                              -- the buyer-file function
grant execute on function app.scan_flags_list(text), app.decide_scan_flag(uuid, text, text),
  app.create_buyer_link(uuid, integer, text), app.revoke_buyer_link(uuid, text), app.buyer_links_of(uuid) to authenticated;
