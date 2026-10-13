# Identity and authorization layer (built 6 October 2026)

Source: the build prompt "GrainVeda — Identity & Authorization Layer" (Veda, 5 October 2026). This note says how it
was built on top of the existing system, what was decided on the way, and what changed for the people who use it.
Migrations 31, 32, 33; the admin's part changed by migration 34 (10 October 2026, below). Run-sheet: `docs/RUNSHEET_phase5.md`. Known limits: `docs/FIX_LIST.md` K23 to K34. Open decisions: G10 to G13 there.

## The idea in four lines

1. **HR creates a person once**, as an identity with a sign-in and a joining checklist. HR gives nobody access.
2. **A manager gives an assignment**: one scope with stages, one client's account, or one state. A person has 0 to n.
3. **What a person may see is the union** of their live assignments. Client and state are independent lenses.
4. Only two things grant access: the **system role** and the **assignments**. Org facts (title, band, department,
   employment type, reports-to) describe a person and open nothing.

## How the spec's names map onto this system

| Spec | Here | Note |
|---|---|---|
| `employee` | `public.app_users` | Kept as the person table: every record, verdict and ledger block points at it. New columns `status`, `system_role`, `external`, `join_date`, `created_by` |
| `employee_org` | `public.employee_org` | Org facts. No rule reads them |
| `employee_docs` | `public.employee_docs` (last four characters, and since migration 37 a keyed fingerprint per number) + `public.employee_files` (documents in the private store `hr-docs`) + `public.employee_personal` (Personal details, migration 37) | Decision: masked + files |
| `system_role` | `app_users.system_role`: `admin`, `hr_admin`, `hr_resource`, `operational` | Exactly one `hr_admin` (a unique index) |
| `assignment` | `public.assignments`: `lens` `scope` / `client` / `state`; `op_role` `operator`, `export_manager`, `client_account`, `client_viewer`, `state_supervisor` | The manager lenses are named `client_account` and `state_supervisor` so they are not mistaken for the designation "Manager" |
| stages of an assignment | `public.slot_assignments` rows that carry `assignment_id` | The stage rows stay what the stage engine reads; the assignment owns them |
| `client`, `scope` | `public.clients`, `public.scopes` | A scope now has its own `state_id` (a client may work in several states) and an optional `season_end` |
| `onboarding_template`, `template_task`, `onboarding_task` | `public.onboarding_templates`, `template_tasks`, `onboarding_tasks` | The standard template has the eight tasks of §6 with their offsets |
| `audit_log` | `public.audit_log` | Append-only: no update, delete or truncate, for anyone |
| Operational / Client manager / State manager / Export manager / Admin | scope + `operator` · client + `client_account` · state + `state_supervisor` · scope + `export_manager` · system role `admin` | |

`app_users.role`, `client_id` and `state_ids` still exist, as a **summary the database writes** from the assignments
(lists and exports keep reading sensibly). No access rule reads them any more, and a hand edit is refused.

## Decisions taken with Veda (5 October 2026)

| Question | Answer | What it means |
|---|---|---|
| Once-a-day sign-in code | Build it, switched off | Password every time; a six-digit code by email once per calendar day (India time). It is tested end to end and stays **off** on every project until a mail sender is set up. The switch refuses while anyone who signs in has no email |
| Identity and bank numbers | Masked + files | The full number is checked on the person's own device (PAN format, Aadhaar check digit, IFSC). Since migration 37 it is sent once to the server function `id-numbers`, which keeps nothing and gives the database a keyed fingerprint (for duplicates) and the last four characters. Documents go to a private store only HR and the admin can open; for Aadhaar only the masked copy |
| A client's own login | Keep, outside HR | Not an employee, no checklist, no HR record. Made under **People & access → Client logins** by whoever manages that client |
| Build order | All in one go | One delivery: database, server functions, screens, tests |

## What changes for people (three things to confirm, and the rest)

**To confirm** (asked on 5 October, no answer yet; built as below; `docs/FIX_LIST.md` G10, G11, G12):

1. **Client Managers and State Managers no longer create people or reset passwords.** HR adds people; HR and the admin
   reset passwords. A manager picks from the pool HR has filled. (A manager still makes the client's own read-only
   login.)
2. **A joiner cannot work on a scope until they are an employee**: HR presses **Mark as joined**, or the checklist is
   complete. A manager may assign them earlier; the form says the assignment opens nothing yet.
3. **The State Manager seat is given by the admin only.** A State Manager gives client accounts for clients homed in
   the state and assigns people to scopes in the state.

