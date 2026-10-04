# Run-sheet for Antigravity — Phase 3 (field-ready: offline, Hindi, dashboards, exports, nightly ledger check)

Prerequisite: `docs/RUNSHEET_phase2.md` done. Stop at the first step that does not match "Expect" and paste the raw
output back to Claude. Never paste keys, tokens or passwords into chat.

| # | Command | Expect |
|---|---|---|
| 1 | `tests/run_local.ps1` | `ALL TESTS PASSED` (files 01–13; 13 includes a tampered-ledger check and a 500-lot timing) |
| 2 | `supabase db push --linked --dry-run` | Would push exactly: `20261001000800_phase3_ops` |
| 3 | `supabase db push --linked --yes` | `Finished supabase db push.` A NOTICE `nightly ledger check not scheduled` means pg_cron is off: do step 5 |
| 4 | `supabase db query --linked -f tests/remote_smoke.sql` | 16 rows. All OK, or only `nightly ledger check` = `NO pg_cron` / `NOT SCHEDULED` (then step 5) |
| 5 | Only if step 4 said so: Dashboard → Database → Extensions → enable **pg_cron**; then SQL Editor: `select cron.schedule('grainveda-ledger-nightly', '30 20 * * *', $$select app.run_ledger_check('nightly')$$);` | Returns a job id; step 4 now 16/16 OK. 20:30 UTC = 02:00 IST |
| 6 | SQL Editor: `select * from app.run_ledger_check('manual');` | One row, `ok = true`, `blocks` = number of ledger blocks |
| 7 | `node scripts/make_ledger_token.mjs` | `LEDGER_CHECK_TOKEN is in .env.functions and .env.local (not shown)`. Both files are git-ignored (`.env.*`) |
| 8 | `supabase secrets set --env-file .env.functions` | `Finished supabase secrets set.` (uploads ONLY that token; never use `.env.local` here) |
| 9 | `supabase functions deploy ledger-check --no-verify-jwt` | `Deployed Function ledger-check` (the monitor authenticates with the token header, not a login) |
| 10 | `node tests/remote_ledger_check.mjs` | `LEDGER CHECK TEST PASSED` (4 checks; the tamper test is local-only and is not run here) |
| 11 | `node tests/remote_rls.mjs` then `supabase db query --linked -f tests/remote_ledger_audit.sql` | `REMOTE RLS PASSED` · `NO ORPHAN BLOCKS` |
| 12 | Replace `.github/workflows/database-tests.yml` with `docs/ci/database-tests.yml`, commit, push | Both CI jobs green. The stack job now also runs the ledger-check function (with a tampered block) and the production-build checks |
| 13 | Veda: an uptime monitor (Better Stack or UptimeRobot, free tier) on `GET https://<project-ref>.supabase.co/functions/v1/ledger-check?evidence=1` every 6 h, header `x-check-token: <token from .env.functions>`, alert to your phone/email on any non-200 | First check green |

Do **not** run `tests/remote_ledger_check.mjs --tamper-local`, `tests/remote_create_user.mjs` or `tests/run_local.*` against
the live project.

## What Veda can try on a phone (dev server, `cd web && npm run dev`, or the deployed app)

- Sign in as `…05`, open Procurement once, then switch on airplane mode: record lots, they show "Saved on phone";
  switch airplane mode off: they send by themselves, codes in the order captured.
- Language → हिन्दी on any operator screen (and on the public page).
- Client Manager / Client View: **Dashboard** → a scope → **Full dashboard and exports**: chain dots, sealed lots, flag log, season CSV;
  a sealed lot → **Journey & export** → CSV or Print / save as PDF.
- A record with a photo shows "file matches its fingerprint" (re-hashed on opening).

## What Phase 3 added

- Migration 21 `phase3_ops`: `public.ledger_checks` + `app.run_ledger_check()` (service role only) scheduled nightly with
  pg_cron; `footprints.client_ref` (unique) so an offline save that is retried never duplicates; `app.lot_trace()` for
  exports (managers and Client View only; walks every source of a Village Batch).
- Edge Function `ledger-check` for an external monitor; optional evidence re-hash of the newest 200 files.
- Web: offline outbox (IndexedDB) with automatic sync in capture order, refused saves kept with the database's reason
  and a "fix and save again" path; offline maths mirror for Procurement and Lot Inward only (D10); service worker so the
  app opens with no network; Hindi for every screen string and every stage, field, option and hand-off check; scope
  dashboard (stage dots, sealed lots, flag log, season CSV); journey page with CSV and print-to-PDF; ledger health
  banner for managers; evidence hash check on retrieval.

## Human tasks Phase 3 cannot close from code (PRD §13)

| Task | Owner | Notes |
|---|---|---|
| Penetration test | external tester | Scope: REST + RPC surface (tests/08 allowlist), Edge Functions, storage policies, RLS per role |
| Device lab | Tarun / QA | 3 low-end Android 9+ phones, Chrome: airplane-mode test of 10 lots, camera evidence, Hindi |
| Hindi review | 2 field operators | Read every operator screen in Hindi; list words they would say differently |
| Session length | done in Phase 4 | Managers are signed out 12 hours after signing in, operators after 30 days (the app counts from the sign-in); the project's own limit is "time-box user sessions: 720 hours" (`docs/RUNSHEET_phase4.md` A7) |
| Lighthouse accessibility ≥ 90 | QA | Measured on the local build in Phase 4: 100 (verify page and sign-in page). On the deployed page: `docs/RUNSHEET_phase4.md` B8 |
