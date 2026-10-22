# Client accounts, Phase 3 release 1: migration 67 and the app, onto the practice system

Veda, 22 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 3 Parts A and B, with Phase 2's B4
(missed in Phase 2 and found while planning Phase 3); "ok continue". Item 64 in `docs/FIX_LIST.md`. Phase 2 (migrations
64–66) is on staging since 22 Oct 2026, 01:24 IST; this script expects **migration 67** waiting and nothing else.

- **How a scope is run (Phase 2, B4).** On a scope's page, "How this scope is run": **Managed** (GrainVeda's people
  record), **Hybrid** (the client's people record, GrainVeda verifies), **Self-run** (the client runs it, GrainVeda
  audits). For a GI crop, the client's **GI authorised-user number** with its certificate. Set by the scope's Client
  Manager; a change on an active scope needs a reason; every scope of before is Managed.
- **Three kinds of client account (A1).** On the client's page, **Client accounts**:
  - the **owner**: made by the admin once the client has been Active; more than one allowed. It sees everything of its
    client, shares with buyers, uploads its written acceptance on a lab record and its renewals, invites viewers and
    says which may download internal copies;
  - the **viewer**: made by an owner (the whole client, one state, or the scopes chosen) or by the Client Manager (one
    state's scopes only, on People → Client logins too). It reads and downloads the shareable copies; internal copies
    only when the owner allows it. It changes nothing;
  - the **client's own staff**: made by the Client Manager. They hold stages only on a Hybrid or Self-run scope of
    their client (offered in its roster), record and verify there as GrainVeda's operators do; a record they make says
    **"Recorded by client staff"** and is verified by GrainVeda at the next stage.
  An account is Active, Suspended or Removed, by whoever may make it (the admin for owners); every change is in the
  Audit log. Client accounts are not employees: no HR record, no checklist, no opening.
- **One rule for every write (A2).** The database refuses every write of a client account except its kind's list
  (`app.client_may`). While the client is suspended in a state, the owner reads and downloads only (revoking a buyer
  link still works).
- **Today's client logins (A3).** Each becomes a **viewer of all its client's scopes** (tcup on staging). The admin may
  promote one to owner ("Make owner").
- **Each client its own (B).** A client account sees only its own client; a viewer only what it reaches (its scopes,
  their farmers, its client record's states, its notices). No client account reads another client's users, any HR
  record, or GrainVeda's people beyond the names on the records they made.

Not in this release: the portfolio and the client's exports (release 2), orders across scopes (3), the evidence pack
(4), the showcase page and badge, and switching off an ended client's accounts after the lifetime period (5).

**Only when Veda has said so.** This pushes migration 67 to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: new columns (`scopes.delivery_model`, `gi_user_no`,
`gi_user_file`, `gi_user_sha256`; `footprints.client_staff`), new closed tables (`client_accounts`,
`client_account_scopes`, `client_account_intents`), one account row for each client login of before; replaced from
their own text, each change named in the migration: the trigger of every client-login guard, the evidence store's
upload rule, the buyer links' read rules, the scope and roster rules for a client operator, the making of a client
login, the internal copy, the client's farmers, record and list, its notices, its renewals, its buyer links, the season
report's delivery model.

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-client-accounts.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 67 waiting; the seven functions current. **Asks you to type `ACCOUNTS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: migration 67 | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `tables=new closed=yes functions=new triggers=yes logins_without_account=0 accounts: TCUP=viewer/client/active … delivery: managed=…` | anything is not as migration 67 leaves it |
| S2 | Smoke check **65** rows (new: `client accounts`), the rules in place, the change log intact (71 tables), **one client and another** (`leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT ACCOUNTS ON STAGING` or `RESULT: STOPPED`. Between S1 and S3 (if a run stops there) the old
app reads as before but cannot make a client login: run the script again.

## Afterwards (about 25 minutes, phone width; practice data, fake names and emails only)

Each person signs in themselves; Claude can then drive the steps in the browser.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | the admin | Clients → Test Client UP → **Client accounts** | tcup listed as **Viewer**, "Every scope of the client" (A3); the form offers an **owner** only |
| 2 | the admin | the form: a name, a practice email → Create | a temporary password shown once; the owner listed |
| 3 | the new owner | sign in with it, set its own password; Clients → Test Client UP → Client accounts → Sees: **Chosen scopes**, tick Bansi; a name, a practice email → Create | a temporary password; the viewer listed with "Chosen scopes: … Bansi" |
| 4 | the new viewer | sign in, set its password | only Bansi in the scope picker; no stage page; no Client accounts card |
| 5 | the owner | a TCUP sale or shipment record (e.g. Bansi's latest) → **Share with buyer** → a link; then revoke it with a reason | the link made, then "revoked" |
| 6 | Lucky (Client Manager) | Season Scopes → Bansi → **How this scope is run**: Hybrid, a reason → Save | "Saved."; Managed → Hybrid in the Audit log |
| 7 | Lucky | People → Client logins → Account: **Client staff**, a name, a practice email → Create; then Bansi's roster | a temporary password; the staff offered on Bansi's stages (not on a Managed scope's) |
| 8 | (optional) the staff | sign in, record a farm-gate lot on Bansi | the record says "Recorded by client staff"; it cannot verify its own; Lucky (GrainVeda) verifies it at the next stage |
| 9 | the owner | Client accounts → the viewer → **Suspend**, a reason; then Resume | while suspended the viewer sees nothing; then its scope again |
| 10 | Lucky | Bansi → How this scope is run → Managed, a reason (after ending the staff's stages, if given) | Managed again |

Not checked on staging (the tests cover them): a second client's people (staging has one client with staff; the
probe in S2 reads every table as each client's people: `leaks=0`), a Client Manager's viewer of another state (staging
has one state with people), the owner's acts paused while the client is suspended, a removed account, the
entity that is both a client and another's buyer (`tests/62_client_accounts.sql`, 77 checks and 18 controls;
`web/tests/release67.test.tsx`; `e2e/phase39.spec.ts`, at 527 px: the admin's owner, the owner's viewer of one scope,
the Client Manager's Hybrid scope and client staff).

## If something is wrong afterwards

Nothing was deleted or rewritten. An account made by mistake is suspended or removed (removing is final: make a new
one); a viewer that sees too much: "Change what it sees"; a scope set Hybrid by mistake: back to Managed with a reason
(once the client's staff hold no stage there). The accounts of before stay viewers until the admin promotes one.
