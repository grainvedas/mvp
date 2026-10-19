-- GrainVeda MVP · migration 59 (Phase 1, release 1 of Veda's combined brief, 19 Oct 2026: "Fixes on the current build" and
-- "The client login must be read-only everywhere"; checked live on 19 Oct as Lucky and as tcup; "ok start").
--   A1  A pack serial opened on /verify/<code> (or /p/<serial>) before its lot is released says "Packed, not yet
--       released" with the crop, the batch code and the date packed, nothing else. "Code not found" only for a code
--       that never existed (the screen asks public_pack when public_lot_journey knows no lot).
--   A2  A step recorded and checked by the same person says so on the public page ("Recorded and checked by the same
--       person."): each step carries same_person. (This brings back what release 10, G21b, took off: the brief asks it.)
--   A3  Every reading has its unit, from the crop's quality schema and the parameter library: app.param_units.
--   A4  What a record shows is read from the record as it is now: a bill of lading added after the shipment was saved
--       is no longer "still to come" on the check-in panel (app.live_computed).
--   A5  The lab's name and accreditation number wherever the report number is shown (app.qc_lab); the "same report
--       twice" check compares the lab as it was chosen, also when it was picked from the list.
--   A6  A file already attached, for the same client, as another kind of document is refused unless a reason is given
--       (attachments.dup_reason, an Audit line).
--   A8  Scopes with records made before automatic batch codes are marked "Practice (old data)" (scopes.data_note); a
--       typed batch code that is in use already is refused, whoever inserts it.
--   B1  A client login reads only: every write to the records, files, flags, lists, farmers and scopes is refused by the
--       database (trigger client_login_reads_only), and a client login stores no file.
--   B2  What the client waits on: app.client_waiting (records waiting for a check, samples at the lab, open flags).
--   B3  A client login reads its farmers only through app.client_farmers: the phone masked, no father's name.
--   B4  A Client Manager sees no one's email and the phone only of people on a stage of his own scopes; app_users'
--       email and phone are no longer readable directly through the API (people_page / employee_profile decide).
-- Nothing is deleted or rewritten: new columns, new functions; the scopes with old data get their note.
select set_config('app.change_path', 'migration 59', true);


-- =====================================================================================================================
-- A8 · scopes with records made before the system gave batch codes; a typed batch code in use is refused
-- =====================================================================================================================
alter table public.scopes add column data_note text check (data_note is null or data_note in ('practice_old_data'));
comment on column public.scopes.data_note is 'migration 59 (A8): practice_old_data = records of before automatic batch codes; shown on screens and in exports';

-- the rule that marks a scope: a packing record whose batch code was typed (or never given), or a pack of a batch
-- "not yet", or two packing records sharing one batch code
create or replace function app.has_old_batch_data(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.pack_batches b where b.scope_id = p_scope and b.typed)
      or exists (select 1 from public.footprints f where f.scope_id = p_scope and f.stage_type = 'packing'
                    and f.status not in ('superseded', 'legacy')
                    and (coalesce(btrim(f.payload->>'batch_code'), '') = '' or lower(f.payload->>'batch_code') like 'not yet%'))
      or exists (select 1 from public.packs p where p.scope_id = p_scope and lower(p.serial) like 'not yet%')
      or exists (select 1 from public.footprints f where f.scope_id = p_scope and f.stage_type = 'packing' and f.status not in ('superseded', 'legacy')
                    and coalesce(btrim(f.payload->>'batch_code'), '') <> ''
                  group by f.payload->>'batch_code' having count(*) > 1) $$;

update public.scopes s set data_note = 'practice_old_data' where app.has_old_batch_data(s.id);

CREATE OR REPLACE FUNCTION app.footprints_batch_code()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.stage_type <> 'packing' then return new; end if;
  if tg_op = 'INSERT' then
    if auth.uid() is not null or coalesce(btrim(new.payload->>'batch_code'), '') = '' then
      new.payload := coalesce(new.payload, '{}'::jsonb) || jsonb_build_object('batch_code', app.next_batch_code(new.scope_id));
    -- migration 59 (A8): a typed code (a script's, a seed's) is kept only while no other record or batch has it
    elsif exists (select 1 from public.pack_batches b where lower(b.batch_code) = lower(btrim(new.payload->>'batch_code')))
       or exists (select 1 from public.footprints o where o.stage_type = 'packing' and o.status not in ('superseded', 'legacy')
                     and lower(btrim(o.payload->>'batch_code')) = lower(btrim(new.payload->>'batch_code'))) then
      raise exception 'batch code % is in use already: a batch code is given by the system', btrim(new.payload->>'batch_code')
        using errcode = '23505';
    end if;
  elsif new.payload->>'batch_code' is distinct from old.payload->>'batch_code' then
    new.payload := new.payload || jsonb_build_object('batch_code', old.payload->>'batch_code');
  end if;
  return new;
end $function$;


-- =====================================================================================================================
-- A3 · the unit of every reading: the scope's quality schema (the crop's, copied at activation), its market profiles'
-- extra tests, the parameter library for a parameter that has no unit of its own
-- =====================================================================================================================
create or replace function app.param_units(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(x.param, x.unit), '{}'::jsonb) from (
    select distinct on (q->>'param') q->>'param' as param,
           coalesce(nullif(btrim(q->>'unit'), ''), (select nullif(btrim(l.unit), '') from public.quality_param_library l where l.param = q->>'param')) as unit
      from jsonb_array_elements(app.scope_test_params(p_scope)) q
     where q->>'param' is not null) x
   where x.unit is not null $$;

