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
