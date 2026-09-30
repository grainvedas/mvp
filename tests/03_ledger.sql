-- Rule 6: ledger is append-only, hash-chained, and tamper-evident.
begin;
select t.as_service();

do $$
declare fp uuid; n0 bigint; n1 bigint; bad record;
begin
  select count(*) into n0 from public.ledger;
  fp := t.procure(t.scope('01'), t.farmer('04'), 166, 2, 2, 12.1, 12.0, 12.2);   -- 162
  select count(*) into n1 from public.ledger;
  perform t.ok(n1 = n0 + 1, 'ledger: create writes one block');
  perform t.ok((select event from public.ledger order by seq desc limit 1) = 'create', 'ledger: event = create');
  perform t.verify(fp, t.u('06'));
  perform t.ok((select event from public.ledger order by seq desc limit 1) = 'verify', 'ledger: verification writes a verify block');
  perform t.ok((select count(*) from public.ledger where event = 'scope_activate') = (select count(*) from public.scopes where status = 'active'),
    'ledger: every seeded scope activation was ledgered');

  -- chain integrity
  select * into bad from app.verify_ledger();
  perform t.ok(bad.seq is null, 'ledger: verify_ledger() finds no bad block on an untouched chain');

  -- prev_hash links
  perform t.ok(not exists (
      select 1 from public.ledger l join public.ledger p on p.seq = l.seq - 1 where l.prev_hash <> p.hash),
    'ledger: every block''s prev_hash equals the previous block''s hash');

  -- no UPDATE / DELETE through any path
  perform t.fails($q$ update public.ledger set payload = '{}'::jsonb where seq = 1 $q$, 'append-only', 'ledger: UPDATE refused (superuser included)');
  perform t.fails($q$ delete from public.ledger where seq = 1 $q$, 'append-only', 'ledger: DELETE refused (superuser included)');
end $$;

-- Tamper simulation: a DBA disables the guard trigger and edits a payload → nightly verification must catch it.
alter table public.ledger disable trigger ledger_no_update_delete;
update public.ledger set payload = payload || '{"qty_out": 9999}'::jsonb where seq = (select min(seq) from public.ledger where event = 'create');
alter table public.ledger enable trigger ledger_no_update_delete;
do $$
declare bad record;
begin
  select * into bad from app.verify_ledger();
  perform t.ok(bad.seq is not null and bad.problem = 'payload_hash mismatch', 'ledger: altered payload detected at seq ' || coalesce(bad.seq::text, '?'));
end $$;

rollback;