-- =====================================================================================================================
-- A4 · a record's worked-out values as they stand now: a bill of lading added later (app.add_bill_of_lading) is no
-- longer "still to come"
-- =====================================================================================================================
create or replace function app.live_computed(f public.footprints) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when f.stage_type = 'shipment' and exists (select 1 from public.bills_of_lading b where b.footprint_id = f.id)
              then coalesce(f.computed, '{}'::jsonb) || jsonb_build_object('bl_pending', false,
                     'bl_no', (select b.bl_no from public.bills_of_lading b where b.footprint_id = f.id))
              else f.computed end $$;

-- =====================================================================================================================
-- A5 · the lab of a lab record: the one chosen (the sample's, or the list's), its accreditation number, the report
-- =====================================================================================================================
create or replace function app.qc_lab(p_fp uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when f.id is null or f.stage_type <> 'qc' then null else jsonb_strip_nulls(jsonb_build_object(
           'name', coalesce(l.name, nullif(btrim(f.computed->>'lab_name'), ''), nullif(btrim(f.computed->>'lab'), ''), nullif(btrim(f.payload->>'lab_name'), '')),
           'accreditation_no', l.accreditation_no, 'kind', l.kind,
           'report_no', coalesce(nullif(btrim(f.computed->>'report_no'), ''), nullif(btrim(f.payload->>'report_no'), '')),
           'report_date', coalesce(nullif(f.computed->>'report_date', ''), nullif(f.payload->>'report_date', '')))) end
    from public.footprints f
    left join public.qc_samples smp on smp.id::text = f.payload->>'sample_ref'
    left join public.labs l on l.id = coalesce(smp.lab_id, case when f.payload->>'lab_id' ~ '^[0-9a-f-]{36}$' then (f.payload->>'lab_id')::uuid end)
   where f.id = p_fp $$;

CREATE OR REPLACE FUNCTION app.report_no_taken(p_lab text, p_no text, p_sample text, p_except uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select f.footprint_code from public.footprints f
   where f.stage_type = 'qc' and f.status not in ('superseded', 'legacy') and f.id is distinct from p_except
     and lower(btrim(f.payload->>'report_no')) = lower(btrim(p_no)) and app.norm_place(app.qc_lab(f.id)->>'name') is not distinct from app.norm_place(p_lab)   -- migration 59 (A5): the lab as chosen
     and (p_sample is null or btrim(p_sample) = '' or coalesce(lower(btrim(f.payload->>'sample_id')), '') <> lower(btrim(p_sample)))
   limit 1 $function$;

CREATE OR REPLACE FUNCTION app.incoming_lots(p_scope uuid, p_stage stage_type)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(to_jsonb(f) || jsonb_build_object('computed', app.live_computed(f)) || jsonb_build_object(   -- migration 59 (A4)
           'available_kg', app.available_qty(f.id),
           'returned', exists (select 1 from public.footprint_returns r where r.footprint_id = f.id and r.status = 'open'),
           'maker_name', (select u.display_name from public.app_users u where u.id = f.created_by),
           'made_by_me', f.created_by = app.current_user_id(),
           'gi_status', app.lot_gi_status(f.id),
           'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(f.id) s join public.footprints e on e.id = s.entry_id))
         order by f.created_at), '[]'::jsonb)
    from app.incoming_records(p_scope, p_stage) f $function$;

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
              'copy_warning', app.scan_warning(p.serial), 'seller', (select c.name from public.clients c where c.id = sc.client_id),   -- migration 56
              'carton', p.carton_code,                                                                                         -- migration 58
              -- migration 57: how often this pack was scanned and the first place (a city, never a person)
              'scans', (select jsonb_build_object('n', count(*),
                          'first_city', (select f.city from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1),
                          'first_country', (select f.country from public.scans f where f.code = p.serial and f.city is not null order by f.at, f.id limit 1))
                          from public.scans x where x.code = p.serial));
  select s into v_seal from app.packing_seals(p.footprint_id) s limit 1;
  if v_seal is null or p.status = 'void' then
    -- migration 59 (A1): before release, the crop, the batch code and the date packed; nothing else (a voided pack says so; a copied code is warned of, without the seller)
    return jsonb_build_object('released', false,
      'pack', jsonb_build_object('serial', p.serial, 'batch_code', p.batch_code, 'packed_on', p.packed_on, 'void', p.status = 'void',
                                 'copy_warning', app.scan_warning(p.serial)),
      'crop', jsonb_build_object('name', cr.name));
  end if;
  select * into q from public.qr_seals where footprint_id = v_seal;
  return app.public_lot_journey(q.qr_code) || jsonb_build_object('pack', v_pack, 'released', true);
end $function$;

CREATE OR REPLACE FUNCTION app.public_lot_journey(p_qr_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
        v_independent boolean := true; v_later_maker uuid; v_same boolean := false; v_mkt text; v_dest text;   -- v_mkt, v_dest: migration 57
begin
  select * into seal from public.qr_seals where qr_code = p_qr_code;
  if seal.footprint_id is null then return null; end if;
  select * into cur from public.footprints where id = seal.footprint_id;
  select * into v_scope from public.scopes where id = cur.scope_id;
  select * into v_crop from public.crops where id = v_scope.crop_id;
  select * into v_client from public.clients where id = v_scope.client_id;
  select * into vd from app.resolve_market_verdict(cur.id);

  while cur.id is not null and hops < 64 loop
    step := jsonb_build_object(
      'stage', cur.stage_type, 'code', cur.footprint_code, 'qty_in_kg', cur.qty_in, 'qty_out_kg', cur.qty_out,
      'verified_at', cur.verified_at, 'created_at', cur.created_at,
      'captured_at', coalesce(cur.captured_at, cur.created_at), 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      -- migration 50 (Part D): the village and the district, never the farmer's name or photo
      step := step || jsonb_build_object('farmer', jsonb_build_object('village', fm.village, 'district', fm.district));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id))
                   || jsonb_build_object('markets', (select coalesce(jsonb_agg(jsonb_build_object('code', pv.code, 'name', pv.name,
                        'verdict', pv.verdict, 'failed', pv.failed,
                        'limits', (select mp.params from public.market_profiles mp where mp.id = pv.profile_id))   -- migration 57
                        order by pv.created_at, pv.code), '[]'::jsonb)
                        from public.qc_profile_verdicts pv where pv.footprint_id = cur.id));                      -- migration 53
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'warehouse' then step := step || jsonb_build_object('days_in_storage', app.storage_days(cur.id)); end if;   -- migration 55
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', coalesce(cur.payload->>'village',      -- migration 52: from the lots
             app.batch_villages(cur.id)),                    -- migration 52b: the villages only, through a helper
        'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('village', g.village, 'district', g.district, 'qty_kg', g.qty_kg) order by g.village, g.qty_kg)
          from (select fa.name, fa.village, fa.district, sum(src.qty_out) as qty_kg                -- migration 49: one line a farmer
                  from public.footprints src join public.farmers fa on fa.id = src.farmer_id
                 where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)
                 group by fa.id, fa.name, fa.village, fa.district) g), '[]'::jsonb));
    end if;
    if cur.stage_type = 'shipment' then   -- migration 57: an export's country; nothing of a domestic dispatch's place
      select coalesce(o.payload->>'market', 'domestic'), o.payload->>'destination_country' into v_mkt, v_dest      -- the order's own words
        from public.footprints o where o.id = cur.prev_footprint_id and o.stage_type = 'commercial';
      step := step || jsonb_build_object('dispatched_on', cur.payload->>'dispatch_date',
        'destination', case when v_mkt = 'export' then coalesce(v_dest, cur.payload->>'destination') end);   -- before 54: the typed place
    end if;
    -- migration 57 (G21): checked by someone other than who recorded it (the public page says so only where true)
    step := step || jsonb_build_object('checked', cur.stage_type <> 'qr_activation' and cur.verified_by is not null
              and cur.verified_by <> cur.created_by
              and not exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory'),
              -- migration 59 (A2, Veda's brief of 19 Oct): the step recorded and checked by one person says so
              'same_person', cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by);
    -- "recorded by the person who handled it and checked by the next person": true only if no step was checked by
    -- its own maker, no two steps in a row were made by one person, and no step was done as a manager's supervisory act
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by)
       or exists (select 1 from public.ledger l where l.footprint_id = cur.id and l.event = 'supervisory') then
      v_independent := false;
    end if;
    -- migration 46: the same person recorded a step and checked it, or recorded the next one (the approved words)
    if (cur.stage_type <> 'qr_activation' and cur.verified_by is not null and cur.verified_by = cur.created_by)
       or (v_later_maker is not null and v_later_maker = cur.created_by and not cur.is_grade_lot) then
      v_same := true;
    end if;
    v_later_maker := cur.created_by;
    steps := jsonb_build_array(step) || steps;     -- prepend: journey reads farm → seal
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;

  return jsonb_build_object(
    'qr_code', seal.qr_code, 'sealed_at', seal.sealed_at, 'ledger_hash', seal.ledger_hash, 'batch_codes', to_jsonb(seal.batch_codes),
    'crop', jsonb_build_object('name', v_crop.name, 'gi_tag', v_crop.gi_tag, 'origin', v_crop.origin),
    'client', jsonb_build_object('name', v_client.name, 'type', v_client.type),
    'season', v_scope.season_code, 'geography', v_scope.geography,
    'verdict', jsonb_build_object('domestic', vd.domestic, 'export', vd.export, 'overridden', vd.override is not null),
    'journey', steps,
    'independent', v_independent,
    -- migration 57 (G21): no same_person here (the ledger keeps it); the villages by share, with their farmers
    'villages', coalesce((select jsonb_agg(jsonb_build_object('village', y.village, 'district', y.district, 'share_pct', y.pct, 'farmers', y.n)
                                  order by y.pct desc, y.village)
                 from (select fv.village, fv.district, round(sum(s.share) * 100, 1) as pct, count(distinct e.farmer_id) as n
                         from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id
                         join public.farmers fv on fv.id = e.farmer_id group by fv.village, fv.district) y), '[]'::jsonb),
    'farmer_count', (select count(distinct e.farmer_id) from app.lot_sources(seal.footprint_id) s join public.footprints e on e.id = s.entry_id),
    'gi_status', app.lot_gi_status(seal.footprint_id),                                                   -- migration 49
    'units', app.param_units(v_scope.id),                                                                 -- migration 59 (A3)
    -- migration 50: the release's status (a recall on every pack) and the packs' dates
    'release', app.release_status(seal.footprint_id) - 'by',
    'packs', (select jsonb_build_object('n', count(*), 'packed_on', min(p.packed_on), 'best_before', min(p.best_before))
                from public.packs p where p.footprint_id in (select app.lot_packings(seal.footprint_id)) and p.status = 'packed')
  );
