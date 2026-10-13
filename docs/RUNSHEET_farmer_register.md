# The farmer register: migration 43 and the app, onto the practice system

Veda, 13 October 2026, "GrainVeda MVP — State Manager role", part D (Release 3 of three), and her answers the same
day. Open item 38 in `docs/FIX_LIST.md`. What changes:

- **GI land** (acres under the GI crop) on every farmer: more than 0 and not more than his land. A draft may be saved
  without it; **the Farmer ID needs it** (the State Manager may fill it in at step 2). The Excel template has a
  `gi_land_acres` column (may be left empty).
- **Possible duplicate**: another record with the **same phone in the same state** (another client's, not deactivated).
  It is saved, but **flagged** for the State Manager, and **no Farmer ID is issued while it is open**. He decides on the
  register: **Not the same person** (with a reason, kept in the Audit log) or **Deactivate this record**.
- **The yield check**: GI land × the crop's yield per acre is what a farmer can sell in a season. A Procurement lot that
  takes him past it is saved with a **warning** that says by how much; **past 120 %** he is **flagged** for the State
  Manager.
- **The farmer register** (State Manager menu → **Farmer register**; also a button on Farmers): every farmer of his
  state across its clients, by district, with filters (season, client, district, status, flag, search). The phone shows
  only its **last four digits**. The admin reads it.
- **"Needs my action"** on his overview also counts possible duplicates and farmers past 120 %.

**Only when Veda has said so.** This pushes migration 43 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten. The server functions are unchanged.

**What it means right after the run:** farmers who already have a Farmer ID keep it; they show "No GI land yet" until
someone fills it in, and their lots are not checked against a yield until then. A farmer waiting for his Farmer ID needs
his GI land first. The run says how many of each.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-farmer-register.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 43, the smoke check, the ledger audit and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 43 waiting; the functions current. **Asks you to type `FARMER REGISTER`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 43 | the push fails (nothing of it is applied) |
| S2 | Smoke check **39** rows (new: `farmer register`), the new rules in place, the ledger audit, logins, functions. Then: how many farmers, how many without GI land, waiting for a Farmer ID, possible duplicates | a row or a check is not `OK` (the two pg_cron rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: FARMER REGISTER ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-farmer-register-<time>.log`: send it to Claude.

**Then check Vercel built it**: Vercel → project `mvp` → Deployments must show the new commit as **Ready** within about
5 minutes. If not: the `…` menu at the top → **Create Deployment** → `main` → **Deploy to Production**.
`staging-crop-registry.cmd` has done its job; it now refuses to run.

## Afterwards, in the app (about 20 minutes, made-up data only)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram | Menu → **Farmer register** | His state's farmers as cards; cards on top; no side-scrolling on a phone; phones as `••••••1234` |
| 2 | the Client Manager (once Ram has given one) | **Farmers → New farmer**: land 2, GI land 3 | "Not more than the land."; the buttons are off. Clear the GI land → **Save and verify** works |
| 3 | Ram | **Farmers** → Ready to verify → that farmer | "The GI land is needed before the Farmer ID", the button is off; **Add it** → GI land 1.5 → Save → issue the Farmer ID |
| 4 | the Client Manager of a second UP client (Test Client UP) | Add a farmer with the **same phone** as one of the first client's | Saved |
| 5 | Ram | Overview → **Needs my action** | "Possible duplicate farmers (same phone): 2" → **View** opens the register on that flag |
| 6 | Ram | Issue that farmer's Farmer ID before deciding | Refused: "possible duplicate (same phone) of …: decide on the farmer register first" |
| 7 | Ram | On the register: **Not the same person**, reason "brothers, one phone" | Both cards lose the flag; Audit log (as Veda): "cleared a possible duplicate"; then the Farmer ID is issued |
| 8 | Procurement | Two lots for a farmer with GI land 0.1 (100 kg of Kalanamak) of about 98 kg each | The second carries "above the expected yield: 196 of 100 kg this season (0.10 acres of GI land)" |
| 9 | Ram | Register → flag **Over 120% of the yield** | That farmer, "Sold 196 kg of 100 kg expected (196%)" |
| 10 | Veda (admin) | **Farmers** → **Farmer register**, pick Uttar Pradesh | She reads it; no decision buttons |

Steps 2 to 9 need a Client Manager (two for step 4), a ready crop and a scope; they wait for those (items 36 and 37).
Step 1 and step 10 can be done right after the run.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 43 adds a column to farmers (and a rule on it that judges new and changed
rows only), a table (`farmer_dup_reviews`), functions and rules, and changes `import_farmers`, `procurement_crop_checks`
and `state_home` (the versions it replaced are in migrations 41 and 42). Ask before changing anything back.

## Rehearsed

On the local stack, 13 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (with the upgrade path; test 37
with 11 controls), the API tests, the unit tests, the screen suite with `phase15` at 527 px, the first day from nothing
(the first Farmer ID with its GI land), the production build. The script on stand-ins (PowerShell 7 on Linux). Not
rehearsed: Windows PowerShell 5.1, the hosted project, a real phone.
