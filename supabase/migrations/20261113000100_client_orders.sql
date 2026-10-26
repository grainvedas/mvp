-- Migration 70 (Phase 3, release 3 of Veda's combined brief of 19 Oct 2026: Part D, with item 67's display fixes).
-- One order drawing on several scopes.
--
--   D   a client order (public.client_orders): one buyer (the client's list), one market (an export market with its
--       profile and destination country), one order number and ONE invoice number; made by whoever holds Commercial in
--       one of the client's scopes of that crop (or runs such a scope), or the admin; never by a client account.
--       Each scope's Commercial person records its part, from a batch of its own, on the usual Commercial form ("Part of
--       a client order"): the buyer, market and order number are the order's; the packs, kilograms and price are the
--       part's. Each pack keeps its batch, scope, serial and public page. A part is refused unless: the scope is the
--       order's client and crop and sells to its market; the client is Active in the scope's state; the batch passed QC
--       for the order's market (or carries the client's written acceptance); the batch has the same GI status and the
--       same farm-verified status as the order's other parts. Every shipment of a part carries the order's invoice
--       number (filled in; another is refused; none yet: refused); the invoice is fixed once a part has shipped. An
--       order is cancelled only while it has no part.
--       The order's page (app.client_order_detail) shows it in one section per scope: the evidence pack of release 4
--       takes the same sections. The client's views (Across scopes) and their exports list the client orders.
--   67  (the run sheet's checks of item 66) the lab of an older QC record kept in "Lab reference" is shown in the
--       client's scope view
--   the farmer register's possible duplicates (found while checking this release: the isolation probe on the local
--       stack after the e2e suite): app.open_duplicates answered anyone signed in, given a farmer's id, with the names
--       and Farmer IDs of another client's farmers sharing his phone. No screen calls it: the farmer register
--       (app.farmer_register) and the Farmer ID's rule call it inside the database. Closed to the app's people.
-- Additive: one new table, new functions; replaced from their own text, each change named: app.reconcile (Commercial and
-- Shipment of a part), app.cv_across_data, app.cv_scope_data, app.export_client_view; app.open_duplicates closed to the
-- app's people. The Commercial form gains its first field ("Part of a client order"); the order's fields hide while one
-- is chosen.
select set_config('app.change_path', 'migration 70', true);

-- 1 · the client order ----------------------------------------------------------------------------------------------------
create table if not exists public.client_orders (
  id                  uuid primary key default gen_random_uuid(),
  code                text not null unique,
  client_id           uuid not null references public.clients(id),
  crop_id             uuid not null references public.crops(id),
  buyer_id            uuid not null references public.buyers(id),
  market              text not null check (market in ('domestic', 'export')),
  market_code         text not null,
  destination_country text,
  order_no            text not null check (length(btrim(order_no)) between 2 and 60),
  invoice_no          text check (invoice_no is null or btrim(invoice_no) ~ '^[A-Za-z0-9][A-Za-z0-9/._ -]{1,39}$'),
  note                text check (note is null or length(note) <= 500),
  status              text not null default 'open' check (status in ('open', 'cancelled')),
  created_by          uuid not null references public.app_users(id),
  created_at          timestamptz not null default now(),
  invoice_by          uuid references public.app_users(id),
  invoice_at          timestamptz,
  cancelled_by        uuid references public.app_users(id),
  cancelled_at        timestamptz,
  cancel_reason       text check (cancel_reason is null or length(btrim(cancel_reason)) between 10 and 500),
  check ((market = 'domestic' and market_code = 'domestic' and destination_country is null)
      or (market = 'export' and market_code <> 'domestic' and length(btrim(coalesce(destination_country, ''))) >= 2)),
  check (status <> 'cancelled' or (cancelled_by is not null and cancelled_at is not null and cancel_reason is not null))
);
-- one order number and one invoice number per order, among a client's orders that stand
create unique index if not exists client_orders_order_no on public.client_orders (client_id, lower(btrim(order_no))) where status = 'open';
create unique index if not exists client_orders_invoice_no on public.client_orders (client_id, upper(btrim(invoice_no))) where status = 'open' and invoice_no is not null;
create index if not exists client_orders_client on public.client_orders (client_id);
-- a part: a Commercial record naming its order (computed.client_order_id)
create index if not exists footprints_client_order on public.footprints ((computed->>'client_order_id')) where stage_type = 'commercial';

alter table public.client_orders enable row level security;
revoke all on public.client_orders from anon, authenticated;
grant select on public.client_orders to authenticated;
drop policy if exists client_orders_read on public.client_orders;
create policy client_orders_read on public.client_orders for select to authenticated using (app.can_access_client(client_id));
drop trigger if exists a00_client_login_reads_only on public.client_orders;
create trigger a00_client_login_reads_only before insert or update or delete on public.client_orders
  for each row execute function app.client_login_reads_only();
drop trigger if exists zz_change_log on public.client_orders;
create trigger zz_change_log after insert or update or delete on public.client_orders for each row execute function app.log_change('id');

-- 2 · the rules of a part -------------------------------------------------------------------------------------------------
-- a batch may go to a market: it passed QC for it (the market's profile, or the crop's domestic verdict), or it carries the
-- client's written acceptance for that market (an export acceptance for an export market)
create or replace function app.order_market_ok(p_batch uuid, p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_code = 'domestic' then
           app.profile_allowed(p_batch, 'domestic')
           or coalesce((select v.domestic = 'pass' or v.override->>'market' = 'domestic' from app.resolve_market_verdict(p_batch) v), false)
         else app.profile_allowed(p_batch, p_code) end
$$;

-- the words of a batch's GI status and farm-verified status (in the messages: English, as the database's messages are)
create or replace function app.order_gi_words(p_gi text, p_fv boolean) returns text
language sql immutable as $$
  select case p_gi when 'gi' then 'GI' when 'non_gi' then 'non-GI' else 'GI not confirmed' end
      || ', ' || case when p_fv then 'farm-verified' else 'not farm-verified' end
$$;

-- the parts of an order that stand (a withdrawn or corrected record is not a part)
create or replace function app.order_parts(p_order uuid) returns setof public.footprints
language sql stable security definer set search_path = public as $$
  select f.* from public.footprints f
   where f.stage_type = 'commercial' and f.computed->>'client_order_id' = p_order::text and f.status not in ('superseded', 'legacy')
$$;

-- the shipments of an order's parts that stand
create or replace function app.order_shipments(p_order uuid) returns setof public.footprints
language sql stable security definer set search_path = public as $$
  select s.* from public.footprints s
   where s.stage_type = 'shipment' and s.status not in ('superseded', 'legacy')
     and (s.prev_footprint_id in (select id from app.order_parts(p_order))
          or exists (select 1 from public.footprint_links k where k.child_id = s.id and k.parent_id in (select id from app.order_parts(p_order))))
$$;

-- Commercial: a part of a client order. The order's buyer, market (and export market, destination) and number replace what
-- the form sent; the part is refused unless the order, the scope, the client's state and the batch allow it.
create or replace function app.order_part_payload(p jsonb, f public.footprints, p_scope public.scopes) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.client_orders; v_gi text; v_fv boolean; other public.footprints; v_ogi text; v_ofv boolean;
begin
  if nullif(btrim(coalesce(p->>'client_order_id', '')), '') is null then return p - 'client_order_id'; end if;
  begin
    select * into o from public.client_orders where id = (p->>'client_order_id')::uuid;
  exception when invalid_text_representation then o := null; end;
  if o.id is null or o.client_id <> p_scope.client_id then
    raise exception 'commercial: that client order is not one of this client''s' using errcode = '23514'; end if;
  if o.status <> 'open' then
    raise exception 'commercial: client order % was cancelled', o.code using errcode = '23514'; end if;
  if o.crop_id <> p_scope.crop_id then
    raise exception 'commercial: client order % is for another crop', o.code using errcode = '23514'; end if;
  if (app.client_status_of_scope(p_scope.id)).status is distinct from 'active' then
    raise exception 'commercial: the client is not Active in this scope''s state: no part of client order % here', o.code using errcode = '23514'; end if;
  if not (o.market_code = any (p_scope.market_codes)) then
    raise exception 'commercial: this scope does not sell to the market of client order %', o.code using errcode = '23514'; end if;
  if f.prev_footprint_id is null then
    raise exception 'commercial: a part of client order % is made from a batch', o.code using errcode = '23514'; end if;
  if not app.order_market_ok(f.prev_footprint_id, o.market_code) then
    raise exception 'commercial: this batch has not passed QC for the market of client order % (nor carries the client''s written acceptance)', o.code
      using errcode = '23514'; end if;
  v_gi := app.lot_gi_status(f.prev_footprint_id); v_fv := app.lot_farm_verified(f.prev_footprint_id);
  select x.* into other from app.order_parts(o.id) x
   where x.id is distinct from f.id and x.id is distinct from f.supersedes_id order by x.created_at limit 1;
  if other.id is not null then
    v_ogi := app.lot_gi_status(other.prev_footprint_id); v_ofv := app.lot_farm_verified(other.prev_footprint_id);
    if v_ogi is distinct from v_gi or v_ofv is distinct from v_fv then
      raise exception 'commercial: every batch of client order % has the same GI status and farm-verified status (the order: %; this batch: %)',
        o.code, app.order_gi_words(v_ogi, v_ofv), app.order_gi_words(v_gi, v_fv) using errcode = '23514'; end if;
  end if;
  return (p - 'buyer' - 'market_code' - 'destination_country')
    || jsonb_build_object('client_order_id', o.id::text, 'buyer_id', o.buyer_id::text, 'market', o.market, 'order_no', o.order_no)
    || case when o.market = 'export' then jsonb_build_object('market_code', o.market_code, 'destination_country', o.destination_country) else '{}'::jsonb end;
end $$;

-- Shipment of a part: the order's one invoice (filled in; another refused; none yet refused); the client Active in the state
create or replace function app.order_shipment_payload(p jsonb, prev public.footprints, p_scope public.scopes) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.client_orders;
begin
  select * into o from public.client_orders where id::text = prev.computed->>'client_order_id';
  if o.id is null then return p; end if;
  if (app.client_status_of_scope(p_scope.id)).status is distinct from 'active' then
    raise exception 'shipment: the client is not Active in this scope''s state: no shipment of client order % here', o.code using errcode = '23514'; end if;
  if o.invoice_no is null then
    raise exception 'shipment: client order % has no invoice number yet: it is set on the order first (one invoice per order)', o.code using errcode = '23514'; end if;
  if nullif(btrim(coalesce(p->>'invoice_no', '')), '') is not null and upper(btrim(p->>'invoice_no')) <> upper(btrim(o.invoice_no)) then
    raise exception 'shipment: client order % has one invoice, %', o.code, o.invoice_no using errcode = '23514'; end if;
  return p || jsonb_build_object('invoice_no', o.invoice_no);
end $$;

