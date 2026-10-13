# The crop registry: migration 42 and the app, onto the practice system

Veda, 13 October 2026, "GrainVeda MVP — State Manager role", part C (Release 2 of three), and her answers the same
day. Open item 37 in `docs/FIX_LIST.md`. What changes:

- **A crop belongs to one state.** The same crop grown in another state is that state's own entry: the crop code is
  unique within a state (Bihar may have its own `KNM`).
- **A crop is READY** when it has a unit, a **yield per acre**, at least one quality limit and a **recommended chain**.
  The Client Manager can activate a scope only with a ready crop; the wizard shows a crop that is not ready but does not
  let him pick it, and starts the chain from the crop's recommended one. Harvest window, practices and export documents
  are optional.
- **Typed quality limits**: a number (≤, ≥, as before), a **grade** picked from a list with the passing grades marked
  (domestic and export apart), or **yes/no** (e.g. "live insects: no"). The lab form, the verdict before saving, the
  saved verdict and the record follow the type. Limits made before stay numbers.
- **Good farming practice (GAP)**: the State Manager lists the practices for his crop (yes/no, date, number, text or
  choice; required or optional). The Client Manager (or Procurement) answers them on the **farmer's page**, per crop.
  At Procurement a **required** practice not answered **refuses** the farmer's lot; an optional one is saved as a
  **warning** on the lot.
- **Harvest window** (from month to month): a lot bought outside it is saved with a warning.
- **Export documents**: a list on the crop (for the export work to come).
- **The admin's acts on a crop added by mistake**: **remove** it while nothing uses it; **retire** one in use (kept, hidden
  from new scopes; the scopes that use it go on); **correct the state** of one nothing uses yet. Each needs a reason and
  is flagged in the Audit log.
- **Small fix**: the State Manager's ledger lists everyone who signed his state's blocks under "Signed by" (Minal was
  missing).

**Only when Veda has said so.** This pushes migration 42 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten (removing a crop is the admin's own act, later, in the app).
The server functions are unchanged.

**What it means right after the run:** Kalanamak on staging has no yield per acre and no recommended chain yet, so it is
**Not ready**: no scope can be activated with it until Ram completes it (step 1 below). Staging has no scope yet, so
nothing stops.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-crop-registry.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 42, the smoke check, the ledger audit and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 42 waiting; the functions current. **Asks you to type `CROP REGISTRY`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 42 | the push fails (nothing of it is applied) |
| S2 | Smoke check **38** rows (new: `crop registry`), the new rules in place, the ledger audit, logins, functions. Then: how many crops, how many not ready, how many without a state | a row or a check is not `OK` (the two pg_cron rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CROP REGISTRY ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-crop-registry-<time>.log`: send it to Claude.

**Then check Vercel built it** (on 13 Oct it missed the push): Vercel → project `mvp` → Deployments must show the new
commit as **Ready** within about 5 minutes. If not: the `…` menu at the top → **Create Deployment** → `main` →
**Deploy to Production**. `staging-state-manager.cmd` has done its job; it now refuses to run.

## Afterwards, in the app (about 20 minutes, made-up data only)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram | **Crops** → Kalanamak → **Edit**: yield per acre (e.g. 1000), **Start from the shortest chain** (or tick the stages), harvest window Oct–Dec; a practice "Seed source", Choice, options `certified, farm_saved`, **Required**; Save | The card says **Ready**; his overview's checklist ticks "crops" |
| 2 | Ram | Add a limit of type **Grade from a list** "Aroma", grades `A, B, C`, domestic passes A and B, export A; and **Yes / no** "Live insects", passes when "no" | The card lists "Aroma A, B / A", "Live insects no / no" |
| 3 | Ram, on a phone | **Crops** | One card per crop, no side-scrolling |
| 4 | the Client Manager (once Ram has given one) | **Season scopes → New scope** → crop | Kalanamak offered; the chain starts as Ram's recommended chain |
| 5 | the Client Manager | A farmer's page → **Good farming practice** | "Seed source" marked required, "Not answered yet"; answer it → Save → "Every practice is answered" (or the optional ones listed) |
| 6 | Procurement | A lot for a farmer whose required practice is open | Refused: "good farming practice not complete for this farmer" |
| 7 | Procurement | A lot for the farmer of step 5 | Saved; outside Oct–Dec it carries "outside the harvest window" |
| 8 | the lab | The lab record of that lot | Aroma is picked from A/B/C, Live insects yes/no; the verdict before saving follows them |
| 9 | Veda (admin) | **Crops** → a crop added by mistake (make one as Ram first, e.g. `TEST`) → **Remove**, reason | Gone; Audit log "removed the crop", flagged |
| 10 | Veda | **Crops** → a crop in use → only **Retire** (no Remove) | — (do not retire Kalanamak) |
| 11 | Ram | **Ledger** → Signed by | Lists Minal (she signed his state's seat blocks) |

Steps 4 to 8 need a Client Manager and a scope; they wait for that (open item 36, checks 4 and 8–10).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 42 adds columns to crops, a table (`farmer_gap`), functions and rules,
replaces the crop code's country-wide uniqueness by uniqueness within a state, and changes the lab's verdict functions
to judge by type (the versions it replaced are in migrations 2 and 29). Ask before changing anything back.

## Rehearsed

On the local stack, 13 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (with the upgrade path; test 36
with 15 controls), the API tests, the unit tests, the screen suite with `phase14` at 527 px, the first day from nothing
(the crop made ready on screen), the production build. The script on stand-ins (PowerShell 7 on Linux). Not rehearsed:
Windows PowerShell 5.1, the hosted project, a real phone.
