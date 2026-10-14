# Farmer corrections: migration 47 and the app, onto the practice system

Veda, 14 October 2026, while testing Procurement on staging: p's lot for farmer TCUP-F-0001 would be refused ("good
farming practice not complete … GAP 1, gap 2") and p had no way to fill it in: on his Farmers list a verified farmer
showed only a badge. Her decisions: *"give access to Good farming practice section only"* (it counts at once) and *"if
other details need omission then if p does it it should go to lucky for verification"*. Item 42 in `docs/FIX_LIST.md`.

- **Good farming practice**: the person at Procurement (or Village Batch) opens a verified farmer's **Practice ·
  corrections** page (from his Farmers list, or from the refused Procurement form: "Fill in good farming practice for
  this farmer →"), answers it, and it counts at once: the lot is no longer refused.
- **Corrections**: on the same page, any other detail he finds wrong or missing (name, father's name, village,
  district, mobile, land, GI land, notes) he proposes with a reason. Nothing changes until the Client Manager approves it
  under **Corrections proposed** on his Farmers page (then it is made in his name, with the proposer and the reason in the
  farmer's history; GI land and mobile still wait for the State Manager to accept) or refuses it with a reason. The
  proposer can withdraw his own while it waits. Every step is in the Audit log.

**Only when Veda has said so.** This pushes migration 47 to the practice database **and pushes to the main branch**.
Production is not touched. Nothing is changed or deleted. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-farmer-corrections.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with exactly migration 47 waiting; the functions current. **Asks you to type `CORRECTIONS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 47 | the push fails (nothing of it is applied) |
| S1b | Reads back the crops with a required practice, active farmers, farmers with practice answered, proposals (read only) | the read fails |
| S2 | Smoke check **44** rows (new: `farmer corrections`), the corrections in place and the change log intact, the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: FARMER CORRECTIONS ON STAGING` or `RESULT: STOPPED`. The summary's `ledger_head` is now the newest
block's number (the requirements run printed 9 for 34: it sorted the number as text).

## Afterwards (about 10 minutes, phone width; practice data)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | p | Procurement → farmer 1 (TCUP-F-0001), 100 kg, 2 bags, 1 kg tare, moisture 12 / 12.1 / 11.9 | "The database will refuse this: good farming practice not complete … GAP 1, gap 2" and the link **Fill in good farming practice for this farmer →** |
| 2 | p | the link → answer GAP 1 and gap 2 → **Record practices** | "complete"; back to Procurement, the same lot → Review → Save: a Pending lot `TCUP-…-P-0001` in p's name |
| 3 | p | Farmers → farmer 1 → **Practice · corrections** → Notes `TEST rain-fed plot`, why `told at the farm gate` → **Send to the Client Manager** | "Sent to the Client Manager."; under Corrections proposed: Waiting for the Client Manager; no Approve for p |
| 4 | Lucky | Farmers | **Corrections proposed** at the top: farmer 1, Notes: — → TEST rain-fed plot, proposed by p → **Approve** | Approved; farmer 1's history: the change in Lucky's name, "proposed by p: told at the farm gate" |
| 5 | Lucky | Milling → Incoming → p's lot → **Verify** | Verified by Lucky |

Claude can drive these in the browser pane once each person has signed in.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 47 adds one table (`farmer_proposals`) and four functions. Good farming
practice was already the Procurement operator's to answer in the database (migration 42); only the app's way to it is new.
