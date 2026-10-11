# Onboarding at scale: migration 38, the server functions and the app, onto the practice system

Brief "GrainVeda MVP — Onboarding at scale (10 → 100 → 200+ hires)" (Veda, 11 October 2026; the six decisions
"as recommended"). Open item 32, line 40 in `docs/FIX_LIST.md`. What it changes, in one line each:

- **A Openings.** HR plans hiring as openings: state, role, positions, optionally client and scope (an operator opening
  names its stage), target date. Each opening, each state and the whole company show positions, joining, joined,
  assigned, "joined, waiting for their wave", ready to assign and vacant. The admin's overview shows the same totals.
- **B Import.** HR → Import joiners: a spreadsheet template (with a sheet listing the open openings), a preview that
  marks each row ready / warning / error with the reason, then only the good rows are added, in one go. The same file
  again adds nobody twice.
- **C Invites** (decisions 1 and 4). A one-time link per person, 72 hours, as a link to copy or a QR code; emailed too
  once a mail sender is set up (none is: the screen says so). Sent again on request (the old link stops working). The
  joiner chooses a password on the link's page and is signed in. "Temporary password instead" stays on each joiner's page.
- **D Roles.** Add joiner and the import take an opening (or a role and stage); the checklist is the role's
  ("Standard · Operator" and so on, copies of the Standard checklist for HR to edit). The role shows on the list and page.
- **E The list.** One Joiners list paged on the server: Mine (HR owner), search, state, role, opening, status, overdue,
  waiting on us / the joiner / IT; tick many and send invites, mark an HR step done, set first-day details, set the HR
  owner or mark as joined. Reminders (decision 2): the joiner sees overdue steps in the app; nudges on day +1 and +3
  (two at most per step) and a daily digest to each HR owner are queued, and sent once a mail sender is set up.
  People & access and the Audit log are paged too.
- **F Assigning.** "Ready to assign" on a roster, a client and a state: everyone who joined for it, tick and give in
  one act (one log line per person). The HR Admin names a **Deputy** who may seat State Managers (decision 3, flagged).
- **G The gate.** Mark as joined is refused while a statutory step is open; HR may record it as "received on paper"
  (decision 5, flagged). Other open steps need a reason (flagged). The page shows "Active" at once.
- **H** H1 "joining date: …" for anyone still joining; H2 the admin may do the HR Admin's own HR steps (flagged);
  H3 HR may do IT steps; H4 "State Manager" everywhere; H5 the texts say the HR Admin seats State Managers; H6 guides
  for the HR Admin and HR resources; **H7 once**: open steps of people still joining that are due within three days
  move to three days from the push (decision 6), each person's move logged.

**Only when Veda has said so.** This deploys the server functions on the practice project, pushes migration 38 to
the practice database **and pushes to the main branch**, from which Vercel builds the staging app. Production is not
touched. **No test data is added**: the 205-person test and the load runs were on the local stack only.

## One double-click (about 5 minutes, then a few minutes for Vercel)

