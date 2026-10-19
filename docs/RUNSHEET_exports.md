# The exports, Phase 1 release 2: migration 60 and the app, onto the practice system

Veda, 19 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 1 Part C, and "release 2". Item 56 in
`docs/FIX_LIST.md`. Release 59 (Phase 1 release 1) is on staging since 19 Oct 2026, 17:47 IST (7183569); this script
expects **migration 60** waiting and nothing else.

- **Two copies.** The journey of a lot and the season of a scope each come as a **shareable copy** (no person's or
  farmer's name, no buyer, no price, no payment reference, no raw values) and an **internal copy** (all of those, the raw
  values in the last column, a footer that says "INTERNAL COPY … Do not forward it"). The server makes both; the
  shareable copy never reaches the browser with a name or a price.
- **Who gets which.** The internal copy: the scope's Client Manager and State Manager, the people who hold a stage on
  it, and the client's own login (tcup). Anyone else who sees the scope (the admin) gets only the shareable copy; the
  internal button does not show for them, and the server refuses it.
- **Readable.** Column names in English or Hindi (the reader's language), each reading in its own column with its unit,
  times in IST. Added: each farm-gate lot's share, GI status, farm-verified, batch code, packs and serial range, the lab
  and its accreditation number, the same-person mark, the loss on the floor.
- **The season is one Excel file** with three sheets: Heading (client, crop, season, place, status, copy, when made),
  Summary (each stage: records, kg in and out, floor loss; the season's totals; each batch with its serial range) and
  Records (every record). The journey is a CSV.
- **Every download is in the Audit log** ("export_downloaded": who, which, which copy, how many rows).
- **The journey prints** with its own heading and page numbers, and without anyone's name.
- **The public lot page names the lab**: "Tested by … (accreditation …)".

**Only when Veda has said so.** This pushes migration 60 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is changed or deleted: new functions, and the public lot data gains the lab. The
seven server functions are unchanged. Between S1 and S3 (a few minutes) the old app works as before (its old CSV
buttons build the files in the browser, as they did).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-exports.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 60 waiting; the seven functions current. **Asks you to type `EXPORTS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 60 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `functions=new granted=yes internal_rule=yes audit=yes public_lab=yes` | the read fails, or anything else |
| S2 | Smoke check **58** rows (new: `exports`), the new rules in place, the change log intact (56 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: EXPORTS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 20 minutes, phone width; practice data)

Each person signs in themselves; Claude can then drive the steps in the browser. Downloads land in the browser's
download folder; Claude reads them there only if you say so.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | A sealed lot of Bansi → Journey & export → "Download journey (shareable)" | a CSV: Step, Record, Stage, … Share (%), GI status, Farm verified, Lab, … ; no farmer's or person's name, no price; the last lines "Shareable copy made by GrainVeda …" |
| 2 | Lucky | The same page → "Internal copy (names and prices)" | the farmer's name, Recorded by, Checked by, Price paid, Transaction ID; "Entered values (raw)" last; the footer "INTERNAL COPY … Do not forward it" |
| 3 | Lucky | The same page → Print / save as PDF (preview only) | a heading "GrainVeda · Journey of …" and "Shareable copy · made …"; page numbers; no names |
| 4 | Lucky | Bansi's dashboard → "Season export, Excel (shareable)", then the internal one | an .xlsx with Heading, Summary, Records; Summary lists each stage with kg and floor loss, the season's totals, each batch's serial range; Heading says "Practice (old data)" (Bansi is an old-data scope) |
| 5 | tcup (the client login) | A journey and the season | both copies offered and downloaded |
| 6 | Veda (admin) | The same journey; then Audit log | only the shareable button; the Audit log has an "export_downloaded" line for each download above (and release 59's "same_file_attached" from the run sheet) |
| 7 | anyone, private window | `/verify/GV-8B1E15E15317` | in "Lab tests": "Tested by Practice lab (test) (accreditation TC-0000)." |

Not checked on staging (the tests cover them): another client's person refused, the shares adding to 100 %, a
withdrawn record's when and why, the times kept on a phone (`tests/55_exports.sql`, `web/tests/release60.test.tsx`,
`e2e/phase32.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 60 adds functions (`app.export_journey`, `app.export_season`,
`app.may_internal_copy` and their helpers) and replaces the public lot data (the lab added). The old CSV buttons are gone
from the app; a download that fails says why in plain words, and the journey page still shows every step.