end $function$;

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
    'files', v_files);
end $function$;

CREATE OR REPLACE FUNCTION app.lot_trace(p_fp uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_scope uuid; steps jsonb;
begin
  select scope_id into v_scope from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
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
           'payload', f.payload, 'computed', app.live_computed(f), 'warnings', to_jsonb(f.warnings),          -- migration 59 (A4)
           'lab', app.qc_lab(f.id),                                                                            -- migration 59 (A5)
           'same_person', f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by,
           'farmer', case when fa.id is null then null else jsonb_build_object('code', fa.farmer_code, 'name', fa.name, 'village', fa.village) end,
           'created_at', f.created_at, 'captured_at', coalesce(f.captured_at, f.created_at), 'created_by', cu.display_name,
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

  return jsonb_build_object('footprint_id', p_fp, 'generated_at', now(), 'steps', coalesce(steps, '[]'::jsonb),
    'units', app.param_units(v_scope),                                                                    -- migration 59 (A3)
    'data_note', (select s.data_note from public.scopes s where s.id = v_scope));                         -- migration 59 (A8)
end$function$;

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
    'footprint', to_jsonb(f) || jsonb_build_object('computed', app.live_computed(f)),                   -- migration 59 (A4)
    'lab', app.qc_lab(f.id),                                                                               -- migration 59 (A5)
    'units', app.param_units(f.scope_id),                                                                  -- migration 59 (A3)
    'data_note', (select s.data_note from public.scopes s where s.id = f.scope_id),                         -- migration 59 (A8)
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
    'warehouse', app.warehouse_of(f.id),                                                                    -- migration 55
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


-- =====================================================================================================================
-- A6 · a file whose fingerprint is attached already, for the same client, as another kind of document: refused unless
-- the person gives a reason (kept on the attachment and in the Audit log). The same lab report on two lots stays
-- allowed (the same kind; the report-number rule of migration 50 asks the shared sample ID).
-- Photos are one kind (a photo, a loading photo): the brief's case is documents.
-- =====================================================================================================================
alter table public.attachments add column dup_reason text check (dup_reason is null or length(btrim(dup_reason)) between 10 and 300);

create or replace function app.doc_kind_word(p text) returns text language sql immutable as $$
  select case p when 'lab_report' then 'lab report' when 'acceptance' then 'client acceptance' when 'pod' then 'proof of delivery'
                when 'loading_photo' then 'loading photo' when 'export_doc' then 'export document' when 'photo' then 'photo'
                else 'document' end $$;

-- the other place this file is attached as another kind (same client only: another client's records are never named)
create or replace function app.same_file_elsewhere(p_fp uuid, p_sha text, p_kind text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('kind', coalesce(a.label, a.kind::text), 'code', o.footprint_code)
    from public.attachments a join public.footprints o on o.id = a.footprint_id
    join public.footprints me on me.id = p_fp
   where a.sha256 = lower(p_sha) and o.client_id = me.client_id and app.can_see_footprint(me.scope_id, me.stage_type)
     and app.doc_kind_word(coalesce(a.label, a.kind::text)) <> app.doc_kind_word(p_kind)
     -- a photo is a photo: the same picture as a loading photo and a photo of the bags is not two kinds of document
     and not (app.doc_kind_word(coalesce(a.label, a.kind::text)) in ('photo', 'loading photo') and app.doc_kind_word(p_kind) in ('photo', 'loading photo'))
   order by a.created_at limit 1 $$;

-- the Audit line of a file attached with a reason (the attachment must be the caller's, with its reason)
create or replace function app.note_same_file(p_att uuid, p_detail jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a public.attachments;
begin
  select * into a from public.attachments where id = p_att;
  if a.id is null or a.dup_reason is null or a.uploaded_by is distinct from app.current_user_id() then
    raise exception 'not allowed' using errcode = '42501'; end if;
  perform app.audit('same_file_attached', a.id, p_detail || jsonb_build_object('reason', a.dup_reason), true);
end $$;

drop function app.register_labelled_attachment(uuid, attachment_kind, text, text, text);
drop function app.register_attachment(uuid, attachment_kind, text, text);

create function app.register_attachment(p_footprint uuid, p_kind attachment_kind, p_path text, p_sha256 text,
                                        p_reason text default null, p_label text default null)
 returns attachments language plpgsql set search_path to 'public' as $function$
declare f public.footprints; r public.attachments; v_other jsonb;
begin
  select * into f from public.footprints where id = p_footprint;
  if f.id is null then raise exception 'record not found' using errcode = 'P0002'; end if;
  if p_path is distinct from format('%s/%s/%s/%s', f.client_id, f.scope_id, f.id, split_part(p_path, '/', 4))
     or split_part(p_path, '/', 4) = '' then
    raise exception 'evidence path must be <client>/<scope>/<footprint>/<file>' using errcode = '23514'; end if;
  -- migration 59 (A6): the same file as another kind of document needs a reason
  v_other := app.same_file_elsewhere(p_footprint, p_sha256, coalesce(p_label, p_kind::text));
  if v_other is not null and coalesce(length(btrim(p_reason)), 0) < 10 then
    raise exception 'same file: this exact file is already attached as % on %', app.doc_kind_word(v_other->>'kind'), v_other->>'code'
      using errcode = 'GVDUP', hint = 'give a reason of 10 characters or more to attach it here too';
  end if;
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by, dup_reason)
  values (p_footprint, p_kind, p_path, lower(p_sha256), app.current_user_id(), case when v_other is not null then btrim(p_reason) end)
  returning * into r;
  if v_other is not null then
    perform app.note_same_file(r.id, jsonb_build_object('record', f.footprint_code, 'also_on', v_other->>'code',
      'as', v_other->>'kind', 'here_as', coalesce(p_label, p_kind::text)));
  end if;
  return r;
end $function$;

create function app.register_labelled_attachment(p_footprint uuid, p_kind attachment_kind, p_path text, p_sha256 text, p_label text,
                                                 p_reason text default null)
 returns attachments language plpgsql set search_path to 'public' as $function$
declare r public.attachments;
begin
  if p_label is not null and p_label not in ('lab_report', 'acceptance', 'pod', 'loading_photo', 'document', 'export_doc') then
    raise exception 'unknown kind of document' using errcode = '22023'; end if;
  r := app.register_attachment(p_footprint, p_kind, p_path, p_sha256, p_reason, p_label);   -- as the caller: the insert's own rules apply
  return app.set_attachment_label(r.id, p_label);
end $function$;


-- =====================================================================================================================
-- B1 · a client login (an external person: the client's read-only login) reads and never writes. One rule, at the
-- tables, so it holds for every way in: the API, the record functions, the stage page, an old app.
-- =====================================================================================================================
create or replace function app.is_client_login() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select u.external from public.app_users u where u.id = app.current_user_id()), false) $$;

create or replace function app.client_login_reads_only() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if app.is_client_login() then
    raise exception 'a client login reads only: it cannot change records, files, flags or lists' using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger a00_client_login_reads_only before insert or update or delete on public.footprints for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.footprint_returns for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.footprint_links for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.attachments for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.flags for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.withdrawals for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.corrections for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.qr_seals for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.qc_verdicts for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.qc_samples for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.lot_payments for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.sale_terms for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.bills_of_lading for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.deliveries for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.export_documents for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.label_prints for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.release_events for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.lot_closures for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.net_weight_checks for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.warehouse_inspections for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.warehouse_bags_out for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.packs for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.cartons for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.buyer_links for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.scan_flags for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.farmers for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.farmer_gap for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.farmer_proposals for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.scopes for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.slot_assignments for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.collection_points for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.mills for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.packing_units for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.buyers for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.pack_skus for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.labs for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.market_profiles for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.reference_files for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.places for each row execute function app.client_login_reads_only();
create trigger a00_client_login_reads_only before insert or update or delete on public.crops for each row execute function app.client_login_reads_only();

-- a client login stores no file
alter policy evidence_upload on storage.objects with check (
  (bucket_id = 'evidence') and not app.is_client_login() and exists (select 1 from public.footprints f
    where (f.id)::text = (storage.foldername(objects.name))[3] and (f.client_id)::text = (storage.foldername(objects.name))[1]
      and (f.scope_id)::text = (storage.foldername(objects.name))[2] and app.can_see_footprint(f.scope_id, f.stage_type)));

-- =====================================================================================================================
-- B2 · what the client is waiting on GrainVeda for: records not yet checked, samples at the lab, open flags (read only)
-- =====================================================================================================================
create or replace function app.client_waiting(p_scope uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); v_scopes uuid[];
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select coalesce(array_agg(s.id), '{}') into v_scopes from public.scopes s
   where s.status in ('active', 'closed') and app.can_access_scope(s.id) and (p_scope is null or s.id = p_scope);
  return jsonb_build_object(
    'pending', coalesce((select jsonb_agg(jsonb_build_object('code', f.footprint_code, 'stage', f.stage_type, 'scope_id', f.scope_id,
                    'since', coalesce(f.captured_at, f.created_at)) order by f.created_at)
                  from public.footprints f where f.scope_id = any (v_scopes) and f.status = 'pending'), '[]'::jsonb),
    'lab_hold', coalesce((select jsonb_agg(jsonb_build_object('code', q.code, 'scope_id', q.scope_id, 'drawn_on', q.drawn_on,
                    'lot', (select f.footprint_code from public.footprints f where f.id = q.footprint_id)) order by q.drawn_on, q.code)
                  from public.qc_samples q where q.scope_id = any (v_scopes) and q.status = 'sent' and q.qc_footprint_id is null), '[]'::jsonb),
    'open_flags', coalesce((select jsonb_agg(jsonb_build_object('text', fl.text, 'kind', fl.kind, 'at', fl.created_at,
                    'code', f.footprint_code, 'scope_id', f.scope_id) order by fl.created_at)
                  from public.flags fl join public.footprints f on f.id = fl.footprint_id
                 where f.scope_id = any (v_scopes) and fl.status = 'open'), '[]'::jsonb));
end $$;

-- =====================================================================================================================
-- B3 · a client login's farmers: its client's, through this function only; the phone masked, no father's name
-- =====================================================================================================================
create or replace function app.client_farmers(p_q text default null, p_ids uuid[] default null, p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := app.current_user_id(); v_clients uuid[]; v_q text := nullif(lower(btrim(p_q)), '');
begin
  if me is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct a.client_id), '{}') into v_clients from app.eff_assignments(me) a
   where a.lens = 'client' and a.op_role = 'client_viewer';
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'farmer_code', f.farmer_code, 'name', f.name, 'village', f.village,
           'district', f.district, 'block', f.block, 'status', f.status, 'land_area_acres', f.land_area_acres, 'gi_land_acres', f.gi_land_acres,
           'phone', case when coalesce(f.phone, '') = '' then null else '••••••' || right(regexp_replace(f.phone, '[^0-9]', '', 'g'), 4) end)
           order by f.name, f.farmer_code)
      from (select * from public.farmers f where f.client_id = any (v_clients)
              and (p_ids is null or f.id = any (p_ids))
              and (v_q is null or lower(f.name) like '%' || v_q || '%' or lower(coalesce(f.farmer_code, '')) like '%' || v_q || '%'
                   or lower(coalesce(f.village, '')) like '%' || v_q || '%')
             order by f.name, f.farmer_code limit least(greatest(coalesce(p_limit, 200), 1), 500)) f), '[]'::jsonb);
