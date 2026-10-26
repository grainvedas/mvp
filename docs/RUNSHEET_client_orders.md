# Client orders, Phase 3 release 3: migration 70 and the app, onto the practice system

Veda, 26 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 3 Part D, with item 67's display
fixes; "proceed" (to the plan sent that day). Item 68 in `docs/FIX_LIST.md`. Phase 3 release 2 (migrations 68 and 69,
client views) is on staging since 26 Oct 2026 (head 8987f17); this script expects **only migration 70** waiting.

- **One order drawing on several scopes (D).** A **client order** holds the buyer (from the client's list), the market
  (an export market with its profile and destination country), the order number and **one invoice number**. It is made
  from **Client orders** in the menu by whoever holds Commercial in one of the client's active scopes of that crop, that
  scope's Client or State Manager, or the admin; never by a client account.
- **Its parts.** Each scope's Commercial person records its part on the usual Commercial form, from a batch of its own,
  by choosing the order under **"Part of a client order"** (the form's new first field). The order's buyer, market and
  number are written by the server (the form hides them); the packs, kilograms and price are the part's. Each pack keeps
  its batch, scope, serial and public page.
- **Refused parts.** A part is refused unless the scope is of the order's client and crop and sells to its market; the
  client is **Active** in the scope's state; the batch **passed QC for the order's market** (or carries the client's
  written acceptance); the batch has the **same GI status and farm-verified status** as the order's other parts. The
  form offers only the orders the batch fits and says why another does not.
- **One invoice.** Every shipment of a part carries the order's invoice (filled in; another number is refused; an order
  with no invoice yet ships nothing). The invoice can be set or changed on the order's page until a part has shipped;
  then it is fixed. An order is cancelled only while it has no part (with a reason, in the Audit log).
- **The order's page** shows the order, then **one section per scope** (batch, packs, kilograms, shipments under the
  order's invoice). Each reader sees the sections of the scopes he reaches (and how many parts are elsewhere); prices
  only where he may read them. The evidence pack of release 4 takes these sections.
- **The client's views.** Portfolio → Across scopes lists the client orders (parts, scopes, kilograms, the invoice) and
  says on each order line "part of ORD-…"; the export of Across scopes has the client orders' table.
- **Found while checking (closed).** The farmer register's "possible duplicates" (`app.open_duplicates`) answered
  anyone signed in, given a farmer's id, with the names and Farmer IDs of another client's farmers sharing his phone.
  No screen calls it (the farmer register and the Farmer ID's rule read it inside the database, and still do); it is now
  closed to the app's people. The isolation probe found it on the local stack after the whole e2e suite (an e2e test
  leaves two clients' farmers with one phone); staging has no such pair (its probe of 26 Oct: `leaks=0`).
- **Item 67.** (1) An older QC record that kept its lab in "Lab reference" shows it as its lab in the client's scope
  view. (2) An order recorded before the currency was asked says "currency not recorded" (screen and export), never
  "220 /kg". (3) Lucky's "End" on an owner's client assignment is left as it is (Veda did not ask for a change).

Not in this release: the evidence pack with its scope sections (release 4), the showcase page and badge, the lifetime
switch-off of ended clients' accounts (release 5).

**Only when Veda has said so.** This pushes migration 70 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: one new table (`client_orders`) and new functions; replaced
from their own text, each change named in the migration: `app.reconcile` (Commercial and Shipment of a part only),
`app.cv_across_data` and `app.export_client_view` (the client orders), `app.cv_scope_data` (the lab reference);
`app.open_duplicates` closed to the app's people. The Commercial form gains its first field.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-client-orders.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 70 waiting; the seven functions current. **Asks you to type `ORDERS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 70 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `table=new functions=new rules=yes form=yes views=yes orders=0 commercial_scopes: … active_states: …` | anything is not as migration 70 leaves it |
| S2 | Smoke check **67** rows (new: `client orders`), the rules in place, the change log intact (**72** tables), **one client and another** in 8 parts (`part 1 of 8: leaks=0 …` … then the sum), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT ORDERS ON STAGING` or `RESULT: STOPPED`. Between S1 and S3 (if a run stops there) the old app
works as before: it offers no Client orders and its Commercial form does not show the new first field (Commercial is
recorded as before). Run the script again.

## Afterwards (about 25 minutes, phone width; practice data only)

Each person signs in themselves; Claude can then drive the steps in the browser. KH26 Bansi (its chain has Commercial
and Shipment), from the verified packing record PK-0001 (its 1 kg packs left after release 7's checks); the practice
buyer `Practice buyer (test)`. Staging has one state with a mill, so the order has one scope's part here; a part from a
second state, and every refusal, are in the tests (`tests/65_client_orders.sql`, 64 checks, 19 controls).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager, holds Commercial, Shipment and QR at Bansi) | the menu → **Client orders** → New client order: Test Client UP · Kalanamak, `Practice buyer (test)`, Domestic, order `PO-TEST-70`, invoice `INV-TEST-70` | the order's page: `ORD-TCUP-0001`, Open, the invoice, no part yet, "Cancel this order" offered |
| 2 | Lucky | Bansi → Commercial → PK-0001 → Record: **Part of a client order** → ORD-TCUP-0001 | "Buyer Practice buyer (test) · Domestic · order PO-TEST-70 (from the order)"; Buyer, Market and Order number leave the form; the packs stay |
| 3 | Lucky | 2 × 1 kg → Review → Save; open the record | the record says Client order ORD-TCUP-0001; buyer and order number the order's |
| 4 | Lucky | the order's page | Bansi's section (Uttar Pradesh): the part, its batch, "2 × 1 kg pouch · 2 kg", not shipped yet; Cancel no longer offered |
| 5 | Lucky | Shipment: verify the part; Record Shipment | the note "A part of client order ORD-TCUP-0001: one invoice for the whole order, INV-TEST-70"; the invoice already filled in; the two pack codes, `UP53AB1234`, `LR-TEST-70` → saves |
| 6 | Lucky | (optional) the same, with invoice `INV-OTHER` | refused in plain words: "Client order ORD-TCUP-0001 has one invoice, INV-TEST-70." |
| 7 | Lucky | the order's page | the invoice "fixed: a part has shipped"; no invoice form |
| 8 | tcup | Portfolio → **Across scopes** | "Client orders": ORD-TCUP-0001, PO-TEST-70, invoice, 1 part in 1 scope; the order line says "part of ORD-TCUP-0001"; the order opens, nothing to change; **no price** |
| 9 | the admin | Client orders → ORD-TCUP-0001; then the **Audit log** | the same order; "made a client order ORD-TCUP-0001 · order PO-TEST-70, invoice INV-TEST-70" |

Not checked on staging (the tests cover them): the part from a second state and its one invoice, the refusals (another
GI or farm-verified status, a batch that failed the market, the client not Active in the state, another client's or
another crop's order, a cancelled order), who reads which section and which price, a client account refused the order
(`tests/65_client_orders.sql`; `web/tests/release70.test.tsx`; `e2e/phase41.spec.ts`, at 527 px).

## If something is wrong afterwards

Nothing was deleted or rewritten. A part is an ordinary Commercial record: corrected or withdrawn as any record is. An
order with no part can be cancelled (its numbers are free again). Send Claude the order's page and the refusal's words.
