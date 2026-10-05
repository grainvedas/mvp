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
