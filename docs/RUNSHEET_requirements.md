# HR requirements and staffing a scope: migration 46 and the app, onto the practice system

Veda, 14 October 2026: *"GrainVeda MVP — HR requirements list and staffing a scope"* (it replaces section B of the
follow-up brief, before the Operator role review). Item 41 in `docs/FIX_LIST.md`. What changes:

- **Requirements**: a need for people is raised once, in lines (role, stage, how many, posting, needed by, note).
  A scope's empty stages become lines when its Client Manager saves the **People step**; a client with no Client
  Manager gets a line in the State Manager's name; the Client Manager (his scope) and the State Manager (his state) ask
  for more with **Request people**. Statuses: Requested, Returned (HR's question), On hold, Published, Joining, Ready to
  assign, Filled, Withdrawn, Declined. A stage staffed from the pool closes its line by itself ("filled from the pool");
  a stage taken out of the chain withdraws it. Every change is a line in the Audit log.
- **HR's queue**: **Requirements**, first in HR's menu with a badge, and "N new requirements · oldest X days" on her
  Joiners page. Grouped state → client → scope, with filters. **Publish** (the number and date can be corrected first:
  logged), **Return** (a question), **Decline** and **Hold** (a reason). Publishing a scope's lines in one act makes
  **one opening** for the scope, a line per stage, "From requirement by Lucky", linked back to the lines. HR sees her
  states; the HR Admin all. Add joiner and Import offer only open openings with a vacancy (as since Release 4).
- **The Client Manager**: on the People step and the Roster, each empty stage with its line's status; people HR has
  made ready for the scope come first in the pool ("ready for Milling"); the list of what stops activation links to
  each stage's status. **The State Manager's home**: the open requirements by client, and Request people.
- **Openings** grouped state → client → scope with subtotals; each says where it came from. **UP-OPR-002 … 007 are
  left as they are and read "Created by HR"** (not merged: Veda's choice in the brief). A new opening can start from
  a scope (it fills the state and the client) and cover several of its stages at once.
- **One person on several stages, also two in a row** (Veda's decision): allowed. The roster says, for example, "p also
  holds Procurement (farm-gate). At Milling he will verify his own procurement records." He then verifies his own
  record: the ledger shows the stage he acted as and marks it **same person, next stage**; the public page says "Some
  steps of this lot were recorded and checked by the same person. The full record is kept in the ledger."; the State
  Manager's home and the scope's Roster count it.
- **Brief F**: a reopened draft opens on step 4 (People); the step names are links; "Save draft → People" moves to
  step 4 or shows the server's words; the Roster of a draft shows whether it can be activated, with **Activate**.

**What the migration does to the data that is there**: it raises the requirements of every draft and active scope's
empty stages (TCUP KH26 gkp's five empty stages become five **Requested** lines in Lucky's name) and of every client
with no Client Manager (in the State Manager's name). Nothing is changed or deleted; the openings get a "source" of
"Created by HR".

**Only when Veda has said so.** This pushes migration 46 to the practice database **and pushes to the main branch**.
Production is not touched. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-requirements.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 46, the smoke check, the ledger audit, the anchor script and its schedule, and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 46 waiting; the functions current. **Asks you to type `REQUIREMENTS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 46 | the push fails (nothing of it is applied) |
| S1b | Reads back what the migration raised: requirements for scopes and clients, Requested lines, openings "Created by HR" (read only) | the read fails |
| S2 | Smoke check **43** rows (new: `requirements`), the requirements in place and the change log intact, the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: REQUIREMENTS ON STAGING` or `RESULT: STOPPED`. Record: `release-evidence\staging-requirements-<time>.log`.

**Then check Vercel built it**: Deployments must show the new commit as **Ready** within about 5 minutes. If not: the
`…` menu → **Create Deployment** → `main`. `staging-safeguards.cmd` has done its job; it now refuses to run.

## Afterwards (about 20 minutes, phone width)

Practice data: steps 4–9 write requirements and openings on the practice system (Veda's OK first, as before). Use the
`TEST` prefix in notes; nothing needs cleaning up afterwards except closing the `TEST` openings (step 10).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Neha (HR, Uttar Pradesh) | her menu | **Requirements** first, with a badge; Joiners shows "5 new requirements · oldest 0 days" (or more, if other scopes have empty stages) |
| 2 | Neha | **Requirements** | Uttar Pradesh → Prasaadam → Kalanamak rice · KH26 · gkp: **5 lines, Requested**, raised by Lucky |
| 3 | Lucky (Client Manager) | Season Scopes → KH26 gkp | opens on **4 People**; under the roster, "People asked from HR": five stages, **Requested**; the missing-stages list links to each |
| 4 | Lucky | give **p** Procurement, then Packing, from the pool | both allowed; the note "p holds several stages here: Procurement (farm-gate), Packing."; Procurement's line reads **Filled** (it leaves the list) |
| 5 | Lucky | Request people → Operator · Milling · 2 · note `TEST second shift` → Send to HR | "Also asked: 2 × Operator · Milling" Requested |
| 6 | Neha | Requirements → the `TEST second shift` line → **Return**: "TEST two, or one for two shifts?" | Returned, with her question |
| 7 | Lucky | that line → **Answer**: "TEST two" | Requested again |
| 8 | Neha | **Publish the scope (N lines) as one opening** | "Opening made: UP-OPR-008, …"; **Openings**: one group under KH26 gkp, "one opening · N stages", each "From requirement by Lucky"; UP-OPR-002 … 007 "Created by HR" |
| 9 | Lucky | KH26 gkp → Roster | each empty stage **Published** with its opening code |
| 10 | Neha | Openings → the openings of step 8 → **Close** (practice data) | closed; the lines stay Published (history) |
| 11 | Ram (State Manager) | his home | **Open requirements** by client, KH26 gkp's lines among them |
| 12 | Lucky | KH26 gkp: every stage given, then **Activate** on the Roster (527 px) | Activate, confirm; the scope is Active |

Claude can drive Chrome for these once each person has signed in.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 46 adds two tables (`requirements`, `requirement_lines`), five columns on
`openings`, triggers that keep the lines in step with the scopes, functions, and replaces nine functions (the
verification rule, the public page, the two ledger pages, the assignment warning, `set_stages`, the roster pool,
`opening_json`, the State Manager's home and the scope's roster). To stop the lines raising themselves, an owner drops
the four `zy_requirements` triggers. Ask before changing anything back.

## Rehearsed

On the local stack, 14 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (test 40: 68 checks, 17
controls; the older tests updated for the two-stages rule and the new keys), the unit tests, the screen suite with
`phase18` at 527 px (brief F, and A–E end to end), the production build. Not rehearsed: the hosted project, Windows
PowerShell 5.1, the staging data's own scopes (KH26 gkp's five lines are counted by S1b and checked in step 2).
