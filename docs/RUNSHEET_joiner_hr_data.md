# Joiner checklist and HR data: migration 37, the server functions and the app, onto the practice system

Brief "GrainVeda MVP — Joiner checklist and HR data improvements" (Veda, 11 October 2026). Open item 31, line 39 in
`docs/FIX_LIST.md`. What it changes, in one line each:

- **A1** A PAN, Aadhaar or UAN already on another person's record is refused ("This number is already registered. HR
  has been told."); HR sees whose. A bank account on another record is saved and HR warned; HR may accept it with a
  reason (flagged). The full number goes from the phone to the new server function `id-numbers` and nowhere else.
- **A2** Only the masked Aadhaar is uploaded (no PAN photo). HR answers "Masked?"; "No" deletes the image and asks the
  joiner again. HR records "PAN card seen".
- **A3** A Personal details step (date of birth, father's or spouse's name, addresses, emergency contact) in the Standard
  template, and added to the open checklists of people still joining.
- **A4** Add joiner needs a phone. **B1** No step is overdue on the day a person is added. **B2** A template task may wait
  for others ("Depends on"); none does unless HR sets it, so steps can be done in any order.
- **B3–B7** "Your joining date: …" while joining; HR joiners read HR words; a Help page and a guide for joiners; first-day
  details set by HR (template defaults); the Aadhaar check-digit words.

**Only when Veda has said so.** This sets a secret and deploys the server functions on the practice project, pushes
migration 37 to the practice database **and pushes to the main branch**, from which Vercel builds the staging app.
Production is not touched. No file in the HR documents store is deleted or changed by the run.

## One double-click (about 5 minutes, then a few minutes for Vercel)

