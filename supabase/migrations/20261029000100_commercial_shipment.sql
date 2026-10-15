-- GrainVeda MVP · migration 54 (Veda, 16 Oct 2026, "continue with release 54", decision G19, and her four points of the
-- same day): release 7 of the operator-stages plan. Villages from the list (a farmer's village is picked from the
-- places list before he is verified); the Collection Batch names its collection point and takes only that point's lots;
-- the client's own labs beside the state's; C7 Commercial (the buyer from the list, the market with its profile and the
-- destination, the order number, packs by type with what is left, price and terms kept apart, export documents with
-- their files) and C8 Shipment (packs of one order, partial shipments, the pack serials scanned for export, the
-- domestic and export papers with their formats, the loading photo, the bill of lading later); and the three faults
-- found in release 6's checks. Additive: nothing is deleted or rewritten; records already there keep their payloads and
-- are read as before. The new rules apply where the scope asks the stage details (migration 53).
select set_config('app.change_path', 'migration 54', true);

-- ---------------------------------------------------------------------------------------------------------------------
-- Labs: the client's own labs beside the state's (Veda, 16 Oct: "the labs details should be with us … labs can be more
-- than 1"). A lab with a client is kept by that client's Client Manager; one without, by the State Manager.
-- ---------------------------------------------------------------------------------------------------------------------
alter table public.labs add column if not exists client_id uuid references public.clients(id);
create index if not exists labs_client on public.labs (client_id) where client_id is not null;

create or replace function app.labs_client_state() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.client_id is not null and new.state_id is null then
    new.state_id := (select c.state_id from public.clients c where c.id = new.client_id);
  end if;
  if tg_op = 'UPDATE' and new.client_id is distinct from old.client_id then
    raise exception 'a lab stays with whoever keeps it (the state or the client)' using errcode = '42501'; end if;
  return new;
end $$;
drop trigger if exists labs_a0_client_state on public.labs;
create trigger labs_a0_client_state before insert or update on public.labs for each row execute function app.labs_client_state();

drop policy if exists labs_insert on public.labs;
create policy labs_insert on public.labs for insert to authenticated with check (
  (client_id is null and app.holds_op_role('state_supervisor'::op_role) and state_id = any (app.my_state_ids()))
  or (client_id is not null and app.runs_client(client_id)));
drop policy if exists labs_update on public.labs;
create policy labs_update on public.labs for update to authenticated
  using ((client_id is null and app.holds_op_role('state_supervisor'::op_role) and state_id = any (app.my_state_ids()))
         or (client_id is not null and app.runs_client(client_id)))
  with check ((client_id is null and state_id = any (app.my_state_ids())) or (client_id is not null and app.runs_client(client_id)));

-- A file may be registered as an export document (C7).
alter table public.attachments drop constraint if exists attachments_label_shape;
alter table public.attachments add constraint attachments_label_shape
  check (label is null or label = any (array['lab_report', 'acceptance', 'pod', 'loading_photo', 'document', 'export_doc']));

-- The labs a scope's QC may send to: the active labs of the scope's state, and the client's own.
create or replace function app.lab_for_scope(p_lab uuid, p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.labs l join public.scopes s on s.id = p_scope
                  where l.id = p_lab and l.active
                    and ((l.client_id is null and l.state_id = s.state_id) or l.client_id = s.client_id)) $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C7 Commercial: price and terms kept apart (as Procurement's payment, migration 52): never in the record, its ledger
-- block or any public or buyer view; read by who recorded it, the client's Client Manager and the admin.
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.sale_terms (
  footprint_id  uuid primary key references public.footprints(id),
  client_id     uuid not null references public.clients(id),
  scope_id      uuid not null references public.scopes(id),
  price_per_kg  numeric(12,2) check (price_per_kg is null or price_per_kg > 0),
  currency      text not null default 'INR' check (currency in ('INR', 'USD', 'EUR', 'GBP', 'AED', 'SAR', 'JPY', 'AUD')),
  incoterms     text check (incoterms is null or incoterms in ('EXW', 'FCA', 'FOB', 'CFR', 'CIF', 'CPT', 'CIP', 'DAP', 'DPU', 'DDP')),
  total_value   numeric(16,2),
  recorded_by   uuid references public.app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
alter table public.sale_terms enable row level security;
revoke all on public.sale_terms from anon, authenticated;
grant select on public.sale_terms to authenticated;
drop policy if exists sale_terms_read on public.sale_terms;
create policy sale_terms_read on public.sale_terms for select to authenticated using (app.reads_lot_payment(client_id, recorded_by));
drop trigger if exists zz_change_log on public.sale_terms;
create trigger zz_change_log after insert or update or delete on public.sale_terms for each row execute function app.log_change('sale_terms');

create or replace function app.footprints_take_sale_terms() returns trigger
language plpgsql security definer set search_path = public as $$
declare t jsonb := '{}'::jsonb; k text;
begin
  foreach k in array array['price_per_kg', 'currency', 'incoterms'] loop
    if new.payload ? k then
      if nullif(btrim(new.payload->>k), '') is not null then t := t || jsonb_build_object(k, new.payload->k); end if;
      new.payload := new.payload - k;
    end if;
  end loop;
  if t = '{}'::jsonb then return new; end if;
  if new.stage_type <> 'commercial' then raise exception 'the sale price and terms are recorded at Commercial' using errcode = '23514'; end if;
  if t ? 'price_per_kg' and (app.opt_num(t, 'price_per_kg', null) is null or app.opt_num(t, 'price_per_kg', null) <= 0) then
    raise exception 'commercial: the price is a number more than 0' using errcode = '23514'; end if;
  if t ? 'currency' and t->>'currency' not in ('INR', 'USD', 'EUR', 'GBP', 'AED', 'SAR', 'JPY', 'AUD') then
    raise exception 'commercial: the currency is one of INR, USD, EUR, GBP, AED, SAR, JPY, AUD' using errcode = '23514'; end if;
  if t ? 'incoterms' and t->>'incoterms' not in ('EXW', 'FCA', 'FOB', 'CFR', 'CIF', 'CPT', 'CIP', 'DAP', 'DPU', 'DDP') then
    raise exception 'commercial: the Incoterms are one of EXW, FCA, FOB, CFR, CIF, CPT, CIP, DAP, DPU, DDP' using errcode = '23514'; end if;
  perform set_config('app.pending_sale_terms', (t || jsonb_build_object('fp', new.id))::text, true);
  return new;
end $$;
drop trigger if exists footprints_a01_sale_terms on public.footprints;
create trigger footprints_a01_sale_terms before insert or update on public.footprints for each row execute function app.footprints_take_sale_terms();

create or replace function app.footprints_keep_sale_terms() returns trigger
language plpgsql security definer set search_path = public as $$
declare t jsonb; v_price numeric;
begin
  t := nullif(current_setting('app.pending_sale_terms', true), '')::jsonb;
  if t is null or (t->>'fp')::uuid is distinct from new.id then return null; end if;
  perform set_config('app.pending_sale_terms', '', true);
  v_price := app.opt_num(t, 'price_per_kg', null);
  insert into public.sale_terms (footprint_id, client_id, scope_id, price_per_kg, currency, incoterms, total_value, recorded_by)
  values (new.id, new.client_id, new.scope_id, v_price, coalesce(t->>'currency', 'INR'), t->>'incoterms',
          case when v_price is null then null else round(v_price * new.qty_out, 2) end, app.current_user_id())
  on conflict (footprint_id) do update set price_per_kg = excluded.price_per_kg, currency = excluded.currency, incoterms = excluded.incoterms,
     total_value = excluded.total_value, updated_at = now();
  return null;
end $$;
drop trigger if exists footprints_z8_sale_terms on public.footprints;
create trigger footprints_z8_sale_terms after insert or update on public.footprints for each row execute function app.footprints_keep_sale_terms();

-- ---------------------------------------------------------------------------------------------------------------------
-- C7: packs by type. What is left of a packing record (packed packs per pack type, less those sold), and of an order
-- (its packs per type, less those shipped). Records superseded or legacy do not count.
-- ---------------------------------------------------------------------------------------------------------------------
-- (app.sku_kg, migration 51: a pack's size in kilograms)
create or replace function app.sku_name(p_sku public.pack_skus) returns text
language sql immutable as $$ select rtrim(to_char(p_sku.size, 'FM999999990.###'), '.') || ' ' || p_sku.unit || ' ' || p_sku.material
  || case when p_sku.market = 'export' then ' (export)' else '' end $$;

create or replace function app.packs_left_of(p_fp uuid, p_except uuid default null) returns jsonb
language sql stable security definer set search_path = public as $$
  with f as (select * from public.footprints where id = p_fp),
  have as (
    -- a packing record: its packed packs per type; an order: the packs it sold
    select k.id as sku_id, count(*)::numeric as units
      from f join public.packs pk on pk.footprint_id = f.id and pk.status = 'packed' join public.pack_skus k on k.id = pk.sku_id
     where f.stage_type = 'packing' group by k.id
    union all
    select (x->>'sku_id')::uuid, (x->>'units')::numeric
      from f, jsonb_array_elements(coalesce(f.computed->'packs', '[]'::jsonb)) x where f.stage_type = 'commercial'),
  used as (
    select (x->>'sku_id')::uuid as sku_id, sum((x->>'units')::numeric) as units
      from public.footprints c, jsonb_array_elements(coalesce(c.computed->'packs', '[]'::jsonb)) x
     where c.prev_footprint_id = p_fp and c.status not in ('superseded', 'legacy') and c.id is distinct from p_except group by 1)
  select coalesce(jsonb_agg(jsonb_build_object('sku_id', h.sku_id, 'name', app.sku_name(k), 'size_kg', app.sku_kg(k), 'market', k.market,
            'units', h.units, 'left', h.units - coalesce(u.units, 0)) order by app.sku_kg(k) desc, k.material), '[]'::jsonb)
    from have h join public.pack_skus k on k.id = h.sku_id left join used u on u.sku_id = h.sku_id $$;

-- The same, for the person who records the next stage (the form's packs to choose from).
create or replace function app.packs_left(p_fp uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  return app.packs_left_of(p_fp);
end $$;

-- The lines of packs chosen (sku, units) checked against what is left; the kilograms and the lines with their sizes.
create or replace function app.check_pack_lines(p_lines jsonb, p_left jsonb, p_what text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare x jsonb; l jsonb; v_units numeric; v_kg numeric := 0; out jsonb := '[]'::jsonb; seen text[] := '{}';
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception '%: choose the packs (by pack type)', p_what using errcode = '23514'; end if;
  for x in select * from jsonb_array_elements(p_lines) loop
    select y into l from jsonb_array_elements(p_left) y where y->>'sku_id' = x->>'sku_id';
    if l is null then raise exception '%: a pack type chosen is not in this lot', p_what using errcode = '23514'; end if;
    if (x->>'sku_id') = any (seen) then raise exception '%: each pack type once', p_what using errcode = '23514'; end if;
    seen := seen || (x->>'sku_id');
    begin v_units := (x->>'units')::numeric; exception when others then v_units := null; end;
    if v_units is null or v_units < 1 or v_units <> trunc(v_units) then
      raise exception '%: the number of packs is a whole number, 1 or more', p_what using errcode = '23514'; end if;
    if v_units > (l->>'left')::numeric then
      raise exception '%: only % packs of % are left', p_what, (l->>'left')::numeric, l->>'name' using errcode = '23514'; end if;
    v_kg := v_kg + v_units * (l->>'size_kg')::numeric;
    out := out || jsonb_build_array(jsonb_build_object('sku_id', x->>'sku_id', 'name', l->>'name', 'size_kg', (l->>'size_kg')::numeric, 'units', v_units));
  end loop;
  return jsonb_build_object('kg', v_kg, 'lines', out);
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C7: the market profile a batch is sold under. Export to a profile needs the batch's QC verdict for that profile (or
-- the client's written acceptance, migration 50/53). The QC record is the nearest one upstream.
-- ---------------------------------------------------------------------------------------------------------------------
create or replace function app.upstream_qc(p_fp uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select v.qc_footprint_id from app.resolve_market_verdict(p_fp) v $$;

create or replace function app.profile_allowed(p_source uuid, p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select pv.verdict = 'pass' from public.qc_profile_verdicts pv where pv.footprint_id = app.upstream_qc(p_source) and pv.code = p_code
                    order by pv.version desc limit 1), false)
      or exists (select 1 from public.qc_verdicts v where v.footprint_id = app.upstream_qc(p_source) and v.override is not null
                  and v.override->>'market' = 'export') $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C7: export documents. The profile's list; each received (with its file), applied, or not required (with a note).
-- Shipment of an export order waits until every one is received with its file, or not required.
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.export_documents (
  footprint_id  uuid not null references public.footprints(id),
  scope_id      uuid not null references public.scopes(id),
  doc           text not null check (length(btrim(doc)) between 2 and 120),
  status        text not null check (status in ('received', 'applied', 'not_required')),
  attachment_id uuid references public.attachments(id),
  note          text check (note is null or length(note) <= 300),
  set_by        uuid not null references public.app_users(id),
  set_at        timestamptz not null default now(),
  primary key (footprint_id, doc),
  check (status <> 'received' or attachment_id is not null),
  check (status <> 'not_required' or length(btrim(coalesce(note, ''))) >= 5)
);
alter table public.export_documents enable row level security;
revoke all on public.export_documents from anon, authenticated;
grant select on public.export_documents to authenticated;
drop policy if exists export_documents_read on public.export_documents;
create policy export_documents_read on public.export_documents for select to authenticated using (app.can_see_footprint(scope_id, 'commercial'));
drop trigger if exists zz_change_log on public.export_documents;
create trigger zz_change_log after insert or update or delete on public.export_documents for each row execute function app.log_change('export_document');

-- The documents an order needs: its market profile's list (none for domestic).
create or replace function app.export_docs_of(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with f as (select * from public.footprints where id = p_fp and stage_type = 'commercial'),
       pr as (select m.export_docs from f join public.scopes s on s.id = f.scope_id
                join public.market_profiles m on m.crop_id = s.crop_id and m.status = 'active' and m.code = f.computed->>'market_code'
               where f.computed->>'market' = 'export')
  select coalesce(jsonb_agg(jsonb_build_object('doc', d.doc, 'status', e.status, 'attachment_id', e.attachment_id, 'note', e.note,
            'done', coalesce(e.status = 'not_required' or (e.status = 'received' and e.attachment_id is not null), false)) order by d.n), '[]'::jsonb)
    from pr cross join lateral unnest(pr.export_docs) with ordinality as d(doc, n)
    left join public.export_documents e on e.footprint_id = (select id from f) and e.doc = d.doc $$;

create or replace function app.set_export_doc(p_fp uuid, p_doc text, p_status text, p_attachment uuid default null, p_note text default null)
returns public.export_documents
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; r public.export_documents;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type <> 'commercial' or coalesce(f.computed->>'market', '') <> 'export' then
    raise exception 'export documents belong to an export sale (Commercial)' using errcode = '23514'; end if;
  if not (app.is_my_stage(me, f.scope_id, 'commercial') or app.manages_scope(me, f.scope_id)) then
    raise exception 'the export documents are kept by Commercial or a manager of the scope' using errcode = '42501'; end if;
  if f.status not in ('pending', 'verified') then raise exception 'this sale is %', f.status using errcode = '23514'; end if;
  if not exists (select 1 from jsonb_array_elements(app.export_docs_of(f.id)) x where x->>'doc' = p_doc) then
    raise exception 'this document is not on the list of the sale''s market' using errcode = '23514'; end if;
  if p_status not in ('received', 'applied', 'not_required') then
    raise exception 'a document is received, applied for, or not required' using errcode = '23514'; end if;
  if p_status = 'received' and not exists (select 1 from public.attachments a where a.id = p_attachment and a.footprint_id = f.id) then
    raise exception 'a received document has its file (attach it first)' using errcode = '23514'; end if;
  if p_status = 'not_required' and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'say why the document is not required (at least 5 characters)' using errcode = '23514'; end if;
  insert into public.export_documents (footprint_id, scope_id, doc, status, attachment_id, note, set_by)
  values (f.id, f.scope_id, p_doc, p_status, case when p_status = 'received' then p_attachment end, nullif(left(btrim(coalesce(p_note, '')), 300), ''), me)
  on conflict (footprint_id, doc) do update set status = excluded.status, attachment_id = excluded.attachment_id, note = excluded.note,
     set_by = excluded.set_by, set_at = now()
  returning * into r;
  perform app.audit('export_document', f.id, jsonb_build_object('code', f.footprint_code, 'doc', p_doc, 'status', p_status), false);
  return r;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- C8: the bill of lading may come after the ship sailed ("Sailed, BL pending"); added once, by Shipment or a manager.
-- ---------------------------------------------------------------------------------------------------------------------
create table if not exists public.bills_of_lading (
  footprint_id uuid primary key references public.footprints(id),
  scope_id     uuid not null references public.scopes(id),
  bl_no        text not null check (bl_no ~ '^[A-Za-z0-9/-]{4,30}$'),
  added_by     uuid not null references public.app_users(id),
  added_at     timestamptz not null default now()
);
alter table public.bills_of_lading enable row level security;
revoke all on public.bills_of_lading from anon, authenticated;
grant select on public.bills_of_lading to authenticated;
drop policy if exists bills_of_lading_read on public.bills_of_lading;
create policy bills_of_lading_read on public.bills_of_lading for select to authenticated using (app.can_see_footprint(scope_id, 'shipment'));
drop trigger if exists zz_change_log on public.bills_of_lading;
create trigger zz_change_log after insert or update or delete on public.bills_of_lading for each row execute function app.log_change('bill_of_lading');

create or replace function app.add_bill_of_lading(p_fp uuid, p_bl text) returns public.bills_of_lading
language plpgsql security definer set search_path = public as $$
declare me uuid := app.current_user_id(); f public.footprints; r public.bills_of_lading;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then raise exception 'record not found' using errcode = 'P0002'; end if;
  if f.stage_type <> 'shipment' or coalesce(f.computed->>'market', '') <> 'export' then
    raise exception 'a bill of lading belongs to an export shipment' using errcode = '23514'; end if;
  if not (app.is_my_stage(me, f.scope_id, 'shipment') or app.manages_scope(me, f.scope_id)) then
    raise exception 'the bill of lading is added by Shipment or a manager of the scope' using errcode = '42501'; end if;
  if nullif(btrim(f.payload->>'bl_no'), '') is not null or exists (select 1 from public.bills_of_lading b where b.footprint_id = f.id) then
    raise exception 'this shipment has its bill of lading already' using errcode = '23505'; end if;
  if btrim(coalesce(p_bl, '')) !~ '^[A-Za-z0-9/-]{4,30}$' then
    raise exception 'a bill of lading number is 4 to 30 letters or digits' using errcode = '23514'; end if;
  insert into public.bills_of_lading (footprint_id, scope_id, bl_no, added_by) values (f.id, f.scope_id, btrim(p_bl), me) returning * into r;
  perform app.ledger_append(f.id, f.scope_id, 'delivery', me, jsonb_build_object('act', 'bill_of_lading', 'footprint_id', f.id,
    'footprint_code', f.footprint_code, 'bl_no', r.bl_no));
  return r;
end $$;

-- The formats C8 checks (spaces and dashes ignored where people type them).
create or replace function app.vehicle_ok(p text) returns boolean language sql immutable as $$
  select upper(regexp_replace(coalesce(p, ''), '[\s-]', '', 'g')) ~ '^([A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}|[0-9]{2}BH[0-9]{4}[A-Z]{1,2})$' $$;
create or replace function app.container_ok(p text) returns boolean language sql immutable as $$
  select upper(regexp_replace(coalesce(p, ''), '[\s-]', '', 'g')) ~ '^[A-Z]{3}[UJZ][0-9]{7}$' $$;

-- ---------------------------------------------------------------------------------------------------------------------
-- The stage forms (stage_definitions): Collection Batch, Commercial, Shipment
-- ---------------------------------------------------------------------------------------------------------------------
-- Collection Batch: its collection point first (Veda, 16 Oct: "there can be more than 1 cc in a scope … like in mill
-- there is option to choose"); the lots offered are that point's.
update public.stage_definitions set form_schema =
  '[{"key": "collection_point_id", "type": "collection_point", "label": "Collection point (where the bags are)", "section": "batch", "required": false, "required_when": "stage_details_required"}]'::jsonb
  || (select coalesce(jsonb_agg(x order by n), '[]'::jsonb) from jsonb_array_elements(form_schema) with ordinality as e(x, n) where x->>'key' <> 'collection_point_id')
 where stage_type = 'village_batch';

-- Commercial (C7): the buyer from the list, the export market's profile and the destination, the order number, packs by
-- type (where the batch was packed from the pack list), price and terms (kept apart; where the scope records prices).
-- A form "with_packs" field shows where the lot it comes from has packs by type; "hidden_when_packs" hides it there.
update public.stage_definitions set form_schema = '[
  {"key": "buyer_id", "type": "buyer", "label": "Buyer (from the client''s list)", "section": "buyer", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "buyer", "type": "text", "label": "Buyer", "section": "buyer", "required": true, "hidden_when": "stage_details_required"},
  {"key": "market", "gate": "market_verdict", "type": "select", "label": "Market", "options": ["domestic", "export"], "section": "buyer", "required": true},
  {"key": "market_code", "type": "market_profile", "label": "Export market (its profile)", "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "destination_country", "type": "text", "label": "Destination country (export)", "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "order_no", "type": "text", "label": "Order or contract number", "section": "buyer", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "sale_route", "type": "select", "label": "Sale route", "options": ["own_brand", "white_label", "bulk", "prasaadam"], "section": "buyer", "required": false, "shown_when": "stage_details_required"},
  {"key": "packs", "type": "order_packs", "label": "Packs sold", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true},
  {"key": "qty_kg", "type": "number", "unit": "kg", "label": "Quantity to this buyer", "section": "quantity", "required": true, "hidden_when_packs": true},
  {"key": "price_per_kg", "type": "number", "unit": "per kg", "label": "Price", "section": "terms", "required": false, "shown_when": "record_price"},
  {"key": "currency", "type": "select", "label": "Currency", "options": ["INR", "USD", "EUR", "GBP", "AED", "SAR", "JPY", "AUD"], "section": "terms", "required": false, "shown_when": "record_price"},
  {"key": "incoterms", "type": "select", "label": "Incoterms (export)", "options": ["EXW", "FCA", "FOB", "CFR", "CIF", "CPT", "CIP", "DAP", "DPU", "DDP"], "section": "terms", "required": false, "shown_when": "record_price"}
]'::jsonb,
  physical_checks = '["Packs set aside for this buyer counted", "Packs handed over match the order"]'::jsonb
 where stage_type = 'commercial';

-- Shipment (C8): the packs of one order (partial shipments), the serials scanned for export, the domestic and export
-- papers, the loading photo. A form "for_market" field shows for the order's market only.
update public.stage_definitions set form_schema = '[
  {"key": "packs", "type": "order_packs", "label": "Packs shipped", "section": "quantity", "required": false, "shown_when": "stage_details_required", "with_packs": true},
  {"key": "shipped_kg", "type": "number", "unit": "kg", "label": "Shipped", "section": "quantity", "required": true, "hidden_when_packs": true},
  {"key": "serials", "type": "serials", "label": "Pack codes loaded (scan or type, one per line)", "section": "quantity", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "vehicle_or_container", "type": "text", "label": "Vehicle / container", "section": "transport", "required": true, "hidden_when": "stage_details_required"},
  {"key": "vehicle_no", "type": "text", "label": "Vehicle number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "domestic"},
  {"key": "transporter", "type": "text", "label": "Transporter", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "driver_phone", "type": "text", "label": "Driver''s phone", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "container_no", "type": "text", "label": "Container number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "seal_no", "type": "text", "label": "Container seal number", "section": "transport", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "vessel", "type": "text", "label": "Vessel", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "forwarder", "type": "text", "label": "Forwarder", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "port_loading", "type": "text", "label": "Port of loading", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "port_discharge", "type": "text", "label": "Port of discharge", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "dispatch_date", "type": "date", "label": "Dispatch date", "section": "transport", "required": true},
  {"key": "arrival_on", "type": "date", "label": "Expected arrival", "section": "transport", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "destination", "type": "text", "label": "Destination", "section": "transport", "required": true},
  {"key": "invoice_no", "type": "text", "label": "Invoice number", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required"},
  {"key": "lr_no", "type": "text", "label": "LR number (lorry receipt)", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "domestic"},
  {"key": "eway_bill_no", "type": "text", "label": "E-way bill number (when required)", "section": "papers", "required": false, "shown_when": "stage_details_required", "for_market": "domestic"},
  {"key": "shipping_bill_no", "type": "text", "label": "Shipping bill number", "section": "papers", "required": false, "shown_when": "stage_details_required", "required_when": "stage_details_required", "for_market": "export"},
  {"key": "bl_no", "type": "text", "label": "Bill of lading number (may come later)", "section": "papers", "required": false, "shown_when": "stage_details_required", "for_market": "export"},
  {"key": "loading_photo", "type": "attachment", "label": "Loading photo (the seal or the vehicle)", "section": "documents", "required": false, "label_as": "loading_photo"},
  {"key": "documents", "type": "attachment", "label": "Documents (photo or PDF)", "accept": "document", "section": "documents", "required": false}
]'::jsonb
 where stage_type = 'shipment';

-- ---------------------------------------------------------------------------------------------------------------------
-- Patches of the current definitions (each change asserted by gen54.py)
-- ---------------------------------------------------------------------------------------------------------------------
-- The save's own rules: the Collection Batch's collection point, the QC lab, Commercial (C7), Shipment (C8)
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
  v_scp public.collection_points;                                                                                    -- migration 54
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
        if nullif(pk->>'sku_id', '') is not null then
          select * into v_sku from public.pack_skus k where k.id::text = pk->>'sku_id' and k.client_id = p_scope.client_id and k.active;
          if v_sku.id is null then raise exception 'packing: a pack is not on the client''s pack list' using errcode = '23514'; end if;
          if abs(app.req_num(pk, 'size_kg') - case v_sku.unit when 'g' then v_sku.size / 1000 else v_sku.size end) > 0.0005 then
            raise exception 'packing: a pack from the list keeps its own size (% %)', v_sku.size, v_sku.unit using errcode = '23514'; end if;
          if app.req_num(pk, 'units') < 1 or app.req_num(pk, 'units') <> trunc(app.req_num(pk, 'units')) then
            raise exception 'packing: the number of packs is a whole number, 1 or more' using errcode = '23514'; end if;
        elsif p_scope.stage_details_required then
          raise exception 'packing: choose the packs from the client''s pack list' using errcode = '23514';
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
        else
          v_in := app.req_num(p, 'qty_kg');
        end if;
        v_out := v_in;
        c := jsonb_build_object('market', p->>'market', 'buyer', coalesce(v_buyer.name, btrim(p->>'buyer')), 'order_no', btrim(p->>'order_no'))
             || case when v_buyer.id is not null then jsonb_build_object('buyer_id', v_buyer.id, 'buyer_country', v_buyer.country) else '{}'::jsonb end
             || case when v_prof.id is not null then jsonb_build_object('market_code', v_prof.code, 'market_name', v_prof.name,
                                                                      'destination_country', btrim(p->>'destination_country')) else '{}'::jsonb end
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when p ? 'sale_route' then jsonb_build_object('sale_route', p->>'sale_route') else '{}'::jsonb end;
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
      if p ? 'packs' or p ? 'invoice_no' or p_scope.stage_details_required then
        -- migration 54 (C8): the packs of one order (partial shipments: no more than are left of it); for export the pack
        -- codes scanned while loading, and the order's export documents complete; the papers of the market, their formats
        v_mkt := coalesce(prev.computed->>'market', prev.payload->>'market', 'domestic');
        if length(btrim(coalesce(p->>'invoice_no', ''))) < 2 then
          raise exception 'shipment: give the invoice number' using errcode = '23514'; end if;
        v_left := case when prev.stage_type = 'commercial' then app.packs_left_of(prev.id, f.id) else '[]'::jsonb end;
        if jsonb_array_length(v_left) > 0 then
          v_pl := app.check_pack_lines(p->'packs', v_left, 'shipment');
          v_in := (v_pl->>'kg')::numeric;
        else
          v_in := app.req_num(p, 'shipped_kg');
        end if;
        if v_mkt = 'export' then
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
          if v_pl is not null then
            select array_agg(upper(btrim(x))) into v_ser from jsonb_array_elements_text(coalesce(p->'serials', '[]'::jsonb)) x where btrim(x) <> '';
            if coalesce(cardinality(v_ser), 0) = 0 then
              raise exception 'shipment: scan or type the codes of the packs loaded (export)' using errcode = '23514'; end if;
            if cardinality(v_ser) <> (select count(distinct sr) from unnest(v_ser) sr) then
              raise exception 'shipment: a pack code is there twice' using errcode = '23514'; end if;
            select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
             where not exists (select 1 from public.packs pk where pk.serial = sr and pk.status = 'packed' and pk.footprint_id = prev.prev_footprint_id);
            if v_ser_txt is not null then
              raise exception 'shipment: % not a pack of this order''s batch (or void)', v_ser_txt using errcode = '23514'; end if;
            select string_agg(sr, ', ') into v_ser_txt from unnest(v_ser) sr
             where exists (select 1 from public.footprints o where o.stage_type = 'shipment' and o.id <> f.id and o.status not in ('superseded', 'legacy')
                             and coalesce(o.payload->'serials', '[]'::jsonb) ? sr);
            if v_ser_txt is not null then
              raise exception 'shipment: % shipped already', v_ser_txt using errcode = '23514'; end if;
            select string_agg(x->>'name', ', ') into v_ser_txt from jsonb_array_elements(v_pl->'lines') x
             where (x->>'units')::numeric <> (select count(*) from unnest(v_ser) sr join public.packs pk on pk.serial = sr where pk.sku_id::text = x->>'sku_id');
            if v_ser_txt is not null or cardinality(v_ser) <> (select sum((x->>'units')::numeric) from jsonb_array_elements(v_pl->'lines') x) then
              raise exception 'shipment: the codes scanned do not match the packs shipped (%)', coalesce(v_ser_txt, 'other pack types') using errcode = '23514'; end if;
          end if;
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
        v_out := v_in;
        c := jsonb_build_object('market', v_mkt, 'invoice_no', btrim(p->>'invoice_no'))
             || case when v_pl is not null then jsonb_build_object('packs', v_pl->'lines') else '{}'::jsonb end
             || case when v_ser is not null then jsonb_build_object('serials_count', cardinality(v_ser)) else '{}'::jsonb end
             || case when v_mkt = 'export' then jsonb_build_object('container_no', upper(regexp_replace(p->>'container_no', '[\s-]', '', 'g')),
                       'bl_pending', nullif(btrim(p->>'bl_no'), '') is null) else '{}'::jsonb end;
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
-- The sample goes to a lab of the state or of the client (migration 54)
CREATE OR REPLACE FUNCTION app.draw_sample(p_fp uuid, p jsonb)
 RETURNS qc_samples
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; sc public.scopes; me uuid := app.current_user_id(); v_on date; v_lot date; v_qty numeric; lb public.labs;
        r public.qc_samples; v_n int; v_keep date;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or me is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  if app.chain_next(f.scope_id, f.stage_type) is distinct from 'qc' then
    raise exception 'a sample is drawn from a lot that goes to Quality Control' using errcode = '23514'; end if;
  if not (app.has_slot(me, f.scope_id, 'qc') or app.manages_scope(me, f.scope_id)) then
    raise exception 'the sample is drawn by Quality Control of this scope' using errcode = '42501'; end if;
  if f.status <> 'verified' then raise exception 'verify the lot before drawing its sample' using errcode = '23514'; end if;
  begin v_on := coalesce(nullif(p->>'drawn_on', '')::date, (now() at time zone 'Asia/Kolkata')::date);
  exception when others then raise exception 'sample: the date drawn is a date' using errcode = '23514'; end;
  v_lot := coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date);
  if v_on > (now() at time zone 'Asia/Kolkata')::date or v_on < v_lot then
    raise exception 'sample: drawn between the lot''s date (%) and today', to_char(v_lot, 'DD Mon YYYY') using errcode = '23514'; end if;
  v_qty := app.opt_num(p, 'qty_kg', null);
  if v_qty is null or v_qty <= 0 then raise exception 'sample: the quantity drawn is more than 0 kg' using errcode = '23514'; end if;
  if v_qty >= app.available_qty(f.id) then
    raise exception 'sample: the sample is smaller than what is left of the lot (% kg)', round(app.available_qty(f.id), 1) using errcode = '23514'; end if;
  if nullif(p->>'lab_id', '') is not null then
    select * into lb from public.labs l where l.id::text = p->>'lab_id' and app.lab_for_scope(l.id, sc.id);   -- migration 54
    if lb.id is null then raise exception 'sample: the lab is not on this state''s or this client''s list' using errcode = '23514'; end if;
  elsif sc.stage_details_required then
    raise exception 'sample: name the lab it goes to (from the list)' using errcode = '23514';
  end if;
  if sc.stage_details_required and (length(btrim(coalesce(p->>'counter_seal_no', ''))) < 2 or length(btrim(coalesce(p->>'counter_stored_at', ''))) < 2) then
    raise exception 'sample: the retained counter-sample''s seal number and where it is stored are required' using errcode = '23514'; end if;
  if (nullif(btrim(p->>'buyer_seal_no'), '') is null) <> (nullif(btrim(p->>'buyer_recipient'), '') is null) then
    raise exception 'sample: a buyer''s sample names its seal number and who receives it' using errcode = '23514'; end if;
  begin v_keep := coalesce(nullif(p->>'keep_until', '')::date, (v_on + interval '12 months')::date);
  exception when others then raise exception 'sample: keep until is a date' using errcode = '23514'; end;
  if v_keep < v_on then raise exception 'sample: kept until a date after it is drawn' using errcode = '23514'; end if;
  select count(*) + 1 into v_n from public.qc_samples s where s.footprint_id = f.id;
  insert into public.qc_samples (code, footprint_id, scope_id, client_id, drawn_on, qty_kg, lab_id, counter_seal_no, counter_stored_at,
                                 keep_until, buyer_seal_no, buyer_recipient, created_by)
  values (f.footprint_code || '-S' || v_n, f.id, f.scope_id, f.client_id, v_on, v_qty, lb.id, nullif(btrim(p->>'counter_seal_no'), ''),
          nullif(btrim(p->>'counter_stored_at'), ''), v_keep, nullif(btrim(p->>'buyer_seal_no'), ''), nullif(btrim(p->>'buyer_recipient'), ''), me)
  returning * into r;
  return r;
end $function$;
-- What the system checks: a batch's villages come from its lots (found in release 6's checks); the sale (C7)
CREATE OR REPLACE FUNCTION app.system_checks(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; fm public.farmers; sc public.scopes; cr public.crops; out jsonb := '[]'::jsonb; n int; m int; ans jsonb;
  ok boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into sc from public.scopes where id = f.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  out := out || jsonb_build_array(jsonb_build_object('key', 'recorded', 'ok', true, 'vars', jsonb_build_object(
           'by', (select display_name from public.app_users where id = f.created_by),
           'on', to_char(coalesce(f.happened_on, (coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata')::date), 'DD Mon YYYY'))));
  case f.stage_type
    when 'procurement' then
      select * into fm from public.farmers where id = f.farmer_id;
      out := out || jsonb_build_array(jsonb_build_object('key', 'farmer_active', 'ok', fm.status = 'active', 'vars', jsonb_build_object('name', fm.name)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'moisture_three',
               'ok', jsonb_typeof(f.payload->'moisture_pct') = 'array' and jsonb_array_length(f.payload->'moisture_pct') = 3, 'vars', '{}'::jsonb));
      out := out || jsonb_build_array(jsonb_build_object('key', 'net_worked_out', 'ok', true, 'vars', jsonb_build_object('kg', f.qty_out)));
      select answers into ans from public.farmer_gap where farmer_id = f.farmer_id and crop_id = cr.id;
      out := out || jsonb_build_array(jsonb_build_object('key', 'practice_complete',
               'ok', jsonb_array_length(app.gap_missing(cr.gap_items, ans)->'required') = 0, 'vars', '{}'::jsonb));
    when 'lot_inward' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'source_declared',
               'ok', coalesce(btrim(f.payload->>'source_type'), '') <> '' and coalesce(btrim(f.payload->>'source_name'), '') <> '', 'vars', '{}'::jsonb));
    when 'village_batch' then
      select count(*), count(*) filter (where s.status = 'verified') into n, m from public.footprints s
       where s.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(f.payload->'source_footprint_ids', '[]'::jsonb)) x);
      out := out || jsonb_build_array(jsonb_build_object('key', 'sources_verified', 'ok', n = m and n > 0, 'vars', jsonb_build_object('n', n)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'batch_sum', 'ok', true, 'vars', jsonb_build_object('kg', f.qty_in)));
      -- migration 54: the villages are taken from the lots (a batch of before named its village)
      out := out || jsonb_build_array(jsonb_build_object('key', 'villages_from_lots',
               'ok', coalesce(btrim(f.payload->>'village'), '') <> '' or jsonb_array_length(coalesce(f.computed->'villages', '[]'::jsonb)) > 0,
               'vars', jsonb_build_object('n', jsonb_array_length(coalesce(f.computed->'villages', '[]'::jsonb)))));
    when 'qc' then
      select count(*) into m from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q;
      select count(*) into n from jsonb_array_elements(coalesce(sc.quality_params, cr.quality_params)) q
       where coalesce(f.payload->'readings', '{}'::jsonb) ? (q->>'param');
      out := out || jsonb_build_array(jsonb_build_object('key', 'params_read', 'ok', n = m, 'vars', jsonb_build_object('n', n, 'm', m)));
      out := out || jsonb_build_array(jsonb_build_object('key', 'verdicts_derived',
               'ok', exists (select 1 from public.qc_verdicts v where v.footprint_id = f.id), 'vars', '{}'::jsonb));
    when 'commercial' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'buyer_market',
               'ok', coalesce(btrim(f.computed->>'buyer'), btrim(f.payload->>'buyer'), '') <> '' and coalesce(f.payload->>'market', '') <> '', 'vars', '{}'::jsonb));
      out := out || jsonb_build_array(jsonb_build_object('key', 'export_backed',
               'ok', coalesce(f.payload->>'market', '') <> 'export'
                     or (case when f.computed ? 'market_code' then app.profile_allowed(f.prev_footprint_id, f.computed->>'market_code')
                              else app.export_allowed(f.prev_footprint_id) end), 'vars', '{}'::jsonb));
      -- migration 54 (C7): an export sale's documents, each received with its file or not required
      if f.computed ? 'market_code' then
        select count(*), count(*) filter (where (x->>'done')::boolean) into m, n from jsonb_array_elements(app.export_docs_of(f.id)) x;
        out := out || jsonb_build_array(jsonb_build_object('key', 'export_docs', 'ok', n = m, 'vars', jsonb_build_object('n', n, 'm', m)));
      end if;
    when 'shipment' then
      out := out || jsonb_build_array(jsonb_build_object('key', 'documents',
               'ok', exists (select 1 from public.attachments a where a.footprint_id = f.id),
               'vars', jsonb_build_object('n', (select count(*) from public.attachments a where a.footprint_id = f.id))));
    else
      out := out || jsonb_build_array(jsonb_build_object('key', 'balance', 'ok', true, 'vars', jsonb_build_object('in', f.qty_in, 'out', f.qty_out)));
      if f.stage_type = 'packing' then
        out := out || jsonb_build_array(jsonb_build_object('key', 'batch_code', 'ok', coalesce(btrim(f.payload->>'batch_code'), '') <> '', 'vars', '{}'::jsonb));
      end if;
  end case;
  select not exists (select 1 from public.flags fl where fl.footprint_id = f.id and fl.status = 'open') into ok;
  out := out || jsonb_build_array(jsonb_build_object('key', 'no_open_flags', 'ok', ok, 'vars', '{}'::jsonb));
  return out;
end $function$;
-- QC: a market profile's own test shows its limits on the form (found in release 6's checks: "<= undefined")
CREATE OR REPLACE FUNCTION app.scope_test_params(p_scope uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with sc as (select s.*, coalesce(s.quality_params, c.quality_params, '[]'::jsonb) as qp from public.scopes s join public.crops c on c.id = s.crop_id where s.id = p_scope),
       own as (select x->>'param' as param from sc, jsonb_array_elements(sc.qp) x),
       extra as (
         select distinct on (x->>'param') x->>'param' as param, x->>'operator' as op, l.name, l.unit, l.type, l.done_by, l.sort_order
           from sc join public.market_profiles m on m.crop_id = sc.crop_id and m.status = 'active' and m.code = any (sc.market_codes)
           cross join jsonb_array_elements(m.params) x
           join public.quality_param_library l on l.param = x->>'param'
          where not exists (select 1 from own o where o.param = x->>'param')
            and not exists (select 1 from own o join public.quality_param_library a on a.param = o.param and a.alias_of = x->>'param'))
  select (select qp from sc) || coalesce((select jsonb_agg(jsonb_build_object('param', e.param, 'label', e.name, 'unit', e.unit,
            'type', e.type, 'operator', coalesce(e.op, '<='), 'from_profile', true, 'done_by', e.done_by,
            'limits', (select coalesce(jsonb_agg(jsonb_build_object('market', m2.name, 'operator', coalesce(y->>'operator', '<='), 'limit', y->'limit')
                                                 order by array_position(sc2.market_codes, m2.code)), '[]'::jsonb)
                         from public.scopes sc2 join public.market_profiles m2 on m2.crop_id = sc2.crop_id and m2.status = 'active' and m2.code = any (sc2.market_codes)
                         cross join jsonb_array_elements(m2.params) y
                        where sc2.id = p_scope and y->>'param' = e.param))                                       -- migration 54
            order by e.sort_order, e.param) from extra e), '[]'::jsonb) $function$;
-- C8: an export shipment is verified once its loading photo is attached, where the scope asks the details
CREATE OR REPLACE FUNCTION app.footprints_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare sc public.scopes;
begin
  -- Sacred stamps never change, whatever the status.
  if new.scope_id <> old.scope_id or new.client_id <> old.client_id or new.stage_type <> old.stage_type
     or new.prev_footprint_id is distinct from old.prev_footprint_id or new.created_by <> old.created_by
     or new.footprint_code <> old.footprint_code or new.is_grade_lot <> old.is_grade_lot or new.grade is distinct from old.grade then
    raise exception 'scope_id, client_id, stage_type, prev_footprint_id, created_by, footprint_code, grade are immutable' using errcode = '42501';
  end if;

  if old.status = 'pending' then
    if new.status = 'verified' then
      if new.verified_by is null then raise exception 'verified_by is required' using errcode = '23514'; end if;
      -- migration 50 (C5): the lab report file before verification, where the scope asks for the report
      if old.stage_type = 'qc' and (select s.qc_report_required from public.scopes s where s.id = old.scope_id)
         and not exists (select 1 from public.attachments a where a.footprint_id = old.id and (a.kind = 'document' or a.label = 'lab_report')) then
        raise exception 'qc: the lab report file is attached before the lab record is verified' using errcode = '23514'; end if;
      -- migration 53 (C6): export packs and packs of 5 kg or less: the packs the system picked are weighed and within the
      -- allowed error, where the scope asks the details
      if old.stage_type = 'packing' and (select s.stage_details_required from public.scopes s where s.id = old.scope_id) and app.needs_weight_check(old)
         and not exists (select 1 from public.net_weight_checks n where n.footprint_id = old.id and n.result = 'pass'
                           and not exists (select 1 from unnest(n.serials) sr where not exists
                                             (select 1 from public.packs pp where pp.serial = sr and pp.status = 'packed'))) then
        raise exception 'packing: weigh the packs the system picked (net weight check) before this record is verified' using errcode = '23514'; end if;
      -- migration 54 (C8): an export shipment's loading photo (the seal or the vehicle) before it is verified
      if old.stage_type = 'shipment' and old.computed->>'market' = 'export' and (select s.stage_details_required from public.scopes s where s.id = old.scope_id)
         and not exists (select 1 from public.attachments a where a.footprint_id = old.id and a.label = 'loading_photo') then
        raise exception 'shipment: attach the loading photo (the seal or the vehicle) before this export shipment is verified' using errcode = '23514'; end if;
      -- migration 48 (A1): returned to its sender, it waits for the correction
      if exists (select 1 from public.footprint_returns r where r.footprint_id = old.id and r.status = 'open') then
        raise exception 'this record was returned to its sender: it is verified after the correction' using errcode = '23514'; end if;
      -- isGate (QR): there is no stage after it; its verification IS the whole-chain re-walk done by the sealer.
      if (select is_gate from public.stage_definitions d where d.stage_type = new.stage_type) then
        if not app.is_my_stage(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not seal: not the assigned QR operator', new.verified_by using errcode = '42501'; end if;
      else
        if not app.is_next_stage_user(new.verified_by, new.scope_id, new.stage_type) then
          raise exception 'user % may not verify a % record: verification is by the receiving stage', new.verified_by, new.stage_type using errcode = '42501'; end if;
        -- migration 46 (Veda, 14 Oct): one person may hold two stages in a row and then verifies his own record; the
        -- ledger marks it "same person, next stage", the public page says so, the overview counts it
        -- migration 48 (A10/G14): a manager who does not hold the receiving stage verifies only with a written reason
        if auth.uid() is not null and app.manages_scope(new.verified_by, new.scope_id)
           and not app.has_slot(new.verified_by, new.scope_id, app.chain_next(new.scope_id, new.stage_type))
           and length(btrim(coalesce(current_setting('app.act_reason', true), ''))) < 10 then
          raise exception 'a manager verifies at a stage he does not hold only with a written reason (at least 10 characters)' using errcode = '23514'; end if;
      end if;
      new.verified_at := coalesce(new.verified_at, now());
      -- the verified snapshot is exactly what the creator reviewed: no payload edits ride along with verification
      if new.payload <> old.payload or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out then
        raise exception 'payload/quantities cannot change in the same act as verification' using errcode = '42501'; end if;
    elsif new.status = 'pending' then
      -- creator may still correct a pending record; reconciliation re-runs
      if new.payload <> old.payload or new.farmer_id is distinct from old.farmer_id then
        select * into sc from public.scopes where id = new.scope_id;
        new := app.reconcile(new, sc);
        if new.prev_footprint_id is not null and not new.is_grade_lot and new.stage_type <> 'village_batch'
           and new.qty_in > app.available_qty(new.prev_footprint_id) + old.qty_in + app.kg_tolerance() then
          raise exception 'qty_in exceeds available on predecessor' using errcode = '23514'; end if;
      end if;
    elsif new.status = 'superseded' then
      null;
    else
      raise exception 'pending → % is not a valid transition', new.status using errcode = '23514';
    end if;
  else
    -- verified / superseded / legacy: frozen except lot_closed and status → superseded
    if new.payload <> old.payload or new.computed <> old.computed or new.qty_in <> old.qty_in or new.qty_out <> old.qty_out
       or new.warnings <> old.warnings or new.farmer_id is distinct from old.farmer_id
       or new.verified_by is distinct from old.verified_by or new.verified_at is distinct from old.verified_at
       or new.split_into_grades <> old.split_into_grades then
      raise exception 'a % footprint is immutable; create a superseding record instead', old.status using errcode = '42501';
    end if;
    if new.status <> old.status and not (old.status = 'verified' and new.status = 'superseded') then
      raise exception '% → % is not a valid transition', old.status, new.status using errcode = '23514';
    end if;
  end if;
  return new;
end$function$;
-- The record page: the sale's terms (to who may read them), its export documents, a shipment's bill of lading
CREATE OR REPLACE FUNCTION app.footprint_detail(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; vd record; name_of jsonb;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  return jsonb_build_object(
    'footprint', to_jsonb(f),
    'stage_label', (select label from public.stage_definitions where stage_type = f.stage_type),
    'created_by_name', (select display_name from public.app_users where id = f.created_by),
    'verified_by_name', (select display_name from public.app_users where id = f.verified_by),
    'farmer', (select jsonb_build_object('name', name, 'farmer_code', farmer_code, 'village', village,
                 'state_farmer_code', (select sf.code from public.state_farmers sf where sf.id = farmers.state_farmer_id))   -- migration 44
                 from public.farmers where id = f.farmer_id),
    'prev', (select jsonb_build_object('id', p.id, 'footprint_code', p.footprint_code, 'stage_type', p.stage_type)
               from public.footprints p where p.id = f.prev_footprint_id),
    'available_kg', app.available_qty(f.id),
    'qc', (select to_jsonb(v) from public.qc_verdicts v where v.footprint_id = f.id),
    'profile_verdicts', coalesce((select jsonb_agg(to_jsonb(pv) order by pv.created_at, pv.code) from public.qc_profile_verdicts pv
                          where pv.footprint_id = vd.qc_footprint_id), '[]'::jsonb),                            -- migration 53
    'closure', (select to_jsonb(lc) || jsonb_build_object('closed_by_name', (select display_name from public.app_users where id = lc.closed_by))
                  from public.lot_closures lc where lc.footprint_id = f.id),
    'net_weight', case when f.stage_type = 'packing' then jsonb_build_object(
                    'needed', app.needs_weight_check(f) and (select s.stage_details_required from public.scopes s where s.id = f.scope_id),
                    'check', (select to_jsonb(n) from public.net_weight_checks n where n.footprint_id = f.id)) end,
    'market_verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'seal', (select to_jsonb(q) from public.qr_seals q where q.footprint_id = f.id),
    'flags', coalesce((select jsonb_agg(jsonb_build_object('id', fl.id, 'text', fl.text, 'status', fl.status, 'created_at', fl.created_at,
               'raised_by_name', (select display_name from public.app_users where id = fl.raised_by), 'kind', fl.kind) order by fl.created_at)
               from public.flags fl where fl.footprint_id = f.id), '[]'::jsonb),
    'returns', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'reason', r.reason, 'status', r.status, 'returned_at', r.returned_at,
               'returned_by_name', (select display_name from public.app_users where id = r.returned_by),
               'resolved_at', r.resolved_at, 'resolved_by_name', (select display_name from public.app_users where id = r.resolved_by)) order by r.returned_at)
               from public.footprint_returns r where r.footprint_id = f.id), '[]'::jsonb),                       -- migration 48
    'can_return', f.status = 'pending' and f.created_by is distinct from app.current_user_id()
                  and not coalesce((select d.is_gate from public.stage_definitions d where d.stage_type = f.stage_type), false)
                  and app.is_next_stage_user(app.current_user_id(), f.scope_id, f.stage_type)
                  and not exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'),
    'packs', case when f.stage_type = 'packing' then jsonb_build_object('batch_code', f.payload->>'batch_code',          -- migration 50
               'packed', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'packed'),
               'void', (select count(*) from public.packs p where p.footprint_id = f.id and p.status = 'void'),
               'prints', (select count(*) from public.label_prints lp where lp.footprint_id = f.id),
               'best_before', (select min(best_before) from public.packs p where p.footprint_id = f.id and p.status = 'packed')) end,
    'sale_terms', (select to_jsonb(st) from public.sale_terms st where st.footprint_id = f.id and app.reads_lot_payment(st.client_id, st.recorded_by)),   -- migration 54
    'export_docs', case when f.stage_type = 'commercial' and f.computed ? 'market_code' then app.export_docs_of(f.id) end,
    'bill_of_lading', (select to_jsonb(b) from public.bills_of_lading b where b.footprint_id = f.id),
    'packs_left', case when f.stage_type in ('packing', 'commercial') then app.packs_left_of(f.id) end,
    'delivery', (select to_jsonb(d) || jsonb_build_object('confirmed_by_name', (select display_name from public.app_users where id = d.confirmed_by))
                   from public.deliveries d where d.shipment_id = f.id),
    'release', case when exists (select 1 from public.qr_seals q where q.footprint_id = f.id) then app.release_status(f.id) end,
    'farmers', app.lot_farmers(f.id),                                                                         -- migration 49
    'gi_status', app.lot_gi_status(f.id),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.footprint_code, 'stage', p.stage_type, 'kg', l.kg,
                 'how', l.how, 'from_older', l.from_older) order by p.footprint_code)
                 from public.footprint_links l join public.footprints p on p.id = l.parent_id where l.child_id = f.id), '[]'::jsonb),
    'system_checks', app.system_checks(f.id),
    'attachments', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from public.attachments a where a.footprint_id = f.id), '[]'::jsonb),
    'ledger', coalesce((select jsonb_agg(jsonb_build_object('seq', l.seq, 'event', l.event, 'hash', l.hash, 'prev_hash', l.prev_hash,
               'created_at', l.created_at, 'actor_name', (select display_name from public.app_users where id = l.actor)) order by l.seq)
               from public.ledger l where l.footprint_id = f.id), '[]'::jsonb)
  );
