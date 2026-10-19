# Release 2's corrections, Phase 1 release 3: migration 61 and the app, onto the practice system

Veda, 19 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Part C checked word by word, and the shown
parts of the season corrections E2.2 to E2.5 found live on build `index-Cv0Uu-5v`; "do what is left as per best". Item
57 in `docs/FIX_LIST.md`. Release 60 (Phase 1 release 2) is on staging since 19 Oct 2026, 21:10 IST (9e24527); this
script expects **migration 61** waiting and nothing else.

- **Both exports, column by column.** One column per field (gross, bags, the three moisture readings, the collection
  point, who delivered; the batch's farmers and villages with shares; the mill, polish, line clearance; head rice,
  broken, husk and bran in kg and as a % of the input; the packing unit and its FSSAI licence; packs by size; best
  before; buyer, order, invoice, LR, vehicle, container, ports, e-way bill, BL). Names, never ids. A column that no
  record fills is left out. The raw values only in the internal copy, last, as `raw_values`.
- **The two copies, in the brief's words.** The shareable copy names the staff and the buyer; it never has a price, a
  farmer's name or phone, an agent, a driver's phone or an id. The internal copy adds those, and its footer reads
  "Internal: contains personal and commercial data. Do not forward." **Prices only where the scope's "Record price" is
  ticked.**
- **Kilograms that add up.** Milling's floor loss = input − (head rice + broken + husk + bran) (Bansi: about 3 kg, not
  93). A lot closed as floor loss (the 2 %-or-less rule) is its own line: "Closed as floor loss: 4 kg, date, by". The
  season's Summary and the dashboard show each stage's **mass balance**: came in = went on + by-products + samples and
  water + floor loss + lost in transit + closed + left; a difference in red. (Blocking the season's close on a
  difference comes with Part D, release 5.)
- **The public page.** "Collection Batch" (not "Village batch"), "2 farmers from 2 villages", and one line for all of a
  batch's purchases ("Bought from 2 farmers: 250 kg") with the villages' shares.
- **Best-before** on every pack page, before release too; "not recorded (old data)" for packs made before shelf lives
  were set. **Packing is refused** while the crop has no shelf life for the pack's material ("Ask the State Manager to
  set the shelf life for this crop and pack material"). S1b lists the crops and materials without one.

**Changed on 20 Oct 2026 (migration 61c, Veda: "DONT MAKE THIS MANDATORY. DONT CHANGE AS OF NOW"):** Packing is no
longer refused without a shelf life: it saves with a warning, and those packs say "Best before: not recorded" (the words
"(old data)" are gone, since new packs can lack one too). Row 1 is dropped; the crops on staging are left as they are.
The village counts (61b) and head rice on its own line in the season's Summary (found at rows 8 and 7) go with it.
Run `staging-shelf-life-optional.cmd` (type `OPTIONAL`).

**Not in this release:** E2.1 (only the serials of a released shipment go live; `B0001-0150` still shows as released
until release 4), the closing check and the season report (Part D, release 5).

**Only when Veda has said so.** This pushes migration 61 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is changed or deleted: new functions, and replaced ones (the exports, the public lot
and pack data, the lot's trace, Packing's save rules). The seven server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-export-corrections.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 61 waiting; the seven functions current. **Asks you to type `CORRECTIONS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 61 | the push fails (nothing of it is applied) |
| S1b | Reads back (read only): `functions=new granted=yes closure_line=yes prices_rule=yes purchases=yes shelf_rule=yes closures=N no_shelf_life=…`. Where `no_shelf_life` is not `none`, it prints a NOTE: Packing is refused for those crops and materials until the State Manager sets their shelf life | the read fails, or anything else |
| S2 | Smoke check **59** rows (new: `export corrections`), the new rules in place, the change log intact, **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (the set-up rows are listed but do not stop it); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: EXPORT CORRECTIONS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 25 minutes, phone width; practice data)

Each person signs in themselves; Claude can then drive the steps in the browser. Downloads land in the browser's
download folder; Claude reads them there only if you say so.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram (State Manager) | If S1b printed a NOTE: Crops → each crop it named → Shelf life (days; per pack material where they differ) → Save | the crop shows its shelf life; a Packing record of that crop is no longer refused |
| 2 | Lucky (Client Manager) | Bansi's dashboard → "Mass balance" | one row per stage; the Collection Batch's row shows 4 kg closed; each row "Balanced", or a red "Difference … kg" (then it is a real gap in the practice data: tell Claude) |
| 3 | Lucky | Journey of `GV-8B1E15E15317` | on the Collection Batch "Closed: Closed as floor loss: 4 kg, …"; on Milling "By-products … kg · Floor loss … kg" (a few kg, not 93) |
| 4 | Lucky | The same page → "Download journey (shareable)" | columns Head rice, Broken rice, Husk, Bran (kg and %), Floor loss; a line "Closed as floor loss" after the batch with 4 kg; the names of who recorded each step; no farmer's name, no price, no "Raw values"; the footer "… No prices, no farmers' names or phones, no internal IDs." |
| 5 | Lucky | The same page → "Internal copy" | the farmer's name; "Raw values (raw_values)" last; prices only if Bansi records prices; the footer "Internal: contains personal and commercial data. Do not forward." |
| 6 | Lucky | The same page → Print / save as PDF (preview only) | the heading "GrainVeda · Journey of …", then "Test Client UP · Kalanamak rice · KH26 · Bansi…", then "Shareable copy · made …" |
| 7 | Lucky | Bansi's dashboard → "Season export, Excel (shareable)" | Summary: per stage In, Out, By-products, Floor loss, Closed as floor loss, Went on, Left, Difference; "By-products of the season" (husk, bran, broken) apart from the floor loss; batches with packs by size; Heading "Made by Lucky …" |
| 8 | anyone, private window | `/verify/GV-8B1E15E15317` | "Collection Batch"; "N farmers from M villages" with the real counts; "Bought from N farmers: … kg" with each village's share |
| 9 | anyone, private window | `/verify/TCUP-KNM-KH26-B0001-0150` | "Best before" with a date, or "not recorded (old data)" (it still shows as released: E2.1 is release 4) |
| 10 | tcup (the client login) | The same journey and the season | both copies offered and downloaded |

Not checked on staging (the tests cover them): prices off and on with "Record price", Packing refused without a shelf
life, a forced mass-balance difference, another client's person refused the balance, an id never in an export
(`tests/56_export_corrections.sql`, 34 checks and 15 controls; `web/tests/release61.test.tsx`; `e2e/phase33.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten. Migration 61 adds functions (`app.record_parts`, `app.stage_balance`,
`app.stage_balance_of`, `app.exp_txt`, `app.export_made_by`) and replaces the exports, the public lot and pack data, the
lot's trace and `app.reconcile` (Packing's shelf-life rule). If Packing is refused for a crop, its State Manager sets
the crop's shelf life (Crops, the crop, Shelf life): nothing else unblocks it.
