# A client in several states, its status, Phase 2 release 2: migration 65 and the app, onto the practice system

Veda, 21 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 2 Parts C and D; "yes, I'll check
everything after completion". Item 61 in `docs/FIX_LIST.md`. Phase 2 release 1 (the client registry, migration 64) is on
staging since 21 Oct 2026, 21:16 IST; this script expects **migration 65** waiting and nothing else.

- **A state added to a client (C).** A State Manager typing the PAN of a client already registered sees "Already
  registered with GrainVeda" and one action per state of his own: **"Add [my state] to this client"**. One record, the
  same client code. His state starts as a Prospect and goes through its own gates (its GSTIN starts with that state's
  code and carries the same PAN); the national items (MSA, Consent Addendum, signatory authority, IEC, RCMC) are reused
  and show **"on file"** there (the file itself stays with the home state's State Manager). Once the admin has approved
  the client's first Active, a later state needs only its State Manager's KYC tick.
- **Told (C).** The client's other State Managers, its own login and the admin see a notice above every screen
  ("ABC Exim added in Uttarakhand by …"); "Mark as read" clears it. The same for a suspension, a resumption, an end, a
  return, and a renewal uploaded by the client's login.
- **Each his own state (C).** A State Manager reads his own state's part of the record and his own state's scopes;
  the client's own login reads every state's scopes in one portfolio. The State Manager of any of the client's states
  may give it a Client Manager (one per client, as today). The scope's form offers the client's states where it is
  Diagnostic or Active.
- **The status per state (D).** On a state's card: **Suspend** (an Active client), **Resume**, **End**, **Return**
  (an Ended client back to Diagnostic: Gate 3 and the KYC tick again). Its State Manager or the admin; the admin also
  "in every state" at once. A reason every time (10 characters or more), kept in the client's history and the Audit
  log. A status the admin set is moved back by the admin.
  - **Suspended**: no new procurement or lot inward, no sale, shipment or QR release. Work already in progress may be
    processed, checked and packed (and verified). Released pages stay live and say **"Verification paused"**.
  - **Ended**: every record of the client's scopes in that state reads only. The public pages say **"Verification
    ended on [date]"** and stay live for the longer of best-before + 12 months and 24 months after the end; after that
    they say the page is no longer live and show nothing of the lot.
- **Warnings, never an automatic suspension (D).** An FSSAI licence (per state), the APEDA RCMC and the MSA, 60 and 15
  days before they expire and after: "Expiring soon" on the Clients list and on the client's record, for the admin and
  the client's State Managers. Then the State Manager renews or suspends.
- **Renewals (B5).** The client's own login uploads a renewed FSSAI licence, RCMC or MSA (Clients → its company →
  Renewals); its State Manager accepts it (it becomes the current document, the expiry moves) or declines it with a
  reason.

Not in this release: sourcing partners, consent per client, Prasaadam's own gates, the hooks (Parts E–G) — release 3.

**Only when Veda has said so.** This pushes migration 65 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: new columns of `client_states` (`ended_on`,
`status_by_admin`, `status_reason`), new tables (`notifications`, `client_renewals`), new functions and triggers;
replaced from their own text, each change named in the migration: the public lot and pack pages, the buyer's link,
`app.may_assign`, `app.client_view`, `app.lookup_pan`, `app.add_client_document`, the client store's read and write
rules. Every client keeps its status (S1b lists them).

## One double-click (about 3 minutes, then Vercel)

**Since release 3 (22 Oct 2026) this release goes to staging with it: double-click `staging-sourcing-hooks.cmd`
(`docs/RUNSHEET_sourcing_hooks.md`), which pushes migration 65 and then 66 and expects both waiting. Do not run
`staging-client-status.cmd`: it checks the app files of release 2 alone and stops at S0.** The steps below are what
that script does for migration 65 (its S1b prints this release's line first).

Double-click **`staging-sourcing-hooks.cmd`** in the repository root (type `SOURCING`).

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 65 and 66 waiting; the seven functions current. **Asks you to type `SOURCING`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 65 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `tables=new columns=new functions=new closed=yes status_rule=19 public_pages=yes clients: <code>=<status>@<state>, …` | anything is not as migration 65 leaves it |
| S2 | Smoke check **64** rows (new: `client status`, `sourcing and hooks`), the rules in place, the change log intact (68 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT STATUS AND SOURCING ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 25 minutes, phone width; practice data, fake numbers only)

Each person signs in themselves; Claude can then drive the steps in the browser. Every change below can be put back
(resume, a new upload); nothing is deleted.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram (State Manager) | Clients → Test Client UP → the Uttar Pradesh card → **Suspend**, a reason ("Practice: payment check") | the card says Suspended and why; the note "no new procurement or sale … Verification paused" |
| 2 | anyone, signed out | open a released lot or pack page of Test Client UP (a QR code from the Phase 1 checks) | "Verification paused" above the journey; the journey still there |
| 3 | an operator of a Test Client UP scope (optional) | My stages → Procurement → a new lot | refused in plain words: "suspended in this state: no new procurement" |
| 4 | Ram | the same card → **Resume**, a reason | Active; the public page no longer says paused |
| 5 | Ram | Clients → the test client of release 1 (e.g. "ABC Exim (test)") → its state's details: tick "name on the pack", an FSSAI number (14 digits, fake) with an expiry **30 days** from today → Save | Clients list: "Expiring soon" with that licence, "Within 60 days" |
| 6 | tcup (the client's login) | Clients → its company → **Renewals**: Master Services Agreement, the dates, any small PDF → Upload | the renewal "waiting for the State Manager"; no Suspend or End buttons for the login |
| 7 | Ram | the notice "…: a renewed Master Services Agreement uploaded by …" → the client → **Accept** | "accepted"; the MSA on file is the new one |
| 8 | the admin | any screen | the notices of steps 1, 4 and 6 (suspended, resumed, a renewal) → Mark as read |

Not checked on staging (the tests cover them): adding a second state to a client (staging has one State Manager),
the notices to another state's State Manager, End and Return (the test client would then need its Gate 3 again), the
lifetime rule after an end, the admin's moves in every state at once (`tests/60_client_states_status.sql`, 78 checks and
19 controls; `web/tests/release65.test.tsx`; `e2e/phase37.spec.ts`, which adds Assam to a client at 527 px).

## If something is wrong afterwards

Nothing was deleted or rewritten. A suspension is undone by Resume (the admin's by the admin); an end by Return (then
Gate 3 and the KYC tick again). A wrong renewal accepted is replaced by the next upload (the old document is kept,
superseded). A notice read by mistake stays in the client's history and the Audit log.
