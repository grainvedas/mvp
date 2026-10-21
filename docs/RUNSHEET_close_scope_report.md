# Close a scope and the season report, Phase 1 release 5: migrations 63a and 63 and the app, onto the practice system

Veda, 21 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 1 Part D, with the closing check of
E2.1 and E2.5; "ok continue". Item 59 in `docs/FIX_LIST.md`. Release 4 (migration 62) is on staging since 21 Oct 2026,
10:47 IST (30924c2); this script expects **migrations 63a and 63** waiting and nothing else.

- **Close a scope (D1).** The Client Manager opens the scope dashboard → **Season report** → **Close scope…**. The
  closing check lists every blocker: records pending verification, lots waiting for lab results, open flags, the
  kilograms left on each lot, export shipments without a delivery, packs never released (per batch: released / old data
  / not released / void), and a stage whose kilograms do not add up (in red). The first two are cleared at their stage;
  the others are answered with a reason (10 to 250 characters): a flag carried over, kilograms written off, "awaiting
  POD", packs written off, a difference explained. **Request the close** is offered only when the check is clear.
  The **State Manager** of the scope's state confirms (or declines with a reason); the requester never confirms. Both
  are ledger blocks; each write-off is a ledger block of its own.
- **After the close** the scope is read only (no record, flag, void, setting); a recall, a scan, a buyer link, a bill of
  lading and the proof of delivery of a shipment carried over as "awaiting POD" stay possible. The State Manager
  **reopens** with a reason; closing again gives version 2 and version 1 shows **Superseded**. The people's assignments
  end at the close, as they did before (a manager records with a reason after a reopen).
- **The season report (D2–D4).** Issued by the server with its reference (`GV-SR-000001` …) and its data kept as issued;
  the PDF (A4) and the Excel file (one sheet per section), each in **English and Hindi**, each in the **shareable** and
  the **internal** copy (8 files), are made **in the browser of the person who confirms the close or makes the interim
  report** and stored; keep that page open until "Making the report's files" is gone (if it is interrupted, "Make the
  files" finishes it). Title "Verified traceability statement: season report", the brief's footer, never "certificate"
  otherwise; an interim report says "Interim: season not closed" on every page. **Verify this document**: the QR on the
  cover opens `/d/<reference>` (Valid, Superseded or Withdrawn; issued on, issued to; each file's SHA-256).
- **Who:** an interim report by the Client Manager or the State Manager, any time before the close; the client's own login
  (tcup) downloads every version, both copies, and closes nothing; the admin downloads the shareable copy and reads the
  **billing count** (Overview → "Season reports issued", per client per month).

**Only when Veda has said so.** This pushes migrations 63a and 63 to the practice database and **pushes to the main
branch**. Production is not touched. Nothing is deleted or rewritten: new tables (`scope_closures`, `reports`), two new
columns of `lot_closures` (`kind`, `closure_id`), new functions, the bucket `reports`; replaced: the scopes' guard (a
signed-in person closes a scope only through its request), the mass balance and the exports (a write-off is its own kind
of closure), the lot's trace. The seven server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-close-scope-report.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 63a and 63 waiting; the seven functions current. **Asks you to type `REPORTS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: 63a (the ledger's new kinds of block), then 63 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `tables=new functions=new guard=yes bucket=yes closed_scopes=… reports=0` | anything is not as migration 63 leaves it |
| S2 | Smoke check **61** rows (new: `close scope report`), the rules in place, the change log intact (58 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLOSE AND SEASON REPORT ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data)

Each person signs in themselves; Claude can then drive the steps in the browser. Rows 3 to 6 close a practice scope:
choose which one (the suggestion is **Practice godown (test)**); a closed scope can be reopened (row 6).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Bansi's dashboard → Season report → **Generate interim report**; wait for "Making the report's files" to go | "Interim report 1 · GV-SR-…", Valid, files of both copies: PDF English, PDF हिन्दी, Excel English, Excel हिन्दी |
| 2 | Lucky | Open the PDF English and the PDF हिन्दी of the shareable copy | A4; "Interim: season not closed" on every page; the cover with the QR; headline figures, mass balance (sold ≤ procured printed), origin, quality, packing, sales and shipments, QR, chain, ledger, open items; no farmer's name or price; the Hindi text joined correctly |
| 3 | anyone, private window | Scan the PDF's QR (or open `/d/<reference>`) | "Valid", issued to Test Client UP, the 8 files' SHA-256 |
| 4 | Lucky | The chosen scope → **Close scope…** | the check lists each blocker, with the kilograms left per lot; answer each (or clear it at its stage) → **Check again** → "Nothing blocks the close." → **Request the close** |
| 5 | Ram (State Manager) | The same dashboard → **Confirm the close**; wait for the files | "This scope is closed"; "Final, version 1"; 8 files; the scope's records read only |
| 6 | tcup | The same dashboard | the reports listed, every file downloads (internal copy too); no "Close scope…", no "Reopen" |
| 7 | the admin | Overview → "Season reports issued" | this month: Test Client UP, 1 final, 1 interim |
| 8 | Ram (optional) | **Reopen scope…** with a reason | the scope active again; the final report still Valid until the next close |

Not checked on staging (the tests cover them): every blocker of the check, a request refused, a second request, the
requester confirming, a pack voided or a flag raised on a closed scope, a recall after the close, version 2 and
"Superseded", a withdrawn report, the admin refused the internal copy, a file stored twice
(`tests/58_close_scope_report.sql`, 57 checks and 12 controls; `web/tests/release63.test.tsx`; `e2e/phase35.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten. A scope closed by mistake is reopened by its State Manager with a reason. A report
that is wrong is withdrawn by the State Manager (the verify page says "Withdrawn"). Files not made ("Make the files" on a
report) are made by the Client Manager or the State Manager from the report's data as it was issued.
