-- GrainVeda MVP · migration 28: what the public page's function sends (found 4 Oct 2026 while comparing with the prototype)
--
-- app.public_lot_journey is callable by anyone (anon). Every step it returned carried the record's worked-out values
-- ("computed"). For a Commercial step those are {market, buyer}: the BUYER'S NAME reached the browser of anyone who
-- scanned the QR, although the page never drew it. Milling yield, losses and sample sizes went out the same way.
-- The page uses none of these values, so the key is removed. The body below is migration 20's, re-created MECHANICALLY
-- (script: one substring removed, asserted to occur once); nothing else differs.
-- What a step now holds: stage, code, qty_in_kg, qty_out_kg, verified_at, created_at, grade, and per stage: farmer,
-- farmers + village, source, readings, batch_code, destination + dispatched_on. tests/19_public_page_data.sql holds
-- that list and fails on any other key.

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
      'verified_at', cur.verified_at, 'created_at', cur.created_at, 'grade', cur.grade);
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
    if cur.stage_type = 'village_batch' then
      step := step || jsonb_build_object('village', cur.payload->>'village', 'farmers', coalesce((
        select jsonb_agg(jsonb_build_object('name', fa.name, 'village', fa.village, 'district', fa.district, 'qty_kg', src.qty_out)
                         order by fa.name)
          from public.footprints src join public.farmers fa on fa.id = src.farmer_id
         where src.id in (select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x)), '[]'::jsonb));
    end if;
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

-- create or replace keeps the grants of migration 14 (anon, authenticated). No new function: nothing to close.
