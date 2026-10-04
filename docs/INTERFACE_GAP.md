# Interface gap: the prototype against the system as built

Compared on 3–4 October 2026. Prototype = `GrainVeda_Platform_v1.html` (19,281 lines). Built system = this repository at
Phase 4, run on the local stack. The app deployed on 3 October (https://mvp-beta-one.vercel.app) is the same screens;
its staging database was still at Phase 3 that day, so the journey was run locally, where every stage can be used.

**How it was compared**

| | Prototype | System as built |
|---|---|---|
| Source read | every line, into an inventory of each screen, form, field and message | all of `web/src` (5,117 lines), `supabase/seeds/01_stage_definitions.sql`, the server functions the screens call |
| Run with real entries | one lot through 7 stages to an active QR and the public page; side runs for sorting, grading, warehouse, village batch, lot inward, imports, flags, queries | one lot through the same 7 stages to a sealed QR and the public page; side runs for sorting, grading, village batch, lot inward, offline, flags, override, withdraw |
| Pictures | 874 (laptop 1366 × 768 and phone 390 × 844) | 571 (same two sizes) |

Limits of this comparison are at the end (section 14). Nothing in the interface was changed for it.

> **Decision, 4 October 2026 (Veda): option B, the prototype's look and frame on a laptop, with laptop and phone both
> working well** (`docs/FIX_LIST.md` G8). In the morning the answer was A (keep as built); it became B the same day,
> because the system will mostly be used on the web.
>
> - The faults of section 10 were fixed first, all but item 15 (an arrival check that cannot refuse a lot), which
>   belongs to options C and D and stays (limit K19).
> - Option B was then built, in the repository: sections 3 and 4 have a last column **"Since decision B"** saying what
>   each row is now. The columns "Prototype" and "System as built" are the comparison as it was made and were not
>   rewritten.
> - Sections 5 to 8 (what the forms ask for, the arrival check, which screens exist, rules) describe differences that
>   **remain**: they are options C and D. This document is the list to choose from, should any part be taken up later.

---

## 1. Short answer

The two interfaces differ on three levels. Only the first is a matter of taste.

| Level | Size of the difference |
|---|---|
| **Look** (colours, frame, how a form opens) | Everything. No screen looks like its prototype counterpart |
| **Layout** (menu, first screen, use of a laptop screen) | Different menu, different first screen for every role. The built system shows a laptop the same single column as a phone |
| **Content** (what a form asks for, which screens exist) | About 100 fields of the prototype's stage forms are not asked for in the built system; one stage (Warehouse Inward) and about 15 screens do not exist in it. The built system has about 12 things the prototype lacks (phone layout, offline, Hindi, hosted public page, labels, corrections, …) |

Since decision B (4 October): the first two levels are closed on a laptop (same colours, frame, menu, first screens,
form layout and status words; a phone keeps its own one-column layout, which the prototype does not have). The third
level, content, is unchanged.

## 2. Why it differs

| # | Cause | Where it was decided | Whose call |
|---|---|---|---|
| 1 | Screen code was not carried over; all stages are drawn by one generic engine | PRD §10 "UI code is not ported", §11 | PRD decision, approved |
| 2 | The same paragraph named the four visual guides as "the screen-by-screen UI reference" and listed "verify-page layout" for re-use. The guides were not opened during the build and the prototype's screens were not read | Build | **Builder's gap** |
| 3 | The forms were built from PRD §7 "Inputs entered", which lists only the numbers the weight check needs. Dates, prices, lab identity, buyer and transport details were in the guides and the prototype, not in §7 | PRD §7 and build | **Builder's gap** (the PRD did not say these were being cut) |
| 4 | The PRD lists 16 stage types. The prototype has 17: **Warehouse Inward** is in its default chain and is not in the PRD, nor are the crop's farm-practice (GAP) fields or the price at procurement | PRD §6–§8 | **Builder's gap in the PRD** (dropped without being flagged) |
| 5 | Operators work on phones (PRD §4, §9). The prototype has no phone layout: at 390 px the save button of most forms is off the screen | PRD decision | Correct for phones; but the same single column was then used on laptops too, which the PRD did not ask for |
| 6 | Rules moved into the database (PRD §3). Some prototype behaviour could not be kept as it was: a hand-off check that passes when items fail, a save that goes through after a warning dialog | PRD decision | Intended |

## 3. Look and frame

| Item | Prototype | System as built | Since decision B (4 Oct) |
|---|---|---|---|
| Colours | near-black green frame (`#071209`, `#0F2010`), bright green actions (`#2D7A2B`, `#3D9E3A`), white cards on pale grey-green | cream page (`#f7f4ea`), mid green header (`#2f5d34`), gold accents (`#d9b44a`) | the prototype's (same values, one set of tokens in `styles.css`). Two were darkened for a text contrast of 4.5:1: yellow chip text, button hover |
| Where the colours came from | the prototype's own style sheet | the style of the four explainer pages ("paddy green + GI gold"), which are documents, not screens | the prototype's style sheet |
| Font and size | Segoe UI, 14 px, small capitals for field labels | system font, 16 px, bold labels | Segoe UI first, 14 px on a laptop, small capitals for field labels; 16 px and plain labels on a phone |
| Sign-in | dark card on a dark page; username + password; "Forgot password? Contact GrainVeda Admin"; company line | light card; two tabs "Field operator (phone)" / "Manager (email)"; no forgot-password line; no company line | white-on-dark card on a dark page, logo, tagline, "Forgot password? Ask your manager", company line. Still two tabs (phone / e-mail) and a language box: logins are per person |
| Top bar | logo · client name · scope selector · name and role · initials badge · Sign out | logo · name and role · language · Sign out. On a phone the name stays; the product name and the role give way (until 4 October the name was hidden on a phone) | logo · where you are · scope selector · name over role · initials badge · language · network · Sign out. Phone: as before |
| Menu | dark side bar, 220 px, in sections: Overview / Registry / Operations / Inventory / System / Support, with icons | a bar of links under the top bar; no sections, no icons | dark side bar, 220 px, in sections: Overview / Registry / Operations / System / Support, with icons. No Inventory section (the screens do not exist). Phone and tablet below 900 px: the bar of links, one row |
| Use of a 1366 px laptop window | side bar + content; forms in a 520–640 px panel beside the page | one centred column of 1,100 px; every input 1,034 px wide; one field per row; 149 px empty each side | side bar + content up to 1,400 px; forms in two columns |
| How a form opens | panel sliding up at the bottom right, page still visible behind | inside the page, replacing the list | **unchanged:** inside the page |
| Form layout | two columns, section headings ("Weighing", "Moisture Readings", "Price & Payment"), computed boxes tinted green | one column, no sections, result in a panel under the form | two columns on a laptop, section headings with icons ("Weighing", "Moisture readings", "Evidence"…); the result panel stays under the form |
| Review before saving | pop-up window | under the form, with a tick box "I have checked these numbers" | **unchanged:** a step in the page, with the tick box |
| Messages | toast for 3.5 s | a line in the page that stays | **unchanged:** a line in the page |
| Status words | "🟡 PENDING VERIFICATION", "🟢 APPROVED", "🔴 REJECTED" | "Pending", "Verified", "Withdrawn" ("Superseded" until 4 October) | "Pending verification", "Approved", "Withdrawn", as chips with a coloured dot. No "Rejected": an arrival cannot be refused (K19) |
| Icons | an emoji on every menu item, page title and button | none | on menu items, page titles, stage cards and form sections |
| On a phone (390 px) | side bar keeps 220 px, 170 px left for content; every table scrolls sideways; form panels are cut on the left: of 19 forms measured, the save button is fully on screen in none, and "Approve" is off screen | one column that fits; header 121 px (14 % of the screen); no page wider than the screen. Until 4 October: header 239 px (28 %), and three pages wider than the screen (record detail, scope people, label sheet) | **unchanged in structure:** one column, the three header lines (121 px), no page wider than the screen; new colours, stage cards, a scope picker on the first screen |

## 4. Menu and first screen, per role

| Role | Prototype: menu | Built: menu | Prototype: first screen | Built: first screen | Since decision B (4 Oct) |
|---|---|---|---|---|---|
| Admin | Dashboard, Pipeline · Clients, Crop Registry, Users & Roles · Inventory · Chain Ledger | Home, States, Clients, Crops, Scopes, Farmers, Users, Flags, Health, My account | first-run wizard (7 steps), set-up tracker, then platform overview with number cards that open detail panels, client cards | "Hello, {name}", one line on the ledger check, one card per scope with a per-stage table | **Menu:** Dashboard · States, Clients, Crop Registry, Season Scopes, Farmers, Users & Roles · the stages of the chosen scope · Flags & Disputes, Health · My account. **First screen:** platform overview with four number cards (active scopes, total volume, needs action, QR issued), the ledger check line, one card per scope; with a scope chosen, as Client manager. No first-run wizard, no detail panels |
| State Manager | the same plus Farmers | Home, Clients, Scopes, Farmers, Users, Flags, Health, My account | state overview, hand-over brief, coverage alerts, client cards | as Admin, for the own state | as Admin, for the own state (no States item) |
| Client manager | Dashboard · Farmers, Season Scopes, Users & Roles · **one item per stage of the chosen scope** · Inventory · Queries & Rejections, Chain Ledger | Home, Scopes, Farmers, Users, Flags, My account | welcome card with tasks, 4 number cards (Volume by Stage, My Action Queue, Yield / Loss, Completed), action queue, "Season flow — stage by stage" with the bottleneck named | as Admin, for the own client. No totals, no action queue | **Menu:** Dashboard · Season Scopes, Farmers, Users & Roles · **one item per stage of the chosen scope** · Flags & Disputes · My account. **First screen:** number cards (Procured, My action queue, Yield, Completed), action queue, headline figures, "Season flow — stage by stage" with the bottleneck named, quick actions, "Team & pipeline overview". No welcome card with tasks, no Inventory, Queries or Chain Ledger items |
| Stage operator | Dashboard · previous stage and own stage · Queries & Rejections (Farmers for procurement) | Home, (Farmers), Saved on phone, My account | "My Stage", what is waiting, own recent records, own season total | one tile per stage held, with "n waiting" | **Menu:** Dashboard · (Farmers) · own stages · Saved on phone, My account. **First screen:** a card per stage held: "My stage", what is waiting, own recent records, own season total |
| Client viewer | Client Portal | Home, Scopes, Farmers, My account | portal page (the prototype cannot create this user) | read-only Home and scope dashboard | as Client manager, read-only: the action queue is shown with **View** in place of **Assign**, no ledger line, no "+ Add farmer"; the menu has no Users & Roles and no Flags & Disputes |

Scope choice: the prototype has a scope selector in the top bar with "Overall — all scopes"; the built system lists every
scope on Home and has no selector. **Since decision B:** a scope selector in the top bar with "⭐ Overall — all scopes"
(on a phone: a picker on the first screen); the choice is kept on the device. There is no "switch client".

---

## 5. What each stage form asks for

"Only in the prototype" lists typed fields by their exact label. \* = marked required in the prototype.
Fields that are worked out, not typed, are in italics.

### 5.1 Fields

| Stage | In both | Only in the prototype | Only in the built system |
|---|---|---|---|
| **Procurement** | farmer, gross weight, bags, tare per bag, 3 moisture readings; *net quantity, moisture average and range* | Procurement Date \*, Price per kg \* (*Total Value*), Field Observations / Notes, the crop's GAP fields, *Footprint ID shown before saving* | Photo evidence. Bags, tare and all three readings are required (optional in the prototype) |
| **Lot Inward** | declared quantity, weighed quantity (*variance*), source type, source name, crop declared, moisture, condition | Date of Receipt \*, moisture as a range, Grain Dimensions / Type, Aroma Observation, Foreign Matter, Pest Damage, Mould / Staining, Due Diligence Note \* (30 characters or more) | — |
| **Village Batch** | village, the farmer lots ticked; *batch total* | Assembly Date \*, Mill Location, Assembly Notes; *average price, moisture range* | — |
| **Warehouse Inward** | — (**the stage does not exist in the built system**) | source lot \*, Date Received \*, Actual Quantity Received \* (*discrepancy*), Reason for discrepancy \*, Storage Location, Condition on Arrival, Notes; inspection window setting; lot inspection | — |
| **Quality Control** | source lot, sample quantity, one reading per crop parameter, sample / lab reference; *quantity passing forward, two verdicts* | Test Date \*, Lab Name \*, Lab NABL / Cert Number, Pesticide Residue, Heavy Metals, Aflatoxin, Microbial Count, Certificate URL, QC Notes, Re-test Reason; *verdict shown while typing* | both limits printed beside each reading (the prototype's form shows the domestic limit only) |
| **Every processing stage** | source lot, input quantity | Operator Name \*, Dispatched from Storage (*Transit Loss*), Transit Loss Note, Process Date \*, "final run — close this source lot" with Floor Loss and Floor Loss Note, Run Observations; *run ID shown before saving, yield %* | — |
| **Milling** | output (rice), bran | Machine Flushed Before Run? \*, Equipment Temperature, Mill / Processor Name \*, Mill Location, Moisture % (Output) | Loss (typed) |
| **Sorting** | reject, reject reasons with kg | eight fixed reject reasons | free reason rows; Loss |
| **Grading** | Grade A, B, C, reject | Broken grain % | Loss; "Split into grade lots" (in the prototype the tick box cannot be reached, so one lot goes forward) |
| **Drying** | output, moisture before and after | Machine Flushed \*, Equipment Temperature, Drying Date \*, Drying Method \*, Duration (hours), Drying Location | — |
| **Popping** | output, pop rate | Head Size, Temperature, Processor / Unit Name | — |
| **Cleaning** | foreign matter removed | Cleaning Method; output is typed | Loss; output is worked out |
| **Blanching** | output | Water Temperature, Duration (minutes) | — |
| **Cold Storage** | quantity stored and retrieved, entry and exit dates | Cold Storage Facility \*, Storage Temperature \*, Humidity %, Facility FSSAI No. | — |
| **Packing** | packets by size, batch code \*, wastage | Packing Date \*, Packing Unit / Operator \*; six fixed sizes (1, 2, 5, 10 kg packets; 25, 50 kg bags); batch code suggested (`PURV-2026-KNM-001`); *wastage, total units* | any packet size (free rows); batch code and wastage are typed |
| **Commercial Clearance** | buyer \*, sale type / market \*, quantity \*, price per kg | Buyer Country / Location, PO / Contract Reference, Brand / Route \*, Payment Terms, Clearance Date \*; export: Destination Country \*, Port of Export, Export Document Checklist (Received / Applied / N/A per document), APEDA RC / IEC Number; domestic: Delivery State / City, Expected Delivery Date, FSSAI Licence \*, GST Invoice Ready \*, GI Certificate Shared with Buyer, Lab Report Shared with Buyer; Notes; *Total Value* | the line "Lab result: domestic … · export …" above the form |
| **Shipment** | quantity, dispatch date \*, container or vehicle number \* | source chosen by buyer (one consignment can draw on several sales), Packed Qty, Loaded Qty — Weight Bridge (*Loading Loss*), Loading Loss Note; export: Seal No, Bill of Lading No \*, Carrier / Shipping Line, Port of Loading, Port of Discharge, Freight Forwarder / Agent, Customs SB Reference, ETD, ETA; domestic: LR Number \*, Transporter, Driver Name, Driver Phone, E-way Bill No, Delivery Address, Delivery State, Expected Delivery Date, Payment at Dispatch (if COD); Notes; "Mark Delivered" afterwards | Destination \*, Transit loss (typed), Documents (photo or PDF, fingerprinted) |
| **QR Activation** | no form in either | — | — |

Count of typed fields that only the prototype asks for: Procurement 3 (+ the crop's GAP fields) · Lot Inward 7 ·
Village Batch 3 · Warehouse Inward 7 · Quality Control 10 · every processing stage 8 · Milling 5 · Drying 6 · Popping 3 ·
Cold Storage 4 · Blanching 2 · Packing 2 · Cleaning 1 · Grading 1 · Commercial 16 · Shipment 22 · arrival check 3.
**Total: 103.**

### 5.2 Dates and record numbers

| Item | Prototype | System as built |
|---|---|---|
| Date of the work | typed on every form (procurement date, test date, process date, clearance date, dispatch date) | only Shipment and Cold Storage ask for a date. Every other record carries the time it was saved on the phone (until 4 October: the time it reached the server) |
| A record saved with no network | — | keeps the time it was captured, and shows when it was sent (fixed 4 October). Before: **the time it was captured stayed on the phone; the record was dated when it was sent** (a lot bought on Monday and sent on Wednesday was dated Wednesday) |
| Record number | shown in the form before saving, so it can be written on the bag | given at saving, first shown on "Saved as …" |
| Number format | `PURV-KNM-ML-0001` | `PRSDM-KNM-KH26-M-0001` (season added, PRD §8) |

---

## 6. Checking what arrived (the hand-off)

| Item | Prototype | System as built |
|---|---|---|
| Where | "Incoming from {stage}" on the receiver's stage page; a second "Verify" on the sender's page | tab "Waiting from {stage}" |
| What the checker sees | summary of the record; for a lab record the full result card | code, quantity, the record's worked-out values, lab result line, warnings |
| Check list | worked out by the app from the record, ✓ or ✗; advisory (Approve works when it says INCOMPLETE; two lists wrongly say INCOMPLETE) | fixed sentences the person must tick; "Verify this lot" stays disabled until all are ticked |
| Extra inputs | first hand-off: Actual Quantity Received, Condition on Arrival; every hand-off: Verification Note \* | none |
| Decisions | Approve · Conditional · Reject | Verify only |
| Reject | raises a Query (Q-0001) to the sender; sender "Re-submits" with a note; manager "Resolves"; listed under Queries & Rejections | **does not exist.** A flag can be raised on the record; a manager can withdraw it with a reason |
| Quantity received at hand-off | stored, but later screens go on with the declared quantity | not asked |

## 7. Screens

### 7.1 In the prototype, not in the built system

| Screen | What it does | Nearest thing in the built system |
|---|---|---|
| Role dashboards with number cards and detail panels | volume by stage, action queue, yield / loss, completed, season flow with bottleneck, team overview | Home: one table per scope (records, pending, verified out, available). **Since decision B: built**, without the detail panels the cards open in the prototype |
| Pipeline | where every lot stands | — |
| Inventory | per stage: came in, moved on, held; by state, client, crop | "Available" column on Home |
| Chain Ledger | every block in one list, "Verify Integrity", export | ledger table on each record; lot journey; check result on Home and Health |
| Queries & Rejections | open and resolved queries, re-submit, resolve | Flags list (open flags only) |
| Flags & Disputes | quality / procedural flags, investigation, recall; a quality flag blocks the QR and marks it "under investigation" | one kind of flag; an open flag blocks the seal |
| Warehouse Inward + inspection window | a stage, see 5.1 | — |
| Crop "Configure Layers" | GAP fields (shown on the procurement form), quality limits, export documents | quality limits only |
| Crop identity | 18 fields (pillar, batch prefix, certifying body, lab standard, export tier, MRL risk, markets, grade options, notes, …) | name, code, GI tag, origin, allowed processing stages |
| Client form | 11 fields (contact person, phone, e-mail, subscription tier, crops, contract start, status, notes) and the client's login in the same step; edit | name, code, type, state; no edit |
| Farmer form | 6 shown + 19 optional (block, WhatsApp, PIN, Aadhar last 4, KYC status, FPO, total land, farming method, certification, years farming, seed variety and source, irrigation, GPS, bank account, IFSC, notes); crop-season registration; two IDs (client and state) | 6 required, notes, photo consent; one ID |
| FPO Clusters | register and list FPOs | — |
| Procurement by Excel | import purchases; a row with an unknown farmer is held until the farmer is added | — (farmers can be imported, purchases cannot) |
| Users | edit a person; archive with a replacement, restore, transfer a State Manager | deactivate, activate, reset password; no edit |
| Scope wizard extras | scope name, target quantity, target farmers, notes; stages in any order; custom stage | season code, place, crop; stage order fixed by the builder |
| QR image window | QR picture, download PNG, summary | QR on the sealed screen and on the label sheet |
| Audience views | Consumer / Buyer / Regulator; Trade Details and Audit View on the public page | one public page; for managers: lot journey with CSV and PDF |
| "Mark Delivered" | closes a shipment with what arrived | — |
| First-run wizard, set-up tracker, role welcome card | guide a new admin and each role | — |
| Scope selector, "Overall — all scopes", switch client | in the top bar | —. **Since decision B: built**, without "switch client" |

### 7.2 In the built system, not in the prototype

| Thing | Note |
|---|---|
| A phone layout | every operator screen fits 390 px |
| Work without network | "Saved on phone", sent by itself, never twice |
| Hindi | operator screens and the public page |
| Logins per person | phone or e-mail, temporary password, own password at first sign-in |
| Photo and document evidence | fingerprint kept in the ledger |
| Correct a pending record; withdraw and replace a verified one | nothing is deleted |
| Grade lots A / B / C as separate lots | each goes to the lab on its own |
| Public page at a real address | no login, 169 KB, Hindi |
| Label sheet with the QR | 1 to 60 per sheet |
| Lot journey with CSV and PDF; season summary CSV | for buyers and auditors |
| Health page | ledger check, problems reported by phones |
| Practice-system strip | staging and production cannot be mixed up |

## 8. Rules that behave differently

| Rule | Prototype | System as built |
|---|---|---|
| Who enforces | the browser | the database; the screen shows the database's answer before saving |
| Milling balance | none: bran is recorded but not checked | input must equal rice + bran + loss |
| Milling yield | flag below 58 %; warning below 70 % at review | warning below 70 % |
| Packing wastage | above 2 % the save is refused | no limit; packets + wastage must equal input |
| Taking more than the lot holds | a dialog "save anyway?" | refused |
| Closing a source lot | "final run" tick, allowed within 2 % | automatic when less than 2 kg is left |
| Lab verdict | shown while typing and at review | shown once the readings are complete and at review (fixed 4 October; before: only after saving) |
| Farmer verification | a farmer typed in is active at once; only imported farmers wait, and the client account verifies them | every farmer waits for the State Manager (PRD F4) |
| Scope after activation | season, crop and unused stages can still be changed | frozen (PRD D1) |
| Stage operator's reach | previous stage and own stage; the person after procurement can also create procurement records | previous stage (read and verify) and own stage, enforced by the database |

---

## 9. Faults found in the prototype (not to be copied)

| # | Fault |
|---|---|
| 1 | Below about 1,800 px window width the review pop-up opens behind the form: its confirm button is covered at every stage. The form has to be closed first |
| 2 | On a phone the save button of most forms, and "Approve", are off the screen |
| 3 | "+ Add Another Buyer" cannot be saved (script error) |
| 4 | The Buyer view of the verify panel does not open (script error); quality tiles on the public page read "[object Object]" |
| 5 | A drying run with real grain loss cannot be saved (script error, no message) |
| 6 | Hand-off check says INCOMPLETE for a complete packing run and for an export shipment |
| 7 | Number cards and the lists they open disagree (4 against 3 + 1 against 2; 2,650 kg against 2,950 kg) |
| 8 | With two scopes, some lists mix the records of both |
| 9 | A person created without a title for a second scope gets the client manager's screens |
| 10 | The warehouse officer has no "Verify" on the own page; the Lot Inward person cannot record |
| 11 | The public address printed under the QR (`verify.grainveda.com/fp/…`) is not served by anything |
| 12 | Stock count, role builder, the QR gate list for a ready lot and the pack label exist in the code and have no button |

## 10. Faults found in the built system during this comparison

None of these was known before; the three test suites passed with all of them present. Numbers are those of
`docs/FIX_LIST.md` on the day they were found. The last column says what became of each: eleven of
the twelve are fixed in the repository, each with a test that failed before the fix. They are not on staging until
migrations 28 and 29 and the app are pushed.

| # | Fault | Class (proposed) | Now (`docs/FIX_LIST.md`) |
|---|---|---|---|
| fixed 21 | The data sent to the public page included the **buyer's name** and the market of each sale. The page did not show them, but anyone with the QR could read them in the browser. Fixed on 4 October in the repository (migration 28); the test failed before the fix. **Staging still has it until migrations 22 to 28 are pushed** (run-sheet Phase 4, A1–A3); staging holds demo data only | Blocker | fixed, line 21 |
| item 6 | Text values are printed as **"NaN"**: batch code, buyer, market, grade, at review, at the next stage's arrival check and on the record | Before next lot | fixed, line 22 |
| item 7 | A crop's quality limit cannot be typed with a decimal point: 12.5 becomes 125 | Before next lot | fixed, line 23 |
| item 8 | The time a record was captured without network is not kept: the record is dated when it is sent | Before next lot | fixed, line 24 |
| item 9 | The lab form shows no pass / fail until after the record is saved (PRD §4 asks that the technician sees both verdicts) | Before next lot | fixed, line 25 |
| item 10 | Raw data shown to operators: reject reasons and the grade split as code text; "Entered values" as code text | This week | fixed, line 26 |
| item 11 | English labels made from internal names: "Net Kg", "Moisture Avg", "Qc", "Qr Activation"; one stage has two names depending on the screen | This week | fixed, line 27 |
| item 12 | A client viewer sees "Remove", "Assign existing…", "+ new person" on a scope (the database refuses the action) | This week | fixed, line 28 |
| item 13 | A first stage opened by someone who cannot record there shows empty tabs | This week | fixed, line 29 |
| item 14 | Phone: record detail, scope people and the label sheet are wider than the screen; the header takes 28 % of the screen and does not say who is signed in | This week | fixed, line 30 |
| item 15 | An arrival can only be verified, never refused (section 6) | with G8 | **not built** (it belongs to options C and D): limit K19 |
| item 16 | Smaller: the farmer form says "verified" for a farmer still waiting; a withdrawn record is badged "Superseded"; a procurement record keeps "verdict pending" after its lot passed the lab; dashboard stage boxes have no caption; "Manager actions" counts stage assignments; Health prints the stage name twice; one Hindi label missing (grain loss at drying); no language choice on the sign-in screen | Later | fixed, line 31 |

---

## 11. Options

Open items 6 to 14 and 16 of the fix list are fixed first in every option (done on 4 October); the data leak (fixed 21) is closed in the repository and reaches staging with the next push. Item 15 (no way to refuse an arrival) belongs to options C and D.

**Chosen: B** (Veda, 4 October 2026; A in the morning, B the same day). Built that day: `docs/FIX_LIST.md`, "The prototype's look and frame".

| | Option | What changes | What stays | Work here | For a two-person team |
|---|---|---|---|---|---|
| A | **Keep the built interface** | faults only | everything else in this document stays different | under 1 day | 1 week |
| B | **Prototype's look and frame** | A + the prototype's colours, top bar and side menu with its sections on a laptop; forms in two columns with section headings; scope selector; role first screens with number cards, action queue and season flow; status wording and icons | phone layout; one engine; what the forms ask for | 2 days | 3 weeks |
| C | **B + what the prototype records** | B + the 103 fields (5.1), dates on every record, record number before saving (with a network; without one it is given at sending), arrival check with received quantity, condition, note and Reject → query, lab verdict while typing, packing 2 % limit | screens of 7.1 not listed here | 4–5 days | 6–8 weeks |
| D | **Screen by screen** | C + the screens of 7.1: pipeline, inventory, chain ledger, queries, Warehouse Inward, crop layers and GAP fields, client and farmer detail, FPO, procurement import, user edit and archive, audience views, mark delivered, first-run wizard | prototype faults (section 9) are not copied | 8–10 days | 3–4 months |

"Work here" means build sessions like the ones that produced Phases 0 to 4, all three test suites green at the end.
Both columns are estimates, not measurements.

**What does not come back in any option** (it would undo what the rebuild was for): rules checked only by the browser;
a hand-off check that passes with failed items; saving after a "save anyway?" dialog; panels that do not fit a phone.

**Needs a separate decision before it is built** (option D): the farmer's Aadhar last four digits, bank account and IFSC.
PRD §9 keeps farmer identity data away from the public page; storing bank details at all was not in the PRD.

## 12. What each option does to the plan

| Item | A | B | C | D |
|---|---|---|---|---|
| Database (migrations) | none | none | stage forms and checks (1–2 migrations); queries / rejection | + Warehouse Inward stage, crop GAP fields, FPO, client and farmer columns |
| PRD | unchanged | §10 note on layout | §5.3, §6 (F5–F10), §7 amended | + §6 F1–F4, F13, §8 |
| End-to-end tests to rewrite | 0 | most (menu and layout change) | most + new fields | all |
| Hindi labels to add | ~10 | ~40 | ~200 | ~350 |
| Staging run-sheets (Antigravity IDE) | can go on now | database parts can go on now; app deploy after B | wait for the new migrations before A1 of Phase 4 | same |
| Acceptance by a non-builder, Hindi review with operators | can go on now | after B | after C | after D |

What A took, as done on 4 October (the column above was an estimate): two migrations, not none (28 for the data leak,
29 for the capture time and the lab verdict before saving: both faults needed the database); 67 English and 19 Hindi
dictionary entries; no existing end-to-end test rewritten, one assertion changed (the season export's header, whose
time column was renamed on purpose) and one strengthened (the practice strip's words as shown).

What B took, as done on 4 October (again against the estimates above): no migration; one seed file changed (a
display-only `section` name on each of the 64 fields); 104 new dictionary entries in each language and 12 reworded;
most end-to-end tests were **not** rewritten (they find things by role and label, and the roles and labels were kept):
about eight assertions in four files changed because a word or a title changed, and one new file of 6 tests holds the new frame in
place. Not built with B, though the prototype has them: the form in a slide-up panel, the review pop-up, toasts, the
detail panels behind the number cards, the first-run wizard and welcome cards.

## 13. Recommendation

**Taken as far as B: Veda chose A, then B, on 4 October 2026.** The step from B to C (the fields and the arrival
check) is open. The text below is kept as it was written, for that decision.

Option **C**, in this order: faults → look and frame (B) → stage fields and arrival check.
Then decide on the screens of 7.1 one group at a time, with the first client's chain in hand.

Reasons:

1. What the prototype records beyond the weights (dates, lab identity, buyer and contract, transport documents) is what
   an importer or auditor asks for. Without it the sealed record proves less than the prototype's.
2. The prototype's frame is the better one on a laptop, where managers, the lab and the sales desk work. The built
   system's frame is the only one that works on a phone. Both can be had: the engine is the same.
3. The screens of 7.1 differ in value. Pipeline, inventory and the ledger page are read-only and cheap. Warehouse Inward
   matters only if a client's chain has a warehouse. FPO, client detail and farmer bank data are not needed to seal a lot.

## 14. Limits of this comparison

| Area | How far it was compared |
|---|---|
| Stage forms, arrival check, review, save | field by field, from both sources and from both runs |
| Look, frame, menu, first screens | from both sources, both runs and the pictures |
| Set-up screens (clients, crops, farmers, users, scopes) | screen by screen and form by form; the prototype's archive / restore / transfer flows were read, not compared step by step |
| Dashboards | which cards and lists exist; the formula behind each number was not compared |
| QR, label, public page, ledger, flags, queries | screen by screen from the runs; not line by line |
| A handset | pictures were made in a 390 px browser window, not on a phone |

A line-by-line pass over the last four areas was started and stopped by a usage limit; the inventories it needs are
complete. It would refine section 7, not change sections 1 to 6.

Pictures: nine screens side by side on a laptop and four on a phone were sent with this document. All 1,445 pictures
and the two inventories stay in the build workspace and can be published on request.
