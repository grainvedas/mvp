# Rules for coding agents (Antigravity IDE, Claude, Cursor, …) working in this repo

You are working on the GrainVeda MVP, built from the PRD: https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb
Phases 0 to 4 are built and tested on a local stand-in. Do not weaken a database rule to make a screen easier.
Where things stand: `README.md`. What is known to be missing: `docs/FIX_LIST.md`.

## Non-negotiables

1. **Rules live in Postgres.** Permissions, chain order, reconciliation, immutability and the ledger are enforced by
   triggers and RLS in `supabase/migrations/`. The front-end mirrors them for live review; it never becomes the only check.
2. **One stage engine.** Every stage type is rendered by ONE generic 8-step component driven by `stage_definitions.form_schema`
   and `handoff_checks`. Never write per-stage screens or a second save path (the prototype's dual code path is the bug we are removing).
3. **Sacred stamps are server-side.** Never send `client_id` (it is overwritten from the scope), never compute `qty_in`/`qty_out`
   in the client and expect them to stick. Read canonical `qty_out`, never raw payload fields, for anything quantity-related.
   A signed-in person's direct API write may set only the columns migration 22 allows; codes, dates, status, lot state,
   quantities, computed values and verdicts are the server's. Do not loosen those triggers.
4. **Thumb rule.** A stage reads only the stage directly behind it, via `app.incoming_records(scope_id, stage_type)`. Do not
   query `footprints` by hardcoded stage names. The ledger follows the same rule (migration 25): an operator reads the
   blocks of the own stage and the one behind, nothing else.
5. **Verification is by the receiving stage.** Call `app.verify_footprint(id)` as the operator of the next stage. The creator
   never verifies their own record.
6. **Seal only through `app.seal_source(source_id)`.** It records the QR stage and seals in one transaction, so a refused
   seal leaves nothing behind. `app.seal_lot(qr_footprint_id)` mints the QR code and is called by it; the screens call
   it directly only to finish a QR record left behind by an older build.
7. **No deletes.** Footprints, verdicts, seals, flags and ledger rows are never deleted. A pending Procurement, Lot Inward
   or processing record is corrected in place (the ledger keeps both versions). A lab record, a Village Batch, a split
   grading run, a grade lot or anything verified is **withdrawn** by a manager with a reason (`app.withdraw_footprint`)
   and recorded again with `supersedes_id`. Grade lots are made by the save itself (trigger); never insert one.
8. **Review = Save = Verify.** The number shown at step 6 is what the server saves and what the next operator sees at step 3.
   Use the same derivation the server uses (`app.reconcile` rules, PRD §7) — port it, do not reinvent it.
9. **Logins are made by service code only**: the `create-user` and `reset-password` Edge Functions,
   `scripts/bootstrap_admin.mjs`, `scripts/create_demo_logins.mjs`. A public sign-up never becomes a GrainVeda user
   (migration 23). The service key never reaches the browser or git.
10. **Two systems.** Production is the project marked by `supabase/seeds/production/10_reference.sql`. Any script that
    writes demo data or runs a destructive check calls `assertNotProduction` first. Demo seeds 02–05 never go there.

## The phone (web app): what must stay true

- **Who is signed in is read from the phone, not asked of the network**: `keptLogin()` in `web/src/lib/keptLogin.ts`.
  Never use `supabase.auth.getSession()` to decide whether someone is signed in or to get a token for a request: with no
  network it answers "nobody" after up to 25 seconds, one hour after the last contact.
- **Every data request gets its token from `accessToken()`** (`web/src/lib/supabase.ts`: the data client). While someone
  is signed in, a request never goes out with the public key; a token that cannot be renewed now is "no connection".
- **Every save of a record goes through `insertOnce(row, saveId)`** (`web/src/offline/outbox.ts`), with one id from the
  first tap, whether it is sent at once or kept on the phone first. Never insert into `footprints` any other way: a
  save whose answer is lost would be stored twice. A new kind of write that can be retried needs its own such id.
- A request that can leave an operator stuck is bounded: reads of forms use `cached()` (the phone's copy after 8 s on a
  dead link), the maths step `within()`, saves 30 s, photo uploads 240 s. What is kept on the phone is cleared on every
  sign-out and when the server no longer knows the person; if you keep something new there, add it to
  `docs/OPERATIONS.md` ("Phone lost or stolen").
- **Every visible string goes through `t()`** with an English key in `i18n.en.ts` and Hindi in `i18n.hi.ts`. Words that come
  from the database in English are shown by key with the English as fallback (`stage.* field.* opt.* check.* qp.*
  computed.* badge.* event.*`). A new stage, field, option, hand-off check, status or ledger event needs its Hindi;
  refresh `web/tests/fixtures/stage_definitions.json` with
  `psql -Atc "select jsonb_pretty(jsonb_agg(to_jsonb(d) order by d.sort_order)) from public.stage_definitions d"`.
  Unit tests fail on a missing key, a missing Hindi label, and on plain text in an operator screen.
- **Offline maths (`web/src/engine/offlinePreview.ts`) mirrors `app.reconcile` for Procurement and Lot Inward ONLY.** Any
  change to those two rules in SQL must change the mirror and `web/tests/phase3.test.ts` in the same commit. Do not add
  other stages: offline saves of every other stage are checked by the server at sync (decision D10).

## Working method

- Any schema or rule change = a new migration file + a test in `tests/` + `tests/run_local.sh` green. Never edit an applied migration.
- **Run `tests/run_local.sh` before every `db push`.** A migration that passes on Supabase can still break a rule the suite covers (migration 7 did).
- To change a function's settings (search_path, security) use `alter function … set …`. Never re-paste a function body from memory: retyped bodies drift (migration 7 dropped two gate checks and added a wrong one).
- **Every new `app` function is closed by hand:** end the migration with `revoke execute on function app.x(...) from public, anon, authenticated;`
  and grant it by name only if it is API. Postgres grants EXECUTE to everyone by default and `app` is exposed over REST.
  Add API functions to the allowlist in `tests/08_api_surface.sql`; that test fails the build on anything left open.
- **A fix needs a test that failed before the fix.** Reproduce first (a failing test, or a probe of the app as it is), then
  fix. If the old behaviour passes your new test, you have hardened something, not fixed a fault: say so
  (`docs/FIX_LIST.md` keeps the two apart). A check that cannot fail proves nothing: give every new check a negative control.
- Do not claim something works without running it. Paste the relevant output in your summary. Say which system it ran on:
  the local stack is a rehearsal, staging is the test, and the release gate (`scripts/release_gate.mjs`) reads result
  files and keeps the two apart.
- When a test fails, first decide whether the rule or the test is wrong. Rules trace to the PRD sections named in the SQL comments.
- Keep `docs/VERIFICATION_LOG.md` honest: what ran, what did not. Keep `docs/FIX_LIST.md` current: every known gap, every decision.
- Stage-specific field names are in `supabase/seeds/01_stage_definitions.sql` (`form_schema.key`). Payload keys must match exactly.
- Web tests, all three: `npx vitest run`; `npx playwright test` (the whole suite, files in name order, against the local
  stack); `npx playwright test -c playwright.prod.config.ts` (the built app: page budget, security policy, and
  `e2e-prod/field_day.spec.ts`, a day without network). Every stage page must pass `expectNoSideScroll` on a phone.
  Do not edit `web/src` while the dev-server suite runs: the hot reload disturbs the test in progress.
- Never run against a hosted project: `tests/00_local_auth_shim.sql`, `tests/run_local.*`, `tests/remote_create_user.mjs`,
  `tests/remote_ledger_check.mjs --tamper-local`, `scripts/collect_release_evidence.sh`.
- Secrets stay in git-ignored `.env.*` files. Never on a command line, in chat, in a log or in a test's output.

## Stack (PRD §10)

Supabase (Postgres 17 hosted, 16 or 17 locally; RLS, PL/pgSQL triggers, Auth, Storage, Edge Functions) · React + TypeScript +
Vite PWA with a service worker · one design system (paddy green + GI gold) · static hosting (Cloudflare by default).