Double-click **`staging-onboarding-at-scale.cmd`** in the repository root (or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_onboarding_at_scale.ps1`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 38, the smoke check, the ledger audit, the app's files and the server functions' files are the tested ones; the practice project `zogkrhgzatplarimbmxk`, answering `staging`, with exactly migration 38 waiting; the key of `id-numbers` set. Records how things stand (read only: people joining, their open steps, how many are due within three days). Says whether a mail sender is set. **Asks you to type `ONBOARDING AT SCALE`** | any check fails, or anything else is typed. Nothing is changed |
| S1 | Deploys the six server functions (`invite` is new, public like `ledger-check`: `--no-verify-jwt`), then `check_functions`: `FUNCTIONS DEPLOYED AND CURRENT` | a deploy fails; a function is old or not configured. The database is not changed yet |
| S2 | `supabase db push`: migration 38 | the push fails (nothing of it is applied) |
| S3 | Smoke check **34** rows (new: `onboarding at scale`, and `reminder round`, which like the nightly check only says whether pg_cron schedules it), the checks of migrations 35 and 36, ledger audit `NO FINDINGS`, `NO LOGIN WITHOUT A PERSON`, the functions again; what migration 38 did: role checklists (4), due dates moved for N people, openings and invites (0) | a row or a check is not `OK` (the two standing rows are listed but do not stop it) |
| S4 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a key, a spreadsheet, a backup or the run record; commit or push fails |

Last line: `RESULT: ONBOARDING AT SCALE ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-onboarding-at-scale-<time>.log`: send it to Claude.

`staging-joiner-hr-data.cmd` has done its job; it now refuses to run (the app is no longer the one it was sealed for).

## Afterwards, in the app (about 25 minutes, three made-up people)

Use **made-up people only**: names starting `TEST`, addresses at `example.com` (they cannot receive mail), phones
`9000000001` to `9000000003`. Nothing here loads the practice system.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | HR Admin | **HR · Openings** → New opening: Uttar Pradesh, Operator, 3 positions, your client, a scope, stage Procurement, title `TEST opening` | A code `UP-OPR-001`; 3 vacant; "the scope is not active yet" if the scope is a draft |
| 2 | HR Admin | **Import joiners** → Download template; fill three rows `TEST One/Two/Three`, `test.one@example.com` …, the phones above, a date next week, `contract`, the opening code; add a fourth row with email `not-an-email` | Preview: 3 ready, 1 error "the email is not right"; Add 3 → "3 added"; the opening shows 3 joining, 0 vacant |
| 3 | HR Admin | Choose the same file again | 3 skipped "already added (the same email and mobile)", nothing to add |
| 4 | HR Admin | **Joiners** → filter by the opening → tick all → **Send invites** | Three links (no sender: "copy each link"); each row "invite link made, not emailed" until opened |
| 5 | You, on your phone | Open TEST One's link (copy it into a message to yourself) | "Choose your password", "Hello TEST, …"; choose one → signed in as TEST One, checklist shown. The link again: "This link has been used already." |
| 6 | HR Admin | Joiners → **Mine**; search `TEST`; Overdue; page buttons (only with more than 50) | Each filter narrows; TEST One shows "invite accepted" |
| 7 | HR Admin | TEST Two's page → Mark as joined | Contract: no statutory step → asks a reason; with one: **Active** at once and "TEST Two is marked as joined" |
| 8 | HR Admin | A full-time test person (add one, `TEST Four`, full time) → Mark as joined | Refused: "a statutory step is still open"; **Received on paper** on that step (a note) → then a reason → joined |
| 9 | Client Manager | The scope's roster | "Ready to assign": TEST Two (and Four if the opening matches); tick → Give → "Done for 1 of 1" |
| 10 | HR Admin, Admin | Openings; the admin's Overview | The same totals in both |
| 11 | HR Admin | **Audit log** → Flagged only | "Joined with steps open" and "Statutory step on paper" lines |
| 12 | HR Admin | Clean-up: offboard TEST One to Four (each person → Offboard, reason "test"); Openings → `TEST opening` → **Close** | They are kept as offboarded records (nothing is deleted, as always); the opening shows 0 vacant |

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 38 adds tables (openings, invites, message queue, deputy seat), columns,
indexes and rules, replaces functions (the versions it replaced are in migrations 33 to 37), adds four role
checklists, and moves the due dates of open steps once (each move in the audit log with the old date). The functions
can be redeployed from an earlier commit. Ask before changing anything back.

## Rehearsed

On the local stack, 11–12 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (32 files with the upgrade
path), the unit tests, the screen suite with `phase11` (205 joiners from one spreadsheet to 40 on a stage, at 527 px,
in Hindi too), the first day from nothing, the production build, and the load runs of `tests/load_onboarding.mjs`
(200 and 2,000 per run). The script on stand-ins (PowerShell 7 on Linux). Not rehearsed: Windows PowerShell 5.1, the
hosted project, pg_cron on it, email (no sender), and the Vercel build.