-- 3 · making an order -----------------------------------------------------------------------------------------------------
-- who: a person of GrainVeda (never a client account) who holds Commercial in an active scope of the client and crop, or
-- runs such a scope (its Client or State Manager), where the client is Active; or the admin
create or replace function app.may_make_order(p_client uuid, p_crop uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and not app.is_client_login() and exists (
    select 1 from public.scopes s
     where s.client_id = p_client and s.crop_id = p_crop and s.status = 'active' and 'commercial' = any (s.chain)
       and (app.client_status_of_scope(s.id)).status = 'active'
       and (app.is_admin() or app.is_my_stage(app.current_user_id(), s.id, 'commercial')))
$$;

create or replace function app.next_client_order_code(p_client uuid) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v_code text; n int;
begin
  perform pg_advisory_xact_lock(hashtext('client_order:' || p_client::text));
  select c.code into v_code from public.clients c where c.id = p_client;
  select count(*) + 1 into n from public.client_orders o where o.client_id = p_client;
  loop
    exit when not exists (select 1 from public.client_orders o where o.code = 'ORD-' || v_code || '-' || lpad(n::text, 4, '0'));
    n := n + 1;
  end loop;
  return 'ORD-' || v_code || '-' || lpad(n::text, 4, '0');
end $$;

-- what the person may make orders for: each client and crop, with the client's active buyers and the markets its scopes
-- of that crop sell to
create or replace function app.client_order_choices() returns jsonb
language sql stable security definer set search_path = public as $$
  with cc as (select distinct s.client_id, s.crop_id from public.scopes s where s.status = 'active' and app.may_make_order(s.client_id, s.crop_id))
  select coalesce(jsonb_agg(jsonb_build_object(
           'client_id', cc.client_id, 'client', c.name, 'client_code', c.code, 'crop_id', cc.crop_id, 'crop', cr.name,
           'buyers', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'country', b.country) order by b.name)
                                 from public.buyers b where b.client_id = cc.client_id and b.active), '[]'::jsonb),
           'markets', coalesce((select jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name) order by m.code = 'domestic' desc, m.name)
                                  from public.market_profiles m where m.crop_id = cc.crop_id and m.status = 'active'
                                   and exists (select 1 from public.scopes s where s.client_id = cc.client_id and s.crop_id = cc.crop_id
                                                 and s.status = 'active' and m.code = any (s.market_codes))), '[]'::jsonb))
         order by c.name, cr.name), '[]'::jsonb)
    from cc join public.clients c on c.id = cc.client_id join public.crops cr on cr.id = cc.crop_id
$$;

create or replace function app.client_order_new(p_client uuid, p_crop uuid, p_buyer uuid, p_market_code text, p_destination text,
  p_order_no text, p_invoice_no text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); v_prof public.market_profiles; v_market text; v_code text; v_id uuid;
begin
  if not coalesce(app.may_make_order(p_client, p_crop), false) then
    raise exception 'you may not make an order for this client and crop (you hold Commercial in none of its active scopes of that crop, where the client is Active)'
      using errcode = '42501'; end if;
  if not exists (select 1 from public.buyers b where b.id = p_buyer and b.client_id = p_client and b.active) then
    raise exception 'client order: the buyer is not one of this client''s active buyers' using errcode = '23514'; end if;
  select * into v_prof from public.market_profiles m where m.crop_id = p_crop and m.status = 'active' and m.code = coalesce(p_market_code, '');
  if v_prof.id is null or not exists (select 1 from public.scopes s where s.client_id = p_client and s.crop_id = p_crop and s.status = 'active'
                                         and v_prof.code = any (s.market_codes)) then
    raise exception 'client order: choose the market (one the client''s scopes of this crop sell to)' using errcode = '23514'; end if;
  v_market := case when v_prof.code = 'domestic' then 'domestic' else 'export' end;
  if v_market = 'export' and length(btrim(coalesce(p_destination, ''))) < 2 then
    raise exception 'client order: name the destination country' using errcode = '23514'; end if;
  if length(btrim(coalesce(p_order_no, ''))) not between 2 and 60 then
    raise exception 'client order: give the order or contract number' using errcode = '23514'; end if;
  if exists (select 1 from public.client_orders o where o.client_id = p_client and o.status = 'open' and lower(btrim(o.order_no)) = lower(btrim(p_order_no))) then
    raise exception 'client order: order number % is on another order of this client', btrim(p_order_no) using errcode = '23505'; end if;
  if nullif(btrim(coalesce(p_invoice_no, '')), '') is not null then
    if btrim(p_invoice_no) !~ '^[A-Za-z0-9][A-Za-z0-9/._ -]{1,39}$' then
      raise exception 'client order: an invoice number is 2 to 40 letters, digits, / . _ - or spaces' using errcode = '23514'; end if;
    if exists (select 1 from public.client_orders o where o.client_id = p_client and o.status = 'open' and upper(btrim(o.invoice_no)) = upper(btrim(p_invoice_no))) then
      raise exception 'client order: invoice % is on another order of this client (one invoice per order)', btrim(p_invoice_no) using errcode = '23505'; end if;
  end if;
  v_code := app.next_client_order_code(p_client);
  insert into public.client_orders (code, client_id, crop_id, buyer_id, market, market_code, destination_country, order_no, invoice_no, note,
                                    created_by, invoice_by, invoice_at)
  values (v_code, p_client, p_crop, p_buyer, v_market, v_prof.code, case when v_market = 'export' then btrim(p_destination) end, btrim(p_order_no),
          nullif(btrim(coalesce(p_invoice_no, '')), ''), nullif(btrim(coalesce(p_note, '')), ''), me,
          case when nullif(btrim(coalesce(p_invoice_no, '')), '') is not null then me end,
          case when nullif(btrim(coalesce(p_invoice_no, '')), '') is not null then now() end)
  returning id into v_id;
  perform app.audit('client_order_created', v_id, jsonb_build_object('code', v_code, 'client_id', p_client, 'order_no', btrim(p_order_no),
    'market', v_prof.code, 'invoice_no', nullif(btrim(coalesce(p_invoice_no, '')), '')), false);
  return jsonb_build_object('id', v_id, 'code', v_code);
end $$;

