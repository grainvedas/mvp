# Fresh start of the practice system, and the first day after it

Decisions: Veda, 6 October 2026 ("clean all the data, so that I can start fresh"; only the admin stays), and again on
27 October 2026, after Phase 3: "after completing phase 3 we can start fresh and diagnose each step"; "ok proceed".
The practice system (staging, `mvp-beta-one.vercel.app`) holds the test clients, scopes, people, lots, packs, reports
and pages of three weeks of releases. A pilot starts with none of that. Part 1 empties it; Part 2 is the first day,
walked step by step with Claude, every step diagnosed into `docs/FIX_LIST.md`.

It stays the **practice** system: the green strip stays, and the real pilot later gets its own production project
(`docs/RUNSHEET_phase5.md` part F, decisions G2 to G5). Nothing here marks the project as production.

## Part 1: empty it (about 5 minutes, one double-click)

Double-click **`staging-fresh-start.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_fresh_start.ps1`). Rebuilt on 27 October 2026 for 78
migrations and rehearsed on the local stack (`docs/VERIFICATION_LOG.md`).

| Step | What it does | It stops if |
|---|---|---|
| F0 | Checks the tools; that the nine files it uses are the rehearsed ones; that the folder is linked to the practice project `zogkrhgzatplarimbmxk`, the project answers `staging` and no migration is waiting. Shows what is in the system and **asks you to type `EMPTY STAGING`** | any check fails, or anything else is typed. Nothing is removed |
| F1 | Copies every row of every table to `backups\fresh-start-<time>\` as JSON (git-ignored) | a table cannot be read. Nothing is removed |
| F2 | Empties the database in one transaction (`scripts/fresh_start/empty_staging.sql`), then reads the counts back | the transaction fails (nothing is removed), something is left, a list the rules read is not as the migrations wrote it, or a guard was left off |
| F3 | Removes every login and empties the five file stores (`evidence`, `hr-docs`, `reference`, `reports`, `client-docs`) | a login or a file is left. Run it again |
| F4 | Makes the first admin, `grainvedas+admin@gmail.com`; the temporary password goes to `.env.admin-login` (git-ignored, not shown) | the admin is not made. Run it again |
| F5 | Reads back: exactly one person, one login, one admin; smoke check **70** rows (`statement logging` stands; "fresh start, no demo data"); ledger audit; logins; server functions | any of them is not as expected |
| F6 | Commits and pushes the new files (the app itself has not changed) | git shows a `.env` file |
| F7 | Restarts the daily outside copy of the ledger: `staging.csv` on the branch `ledger-anchors` is kept as `staging-before-<date>.csv`, so the next daily run starts a new copy (`docs/PRODUCTION_SAFEGUARDS.md`) | the branch cannot be fetched or pushed (the fresh start itself is complete; rename it by hand) |

Last line: `RESULT: FRESH START DONE` or `RESULT: STOPPED`. The record is
`release-evidence\staging-fresh-start-<time>.log`. A second run on an already empty system removes nothing and asks
nothing: it repeats the checks.

**What goes:** every person, state, crop, client, scope, farmer, record, verdict, seal, flag, ledger block, audit
line, change-log line and counter; every client account, order, season report, evidence pack, buyer link and showcase;
every login; every stored file.
**What stays:** the rules (all 78 migrations), the 17 stage definitions, the joining checklists the migrations wrote
(the standard one and one per role), the 9 departments and the quality parameter library (lists the rules read), the
server functions, the app, the daily rounds (pg_cron), the mark "practice system". A department a person added goes.
**Reference numbers run on:** the next season report and evidence pack get the next numbers (GV-SR-…, GV-EP-…), never
one already printed. Lot, batch and pack codes start again per client code; a practice label printed before the fresh
start can match a new practice pack with the same client code.
**It cannot be undone.** The JSON copy is for looking things up; it cannot be loaded back. What it holds was practice
data.

**What no longer works on staging afterwards:** every sign-in except the admin's (tcup, Lucky, Ram, the practice
owner and viewers: their logins are gone); the buyer links already sent; the showcase page `/verified/TCUP` and its
badge ("No showcase page" until a client's owner approves one again); verify pages of the old reports and packs. The
release scripts still run (they check the rules, not the data).

Never run it against production: it refuses a project that says "production", and it refuses every project but the
one named in it.

## Part 2: the first day, step by step (with Claude)

Each person signs in themselves in the browser pane; Claude drives the screens at phone width (527 px) and, after each
step, writes down what was slow, unclear, wrong in Hindi or blocked (FIX_LIST, a class Veda sets). Each new person gets
a temporary password shown **once** on the screen where they are made (no mail is sent): note it and hand it over.
This is the order `web/e2e-fresh/fresh_start.spec.ts` walks on the local stack (rehearsed 27 Oct from the same
emptied state to a sealed lot and its public page).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Admin | Sign in with the temporary password, set your own | Platform overview of an empty system, "Setting up: 0 of 3 done", no error |
| 2 | Admin | **States** → `Uttar Pradesh`, `UP` | 1 of 3 |
| 3 | Admin | **HR · Joiners → Add joiner** (System role HR, a phone) → **Seats** → appoint the HR Admin → her joiner page → **Mark as joined** | "… has joined as HR Admin"; 2 of 3; HR · Joiners leaves the admin's menu |
| 4 | HR Admin | Own password. **Add joiner** for the State Manager, the Client Manager and one person per stage (base state Uttar Pradesh); **Mark as joined** each | Active, Unassigned |
| 5 | HR Admin | **People & access** → the State Manager → **Assign** → State `Uttar Pradesh` | 3 of 3 on the admin's checklist |
| 6 | State Manager | Own password. **Crops**: Kalanamak rice (`KNM`, GI 280), unit, yield per acre, limits (moisture, broken grains, foreign matter), the recommended chain, the GI districts | "Ready" |
| 7 | State Manager | **Places** (district, block, village) and **Labs** (the state's lab) | Listed |
| 8 | State Manager | **Clients → Onboard**: PAN first (fake, format-valid), then the three gates with their documents → request Active | "Waiting for the admin's approval" |
| 9 | Admin | **Approve** the client's first Active | Active in Uttar Pradesh |
| 10 | State Manager | People & access → the Client Manager → **Assign** → the client's account | Listed |
| 11 | Client Manager | Own password. The client's lists (collection points, mill, packing unit, buyers, pack types); **Scopes → New** (chain, markets, people at each stage) → **Activate** | "Active" |
| 12 | Client Manager, then State Manager | **Farmers → New farmer** (village from the list, GPS, GI land) → verify; the State Manager verifies its location | The first Farmer ID |
| 13 | Stage people | Each signs in: Procurement → (Collection Batch) → Milling → sample → QC with the lab report → Packing → Commercial → Shipment → QR seal | A lot code, the lab's verdict against step 6's limits, packs, a QR `GV-…` and its public page; the evidence pack issued at the seal |
| 14 | Admin | Approves the client's owner; the owner signs in, previews and publishes the showcase page | `/verified/<code>` public, the badge "Verified by GrainVeda" |
| 15 | Admin | **Overview**, **Pipeline**, **Ledger**, **Audit log** | Every step counted and listed |

What the admin is not offered (and the database refuses): a farmer, a client, a crop, a scope, a roster, a record, a
client's account, a State Manager's seat; HR acts once the HR Admin seat is filled; making an admin (break-glass
only). There is no override.

## Rehearsed

- 6 October 2026, on the local stack: the first version (33 migrations).
- 27 October 2026, on the local stack, the rebuilt script whole, with stand-ins only for the Supabase command line
  (psql on the stack, shown as the CLI shows it) and git's `main`; the node scripts ran for real and the anchor branch
  was a local copy:
  - Typing the words in lower case stopped at F0 with nothing removed.
  - The real run went from 19 people, 19 logins, 2 clients, 7 scopes, a sealed lot, 98 ledger blocks, two evidence
    packs and a file in each of the five stores to one admin, then `RESULT: FRESH START DONE`.
  - A second run removed nothing.
  - The daily anchor job then started a new copy (`ANCHOR OK`).
  - The first-day test passed from that state, to a sealed lot and its public page.

- 27 October 2026, 17:08 IST, on staging: stopped at F2 after the emptying, on an exact count of the parameter library (12 on
  staging, 11 in the rehearsal: migration 51 also copied the tests crops already used). The check now asks for at least
  11; rehearsed from the same state (logins and files left, no admin): `RESULT: FRESH START DONE`.

Not rehearsed anywhere: the run on the hosted project itself (Supabase's own login and file services instead of the
stand-ins). The script's checks in F5 are what tells.
