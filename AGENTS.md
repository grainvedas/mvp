# Rules for coding agents (Antigravity IDE, Claude, Cursor, …) working in this repo

You are working on the GrainVeda MVP, built from the PRD: https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb
Phases 0 to 4 are built and tested on a local stand-in. Do not weaken a database rule to make a screen easier.
Where things stand: `README.md`. What is known to be missing: `docs/FIX_LIST.md`.
**The interface has the prototype's look and frame** (decision G8 = B, Veda, 4 October 2026; it replaced A of the same
morning). What the forms ask for is still this system's: do not add the prototype's fields or screens without a new
decision. `docs/INTERFACE_GAP.md` is the list to choose from; faults are fixed whenever they are found.

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
- **How a record's values are shown is one file, `web/src/engine/values.tsx`** (`ComputedRows`, `EnteredRows`,
  `showComputed`, `showEntered`), for the review step, the arrival check, the record page and the journey. Never push a
  value of unknown type through `num()` or print it with `JSON.stringify`: a batch code came out as "NaN" and a list
  as code text (FIX_LIST 22, 26). A new worked-out key needs `computed.<key>` in both dictionaries and a place in
  `ORDER`; a stage's name is `t('stage.<type>')` on every screen.
- **A record has two times.** `captured_at`: when the work was done (the phone's clock, accepted by the server within
  31 days back and 5 minutes ahead; migration 29). `created_at`: when the server stored it. "When was this recorded" is
  `capturedAt(f).at` in the app and `coalesce(captured_at, created_at)` in SQL; `created_at` alone only answers "how
  long has it been at the server". The phone sends `captured_at` only for a save that waited in the outbox
  (`insertWithCaptureTime`). Never name it in a `select` list: the app must keep working on a database that does not
  have the column yet (it retries without it on `PGRST204`).
- **The lab verdict before saving comes from the database** (`app.preview_verdict`, the save's own rule). Do not work it
  out in the browser; `tests/21_verdict_preview.sql` holds the preview and the save to the same answer.
- **On a phone the header is three single lines** (practice strip, top bar with the person's name, menu that scrolls
  sideways) and no page is wider than the screen; `e2e/phase5.spec.ts` bounds both. In `styles.css` a width override
  goes after the rule it overrides: put before it, the practice strip showed no words at all on phones.
- **Two sizes, one set of screens** (decision B). A laptop (900 px and wider) gets the top bar and the dark side menu;
  below that the phone frame. Every colour is a token at the top of `styles.css` (the prototype's values; text pairs
  hold 4.5:1): never a colour written into a component. The frame is `shell/Layout.tsx`; the scope in force is
  `useScope()` from `shell/scope.tsx` ("Overall" when a person has several scopes and has chosen none), never a second
  piece of state. First screens are `pages/Home.tsx`; their figures come from `app.pipeline_summary` through
  `scopeFigures()`: do not count records in the browser.
- **A form's sections are data.** Each field in `supabase/seeds/01_stage_definitions.sql` carries `"section"`: display
  only, the database does not read it. A new section name needs `section.<name>` in both dictionaries and a pictogram
  in `engine/icons.ts` (`SECTION_ICON`); a new stage type needs one in `STAGE_ICON`; fields of one section stand
  together. A field type that needs the whole row of a two-column form goes into `FULL_WIDTH` (`engine/widgets.tsx`).
  `tests/look_b.test.tsx` fails on any of these; `e2e/phase6.spec.ts` holds the frame, the first screens and the
  two-column form at 1366 px and their folding to one column at 390 px.
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
  For a screen: run the new test against the app as it was (the previous commit served on another port).
- **A check of a text is not a check that it is shown.** `toContainText` and `toHaveText` read hidden text too: use
  `{ useInnerText: true }`, or `toBeVisible()` on the element that carries the words. After a change to the layout,
  look at pictures of the changed screens at 390 px and at 1366 px before calling it done.
- The tests of 4 October name faults "item 6" to "item 16": the open-item numbers of that day. `docs/FIX_LIST.md`
  lines 22 to 31 say which is which.
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
Vite PWA with a service worker · one design system (the prototype's greens; tokens in `web/src/styles.css`) · static hosting (Cloudflare by default).
