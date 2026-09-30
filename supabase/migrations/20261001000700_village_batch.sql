-- GrainVeda MVP · migration 20: Village Batch end to end (Phase 2)
--
-- Gaps found while building the batch screen and its test:
-- 1. public_lot_journey walks prev_footprint_id, which for a batch points at its FIRST source only, so the public page
--    named one farmer of a batch of many. Its body is re-created from migration 6 MECHANICALLY (script) with one block
--    added: a village_batch step lists every farmer in the batch.
-- 2. seal_lot's gate walks the same single path, so an open flag on any other source lot of a batch did not block the
--    seal. A BEFORE INSERT trigger on qr_seals now re-checks every batch source (seal_lot inserts the seal last, so a
--    refusal here undoes the whole seal). seal_lot itself is untouched.

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

create or replace function app.qr_seals_batch_sources_gate() returns trigger
language plpgsql security definer set search_path = public as $$
declare cur public.footprints; hops int := 0; src uuid; s public.footprints;
begin
  select * into cur from public.footprints where id = new.footprint_id;
  while cur.id is not null and hops < 64 loop
    if cur.stage_type = 'village_batch' then
      for src in select (x)::uuid from jsonb_array_elements_text(cur.payload->'source_footprint_ids') x loop
        select * into s from public.footprints where id = src;
        if s.status <> 'verified' then
          raise exception 'gate: batch source % is not verified', s.footprint_code using errcode = '23514'; end if;
        if exists (select 1 from public.flags fl where fl.footprint_id = src and fl.status = 'open') then
          raise exception 'gate: open flag on batch source %', s.footprint_code using errcode = '23514'; end if;
      end loop;
    end if;
    exit when cur.prev_footprint_id is null;
    select * into cur from public.footprints where id = cur.prev_footprint_id;
    hops := hops + 1;
  end loop;
  return new;
end $$;
create trigger qr_seals_batch_sources_gate before insert on public.qr_seals
  for each row execute function app.qr_seals_batch_sources_gate();

-- public_lot_journey keeps its grants (create or replace preserves them); the new trigger function is closed.
revoke execute on function app.qr_seals_batch_sources_gate() from public, anon, authenticated;
notify pgrst, 'reload schema';
