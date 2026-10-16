# Part H: what an operator who holds one stage sees today

The operator-stages brief, Part H: "An operator who holds **one** stage … has not been reviewed yet: his home page, menu,
work queue, and how 'waiting for me' looks on a phone. Do not redesign it in this brief. … Report what he sees today, so
the owner can review it after Phase 1." This is that report, for Veda's review (decision G22 in `docs/FIX_LIST.md`).

**How it was taken.** 16 October 2026, the app as built with release 9 (migration 56), on the local stack, at **390 px**
(a small phone), signed in as two demo operators who each hold **one stage in one scope**:

- the **Collection Batch** operator (KH26 · Bansi batch; five farm-gate lots waiting for him, two of them not yet
  checked in);
- the **Lot Inward** operator (KH26 · Gorakhpur mandi; an entry stage: nothing waits for him).

The pictures are in the folder `Claude outputs/part-h-2026-10-16/` on Veda's computer (git-ignored; the file names
below). Every change of Part A was checked for a single-stage operator by the end-to-end tests (`e2e/phase*.spec.ts`
sign in as such operators).

## What he sees

| # | Picture | What is on it |
|---|---|---|
| 1 | `01_cb_first_screen.png` | The practice strip; the top bar with his name, the language and Sign out; the menu (Dashboard, Farmers, Collection Batch (one collection point), My guide, Saved on phone, My account) scrolling sideways. "Hi Village Batch Operator · Operator · Kalanamak rice · KH26 · Bansi batch". **Needs my action (2)**: "2 from Procurement (farm-gate) waiting for your verification", Open. **Your stages**: "My stage: Collection Batch (one collection point)", **5 lot(s) waiting for you**, "Check what arrived →". My recent records: "No records yet." |
| 2 | `02_cb_stage_waiting.png` | The scope's banner (crop, season, place, client, GI Tag No. 280); the stage's name; three tabs stacked (Waiting from Procurement, New … record, Records at this stage); the eight steps (1 Look up … 8 Handoff); the waiting list: code, what is **left**, status (three APPROVED, two PENDING VERIFICATION) |
| 3 | `03_cb_check_in.png` | A lot opened from the list (one already checked in): code, quantity forwarded, net weight, moisture (average, lowest, highest), where it was weighed, "Checked by the system" (✓ recorded by whom and when, the farmer verified, three moisture readings, the net weight, good farming practice, no open flag), Open full record, "Verified", "Record Collection Batch … for this lot" (a lot not yet checked in shows the physical ticks, Verify and Return to sender instead) |
| 4 | `05_cb_new_batch.png` | The form: the "On" date, where (collection point or at the farm), **the lot filters of release 9** (village, search, "Choose the 3 shown", "3 of 3 lots shown · 0 chosen"), the lots by place with the farmer and village, single-origin, bags, the optional re-weighing and moisture, "Fill in the form to see the result", Review |
| 5 | `06_cb_records.png` | Records at this stage: "Nothing here yet." |
| 6 | `07_cb_help.png` | Help: who helps you (the scope's manager for the work, HR for the password), report a problem |
| 7 | `08_cb_account.png` | My account |
| 8 | `09_li_first_screen.png` | Lot Inward: the same frame; no "Needs my action" (nothing waits for an entry stage); "My stage: Lot Inward (pre-aggregated lot) · This is where a lot starts · Go to Lot Inward →" |
| 9 | `10_li_stage.png` | Lot Inward's stage: two tabs (New record, Records), the steps, "Signed by Lot Inward Operator · saved as pending, then verified by Quality Control", the form (On, declared and weighed quantity, source type …) |

## What works for him

- One stage, one scope: his first screen is his stage, nothing to choose; the scope's crop, season and place are on
  every screen.
- "Needs my action" and "lots waiting" are both on the first screen, each one tap from the work.
- What is shown of a lot is what is **left** (Part A3), and checking a lot in shows the system's checks apart from what he
  ticks (A2).
- Nothing is wider than the phone; no database words; English and Hindi throughout.

## For Veda to decide (nothing changed; Part H says report, not redesign)

1. **Two counts on one screen.** "Needs my action (2)" counts lots **to check in**; "5 lot(s) waiting for you" counts
   lots waiting, **checked in or not** (three are checked in and wait for a batch). An operator may read them as a
   contradiction. Proposal: "2 to check in · 3 checked in, ready for a batch".
2. **The waiting list on a small phone.** A record number (`PRSDM-KNM-KH26-BNS-P-0001`) breaks over five lines in the
   Code column, and the list shows no farmer or village. With many lots per farmer per village (Veda, 16 Oct), the
   waiting list would want the same village filter and search as the new batch form, and the farmer and village on each
   row. Proposal: a card per lot (number on one line, farmer · village, kg left, status) with the filter above.
3. **The stage's long name.** "Collection Batch (one collection point)" is cut off in the menu bar and makes the page
   title two lines. Proposal: "Collection Batch" in the menu and titles, the explanation under the title.
4. **The menu.** A Collection Batch operator has "Farmers" in his menu (he may register a farmer, migration 41); a Lot
   Inward operator has not. Keep, or put "Farmers" only where the stage registers farmers.
5. **Three tabs stacked.** On a small phone the three tabs take three rows above the steps. Proposal: one row of short
   words (Waiting · New · Records).
6. **The batch form's filter on 390 px**: the village box shows "All villages (3" and the search "Farmer, farmer" (cut).
   Proposal: put them on two rows below 420 px.

Not looked at here (other days of the brief): the offline day (`e2e-prod/field_day.spec.ts` covers it), the Hindi of
these screens (G6: two field operators read it).
