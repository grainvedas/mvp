# Verification log — Phase 0

Environment: PostgreSQL 16.13 (Ubuntu), pgcrypto, uuid-ossp. Local scratch instance, NOT a Supabase project.
Run: `tests/run_local.sh` on 2026-09-27.

## Result

    migrate  supabase/migrations/20260927000100_extensions_enums.sql
    migrate  supabase/migrations/20260927000200_core_tables.sql
    migrate  supabase/migrations/20260927000300_footprints_ledger.sql
    migrate  supabase/migrations/20260927000400_integrity_triggers.sql
    migrate  supabase/migrations/20260927000500_rls_policies.sql
    migrate  supabase/migrations/20260927000600_views_rpc.sql
    seed     supabase/seeds/01_stage_definitions.sql
    seed     supabase/seeds/02_kalanamak_demo.sql
    test     tests/01_helpers.sql
    test     tests/02_integrity_rules.sql
    test     tests/03_ledger.sql
    test     tests/04_rls.sql
    test     tests/05_chains.sql
    ALL TESTS PASSED

125 assertions passed, 0 failed. Full list:

- rule 5: chain without QC rejected
- rule 5: same stage type twice rejected
- rule 5: chain must start with procurement or lot_inward
- rule 5: chain must end with QR
- rule 5: popping not allowed for Kalanamak
- rule 5: active chain is frozen (D1)
- seeded minimal scope is active
- rule 1: non-first stage without predecessor rejected
- rule 2: stage outside the scope chain rejected
- procurement: net 126 - 3x2 = 120 stamped as qty_in/qty_out
- procurement: client_id stamped from scope
- procurement: footprint code format PRSDM-KNM-KH26-P-0001
- procurement: moisture avg computed
- procurement: created pending
- procurement: gross < bags x tare rejected
- isMyStage: QC technician cannot create at procurement
- rule 2: predecessor must be verified first
- verify: procurement op is not the receiving stage
- verify: QR sealer is not the stage after procurement
- verify: QC technician (next stage) verifies procurement
- rule 4: verified payload immutable
- rule 4: verified qty immutable
- rule 4: scope_id immutable
- rule 4: footprints never deleted
- rule 7: QC qty_out = 147.5 - 0.5 sample
- qc: domestic PASS derived (11.9 <= 13)
- qc: export PASS derived (11.9 <= 12)
- availability: procurement lot fully consumed by QC
- auto-close: source with < 2 kg left is closed
- availability: closed lot cannot be drawn again
- qc: derived verdict immutable
- qc override: operator cannot authorise
- availability: qty_in 200 > 178 available rejected
- qc: 12.4% moisture → domestic PASS, export FAIL
- milling: input ≠ rice + bran + loss rejected
- milling: qty_out = rice 130
- milling: yield 67% < 70% flagged as warning, not rejected
- drying: expected out 100×80/88 = 90.91
- drying: 9 kg drop explained by moisture → no loss flag
- drying: 85 kg out (< 90.9 expected) flags grain loss
- popping: 50% weight yield at 85% pop rate → no flag
- popping: 75% pop rate flagged
- blanching: output > input allowed (water uptake 8 kg)
- rule 3: non-blanching stage cannot exceed input / needs its fields
- sorting: clean output derived = 100 - 6 - 1 = 93
- grading: A+B+C = 90 forwarded; A+B+C+reject+loss = 93 balances
- grading: A+B+C+reject+loss ≠ input rejected
- cold storage: output = retrieved, spoilage 3
- packing: Σ packets 99 + wastage 1 = 100
- packing: batch_code mandatory
- shipment: transit loss carried forward (X − Y = 97.5)
- ledger: create writes one block
- ledger: event = create
- ledger: verification writes a verify block
- ledger: the 3 seeded scope activations were ledgered
- ledger: verify_ledger() finds no bad block on an untouched chain
- ledger: every block's prev_hash equals the previous block's hash
- ledger: UPDATE refused (superuser included)
- ledger: DELETE refused (superuser included)
- ledger: altered payload detected at seq 20
- operator: procurement op sees both procurement lots
- operator: procurement op cannot see QC records (stage ahead)
- farmers: procurement op sees farmers
- users: operator sees only self
- trigger+RLS: procurement op cannot insert a QC record
- ledger: operator can read blocks of own scopes
- thumb rule: QC op sees scope-01 procurement (stage behind) but not scope-02 procurement (grading is behind QC there)
- thumb rule: QC op sees own QC record
- farmers: QC technician does not see the farmers module
- incoming: p1 fully consumed → not incoming
- scope isolation: sorting op sees exactly the scope-02 procurement lot
- incoming: sorting op sees p2 as incoming (pending, yellow)
- scope isolation: sorting op sees one scope
- isMyStage: sorting op cannot create at grading
- tenant isolation: other client's operator sees 0 footprints
- tenant isolation: other client's operator sees 0 farmers
- tenant isolation: other client's operator sees 0 scopes
- tenant isolation: other client's operator sees 0 ledger blocks
- client_view: sees all 3 footprints of the client
- client_view: sees farmers
- client_view: cannot insert a farmer
- client_view: update policy yields no rows
- client_manager: sees the client's 3 scopes
- client_manager: sees the client's 9 users (self, client_view, 7 operators)
- state_manager: sees both UP clients
- anon: no table access
- T1: QR cannot activate on an unverified QC
- T1: QR footprint carries the final 147 kg
- T1 gate: open flag on an ancestor blocks sealing
- T1 gate: QC technician cannot seal
- T1: sealed with QR code GV-149AB08320CA
- T1: QR footprint verified by the seal
- T1: seal block written
- T1: ≥ 5 ledger blocks across the lot
- T1: cannot seal twice
- T1: seal immutable
- T1 public: journey resolves for the QR code
- T1 public: GI tag shown
- T1 public: 3 steps (procurement, qc, qr)
- T1 public: farmer name + village
- T1 public: farmer phone never exposed
- T1 public: export PASS shown
- T1 public: unknown code → null
- T1 public: anon cannot read farmers table
- T2: sorting clean output derived 170
- T2: grade lots cannot exceed the run's A+B+C (165)
- T2: grade lot code carries the grade
- T2: split parent fully allocated to grade lots
- T2 rule 8: split parent hidden from QC incoming
- T2 rule 8: 3 grade lots incoming at QC
- T2 rule 8: QC cannot build on the split parent
- T2: grade-A lot sealed independently
- T2 public: journey = procurement, sorting, grading run, grade lot, qc, qr (6 steps)
- T2: grade B and C still available for other buyers
- T3: 12.1% → export FAIL, domestic PASS
- T3: market verdict resolved through milling to the QC record
- T3: export sale of a domestic-only lot refused
- T3: 30 kg of rice left after a 50 kg domestic allocation
- T3 override: reason mandatory
- T3 override: derived FAIL kept for audit
- T3 override: ledgered
- T3: milling lot auto-closed at 0 kg available
- T3 override: cannot be removed
- T3 public: verify page discloses the override
- gateway: client manager's create is ledgered as supervisory

## Remote checks (live project `zogkrhgzatplarimbmxk`)

| File | What it proves | Run? |
| --- | --- | --- |
| `tests/remote_smoke.sql` | Read-only: schema, triggers, seeds, ledger intact (13 rows since the API row was removed) | 12/13 on 2026-09-27; only `auth.uid mapping` open |
| `tests/remote_api_check.ps1` | `app` schema exposed: `app.public_lot_journey('GV-NONE')` over REST with the public key → HTTP 200, null | OK on 2026-09-27 |
| `tests/remote_t1_rollback.sql` | T1 procure → QC → seal on the live DB, public journey as anon, then undone via a savepoint; fails if anything is left behind | Run 1 (migrations 1–7): FAIL at the seal, as expected. Run 2 (migrations 1–8): **PASSED**. Not yet run locally |

`remote_t1_rollback.sql` is one statement, so it runs the same through `supabase db query --linked -f`, `psql -f` or the
SQL Editor. `run_local.sh` now also runs it against the fresh local build as a self-test; that change is unrun too, so
the next `run_local.sh` output is its first evidence. Expected on the live project before migration 8 is pushed: FAIL
with "another closed lot".

## What this does NOT prove

- Not applied to a Supabase project. `auth.uid()` and the `anon`/`authenticated`/`service_role` roles were emulated by
  `tests/00_local_auth_shim.sql`. PostgREST exposure of the `app` schema is untested (see README step 4).
- Stages exercised only through `app.reconcile()` unit checks, not a full chain: drying, popping, blanching, cleaning,
  cold_storage, packing, shipment, lot_inward, village_batch. T4 (full chain with packing + shipment) has not been run.