**The rest:**

- **Users & Roles is gone.** In its place: **HR · Joiners** (pipeline, add joiner, a joiner's page, checklist
  templates) and **People & access** (directory with client and state lenses, profile on four axes, assign, roster).
  **State overview**, **Seats** and **Audit log** are new.
- A person who holds stages in **more than one scope** says where they are working after signing in, and can change
  it with one tap. A person with **no assignment** sees a calm waiting screen naming the person they report to.
- **Deactivate** became two things: **Suspend** (frozen at once, everything kept, reversible) and **Offboard** (every
  assignment ends, exit date / final settlement / Form 16 reference recorded, the record kept for ever, re-hire on the
  same record).
- An assignment only moves forward: it is given, its stages change, it is ended or replaced. Nothing is reopened or
  rewritten; the profile shows the ended ones.
- Every person HR adds signs in by **email**. The demo operators of the earlier seeds keep their phone sign-ins.
- A scope's wizard asks for the **state** (default: the client's home state) and an optional **season end**.

## The fault class this removes

The old rules asked "is this person a manager?" once, globally, and separately "can they reach this scope?". With one
role per person that was one question. With a union it is two: someone who manages client A and holds one stage for
client B would have been a manager in B (withdraw records, override verdicts, verify farmers there). Sixteen record
functions asked the global question. Each now asks about the scope in hand (`app.manages_scope(person, scope)`).
`tests/24_union_access.sql` builds exactly that person and holds every one of those functions to the right answer;
four deliberately broken versions of the rules were each caught by it.

## Who may do what (since migration 35, 10 October 2026: the admin's two jobs)

Veda, 10 October 2026, answering the follow-up brief: "admin can only add HR admin. and add state (hence admin has only
2 jobs) - rest he will just look onto data as admin for making strategic decision". The State Manager seat: "HR Admin
seats them". HR data: the admin sees people as counts and charts, not HR records. No override ("no override required").
Her set-up order, with step 4 changed:

1. Admin creates the state.
2. Admin adds the first HR person and gives them the HR Admin seat (the only person the admin adds, and only while the
   seat is empty).
