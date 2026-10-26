# Client views, Phase 3 release 2: migrations 68 and 69 and the app, onto the practice system

Veda, 26 October 2026: the combined brief ("GrainVeda MVP: combined brief"), Phase 3 Parts C and E4, with item 65 (the
run sheet's checks of release 1); "release 2 next proceed". Item 66 in `docs/FIX_LIST.md`. Phase 3 release 1 (migration
67, client accounts) is on staging since 22 Oct 2026 (head 3fd1531); this script expects **migrations 68 and 69** waiting (or **69** alone: the run of 26 Oct, 17:03, pushed 68) and
nothing else.

- **What client users see (C).** A client account (owner or viewer) has **Portfolio** in its menu; GrainVeda's people
  who read the client (the admin, its State and Client Managers) open it from the client's page, **Portfolio and
  exports**. Three tabs:
  - **Portfolio**: the totals; then by state and crop; then each scope it reaches, with procured, in process (verified,
    not yet packed), packed, sold, shipped, packs released, scans, open copy flags, open lab results (samples at the lab;
    results failing every market of the scope with no acceptance), recalls, waiting on GrainVeda. A scope opens its own
    view: the pipeline by stage, lots and batches, QC per market with the lab and report number, documents, the reports
    issued, the people on each stage (name and role only).
  - **Across scopes**: buyers and orders, scans by city, copy flags, recalls, the outputs issued (the evidence packs join
    this list in release 4).
  - **Farmers**: the client's own farmers (their records are their consent to it); never a phone.
- **Prices.** The client's own prices are on the screens and in the internal copy only for those who may take the
  internal copy: the owner, the viewers it allowed, GrainVeda's people of the client. A plain viewer sees none.
- **Exports (E4).** Every view downloads as Excel or CSV, made on the server from the same data as the screen
  (`app.export_client_view`, so a later API can use it): the **shareable** copy by default (no price, no farmer's name
  or phone), the **internal** one for those allowed. Every download is written in the Audit log ("downloaded an export:
  the client's view, …").
- **Item 65.** People → Client logins says what each client account is ("Client staff: Test Client UP", "Client owner:
  …", Suspended); the person's page of an owner says "Client owner", not "Client login (read-only)"; a sign-in that
  opens nothing tells a client account to ask its owner or Client Manager (not only HR); the viewer's scope list marks a
  closed scope; a client account's scope home shows what was shipped instead of "My action queue".

Not in this release: orders across scopes (release 3), the evidence pack (4), the showcase page and badge, and switching
off an ended client's accounts after the lifetime period (5).

- **The check in parts (migration 69).** S2's check that one client sees nothing of another ran past the project's
  time limits on 26 Oct (the query's 2 minutes, then the gateway's 100 seconds) after 68 was pushed. Migration 69 adds
  the same check in parts (`app.isolation_probe_part`): S2 runs it in eight parts, which together do exactly what the
  whole check does, and adds up their answers.

**Only when Veda has said so.** This pushes migrations 68 and 69 (what is waiting) to the practice database and **pushes to the main branch**.
Production is not touched. Nothing is deleted or rewritten: new functions only; replaced from their own text, each
change named in the migration: the people directory (`app.people_page`) and the person's page (`app.employee_profile`)
say what a client account is; the isolation probe of S2 (`app.isolation_probe`) counts a person's own rows as his own (an
ended assignment of his was counted as a leak on the local stack).

## One double-click (about 3 minutes, then Vercel)

Double-click **`staging-client-views.cmd`** in the repository root.

| Step | What it does | It stops if |
|---|---|---|
| S0 | Checks the tools; the tested files; the practice project, answering `staging`, with 68 and 69 waiting, or 69 alone; the seven functions current. **Asks you to type `VIEWS`** | any check fails or anything else is typed. Nothing is changed |
| S1 | `supabase db push`: what is waiting (69; 68 too if it is waiting) | the push fails (a migration is one transaction) |
| S1b | Reads back (read only): `functions=new closed=yes people=yes probe_parts=yes scopes_in_views: TCUP=… accounts: …` | anything is not as migrations 68 and 69 leave it |
| S2 | Smoke check **66** rows (new: `client views`), the rules in place, the change log intact (71 tables), **one client and another**, in 8 parts (`part 1 of 8: leaks=0 …` … then the sum `leaks=0 …`), the ledger audit, logins, functions | a row or a check is not `OK` (statement logging stands); any leak stops it before the app is pushed |
| S3 | Commits and pushes the app | git shows a `.env` file, a key, a spreadsheet, a backup or the run record |

Last line: `RESULT: CLIENT VIEWS ON STAGING` or `RESULT: STOPPED`. Between S1 and S3 (if a run stops there) the old app
works as before (it does not offer the Portfolio): run the script again.

## Afterwards (about 20 minutes, phone width; practice data only)

Each person signs in themselves; Claude can then drive the steps in the browser. The accounts are those of release 1's
checks: tcup (viewer of the whole client), Practice Owner TCUP, Practice Viewer Bansi, Practice Staff Bansi.

| # | Who | Do | Expect |
|---|---|---|---|
| 1 | tcup | the menu → **Portfolio** | the totals; "Uttar Pradesh · Kalanamak Rice"; each scope (Bansi, gkp, Siddharthnagar, the closed practice one); Bansi's procured kg as on its dashboard; no "Copy" choice |
| 2 | tcup | **Download Excel** | `grainveda-portfolio-TCUP-shareable.xlsx`: a Heading sheet, then Scopes, By state and crop, Total; the footer "No prices, no farmers' names or phones" |
| 3 | tcup | a scope (Bansi) | the pipeline by stage; lots (the recalled practice lot says Recalled); batches; QC with its lab and report number; documents; the people by name and role only; **Download CSV**: no phone in it |
| 4 | tcup | **Across scopes** | the orders with their buyer and kilograms, **no price**; scans by city; recalls with their reason; the outputs (the season report, if issued) |
| 5 | Practice Viewer Bansi | Portfolio | **Bansi only**; Farmers → Download CSV: the farmers who sold into Bansi, Farmer ID and village, **no Name column**, no phone |
| 6 | Practice Owner TCUP | Across scopes → Copy: **Internal copy** → Download CSV | `…-internal.csv` with the price per kg and the total; the footer "Internal: contains personal and commercial data. Do not forward." |
| 7 | the admin | Clients → Test Client UP → **Portfolio and exports**; then the **Audit log** | the same portfolio; the Audit log lists the downloads above ("downloaded an export: the client's view, …, Shareable/Internal copy") |
| 8 | Lucky (Client Manager) | People → Client logins; then Practice Owner TCUP's page | "Client staff: Test Client UP" on the staff's row; "Client owner" on the owner's page (item 65) |

Not checked on staging (the tests cover them): a second state's scopes in the portfolio (staging has one state with
data), a failing lab result closed by the client's acceptance, another client's account refused, client staff refused
the portfolio, the data functions closed (`tests/63_client_views.sql`, 48 checks and 17 controls;
`web/tests/release68.test.tsx`; `e2e/phase40.spec.ts`, at 527 px).

## If something is wrong afterwards

Nothing was deleted or rewritten: migrations 68 and 69 only add functions and says what a client account is in two lists. A
figure that looks wrong: compare it with the scope's dashboard and send both to Claude; the export is the screen's own
data. A download in the Audit log cannot be removed.
