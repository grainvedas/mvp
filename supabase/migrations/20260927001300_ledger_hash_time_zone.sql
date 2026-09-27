-- GrainVeda MVP · Phase 0 · migration 13: ledger hashes independent of the session's time zone (workstream H; PRD §8)
-- ledger_append hashes created_at::text and verify_ledger recomputes it. timestamptz → text follows the session's
-- TimeZone and DateStyle, so a block written by a session in Asia/Kolkata failed verification in a UTC session, and
-- would look tampered with. Both functions now run with UTC + ISO whatever the caller's settings. Blocks written so far
-- came from UTC/ISO sessions (the Supabase default), so they verify unchanged. Bodies untouched (AGENTS.md lesson).

alter function app.ledger_append(uuid, uuid, public.ledger_event, uuid, jsonb) set timezone = 'UTC' set datestyle = 'ISO';
alter function app.verify_ledger() set timezone = 'UTC' set datestyle = 'ISO';
