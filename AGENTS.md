# Rules for coding agents (Antigravity IDE, Claude, Cursor, …) working in this repo

You are working on the GrainVeda MVP, built from the PRD: https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb
Phases 0 to 4 and the identity layer (Phase 5, 6 October 2026: `docs/IDENTITY_DESIGN.md`) are built and tested on a
local stand-in. Do not weaken a database rule to make a screen easier.
Where things stand: `README.md`. What is known to be missing: `docs/FIX_LIST.md`.
**The interface has the prototype's look and frame** (decision G8 = B, Veda, 4 October 2026; it replaced A of the same
morning). What the forms ask for is still this system's: do not add the prototype's fields or screens without a new
decision. `docs/INTERFACE_GAP.md` is the list to choose from; faults are fixed whenever they are found.

## Non-negotiables

1. **Rules live in Postgres.** Permissions, chain order, reconciliation, immutability and the ledger are enforced by
   triggers and RLS in `supabase/migrations/`. The front-end mirrors them for live review; it never becomes the only check.
2. **One stage engine.** Every stage type is rendered by ONE generic 8-step component driven by `stage_definitions.form_schema`
   and `handoff_checks`. Never write per-stage screens or a second save path (the prototype's dual code path is the bug we are removing).
3. **Sacred stamps are server-side.** Never send `client_id` (it is overwritten from the scope), never compute `qty_in`/`qty_out`
   in the client and expect them to stick. Read canonical `qty_out`, never raw payload fields, for anything quantity-related.
   A signed-in person's direct API write may set only the columns migration 22 allows; codes, dates, status, lot state,
   quantities, computed values and verdicts are the server's. Do not loosen those triggers.
4. **Thumb rule.** A stage reads only the stage directly behind it, via `app.incoming_records(scope_id, stage_type)`. Do not
   query `footprints` by hardcoded stage names. The ledger follows the same rule (migration 25): an operator reads the
   blocks of the own stage and the one behind, nothing else.
5. **Verification is by the receiving stage.** Call `app.verify_record(id, reason, condition)` (migration 48; the older
   `app.verify_footprint(id)` is the same without them) as the operator of the next stage, or send it back with
   `app.return_footprint`. A person who holds two stages in a row verifies his own record, marked (migration 46).
6. **Seal only through `app.seal_source(source_id)`.** It records the QR stage and seals in one transaction, so a refused
   seal leaves nothing behind. `app.seal_lot(qr_footprint_id)` mints the QR code and is called by it; the screens call
   it directly only to finish a QR record left behind by an older build.
7. **No deletes.** Footprints, verdicts, seals, flags and ledger rows are never deleted. A pending Procurement, Lot Inward
   or processing record is corrected in place (the ledger keeps both versions). A lab record, a Village Batch, a split
   grading run, a grade lot or anything verified is **withdrawn** by a manager with a reason (`app.withdraw_footprint`)
   and recorded again with `supersedes_id`. Grade lots are made by the save itself (trigger); never insert one.
8. **Review = Save = Verify.** The number shown at step 6 is what the server saves and what the next operator sees at step 3.
   Use the same derivation the server uses (`app.reconcile` rules, PRD §7) — port it, do not reinvent it.
9. **Logins are made by service code only**: the `create-user` and `reset-password` Edge Functions,
   `scripts/bootstrap_admin.mjs`, `scripts/create_demo_logins.mjs`. A public sign-up never becomes a GrainVeda user
   (migration 23). The service key never reaches the browser or git. Every person HR adds signs in by **email +
   password**; the demo operators of seeds 02 to 05 keep phone sign-ins. No SMS is sent, and no mail unless a sender
   is configured (none is).
10. **HR creates a person; a manager gives access. Never both in one act** (identity layer, migrations 31 to 33).
    - A person is written only by the functions of migration 33 (`app.add_joiner`, `app.add_client_viewer`, the
      lifecycle functions). The API may not insert into `app_users` and may update only name, phone and email.
      `role`, `client_id`, `state_ids` are a **summary the database writes** from the assignments: never read them
      to decide access, never write them.
    - Access is the **union** of a person's live assignments (`public.assignments`: scope / client / state) plus the
      system role. HR's system roles grant people records and nothing else: no rule may let HR assign.
    - **A rule about a record asks about the scope in hand**: `app.manages_scope(person, scope)`,
      `app.manages_client`, `app.acts_in_scope`. Never "is this person a manager" on its own
      (`is_gateway_role(user_role_of(x))`): a manager of client A who holds a stage for client B is not a manager in
      B. `tests/24_union_access.sql` builds that person; a new record function needs its case there.
    - An assignment only moves forward (given, stages changed, ended, replaced). `audit_log` is append-only. A person
      is never deleted: suspended, or offboarded and re-hired on the same record.
    - Identity and bank numbers are checked in full in the browser (`web/src/lib/people.ts`) and sent **only** to the
      server function `id-numbers` (`web/src/lib/idNumbers.ts`), which keeps nothing: the database gets a keyed
      fingerprint (HMAC-SHA256, key `ID_HMAC_KEY` only in that function's secrets) and the last four characters
      (migration 37). Never add a column, a log line, an error text, an outbox entry or a request that carries the full
      number; `web/tests/id_numbers.test.ts` and `e2e/phase10.spec.ts` (a search of everything the stack wrote) hold it.
      Duplicates are refused by unique fingerprints; never compare numbers any other way.
      HR documents live in the private store `hr-docs`, readable by HR only (the admin only while the HR Admin seat
      is empty: `app.acts_as_hr`, migration 35).
    - The once-a-day sign-in code is built and **off**. `app.current_user_id()` is gated by it: use that function
      (not `auth.uid()`) for "who is signed in" in any rule, or the gate has a hole.
11. **Two systems.** Production is the project marked by `supabase/seeds/production/10_reference.sql`. Any script that
    writes demo data or runs a destructive check calls `assertNotProduction` first. Demo seeds 02–06 never go there.

## The phone (web app): what must stay true

- **Who is signed in is read from the phone, not asked of the network**: `keptLogin()` in `web/src/lib/keptLogin.ts`.
  Never use `supabase.auth.getSession()` to decide whether someone is signed in or to get a token for a request: with no
  network it answers "nobody" after up to 25 seconds, one hour after the last contact.
- **Every data request gets its token from `accessToken()`** (`web/src/lib/supabase.ts`: the data client). While someone
  is signed in, a request never goes out with the public key; a token that cannot be renewed now is "no connection".
- **Every save of a record goes through `insertOnce(row, saveId)`** (`web/src/offline/outbox.ts`), with one id from the
  first tap, whether it is sent at once or kept on the phone first. Never insert into `footprints` any other way: a
  save whose answer is lost would be stored twice. A new kind of write that can be retried needs its own such id.
- **`useAsync().reload` loads what is on screen now.** It is handed to buttons and rows, and an action can finish
  after the person changed tab or filter; the hook keeps the newest loader for that (`web/tests/use_async.test.tsx`).
  Do not hold a list's loader in a closure of your own.
- A request that can leave an operator stuck is bounded: reads of forms use `cached()` (the phone's copy after 8 s on a
  dead link), the maths step `within()`, saves 30 s, photo uploads 240 s. What is kept on the phone is cleared on every
  sign-out and when the server no longer knows the person; if you keep something new there, add it to
  `docs/OPERATIONS.md` ("Phone lost or stolen").
- **Every visible string goes through `t()`** with an English key in `i18n.en.ts` and Hindi in `i18n.hi.ts` (a word the
  public verify page shows goes in `i18n.public.ts` instead: the public page loads only that file, K13). Words that come
  from the database in English are shown by key with the English as fallback (`stage.* field.* opt.* check.* qp.*
  computed.* badge.* event.*`). A new stage, field, option, hand-off check, status or ledger event needs its Hindi;
  refresh `web/tests/fixtures/stage_definitions.json` with
  `psql -Atc "select jsonb_pretty(jsonb_agg(to_jsonb(d) order by d.sort_order)) from public.stage_definitions d"`.
  Unit tests fail on a missing key, a missing Hindi label, and on plain text in an operator screen.
- **How a record's values are shown is one file, `web/src/engine/values.tsx`** (`ComputedRows`, `EnteredRows`,
  `showComputed`, `showEntered`), for the review step, the arrival check, the record page and the journey. Never push a
  value of unknown type through `num()` or print it with `JSON.stringify`: a batch code came out as "NaN" and a list
  as code text (FIX_LIST 22, 26). A new worked-out key needs `computed.<key>` in both dictionaries and a place in
  `ORDER`; a stage's name is `t('stage.<type>')` on every screen.
- **A record has two times.** `captured_at`: when the work was done (the phone's clock, accepted by the server within
  31 days back and 5 minutes ahead; migration 29). `created_at`: when the server stored it. "When was this recorded" is
  `capturedAt(f).at` in the app and `coalesce(captured_at, created_at)` in SQL; `created_at` alone only answers "how
  long has it been at the server". The phone sends `captured_at` only for a save that waited in the outbox
  (`insertWithCaptureTime`). Never name it in a `select` list: the app must keep working on a database that does not
  have the column yet (it retries without it on `PGRST204`).
- **The lab verdict before saving comes from the database** (`app.preview_verdict`, the save's own rule). Do not work it
  out in the browser; `tests/21_verdict_preview.sql` holds the preview and the save to the same answer.
- **On a phone the header is three single lines** (practice strip, top bar with the person's name, menu that scrolls
  sideways) and no page is wider than the screen; `e2e/phase5.spec.ts` bounds both. In `styles.css` a width override
  goes after the rule it overrides: put before it, the practice strip showed no words at all on phones.
- **Two sizes, one set of screens** (decision B). A laptop (900 px and wider) gets the top bar and the dark side menu;
  below that the phone frame. Every colour is a token at the top of `styles.css` (the prototype's values; text pairs
  hold 4.5:1): never a colour written into a component. The frame is `shell/Layout.tsx`; the scope in force is
  `useScope()` from `shell/scope.tsx` ("Overall" when a person has several scopes and has chosen none), never a second
  piece of state. Which first screen a person gets is the pure `firstScreen()` in `pages/Home.tsx` (joiner, HR,
  nobody assigned, pick a place, stages, scope, overall); the menu is `NAV` in `shell/Layout.tsx`, shown by what the
  server says the person may do (`me.can`), not by the role word. A scope carries `manage` and `whole` per person.
  People who only hold stages work in ONE scope at a time (the picker; a rule of the screens, the API follows the
  union). First screens are `pages/Home.tsx`; their figures come from `app.pipeline_summary` through
  `scopeFigures()`: do not count records in the browser.
- **A form's sections are data.** Each field in `supabase/seeds/01_stage_definitions.sql` carries `"section"`: display
  only, the database does not read it. A new section name needs `section.<name>` in both dictionaries and a pictogram
  in `engine/icons.ts` (`SECTION_ICON`); a new stage type needs one in `STAGE_ICON`; fields of one section stand
  together. A field type that needs the whole row of a two-column form goes into `FULL_WIDTH` (`engine/widgets.tsx`).
  `tests/look_b.test.tsx` fails on any of these; `e2e/phase6.spec.ts` holds the frame, the first screens and the
  two-column form at 1366 px and their folding to one column at 390 px.
- **Offline maths (`web/src/engine/offlinePreview.ts`) mirrors `app.reconcile` for Procurement and Lot Inward ONLY.** Any
  change to those two rules in SQL must change the mirror and `web/tests/phase3.test.ts` in the same commit. Do not add
  other stages: offline saves of every other stage are checked by the server at sync (decision D10).

## Working method

- Any schema or rule change = a new migration file + a test in `tests/` + `tests/run_local.sh` green. Never edit an applied migration.
- **Run `tests/run_local.sh` before every `db push`.** A migration that passes on Supabase can still break a rule the suite covers (migration 7 did).
- To change a function's settings (search_path, security) use `alter function … set …`. Never re-paste a function body from memory: retyped bodies drift (migration 7 dropped two gate checks and added a wrong one).
- **Every new `app` function is closed by hand:** end the migration with `revoke execute on function app.x(...) from public, anon, authenticated;`
  and grant it by name only if it is API. Postgres grants EXECUTE to everyone by default and `app` is exposed over REST.
  Add API functions to the allowlist in `tests/08_api_surface.sql`; that test fails the build on anything left open.
- **A read policy decides from the row's own columns.** A policy that looks its own row up by id
  (`using (app.can_access_x(id))`) cannot see a row inside the statement that inserts it, so `INSERT … RETURNING`
  (what `supabase-js` sends when the app writes `.insert().select()`) is refused for everybody: scopes in Phase 1
  (migration 18), clients on 5 October (migration 30). Test every table a screen inserts into with `returning *`, as
  each role that may insert.
- **Demo data hides set-up faults.** What a seed puts in place was never made through the screens. Anything a real
  client needs before its first lot (client, manager, scope, people, farmer) has to be made in a test the way a
  person makes it: `e2e/phase7.spec.ts` "A brand-new client from nothing: HR adds the people, managers give them
  access, the first lot is sealed".
- **A migration that writes rows of its own** (migration 31: the standard joining checklist) is also in every backup:
  the restore drill empties what the migrations filled before it loads the data, and `docs/RESTORE.md` says the same
  for a hosted restore. Run `node scripts/restore_drill.mjs` after adding such a migration. **A new kind of ledger
  block** needs its line in `tests/remote_ledger_audit.sql`, or the audit reports it as a block without a counterpart.
- **A migration that moves or rewrites existing rows must be run on a database that has rows.** Every test builds
  from nothing, where the tables are still empty when the migration runs: on 6 October migration 31 passed 870
  checks and would have stopped on staging at its first `update` (an older trigger refused it). The "upgrade path"
  step of `tests/run_local.*` builds the database as it stood before the identity layer, with the demo people,
  applies the later migrations one transaction each, and runs every test again. A new migration after 33 is applied
  in that second group automatically; if it changes what an OLDER migration left behind, move the cut-off.
- **Run the whole thing from a clean build before calling it done**: `scripts/collect_release_evidence.sh --fresh`.
  On 6 October the per-file runs were all green and the full run found four faults (ledger audit, restore drill, a
  test that used a closed route, a stale list reload).
- **A test runner needs a control too.** `tests/run_local.ps1` printed `ALL TESTS PASSED` for nine days whatever the
  test files did: in PowerShell a function returns everything printed inside it, the rows psql printed made the answer
  a list, and a list is "true". It now discards the rows and begins with a self-test that must fail. When you write
  or change a runner, a CI step or a gate script, make it fail once on purpose and read its last line and exit code.
- **A fix needs a test that failed before the fix.** Reproduce first (a failing test, or a probe of the app as it is), then
  fix. If the old behaviour passes your new test, you have hardened something, not fixed a fault: say so
  (`docs/FIX_LIST.md` keeps the two apart). A check that cannot fail proves nothing: give every new check a negative control.
  For a screen: run the new test against the app as it was (the previous commit served on another port).
- **A check of a text is not a check that it is shown.** `toContainText` and `toHaveText` read hidden text too: use
  `{ useInnerText: true }`, or `toBeVisible()` on the element that carries the words. After a change to the layout,
  look at pictures of the changed screens at 390 px and at 1366 px before calling it done.
- The tests of 4 October name faults "item 6" to "item 16": the open-item numbers of that day. `docs/FIX_LIST.md`
  lines 22 to 31 say which is which.
- Do not claim something works without running it. Paste the relevant output in your summary. Say which system it ran on:
  the local stack is a rehearsal, staging is the test, and the release gate (`scripts/release_gate.mjs`) reads result
  files and keeps the two apart.
- When a test fails, first decide whether the rule or the test is wrong. Rules trace to the PRD sections named in the SQL comments.
- **The server functions are a third deploy, apart from the database and the app.** When a migration changes what a
  function must send or may rely on (migration 23 did: logins need `app_metadata.grainveda_login`), or a function
  changes what the app relies on, raise `VERSION` in all six `supabase/functions/*/handler.ts` (`create-user`,
  `reset-password`, `ledger-check`, `daily-code`, `id-numbers`, `invite`) and `FUNCTIONS_NEEDED` in `web/src/lib/api.ts`
  (`web/tests/functions.test.ts` holds them together), and say in the run-sheet that the functions step (Phase 5 D4)
  has to be repeated. A step that makes two things in two systems (a person's row, then a login) takes both back on
  every way out, checks that the removal happened, and says why the second step failed: "created but not linked"
  with no reason cost a day (FIX_LIST fault 32). When you write a prompt for another agent, name every step, not the
  ones you think are new.
- Keep `docs/VERIFICATION_LOG.md` honest: what ran, what did not. Keep `docs/FIX_LIST.md` current: every known gap, every decision.
- Stage-specific field names are in `supabase/seeds/01_stage_definitions.sql` (`form_schema.key`). Payload keys must match exactly.
- Web tests, all three: `npx vitest run`; `npx playwright test` (the whole suite, files in name order, against the local
  stack); `npx playwright test -c playwright.prod.config.ts` (the built app: page budget, security policy, and
  `e2e-prod/field_day.spec.ts`, a day without network). Every stage page must pass `expectNoSideScroll` on a phone.
  Do not edit `web/src` while the dev-server suite runs: the hot reload disturbs the test in progress.
- Never run against a hosted project: `tests/00_local_auth_shim.sql`, `tests/run_local.*`, `tests/remote_create_user.mjs`,
  `tests/remote_ledger_check.mjs --tamper-local`, `scripts/collect_release_evidence.sh`.
- **The practice system was emptied on 6 October 2026 and holds no demo data** (`docs/RUNSHEET_fresh_start.md`):
  one admin, and what people make in the app. `scripts/staging_fresh_start.ps1` and everything under
  `scripts/fresh_start/` remove data for good: staging only, never production (they refuse), and never without the
  person typing the words the script asks for. Do not reload seeds 02 to 06 there unless Veda asks. What needs the
  demo people (`remote_rls.mjs --t1`, the acceptance suite) runs on the local stack and in CI.
- **The first day from nothing is a test of its own**: `web/e2e-fresh/fresh_start.spec.ts` (after
  `local-stack/fresh_start.sh`; `playwright.fresh.config.ts`). A change to the States, Crops, Clients, Seats, Add
  joiner, Assign or scope screens has to keep it green: it is the only test in which nothing was seeded.
- **The admin oversees and runs nothing** (migration 34, Veda 10 October 2026; `docs/IDENTITY_DESIGN.md` "Who may do
  what" has her set-up order). The admin reads everything, creates states, seats State Managers and the HR Admin, runs
  the ledger check, and adds joiners only while the HR Admin seat is empty. No stage act, farmer act, client, crop,
  scope or roster change: the database refuses them and no screen offers them. There is **no override** (Veda: "it
  will create confusion"): do not add one without her say-so. A screen decides a button from `web/src/lib/rights.ts`
  (`oversees`, `managesScope`, `holdsClientAccount`, `supervisesState`, `isStateManager`), never from
  `role === 'admin'` or `isManager(role)`. A farmer is verified twice: Client Manager, then the State Manager of the
  farmer's state, two different people.
- **The admin has two jobs** (migration 35, Veda 10 October 2026, decision G16): he creates states and appoints the
  HR Admin; everything else he watches (the overview is a dashboard: `app.platform_overview`, `app.admin_trends`).
  The **HR Admin seats State Managers** (`app.may_assign`, `seatsStateManagers` / `givesAssignments` in `rights.ts`).
  The admin sees people as numbers only: never an HR file, ID or bank digits, documents, notes or exits. Nobody makes
  an admin in the app (break-glass only). The admin's menu is grouped by headings (`ROLE_MENUS` in `shell/Layout.tsx`);
  another role adopts them by adding its own list. Charts follow `web/src/pages/admin/charts.tsx`: one hue for
  amounts, status colours only for pass and fail with words, a table under every chart.
- **Hiring at scale goes through openings and the server's lists** (migration 38, Veda 11 October 2026,
  `docs/IDENTITY_DESIGN.md` "Onboarding at scale"). A list that can grow past a few hundred (Joiners, People & access,
  the Audit log, a roster's pool) is paged and filtered by the database (`joiners_page`, `people_page`, `audit_page`):
  do not load it whole into the browser. Many people at once go through the `*_many` functions, which do each person
  through the one-person rule and log each. An invite token is never stored or logged: the database keeps its SHA-256,
  the link carries it after the `#`. Mark as joined is refused while a statutory step is open ("received on paper" is
  HR's flagged way out); do not add another. Load tests run on the local stack only (`tests/load_onboarding.mjs`).
- **HR works by state and holds no seat** (migration 39, Veda 12 October 2026). An HR resource reaches only the people
  based in her states (`app.hr_covers`, `app.hr_may_manage_person`); a new HR function or read rule about a person asks
  it, and `tests/33_hr_geography.sql` needs its case. Nobody in HR is given an assignment of any kind; HR for a state
  is `hr_states`. The base location (`employee_org.base_state_id`, `base_district`) grants nothing and is written only
  through its functions. A field added to the Add joiner form must also be passed by `create-user` (`JOINER_FIELDS`):
  the opening was dropped there for a day (FIX_LIST line 41).
- **The State Manager owns one state and runs nothing in it** (migration 41, Veda 13 October 2026). `app.sm_limited()`
  is a State Manager who is not also a Client Manager, HR or the admin; `app.sm_sees(person)` is who he may see and
  seat. Scopes are written by the Client Manager (`app.runs_client`), a new one in its client's home state; farmers are
  created by the Client Manager and Procurement / Village Batch (`app.farmer_create`); a farmer's own state decides its
  staff (`app.farmer_staff`), and step 2 always follows step 1. Crops have a state, set once. A new rule about a person,
  a scope, a farmer or a crop that a State Manager may reach needs its case in `tests/35_state_manager.sql`.
- **A crop is used only when it is ready** (migration 42, Veda 13 October 2026). Ready = `app.crop_missing` is empty
  (unit, yield per acre, a quality limit, a recommended chain); a scope is activated only with a ready, not retired
  crop. A quality limit has a `type` (number when absent, grade, yes/no) and is judged by `app.judge_typed` in both the
  preview and the save: a new type goes there, in `quality_params_problems`, in the lab widget and in the record. A
  farmer's good farming practice is written only by `app.save_farmer_gap`; Procurement asks it in `check_new_footprint`
  (a required practice open refuses the lot). A crop's code is unique within its state. `tests/36_crop_registry.sql`
  needs a case for any new crop rule.
- **No state farmer ID without GI land** (migration 43, Veda 13 October 2026; the duplicate model of migration 44).
  `farmers_z2_register_rules` asks it at the State Manager's first verification. The yield check (GI land × yield per
  acre, per season) is in `procurement_crop_checks` and `app.above_yield`: a warning, never a refusal or a flag. The
  register (`app.farmer_register`) shows a phone only as its last four digits: no screen that lists farmers across
  clients shows a whole number. `tests/37_farmer_register.sql` needs a case for any new register rule.
- **A stage only for who the roster may hold; activation only when every stage has a person; two farmer IDs**
  (migration 44, Veda 14 October 2026). `app.stage_refusal` is the one rule for a stage (an operational person based in
  the scope's state, or the client's own Client Manager), asked by `assign`, `set_stages`, `slots_assignment`,
  `ready_to_assign` and `app.roster_pool`; `scopes_a3_staffed` refuses an activation while `app.coverage_gaps` is not
  empty. The State Manager reads scopes (`app.watches_state`, `app.watches_scope`) and manages none (`manages_place` is
  the client's account only). The client farmer ID is given at step 1, the state farmer ID (`state_farmers`,
  `F-<state>-00001`) at step 2 by `farmers_z3_state_id`: the same phone already a state farmer's is linked
  (`app.state_link`) or given a new ID with a reason. A change to a farmer with an ID goes through `app.change_farmer`
  with a reason (`app.change_reason`); every step and change is a ledger block (`farmers_ledger`). People marked
  `test_data` are left out of every list. `tests/38_rules_and_farmer_ids.sql` needs a case for any new rule here.
- **Every change to the tables that matter is in the change log; live data is corrected only through the door**
  (migration 45, Veda 14 October 2026). A new table people or lots depend on gets a `zz_change_log` trigger (and the count
  in `tests/39_production_safeguards.sql` and the smoke row). A migration that changes rows declares itself first:
  `select set_config('app.change_path', 'migration NN', true);`. A correction of live data, on any system, runs inside
  `app.open_correction(id)` … `app.close_correction()` (or `app.owner_correction(reason)` while two-person approval is
  off), never as a bare update; a practice-data function refuses production. The change log keeps no values.
- **A need for people is a requirement, and HR publishes it** (migration 46, Veda 14 October 2026). Nobody types an
  opening for a scope's empty stages: they become requirement lines when the People step is saved, and HR publishes them
  (`app.decide_lines`), which makes the opening and links it back. A new place that changes who holds a stage, a scope's
  chain or a client's Client Manager keeps the `zy_requirements` triggers' effect (the lines follow), and a new line
  status or act writes its Audit line through `app.line_status`. One person may hold two stages in a row (Veda's
  decision): never bring back the "verified by its own creator" refusal; it is marked (ledger `same_person`, the public
  page's approved words, `app.same_person_counts`), not refused.
- **A verified farmer is corrected by its Client Manager; Procurement proposes** (migration 47, Veda 14 October 2026).
  Good farming practice is the exception: Procurement and Village Batch answer it and it counts at once. Any other
  detail from them goes through `app.propose_farmer_change` and the CM's `app.decide_farmer_proposal`, which changes the
  farmer only through `app.change_farmer` (so every rule on a farmer's change still applies). A release script's summary
  takes a number's maximum (`max(seq)`), never `seq::text … order by seq` (that sorts the text).
- **A record goes back to its sender, never sideways** (migration 48, Veda 15 October 2026; the operator-stages brief,
  release 1). The next stage (or a manager) returns a pending record with `app.return_footprint` (10 characters); while
  the return is open nobody verifies it; the sender's correction or withdrawal closes it (trigger, `return` blocks).
  Verify through `app.verify_record(id, reason, condition)`: a manager who does not hold the receiving stage must give a
  reason; a condition is an open flag of kind `condition` and blocks the seal. A manager who records at a stage he does
  not hold sends `manager_reason` (10 characters). Every record has `happened_on` ("On", the day it happened) besides
  its two times. Record numbers carry the scope's `short_code` (never change one that a number carries); never parse
  a number for its parts. A screen shows a database refusal through `plainText` (`lib/plainErrors.ts`): a new
  `raise exception` that people can meet needs its rule there and `err.*` in both dictionaries. Every time shown is
  `dateTime`/`date` (India's time) and every exported time `istStamp`.
- **People tick only what they see; quantities and lineage are the server's** (migration 49, Veda 15 October 2026). A
  stage's handoff list for people is `stage_definitions.physical_checks` (also in seed 01); everything the data answers
  is `app.system_checks`, shown, never ticked. `app.verify_record(…, p_checked)` needs every physical check. A screen
  shows what is LEFT on a lot (`app.incoming_lots`, `available_qty`), never what it once held. Every record's sources
  and the kilograms taken are `footprint_links` (written by the save; never by hand): farmers' shares
  (`app.lot_farmers`, "documented proportions") and GI (`app.lot_gi_status`: GI only when every source's farmer is in
  the crop's `gi_districts`) come from it. No threshold is a number in code: a crop's are `crops.thresholds`.
- **Packs, release and proof are the server's** (migration 50, Veda 15 October 2026). A batch code is given by the save
  (`app.next_batch_code`, trigger `footprints_a1_batch_code`): never ask for one or write one. Packs are made by the save
  from the packets (`app.make_packs`); a correction voids the earlier packs and makes new ones; never insert or delete a
  pack. Labels are printed through `app.print_labels` (a reprint needs a reason) and a pack is voided only through
  `app.void_pack`. A release's status is `release_events`, changed only by `app.set_release_status` (a recall is final);
  the QR step shows `app.release_preview` and seals only after the person confirms it. The public pages
  (`public_lot_journey`, `app.public_pack`) never carry a farmer's name or photo. A document that a rule asks for
  carries `attachments.label` (`register_labelled_attachment`): the lab report before a lab record is verified (where
  `scopes.qc_report_required`), the client's acceptance before an export override, the proof of delivery before an
  export delivery (`app.confirm_delivery`). A form field with `required_when` is required where the scope's setting of
  that name is on (`withScopeRules`). A new ledger event needs its line in `tests/remote_ledger_audit.sql` in the same
  release (migration 48's `return` blocks went without one for a release).
- **What a stage picks from is a list; a farm has its GPS** (migration 51, Veda 15 October 2026). Places (`places`:
  a district row, its blocks, their villages; compared by `app.norm_place`, letters only) are added only through
  `app.add_place` (a district by the State Manager); a state with no list accepts what is typed (`app.district_listed`).
  The Client Manager's lists (`collection_points`, `mills`, `packing_units`, `buyers`, `pack_skus`) are written by
  `app.runs_client`, the labs by the state's State Manager; a row is retired (`active = false`), never deleted, never
  moved to another client (`client_list_guard`). A market profile is saved through `app.save_market_profile` (an active
  one gets a new draft version) and activated only through `app.activate_market_profile`, with params from
  `quality_param_library` and a source file (`reference_files`, bucket `reference`, `app.register_reference_file`); a
  new crop gets its Domestic and Export profiles from its limits (trigger), and a crop with documents or profiles of
  its own is in use. A GI crop is `crops.gi_crop` (generated from the GI number): no GI area without it. A farmer
  registered by a person needs `farm_lat`/`farm_lng` and a listed district before step 1 (`farmers_z4_location`;
  `location_required` is false for those of before: asked, never refused). The screens mirror these in `lib/setup.ts`
  (`tests/setup_lists.test.ts` holds them to the migration's text); `tests/45_setup_lists.sql` needs a case for any new
  rule here. The ledger banner reads `app.ledger_status` (blocks added since the last full check); the roster pool's
  `elsewhere` is a person's work on other scopes, shown, never refused.
- **A farm-gate lot says where, how and for how much; a batch is one place** (migration 52, Veda 15 October 2026). Price
  and payment never enter `footprints.payload` or the ledger: `footprints_a00_payment` takes them out before the save
  and `footprints_z6_payment` keeps them in `lot_payments` (read through `app.reads_lot_payment`: the recorder, the
  client's Client Manager, the admin; paid later only through `app.save_lot_payment`). A payment reference is a
  transaction ID (`^[A-Za-z0-9/-]{4,40}$`), never an account number. Where / GPS / who delivered are required where
  `scopes.procurement_details_required` (the default), price and payment only where `scopes.record_price`; the form
  marks such fields `required_when` / `shown_when` (`withScopeRules`). A Collection Batch (`village_batch`) is the lots of
  one collection point; its villages, farmers, moisture and loss are worked out from the lots (`computed`), never typed.
  Any rule added to Procurement or the Collection Batch in `app.reconcile` goes into `engine/offlinePreview.ts` (same
  words, `tests/procurement_batch.test.ts`) and into `plainErrors.ts`; `tests/46_procurement_batch.sql` needs a case.
  The journey forward is `app.lot_forward` (whole-scope readers only). A GPS pair typed in one box is split on paste or
  when the box is left, never while typing.
- **The admin marks one person as joined: the HR Admin seat holder** (migration 36). Everyone else is HR's to mark, also
  while the seat is vacant. Nobody is activated by being given the seat, and nobody has HR access while Joining.
- **On production, an agent changes nothing directly** (Veda, 14 Oct 2026; the table in `docs/PRODUCTION_SAFEGUARDS.md`,
  "How Claude and other helpers work once production is live"). No production data, keys, seats or settings; releases
  are scripts Veda runs; a settings change only after her yes for that one step; her browser is read, not clicked, unless
  she approves the step. What is allowed on staging (practice data) is not allowed on production.
- Secrets stay in git-ignored `.env.*` files. Never on a command line, in chat, in a log or in a test's output.

## Stack (PRD §10)

Supabase (Postgres 17 hosted, 16 or 17 locally; RLS, PL/pgSQL triggers, Auth, Storage, Edge Functions) · React + TypeScript +
Vite PWA with a service worker · one design system (the prototype's greens; tokens in `web/src/styles.css`) · static hosting (Cloudflare by default).
