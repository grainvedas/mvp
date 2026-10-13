# The State Manager: migration 41 and the app, onto the practice system

Veda, 13 October 2026, "GrainVeda MVP — State Manager role" (Ram is the Uttar Pradesh State Manager). Release 1 of
three: parts A, B, E and F of the brief, and the crop's state. Open item 36 in `docs/FIX_LIST.md`. The role, as decided:

- **The State Manager owns one state.** He keeps its crops, onboards its clients, gives each client its Client
  Manager, verifies farmers after the Client Manager, and watches everything in his state. He does not build scopes,
  hire, touch other states or override records. The database refuses each of these, not only the screen.
- **Crops have a state.** A State Manager adds and edits only his state's crops. An existing crop has no state yet:
  the first State Manager to save it sets it to his state, once (the Audit log records it).
- **Season scopes are built by the Client Manager.** A new scope is in its client's own state (existing ones are kept).
  The State Manager reads them.
- **Farmers are added by the Client Manager** (by hand or from Excel) and by Procurement and Village Batch; the
  Client Manager verifies first, the State Manager of the farmer's state after him. Nobody skips the Client Manager.
- **People & access** shows him only his state's people (no admin, no HR). **States** and **Health** are the admin's.
- **His home is his state's overview**: "Uttar Pradesh overview · State Manager · Ram", his guide and a checklist that
  ticks itself, four figures (My clients, Active scopes, Needs my action, QR issued), the clients with no Client Manager
  with a button to give one, client cards that open read-only, the stages with nobody. Also **Pipeline** and the
  **Ledger of his state** (read-only, with the last check of the whole chain). His menu: Watch, Audit, Master data,
  Access, Me. Every new word in English and Hindi; every screen at phone width.

**Only when Veda has said so.** This pushes migration 41 to the practice database **and pushes to the main branch**,
from which Vercel builds the staging app. Production is not touched. Nothing is deleted or rewritten. The server
functions are unchanged.

## Before the run

Nothing. (The run lists, after the push, what is left to set up.)

## One double-click (about 3 minutes, then a few minutes for Vercel)

Double-click **`staging-state-manager.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 41, the smoke check, the ledger audit and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 41 waiting; the functions current. **Asks you to type `STATE MANAGER`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 41 | the push fails (nothing of it is applied) |
| S2 | Smoke check **37** rows (new: `state manager rules`), the new rules in place, the ledger audit, logins, functions. Then **what is left to set up**: crops with no state, clients with no Client Manager, scopes outside their client's state (old ones, kept) | a row or a check is not `OK` (the two pg_cron rows are listed but do not stop it) |
| S3 | Commits and pushes the app (Vercel builds it) | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: STATE MANAGER ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-state-manager-<time>.log`: send it to Claude.

Between S1 and the end of the Vercel build (a few minutes) the old app still offers the State Manager buttons the
database now refuses (New scope, New farmer): he gets "Not allowed". `staging-hr-admin-base.cmd` and the earlier
scripts have done their job; they now refuse to run.

## Afterwards, in the app (about 20 minutes, made-up data only)

Ram needs a State Manager seat for Uttar Pradesh. If he has none yet: HR adds him, the HR Admin gives the seat
(People & access → Ram → Assign → State Manager → Uttar Pradesh). Use names starting `TEST`.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram, on a phone | Sign in | "Uttar Pradesh overview · State Manager · Ram"; the guide with 5 steps; four figures; no side-scrolling |
| 2 | Ram | The menu | Watch, Audit, Master data, Access, Me. No **States**, **Health** or **State overview**. Typing `/states` or `/health` brings him home |
| 3 | Ram | **Crops**: each crop of Uttar Pradesh that says "State not set" → **Edit** → **Save** | It now shows "Uttar Pradesh". **Only crops grown in Uttar Pradesh**: the save sets his state for good. A crop of another state waits for that state's manager |
| 4 | Ram | **Needs my action** → the client with no Client Manager → **Give … a Client Manager** | People & access opens, filtered to that client |
| 5 | Ram | **People & access** | Only Uttar Pradesh people; not Veda, Minal or Neha. The State filter offers only Uttar Pradesh |
| 6 | Ram | **Season scopes** | "read-only" note; no **New scope**; a scope opens read-only |
| 7 | Ram | **Farmers** | No **New farmer**, no **Import**; his first tab is **Ready to verify** |
| 8 | The Client Manager of a UP client | **New farmer** `TEST Farmer` → save → verify (step 1) | It goes to "Ready to verify" |
| 9 | Ram | **Farmers** → that client → `TEST Farmer` → verify | A Farmer ID is issued |
| 10 | The Client Manager | **Season scopes → New scope** | The state is shown as the client's own, not a choice |
| 11 | Ram | **Ledger** | "Ledger of your state", the last check line, no "Run a check" button; **Export** works |
| 12 | Veda (admin) | **Audit log** | "set the state of the crop" lines for step 3 |
| 13 | Ram | Language → हिन्दी | The overview, the guide and the menu in Hindi |

`TEST Farmer` stays as a record (nothing is deleted); the Client Manager may archive it.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 41 adds a column (`crops.state_id`), functions and rules, and changes read
and write rules and functions to ask about the state (the versions it replaced are in migrations 33 to 40). A crop's
state, once set, is kept. Ask before changing anything back.

## Rehearsed

On the local stack, 13 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (35 files, with the upgrade path;
test 35 with 16 controls), the API tests, the unit tests, the screen suite with `phase13` at 527 px, the first day from
nothing, the production build. The script on stand-ins (PowerShell 7 on Linux). Not rehearsed: Windows PowerShell 5.1,
the hosted project, a real phone.