-- the invoice number: set or changed until a part has shipped; then fixed
create or replace function app.client_order_invoice(p_order uuid, p_invoice_no text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.client_orders; me uuid := app.current_user_id();
begin
  select * into o from public.client_orders where id = p_order;
  if o.id is null or not coalesce(app.may_make_order(o.client_id, o.crop_id), false) then
    raise exception 'order not found' using errcode = 'P0002'; end if;
  if o.status <> 'open' then raise exception 'client order % was cancelled', o.code using errcode = '23514'; end if;
  if exists (select 1 from app.order_shipments(o.id)) then
    raise exception 'client order %: the invoice is fixed once a part has shipped (%)', o.code, o.invoice_no using errcode = '23514'; end if;
  if btrim(coalesce(p_invoice_no, '')) !~ '^[A-Za-z0-9][A-Za-z0-9/._ -]{1,39}$' then
    raise exception 'client order: an invoice number is 2 to 40 letters, digits, / . _ - or spaces' using errcode = '23514'; end if;
  if exists (select 1 from public.client_orders x where x.client_id = o.client_id and x.status = 'open' and x.id <> o.id
               and upper(btrim(x.invoice_no)) = upper(btrim(p_invoice_no))) then
    raise exception 'client order: invoice % is on another order of this client (one invoice per order)', btrim(p_invoice_no) using errcode = '23505'; end if;
  update public.client_orders set invoice_no = btrim(p_invoice_no), invoice_by = me, invoice_at = now() where id = o.id;
  perform app.audit('client_order_invoice', o.id, jsonb_build_object('code', o.code, 'invoice_no', btrim(p_invoice_no), 'was', o.invoice_no), false);
  return jsonb_build_object('id', o.id, 'code', o.code, 'invoice_no', btrim(p_invoice_no));
end $$;

-- cancelled only while it has no part (a part made is a record: it is withdrawn first, by the usual way)
create or replace function app.client_order_cancel(p_order uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.client_orders;
begin
  select * into o from public.client_orders where id = p_order;
  if o.id is null or not coalesce(app.may_make_order(o.client_id, o.crop_id), false) then
    raise exception 'order not found' using errcode = 'P0002'; end if;
  if o.status <> 'open' then raise exception 'client order % was cancelled already', o.code using errcode = '23514'; end if;
  if exists (select 1 from app.order_parts(o.id)) then
    raise exception 'client order % has parts: it is cancelled only while it has none', o.code using errcode = '23514'; end if;
  if length(btrim(coalesce(p_reason, ''))) not between 10 and 500 then
    raise exception 'say why the order is cancelled (10 to 500 characters)' using errcode = '23514'; end if;
  update public.client_orders set status = 'cancelled', cancelled_by = app.current_user_id(), cancelled_at = now(), cancel_reason = btrim(p_reason)
   where id = o.id;
  perform app.audit('client_order_cancelled', o.id, jsonb_build_object('code', o.code, 'reason', btrim(p_reason)), false);
  return jsonb_build_object('id', o.id, 'code', o.code, 'status', 'cancelled');
end $$;

-- 4 · reading orders ------------------------------------------------------------------------------------------------------
-- a reader of an order's client: a person of GrainVeda who reaches the client (as its buyers list), or a client account
-- that reads the client's views (owner, viewer)
create or replace function app.order_reader(p_client uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and case when app.is_client_login() then app.cv_may_client(p_client) else app.can_access_client(p_client) end
$$;

-- the scopes of an order's client whose parts the reader sees: a client account, the scopes it reaches; a person of
-- GrainVeda, the scopes where he sees Commercial records
create or replace function app.order_scope_seen(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when app.is_client_login() then app.cv_may_scope(p_scope) else app.can_see_footprint(p_scope, 'commercial') end
$$;

-- prices: a client account that may take the internal copy of the scope; a person of GrainVeda who reads the sale terms
create or replace function app.order_price_seen(p_scope uuid, p_client uuid, p_by uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when app.is_client_login() then app.cv_internal_scope(p_scope) else app.reads_lot_payment(p_client, p_by) end
$$;

create or replace function app.order_head(o public.client_orders) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'code', o.code, 'order_no', o.order_no, 'status', o.status, 'market', o.market, 'market_code', o.market_code,
    'market_name', (select m.name from public.market_profiles m where m.crop_id = o.crop_id and m.code = o.market_code order by m.status = 'active' desc limit 1),
    'destination_country', o.destination_country, 'invoice_no', o.invoice_no, 'note', o.note,
    'client_id', o.client_id, 'client', (select c.name from public.clients c where c.id = o.client_id),
    'client_code', (select c.code from public.clients c where c.id = o.client_id),
    'crop_id', o.crop_id, 'crop', (select cr.name from public.crops cr where cr.id = o.crop_id),
    'buyer', (select b.name from public.buyers b where b.id = o.buyer_id), 'buyer_country', (select b.country from public.buyers b where b.id = o.buyer_id),
    'created_at', o.created_at, 'created_by', (select u.display_name from public.app_users u where u.id = o.created_by),
    'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason)
$$;

-- the orders the person reads: a client account, its client's orders with a part in the scopes it reaches; a person of
-- GrainVeda, the orders of the clients he reaches (p_client: one of them)
create or replace function app.client_orders_list(p_client uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with o as (select o.* from public.client_orders o
              where (p_client is null or o.client_id = p_client) and app.order_reader(o.client_id)
                and (not app.is_client_login() or exists (select 1 from app.order_parts(o.id) x where app.order_scope_seen(x.scope_id)))),
  parts as (select o.id as order_id, x.* from o, app.order_parts(o.id) x where app.order_scope_seen(x.scope_id))
  select jsonb_build_object(
    'orders', coalesce((select jsonb_agg(app.order_head(o) || jsonb_build_object(
                 'parts', (select count(*) from parts p where p.order_id = o.id),
                 'scopes', (select count(distinct p.scope_id) from parts p where p.order_id = o.id),
                 'qty_kg', (select coalesce(sum(p.qty_out), 0) from parts p where p.order_id = o.id),
                 'shipped_kg', (select coalesce(sum(s.qty_in), 0) from app.order_shipments(o.id) s where s.status = 'verified' and app.order_scope_seen(s.scope_id)))
               order by o.status = 'open' desc, o.created_at desc) from o), '[]'::jsonb),
    'may_make', not app.is_client_login() and jsonb_array_length(app.client_order_choices()) > 0)
$$;

-- one order: its head, then one section per scope (the evidence pack of release 4 takes the same sections)
create or replace function app.client_order_detail(p_order uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.client_orders; v_parts jsonb; v_hidden int; v_first public.footprints; v_may boolean;
begin
  select * into o from public.client_orders where id = p_order;
  if o.id is null or not app.order_reader(o.client_id) then raise exception 'order not found' using errcode = 'P0002'; end if;
  select count(*) into v_hidden from app.order_parts(o.id) x where not app.order_scope_seen(x.scope_id);
  if app.is_client_login() and not exists (select 1 from app.order_parts(o.id) x where app.order_scope_seen(x.scope_id)) then
    raise exception 'order not found' using errcode = 'P0002'; end if;
  select x.* into v_first from app.order_parts(o.id) x order by x.created_at limit 1;
  v_may := not app.is_client_login() and o.status = 'open' and coalesce(app.may_make_order(o.client_id, o.crop_id), false);
  select coalesce(jsonb_agg(sec order by sec->>'state', sec->>'scope'), '[]'::jsonb) into v_parts from (
    select jsonb_build_object('scope_id', s.id, 'scope', app.cv_scope_label(s.id), 'state', st.name, 'season', s.season_code, 'geography', s.geography,
      'parts', (select jsonb_agg(jsonb_build_object(
          'id', x.id, 'code', x.footprint_code, 'status', x.status, 'on', coalesce(x.happened_on, x.created_at::date),
          'batch_code', (select pb.batch_code from public.pack_batches pb where pb.footprint_id = x.prev_footprint_id),
          'batch', (select b.footprint_code from public.footprints b where b.id = x.prev_footprint_id),
          'gi_status', app.lot_gi_status(x.prev_footprint_id), 'farm_verified', app.lot_farm_verified(x.prev_footprint_id),
          'packs', coalesce(x.computed->'packs', '[]'::jsonb), 'qty_kg', x.qty_out,
          'shipments', coalesce((select jsonb_agg(jsonb_build_object('id', sh.id, 'code', sh.footprint_code, 'status', sh.status,
                                   'invoice_no', sh.payload->>'invoice_no', 'qty_kg', sh.qty_in, 'packs', sh.computed->>'serials_count',
                                   'dispatch_date', sh.payload->>'dispatch_date', 'destination', sh.payload->>'destination') order by sh.created_at)
                                  from app.order_shipments(o.id) sh where sh.prev_footprint_id = x.id), '[]'::jsonb),
          'shipped_kg', coalesce((select sum(sh.qty_in) from app.order_shipments(o.id) sh where sh.prev_footprint_id = x.id and sh.status = 'verified'), 0))
          || case when app.order_price_seen(s.id, o.client_id, t.recorded_by) and t.footprint_id is not null
                  then jsonb_build_object('price_per_kg', t.price_per_kg, 'currency', t.currency, 'total_value', t.total_value) else '{}'::jsonb end
          order by x.created_at)
          from app.order_parts(o.id) x left join public.sale_terms t on t.footprint_id = x.id where x.scope_id = s.id)) as sec
      from public.scopes s join public.states st on st.id = s.state_id
     where s.id in (select x.scope_id from app.order_parts(o.id) x) and app.order_scope_seen(s.id)) z;
  return app.order_head(o) || jsonb_build_object(
    'gi_status', case when v_first.id is not null then app.lot_gi_status(v_first.prev_footprint_id) end,
    'farm_verified', case when v_first.id is not null then app.lot_farm_verified(v_first.prev_footprint_id) end,
    'sections', v_parts, 'hidden_parts', v_hidden,
    'qty_kg', (select coalesce(sum((p->>'qty_kg')::numeric), 0) from jsonb_array_elements(v_parts) sct, jsonb_array_elements(sct->'parts') p),
    'shipped_kg', (select coalesce(sum((p->>'shipped_kg')::numeric), 0) from jsonb_array_elements(v_parts) sct, jsonb_array_elements(sct->'parts') p),
    'shipped', exists (select 1 from app.order_shipments(o.id)),
    'may_edit', v_may, 'may_invoice', v_may and not exists (select 1 from app.order_shipments(o.id)),
    'may_cancel', v_may and not exists (select 1 from app.order_parts(o.id)));
end $$;

-- the Commercial form: the open orders a part may join from this scope, and whether this batch fits each (and why not)
create or replace function app.client_orders_open_for(p_scope uuid, p_batch uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with sc as (select * from public.scopes s where s.id = p_scope
                 and app.current_user_id() is not null and not app.is_client_login() and app.is_my_stage(app.current_user_id(), s.id, 'commercial')),
  o as (select o.* from public.client_orders o, sc where o.client_id = sc.client_id and o.crop_id = sc.crop_id and o.status = 'open'
          and o.market_code = any (sc.market_codes)),
  fit as (select o.id,
            case when (select (app.client_status_of_scope(sc.id)).status from sc) is distinct from 'active' then 'state'
                 when p_batch is null then null
                 when not app.order_market_ok(p_batch, o.market_code) then 'market'
                 when exists (select 1 from app.order_parts(o.id) x where x.prev_footprint_id <> p_batch
                                and (app.lot_gi_status(x.prev_footprint_id) is distinct from app.lot_gi_status(p_batch)
                                     or app.lot_farm_verified(x.prev_footprint_id) is distinct from app.lot_farm_verified(p_batch))) then 'gi'
                 else null end as why
          from o, sc)
  select coalesce(jsonb_agg(app.order_head(o) || jsonb_build_object('fits', f.why is null, 'why', f.why,
           'parts', (select count(*) from app.order_parts(o.id))) order by o.created_at desc), '[]'::jsonb)
    from o join fit f on f.id = o.id
$$;

-- a part's order, for the Shipment form (its invoice) and the record page
create or replace function app.order_of_part(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', o.id, 'code', o.code, 'order_no', o.order_no, 'invoice_no', o.invoice_no, 'status', o.status)
    from public.footprints f join public.client_orders o on o.id::text = f.computed->>'client_order_id'
   where f.id = p_fp and f.stage_type = 'commercial' and app.current_user_id() is not null and app.can_see_footprint(f.scope_id, f.stage_type)
$$;

-- 5 · the Commercial form: its first field; the order's fields hide while an order is chosen ---------------------------------
update public.stage_definitions d
   set form_schema = '[{"key": "client_order_id", "type": "client_order", "label": "Part of a client order (optional)", "section": "buyer", "required": false}]'::jsonb
       || (select jsonb_agg(case when f->>'key' in ('buyer_id', 'buyer', 'market', 'market_code', 'destination_country', 'order_no')
                                 then f || '{"hidden_if_set": "client_order_id"}'::jsonb else f end order by n)
             from jsonb_array_elements(d.form_schema) with ordinality as x(f, n))
 where d.stage_type = 'commercial'
   and not exists (select 1 from jsonb_array_elements(d.form_schema) f where f->>'key' = 'client_order_id');

-- 8 · the functions replaced, each from its text as migration 69 left it, with the change named ---------------------------
-- D: Commercial, a part of a client order (the order's buyer, market and number; the part's rules); Shipment of a part, the order's one invoice
CREATE OR REPLACE FUNCTION app.reconcile(f footprints, p_scope scopes)
 RETURNS footprints
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  p jsonb := f.payload; c jsonb := '{}'::jsonb; w text[] := '{}';
  tol jsonb := p_scope.tolerances;
  v_in numeric; v_out numeric; a numeric; b numeric; d numeric; e numeric; s numeric; pk jsonb;
  prev public.footprints;
  v_ceiling numeric; v_learn int; v_rng record; v_pct numeric;   -- migration 49
  v_rdate date; v_taken text; v_on date;                          -- migration 50
  v_cp text; v_n int; v_crop public.crops; v_lim numeric; v_spread numeric; v_vill jsonb; v_nv int; v_moist numeric; v_far int;   -- migration 52
  v_mill public.mills; v_pu public.packing_units; v_sku public.pack_skus; v_smp public.qc_samples; v_lab public.labs;
  v_labname text; v_labtests text; v_loss numeric;                                                                   -- migration 53
  v_buyer public.buyers; v_left jsonb; v_pl jsonb; v_mkt text; v_prof public.market_profiles; v_ser text[]; v_ser_txt text;
  v_units jsonb; v_packs text[]; v_ncart int;                                                            -- migration 58
  v_papers boolean; v_packed boolean;                                                                    -- migration 62
  v_scp public.collection_points;                                                                                    -- migration 54
  v_mat text;                                                                                                        -- migration 61
begin
  if f.prev_footprint_id is not null then
    select * into prev from public.footprints where id = f.prev_footprint_id;
  end if;
  select * into v_crop from public.crops where id = p_scope.crop_id;          -- migration 52: its limits and thresholds

  case f.stage_type
    when 'procurement' then
      a := app.req_num(p, 'gross_kg'); b := app.req_num(p, 'bags'); d := app.req_num(p, 'tare_kg_per_bag');
      if not (p ? 'moisture_pct' and jsonb_typeof(p->'moisture_pct') = 'array' and jsonb_array_length(p->'moisture_pct') = 3) then
        raise exception 'payload.moisture_pct must be an array of 3 readings' using errcode = '23514';
      end if;
      select avg(x::numeric), min(x::numeric), max(x::numeric) into a, b, d
        from jsonb_array_elements_text(p->'moisture_pct') x;   -- reuse vars: a=avg b=min d=max
      v_in := app.req_num(p, 'gross_kg') - app.req_num(p, 'bags') * app.req_num(p, 'tare_kg_per_bag');
      if v_in <= 0 then raise exception 'net weight must be positive (gross - bags x tare)' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('net_kg', v_in, 'moisture_avg', round(a, 2), 'moisture_min', b, 'moisture_max', d);
      if f.farmer_id is null then raise exception 'procurement requires farmer_id' using errcode = '23514'; end if;
      -- migration 52 (C1): where it was weighed, its GPS, who delivered it (asked where the scope says so)
      v_cp := nullif(btrim(p->>'collection_point_id'), '');
      if v_cp is not null and v_cp <> 'farm' and not exists (select 1 from public.collection_points cp
           where cp.id::text = v_cp and cp.client_id = p_scope.client_id and cp.active) then
        raise exception 'procurement: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
      if v_cp is not null then                                                  -- its name, for the record, the receipt and the batch
        c := c || jsonb_build_object('collection_point', case when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end); end if;
      if (p ? 'gps_lat' or p ? 'gps_lng') and (app.opt_num(p, 'gps_lat', null) is null or app.opt_num(p, 'gps_lng', null) is null
           or not app.valid_gps(app.opt_num(p, 'gps_lat', null), app.opt_num(p, 'gps_lng', null))) then
        raise exception 'procurement: the GPS point is two numbers in India' using errcode = '23514'; end if;
      if coalesce(p->>'delivered_by', 'farmer') not in ('farmer', 'family', 'agent') then
        raise exception 'procurement: delivered by the farmer, his family or an agent' using errcode = '23514'; end if;
      if p->>'delivered_by' = 'agent' and length(btrim(coalesce(p->>'agent_name', ''))) < 2 then
        raise exception 'procurement: name the agent who delivered the lot' using errcode = '23514'; end if;
      if p ? 'condition' and p->>'condition' not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'procurement: the condition is good, damp, pest or mixed' using errcode = '23514'; end if;
      if coalesce(p_scope.procurement_details_required, false) then
        if v_cp is null then
          raise exception 'procurement: say where the lot was weighed (a collection point, or at the farm)' using errcode = '23514'; end if;
        if not (p ? 'gps_lat') then
          raise exception 'procurement: the GPS of where the lot was weighed is required' using errcode = '23514'; end if;
        if not (p ? 'delivered_by') then
          raise exception 'procurement: say who delivered the lot (the farmer, his family or an agent)' using errcode = '23514'; end if;
      end if;
      -- warnings only: above the crop's moisture limit; three readings far apart (the crop's threshold, else 1.5 points)
      select app.opt_num(q, 'domestic_limit', null) into v_lim
        from jsonb_array_elements(coalesce(p_scope.quality_params, v_crop.quality_params, '[]'::jsonb)) q
       where q->>'param' in ('moisture_pct', 'moisture') and coalesce(q->>'operator', '<=') in ('<=', '<') limit 1;
      if v_lim is not null and a > v_lim then
        w := array_append(w, format('moisture %s %% is above the crop''s limit of %s %%', round(a, 1), v_lim)); end if;
      v_spread := coalesce((v_crop.thresholds->>'moisture_spread_pct')::numeric, 1.5);
      if d - b > v_spread then
        w := array_append(w, format('the moisture readings are %s points apart (more than %s): read them again', round(d - b, 1), v_spread)); end if;

    when 'lot_inward' then
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'weighed_kg');
      if b <= 0 then raise exception 'weighed_kg must be positive' using errcode = '23514'; end if;
      if coalesce(p->>'source_type', '') = '' or coalesce(p->>'source_name', '') = '' then
        raise exception 'payload.source_type and source_name are required' using errcode = '23514'; end if;
      perform app.req_num(p, 'moisture_pct');
      v_in := b; v_out := b;
      c := jsonb_build_object('variance_kg', a - b, 'variance_pct', case when a > 0 then round((a - b) / a * 100, 2) else null end);
      if a > 0 and abs(a - b) / a * 100 > app.opt_num(tol, 'lot_inward_variance_pct', 2) then
        w := array_append(w, 'declared vs weighed variance exceeds tolerance'); end if;

    when 'village_batch' then
      -- aggregates: qty_in = Σ qty_out of the source procurement lots (validated in the insert trigger)
      select coalesce(sum(s.qty_out), 0) into v_in
        from public.footprints s
        where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_in <= 0 then raise exception 'village_batch needs payload.source_footprint_ids with quantity' using errcode = '23514'; end if;
      v_out := v_in;
      c := jsonb_build_object('source_count', jsonb_array_length(p->'source_footprint_ids'));
      -- migration 52 (C2): one collection point; villages and farmers from the lots; single origin; re-weighed total
      select count(distinct coalesce(s.payload->>'collection_point_id', '')), min(coalesce(s.payload->>'collection_point_id', ''))
        into v_n, v_cp from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if v_n > 1 then
        raise exception 'collection batch: the lots are from different collection points (%): a batch is the lots at one place',
          (select string_agg(s.footprint_code || ' ' || coalesce(cp.name, case s.payload->>'collection_point_id' when 'farm' then 'at the farm' else 'no place recorded' end),
                             ', ' order by s.footprint_code)
             from public.footprints s left join public.collection_points cp on cp.id::text = s.payload->>'collection_point_id'
            where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)) using errcode = '23514'; end if;
      -- migration 54: the batch names its collection point (or "at the farm"); its lots are that point's
      if nullif(p->>'collection_point_id', '') is not null then
        if p->>'collection_point_id' <> 'farm' then
          select * into v_scp from public.collection_points cp where cp.id::text = p->>'collection_point_id' and cp.client_id = p_scope.client_id and cp.active;
          if v_scp.id is null then raise exception 'collection batch: the collection point is not one of this client''s active points' using errcode = '23514'; end if;
        end if;
        select string_agg(s.footprint_code, ', ' order by s.footprint_code) into v_ser_txt from public.footprints s
         where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x)
           and coalesce(s.payload->>'collection_point_id', '') <> p->>'collection_point_id';
        if v_ser_txt is not null then
          raise exception 'collection batch: % not weighed at this collection point (a batch is the lots of the point it names)', v_ser_txt using errcode = '23514'; end if;
        v_cp := p->>'collection_point_id';
      elsif p_scope.stage_details_required then
        raise exception 'collection batch: choose the collection point (where the bags are)' using errcode = '23514';
      end if;
      select coalesce(jsonb_agg(jsonb_build_object('village', g.village, 'kg', g.kg, 'share_pct', round(g.kg / nullif(v_in, 0) * 100, 1))
                                order by g.kg desc, g.village), '[]'::jsonb), count(*)
        into v_vill, v_nv
        from (select min(fm.village) as village, sum(s.qty_out) as kg
                from public.footprints s join public.farmers fm on fm.id = s.farmer_id
               where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x) group by app.norm_place(fm.village)) g;
      if coalesce((p->>'single_origin')::boolean, false) and v_nv > 1 then
        raise exception 'collection batch: a single-origin batch is from one village (these lots are from %)',
          (select string_agg(x->>'village', ', ') from jsonb_array_elements(v_vill) x) using errcode = '23514'; end if;
      select count(distinct s.farmer_id),
             round(sum(s.qty_out * (s.computed->>'moisture_avg')::numeric) / nullif(sum(s.qty_out) filter (where s.computed ? 'moisture_avg'), 0), 2)
        into v_far, v_moist from public.footprints s where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(p->'source_footprint_ids', '[]'::jsonb)) x);
      if p ? 'bags' and app.req_num(p, 'bags') < 1 then
        raise exception 'collection batch: the bags are 1 or more' using errcode = '23514'; end if;
      if p ? 'moisture_fresh_pct' and (app.req_num(p, 'moisture_fresh_pct') < 0 or app.req_num(p, 'moisture_fresh_pct') >= 100) then
        raise exception 'moisture must be below 100' using errcode = '23514'; end if;
      if p ? 'reweighed_kg' then
        e := app.req_num(p, 'reweighed_kg');
        if e <= 0 then raise exception 'collection batch: the re-weighed total is more than 0' using errcode = '23514'; end if;
        if e > v_in + app.kg_tolerance() then
          raise exception 'collection batch: the re-weighed total (% kg) is more than the lots (% kg)', e, v_in using errcode = '23514'; end if;
        v_out := least(e, v_in);
        if (v_in - v_out) / v_in * 100 > coalesce((v_crop.thresholds->>'batch_loss_pct')::numeric, 1) then
          w := array_append(w, format('the batch weighs %s kg (%s %%) less than its lots', round(v_in - v_out, 1), round((v_in - v_out) / v_in * 100, 1))); end if;
      end if;
      c := c || jsonb_build_object('total_kg', v_in, 'farmers', v_far, 'villages', v_vill, 'moisture_avg', v_moist,
                                   'collection_point', case when v_cp = '' then null when v_cp = 'farm' then 'farm'
                                                            else (select cp.name from public.collection_points cp where cp.id::text = v_cp) end)
                || case when p ? 'reweighed_kg' then jsonb_build_object('loss_kg', round(v_in - v_out, 3)) else '{}'::jsonb end;

    when 'milling' then
      if p ? 'head_rice_kg' then
        -- migration 53 (C4): head rice, broken, husk and bran; the loss worked out (never typed, never below 0); the mill
        -- from the client's list, its operator, how the line was cleared (recorded by itself at a mill dedicated to the
        -- crop); sent vs received when the mill is elsewhere. Head rice goes forward; broken rice is a by-product.
        v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'head_rice_kg');
        b := app.opt_num(p, 'broken_kg', 0); d := app.opt_num(p, 'husk_kg', 0); e := app.opt_num(p, 'bran_kg', 0);
        if v_in <= 0 then raise exception 'milling: the paddy in is more than 0 kg' using errcode = '23514'; end if;
        if least(a, b, d, e) < 0 then raise exception 'milling: an output is 0 kg or more' using errcode = '23514'; end if;
        v_loss := v_in - a - b - d - e;
        if v_loss < -app.kg_tolerance() then
          raise exception 'milling: the outputs (% kg) are more than the paddy in (% kg)', a + b + d + e, v_in using errcode = '23514'; end if;
        v_loss := greatest(v_loss, 0);
        if nullif(p->>'mill_id', '') is not null then
          select * into v_mill from public.mills m where m.id::text = p->>'mill_id' and m.client_id = p_scope.client_id and m.active;
          if v_mill.id is null then raise exception 'milling: the mill is not one of this client''s active mills' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'milling: say which mill (from the client''s list)' using errcode = '23514'; end if;
        if p_scope.stage_details_required and length(btrim(coalesce(p->>'mill_operator', ''))) < 2 then
          raise exception 'milling: name the mill operator' using errcode = '23514'; end if;
        if v_mill.id is not null and v_mill.dedicated_crop_id = p_scope.crop_id then v_cp := 'dedicated';
        else
          v_cp := nullif(p->>'line_clearance', '');
          if v_cp is not null and v_cp not in ('fully_cleaned', 'quick_clean', 'same_crop') then
            raise exception 'milling: the line was fully cleaned, given a quick clean, or its previous run was this crop' using errcode = '23514'; end if;
          if v_cp is null and v_mill.id is not null then
            raise exception 'milling: say how the line was cleared (the mill is not dedicated to this crop)' using errcode = '23514'; end if;
        end if;
        if p ? 'polish' and p->>'polish' not in ('light', 'medium', 'full') then
          raise exception 'milling: the polish is light, medium or full' using errcode = '23514'; end if;
        v_out := a;
        c := jsonb_build_object('head_rice_kg', a, 'broken_kg', b, 'husk_kg', d, 'bran_kg', e, 'loss_kg', round(v_loss, 3),
               'recovery_pct', round((a + b) / v_in * 100, 2), 'head_rice_pct', round(a / v_in * 100, 2), 'yield_pct', round((a + b) / v_in * 100, 2));
        if v_mill.id is not null then c := c || jsonb_build_object('mill', v_mill.name); end if;
        if v_cp is not null then c := c || jsonb_build_object('line_clearance', v_cp); end if;
        if p ? 'sent_kg' then
          s := app.req_num(p, 'sent_kg');
          if v_in > s + app.kg_tolerance() then
            raise exception 'milling: the mill received (% kg) more than was sent (% kg)', v_in, s using errcode = '23514'; end if;
          c := c || jsonb_build_object('transit_loss_kg', round(greatest(s - v_in, 0), 3));
        end if;
        -- no fixed threshold: the crop's ceiling (the State Manager is told) and, after enough runs, this mill's usual range
        v_pct := round((a + b) / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        if v_mill.id is not null then
          select * into v_rng from app.milling_range_mill(p_scope.crop_id, v_mill.id::text, f.id);
          if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
            w := array_append(w, format('recovery %s %% is outside the usual range of this mill (%s to %s %%, from %s verified runs)', v_pct,
                   round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
        end if;
      else
      -- a record of before migration 53: rice out, bran and loss typed
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'rice_kg'); b := app.req_num(p, 'bran_kg'); d := app.req_num(p, 'loss_kg');
      if not app.approx_eq(v_in, a + b + d) then
        raise exception 'milling: input (%) must equal rice + bran + loss (%)', v_in, a + b + d using errcode = '23514'; end if;
      v_out := a;
      c := jsonb_build_object('yield_pct', round(a / nullif(v_in, 0) * 100, 2), 'bran_kg', b, 'loss_kg', d);
      -- migration 49 (A7/G5): no fixed threshold. Above the crop's ceiling (70 % unless set) the State Manager is told;
      -- once the crop has its own verified runs (10 unless set), outside their usual range (mean ± 2 SD) is warned.
      if v_in > 0 then
        v_pct := round(a / v_in * 100, 1);
        select coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70), coalesce((cr.thresholds->>'learn_after_runs')::int, 10)
          into v_ceiling, v_learn from public.crops cr where cr.id = p_scope.crop_id;
        if v_pct > v_ceiling then
          w := array_append(w, format('outturn %s %% is above the crop''s ceiling of %s %%: the State Manager is told', v_pct, v_ceiling)); end if;
        select * into v_rng from app.milling_range(p_scope.crop_id, p_scope.client_id, f.id);
        if v_rng.n >= v_learn and v_rng.sd is not null and abs(v_pct - v_rng.mean) > 2 * v_rng.sd then
          w := array_append(w, format('outturn %s %% is outside the usual range of this crop (%s to %s %%, from %s verified runs)', v_pct,
                 round(v_rng.mean - 2 * v_rng.sd, 1), round(v_rng.mean + 2 * v_rng.sd, 1), v_rng.n)); end if;
      end if;
      end if;                                                                           -- migration 53

    when 'sorting' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'reject_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;                                          -- clean output is DERIVED, never entered
      if v_out < 0 then raise exception 'sorting: reject + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('clean_kg', v_out, 'reject_kg', a, 'loss_kg', d, 'reject_reasons', coalesce(p->'reject_reasons', '[]'::jsonb));

    when 'grading' then
      if f.is_grade_lot then
        -- child grade lot: quantity given directly, coupled to the grading run (validated in trigger)
        v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
        c := jsonb_build_object('grade', f.grade);
      else
        v_in := app.req_num(p, 'input_kg');
        a := app.req_num(p, 'grade_a_kg'); b := app.req_num(p, 'grade_b_kg'); d := app.req_num(p, 'grade_c_kg');
        e := app.req_num(p, 'reject_kg'); s := app.req_num(p, 'loss_kg');
        if not app.approx_eq(v_in, a + b + d + e + s) then
          raise exception 'grading: A + B + C + reject + loss (%) must equal input (%)', a + b + d + e + s, v_in using errcode = '23514'; end if;
        v_out := a + b + d;
        c := jsonb_build_object('grade_split', jsonb_build_object('A', a, 'B', b, 'C', d), 'reject_kg', e, 'loss_kg', s);
      end if;

    when 'drying' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'moisture_in_pct'); b := app.req_num(p, 'moisture_out_pct');
      v_out := app.req_num(p, 'output_kg');
      if b >= 100 or a >= 100 then raise exception 'moisture must be below 100%%' using errcode = '23514'; end if;
      e := v_in * (100 - a) / (100 - b);                              -- dry-matter expected output
      c := jsonb_build_object('expected_out_kg', round(e, 3), 'water_removed_kg', round(v_in - e, 3),
                              'grain_loss_kg', round(greatest(e - v_out, 0), 3));
      if v_out > e * 1.01 + app.kg_tolerance() then w := array_append(w, 'output exceeds dry-matter expectation'); end if;  -- 1% weighing noise
      if e - v_out > greatest(e * 0.02, app.kg_tolerance()) then w := array_append(w, 'grain loss beyond moisture removal'); end if;

    when 'popping' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg'); a := app.req_num(p, 'pop_rate_pct');
      c := jsonb_build_object('pop_rate_pct', a, 'weight_yield_pct', round(v_out / nullif(v_in, 0) * 100, 2));
      if a < app.opt_num(tol, 'pop_rate_min_pct', 80) then w := array_append(w, 'pop rate below threshold'); end if;

    when 'blanching' then
      v_in := app.req_num(p, 'input_kg'); v_out := app.req_num(p, 'output_kg');
      c := jsonb_build_object('water_uptake_kg', round(v_out - v_in, 3));   -- output > input is valid here

    when 'cleaning' then
      v_in := app.req_num(p, 'input_kg'); a := app.req_num(p, 'foreign_matter_kg'); d := app.req_num(p, 'loss_kg');
      v_out := v_in - a - d;
      if v_out < 0 then raise exception 'cleaning: foreign matter + loss exceed input' using errcode = '23514'; end if;
      c := jsonb_build_object('foreign_matter_kg', a, 'loss_kg', d);

    when 'warehouse' then
      -- migration 55 (C3): sent (taken from the lot) vs received; a reason for any difference; condition, bags, location
      a := app.req_num(p, 'declared_kg'); b := app.req_num(p, 'received_kg');
      if a <= 0 then raise exception 'warehouse: what was sent is more than 0 kg' using errcode = '23514'; end if;
      if b <= 0 then raise exception 'warehouse: what was received is more than 0 kg' using errcode = '23514'; end if;
      if b > a + app.kg_tolerance() then
        raise exception 'warehouse: the received weight (% kg) is more than was sent (% kg)', trim_scale(b), trim_scale(a) using errcode = '23514'; end if;
      d := a - b; v_pct := round(d / a * 100, 2);
      if d > app.kg_tolerance() and length(btrim(coalesce(p->>'discrepancy_reason', ''))) < 5 then
        raise exception 'warehouse: say why % kg less was received than sent (at least 5 characters)', trim_scale(round(d, 3)) using errcode = '23514'; end if;
      if coalesce(p->>'condition', '') not in ('good', 'damp', 'pest', 'mixed') then
        raise exception 'warehouse: the condition on arrival is good, damp, pest or mixed' using errcode = '23514'; end if;
      e := app.req_num(p, 'bags_in');
      if e < 1 or e <> trunc(e) then raise exception 'warehouse: the bags in are a whole number, 1 or more' using errcode = '23514'; end if;
      if length(btrim(coalesce(p->>'location', ''))) < 2 then
        raise exception 'warehouse: name the warehouse or location' using errcode = '23514'; end if;
      v_in := a; v_out := b;
      c := jsonb_build_object('discrepancy_kg', round(d, 3), 'discrepancy_pct', v_pct, 'condition', p->>'condition', 'bags_in', e,
                              'location', btrim(p->>'location')) || case when nullif(btrim(p->>'stack'), '') is not null
                              then jsonb_build_object('stack', btrim(p->>'stack')) else '{}'::jsonb end;
      if v_pct > app.opt_num(v_crop.thresholds, 'warehouse_discrepancy_pct', 2) then
        w := array_append(w, format('the warehouse received %s kg (%s %%) less than was sent: flagged for the manager', trim_scale(round(d, 1)), trim_scale(round(v_pct, 1))));
      end if;

    when 'cold_storage' then
      v_in := app.req_num(p, 'stored_kg'); v_out := app.req_num(p, 'retrieved_kg');
      c := jsonb_build_object('spoilage_kg', round(v_in - v_out, 3));

    when 'packing' then
      v_in := app.req_num(p, 'input_kg');
      -- migration 50 (G1): the save gives the batch code (trigger footprints_a1_batch_code); the preview has none yet
      if coalesce(p->>'batch_code', '') = '' and f.id is not null then raise exception 'packing: batch_code is mandatory (QR link)' using errcode = '23514'; end if;
      if not (p ? 'packets' and jsonb_typeof(p->'packets') = 'array' and jsonb_array_length(p->'packets') > 0) then
        raise exception 'packing: payload.packets [{units,size_kg}] is required' using errcode = '23514'; end if;
      select coalesce(sum(app.req_num(x, 'units') * app.req_num(x, 'size_kg')), 0) into v_out from jsonb_array_elements(p->'packets') x;
      -- migration 53 (C6): packs from the client's pack list (each keeps its own size), the packing unit from the list;
      -- the wastage worked out (a record of before typed it); above 2 % (the crop's packing_wastage_pct) a reason
      for pk in select * from jsonb_array_elements(p->'packets') loop
        v_mat := null;                                                                                   -- migration 61
        if nullif(pk->>'sku_id', '') is not null then
          select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id' and k.client_id = p_scope.client_id and k.active;
          if v_sku.id is null then raise exception 'packing: a pack is not on the client''s pack list' using errcode = '23514'; end if;
          if abs(app.req_num(pk, 'size_kg') - case v_sku.unit when 'g' then v_sku.size / 1000 else v_sku.size end) > 0.0005 then
            raise exception 'packing: a pack from the list keeps its own size (% %)', v_sku.size, v_sku.unit using errcode = '23514'; end if;
          if app.req_num(pk, 'units') < 1 or app.req_num(pk, 'units') <> trunc(app.req_num(pk, 'units')) then
            raise exception 'packing: the number of packs is a whole number, 1 or more' using errcode = '23514'; end if;
          v_mat := v_sku.material;                                                                       -- migration 61
        elsif p_scope.stage_details_required then
          raise exception 'packing: choose the packs from the client''s pack list' using errcode = '23514';
        end if;
        -- migration 61 (E2.4): a pack's best-before date is the packed date + the shelf life the State Manager set for the
        -- crop and the pack's material. Migration 61c (Veda, 20 Oct 2026: "DONT MAKE THIS MANDATORY"): without one
        -- Packing goes ahead, with a warning on the record; those packs carry no best-before date
        if app.shelf_life_for(p_scope.crop_id, v_mat) is null then
          v_ser_txt := case when v_mat is null then 'no shelf life is set for this crop: these packs carry no best-before date (the State Manager sets it)'
                            else format('no shelf life is set for this crop and pack material (%s): these packs carry no best-before date (the State Manager sets it)', v_mat) end;
          if not (v_ser_txt = any(w)) then w := array_append(w, v_ser_txt); end if;
        end if;
      end loop;
      if nullif(p->>'packing_unit_id', '') is not null then
        select * into v_pu from public.packing_units u where u.id::text = p->>'packing_unit_id' and u.client_id = p_scope.client_id and u.active;
        if v_pu.id is null then raise exception 'packing: the packing unit is not one of this client''s active units' using errcode = '23514'; end if;
      elsif p_scope.stage_details_required then
        raise exception 'packing: say where it was packed (a packing unit of the client)' using errcode = '23514';
      end if;
      if p ? 'wastage_kg' then
        d := app.req_num(p, 'wastage_kg');
        if not app.approx_eq(v_in, v_out + d) then
          raise exception 'packing: Σ packets (%) + wastage (%) must equal input (%)', v_out, d, v_in using errcode = '23514'; end if;
      else
        d := v_in - v_out;
        if d < -app.kg_tolerance() then
          raise exception 'packing: the packs (% kg) are more than the input (% kg)', v_out, v_in using errcode = '23514'; end if;
        d := greatest(d, 0);
      end if;
      v_lim := coalesce((v_crop.thresholds->>'packing_wastage_pct')::numeric, 2);
      if v_in > 0 and d / v_in * 100 > v_lim then
        if length(btrim(coalesce(p->>'wastage_reason', ''))) < 5 then
          raise exception 'packing: the wastage is % %% of the input (more than % %%): say why', round(d / v_in * 100, 1), v_lim using errcode = '23514'; end if;
        w := array_append(w, format('wastage %s %% is above %s %%: %s', round(d / v_in * 100, 1), v_lim, btrim(p->>'wastage_reason')));
      end if;
      c := jsonb_build_object('packed_kg', v_out, 'wastage_kg', round(d, 3), 'wastage_pct', round(d / nullif(v_in, 0) * 100, 2), 'batch_code', p->>'batch_code')
           || case when v_pu.id is not null then jsonb_build_object('packing_unit', v_pu.name) else '{}'::jsonb end;

    when 'qc' then
      v_in := app.req_num(p, 'qty_kg');
      -- migration 53 (C5): the sample drawn first (its quantity and lab come with it); the lab from the state's list; a
      -- lab test (the library says "lab") is read at an accredited external lab, never in-house
      if nullif(p->>'sample_ref', '') is not null then
        select * into v_smp from public.qc_samples sm where sm.id::text = p->>'sample_ref';
        if v_smp.id is null or v_smp.footprint_id is distinct from f.prev_footprint_id then
          raise exception 'qc: the sample is not one drawn from this lot' using errcode = '23514'; end if;
        if v_smp.status <> 'sent' and v_smp.qc_footprint_id is distinct from f.id then
          raise exception 'qc: the results of sample % are in already (or it was disposed of)', v_smp.code using errcode = '23514'; end if;
        a := v_smp.qty_kg;
        if v_smp.lab_id is not null then select * into v_lab from public.labs l where l.id = v_smp.lab_id; end if;
      else
        if p_scope.stage_details_required then
          raise exception 'qc: choose the sample drawn from this lot (draw it first: it goes to the lab)' using errcode = '23514'; end if;
        a := app.req_num(p, 'sample_qty_kg');
      end if;
      if v_lab.id is null and nullif(p->>'lab_id', '') is not null then
        select * into v_lab from public.labs l where l.id::text = p->>'lab_id' and app.lab_for_scope(l.id, p_scope.id);   -- migration 54
        if v_lab.id is null then raise exception 'qc: the lab is not on this state''s or this client''s list' using errcode = '23514'; end if;
      end if;
      v_labname := coalesce(v_lab.name, nullif(btrim(p->>'lab_name'), ''));
      if p ? 'readings' and jsonb_typeof(p->'readings') = 'object' then
        select string_agg(distinct coalesce(lb.name, la.name), ', ') into v_labtests
          from jsonb_each(p->'readings') r
          join public.quality_param_library la on la.param = r.key
          left join public.quality_param_library lb on lb.param = la.alias_of
         where coalesce(lb.done_by, la.done_by) = 'lab' and nullif(btrim(r.value #>> '{}'), '') is not null;
        if v_labtests is not null and (v_lab.kind = 'in_house' or (v_lab.id is null and p_scope.stage_details_required)) then
          raise exception 'qc: % is a lab test: it is read at an accredited external lab', v_labtests using errcode = '23514'; end if;
      end if;
      if a >= v_in then raise exception 'qc: sample must be smaller than the lot' using errcode = '23514'; end if;
      if not (p ? 'readings' and jsonb_typeof(p->'readings') = 'object') then
        raise exception 'qc: payload.readings {param: value} is required' using errcode = '23514'; end if;
      v_out := v_in - a;                                              -- sample consumed in testing (rule 7)
      c := jsonb_build_object('sample_qty_kg', a, 'forwarding_kg', v_out);
      if v_smp.id is not null then c := c || jsonb_build_object('sample_code', v_smp.code); end if;                 -- migration 53
      if v_lab.id is not null then c := c || jsonb_build_object('lab', v_lab.name, 'lab_kind', v_lab.kind); end if;
      -- migration 50 (C5): the scope asks for the lab report (the default): the lab, its number and date; the file comes
      -- before verification. The date: not ahead of today, not before the lot existed. A number once per lab, unless
      -- the lots share the sample.
      if p_scope.qc_report_required then
        if coalesce(v_labname, '') = '' or coalesce(btrim(p->>'report_no'), '') = '' or coalesce(p->>'report_date', '') = '' then
          raise exception 'qc: the lab, the report number and the report date are required' using errcode = '23514'; end if;
        begin v_rdate := (p->>'report_date')::date; exception when others then
          raise exception 'qc: the report date is a date' using errcode = '23514'; end;
        if v_rdate > (now() at time zone 'Asia/Kolkata')::date then
          raise exception 'qc: the report date (%) is in the future', to_char(v_rdate, 'DD Mon YYYY') using errcode = '23514'; end if;
        v_on := coalesce(prev.happened_on, (coalesce(prev.captured_at, prev.created_at) at time zone 'Asia/Kolkata')::date);
        if prev.id is not null and v_rdate < v_on then
          raise exception 'qc: the report date (%) is before the lot it tests (% on %)', to_char(v_rdate, 'DD Mon YYYY'), prev.footprint_code, to_char(v_on, 'DD Mon YYYY')
            using errcode = '23514'; end if;
        v_taken := app.report_no_taken(v_labname, p->>'report_no', p->>'sample_id', f.id);
        if v_taken is not null then
          raise exception 'qc: report % of this lab is on % already (the same report twice needs the same sample ID)', btrim(p->>'report_no'), v_taken
            using errcode = '23505'; end if;
        c := c || jsonb_build_object('lab_name', v_labname, 'report_no', btrim(p->>'report_no'), 'report_date', v_rdate);
      end if;

    when 'commercial' then
      if p ? 'client_order_id' then                                                       -- migration 70 (D): a part of a client order
        p := app.order_part_payload(p, f, p_scope); f.payload := p; end if;
      if p ? 'buyer_id' or p ? 'packs' or p ? 'order_no' or p_scope.stage_details_required then
        -- migration 54 (C7): the buyer from the client's list; the market, and for export its profile and the destination
        -- (the batch passed QC for that profile, or carries the client's written acceptance); the order number; packs by
        -- type where the batch was packed from the pack list (no more than are left), else the kilograms
        if coalesce(p->>'market', '') not in ('domestic','export') then
          raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
        if nullif(p->>'buyer_id', '') is not null then
          select * into v_buyer from public.buyers b where b.id::text = p->>'buyer_id' and b.client_id = p_scope.client_id and b.active;
          if v_buyer.id is null then raise exception 'commercial: the buyer is not one of this client''s active buyers' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required or coalesce(btrim(p->>'buyer'), '') = '' then
          raise exception 'commercial: choose the buyer from the client''s list' using errcode = '23514';
        end if;
        if length(btrim(coalesce(p->>'order_no', ''))) < 2 then
          raise exception 'commercial: give the order or contract number' using errcode = '23514'; end if;
        if p->>'market' = 'export' then
          select * into v_prof from public.market_profiles m where m.crop_id = p_scope.crop_id and m.status = 'active'
             and m.code = p->>'market_code' and m.code <> 'domestic' and m.code = any (p_scope.market_codes);
          if v_prof.id is null then
            raise exception 'commercial: choose the export market (one of this scope''s market profiles)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'destination_country', ''))) < 2 then
            raise exception 'commercial: name the destination country' using errcode = '23514'; end if;
          if not app.profile_allowed(f.prev_footprint_id, v_prof.code) then
            raise exception 'commercial: this batch has not passed QC for % (nor carries the client''s written acceptance)', v_prof.name using errcode = '23514'; end if;
        end if;
        if p ? 'sale_route' and p->>'sale_route' not in ('own_brand', 'white_label', 'bulk', 'prasaadam') then
          raise exception 'commercial: the sale route is own brand, white label, bulk or Prasaadam' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'packing' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'commercial');
          v_in := (v_pl->>'kg')::numeric;
          v_units := app.allocate_units(f.id, prev.id, v_pl->'lines', p->'cartons');                    -- migration 58: what it sets aside
        else
          v_in := app.req_num(p, 'qty_kg');
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', p->>'market', 'buyer', coalesce(v_buyer.name, btrim(p->>'buyer')), 'order_no', btrim(p->>'order_no'))
             || case when v_buyer.id is not null then jsonb_build_object('buyer_id', v_buyer.id, 'buyer_country', v_buyer.country) else '{}'::jsonb end
             || case when v_prof.id is not null then jsonb_build_object('market_code', v_prof.code, 'market_name', v_prof.name,
                                                                      'destination_country', btrim(p->>'destination_country')) else '{}'::jsonb end
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_units is not null then jsonb_build_object('units', v_units) else '{}'::jsonb end   -- migration 58
             || case when p ? 'sale_route' then jsonb_build_object('sale_route', p->>'sale_route') else '{}'::jsonb end
             || case when p ? 'client_order_id' then jsonb_build_object('client_order_id', p->>'client_order_id',   -- migration 70
                       'client_order', (select o.code from public.client_orders o where o.id::text = p->>'client_order_id')) else '{}'::jsonb end;
      else
      v_in := app.req_num(p, 'qty_kg'); v_out := v_in;
      if coalesce(p->>'buyer', '') = '' then raise exception 'commercial: buyer is required' using errcode = '23514'; end if;
      if coalesce(p->>'market', '') not in ('domestic','export') then
        raise exception 'commercial: market must be domestic or export' using errcode = '23514'; end if;
      if p->>'market' = 'export' and not app.export_allowed(f.prev_footprint_id) then
        raise exception 'commercial: export sale requires export PASS or a client-level override' using errcode = '23514'; end if;
      c := jsonb_build_object('market', p->>'market', 'buyer', p->>'buyer');
      end if;                                                                           -- migration 54

    when 'shipment' then
      if prev.stage_type = 'commercial' and nullif(prev.computed->>'client_order_id', '') is not null then   -- migration 70 (D): the order's invoice
        p := app.order_shipment_payload(p, prev, p_scope); f.payload := p; end if;
      -- migration 62 (E2.1): a packed lot is shipped by its codes whatever the scope's details setting; the papers are
      -- asked where they were before (the details asked, or the form gave the packs or the invoice)
      v_papers := p ? 'packs' or p ? 'invoice_no' or p_scope.stage_details_required;
      v_packed := exists (select 1 from public.packs pq where pq.footprint_id in (select app.lot_packings(prev.id)) and pq.status = 'packed');
      if v_papers or v_packed then
        -- migration 54 (C8): the packs of one order (partial shipments: no more than are left of it); for export the pack
        -- codes scanned while loading, and the order's export documents complete; the papers of the market, their formats
        v_mkt := coalesce(prev.computed->>'market', prev.payload->>'market', 'domestic');
        if v_papers and length(btrim(coalesce(p->>'invoice_no', ''))) < 2 then
          raise exception 'shipment: give the invoice number' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'commercial' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'shipment');
          v_in := (v_pl->>'kg')::numeric;
        else
          v_in := app.req_num(p, 'shipped_kg');
        end if;
        if not v_papers then null;                                                                       -- migration 62
        elsif v_mkt = 'export' then
          if not app.container_ok(p->>'container_no') then
            raise exception 'shipment: the container number is 4 letters and 7 digits (e.g. MSKU1234567)' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'seal_no', ''))) < 3 then
            raise exception 'shipment: give the container seal number' using errcode = '23514'; end if;
          if btrim(coalesce(p->>'shipping_bill_no', '')) !~ '^[0-9]{6,8}$' then
            raise exception 'shipment: the shipping bill number is 6 to 8 digits' using errcode = '23514'; end if;
          if nullif(btrim(p->>'bl_no'), '') is not null and btrim(p->>'bl_no') !~ '^[A-Za-z0-9/-]{4,30}$' then
            raise exception 'shipment: a bill of lading number is 4 to 30 letters or digits' using errcode = '23514'; end if;
          select string_agg(x->>'doc', ', ') into v_ser_txt from jsonb_array_elements(app.export_docs_of(prev.id)) x where not (x->>'done')::boolean;
          if v_ser_txt is not null then
            raise exception 'shipment: the export documents of order % are not complete (%): attach their files at Commercial first', prev.footprint_code, v_ser_txt
              using errcode = '23514'; end if;
        else
          if not app.vehicle_ok(p->>'vehicle_no') then
            raise exception 'shipment: the vehicle number reads like UP53AB1234' using errcode = '23514'; end if;
          if length(btrim(coalesce(p->>'lr_no', ''))) < 2 then
            raise exception 'shipment: give the LR (lorry receipt) number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'driver_phone'), '') is not null and regexp_replace(p->>'driver_phone', '[^0-9]', '', 'g') !~ '^(91)?[6-9][0-9]{9}$' then
            raise exception 'shipment: the driver''s phone is a 10-digit mobile number' using errcode = '23514'; end if;
          if nullif(btrim(p->>'eway_bill_no'), '') is not null and regexp_replace(p->>'eway_bill_no', '\s', '', 'g') !~ '^[0-9]{12}$' then
            raise exception 'shipment: an e-way bill number is 12 digits' using errcode = '23514'; end if;
        end if;
        -- migration 57: the codes of the packs loaded, for a domestic shipment too; migration 58: a carton's code stands
        -- for its packs, and every check is on sets (1 lakh packs stay quick)
        if v_pl is not null or v_packed then                                                             -- migration 62
          select array_agg(upper(btrim(x))) into v_ser from jsonb_array_elements_text(case when jsonb_typeof(p->'serials') = 'array' then p->'serials' else '[]'::jsonb end) x where btrim(x) <> '';
          if coalesce(cardinality(v_ser), 0) = 0 then
            raise exception 'shipment: scan or type the codes of the packs loaded' using errcode = '23514'; end if;
          if cardinality(v_ser) <> (select count(distinct sr) from unnest(v_ser) sr) then
            raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;
          select string_agg(code, ', '), count(*) into v_ser_txt, v_ncart
            from (select ct.code from public.cartons ct where ct.code in (select unnest(v_ser)) and ct.status <> 'packed' order by ct.code limit 10) z;
          if v_ser_txt is not null then
            raise exception 'shipment: carton % was opened: scan its packs one by one', v_ser_txt using errcode = '23514'; end if;
          select count(*) into v_ncart from public.cartons ct where ct.code in (select unnest(v_ser));
          select array_agg(cs) into v_packs from (
            select pq.serial as cs from public.cartons ct join public.packs pq on pq.carton_code = ct.code and pq.status = 'packed'
             where ct.code in (select unnest(v_ser))
            union all
            select sr from unnest(v_ser) sr where sr not in (select ct.code from public.cartons ct where ct.code in (select unnest(v_ser)))) e;
          if cardinality(v_packs) <> (select count(distinct x) from unnest(v_packs) x) then
            raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;      -- a pack and its carton
          select string_agg(sr, ', ') into v_ser_txt from (select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr
             where sr not in (select pq.serial from public.packs pq where pq.footprint_id in (select app.lot_packings(prev.id)) and pq.status = 'packed') order by 1 limit 10) z;   -- migration 62: the lot's batch
          if v_ser_txt is not null then
            raise exception 'shipment: % not a pack of this order''s batch (or void)', v_ser_txt using errcode = '23514'; end if;
          select string_agg(sr, ', ') into v_ser_txt from (
            with others as (select x as code from public.footprints o,
                                   jsonb_array_elements_text(case when jsonb_typeof(o.payload->'serials') = 'array' then o.payload->'serials' else '[]'::jsonb end) x
                             where o.stage_type = 'shipment' and o.scope_id = f.scope_id and o.id <> f.id and o.status not in ('superseded', 'legacy')),
                 shipped as (select upper(code) as cs from others union all select pq.serial from others oo join public.packs pq on pq.carton_code = upper(oo.code))
            select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr where sr in (select cs from shipped) order by 1 limit 10) z;
          if v_ser_txt is not null then
            raise exception 'shipment: % shipped already', v_ser_txt using errcode = '23514'; end if;
          if jsonb_typeof(prev.computed->'units') = 'array' then                                       -- the order set them aside
            select string_agg(sr, ', ') into v_ser_txt from (
              with u as (select x from jsonb_array_elements(prev.computed->'units') x),
                   alloc as (select x->>'code' as cs from u union all select pq.serial from u join public.packs pq on pq.carton_code = u.x->>'code' where u.x->>'kind' = 'carton')
              select distinct coalesce(sc.ct, sr) as sr from unnest(v_packs) sr left join (select pq.serial, pq.carton_code as ct from public.packs pq where pq.carton_code = any (v_ser)) sc on sc.serial = sr
               where sr not in (select cs from alloc)
                 and (select pq.sku_id from public.packs pq where pq.serial = sr) in (select (x->>'sku_id')::uuid from u)
               order by 1 limit 10) z;
            if v_ser_txt is not null then
              raise exception 'shipment: % not set aside for this order', v_ser_txt using errcode = '23514'; end if;
          end if;
          select string_agg(x->>'name', ', ') into v_ser_txt from jsonb_array_elements(v_pl->'lines') x
           where (x->>'units')::numeric <> (select count(*) from unnest(v_packs) sr join public.packs pq on pq.serial = sr where pq.sku_id::text = x->>'sku_id');
          if v_ser_txt is not null or cardinality(v_packs) <> (select sum((x->>'units')::numeric) from jsonb_array_elements(v_pl->'lines') x) then
            raise exception 'shipment: the codes scanned do not match the packs shipped (%)', coalesce(v_ser_txt, 'other pack types') using errcode = '23514'; end if;
          -- migration 62: an order by kilograms: the packs loaded weigh what is shipped
          if v_pl is null then
            d := (select coalesce(sum(pq.size_kg), 0) from unnest(v_packs) sr join public.packs pq on pq.serial = sr);
            if abs(d - v_in) > greatest(app.kg_tolerance(), 0.001) then
              raise exception 'shipment: the packs loaded weigh % kg, the shipment % kg', trim_scale(round(d, 3)), trim_scale(round(v_in, 3)) using errcode = '23514'; end if;
          end if;
        end if;
        -- migration 62: a scope without the details keeps its transit loss, as before
        v_out := v_in - case when v_papers then 0 else app.opt_num(p, 'transit_loss_kg', 0) end;
        if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
        c := jsonb_build_object('market', v_mkt, 'invoice_no', btrim(p->>'invoice_no'))
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_ser is not null then jsonb_build_object('serials_count', cardinality(v_packs)) else '{}'::jsonb end   -- 58: packs
             || case when coalesce(v_ncart, 0) > 0 then jsonb_build_object('cartons_count', v_ncart) else '{}'::jsonb end           -- migration 58
             || case when v_mkt = 'export' then jsonb_build_object('container_no', upper(regexp_replace(p->>'container_no', '[\s-]', '', 'g')),
                       'bl_pending', nullif(btrim(p->>'bl_no'), '') is null) else '{}'::jsonb end;
        if not v_papers then c := c || jsonb_build_object('transit_loss_kg', app.opt_num(p, 'transit_loss_kg', 0)); end if;   -- migration 62
      else
      v_in := app.req_num(p, 'shipped_kg'); d := app.opt_num(p, 'transit_loss_kg', 0);
      v_out := v_in - d;
      if v_out < 0 then raise exception 'shipment: transit loss exceeds shipped quantity' using errcode = '23514'; end if;
      c := jsonb_build_object('transit_loss_kg', d);
      end if;                                                                           -- migration 54

    when 'qr_activation' then
      if prev.id is null then raise exception 'qr_activation needs a predecessor' using errcode = '23514'; end if;
      v_in := app.available_qty(prev.id); v_out := v_in;              -- takes whatever remains of the final lot
      if v_in <= 0 then raise exception 'qr_activation: final quantity must be recorded and positive' using errcode = '23514'; end if;
      c := jsonb_build_object('final_kg', v_in);

    else
      raise exception 'no reconciliation rule for stage %', f.stage_type using errcode = '23514';
  end case;

  -- Rule 3: output never exceeds input, except blanching.
  if v_out > v_in + app.kg_tolerance() and f.stage_type <> 'blanching' then
    raise exception '% : output (%) exceeds input (%)', f.stage_type, v_out, v_in using errcode = '23514';
  end if;

  f.qty_in := round(v_in, 3); f.qty_out := round(v_out, 3); f.computed := c; f.warnings := w;
  return f;
