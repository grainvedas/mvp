# Commercial and Shipment, release 7: migration 54 and the app, onto the practice system

Veda, 16 October 2026, "continue with release 54" (decision G19), with her four points on release 6's checks. Release 7
of the operator-stages plan. Item 49 in `docs/FIX_LIST.md`. Releases 1 to 6 (migrations 48 to 53) are on staging since
16 Oct 2026, 00:59 (a49f01e); this script expects **only migration 54** waiting.

- **Commercial (C7).** The buyer **from the client's list** (Set-up lists, Buyers), the order or contract number, the
  sale route (own brand, white label, bulk, Prasaadam). An export sale names its **market's profile** (the batch passed
  QC for it, or the client accepted it in writing) and the destination country. A batch packed from the pack list is
  sold **by packs, per pack type**, from what is left of it; the kilograms are worked out. The **price, currency and
  Incoterms** (where the scope records prices) are kept apart from the record and its ledger: who recorded them and
  the client's Client Manager read them. An export order keeps the **documents its market asks** (the profile's list):
  each received with its file, applied for, or not required with why.
- **Shipment (C8).** The packs of one order (an order may go in several shipments) and the invoice number.
  **Domestic**: the vehicle number (UP53AB1234), the LR number, the transporter, the driver's phone, the e-way bill.
  **Export**: the container (4 letters, 7 digits) and its seal, the shipping bill (6 to 8 digits), the vessel, ports,
  the **pack codes scanned** (one per line: of that batch, each once, as many as the packs), the **loading photo**
  (before it is verified), and the **bill of lading**, also after the ship sailed (the shipment's record, once). An
  export order ships only once its documents are complete.
- **Veda's four points.** (1) A farmer's **village is picked from the list** (Set-up lists, Places): a farmer is
  verified only in a village on it; farmers already verified keep theirs. (2) The **Collection Batch names its
  collection point** first and is offered only that point's lots. (3) At the farm gate the farmer is picked **by his
  village, then from that village's farmers** (two lists; still on the phone without a network). (4) The **client keeps
  labs of its own** (Set-up lists, Lists, Labs, by the Client Manager), offered to QC beside the state's labs.
- **Fixed from the checks of release 6**: the batch's system check "Village named" is now "Villages taken from the lots";
  a milling run shows "Recovery" once (no "Yield" beside it); a market profile's own test shows each market's limit on
  the lab form (no "<= undefined").

**Only when Veda has said so.** This pushes migration 54 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is changed or deleted. The server functions are unchanged (build 2026-10-14).
Between S1 and S3 (a few minutes) the old app cannot record Commercial, Shipment or a Collection Batch in a scope that
asks the stage details: wait for S3.

**Before the checks below**: a new farmer is verified only in a village on Uttar Pradesh's list, so the villages people
register farmers in are added first (Set-up lists, Places: district, block, village). Commercial needs a buyer on the
client's list (Set-up lists, Buyers); an export order needs the scope's market profile for export.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-commercial-shipment.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 54 waiting; the functions current. **Asks you to type `SHIPMENT`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 54 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `commercial_form=new shipment_form=new batch_form=new villages=… state_labs=… client_labs=0 draft_farmers=… sale_terms=0 export_documents=0 bills_of_lading=0` | the read fails, a form is the old one, or a client lab, sale terms, a document or a bill of lading exists already |
| S2 | Smoke check **51** rows (new: `commercial shipment`), the new rules in place, the change log intact (**49** tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: COMMERCIAL SHIPMENT ON STAGING` or `RESULT: STOPPED`.

`draft_farmers` in S1b is how many farmers are still drafts: each is verified only once his village is on the list.

## Afterwards (about 40 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser. KH26 Bansi (its chain has Commercial
and Shipment), from the verified packing record PK-0001 (1 kg and 500 g packs).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Set-up lists → Places: Siddharthnagar, a block `Practice block (test)`, a village `Practice village (test)` | the village under its block |
| 2 | Lucky | Farmers → New: the district, the block, the village **from the lists** | no typing for the village; "Add a village" leads to Places |
| 3 | Lucky | Set-up lists → Lists → **Labs**: `Practice client lab (test)`, external, accreditation `TEST-0002`, Basti | on the list, "client's own" in QC's lab list |
| 4 | Lucky | Set-up lists → Buyers: `Practice buyer (test)` (IN, a test GSTIN, an address) and `Practice export buyer (test)` (NL, an address) | on the list |
| 5 | Procurement person | Record a lot | a village first, then the farmer of that village |
| 6 | Collection Batch person | New Collection Batch | the collection point first; only its lots are offered |
| 7 | QC person | A lot to draw a sample from → Draw a sample | the lab list has the state's labs and the client's lab |
| 8 | Commercial person | PK-0001 → Record Commercial Clearance: the practice buyer, Domestic, an order number `PO-TEST-1`, own brand, 10 × 1 kg and 4 × 500 g, a price | 12 kg worked out; the record shows the packs; the price only on its own card |
| 9 | Same | Another order: the export buyer, Export, its market, Netherlands, `EX-TEST-1`, 10 × 1 kg, USD, FOB | the record lists the export documents of its market (if the profile names any): one received with a test file, the others "not required" with why |
| 10 | Shipment person | Verify the domestic order; Record Shipment: the packs, `UP53AB1234`, `LR-TEST-1`, invoice `INV-TEST-1`, dispatch date, destination | only the domestic papers are asked |
| 11 | Same | Verify the export order; Record Shipment: the packs, container `MSKU1234567`, seal `SL-TEST-1`, shipping bill `1234567`, the pack codes of 10 packs (Packs and labels of PK-0001), a loading photo | with 9 codes it says the codes do not match; with 10 it saves; "Bill of lading still to come: Yes" |
| 12 | Same | The export shipment's record → Bill of lading `MAEU0000001` | added once; "still to come: No" |
| 13 | Anyone | VB-0001's arrival check at QC (or its record) | "Villages taken from the lots" ticked |
| 14 | Mill person | M-0001's record | "Recovery" once, no "Yield" beside it |

Clean-up: the practice lists stay (named "(test)"); the orders and shipments are practice records.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 54 adds the tables `sale_terms`, `export_documents` and `bills_of_lading`
(each with its change log and read rule), a column (`labs.client_id`), triggers and functions; the Commercial, Shipment
and Collection Batch forms in the stage list are updated, and demo villages are added only to the demo seed (not to
staging). Records already made keep what they have (a sale of before: a typed buyer and kilograms; a shipment of
before: vehicle or container and kilograms). To work as before in a scope, its Client Manager unticks "Ask … from the
lists" on the scope page (the buyer is typed and the kilograms are given again); the village list stays.
