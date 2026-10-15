# GrainVeda MVP — Operator stages (all eight stages, one template)

> Veda's brief, as given on 15 Oct 2026 (decision G19: nine releases, migrations 48–56). Kept here verbatim so the
> plan does not depend on a chat. What is built, release by release: `docs/FIX_LIST.md` items 43 on, and the coverage
> table at the end of this file.

This brief comes from a full run of the operator flow on build `mv7mnlkg` (14–15 Oct 2026). The product owner (Veda) ran it as Lucky (Client Manager), who held every stage of a new scope, "Kalanamak Rice · KH26 · Bansi":

Procurement → Village Batch → Milling → QC → Packing → Commercial → Shipment → QR.

The run was compared with the prototype (`GrainVeda_Platform_v1.html`). Afterwards the owner decided each stage in detail. **Every decision below is final unless marked "Owner decides".**

It covers:

- **Part A:** the stage template that every operator stage shares. Fix it once and every stage gets it.
- **Part B:** the set-up lists the stages need.
- **Part C:** each stage.
- **Part D:** packs, labels, QR codes and the public page.
- **Part E:** farmer-level traceability and GI status.
- **Part F:** sharing a shipment with a buyer.
- **Part G:** the bugs found in the run.

This is large. Do **not** build it in one go.

## Start by reading, then tell me your plan

Before changing anything, reply with:

1. **A phased plan.** My suggested order:
   - **Phase 1, trust and correctness:** Part A, Part G, the batch code, unique pack codes, GI status, report proof, and the blocks.
   - **Phase 2, set-up lists and richer stage fields:** Parts B and C.
   - **Phase 3:** Warehouse, buyer link, scan analytics, delivery confirmation.

   Change the order if the code suggests a better one, and say why.
2. **Conflicts** between this brief and the code or data model, especially for Part E (farmer shares through merges and splits).
3. **Migration notes:** how existing records (the gkp, Siddharthnagar and Bansi scopes) are treated. Use additive changes only.

## Part A — The stage template (every stage)

Today each stage page has steps 1–8 (Look up · Arrival · Verify · Form · Maths · Review · Save · Handoff). Keep that shape and fix the following for all stages.

1. **Return, not only Verify.**
   - Checking an incoming lot offers only "Verify this lot". Add **Return to sender** with a reason (required, at least 10 characters). The returned record goes back to its creator, who corrects and resubmits. Keep the history.
   - The prototype had Approve / Conditional / Reject with a query. Build Approve and Return now. Conditional: **Owner decides**, propose it.
2. **The system checks what it can check.**
   - The handoff checklist asks people to tick things the app already knows, e.g. "Documents attached" (ticked in the run although no document was attached), "Σ packets + wastage = input", "Batch code assigned".
   - The app checks these itself and shows them as ✓ or ✗.
   - The person ticks **only physical facts**, e.g. "bags counted and match", "seal intact", "condition as described".
3. **Remaining quantity everywhere.**
   - After a partial use (two milling runs, a split sale), the waiting list still shows the original quantity, e.g. VB-0001 "1,885.2 kg" after 1,200 kg was milled.
   - The form also pre-fills the original quantity. Show and pre-fill **what is left**.
4. **Plain error messages.**
   - Today: "The database will refuse this: qty_in 1885.200 exceeds available 685.200 on predecessor".
   - Should read: "Only 685.2 kg of VB-0001 is left. Enter 685.2 kg or less."
   - Never show database text to an operator.
5. **No full page reload.** "New … record" reloads the whole app. On a weak phone connection that is slow and loses what was typed. Stay in the app.
6. **Units on every number** in forms, reviews, records and public pages: kg, %, ₹/kg, packs. Show the total value on sales.
7. **Thresholds come from data, not code.**
   - Remove fixed warnings such as milling "yield below threshold", which fired at 65%, a normal yield.
   - Limits come from the crop (set by the State Manager), or are learned (Part C3).