end $function$;
-- A farmer's village is picked from the places list before he is verified (Veda, 16 Oct: "villages … entered in database
-- before hand"); farmers of before keep theirs
CREATE OR REPLACE FUNCTION app.farmers_location_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- migration 54: the village too (added first in Set-up lists, Places)
    if v_state is not null and exists (select 1 from public.places pl0 where pl0.state_id = v_state)      -- a state with no list: as before
       and not exists (select 1 from public.places pl where pl.state_id = v_state and pl.village is not null
          and app.norm_place(pl.district) = app.norm_place(new.district) and app.norm_place(pl.village) = app.norm_place(new.village)
          and (nullif(btrim(new.block), '') is null or app.norm_place(pl.block) = app.norm_place(new.block))) then
      raise exception 'the village % is not on the list of district %: pick it from the list (Set-up lists, Places, adds it first)', new.village, new.district
        using errcode = '23514'; end if;
  end if;
  return new;
end $function$;
-- The markets a lot can be sold to: export also where an export profile of the scope passed (C7)
CREATE OR REPLACE FUNCTION app.lot_markets(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare f public.footprints; vd record; ok_export boolean;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null or app.current_user_id() is null or not app.can_see_footprint(f.scope_id, f.stage_type) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  select * into vd from app.resolve_market_verdict(f.id);
  ok_export := app.export_allowed(f.id) or exists (select 1 from public.scopes s where s.id = f.scope_id
                  and exists (select 1 from unnest(s.market_codes) mc where mc <> 'domestic' and app.profile_allowed(f.id, mc)));   -- migration 54
  return jsonb_build_object(
    'has_qc', vd.qc_footprint_id is not null, 'domestic', vd.domestic, 'export', vd.export,
    'overridden', vd.override is not null, 'export_allowed', ok_export,
    'markets', to_jsonb(case when ok_export then array['domestic', 'export'] else array['domestic'] end),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name, 'verdict', pv.verdict) order by pv.code)
                            from public.qc_profile_verdicts pv where pv.footprint_id = vd.qc_footprint_id), '[]'::jsonb));
