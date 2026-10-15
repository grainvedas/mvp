# Numbers you can trust, release 2: migration 49 and the app, onto the practice system

> **The run itself: double-click `staging-packs-release.cmd` (`docs/RUNSHEET_packs_and_release.md`).** It pushes
> whatever of migrations 48, 49 and 50 is waiting, in order, with the app of all three. There is no separate
> `staging-trust-numbers.cmd` (the table below describes the same steps). This sheet's "Afterwards" still applies.

Veda, 15 October 2026, "ok complete everything" (decision G19). Release 2 of the operator-stages plan. Item 44 in
`docs/FIX_LIST.md`. **If release 1 (`staging-operator-template.cmd`) has not been run, this script pushes migration 48
first and then 49, with the app of both: one run.** Its run sheet (`docs/RUNSHEET_operator_template.md`, Afterwards)
still applies; do it before this one's.

- **What people tick, what the system checks (A2, G3).** At each arrival the receiver sees "Checked by the system": the
  farmer verified, the three readings, the net weight, the practice, the balance, the sources, the lab's verdicts, no
  open flag (a tick or a cross each). He ticks only what he sees with his own eyes, a short list per stage (Procurement:
  bags counted, the grain sound, the bags tagged). The ledger keeps what he ticked.
- **What is left (A3, G2).** The waiting lots show "59 kg left of 119 kg"; the next form starts from what is left.
- **Thresholds from the crop (A7, G5).** No fixed milling yield any more. Above the crop's outturn ceiling (70 % unless
  the crop says) the run is warned and the State Manager sees it in "Needs my action"; once the crop has its own
  verified runs (10 unless the crop says), an outturn far from them is warned with their range. Crop page: "Milling
  outturn ceiling", "Runs before a usual range".
- **Lineage (Part E), farmers and GI.** Every record keeps its sources with the kilograms it took (filled for the records
  already there, marked "from the older record"). The record page: "Comes from", "Farmers in this lot" with each
  farmer's share (documented proportions), the GI status. A lot is GI only when every source's farmer is in one of the
  crop's **GI area** districts (crop page, new field). The public page counts farmers, not lots (G6), and shows
  "GI Tag No. 280" only for a GI lot (G7).
- **No full page reload** for a new record (A5, G11); warnings in plain words, English and Hindi.

**Only when Veda has said so.** This pushes migration 49 (and 48 if waiting) to the practice database **and pushes to
the main branch**. Production is not touched. Nothing is changed or deleted. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-trust-numbers.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 49 waiting (or 48 and 49); the functions current. **Asks you to type `NUMBERS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: what is waiting, in order | the push fails (nothing of that migration is applied) |
| S1b | Reads back the lineage filled for the records already there and every scope's short code (read only): `records=… links=… links_from_older=… records_without_link=0` | the read fails, a scope has no short code, or a record built on another has no link |
| S2 | Smoke check **46** rows (new: `trust numbers`), the new rules in place, the change log intact (26 tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: TRUST NUMBERS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 15 minutes, phone width; practice data in KH26 gkp)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram (State Manager) | Crops → Kalanamak Rice → GI area: the districts of GI 280. As far as Claude knows they are 11: Maharajganj, Siddharthnagar, Sant Kabir Nagar, Basti, Gorakhpur, Deoria, Kushinagar, Bahraich, Balrampur, Gonda, Shravasti; **check them against the GI certificate first** → Save | The crop card: "GI area: … districts"; the badge reads "GI Tag No. 280" |
| 2 | p | Procurement → farmer 1, 100 kg, 2 bags, 1 kg tare, moisture 12 / 12.1 / 11.9 → Save | saved `TCUP-KNM-KH26-GKP-P-000n` |
| 3 | Lucky | Milling → Incoming → the lot | "Checked by the system": the farmer verified, three readings, net weight, practice, no open flag, each ✓; three boxes to tick (bags counted, sound grain, tags); Verify stays off until all three are ticked → Verify |
| 4 | Lucky | Record Milling: paddy in 60 (of the lot), rice 45, bran 14, loss 1 | the maths: "Outturn 75.0 % is above the crop's ceiling of 70 %: the State Manager is told"; Save |
| 5 | Lucky | **New Milling record** | the page does not reload; Incoming shows the lot "… kg left of … kg"; Record Milling starts from what is left |
| 6 | Lucky | the milling record's page | "Comes from" the lot, "60 kg taken"; "Farmers in this lot": farmer 1, 100 %; GI status "GI (every source from the GI area)" if farmer 1's district is in the GI area |
| 7 | Ram | Home | "Needs my action": 1 milling run above the crop's ceiling |

Claude can drive these in the browser pane once each person has signed in.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 49 adds one table (`footprint_links`, filled from what was recorded),
columns (`stage_definitions.physical_checks`, `crops.gi_districts`, `crops.thresholds`), triggers and functions. The
fixed "yield below threshold" warning is no longer given; the warnings already on records stay as they were.