8. **Offline.** Procurement must work without signal and sync later. Report what "Saved on phone" covers today, and what is needed for Procurement and Collection Batch.
9. **Dates.** Every stage has an **"on" date** (when it happened, editable within limits) and a **"recorded at"** time (automatic). Offline and late entries need this.
10. **Manager recording.**
    - A manager (Client Manager or State Manager) may record at a stage he does not hold **only with a written reason**.
    - The record shows "Recorded by manager on behalf of the stage".
    - Today Lucky could record Procurement in a stage he didn't hold, with no reason.
11. **Same person, next stage.**
    - One person may hold several stages, including adjacent ones (owner decision).
    - When the same person verifies their own previous step, mark that verification **"same person, next stage"** on the record and in the ledger.
    - The public page keeps the honest wording, as it does today.
12. **Evidence files.** Every stage may attach photos or files. Which are **required** is set per stage in Parts C and D.
    - Store a fingerprint (hash) of every file in the ledger block, so a file cannot be swapped later.
13. **Journey both ways.**
    - "Journey & export" from a procurement record today shows only that one record: it looks back only.
    - Every record's journey shows **where it came from and where it went**. For example, from a farmer's lot: batch → milling runs → QC → packs → buyers → released codes.
    - Recalls and buyer questions need the forward direction.
14. **Ledger check banner.**
    - Dashboards say "Ledger check passed: 18 blocks intact (2:00 am)" while the ledger already holds 50+ blocks.
    - Show instead: "Last full check 2:00 am: 18 blocks intact · N blocks added since".
15. **Roster pool: people already on other scopes.** In the scope's People step, people already holding stages on other scopes stay selectable (owner decision), with these changes:
    - List **free people first**, then **"Already on other scopes"**.
    - Show each person's current work, e.g. "mt1 · Milling on KH26 · gkp (active)".
    - On picking one, show a soft note: "mt1 already holds Milling on KH26 · gkp; he will have two work queues". Do not block.
    - The State Manager's overview counts people holding stages on more than one scope.

## Part B — Set-up lists (needed by the stages)

| List | Kept by | Fields | Used at |
|---|---|---|---|
| **Collection points** | Client Manager | Name, type (collection centre / field point / store), village, block, district, GPS | Procurement, Collection Batch |
| **Mills** | Client Manager | Name, place, GPS, own or hired, dedicated to this crop (yes/no) | Milling |
| **Packing units** | Client Manager | Name, place, own or contract, FSSAI licence number | Packing |
| **Labs** | State Manager | Name, accreditation number, external or in-house, location | QC |
| **Buyers** | Client Manager | Name, country, GSTIN or importer ID, address, FSSAI (domestic), contact | Commercial, Shipment, buyer link |
| **Pack list (SKUs)** | Client Manager | Pack size, unit, material (pouch / jute / PP bag), market, label type | Packing |
| **Parameter library** | Admin (GrainVeda, once) | Test name, unit, test method, in-house or lab | Crop quality schema |
| **Market profiles** | State Manager, per crop | Domestic, Export general, EU, UAE/GCC, USA … Each has its parameters with limits, its required export documents, and the **uploaded source document** (FSSAI standard, importer spec, destination rule) | QC, Commercial |

**Crop Registry additions (State Manager):**

- **GI crop: yes/no.** If yes, the **GI districts** (and blocks if needed). Non-GI crops have no GI checks at all.
- **Quality schema in four layers:**
  1. the parameter library;
  2. the crop's chosen parameters;
  3. the limits per **market profile**;
  4. the **buyer specification** per scope (Client Manager), which may only be **stricter**.
- Limits stay versioned. An active scope keeps the version it started with; every change is logged with its source file.
- **Shelf life** per packing material (milled rice is commonly about 12 months; the packer or lab confirms). Used for the best-before date.
- **Reference photo** of the crop, for the optional quick look at Procurement (Part C1).

**Farmer additions:**

- District, block and village **picked from lists** (today "district 1" is typed).
- **Farm GPS required** at registration. Existing farmers are asked to add it.
- **Optional:** land record number (khasra or khatauni) and GI authorised-user number.
- **GI-area check:** if the farmer's district is outside the crop's GI districts, accept him with a warning and mark him **"Outside the GI area"**.
- **GPS check:** if his GPS point is outside his stated district, flag it for the State Manager at farmer verification.

