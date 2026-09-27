-- Concurrency check, step 3: after the four sessions finished.
do $$
declare v_switches int;
begin
  perform t.ok(not exists (select 1 from app.verify_ledger()), 'concurrency: ledger chain valid after 4 sessions wrote at once');
  perform t.ok(not exists (select 1 from public.ledger group by prev_hash having count(*) > 1),
               'concurrency: no two blocks share a predecessor (the chain never forked)');
  perform t.ok((select count(*) from public.footprints) = 100, 'concurrency: all 100 lots saved');
  select count(*) into v_switches
    from (select f.farmer_id, lag(f.farmer_id) over (order by l.seq) as prev
            from public.ledger l join public.footprints f on f.id = l.footprint_id where l.event = 'create') s
   where prev is not null and prev <> farmer_id;
  perform t.ok(v_switches > 3, format('concurrency: the sessions really overlapped (%s switches between sessions; 3 = one after another)', v_switches));
  perform t.ok((select count(distinct farmer_code) from public.farmers where name like 'Concurrent %') = 20,
               'concurrency: 20 verifications at once got 20 distinct Farmer IDs');
  perform t.ok((select max(farmer_code) from public.farmers where client_id = '00000000-0000-4000-8000-000000000201') = 'PRSDM-F-0025',
               'concurrency: Farmer IDs run on to PRSDM-F-0025 with no gaps');
end $$;