end $$;

-- =====================================================================================================================
-- B4 · a Client Manager sees a person's phone only while the person holds a stage on one of his scopes
-- =====================================================================================================================
create or replace function app.cm_phone_ok(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.assignments a where a.employee_id = p_person and a.active and a.lens = 'scope'
                    and cardinality(a.stages) > 0 and (a.ends_on is null or a.ends_on >= app.today()) and app.i_manage_scope(a.scope_id)) $$;

-- Speed (found while testing release 59): People & access for a Client Manager asked app.cm_seen_ids() once per row
-- through app.may_offer_assign (0.3 s each with 230 people: 15 s a page). The rule is unchanged: may_offer_assign is
-- may_offer_assign_seen and "within cm_seen_ids"; people_page, whose rows are within cm_seen_ids already, asks the first.
create or replace function app.may_offer_assign_seen(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (app.is_hr_admin() or (app.can_assign() and not app.is_admin()))
       and u.status in ('invited', 'onboarding', 'active') and not u.external and u.id <> app.current_user_id()
       and u.system_role not in ('admin', 'hr_admin', 'hr_resource') and not u.test_data
       and (not app.cm_limited() or (u.system_role = 'operational'
                                     and not exists (select 1 from public.assignments z where z.employee_id = u.id and z.active and z.lens = 'state')))
       and (not app.sm_limited() or app.sm_sees(u.id))
      from public.app_users u where u.id = p_person), false) $$;

