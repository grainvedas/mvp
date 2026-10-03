-- READ-ONLY audit of the ledger against the records it describes. One statement; safe on any project.
--   supabase db query --linked -f tests/remote_ledger_audit.sql        (or: psql -f tests/remote_ledger_audit.sql)
-- Expected: one row, 'NO FINDINGS'. Anything else: stop and report the rows.
--
-- Why it exists. app.verify_ledger() proves the chain is intact (no block changed, removed or reordered). It cannot see
--   (a) a block that was appended properly but describes nothing real (until migration 14 anyone with the public key
--       could call app.ledger_append), nor
--   (b) a record that was changed underneath its block: an evidence fingerprint rewritten in public.attachments, a
--       record without its 'create' block, a seal whose hash is not the ledger's.
-- This audit checks both directions. It knows every kind of block written up to migration 27.
with blocks as (
  select l.seq, l.event::text as event, l.footprint_id, l.scope_id, l.actor, l.hash, l.created_at, l.payload,
    case l.event::text
      when 'scope_activate' then exists (select 1 from public.scopes s where s.id = l.scope_id and s.status <> 'draft')
      when 'create'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.created_by = l.actor)
      when 'verify'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.verified_by = l.actor)
      when 'seal'           then exists (select 1 from public.qr_seals q where q.footprint_id = l.footprint_id and q.ledger_hash = l.hash)
      when 'override'       then exists (select 1 from public.qc_verdicts v where v.footprint_id = l.footprint_id and v.override is not null)
      when 'close'          then exists (select 1 from public.footprints f where f.id = l.footprint_id)          -- a withdrawal may reopen the lot later
      when 'supersede'      then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.status = 'superseded')
      when 'evidence'       then exists (select 1 from public.attachments a
                                          where a.id::text = l.payload->>'attachment_id' and a.footprint_id = l.footprint_id
                                            and a.sha256 = l.payload->>'sha256' and a.storage_path = l.payload->>'storage_path')
      when 'supervisory'    then case
          when l.payload->>'act' = 'withdraw'
            then exists (select 1 from public.withdrawals w where w.footprint_id = l.footprint_id and w.withdrawn_by = l.actor)
          when l.payload->>'act' like 'flag\_%'
            then exists (select 1 from public.flags fl where fl.id::text = l.payload->>'flag_id' and fl.footprint_id = l.footprint_id)
          when l.payload->>'act' in ('slot_assigned', 'slot_removed', 'slots_at_activation')
            then exists (select 1 from public.scopes s where s.id = l.scope_id and s.status <> 'draft')
          when l.payload->>'kind' in ('farmer_verified', 'farmer_changed')
            then exists (select 1 from public.farmers fm where fm.id::text = l.payload->>'farmer_id')
          when l.payload->>'kind' in ('user_created', 'user_changed')
            then exists (select 1 from public.app_users u where u.id::text = l.payload->>'user_id')
              or exists (select 1 from public.ledger r where r.seq > l.seq and r.payload->>'kind' = 'user_removed' and r.payload->>'user_id' = l.payload->>'user_id')
          when l.payload->>'kind' = 'user_removed'
            then not exists (select 1 from public.app_users u where u.id::text = l.payload->>'user_id')
          else exists (select 1 from public.footprints f where f.id = l.footprint_id)                           -- a manager acting at a stage
        end
      else false end as has_counterpart
  from public.ledger l
),
findings as (
  select seq, event, footprint_id::text as subject, created_at, 'BLOCK WITHOUT A REAL COUNTERPART' as finding
    from blocks where not has_counterpart
  union all
  select null, 'create', f.id::text, f.created_at, 'RECORD WITHOUT ITS CREATE BLOCK'
    from public.footprints f
   where f.status <> 'legacy' and not exists (select 1 from public.ledger l where l.footprint_id = f.id and l.event::text = 'create')
  union all
  select null, 'seal', q.footprint_id::text, q.sealed_at, 'SEAL WHOSE HASH IS NOT IN THE LEDGER'
    from public.qr_seals q
   where not exists (select 1 from public.ledger l where l.footprint_id = q.footprint_id and l.event::text = 'seal' and l.hash = q.ledger_hash)
  union all
  select null, 'withdraw', w.footprint_id::text, w.withdrawn_at, 'WITHDRAWAL WITHOUT ITS BLOCK'
    from public.withdrawals w
   where not exists (select 1 from public.ledger l where l.footprint_id = w.footprint_id and l.event::text = 'supervisory' and l.payload->>'act' = 'withdraw')
  union all
  -- evidence: one block per file, carrying the fingerprint the file has in the table today (checked only once migration 27 is in)
  select null, 'evidence', a.id::text, a.created_at,
         case when not exists (select 1 from public.ledger l where l.event::text = 'evidence' and l.payload->>'attachment_id' = a.id::text)
              then 'EVIDENCE WITHOUT ITS BLOCK (run: select app.record_missing_evidence_blocks())'
              else 'EVIDENCE FINGERPRINT OR PATH DIFFERS FROM ITS BLOCK' end
    from public.attachments a
   where to_regprocedure('app.record_missing_evidence_blocks()') is not null
     and (select count(*) from public.ledger l
           where l.event::text = 'evidence' and l.payload->>'attachment_id' = a.id::text
             and l.payload->>'sha256' = a.sha256 and l.payload->>'storage_path' = a.storage_path) <> 1
)
select seq, event, subject, created_at, finding from findings
union all
select null, null, null, null,
       format('NO FINDINGS (%s blocks, %s records, %s seals, %s evidence files checked)',
              (select count(*) from blocks), (select count(*) from public.footprints),
              (select count(*) from public.qr_seals), (select count(*) from public.attachments))
 where not exists (select 1 from findings)
order by 1 nulls last, 4;