end $function$;

-- item 67 (1): an older QC record keeps its lab in "Lab reference": shown when it names no lab of the list
CREATE OR REPLACE FUNCTION app.cv_scope_data(p_scope uuid, p_internal boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with s as (select * from public.scopes where id = p_scope),
  live as (select f.* from public.footprints f where f.scope_id = p_scope and f.status not in ('superseded', 'legacy')
             and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  seals as (select q.*, f.footprint_code from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope),
  bat as (select p.batch_code, count(*) filter (where p.status <> 'void') as packs, coalesce(sum(p.size_kg) filter (where p.status <> 'void'), 0) as kg,
                 min(p.best_before) filter (where p.status <> 'void') as best_before, min(p.packed_on) as packed_on
            from public.packs p where p.scope_id = p_scope group by p.batch_code)
  select jsonb_build_object(
    'head', app.export_scope_head(p_scope) || jsonb_build_object('scope_id', p_scope, 'label', app.cv_scope_label(p_scope),
              'delivery_model', (select delivery_model from s), 'markets', to_jsonb((select market_codes from s)),
              'gi_user_no', (select gi_user_no from s), 'chain', to_jsonb((select chain from s))),
    'figures', app.cv_scope_figures(p_scope),
    'pipeline', coalesce((select jsonb_agg(jsonb_build_object('stage', c.st, 'pos', c.i,
                   'records', (select count(*) from live l where l.stage_type = c.st),
                   'pending', (select count(*) from live l where l.stage_type = c.st and l.status = 'pending'),
                   'verified', (select count(*) from live l where l.stage_type = c.st and l.status = 'verified'),
                   'kg_out', coalesce((select sum(l.qty_out) from live l where l.stage_type = c.st and l.status = 'verified' and not l.split_into_grades), 0),
                   'kg_waiting', coalesce((select sum(app.available_qty(l.id)) from live l
                                            where l.stage_type = c.st and l.status = 'verified' and not l.lot_closed and not l.split_into_grades), 0))
                   order by c.i) from s cross join unnest(s.chain) with ordinality c(st, i)), '[]'::jsonb),
    'lots', coalesce((select jsonb_agg(jsonb_build_object('lot', q.footprint_code, 'qr_code', q.qr_code, 'sealed_at', q.sealed_at,
                   'batches', array_to_string(q.batch_codes, ', '), 'release', app.release_status(q.footprint_id) ->> 'status',
                   'packs_live', (select count(*) from app.lot_released_packs(q.footprint_id)))
                   order by q.sealed_at desc) from seals q), '[]'::jsonb),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packs', b.packs, 'kg', b.kg, 'packed_on', b.packed_on,
                   'best_before', b.best_before, 'released', coalesce(ps.released, 0) + coalesce(ps.old_data, 0), 'held', coalesce(ps.held, 0),
                   'void', coalesce(ps.void, 0)) order by b.batch_code)
                   from bat b left join app.scope_pack_states(p_scope) ps on ps.batch_code = b.batch_code), '[]'::jsonb),
    'qc', coalesce((select jsonb_agg(jsonb_build_object('code', l.footprint_code, 'status', l.status, 'tested_on', coalesce(l.happened_on, l.created_at::date),
                   'lab', coalesce((select name from public.labs where id::text = l.payload->>'lab_id'), l.payload->>'lab_name', nullif(btrim(l.payload->>'lab_ref'), '')),
                   'report_no', l.payload->>'report_no', 'report_date', l.payload->>'report_date',
                   'domestic', case when 'domestic' = any (s.market_codes) then v.domestic_verdict::text end,
                   'export', case when 'export' = any (s.market_codes) then v.export_verdict::text end,
                   'accepted', exists (select 1 from public.attachments a where a.footprint_id = l.id and a.label = 'acceptance'),
                   'decided', v.override is not null) order by l.created_at)
                   from live l cross join s left join public.qc_verdicts v on v.footprint_id = l.id where l.stage_type = 'qc'), '[]'::jsonb),
    'documents', coalesce((select jsonb_agg(d order by d->>'kind', d->>'what') from (
                   select jsonb_build_object('kind', 'export_doc', 'what', e.doc, 'status', e.status, 'record', f.footprint_code,
                            'on_file', e.attachment_id is not null, 'at', e.set_at) as d
                     from public.export_documents e join public.footprints f on f.id = e.footprint_id where e.scope_id = p_scope
                   union all
                   select jsonb_build_object('kind', 'lab_report', 'what', coalesce(l.payload->>'report_no', l.footprint_code), 'status', l.status,
                            'record', l.footprint_code, 'on_file', exists (select 1 from public.attachments a where a.footprint_id = l.id),
                            'at', l.created_at)
                     from live l where l.stage_type = 'qc'
                   union all
                   select jsonb_build_object('kind', 'gi_user', 'what', s.gi_user_no, 'status', 'recorded', 'record', null,
                            'on_file', s.gi_user_file is not null, 'at', null)
                     from s where s.gi_user_no is not null) x), '[]'::jsonb),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
                   'issued_at', r.issued_at) order by r.issued_at desc) from public.reports r where r.scope_id = p_scope), '[]'::jsonb),
    -- the people on each stage: name and role only (never a phone, an email or an HR fact)
    'people', coalesce((select jsonb_agg(jsonb_build_object('stage', sa.stage_type, 'name', u.display_name, 'client_staff', u.external)
                   order by array_position((select chain from s), sa.stage_type), u.display_name)
                   from public.slot_assignments sa join public.assignments a on a.id = sa.assignment_id join public.app_users u on u.id = sa.user_id
                  where sa.scope_id = p_scope and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'), '[]'::jsonb),
    'internal', p_internal)
$function$;

-- D: across scopes lists the client orders (each with its parts in the scopes the reader reaches); an order's part names its order
CREATE OR REPLACE FUNCTION app.cv_across_data(p_client uuid, p_internal boolean)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with sc as (select id from app.cv_scopes(p_client) id),
  live as (select f.* from public.footprints f where f.scope_id in (select id from sc) and f.status not in ('superseded', 'legacy')
             and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ord as (select o.*, coalesce((select b.name from public.buyers b where b.id::text = o.payload->>'buyer_id'), o.payload->>'buyer') as buyer_name,
                 coalesce((select sum(x.qty_out) from live x where x.stage_type = 'shipment' and x.status = 'verified'
                            and (x.prev_footprint_id = o.id or exists (select 1 from public.footprint_links k where k.child_id = x.id and k.parent_id = o.id))), 0) as shipped
            from live o where o.stage_type = 'commercial'),
  seals as (select q.footprint_id as seal_id, q.qr_code, f.scope_id from public.qr_seals q join public.footprints f on f.id = q.footprint_id
             where f.scope_id in (select id from sc)),
  sx as (select x.* from public.scans x
          where (x.kind = 'pack' and exists (select 1 from public.packs p where p.serial = x.code and p.scope_id in (select id from sc)))
             or (x.kind = 'lot' and exists (select 1 from seals q where q.qr_code = x.code)))
  select jsonb_build_object(
    'client_orders', coalesce((select jsonb_agg(jsonb_build_object('id', co.id, 'code', co.code, 'order_no', co.order_no,   -- migration 70 (D)
                   'buyer', (select b.name from public.buyers b where b.id = co.buyer_id), 'market', co.market_code,
                   'destination_country', co.destination_country, 'invoice_no', co.invoice_no, 'status', co.status,
                   'scopes', (select count(distinct o.scope_id) from ord o where o.computed->>'client_order_id' = co.id::text),
                   'parts', (select count(*) from ord o where o.computed->>'client_order_id' = co.id::text),
                   'qty_kg', (select coalesce(sum(o.qty_out), 0) from ord o where o.computed->>'client_order_id' = co.id::text),
                   'shipped_kg', (select coalesce(sum(o.shipped), 0) from ord o where o.computed->>'client_order_id' = co.id::text),
                   'created_at', co.created_at) order by co.created_at desc)
                 from public.client_orders co where co.client_id = p_client
                  and exists (select 1 from ord o where o.computed->>'client_order_id' = co.id::text)), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('code', o.footprint_code, 'scope_id', o.scope_id, 'scope', app.cv_scope_label(o.scope_id),
                   'client_order', o.computed->>'client_order',                                                    -- migration 70
                   'on', coalesce(o.happened_on, o.created_at::date), 'buyer', o.buyer_name, 'market', o.payload->>'market',
                   'destination_country', o.payload->>'destination_country', 'order_no', o.payload->>'order_no', 'qty_kg', o.qty_out,
                   'shipped_kg', o.shipped, 'status', o.status)
                 || case when p_internal then jsonb_build_object(
                   'price_per_kg', coalesce(st.price_per_kg, (o.payload->>'price_per_kg')::numeric),
                   'currency', coalesce(st.currency, o.payload->>'currency'),
                   'total_value', coalesce(st.total_value, round(o.qty_out * (o.payload->>'price_per_kg')::numeric, 2))) else '{}'::jsonb end
                 order by o.created_at desc)
                 from ord o left join public.sale_terms st on st.footprint_id = o.id), '[]'::jsonb),
    'buyers', coalesce((select jsonb_agg(jsonb_build_object('buyer', b.buyer, 'orders', b.n, 'qty_kg', b.kg, 'shipped_kg', b.sh) order by b.kg desc, b.buyer)
                 from (select coalesce(buyer_name, '—') as buyer, count(*) as n, coalesce(sum(qty_out), 0) as kg, coalesce(sum(shipped), 0) as sh
                         from ord group by coalesce(buyer_name, '—')) b), '[]'::jsonb),
    'scans_by_city', coalesce((select jsonb_agg(jsonb_build_object('city', c.city, 'region', c.region, 'country', c.country, 'scans', c.n, 'last_at', c.last_at)
                 order by c.n desc, c.city) from (select city, region, country, count(*) as n, max(at) as last_at from sx group by city, region, country) c), '[]'::jsonb),
    'copy_flags', coalesce((select jsonb_agg(jsonb_build_object('serial', g.serial, 'kind', g.kind, 'status', g.status, 'raised_at', g.raised_at,
                 'scope', app.cv_scope_label(g.scope_id)) order by g.raised_at desc)
                 from public.scan_flags g where g.scope_id in (select id from sc)), '[]'::jsonb),
    'recalls', coalesce((select jsonb_agg(jsonb_build_object('qr_code', q.qr_code, 'scope', app.cv_scope_label(q.scope_id), 'status', e.status,
                 'reason', e.reason, 'at', e.at) order by e.at desc)
                 from seals q join lateral (select * from public.release_events e where e.seal_id = q.seal_id order by e.seq desc limit 1) e on true
                where e.status in ('recalled', 'under_investigation')), '[]'::jsonb),
    'outputs', coalesce((select jsonb_agg(jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
                 'issued_at', r.issued_at, 'scope', app.cv_scope_label(r.scope_id)) order by r.issued_at desc)
                 from public.reports r where r.scope_id in (select id from sc)), '[]'::jsonb),
    'internal', p_internal)
