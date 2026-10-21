-- GrainVeda MVP · migration 63a: the ledger events of closing a scope and of issued reports (Phase 1, release 5 of Veda's
-- combined brief of 19 Oct 2026, Part D; "ok continue"). New values of public.ledger_event, in a migration of their own:
-- a value added to an enum cannot be used in the transaction that adds it, and every migration is one transaction.
-- Migration 63 uses them. Nothing else changes here.
select set_config('app.change_path', 'migration 63a', true);
alter type public.ledger_event add value if not exists 'scope_close_request';
alter type public.ledger_event add value if not exists 'scope_close';
alter type public.ledger_event add value if not exists 'scope_reopen';
alter type public.ledger_event add value if not exists 'write_off';
alter type public.ledger_event add value if not exists 'report';
