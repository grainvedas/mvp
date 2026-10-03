-- GrainVeda MVP · migration 27: evidence in the hash chain
--
-- Every photo or document registered against a record is now a ledger block (event 'evidence') carrying the file's
-- path and SHA-256, the record, who uploaded it and when. The nightly check then covers the fingerprints too: a file
-- or a fingerprint replaced afterwards no longer matches the chain (tests/remote_ledger_audit.sql compares them).
-- Evidence registered before this migration gets its block now, marked as recorded late.

create or replace function app.attachments_ledger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.ledger_append(new.footprint_id, (select f.scope_id from public.footprints f where f.id = new.footprint_id),
    'evidence'::public.ledger_event, new.uploaded_by,
    jsonb_build_object('attachment_id', new.id, 'footprint_id', new.footprint_id, 'kind', new.kind,
                       'storage_path', new.storage_path, 'sha256', new.sha256, 'registered_at', new.created_at));
  return null;
end $$;
create trigger attachments_ledger after insert on public.attachments
  for each row execute function app.attachments_ledger();

-- Blocks for evidence that has none (registered before this migration). Safe to run again: it finds nothing.
create or replace function app.record_missing_evidence_blocks() returns int
language plpgsql security definer set search_path = public as $$
declare a public.attachments; n int := 0;
begin
  for a in select x.* from public.attachments x
            where not exists (select 1 from public.ledger l where l.event = 'evidence' and l.payload->>'attachment_id' = x.id::text)
            order by x.created_at, x.id loop
    perform app.ledger_append(a.footprint_id, (select f.scope_id from public.footprints f where f.id = a.footprint_id),
      'evidence'::public.ledger_event, a.uploaded_by,
      jsonb_build_object('attachment_id', a.id, 'footprint_id', a.footprint_id, 'kind', a.kind,
                         'storage_path', a.storage_path, 'sha256', a.sha256, 'registered_at', a.created_at, 'recorded_late', true));
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function app.attachments_ledger(), app.record_missing_evidence_blocks() from public, anon, authenticated;
-- If this file and migration 26 are applied in one transaction, the new event name cannot be used yet: the catch-up is
-- then skipped here and run once afterwards (run-sheet step: select app.record_missing_evidence_blocks();).
do $$
begin
  raise notice 'evidence blocks written for % earlier attachment(s)', app.record_missing_evidence_blocks();
exception when others then
  raise notice 'catch-up not run in this transaction (%): run  select app.record_missing_evidence_blocks();  once after the push', sqlerrm;
end $$;
notify pgrst, 'reload schema';
