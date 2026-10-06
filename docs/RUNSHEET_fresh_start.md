# Fresh start of the practice system, and the first day after it

Decision: Veda, 6 October 2026: "clean all the data, so that I can start fresh", with only the admin left in it.
The practice system (staging, `mvp-beta-one.vercel.app`) had filled up with the demo client, six demo scopes, 31
people from the demo seeds and from testing. A pilot starts with none of that. This run-sheet empties the practice
system and then walks through the first day the way the pilot will be set up: everything made in the app.

It stays the **practice** system: the green strip stays, and the real pilot later gets its own production project
(`docs/RUNSHEET_phase5.md` part F, decisions G2 to G5). Nothing here marks the project as production.

## Part 1 — empty it (about 3 minutes, one double-click)

Double-click **`staging-fresh-start.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_fresh_start.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| F0 | Checks the tools, that the seven files it uses are the rehearsed ones, that the folder is linked to the practice project `zogkrhgzatplarimbmxk`, that the project answers `staging`, that no migration is waiting. Shows what is in the system and **asks you to type `EMPTY STAGING`** | any check fails, or anything else is typed. Nothing is removed |
| F1 | Copies every row of every table to `backups\fresh-start-<time>\` as JSON (git-ignored) | a table cannot be read. Nothing is removed |
| F2 | Empties the database in one transaction (`scripts/fresh_start/empty_staging.sql`), then reads the counts back | the transaction fails (nothing is removed), or something is left |
| F3 | Removes every login and empties the two file stores (`evidence`, `hr-docs`) | a login or a file is left. Run it again |
| F4 | Makes the first admin, `grainvedas+admin@gmail.com`; the temporary password goes to `.env.admin-login` (git-ignored, not shown) | the admin is not made. Run it again |
| F5 | Reads back: exactly one person, one login, one admin; smoke check 30 rows; ledger audit; logins; server functions | any of them is not as expected |
| F6 | Commits and pushes the new files (the app itself has not changed) | git shows a `.env` file |

Last line: `RESULT: FRESH START DONE` or `RESULT: STOPPED`. The record is
`release-evidence\staging-fresh-start-<time>.log`. A second run on an already empty system removes nothing and asks
nothing: it repeats the checks.

**What goes:** every person, state, crop, client, scope, farmer, record, verdict, seal, flag, ledger block, audit
line and counter; every login; every stored file.
**What stays:** the rules (all 33 migrations), the 16 stage definitions, the standard joining checklist (8 tasks),
the four server functions, the app, the nightly ledger check, the mark "practice system".
**It cannot be undone.** The JSON copy is for looking things up; it cannot be loaded back, and this project has no
other backup (no `pg_dump` on the computer, no paid plan). What it holds was demo and test data.

**What no longer works on staging afterwards, until demo data is loaded again** (seeds 02 to 06 and
`scripts/create_demo_logins.mjs` would bring it back; do that only on purpose):
- the demo sign-ins of `.env.demo-logins` (that file is of no use any more);
- `node tests/remote_rls.mjs --t1` (Phase 4 step A9, Phase 5 step D12) and the acceptance suite T1 to T5 against
  staging: both sign in as the demo people. They still run on the local stack and in CI;
- part E of `docs/RUNSHEET_phase5.md` as written (it names demo people). Part 2 below replaces its set-up; its
  steps 3 to 15 can then be done with the people you make.

Never run it against production: it refuses a project that says "production", and it refuses every project but the
one named in it.

## Part 2 — the first day, in the app (about 45 minutes)

This is the path `web/e2e-fresh/fresh_start.spec.ts` walks on the local stack, from the same empty state to a sealed
lot. Laptop. Each new person gets a temporary password shown **once** on the screen where they are made (no mail is
sent): note it and hand it over.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | You | Open the app. Sign in with `grainvedas+admin@gmail.com` and the temporary password from `.env.admin-login` | The app asks for your own password at once. Then the menu, with empty lists and no error anywhere. Delete `.env.admin-login` |
| 2 | Admin | **States** → name `Uttar Pradesh`, code `UP` → Create | Listed with `UP` |
| 3 | Admin | **Crops** → Create: name `Kalanamak rice`, code `KNM`, GI tag `GI 280`, origin. **+ limit** three times: `moisture_pct` / Moisture / `%` / at most / 13 / 12; `broken_pct` / Broken grains / 5 / 3; `foreign_matter_pct` / Foreign matter / 1 / 0.5. Tick the processing stages the crop may go through. Save | Listed with `KNM`. Open it again: 0.5 is still 0.5. These limits are what the lab's pass/fail is judged against, and the labels are what the lab form shows |
| 4 | Admin | **Clients** → name, code (2 to 6 capitals: it is in every lot code and Farmer ID, e.g. `PRSDM`), type, state → Create | Listed |
| 5 | Admin | **HR · Joiners → Add joiner**: the person who will run HR; System role **HR**. Save, note the password. On their page: **Mark as joined** | Status Active |
| 6 | Admin | **System → Seats** → Appoint: pick that person (shown as "name (HR)") → Appoint → confirm | HR Admin seat shows their name |
| 7 | HR Admin | Signs in, sets a password. **Add joiner** for each person: the client's manager, and one per stage. **Mark as joined** on each (or let them complete the checklist) | The form has no client, scope or stage field. Each is Active and Unassigned |
| 8 | Admin | **People & access** → the manager → **Assign** → tab **A client's account** → the client → Give | The assignment is listed. (A State Manager, once you seat one, can do this for clients of the state) |
| 9 | Client Manager | Signs in, sets a password. **Scopes → New**: geography, state, crop, chain → Save draft → put a person at each stage → **Activate scope** | "Draft", then all stages covered, then "Active". The chain cannot be changed after activation |
| 10 | Client Manager | **Farmers → New** → Submit for verification | — |
| 11 | Admin (or a State Manager) | **Farmers** → Ready to verify → **Verify and issue Farmer ID** | The first Farmer ID: `<client code>-F-0001` |
| 12 | Stage people | Each signs in, sets a password, and records: buy, test, seal | Lot code `<client>-KNM-<season>-P-0001`; the lab's verdict against the limits of step 3; a QR code `GV-…` and its public page |

Decisions this first day puts in front of you (`docs/FIX_LIST.md` G10 to G12): only HR adds people (steps 5, 7);
a person works only once marked as joined (steps 5, 7); the State Manager seat is given by the admin (step 8).

## Rehearsed

On the local stack, 6 October 2026 (`docs/VERIFICATION_LOG.md`): the script itself emptied a stack with the demo
data, 19 logins and stored files; a second run removed nothing; then the first-day test ran from that state to a
sealed lot and its public page. 26 scenarios with one thing wrong each stopped where they should. Not rehearsed
anywhere: the run on the hosted project itself (Supabase's own login and file services instead of the stand-ins).
The script's checks in F5 are what tells.
