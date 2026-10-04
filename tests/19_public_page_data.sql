-- Migration 28: what an anonymous visitor's browser receives from the public page's function.
-- Before it, every step carried the record's worked-out values ("computed"), which for a sale hold the BUYER'S NAME
-- and the market. The page never drew them, but anyone with the QR could read them. Now the answer is a fixed list of
-- keys, and nothing from a sale beyond its date and quantity.
begin;
select t.as_service();

do $$
declare s uuid := '00000000-0000-4000-8000-000000000405'; c uuid := '00000000-0000-4000-8000-000000000201';
        p uuid; q uuid; m uuid; pk uuid; ex uuid; sh uuid; qr uuid; seal public.qr_seals; j jsonb; txt text; bad text;
        top_ok constant text[] := array['qr_code','sealed_at','ledger_hash','batch_codes','crop','client','season','geography','verdict','journey'];
        step_ok constant text[] := array['stage','code','qty_in_kg','qty_out_kg','verified_at','created_at','captured_at','grade','farmer','farmers',
                                         'village','source','readings','batch_code','destination','dispatched_on'];
begin
  p := t.procure(s, t.farmer('05'), 199, 2, 2, 11.8, 11.7, 11.9);
  perform t.as_user(t.u('06')); perform app.verify_footprint(p);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qc', p, t.u('06'), '{"qty_kg":195,"sample_qty_kg":1,"readings":{"moisture_pct":11.8,"broken_pct":2,"foreign_matter_pct":0.2}}')
  returning id into q;
  perform t.as_user(t.u('08')); perform app.verify_footprint(q);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'milling', q, t.u('08'), '{"input_kg":194,"rice_kg":130,"bran_kg":54,"loss_kg":10}') returning id into m;
  perform t.as_user(t.u('09')); perform app.verify_footprint(m);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'packing', m, t.u('09'),
          '{"input_kg":130,"packets":[{"units":129,"size_kg":1}],"wastage_kg":1,"batch_code":"KNM-KH26-B777"}') returning id into pk;
  perform t.as_user(t.u('11')); perform app.verify_footprint(pk);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'commercial', pk, t.u('11'), '{"buyer":"Zeta Confidential Imports BV","market":"export","qty_kg":129,"price_per_kg":431.75}')
  returning id into ex;
  perform t.as_user(t.u('14')); perform app.verify_footprint(ex);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'shipment', ex, t.u('14'), '{"shipped_kg":129,"transit_loss_kg":0.5,"vehicle_or_container":"MSKU7654321",
          "dispatch_date":"2026-11-20","destination":"Rotterdam"}') returning id into sh;
  perform t.as_user(t.u('07')); perform app.verify_footprint(sh);
  insert into public.footprints (scope_id, client_id, stage_type, prev_footprint_id, created_by, payload)
  values (s, c, 'qr_activation', sh, t.u('07'), '{}') returning id into qr;
  seal := app.seal_lot(qr);

  -- the record itself does hold the buyer (so the checks below can fail)
  perform t.as_service();
  perform t.ok((select computed->>'buyer' from public.footprints where id = ex) = 'Zeta Confidential Imports BV',
               'public data: the sale record itself holds the buyer''s name');

  perform t.as_anon();
  j := app.public_lot_journey(seal.qr_code);
  txt := j::text;
  perform t.ok(jsonb_array_length(j->'journey') = 7, 'public data: the journey still has its 7 steps');
  perform t.ok(position('Zeta Confidential' in txt) = 0, 'public data: the buyer''s name is not sent to an anonymous visitor');
  perform t.ok(position('431.75' in txt) = 0, 'public data: the price is not sent');
  perform t.ok(position('MSKU7654321' in txt) = 0, 'public data: the container number is not sent');
  perform t.ok(not exists (select 1 from jsonb_array_elements(j->'journey') e where e ? 'computed' or e ? 'payload' or e ? 'buyer' or e ? 'market'),
               'public data: no step carries worked-out values, entered values, buyer or market');
  select string_agg(distinct k, ', ') into bad from jsonb_object_keys(j) k where k <> all (top_ok);
  perform t.ok(bad is null, 'public data: top level holds only the listed keys' || coalesce(' (extra: ' || bad || ')', ''));
  select string_agg(distinct k, ', ') into bad from jsonb_array_elements(j->'journey') e, jsonb_object_keys(e) k where k <> all (step_ok);
  perform t.ok(bad is null, 'public data: every step holds only the listed keys' || coalesce(' (extra: ' || bad || ')', ''));
  -- what the page draws is still there
  perform t.ok(exists (select 1 from jsonb_array_elements(j->'journey') e where e->'farmer'->>'name' is not null)
           and exists (select 1 from jsonb_array_elements(j->'journey') e where (e->'readings'->>'moisture_pct')::numeric = 11.8)
           and exists (select 1 from jsonb_array_elements(j->'journey') e where e->>'batch_code' = 'KNM-KH26-B777')
           and exists (select 1 from jsonb_array_elements(j->'journey') e where e->>'destination' = 'Rotterdam' and e->>'dispatched_on' = '2026-11-20')
           and exists (select 1 from jsonb_array_elements(j->'journey') e where e->>'stage' = 'commercial' and (e->>'qty_out_kg')::numeric = 129),
               'public data: farmer, lab readings, batch code, destination, dispatch date and the sold quantity are still sent');
  perform t.as_service();
end $$;

rollback;
