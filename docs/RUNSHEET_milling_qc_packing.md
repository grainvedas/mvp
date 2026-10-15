# Milling, Quality Control and Packing, release 6: migration 53 and the app, onto the practice system

Veda, 15 October 2026, "ok proceed ahead with release 53" (decision G19). Release 6 of the operator-stages plan. Item
48 in `docs/FIX_LIST.md`. Releases 1 to 5 (migrations 48 to 52b) are on staging since 15 Oct 2026, 22:55 (a231413);
this script expects **only migration 53** waiting.

- **Milling (C4).** The mill from the client's list (Set-up lists), how the line was cleared (fully cleaned, a quick
  clean, or its previous run was this crop; recorded by itself at a mill dedicated to the crop), the mill operator.
  **Head rice, broken, husk and bran** are typed; the loss and the recovery are worked out (never typed, never below
  0); "sent from the lot" when the mill is elsewhere gives the loss on the way. Head rice goes forward. No fixed
  threshold: above the crop's ceiling the State Manager is told; after enough verified runs, outside **this mill's**
  usual range is a warning. Milling records of before keep their rice out, bran and loss.
- **Closing a lot.** A lot with **2 % or less** left (or the crop's auto-close weight) is closed by the stage that took
  it, or a manager, with a reason: the rest is floor loss (lot record, "Close the lot").
- **Quality Control (C5).** The sample is drawn **first**, on the verified lot (the QC screen, after "Verify this lot";
  and the lot's record): quantity, the lab from the **state's list**, the retained counter-sample's seal number and
  where it is stored, a buyer's sample if any; kept 12 months unless a date is given. It shows "sent to the lab,
  awaiting results". The lab record then **chooses that sample** (no sample quantity or lab name typed) and the sample
  becomes "results in". A lab test (aflatoxin and the like) is read at an accredited **external** lab, never in-house.
  The lab record shows a **verdict per market** of the scope. An export release names **who at the client accepted
  it, their title and the date**.
- **Packing (C6).** The packing unit from the client's list; the packs **from the client's pack list** (each keeps its
  own size); the wastage worked out, with a reason above the crop's limit (2 % unless set); best-before by the pack's
  material. **Net weight check**: the system picks 5 packs; each is weighed in grams against the allowed error (Legal
  Metrology); the packing record is verified only once they pass (export packs and packs of 5 kg or less).
  Commercial ticks "Pack count per size matches the packing record".
- **The scope's settings** (scope page, "Milling, Quality Control and Packing"): ask the mill, sample and lab, packing
  unit and packs from the lists (**on in every scope**, also those already there; the Client Manager can turn it
  off), and which markets QC judges against.
- **The public page** shows the lab's verdict per market.
- **Fixed from the checks of release 5**: the menu line "Collection Batch (one collection point)" no longer runs into
  the next line on a laptop.

**Only when Veda has said so.** This pushes migration 53 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is changed or deleted. The server functions are unchanged (build 2026-10-14).
Between S1 and S3 (a few minutes) the old app cannot record Milling, nor QC or Packing in a scope that asks the stage
details: wait for S3.

**Before the checks below**, every scope asks the stage details: QC needs a lab on Uttar Pradesh's list, Milling a mill
and Packing a packing unit and packs on the client's lists (Set-up lists). Until they are there, those stages say so;
the Client Manager can untick the setting on the scope page to work as before.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-milling-qc-packing.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 53 waiting; the functions current. **Asks you to type `PACKING`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 53 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `scopes=… asking_details=… markets=… milling_form=new qc_form=new packing_form=new samples=0 market_verdicts=0 closed_lots=0 weight_checks=0` | the read fails, a form is the old one, or a sample, verdict, closure or weight check exists already |
| S2 | Smoke check **50** rows (new: `milling qc packing`), the new rules in place, the change log intact (**46** tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: MILLING QC PACKING ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser. A scope whose chain has Quality
Control, Milling and Packing (KH26 Bansi if its chain has them; otherwise the practice scope that does).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | The menu on a laptop | "Collection Batch (one collection point)" on two lines, not over the next one |
| 2 | Lucky | The scope page → "Milling, Quality Control and Packing" | "Ask … from the lists" ticked; Domestic and Export ticked |
| 3 | Ram (State Manager) | Set-up lists → Labs: `Practice lab (test)`, external, accreditation `TEST-0001`, Lucknow | on the list |
| 4 | Lucky | Set-up lists: a mill `Practice mill (test)`, a packing unit `Practice packing (test)`, packs 1 kg pouch and 500 g pouch | on the lists |
| 5 | QC person | A verified lot (e.g. VB-0001): Verify, then **Draw a sample** (1 kg, the practice lab, seal `CS-TEST-1`, "QC shelf") | "sent to the lab, awaiting results" |
| 6 | Same | Record Quality Control: choose the sample; readings | no sample quantity or lab name to type; the record shows a verdict per market; the sample says "results in" |
| 7 | Milling person | Verify the lab lot; Record Milling: the practice mill, line fully cleaned, an operator; head rice, broken, husk, bran a little less than the paddy in | the loss and the recovery worked out; head rice goes forward |
| 8 | Same | The lab lot's record, when 2 % or less is left | "Close the lot" with a reason: floor loss |
| 9 | Packing person | Verify the milling lot; Record Packing: the practice unit; packs 1 kg and 500 g | the wastage worked out; above 2 % it asks why |
| 10 | Same | The packing record → **Net weight check**: pick, weigh one short (40 g under) | "Failed"; weighed right: "Passed" |
| 11 | Commercial person | Verify the packs | "Pack count per size matches the packing record" to tick; before the check passes it refuses |

Clean-up: the practice lists stay (named "(test)"); untick "Ask … from the lists" on a scope that should work as before.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 53 adds the tables `qc_samples`, `qc_profile_verdicts`, `lot_closures` and
`net_weight_checks` (each with its change log and read rule), columns (scopes: `stage_details_required` on,
`market_codes` Domestic and Export; packs: `sku_id`), triggers and functions; the Milling, Quality Control and Packing
forms in the stage list are updated. Records already made keep what they have (Milling of before: rice out, bran,
loss; Packing of before: typed sizes and wastage). To stop asking the stage details in a scope, its Client Manager
unticks it on the scope page.
