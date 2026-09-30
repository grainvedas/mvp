# Rules for coding agents (Antigravity IDE, Claude, Cursor, …) working in this repo

You are building the GrainVeda MVP from the PRD: https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb
Phase 0 (this database foundation) is done and tested. Do not weaken it to make a front-end task easier.

## Non-negotiables

1. **Rules live in Postgres.** Permissions, chain order, reconciliation, immutability and the ledger are enforced by
   triggers and RLS in `supabase/migrations/`. The front-end mirrors them for live review; it never becomes the only check.
2. **One stage engine.** Every stage type is rendered by ONE generic 8-step component driven by `stage_definitions.form_schema`
   and `handoff_checks`. Never write per-stage screens or a second save path (the prototype's dual code path is the bug we are removing).
3. **Sacred stamps are server-side.** Never send `client_id` (it is overwritten from the scope), never compute `qty_in`/`qty_out`
   in the client and expect them to stick. Read canonical `qty_out`, never raw payload fields, for anything quantity-related.
4. **Thumb rule.** A stage reads only the stage directly behind it, via `app.incoming_records(scope_id, stage_type)`. Do not
   query `footprints` by hardcoded stage names.
5. **Verification is by the receiving stage.** Call `app.verify_footprint(id)` as the operator of the next stage. The creator
   never verifies their own record.
6. **Seal only through `app.seal_lot(qr_footprint_id)`.** It is the only code path that mints a QR code.
7. **No deletes.** Footprints, verdicts, seals and ledger rows are never deleted. Corrections are superseding records.
8. **Review = Save = Verify.** The number shown at step 6 is what the server saves and what the next operator sees at step 3.
   Use the same derivation the server uses (`app.reconcile` rules, PRD §7) — port it, do not reinvent it.

## Working method

- Any schema or rule change = a new migration file + a test in `tests/` + `tests/run_local.sh` green. Never edit an applied migration.
- **Run `tests/run_local.sh` before every `db push`.** A migration that passes on Supabase can still break a rule the suite covers (migration 7 did).
- To change a function's settings (search_path, security) use `alter function … set …`. Never re-paste a function body from memory: retyped bodies drift (migration 7 dropped two gate checks and added a wrong one).
- **Every new `app` function is closed by hand:** end the migration with `revoke execute on function app.x(...) from public, anon, authenticated;`
  and grant it by name only if it is API. Postgres grants EXECUTE to everyone by default and `app` is exposed over REST.
  Add API functions to the allowlist in `tests/08_api_surface.sql`; that test fails the build on anything left open.
- Do not claim something works without running it. Paste the relevant `run_local.sh` output in your summary.
- When a test fails, first decide whether the rule or the test is wrong. Rules trace to the PRD sections named in the SQL comments.
- Keep `docs/VERIFICATION_LOG.md` honest: what ran, what did not.
- Stage-specific field names are in `supabase/seeds/01_stage_definitions.sql` (`form_schema.key`). Payload keys must match exactly.
- **Offline maths (`web/src/engine/offlinePreview.ts`) mirrors `app.reconcile` for Procurement and Lot Inward ONLY.** Any change
  to those two rules in SQL must change the mirror and `web/tests/phase3.test.ts` in the same commit. Do not add other stages:
  offline saves of every other stage are checked by the server at sync (decision D10).
- **Every visible string goes through `t()`** with an English key in `i18n.en.ts` and Hindi in `i18n.hi.ts`. A new stage,
  field, option or hand-off check in `stage_definitions` needs its Hindi (`stage.* field.* opt.* check.*`); refresh
  `web/tests/fixtures/stage_definitions.json` — the unit test fails on any gap.
- Web e2e: run the whole suite (`npx playwright test`, files in name order) plus `npx playwright test -c playwright.prod.config.ts`
  for the service worker and the public-page budget. Every stage page must pass `expectNoSideScroll` on a phone.

## Stack (PRD §10)

Supabase (Postgres 16, RLS, PL/pgSQL triggers, Auth, Storage, Edge Functions) · React + TypeScript + Vite PWA · one design system
(paddy green + GI gold). Front-end work starts in Phase 1 after the auth flows exist.
