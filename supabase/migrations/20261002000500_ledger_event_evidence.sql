-- GrainVeda MVP · migration 26: a ledger event for evidence
--
-- PRD §9 Evidence: "photos and documents stored with SHA-256 recorded in ledger". Until now the hash was recorded in
-- public.attachments only, which is append-only for the app but is not part of the hash chain. Migration 27 writes a
-- ledger block for every piece of evidence; this file only adds the event name, on its own, because a new enum value
-- cannot be used in the transaction that adds it.
alter type public.ledger_event add value if not exists 'evidence';
