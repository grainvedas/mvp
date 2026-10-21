# Only shipped packs are released, Phase 1 release 4: migration 62 and the app, onto the practice system

Veda, 19 October 2026: the combined brief ("GrainVeda MVP: combined brief"), season correction E2.1 "Only shipped packs
are released", the most important of them; "ok proceed" (21 Oct). Item 58 in `docs/FIX_LIST.md`. Release 3c (migration
61c) is on staging since 20 Oct 2026, 01:13 IST (088986f); this script expects **migration 62** waiting and nothing else.

Found live on 19 Oct: pack `TCUP-KNM-KH26-B0001-0150` was never sold or shipped (14 of the batch's 190 packs went out, in
lot `GV-8B1E15E15317`), yet its page said "Genuine pack, sealed record": sealing one lot released every pack of the batch.

- **A pack goes live with its shipment.** Only a pack whose code (or whose carton's code) a sealed shipment carries is
  released. Every other pack of the batch says "Packed, not yet released", whatever else of the batch went out.
- **Every shipment of a packed lot gives its codes**: export and domestic, an order by packs or by the kilogram, whatever
  the scope's "details" setting. The Shipment form shows "Pack codes loaded" wherever the lot is packed. By the kilogram,
  the packs loaded must weigh what is shipped ("The packs loaded weigh 39 kg; the shipment is 40 kg. Add or remove
  codes."). A run of one pack size is added with "Add a range": From and To.
- **Shipments of before** that recorded no codes (Veda's default (a)): their packs say **"Released, serials not recorded
  (old data)"**, never "Genuine pack". No code is guessed. This is what `B0001-0150` and the rest of `B0001` will say.
  A lot with no shipment in its chain (sold at the gate, say) is released whole by its seal, as before.
- **The counts.** The lot page counts only the packs that went live. The QR step's summary says "Packs that go live with
  this seal: N (batch …). Not yet released: M." The season export lists per batch: Packs, Released, Released, codes not
  recorded (old data), Not yet released, Voided.

**Not in this release:** the closing check and the season report (Part D, release 5; the closing check will list each
batch's released, old data, held and void packs).

**Only when Veda has said so.** This pushes migration 62 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted, no record or ledger block rewritten: new functions, replaced ones (the
pack page, the lot page data, the QR step's summary, the season export, Shipment's save rules) and the Shipment form's
pack codes field. The seven server functions are unchanged. Run S3 soon after S1: between them the old app does not
show the codes field for a shipment of a packed lot by the kilogram, and the database refuses that save.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-shipped-packs.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 62 waiting; the seven functions current. **Asks you to type `PACKS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 62 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `functions=new codes_rule=yes form_field=yes packs: released=… old_data=… not_released=… void=… b0001_0150=old_data` (all scopes' packs by state) | the functions, the codes rule or the form field are not there |
| S2 | Smoke check **60** rows (new: `shipped packs`), the new rules in place, the change log intact, **one client and another** (`leaks=0 …`), the ledger audit, logins, functions; `after:` counts the shipments with and without codes | a row or a check is not `OK` (the set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: SHIPPED PACKS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 20 minutes, phone width; practice data)

Each person signs in themselves; Claude can then drive the steps in the browser. Downloads land in the browser's
download folder; Claude reads them there only if you say so.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | anyone, private window | `/p/TCUP-KNM-KH26-B0001-0150` | "Released, serials not recorded (old data)", not "Genuine pack" |
| 2 | anyone, private window | `/verify/GV-8B1E15E15317` | "190 packs, packed 16 Oct 2026" with, below it, "This lot's packs were released before shipments recorded their codes (old data)." (default (a): the 190 count as released, as old data; corrected 21 Oct, this row first said "no 190 packs line") |
| 3 | Lucky (Client Manager) | The TCUP scope's dashboard → "Season export, Excel (shareable)" → Batches | the columns Packs, Released, Released, codes not recorded (old data), Not yet released, Voided; `B0001`: 190 packs, all under "codes not recorded (old data)" |
| 4 | Lucky, holding Commercial, Shipment and QR in a practice scope (as release 7's checks) | A packed lot: Record Commercial Clearance **by the kilogram** (say 5 kg of 1 kg packs) → Record Shipment | "Pack codes loaded" is asked, also where the scope asks no details; "Add a range" From the first code To the fourth: refused in plain words ("The packs loaded weigh 4 kg; the shipment is 5 kg …"); To the fifth: saved | (21 Oct: not possible on staging, where every scope asks details and Commercial sells by packs; left to the tests)
| 5 | Lucky (QR) | That shipment → the release summary | "Packs that go live with this seal: 5 (batch …). Not yet released: …" → read, seal |
| 6 | anyone, private window | `/p/<one of the five codes>`, then `/p/<the sixth code of that batch>` | the first "Genuine pack, sealed record"; the second "Packed, not yet released" (this is the Done check of `B0001-0150`, on a batch shipped now) |

Not checked on staging (the tests cover them): a code of another batch, a void pack or a pack in two shipments refused, a
carton's code releasing its packs, a recall on the released packs only, an order by packs, the Hindi words, another
client's person refused (`tests/57_shipped_packs.sql`; `web/tests/release62.test.tsx`; `e2e/phase34.spec.ts`,
`phase2`, `phase22`, `phase29`).

## If something is wrong afterwards

Nothing was deleted or rewritten. Migration 62 adds functions (`app.lot_shipments`, `app.lot_released_packs`,
`app.pack_release`, `app.scope_pack_states`), replaces the pack page and lot page data, the QR step's summary, the season
export and `app.reconcile` (Shipment's codes rule), and marks the Shipment form's pack codes field `when_packed`. If a
shipment is refused for its codes, the codes loaded are added on the form (they must weigh what is shipped): nothing
else unblocks it.
