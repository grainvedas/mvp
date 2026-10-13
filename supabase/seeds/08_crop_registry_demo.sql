-- GrainVeda MVP · seed 08: the demo crops are ready (migration 42: a scope is activated only with a ready crop: unit,
-- yield per acre, quality limits, recommended chain). No practice list and no harvest window here, so the demo lots of
-- the other tests are recorded as before; tests/36_crop_registry.sql makes its own. Demo data: never on production.
-- Idempotent.
do $$ begin
  if to_regprocedure('app.environment()') is not null then
    if app.environment() = 'production' then
      raise exception 'demo seed refused: this is the PRODUCTION project (use supabase/seeds/production/)';
    end if;
  end if;
end $$;

update public.crops set yield_per_acre_kg = 1000,
       recommended_chain = '{procurement,qc,qr_activation}',               -- the shortest: the wizard starts from it as it did before
       export_docs = '{Phytosanitary certificate,Certificate of origin,GI authorised user certificate,Lab report}'
 where id = '00000000-0000-4000-8000-000000000101' and yield_per_acre_kg is null;
update public.crops set yield_per_acre_kg = 800, recommended_chain = '{procurement,qc,qr_activation}'
 where id = '00000000-0000-4000-8000-000000000102' and yield_per_acre_kg is null;
