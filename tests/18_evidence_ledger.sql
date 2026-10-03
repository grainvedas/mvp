-- Migrations 26–27: every piece of evidence is a ledger block carrying its SHA-256 (PRD §9 Evidence).
begin;
select t.as_service();

do $$
declare p uuid; fp public.footprints; a public.attachments; b record; path text; n0 bigint; late uuid;
begin
  p := t.procure(t.scope('01'), t.farmer('02'), 150, 1, 2.5, 11.9, 11.8, 12.0);
  select * into fp from public.footprints where id = p;
  path := format('%s/%s/%s/weighbridge.jpg', fp.client_id, fp.scope_id, fp.id);
  select count(*) into n0 from public.ledger;

  perform t.as_user(t.u('05'));
  a := app.register_attachment(p, 'photo', path, repeat('AB', 32));
  perform t.as_service();
  select * into b from public.ledger order by seq desc limit 1;
  perform t.ok((select count(*) from public.ledger) = n0 + 1 and b.event = 'evidence' and b.footprint_id = p and b.scope_id = fp.scope_id
               and b.actor = t.u('05') and b.payload->>'sha256' = repeat('ab', 32) and b.payload->>'storage_path' = path
               and b.payload->>'attachment_id' = a.id::text and b.payload->>'kind' = 'photo',
               'evidence: registering a photo writes a ledger block with its path and SHA-256, in the uploader''s name');

  perform t.as_user(t.u('06'));                                          -- QC technician: the next stage sees the record
  perform t.ok((select count(*) from public.ledger where event = 'evidence' and footprint_id = p) = 1, 'evidence: the next stage reads the block with the record');
  perform t.as_user(t.u('10'));                                          -- grading operator of another scope
  perform t.ok((select count(*) from public.ledger where event = 'evidence') = 0, 'evidence: an operator who cannot see the record cannot read its evidence block');
  perform t.as_user(t.u('03'));
  perform t.ok((select count(*) from app.scope_activity(fp.scope_id, 14) x where x.saved > 0) >= 1
               and (select coalesce(sum(x.supervisory), 0) from app.scope_activity(fp.scope_id, 14) x) =
                   (select count(*) from public.ledger l where l.scope_id = fp.scope_id and l.event in ('supervisory', 'override', 'supersede')),
               'evidence: evidence blocks are not counted as saves or manager actions in the activity table');

  -- evidence registered before migration 27 (no block): the catch-up writes it once, marked late
  perform t.as_service();
  alter table public.attachments disable trigger attachments_ledger;
  insert into public.attachments (footprint_id, kind, storage_path, sha256, uploaded_by)
  values (p, 'document', format('%s/%s/%s/gate-pass.pdf', fp.client_id, fp.scope_id, fp.id), repeat('c', 64), t.u('05')) returning id into late;
  alter table public.attachments enable trigger attachments_ledger;
  perform t.ok(app.record_missing_evidence_blocks() = 1 and app.record_missing_evidence_blocks() = 0,
               'evidence: earlier evidence gets its block once');
  perform t.ok((select payload->>'recorded_late' = 'true' and payload->>'sha256' = repeat('c', 64) from public.ledger where payload->>'attachment_id' = late::text),
               'evidence: marked as recorded late, with the fingerprint held at that time');

  -- the invariant the audit checks: one block per attachment, same fingerprint
  perform t.ok(not exists (select 1 from public.attachments x
                            where (select count(*) from public.ledger l where l.event = 'evidence' and l.payload->>'attachment_id' = x.id::text
                                      and l.payload->>'sha256' = x.sha256 and l.payload->>'storage_path' = x.storage_path) <> 1),
               'evidence: every attachment has exactly one block with the same path and fingerprint');
  perform t.ok((select count(*) from app.verify_ledger()) = 0, 'evidence: the chain verifies');
  perform t.as_anon();
  perform t.fails('select app.record_missing_evidence_blocks()', 'permission denied', 'evidence: the catch-up is not callable from the API');
  perform t.as_service();
end $$;

rollback;
