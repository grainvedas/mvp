# The admin's two jobs: migration 35 and the app, onto the practice system

Decision: Veda, 10 October 2026 (`docs/FIX_LIST.md` G16). Brief "GrainVeda MVP — Admin role, follow-up" and her
answers: no override; the admin has two jobs (states, the HR Admin seat) and watches the rest on a dashboard; the
HR Admin seats State Managers; the admin sees people as numbers, not HR files. What changes for whom:
`docs/IDENTITY_DESIGN.md` "Who may do what (since migration 35)". Open item 29.

**Only when Veda has said so.** This pushes migration 35 to the practice database **and pushes to the main branch**,
from which Vercel builds the staging app. Production is not touched (it does not exist yet; its run-sheet is
`docs/RUNSHEET_phase5.md` part F, where migration 35 then goes with the others).

## One double-click (about 3 minutes, then a few minutes for Vercel)

Double-click **`staging-admin-two-jobs.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_admin_two_jobs.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 35, the smoke check, the ledger audit and the app's files are the tested ones; that the folder is linked to the practice project `zogkrhgzatplarimbmxk`, that it answers `staging`, and that exactly migration 35 is waiting. Says what will happen and **asks you to type `ADMIN TWO JOBS`** | any check fails, or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 35 | the push fails (nothing of it is applied) |
| S2 | Reads the project back: smoke check **31 rows** (unchanged), the **two-jobs check** (`OK`: the two new functions, the HR Admin's state seat, HR files behind HR, the "report" kind), ledger audit `NO FINDINGS`, `NO LOGIN WITHOUT A PERSON`, the server functions (unchanged: build 2026-10-06), one line of what is in the system | a row or the two-jobs check is not `OK` (the nightly check is listed but does not stop it) |
| S3 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a backup or the run record; commit or push fails |

Last line: `RESULT: ADMIN TWO JOBS ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-admin-two-jobs-<time>.log`. Run again after a stop: a database already on migration 35 is
not pushed twice. `-NoGit` stops after S2 (then the staging app is the old one against the new rules: it still offers
the admin "Assign" for a state, which the database refuses in its own words; push soon after).

`staging-admin-oversight.cmd` (migration 34) has done its job; it now refuses to run (the app is no longer the one it
was sealed for). That is expected.

## Afterwards, in the app (about 10 minutes)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | You (admin) | Open the app (reload once), sign in | The menu has five headings: **Watch, Audit, Master data (read-only, States apart), Access, Me**. The overview: role guide ("You have two jobs…"), set-up checklist, four number cards, **Last 12 weeks** (four figures with their change, four weekly charts), pipeline in short, lab results, people as numbers, farmers by state, clients by state, volume |
| 2 | Admin | Under a chart: **Show the numbers** | The same figures as a table |
| 3 | Admin | **Pipeline** (Watch) | Every stage in chain order (Procurement first, QR seal last); no "Records" column. Choose one scope: its own chain |
| 4 | Admin | **People & access** → any person | No **Assign** button, no HR record. On the HR Admin's page only **Reset password** |
| 5 | Admin | Type `/hr` in the address bar | Back on the overview (HR's pages are HR's once the seat is filled) |
| 6 | Admin | **Help** → write a line → **Send**; then **Health** | The line is listed under problems reported |
| 7 | Admin | **My account** | "only another admin can give you a new one; with no other admin, the database owner's break-glass procedure" |
| 8 | HR Admin | **People & access** → the future State Manager → **Assign** | One choice only, **A state**; save; the person is a State Manager. The admin's checklist ticks "The HR Admin seats a State Manager" |
| 9 | Anyone | The public page of a sealed lot (scan or `/verify/<code>`) | "checked by the next person" only when every step was; a lot one person handled alone says the plainer sentence |

The first day in Veda's order (`docs/RUNSHEET_fresh_start.md` part 2) now has step 4 done by the HR Admin.

## If something is wrong afterwards

Nothing was deleted or rewritten, so there is nothing to restore. The rules can be put back as they were by a new
migration (the functions as they stood in migration 34 are in the repository); ask before doing that. Do not run
`supabase db reset` or the fresh start to undo it.

## Rehearsed

On the local stack, 10 October 2026 (`docs/VERIFICATION_LOG.md`): the database test files (29, with the upgrade
path), the unit tests, the screen suite, the first day from nothing in Veda's order with the HR Admin seating the State
Manager. The two-jobs check was run on a database with and without migration 35 (`OK`, `MISSING`). Not rehearsed
anywhere: the push to the hosted project and the Vercel build. S2 and the steps above are what tells.
