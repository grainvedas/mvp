# Run-sheet for Antigravity — Phase 1 (backend B1–B7, corrections, web app)

Prerequisite: `docs/RUNSHEET_2026-10-01_security_and_phase0.md` done (migration 14 pushed, logins created).
Stop at the first step that does not match "Expect" and paste the raw output back to Claude.

| # | Command | Expect |
|---|---|---|
| 1 | `tests/run_local.ps1` | `ALL TESTS PASSED` (files 01–11) |
| 2 | `supabase db push --linked --dry-run` | Would push exactly: `20261001000200_validation_preview_chain_limits`, `…0300_phase1_api`, `…0400_corrections`, `…0500_scope_read_by_client` |
| 3 | `supabase db push --linked --yes` | `Finished supabase db push.` |
| 4 | `supabase db query --linked -f supabase/seeds/01_stage_definitions.sql` | No errors (adds the Farmer field to the Procurement form) |
| 5 | `supabase functions deploy create-user` | `Deployed Function create-user` |
| 6 | `supabase db query --linked -f tests/remote_smoke.sql` | 14/14 OK |
| 7 | `node tests/remote_rls.mjs` | `REMOTE RLS PASSED` |
| 8 | `supabase db query --linked -f tests/remote_ledger_audit.sql` | `NO ORPHAN BLOCKS` |
| 9 | Storage check: Dashboard → Storage | A private bucket `evidence` exists (created by migration 16) |
| 10 | `cd web && npm ci && npm run dev` | App on http://127.0.0.1:5173, using `NEXT_PUBLIC_SUPABASE_URL` and the publishable key from `.env.local` (the service key is never read by the web app) |
| 11 | Veda: sign in as `+910000000005` (password in `.env.demo-logins`), record a procurement lot for Sita Devi with a photo; sign in as `…06`, verify it and record QC; sign in as `…07`, verify and seal; open the public page from the QR | Sealed `GV-…`; public page shows Sita Devi, Itwa; the record shows the photo under Evidence |
| 12 | Replace `.github/workflows/database-tests.yml` with `docs/ci/database-tests.yml`, commit, push | Both CI jobs green (the `stack` job now also runs the web tests and Playwright) |

Do **not** run `tests/remote_create_user.mjs` against the live project: it creates users (it refuses unless forced).

## What Phase 1 added

- Migrations 15–18: one validation path for save and preview (`preview_reconcile`), `check_chain`, crop limits frozen
  per scope, `stage_form`, `my_context`, `footprint_detail`, farmer workflow + Excel import, evidence bucket and
  `register_attachment`, correction guard + `preview_correction`, scope read-back fix.
- Edge Function `create-user` (managers create logins; the database decides who may create whom).
- `web/`: React + TypeScript + Vite app. One generic 8-step engine for every stage; 20 screens (S1–S20).
- Tests: SQL 09–11; `tests/remote_create_user.mjs`; web component tests (`npx vitest run`) and Playwright
  end-to-end (`web/e2e`) against the local stack.