create or replace function app.may_offer_assign(p_person uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.may_offer_assign_seen(p_person) and (not app.cm_limited() or p_person = any (app.cm_seen_ids())) $$;

CREATE OR REPLACE FUNCTION app.farmer_read(p_client uuid, p_state uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- migration 59 (B3): a client login reads its farmers through app.client_farmers (the phone masked), not the table
  select app.is_admin() or app.farmer_create(p_client) or app.i_staff_farmer(p_client, p_state) $function$;

CREATE OR REPLACE FUNCTION app.people_page(p jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); full_view boolean; v_kind text := coalesce(nullif(p->>'kind', ''), 'employees');
        v_q text := nullif(lower(btrim(p->>'q')), ''); v_status text := nullif(p->>'status', ''); v_state uuid := nullif(p->>'state', '')::uuid;
        v_client uuid := nullif(p->>'client', '')::uuid; v_role text := nullif(p->>'role', ''); v_open uuid := nullif(p->>'opening', '')::uuid;
        v_owner text := nullif(p->>'owner', ''); v_unass boolean := coalesce((p->>'unassigned')::boolean, false);
        v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 200); v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
        v_digits text; res jsonb; v_limited boolean := app.is_hr() and not app.hr_full(); v_mine uuid[] := app.my_hr_states();
        v_cm boolean := app.cm_limited();                                       -- migration 59 (B4)
begin
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  v_digits := regexp_replace(coalesce(v_q, ''), '[^0-9]', '', 'g');
  with vis as (
    select u.*, o.employment_type, o.designation_band, o.department, o.job_title, o.reports_to, o.opening_id, o.intended_role,
           o.intended_stage, o.hr_owner, o.base_state_id, o.base_district
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where ((not u.external and (full_view or u.status <> 'offboarded')) or (u.external and (app.is_admin() or app.manages_viewer(u.id))))
       and (not v_limited or u.id = me or o.base_state_id = any(v_mine))
       and (full_view or u.external or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))   -- migration 41
       and (full_view or u.external or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids())))   -- migration 44 (A4)
       and not u.test_data                                                                                            -- migration 44 (G7)
  ), f as (
    select v.* from vis v
     where (v_kind = 'client_logins') = v.external
       and (v_q is null or lower(v.display_name) like '%' || v_q || '%' or (not v_cm and lower(coalesce(v.email, '')) like '%' || v_q || '%')
            or (not v_cm and v_q ~ '^[0-9+ -]{4,}$' and coalesce(v.phone, '') like '%' || v_digits || '%')
            or lower(coalesce(v.job_title, '')) like '%' || v_q || '%')
       and (v_status is null or v.status::text = v_status)
       and (v_state is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id left join public.clients c on c.id = a.client_id
                                        where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_state in (a.state_id, s.state_id, c.state_id))
            or exists (select 1 from public.openings op where op.id = v.opening_id and op.state_id = v_state)
            or v.base_state_id = v_state)
       and (v_client is null or exists (select 1 from public.assignments a left join public.scopes s on s.id = a.scope_id
                                         where a.employee_id = v.id and a.active and (full_view or app.assignment_visible(a)) and v_client in (a.client_id, s.client_id)))
       and (v_role is null or v.intended_role = v_role)
       and (v_open is null or v.opening_id = v_open)
       and (v_owner is null or (v_owner = 'mine' and v.hr_owner = me) or (v_owner not in ('mine', 'none') and v.hr_owner::text = v_owner)
            or (v_owner = 'none' and v.hr_owner is null))
       and (not v_unass or not exists (select 1 from public.assignments a where a.employee_id = v.id and a.active))
  )
  select jsonb_build_object(
    'total', (select count(*) from f),
    'counts', (select jsonb_build_object('employees', count(*) filter (where not external), 'client_logins', count(*) filter (where external)) from vis),
    'rows', coalesce((select jsonb_agg(x.j order by x.external, x.display_name) from (
      select f.external, f.display_name, jsonb_build_object(
             'id', f.id, 'name', f.display_name, 'email', case when v_cm and not f.external then null else f.email end,                              -- migration 59 (B4)
             'phone', case when v_cm and not f.external and not app.cm_phone_ok(f.id) then null else f.phone end, 'status', f.status, 'system_role', f.system_role,
             'external', f.external, 'join_date', f.join_date, 'has_login', f.auth_uid is not null and f.auth_uid <> f.id,
             'role', f.intended_role, 'stage', f.intended_stage,
             'opening_code', (select code from public.openings where id = f.opening_id),
             'base', jsonb_build_object('state_id', f.base_state_id, 'state_name', (select name from public.states where id = f.base_state_id),
                                        'district', f.base_district),
             'org', jsonb_build_object('employment_type', f.employment_type, 'designation_band', f.designation_band,
                      'department', f.department, 'job_title', f.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = f.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = f.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = f.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = f.id and a.active),
             'assignable', app.may_offer_assign_seen(f.id)) as j
        from f order by f.external, f.display_name limit v_limit offset v_offset) x), '[]'::jsonb),
    'limit', v_limit, 'offset', v_offset) into res;
  return res;