## Part C — The stages

### C1. Procurement

| Field | Rule |
|---|---|
| Farmer | Picked as today. Show a **farmer card**: GI land, sold this season vs expected, good-practice status, GI-area status |
| **Where** | **Collection point** from the list, or **"At the farm"**. GPS taken automatically from the phone. Required |
| **Procured on** | Date, required. "Recorded at" is automatic |
| **Delivered by** | Farmer / family member / agent (agent name required). Required |
| Gross, bags, tare → net | Keep (works today). Tare defaults from the pack-material setting |
| Moisture × 3 | Keep. Above the crop limit: **warning only**. Also warn when the spread between readings is wide |
| Price and payment | Only when the scope setting **"Record price & payment"** is on (set by the Client Manager). Fields: price per quintal, total amount (calculated), payment status (paid / pending), mode (bank / UPI / cash), **transaction reference** (never an account number). Visible only to the client and GrainVeda; never on public or buyer views |
| Optional | Harvest date; condition (Good / Damp / Pest / Mixed, one tap); weighbridge or scale slip photo |
| Variety | **No variety check for now** (owner decision). **Owner decides later:** a one-tap "Looks right / Not sure" against the crop's reference photo, plus the system picking 1 lot in 20 for a retained sample. Do not build now; leave room in the data model |
| Good farming practice | Keep the block (works today: farmer 2 was refused for unanswered required practices) |
| Yield check | Warning only (decided earlier) |
| **Farmer receipt** | After saving, show a receipt (lot code, date, net weight, moisture, and price if recorded) that can be printed or shown. SMS later |
| GI status | The lot carries the farmer's GI-area status (Part E) |

**What Collection Batch checks:** that the lot arrived and its bags match, then Accept or Return (Part A).

### C2. Collection Batch (renamed from "Village Batch")

| Rule | Detail |
|---|---|
| One place | A batch belongs to **one collection point**: the place where the bags are. Lots from different collection points cannot be combined |
| Villages | May mix within that collection point. The batch keeps the **share per village and per farmer** automatically (Part E) |
| Single-origin | Optional tick **"Single-origin batch"**: lots from one village only (or one farmer). For premium clients |
| **GI rule (hard block)** | **GI-area and non-GI-area lots can never be in the same batch.** Refuse it, saying which lot is the problem. Non-GI-area lots form their own batch, marked "not GI-area origin" |
| Always | Same crop, same scope |
| Village name | **Taken from the lots**, not typed. Several villages show as a list with shares |
| Fields | Collection point (from the lots), assembled-on date, bag count. Optional: **re-weighed total**, where the difference vs the sum of lots is shown as a loss, with a warning above a set %. Optional: fresh moisture reading |
| Calculated | Total, weighted average moisture, number of **distinct farmers** (today the public page says "2 farmers" for one farmer who sold twice) |

**What the next stage (Warehouse or Milling) checks:** weight received at arrival, condition, Accept or Return.

### C3. Warehouse (bring back from the prototype; optional per scope)

Chosen per scope, between Collection Batch and Milling. Rebuild the prototype's Warehouse Inward:

- **Arrival:** declared vs actual quantity, discrepancy (calculated), a **reason required** for any discrepancy, **flag above 2%**.
- **Storage:** location and stack; condition on arrival; **bags in and bags out**.
- **Inspections:** an interval set by the Client Manager. Each inspection records condition (Good / minor deterioration / significant deterioration / pest found), date and who. Lots show as inspection due or overdue.
- **Days in storage** shown on the lot, and on buyer and public views.
- **Warning:** in a scope **without** Warehouse, if a batch waits more than **15 days** for milling, warn the Client Manager: "Stored but not recorded".

### C4. Milling

