# The evidence pack, Phase 3 release 4: migration 71 and the app, onto the practice system

Veda, 27 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 3 Part E1, with item 69 (1); "ok
proceed further" (to the plan sent with release 3's report). Item 70 in `docs/FIX_LIST.md`. Phase 3 release 3 (migration
70, client orders) is on staging since 26 Oct 2026 (head 9efffb4); this script expects **only migration 71** waiting.

- **Made at the seal.** When a lot is sealed at QR the server issues its evidence pack: the shipment's, where the lot
  went out in one (else the sealed lot's own); and, where the shipment is a part of a client order, the order's pack,
  with **one section per scope**. A pack that cannot be made never stops a seal (it is in the Audit log as
  `evidence_pack_failed`, and is made on request).
- **On request.** On the shipment's (or the sealed lot's) record and on the client order's page, whoever reads the whole
  scope and runs it (its Client Manager or State Manager) or the admin makes a **new version**: the earlier version is
  kept, marked Superseded by the new one. Never a stage's operator, never a client account.
- **Its sections** (the brief's table): header (client, scope, state, crop, season, lot or shipment, buyer, reference
  `GV-EP-000123`, version, date); origin (villages and districts with their shares, distinct farmers, GI-area and
  farm-verified shares, GI status); mass balance (procured → milled with its recovery against the 70 % ceiling → QC
  sample → packed with wastage → sold → shipped, floor losses; sold never above procured); quality (the verdict per
  market, the lab and its accreditation, the report number and date, the file's fingerprint; a release on the client's
  written acceptance said as such, never "Passed"); documents (the shipment's papers, the export documents, each file's
  fingerprint); chain (each stage: who recorded, who verified, dates, same-person marks, returns and flags, client
  staff); packs (batch codes and serial ranges; the scanned serials of an export shipment); seal and ledger (the seal,
  the ledger fingerprints of the key blocks); verification (the reference, the verify page, the data's SHA-256).
- **Two copies.** The shareable copy (the default; the one on the buyer link) has no farmer's name or phone, no price,
  no internal ID. The internal copy names the farmers and, where the scope records prices, the sale's price; it is for
  the scope's people who may read it and the client's own login where allowed.
- **Its files.** Each copy as a PDF (A4, English and Hindi) and as JSON (the data, with the PDFs' SHA-256). The Client
  Manager or State Manager stores them ("Store its files"); their SHA-256 shows on **Verify this document** (`/d/<ref>`),
  which says what the pack is of and in how many scopes. A file is the same, byte for byte, whenever it is drawn: the
  buyer's PDF checks against the verify page.
- **Where.** "Evidence packs" on a shipment's and a sealed lot's record, a client order's page, the scope dashboard and
  the client's scope view (Portfolio). The buyer's page has an "Evidence pack" section (PDF English, PDF हिन्दी, JSON).
- **Billing.** The admin's "Reports issued" (Home) has an **Evidence packs** column: every pack issued per client per
  month, each version (at a seal or on request). No invoicing in the app.
- **Item 69 (1).** A Commercial record's worked-out "Market" reads "Domestic" / "Export" (and in Hindi), not the stored
  word. Item 69 (2) (Bansi's batch reads "Not GI": the practice crop's GI districts) is practice data: look at
  Kalanamak's GI area in the Crop Registry before reading GI on a pack.

Not in this release: the showcase page and badge, the lifetime switch-off of ended clients' accounts (release 5). Lots
sealed before this release have no pack; one is made on request.

**Only when Veda has said so.** This pushes migration 71 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: new columns on the reports (what a pack is of, its scopes;
the season reports keep theirs empty), a sequence, new functions and a trigger after a seal; replaced from their own
text, each change named in the migration: `app.issue_report` and `app.scope_reports` (the season reports' own versions
and list), `app.report_head`, `app.report_content`, `app.may_read_report_file`, `app.register_report_file`,
`app.may_write_report_file`, `app.may_write_report_object` (who reads and stores a report's files; a pack's JSON),
`app.public_document` (the verify page), `app.reports_issued` (the count), `app.buyer_content` (the buyer's page),
`app.cv_scope_data` (the client's scope view).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-evidence-pack.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 71 waiting; the seven functions current. **Asks you to type `PACKS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 71 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `columns=new functions=new seal=yes readers=yes buyer=yes billing=yes season_reports=… packs=0 sealed_lots=…` | anything is not as migration 71 leaves it |
| S2 | Smoke check **68** rows (new: `evidence pack`), the rules in place (70's and 71's), the change log intact (**72** tables), **one client and another** in 8 parts (`part 1 of 8: leaks=0 …` … then the sum), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: EVIDENCE PACK ON STAGING` or `RESULT: STOPPED`. Between S1 and S3 (if a run stops there) the old app
works as before; a seal already issues its pack on the server (the old app does not show it, and its verify page says
"season report" for a pack). Run the script again.

## Afterwards (about 25 minutes, phone width; practice data only)

Each person signs in themselves; Claude can then drive the steps in the browser. KH26 Bansi (Test Client UP), the
shipment `…-SH-0005` of release 3's checks (part of client order `ORD-TCUP-0001`, invoice `INV-TEST-70`). Staging has one
state with a mill, so the order's pack has one scope section here; an order's pack with two states' sections, who reads
which copy, the refusals and the count are in the tests (`tests/66_evidence_pack.sql`, 52 checks, 21 controls).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager; holds Shipment and QR at Bansi) | Bansi → QR Activation → `…-SH-0005` (verify it: attach its loading photo if the page asks) → Activate and seal | sealed, a `GV-…` code; this page shows no pack card to a stage's operator (Lucky sees it as the Client Manager) |
| 2 | Lucky | the shipment `…-SH-0005`'s record → **Evidence packs** | Version 1, `GV-EP-…`, Valid, "made at the seal"; the shareable and internal copies' PDF English, PDF हिन्दी, JSON; "Store its files (6)" |
| 3 | Lucky | Store its files (6), then PDF English and PDF हिन्दी of the shareable copy | each file "stored"; the PDF: A4, "Verified traceability statement: evidence pack", the footer on every page, the verify QR; no farmer's name, no price; the Hindi PDF in Hindi |
| 4 | Lucky | Verify page (or scan the PDF's QR) | "Valid", "Of: Shipment …-SH-0005", six files with their SHA-256 |
| 5 | Lucky | Client orders → `ORD-TCUP-0001` → Evidence packs | the order's pack, version 1 ("Client order ORD-TCUP-0001"), its PDF with Bansi's section and the invoice `INV-TEST-70` |
| 6 | Lucky | back on `…-SH-0005`: Make a new version → Make it | Version 2 ("made on request"); "Earlier versions (1)"; version 1's verify page: "Superseded · replaced by GV-EP-…" |
| 7 | Lucky | Share with buyer on `…-SH-0005` (7 days); open the link in a private window | the buyer's page has "Evidence pack": the order's pack; its PDF English is the stored file (Claude checks its SHA-256 against the verify page) |
| 8 | tcup | Portfolio → KH26 Bansi | "Evidence packs": the packs with their files; no "Store", no "Make" |
| 9 | the admin | Home → Reports issued | this month, Test Client UP: **Evidence packs** 3 (or more) |
| 10 | Lucky | a Commercial record's page (e.g. the part of `ORD-TCUP-0001`) | "Market: Domestic" (item 69 (1)) |

Not checked on staging (the tests cover them): an order's pack with two states' sections, the order's pack made again
at the second state's seal, a lot sealed without a shipment, a release on the client's acceptance in the pack, who may
issue (not the QC technician, not Commercial, not a client account), who reads which copy (the viewer of one scope: its
shipment's pack, not the order's), the internal copy's price only where the scope records prices, no internal ID in the
shareable copy, the season reports untouched by the packs (`tests/66_evidence_pack.sql`; `web/tests/release71.test.tsx`;
`e2e/phase42.spec.ts`, at 527 px).

## If something is wrong afterwards

Nothing was deleted or rewritten. A pack is never changed: a new version is made, and the earlier one says Superseded on
its verify page. A pack's stored file is never replaced. Send Claude the pack's reference and the page's words.
