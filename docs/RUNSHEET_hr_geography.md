# HR by geography: migration 39, the server functions and the app, onto the practice system

Veda, 12 October 2026, after seeing on staging that the HR Admin had made Neha (HR for one state) a State Manager,
because there was no other way to say "HR for this state". Open item 33, line 41 in `docs/FIX_LIST.md`. Her decisions:

- **An HR resource works only for her states.** She sees and acts on the people based there: their records, joiners,
  openings, HR files, invites. Nobody else's. The HR Admin works for every state and gives each HR resource her states
  on the new page **HR · Team**. An HR resource with no state yet sees nobody.
- **"HR should never be the State Manager."** Nobody in HR holds a seat: no State Manager, client's account or stage.
  The database refuses one, and refuses to make HR anyone who holds a seat. (Before, a State Manager seat let an HR
  person give client accounts, so one person could both add people and give them access.) The Deputy who seats State
  Managers while the HR Admin is away does so only in her own states.
- **Every person has a base location**: a state and a district on their HR record. It grants nothing; for HR it says
  whose record it is. Add joiner and the spreadsheet import ask for it (an opening gives its state). The migration fills
  it in where the data leaves no doubt: the opening's state, or the one state of a person's seats.
- **Fixed on the way:** since migration 38, the opening, role, stage and HR owner chosen on the Add joiner form did not
  reach the database (the `create-user` function passed only the older fields), so a joiner added on the form was on no
  opening and got the default checklist. Joiners added from a spreadsheet were not affected. The six functions are
  redeployed (build `2026-10-14`).

**Only when Veda has said so.** This deploys the server functions on the practice project, pushes migration 39 to the
practice database **and pushes to the main branch**, from which Vercel builds the staging app. Production is not
touched. Nothing is deleted.

## Before the run (Minal, the HR Admin, in the app, 2 minutes)

1. **People & access** → Neha → her State Manager assignment → **End**, reason "HR holds no seat".
2. Anyone else in HR who holds a seat: the same. (The script names them and stops if any is left.)

## One double-click (about 5 minutes, then a few minutes for Vercel)

Double-click **`staging-hr-geography.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 39, the smoke check, the ledger audit, the app's and the functions' files are the tested ones; the practice project, answering `staging`, with exactly migration 39 waiting; **nobody in HR holds a seat** (names them otherwise). Records how many HR people and people there are. **Asks you to type `HR GEOGRAPHY`** | any check fails, an HR person holds a seat, or anything else is typed. Nothing is changed |
| S1 | Deploys the six server functions (`invite` and `ledger-check` with `--no-verify-jwt`), then `FUNCTIONS DEPLOYED AND CURRENT` | a deploy fails. The database is not changed yet |
| S2 | `supabase db push`: migration 39 | the push fails (nothing of it is applied) |
| S3 | Smoke check **36** rows (new: `hr by geography`, `HR holds no seat`), the earlier checks, ledger audit, logins, functions. Then: how many base states were filled in, and **a list for the HR Admin**: each HR resource with no state yet, each person with no base state | a row or a check is not `OK` (the two pg_cron rows are listed but do not stop it) |
| S4 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: HR GEOGRAPHY ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-hr-geography-<time>.log`: send it to Claude.

`staging-onboarding-at-scale.cmd` has done its job; it now refuses to run.

## Right after the run (Minal, 5 minutes)

1. **HR · Team**: tick Neha's state(s) → **Save**. Same for every HR resource the run listed. Until then they see nobody.
2. Each person the run listed with **no base state**: their profile → **Based in** → **Edit** → state (and district).

## Afterwards, in the app (about 15 minutes, made-up people only)

Use names starting `TEST`, addresses at `example.com`, phones `9000000011` to `9000000013`.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Neha | **HR · Joiners** | "You work for: <her state>". Only people based there |
| 2 | Minal | **Add joiner** `TEST Other`, **Based in** a state that is not Neha's | Saved; the joiner page shows "Based in: …" |
| 3 | Neha | Search `TEST Other`; open its address from Minal's screen | Not in the list; the page does not open |
| 4 | Neha | **Add joiner** `TEST Mine` against an open opening of her state | **Based in** offers only her states; the joiner page shows the opening's role (the fault fixed above) |
| 5 | Minal | **HR · Team** → tick the other state for Neha → Save; Neha reloads | `TEST Other` now in Neha's list. Untick it again |
| 6 | Minal | Neha's profile | No **Assign** button; "Works for (HR): …" |
| 7 | Minal | `TEST Mine`'s profile → Based in → Edit → district | Saved; **Audit log** shows "set where this person is based" |
| 8 | Minal | Clean-up: offboard `TEST Other` and `TEST Mine` | Kept as offboarded records |

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 39 adds a table (`hr_states`), two columns, functions, and changes read
rules and functions to ask about the state (the versions it replaced are in migrations 33 to 38); the base state was
filled in only where it was empty. To let an HR resource see everyone again without a new migration, the HR Admin ticks
every state for her on HR · Team. Ask before changing anything back.

## Rehearsed

On the local stack, 13 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (33 files with the upgrade path;
test 33 with ten controls), the unit tests (with the create-user fault, which failed before the fix), the screen suite
with `phase12` at 527 px, the first day from nothing, the production build. The script on stand-ins (PowerShell 7 on
Linux), including the stop when an HR person holds a seat. Not rehearsed: Windows PowerShell 5.1, the hosted project.
