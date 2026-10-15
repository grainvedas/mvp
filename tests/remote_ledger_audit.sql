-- READ-ONLY audit of the ledger against the records it describes. One statement; safe on any project.
--   supabase db query --linked -f tests/remote_ledger_audit.sql        (or: psql -f tests/remote_ledger_audit.sql)
-- Expected: one row, 'NO FINDINGS'. Anything else: stop and report the rows.
--
-- Why it exists. app.verify_ledger() proves the chain is intact (no block changed, removed or reordered). It cannot see
--   (a) a block that was appended properly but describes nothing real (until migration 14 anyone with the public key
--       could call app.ledger_append), nor
--   (b) a record that was changed underneath its block: an evidence fingerprint rewritten in public.attachments, a
--       record without its 'create' block, a seal whose hash is not the ledger's.
-- This audit checks both directions. It knows every kind of block written up to migration 45, and needs migration 31
-- on the project (it reads public.assignments): push the migrations first.
-- Migration 44: a scope put back to draft by the owner's correction keeps its activation blocks; the correcting block
-- ('activation_reversed', after them) is their counterpart.
with blocks as (
  select l.seq, l.event::text as event, l.footprint_id, l.scope_id, l.actor, l.hash, l.created_at, l.payload,
    case l.event::text
      when 'scope_activate' then exists (select 1 from public.scopes s where s.id = l.scope_id and s.status <> 'draft')
                                 or exists (select 1 from public.ledger r where r.seq > l.seq and r.scope_id = l.scope_id and r.payload->>'act' = 'activation_reversed')
      when 'create'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.created_by = l.actor)
      when 'verify'         then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.verified_by = l.actor)
      when 'seal'           then exists (select 1 from public.qr_seals q where q.footprint_id = l.footprint_id and q.ledger_hash = l.hash)
      when 'override'       then exists (select 1 from public.qc_verdicts v where v.footprint_id = l.footprint_id and v.override is not null)
      when 'close'          then exists (select 1 from public.footprints f where f.id = l.footprint_id)          -- a withdrawal may reopen the lot later
      when 'supersede'      then exists (select 1 from public.footprints f where f.id = l.footprint_id and f.status = 'superseded')
      when 'evidence'       then exists (select 1 from public.attachments a
                                          where a.id::text = l.payload->>'attachment_id' and a.footprint_id = l.footprint_id
                                            and a.sha256 = l.payload->>'sha256' and a.storage_path = l.payload->>'storage_path')
      -- migration 48: a record returned to its sender, the return closed by its correction or withdrawal, the sender's
      -- own withdrawal of a returned record
      when 'return'         then case
          when l.payload->>'act' = 'returned'
            then exists (select 1 from public.footprint_returns r where r.footprint_id = l.footprint_id and r.returned_by = l.actor)
          when l.payload->>'act' = 'withdraw'
            then exists (select 1 from public.withdrawals w where w.footprint_id = l.footprint_id and w.withdrawn_by = l.actor)
          else exists (select 1 from public.footprint_returns r where r.id::text = l.payload->>'return_id' and r.footprint_id = l.footprint_id
                         and r.status = l.payload->>'act')
        end
      -- migration 50: what arrived, recorded at delivery
      when 'delivery'       then exists (select 1 from public.deliveries d where d.shipment_id = l.footprint_id and d.confirmed_by = l.actor
                                          and d.received_kg::text = l.payload->>'received_kg')
      when 'supervisory'    then case
          -- migration 50: a release's status changed (under investigation, recalled, active again)
          when l.payload->>'act' like 'release\_%'
            then exists (select 1 from public.release_events e where e.seal_id = l.footprint_id and e.by_user = l.actor
                           and e.status = l.payload->>'to')
          when l.payload->>'act' = 'withdraw'
            then exists (select 1 from public.withdrawals w where w.footprint_id = l.footprint_id and w.withdrawn_by = l.actor)
          when l.payload->>'act' like 'flag\_%'
            then exists (select 1 from public.flags fl where fl.id::text = l.payload->>'flag_id' and fl.footprint_id = l.footprint_id)
          when l.payload->>'act' in ('slot_assigned', 'slot_removed', 'slots_at_activation')
            then exists (select 1 from public.scopes s where s.id = l.scope_id and s.status <> 'draft')
              or exists (select 1 from public.ledger r where r.seq > l.seq and r.scope_id = l.scope_id and r.payload->>'act' = 'activation_reversed')
          -- migration 44: the owner's correction of a scope activated in a test (it is a draft again)
          when l.payload->>'act' = 'activation_reversed'
            then exists (select 1 from public.scopes s where s.id = l.scope_id)
          -- migration 45: a correction opened and closed through the door, in the name of the admin who asked
          when l.payload->>'act' = 'correction_opened'
            then exists (select 1 from public.corrections c where c.id::text = l.payload->>'correction_id' and c.requested_by = l.actor
                           and c.status in ('open', 'done'))
          when l.payload->>'act' = 'correction_closed'
            then exists (select 1 from public.corrections c where c.id::text = l.payload->>'correction_id' and c.requested_by = l.actor
                           and c.status = 'done' and c.rows_changed::text = l.payload->>'rows_changed')
          -- identity layer (migration 31): who was given, or lost, a client's account, a state, or an export manager's view
          when l.payload->>'act' = 'assignment_given'
            then exists (select 1 from public.assignments a where a.id::text = l.payload->>'assignment_id' and a.employee_id::text = l.payload->>'user_id')
          when l.payload->>'act' = 'assignment_ended'
            then exists (select 1 from public.assignments a where a.id::text = l.payload->>'assignment_id' and a.employee_id::text = l.payload->>'user_id' and not a.active)
          when l.payload->>'kind' in ('farmer_verified', 'farmer_changed', 'farmer_verified_client', 'farmer_verified_state', 'state_farmer_id_given')   -- the last three: migration 44
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
  -- A record's first block is 'create', or 'supervisory' when a manager made it at a stage they do not hold
  -- (app.footprints_after_insert). The audit knew only 'create' until 10 Oct 2026, when the admin's test lot on
  -- staging (made as admin, holding no stage) was reported as five records without their block.
  select null, 'create', f.id::text, f.created_at, 'RECORD WITHOUT ITS CREATE BLOCK'
    from public.footprints f
   where f.status <> 'legacy'
     and not exists (select 1 from public.ledger l where l.footprint_id = f.id and l.event::text = 'create')
     and not exists (select 1 from public.ledger l where l.footprint_id = f.id and l.event::text = 'supervisory'
                       and l.seq = (select min(l2.seq) from public.ledger l2 where l2.footprint_id = f.id)
                       and l.payload->>'id' = f.id::text)
  union all
  select null, 'seal', q.footprint_id::text, q.sealed_at, 'SEAL WHOSE HASH IS NOT IN THE LEDGER'
    from public.qr_seals q
   where not exists (select 1 from public.ledger l where l.footprint_id = q.footprint_id and l.event::text = 'seal' and l.hash = q.ledger_hash)
  union all
  select null, 'withdraw', w.footprint_id::text, w.withdrawn_at, 'WITHDRAWAL WITHOUT ITS BLOCK'
    from public.withdrawals w
   where not exists (select 1 from public.ledger l where l.footprint_id = w.footprint_id and l.event::text in ('supervisory', 'return') and l.payload->>'act' = 'withdraw')
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
