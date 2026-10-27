-- Migration 71 (Phase 3, release 4 of Veda's combined brief of 19 Oct 2026: Part E1, the evidence pack; item 69 (1) is the
-- app's).
--   E1  a Verified traceability statement of one sealed lot, of one shipment (with its buyer), or of one client order (one
--       section per scope): generated from the records, never typed (app.ep_lot_data, app.ep_order_data), in two copies
--       (shareable by default: no farmer's name or phone, no price; internal: the farmers' names and the sale's price where
--       the scope records prices). Sections: header, origin (villages and districts by share, farmers, GI-area and
--       farm-verified share, GI status), mass balance (each stage in, out, by-products, floor loss and what was closed or
--       written off; milling's outturn against the crop's ceiling, 70 % unless set; sold never above procured), quality
--       (each lab result per market with the lab, its accreditation, the report number and date and the files'
--       fingerprints; a release on the client's written acceptance said as such), documents (the export documents and the
--       shipment's papers with their fingerprints), chain (who recorded and checked each stage, "same person", returns and
--       flags, client staff), packs (batch codes and serial ranges; the codes scanned for an export shipment), verification
--       (the ledger fingerprints of the key blocks; "Verify this document").
--       Issued (app.issue_evidence_pack) automatically when a lot is sealed (its shipment's pack where it went out in one;
--       the client order's too where the shipment is a part of one), or on demand by the scope's managers and its
--       Commercial, Shipment or QR person; versioned: a new version supersedes the old, which is kept. Kept with the season
--       reports (public.reports, kind evidence_pack, ref GV-EP-000123) and verified by the same page (/d/<ref>). Read by
--       whoever reads the season report of each of its scopes; the buyer link's page carries the shareable copy of its
--       sale's pack. The admin's count of reports issued per client per month counts the packs (billed monthly).
-- Additive: new columns of public.reports and their constraints widened (a kind and a ref of their own), a sequence, new
-- functions, one trigger on qr_seals; replaced from their own text, each change named: app.issue_report and
-- app.scope_reports (the season reports only), app.report_head, app.report_content, app.may_read_report_file,
-- app.register_report_file and app.may_write_report_object (a pack's readers: every scope of it), app.public_document
-- (what a pack is of), app.reports_issued (the packs counted), app.buyer_content (the sale's pack). No record changed.
select set_config('app.change_path', 'migration 71', true);

-- 1 · the packs are issued outputs, kept with the season reports ----------------------------------------------------------
alter table public.reports drop constraint if exists reports_kind_check;
alter table public.reports add constraint reports_kind_check check (kind in ('season_report', 'evidence_pack'));
alter table public.reports drop constraint if exists reports_ref_check;
alter table public.reports add constraint reports_ref_check check (
  (kind = 'season_report' and ref ~ '^GV-SR-[0-9]{6,}$') or (kind = 'evidence_pack' and ref ~ '^GV-EP-[0-9]{6,}$'));
alter table public.reports add column if not exists subject_kind text check (subject_kind is null or subject_kind in ('lot', 'shipment', 'order'));
alter table public.reports add column if not exists subject_id uuid;
alter table public.reports add column if not exists subject_code text;
alter table public.reports add column if not exists scope_ids uuid[];
alter table public.reports add column if not exists auto boolean not null default false;
alter table public.reports add constraint reports_subject_shape check (
  (kind = 'season_report' and subject_kind is null and subject_id is null)
  or (kind = 'evidence_pack' and subject_kind is not null and subject_id is not null and subject_code is not null
      and scope_ids is not null and cardinality(scope_ids) >= 1 and scope_id = scope_ids[1]));
create index if not exists reports_subject on public.reports (subject_kind, subject_id, issued_at) where kind = 'evidence_pack';
comment on column public.reports.subject_kind is 'Migration 71 (E1): an evidence pack is of a sealed lot (its QR record), a shipment, or a client order; scope_ids its scopes (the first is scope_id).';
create sequence if not exists public.ep_ref_seq start 1;

-- 2 · the data of one lot or shipment -------------------------------------------------------------------------------------
-- serials as ranges: "TCUP-KNM-KH26-B0001-0011 – 0020" (a run of consecutive codes of one batch is one line)
create or replace function app.ep_ranges(p_serials text[]) returns jsonb
language sql stable security definer set search_path = public as $$
  with s as (select p.serial, p.batch_code, p.size_kg, p.packed_on, p.best_before,
                    coalesce(substring(p.serial from '([0-9]+)$')::bigint, 0) as n
               from public.packs p where p.serial = any (coalesce(p_serials, '{}'))),
  g as (select s.*, s.n - row_number() over (partition by s.batch_code order by s.n) as grp from s),
  r as (select batch_code, min(serial) as first, max(serial) as last, count(*) as cnt, min(n) as lo from g group by batch_code, grp)
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packs', b.packs, 'kg', b.kg, 'sizes', b.sizes,
           'packed_on', b.packed_on, 'best_before', b.best_before,
           'ranges', (select jsonb_agg(case when r.cnt = 1 then r.first else r.first || ' – ' || substring(r.last from '([0-9]+)$') end order by r.lo)
                        from r where r.batch_code = b.batch_code)) order by b.batch_code), '[]'::jsonb)
    from (select batch_code, count(*) as packs, sum(size_kg) as kg, min(packed_on) as packed_on, min(best_before) as best_before,
                 string_agg(distinct trim_scale(size_kg)::text || ' kg', ', ') as sizes
            from s group by batch_code) b
$$;

-- the serials a shipment carries (a carton's code stands for its packs)
create or replace function app.ep_shipment_serials(p_ship uuid) returns text[]
language sql stable security definer set search_path = public as $$
  with c as (select upper(btrim(x)) as code from public.footprints s,
               jsonb_array_elements_text(case when jsonb_typeof(s.payload->'serials') = 'array' then s.payload->'serials' else '[]'::jsonb end) x
              where s.id = p_ship)
  select coalesce(array_agg(distinct x), '{}') from (
    select p.serial as x from c join public.packs p on p.serial = c.code
    union all select p.serial from c join public.packs p on p.carton_code = c.code) y
$$;

create or replace function app.ep_lot_data(p_top uuid, p_internal boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare top public.footprints; sc public.scopes; cr public.crops; cl public.clients; ids uuid[];
        v_ship public.footprints; v_sale public.footprints; v_qr public.footprints; v_seal public.qr_seals;
        v_serials text[]; v_old boolean := false; v_ceiling numeric; v_prices boolean; co public.client_orders;
begin
  select * into top from public.footprints where id = p_top;
  if top.id is null then return null; end if;
  select * into sc from public.scopes where id = top.scope_id;
  select * into cr from public.crops where id = sc.crop_id;
  select * into cl from public.clients where id = sc.client_id;
  ids := array(select x from app.lot_upstream(p_top) x join public.footprints f on f.id = x where f.status not in ('superseded', 'legacy'));
  select f.* into v_ship from public.footprints f where f.id = any (ids) and f.stage_type = 'shipment' order by f.created_at desc limit 1;
  select f.* into v_sale from public.footprints f where f.id = any (ids) and f.stage_type = 'commercial' order by f.created_at desc limit 1;
  if top.stage_type = 'qr_activation' then v_qr := top;
  elsif v_ship.id is not null then
    select f.* into v_qr from public.footprints f join public.qr_seals q on q.footprint_id = f.id where f.prev_footprint_id = v_ship.id limit 1;
  end if;
  select * into v_seal from public.qr_seals where footprint_id = v_qr.id;
  select * into co from public.client_orders where id::text = v_sale.computed->>'client_order_id';
  v_ceiling := coalesce((cr.thresholds->>'milling_outturn_ceiling_pct')::numeric, 70);
  v_prices := p_internal and sc.record_price;
  -- the packs: a shipment's codes; a sealed lot's released packs; else the batches' packs
  if v_ship.id is not null then
    v_serials := app.ep_shipment_serials(v_ship.id);
    if cardinality(v_serials) = 0 then
      v_old := true;
      v_serials := array(select p.serial from public.packs p where p.footprint_id = any (ids) and p.status = 'packed');
    end if;
  elsif v_qr.id is not null then
    v_serials := array(select r.serial from app.lot_released_packs(v_qr.id) r);
    v_old := coalesce((select bool_or(r.old_data) from app.lot_released_packs(v_qr.id) r), false);
  else
    v_serials := array(select p.serial from public.packs p where p.footprint_id = any (ids) and p.status = 'packed');
  end if;

  return jsonb_build_object(
    'header', jsonb_build_object(   -- the scope's id in the internal copy only (the shareable copy carries no internal IDs)
      'client', cl.name, 'client_code', cl.code, 'crop', cr.name, 'gi_tag', cr.gi_tag, 'season', sc.season_code, 'geography', sc.geography,
      'state', (select st.name from public.states st where st.id = sc.state_id), 'scope', app.cv_scope_label(sc.id), 'scope_id', case when p_internal then sc.id end,
      'top', top.footprint_code, 'top_stage', top.stage_type,
      'lot', coalesce(v_qr.footprint_code, top.footprint_code), 'qr_code', v_seal.qr_code, 'sealed_at', v_seal.sealed_at,
      'shipment', v_ship.footprint_code, 'dispatch_date', v_ship.payload->>'dispatch_date', 'invoice_no', v_ship.payload->>'invoice_no',
      'sale', v_sale.footprint_code, 'buyer', v_sale.computed->>'buyer', 'buyer_country', v_sale.computed->>'buyer_country',
      'market', v_sale.computed->>'market', 'market_name', v_sale.computed->>'market_name',
      'destination_country', v_sale.computed->>'destination_country', 'order_no', v_sale.computed->>'order_no',
      'client_order', co.code, 'data_note', sc.data_note),
    'origin', (
      with src as (select s.share, e.farmer_id, e.farm_verified, app.entry_gi(e.id) as gi, fa.village, fa.district, fa.farmer_code, fa.name
                     from app.lot_sources(p_top) s join public.footprints e on e.id = s.entry_id left join public.farmers fa on fa.id = e.farmer_id)
      select jsonb_build_object(
        'villages', coalesce((select jsonb_agg(jsonb_build_object('village', v.village, 'district', v.district, 'share_pct', v.pct, 'farmers', v.n)
                                order by v.pct desc, v.village)
                       from (select village, district, round(sum(share) * 100, 1) as pct, count(distinct farmer_id) as n from src
                              where farmer_id is not null group by village, district) v), '[]'::jsonb),
        'districts', coalesce((select jsonb_agg(jsonb_build_object('district', v.district, 'share_pct', v.pct) order by v.pct desc, v.district)
                       from (select district, round(sum(share) * 100, 1) as pct from src where farmer_id is not null group by district) v), '[]'::jsonb),
        'farmers', (select count(distinct farmer_id) from src),
        'gi_pct', (select round(coalesce(sum(share) filter (where gi = 'gi'), 0) * 100, 1) from src),
        'farm_verified_pct', (select round(coalesce(sum(share) filter (where farm_verified), 0) * 100, 1) from src),
        'gi_status', app.lot_gi_status(p_top), 'farm_verified', app.lot_farm_verified(p_top),
        'shares_note', 'documented proportions by mass balance, not physical identity')
        || case when p_internal then jsonb_build_object('farmer_list', coalesce((select jsonb_agg(jsonb_build_object('code', f.farmer_code, 'name', f.name,
                  'village', f.village, 'district', f.district, 'share_pct', f.pct) order by f.pct desc, f.name)
                from (select farmer_code, name, village, district, round(sum(share) * 100, 1) as pct from src where farmer_id is not null
                       group by farmer_code, name, village, district) f), '[]'::jsonb)) else '{}'::jsonb end
      from (select 1) d),
    'mass_balance', (
      with r as (select f.*, app.record_parts(f) as pt, array_position(sc.chain, f.stage_type) as pos from public.footprints f where f.id = any (ids)),
      g as (select r.stage_type as stage, min(r.pos) as pos, count(*) as records,
                   sum((r.pt->>'in')::numeric) as in_kg, sum((r.pt->>'out')::numeric) as out_kg,
                   sum((r.pt->>'by_products')::numeric) as by_products_kg, sum((r.pt->>'other')::numeric) as other_kg,
                   sum((r.pt->>'transit_in')::numeric) as transit_kg, sum((r.pt->>'floor_loss')::numeric) as floor_loss_kg,
                   coalesce(sum((select sum(lc.floor_loss_kg) from public.lot_closures lc where lc.footprint_id = r.id and lc.kind = 'floor_loss')), 0) as closed_kg,
                   coalesce(sum((select sum(lc.floor_loss_kg) from public.lot_closures lc where lc.footprint_id = r.id and lc.kind = 'written_off')), 0) as written_off_kg,
                   sum((r.computed->>'head_rice_kg')::numeric) as head_kg, sum((r.computed->>'broken_kg')::numeric) as broken_kg,
                   sum((r.computed->>'husk_kg')::numeric) as husk_kg, sum((r.computed->>'bran_kg')::numeric) as bran_kg,
                   sum((r.computed->>'wastage_kg')::numeric) as wastage_kg, sum((r.computed->>'sample_qty_kg')::numeric) as sample_kg
              from r group by r.stage_type)
      select jsonb_build_object(
        'stages', coalesce((select jsonb_agg(jsonb_build_object('stage', g.stage, 'pos', g.pos, 'records', g.records, 'in_kg', g.in_kg, 'out_kg', g.out_kg,
                   'by_products_kg', g.by_products_kg, 'other_kg', g.other_kg, 'transit_kg', g.transit_kg, 'floor_loss_kg', g.floor_loss_kg,
                   'closed_kg', g.closed_kg, 'written_off_kg', g.written_off_kg)
                   || case when g.stage = 'milling' and coalesce(g.in_kg, 0) > 0 then jsonb_build_object('head_rice_kg', g.head_kg, 'broken_kg', g.broken_kg,
                        'husk_kg', g.husk_kg, 'bran_kg', g.bran_kg,
                        'outturn_pct', round((coalesce(g.head_kg, 0) + coalesce(g.broken_kg, 0)) / g.in_kg * 100, 1), 'ceiling_pct', v_ceiling,
                        'over_ceiling', round((coalesce(g.head_kg, 0) + coalesce(g.broken_kg, 0)) / g.in_kg * 100, 1) > v_ceiling) else '{}'::jsonb end
                   || case when g.stage = 'packing' and coalesce(g.in_kg, 0) > 0 then jsonb_build_object('wastage_kg', g.wastage_kg,
                        'wastage_pct', round(coalesce(g.wastage_kg, 0) / g.in_kg * 100, 1)) else '{}'::jsonb end
                   || case when g.stage = 'qc' then jsonb_build_object('sample_kg', g.sample_kg) else '{}'::jsonb end
                   order by g.pos, g.stage) from g), '[]'::jsonb),
        'procured_kg', coalesce((select sum(out_kg) from g where stage in ('procurement', 'lot_inward')), 0),
        'sold_kg', coalesce((select sum(out_kg) from g where stage = 'commercial'), 0),
        'shipped_kg', coalesce((select sum(in_kg) from g where stage = 'shipment'), 0),
        'sold_within_procured', coalesce((select sum(out_kg) from g where stage = 'commercial'), 0)
                                <= coalesce((select sum(out_kg) from g where stage in ('procurement', 'lot_inward')), 0) + app.kg_tolerance())
      from (select 1) d),
    'quality', coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'on', x.happened_on,
                   'lab', app.qc_lab(x.id)->>'name', 'accreditation_no', app.qc_lab(x.id)->>'accreditation_no',
                   'report_no', app.qc_lab(x.id)->>'report_no', 'report_date', app.qc_lab(x.id)->>'report_date',
                   'sample', (select smp.code from public.qc_samples smp where smp.id::text = x.payload->>'sample_ref'),
                   'domestic', v.domestic_verdict, 'export', v.export_verdict,
                   'accepted', v.override is not null, 'accepted_market', v.override->>'market',
                   'markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name, 'verdict', pv.verdict) order by pv.code), '[]'::jsonb)
                                 from public.qc_profile_verdicts pv where pv.footprint_id = x.id),
                   'files', (select coalesce(jsonb_agg(jsonb_build_object('label', a.label, 'sha256', a.sha256, 'at', a.created_at) order by a.created_at), '[]'::jsonb)
                               from public.attachments a where a.footprint_id = x.id and a.label in ('lab_report', 'acceptance'))) order by x.created_at)
                   from public.footprints x join public.qc_verdicts v on v.footprint_id = x.id where x.id = any (ids)), '[]'::jsonb),
    'documents', jsonb_build_object(
      'export', case when v_sale.computed->>'market' = 'export' then coalesce((select jsonb_agg(d || jsonb_build_object('sha256',
                   (select a.sha256 from public.attachments a where a.id::text = d->>'attachment_id')) - 'attachment_id') from jsonb_array_elements(app.export_docs_of(v_sale.id)) d), '[]'::jsonb)
                    else '[]'::jsonb end,
      'shipment', case when v_ship.id is null then null else jsonb_build_object('code', v_ship.footprint_code, 'market', v_ship.computed->>'market',
                   'invoice_no', v_ship.payload->>'invoice_no', 'lr_no', v_ship.payload->>'lr_no', 'eway_bill_no', v_ship.payload->>'eway_bill_no',
                   'container_no', v_ship.computed->>'container_no', 'seal_no', v_ship.payload->>'seal_no', 'shipping_bill_no', v_ship.payload->>'shipping_bill_no',
                   'bl_no', coalesce((select b.bl_no from public.bills_of_lading b where b.footprint_id = v_ship.id), v_ship.payload->>'bl_no'),
                   'delivered', (select jsonb_build_object('on', d.received_on, 'received_kg', d.received_kg) from public.deliveries d
                                  where d.shipment_id = v_ship.id order by d.confirmed_at desc limit 1)) end,
      'files', coalesce((select jsonb_agg(jsonb_build_object('label', a.label, 'record', x.footprint_code, 'sha256', a.sha256, 'at', a.created_at) order by a.created_at)
                   from public.attachments a join public.footprints x on x.id = a.footprint_id
                  where a.footprint_id in (v_ship.id, v_sale.id) and a.label in ('loading_photo', 'pod', 'bill_of_lading', 'document')), '[]'::jsonb)),
    'chain', (
      with r as (select f.*, array_position(sc.chain, f.stage_type) as pos from public.footprints f where f.id = any (ids))
      select coalesce(jsonb_agg(jsonb_build_object('stage', g.stage, 'pos', g.pos, 'records', g.n, 'codes', g.codes,
               'recorded_by', g.rec, 'verified_by', g.ver, 'first_on', g.first_on, 'last_on', g.last_on,
               'same_person', g.same, 'client_staff', g.staff, 'verified', g.verified,
               'returns', g.returns, 'flags', g.flags) order by g.pos, g.stage), '[]'::jsonb)
        from (select r.stage_type as stage, min(r.pos) as pos, count(*) as n,
                     (array_agg(r.footprint_code order by r.created_at))[1:5] as codes,
                     array_agg(distinct cu.display_name) filter (where cu.display_name is not null) as rec,
                     array_agg(distinct vu.display_name) filter (where vu.display_name is not null) as ver,
                     min(coalesce(r.happened_on, r.created_at::date)) as first_on, max(coalesce(r.happened_on, r.created_at::date)) as last_on,
                     count(*) filter (where r.stage_type <> 'qr_activation' and r.verified_by is not null and r.verified_by = r.created_by) as same,
                     count(*) filter (where r.client_staff) as staff, bool_and(r.status = 'verified') as verified,
                     coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'reason', fr.reason, 'status', fr.status) order by fr.returned_at)
                                 from public.footprint_returns fr join public.footprints x on x.id = fr.footprint_id
                                where fr.footprint_id = any (array_agg(r.id))), '[]'::jsonb) as returns,
                     coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'kind', fl.kind, 'text', fl.text, 'status', fl.status) order by fl.created_at)
                                 from public.flags fl join public.footprints x on x.id = fl.footprint_id
                                where fl.footprint_id = any (array_agg(r.id))), '[]'::jsonb) as flags
                from r left join public.app_users cu on cu.id = r.created_by left join public.app_users vu on vu.id = r.verified_by
               group by r.stage_type) g),
    'packs', jsonb_build_object('batches', app.ep_ranges(v_serials), 'count', coalesce(cardinality(v_serials), 0), 'old_data', v_old,
               'scanned', case when v_ship.id is not null and v_ship.computed->>'market' = 'export' and not v_old
                               then to_jsonb((select array_agg(x order by x) from unnest(v_serials) x)) end),
    'verification', jsonb_build_object(
      'seal', case when v_seal.footprint_id is null then null else jsonb_build_object('qr_code', v_seal.qr_code, 'sealed_at', v_seal.sealed_at, 'ledger_hash', v_seal.ledger_hash) end,
      'blocks', coalesce((select jsonb_agg(jsonb_build_object('code', b.code, 'stage', b.stage, 'event', b.event, 'seq', b.seq, 'hash', b.hash) order by b.seq)
                 from (select distinct on (l.footprint_id) l.footprint_id, x.footprint_code as code, x.stage_type as stage, l.event, l.seq, l.hash
                         from public.ledger l join public.footprints x on x.id = l.footprint_id
                        where l.footprint_id = any (ids) and x.stage_type not in ('procurement', 'lot_inward')
                        order by l.footprint_id, l.seq desc) b), '[]'::jsonb),
      'procurement_blocks', (select count(*) from public.ledger l join public.footprints x on x.id = l.footprint_id
                              where l.footprint_id = any (ids) and x.stage_type in ('procurement', 'lot_inward'))),
    'internal', p_internal)
    || case when v_prices and v_sale.id is not null then jsonb_build_object('price', (select jsonb_build_object('price_per_kg', t.price_per_kg,
              'currency', t.currency, 'incoterms', t.incoterms, 'total_value', t.total_value) from public.sale_terms t where t.footprint_id = v_sale.id))
            else '{}'::jsonb end;
