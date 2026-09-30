# Run-sheet for Antigravity — 1 Oct 2026: security fix + Phase 0 close

Do these in order. Stop at the first step that does not match "Expect", and paste the output back to Claude.
Paste raw output for every step; do not summarise.

## Why this is urgent

Since the `app` schema was exposed to the REST API (27 Sep), every function in it has been callable by anyone holding
the **public** key, because Postgres grants EXECUTE to everyone by default. That includes `app.ledger_append`:
an anonymous visitor can write a forged block into the ledger, and it hashes correctly, so `verify_ledger()` cannot
tell it apart. Proven on the local stack. **Migration 14 (`20261001000100_api_surface.sql`) closes it.**

## Steps

| # | Command | Expect |
|---|---|---|
| 1 | `tests/run_local.ps1` | `ALL TESTS PASSED`; test `08_api_surface.sql` listed |
| 2 | `supabase db push --linked --dry-run` | Would push **only** `20261001000100_api_surface.sql` |
| 3 | `supabase db push --linked --yes` | `Finished supabase db push.` |
| 4 | `supabase db query --linked -f tests/remote_ledger_audit.sql` | One row: `NO ORPHAN BLOCKS (n blocks checked)`. **Any `ORPHAN BLOCK` row: stop, report it.** |
| 5 | `supabase db query --linked -f supabase/seeds/03_demo_emails.sql` then `… -f supabase/seeds/04_lot_inward_demo.sql` | No errors |
| 6 | `supabase db query --linked -f tests/remote_smoke.sql` | All OK except `auth.uid mapping` (13 users still on placeholder) — `api surface closed` must be OK |
| 7 | `node scripts/create_demo_logins.mjs` | 13 rows, all `login yes / linked yes`; `ALL DEMO LOGINS CREATED AND LINKED`. Passwords land in `.env.demo-logins` (git-ignored — check `git status` does not list it) |
| 8 | `node tests/remote_rls.mjs` | `… passed, 0 failed` / `REMOTE RLS PASSED` |
| 9 | `node tests/remote_rls.mjs --t1` | `REMOTE RLS PASSED`, including `T1 sealed by 307: GV-…`. This leaves one sealed demo lot in the dev project on purpose (Sita Devi, 147 kg) |
| 10 | `supabase db query --linked -f tests/remote_smoke.sql` | **14/14 OK** |
| 11 | `supabase db query --linked -f tests/remote_ledger_audit.sql` | `NO ORPHAN BLOCKS` (now including the T1 blocks) |
| 12 | Replace `.github/workflows/database-tests.yml` with `docs/ci/database-tests.yml` (adds the `stack` job; remote tools cannot write into `.github/`). Then `git add -A && git commit` and `git push` | GitHub Actions: both jobs `run_local.sh` and `local stack + real logins` green |
| 13 | CI proof: on a branch, change one expected number in `tests/02_integrity_rules.sql`, push, open a PR | Red run on the PR. Screenshot it, then delete the branch |
| 14 | Veda: GitHub → Settings → Branches → protect `main`: require the two checks | — |

`scripts/create_demo_logins.mjs` and `tests/remote_rls.mjs` read `.env.local`. They accept `SUPABASE_URL` or
`NEXT_PUBLIC_SUPABASE_URL`, the publishable key under either common name, and `SUPABASE_SERVICE_ROLE_KEY`
(or `SUPABASE_SECRET_KEY`). If a name differs, add the expected one to `.env.local`; do not pass keys on the command line.

## Demo logins (development project only)

| User | Sign-in |
|---|---|
| Admin (Veda) | grainvedas+admin@gmail.com |
| UP State Manager | grainvedas+statemanager@gmail.com |
| Prasaadam Client Manager | grainvedas+clientmanager@gmail.com |
| Prasaadam Client View | grainvedas+clientview@gmail.com |
| Operators 305–313 | phone `+9100000000NN` (NN = 05 … 13) + password |

Passwords: `.env.demo-logins` on the machine that ran step 7. Gmail delivers `grainvedas+anything@gmail.com` to the
`grainvedas@gmail.com` inbox, so any reset mail reaches Veda. Logins are created confirmed; no mail or SMS is sent.

## New in the repo

- `local-stack/` — Postgres + real Supabase Auth + PostgREST + Edge Function runner behind one URL (Linux/macOS/CI).
  `local-stack/up.sh` then `ENV_FILE=.env.stack node …` runs every remote test locally. CI runs it on every push.
- `tests/08_api_surface.sql` — fails if any `app` function becomes callable beyond the named allowlist.
- `tests/remote_rls.mjs` — real-login permission test (read, refused writes, closed API, optional T1).
- `tests/remote_ledger_audit.sql` — every ledger block must have a real counterpart.