$function$;

-- D: the export of across scopes: the client orders, and each order's part names its order
CREATE OR REPLACE FUNCTION app.export_client_view(p_view text, p_client uuid DEFAULT NULL::uuid, p_scope uuid DEFAULT NULL::uuid, p_copy text DEFAULT 'shareable'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_int boolean; v_client uuid; d jsonb; tabs jsonb; v_target uuid; v_rows int;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  if p_view is null or p_view not in ('portfolio', 'scope', 'farmers', 'across') then
    raise exception 'a view is the portfolio, one scope, the farmers or across scopes' using errcode = '22023'; end if;
  if p_view = 'scope' then
    if p_scope is null or not app.cv_may_scope(p_scope) then raise exception 'not allowed to export this scope' using errcode = '42501'; end if;
    v_client := (select client_id from public.scopes where id = p_scope); v_target := p_scope;
    v_int := p_copy = 'internal';
    if v_int and not app.cv_internal_scope(p_scope) then
      raise exception 'the internal copy is for the people of this scope, the client''s owner and the viewers it allowed: take the shareable copy'
        using errcode = '42501'; end if;
  else
    if p_client is null or not app.cv_may_client(p_client) then raise exception 'not allowed to export this client''s views' using errcode = '42501'; end if;
    v_client := p_client; v_target := p_client;
    v_int := p_copy = 'internal';
    if v_int and not app.cv_internal_client(p_client) then
      raise exception 'the internal copy is for the people of this client, its owner and the viewers it allowed: take the shareable copy'
        using errcode = '42501'; end if;
  end if;

  if p_view = 'portfolio' then
    d := app.cv_portfolio_data(p_client);
    tabs := jsonb_build_array(
      app.cv_table('scopes', d->'scopes', array['state', 'crop', 'season', 'place', 'status', 'delivery_model'] || app.cv_figure_cols()),
      app.cv_table('groups', d->'groups', array['state', 'crop', 'scopes'] || app.cv_figure_cols()),
      app.cv_table('total', jsonb_build_array(d->'total'), array['scopes'] || app.cv_figure_cols()));
  elsif p_view = 'scope' then
    d := app.cv_scope_data(p_scope, v_int);
    tabs := jsonb_build_array(
      app.cv_table('pipeline', d->'pipeline', array['pos', 'stage', 'records', 'pending', 'verified', 'kg_out', 'kg_waiting']),
      app.cv_table('lots', d->'lots', array['lot', 'qr_code', 'sealed_at', 'batches', 'release', 'packs_live']),
      app.cv_table('batches', d->'batches', array['batch_code', 'packs', 'kg', 'packed_on', 'best_before', 'released', 'held', 'void']),
      app.cv_table('qc', d->'qc', array['code', 'status', 'tested_on', 'lab', 'report_no', 'report_date', 'domestic', 'export', 'accepted', 'decided']),
      app.cv_table('documents', d->'documents', array['kind', 'what', 'status', 'record', 'on_file', 'at']),
      app.cv_table('reports', d->'reports', array['ref', 'kind', 'final', 'version', 'status', 'issued_at']),
      app.cv_table('people', d->'people', array['stage', 'name', 'client_staff']));
  elsif p_view = 'across' then
    d := app.cv_across_data(p_client, v_int);
    tabs := jsonb_build_array(
      app.cv_table('client_orders', d->'client_orders', array['code', 'order_no', 'buyer', 'market', 'destination_country', 'invoice_no', 'scopes', 'parts',
                                                             'qty_kg', 'shipped_kg', 'status']),                     -- migration 70 (D)
      app.cv_table('orders', d->'orders', array['code', 'client_order', 'scope', 'on', 'buyer', 'market', 'destination_country', 'order_no', 'qty_kg', 'shipped_kg', 'status']
                     || case when v_int then array['price_per_kg', 'currency', 'total_value'] else '{}'::text[] end),
      app.cv_table('buyers', d->'buyers', array['buyer', 'orders', 'qty_kg', 'shipped_kg']),
      app.cv_table('scans_by_city', d->'scans_by_city', array['city', 'region', 'country', 'scans', 'last_at']),
      app.cv_table('copy_flags', d->'copy_flags', array['serial', 'kind', 'status', 'raised_at', 'scope']),
      app.cv_table('recalls', d->'recalls', array['qr_code', 'scope', 'status', 'reason', 'at']),
      app.cv_table('outputs', d->'outputs', array['ref', 'kind', 'final', 'version', 'status', 'issued_at', 'scope']));
  else
    d := app.cv_farmers_data(p_client, v_int);
    tabs := jsonb_build_array(app.cv_table('farmers', d,
      case when v_int then array['farmer_code', 'name'] else array['farmer_code'] end
      || array['village', 'block', 'district', 'state', 'land_area_acres', 'gi_land_acres', 'status']));
  end if;

  select coalesce(sum(jsonb_array_length(x->'rows')), 0) into v_rows from jsonb_array_elements(tabs) x;
  perform app.audit('export_downloaded', v_target, jsonb_build_object('kind', 'client_view', 'view', p_view, 'copy', p_copy,
    'client_id', v_client, 'rows', v_rows), false);
  return jsonb_build_object('kind', 'client_view', 'view', p_view, 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'), 'generated_by', app.export_made_by(),
    'client', (select jsonb_build_object('name', c.name, 'code', c.code) from public.clients c where c.id = v_client),
    'scope', case when p_view = 'scope' then app.export_scope_head(p_scope) || jsonb_build_object('label', app.cv_scope_label(p_scope)) end,
    'units', case when p_view = 'scope' then app.param_units(p_scope) else '{}'::jsonb end,
    'tables', tabs);
end $function$;


-- 9 · grants --------------------------------------------------------------------------------------------------------------
revoke execute on function app.order_market_ok(uuid, text), app.order_gi_words(text, boolean), app.order_parts(uuid), app.order_shipments(uuid),
  app.order_part_payload(jsonb, public.footprints, public.scopes), app.order_shipment_payload(jsonb, public.footprints, public.scopes),
  app.may_make_order(uuid, uuid), app.next_client_order_code(uuid), app.order_reader(uuid), app.order_scope_seen(uuid),
  app.order_price_seen(uuid, uuid, uuid), app.order_head(public.client_orders)
  from public, anon, authenticated;
revoke execute on function app.client_order_choices(), app.client_order_new(uuid, uuid, uuid, text, text, text, text, text),
  app.client_order_invoice(uuid, text), app.client_order_cancel(uuid, text), app.client_orders_list(uuid), app.client_order_detail(uuid),
  app.client_orders_open_for(uuid, uuid), app.order_of_part(uuid) from public, anon;
grant execute on function app.client_order_choices(), app.client_order_new(uuid, uuid, uuid, text, text, text, text, text),
  app.client_order_invoice(uuid, text), app.client_order_cancel(uuid, text), app.client_orders_list(uuid), app.client_order_detail(uuid),
  app.client_orders_open_for(uuid, uuid), app.order_of_part(uuid) to authenticated;

-- the farmer register's possible duplicates: read inside the database only (found while checking this release)
revoke execute on function app.open_duplicates(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
