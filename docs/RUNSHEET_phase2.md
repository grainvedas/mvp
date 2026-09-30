# Run-sheet for Antigravity — Phase 2 (grade split, Village Batch, T4 path, labels, phone layout)

Prerequisite: `docs/RUNSHEET_phase1.md` done. Stop at the first step that does not match "Expect" and paste the raw
output back to Claude. Never paste keys or passwords into chat.

| # | Command | Expect |
|---|---|---|
| 1 | `tests/run_local.ps1` | `ALL TESTS PASSED` (files 01–12) |
| 2 | `supabase db push --linked --dry-run` | Would push exactly: `20261001000600_grade_split`, `20261001000700_village_batch` |
| 3 | `supabase db push --linked --yes` | `Finished supabase db push.` |
| 4 | `supabase db query --linked -f supabase/seeds/01_stage_definitions.sql` | No errors (grading split becomes a form column; Village Batch source picker) |
| 5 | `supabase db query --linked -f supabase/seeds/05_phase2_demo.sql` | No errors (scopes "Basti mill" and "Bansi batch"; operators 314 Shipment, 315 Village Batch) |
| 6 | `node scripts/create_demo_logins.mjs` | Creates `+910000000014` and `+910000000015`; the others are left untouched; `ALL DEMO LOGINS CREATED AND LINKED` |
| 7 | `supabase db query --linked -f tests/remote_smoke.sql` | 14/14 OK (6 active scopes) |
| 8 | `node tests/remote_rls.mjs` | `REMOTE RLS PASSED` |
| 9 | `supabase db query --linked -f tests/remote_ledger_audit.sql` | `NO ORPHAN BLOCKS` |
| 10 | Replace `.github/workflows/database-tests.yml` with `docs/ci/database-tests.yml`, commit, push | Both CI jobs green (Playwright now runs every spec in `web/e2e`) |
| 11 | Veda, on a phone: `+910000000005` records two procurement lots at "Bansi batch" (Ram Achal, Geeta Kumari); `…15` verifies both and makes one Village Batch; `…06` verifies and records QC; `…07` seals; open the QR | Public page: "2 farmers of Bansi", both names |
| 12 | Veda, on a phone: "Basti mill" full path `…05 → …06 → …08 milling → …09 packing (batch code) → …11 two buyers → …14 shipment → …07 seal`, then **Print labels** | 12 labels on A4 with the batch code; public page shows Milled, Batch, Shipped to … |

## What Phase 2 added

- Migration 19 `grade_split`: `app.split_grades(run)` makes grade lots A/B/C from a verified grading split; verifying
  a grade lot also verifies its parent run (it could never be verified from the screens before).
- Migration 20 `village_batch`: the public page names every farmer in a batch; sealing refuses if any batch source is
  unverified or has an open flag (before, only the first source was checked).
- Web: grade-lot hand-off, Village Batch source picker, split quantities to several buyers ("Another … from this lot"),
  A4 label sheet (`/labels/<code>`), full public page. Phone layout fix: long stage or farmer names wrap instead of
  widening the page (on a Pixel 7 the page was zoomed out and taps near the bottom edge missed).
- Tests: SQL 12 (T4, T2, Village Batch with the flag gate); Playwright `web/e2e/phase2.spec.ts`; every stage page in
  that spec now fails if anything is wider than the phone screen.
