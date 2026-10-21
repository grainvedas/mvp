# The client registry, Phase 2 release 1: migration 64 and the app, onto the practice system

Veda, 21 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 2 Parts A and B; "yes, I'll check
everything after completion". Item 60 in `docs/FIX_LIST.md`. Phase 1 is on staging (release 5b since 21 Oct 2026,
17:52 IST, 4a1db4c); this script expects **migration 64** waiting and nothing else.

- **One legal entity, one record, keyed on PAN (A1, A2).** A State Manager opens Clients → **New client** and types the
  entity type, the PAN and the legal name first → **Check the PAN**. A PAN already a client: "Already registered with
  GrainVeda" and its shared identity (legal name, masked PAN, type, registered office's city and state, status, code);
  no second client can be made (the server refuses a direct call too). A PAN known in another role (a buyer): "Known to
  GrainVeda as a business" and nothing about that role. A similar name with another PAN: a soft warning only.
- **The checks (A2).** PAN: 5 letters, 4 digits, 1 letter, its 4th letter by entity type (C company, F firm or LLP,
  P individual, T trust, A society or cooperative, H HUF, G government). GSTIN: the state's GST code (UP 09,
  Uttarakhand 05, Himachal 02, Bihar 10 …; the admin sets it under States for a state without one) and the client's PAN
  in characters 3 to 12. CIN, LLPIN, FSSAI (14 digits), IEC formats.
- **The numbers (A3).** In full only in the registry, read by the admin and the client's own State Managers; masked
  elsewhere (`ABCDE****F`); the audit log and the change log carry a keyed hash, never a number.
- **The gates (B1–B3), per state.** Gate 1 (Prospect, made with the client), Gate 2 (Diagnostic: registered office,
  CIN/LLPIN/registration number, the state's GSTIN or "not registered" with a reason, the authorised signatory, the
  diagnostic order with its date and amount, the certificate of incorporation), Gate 3 (Active: the MSA with its dates,
  the Farmer Data and Consent Addendum, the signatory authority, billing; the FSSAI licence when the client's name is on
  the pack; the IEC and the APEDA RCMC only when a scope exports, the RCMC for an APEDA-scheduled crop: a new tick on
  the crop; the KYC tick after the files). Each gate says "n of m done". The **first Active** of a client is
  **approved by the admin** (Overview → "Clients waiting for your approval").
- **Scopes (B4).** Prepared (draft) only with the client in Diagnostic or Active in that state; activated only Active;
  an export scope needs the IEC (and for rice the RCMC) on file. A client kept from before (below) is not asked its
  IEC until it is backfilled.
- **Who (B5).** The State Manager fills his state's gates, ticks KYC, types a missing PAN once. The admin approves the
  first Active, changes the national identity after Active (with a reason), the code once before Active; fills no gate.
  The Client Manager reads his client's record and contacts (no files). The client's own login reads its company.
- **The clients already there** are kept **Active with "PAN pending"** (off production), each with an entity of its
  own; GrainVeda's own client becomes "GrainVeda Private Limited", trade name Prasaadam, "Own brand of GrainVeda".
  S1b lists every client with its state and status. On production (later) the same clients would be Prospects.

Not in this release: adding a state to a client (Part C), suspend and end, expiry warnings, notifications (Part D) —
release 2; sourcing partners, consent per client, Prasaadam's own gates, the hooks (Parts E–G) — release 3.

**Only when Veda has said so.** This pushes migration 64 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: new tables (`entities`, `entity_roles`, `entity_ids`,
`client_states`, `client_documents`, `client_status_events`), new columns (`clients`: the registry's; `states.gst_code`;
`crops.apeda_scheduled`), the bucket `client-docs`; replaced: the clients' read rule, `app.can_access_client`,
`app.manages_client`, `app.client_states`, `app.scopes_place`. From here **nobody writes `public.clients` directly**
(the old app's client form stops working between S1 and S3).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-client-registry.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 64 waiting; the seven functions current. **Asks you to type `REGISTRY`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 64 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `tables=new functions=new closed=yes scope_rule=yes bucket=yes states_without_gst_code=… clients: <code>=active/PAN pending@UP, …` | anything is not as migration 64 leaves it |
| S2 | Smoke check **62** rows (new: `client registry`), the rules in place, the change log intact (64 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT REGISTRY ON STAGING` or `RESULT: STOPPED`.

## Afterwards (about 30 minutes, phone width; practice data, fake numbers only)

Each person signs in themselves; Claude can then drive the steps in the browser. **Use only fake, format-valid numbers**
(PAN `ZZZC…`, GSTIN `09` + that PAN + `1Z5`); never a real company's.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | Ram (State Manager) | Clients → New client → Company, a fake PAN, "ABC Exim Ltd (test)" → Check the PAN → Gate 1 → Create | the client page: Prospect, a code of 3–5 capitals, Gate 1 "7 of 7 done", Gate 2 "0 of 6" |
| 2 | Ram | New client again with the same PAN | "Already registered with GrainVeda", the masked PAN; no form to create |
| 3 | Ram | Details: a GSTIN starting `05`, then `09`; office, CIN, signatory; upload the diagnostic order (date, amount) and the incorporation certificate (any small PDF) → Move to Diagnostic | the `05` refused in plain words; Gate 2 "6 of 6"; Diagnostic |
| 4 | Ram | Billing; upload MSA, Consent Addendum, signatory authority → the KYC tick → Ask the admin to approve | "Waiting for the admin's approval" |
| 5 | the admin | Overview → "Clients waiting for your approval" → the client → Approve | Active; the admin sees no form to fill |
| 6 | Ram | Clients → Test Client UP | "PAN pending", "Registered before the registry"; (optional) Type the PAN with a fake one |
| 7 | Lucky (Client Manager) | Clients | his client only; its record, no files |
| 8 | tcup | Clients | its company only; no "New client" |

Not checked on staging (the tests cover them): another state's State Manager (no second one on staging), a business
known as a buyer, the IEC/RCMC/FSSAI rules, a scope refused before Diagnostic or before Active, the admin's code edit
(`tests/59_client_registry.sql`, 82 checks and 14 controls; `web/tests/release64.test.tsx`; `e2e/phase36.spec.ts`).

## If something is wrong afterwards

Nothing was deleted or rewritten. A test client made by mistake stays a Prospect (it can be left; deleting is never
done). A wrong number is replaced by a new one (the old is kept, not current). A wrong code: the admin changes it once
before Active.
