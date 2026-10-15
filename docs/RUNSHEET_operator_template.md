# Operator template, release 1: migration 48 and the app, onto the practice system

> **The run itself: double-click `staging-packs-release.cmd` (`docs/RUNSHEET_packs_and_release.md`).** It pushes
> whatever of migrations 48, 49 and 50 is waiting, in order, with the app of all three. The script this sheet names
> (`staging-operator-template.cmd`) refuses to run now (the app was sealed again). This sheet's "Afterwards" still applies.

Veda, 15 October 2026: "yes but with this i have one more prompt / combine both", then "ok complete everything". The
operator-stages brief (Parts A–G) is built in releases; this is the first, with the Client Manager's home, menu and
ledger (D3–D5) and the two fixes held from the farmer-corrections run. Item 43 in `docs/FIX_LIST.md`.

- **Return to sender (A1, G4).** At the next stage, "Return to sender" with a reason (10 characters or more). The record
  stays pending at its sender; nobody can verify it. The sender sees it first on his home ("Needs my action", with the
  reason), corrects it (or, for a lab record, a batch or a record something was made from, withdraws it and records it
  again). The ledger has a "Returned" block for each step.
- **Verify with a condition** (Owner decides; the recommendation accepted): the record is verified and an open
  condition is raised on it, which blocks the QR seal until a manager closes it.
- **"On" (A9).** Every form asks the day it happened (today unless changed; at most 31 days back; never before the lot it
  comes from). The record keeps both: "On 14 Oct 2026" and "Recorded 15 Oct 2026, 9:12 am IST".
- **A manager's reason (A10, G14).** A manager who records or verifies at a stage he does not hold writes why (10
  characters or more); the ledger block is "Supervisory" and carries it.
- **Record numbers name the scope (E4, G15).** `TCUP-KNM-KH26-GKP-P-0001`. Every scope gets a short code (2–4 letters):
  the ones there now get one from their place name (gkp → GKP, Bansi → BNS; S1b prints them all). A new scope's code is
  typed in the wizard or given. Old record numbers are not changed. The batch code on packs comes in release 3.
- **The Client Manager's day (D3–D5).** "Needs my action" is the first thing on every home (his returned records, what
  waits at his stages, farmers to verify, corrections proposed, requirement lines HR returned, open conditions and
  flags). His own menu: Watch · My scopes · Farmers · People · Audit · Me. Audit → Ledger: his client's blocks, each
  return and manager's reason in quotes; the export in IST.
- **Fix 1:** the farmer's history names every line: "Good farming practice answered (Kalanamak Rice) · p (Operator)";
  his lots ("Lot … recorded at Procurement (98 kg)"). **Fix 2:** every time in IST (with "IST"), exports too.
- **Plain error messages (A4, G13)**, English and Hindi; the database's inside words never reach the screen.

**Only when Veda has said so.** This pushes migration 48 to the practice database **and pushes to the main branch**.
Production is not touched. No record is changed or deleted; the scopes get a short code each. The server functions are
unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-operator-template.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with exactly migration 48 waiting; the functions current. **Asks you to type `OPERATOR`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 48 | the push fails (nothing of it is applied) |
| S1b | Reads back every scope's short code (read only): `codes=gkp:GKP,…` | the read fails, or a scope has none |
| S2 | Smoke check **45** rows (new: `operator template`), the new rules in place and the change log intact (25 tables), the ledger audit, logins, functions | a row or a check is not `OK` (the three set-up rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: OPERATOR TEMPLATE ON STAGING` or `RESULT: STOPPED`.

Between S1 and S3 (a minute or two) a manager who verifies at a stage he does not hold is refused by the old app (it has
no reason box yet); everyone else works as before.

## Afterwards (about 15 minutes, phone width; practice data in KH26 gkp)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | p | Procurement → farmer 1 (TCUP-F-0001), **On** = yesterday, 100 kg, 2 bags, 1 kg tare, moisture 12 / 12.1 / 11.9 → Review → Save | Review shows "On" yesterday; saved as `TCUP-KNM-KH26-GKP-P-000n` |
| 2 | Lucky | Milling → Incoming → that lot → **Return to sender**, why: `TEST moisture readings look copied` → Return it | "Returned to its sender by Lucky … It is verified after the correction."; no Verify button; the Incoming list says "Returned to sender" |
| 3 | p | Home | **Needs my action**: the lot, "returned to you by Lucky", the reason → **Correct it** → Correct it → moisture 2 = 12.2 → Review → Save. Home: the line is gone |
| 4 | Lucky | Milling → Incoming → the lot → tick the list → **Verify with a condition…**, the condition `TEST slip photo to be added` → Verify with this condition | Verified; the record's Flags show "Condition", open |
| 5 | Lucky | Home; the menu | "Needs my action" with 1 open condition; the menu headings Watch, My scopes, Farmers, People, Audit, Me |
| 6 | Lucky | Audit → Ledger → Event: Returned | "Ledger of my client"; the return and its correction, with the reason in quotes; times end with "IST"; Export: the `time_ist` column |
| 7 | Lucky | Farmers → farmer 1 | The history: "Good farming practice answered (Kalanamak Rice) · p (Operator)", "Lot … recorded at Procurement (… kg)"; no blank line |
| 8 | Lucky | the lot's record page → Flags → **Resolve** the condition | closed; nothing stays open on the practice lot |
| 9 | Lucky | (optional) Procurement in gkp (he does not hold it) → a lot | Review stays off until "Why you record at this stage" has 10 characters; the record page shows the reason; the ledger block "Supervisory" |

Claude can drive these in the browser pane once each person has signed in.

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 48 adds one table (`footprint_returns`), columns (`scopes.short_code`,
`footprints.happened_on`, `footprints.manager_reason`, `flags.kind`), the ledger event `return`, triggers and functions.
A short code can be changed in the scope while no record number carries it.
