-- GrainVeda MVP · seed 09: migration 50 (packs, proof and blocks). The demo scopes do not ask for a lab report file
-- (their tests record lab results without one); a scope made in the app asks for it (the default), and e2e/phase22,
-- e2e/phase7, e2e/phase14 and the first day from nothing test that path. A seed of its own so that it runs after the
-- migrations on a database in use (the upgrade path of tests/run_local.sh). Demo data: never on production. Idempotent.
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

update public.scopes set qc_report_required = false where id::text like '00000000-0000-4000-8000-0000000004%' and qc_report_required;

-- Migration 52 (C1): the demo scopes do not ask where, GPS and who delivered at Procurement (their tests record lots
-- without them); a scope made in the app asks them (the default), and tests/46 and e2e/phase24 turn it on to test that
-- path. A database from before migration 52 has no such column: nothing to do.
do $seed52$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scopes' and column_name = 'procurement_details_required') then
    execute $q$ update public.scopes set procurement_details_required = false
                 where id::text like '00000000-0000-4000-8000-0000000004%' $q$;
  end if;
end $seed52$;

-- Migration 53 (C4–C6): the demo scopes do not ask the mill, the sample and lab from the lists, the packing unit and the
-- packs from the pack list (their tests record without them); a scope made in the app asks them, and tests/47 and
-- e2e/phase25 turn it on to test that path.
do $seed53$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'scopes' and column_name = 'stage_details_required') then
    execute $q$ update public.scopes set stage_details_required = false
                 where id::text like '00000000-0000-4000-8000-0000000004%' $q$;
  end if;
end $seed53$;

-- Migration 54: a farmer's village is picked from the places list (district, block, village) before he is verified.
-- The demo's villages are on the list, so that the tests and the demo register farmers there; a block and village of
-- the practice system are added by its people in Set-up lists, Places. A database from before migration 51 has no
-- places: nothing to do.
do $seed54$
declare up uuid := (select id from public.states where name = 'Uttar Pradesh' limit 1); v text[];
begin
  if to_regclass('public.places') is null or up is null then return; end if;
  foreach v slice 1 in array array[
    ['Siddharthnagar', 'Bansi', 'Bansi'], ['Siddharthnagar', 'Bansi', 'Itwa'], ['Siddharthnagar', 'Bansi', 'Bansi Kalan'],
    ['Siddharthnagar', 'Bansi', 'Bansi Khurd'], ['Siddharthnagar', 'Bansi', 'Naugarh'], ['Siddharthnagar', 'Bansi', 'Shohratgarh'],
    ['Siddharthnagar', 'Domariyaganj', 'Domariyaganj'], ['Siddharthnagar', 'Domariyaganj', 'Domariaganj'],
    ['Maharajganj', 'Nichlaul', 'Nichlaul'], ['Lucknow', 'Gosaiganj', 'Gosaiganj'], ['Gorakhpur', 'Campierganj', 'Campierganj']] loop
    if exists (select 1 from public.places p where p.state_id = up and p.block is null and app.norm_place(p.district) = app.norm_place(v[1])) then
      insert into public.places (state_id, district, block) values (up, v[1], v[2]) on conflict do nothing;
      insert into public.places (state_id, district, block, village) values (up, v[1], v[2], v[3]) on conflict do nothing;
    end if;
  end loop;
end $seed54$;