| Field | Rule |
|---|---|
| Mill | From the mill list. Required |
| **Line clearance** | One tap: Fully cleaned / Quick clean / Previous run was also this crop. **Required at hired or shared mills.** At a mill marked "dedicated to this crop" it is recorded automatically as "Dedicated line" |
| Mill operator | Name. Required (results depend on the operator) |
| Input | Pre-filled with **what is left** of the source lot. If the mill is elsewhere: sent vs received, transit loss calculated |
| Outputs | **Head rice, broken rice, husk, bran** (kg). Loss = input − all outputs (calculated, cannot be negative) |
| Results | **Rice recovery %** (head + broken ÷ input) and **head-rice %** |
| Warnings | **No fixed thresholds.** Record mill, operator and variety for every run. After about 10 runs for a mill and variety, show "outside the usual range for this mill" as **information only**. Also apply the **mass-balance outturn ceiling** in the GrainVeda protocol (70% for rice unless the order form says otherwise): flag a run above it for the State Manager's review |
| **Broken rice** | Scope setting by the Client Manager: **"By-product, quantity only"** (default; clients mostly want whole rice) or **"Own traceable lot"**, which continues as its own lot marked "broken" |
| Husk, bran | Quantity only |
| Partial runs | Keep (they work today). When 2% or less of the source is left, offer **"Close lot"**, with the rest recorded as floor loss |
| Optional | Polish level (light / medium / full), mill slip photo |

### C5. Quality Control

| Item | Rule |
|---|---|
| What is tested | Built from the **market profiles** for this scope's markets plus any buyer spec. The operator selects nothing |
| In-house vs lab | Each parameter says which. **External accredited labs are the default.** In-house is allowed for basic parameters only |
| Lab | From the lab list (name and accreditation number) |
| **Sample** | Sample ID generated by the system, date drawn, quantity. **Retained counter-sample:** seal number, photo of the sealed bag, where stored, keep until (e.g. 12 months or best-before + 3 months). Optional buyer sample with seal number and recipient. Disposal of a retained sample is recorded |
| **Waiting for results** | Status "Sent to lab, awaiting results". **The lot is fully held** until results are entered |
| **Lab report (required for lab tests)** | Report number, report date, lab, **file**. The system checks: a file is present; report date ≥ date sent; **the same report number is not used on another lot** unless both lots share that sample |
| Verdict | One per market, e.g. "Domestic PASS · EU FAIL (residue) · UAE PASS". Automatic, as today, extended to profiles |
| Re-test | On a **new sample**, with a reason. The failed result stays on record for ever |
| **Export release on the client's acceptance** | Only the **Client Manager** may release a lot that failed export. Required: reason; the client's authorising person (name and title); **the client's written acceptance as an uploaded file**; date. The State Manager is notified. The ledger keeps the file hash. The lot is permanently marked **"Released for export on the client's written acceptance despite: <parameter>"**. Public and buyer views say that, **never "export PASSED"** |

Starting parameter set for Kalanamak, to be loaded by the State Manager (limits from labs and buyers, not from you):

| Group | Parameters | Done by |
|---|---|---|
| Basic | Moisture, broken %, foreign matter, damaged/discoloured grains | In-house |
| Authenticity | Admixture of other varieties, grain length, aroma | In-house or lab |
| Safety | Pesticide residues (multi-residue), aflatoxin, heavy metals | Accredited lab (export) |

### C6. Packing

| Item | Rule |
|---|---|
| Packing unit | From the list (own or contract, FSSAI licence). Required |
| Date | Packed-on date |
| Input | Pre-filled with **what is left**. Partial runs over several days allowed |
| **Packs** | Chosen from the **client's pack list** (no free typing of sizes). Count per pack type; kg calculated |
| Wastage | Calculated. **Above 2% requires a reason** (warning, not a block). A learned normal range later |
| **Batch code** | **Generated by the system and unique**, e.g. `TCUP-KNM-KH26-B0001`. The operator never types it. Today it is typed, and **the same code was accepted for two lots with different export results** (bug) |
| **Unique pack codes** | One **serial QR code per pack** (Part D) |
| Labels | Printed **at Packing** (Part D) |
| **Net weight check** | The system picks 5 packs at random; the operator weighs them; the app compares them with the stated size. **Required for export packs and retail packs of 5 kg or less**, optional for bulk bags |
| Best-before | **Packed date + shelf life** for that crop and material (FSSAI Labelling & Display Regulations 2020 require the packing date and a best-before date). Printed on the sticker, shown on the public page |

