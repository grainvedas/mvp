# Packs, proof and blocks, release 3: migration 50 and the app, onto the practice system

Veda, 15 October 2026, "ok complete everything" (decision G19). Release 3 of the operator-stages plan. Item 45 in
`docs/FIX_LIST.md`. **This one script pushes whatever of releases 1 and 2 is still waiting (migrations 48 and 49),
then 50, with the app of all three: one run.** If 48 or 49 was waiting, do their run sheets' "Afterwards" too
(`docs/RUNSHEET_operator_template.md`, `docs/RUNSHEET_trust_numbers.md`), before this one's.

- **Batch codes from the system (G1).** Packing no longer asks for one: the save gives `TCUP-KNM-KH26-B0001` (client,
  crop, season, a number that never repeats). Codes typed before are kept as they are.
- **One serial, one label per pack (G8, Part D).** Each pack gets `<batch>-0001`, `-0002`, …; "Print labels" makes
  one label per pack, each with its own QR. A second print needs a reason. A damaged or lost pack is voided with a
  reason. Best-before = the day packed + the crop's shelf life (the crop page, when set).
- **The summary before release (G9).** At the QR step the person reads what the QR will carry (every step verified, no
  open flag, the lab's verdict, GI, farmers, packs) and ticks "I have read this summary" before sealing.
- **Release status and recall (G10, C9).** On the sealed record, the Client Manager (or the State Manager) can set
  "Under investigation" or "Recalled", with a reason. A recall is final and shows on every pack's page.
- **The public page (Part D).** No farmer names: the village, the district, the season. A pack scanned before release
  says "Packed, not yet released". Every scan is counted (time and code only).
- **Lab proof (C5).** A lab record names the lab, the report number and date, and attaches the report before it is
  verified. The demo scopes are set not to ask; every new scope asks.
- **Blocks.** GI and non-GI lots are not batched together; an export release by the Client Manager needs the client's
  written acceptance attached. **Delivery (G12):** the transit loss is recorded when the goods arrive, not at dispatch.

**Only when Veda has said so.** This pushes the waiting migrations to the practice database **and pushes to the main
branch**. Production is not touched. Nothing is changed or deleted. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-packs-release.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 50 waiting (or 49 and 50, or 48, 49 and 50); the functions current. **Asks you to type `PACKS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: what is waiting, in order | the push fails (nothing of that migration is applied) |
| S1b | Reads back what was filled for the records already there (read only): `records=… links=… packing_records=… batches=… packs=… releases=… seals=…` | the read fails, a scope has no short code, a record built on another has no link, or a seal has no release status |
| S2 | Smoke check **47** rows (new: `packs and release`), the new rules in place, the change log intact (31 tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: PACKS AND RELEASE ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 20 minutes, phone width; practice data in KH26 gkp)

The practice scope asks for the lab report (a new scope's default). Have a small PDF or a photo at hand for it.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram (State Manager) | Crops → Kalanamak Rice → Shelf life (days): 365 → Save | the crop card shows it |
| 2 | p | Procurement → farmer 1, 100 kg, 2 bags, 1 kg tare, moisture 12 / 12.1 / 11.9 → Save | `TCUP-KNM-KH26-GKP-P-000n` |
| 3 | Lucky | QC → the lot → tick, Verify → Record QC: sample 1, readings, then **Lab, Report number, Report date** and **Lab report** (the file) | Review stays off until the four are there; saved `…-QC-000n` |
| 4 | the next stage | the lab record → Verify | verified (without the file it would say "Attach the lab report before this lab record is verified") |
| 5 | Packing (if the scope has it) | Record Packing: packets, wastage; **no batch code to type** → Save | "Batch TCUP-KNM-KH26-B0001: its packs have their serial numbers"; **Print labels** → one label per pack; print again → asks why |
| 6 | QR | the lot → tick, Verify | "Before release: what the QR of … will carry" with ✓ lines; Activate and seal stays off until "I have read this summary" is ticked |
| 7 | anyone, phone camera | scan a pack label (or open `/p/<serial>`) | before step 6: "Packed, not yet released"; after: the journey, "Grown in <village>, <district>", **no farmer's name** |
| 8 | Client Manager | the sealed record → Release → Recalled, reason "practice recall, ignore" → confirm | the pack's page and the lot's page say "Recalled: do not use this lot" with the reason |
| 9 | Shipment (if the scope has it) | the shipment record → Delivery: what arrived, the date → Confirm | "Lost in transit: … kg"; for export the proof of delivery is asked first |

Claude can drive these in the browser pane once each person has signed in.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 50 adds tables (`batch_code_counters`, `pack_batches`, `packs`,
`label_prints`, `release_events`, `scans`, `deliveries`), columns (`scopes.qc_report_required`,
`crops.shelf_life_days`, `attachments.label`), triggers and functions, and edits three forms (Packing loses the batch
code, Shipment the transit loss, QC gains the lab fields). Records already there keep their payloads; their packs and
release statuses are new rows. A scope that should not ask for the lab report: its Client Manager asks Claude for a
correction through the door (`app.owner_correction`), not a bare update.
