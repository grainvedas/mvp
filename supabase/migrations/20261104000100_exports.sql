-- Migration 60 (Phase 1, release 2 of Veda's combined brief of 19 Oct 2026, Part C: the exports; "ok start" to the plan's
-- defaults). Before this the journey CSV and the season CSV were built in the browser from what the screens read: the
-- journey carried the raw saved values (an old record's price among them), the season read the records table, and no
-- download was written down anywhere.
--   C1  Both exports are made on the server: app.export_journey(lot, copy) and app.export_season(scope, copy), copy =
--       'shareable' or 'internal'. A shareable copy never carries a person's name, a farmer's name, a buyer, a price or
--       the raw saved values; it does not reach the browser with them either.
--   C2  Readable columns, one per field, each reading in its own column with its unit (app.param_units); codes and
--       names instead of ids; the raw saved values only in the internal copy, in its last column.
--   C3  Added: each source's share of the lot (or of the season), GI status and farm-verified (Procurement yes, Lot
--       Inward no), batch code, pack count and serial range, the lab and its accreditation number, the same-person
--       mark, the loss on the floor per step and per stage.
--   C4  The internal copy: the people of the scope (its managers and those who hold a stage on it) and the client's own
--       login (app.may_internal_copy); anyone else who sees the scope gets the shareable copy.
--   C5  Every export is written in the Audit log ("export_downloaded": which, which copy, how many rows) by the same
--       call that makes it, so a download cannot skip it.
--   A5  (release 59's gap, seen on staging) the public lot page names the lab and its accreditation number.
-- Additive: new functions; one function replaced (the public lot data, the lab added); no table, no record changed.

-- =====================================================================================================================
-- C4 · who takes the internal copy
-- =====================================================================================================================
create or replace function app.may_internal_copy(p_scope uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.current_user_id() is not null
     and (app.acts_in_scope(p_scope) or (app.is_client_login() and app.sees_whole_scope(p_scope))) $$;

-- =====================================================================================================================
-- C2/C3 · one record, readable (the internal copy adds names, the buyer, prices and the raw saved values)
-- =====================================================================================================================
create or replace function app.export_record(p_fp uuid, p_internal boolean, p_share numeric default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f public.footprints; fa public.farmers; q public.qc_verdicts; s public.qr_seals; v_lab jsonb; r jsonb; v_entry boolean;
        lp public.lot_payments; st public.sale_terms;
begin
  select * into f from public.footprints where id = p_fp;
  if f.id is null then return null; end if;
  select * into fa from public.farmers where id = f.farmer_id;
  select * into q from public.qc_verdicts where footprint_id = f.id;
  select * into s from public.qr_seals where footprint_id = f.id;
  v_lab := app.qc_lab(f.id);
  v_entry := f.stage_type in ('procurement', 'lot_inward');
  r := jsonb_build_object(
    'code', f.footprint_code, 'stage', f.stage_type, 'status', f.status, 'happened_on', f.happened_on,
    'recorded_at', to_char(coalesce(f.captured_at, f.created_at) at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'verified_at', to_char(f.verified_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'same_person', case when f.stage_type <> 'qr_activation' and f.verified_by is not null and f.verified_by = f.created_by then 'yes' end,
    'qty_in_kg', f.qty_in, 'qty_out_kg', f.qty_out,
    'loss_kg', case when not v_entry and f.qty_in > f.qty_out then f.qty_in - f.qty_out end,
    'farmer_code', fa.farmer_code, 'village', fa.village, 'district', fa.district,
    'share_pct', case when p_share is not null then round(p_share * 100, 1) end,
    'gi_status', case when v_entry then app.entry_gi(f.id) end,
    'farm_verified', case f.stage_type when 'procurement' then 'yes' when 'lot_inward' then 'no' end,
    'grade', f.grade, 'qc_domestic', q.domestic_verdict, 'qc_export', q.export_verdict, 'readings', coalesce(q.readings, '{}'::jsonb),
    'lab', v_lab->>'name', 'lab_accreditation', v_lab->>'accreditation_no', 'report_no', v_lab->>'report_no', 'report_date', v_lab->>'report_date',
    'market', f.payload->>'market',
    'batch_code', coalesce((select string_agg(distinct p.batch_code, ' ') from public.packs p where p.footprint_id = f.id),
                           case when f.stage_type = 'packing' then f.payload->>'batch_code' end),
    'packs', (select nullif(count(*), 0) from public.packs p where p.footprint_id = f.id and p.status <> 'void'),
    'serials', (select case when count(*) > 0 then min(p.serial) || ' to ' || max(p.serial) end from public.packs p where p.footprint_id = f.id),
    'qr_code', s.qr_code, 'sealed_at', to_char(s.sealed_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'open_flags', (select nullif(count(*), 0) from public.flags fl where fl.footprint_id = f.id and fl.status = 'open'),
    'evidence_sha256', (select string_agg(a.sha256, ' ' order by a.created_at) from public.attachments a where a.footprint_id = f.id),
    'ledger_blocks', (select count(*) from public.ledger l where l.footprint_id = f.id),
    'last_block_hash', (select l.hash from public.ledger l where l.footprint_id = f.id order by l.seq desc limit 1),
    'warnings', nullif(array_to_string(f.warnings, ' | '), ''),
    'withdrawn', (select to_char(w.withdrawn_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI') || ': ' || w.reason
                    from public.withdrawals w where w.footprint_id = f.id),
    'replaces', (select o.footprint_code || ' (' || o.qty_out || ' kg)' || coalesce(': ' || w.reason, '')
                   from public.footprints o left join public.withdrawals w on w.footprint_id = o.id where o.id = f.supersedes_id),
    'lot_closed', case when f.lot_closed then 'yes' end,
    -- when the server stored it; recorded_at is when the work was done (for a save that waited on the phone, its capture)
    'received_at', to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'));
  if p_internal then
    select * into lp from public.lot_payments where footprint_id = f.id;
    select * into st from public.sale_terms where footprint_id = f.id;
    r := r || jsonb_build_object(
      'farmer_name', fa.name,
      'recorded_by', (select u.display_name from public.app_users u where u.id = f.created_by),
      'verified_by', (select u.display_name from public.app_users u where u.id = f.verified_by),
      'buyer', (select b.name from public.buyers b where b.id::text = f.payload->>'buyer_id'),
      'order_no', f.payload->>'order_no',
      'price_per_quintal', lp.price_per_quintal, 'payment_status', lp.status, 'payment_ref', lp.txn_ref,
      'price_per_kg', st.price_per_kg, 'currency', st.currency, 'total_value', st.total_value,
      'entered_values', f.payload);
  end if;
  return r;
end $$;

-- the records as one table: the columns (a reading is 'r:<its key>') and a row per record, in the order given
create or replace function app.export_table(p_ids uuid[], p_internal boolean, p_shares jsonb, p_note text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare recs jsonb[]; rkeys text[]; keys text[]; rows jsonb := '[]'::jsonb; r jsonb; i int := 0; one jsonb;
begin
  select coalesce(array_agg(app.export_record(u.id, p_internal, (p_shares->>u.id::text)::numeric) order by u.ord), '{}')
    into recs from unnest(coalesce(p_ids, '{}'::uuid[])) with ordinality u(id, ord);
  select coalesce(array_agg(distinct k order by k), '{}') into rkeys
    from unnest(recs) x, jsonb_object_keys(coalesce(x->'readings', '{}'::jsonb)) k;
  keys := (case when p_internal then array['step', 'code', 'stage', 'status', 'happened_on', 'recorded_at', 'verified_at', 'recorded_by', 'verified_by', 'same_person', 'qty_in_kg', 'qty_out_kg', 'loss_kg', 'farmer_code', 'farmer_name', 'village', 'district', 'share_pct', 'gi_status', 'farm_verified', 'grade', 'qc_domestic', 'qc_export']::text[] else array['step', 'code', 'stage', 'status', 'happened_on', 'recorded_at', 'verified_at', 'same_person', 'qty_in_kg', 'qty_out_kg', 'loss_kg', 'farmer_code', 'village', 'district', 'share_pct', 'gi_status', 'farm_verified', 'grade', 'qc_domestic', 'qc_export']::text[] end)
          || array(select 'r:' || k from unnest(rkeys) k)
          || (case when p_internal then array['lab', 'lab_accreditation', 'report_no', 'report_date', 'market', 'buyer', 'order_no', 'price_per_quintal', 'payment_status', 'payment_ref', 'price_per_kg', 'currency', 'total_value', 'batch_code', 'packs', 'serials', 'qr_code', 'sealed_at', 'open_flags', 'evidence_sha256', 'ledger_blocks', 'last_block_hash', 'warnings', 'withdrawn', 'replaces', 'lot_closed', 'received_at', 'data_note', 'entered_values']::text[] else array['lab', 'lab_accreditation', 'report_no', 'report_date', 'market', 'batch_code', 'packs', 'serials', 'qr_code', 'sealed_at', 'open_flags', 'evidence_sha256', 'ledger_blocks', 'last_block_hash', 'warnings', 'withdrawn', 'replaces', 'lot_closed', 'received_at', 'data_note']::text[] end);
  foreach r in array recs loop
    i := i + 1;
    select jsonb_agg(case when k = 'step' then to_jsonb(i) when k = 'data_note' then to_jsonb(p_note)
                          when k like 'r:%' then r->'readings'->substr(k, 3) else r->k end order by o)
      into one from unnest(keys) with ordinality t(k, o);
    rows := rows || jsonb_build_array(one);
  end loop;
  return jsonb_build_object('columns', to_jsonb(keys), 'rows', rows);
end $$;

-- the scope's heading: client, crop, season, place, state
create or replace function app.export_scope_head(p_scope uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('client', c.name, 'client_code', c.code, 'crop', cr.name, 'gi_tag', cr.gi_tag, 'season', s.season_code,
           'geography', s.geography, 'state', st.name, 'status', s.status, 'data_note', s.data_note)
    from public.scopes s join public.clients c on c.id = s.client_id join public.crops cr on cr.id = s.crop_id
    left join public.states st on st.id = s.state_id
   where s.id = p_scope $$;

-- =====================================================================================================================
-- C1 · the journey of one lot (every origin lot, every step after it)
-- =====================================================================================================================
create or replace function app.export_journey(p_fp uuid, p_copy text default 'shareable') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_scope uuid; v_code text; v_int boolean; ids uuid[]; v_shares jsonb; t jsonb;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  select scope_id, footprint_code into v_scope, v_code from public.footprints where id = p_fp;
  if v_scope is null or app.current_user_id() is null or not app.sees_whole_scope(v_scope) then
    raise exception 'not allowed to trace this lot' using errcode = '42501'; end if;
  v_int := p_copy = 'internal';
  if v_int and not app.may_internal_copy(v_scope) then
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy'
      using errcode = '42501'; end if;
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
       where up.depth < 64)
  select array_agg(f.id order by f.created_at, f.footprint_code) into ids
    from (select distinct id from up) u join public.footprints f on f.id = u.id;
  select coalesce(jsonb_object_agg(s.entry_id::text, s.share), '{}'::jsonb) into v_shares from app.lot_sources(p_fp) s;
  t := app.export_table(ids, v_int, v_shares, (select data_note from public.scopes where id = v_scope));
  perform app.audit('export_downloaded', p_fp, jsonb_build_object('kind', 'journey', 'copy', p_copy, 'code', v_code,
    'rows', jsonb_array_length(t->'rows')), false);
  return t || jsonb_build_object('kind', 'journey', 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'units', app.param_units(v_scope), 'scope', app.export_scope_head(v_scope),
    'lot', jsonb_build_object('code', v_code, 'qr_code', (select s.qr_code from public.qr_seals s where s.footprint_id = p_fp)));
end $$;

-- =====================================================================================================================
-- C1 · the season of one scope: a heading, a summary per stage with the season's totals, every record
-- =====================================================================================================================
create or replace function app.export_season(p_scope uuid, p_copy text default 'shareable') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_int boolean; ids uuid[]; v_shares jsonb; t jsonb; v_summary jsonb; v_totals jsonb; v_batches jsonb;
begin
  if p_copy is null or p_copy not in ('shareable', 'internal') then
    raise exception 'an export is a shareable or an internal copy' using errcode = '22023'; end if;
  if app.current_user_id() is null or not exists (select 1 from public.scopes where id = p_scope) or not app.sees_whole_scope(p_scope) then
    raise exception 'not allowed to export this scope' using errcode = '42501'; end if;
  v_int := p_copy = 'internal';
  if v_int and not app.may_internal_copy(p_scope) then
    raise exception 'the internal copy is for the people of this scope and the client''s own login: take the shareable copy'
      using errcode = '42501'; end if;
  select array_agg(f.id order by f.created_at, f.footprint_code) into ids from public.footprints f where f.scope_id = p_scope;
  -- a source's share of the season: its kg of all the kg that came in (records not replaced, not withdrawn)
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status <> 'superseded'
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id))
  select coalesce(jsonb_object_agg(e.id::text, e.qty_out / nullif(tot.kg, 0)) filter (where e.id is not null), '{}'::jsonb) into v_shares
    from (select sum(qty_out) as kg from live where stage_type in ('procurement', 'lot_inward')) tot
    left join live e on e.stage_type in ('procurement', 'lot_inward');
  t := app.export_table(ids, v_int, v_shares, (select data_note from public.scopes where id = p_scope));
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status <> 'superseded'
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id))
  select coalesce(jsonb_agg(jsonb_build_object('stage', c.stage, 'pos', c.pos,
           'records', coalesce(x.n, 0), 'pending', coalesce(x.pending, 0), 'verified', coalesce(x.verified, 0),
           'kg_in', coalesce(x.kg_in, 0), 'kg_out', coalesce(x.kg_out, 0), 'loss_kg', coalesce(x.loss, 0)) order by c.pos), '[]'::jsonb)
    into v_summary
    from public.scopes s, unnest(s.chain) with ordinality c(stage, pos)
    left join lateral (select count(*) as n, count(*) filter (where l.status = 'pending') as pending,
                              count(*) filter (where l.status in ('verified', 'closed')) as verified,
                              sum(l.qty_in) as kg_in, sum(l.qty_out) as kg_out,
                              sum(case when l.stage_type not in ('procurement', 'lot_inward') and l.qty_in > l.qty_out then l.qty_in - l.qty_out else 0 end) as loss
                         from live l where l.stage_type = c.stage) x on true
   where s.id = p_scope;
  select coalesce(jsonb_agg(jsonb_build_object('batch_code', b.batch_code, 'packs', b.n, 'void', b.v, 'first', b.first, 'last', b.last) order by b.batch_code), '[]'::jsonb)
    into v_batches
    from (select p.batch_code, count(*) filter (where p.status <> 'void') as n, count(*) filter (where p.status = 'void') as v,
                 min(p.serial) as first, max(p.serial) as last
            from public.packs p where p.scope_id = p_scope group by p.batch_code) b;
  with live as (
    select f.* from public.footprints f
     where f.scope_id = p_scope and f.status <> 'superseded'
       and not exists (select 1 from public.withdrawals w where w.footprint_id = f.id)),
  ent as (select l.*, app.entry_gi(l.id) as gi from live l where l.stage_type in ('procurement', 'lot_inward'))
  select jsonb_build_object(
           'farmers', (select count(distinct farmer_id) from ent),
           'kg_in', (select coalesce(sum(qty_out), 0) from ent),
           'gi_kg', (select coalesce(sum(qty_out), 0) from ent where gi = 'gi'),
           'gi_pct', (select round(100 * coalesce(sum(qty_out) filter (where gi = 'gi'), 0) / nullif(sum(qty_out), 0), 1) from ent),
           'farm_verified_kg', (select coalesce(sum(qty_out), 0) from ent where stage_type = 'procurement'),
           'loss_kg', (select coalesce(sum(qty_in - qty_out), 0) from live where stage_type not in ('procurement', 'lot_inward') and qty_in > qty_out),
           'sealed_lots', (select count(*) from public.qr_seals q join public.footprints f on f.id = q.footprint_id where f.scope_id = p_scope),
           'packs', (select count(*) from public.packs p where p.scope_id = p_scope and p.status <> 'void'),
           'open_flags', (select count(*) from public.flags fl join public.footprints f on f.id = fl.footprint_id
                           where f.scope_id = p_scope and fl.status = 'open'),
           'records', coalesce(cardinality(ids), 0))
    into v_totals;
  perform app.audit('export_downloaded', p_scope, jsonb_build_object('kind', 'season', 'copy', p_copy,
    'rows', jsonb_array_length(t->'rows')), false);
  return t || jsonb_build_object('kind', 'season', 'copy', p_copy,
    'generated_at', to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI'),
    'units', app.param_units(p_scope), 'scope', app.export_scope_head(p_scope),
    'summary', v_summary, 'totals', v_totals, 'batches', v_batches);
end $$;

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
                   || jsonb_build_object('lab', (select case when l->>'name' is null then null
                        else jsonb_build_object('name', l->>'name', 'accreditation_no', l->>'accreditation_no') end
                        from (select app.qc_lab(cur.id) as l) x))                                       -- migration 60 (A5 on the public page)
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


-- =====================================================================================================================
-- who may call what
-- =====================================================================================================================
revoke execute on function app.may_internal_copy(uuid), app.export_record(uuid, boolean, numeric), app.export_table(uuid[], boolean, jsonb, text),
  app.export_scope_head(uuid), app.export_journey(uuid, text), app.export_season(uuid, text) from public, anon, authenticated;
grant execute on function app.may_internal_copy(uuid), app.export_journey(uuid, text), app.export_season(uuid, text) to authenticated;