**What Commercial checks:** pack count per size, then Accept or Return.

### C7. Commercial (the sale)

| Item | Rule |
|---|---|
| Buyer | From the buyer list. Required |
| Market | Domestic, or **export + destination country**. The country selects the **market profile**, and every batch sold must have **passed QC for that profile** (or carry a client-acceptance release, C5) |
| What is sold | **Packs by type**, kg calculated |
| **One order, several batches** | Allowed. Every batch in the order must pass the order's market and share one GI status. Packs keep their own batch codes and serials. One invoice per order |
| Order | Order or contract number. Required |
| Price | Price, currency, Incoterms (for export), total value. Behind the scope's **"Record price & payment"** setting, private as in Procurement |
| **Export documents** | Checklist from the market profile (phytosanitary, certificate of origin, lab report, GI certificate copy, plus country extras). Each document: received / applied / not required, with a **file**. **Shipment is blocked until every required document has a file** |
| Optional | Sale route: own brand / white label / bulk / Prasaadam |
| Split | Keep (works today: 500 kg sold, 275 kg left). Show what is left |

**What Shipment checks:** that the packs handed over match the order, then Accept or Return.

### C8. Shipment

| Item | Rule |
|---|---|
| What ships | The packs of one order. **Partial shipments allowed**; the order shows what is left |
| **Pack scanning** | **Export:** scan pack or carton codes while loading, so the system knows exactly which serials went to which buyer. **Domestic:** count only |
| Domestic | Vehicle number (format checked), transporter, driver phone, **LR number (required)**, **e-way bill number** when required, **invoice number (required)** |
| Export | **Container number (format checked, required)**, **container seal number (required)**, **shipping bill number (required)**, **invoice number (required)**, ports, vessel, forwarder, departure/arrival dates. **BL may be added later**: status "Sailed, BL pending" |
| Photo | Loading photo showing the seal or the vehicle. **Required for export**, optional for domestic |
| Loss | At dispatch: packs counted. **Transit loss moves to delivery** (today it is asked at dispatch, before it can exist) |
| **Delivery confirmation** | Date, packs received, shortage with a note, **proof-of-delivery file**. **Required for export**, optional for domestic. Recorded by the Client Manager or stage holder from the buyer's proof |
| Block | Export cannot be recorded until C7's required documents have files |

**What the release stage checks:** the system confirms papers and files are present (Part A2); the person confirms the dispatch physically happened, then Accept or Return.

### C9. QR Activation, now "Release"

Codes are already on the packs (printed at Packing). This stage **releases** them: their pages go live.

1. **Per shipment.** Only the packs of that shipment go live. Packs not yet shipped stay unreleased.
2. **Release check with a summary** (today one click, "Activate and seal", checks nothing). Check:
   - every record in the chain is approved;
   - nothing is returned or flagged;
   - QC is valid for the shipment's market (or a client-acceptance release exists);
   - documents are complete;
   - GI status;
   - the count of "same person, next stage" checks.
3. **Preview** of exactly what the public page will say, then **confirm**.
4. **After release:** status **Active / Under investigation / Recalled**, set by the Client Manager or State Manager **with a reason**.
   - A recall works by batch and shows a **public notice** on every affected pack.
   - The ledger records each change.

## Part D — Packs, labels, QR codes and the public page

1. **One unique serial code per pack.** E.g. batch B0001 with 160 packs gets codes …-B0001-0001 to …-B0001-0160, each with its own public URL.
2. **Labels** are a QR sticker carrying:
   - crop;
   - **"GI Tag No. 280"** (not a bare "280"), only for GI-area lots;
   - pack size;
   - batch code;
   - packed date;
   - best-before date;
   - serial;
   - the scan line.

   The full pack label (FSSAI, MRP) comes later.
