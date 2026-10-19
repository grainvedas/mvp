# Fixes and the client login reads only, Phase 1 release 1: migration 59 and the app, onto the practice system

Veda, 19 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 1 Parts A and B, and "ok start" to
the plan's twelve defaults (`claude/clients-reports-plan.md` in the project). Item 54 in `docs/FIX_LIST.md`. Releases 1
to 11 (migrations 48 to 58) are on staging since 17 Oct 2026 (the last, 58, at 11:40, 760bcfa); this script expects
**migration 59** waiting and nothing else.

- **A pack before release.** Its QR, on `/p/<serial>` and now on `/verify/<serial>` too, says "Packed, not yet
  released" with the crop, the serial, the batch code and the date packed. Nothing else: no seller, no farmers, no
  results. A voided pack says it is voided; a code scanned far apart keeps its copy warning, without the
  seller's name. "Code not found" only when there is neither a lot nor a pack of
  that code.
- **The same person.** A step recorded and checked by one person says "Recorded and checked by the same person." on
  that step (English and Hindi), on the public page and in the journey.
- **Units, the lab, the BL.** Each reading's unit comes from the scope's test parameters (else the library), on every
  page and in the CSV. The lab's name and accreditation number come wherever the report number is. A BL added later
  no longer shows "BL pending".
- **One file, two kinds of document.** Attaching a file already attached as another kind of document (the same lab
  report as a delivery proof, say) asks a reason (10 characters or more), kept with the file and in the Audit log.
- **Old data.** A typed batch code already in use is refused, whoever sends it. A scope with records of before system
  batch codes is marked "Practice (old data)" on its screens and in its exports; S1b lists them.
- **The client's own login reads only** (tcup, Prasaadam's client view). The database refuses every write it sends:
  records, corrections, checks, files, flags, buyer links, labels, lists. Its menu has no stages; its home has no
  "Needs action" but "Waiting on GrainVeda" (records not yet checked, samples at the lab) and "Open flags". Its
  Farmers page shows the phone as `••••••` and the last four digits. It raises no flag: it tells its Client Manager.
- **A Client Manager sees no email** of anyone, and a phone only of people on his own scopes' stages. HR and the
  State Manager see what they saw.
- **Practice data (A7).** S1c adds Siddharthnagar to Kalanamak's GI area if it is missing. The labels print the GI
  tag only for a lot whose GI status is GI.

**Only when Veda has said so.** This pushes migration 59 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is changed or deleted, except: scopes of old data get the note, and one crop's GI
area gets one district. The seven server functions are unchanged. Between S1 and S3 (a few minutes) the old app works,
but the client login's writes are refused in the database's words and its Farmers page is empty.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-fixes-client-reads-only.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 59 waiting; the seven functions current. **Asks you to type `READS ONLY`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 59 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `columns=new reads_only_tables=40 upload_policy=new emails_closed=yes old_data_scopes=<n>`, then lists the scopes marked "Practice (old data)" | the read fails, or anything else |
| S1c | Practice data: Kalanamak's GI area includes Siddharthnagar; prints the GI area | the change or the read fails |
| S2 | Smoke check **57** rows (new: `fixes and client reads only`), the new rules in place, the change log intact (56 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: FIXES AND CLIENT READS ONLY ON STAGING` or `RESULT: STOPPED`. Send Claude the S1b lines (the
old-data scopes go in the report).

## Afterwards (about 30 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | tcup (the client login) | Sign in; open the menu | no stage pages, no "Needs action"; "Waiting on GrainVeda" and "Open flags" on the home; nothing to tap that records |
| 2 | tcup | Type `/work/<a scope>/procurement` in the address bar | back on the home |
| 3 | tcup | Farmers | names and villages; each phone `••••••` and four digits; no buttons |
| 4 | tcup | A record of its scope | no "Raise a flag", no "Add a file"; the lab with its accreditation number on a QC record; "Practice (old data)" on an old-data scope |
| 5 | Lucky (Client Manager) | People & access | no email anywhere; a phone only for the people on his scopes' stages |
| 6 | anyone, private window | A pack's QR of a lot not yet released, on `/verify/<serial>` | "Packed, not yet released", the crop, the serial, the batch code, the date packed; nothing else |
| 7 | anyone, private window | A released lot's page where one person recorded and checked a step | "Recorded and checked by the same person." on that step; readings with their units; the lab's name |
| 8 | Lucky | Farmers → New farmer "Siddharthnagar GI (test)": district Siddharthnagar, GI land 1 acre; the State Manager verifies it | the farmer is verified with GI land |
| 9 | Procurement | A practice lot of that farmer (Kalanamak scope) → the record | the GI badge "GI"; its labels print the GI tag (a lot of a farmer outside Siddharthnagar's list prints none) |
| 10 | Lucky | Attach the same PDF to a record twice as two kinds (lab report, then delivery proof) | the second asks "Why attach this same file here too?"; with a reason it is attached, and the Audit log says so |

Clean-up: the practice records stay (named "(test)"). Siddharthnagar stays in Kalanamak's GI area (it is in the real GI
area).

Not checked on staging (the tests cover them): every write refused from the client login by direct calls (40 tables,
files, flags), the storage upload, the typed batch code refused for the service role, `app_users` email closed, the
isolation of `app.param_units` (`tests/54_fixes_client_reads_only.sql`, `web/tests/release59.test.tsx`,
`e2e/phase31.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 59 adds two columns (`scopes.data_note`, `attachments.dup_reason`), new
functions, a read-only trigger on 40 tables, a changed upload policy and column grants on `app_users`; it replaces the
public pack and lot data, the buyer page data, the journey, the record's data, People's lists (and "Assign" worked
out once a page: faster for a Client Manager), and the two attach functions. If the client login must write again (it should not), the trigger is dropped by a new migration; nothing
it refused was stored.
