# Run-sheet for Antigravity — Phase 5 (identity and authorization layer)

What this puts on staging: HR adds a person once; a manager gives access as assignments; the screens for both;
suspend / offboard / re-hire; the two seats; the audit log; the once-a-day sign-in code (built, **off**).
What it is and why: `docs/IDENTITY_DESIGN.md`. Built and tested on the local stack (6 October 2026).
**Part D was done on staging on 6 October 2026** (D12 excepted; results in `docs/VERIFICATION_LOG.md`). Part E is next.

**Three things are deployed, in this order: database (D2–D3), server functions (D4), app (D11).** Between D3 and
D11 the old app's **Users & Roles** page does not work (it answers "reload the app"); everything else does. Do D1 to
D11 in one sitting.

Prerequisite: Phase 4 part A is done on staging through migration 30 (step D2 shows whether it is).
Stop at the first step that does not match "Expect" and paste the raw output back to Claude.
Never paste keys, tokens or passwords into chat. PowerShell, from the repository root unless a step says `cd web`.

**Never run against a hosted project:** `tests/00_local_auth_shim.sql`, `tests/run_local.*` (they rebuild a database),
`tests/remote_create_user.mjs`, `tests/remote_ledger_check.mjs --tamper-local`, `scripts/collect_release_evidence.sh`,
and anything with `ENV_FILE=.env.stack`. Seeds 02–06 never go to production (they refuse; do not test it).

## Part D — staging database, server functions, app (about 40 minutes)

