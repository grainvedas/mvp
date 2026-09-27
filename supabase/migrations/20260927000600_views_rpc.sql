-- GrainVeda MVP · Phase 0 · migration 6: incoming-records (rule 9), public verify journey, pipeline summary

-- Rule 9: what the operator at p_stage sees as incoming — only the stage directly behind, same scope,
-- pending or verified, open, not a split parent, with quantity left. Grade lots ride in as stage 'grading'.
create or replace function app.incoming_records(p_scope uuid, p_stage public.stage_type)
returns setof public.footprints
language sql stable security definer set search_path = public as $$
  select f.*
  from public.footprints f
  where f.scope_id = p_scope
    and f.stage_type = app.chain_prev(p_scope, p_stage)
    and f.status in ('pending','verified')
    and f.lot_closed = false
    and f.split_into_grades = false
    and app.available_qty(f.id) > 0
    and (auth.uid() is null or app.can_see_footprint(f.scope_id, f.stage_type))   -- service role: unfiltered
  order by f.created_at
$$;
grant execute on function app.incoming_records(uuid, public.stage_type) to authenticated;

-- Public verify page (PRD F12): no login, one sealed lot, farmer PII limited to name + village (+ photo only with consent).
create or replace function app.public_lot_journey(p_qr_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare seal public.qr_seals; cur public.footprints; steps jsonb := '[]'::jsonb; hops int := 0;
        v_scope public.scopes; v_crop public.crops; v_client public.clients; vd record; fm public.farmers; step jsonb;
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
      'verified_at', cur.verified_at, 'created_at', cur.created_at, 'computed', cur.computed, 'grade', cur.grade);
    if cur.stage_type = 'procurement' and cur.farmer_id is not null then
      select * into fm from public.farmers where id = cur.farmer_id;
      step := step || jsonb_build_object('farmer', jsonb_build_object('name', fm.name, 'village', fm.village, 'district', fm.district,
                                            'photo', case when fm.photo_consent then fm.extra->>'photo_path' else null end));
    end if;
    if cur.stage_type = 'lot_inward' then
      step := step || jsonb_build_object('source', jsonb_build_object('type', cur.payload->>'source_type', 'name', cur.payload->>'source_name'));
    end if;
    if cur.stage_type = 'qc' then
      step := step || jsonb_build_object('readings', (select readings from public.qc_verdicts where footprint_id = cur.id));
    end if;
    if cur.stage_type = 'packing' then step := step || jsonb_build_object('batch_code', cur.payload->>'batch_code'); end if;
    if cur.stage_type = 'shipment' then
      step := step || jsonb_build_object('destination', cur.payload->>'destination', 'dispatched_on', cur.payload->>'dispatch_date'); end if;
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
    'journey', steps
  );
end $$;
grant execute on function app.public_lot_journey(text) to anon, authenticated;

-- Pipeline summary per scope for the Client Manager dashboard (F13).
create or replace function app.pipeline_summary(p_scope uuid)
returns table (stage public.stage_type, chain_pos int, records bigint, pending bigint, verified bigint, kg_out numeric, kg_available numeric)
language sql stable security definer set search_path = public as $$
  select c.st, c.i::int,
         count(f.id), count(f.id) filter (where f.status = 'pending'), count(f.id) filter (where f.status = 'verified'),
         coalesce(sum(f.qty_out) filter (where f.status = 'verified' and not f.split_into_grades), 0),
         coalesce(sum(app.available_qty(f.id)) filter (where f.status = 'verified' and not f.lot_closed and not f.split_into_grades), 0)
  from public.scopes s
  cross join unnest(s.chain) with ordinality as c(st, i)
  left join public.footprints f on f.scope_id = s.id and f.stage_type = c.st and f.status not in ('superseded','legacy')
  where s.id = p_scope and app.can_access_scope(s.id)
  group by c.st, c.i order by c.i
$$;
grant execute on function app.pipeline_summary(uuid) to authenticated;
