-- Concurrency check, step 2: one of four sessions started at the same time (psql -v worker=1..4).
-- Each saves 25 lots and verifies its 5 farmers, committing every act on its own, so the sessions' ledger appends and
-- Farmer ID draws interleave. Worker w records lots for seeded farmer 0w, which is how check.sql tells sessions apart.
select set_config('cc.worker', :'worker', false) as worker;
do $$
declare w int := current_setting('cc.worker')::int;
begin
  for i in 1..25 loop
    perform t.procure(t.scope('01'), t.farmer('0' || w), 100, 1, 1, 12, 12, 12);
    commit;
    perform pg_sleep(random() * 0.01);
    if i % 5 = 0 then
      update public.farmers set status = 'active', verified_by = t.u('02') where name = format('Concurrent %s-%s', w, i / 5);
      commit;
    end if;
  end loop;
end $$;