3. HR Admin adds the people, including the future State Manager, client manager, operator, HR and all users.
4. **HR Admin seats the State Manager** (gives the person a state).
5. to 8. as below (State Manager: crop, client, client's account; Client Manager: scope, roster, farmer step 1; State
   Manager of the farmer's state: step 2; operators buy, test and seal).

What changed from the table below (migration 34); everything else stands:

| Act | Who (migration 35) | Function |
|---|---|---|
| Seat a State Manager (the state lens) | **the HR Admin only**; she gives no other lens. The admin gives nothing | `app.may_assign`, `app.assign` |
| Add a person | HR Admin, HR resource; the admin **only the HR person for the empty HR Admin seat** (system role HR). **Nobody adds an admin in the app**: break-glass only (`scripts/bootstrap_admin.mjs`) | `app.add_joiner` |
| System role | HR Admin: operational ↔ HR resource; the admin only while the HR Admin seat is empty. Nobody makes an admin in the app | `app.set_system_role` |
| HR acts, HR files (documents, files, notes, exits, goals, joining checklist) | HR; the admin only while the HR Admin seat is empty (`app.acts_as_hr`) | the HR functions, table and storage policies |
| Reset a password | HR for employees; **the admin for the HR Admin and for another admin** (nobody else resets either; with no other admin, break-glass); whoever manages the client for its login | `app.reset_login_allowed` |
| Suspend, offboard the HR Admin | nobody; replacing her is moving the seat | `app.hr_may_manage` |
| Mark the HR Admin as joined (migration 36) | **the admin**, the HR Admin seat holder only (a flagged audit line); anyone else is HR's to mark, also while the seat is vacant. Nobody is activated by being given the seat; no HR access while Joining | `app.activate_joiner`, `app.joiner_detail` (`can_activate`) |
| People on the admin's overview | numbers only (by system role, State and Client Managers, people on stages, unassigned, joining and checklist %, suspended, left in 90 days, client logins) | `app.platform_overview` (`people`) |
| Weekly figures for the admin | the admin | `app.admin_trends` |
| Report a problem (Help) | anyone signed in; the admin reads it on Health | `app.report_client_error` (kind `report`) |

Tests: `tests/29_admin_two_jobs.sql` and `tests/30_hr_admin_joined.sql` (the database, with controls), `web/tests/admin_two_jobs.test.ts` (the screens'
rules), `web/e2e/phase9.spec.ts` and `web/e2e-fresh/fresh_start.spec.ts`.

## Who may do what (since migration 34, 10 October 2026)

Veda, 10 October 2026: "Admin is oversight only. The Admin watches the operation and uses the dashboard to make
strategic decisions." Override was dropped ("it will create confusion"): what the admin may not do, the admin cannot
do, in the screens and in the database alike. The order a system is set up in (Veda's words, kept as the reference):

1. Admin creates the state.
2. Admin adds the first HR person and gives them the HR Admin seat.
3. HR Admin adds the people, including the future State Manager, client manager, operator, HR and all users
   irrespective of domain.
4. Admin seats the State Manager.
5. State Manager creates crop and onboard the client and gives the Client Manager the client's account.
6. Client Manager builds the scope and assign role to user once user are onboarded by HR.
7. Client Manager adds the farmer and verify once then State Manager verifies the farmer again by Location only (as
   farmer should be part of that state).
8. Operators buy, test and seal.

| Act | Who | Function |
|---|---|---|
| Read everything (overview, every scope, record, farmer, client, crop, roster, the whole ledger) | admin | `app.platform_overview`, `app.ledger_page`, the table rules |
| States | admin | table rules |
| Seat a State Manager (the state lens) | admin only; it is **all** the admin gives | `app.assign` |
| HR Admin seat | admin only; exactly one seat | `app.appoint_hr_admin` |
| Add a person (identity, sign-in, checklist) | HR Admin, HR resource; the admin **only while the HR Admin seat is empty** | `app.add_joiner` through `create-user` |
| Mark as joined, suspend, reinstate, offboard, re-hire | HR Admin, HR resource (not on HR people or admins); the admin on the HR Admin and on admins, and on anyone while the seat is empty | `app.activate_joiner`, `suspend_person`, … |
| Checklist templates | HR Admin; the admin while the seat is empty | table rules |
| Crops | State Manager (any: a crop is shared by every state) | table rules |
| Clients (create, edit) | State Manager, in a state they hold | table rules |
| Give a client's account | State Manager, for clients of the state | `app.assign` |
| Scopes (create, chain, activate), rosters, scope assignments | Client Manager of the client; State Manager of the scope's state | `app.assign`, table rules |
| Add a farmer, import farmers | Client Manager, State Manager, stage people of Procurement or Village Batch; always as a **draft** | table rules, `app.import_farmers` |
| Farmer, step 1 (draft → waiting) | **Client Manager of the client** (recorded as `reviewed_by`) | `app.submit_farmer` |
| Farmer, step 2 (location, Farmer ID) | **State Manager of the farmer's state**, never the person of step 1 | `app.verify_farmer` |
| Send a farmer back | a State Manager of a state the client works in (step 1 is then done again) | `app.send_back_farmer` |
| Stage work (record, verify, seal), withdraw, verdict override, resolve a flag | the people and managers of the scope; **never the admin** | the record functions |
| Raise a flag | anyone who reads the record, the admin too | table rules |
| Reset a password | HR for employees (the admin while the seat is empty, and for the HR Admin and admins); whoever manages the client for its login | `reset-password` |
| System role | admin: any but HR Admin · HR Admin: operational ↔ HR resource | `app.set_system_role` |
| Read the audit log | HR Admin and the admin | `app.audit_feed` |
| Run the ledger check | the admin | `app.check_ledger_now` |

An assignment held by an admin grants nothing (`app.eff_assignments` leaves it out), and an admin cannot be given one:
otherwise the admin could seat themselves as State Manager and do it all again. Farmers made before migration 34 have
no state: their step 2 stays as it was (a State Manager of a state the client works in), with no step 1 required.
Tests: `tests/28_admin_oversight.sql` (the database), `web/tests/admin_oversight.test.ts` (the screens' rules),
`web/e2e/phase9.spec.ts` and `web/e2e-fresh/fresh_start.spec.ts` (through the screens, the second in Veda's order).

The last active admin cannot be suspended, offboarded or given another role. If every admin is locked out, nothing in
the app can help: the database owner runs `scripts/bootstrap_admin.mjs` (`docs/OPERATIONS.md` "Break glass").

## Warnings that do not block (the guardrail)

`app.assignment_warnings` answers before saving, and the saved assignment's audit line keeps the warnings that were
shown: the person is not active yet · has no sign-in · already works in another state · already works at another
place this season · two stages that follow each other (a record is checked by the next stage, never by its maker, so
that person cannot pass their own lots on). Ending or moving an assignment says beforehand which stages would be left
with nobody.

## Audit log

Every change to a person or to their access is one line: who, what, about whom, with the details. Flagged for the HR
Admin: an HR resource made by an HR resource · every offboarding · the HR Admin seat changing hands · a system role
going to or from admin · the sign-in code switched. Assignments through the client or state lens and export-manager
assignments are also blocks in the hash-chained ledger.

## Server functions (six, one build)

`create-user` (joiner or client login; the login is made with the service key, linked, and taken back on any failure;
since migration 37 a joiner needs a phone), `reset-password` (since migration 38 it also makes the sign-in of an
imported joiner who has none), `ledger-check`, `daily-code`, `id-numbers` (migration 37, below), `invite` (migration
38, below; public like `ledger-check`: deployed with `--no-verify-jwt`, it checks the caller itself). All carry
`VERSION = '2026-10-14'`; the app needs that build
(`FUNCTIONS_NEEDED`) and says so on the Add joiner page when the server is behind. Mail (the invite note, the sign-in
code) goes through one sender setting (`MAIL_API_URL`, `MAIL_API_KEY`, `MAIL_FROM`); **none is set on any hosted
project**, so no mail is sent: HR hands over the temporary password in person, as before, and the code stays off.

## Identity numbers and joiner data (migration 37, 11 October 2026)

| Rule | How |
|---|---|
| A full number is never kept | Phone → `id-numbers` (HTTPS POST body, once) → HMAC-SHA256 with `ID_HMAC_KEY` over `<kind>:<number>` (bank: `bank:<first 4 of IFSC>:<account>`) → `app.record_id_number` (service key only) stores the 64-hex fingerprint, the last four and the key's name. The function logs nothing and answers fixed codes. `complete_task` refuses `*_last4`, `pan`, `aadhaar`, `uan`, `account` keys (an old app) |
| Who may give a number for whom | `app.id_number_target`, asked as the caller: the joiner for their own open step of that kind, or HR for a person HR manages |
| Duplicates | Unique partial indexes on `pan_hmac`, `aadhaar_hmac`, `uan_hmac`: refused, `id_number_matches` row `refused`, flagged audit `id_number_refused` (HR sees whose; the joiner reads neutral words). Bank: saved, `warned` row, audit `bank_account_shared`; `app.accept_shared_bank(match, reason)` flagged `bank_duplicate_accepted` |
| Before migration 37 | Records with only the last four show "not checked for duplicates" until the number is given again |
| Images | `employee_files.kind` adds `aadhaar_masked`; `pan` and `aadhaar` uploads are refused. `app.confirm_masked(file, yes/no)`: yes is recorded; no reopens the identity step and the image is removed from the store (policy `hr_docs_remove_unmasked`, then `app.note_file_removed`); the file's line stays. `app.record_card_seen` for the PAN card |
| Personal details | Task kind `personal`; `employee_personal` (read: the person and HR); added to the Standard template and to open checklists of invited/onboarding people |
| Due dates | `greatest(join date + offset, date added + 3 days)` for new checklists; existing ones unchanged |
| Order | `template_tasks.depends_on` / `onboarding_tasks.depends_on` (codes); a joiner's step waits only for those; none by default |
| First day | `employee_org.first_day_*` per person, else `onboarding_templates.first_day_*`, date defaults to the join date |
| Free text | `app.scrub_numbers` on client error reports and acceptance reasons (and the phone does the same before sending) |

## Onboarding at scale (migration 38, 11 October 2026)

| Rule | How |
|---|---|
| Openings | `public.openings` (code `<STATE>-<SM\|CM\|OPR\|EXM\|HR\|OTH>-nnn`; an operator opening names its stage; a client or scope must be in the state, the stage in the scope's chain). Read: HR, the admin, managers who assign. Written by `app.save_opening` / `set_opening_status` (HR). The numbers come from `app.opening_numbers`: people linked by `employee_org.opening_id`; **assigned** = an active assignment that fills it (state seat; client account; an operator assignment in a matching scope, any stage); **ready** = joined, not assigned, and the target is ready (`app.opening_ready`: an active scope with that stage, a client in the state); **waiting for their wave** = joined, not assigned, target not ready |
| People's new columns | `employee_org.opening_id, intended_role, intended_stage, hr_owner, import_batch` are written only by the functions (`employee_org_guard` refuses direct API writes) |
| Import | `app.import_joiners(rows, dry_run, batch)`: reason codes `imp.*` per row; warnings do not stop a row; a row whose email **and** mobile match an existing person is skipped; each row is added by `add_joiner` in its own sub-transaction; one audit line `joiners_imported` |
| Checklist per role | `onboarding_templates.role` (one active per role); Add joiner and the import take the given template, else the role's, else the default |
| Invites | 32 random bytes, base64url, in the link after `#`; the database keeps only its SHA-256 (`invites.token_hash`, not readable by people); 72 hours; one use; a new invite revokes the open one. `record_invite`, `invite_lookup`, `use_invite` are service-key only. `invite` accept: makes the sign-in (or sets the password of an existing one), verifies the link to the person, else removes it |
| Gate | `app.activate_joiner(person, reason)`: refused while a statutory step is open; `app.record_on_paper(task, note)` (HR, flagged `statutory_on_paper`); other open steps need a reason (≥ 5 characters; flagged `activated_with_open_steps`). Bulk: `activate_many`, the same rule per person |
| Many at once | `complete_task_many`, `update_joiner_many` (first-day fields only), `set_hr_owner`, `activate_many`, `assign_many` (each person through the one-person function, each logged); at most 500 |
| Lists | `joiners_page`, `people_page`, `audit_page`: filters and paging on the server, with indexes |
| Ready to assign | `app.ready_to_assign(lens, target)`: active people of matching openings without that assignment; offered on a draft roster too (that is how a draft is staffed) |
| Deputy | `seat_deputies` (one, seat `state_managers`), set by the HR Admin (the admin only while that seat is vacant); `may_assign` lets the Deputy seat State Managers; flagged `state_seated_by_deputy` |
| Reminders | `queue_reminders` (service key; pg_cron `grainveda-reminders` 03:30 UTC where it exists, and the `invite` function's `reminders` action when HR opens the list) → `message_queue` (deduplicated); sent only with a mail sender |
| H2, H3 | The admin may complete the HR Admin's own HR steps (flagged `hr_admin_task_by_admin`); HR may complete IT steps |
| H7 | Once, in the migration: open steps of invited/onboarding people due before today + 3 → today + 3; audit `due_dates_recalculated` per person |

## HR by geography (migration 39, 12 October 2026; decisions G18)

| Rule | How |
|---|---|
| Base location | `employee_org.base_state_id`, `base_district`: grants nothing. Set at Add joiner (given, else the opening's state, else an HR resource's one state) and in the import (`state` by name or code, `district`), later by `app.set_base_location` (HR of the person's state; an HR resource only into her states). Never a direct write (`employee_org_guard`). Filled in once by the migration from the opening's state or the one state of a person's seats |
| HR states | `hr_states` (active while `ended_at` is null), given by the HR Admin with `app.set_hr_states(person, states[])` (the whole list; ended rows kept; audit `hr_states_set`). Only HR resources have states; the HR Admin works for every state |
| Reach | `app.hr_covers(person)`: the admin and the HR Admin: everyone; an HR resource: people whose base state is one of hers. `app.hr_may_manage_person(person)` = by system role (`hr_may_manage`) and by state. Every HR act, list, opening function and HR read rule (people, HR records, checklists, documents, files in `hr-docs` by `hr_covers_path`, invites, number matches, notes, exits, goals, openings) asks it. An HR resource sees her HR colleagues' names, not their records |
| Who sets a base location | HR covering the person (`app.set_base_location`); nobody their own; the admin only while the HR Admin seat is vacant, and **the HR Admin's own** (migration 40, 13 Oct 2026: nobody else could) |
| HR holds no seat | `app.assign` refuses anyone whose system role is HR; `set_system_role(→ hr_resource)` and `appoint_hr_admin` refuse someone who holds a seat; leaving HR ends her states. The Deputy seats State Managers only in her states. Smoke row `HR holds no seat` |
| Screens | `app.hr_scope()` (am I limited, to which states), `app.person_geo(person)`, `app.hr_people_states()`; HR · Team; "You work for: …" on the Joiners list, People & access, Openings, Import |

## The State Manager (migration 41, 13 October 2026; FIX_LIST item 36)

| What | How |
|---|---|
| Who counts | `app.sm_limited()`: holds a state seat and is not a Client Manager, HR or the admin. Someone who also holds a client's account keeps that seat's rights |
| Whom he sees and seats | `app.sm_sees(person)`: himself; operational, non-external people with a live seat in his states (the seat's state, else the scope's, else the client's home); the unassigned based in his states. `app.assert_assignable` refuses himself, the admin, HR and anyone he does not see, also for a seat written directly (`slots_assignment`). A client login's email or password only if every client of that login is his (`manages_viewer_fully`) |
| Scopes | written by the client's account holder (`app.runs_client`); a new scope, or one moved, is in its client's home state (`app.client_home`); a crop of another state is refused. `my_context` says `build` per scope and `can.build_scope` |
| Farmers | created by `app.farmer_create` (the Client Manager, Procurement, Village Batch); staff = the State Manager of the farmer's state, else of the client's home (`app.farmer_staff`); read by `app.farmer_read`; any first activation needs step 1 by another person; the state is never blanked |
| Crops | `crops.state_id`, set once (`crops_a0_state_guard`); written by a State Manager of that state; audited (`crop_added`, `crop_state_set`, `crop_changed`) |
| His screens | `app.state_home(state)` (overview, client cards, attention lists, pipeline), `app.state_ledger_page(...)` (the blocks of his state, read-only, with the last chain check) |
| Left as it was | He still manages his state's scopes for records (record in a stage's place, withdraw, resolve a flag): FIX_LIST K62, for Veda |

## Tests

| Where | What | Count |
|---|---|---|
| `tests/23_identity_layer.sql` | tables, the move of existing people, seats, derived summary, direct writes refused | 53 |
| `tests/24_union_access.sql` | union of lenses, the manager-in-the-wrong-client trap, lapse, status | 67 |
| `tests/25_people_lifecycle.sql` | assign / move / end, suspend, offboard, re-hire, roles, seats, audit | 100 |
| `tests/26_onboarding.sql` | templates, checklist, last-four rule, auto-activation, HR files and the private store | 60 |
| `tests/27_daily_code.sql` | the code: issue, verify, tries, once a day, the switch | 28 |
| `tests/31_joiner_hr_data.sql` | fingerprints and duplicates, the target rule, bank warning and acceptance, masked images and their removal, PAN seen, Personal details, dependencies, due dates, first day, scrubbing (seven controls) | 71 |
| `tests/32_onboarding_at_scale.sql` | openings and their numbers, import (dry run, commit, re-upload), role checklists, invites (service only, one use, revoke), lists and filters, the gate and on paper, bulk acts, ready to assign, the Deputy, H2, H3, H7, direct writes refused (ten controls) | 99 |
| `tests/33_hr_geography.sql` | HR states, reach of an HR resource (records, lists, acts, files, openings, import), the base location, HR holds no seat, the Deputy's states (ten controls) | 53 |
| `tests/34_hr_admin_base.sql` | The admin sets the HR Admin's base location; not anyone else's while the seat is filled; nobody their own (failed without migration 40) | 12 |
| `tests/35_state_manager.sql` | the State Manager in his own state: crops, scopes, people and seats (also the direct path), farmers (create, read, two steps on every route), QC override, his overview and ledger, the counts (16 controls) | 73 |
| `tests/remote_create_user.mjs`, `tests/remote_rls.mjs --t1` | the same rules with real logins over the API (local stack) | 84 + 192 |
| `web/tests/identity.test.ts`, `functions.test.ts`, `id_numbers.test.ts`, `invite.test.ts`, `scale.test.ts` | number checks, checklist states, first screen, menu, session length; the six functions; the invite function (no token in any log); import dates and columns, list filters, bulk refusals, Hindi of the new words; no number in any request, answer or log of `id-numbers` | 29 + 33 + 52 |
| `tests/run_local.*` "upgrade path" | migrations 31 to 33 applied to a database already in use, then all 27 test files again | every run |
| `web/e2e/phase7.spec.ts`, `phase8.spec.ts`, `phase10.spec.ts`, `phase11.spec.ts` (205 joiners from a spreadsheet to 40 on a stage, at 527 px), `phase12.spec.ts` (HR by geography) | through the screens: a client set up from nothing; a joiner on a phone; directory, assign, lifecycle, state, seats, audit, the code; duplicates, masked images, the joiner's words, and a search of everything the stack wrote for the numbers typed | 3 + 8 + 4 |

All of the table above ran on the local stack. **On staging since 6 October 2026** (run-sheet part D, three runs of
`scripts/staging_phase5.ps1`; `docs/VERIFICATION_LOG.md`): migrations 31 to 33 on the database in use, the four
functions, seed 06 with its logins, the smoke check (30 of 30), the ledger audit, and the app. Not yet on staging:
anything done by a person through the screens (run-sheet part E), and the rules with real logins (step D12).
