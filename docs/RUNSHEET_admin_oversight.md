# The admin oversees: migration 34 and the app, onto the practice system

Decision: Veda, 10 October 2026 (`docs/FIX_LIST.md` G15). Brief "GrainVeda MVP — Admin role changes", with
override removed ("it will create confusion") and her set-up order. What changes for whom:
`docs/IDENTITY_DESIGN.md` "Who may do what". Open item 28.

**Only when Veda has said so.** This pushes migration 34 to the practice database **and pushes to the main branch**,
from which Vercel builds the staging app. Production is not touched (it does not exist yet; its run-sheet is
`docs/RUNSHEET_phase5.md` part F, where migration 34 then goes with the others).

## One double-click (about 3 minutes, then a few minutes for Vercel)

Double-click **`staging-admin-oversight.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_admin_oversight.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 34, the smoke check, the ledger audit and the app's files are the tested ones; that the folder is linked to the practice project `zogkrhgzatplarimbmxk`, that it answers `staging`, and that exactly migration 34 is waiting. Says what will happen and **asks you to type `ADMIN OVERSIGHT`** | any check fails, or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 34 | the push fails (nothing of it is applied) |
| S2 | Reads the project back: smoke check **31 rows** (new row `the admin oversees`), ledger audit `NO FINDINGS`, `NO LOGIN WITHOUT A PERSON`, the server functions (unchanged: build 2026-10-06), and one line of what is in the system | a row is not `OK` (the nightly check is listed but does not stop it) |
| S3 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a backup or the run record; commit or push fails |

Last line: `RESULT: ADMIN OVERSIGHT ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-admin-oversight-<time>.log`. Run again after a stop: a database already on migration 34 is
not pushed twice. `-NoGit` stops after S2 (then the staging app is the old one against the new rules: its admin
screens offer acts the database refuses, in the database's words; push soon after).

## Afterwards, in the app (about 10 minutes)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | You (admin) | Open the app (reload once), sign in | **Platform overview**: role guide, set-up checklist, four number cards, your clients grouped by state |
| 2 | Admin | Tap **Needs attention** | The list adds up to the number on the card |
| 3 | Admin | A client card → **Open (read-only)** → a scope → **Exit** | "Viewing … — read-only"; the scope screen says "Needs attention", not "My action queue"; back to the overview |
| 4 | Admin | **Ledger** (menu, System) → Event: Sealed → **Export this list** | Your sealed lot's block; a CSV with one line per block |
| 5 | Admin | **Farmers**, **Clients**, **Crop Registry**, **Season Scopes** | Lists to read; no New, Create, Edit, Verify or Activate |
| 6 | Admin | **HR · Joiners** | In the menu only while the HR Admin seat is empty |

Your test records (the clients, scopes and the sealed lot you made alone as admin) stay as they are and still open.
Because the admin no longer works stages, you cannot add to them as admin: from here on the first day goes in your
order, `docs/RUNSHEET_fresh_start.md` part 2 (HR Admin, State Manager, Client Manager, stage people).

## If something is wrong afterwards

Nothing was deleted or rewritten, so there is nothing to restore. The rules can be put back as they were by a new
migration (the functions as they stood in migration 33 are in the repository); ask before doing that. Do not run
`supabase db reset` or the fresh start to undo it.

## Rehearsed

On the local stack, 10 October 2026 (`docs/VERIFICATION_LOG.md`): the database test files (28, with the upgrade
path: migration 34 on a database already in use), the unit tests, the screen suite, the first day from nothing in
Veda's order, and migration 34 on a practice system made the old way (admin doing everything, a sealed lot) with the
records read back afterwards. The script itself ran against a stand-in for the hosted project (every stop and the
whole run). Not rehearsed anywhere: the push to the hosted project and the Vercel build. S2 and the steps above are
what tells.
