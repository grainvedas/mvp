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
| `employee_docs` | `public.employee_docs` (last four characters) + `public.employee_files` (documents in the private store `hr-docs`) | Decision: masked + files |
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
| Identity and bank numbers | Masked + files | The full number is checked on the person's own device (PAN format, Aadhaar check digit, IFSC) and only its last four characters are sent and stored. Documents go to a private store only HR and the admin can open |
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

## Server functions (four, one build)

`create-user` (joiner or client login; the login is made with the service key, linked, and taken back on any failure),
`reset-password`, `ledger-check`, `daily-code` (new). All carry `VERSION = '2026-10-06'`; the app needs that build
(`FUNCTIONS_NEEDED`) and says so on the Add joiner page when the server is behind. Mail (the invite note, the sign-in
code) goes through one sender setting (`MAIL_API_URL`, `MAIL_API_KEY`, `MAIL_FROM`); **none is set on any hosted
project**, so no mail is sent: HR hands over the temporary password in person, as before, and the code stays off.

## Tests

| Where | What | Count |
|---|---|---|
| `tests/23_identity_layer.sql` | tables, the move of existing people, seats, derived summary, direct writes refused | 53 |
| `tests/24_union_access.sql` | union of lenses, the manager-in-the-wrong-client trap, lapse, status | 67 |
| `tests/25_people_lifecycle.sql` | assign / move / end, suspend, offboard, re-hire, roles, seats, audit | 100 |
| `tests/26_onboarding.sql` | templates, checklist, last-four rule, auto-activation, HR files and the private store | 60 |
| `tests/27_daily_code.sql` | the code: issue, verify, tries, once a day, the switch | 28 |
| `tests/remote_create_user.mjs`, `tests/remote_rls.mjs --t1` | the same rules with real logins over the API (local stack) | 84 + 192 |
| `web/tests/identity.test.ts`, `functions.test.ts` | number checks, checklist states, first screen, menu, session length; the four functions | 29 + 33 |
| `tests/run_local.*` "upgrade path" | migrations 31 to 33 applied to a database already in use, then all 27 test files again | every run |
| `web/e2e/phase7.spec.ts`, `phase8.spec.ts` | through the screens: a client set up from nothing; a joiner on a phone; directory, assign, lifecycle, state, seats, audit, the code | 3 + 8 |

All of the table above ran on the local stack. **On staging since 6 October 2026** (run-sheet part D, three runs of
`scripts/staging_phase5.ps1`; `docs/VERIFICATION_LOG.md`): migrations 31 to 33 on the database in use, the four
functions, seed 06 with its logins, the smoke check (30 of 30), the ledger audit, and the app. Not yet on staging:
anything done by a person through the screens (run-sheet part E), and the rules with real logins (step D12).
