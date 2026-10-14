# Production safeguards: migration 45 and the app, onto the practice system

Veda, 14 October 2026 (after Release 4): *"when in production and in real time can such thing happen and not
recorded? … ok go ahead"*. Open item 40 in `docs/FIX_LIST.md`; what it is and the go-live checklist:
`docs/PRODUCTION_SAFEGUARDS.md`. What changes:

- **The change log**: every change to farmers, people, HR records, assignments, rosters, openings, scopes, clients,
  crops, states, lots and the system settings is recorded: who, when, how (in the app, a server function, a correction,
  declared, direct), which columns, fingerprints. No values. It cannot be edited or emptied without breaking its chain.
- **One door for corrections**: the admin asks on the new **Safeguards** page with a reason; a second person (the HR
  Admin) approves or refuses; a database owner runs it. The ledger records it in the admin's name.
- **The daily outside copy**: a GitHub job copies the ledger's fingerprint outside the database every day and checks
  the earlier copies. This script installs it (`.github/workflows/ledger-anchor.yml`); it runs once two GitHub
  variables are set (step 5 below).
- **Safeguards page**: the admin's menu → Audit → Safeguards; the HR Admin's menu → System → Safeguards.
- **The correcting block** (S1b): block "Activation reversed" of 14 Oct named Lucky as signer. A new block in Veda's
  name says it was the release correction and that Lucky did not act. Nothing is edited.

**Only when Veda has said so.** This pushes migration 45 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-safeguards.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 45, the smoke check, the ledger audit, the anchor script and its schedule, and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 45 waiting; the functions current. **Asks you to type `SAFEGUARDS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 45 | the push fails (nothing of it is applied) |
| S1b | The correcting block for block "Activation reversed" ("explained already" when run again) | the function does not answer |
| S2 | Smoke check **42** rows (new: `production safeguards`, and `statement logging`, a go-live step that does not stop the run), the safeguards in place and the change log intact, the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Installs the daily ledger copy, commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: SAFEGUARDS ON STAGING` or `RESULT: STOPPED`. Record: `release-evidence\staging-safeguards-<time>.log`.

**Then check Vercel built it**: Deployments must show the new commit as **Ready** within about 5 minutes. If not: the
`…` menu → **Create Deployment** → `main`. `staging-rules-and-ids.cmd` has done its job; it now refuses to run.

## Afterwards (about 15 minutes)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Veda (admin) | Menu → **Safeguards** | "Change log intact"; how the day's changes came; the correction of S1b under Corrections, **Done** |
| 2 | Veda | **Ledger** | After block 29 ("Activation reversed", Lucky), a "correction opened" block in **Veda's** name saying Lucky did not act, and "correction closed" |
| 3 | Veda | Safeguards → ask a test correction: "Test of the door, nothing to change" | "Waiting for approval"; no Approve button for her |
| 4 | Minal (HR Admin) | Menu → **Safeguards** → that request → **Refuse**, reason "test" | "Refused by Minal" with the reason; the Audit log has both lines, flagged |
| 5 | Veda | GitHub → the repository → Settings → Secrets and variables → Actions → **Variables**: `GV_STAGING_URL` = the practice project's URL, `GV_STAGING_ANON_KEY` = its public (anon) key | two variables listed |
| 6 | Veda | GitHub → Actions → **ledger anchor** → Run workflow | green; the branch `ledger-anchors` has `staging.csv` with today's line; Vercel builds nothing for that branch |
| 7 | Lucky | his menu | no Safeguards |

Step 5 uses the **public** key (the one the app itself uses), never the service key. Claude can drive Chrome for 1–4
and 7 once each person has signed in; 5 and 6 are in your GitHub account.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 45 adds two tables (`change_log`, `corrections`), triggers that write the
log after each change, functions, and guards. To stop logging a table, an owner drops its `zz_change_log` trigger (a
schema change pgaudit records once step 4 of the checklist is done). Ask before changing anything back.

## Rehearsed

On the local stack, 14 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests with the upgrade path and four
sessions at once (test 39: 63 checks, 17 controls), the API tests, the unit tests, the screen suite with `phase17` at
527 px, the first day from nothing, the production build; the anchor script against the local stack (matching, a
changed copy found, not set up skipped); the GitHub job's branch handling on a local repository (three days). The
script on stand-ins (PowerShell 7 on Linux). Not rehearsed: GitHub Actions itself, Windows PowerShell 5.1, the hosted
project, pgaudit (not on this machine).