end $function$;

CREATE OR REPLACE FUNCTION app.people_directory()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare full_view boolean;
begin
  perform app.me_or_raise();
  full_view := app.is_admin() or app.is_hr();
  if not (full_view or app.can_assign()) then
    raise exception 'the people directory is for HR and for those who assign' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', u.id, 'name', u.display_name,
             'email', case when app.cm_limited() and not u.external and u.id <> app.current_user_id() then null else u.email end,   -- migration 59 (B4)
             'phone', case when app.cm_limited() and not u.external and u.id <> app.current_user_id() and not app.cm_phone_ok(u.id) then null else u.phone end, 'status', u.status, 'system_role', u.system_role,
             'external', u.external, 'join_date', u.join_date, 'has_login', u.auth_uid is not null and u.auth_uid <> u.id,
             'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band,
                      'department', o.department, 'job_title', o.job_title,
                      'reports_to_name', (select display_name from public.app_users where id = o.reports_to)),
             'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                                        from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
             'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
             'unassigned', not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active))
           order by u.external, u.display_name)
      from public.app_users u left join public.employee_org o on o.employee_id = u.id
     where (not u.external and (full_view or u.status <> 'offboarded') and (full_view or not (select app.sm_limited()) or u.id in (select unnest(app.sm_seen_ids())))
            and (full_view or not (select app.cm_limited()) or u.id in (select unnest(app.cm_seen_ids()))) and not u.test_data   -- migration 44
            and (not app.is_hr() or app.hr_full() or u.id = app.current_user_id() or o.base_state_id = any(app.my_hr_states())))
        or (u.external and (app.is_admin() or app.manages_viewer(u.id)))), '[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION app.employee_profile(p_employee uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare me uuid := app.me_or_raise(); u public.app_users; o public.employee_org; full_view boolean; hr_ok boolean;