end $function$;
-- A file registered as an export document (C7)
CREATE OR REPLACE FUNCTION app.register_labelled_attachment(p_footprint uuid, p_kind attachment_kind, p_path text, p_sha256 text, p_label text)
 RETURNS attachments
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare r public.attachments;
begin
  if p_label is not null and p_label not in ('lab_report', 'acceptance', 'pod', 'loading_photo', 'document', 'export_doc') then
    raise exception 'unknown kind of document' using errcode = '22023'; end if;
  r := app.register_attachment(p_footprint, p_kind, p_path, p_sha256);       -- as the caller: the insert's own rules apply
  return app.set_attachment_label(r.id, p_label);
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------
-- API surface (migration 14 rule): every new function closed, the API ones opened by name
-- ---------------------------------------------------------------------------------------------------------------------
revoke execute on function app.labs_client_state() from public, anon, authenticated;
revoke execute on function app.lab_for_scope(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.footprints_take_sale_terms() from public, anon, authenticated;
revoke execute on function app.footprints_keep_sale_terms() from public, anon, authenticated;
revoke execute on function app.sku_name(public.pack_skus) from public, anon, authenticated;
revoke execute on function app.packs_left_of(uuid, uuid) from public, anon, authenticated;
revoke execute on function app.packs_left(uuid) from public, anon, authenticated;
revoke execute on function app.check_pack_lines(jsonb, jsonb, text) from public, anon, authenticated;
revoke execute on function app.upstream_qc(uuid) from public, anon, authenticated;
revoke execute on function app.profile_allowed(uuid, text) from public, anon, authenticated;
revoke execute on function app.export_docs_of(uuid) from public, anon, authenticated;
revoke execute on function app.set_export_doc(uuid, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function app.add_bill_of_lading(uuid, text) from public, anon, authenticated;
revoke execute on function app.vehicle_ok(text) from public, anon, authenticated;
revoke execute on function app.container_ok(text) from public, anon, authenticated;
grant execute on function app.packs_left(uuid) to authenticated;
grant execute on function app.set_export_doc(uuid, text, text, uuid, text) to authenticated;
grant execute on function app.add_bill_of_lading(uuid, text) to authenticated;
