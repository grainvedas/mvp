-- Migration 17: only the creator (or a manager) corrects a pending record; the correction preview equals the update.
begin;
select t.as_service();
do $$
declare p uuid; pv jsonb; r public.footprints;
begin
  p := t.procure(t.scope('01'), t.farmer('01'), 126, 3, 2, 12.1, 12.0, 12.2);          -- 120 kg, pending, by 305
  perform t.as_user(t.u('06'));
  perform t.fails(format($q$ update public.footprints set payload = payload || '{"gross_kg":200}' where id = %L $q$, p),
                  'only the person who recorded', 'S20 next-stage operator cannot rewrite a pending lot before verifying it');
  pv := app.preview_correction(p, '{"gross_kg":130,"bags":3,"tare_kg_per_bag":2,"moisture_pct":[12.1,12.0,12.2]}');
  perform t.ok(not (pv->>'ok')::boolean, 'S20 correction preview refused for someone else''s record');
  perform t.as_user(t.u('05'));
  pv := app.preview_correction(p, '{"gross_kg":130,"bags":3,"tare_kg_per_bag":2,"moisture_pct":[12.1,12.0,12.2]}');
  perform t.ok((pv->>'ok')::boolean and (pv->>'qty_out')::numeric = 124, 'S20 creator previews the correction: 130 - 3x2 = 124');
  update public.footprints set payload = '{"gross_kg":130,"bags":3,"tare_kg_per_bag":2,"moisture_pct":[12.1,12.0,12.2]}' where id = p
  returning * into r;
  perform t.ok(r.qty_out = (pv->>'qty_out')::numeric and r.computed = pv->'computed', 'S20 correction preview = saved correction');
  perform t.as_user(t.u('03'));
  update public.footprints set payload = payload || '{"gross_kg":131}' where id = p returning * into r;
  perform t.ok(r.qty_out = 125, 'S20 a client manager may correct a pending record');
  perform t.as_user(t.u('06'));
  perform app.verify_footprint(p);
  perform t.as_user(t.u('05'));
  pv := app.preview_correction(p, '{"gross_kg":140,"bags":3,"tare_kg_per_bag":2,"moisture_pct":[12,12,12]}');
  perform t.ok(pv->>'error' = 'only a pending record can be corrected', 'S20 a verified record cannot be corrected');
  perform t.as_service();
end $$;
rollback;
