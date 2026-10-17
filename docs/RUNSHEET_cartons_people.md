# Cartons, Reports to and departments, release 11: migration 58 and the app, onto the practice system

Veda, 16 October 2026: "There should a mechanism to choose packs and in future there will be more than 1 lakhs packs";
"carton size - cm sets them in the pack list / Pallets - no idea / Carton labels - share suggestion / At loading - share
suggestion / proceed with 58"; on the HR Admin's screens (Minal) "report to - it sees all people which should not be the
case", "department ... there should be drop down" (decision G24). Item 53 in `docs/FIX_LIST.md`. Releases 1 to 10
(migrations 48 to 57) are on staging since 16 Oct 2026 (the last, 57, at 21:11, 978fe0d); this script expects
**migration 58** waiting and nothing else.

- **Cartons.** The Client Manager sets "Packs per carton" on a pack type (Set-up lists → Packs). Packing then puts the
  packs in cartons by itself: carton `<batch>-C0001` holds packs 0001 to 0020, the next twenty go in C0002, the last
  carton holds what is left. A pack voided opens its carton. A pack type with no carton size packs as before.
- **Carton labels.** The labels page of a packing record has "Pack labels" and "Carton labels": an A4 sheet of 8 (any
  printer) or a 100 × 150 mm label (a label printer). Each label: a big QR of the carton's code (the code only), the
  code, how many packs and of which type, which packs (0001 to 0020), the crop, season, packing day and client.
- **Orders.** A sale of packs sets aside cartons: those chosen (the buyer asked for them, or they are at the front),
  else the oldest free ones, then packs of a carton not taken whole. Never what another order set aside. The record
  says "Set aside: 2 cartons (40 packs)".
- **Loading.** The Shipment person scans each carton once (it counts all its packs) and any loose pack; nobody opens a
  carton. The phone says at once "Not set aside for this order" or "Carton opened: scan its packs one by one". The
  server checks everything again on sets, so 1 lakh packs (about 5,000 cartons) stay quick.
- **No pallets** for now: they can be added later above cartons without changing anything recorded.
- **People.** Reports to offers only the managers of the person's state (band Manager or above, or someone who holds a
  seat: admin, HR Admin, State Manager, Client Manager; head-office people with no state for everyone), grouped by state
  with their seat and band. The buddy: colleagues of that state. The department: a list the HR Admin keeps on the
  Templates page (it starts with nine). The database refuses anything else, whoever sends it; the spreadsheet import
  leaves it out with a warning. A department or manager chosen before stays until someone changes it.

**Only when Veda has said so.** This pushes migration 58 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is changed or deleted (one form definition: the Commercial form's cartons). The
seven server functions are unchanged. Between S1 and S3 (a few minutes) the old app works; its HR forms still list
everyone, and the database refuses a manager or department that is not allowed.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-cartons-people.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 58 waiting; the seven functions current. **Asks you to type `CARTONS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 58 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `commercial_form=new stages=17 tables=new departments=9 rule=yes` | the read fails, or anything else |
| S2 | Smoke check **56** rows (new: `cartons people choices`), the new rules in place, the change log intact (56 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CARTONS AND PEOPLE CHOICES ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser. Rows 5 and 6 of release 10's checks
(a domestic shipment of packs with its codes; its buyer link) are done here too, with cartons.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Set-up lists → Packs: a pack type (test) → Edit → Packs per carton 20 → Save | the card says "Packs per carton 20"; 0 or 1001 is refused in plain words |
| 2 | Packing (Lucky if he holds it) | A practice packing record of that pack type (e.g. 69 packs) → its labels page → Carton labels | "Carton labels (4)": three of 20, the last of 9; A4 sheet of 8 and 100 × 150 mm both show; print preview fits the page |
| 3 | Commercial | A domestic order of 40 packs of that lot → Cartons: tick "Choose the cartons", add C0003 → Save | "20 of the 40 packs in the cartons chosen"; the record says "Set aside: 2 cartons (40 packs)" (C0003 and C0001) |
| 4 | Shipment | Record Shipment of that order: type C0003 and C0002, then C0001 | C0002 "Not set aside for this order" with Remove; with C0003 and C0001 "40 of 40 packs loaded · 2 cartons"; saved |
| 5 | Lucky | That shipment's buyer link, opened in a private window (release 10's row 6) | the LR and the e-way bill; no vehicle number |
| 6 | Minal (HR Admin) | Templates page → Departments: add "Seed Production (test)", then retire it | it shows, then "Retired"; Add joiner no longer offers it |
| 7 | Minal | Add joiner (do not save), based in Uttar Pradesh: Reports to, Buddy, Department | Reports to: only managers of UP and head office, each with seat and band, grouped by state; not the operators; Department a list |
| 8 | Minal | A person's page → About the person → Edit | the department a list (a typed one before shows "(typed before; not on the list)"); Reports to as in row 7; Save keeps what was not changed |

Clean-up: the practice records stay (named "(test)"); the department of row 6 stays retired; a buyer link made for
row 5 is revoked with a reason.

Not checked on staging (the tests cover them): a correction of a packing record voiding its cartons, an opened carton
refused at loading, a pack and its carton both scanned, the import's warnings, an HR resource asking another state's
choices (`tests/53_cartons_people_choices.sql`, `web/tests/release58.test.tsx`, `e2e/phase30.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 58 adds two tables and three columns, adds new functions, replaces seven
(packing's packs, voiding a pack, the save's rule for sales and shipments, the order's codes, the public pack data,
the import, a person's HR page data) and adds the Commercial form's cartons field. A lot packed before has no cartons
and works as before. A person whose manager or department is refused is saved again with one from the list.