begin
  select * into u from public.app_users where id = p_employee;
  full_view := app.is_admin() or (app.is_hr() and (app.hr_full() or app.hr_covers(p_employee)));
  if u.id is null or not (u.id = me or (not u.external and (full_view or (app.can_assign() and u.status <> 'offboarded' and (not app.sm_limited() or app.sm_sees(u.id)) and (not app.cm_limited() or u.id = any (app.cm_seen_ids())) and not u.test_data)))
                          or (u.external and (app.is_admin() or app.manages_viewer(u.id)))) then
    raise exception 'person not found' using errcode = 'P0002'; end if;
  select * into o from public.employee_org where employee_id = u.id;
  hr_ok := app.may_manage_person(u.id);
  return jsonb_build_object(
    'identity', jsonb_build_object('id', u.id, 'name', u.display_name,
                  'email', case when u.id <> me and not u.external and app.cm_limited() then null else u.email end,              -- migration 59 (B4)
                  'phone', case when u.id <> me and not u.external and app.cm_limited() and not app.cm_phone_ok(u.id) then null else u.phone end,
                  'status', u.status,
                  'external', u.external, 'join_date', u.join_date, 'created_at', u.created_at,
                  'has_login', u.auth_uid is not null and u.auth_uid <> u.id),
    'org', jsonb_build_object('employment_type', o.employment_type, 'designation_band', o.designation_band, 'department', o.department,
             'job_title', o.job_title, 'reports_to_name', (select display_name from public.app_users where id = o.reports_to),
             'buddy_name', (select display_name from public.app_users where id = o.buddy)),
    'system_role', u.system_role,
    'assignments', coalesce((select jsonb_agg(app.assignment_json(a) order by a.lens, a.created_at)
                               from public.assignments a where a.employee_id = u.id and a.active and app.assignment_visible(a)), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(app.assignment_json(a) order by a.ended_at desc)
                           from public.assignments a where a.employee_id = u.id and not a.active and app.assignment_visible(a)), '[]'::jsonb),
    'elsewhere', case when app.cm_limited() then 0 else (select count(*) from public.assignments a where a.employee_id = u.id and a.active and not app.assignment_visible(a)) end,   -- migration 57 (G20)
    'exits', case when app.acts_as_hr() then coalesce((select jsonb_agg(jsonb_build_object('exit_date', e.exit_date, 'reason', e.reason) order by e.created_at desc)
                                                   from public.employee_exits e where e.employee_id = u.id), '[]'::jsonb) else '[]'::jsonb end,
    'can', jsonb_build_object(
      'assign', app.may_offer_assign(u.id),   -- migration 44
      'suspend', hr_ok and u.status in ('invited', 'onboarding', 'active'),
      'reinstate', hr_ok and u.status = 'suspended',
      'offboard', hr_ok and u.status <> 'offboarded',
      'rehire', hr_ok and u.status = 'offboarded' and not u.external,
      'reset_login', app.reset_login_allowed(u.id),
      'set_role', not u.external and u.id <> me and u.system_role in ('operational', 'hr_resource')
                  and (app.is_hr_admin() or (app.is_admin() and not app.hr_seat_filled())),
      'hr_record', app.acts_as_hr() and not u.external));