**In one command (added 6 October 2026):** double-click `staging-phase5.cmd` in the repository root, or run
`powershell -ExecutionPolicy Bypass -File scripts\staging_phase5.ps1`. It runs D1 to D11 below in order, checks each
step's "Expect" itself, and stops at the first one that does not match (the last line is `RESULT: PART D RAN TO THE
END` or `RESULT: STOPPED`). Before anything is sent it checks that the linked project answers `staging`, and that
the three migrations, seed 06, the four functions and the two SQL checks are the files that were tested (a changed
file stops it). It reads no `.env` file and prints no key or password. The record of the run is
`release-evidence\staging-phase5-<time>.log` (git-ignored): give that file to Claude instead of pasting output.
- **D1** runs on a scratch PostgreSQL the script makes and removes (PostgreSQL 16 or 17 tools found on the computer,
  or `-PgBin <folder>`). No tools: D1 is marked `NOT RUN` and the run goes on, because the files are proven to be the
  tested ones. A test that fails: it stops, nothing is sent.
- **D4**: if the only thing `check_functions` reports is that the token of `ledger-check` is not set on the project
  (a Phase 3 setting, `docs/FIX_LIST.md` open item 24), it is listed and the run goes on. Anything else stops it.
- **D11**: if no unit test can START because Node on the computer is older than the test tools need (Node 22;
  open item 26), and the type check passed, the script compares the app's 78 files with
  `scripts/tested_app_files.txt` (the app as it was tested). All the same: D11 is marked `NOT RUN` and the run goes
  on. One file changed, missing or new, or a test that really fails: it stops and the app is not pushed.
- **D5**: three rows describe how the project is set up, not today's change (`demo data`, `auth.uid mapping`,
  `nightly ledger check`): one of these not `OK` is listed and does not stop the run. Any other row does.
- **D12** runs only with `-RunT1`. After a stop that has been read: `-From D5` starts there; `-SkipCheck D5` keeps
  a step's output without judging it; `-NoGit` stops before the commit and push; `-SkipLocalTests` leaves D1 out.
- The table below stays the reference: the script does exactly these steps.

| # | Command | Expect |
|---|---|---|
| D1 | `tests/run_local.ps1` | Last line `ALL TESTS PASSED`. Before it, a line **`ok   upgrade: the later migrations apply to a database in use, and all 27 test files pass on it`** (the database as it stood at migration 30 with the demo people, then 31 to 33 on top: the same thing D3 does to staging). **Two lines that look like trouble are expected:** one `ERROR: function gv_runner_probe_fails_on_purpose() does not exist` right after `runner self-test` (the runner checking that it can fail), and one `WARNING: LEDGER CHECK FAILED at block …` (a test alters a block on purpose). Any line starting `FAILED`, or a last line `SOME TESTS FAILED`: stop, paste the output, do not push. This is the first run of this runner that can fail on a test (`docs/FIX_LIST.md` line 36) |
| D2 | `supabase db push --linked --dry-run` | Would push exactly three: `20261006000100_identity_schema`, `20261006000200_union_access`, `20261006000300_people_lifecycle`. **Any other name in the list: stop.** An older name means Phase 4 part A was not finished on this project |
| D3 | `supabase db push --linked --yes` | `Finished supabase db push.` |
| D4 | `supabase functions deploy create-user` · `supabase functions deploy reset-password` · `supabase functions deploy ledger-check --no-verify-jwt` · `supabase functions deploy daily-code` · then `node scripts/check_functions.mjs` | `Deployed Function` **four** times (`daily-code` is new). Then four lines `ok … build 2026-10-06` and `FUNCTIONS DEPLOYED AND CURRENT`. A line `FAIL … an older build` or `not deployed`: deploy that one again. `… secrets are not set` on ledger-check: `docs/RUNSHEET_phase3.md` steps 7 and 8 |
| D5 | `supabase db query --linked -f tests/remote_smoke.sql` | **30 rows, all `OK`.** The six new rows: `identity layer objects`, `people moved to assignments`, `the two seats`, `manager rules ask about the scope`, `people written only by their actions`, `once-a-day sign-in code` (it says **off**) |
| D6 | `supabase db query --linked "select id, public from storage.buckets where id = 'hr-docs'"` | One row: `hr-docs`, `false` (the private store for HR documents) |
| D6b | `supabase db query --linked -f tests/remote_ledger_audit.sql` | One row starting `NO FINDINGS (`. (The audit now knows the blocks written when a client's account or a state is given or taken away; it needs migration 31, so it comes after D3) |
| D7 | `supabase db query --linked "select u.display_name, coalesce(u.email, u.phone) as sign_in from public.app_users u where not u.external and u.system_role = 'operational' and u.status = 'active' and not exists (select 1 from public.assignments a where a.employee_id = u.id and a.active) order by 1"` | The people who had a login but **no stage, client or state** before today. They can still sign in and will see "A manager will assign you to your work soon" until a manager assigns them. **Paste this list to Veda** (zero rows is fine) |
| D8 | `supabase db query --linked "select system_role, status, count(*) from public.app_users group by 1, 2 order by 1, 2"` | At least one row `admin · active`. No row `hr_admin` yet unless D9 was run before: the HR Admin seat is filled in D9 (demo) or by Veda in step E2 |
| D9 | `supabase db query --linked -f supabase/seeds/06_identity_demo.sql` · then `node scripts/create_demo_logins.mjs` | No errors. Then a table: the lines of keys **316, 317, 318, 319** end in `created` with `yes` under `linked`; the others end in `existing, unchanged`; last line `ALL DEMO LOGINS CREATED AND LINKED`. Their passwords are in `.env.demo-logins` (git-ignored; do not paste them). If the only lines not linked are keys 305 to 315 (phone sign-ins, with the Phone provider OFF on this project), that was so before today: say so and go on |
| D10 | `node scripts/check_logins.mjs` | `NO LOGIN WITHOUT A PERSON`. (A listed "person without a login" is FIX_LIST K22, not a stop) |
| D11 | `cd web; npm ci; npx tsc -b --noEmit; npx vitest run; cd ..` · then `git add -A; git commit -m "Identity and authorization layer: HR onboarding, assignments, lifecycle, seats, audit log (migrations 31-33)"; git push` | No type errors. Vitest: all files pass (the count is in `docs/VERIFICATION_LOG.md`, entry of 6 October). `git status` before the commit shows **no** `.env.*` file. Vercel builds the push; wait for the deployment to be **Ready** |
| D12 | Only if step A9 of the Phase 4 run-sheet passed on this project before (it signs the demo operators in by phone, so it needs the Phone provider ON): `node tests/remote_rls.mjs --t1` | Last lines `… passed, 0 failed` and `REMOTE RLS PASSED`. If the Phone provider is OFF on staging, skip this step and say so |

If D3 fails: nothing was changed (each migration is one transaction). Paste the error. Do not edit a migration file.

## Part E — the new screens on the deployed staging app, by a person (about 40 minutes)

**After the fresh start of 6 October 2026** (`docs/RUNSHEET_fresh_start.md`) the demo people named below no longer
exist on staging. Do part 2 of that run-sheet first (state, crop, client, HR seat, people, scope); then steps 3 to
15 here with the people you made: "HR" is your HR Admin, "Client Manager" is the person you gave the client's
account. Steps 1 and 2 as written, except that the HR Admin seat shows whoever you appointed.

By Veda or anyone who did not build it. Laptop for steps 1 to 3 and 7 to 15, **a phone for steps 4 to 6**. Demo
sign-ins: the addresses below with the passwords in `.env.demo-logins` (lines `DEMO_316…` to `DEMO_319…`, and the ones
used before). On staging use made-up identity numbers: it is the practice system.
Anything that does not match goes into `docs/FIX_LIST.md` as a new open item (the next number is 27).

| # | Sign in as | Do | Expect |
|---|---|---|---|
| 1 | admin | Look at the menu. Then type `/users` after the app's address | A section **People**: HR · Joiners, People & access, State overview. Under System: **Seats**, **Audit log**. No "Users & Roles". The old address opens People & access |
| 2 | admin | **Seats** | Your name under **Admin (root)** with the note "If every admin is locked out…". **HR Admin (exactly one)**: `Asha (HR Admin)` (from D9). **Once-a-day sign-in code**: OFF, mail sender "not set up", the switch greyed out |
| 3 | HR `grainvedas+hr@gmail.com` | First screen is **Joiners**. **Add joiner**: full name, join date today, an email address nobody in the system has (no mail is sent), employment type **Intern**. Save | The form has **no** client, scope, state or stage field. A blue note says interns skip the statutory task. After saving: the temporary password, shown once, and "No mail sender is set up: give them the sign-in address and this password yourself". **Open their page**: seven tasks, status Invited |
| 4 | the new joiner, **on a phone**, with that password | Sign in | The email is shown and cannot be changed; you choose your own password. Then **Welcome, …** and "Today is your first day". The menu has **My joining checklist** and nothing of the work |
| 5 | the same | **Open my checklist** → **Start**: tick the box → Done. Next step: PAN `ABCDE1234` | Only one step can be started at a time; later ones show a lock; HR's steps say "We're on it". The short PAN is refused in words; `ABCDE1234F` is accepted but the step still asks for a photo of the card |
| 6 | the same | Attach any photo, Done. Then the bank step: any bank name, IFSC `SBIN0001234`, account `12345678901` | `3 of 7 done`. Nothing left to start |
| 7 | HR, laptop | The joiner's page, reload | **Documents** shows `•••• 234F` and `•••• 8901`, never the full numbers. The photo is listed and **Open** shows it. **Waiting on you (4)** |
| 8 | HR | Mark the four steps done (name a buddy; write three goals) | After the last one the status turns **Active** by itself. On the phone (reload): "You're all set, … A manager will assign you to your work soon" |
| 9 | Client Manager | **People & access**. Tick **Unassigned only** | The joiner is there with a yellow **Unassigned**. The State Manager's row says **+1 elsewhere** and not where. No "Add joiner" anywhere for this person |
| 10 | Client Manager | **Assign** on the joiner: a scope, tick **Procurement** and **Quality Control** | A yellow box: "… follow each other … cannot pass their own lots on". The save button stays usable. Untick Quality Control, type a posting, **Give this assignment** |
| 11 | the joiner, phone, reload | — | The Procurement card of that scope |
| 12 | Client Manager | The joiner's profile. **Assign** again: the scope **Nagaon** (the same client in Assam, nobody on it), Procurement. Then on the profile: **Change stages** on the first assignment, and **End** on the Nagaon one | Four boxes: Identity, Org facts (grey: "describes; grants no access"), System role, Assignments. Assigning Nagaon warns "Already working in another state" and still saves. Ending it says beforehand "This will leave nobody at: Procurement (farm-gate)." The ended assignment stays listed under **Ended**, with no buttons |
| 13 | HR | The joiner's profile: **Suspend** (a reason is required). Joiner tries to sign in. **Reinstate**. Then **Offboard**: exit date, reason, final settlement, Form 16 reference | Suspended: the joiner's sign-in says "This sign-in opens nothing…". Reinstated: everything is back. Offboarded: status **Left**, every assignment under Ended, a **Re-hire** button, no way to delete the person |
| 14 | HR Admin `grainvedas+hradmin@gmail.com` | **Audit log** → **Flagged only** | The offboarding of step 13, marked. Without the tick: every step above as a line, with who did it |
| 15 | Procurement demo operator (holds stages in five scopes; a phone sign-in, so only where the Phone provider is ON. Otherwise: give the joiner of step 3 a stage in a second scope and use them) | Sign in | "Where are you working now?" with the places. One tap opens that scope's stage only; **Change where I am working** brings the list back |

## Part F — production, when go-live day comes

Part C of `docs/RUNSHEET_phase4.md` stays the sequence. What this phase changes in it:

| Step there | Now |
|---|---|
| C4 | **34** migrations, the last `20261010000100_admin_oversight` (added 10 October 2026, decision G15) |
| C5 | unchanged. **Never seeds 02–06** |
| C6 | **four** functions: add `supabase functions deploy daily-code` |
| C8 | 31 rows `OK`; `once-a-day sign-in code` says off; `the admin oversees` OK |
| C10 | unchanged: `scripts/bootstrap_admin.mjs` makes the first admin. It is also the **break-glass** tool: with `--additional` it makes another admin when every admin is locked out (`docs/OPERATIONS.md`) |
| C13 | Veda, in the app, in this order: **HR · Joiners → Add joiner** for the person who will be HR Admin (system role **HR**) → **Seats → Appoint** that person → from then on HR adds people. The admin gives each State Manager their state (**People & access → profile → Assign → A state**). A State Manager gives a client's account to its manager. That manager opens the scope and gives the stages. Then farmers, then **Activate** |

**Mail sender (optional, any time).** Without one: HR hands the temporary password over in person and the sign-in
code stays off; nothing else depends on it. With one (a Resend-style HTTP mail service): add three lines
`MAIL_API_URL=`, `MAIL_API_KEY=`, `MAIL_FROM=` (and optionally `APP_URL=`) to the git-ignored `.env.functions`
(production: `.env.functions.production`), then `supabase secrets set --env-file .env.functions`. **Seats** then says
"set up". The code can be switched on there once every person who signs in has an email; the switch names the people
who do not.

## What this phase added

- **Migrations 31 to 33.** 31 `identity_schema`: status and system role on the person, assignments, org facts, masked
  identity details, HR files, checklist templates and tasks, audit log, the sign-in code's tables; existing people are
  moved to assignments in the same transaction. 32 `union_access`: every access rule reads the system role and the
  live assignments; sixteen record functions ask "does this person manage **this** scope" instead of "is this person a
  manager"; the private store `hr-docs`. 33 `people_lifecycle`: the actions (add joiner, checklist, assign, move, end,
  suspend, offboard, re-hire, seats, audit feed, sign-in code).
- **Server functions.** `create-user` rewritten (joiner or client login); `daily-code` new; all four build 2026-10-06.
- **Web.** HR (pipeline, add joiner, joiner page, templates); the joiner's phone screens (own password with the
  sign-in locked, checklist, one task, first day, goals, waiting screen); People & access (directory with two lenses,
  profile, assign, roster, state overview); Seats; Audit log; the sign-in code screen; work picker for people with
  stages in several scopes. About 420 new strings in English and Hindi.
- **Removed.** The Users & Roles page; "+ new person" in the scope wizard; creating a person by direct write.

## What only people can close

| Task | Owner | Where it is recorded |
|---|---|---|
| The three changes in behaviour (managers no longer create people or reset passwords; a joiner works only once joined; the State Manager seat is the admin's to give) | Veda | `docs/IDENTITY_DESIGN.md` "To confirm" |
| Part E on the deployed app | Veda or a non-builder | `docs/FIX_LIST.md` |
| Who is HR Admin, and who are the HR resources | Veda | Seats |
| The new Hindi (about 420 strings) read by two people who will use it | Veda arranges | `docs/FIX_LIST.md` K9 |
| A mail sender, if invites by mail or the sign-in code are wanted | Veda | Part F |
