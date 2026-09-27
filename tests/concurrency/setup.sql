-- Concurrency check, step 1 (run_local only, after every other test; it COMMITS into the scratch database).
-- 20 farmers under review, five per worker session.
insert into public.farmers (client_id, scope_ids, status, name, guardian_name, village, district, phone, land_area_acres, created_by)
select '00000000-0000-4000-8000-000000000201', array[t.scope('01')], 'under_review', format('Concurrent %s-%s', w, i),
       'Shri Test', 'Bansi', 'Siddharthnagar', format('+9180000000%s%s', w, i), 1, t.u('05')
  from generate_series(1, 4) w, generate_series(1, 5) i;
