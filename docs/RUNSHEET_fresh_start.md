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
**What stays:** the rules (all the migrations: 33 on 6 October), the 16 stage definitions, the standard joining checklist (8 tasks),
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

## Part 2 — the first day, in the app (about 50 minutes)

**In Veda's order (10 October 2026, decisions G15 and G16), once migrations 35 and 36 are on staging** (`docs/RUNSHEET_admin_two_jobs.md`,
`docs/RUNSHEET_hr_admin_joined.md`).
With migration 34 only, step 5 is the admin's (People & access → the State Manager → Assign → State); before
migration 34, the admin still does everything and the order of 6 October applies (in git history). This is the path
`web/e2e-fresh/fresh_start.spec.ts` walks on the local stack, from the same empty state to a sealed lot. Laptop. Each
new person gets a temporary password shown **once** on the screen where they are made (no mail is sent): note it and
hand it over.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | You (admin) | Open the app. Sign in with `grainvedas+admin@gmail.com` and your password | **Platform overview**: the role guide ("You have two jobs…"), "Setting up: 0 of 3 done", empty cards and charts, no error anywhere |
| 2 | Admin | **States** → name `Uttar Pradesh`, code `UP` → Create | Listed with `UP`. The checklist says 1 of 3 |
| 3 | Admin | **HR · Joiners → Add joiner**: the person who will run HR; System role **HR**. Save, note the password. Then **Access → Seats** → Appoint: that person (shown as "name (HR)") → Appoint → confirm. Seats now says she has not joined yet: **Open the joiner page** → **Mark as joined** (migration 36: the admin marks only the HR Admin seat holder as joined) | Back on Seats: "… has joined as HR Admin". 2 of 3. A flagged line in the audit log. **HR · Joiners leaves your menu**: from now on HR adds people |
| 4 | HR Admin | Signs in, sets a password. **Add joiner** for everyone: the State Manager, the Client Manager, one person per stage. **Mark as joined** on each | The form has no client, scope or stage field. Each is Active and Unassigned |
| 5 | HR Admin | Still signed in: **People & access** → the State Manager → **Assign** → State `Uttar Pradesh` → Give | One choice only, **A state**. The admin's checklist then says 3 of 3 ("The HR Admin seats a State Manager") |
| 6 | State Manager | Signs in, sets a password. **Crops** → Create: name `Kalanamak rice`, code `KNM`, GI tag `GI 280`, origin. **+ limit** three times: `moisture_pct` / Moisture / `%` / at most / 13 / 12; `broken_pct` / Broken grains / 5 / 3; `foreign_matter_pct` / Foreign matter / 1 / 0.5. Tick the processing stages. Save | Listed with `KNM`. Open it again: 0.5 is still 0.5 |
| 7 | State Manager | **Clients** → Onboard a client: name, code (2 to 6 capitals, e.g. `PRSDM`), type, state `Uttar Pradesh` → Create. Then **People & access** → the Client Manager → **Assign** → tab **A client's account** → the client → Give | The client is listed; the assignment is listed |
| 8 | Client Manager | Signs in, sets a password. **Scopes → New**: geography, state, crop, chain → Save draft → a person at each stage → **Activate scope** | "Draft", then all stages covered, then "Active" |
| 9 | Client Manager | **Farmers → New farmer** (state: Uttar Pradesh) → **Save and verify** | The farmer is under "Ready to verify", "Waiting for the State Manager of Uttar Pradesh" |
| 10 | State Manager | **Farmers** → Ready to verify: the row shows the village, district, state and who verified it first → **Location verified — issue Farmer ID** | The first Farmer ID: `<client code>-F-0001` |
| 11 | Stage people | Each signs in, sets a password, and records: buy, test, seal | Lot code `<client>-KNM-<season>-P-0001`; the lab's verdict against the limits of step 6; a QR code `GV-…` and its public page |
| 12 | Admin | **Overview**: the last 12 weeks, the client (read-only, Exit), a scope; **Pipeline**; **Ledger** | "Procured, last 4 weeks" and "QR issued" count the lot; the client card counts it too; the pipeline runs Procurement → … → QR seal; the ledger lists every block, newest first |

What the admin is no longer offered (and the database refuses): a farmer, a client, a crop, a scope, a roster, a
record, a client's account, a State Manager's seat; HR acts and HR files once the HR Admin seat is filled; making an
admin (break-glass only). There is no override.

## Rehearsed

On the local stack, 6 October 2026 (`docs/VERIFICATION_LOG.md`): the script itself emptied a stack with the demo
data, 19 logins and stored files; a second run removed nothing; then the first-day test ran from that state to a
sealed lot and its public page. 26 scenarios with one thing wrong each stopped where they should. Not rehearsed
anywhere: the run on the hosted project itself (Supabase's own login and file services instead of the stand-ins).
The script's checks in F5 are what tells.