end $function$;


-- B4: email and phone are not readable straight from the table through the API; the functions above decide who sees them
revoke select on public.app_users from authenticated;
grant select (id, auth_uid, role, display_name, client_id, state_ids, active, created_at, system_role, status, external,
              join_date, created_by, test_data, test_data_note) on public.app_users to authenticated;

-- =====================================================================================================================
-- who may call what
-- =====================================================================================================================
revoke execute on function app.has_old_batch_data(uuid), app.param_units(uuid), app.live_computed(public.footprints), app.qc_lab(uuid),
  app.doc_kind_word(text), app.same_file_elsewhere(uuid, text, text), app.note_same_file(uuid, jsonb), app.is_client_login(), app.client_login_reads_only(),
  app.client_waiting(uuid), app.client_farmers(text, uuid[], integer), app.cm_phone_ok(uuid), app.may_offer_assign_seen(uuid),
  app.register_attachment(uuid, attachment_kind, text, text, text, text), app.register_labelled_attachment(uuid, attachment_kind, text, text, text, text)
  from public, anon, authenticated;
grant execute on function app.client_waiting(uuid), app.client_farmers(text, uuid[], integer),
  app.doc_kind_word(text), app.same_file_elsewhere(uuid, text, text), app.note_same_file(uuid, jsonb),   -- register_attachment runs as the caller
  app.is_client_login(),                                                   -- the storage rule asks it as the caller
  app.register_attachment(uuid, attachment_kind, text, text, text, text), app.register_labelled_attachment(uuid, attachment_kind, text, text, text, text)
  to authenticated;