3. **Number of labels = number of packs** (today it defaults to 12 copies for 160 packs). Print as a PDF for normal or thermal printers. **Reprints need a reason**, and spoiled labels are voided; both are logged.
4. **Before release**, a scan shows **"Packed, not yet released"**.
5. **Scans are unlimited and never metered** (owner decision: no scan quota or per-scan charge in the product).
   - **Log every scan:** time, approximate city from IP, the code. **No personal data**, no precise location.
   - Add a fair-use limit against bots only.
6. **Copy detection.**
   - A serial scanned in far-apart places, or far more often than normal, is flagged to the Client Manager and State Manager.
   - The public page then tells the person scanning: "This code has been scanned many times in different places. If your pack's seal was broken, contact …".
7. **Public page content.**
   - **Origin:** GI badge only for GI-area lots of a GI crop.
   - **Villages:** **district, village cluster and season only**. **No farmer names, phone or plot** (owner decision, per the Farmer Data and Consent Addendum). Keep the data model ready for an optional per-farmer consent to show names later.
   - **Lab result per market.** A client-acceptance release is shown as such.
   - **Dates:** packed and best-before.
   - **Journey:** units on every value, batch code shown (never "Batch not yet"), farmer count per distinct farmer, the honest "same person" wording (keep), and the recall or investigation notice if any.

## Part E — Farmer-level traceability and GI status

1. **Design basis: farmer level** (owner decision). Every lot carries its **farmer shares** through every merge (batch, order) and split (milling runs, packing runs, sales).
   - Calculate the shares automatically by mass balance. **No operator effort.**
   - The system can then say "this pack's paddy came 62% from farmer A and 38% from farmer B of village X", which serves recalls, the yield check and buyer evidence packs.
2. **Honest wording.** After mixing, shares are **documented proportions**, not physical identity. Buyer and public views say so where shares are shown.
3. **GI status travels with the lot:**
   - a lot from an outside-GI-area farmer is "not GI-area origin" permanently;
   - no batch may mix the two statuses (C2);
   - every downstream lot, pack and public page inherits the status. The GI badge appears only when every source is GI-area.
4. **Code format.** Record codes should identify the **scope**, not only client, crop and season. Today two KH26 scopes share one number series (P-0002 in Bansi follows P-0001 in gkp). Propose a format.

## Part F — Sharing a shipment with a buyer

1. On a sale or shipment, the Client Manager can **"Share with buyer"**. This sends a **secure link** (email or WhatsApp) to that shipment only, showing:
   - lab reports;
   - export documents;
   - chain and farmer/village shares (as consent allows);
   - the evidence pack download.
2. The link **expires**, can be **revoked**, and **every view is logged** for the client.
3. A buyer never sees another buyer's volumes, prices or sources.
4. Buyer logins (a portal) come later. Design the link so a login can replace it.

## Part G — Bugs found in the run (fix in Phase 1)

| # | Bug |
|---|---|
| G1 | Same batch code accepted for two lots (PK-0002 export PASS, PK-0003 export NOT MET) |
| G2 | Waiting lists and pre-fills show the original quantity after partial use |
| G3 | Handoff checklist makes people confirm things the app knows (and allowed a false "Documents attached") |
| G4 | No way to return a lot at verification |
| G5 | Milling "yield below threshold" at 65% (fixed threshold, wrong) |
| G6 | Public page counts lots as farmers ("2 farmers" = one farmer twice) |
| G7 | Public page shows "Batch not yet"; "280" without "GI Tag No."; values without units |
| G8 | Labels default to 12 copies regardless of packs |
| G9 | "Activate and seal" seals with one click and no check or confirmation |
| G10 | QR comes after Shipment, so labels are printed after goods leave (resolved by C6 + C9) |
| G11 | "New record" reloads the whole page |
| G12 | Transit loss asked at dispatch |
| G13 | Database error text shown to operators |
| G14 | Manager can record at a stage he does not hold, without a reason |
| G15 | Record numbers shared across scopes of the same client, crop and season |

