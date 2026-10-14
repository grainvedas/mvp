# Rules and farmer IDs: migration 44 and the app, onto the practice system

Veda, 14 October 2026, "GrainVeda MVP — Follow-up: State Manager, Client Manager, HR, scopes and farmer IDs", Release 4
of three (sections 0, A, E, D1, D2, D6 and G), and her answer "go with your recommendations". Open item 39 in
`docs/FIX_LIST.md`. What changes:

- **Who may hold a stage** (A1, A2): only an operational person **based in the scope's state**, or the client's own
  **Client Manager** himself (a small client). Never the admin, HR or the State Manager. The roster's list ("the pool")
  shows only those, with "(you)" for the Client Manager. The database refuses the rest in words ("a State Manager holds
  no stage", "this person is not based in Assam").
- **Activation needs people** (A3): a scope is activated only when **every stage has a person**. The People step lists
  what is missing ("nobody yet at Quality Control"); **Activate** stays off until it is empty.
- **The State Manager reads scopes and rosters** (A1, K62 closed): no roster controls, no "A scope" on Assign; he keeps
  "A client's account". His home stays his state's overview even with one scope (D1).
- **The Client Manager's People & access** (A4): his client's people and his state's pool; never the admin, HR or the
  State Manager.
- **Two farmer IDs** (E1, E2): the **client farmer ID** (`PRSDM-F-0001`) is given at the Client Manager's step 1 ("Save
  and verify" or Verify); the **state farmer ID** (`F-UP-00001`) at the State Manager's step 2. If the phone is already a
  state farmer's in the state, he chooses: **the same person** (link to that ID) or **another person** (a new ID, with
  the reason). A farmer's page shows both IDs; a tick records the farmer's consent to show his ID publicly (shown
  publicly only from Release 5).
- **Reasons and history** (E3, E4): every change to a farmer who has an ID needs a reason (also deactivating and
  reactivating); every step and change is a ledger block, listed on the farmer's page as **History**. GI land or phone
  changed after the State Manager's verification by anyone else goes to him: **"1 change of GI land or mobile"** on the
  register and in "Needs my action"; he **accepts** it on the farmer's page.
- **The yield is a warning** (E6): "above the expected yield" on the register, not a flag he must clear.
- **The ledger names the role** each signer held at the time (D6): Client Manager, State Manager, …
- **My guide** (D2): in everyone's menu; it opens the guide of the person's role.
- **HR** (G): one position on a State Manager opening; closed openings left out of the totals; full openings not
  offered when adding a joiner; due dates of open tasks recalculated (none overdue on the day); the state listed once.
- **Test data** (section 0): a person marked as test data (offboarded first) is hidden from lists, kept in the records.

**S1b corrects three practice records** (section 0, nothing deleted, new rows and a ledger block):

| Record | Correction |
|---|---|
| Scope TCUP · KH26 · gkp, activated in a test with nobody on its stages | back to **draft**; a ledger block "Activation reversed: activated in a test with no staff (practice data, 14 Oct 2026; migration 44)". Not changed if it has records |
| Opening UP-SM-001 (10 positions) | **1 position** (Audit log: opening changed). Not changed if more than one person holds it |
| TEST Mine (test.mine@example.com) | **marked as test data**, hidden. Not marked unless offboarded |

The push also gives farmer TCUP-F-0001 (verified on 13 Oct) its state farmer ID, with a ledger block.

**Only when Veda has said so.** This pushes migration 44 to the practice database **and pushes to the main branch**.
Production is not touched. The server functions are unchanged.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-rules-and-ids.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; that migration 44, the smoke check, the ledger audit and the app's files are the tested ones; the practice project, answering `staging`, with exactly migration 44 waiting; the functions current. **Asks you to type `RULES AND IDS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 44 | the push fails (nothing of it is applied) |
| S1b | The three corrections above; prints what it did ("already" when run again) | the function does not answer |
| S2 | Smoke check **40** rows (new: `rules and farmer ids`), the new rules in place, the ledger audit, logins, functions. Then: farmers, with a state farmer ID, verified without one (should be 0), changes to accept, active scopes without a person at every stage | a row or a check is not `OK` (the two pg_cron rows are listed but do not stop it) |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: RULES AND IDS ON STAGING` or `RESULT: STOPPED`. Record:
`release-evidence\staging-rules-and-ids-<time>.log`: send it to Claude.

**Then check Vercel built it**: Vercel → project `mvp` → Deployments must show the new commit as **Ready** within about
5 minutes. If not: the `…` menu at the top → **Create Deployment** → `main` → **Deploy to Production**.
`staging-farmer-register.cmd` has done its job; it now refuses to run.

## Afterwards, in the app (about 20 minutes, made-up data only)

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Lucky (Client Manager, TCUP) | **Scopes** → TCUP KH26 gkp | **Draft** again; the People step says who is missing; **Activate** is off |
| 2 | Lucky | The roster's lists | People based in Uttar Pradesh and "Lucky (you)"; not Veda, not HR, not Ram |
| 3 | Lucky | A person at every stage → **Activate** | Active |
| 4 | Lucky | **People & access** | His client's people and the UP pool; no Veda, no HR, no Ram; the state filter shows Uttar Pradesh only |
| 5 | Ram | That scope | Read only: no lists, no Remove; on a person's **Assign** only "A client's account" |
| 6 | Ram | **Farmers** → TCUP-F-0001 → Edit | Both IDs: TCUP-F-0001 and a state farmer ID F-UP-…; **History**: Ram's verification of 13 Oct and the state farmer ID given by the push. Lucky's step 1 of 13 Oct is shown from the record: it wrote no ledger block then (from now on it does) |
| 7 | the Client Manager of a **second** UP client | A new farmer with the **same phone** as TCUP-F-0001 → Save and verify | A client farmer ID of that client at once. (Within one client a phone is used once: Lucky gets "This already exists (same phone, email or code)" and nothing is saved; checked 14 Oct) |
| 8 | Ram | **Farmers** → Ready to verify → that farmer | "Same phone as F-UP-00001": **Same person: link** or **Not the same person** (a reason) → a new ID |
| 9 | Lucky | TCUP-F-0001: GI land changed | **Save** is off until "Why" is filled in |
| 10 | Ram | Overview → **Needs my action** → changes | The register card "1 change of GI land or mobile" → the farmer → **Accept** |
| 11 | Ram | **System → Ledger** | "Signed by" with the role each held: Client Manager, State Manager |
| 12 | Anyone | Menu → **My guide** | The guide of their own role |
| 13 | HR Admin | **Openings**: a State Manager opening with 2 positions | Refused: "one State Manager per state" |
| 14 | Veda | **People & access** | TEST Mine no longer listed; UP-SM-001 shows 1 position |

## If something is wrong afterwards

Nothing was deleted or rewritten: migration 44 adds two columns to people, two to farmers, three tables
(`state_farmers`, `state_farmer_counters`, `farmer_change_flags`), functions and rules, and changes functions whose
versions it replaced are in migrations 41 to 43. The corrections are new rows, an Audit entry and a ledger block. Ask
before changing anything back.

## Rehearsed

On the local stack, 14 October 2026 (`docs/VERIFICATION_LOG.md`): the database tests (with the upgrade path; test 38
with 17 controls), the corrections on an upgraded copy (ledger audit: no findings), the API tests, the unit tests, the
screen suite with `phase16` at 527 px, the first day from nothing, the production build. The script on stand-ins
(PowerShell 7 on Linux). Not rehearsed: Windows PowerShell 5.1, the hosted project, a real phone.
