# The Warehouse, release 8: migrations 55a and 55 and the app, onto the practice system

Veda, 16 October 2026, "yes proceed" (decision G19). Release 8 of the operator-stages plan. Item 50 in
`docs/FIX_LIST.md`. Releases 1 to 7 (migrations 48 to 54) are on staging since 16 Oct 2026, 03:56 (d4efafb); this
script expects **only migrations 55a and 55** waiting, in that order (55a adds the stage type alone: a new stage type is
used only after its own transaction).

- **The Warehouse (C3).** A stage chosen per scope when it is built, right after the entry stage or the Collection
  Batch, before any processing or the lab. **Arrival**: what was sent (opened with what the lot holds) and what was
  received, the difference worked out, a reason for any difference, and **above 2 % a flag** for the manager; the
  condition on arrival, the bags in, the warehouse or location and the stack. **Inspections** every N days (the
  scope's Client Manager sets N, 15 unless he does): the condition, the date, who; a stored lot shows **on time, due or
  overdue**, and "Needs my action" lists it. **Bags out** as they leave. **Days in storage** on the record and on the
  public page.
- **Stored but not recorded.** In a scope without a Warehouse, a lot waiting more than 15 days for Milling with
  nothing taken shows in the Client Manager's "Needs my action".
- **Veda's two points.** A domestic order no longer shows the export market, the destination country and the
  Incoterms. `Claude outputs/` is git-ignored: the practice PDF that release 7's commit carried leaves the repository
  (it stays in the folder on this computer).
- **Found while building it**: a link to the wizard's chain step put the draft back on that step after "Save draft".

**Only when Veda has said so.** This pushes migrations 55a and 55 to the practice database **and pushes to the main
branch**. Production is not touched. Nothing is changed or deleted. The server functions are unchanged (build
2026-10-14). Between S1 and S3 (a few minutes) the old app works as before; it does not offer the Warehouse yet.

**Scopes already active keep their chain** (it is frozen at activation): the checks below build a new practice scope
with a Warehouse.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-warehouse.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migrations 55a and 55 waiting (or only 55, if a run stopped after 55a); the functions current. **Asks you to type `WAREHOUSE`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migrations 55a, then 55 | a push fails (nothing of that migration is applied) |
| S1b | Reads back (read only): `warehouse_stage=new commercial_form=new stages=17 scopes=… warehouse_scopes=0 inspections=0 bags_out=0` | the read fails, the stage or the form is the old one, or a scope with a Warehouse, an inspection or bags out exist already |
| S2 | Smoke check **52** rows (new: `warehouse`; `stage_definitions (17)`), the new rules in place, the change log intact (**51** tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Takes `Claude outputs/` out of git (not off the computer), commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: WAREHOUSE ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser. Lucky holds every stage of Test Client
UP's scopes, so he can do each step himself.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Season Scopes → New: Test Client UP, KH26, place `Practice godown (test)`; Kalanamak; Chain: Procurement, **Collection Batch**, **Warehouse**, Milling before QC | the chain reads Procurement → Collection Batch → Warehouse → Milling → Quality Control → QR, "This chain is valid" |
| 2 | Lucky | Save draft → People: someone on every stage → Activate | the scope active; its stage settings show "Inspect stored lots every … days" (15) |
| 3 | Lucky | Stage settings: inspect every `1` day, Save | kept after a reload |
| 4 | Procurement | Two lots at the farm gate (practice farmers, Practice village (test)) | two P records |
| 5 | Collection Batch | A batch of the two lots | a VB record |
| 6 | Warehouse | Check the batch in → Record Warehouse: Sent is the batch's weight already; Received about 3 % less | "Say why … kg less was received than sent"; with a reason it saves; the record says "flagged for the manager" |
| 7 | Same | Condition Good, Bags in `4`, location `Practice godown (test)`, stack `S-1` (on the form of step 6) | on the record: the difference in kg and %, the place and the stack |
| 8 | Lucky | Flags | the flag "Warehouse: received … kg, … % less than was sent …", with the reason |
| 9 | Warehouse | The WH record → In the warehouse: 0 days, 4 in · 0 out · 4 left; Record an inspection: Minor deterioration | Save stays off until "What was found" has 5 letters; then listed with the date and who |
| 10 | Lucky | Home → Needs my action | "WH-…: inspection due by …" (every 1 day) |
| 11 | Milling | Check the stored lot in; its record → Record bags out: `5`, then `4` | 5 refused (only 4 came in); 4 saved: 4 in · 4 out · 0 left |
| 12 | Milling | Record Milling from the stored lot | its record; the WH record: nothing left in storage |
| 13 | Commercial | KH26 Bansi, a packed lot (PK-0001) → Record Commercial Clearance, Market Domestic (then Cancel) | no Export market, Destination country or Incoterms; with Export they come back |

Clean-up: the practice scope and its records stay (named "(test)"); the interval can be put back to 15.

Not checked on staging (the tests cover them): "stored but not recorded" (it needs a lot waiting 15 days:
`tests/49_warehouse.sql` §7) and the days in storage on the public page (a sealed lot: `tests/49` §8).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 55a adds the stage type; migration 55 adds the Warehouse to the stage list,
two tables (`warehouse_inspections`, `warehouse_bags_out`, each with its change log and read rule), a column
(`scopes.warehouse_inspection_days`), a trigger and functions, and marks three fields of the Commercial form "export
only". Scopes already active keep their chain; records of before keep what they have. A scope that should not have a
Warehouse is closed and a new one opened without it.