## Part H — Not yet reviewed: the operator's own login

The run was done as Lucky (Client Manager holding every stage). An operator who holds **one** stage, e.g. p at Procurement, has not been reviewed yet: his home page, menu, work queue, and how "waiting for me" looks on a phone.

Do not redesign it in this brief. Make sure every Part A change also works for a single-stage operator. Report what he sees today, so the owner can review it after Phase 1.

## Out of scope for this brief (known, later)

- Buyer portal logins (Part F's link comes first).
- Regulator / auditor view.
- Intelligence reports and dashboards.
- Scan analytics dashboards: only the scan log and copy flags are in this brief.
- Full pack label with FSSAI and MRP.
- SMS receipts and alerts.
- The variety check at Procurement.
- Showing farmer names on public pages.

## Constraints

- Every new string needs English and Hindi.
- Everything must work at phone width (about 527 px). Procurement and Collection Batch must work offline.
- Use additive migrations only. Do not delete or rewrite existing records, files or ledger blocks; correct with new blocks.
- No Aadhaar or bank account numbers anywhere. Payment reference = transaction ID only.
- Tests that write data run on a local or branch database. On the practice system, use clearly fake data and clean up.
- Do not weaken the last-active-admin guard or the break-glass procedure.
- Do not deploy to production or push to the main branch without my say-so.

## Done means (one test season, on a test database)

1. **Farmers:** three farmers, one outside the GI districts.
   - The outsider is accepted with a warning and marked.
   - His lot **cannot** join a batch with GI-area lots.
2. **Procurement** at a collection point, with GPS, procured-on date and delivered-by. Price and payment appear only when the scope setting is on. A receipt is shown. One lot is recorded offline and syncs later.
3. **Collection Batch:**
   - two villages at one collection point, with shares shown;
   - a single-origin batch refuses a second village;
   - the farmer count is correct.
4. **Milling:**
   - at a hired mill, line clearance is required; at a dedicated mill it is automatic;
   - two partial runs, with **remaining quantity shown and pre-filled**;
   - head/broken/husk/bran recorded;
   - no "below threshold" warning at 65%;
   - a run above the 70% outturn ceiling is flagged.
5. **QC:**
   - parameters appear from the market profiles;
   - lot held while "awaiting results";
   - report file required;
   - reusing a report number on another lot is refused;
   - a failed export lot is released only with the client's acceptance file, and the public page says so.
6. **Packing:**
   - packs from the pack list;
   - **batch code generated and unique**;
   - one serial code per pack;
   - labels = packs;
   - net-weight check required for 1 kg packs;
   - best-before printed;
   - a scan before release shows "Packed, not yet released".
7. **Commercial:**
   - one order from two batches;
   - an EU order refused for a batch that failed the EU profile;
   - Shipment blocked until export documents have files.
8. **Shipment:**
   - export with container, seal, shipping bill, invoice and photo;
   - BL added later;
   - packs scanned at loading;
   - delivery confirmation with proof of delivery and a shortage.
9. **Release:**
   - the check summary and preview appear;
   - only that shipment's packs go live;
   - a recall shows the notice on every pack of the batch.
10. **Return:** a lot returned at any stage goes back to its creator with the reason and can be resubmitted.
11. **Copy detection:** scanning one serial from two distant locations raises a flag and the public warning.
12. **Buyer link:** "Share with buyer" opens one shipment for the buyer, expires, can be revoked, and views are logged.
13. Every G bug is fixed.
14. **Journey and ledger banner:**
    - The journey of a farmer's lot shows its way forward to packs and buyers.
    - The ledger banner shows the blocks added since the last check.
15. **Roster pool:** a person already on another scope is listed after free people, with their current work and the soft note.

## Report back

When you finish each phase, tell me:

- what changed;
- your proposals for the "Owner decides" items (Conditional verification; the variety check later);
- the record-code format (E4);
- what "Saved on phone" covers;
- anything you could not test.

Say plainly what is not done.