Double-click **`staging-joiner-hr-data.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_joiner_hr_data.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 37, the smoke check, the ledger audit, the app's files **and the server functions' files** are the tested ones; the practice project `zogkrhgzatplarimbmxk`, answering `staging`, with exactly migration 37 waiting. Records how things stand (read only, no names: people joining, identity records, HR files by kind, whether the key is set). **Asks you to type `JOINER HR DATA`** | any check fails, or anything else is typed. Nothing is changed |
| S1 | **The key of `id-numbers`.** Makes 32 random bytes on your PC, **never shows them**, writes them to `.env.id-hmac-key.staging` (git-ignored) and sets them as the project's secret `ID_HMAC_KEY` (name `k1`). If the project already has the key, it is kept | the file would not be git-ignored; `secrets set` fails |
| S2 | Deploys the five server functions (`create-user`, `reset-password`, `ledger-check`, `daily-code`, `id-numbers`), then `check_functions`: `FUNCTIONS DEPLOYED AND CURRENT` (it also checks the key is set) | a deploy fails; a function is old or not configured. The database is not changed yet |
| S3 | `supabase db push`: migration 37 | the push fails (nothing of it is applied) |
| S4 | Smoke check **32** rows (new: `joiner HR data`), the checks of migrations 35 and 36, ledger audit `NO FINDINGS`, `NO LOGIN WITHOUT A PERSON`, the functions again. Then **lists the files already in the HR documents store** (kind, date, the person's status, file name with any number removed, whether the image is stored) | a row or a check is not `OK` (the nightly check is listed but does not stop it) |
| S5 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, the key, a backup or the run record; commit or push fails |

Last line: `RESULT: JOINER HR DATA ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-joiner-hr-data-<time>.log` — send it to Claude: the `HR files already stored` lines are the
list the brief asked for (A2).

**The key file.** After the run, open `.env.id-hmac-key.staging` in Notepad, copy the line `ID_HMAC_KEY=…` into your
password manager (title "GrainVeda practice: id-numbers key"), then delete the file. Do not send it to anybody,
Claude included. Lost: nothing saved is lost or exposed; see `docs/OPERATIONS.md`, "The key of the id-numbers function".

`staging-hr-admin-joined.cmd` has done its job; it now refuses to run (the app is no longer the one it was sealed for).

## Afterwards, in the app (about 20 minutes)

Use **made-up numbers** for the test joiners, never a real person's: PAN `ZZZZZ9999Z` and `ZZZZY9999Z`, Aadhaar
`9876 5432 1012` (a valid check digit), account `123456789012` at IFSC `SBIN0001234`. For the image, any picture that
is not an ID card.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | HR Admin | **HR · Templates** → Standard | "Personal details" after the identity step; each task has **Depends on** (none ticked); **First day** defaults can be set (time, place, who to ask, what to bring) |
| 2 | HR Admin | **Add joiner**, without a phone → Save | The form will not go; with a phone it does. Add **Test One** (full time, your `+t1` address) and **Test Two** (`+t2`) |
| 3 | HR Admin | Test One's page | No step says "overdue"; every due date is at least three days ahead. **First day** card: set a place |
| 4 | Test One (phone) | Sign in, own password | "Your joining date: …" (not "joined … ago"); a guide card; **Help** in the menu with your name, email and phone under HR Admin |
| 5 | Test One | Checklist: **bank first**, then identity (PAN `ZZZZZ9999Z`, Aadhaar `9876 5432 1012` — try the last digit `3` first: the check-digit words), upload the picture as the masked Aadhaar, then Personal details | Each step saves; the PAN photo is not asked for; the steps open in any order |
| 6 | HR Admin | Test One's page | PAN, Aadhaar, bank "checked for duplicates"; Personal details card; the image with **Masked?** → **No** → "image deleted"; Test One sees identity open again with "asked again: a masked Aadhaar …". **PAN card seen** → "seen by …" |
| 7 | Test Two (phone) | Identity with PAN `ZZZZZ9999Z`; then Aadhaar `9876 5432 1012`; bank with the same account | "This number is already registered. HR has been told." twice (no name shown); the bank step saves |
| 8 | HR Admin | Test Two's page | "PAN •••• 999Z was refused …: it is already on Test One's record" (and the Aadhaar); "This bank account is also on Test One's record." → type a reason → **Accept** |
| 9 | HR Admin | **Audit log** → Flagged only | "refused a number already on another record" (two) and "accepted a shared bank account" |
| 10 | Veda | **The hosted logs** (below) | No result for any of the numbers |
| 11 | HR Admin | Neha's page (a real joiner) | "Personal details" added to her checklist; if she gave her PAN or Aadhaar before today: "not checked for duplicates" (reopen the step if it should be checked) |
| 12 | HR Admin | Offboard Test One and Test Two | — |

### Step 10: search the hosted logs for the numbers typed

Supabase dashboard → the practice project → **Logs** → **Logs Explorer**. Set the time range to cover steps 5 to 8.
Search each source — **Edge Functions** (and **Edge Function logs** / `function_logs`), **Postgres**, **API Gateway**
(`edge_logs`), **PostgREST**, **Auth** — for each of: `ZZZZZ9999Z`, `ZZZZY9999Z`, `987654321012`, `9876 5432 1012`,
`123456789012`.

Expect **no result** in any of them. To prove the search works, search the same sources for `+t1@` (Test One's email):
Auth must show results. Then in the **SQL editor** (read only):

```sql
select 'found in ' || t from (
  select 'audit_log' t, a::text x from public.audit_log a union all
  select 'client_errors', c::text from public.client_errors c union all
  select 'employee_docs', d::text from public.employee_docs d union all
  select 'employee_files', f::text from public.employee_files f union all
  select 'onboarding_tasks', o::text from public.onboarding_tasks o union all
  select 'ledger', l::text from public.ledger l) s
where x ~ '(ZZZZZ9999Z|ZZZZY9999Z|987654321012|9876 5432 1012|123456789012)';
```

Expect **no rows**. A result anywhere: tell Claude where, and do not type more numbers until it is understood.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 37 adds columns, two tables, indexes and rules, replaces functions (the
versions it replaced are in migrations 33 to 36), and adds the Personal details step. The functions can be redeployed
from an earlier commit. Ask before changing anything back. The key stays in the project's secrets either way.

## Rehearsed

On the local stack, 11 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (31 files with the upgrade path),
the unit tests (with the number-leak tests), the screen suite (with `phase10`: duplicates, masked image, phone, day one,
the joiner's words in both languages, and the search for typed numbers in everything the stack wrote), the first day
from nothing, and the production build. The script on stand-ins (PowerShell 7 on Linux): the full run, a second run,
each stop (wrong words, production, another migration waiting, a secret that will not set, a function that will not
deploy, a smoke row not OK, a changed or new function file) and `-NoGit`; the key never appeared in the screen output
or the record. Not rehearsed: Windows PowerShell 5.1, the hosted project, its logs, and the Vercel build.
