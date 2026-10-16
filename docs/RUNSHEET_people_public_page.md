# Another client's people, the public page, the packs loaded, release 10: migration 57 and the app, onto the practice system

Veda, 16 October 2026: "G20 - NO, client info should not be shared", the public page's same-person line "should not
appear", "make a good UI current is so boring", Part H, the shipment's pack codes; then "rest all ok and proceed with 57"
(decisions G20, G21b, G22, G23). Item 52 in `docs/FIX_LIST.md`. Releases 1 to 9 (migrations 48 to 56b) are on staging
since 16 Oct 2026 (the last, 56.1, at 11:22, d7ad030); this script expects **migration 57** waiting and nothing else.

- **Another client's people (G20).** A Client Manager no longer sees a person who works now for another client: not in
  his scope's roster pool, not in People, not that person's page, and no "+N elsewhere". His own client's people and
  the free people of his state as before; a person shared with his client stays, without the other client's work. HR
  and the admin see everyone; to borrow a busy person, the Client Manager asks HR.
- **The public page (G21b and "a good UI").** It never says that one person recorded and checked a step. Each step
  says "Checked by another person" only where that is true. The new look (the design system's provenance story): the
  crop and its GI tag in a deep green hero, "Genuine pack, sealed record", the pack's scans (how many, the first city,
  "No copies" or "Being checked"), the villages by share with their farmers (never a name), the journey step by step,
  the lab readings beside each market's limit, the pack's details; Hindi throughout. An export names its country; a
  domestic dispatch's place is not shown.
- **The single-stage operator (G22).** "2 to check in · 3 checked in, ready"; the waiting list a card per lot (number,
  farmer · village, kg left) with the village filter and the search; "Collection Batch" and "Lot Inward" without their
  long words (what the stage is shows under the title); the tabs in one row; the filters on two rows on a small phone.
- **The packs loaded (G23).** A shipment of packs asks the codes loaded, **domestic too**. The phone checks each code
  as it comes (this order's batch, void, shipped already and on which shipment, twice), with Remove; a range ("from
  …-0009 to 0010"); "Add all N packs of batch X" when the order takes all that is left; typing or pasting; the camera
  keeps scanning on phones whose browser can read QR codes (Chrome on Android). The buyer's page shows a domestic
  shipment's e-way bill and LR, not the vehicle number.

**Only when Veda has said so.** This pushes migration 57 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is changed or deleted (one form definition: the Shipment's pack codes). The seven
server functions are unchanged. Between S1 and S3 (a few minutes) the old app works, but **do not record a domestic
shipment of packs then**: the database asks its codes and the old form has no box for them.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-people-public-page.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 57 waiting; the seven functions current. **Asks you to type `PACKS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 57 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `shipment_form=new stages=17 functions=new public_same_person=no` | the read fails, or anything else |
| S2 | Smoke check **55** rows (new: `people public page packs`), the new rules in place, the change log intact (54 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: PEOPLE, PUBLIC PAGE AND PACKS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 25 minutes, phone width; practice data, clearly fake)

Each person signs in themselves; Claude can then drive the steps in the browser.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Nobody signed in (a private window) | A pack's page `/p/<code>` of a released lot (or `/verify/<code>` of a sealed lot) | the new look: the green hero with "Genuine pack, sealed record", the scans' tiles (a pack), "Where it was grown", the journey with "Checked by another person" on the steps that were, the lab readings; **no line about the same person** anywhere; no farmer's name; English and हिन्दी |
| 2 | Same | A lot where one person held two stages in a row (a practice scope with that roster), if there is one | the page does not say so; that step has no "Checked by another person"; the closing sentence is the plain one |
| 3 | Lucky (Client Manager) | Season Scopes → a scope's People: the pool; People | a person who works now for another client is not there (no "for another client" line, no "+N elsewhere") |
| 4 | An operator with one stage (a Collection Batch operator, if staffed) | Home; the stage | "N to check in · M checked in, ready"; the title "Collection Batch" with "One collection point: …" under it; the tabs in one row; the lots as cards with the farmer and village; the village box and the search, on two rows on a small phone |
| 5 | Shipment (Lucky holds it) | A domestic order of packs (release 7's checks) → Record Shipment | "Pack codes loaded" is asked; codes typed are checked as they come (a wrong one says "Not this order's batch", with Remove); "Add a range" adds a run; the count per pack type; on an Android phone "Scan packs with the camera" keeps scanning |
| 6 | Lucky | That shipment's buyer link (as in release 9's checks), opened in a private window | the LR and the e-way bill; no vehicle number |

Clean-up: the practice records stay (named "(test)"); a buyer link made for row 6 is revoked with a reason.

Not checked on staging (the tests cover them): the person who is offered again once his work for another client ends,
a correction's own codes, the camera's beep (`tests/52_people_public_page_packs.sql`, `web/tests/release57.test.tsx`,
`e2e/phase29.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 57 adds two functions, replaces ten (the people lists, the public page's
data, the buyer's page, the shipment's rule) and changes the Shipment form's pack codes field (for both markets, where
the lot has packs). A shipment refused for its codes is saved again with them. The public page reads only what it read
before, less the same-person flag, plus the villages, the markets' limits and a pack's scans.
