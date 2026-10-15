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