end $$;

-- the tops of a client order: each part's shipments that stand, or the part itself while it has none; by scope
create or replace function app.ep_order_tops(p_order uuid) returns table (scope_id uuid, top uuid)
language sql stable security definer set search_path = public as $$
  select p.scope_id, coalesce(s.id, p.id)
    from app.order_parts(p_order) p
    left join public.footprints s on s.prev_footprint_id = p.id and s.stage_type = 'shipment' and s.status not in ('superseded', 'legacy')
$$;

create or replace function app.ep_order_data(p_order uuid, p_internal boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'header', (select jsonb_build_object('client', c.name, 'client_code', c.code, 'crop', cr.name, 'gi_tag', cr.gi_tag,
                 'client_order', o.code, 'order_no', o.order_no, 'buyer', (select b.name from public.buyers b where b.id = o.buyer_id),
                 'buyer_country', (select b.country from public.buyers b where b.id = o.buyer_id), 'market', o.market,
                 'market_name', (select m.name from public.market_profiles m where m.crop_id = o.crop_id and m.code = o.market_code order by m.status = 'active' desc limit 1),
                 'destination_country', o.destination_country, 'invoice_no', o.invoice_no)
                 from public.client_orders o join public.clients c on c.id = o.client_id join public.crops cr on cr.id = o.crop_id where o.id = p_order),
    'scopes', coalesce((select jsonb_agg(jsonb_build_object('scope_id', case when p_internal then s.id end, 'scope', app.cv_scope_label(s.id),
                 'state', (select st.name from public.states st where st.id = s.state_id), 'season', s.season_code, 'geography', s.geography,
                 'lots', (select jsonb_agg(app.ep_lot_data(t.top, p_internal) order by t.top) from app.ep_order_tops(p_order) t where t.scope_id = s.id))
               order by (select st.name from public.states st where st.id = s.state_id), s.geography)
               from public.scopes s where s.id in (select t.scope_id from app.ep_order_tops(p_order) t)), '[]'::jsonb),
    'internal', p_internal)
