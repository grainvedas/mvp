# Set-up lists, release 4: migration 51 and the app, onto the practice system

Veda, 15 October 2026, "ok complete everything" (decision G19). Release 4 of the operator-stages plan. Item 46 in
`docs/FIX_LIST.md`. Releases 1 to 3 (migrations 48 to 50) are on staging since 15 Oct 2026, 17:01 (b3ce4d8); this
script expects **only migration 51** waiting.

- **The lists the stages pick from (Part B).** One page, **Set-up lists**:
  - the **places** of a state: Uttar Pradesh's 75 districts are loaded; a block or a village is added by whoever
    registers farmers there; a new district only by the State Manager. The same place written differently is one place;
  - the **Client Manager's lists**: collection points (with GPS), mills (own or hired, dedicated to a crop), packing
    units (FSSAI licence: 14 digits), buyers (a buyer in India needs a GSTIN or an FSSAI licence), the pack list
    (size, unit, material, market, label). A row is retired, never deleted;
  - the **State Manager's labs** (an external lab names its accreditation) and **market profiles** per crop: each
    crop's Domestic and Export limits become its first two profiles; a new profile (EU, GCC …) takes its tests from the
    **parameter library** (11 tests, loaded once, read-only) and is activated only with the **document its limits come
    from** attached. A change makes a new version; the one in use stays until the new one is activated.
- **The crop.** A GI crop is one with a GI number (a crop without one has no GI area at all); GI blocks; shelf life per
  packing material; a reference photo (for the quick look at Procurement, release 5).
- **The farmer.** The district from the state's list; block and village from the list or new; **the farm's GPS** ("Use
  where I am now" at the farm, or two numbers typed or pasted) is needed before the Client Manager verifies a farmer
  registered from now on. **Farmers already there are asked, never refused**: "Needs my action" lists them. Land
  record number and GI authorised-user number (optional). A farmer outside the crop's GI districts is accepted and
  marked; at step 2 the State Manager sees how far the farm is from the district's other farms.
- **A14, the ledger banner**: "Last full ledger check …: N blocks intact · M blocks added since".
- **A15, the roster pool**: free people first, then "Already on other scopes" with their work there; picking one says
  "… already holds …; he will have two work queues" (nothing is refused). The State Manager's overview counts the people
  holding stages on more than one scope.

**Only when Veda has said so.** This pushes migration 51 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is changed or deleted. The server functions are unchanged (build 2026-10-14).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-setup-lists.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with migration 51 waiting; the functions current. **Asks you to type `LISTS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 51 | the push fails (nothing of it is applied) |
| S1b | Reads back what the migration filled (read only): `states=… districts=… up_districts=75 library=11 crops=… crops_without_profiles=0 farmers=… farmers_gps_asked=…` | the read fails, a crop has not got its two profiles, or the library is empty |
| S2 | Smoke check **48** rows (new: `setup lists`), the new rules in place (the `reference` file store too), the change log intact (**41** tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: SET-UP LISTS ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 20 minutes, phone width; practice data, clearly fake, in KH26 gkp)

Each person signs in themselves (Veda, 15 Oct: "ok ill do"); Claude can then drive the steps in the browser pane.
Have a small PDF at hand (any one-page PDF: it is the "source document" of a practice profile).

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Client Manager | Menu → **Set-up lists** → Collection points → Add: "Practice centre", Collection centre, district Gorakhpur, GPS `26.76, 83.37` → Save | the card shows the GPS; a GPS typed as `51.5, -0.12` is refused before the save ("not in India") |
| 2 | Client Manager | Buyers → Add: "Practice buyer", country IN, an address, no GSTIN → Save; then GSTIN `09AAAAA0000A1Z5` → Save | first: "A buyer in India needs a GSTIN or an FSSAI licence number"; then saved. **Retire** it afterwards |
| 3 | Ram (State Manager) | Set-up lists → Labs → Add: "Practice lab", External, accreditation `TC-0000`, Lucknow → Save | saved; without the accreditation it is refused |
| 4 | Ram | Market profiles → Kalanamak | Domestic and Export (general) "Version 1 in use", their limits = the crop's |
| 5 | Ram | New market profile: code `practice`, name "Practice EU" → Start → add Aflatoxin B1, at most 2 → Save → attach the PDF → Activate | "Version 1 in use", the PDF's name and fingerprint shown; Activate stays off until the PDF is there |
| 6 | Ram | Crops → Kalanamak → Edit: shelf life Jute bag 270 → Save | the card: "Shelf life per packing material: Jute bag 270 days" |
| 7 | Client Manager | Home | "Needs my action": the verified farmers without their farm GPS; the ledger line says "… · N blocks added since" |
| 8 | Client Manager, at a farm or anywhere | Farmers → New: name "Practice farmer", district from the list, a new block "Practice block", village "Practice gaon", **Use where I am now** (allow the location), mobile, land, GI land → **Save and verify** | Save and verify stays off until the GPS is there; saved; the block and village are now on the state's list |
| 9 | Ram | Farmers → Ready to verify → the practice farmer | "GPS check: …" (too few other farms with GPS in the district to compare, at first) |
| 10 | Client Manager | Season scopes → KH26 gkp → People | each stage's list: people free first, then "Already on other scopes" with their work; picking one shows the note (take him off again) |

Clean-up: retire the practice list rows (Retire); the practice farmer stays a practice farmer (named so); the practice
profile can be left (it judges nothing until release 5 uses profiles).

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 51 adds tables (`places`, `collection_points`, `mills`, `packing_units`,
`buyers`, `pack_skus`, `labs`, `quality_param_library`, `reference_files`, `market_profiles`), columns (farmers: block,
farm GPS, land record, GI user number, `location_required` = false for those already there; crops: `gi_crop`
(worked out from the GI number), GI blocks, shelf life per material, reference photo), the `reference` file store,
triggers and functions. A crop with no GI number that had GI districts typed keeps them until its next save, which
clears them (a non-GI crop has no GI checks). A farmer registered by the old app between S1 and S3 needs his GPS added
before step 1.
