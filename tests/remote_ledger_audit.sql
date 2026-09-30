-- READ-ONLY audit: does every ledger block have a real counterpart? Run once on the live project after migration 14,
-- because until then anyone with the public key could call app.ledger_append (27 Sep → push of migration 14).
-- A forged block hashes correctly, so verify_ledger() cannot see it; only its missing counterpart gives it away.
--   supabase db query --linked -f tests/remote_ledger_audit.sql
-- Expected: one row, 'NO ORPHAN BLOCKS'. Anything else: stop and report the rows.
with blocks as (
  select l.seq, l.event, l.footprint_id, l.scope_id, l.actor, l.hash, l.created_at,
    case l.event
      when 'scope_activate' then exists (select 1 from public.scopes s where s.id = l.scope_id and s.status <> 'draft')
      when 'create'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.created_by = l.actor)
      when 'supervisory'    then exists (select 1 from public.footprints f where f.id = l.footprint_id)
      when 'verify'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.verified_by = l.actor)
      when 'seal'           then exists (select 1 from public.qr_seals q where q.footprint_id = l.footprint_id and q.ledger_hash = l.hash)
      when 'override'       then exists (select 1 from public.qc_verdicts v where v.footprint_id = l.footprint_id and v.override is not null)
      when 'close'          then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.lot_closed)
      when 'supersede'      then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.status = 'superseded')
      else false end as has_counterpart
  from public.ledger l
)
select seq, event, footprint_id, scope_id, actor, created_at, 'ORPHAN BLOCK' as finding
  from blocks where not has_counterpart
union all
select null, null, null, null, null, null,
       format('NO ORPHAN BLOCKS (%s blocks checked)', (select count(*) from blocks))
 where not exists (select 1 from blocks where not has_counterpart)
order by 1 nulls last;