- `app.verify_footprint()` RPC path untested; tests verify via direct UPDATE (same trigger, but the RPC's `auth.uid()` lookup is not covered).
- Farmer verification (`farmers_guard`) exercised only by the seed's activation UPDATE.
- No concurrency test on the ledger advisory lock; no performance test.
- No pgTAP: assertions are plain PL/pgSQL. Adding pgTAP later is a drop-in.

## Bugs found and fixed while testing (kept for the record)

1. Footprint codes collided when two scopes shared client+crop+season (different geographies) → counter re-keyed per series.
2. `text[] || 'literal'` parsed the literal as an array → `array_append` everywhere.
3. Drying: 91 kg out vs 90.91 expected flagged as "exceeds expectation" → 1% weighing-noise allowance added.
4. QR footprint verification refused (no stage after the gate) → isGate stage is verified by its own sealer.
5. `users_read` policy recursed into `app_users` → helper functions (`app.my_client_id`, `app.my_state_ids`) made security definer.
6. `incoming_records` returned nothing for the service role (no JWT) → visibility filter skipped when `auth.uid()` is null.
7. Test-data errors caught by the rules (not bugs): 2-stage chain, packing without batch_code, QC op expected to see a
   scope where grading (not procurement) is the stage behind QC.

## 2026-09-27 — remote push (Supabase project zogkrhgzatplarimbmxk)

- `supabase db push`: migrations 1–7 applied; seeds applied via `supabase db query`; `tests/remote_smoke.sql` 12/14 OK
  (non-OK: `auth.uid mapping` and `api exposes app schema`, both pending manual steps).
- Supabase installs pgcrypto in schema `extensions`, so security-definer functions with `search_path = public` could not
  find `digest()`. Antigravity IDE added migration 7 to fix this — correct — but re-typed `seal_lot` with logic changes
  that break every chain at the seal (a fully consumed, auto-closed source was treated as "part of another closed lot").
  Caught by `tests/05_chains.sql` T1 as soon as migration 7 was run locally. Migration 8 restores the tested body.
- Local suite with migrations 1–8: ALL TESTS PASSED, 125 assertions.
- Lesson recorded in AGENTS.md: change a function's search_path with `ALTER FUNCTION … SET search_path`, never by re-pasting its body.

## 2026-09-27 — remote T1 check, run 1 (live project has migrations 1–7, not 8)

`supabase_migrations.schema_migrations` on the live project: 20260927000100 … 20260927000700 (7 rows).

    supabase db query --linked -f tests/remote_t1_rollback.sql
    ERROR:  P0001: ASSERTION FAILED: seal gate: open flag on an ancestor blocks sealing — refused for a different reason:
            gate: predecessor procurement PRSDM-KNM-KH26-P-0001 is already part of another closed lot
    CONTEXT:  PL/pgSQL function pg_temp_11.remote_t1_check() line 56 at PERFORM

- The check caught the migration 7 seal bug on the live project. The first `seal_lot` call (the open-flag gate test) hit
  the wrong "another closed lot" rule before reaching the flag check.
- Steps 1–4 passed on the live project (procurement net 147.5, client_id stamp, own-record verify refused, QC verdicts,
  auto-close, QR activation): the function only reaches line 56 after those assertions. The Management API does not
  return NOTICE lines, so the individual `ok` lines were not seen.
- Nothing left behind, checked with a read-only query afterwards: footprints 0, qc_verdicts 0, qr_seals 0, flags 0,
  footprint_counters 0, ledger 3 blocks (the seeded scope activations), `app.verify_ledger()` 0 problems.
- Next: push migration 8, re-run; expected result `REMOTE T1 PASSED`.

## 2026-09-27 — migration 8 pushed; remote T1 check, run 2

    supabase db push --linked --dry-run   → Would push these migrations: • 20260927000800_seal_lot_restore.sql
    supabase db push --linked --yes       → Applying migration 20260927000800_seal_lot_restore.sql... Finished supabase db push.
    supabase db query --linked -f tests/remote_t1_rollback.sql
      result: REMOTE T1 PASSED — sealed GV-A32B4B216355, public journey checked, rolled back, nothing left behind

- Read-only query afterwards: footprints 0, qc_verdicts 0, qr_seals 0, flags 0, footprint_counters 0, ledger 3 blocks,
  `app.verify_ledger()` 0 problems, `supabase_migrations.schema_migrations` 8 rows.
- `tests/remote_smoke.sql`: 12/14 OK. Not OK: `auth.uid mapping` (12 users still on placeholder auth_uid, workstream D)
  and `api exposes app schema` (unset, workstream C).
- Run with the pre-rotation access token and DB password, by the owner's decision; rotation (workstream A) still open.
- `tests/run_local.sh` with the self-test line has still not been run (no Postgres on the Windows machine).

## 2026-09-27 — app schema exposed (workstream C)

- The dashboard change had not saved: REST returned `HTTP 406 PGRST106 "Only the following schemas are exposed: public,
  graphql_public"`, and the Management API read `db_schema = public,graphql_public`.
- Set through the Management API (owner approved): `PATCH /v1/projects/zogkrhgzatplarimbmxk/postgrest
  {"db_schema":"public,graphql_public,app"}`. Read back: `db_schema = public,graphql_public,app`,
  `db_extra_search_path = public, extensions`, `max_rows = 1000` (the last two unchanged).
- `tests/remote_api_check.ps1`: `OK    app schema exposed: public_lot_journey('GV-NONE') over REST with the publishable
  key -> HTTP 200, null` (first attempt).
- The smoke row `api exposes app schema` was removed: it read `current_setting('pgrst.db_schemas')`, which hosted Supabase
  never sets in the database (`pg_db_role_setting` holds no `pgrst.*` entry), so it could not read OK. The REST check
  replaces it. `tests/remote_smoke.sql` afterwards: 12/13 OK; only `auth.uid mapping` (workstream D) remains.

## 2026-09-27 — workstream D: migrations 9 and 10, tested locally and trialled on live (NOT pushed)

- `20260927000900_login_linking.sql`: normalised unique phone/email on `app_users`; trigger on `auth.users` links a
  login to the one active, unlinked row matching its CONFIRMED phone or email.
- `20260927001000_app_users_guard.sql`: closes a hole in migration 5 (`users_update` had no WITH CHECK: a Client Manager
  could make themselves admin or set any `auth_uid`). Signed-in callers never write `auth_uid`, never change their own
  role/client/states/active flag, and edit only users ranked below them.
- `tests/06_logins.sql` (19 checks) and an `auth.users` table in `tests/00_local_auth_shim.sql`.

Local run on the Windows machine: portable PostgreSQL 17.6 (EDB binaries, matches the live project's 17.6), scratch
cluster on port 5433, `tests/run_local.ps1` (Windows twin of `run_local.sh`, same steps):

    migrate  supabase/migrations/20260927000100_extensions_enums.sql … 20260927001000_app_users_guard.sql (10 files)
    seed     supabase/seeds/01_stage_definitions.sql, 02_kalanamak_demo.sql
    test     tests/01_helpers.sql … tests/06_logins.sql
    psql:…/06_logins.sql:67: WARNING:  login 10000000-0000-4000-8000-000000000005 matches 2 app users by phone/email; not linked
    test     tests/remote_t1_rollback.sql (local self-test)
    ALL TESTS PASSED

- ok checks per file: 02 = 51, 03 = 9, 04 = 26, 05 = 39 (the original 125, unchanged), 06 = 19, remote T1 self-test = 25.
  The WARNING is the expected output of the "phone and email match two users" check.
- Negative control: the same build WITHOUT migration 10, then `tests/06_logins.sql` →
  `ERROR: ASSERTION FAILED: guard: client manager cannot make themselves admin — statement was accepted` (exit 3).
  The hole exists before migration 10 and the test catches it.
- `run_local.sh` (bash) itself is still unrun on this machine; `run_local.ps1` runs the same files in the same order.

Rolled-back trial on the live project (migrations 9 + 10 executed inside a savepoint, then undone; one request via
`supabase db query --linked`):

    TRIAL PASSED: run as postgres | migrations 9 + 10 apply on hosted Supabase (trigger on auth.users created) |
    guard: client manager cannot self-promote or write auth_uid (as authenticated, live RLS) |
    link: unconfirmed email ignored; confirming links; current_role() = admin |
    link: confirmed phone 910000000005 links +910000000005; unconfirmed phone ignored |
    undone: no trigger, index, login or app_users change left

- Not yet exercised through the real Auth API (logins are written to `auth.users` directly in both runs).

## 2026-09-27 — migrations 9 and 10 pushed

    supabase db push --linked --dry-run   → Would push: 20260927000900_login_linking.sql, 20260927001000_app_users_guard.sql
    supabase db push --linked --yes       → Applying migration 20260927000900_login_linking.sql...
                                            Applying migration 20260927001000_app_users_guard.sql... Finished supabase db push.

- Live afterwards: 10 rows in `supabase_migrations.schema_migrations`; triggers `auth.users.grainveda_link_login` and
  `app_users.app_users_guard`; indexes `app_users_phone_key`, `app_users_email_key`.
- `tests/remote_smoke.sql`: 12/13 OK (`auth.uid mapping`: 12 users still on placeholder auth_uid — no logins created yet).
- `tests/remote_t1_rollback.sql`: `REMOTE T1 PASSED — sealed GV-817DDD867810, public journey checked, rolled back, nothing left behind`.
- `tests/remote_api_check.ps1`: `OK    app schema exposed … HTTP 200, null`.

## 2026-09-27 — workstream H: untested server paths closed (migrations 11–13), local only, NOT pushed

- `20260927001100_actor_is_caller.sql`: for signed-in callers the actor must be the caller: footprint `verified_by`,
  the sealer in `seal_lot` (p_sealer honoured only without a JWT), the QC override `authoriser`, the farmer verifier;
  farmer `created_by` is stamped; `farmer_code` only by verification. Guard triggers; `seal_lot` re-created from
  migration 8 with only its `me` line changed.
- `20260927001200_identifier_counters.sql`: Farmer ID from a per-client counter (was count + 1); padding that never
  truncates, for Farmer IDs and footprint codes.
- `20260927001300_ledger_hash_time_zone.sql`: `ledger_append` and `verify_ledger` run with timezone UTC, datestyle ISO.
- Tests: `tests/07_server_paths.sql` (24 checks) and `tests/concurrency/` (4 parallel psql sessions, 6 checks), wired
  into `run_local.sh` and `run_local.ps1`.

Local run (PostgreSQL 17.6, `tests/run_local.ps1`; the portable build first lacked time-zone data because `tar` had
extracted only part of the EDB zip, repaired before this run):

    migrate  … 20260927001300_ledger_hash_time_zone.sql (13 files); seed 01, 02
    test     tests/01_helpers.sql … tests/07_server_paths.sql
    psql:…/06_logins.sql:67: WARNING:  login … matches 2 app users by phone/email; not linked   (expected)
    test     tests/remote_t1_rollback.sql (local self-test)
    test     tests/concurrency (4 parallel sessions)
    ALL TESTS PASSED

- ok checks: 02 = 51, 03 = 9, 04 = 26, 05 = 39, 06 = 19, 07 = 24 → suite 168 (was 125); T1 self-test 25; concurrency 6.

Negative control — the same probes on a build with migrations 1–10 only (each probe undone after it ran):

    ACCEPTED  1 creator verifies own lot by naming the QC technician
    ACCEPTED  2 login with no app user seals by naming the QR operator
    ACCEPTED  3 client manager records the admin as override authoriser
    ACCEPTED  4 operator activates a farmer by naming the State Manager
    ACCEPTED  5 operator rewrites an issued Farmer ID
    6 the 10,000th procurement lot gets code PRSDM-KNM-KH26-P-1000; the 10,001st fails:
      duplicate key value violates unique constraint "footprints_footprint_code_key"
    7 verify_ledger() from UTC after an IST write: hash mismatch at seq 1
    concurrency: worker 1 and worker 4 exit 3 — duplicate key value violates unique constraint "farmers_farmer_code_key";
      farmers verified: 10 of 20; ledger chain still valid (the advisory lock already serialised appends)

All seven are refused or correct with migrations 11–13 (the 24 checks in `tests/07_server_paths.sql`).

## 2026-09-27 — migrations 11–13: live trial, then pushed

Rolled-back trial on the live project (the three migrations executed inside a savepoint, then undone). The same script
first ran on a local copy built like live (migrations 1–10 + seeds, UTC sessions):

    TRIAL PASSED: migrations 11-13 apply on hosted Supabase | existing live ledger (3 blocks) verifies with UTC/ISO pinned |
    Farmer ID counter picked up at 5 for Prasaadam | signed in: creator cannot verify by naming QC; operator cannot
    activate a farmer by naming the SM | signed in without an app user: cannot seal by naming the QR operator |
    State Manager verification issues PRSDM-F-0006 | a ledger block written in Asia/Kolkata verifies from UTC |
    undone: no objects or rows left

- Caveat found on the way: pinning UTC makes any block that was written from a non-UTC session unverifiable. A local
  copy seeded from an Asia/Calcutta session failed (`hash mismatch at seq 1`); the live ledger passed because every live
  block came from UTC sessions. Do not apply migration 13 to a database whose ledger was written in another time zone.

    supabase db push --linked --dry-run   → Would push 20260927001100, 001200, 001300
    supabase db push --linked --yes       → Applying migration 20260927001100_actor_is_caller.sql...
                                            Applying migration 20260927001200_identifier_counters.sql...
                                            Applying migration 20260927001300_ledger_hash_time_zone.sql... Finished.

- Live afterwards: 13 migrations; triggers `farmers_actor_guard`, `footprints_actor_guard`, `qc_verdicts_actor_guard`;
  `farmer_id_counters` with RLS on, Prasaadam at 5; `app.verify_ledger` settings `TimeZone=UTC; DateStyle=ISO`;
  `app.verify_ledger()` 0 problems.
- `tests/remote_smoke.sql` first read 11/13: `footprint triggers (5) -> GOT 6`, because migration 11 adds
  `footprints_actor_guard`. The row now checks the six triggers by name; re-run: 12/13 OK (only `auth.uid mapping`).
- `tests/remote_t1_rollback.sql`: `REMOTE T1 PASSED — sealed GV-354EC8D11C05, …, nothing left behind`.
- `tests/remote_api_check.ps1`: `OK … HTTP 200, null`.

## 2026-10-01 — Claude: independent re-run, security fix (migration 14), Phase 0 close-out tooling

Environment: Claude's sandbox, PostgreSQL 16.13, UTC sessions. Plus a local stack built from the real servers:
Supabase Auth v2.197.0 + PostgREST v12.2.3 + the 14 migrations, behind one URL (`local-stack/up.sh`).

- Independent re-run of Antigravity's migrations 9–13 and tests before any change: `ALL TESTS PASSED`, checks per file
  02 = 51, 03 = 9, 04 = 26, 05 = 39, 06 = 19, 07 = 24 (168), T1 self-test 25, concurrency 6 — identical to the log above.
- **Security finding:** with `app` exposed to PostgREST, every function in it was executable by anon (default EXECUTE to
  PUBLIC). Proven on the local stack: anonymous `POST /rest/v1/rpc/ledger_append` wrote block 15 `seal`
  `{"forged": "by anonymous caller"}`. 60 app functions were executable by anon.
- Fix: `20261001000100_api_surface.sql` revokes EXECUTE from public/anon/authenticated on all `app` functions, closes
  default privileges, grants back only the named API and RLS helpers. `tests/08_api_surface.sql` (7 checks) enforces the
  allowlist. Negative control without migration 14: the allowlist check FAILS and lists ~100 role/function pairs.
- `tests/remote_ledger_audit.sql`: every block must have a counterpart; proven to flag a forged block (rolled back).
- Seeds 03 (manager emails, plus-addresses of grainvedas@gmail.com) and 04 (Lot Inward scope + operator 313).
  Tests 03, 04 and `remote_smoke.sql` now expect 4 scopes / 10 client users.
- `run_local.sh` after all changes: `ALL TESTS PASSED`, 206 ok lines (168 + 7 + 25 + 6).
- Local stack, real logins: `scripts/create_demo_logins.mjs` → 13/13 created and linked by migration 9;
  `tests/remote_rls.mjs --t1` → **85 passed, 0 failed** (sign-in, current_role, scope/farmer visibility per role,
  refused writes, closed API, T1 as 305 → 306 → 307 with seal and anonymous journey, ledger intact);
  `tests/remote_smoke.sql` → 14/14 OK; ledger audit → NO ORPHAN BLOCKS.
- NOT run: anything against the live project (Antigravity, see docs/RUNSHEET_2026-10-01_security_and_phase0.md);
  the new CI `stack` job (first run is its proof).

## 2026-10-01 — Phase 1 (Claude): backend B1–B7, corrections, web app — built and tested locally, NOT pushed

SQL suite (`tests/run_local.sh`, PostgreSQL 16, UTC): `ALL TESTS PASSED`, 266 ok lines
(files 02–11 + T1 self-test 25 + concurrency 6). New: 09 Phase 1 backend (49), 10 corrections (6), 11 scope read-back (5).

- Migration 15 (`validation_preview_chain_limits`): the save trigger and `app.preview_reconcile` now run ONE function,
  `app.check_new_footprint`, extracted mechanically (script) from migration 4's trigger body. Test: for procurement and
  milling the saved qty_in, qty_out, computed and warnings equal the preview; the preview writes no record, ledger block
  or footprint code. `app.check_chain` returns every chain problem. Crop limits are copied into the scope at activation
  and frozen; QC judges against the copy (a crop edit mid-season leaves active scopes' verdicts unchanged).
- Postgres cannot revoke the default PUBLIC execute per schema, so migration 14's default-privileges line is a no-op;
  every later migration closes its own functions explicitly. `tests/08_api_surface.sql` caught migration 15's first
  draft leaving 8 functions open — the backstop works.
- Migration 16 (`phase1_api`): `stage_form`, `my_context`, `footprint_detail`, farmer submit / send-back / verify,
  `import_farmers` (all rows or none, row-numbered errors, +91 normalisation, duplicate phones), unique phone per client,
  evidence bucket + storage policies (tested locally against a Storage stand-in in the shim), `register_attachment`.
- Migration 17 (`corrections`): gap found — any user who could SEE a pending record could rewrite its figures (e.g. the
  next stage before verifying). Now only its creator or a manager; `app.preview_correction`.
- Migration 18 (`scope_read_by_client`): BUG found by the Playwright wizard test — a Client Manager could not create a
  draft scope from the app (INSERT … RETURNING failed the id-based SELECT policy). Negative control: test 11 fails
  without migration 18 with `new row violates row-level security policy for table "scopes"`.
- Edge Function `create-user`: `tests/remote_create_user.mjs` on the local stack 11/11 (401 unsigned, 201 manager →
  operator with slot + sign-in with temp password, 409 duplicate with no leftover row, 403 CM → State Manager,
  403 other client, 403 operator, 201 SM → CM, 400 bad phone).
- Local stack after all migrations: `remote_rls.mjs --t1` 85/85, ledger audit NO ORPHAN BLOCKS (127 blocks).
- Web app: `tsc` clean, `vite build` OK, `vitest` 24/24 (all 16 stage definitions render through the generic engine;
  payload building; chain assembly; Excel parsing; error wording).
- Playwright (Chromium, Pixel 7 viewport) against the local stack, two consecutive runs, 7/7 each:
  T1 from the UI (305 → 306 → 307, seal, public page) · Lot Inward → QC export FAIL → Client Manager override → seal ·
  scope wizard (draft → create a person for a stage → activate) · farmer create/submit → State Manager verify → Farmer ID ·
  Excel import (bad file names rows 3 and 4 and imports nothing; clean file imports 2) · role rules in the UI ·
  correct a pending record, flag it, manager resolves. Two UI bugs found and fixed on the way (wizard returned to the
  chain step after the first save; client picker could override the user's choice while loading).
- NOT run: anything on the live project; photo upload (no Storage in the local stack); SMS/OTP; the web app on a real
  phone; the CI jobs (first run is their proof).

## 2026-10-01 — Phase 2 (local stack, rebuilt from zero)

- Migration 19 (`grade_split`) and 20 (`village_batch`) + seed 05. SQL suite `ALL TESTS PASSED`, 287 checks (files 00–12
  + concurrency). Test 12: T4 procurement → shipment → seal; T2 grading split into A/B/C, QC on A, seal; Village Batch
  of two farmer lots, seal refused while a source has an open flag. Negative control: test 12 fails without migration 20
  (flag on the second batch source ignored at seal).
- Local stack: `remote_rls.mjs --t1` 95/95, `remote_create_user.mjs` 11/11, ledger audit NO ORPHAN BLOCKS (272 blocks),
  smoke 12/14 on the stack only because the e2e runs add scopes and farmers (GOT 9 scopes, 8 farmers); 14/14 expected live.
- Web: `tsc` clean, `vite build` OK (public 148 KB gzip, signed-in chunk 81 KB gzip), `vitest` 28/28.
- Playwright (Pixel 7), all specs, two consecutive runs, 10/10 each: T1 · 6 Phase 1 flows · T4 (7 people, two buyers,
  12 labels with batch code, public page) · T2 (grade split) · Village Batch (public page names both farmers).
- BUG found by e2e and fixed: on a phone, a long tab label ("New Village Batch (aggregate farmer lots) record") and the
  farmer picker buttons could not wrap, so the page became wider than the screen and Chrome zoomed it out; taps near
  the bottom edge then missed (the 4th hand-off tick box). Buttons now wrap; `expectNoSideScroll` guards every stage page.
- Test fix: the Lot Inward spec still expected the old public-page wording; updated to the current text.
- NOT run: anything on the live project; photos into real Storage; the web app on a real phone; CI.

## 2026-10-01 — Phase 3 "field-ready" (local stack, rebuilt from zero)

- Migration 21 (`phase3_ops`). SQL suite `ALL TESTS PASSED`, 307 checks (files 00–13 + concurrency). Test 13:
  ledger check records a clean chain; only the service role can run it; nobody can write a fake result; operators do not
  see results; a payload_hash altered with the guard bypassed (superuser, session_replication_role) is caught at that
  block. Offline: 10 saves with client_ref get consecutive codes in capture order; a retried client_ref is refused
  (`footprints_client_ref_key`), one lot remains. Trace: operator and other-client user refused; Client View gets both
  farmer lots, the batch and QC; farmers, ledger blocks, QC verdict and recorder named. Performance on a 500-lot scope:
  incoming list 154 ms, pipeline summary 2 ms, season read under RLS 143 ms (budget 1 s).
- pg_cron is not available in the sandbox Postgres: the migration's schedule branch logged its notice and skipped.
  The scheduled branch is NOT tested here; the smoke row that checks it was tested against a stand-in `cron.job` table
  (OK when the job exists, NOT SCHEDULED when not).
- Edge Function `ledger-check` on the stack: 401 without / with a wrong token, 200 on an intact chain, 200 with the
  evidence re-hash (0 files: no Storage in the local stack, so the re-hash itself is NOT exercised), 500 naming the
  block after a real tamper through psql, 200 again after restoring it (`tests/remote_ledger_check.mjs --tamper-local`).
- Stack: `remote_rls.mjs --t1` PASSED, `remote_create_user.mjs` PASSED, ledger audit NO ORPHAN BLOCKS (455 blocks).
- Web: `tsc` clean; `vitest` 38/38 (new: Hindi has every English key with the same placeholders, and every stage name,
  field, option and hand-off check of all 16 stages; stage-specific meanings kept; English untouched; offline maths equal
  the server's rules for Procurement and Lot Inward incl. refusals; CSV quoting and formula-injection guard).
- Playwright (Pixel 7), all specs, two consecutive runs, 14/14 each. New: airplane mode — 10 farm-gate lots captured
  offline, synced by themselves when the network returned, consecutive codes in capture order, each saved quantity equal
  to the one reviewed offline · a milling save made offline and refused at sync stays "needs attention" with the
  database's reason, reopens with the typed values, is fixed and saved · dashboards for Client Manager and Client View
  (stage dots, season CSV with rows, sealed lot → journey with 7 steps → CSV with the QR code and no farmer phones) ·
  Hindi on operator screens and back to English.
- Production build (`playwright.prod.config.ts`), two runs, 2/2 each: public verify page on throttled 3G (150 ms RTT,
  1.6 Mbps) visible in ~1.65 s with 160 KB transferred (budgets 3 s, 200 KB) · after one online sign-in the app opens
  with the network off (service worker), records a lot offline and syncs it.
- BUGS found by these tests and fixed: the offline badge made the top bar wider than a phone screen (page zoomed out,
  taps missed) — the bar now wraps; the badge said "0 to send" next to "1 need attention".
- NOT run: anything on the live project; pg_cron scheduling; evidence re-hash against real Storage; the app on real
  low-end phones (device lab); Lighthouse; penetration test; Hindi review by operators.

## 2026-10-02 — Phase 4 "go-live kit" (local stack, rebuilt from zero; nothing on a hosted project)

Final run: `PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres scripts/collect_release_evidence.sh --fresh`, exit 0, every
step green; result files in `release-evidence/` (git-ignored). Postgres 16.13, Supabase Auth v2.197.0, PostgREST
v12.2.3, Chromium with a Pixel 7 profile.

- Migrations 22–27. SQL suite `ALL TESTS PASSED`, 510 assertions (files 01–18, the T1 self-test, the production build
  on a second scratch database, concurrency). The same 510 under PowerShell (`tests/run_local.ps1`).
- Stack with real logins: `remote_rls.mjs --t1` 121/121 · `remote_create_user.mjs` 29/29 · `ledger-check` function 6/6
  incl. a block altered through psql and restored · ledger audit `NO FINDINGS (705 blocks, 227 records, 37 seals,
  6 evidence files checked)` · smoke 20/21 (the 21st is `pg_cron`, which the sandbox Postgres does not have).
- Web: `tsc` clean · `vitest` 83/83 · Playwright whole suite 25/25, two consecutive runs · built app behind a host-like
  server 14/14 (public page on throttled 3G: 1681 ms, 169 KB; budgets 3 s, 200 KB) · acceptance rehearsal T1–T5
  against the built app 5/5, two consecutive runs (public page 1664 and 1671 ms, 169 KB) · Lighthouse accessibility 100.
- Backup and restore drill `RESTORE DRILL PASSED`: schema from the 27 migrations, data loaded in 1.9 s; identical to the
  source in 20 tables, 1139 rows, 109 functions, 36 policies, 40 triggers; 705 ledger blocks verify with the source's
  last hash; newest sealed lot's public page byte-identical; one block altered by hand in the copy is caught; 6/6
  evidence files re-hashed; 22 logins in `auth.dump`.
- Release gate (`release-evidence/GATE.md`), 10 rows: PASS 3 (edge checks, Hindi, ledger audit), REHEARSAL 4 (T1–T5,
  RLS, page speed + Lighthouse, restore drill: green, but on the local stack), PENDING 3 (Veda's own run, acceptance
  run by a non-builder, a day without network on a real phone). Gate CLOSED, as it must be before staging.

Faults found in this phase, each reproduced before it was fixed (the list with the user-facing wording is in
`docs/FIX_LIST.md`):

- **Offline work ended after one hour** (fix-list 1, 2, 7). Reproduced on the build as it was: with no network and the
  sign-in token past its hour, a cold start showed "Sign in" (test failed at that line). A probe of that build, with a
  save waiting on the phone, the hour over and the network back, showed the request leaving with the PUBLIC key and
  the save marked "needs attention · Permission denied for table footprints". A second probe: Sign out in that state
  did nothing for 38 s while the offline copy was already erased (0 entries). Cause: supabase-js answers "no session"
  when it cannot renew, after up to 25 s of retries, and falls back to the public key. Fix: the app reads the login
  kept on the phone itself (`web/src/lib/keptLogin.ts`), a separate data client gets its token from `accessToken()`,
  and a token that cannot be renewed is "no connection".
- **A save whose answer was lost was stored twice** (fix-list 3). Reproduced: the request was let through and its answer
  dropped; the old build ended with 2 records of that weight. Fix: one save id from the first tap (`insertOnce`).
- **An unsent photo was dropped; a dead link left a form closed and a save hanging** (fix-list 4, 5): reproduced on
  the old build (no "kept on the phone" after the photo upload failed; the form not open after 40 s on a link that
  never answers). Now: the photo waits with the save; the form opens from the phone's copy after 9.0 s; the save is
  stopped after 31 s and kept; it is sent once when the link is back.
- **The offline copy survived a lost phone and a login ended by the server** (fix-list 6): on the old build 6 cache
  entries (the farmer list among them) remained after deactivation and after a forced sign-out. Now 0.
- Negative control for all of the above: the eight tests of `e2e-prod/field_day.spec.ts` run against a build of the
  code as it was before these fixes: 8/8 FAIL, each at the line that states the fault. Against the fixed build: 8/8 pass
  (cold start with no network and a run-out token: 0.5 s; after a dead link, sent 48 s after the link was back).
- **A regression of my own, caught by an existing test**: the first version of the save id was kept per form, so ten
  lots captured offline in a row overwrote each other in the outbox (1 left of 10). The Phase 3 airplane-mode test
  failed ("1 to send", expected 10). Fixed (the id is released when the save is handed to the outbox); 10 of 10 again,
  consecutive codes.
- **Hindi screens showed English** on the record page, in status words and in the app's own messages (fix-list 17).
  Found by a scan of the operator screens for text outside the dictionary; the scan is now a unit test, and it fails
  on a planted line (negative control: three planted strings, three findings).
- Earlier in this phase, each with its failing test first: a half-filled form wiped when the phone came back from
  another app (supabase-js announces SIGNED_IN on every refocus) · a lot left closed and unsealable after a refused
  seal · a split grading run without its grade lots · the whole scope's ledger readable by any operator (a Procurement
  operator read 11 blocks, among them the buyer and the sale) · eleven direct-write openings (migration 22 header) ·
  "Correct this record" opening the waiting list · contrast below the mark (Lighthouse 96, now 100).
- Checks that were given a negative control: the ledger audit (5 findings on forged and altered rows); the restore
  drill (fails, naming the table and the block, when the manifest disagrees; the backup names an altered evidence
  file); evidence restore (one file removed, put back byte-identical; the monitor reports a missing and an altered
  file); the auth-settings check (three combinations of settings against a stand-in server: sign-up off with
  auto-confirm on → PASSED with notes; sign-up open → 3 failures; all strict → PASSED).
- Public sign-up OFF, as the live projects will have it (`STACK_DISABLE_SIGNUP=1 local-stack/up.sh`): demo logins made,
  `remote_create_user.mjs` 28/28 (the 29th check is "a sign-up gets no role", replaced by "sign-up is switched off"),
  `remote_rls.mjs --t1` 121/121, and through the screens: scope wizard creating a person, new person → own password →
  reset → deactivate, T1.
- Tooling faults fixed: `collect_release_evidence.sh` stopped at step 6 on its first complete run (`$!` unset under
  `set -u`); `local-stack/down.sh` did not stop the Auth server (the recorded pid was a wrapper shell's), so rebuilt
  stacks accumulated Auth servers sharing one port. Both fixed and re-run from zero.
- Not a demonstrated fault, and not claimed as one: the service worker's plain copy of the app shell (the old worker
  passed the same test); sign-out with no network while the token is still fresh (it worked before).
- Cosmetic, left as is: in one of four suite runs the list reporter printed the compiled file's line numbers for
  `t3_t5.spec.ts` (12 and 158 instead of 13 and 125). One compiled copy exists in the runner's cache; the same tests ran.

NOT run, and therefore not known:

- Anything on the hosted staging or production project: migrations 22–27, the `reset-password` function, the Auth
  settings, the smoke check, permissions with real logins, the restore drill from a real backup.
- Which earlier run-sheets (Phases 1 to 3) have been completed on the hosted project: step A2 of
  `docs/RUNSHEET_phase4.md` shows it.
- The Cloudflare deploy, and whether Cloudflare applies `_headers` to the single-page fallback (tested here against a
  stand-in server that reads the same file).
- The app on a real phone: low-end Android, a real hour without network, the camera, a real weak signal.
- The CI workflow in `docs/ci/database-tests.yml` with its new steps (result files, artifact upload, 40-minute limit):
  its first run is its proof.
- `pg_cron` scheduling; phone + password sign-in with the hosted Phone provider settings; SMS.
- Restoring `auth.dump` and uploading evidence into a hosted project (the evidence upload was rehearsed against the
  local stand-in only).
- Penetration test, device lab, Hindi read by operators.

## 2026-10-03 — Claude: first working Vercel deploy of the staging app (commit 787b652)

Why five deploys in a row had failed (commits 5d05103 to 25c142c), read from the systems, not guessed:

- Vercel dashboard, deployment of 25c142c: "The `vercel.json` schema validation failed with the following message: should
  NOT have additional property `$comment`", duration "—": the build never started. The project's Root Directory is
  `web`, so the file Vercel reads is `web/vercel.json`. The four commits that changed files at the repo root could not
  change the result.
- GitHub Actions on the same commits, `npm ci` in `web/`: 5ffc656 "can only install with an existing
  package-lock.json"; b1f9b6f onwards "Cannot find module @rollup/rollup-linux-x64-gnu". The root `package.json` named
  `web` as a workspace, so npm used the root lockfile, written on Windows.

What ran:

- This machine (Windows, Node 20.18), before the fix: `npx vitest run tests/phase4.test.tsx -t "hosting config"
  --environment node` → 2 failed (`["$comment"]`; `expected [ 'web' ] to be undefined`). After: 2 passed.
  `--environment node` because jsdom 30 does not load on Node 20: the full unit suite did NOT run on this machine.
- Fresh clone plus the patch, from `web/` (a rehearsal: Windows cannot show the Linux fault): `npm ci` 317 packages from
  `web/package-lock.json`; `npx tsc -b --noEmit` exit 0; `npx vite build --mode staging` built.
- GitHub Actions on 787b652 (Linux, Node 22, run 37116623173): `run_local.sh` success · web install, typecheck,
  component tests success (failed on the four commits before) · Playwright end-to-end success · production build suite
  success · **"smoke + ledger audit" FAILED**: the workflow looks for `NO ORPHAN BLOCKS`, the audit prints
  `NO FINDINGS (288 blocks, 83 records, 12 seals, 4 evidence files checked)`. The run is red for a reason in the
  workflow file (FIX_LIST open item 3).
- Vercel: 787b652 Ready in 14 s, Production. https://mvp-beta-one.vercel.app: `/`, `/work/x/y`, `/sw.js`,
  `/asset-manifest.json`, `/manifest.webmanifest` → 200; the deep address carries the Content-Security-Policy,
  `nosniff`, `X-Frame-Options: DENY`, HSTS and the referrer policy; the bundle names one Supabase project
  (`zogkrhgzatplarimbmxk`); the sign-in screen renders in Chrome on `/` and `/work/x/y` with no console errors.

NOT run, and what the deployed app cannot do yet (read-only queries on the staging project, same day):

- **Nobody can sign in.** Supabase Auth on staging holds 0 logins; the 15 demo people are in `app_users` with the seed
  placeholder. `scripts/create_demo_logins.mjs` has not been run against it (there is no `.env.demo-logins` on this
  machine either).
- Staging has 21 migrations (last `20261001000800`); 22 to 27 are not applied. Edge Functions deployed: `create-user`
  v1, `ledger-check` v1; no `reset-password`. The deployed app is the Phase 4 build: part A of
  `docs/RUNSHEET_phase4.md` is still to do (FIX_LIST open item 4).
- A sign-in, any stage, a save, a phone.

## 2026-10-03 — Claude: demo journey kept on staging (T1, scope 401), and what the live app shows of it

Asked for by Veda. Not through the screens: operators cannot sign in (Phone provider off) and Claude does not sign in
to a hosted service. The three steps of T1 (`tests/remote_rls.mjs`, at the Phase 3 level staging is on) were carried
out in one transaction as the three demo operators, with the caller set per step, so every trigger and policy applied.
Script: `Claude outputs/demo-run-2026-10-03/demo_journey.sql`.

- Trial first, rolled back (private SQLSTATE): the full result came back in the error text; staging unchanged
  afterwards (0 records, 6 blocks, 0 seals).
- Then kept, 17:09 IST: `PRSDM-KNM-KH26-P-0001` 147.5 kg (Sita Devi, Itwa) → `PRSDM-KNM-KH26-QC-0001` 147 kg, verdict
  domestic pass / export pass → `PRSDM-KNM-KH26-QR-0001` 147 kg, sealed `GV-D3C38791036F`. Ledger blocks 63 to 72;
  `app.verify_ledger()` 0 problems (16 blocks). All three records carry one timestamp (one transaction).
- Refused during the run, as they must be: the procurement operator verifying the own record ("verification is by
  the receiving stage"); the QC technician sealing ("only the assigned QR operator … may seal").
- On the deployed app (https://mvp-beta-one.vercel.app), in Veda's signed-in admin session and without login for the
  public page: `/verify/GV-D3C38791036F` shows the journey and both verdicts, no farmer phone; Home, the scope
  dashboard (pipeline 1/1/1, the sealed lot), the QC record, **Journey & export** and the label sheet all open.
- **Fails on the deployed app:** the dashboard's "Activity, last 14 days" box: "Could not find the function
  app.scope_activity(p_days, p_scope) in the schema cache". The Phase 4 app against the Phase 3 database (FIX_LIST
  open item 4).

NOT done: any stage through the screens; a photo; any chain longer than three stages; anything as an operator login.

## 2026-10-04 — Comparison with the prototype; migration 28 (public page data)

Asked by Veda: the built interface is not the prototype's. What was done, on the local stack only:

- The prototype (`GrainVeda_Platform_v1.html`) was read in full into an inventory of its screens, forms and messages, and
  driven in a headless browser with entries made through its own forms: one lot through seven stages to an active QR and
  the verify page, plus side runs. 874 pictures (laptop 1366 × 768, phone 390 × 844). Sign-in was done by setting the
  prototype's own session, never by typing a password.
- The built system was inventoried from `web/src` and driven on the local stack through the same journey. 571 pictures.
- Result: `docs/INTERFACE_GAP.md`. 103 typed fields of the prototype's stage forms are not asked for here (counted by
  label from the prototype's source: procurement 9761–9959, QC 13002–13270, commercial 16567–17002, shipment
  17422–17727, arrival check 10714–10783, processing configurations 13561–13689); the prototype has 17 stage types
  (`ALL_STAGES`, line 13524), this system 16 (no Warehouse Inward); about 15 screens have no counterpart.
- Faults found in the built system: 11 open (FIX_LIST open items 6 to 16) and one fixed (below). None was caught by the suites.

Fixed, database only:

- **Fixed fault 21.** `app.public_lot_journey` (callable without a login) returned each record's `computed` values; for
  a Commercial record these are `{market, buyer}`. Migration 28 (`20261004000100_public_page_data`) re-creates the
  function from migration 20's body by script with that one key removed (diff: one line).
- Negative control: `tests/19_public_page_data.sql` run on a build WITHOUT migration 28: `ASSERTION FAILED: public data:
  the buyer's name is not sent to an anonymous visitor`, the only failing file. With migration 28: `ALL TESTS PASSED`,
  519 assertions (510 + 9).
- `tests/remote_smoke.sql` has a 22nd row, `public page data`: `OK` on a build with migration 28,
  `OPEN: the buyer's name is sent to anyone who has the QR (push migration 28)` on one without.

NOT run, and therefore not known:

- Migration 28 on the hosted project (run-sheet Phase 4, steps A1–A3 and A8). Staging was at 21 migrations on 3 October
  (entry above), so the leak is open there until 22 to 28 are pushed; it holds demo data only.
- The comparison on a real handset: the phone pictures are a 390 px browser window.
- A line-by-line comparison of dashboards, set-up screens, QR, ledger, flags and queries: started, stopped by a usage
  limit. `docs/INTERFACE_GAP.md` section 14 says how far each area was compared.
- No screen was changed. Open items 6 to 16 are open.

## 2026-10-04 — Decision G8 = A; the faults of the comparison fixed (migration 29, web app); local stack only

Veda's decision the same day: **A, keep the interface as built**; only the faults found in the comparison are fixed.
Of the eleven open items (6 to 16), ten are fixed (`docs/FIX_LIST.md` lines 22 to 31); item 15, an arrival check that
cannot refuse a lot, is not built under A and is limit K19.

What changed:

- Migration 29 `20261004000200_capture_time_verdict_preview`: `footprints.captured_at` with its insert trigger;
  `footprint_snapshot`, `public_lot_journey`, `lot_trace` re-created by script with that one key added;
  `app.judge_readings` (closed) generated by script from `derive_qc_verdict`; `app.preview_verdict` (API).
- Web: 21 files of `web/src` (one new, `engine/values.tsx`); 67 English and 19 Hindi dictionary entries.
- Tests: `tests/20_capture_time.sql`, `tests/21_verdict_preview.sql`; `tests/08` allowlist and `tests/19` key list;
  smoke row 23; `web/tests/faults_oct4.test.tsx` (23 unit tests); `web/e2e/phase5.spec.ts` (11 tests).
- Guides: `docs/OPERATIONS.md` (capture time; how an arrival is refused without a "Reject"), `docs/OPERATOR_GUIDE.md`
  (three sentences, both languages), `docs/RUNSHEET_phase4.md` (the note of 4 October and step B11), `AGENTS.md`.

What ran (local stack: Postgres 16, PostgREST 12.2.3, Supabase Auth 2.197.0; Chromium with a Pixel 7 profile):

- `tests/run_local.sh`: `ALL TESTS PASSED`, 547 assertions (519 + 13 in file 20 + 15 in file 21), counted as in the
  entries above: 546 `NOTICE: ok` lines and the production-seed check the runner prints itself.
- The same on a build WITHOUT migration 29: file 20 fails (`record "x" has no field "captured_at"`), file 21 fails
  (`function app.preview_verdict(uuid, jsonb) does not exist`), nothing else. `tests/remote_smoke.sql`: 23 rows, all
  `OK` but `pg_cron` on the full build; `capture time, verdict preview` → `MISSING (push migration 29)` without it.
- `npx tsc -b --noEmit` clean; `npx vitest run`: 108 passed (5 files).
- `npx playwright test`: **36 passed** (5.8 min). `npx playwright test -c playwright.prod.config.ts`: **14 passed**
  (3.6 min); public page 170 KB transferred of the 200 KB budget, 1,649 ms on throttled 3G.
- **Negative control for the screens**: `e2e/phase5.spec.ts` against the app as it was on 2 October (this tree with the
  20 changed files taken from the computer's folder, served on port 5174; same database, so with migration 29):
  10 failed, 1 passed. The nine fault tests fail at the fault itself:
  1. `Net Kg` where "Net weight" is expected; at the packing review `Batch CodeNaN`.
  2. `Reject Reasons[{"kg":4,"reason":"discoloured grains"},{"kg":2,"reason":"stones"}]`.
  3. 12.5 typed, `125` in the box.
  4. No lab result on the form before saving.
  5. The record's time is the moment it was sent, 10,800,023 ms after the moment it was captured.
  6. "+ new person" drawn three times for a client viewer.
  7. The name hidden; header 239 px for operator and manager; practice strip 43 px, on two lines; the record page
     12 px, the label sheet 135 px and the people of a scope 64 px wider than a 390 px screen.
  8. No language box on the sign-in screen.
  9. "Market verdict domestic Pending · export Pending" on a farm-gate record, before and after the lab; `57 · 443 kg`
     in a stage box; "Manager actions".
  The tenth failure is the test of the app ahead of its database (next point): the old app never sends a capture
  time. The test that passes is the K19 path, which is not a fix and works on the old app too. These runs also show
  the old app working against the database with migration 29: lots, lab records and seals were saved through it.
  A first control run had four of these tests stopping at an element that did not exist yet, which shows that the
  old app lacks the fix but not what it showed instead; their checks were then put in an order, or made soft, so that
  the old app reaches the fault. The figures above are from the second run.
- **The app ahead of its database.** PostgREST's answer to an insert naming a column it does not know was read from
  the local server: `HTTP 400`, `PGRST204`, "Could not find the 'captured_at_x' column of 'footprints' in the schema
  cache". With that answer given for `captured_at`, a save that waited on the phone is sent a second time without the
  capture time, under the same save id, and goes through (`phase5` "An app deployed ahead of its database…"). With
  the fallback switched off the same test fails: the save never reaches "sent".
- After all the runs, `tests/remote_ledger_audit.sql` on the stack: `NO FINDINGS (1464 blocks, 524 records, 66 seals,
  12 evidence files checked)`; 18 of the 524 records carry a capture time earlier than the time the server stored
  them, none carries the clock warning.
- Header on a phone, measured: 121 px (strip 25, top bar 48, menu 48), 14 % of an 844 px screen, at 390, 360 and
  320 px, English and Hindi, operator and manager. Before: 239 px.
- The way to refuse an arrival under limit K19, through the screens (`phase5` "An arrival that is wrong…"): the
  receiver cannot verify without ticking, finds no "Reject", opens the full record, raises a flag; the manager sees
  the flag and withdraws the pending record with a reason; it no longer waits at the receiving stage.

Found on the way, in this work's own changes:

- First complete run after the changes: 31 passed, 2 failed, both caused by the changes. (1) The people of a scope
  were turned from a table into a grid for phones and lost their table rows; "Scope wizard…" finds a stage by its row.
  Fixed in the app: the grid carries table roles. (2) The season export's time column was renamed on purpose
  (`created_at` → `recorded_at`, plus `received_by_server_at` last); the test that pins the header was changed to the
  new header, and the columns are now unit-tested (`faults_oct4` "the season export gives both times").
- **Found by looking at pictures, not by a test:** on a phone the practice strip had become an empty gold bar (a
  width override placed before the rule it overrides: both wordings hidden). Two existing checks of the strip passed,
  because a text check reads hidden text. Fixed; the phone test now checks the words as shown and fails when the
  faulty order is put back (`Expected: visible, Received: hidden`); `e2e/phase4.spec.ts` checks the shown text too.
- The lab result was drawn twice at review; now once.
- Three of the smaller fixes (the verdict line on a farm-gate record, the stage box caption, the activity column's
  name) had no test; they have one now (point 9 above).

NOT run, and therefore not known:

- **Nothing on the hosted project.** Migrations 22 to 29 are not pushed from here and the deployed app is the build
  of 3 October: every fault above is still there on https://mvp-beta-one.vercel.app until run-sheet Phase 4 part A,
  a push to GitHub `main`, and step B11.
- `tests/run_local.ps1` (the Windows runner): step A1.
- A real phone. The 390, 360 and 320 px figures are a desktop Chromium window; the Hindi figures are from a browser
  whose Devanagari font is not the one on an operator's phone.
- The new app against a real database without migration 29: the refusal was given to the browser in the server's own
  words, not produced by such a database.
- A phone clock that is wrong by less than 31 days is accepted as it is. That is a limit (K20), not a test.
- The acceptance suite (`playwright.acceptance.config.ts`) against a deployed address.
- Nobody but the builder has looked at any of this.

## 2026-10-04 — Decision G8 = B; the prototype's look and frame built (web app, seed 01); local stack only

Veda's decision later the same day, replacing A: **B, the prototype's look on a laptop**, built so that laptop and
phone both work well (who works on which is not decided). `docs/FIX_LIST.md` "The prototype's look and frame", B1 to B7.
This is new build, not fault fixing: nothing here "failed before"; each part has a test that holds it and a negative
control that shows the test can fail.

What changed:

- No migration, no database rule. `supabase/seeds/01_stage_definitions.sql`: a display-only `"section"` on each of the
  64 fields; cold storage's four fields reordered (stored, stored on, retrieved, retrieved on).
- Web: `styles.css` rewritten around the prototype's colour tokens; `shell/Layout.tsx` (top bar, side menu in
  sections), `shell/scope.tsx` (new: the scope in force, the scope a page belongs to, laptop or not),
  `pages/Home.tsx` (first screens by role), `auth/SignIn.tsx`, `engine/StagePage.tsx` and `engine/widgets.tsx` (forms
  in sections), `engine/icons.ts` (new), page titles of the admin pages, `index.html`, manifest and icon colours.
  104 new dictionary entries in each language, 12 reworded (menu and status words).
- Tests: `web/tests/look_b.test.tsx` (new, 21 unit tests), `web/e2e/phase6.spec.ts` (new, 6 tests: 4 at 1366 px,
  1 at 390 px, 1 for the status words). Eight assertions in four existing files changed because a word or a title
  changed on purpose: `e2e/phase3.spec.ts` (Hindi menu word, a title that now carries a pictogram, Hindi status
  words), `e2e/phase5.spec.ts` ("Crop Registry", name over role in the top bar, "Pending verification"),
  `e2e-prod/field_day.spec.ts` and `prod.spec.ts` (the title). No test was removed.
- Guides: the menu and status words in `OPERATIONS.md`, `OPERATOR_GUIDE.md` (both languages), `ACCEPTANCE.md`,
  `RUNSHEET_phase3.md`, `RUNSHEET_phase4.md` (seed 01 again in A5; B11 now has 15 steps, 6 of them on a laptop),
  `AGENTS.md`, `README.md`, `INTERFACE_GAP.md` (a column "Since decision B" in sections 3 and 4).

What ran (local stack: Postgres 16, PostgREST 12.2.3, Supabase Auth 2.197.0; Chromium, Pixel 7 profile unless a
test sets its own size):

- `tests/run_local.sh` after the seed change: `ALL TESTS PASSED`, 547 assertions (unchanged: the database does not
  read `section`). On the stack: 64 of 64 fields carry a section.
- `npx tsc -b --noEmit` clean; `npx vitest run`: **129 passed** (6 files).
- `npx playwright test`: **42 passed** (7.2 min), run twice, the second time after the last change to the frame.
  `npx playwright test -c playwright.prod.config.ts`: **14 passed** (3.7 min), also twice; public page 175 KB transferred of the
  200 KB budget (170 before: the style sheet and the dictionaries grew), 1.7 s on throttled 3G, both runs.
- Acceptance rehearsal (`playwright.acceptance.config.ts` against the built app on the local stack): **5 passed**
  (T1 to T5, 1.3 min).
- Lighthouse 12, accessibility: 100 on the sign-in page and on the public page. A first run gave 96 on sign-in
  (white on the lighter green of the active tab and the button); both were darkened. All text / background pairs of
  the palette were then computed: 4.5:1 or more.
- **Negative controls** for `e2e/phase6.spec.ts`: one thing broken at a time in the app, the one test that should
  notice run, the change put back. All six were caught:
  1. forms in one column on a laptop → "gross weight and bags on one line" fails;
  2. the "Procured" card showing 1 kg too much → `Expected "5,592 kg"`, received `5,593 kg`;
  3. side menu 260 px → `Expected: 220, Received: 260`;
  4. the scope choice not kept on the device → after reload the selector no longer holds the scope;
  5. full stage cards on a phone with five stages → `Expected: 0, Received: 5` lists;
  6. status word "Verified" in place of "Approved" → the chip test fails (and a unit test).
  After putting everything back: `phase6` 6 passed, then the two full runs above.
- Pictures of 21 screens at 1366 × 768 and at 390 × 844 were looked at (sign-in, the three kinds of first screen,
  a form, review, saved, a record, the arrival check, the lab form, scope dashboard, farmers, scopes, people, users,
  flags, crops, health). One sheet of each size is in `Claude outputs\interface-gap-2026-10-04\`.

Found on the way, in this work's own changes:

- **Found by looking at pictures:** with "Overall" chosen, the top bar said "Overall — all scopes" above a form that
  belongs to one scope, and the menu showed no stages there. The frame now shows the scope of the page being worked
  on (a stage page, a scope's dashboard) without changing the person's choice; unit-tested and in `phase6`.
- The action queue sent a manager to the "new record" tab of a stage; it now opens "Records at this stage".
- Initials of "Veda (Admin)" came out as "V(": brackets and signs are no longer counted as letters.
- A count of scope cards was written as a fixed number and failed when another test had added a scope; it is now the
  number the server says the person can read.
- Three title checks used an exact match and failed once titles carried a pictogram; they check the words now.

NOT run, and therefore not known:

- **Nothing on the hosted project.** The deployed app (https://mvp-beta-one.vercel.app) is still the build of
  3 October with the old look. The new one arrives with a push to GitHub `main`; the form sections with step A5.
- A real laptop and a real phone. Both sizes are a desktop Chromium window; "Segoe UI" is not installed on the build
  machine, so the pictures show a fallback font, and the pictograms are the build machine's emoji font.
- Widths between 600 and 900 px (a tablet, a narrow laptop window) get the phone frame; no test or picture at those
  widths beyond the rule itself.
- Browsers other than Chromium.
- The new Hindi words (104 entries) have been read by nobody who speaks Hindi in the field (limit K9).
- The acceptance suite against a deployed address; the Windows runner.
- Nobody but the builder has looked at any of this: run-sheet step B11, steps 10 to 15, is that check.

## 2026-10-04 (evening) — "Login created but not linked; both removed" on staging: cause read from the live project; functions and app changed; local stack only

Reported by Veda from the deployed app (Users & Roles → New user, every attempt). `docs/FIX_LIST.md` open item 17
(staging) and fault 32 (what was wrong in the repository).

Read from the staging project, without signing in and without changing anything (a browser on Veda's computer; the
build machine cannot reach the project):

- Functions: `create-user` answers, with no build header (a build from before today); `reset-password`:
  `404 NOT_FOUND "Requested function was not found"`; `ledger-check`: `500 "function not configured (SUPABASE_URL,
  service key, LEDGER_CHECK_TOKEN)"`. From another origin a request to the missing function fails in the browser
  ("Failed to fetch"): the gateway's 404 carries no CORS headers.
- Database, asked with the app's public key: `app.environment()` → `"staging"`; `preview_verdict`, `scope_activity`,
  `seal_source` exist (permission denied for a visitor, not "not found"). So migrations 23, 24 and 29 are applied.
- The folder on the computer: the Supabase CLI was used after batch 8; two scripts were added by Antigravity
  (`scripts/check_b11.mjs`, `scripts/debug_signin.mjs`: B11 run by a script against the deployed app).

Cause: run-sheet step A6 was not done. `create-user` of 1 October makes the login without
`app_metadata.grainveda_login`; the linking trigger of migration 23 returns at that condition without an error; the
function finds the row unlinked and removes both. None of scope ("Overall"), row-level security or a missing column:
the form sends no scope, the row insert (as the caller) succeeds, and no insert happens at the link step.

Reproduced on the local stack (real Supabase Auth 2.197.0, the version the staging project reported when it was
linked), the Phase 1 handler taken from git (`b83ada8`) against a database with migration 23:

```
Phase 1 function : 500 {"error":"login created but not linked; both removed"}      (no row, no login left behind)
function of 2 Oct: 201
```

What changed (no migration):

- `supabase/functions/*/handler.ts`: one `VERSION` in all three, sent with every answer (`x-grainveda-function`) and
  as the answer to GET. `create-user`: `whyNotLinked()`; every removal checked and tried twice; the login and the row
  are taken back on every way out, also when a request throws.
- `scripts/check_functions.mjs`, `scripts/check_logins.mjs` (new). `local-stack/gateway.mjs` lets a page read the header.
- Web: `lib/api.ts` (`FUNCTIONS_NEEDED`, `functionState`, a failed call to an outdated or missing function becomes
  an error of kind `setup`), `lib/errors.ts`, `shell/ui.tsx`, `pages/admin/Admin.tsx` (the warning), 5 dictionary
  entries in each language.
- Tests: `web/tests/functions.test.ts` (new, 21), `web/e2e/phase7.spec.ts` (new, 1).
- Guides: `FIX_LIST.md` (item 17, fault 32, limit K22), `RUNSHEET_phase4.md` (A6 with its two checks, B4, C6),
  `OPERATIONS.md` ("When New user or Reset password does not work"), `DEPLOY.md` ("Three things are deployed apart"),
  `AGENTS.md`, `README.md`.

What ran (local stack):

- `npx tsc -b --noEmit` clean; `npx vitest run`: **150 passed** (7 files).
- `npx playwright test`: **43 passed** (7.2 min). `npx playwright test -c playwright.prod.config.ts`: **14 passed**
  (3.7 min); public page 176 KB transferred of the 200 KB budget.
- `ENV_FILE=.env.stack node tests/remote_create_user.mjs`: `29 passed, 0 failed`, `CREATE-USER PASSED` (the functions
  through the gateway, real logins).
- **The fault itself, before and after, on the screen** (`e2e/phase7.spec.ts`: the browser is given the answers
  staging gave). The app as delivered in batch 8: no warning; after **Create**: `Login created but not linked; both
  removed`; after **Reset**: `No connection to the server`. The app now: the warning names both functions; after
  **Create**: "The server is not up to date with this app … Nothing is wrong with what you entered … (run-sheet step
  A6) … it answered "login created but not linked; both removed""; after **Reset**: "A part of the server is not
  installed…". With the real functions: no warning, the person is created and linked.
- **The clean-up, before and after** (the handler with a stand-in server; `functions.test.ts` holds the "after"):

  | Case | Function of 2 Oct | Now |
  |---|---|---|
  | The server stops answering after the login is made | throws; **login and row stay** | `502 … both removed`; both DELETEs sent |
  | The login cannot be deleted | says `both removed` | deletes tried twice, then `COULD NOT REMOVE login <id>: remove by hand` |

- A link that fails for another reason, real function and real Auth server (the trigger switched off in the stack's
  database for one call): `500 login created but not linked: the database declined the link: … ; both removed`;
  0 rows and 0 logins left; the reason is in the function's log. With the trigger on again: `201`.
- `scripts/check_functions.mjs`: local stack → three `ok`, `FUNCTIONS DEPLOYED AND CURRENT`; a stand-in that answers
  as staging did → `create-user: … an older build`, `reset-password: not deployed`, `ledger-check: … an older build`,
  exit 1.
- `scripts/check_logins.mjs`: `NO LOGIN WITHOUT A PERSON`; with two logins made the old way → lists both, exit 1;
  `--remove` → removed; again `NO LOGIN WITHOUT A PERSON`.

NOT run, and therefore not known:

- **Nothing was changed on staging and no function was deployed from here.** Until step A6 is done there, New user
  and Reset password keep failing; with the app of batch 8 they keep the old words.
- That the function deployed on staging is byte for byte the Phase 1 build: inferred from its answers (no build
  header, GET refused as "POST only") and from `reset-password` and the `ledger-check` token missing.
- Whether the failed attempts on staging left a login behind: the old function removes it and does not check;
  `node scripts/check_logins.mjs` after A6 answers that.
- Whether the hosted gateway lets a page read `x-grainveda-function` from another origin. The app also reads the
  build from the answer to GET, so it does not depend on it; `check_functions.mjs` is not a browser.
- `tests/run_local.sh`: not run again; no SQL changed.

## 2026-10-05 — "Not allowed for your role or stage" on Clients → Create: migration 30, the Clients form; local stack only

Reported by Veda from the deployed app, signed in as admin. `docs/FIX_LIST.md` open item 18, fault 33.

Cause: `clients_read` is `using (app.can_access_client(id))`, a function that looks the client up by id. The app sends
`insert … returning` (`.insert().select()`); the row being inserted is not visible to that lookup, the returned row
fails the read rule, the insert is refused. Not a matter of the admin's role: the insert rule itself passes.

Reproduced on the local stack through the API, as the demo admin and the demo State Manager:

```
admin, as the app sends it (wants the row back): 403 new row violates row-level security policy for table "clients"
admin, same row, not asking for it back        : 201
state manager, as the app sends it             : 403 (the same)
```

Looked through for the same pattern: the read rule of every table (`pg_policies`). Only scopes (fixed in migration 18)
and clients look their own row up by id. `insert … returning` as admin on states and crops: accepted.

What changed:

- Migration 30 `20261005000100_clients_read_by_row`: one more read rule on clients, from the row's own columns.
- `web/src/pages/admin/Admin.tsx`: the Clients form inserts without asking for the row back (it reads the list again).
- Tests: `tests/22_clients_create_returning.sql` (10 assertions), smoke row 24 `a new client can be read back`,
  `web/e2e/phase7.spec.ts`: "An admin adds a client…" and "A brand-new client, set up from the screens only…".

What ran (local stack):

- `tests/22` on the test database as built before migration 30: fails at its first statement, `new row violates
  row-level security policy for table "clients"`. `tests/run_local.sh` with migration 30: `ALL TESTS PASSED`,
  **557 assertions** (547 + 10).
- The screen test "An admin adds a client…", in the four combinations:

  | App | Database | Result |
  |---|---|---|
  | as delivered in batch 9 | without migration 30 | fails: "Not allowed for your role or stage." on the screen, no row |
  | now | without migration 30 | passes |
  | as delivered in batch 9 | with migration 30 | passes |
  | now | with migration 30 | passes |

- **A brand-new client from nothing, through the screens only** (new test, 23 s): the admin adds the client and its
  manager; the manager chooses an own password, makes a scope, makes a new person at each of three stages, activates;
  registers a farmer; the State Manager verifies (Farmer ID `<new code>-F-0001`); the three new people each choose a
  password, buy, test and seal (`<new code>-KNM-…-P-0001`); the public page shows the farmer and never the phone
  number. It passed at the first run: no further fault on that path in this build.
- `npx tsc -b --noEmit` clean; `npx vitest run`: 150 passed. `npx playwright test`: **45 passed** (7.8 min).
  `npx playwright test -c playwright.prod.config.ts`: **14 passed** (3.7 min); public page 176 KB.
- `tests/remote_smoke.sql` on the stack: 24 rows, 23 `OK` and the expected `NO pg_cron` of the local stack.

NOT run, and therefore not known:

- **Nothing on staging.** The Clients page there fails until the app is pushed to GitHub (or migration 30 is pushed).
  Creating people there still needs step A6 (open item 17).
- The from-nothing test needs the functions of 4 October and ran on the local stack only; on staging the same path
  stops at "create the manager" until A6 is done.
- States and Crops were checked for this fault through SQL as admin, not by adding one from the screen.

Found in the folder before delivering (changed by someone else after batch 9, kept as found): `Admin.tsx` with
rename and delete for states, and a new `Admin-1.tsx` that nothing imports. The Clients change was merged into the
folder's `Admin.tsx`; with the merged file: `tsc` clean, vitest 150 passed, `phase7` 3 passed, and the two other
screen tests that use that file passed. Tried on the stack: renaming a state works; **Delete** answers "Permission
denied for table states" (FIX_LIST open items 19 and 20). The full Playwright suite was run before the merge, not
again after it; the merge adds only the states part.

## 2026-10-05 — operators can sign in with email + password (web app + create-user; local stack only)

Veda's decision, to run a pilot without enabling Supabase's Twilio-gated Phone provider (FIX_LIST item 21, fault 34).
Not a fault fix: a new way to sign in.

What changed (no migration):
- `supabase/functions/create-user/handler.ts`: an operator may be created with an email, a phone, or both; at least
  one is required (was: operator forced to phone). Build raised to 2026-10-05 in all three functions; `FUNCTIONS_NEEDED`
  in `web/src/lib/api.ts` with it.
- `web/src/pages/admin/Admin.tsx` and `web/src/pages/scopes/Scopes.tsx`: an optional Email box for operators; the
  number is now optional too.
- `web/src/auth/SignIn.tsx` + i18n: the sign-in tabs are relabelled **Phone** / **Email** (were "Field operator
  (phone)" / "Manager (email)"); default tab unchanged. `web/e2e/helpers.ts` and `phase7` updated to the new tab name.

What ran (local stack):
- The real function through the gateway: a Client Manager creates an operator with an **email only** → 201; the
  operator signs in by email and `my_context` returns role operator with the procurement slot. An operator with
  **neither** email nor phone → 400 "a phone number or an email is required to sign in".
- The previous build (batch 9) against the same stack: an operator with email only → 400 "operators sign in by phone:
  phone is required" (the "failed before" control).
- `npx tsc -b --noEmit` clean; `npx vitest run` 150 passed; `npx playwright test` **46 passed** (the new
  `phase7` "An operator can be created with an email…" among them); `npx playwright test -c playwright.prod.config.ts`
  14 passed; `ENV_FILE=.env.stack node tests/remote_create_user.mjs` 29 passed (phone operators unaffected).

NOT run / not known:
- Nothing on staging. On the hosted project an email operator works only once the new app and the new functions
  (build 2026-10-05, run-sheet A6) are deployed.
- No real field trial of operators typing an email on a phone; the field-usability trade-off (email vs number) stands.
- The demo seed still makes operators with phone numbers; email operators are exercised only by the new test.


## 2026-10-06 — Identity and authorization layer: migrations 31 to 33, four server functions, the people screens; local stack only

Veda's build prompt of 5 October ("GrainVeda — Identity & Authorization Layer"); her four answers the same day: the
once-a-day code built and switched off; identity numbers as last four plus documents in a private store; the client's
own login kept, outside HR; everything in one delivery. What it is: `docs/IDENTITY_DESIGN.md`. Run-sheet:
`docs/RUNSHEET_phase5.md`. New build, not fault fixes, except the lines marked "fault" below.

What changed:
- **Database.** `20261006000100_identity_schema` (status, system role, assignments, org facts, masked identity details,
  HR files, checklist templates and tasks, audit log, the code's tables; existing people moved to assignments),
  `…000200_union_access` (every access rule from the system role and live assignments; sixteen record functions ask
  about the scope in hand; store `hr-docs`), `…000300_people_lifecycle` (the actions). Seed 06 (HR seats, a joiner, an
  unassigned employee, the same client's scope in Assam).
- **Server functions.** `create-user` rewritten (joiner or client login), `daily-code` new, `_shared/mail.ts`; all four
  build 2026-10-06; `FUNCTIONS_NEEDED` with it. The local stack gained a mail stand-in.
- **Web.** `pages/hr`, `pages/onboarding`, `pages/people`, `pages/system`, `auth/DailyCode.tsx`, `lib/people.ts`;
  `Home.tsx` (which first screen), `Layout.tsx` (menu from what the server says a person may do), `scope.tsx`,
  `Scopes.tsx` (state and season end; the People step picks from the pool), `Admin.tsx` (Users page removed). 421 new
  strings in English and Hindi.
- **Fault 35** (was open item 5): a list reloaded by an action that finished after the person changed tab showed the
  old tab's rows (`lib/useAsync.ts`).
- **Scripts.** `backup.mjs` and `restore_evidence.mjs` carry HR documents; `restore_drill.mjs` empties what the
  migrations filled before loading; `bootstrap_admin.mjs` is also the break-glass tool; `check_functions.mjs` knows
  four functions. `tests/run_local.*` gained the **upgrade path** step; `tests/remote_ledger_audit.sql` knows the
  assignment blocks; `tests/remote_smoke.sql` has 30 rows.

What ran, all on the local stack, the last time from a clean rebuild (`scripts/collect_release_evidence.sh --fresh`,
"EVERY LOCAL CHECK RAN GREEN"):
- `tests/run_local.sh`: **ALL TESTS PASSED, 878 assertions** (557 before this layer). New files: 23 identity layer 53,
  24 union access 67, 25 people lifecycle 100, 26 onboarding 60, 27 sign-in code 28. Production build: 8 checks.
  **Upgrade path: the later migrations apply to a database in use, and all 27 test files pass on it.**
- `npx tsc -b --noEmit` clean. `npx vitest run`: **193 passed** in 9 files (150 before): `identity.test.ts` 29,
  `use_async.test.tsx` 2, `functions.test.ts` 33.
- `npx playwright test`: **53 passed, twice in a row** (46 before). `phase7` (3): a failed server function names the
  server; a client added from the screen; **a brand-new client from nothing** (the admin makes the client, HR adds four
  people, the State Manager gives the client's account, that manager opens a scope and gives the stages, a farmer, the
  first lot sealed and on its public page). `phase8` (8): a joiner from invite to first day on a phone; the new
  screens on a phone and in Hindi; the sign-in code; directory and lenses; assigning; suspend / offboard / re-hire;
  state overview and roster; seats and audit log.
- `npx playwright test -c playwright.prod.config.ts`: **14 passed**. Public page first load **192 KB** of 200 (176
  before: limit K13), 1.8 s on throttled 3G. Lighthouse accessibility 100.
- Acceptance rehearsal T1 to T5 against the built app: 5 passed, twice.
- `tests/remote_rls.mjs --t1`: **192 passed, 0 failed** (121 before). `tests/remote_create_user.mjs`: **84 passed**
  (29 before): joiner, client login, the HR store, resets, offboard, public sign-up, the code with the mail stand-in.
- `tests/remote_ledger_check.mjs --tamper-local` passed. Ledger audit: NO FINDINGS (936 blocks, 279 records, 43 seals).
  Smoke: 29 of 30 rows OK (the thirtieth is `pg_cron`, which a plain Postgres does not have).
- `node scripts/restore_drill.mjs`: RESTORE DRILL PASSED (identical to the source; HR documents re-hashed).
- `scripts/bootstrap_admin.mjs --additional` on the stack: a second admin, linked, system role admin, one audit line.
- **Upgrade rehearsal by hand** on a database at migration 30 with the demo people, a sealed T1 lot, a switched-off
  person, a State Manager of two states and an operator with a login and no stage; then 31 to 33, one transaction
  each. After: everyone's role, client and states as before except the two operators who held no stage (they belong
  to no client now: the pool); switched-off people are suspended; 27 stage rows each tied to an assignment; the ledger
  has the same 71 blocks and verifies; the sealed lot is still on its public page; ledger audit NO FINDINGS.

Controls (a check that cannot fail proves nothing):
- 21 database rules broken one at a time in a copy of the built database; the named test file failed each time. Among
  them: HR may assign; any HR manages anyone; the audit log can be edited; two HR Admins; the last admin removed;
  interns get the statutory task; a full PAN stored; a complete checklist does not make the joiner active; any code
  passes; the code gate left open; a person inserted or changed through the API; the summary hand-edited; an ended
  assignment reopened; the uploader, or anyone, reads HR documents; uploads into another person's folder; access
  counted whatever the holder's status; and the four of 24_union_access (a global "is a manager" check, status
  ignored, the state lens through the client's home state, lapse ignored).
- 3 screen rules broken one at a time (the Assign link drawn for everyone; the whole PAN sent; a joiner's first
  screen is the work): the browser test for each failed.
- `use_async.test.tsx` fails on the hook as it was. The upgrade step fails on migration 31 as it was. The ledger audit
  still reports an assignment block that points at no assignment.

The Windows runner, run under PowerShell 7.4 on Linux (`psql`, `createdb`, `dropdb` behind `.exe` shims) before the
files were written into the folder:
- **Fault 36: it could not fail.** With a test file that prints one row and then fails, the runner as it was printed
  `ALL TESTS PASSED`, exit code 0 (the ERROR line was on the screen, the verdict ignored it). Fixed; with the same
  file the runner now prints `FAILED tests/99_control.sql`, `FAILED upgrade path`, `SOME TESTS FAILED`, exit code 1.
- The runner's new self-test stops the runner as it was ("a failing file was reported as passed").
- Clean run: `ALL TESTS PASSED`, exit 0, 878 checks, the upgrade line present. With migration 31 as it was: `FAILED
  upgrade: …identity_schema.sql does not apply to a database in use`, exit 1.

Found before delivery, by rehearsing the upgrade and by the full run from a clean build (FIX_LIST, "Found by…"):
- **Migration 31 stopped on any database with a stage row in it.** All 870 checks of that moment passed with the
  fault in place. Fixed; the runners now rehearse the upgrade every time.
- The ledger audit reported the new assignment blocks; the restore drill failed on rows the migration itself writes;
  the lost-phone test switched a person off by a route that is closed now; HR documents were missing from the backup.
- Seen once and not again: in the first full run of the evening, T5 stopped at a sign-in of the QC technician (the
  menu did not appear within 10 s). No error in the sign-in server's or the database's log; the trace was overwritten
  by the next run. It passed in the two full runs after it, four repeats on its own and four acceptance runs
  (FIX_LIST open item 23).

NOT run / not known:
- **Nothing on staging or production.** The move of real people, the four functions on the hosted project, and
  Supabase Storage's handling of the `hr-docs` rules (upload allowed, reading back refused for the uploader) are
  checked there by run-sheet part D and steps E5 to E7.
- `tests/run_local.ps1` (the Windows runner) has not run on Windows itself, nor under Windows PowerShell 5.1; it
  was run here under PowerShell 7.4 on Linux (below). Run-sheet step D1 is its first run on the Windows machine.
- No mail was ever sent to a real address: the invite note and the code were tested against the local stand-in.
- No person other than the builder has looked at the screens; no real phone. The Hindi (421 new strings) is unread.
- Three behaviour changes wait for Veda's yes or no (FIX_LIST G10 to G12); a mail sender is undecided (G13).


## 2026-10-06 (later) — Part D as one command: `scripts/staging_phase5.ps1`

Why: Veda asked Claude to run part D itself. Claude cannot type into a terminal on her computer (the desktop bridge
gives terminals and IDEs look-and-click access only, and offers no shell there), and the sandbox cannot reach
Supabase. So the 25 lines became one script with the run-sheet's "Expect" built in, started by one double-click.

What ran, all in the sandbox (PowerShell 7.4 on Linux, the hosted tools replaced by stand-ins that print what the
real ones print; `git` real, against a local remote; D1 against a real scratch PostgreSQL 16):
- The whole run to the end: every step `OK`, D12 `NOT RUN`, a commit of 19 files pushed, exit code 0.
- **44 scenarios with one thing wrong each, every one stopped at the right step** (or went on where it should):
  the linked project answering `production` or nothing (D0, nothing sent); an older or a missing migration in the
  dry run, the dry run failing (D2, nothing sent); the push failing (D3); a function failing to deploy (D4); a broken
  ledger, an old rule, three rows missing, a result `OKAY-ISH` (D5), each of them also in six output layouts (plain
  table, boxed table, JSON on several lines, JSON on one line, CSV, Markdown) because the layout of
  `supabase db query` on the Windows machine is not known here; the HR store public or absent (D6; `-SkipCheck`
  does not let a public store through); an audit finding (D6b); no active admin (D8); the seed refusing, a new demo
  person not linked, the login script failing (D9); a login without a person (D10); a type error, a failing unit
  test (D11, nothing committed); T1 failing (D12). Phone sign-ins not linked (provider off) and the three standing
  smoke rows go on, with a note.
- 11 more: a migration changed by one line, a function file missing, a 34th migration file (D0, nothing sent); the
  same file with Windows line ends (accepted: it is the same file); functions not current (one more ask after 30 s,
  then D4); `.env` not ignored any more (D11b, nothing committed); a file named `my.environment.md` (not a secret:
  goes through); no remote (D11b: committed here, not pushed); nothing to commit; no `node_modules` (`npm ci`).
- D1: a clean run (`ALL TESTS PASSED`, upgrade line, scratch server made on a free port, stopped, folder removed);
  a test file made to fail (stopped at D1, nothing sent); no tools, an old PostgreSQL 13, `initdb` failing (each
  `NOT RUN` with the reason, the run goes on).

NOT run / not known:
- **The script has not run on Windows, nor under Windows PowerShell 5.1, and never against the hosted project.**
  Unproven there: how `cmd` hands the lines over, the layout `supabase db query` prints, starting and stopping the
  scratch PostgreSQL (`Start-Process`), and whether the tools ask for a sign-in. Its first hosted call (D0) only
  reads; a surprise there stops it before anything is sent.

### First run on staging: 6 October 2026, 14:06 (Veda's computer, Windows, Supabase CLI 2.118.0, Node 20.18)

Read from the record `release-evidence/staging-phase5-20261006-140609.log`. This is the first time anything of the
identity layer ran on a hosted project, and the first run of the script on Windows.
- D0 **OK**: the 15 files are the tested ones; 33 migration files; the linked project answered `environment=staging`.
- D1 **NOT RUN**: no PostgreSQL 16 or 17 tools on that computer (FIX_LIST open item 25).
- D2 **OK**: the dry run listed exactly migrations 31, 32, 33.
- D3 **OK**: `Applying migration …identity_schema.sql`, `…union_access.sql`, `…people_lifecycle.sql`, `Finished supabase
  db push.` Migration 31 moved the people and stage rows of a database in use without a refusal: the case the
  upgrade rehearsal was added for.
- D4: the four functions deployed (`Deployed Functions on project …` four times); `check_functions`: `create-user`,
  `reset-password`, `daily-code` `ok … build 2026-10-06`; `ledger-check` on build 2026-10-06 **but "its secrets are
  not set"**. **The script stopped here.** The cause is older than today: the ledger-check token was never set on
  staging (FIX_LIST open item 24). The script was wrong to stop for a standing setting; it now lists it and goes on
  (six more scenarios: only that → goes on; that plus another function not ready, ledger-check on an old build,
  another function stale → stops; rerun with nothing left to push → goes on without pushing; 50 scenarios in all).
- **Not run yet on staging: D5 to D11** (smoke check, HR store, ledger audit, the lists of people, demo people and
  logins, type check and unit tests, commit and push). **State of staging between the two runs: database and
  functions new, app old**: the old Users & Roles page does not work there until the app is pushed.
- Learned about the machine: `supabase db query` prints a boxed table (one of the six layouts tested); functions
  deploy without Docker; no tool asked for a sign-in.

### Second run on staging: 6 October 2026, 14:16 (record `…-141634.log`)

- D0 OK · D1 NOT RUN (as before) · D2 OK: nothing left to push · D3: nothing to do.
- D4 **OK**: four functions deployed again, all `build 2026-10-06`; the ledger-check token listed as standing.
- D5 **OK: 30 rows of 30 `OK`**, among them `ledger chain intact`, `identity layer objects`, `people moved to
  assignments` (`OK 41 live assignments`), `the two seats` (`OK 1 admin, HR Admin seat VACANT`), `manager rules ask
  about the scope`, `people written only by their actions`, `once-a-day sign-in code` (`OK off`), and the three
  standing rows (`demo data`, `auth.uid mapping`, `nightly ledger check`: all `OK`).
- D6 **OK**: `hr-docs`, `public = false`. D6b **OK**: `NO FINDINGS (91 blocks, 6 records, 2 seals, 0 evidence files
  checked)`: the 41 assignments were written without a ledger block the audit cannot place.
- D7: **zero rows**: nobody on staging who can sign in was left without an assignment by the move.
- D8 (before the demo seed): `admin · active · 1`, `operational · active · 7`, `operational · suspended · 19`. The 19
  are the people who were switched off before today (test users of earlier phases); they came across as Suspended.
- D9 **OK**: seed 06 applied; logins: 15 `existing, unchanged`, **316 to 319 `created`**, all 19 `linked yes`, `ALL
  DEMO LOGINS CREATED AND LINKED` (so `create-user`'s rule, a service-made login links to its person, holds on the
  hosted project; the phone logins are linked too). D10 **OK**: `logins: 31 people: 31`, `NO LOGIN WITHOUT A PERSON`.
- D11: `npx tsc -b --noEmit` **passed** (exit 0). `npx vitest run` **could not start**: `ERR_REQUIRE_ESM` nine times,
  "no tests", 9 errors, on Node 20.18.0 (FIX_LIST open item 26). **The script stopped here; the app was not pushed.**
  Not a failing test: no test ran. The script now tells the two apart: when no test can start on an old Node and
  the app's 78 files are the tested ones (`scripts/tested_app_files.txt`), it marks D11 NOT RUN and goes on.
  Checked here: goes on (Node 20.18, and 22.11); stops when Node is new enough, when a test really fails, when
  failures and the loading error come together, when one app file is changed, new or missing, when the list is
  edited or missing; Windows line ends are accepted. 55 scenarios in the table run and 8 beside it.
  The unit tests ran here again on the same 78 files (sizes equal to the folder's): 9 files, 193 passed, Node 22.22.

### Third run on staging: 6 October 2026, 14:26 (record `…-142651.log`): `RESULT: PART D RAN TO THE END`

- D0 OK · D1 NOT RUN · D2, D3: nothing left to push · D4 OK (ledger-check token: standing) · D5 **30 of 30 OK** ·
  D6 OK · D6b **OK: `NO FINDINGS (95 blocks, 6 records, 2 seals, 0 evidence files checked)`** (4 blocks more than
  in the second run: the seats and lenses given by seed 06) · D7 one row: Ravi Kumar, the demo person seed 06 adds without an assignment on purpose (the
  second run, before the seed, showed zero) · D8 OK · D9 OK (all 19 `existing, unchanged`, `linked yes`) · D10 OK (`NO LOGIN WITHOUT A PERSON`).
- D11: type check **passed**; unit tests **NOT RUN** on that computer (Node 20.18.0; the 78 app files compared with
  `scripts/tested_app_files.txt`: all the tested ones).
- D11b **OK**: `git status` showed no `.env` file; 98 files committed (`cd597c7`), `14f20e7..cd597c7 main -> main`
  on `github.com/grainvedas/mvp`; the working tree clean afterwards. D12 NOT RUN (Phone provider off).
- **The deployed app, read from outside at 15:16** (Veda's Chrome, `https://mvp-beta-one.vercel.app`, the page and
  its two script files fetched fresh, nothing signed in): status 200, the sign-in page of the practice system, and
  the scripts carry `2026-10-06` (the function build the app asks for), "Ask HR to reset it", "People & access" and
  "Add joiner": the build of commit `cd597c7` is the one being served. The Vercel dashboard itself was not looked at.

### Where part D stands after the three runs

| Step | On staging | Note |
|---|---|---|
| D1 local tests on Windows | **NOT RUN** | no PostgreSQL on that computer (open item 25) |
| D2, D3 database | done | migrations 31, 32, 33 on a database in use |
| D4 functions | done | four on build 2026-10-06; the ledger-check token was never set (open item 24) |
| D5 to D8 checks | done | 30 of 30; store private; no audit finding; nobody left unassigned by the move; 1 active admin |
| D9, D10 demo people and logins | done | 316 to 319 created and linked; no login without a person |
| D11 type check | done | passed |
| D11 unit tests on that computer | **NOT RUN** | Node 20.18 (open item 26); 193 passed here on the same files |
| D11 push, Vercel | done | `cd597c7`; the served app is that build |
| D12 rules with real logins | **NOT RUN** | needs the Phone provider ON (open item 21) |

NOT run / not known, still:
- **No person has used the new screens on staging**: part E (15 steps, laptop and phone) is the test of that. In
  particular: a joiner added through `create-user` on the hosted project, the first sign-in with a temporary
  password, a document uploaded to `hr-docs` and refused to its uploader on reading back (E5 to E7).
- The rules with real logins on staging (D12), the Windows test runner (D1), the unit tests on Veda's computer.
- Three behaviour changes still wait for Veda's yes or no (FIX_LIST G10 to G12); the mail sender (G13).

### After part D, the same day: the ledger-check token on staging (open item 24)

Done by Veda in the terminal (`docs/RUNSHEET_phase3.md` steps 7 to 10); the last command's output as she pasted it:
`ok no token → 401` · `ok wrong token → 401` · `ok right token → 200, chain intact (95 blocks)` · `ok evidence
re-hash → 200 (0 files checked)` · `4 passed, 0 failed` · `LEDGER CHECK TEST PASSED`. So an outside monitor can now
ask the staging project whether the ledger is intact. Not seen here: the output of the steps before it
(`check_functions.mjs` should now end `FUNCTIONS DEPLOYED AND CURRENT`). Production still needs the same steps.

## 2026-10-06 (evening) — The fresh start of the practice system (decision G14), rehearsed

Veda, after part D: "remove all entries from the system … start fresh as during pilot"; asked what should be there
at the first sign-in: "only you as admin". Built: `scripts/staging_fresh_start.ps1` (+ `staging-fresh-start.cmd`),
`scripts/fresh_start/empty_staging.sql`, `export_rows.mjs`, `clear_logins_and_files.mjs`, `local-stack/fresh_start.sh`,
`web/e2e-fresh/fresh_start.spec.ts`, `docs/RUNSHEET_fresh_start.md`. The smoke check learned what a fresh start is.

What ran, all on the local stack (PowerShell 7.4 on Linux; the Supabase CLI replaced by a stand-in that runs the
same SQL files with `psql` against the stack's database; the Node scripts real, against the stack's own login
service and file store):
- **The script itself, on a stack the whole default suite had just filled** (30 people, 30 logins, 98 records, 14
  sealed lots, 376 ledger blocks, 93 audit lines, 3 stored files): 904 rows copied out; database emptied; 30 logins
  removed, both stores empty; one admin made; read back: 1 person, 1 login, 0 records, 1 ledger block (the admin's
  seat), 0 files on disk; smoke 29 of 30 (the 30th is `pg_cron`, absent locally); audit `NO FINDINGS`; `RESULT: FRESH
  START DONE`. No password in the record.
- **A second run** on the emptied stack: "already empty with one admin: nothing is removed", no question asked,
  the checks repeated.
- **The first day of a pilot, through the screens, on what the script left** (`e2e-fresh`, 1 test, 43 s, three times
  on three emptied stacks): the admin's first sign-in with the temporary password; every list page of an empty
  system without an error; a state; a crop with three limits (0.5 stays 0.5) and its stages; a client; the first HR
  person added by the admin, marked joined, given the HR Admin seat; four people added by the HR Admin; the client's
  account given by the admin; a scope drafted, staffed and activated by that manager; a farmer registered and
  verified (`PRSDM-F-0001`); a lot bought, tested against the limits typed that morning, sealed; its public page.
  **No fault found on this path.** One thing the test had wrong: the seat list shows the person as "name (HR)".
- **The emptying SQL** on copies of a demo database: empties everything but the 16 stage definitions and the 8
  checklist tasks; the link from the checklist to people is put back exactly as it was; the audit log refuses a
  TRUNCATE again afterwards. Controls: a production build (**refused, nothing removed**); the SQL broken in the middle
  (**nothing removed**: 19 people, 64 blocks still there, guard on, link there). First version failed here: Postgres
  refuses to truncate a table that a kept table points at; found on the first try, fixed.
- **26 scenarios with one thing wrong each**, in a simulated project: the wrong words, nothing or "y" typed; the
  project says production or nothing; another project linked; not linked; a migration waiting; a rehearsed file
  changed (all: nothing removed, the emptying never called); the copy fails (nothing removed); the emptying fails,
  leaves rows, leaves the audit guard off, or the stage definitions are gone (logins never touched); logins not
  all removed, the admin not made ("nobody can sign in until this has run to the end; run it again"); two people
  afterwards; a broken smoke row; the smoke check not saying "fresh start"; an audit finding; a bad address; a
  second run; a rerun after a stop in the middle.
- **The smoke check**: on a demo database unchanged (28 `OK` and the two local-only rows, as before); on a production
  build unchanged; emptied with the mark: `OK fresh start (…): 0 crop(s), made in the app` and `OK staging: fresh
  start, no demo data`; emptied without the mark: `NOT SEEDED` twice; with the mark and a demo person back: `NOT
  SEEDED`. First version broke the check on every database without the mark (an empty answer where one row was
  needed); the control found it.
- After the changes: `tests/run_local.sh` `ALL TESTS PASSED`; the default screen suite 53 passed (10.2 min).

NOT run / not known:
- **Nothing of this has run on the hosted project.** There the logins go through Supabase Auth and the files
  through Supabase Storage ("empty bucket", "list"), not the stand-ins; the emptying SQL goes through `supabase db
  query`. The script reads everything back from the database itself (F5) and stops if it is not one admin and
  nothing else. FIX_LIST open item 27.
- The script under Windows PowerShell 5.1: its helpers are the ones `staging_phase5.ps1` ran with on that computer
  three times; the question it asks (`Read-Host`) is new there.
- The copy in `backups\` cannot be loaded back (limit K36).

### The fresh start on staging: 6 October 2026, 16:29 (record `staging-fresh-start-20261006-162930.log`)

Run by Veda (`staging-fresh-start.cmd`, the words typed: `EMPTY STAGING`); one run, `RESULT: FRESH START DONE`.
- F0 **OK**: 7 files the rehearsed ones; linked to `zogkrhgzatplarimbmxk`; `environment=staging`; no migration
  waiting. **Before: 31 people, 31 logins, 4 states, 2 crops, 4 clients, 10 scopes, 25 farmers, 6 records, 2 sealed
  lots, 95 ledger blocks, 27 audit lines.**
- F1 **OK**: `ROWS COPIED: 347 rows of 33 tables` → `backups\fresh-start-20261006T110000Z`.
- F2 **OK**: emptied in one transaction; read back: 0 people, 0 states, crops, clients, scopes, farmers, records,
  seals, ledger blocks, audit lines; 16 stage definitions, 8 checklist tasks; audit guard on. (So `supabase db
  query` ran the whole file, and the owner could set the audit guard aside and put it back.)
- F3 **OK**: `logins removed: 31 left: 0`; `store evidence: empty`; `store hr-docs: empty` (Supabase Auth and
  Storage, the services the rehearsal had only stand-ins for).
- F4 **OK**: `ADMIN CREATED AND LINKED: Veda <grainvedas+admin@gmail.com>`; temporary password in
  `.env.admin-login`, not in the record.
- F5 **OK**: 1 person, 1 login, 1 active admin, nothing else; **smoke 30 of 30 `OK`** (`OK fresh start (2026-10-06
  16:30 IST): 0 crop(s), made in the app`, `OK staging: fresh start, no demo data`, `OK 1 admin, HR Admin seat
  VACANT`, `nightly ledger check OK`); ledger audit `NO FINDINGS (1 blocks, 0 records, 0 seals, 0 evidence files
  checked)`; `NO LOGIN WITHOUT A PERSON`; four functions `ok … build 2026-10-06`, `FUNCTIONS DEPLOYED AND CURRENT`
  (the first time all four: the ledger-check token was set earlier in the day).
- F6 **OK**: 18 files committed, `01dcd0a..a455b25 main -> main`.

NOT run / not known:
- **Nobody has signed in to the emptied system yet.** The first sign-in with the temporary password and the whole
  first day (part 2 of `docs/RUNSHEET_fresh_start.md`) are Veda's; they ran here on the local stack only.
- The app was rebuilt by Vercel from `a455b25` (no app file changed); the deployment was not looked at.

## 2026-10-10 — The admin oversees (decision G15, migration 34): built and rehearsed on the local stack

Brief "GrainVeda MVP — Admin role changes" (Veda, 10 October), override removed, her set-up order. All of it ran on
the local stack (PostgreSQL 16, PostgREST, Supabase Auth) and in a Chromium with a phone profile (Pixel 7) and at
1366 px. **Nothing of it is on staging** (open item 28).

Ran:
- **Database**: `tests/run_local.sh` → `ALL TESTS PASSED`; 964 `ok` lines; `ok upgrade: the later migrations apply to a
  database in use, and all 28 test files pass on it`; production build: the demo seed refuses. The two `LEDGER CHECK
  FAILED` warnings are the test that alters a block on purpose. New `tests/28_admin_oversight.sql`: every act the
  admin lost is refused, every act kept still works, the two farmer steps, the HR seat filled and vacant, the
  overview's figures against the tables, the ledger page and its refusal for anyone else. **Controls**: eight
  deliberately broken versions of the rules (the admin back in `manages_place`, `eff_assignments` counting an admin's
  assignments, `may_assign` giving the admin a client, `farmer_write`, `hr_may_manage`, the clients and crops rules,
  the two-step trigger), each caught by it.
- **Unit tests**: 208 passed (193 before; new `web/tests/admin_oversight.test.ts`: first screen, rights, menu, the
  farmer buttons, the counts that must agree, the role guide in both languages, every ledger event named). Type check
  clean; `npm run build:ci` builds.
- **Screens**: the default suite **57 passed (10.3 min)**, then phases 5, 6 and 9 again after the last style fix
  (21 passed); `playwright.prod.config.ts` 14 passed (the built
  app, field day); the first day from nothing in Veda's order (`e2e-fresh/fresh_start.spec.ts`, rewritten): 1 passed,
  from an emptied stack to a sealed lot, then the admin's overview, a client read-only, and the ledger.
- **Faults found by these runs and fixed before delivery**: the overview was 30 px wider than a phone (the volume
  cards' grid took the width of its widest table); with a single scope in the system the admin could never reach the
  overview (the one scope was always chosen for everyone; a run of the first-day test found it); the event
  "override" was renamed on the record page by the new ledger words (T3 caught it; it says "Override" again).
  Seen only by looking at pictures at 390 and 1366 px: the open number card was dark green text on dark green (the
  app's button colour); it is white like the others now.
- **The counting faults of the brief**, with a control: the scope screen's queue title now shows the same number as
  its card; with the title put back to "number of lines", `phase6` "Scope selector" fails (`Expected "Your action
  queue (9)", Received "(2)"`). Every stage with nobody is named (the list was cut at three); no screen test reaches a
  scope with four open stages, so that part was checked by reading only.
- **Migration 34 on a practice system made the old way**: the stack built at migration 33, emptied
  (`local-stack/fresh_start.sh`), then the first day of 6 October run with the app as it was then (the admin made the
  state, crop and client, gave the client's account, verified the farmer; a lot sealed and its QR issued); then, as
  the admin under the old rules, a second client, a scope for it, and the admin holding every stage of it and one
  stage of the first. Migration 34 applied in one transaction on top: smoke 31 rows (30 `OK`; the 31st is pg_cron,
  absent locally), ledger audit `NO FINDINGS (29 blocks, 3 records, 1 seals, …)`. Read as the admin: overview 2
  clients, 2 active scopes, 1 QR, **3 stages with nobody** (the admin's own stages count as nobody now, as they should);
  ledger 29 blocks; the admin holds no stage. Through the new screens at phone width: the overview, both client cards,
  a scope read-only, the sealed lot's ledger block and record, the farmer, and the public page of the QR.
  (In this rehearsal the lot was sealed by stage people, not by the admin alone as on staging.)
- **`scripts/staging_admin_oversight.ps1`** under PowerShell 7 with stand-ins for `supabase`, `node` and `cmd` and a
  real git remote: the whole run (`RESULT: ADMIN OVERSIGHT ON STAGING`), and a stop at the right step with the right
  words for: wrong words typed, a project that says production, another migration waiting, a failed push, a migration
  still waiting after the push, a broken smoke row, a missing smoke row, an audit finding, a changed app file, a new
  app file, a changed migration, the wrong project, a `.env` file in git; and `-NoGit`, a second run, the nightly
  check not scheduled (listed, does not stop), old server functions (listed, does not stop).
- `scripts/staging_fresh_start.ps1` (smoke list now 31 rows, new file hash) rerun on its stand-in: a full run and a
  second run, both `RESULT: FRESH START DONE`.

NOT run / not known:
- **Nothing on staging.** Migration 34 is not pushed, the app is not pushed (both wait for Veda's say-so: the push
  goes to the main branch). Staging still lets the admin do everything.
- Windows PowerShell 5.1 for the new script (its helpers are those of the two scripts that ran there).
- The new Hindi strings (about 130) have been read by nobody who will use them (K43).
- Veda's own test records on staging were not looked at; the rehearsal above stands in for them.

### First run on staging: 10 October 2026, 09:16 (record `staging-admin-oversight-20261010-091627.log`)

Run by Veda (`staging-admin-oversight.cmd`, the words typed: `ADMIN OVERSIGHT`).
- S0 **OK**: tested files; app 84 files the tested ones; `environment=staging`; exactly migration 34 waiting.
- S1 **OK**: `Applying migration 20261010000100_admin_oversight.sql... Finished`; dry run afterwards: up to date.
- S2 **STOPPED**: smoke **31 of 31 `OK`** (`the admin oversees` OK; `the two seats`: 1 admin, HR Admin seat filled;
  nightly check OK). The ledger audit named five records `RECORD WITHOUT ITS CREATE BLOCK`. Read with
  `release-evidence/q_findings.sql`: Veda's test lot `TEST-KNM-KH26-P/M/QC/PK/QR-0001` (client "Test Client",
  Siddharthnagar), made by Veda as admin 06:09–06:13 IST, each with `supervisory` blocks and a `close`, the last with
  its `seal`. **A fault of the audit (FIX_LIST 37), not of the ledger**: a record made by a manager who does not hold
  the stage is ledgered as `supervisory`. Reproduced on the local stack with a Client Manager's record; fixed; the
  negative control (a record with its block removed) is still found.
- S3 **NOT RUN**: the staging app is still the old build (its admin screens offer acts the database now refuses).

### Second run on staging: 10 October 2026, 09:30 (record `staging-admin-oversight-20261010-093047.log`): `RESULT: ADMIN OVERSIGHT ON STAGING`

- S0 **OK** (nothing waiting: migration 34 already in) · S1 **NOT RUN** (already pushed).
- S2 **OK**: smoke 31 of 31; ledger audit (fixed, FIX_LIST 37) `NO FINDINGS (27 blocks, 5 records, 1 seals, 0 evidence
  files checked)`; `NO LOGIN WITHOUT A PERSON` (3 logins, 3 people); four functions current. In the system: 2 states,
  2 clients, 2 scopes, 2 farmers (both made before migration 34, so without a state: K38), 5 records, 1 seal, 27
  ledger blocks, HR Admin seat filled.
- S3 **OK**: 52 files committed, `a455b25..355bfc7 main -> main`; Vercel builds staging from it.

NOT run / not known: the deployed app has not been looked at (the sandbox cannot reach it); the run-sheet's
"Afterwards" steps are Veda's.


## 2026-10-10 (afternoon) — The admin's two jobs (decision G16, migration 35): built and rehearsed on the local stack

Brief "GrainVeda MVP — Admin role, follow-up" and Veda's answers the same day: no override (items 1a and 1c dropped);
the admin creates states and appoints the HR Admin, and watches the rest; the HR Admin seats State Managers; people
as numbers for the admin. **Nothing of it is on staging** (open item 29): it waits for Veda's say-so.

Ran:
- **Database**: `tests/run_local.sh` → `ALL TESTS PASSED`; **1021** `ok` lines (964 before); `ok upgrade: the later
  migrations apply to a database in use, and all 29 test files pass on it`; production build: the demo seed refuses.
  New `tests/29_admin_two_jobs.sql`: joiners and system roles (the admin adds only the HR person, only while the seat
  is empty; nobody makes an admin in the app), the State Manager seat (the HR Admin's; refused for the admin, an HR
  resource and a State Manager), HR acts and passwords (the admin: the HR Admin's and another admin's password, nothing
  else; HR files closed to him once the seat is filled, open while it is empty), the overview's people numbers and the
  weekly figures against the tables, the public page (`independent` true for a lot checked by different people;
  false for a lot with a manager's supervisory record and for one where one person recorded two steps in a row, as
  on staging's GV-9DB7C336D205), the pipeline in chain order (procurement first, QC before milling and packing, the
  seal last), "Report a problem". **Controls**: five broken versions of the rules (`acts_as_hr`, `hr_may_manage`,
  `may_assign`, the seat check in `add_joiner`, the journey's `independent`), each caught. Tests 06, 08, 19, 25 and 28
  adapted to the new rules.
- **Unit tests**: 220 passed (new `web/tests/admin_two_jobs.test.ts`: the menu by heading, who is offered Assign, Help
  by role, the password words, the public page's sentence, the dashboard's arithmetic, the Pipeline page's order and
  no Records column). Type check clean; `npm run build:ci` builds.
- **Screens**: default suite, 59 tests: **57 passed (11.7 min)**; the 2 others failed on the test's own expectations
  (the menu word "Crop Registry" is "Crops" in the admin's new menu; a heading that is hidden at phone width was
  checked as visible) and passed after the specs were corrected (`phase6` and `phase9` again: 12 passed). Built app
  (`playwright.prod.config.ts`): 14 passed, the public page still under 200 KB on throttled 3G. First day from nothing
  (`e2e-fresh/fresh_start.spec.ts`, step 4 now the HR Admin's): 1 passed, to a sealed lot, the dashboard counting it
  and the Pipeline page in chain order.
- **Looked at** (pictures at 390 and 1366 px, English and Hindi): overview, Pipeline, Help. No sideways scroll.
- **`scripts/staging_admin_two_jobs.ps1`** under PowerShell 7 with stand-ins for `supabase`, `node`, `cmd` and a real
  git remote: the whole run (`RESULT: ADMIN TWO JOBS ON STAGING`), a second run (nothing pushed twice), `-NoGit`, and
  a stop at the right step for: wrong words, a project that says production, another migration waiting, a failed push,
  the two-jobs check answering OLD, an audit finding, a changed app file. The two-jobs check itself ran on a real
  database with and without migration 35 (`OK`, `MISSING`).

Found and changed while building:
- Migration 35 as first written let no admin give another admin a new password, while the brief's wording for My
  account says "only another admin". Changed: an admin may reset another admin's password (not suspend or offboard
  him); tested both ways.

NOT run / not known:
- **Nothing on staging.** Migration 35 is not pushed and the app is not pushed.
- Windows PowerShell 5.1 for the new script (its helpers are those of the scripts that ran there).
- About 95 new Hindi strings read by nobody who will use them (K45).
- The weekly charts on staging's real dates (the demo data put almost everything in the present week).

### The admin's two jobs on staging: 10 October 2026, 20:55 (record `staging-admin-two-jobs-20261010-205509.log`): `RESULT: ADMIN TWO JOBS ON STAGING`

Run by Veda. S0 OK (app 88 files the tested ones; exactly migration 35 waiting) · S1 OK (migration 35 pushed) · S2 OK
(smoke 31 of 31, two jobs OK, `NO FINDINGS (1 blocks …)`, no login without a person, functions current; the system
empty but for the admin, HR Admin seat vacant) · S3 OK (37 files, `4f5b3dc..66ca725 main -> main`).

## 2026-10-10 (night) — The admin marks the HR Admin as joined (migration 36, open item 30): built and rehearsed on the local stack

Brief "GrainVeda MVP — fix: the HR Admin cannot be activated". Found by Veda on build `mv2jrkag`: the HR Admin seat
holder was Joining, nobody could mark her as joined (the admin's call refused), so HR could never be switched on.
**Nothing of the fix is on staging** (it waits for Veda's say-so).

Ran:
- **The fault, first**: on the local copy of migration 35, in the state found (seat holder Joining, no other HR
  person), the admin's `activate_joiner` for her **succeeds**, and for any other HR or operational joiner too (the
  button was offered on every joiner's page, as the brief says). **The refusal on staging was not reproduced.** The
  run script now records how the seats stand on staging (read only) before it pushes.
- **Database**: `tests/run_local.sh` → `ALL TESTS PASSED`; **1049** `ok` lines; `ok upgrade: … all 30 test files pass on
  it`. New `tests/30_hr_admin_joined.sql` (28 checks): while Joining she has no HR access and cannot mark herself; the
  admin is offered the button only on her page; the server refuses the admin for an operational and for another HR
  joiner (nothing changes for them); the admin marks her as joined, she is Active, one flagged audit line
  `hr_admin_activated_by_admin` by the admin about her; once only; then her HR pages open, she reads the flagged line,
  she marks the other joiners (an ordinary `activated` line); the admin has no HR access, no joiner pages, and on a
  person's page no Reset password, Suspend, Offboard or HR record (the HR Admin's password stays his). **Controls**:
  four broken versions (the admin may mark anyone; the line not flagged; the button for every joiner; no admin branch),
  each caught. Test 29 adapted (with the seat empty the admin no longer marks the HR person he adds until she holds the
  seat).
- **Unit tests**: 223 passed (new `web/tests/hr_admin_joined.test.ts`: the button follows the server; the words in both
  languages). Type check clean; `npm run build:ci` builds.
- **Screens**: default suite **59 passed (10.3 min)**. First day from nothing (`e2e-fresh/fresh_start.spec.ts`, now: the
  admin adds the HR person, no button for her yet; appoints her; Seats says she has not joined; a second HR joiner: no
  button, and the admin's API call answers "only HR marks a joiner as joined"; the HR Admin's page → Mark as joined →
  Seats says HR is on, HR · Joiners leaves the admin's menu, the flagged audit line is there; she signs in and sees HR ·
  Joiners, People & access, Audit log, and marks the second joiner; the admin's view of a person has no HR buttons):
  **1 passed** — after one fault found by it and fixed (the admin was sent to the overview, not Seats: the joiner page's
  own guard acted first). Phases 4, 7, 8, 9 again after that fix: 26 passed.
- **`scripts/staging_hr_admin_joined.ps1`** on stand-ins: the whole run, a second run, and stops for wrong words,
  another migration waiting, the HR-joined check OLD, a changed app file. The two new queries on real databases (with
  and without migration 36: `OK`, `OLD`; the seats line on an empty one).

NOT run / not known:
- **Why staging refused** the admin's call: not reproduced here; the run record's `the seats now:` line is the next look.
- Nothing on staging; the built-app suite was not run again after this change (the public page is untouched).
- 5 new Hindi strings unread by their users (K45).

## 2026-10-10 22:03 IST — Migration 36 on staging (run by Veda)

`staging-hr-admin-joined.cmd`: `RESULT: HR ADMIN JOINED ON STAGING`, app commit `84f54e4`. The record's `the seats now:`
line showed the HR Admin already **active**, marked with a plain `activated` line before migration 36 was pushed: the
first refusal on staging was therefore not reproduced there either. Open item 30 done.

## 2026-10-11 — Joiner checklist and HR data (migration 37, open item 31): built and rehearsed on the local stack

Brief "GrainVeda MVP — Joiner checklist and HR data improvements" (Veda, 11 Oct; plan approved "as per
recommendation"). **Nothing of it is on staging** (it waits for Veda's say-so).

Ran:
- **Database**: `tests/run_local.sh` → `ALL TESTS PASSED`; **1126** `ok` lines; `ok upgrade: the later migrations apply
  to a database in use, and all 31 test files pass on it`; the production build (template now nine tasks). New
  `tests/31_joiner_hr_data.sql` (71 checks): due dates (`greatest(join ± offset, added + 3)`, never overdue on day one),
  Personal details in the template and added to open checklists, who may give a number for whom, PAN/Aadhaar/UAN
  duplicates refused by fingerprint (and by the unique index directly), fingerprints and last four validated, HR sees
  whose and the joiner does not, records without fingerprints "not checked", bank warning and acceptance with a scrubbed
  reason (flagged), the masked-image flow with the storage delete policy and the file's line kept, PAN card seen,
  Personal details saved and read, dependencies, the joiner's contacts and first day, client error reports scrubbed,
  the ledger intact. **Controls** (seven broken versions, each caught): no unique index; no refusal; the storage policy
  open to anyone; no three-day grace; no scrub; no dependency check; `record_id_number` open to people. Tests 25, 26,
  28, 29, 08 and `production_seed_check.sql` adapted (phones, nine tasks, the API surface).
- **API on the local stack**: `tests/remote_create_user.mjs` **91 passed** (a joiner without a phone → 400; the PAN photo
  refused; an old app's last four refused; the identity step closed only after the number went through `id-numbers`;
  a manager cannot give a number for someone else; a wrong check digit refused without being repeated);
  `tests/remote_rls.mjs --t1` **192 passed**.
- **Unit tests**: **279 passed** (new `web/tests/id_numbers.test.ts`, 52: the number rules, HMAC against RFC 4231,
  every answer code, and for each kind and each outcome — saved, warned, refused, database error, network failure —
  the number is in no request to the database, no answer and no log line; the function's source has no console call.
  **Controls**: a `console.error` of the number, the number sent to the database, the number echoed in an answer:
  17, 16 and 5 tests fail. New `web/tests/i18n_split.test.ts`.) Type check clean; `npm run build:ci` builds.
- **Screens**: default suite **63 passed (11.3 min)**, including new `e2e/phase10.spec.ts` (4) and the reworked joiner
  path in `phase8`. `phase10` types a fresh PAN, Aadhaar, UAN and account for one joiner, refuses them for a second
  (English and Hindi words, no name shown), accepts the shared account with a reason, finds the flagged lines in the
  HR Admin's log, then **searches**: the full `pg_dump`, the PostgreSQL log with `log_statement = all` for the length of
  the test (every statement and its parameters), every log of the local services, the stored files, and the browser's
  localStorage, sessionStorage and IndexedDB, for seven shapes of the numbers: **none found**. Planted controls found
  (the joiner's name and last four in the dump, a marker statement in the PostgreSQL log, a marker inside the uploaded
  image in the store). **Control**: the function changed to `console.log` the number → the test fails naming
  `functions.log`. Then: Add joiner refused without a phone (browser and server); nothing overdue on day one; "not
  masked" deletes the image (the store refuses it afterwards) and reopens the step with the note; the joiner's date,
  HR words, Help page with the HR Admin's contact, guide, first-day details, B7 words and Personal details in both
  languages at phone width.
- **First day from nothing** (`e2e-fresh`): 1 passed. **Built app** (`playwright.prod.config.ts`): **14 passed**; the
  public page first load **162 KB** (it was 204 KB with migration 37's words, over the 200 KB budget: the public page
  now loads only its own words, K13 closed).
- **`scripts/staging_joiner_hr_data.ps1`** on stand-ins (PowerShell 7 on Linux): the whole run; a second run (key kept,
  nothing pushed twice); stops for wrong words, production, another migration waiting, a secret that will not set, a
  function that will not deploy (then a re-run completes), a smoke row not OK, a changed and a new function file;
  `-NoGit`; an existing key file reused. The key never appeared in the screen output or the record.

NOT run / not known:
- Nothing on staging: the secret, the functions, the migration, the app. The hosted logs (Edge Functions, Postgres,
  API gateway, PostgREST) have not been searched: run-sheet step 10 is for Veda.
- Windows PowerShell 5.1 (the script is plain ASCII and uses only what the earlier scripts use).
- About 110 new Hindi strings unread by their users (K50).
- The HR files already on staging: the run lists them (S4); the brief's list waits for that record.
