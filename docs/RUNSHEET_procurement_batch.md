# Procurement and Collection Batch, release 5: migration 52 and the app, onto the practice system

Veda, 15 October 2026, "ok great proceed" (decision G19). Release 5 of the operator-stages plan. Item 47 in
`docs/FIX_LIST.md`. Releases 1 to 4 (migrations 48 to 51) are on staging since 15 Oct 2026, 19:54 (544b45d); this
script expects **only migration 52b** waiting: the first run (15 Oct, 22:43 IST) pushed migration 52 and stopped at S2,
because the smoke check's "public page data" rule caught 52's public page reading the batch's villages from what the
record worked out. 52b gives the villages through a helper (names only). The app was not pushed then: run it again.

- **Procurement (C1).** Where the lot was weighed (a collection point from the Client Manager's list, or "At the farm"),
  its GPS (taken from the phone when the form opens; "Use where I am now"; or two numbers typed or pasted), who
  delivered it (the farmer, his family, or an agent, named). If known: harvest date, condition, a photo of the scale
  slip. These three are **asked in every scope**; its Client Manager can turn that off (scope page, "The farm-gate
  form"). Warnings (saved, said in plain words): moisture above the crop's limit; three readings far apart.
- **The farmer card**: GI land, sold this season against what it should give, practice still to fill, GI area.
- **Price and payment**, only where the Client Manager turns it on: price per quintal, paid or pending, bank / UPI /
  cash and the **transaction ID only** (never an account number). Kept apart from the record and its ledger block;
  read only by the person who recorded the lot and the Client Manager. Paid later from the record page.
- **The farmer's receipt**, offered after the save (print or save as PDF from the phone).
- **Collection Batch (C2)**, was "Village Batch": the lots of **one** collection point (lots of two places are refused,
  naming them); the villages and their shares, the farmers and the moisture come from the lots (no village typed);
  "single origin" keeps it to one village; bags; re-weighed total (a loss above 1 % is a warning). **Works with no
  network**: the phone works it out as the save does and sends it when the network is back.
- **A13, where the lot went**: on a record and its trace, the records built on it, the packs and the seal.
- **Fixed from the checks of release 4**: GPS typed key by key is split only when the box is left; Places opens on the
  Client Manager's own state; "Moisture (%)" once in the parameter library.

**Only when Veda has said so.** This pushes migration 52 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is changed or deleted. The server functions are unchanged (build 2026-10-14).
Between S1 and S3 (a few minutes) the old app cannot record Procurement in a scope that asks where the lot was weighed,
nor a Collection Batch: wait for S3.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-procurement-batch.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 52b waiting (52 before it, if still waiting); the functions current. **Asks you to type `BATCH`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 52b (52 first, if waiting) | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `scopes=… asking_where=… recording_price=0 library=… library_second_names=… payments=0 batch_form=new` | the read fails, a scope records prices already, a payment exists, or the batch form is the old one |
| S2 | Smoke check **49** rows (new: `procurement batch`), the new rules in place, the change log intact (**42** tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: PROCUREMENT AND BATCH ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 20 minutes, phone width; practice data, clearly fake, in KH26 gkp)

Each person signs in themselves; Claude can then drive the steps in the browser.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager) | Season scopes → KH26 gkp → "The farm-gate form": tick **Record the price and the payment** | both boxes ticked; the scope stays active |
| 2 | Lucky | Set-up lists → Places | opens on **Uttar Pradesh** (it opened on Bihar before); Parameter library: "Moisture (%)" once |
| 3 | The Procurement person of KH26 gkp | Procurement → a practice farmer | the farmer card (GI land, sold this season, practice, GI area) |
| 4 | Same | Weights; Where = "Practice centre"; GPS: type `26.76, 83.37` in the first box, then tap the second | not split while typing; split when the box is left |
| 5 | Same | Delivered by = An agent; price 3500; Payment = Paid, by UPI; no transaction ID | "Name the agent …", then "Give the transaction ID …"; with `UPI-TEST-0001` and the agent's name it saves |
| 6 | Same | **Receipt** | the lot, net weight, ₹ amount, "Paid · UPI · UPI-TEST-0001"; no account number anywhere |
| 7 | Same | A second lot at the same point, Payment = Pending; then on its record **Record the payment** → Cash | the panel says Paid |
| 8 | The Collection Batch person | Verify the two lots; New Collection Batch | the lots grouped under "Practice centre"; choosing a lot of another place says so at once |
| 9 | Same, phone in airplane mode | Choose the two lots; re-weighed total a little less | the maths shown ("worked out on this phone"), the villages from the lots; Save on this phone; network back: it is sent |
| 10 | Lucky | The first lot's record | "Where the lot went": the batch, with the kilograms taken |

Clean-up: untick "Record the price and the payment" for KH26 gkp if it should stay off; the practice lots stay
practice lots (named so in the farmer).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 52 adds the table `lot_payments` (with its change log and read rule),
columns (scopes: `record_price` off, `procurement_details_required` on; the library's `alias_of`), triggers and
functions; the Procurement and Collection Batch forms in the stage list are updated (their labels and fields). Lots
already recorded keep what they have; a Village Batch already recorded keeps its typed village. To stop asking where,
the GPS and who delivered in a scope, its Client Manager unticks it on the scope page.