$$;

-- 3 · issuing a pack ------------------------------------------------------------------------------------------------------
-- the subject of a sealed lot: the shipment it went out in, else the lot itself
create or replace function app.ep_subject_of_seal(p_qr uuid) returns table (kind text, id uuid)
language sql stable security definer set search_path = public as $$
  select case when s.id is not null then 'shipment' else 'lot' end, coalesce(s.id, p_qr)
    from public.footprints q left join public.footprints s on s.id = q.prev_footprint_id and s.stage_type = 'shipment'
   where q.id = p_qr
$$;

-- who issues one on demand: who reads it (sees each of its scopes whole) and runs one of them: its Client Manager or State
-- Manager, or the admin. Never a client account.
create or replace function app.ep_subject_scopes(p_kind text, p_id uuid) returns uuid[]
language sql stable security definer set search_path = public as $$
  select case p_kind when 'order' then array(select distinct t.scope_id from app.ep_order_tops(p_id) t order by 1)
                     when 'lot' then array(select f.scope_id from public.footprints f where f.id = p_id)
                     when 'shipment' then array(select f.scope_id from public.footprints f where f.id = p_id) end
$$;
create or replace function app.may_issue_pack(p_kind text, p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and not app.is_client_login() and p_kind in ('lot', 'shipment', 'order')
     and cardinality(coalesce(app.ep_subject_scopes(p_kind, p_id), '{}')) > 0
     and (select bool_and(app.sees_whole_scope(x)) from unnest(app.ep_subject_scopes(p_kind, p_id)) x)
     and (app.is_admin() or exists (select 1 from unnest(app.ep_subject_scopes(p_kind, p_id)) x
                                     where app.manages_scope(app.current_user_id(), x) or app.sm_of_scope(x)))
$$;

-- the core: makes the data of both copies, keeps them as the next version, supersedes the one before; a ledger block
create or replace function app.ep_issue(p_kind text, p_id uuid, p_by uuid, p_auto boolean) returns public.reports
language plpgsql volatile security definer set search_path = public, extensions as $$
declare f public.footprints; o public.client_orders; v_scopes uuid[]; v_client uuid; v_code text; d_int jsonb; d_sh jsonb; v_ver int; r public.reports;
begin
  if p_kind in ('lot', 'shipment') then
    select * into f from public.footprints where id = p_id;
    if f.id is null or (p_kind = 'lot' and (f.stage_type <> 'qr_activation' or not exists (select 1 from public.qr_seals q where q.footprint_id = f.id)))
       or (p_kind = 'shipment' and (f.stage_type <> 'shipment' or f.status in ('superseded', 'legacy'))) then
      raise exception 'an evidence pack is of a sealed lot, a shipment or a client order' using errcode = '22023'; end if;
    v_scopes := array[f.scope_id]; v_client := f.client_id;
    v_code := coalesce((select q.qr_code from public.qr_seals q where q.footprint_id = f.id), f.footprint_code);
    d_int := app.ep_lot_data(f.id, true); d_sh := app.ep_lot_data(f.id, false);
  elsif p_kind = 'order' then
    select * into o from public.client_orders where id = p_id;
    if o.id is null or not exists (select 1 from app.order_parts(o.id)) then
      raise exception 'a client order''s evidence pack needs a part' using errcode = '22023'; end if;
    v_scopes := array(select distinct t.scope_id from app.ep_order_tops(o.id) t order by 1);
    v_client := o.client_id; v_code := o.code;
    d_int := app.ep_order_data(o.id, true); d_sh := app.ep_order_data(o.id, false);
  else
    raise exception 'an evidence pack is of a sealed lot, a shipment or a client order' using errcode = '22023';
  end if;
  d_int := jsonb_build_object('kind', p_kind) || d_int; d_sh := jsonb_build_object('kind', p_kind) || d_sh;
  perform pg_advisory_xact_lock(hashtext('evidence_pack:' || p_id::text));
  select coalesce(max(version), 0) + 1 into v_ver from public.reports where kind = 'evidence_pack' and subject_kind = p_kind and subject_id = p_id;
  insert into public.reports (ref, kind, scope_id, client_id, final, version, issued_by, issued_to, data_hash, data_shareable, data_internal,
                              subject_kind, subject_id, subject_code, scope_ids, auto)
  values ('GV-EP-' || lpad(nextval('public.ep_ref_seq')::text, 6, '0'), 'evidence_pack', v_scopes[1], v_client, true, v_ver, p_by,
          (select c.name from public.clients c where c.id = v_client),
          encode(digest(d_int::text, 'sha256'), 'hex'), d_sh, d_int, p_kind, p_id, v_code, v_scopes, p_auto)
  returning * into r;
  update public.reports set status = 'superseded', superseded_by = r.id, superseded_at = now()
   where kind = 'evidence_pack' and subject_kind = p_kind and subject_id = p_id and id <> r.id and status = 'valid';
  perform app.ledger_append(null, v_scopes[1], 'report', p_by, jsonb_build_object('act', 'issued', 'kind', 'evidence_pack', 'report_id', r.id,
    'ref', r.ref, 'version', r.version, 'data_hash', r.data_hash, 'subject_kind', p_kind, 'subject_id', p_id, 'subject', v_code,
    'scope_ids', to_jsonb(v_scopes), 'auto', p_auto));
  perform app.audit_as(p_by, 'evidence_pack_issued', v_scopes[1], jsonb_build_object('ref', r.ref, 'version', r.version, 'subject', v_code,
    'subject_kind', p_kind, 'auto', p_auto), false);
  return r;
end $$;

create or replace function app.issue_evidence_pack(p_kind text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.reports;
begin
  if not coalesce(app.may_issue_pack(p_kind, p_id), false) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  r := app.ep_issue(p_kind, p_id, app.current_user_id(), false);
  return app.report_head(r);
end $$;

-- when a lot is sealed: its pack (its shipment's, where it went out in one) and, where the shipment is a part of a client
-- order, the order's. A pack that could not be made does not stop the seal: it is in the Audit log, and made on demand.
create or replace function app.qr_seals_evidence_pack() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; v_order uuid;
begin
  select * into s from app.ep_subject_of_seal(new.footprint_id);
  begin
    perform app.ep_issue(s.kind, s.id, new.sealed_by, true);
    if s.kind = 'shipment' then
      select (p.computed->>'client_order_id')::uuid into v_order
        from public.footprints sh join public.footprints p on p.id = sh.prev_footprint_id where sh.id = s.id and p.computed ? 'client_order_id';
      if v_order is not null then perform app.ep_issue('order', v_order, new.sealed_by, true); end if;
    end if;
  exception when others then
    perform app.audit_as(new.sealed_by, 'evidence_pack_failed', (select f.scope_id from public.footprints f where f.id = new.footprint_id),
      jsonb_build_object('qr_code', new.qr_code, 'error', left(sqlerrm, 300)), true);
  end;
  return null;
end $$;
drop trigger if exists qr_seals_z2_evidence_pack on public.qr_seals;
create trigger qr_seals_z2_evidence_pack after insert on public.qr_seals for each row execute function app.qr_seals_evidence_pack();

-- 4 · reading packs -------------------------------------------------------------------------------------------------------
-- a report's readers: whoever sees each of its scopes whole (a season report: its one scope)
create or replace function app.report_readable(r public.reports) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null and coalesce((select bool_and(app.sees_whole_scope(x)) from unnest(coalesce(r.scope_ids, array[r.scope_id])) x), false)
$$;
create or replace function app.report_internal_ok(r public.reports) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select bool_and(app.may_report_internal(x)) from unnest(coalesce(r.scope_ids, array[r.scope_id])) x), false)
$$;

-- the packs of a subject (a lot, a shipment, an order), or of a scope (p_kind 'scope'), as their heads
create or replace function app.evidence_packs(p_kind text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_int boolean;
begin
  if app.current_user_id() is null then raise exception 'record not found' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'packs', coalesce((select jsonb_agg(app.report_head(r) || jsonb_build_object('internal_ok', app.report_internal_ok(r), 'may_store', app.may_write_report_file(r.id),
               'files', (select coalesce(jsonb_object_agg(k, jsonb_build_object('sha256', v->>'sha256', 'bytes', v->'bytes', 'at', v->'at')), '{}'::jsonb)
                           from jsonb_each(r.files) e(k, v) where k like '%_shareable' or app.report_internal_ok(r)))
               order by r.issued_at desc)
               from public.reports r
              where r.kind = 'evidence_pack' and app.report_readable(r)
                and case p_kind when 'scope' then p_id = any (r.scope_ids)
                                when 'lot' then r.subject_kind = 'lot' and r.subject_id = p_id
                                when 'shipment' then r.subject_kind = 'shipment' and r.subject_id = p_id
                                when 'order' then r.subject_kind = 'order' and r.subject_id = p_id
                                else false end), '[]'::jsonb),
    'may_issue', case when p_kind in ('lot', 'shipment', 'order') then coalesce(app.may_issue_pack(p_kind, p_id), false) else false end);
end $$;

-- 8 · the functions replaced, each from its text as migration 70 left it, with the change named ---------------------------
-- E1: a season report's version and what it supersedes are the season reports' only (the packs are kept beside them)
CREATE OR REPLACE FUNCTION app.issue_report(p_scope uuid, p_final boolean, p_closure uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare me uuid := app.current_user_id(); sc public.scopes; v_ref text; v_ver int; d_int jsonb; d_sh jsonb; v_cl jsonb; r public.reports;
        v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  select * into sc from public.scopes where id = p_scope;
  if p_final then
    select version into v_ver from public.scope_closures where id = p_closure and scope_id = p_scope and status = 'confirmed';
    if v_ver is null then raise exception 'a final report follows a confirmed close' using errcode = '23514'; end if;
  else
    select coalesce(max(version), 0) + 1 into v_ver from public.reports where scope_id = p_scope and not final and kind = 'season_report';   -- migration 71
  end if;
  v_ref := 'GV-SR-' || lpad(nextval('public.report_ref_seq')::text, 6, '0');
  d_int := app.season_report_data(p_scope, true);
  d_sh := app.season_report_data(p_scope, false);
  if p_final then
    v_cl := app.closure_summary(p_closure);
    d_int := d_int || jsonb_build_object('closure', v_cl);
    d_sh := d_sh || jsonb_build_object('closure', v_cl);
  end if;
  insert into public.reports (ref, scope_id, client_id, final, version, issued_by, issued_to, period_from, period_to, closure_id,
                              data_hash, data_shareable, data_internal)
  values (v_ref, p_scope, sc.client_id, p_final, v_ver, me, (select c.name from public.clients c where c.id = sc.client_id),
          (d_int->'cover'->>'period_from')::date, v_today, p_closure,
          encode(digest(d_int::text, 'sha256'), 'hex'), d_sh, d_int)
  returning * into r;
  update public.reports set status = 'superseded', superseded_by = r.id, superseded_at = now()
   where scope_id = p_scope and id <> r.id and status = 'valid' and (p_final or not final) and kind = 'season_report';   -- migration 71
  perform app.ledger_append(null, p_scope, 'report', me, jsonb_build_object('act', 'issued', 'report_id', r.id, 'ref', r.ref,
    'final', r.final, 'version', r.version, 'data_hash', r.data_hash, 'scope_id', p_scope, 'closure_id', p_closure));
  perform app.audit('report_issued', p_scope, jsonb_build_object('ref', r.ref, 'final', r.final, 'version', r.version), false);
  return jsonb_build_object('id', r.id, 'ref', r.ref, 'final', r.final, 'version', r.version, 'issued_at', r.issued_at, 'status', r.status);
end $function$;

-- E1: the scope's season reports (its packs are listed by app.evidence_packs)
CREATE OR REPLACE FUNCTION app.scope_reports(p_scope uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_int boolean;
begin
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.sees_whole_scope(p_scope) then
    raise exception 'record not found' using errcode = 'P0002'; end if;
  v_int := app.may_report_internal(p_scope);
  return coalesce((select jsonb_agg(app.report_head(r) || jsonb_build_object('files',
             (select coalesce(jsonb_object_agg(k, jsonb_build_object('sha256', v->>'sha256', 'bytes', v->'bytes', 'at', v->'at')), '{}'::jsonb)
                from jsonb_each(r.files) e(k, v) where k like '%_shareable' or v_int))
           order by r.issued_at desc) from public.reports r where r.scope_id = p_scope and r.kind = 'season_report'), '[]'::jsonb);   -- migration 71
end $function$;

-- E1: a report says what it is (a pack: of which lot, shipment or order, in which scopes)
CREATE OR REPLACE FUNCTION app.report_head(r reports)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('id', r.id, 'ref', r.ref, 'scope_id', r.scope_id, 'final', r.final, 'version', r.version, 'status', r.status,
           'issued_at', r.issued_at, 'issued_by', (select u.display_name from public.app_users u where u.id = r.issued_by),
           'issued_to', r.issued_to, 'period_from', r.period_from, 'period_to', r.period_to, 'data_hash', r.data_hash,
           'superseded_by', (select s.ref from public.reports s where s.id = r.superseded_by), 'superseded_at', r.superseded_at,
           'withdrawn_at', r.withdrawn_at, 'withdrawn_reason', r.withdrawn_reason,
           'kind', r.kind, 'subject_kind', r.subject_kind, 'subject_id', r.subject_id, 'subject_code', r.subject_code,   -- migration 71
           'scope_ids', to_jsonb(coalesce(r.scope_ids, array[r.scope_id])), 'auto', r.auto) $function$;

-- E1: a report is read by whoever sees each of its scopes whole (a pack of an order: all its scopes)
CREATE OR REPLACE FUNCTION app.report_content(p_report uuid, p_copy text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.reports;
begin
  select * into r from public.reports where id = p_report;
  if r.id is null or app.current_user_id() is null or not app.report_readable(r) then   -- migration 71
    raise exception 'record not found' using errcode = 'P0002'; end if;
  if p_copy is null or p_copy not in ('shareable', 'internal') then raise exception 'a report is a shareable or an internal copy' using errcode = '22023'; end if;
  if p_copy = 'internal' and not app.report_internal_ok(r) then   -- migration 71
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy' using errcode = '42501'; end if;
  perform app.audit('report_read', r.scope_id, jsonb_build_object('ref', r.ref, 'copy', p_copy), false);
  return jsonb_build_object('report', app.report_head(r), 'copy', p_copy,
    'data', case when p_copy = 'internal' then r.data_internal else r.data_shareable end);
end $function$;

-- E1: a report's files, likewise
CREATE OR REPLACE FUNCTION app.may_read_report_file(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_file text; r public.reports;
begin
  if p_name !~ '^[0-9a-f-]{36}/(shareable|internal)\.(en|hi)\.(pdf|xlsx|json)$' then return false; end if;   -- migration 71: a pack's JSON
  v_id := split_part(p_name, '/', 1)::uuid; v_file := split_part(p_name, '/', 2);
  select * into r from public.reports where id = v_id;
  if r.id is null or app.current_user_id() is null or not app.report_readable(r) then return false; end if;   -- migration 71
  return v_file like 'shareable.%' or app.report_internal_ok(r);   -- migration 71
end $function$;

-- E1: a report's files are stored by its writers who read it (every scope of a pack)
CREATE OR REPLACE FUNCTION app.register_report_file(p_report uuid, p_copy text, p_format text, p_lang text, p_sha256 text, p_bytes bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.current_user_id(); r public.reports; v_key text; v_path text;
begin
  select * into r from public.reports where id = p_report for update;
  if r.id is null or me is null or not app.report_readable(r) then raise exception 'record not found' using errcode = 'P0002'; end if;   -- migration 71
  if not app.may_write_report_file(r.id) then raise exception 'report: the Client Manager or the State Manager stores a report''s files' using errcode = '42501'; end if;
  if r.kind = 'evidence_pack' and (p_copy not in ('shareable', 'internal') or p_format not in ('pdf', 'json') or p_lang not in ('en', 'hi')) then   -- migration 71
    raise exception 'an evidence pack''s file is its PDF or its JSON, of one copy, in English or Hindi' using errcode = '22023'; end if;
  if p_copy not in ('shareable', 'internal') or p_format not in ('pdf', 'xlsx', 'json') or p_lang not in ('en', 'hi') or (p_format = 'json' and r.kind <> 'evidence_pack') then
    raise exception 'a report file is a PDF or an Excel file of one copy, in English or Hindi' using errcode = '22023'; end if;
  if p_copy = 'internal' and not app.report_internal_ok(r) then raise exception 'the internal copy is for the people of this scope' using errcode = '42501'; end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' or p_bytes is null or p_bytes <= 0 then raise exception 'a file''s SHA-256 and size' using errcode = '22023'; end if;
  v_key := p_format || '_' || p_lang || '_' || p_copy;
  v_path := r.id || '/' || p_copy || '.' || p_lang || '.' || p_format;
  if r.files ? v_key then raise exception 'report: this file is stored already' using errcode = '23505'; end if;
  update public.reports set files = files || jsonb_build_object(v_key, jsonb_build_object('path', v_path, 'sha256', p_sha256, 'bytes', p_bytes,
           'at', now(), 'by', (select u.display_name from public.app_users u where u.id = me)))
   where id = r.id returning * into r;
  perform app.ledger_append(null, r.scope_id, 'report', me, jsonb_build_object('act', 'file', 'report_id', r.id, 'ref', r.ref,
    'copy', p_copy, 'format', p_format, 'lang', p_lang, 'sha256', p_sha256, 'bytes', p_bytes));
  return app.report_head(r) || jsonb_build_object('path', v_path);
end $function$;

-- E1: a pack's files are stored by its issuer, the Client Manager or State Manager of any of its scopes, or the admin (who reads every scope of an order's pack)
CREATE OR REPLACE FUNCTION app.may_write_report_file(p_report uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from public.reports r where r.id = p_report and r.status <> 'withdrawn'
                   and app.current_user_id() is not null and not app.is_client_login()
                   and (r.issued_by = app.current_user_id() or app.manages_scope(app.current_user_id(), r.scope_id) or app.sm_of_scope(r.scope_id)
                        or (r.kind = 'evidence_pack' and (app.is_admin() or exists (select 1 from unnest(r.scope_ids) x   -- migration 71
                              where app.manages_scope(app.current_user_id(), x) or app.sm_of_scope(x)))))) $function$;

-- E1: likewise in the store
CREATE OR REPLACE FUNCTION app.may_write_report_object(p_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r public.reports;
begin
  if p_name !~ '^[0-9a-f-]{36}/(shareable|internal)\.(en|hi)\.(pdf|xlsx|json)$' then return false; end if;   -- migration 71: a pack's JSON
  select * into r from public.reports where id = split_part(p_name, '/', 1)::uuid;
  if r.id is null or not app.may_write_report_file(r.id) then return false; end if;
  return p_name like '%/shareable.%' or app.report_internal_ok(r);   -- migration 71
end $function$;

-- E1: "Verify this document" says what a pack is of (a lot, a shipment, an order) and in how many scopes
CREATE OR REPLACE FUNCTION app.public_document(p_ref text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('ref', r.ref, 'kind', r.kind, 'final', r.final, 'version', r.version, 'status', r.status,
           'issued_at', r.issued_at, 'issued_to', r.issued_to, 'period_from', r.period_from, 'period_to', r.period_to,
           'crop', cr.name, 'season', s.season_code, 'geography', s.geography, 'state', st.name,
           'superseded_by', (select x.ref from public.reports x where x.id = r.superseded_by), 'superseded_at', r.superseded_at,
           'withdrawn_at', r.withdrawn_at,
           'subject_kind', r.subject_kind, 'subject', r.subject_code, 'scopes', coalesce(cardinality(r.scope_ids), 1),   -- migration 71
           'files', coalesce((select jsonb_agg(jsonb_build_object('copy', split_part(k, '_', 3), 'format', split_part(k, '_', 1), 'lang', split_part(k, '_', 2),
                                'sha256', v->>'sha256', 'bytes', v->'bytes') order by k) from jsonb_each(r.files) e(k, v)), '[]'::jsonb))
    from public.reports r join public.scopes s on s.id = r.scope_id join public.crops cr on cr.id = s.crop_id
    left join public.states st on st.id = s.state_id
   where r.ref = upper(btrim(p_ref)) $function$;

-- E1: the billing count: the evidence packs issued per client per month beside the season reports
CREATE OR REPLACE FUNCTION app.reports_issued(p_months integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not app.is_admin() then raise exception 'the admin reads the reports issued' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('month', m, 'client', c.name, 'client_code', c.code, 'final', fin, 'interim', intr,
                     'evidence_packs', ep, 'total', fin + intr + ep) order by m desc, c.name)
                     from (select to_char(r.issued_at at time zone 'Asia/Kolkata', 'YYYY-MM') as m, r.client_id,
                                  count(*) filter (where r.final and r.kind = 'season_report') as fin, count(*) filter (where not r.final) as intr,
                                  count(*) filter (where r.kind = 'evidence_pack') as ep
                             from public.reports r
                            where r.issued_at >= date_trunc('month', now() at time zone 'Asia/Kolkata') - make_interval(months => greatest(p_months, 1) - 1)
                            group by 1, 2) x join public.clients c on c.id = x.client_id), '[]'::jsonb);
end $function$;

-- E1: the buyer's page carries the shareable copy of its sale's evidence pack (the client order's, else its shipment's)
CREATE OR REPLACE FUNCTION app.buyer_content(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                   'eway_bill_no', s.payload->>'eway_bill_no', 'transporter', s.payload->>'transporter', 'lr_no', s.payload->>'lr_no',   -- migration 57: no vehicle
                   'container_no', s.computed->>'container_no', 'seal_no', s.payload->>'seal_no', 'shipping_bill_no', s.payload->>'shipping_bill_no',
                   'vessel', s.payload->>'vessel', 'port_loading', s.payload->>'port_loading', 'port_discharge', s.payload->>'port_discharge',
                   'bl_no', coalesce((select b.bl_no from public.bills_of_lading b where b.footprint_id = s.id), s.payload->>'bl_no'),
                   'packs', s.computed->'packs', 'kg', s.qty_out, 'pack_codes', s.computed->'serials_count',
                   'delivery', (select jsonb_build_object('on', d.received_on, 'received_kg', d.received_kg, 'note', d.note)
                                  from public.deliveries d where d.shipment_id = s.id order by d.confirmed_at desc limit 1)) order by s.created_at)
                   from public.footprints s where s.id = any (v_ships)), '[]'::jsonb),
    'lab', coalesce((select jsonb_agg(jsonb_build_object('code', x.footprint_code, 'on', x.happened_on,
                   'lab', app.qc_lab(x.id)->>'name', 'accreditation_no', app.qc_lab(x.id)->>'accreditation_no',   -- migration 59 (A5)
                   'report_no', app.qc_lab(x.id)->>'report_no', 'report_date', app.qc_lab(x.id)->>'report_date', 'readings', v.readings,
                   'units', app.param_units(x.scope_id),                                                            -- migration 59 (A3)
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
    'evidence_pack', (select jsonb_build_object('ref', r.ref, 'version', r.version, 'issued_at', r.issued_at, 'subject_kind', r.subject_kind,   -- migration 71
                        'subject', r.subject_code, 'status', r.status, 'issued_to', r.issued_to, 'data_hash', r.data_hash, 'auto', r.auto,
                        'issued_by', (select u.display_name from public.app_users u where u.id = r.issued_by), 'data', r.data_shareable,
                        'files', (select coalesce(jsonb_object_agg(k, jsonb_build_object('sha256', v->>'sha256', 'bytes', v->'bytes')), '{}'::jsonb)
                                    from jsonb_each(r.files) e(k, v) where k like '%_shareable'))
                        from public.reports r where r.kind = 'evidence_pack' and r.status = 'valid'
                         and ((r.subject_kind = 'shipment' and r.subject_id = any (v_ships))
                              or (r.subject_kind = 'order' and r.subject_id::text = sale.computed->>'client_order_id'))
                       order by (r.subject_kind = 'order') desc, r.issued_at desc limit 1),
    'files', v_files);
end $function$;

-- E1: the client's scope view lists the evidence packs of the scope it may read (an order's pack in each of its scopes)
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
                   'issued_at', r.issued_at, 'subject_kind', r.subject_kind, 'subject', r.subject_code) order by r.issued_at desc)   -- migration 71
                   from public.reports r where p_scope = any (coalesce(r.scope_ids, array[r.scope_id]))
                    and (r.kind = 'season_report' or app.report_readable(r))), '[]'::jsonb),
    -- the people on each stage: name and role only (never a phone, an email or an HR fact)
    'people', coalesce((select jsonb_agg(jsonb_build_object('stage', sa.stage_type, 'name', u.display_name, 'client_staff', u.external)
                   order by array_position((select chain from s), sa.stage_type), u.display_name)
                   from public.slot_assignments sa join public.assignments a on a.id = sa.assignment_id join public.app_users u on u.id = sa.user_id
                  where sa.scope_id = p_scope and a.active and (a.ends_on is null or a.ends_on >= app.today()) and u.status = 'active'), '[]'::jsonb),
    'internal', p_internal)
$function$;


-- 9 · grants --------------------------------------------------------------------------------------------------------------
revoke execute on function app.ep_ranges(text[]), app.ep_shipment_serials(uuid), app.ep_lot_data(uuid, boolean), app.ep_order_tops(uuid),
  app.ep_order_data(uuid, boolean), app.ep_subject_of_seal(uuid), app.ep_subject_scopes(text, uuid), app.may_issue_pack(text, uuid),
  app.ep_issue(text, uuid, uuid, boolean), app.qr_seals_evidence_pack(), app.report_readable(public.reports), app.report_internal_ok(public.reports)
  from public, anon, authenticated;
revoke execute on function app.issue_evidence_pack(text, uuid), app.evidence_packs(text, uuid) from public, anon;
grant execute on function app.issue_evidence_pack(text, uuid), app.evidence_packs(text, uuid) to authenticated;

notify pgrst, 'reload schema';
