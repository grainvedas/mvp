# The admin marks the HR Admin as joined: migration 36 and the app, onto the practice system

Brief "GrainVeda MVP — fix: the HR Admin cannot be activated" (Veda, 10 October 2026). Open item 30, fault 38 in
`docs/FIX_LIST.md`. The rule: the admin may mark as joined the person who holds the HR Admin seat, and only that
person; it is a flagged line in the audit log. For anyone else "Only HR marks a joiner as joined" stays.

**Only when Veda has said so.** This pushes migration 36 to the practice database **and pushes to the main branch**,
from which Vercel builds the staging app. Production is not touched. Nobody is marked as joined by the run itself.

## One double-click (about 3 minutes, then a few minutes for Vercel)

Double-click **`staging-hr-admin-joined.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_hr_admin_joined.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 36, the smoke check, the ledger audit and the app's files are the tested ones; the practice project `zogkrhgzatplarimbmxk`, answering `staging`, with exactly migration 36 waiting. **Records how the two seats stand** (read only, no names: admins active and linked, the HR Admin seat holder's status, HR resources, the sign-in code, the last audit actions). Says what will happen and **asks you to type `HR ADMIN JOINED`** | any check fails, or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 36 | the push fails (nothing of it is applied) |
| S2 | Smoke check 31 rows, the two-jobs check (migration 35 still in place), the **HR-joined check** (`OK`), ledger audit `NO FINDINGS`, `NO LOGIN WITHOUT A PERSON`, the server functions | a row or a check is not `OK` (the nightly check is listed but does not stop it) |
| S3 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a backup or the run record; commit or push fails |

Last line: `RESULT: HR ADMIN JOINED ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-hr-admin-joined-<time>.log` — the line `the seats now: …` is what Claude needs to explain
why the admin's call was refused on 10 October (it could not be reproduced on the local copy).

`staging-admin-two-jobs.cmd` has done its job; it now refuses to run (the app is no longer the one it was sealed for).

## Afterwards, in the app (about 5 minutes)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Admin | Reload the app. **Access → Seats** | Under HR Admin: "… holds the seat but has not joined yet …", with **Open the joiner page** |
| 2 | Admin | Open another joiner's page, if there is one (HR · Joiners) | No **Mark as joined** button |
| 3 | Admin | **Open the joiner page** (the HR Admin's) → **Mark as joined** | You land on Seats: "… has joined as HR Admin. HR is switched on …"; **HR · Joiners** leaves your menu |
| 4 | Admin | **Audit → Audit log** → Flagged only | A flagged line "marked the HR Admin as joined", badge "Admin marked the HR Admin as joined" |
| 5 | HR Admin | Sign in | **HR · Joiners**, **People & access**, **Audit log** in the menu; she marks the other joiners as joined herself |
| 6 | Admin | **People & access** → any person | No Reset password, Suspend, Offboard or HR record (on the HR Admin's own page: Reset password only, as before) |

## If something is wrong afterwards

Nothing was deleted or rewritten. Migration 36 replaces two functions; the versions it replaced are in migrations 33
and 35. Ask before changing anything back.

## Rehearsed

On the local stack, 10 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (30 files with the upgrade path),
the unit tests, the screen suite and the first day from nothing (the admin adds the HR person, appoints her, marks her
as joined; a second HR joiner gets no button and the API refuses). The script on stand-ins. Not rehearsed: the push to
the hosted project and the Vercel build.
