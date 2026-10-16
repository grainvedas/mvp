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

**Staging, 11 Oct 2026, 00:20 IST (Veda ran `staging-joiner-hr-data.cmd`):** `RESULT: JOINER HR DATA ON STAGING`;
app commit `8bef8ed`; smoke 32 of 32; `personal_steps_added=1`; the HR files already stored: three, all logo images
(kinds pan, bank_proof, pf_form), none a real ID. Migration 37 and the five functions are on the practice system.

## 2026-10-12 — Onboarding at scale (migration 38, open item 32): built and rehearsed on the local stack

Brief "GrainVeda MVP — Onboarding at scale (10 → 100 → 200+ hires)" (Veda, 11 Oct; the six decisions "as
recommended", FIX_LIST G17). **Nothing of it is on staging** (it waits for Veda's say-so).

Ran:
- **Database**: `tests/run_local.sh` → `ALL TESTS PASSED`; **1,229** `ok` lines; `ok upgrade: the later migrations apply
  to a database in use, and all 32 test files pass on it`. New `tests/32_onboarding_at_scale.sql` (**99 checks**):
  openings (codes, validation, who reads and plans, the form's lists), Add joiner against an opening (role, the
  role's checklist, HR owner, a full opening refuses), the import (dry run with reasons, commit of only the good rows,
  the same file again skipped), the HR owner and Mine, invites (service key only, token fingerprint not readable, one
  use, expiry, a new one revokes), reminders queued once per step and day, the lists and filters, the gate (statutory
  refuses; on paper flagged; a reason flagged), bulk acts each logged, H2 and H3, ready to assign and assigning many,
  the Deputy (flagged), the numbers per opening, state and overall and on the admin's overview, H7, direct writes of
  the new columns refused. **Controls** (`controls.sh`, ten broken versions, each caught): statutory not checked; no
  reason needed; error rows committed; an opening never full; invite expiry ignored; `assign_many` without the
  may-assign check; Deputy seating not flagged; the admin on the HR Admin's checklist not flagged; Mine shows everyone;
  assigned never counted. Tests 26, 30, 08 and `production_seed_check.sql` adapted (the gate, role checklists, the API
  surface). The smoke check's new rows (`onboarding at scale`, `reminder round`): OK on the stack; the first fails on
  each of five broken versions (an invite function opened, the token fingerprint readable, the guard trigger dropped,
  a role checklist switched off, a function missing).
- **API on the local stack**: `tests/remote_create_user.mjs` **95 passed** (now through the gate: refused with the
  statutory step open, recorded on paper, refused without a reason, joined with one); `tests/remote_rls.mjs --t1`
  **192 passed**.
- **Unit tests**: **311 passed** (new `web/tests/scale.test.ts`, 13: import dates and column names, filters, paging,
  invite token shape, the group message, the gate, a joiner's overdue steps, bulk refusals in the reader's language,
  every new word in English and Hindi, "State Manager"; `web/tests/invite.test.ts` 19, two planted faults caught).
  Type check clean; `npm run build:ci` builds (the invite page is its own 3.6 KB chunk).
- **Screens**: default suite **64 passed (11.5 min)** on a stack built from nothing, including new `e2e/phase11.spec.ts`
  at **527 px**: a Client Manager drafts a scope; HR makes an opening for it (205 positions; "the scope is not active
  yet"); a 208-row spreadsheet: preview 205 good, 3 errors with their reasons; add; the same file again: 205 skipped,
  nothing added; the list by opening, paged (Page 1 of 5 · 205), Mine, search, H1 "joining date:" for someone joining
  today; invite links for a page of 50 (on the stack a mail stand-in counts as a sender: "Emailed to 50"); one joiner
  opens the link on a 390 px phone, the token leaves the address bar, chooses a password, is signed in on the
  checklist; the link again: used; the gate: a full-time joiner refused, on paper, a reason, "Active" at once (G2);
  bulk Mark as joined: the four full-time ones refused ("a statutory step is still open"), a page of 50 contract
  operators joined with one reason; the openings: joined 51, waiting for their wave 51, ready 0; Hindi on the phone;
  the Client Manager staffs the draft from the joined people (searching the pool), activates it: 48 ready, **40 given
  Procurement in one act**, 8 left; the openings: assigned 43, waiting 0, ready 8; the admin's overview shows the same
  totals; 43 `assigned` lines in the audit log. Existing tests adapted: Mark as joined through the gate (`markJoined`
  helper: phase 7, 8, fresh start), the HR list's new screen, "State Manager", and the roster's pool (the first 100 by
  name; tests now search, as a manager would with hundreds of people). A fault found by these runs and fixed: the
  joiner page broke with a hook after an early return (blank page); the admin reached any joiner's page (now only the
  HR Admin's, else home); the HR list showed task titles without their Hindi; a bulk act's outcome vanished with the
  selection; the opening form read clients HR may not read (now `app.opening_targets`).
- **First day from nothing** (`e2e-fresh`): **1 passed**, after a fault found on the way: the fresh-start removal
  (`scripts/fresh_start/empty_staging.sql`, also the staging script's file) removed checklists that people still
  pointed at and stopped; it now keeps the checklists the migrations wrote (the standard one and one per role) and
  removes those made by people after the people. Shown on a stack with 203 joiners on role checklists.
  `scripts/staging_fresh_start.ps1` takes the new file's hash and counts the standard checklist's tasks (9); that
  script itself was not run again.
- **Built app** (`playwright.prod.config.ts`): **14 passed**; the public page first load **162 KB**.
- **Load** (`tests/load_onboarding.mjs`, local stack only; fake names, `example.com`, phones `7…`): the brief's shape
  (1 State Manager, 2 Client Managers, 200 operators over 5 stages): **29 passed** — preview 209 rows 49 ms, add 382 ms,
  invites for 203 people 1.2 s, the joiners list 26–35 ms per page, People & access 84 ms, by role and state 120 ms
  (887 ms before HR's view skipped the per-assignment visibility check), audit log 20 ms, openings 118 ms, on paper
  for 203 people 0.6 s, Mark as joined for 203 0.45 s, ready to assign 11 ms, **40 on a stage in one act 100–141 ms**.
  At ten times that (2,003 per run, about 5,700 people in the system, 3,600 joining): preview 1,000 rows 0.5 s, add
  3.1 s, invites 11.5 s, a joiners page 115–150 ms, People & access 101 / 194 ms, openings 170 ms, Mark as joined for
  2,003 4.3 s, **400 on a stage in one act 0.85–0.92 s**. All on the local stack: the hosted project adds the network.
- **`scripts/staging_onboarding_at_scale.ps1`** on stand-ins (PowerShell 7 on Linux): the whole run (`RESULT:
  ONBOARDING AT SCALE ON STAGING`, six functions, `invite` and `ledger-check` with `--no-verify-jwt`); a second run
  (nothing pushed twice); stops for wrong words, production, another migration waiting, no key of id-numbers, a
  function that will not deploy (then a re-run completes), a push that fails, a smoke row not OK, a changed and a new
  function file; the reminder row not scheduled is listed and does not stop; `-NoGit`. `staging-joiner-hr-data.cmd`
  now refuses (its files are no longer the tested ones).

NOT run / not known:
- Nothing on staging: the functions, the migration, the app.
- Email: no sender on any hosted project; invites and reminders are not emailed there (decisions 1 and 2). pg_cron on
  the hosted project: the smoke row says whether the reminder round is scheduled.
- Windows PowerShell 5.1; real phones; the hosted project's speed.
- About 250 new Hindi strings unread by their users (K57).

**Staging, 11 Oct 2026, 15:30 IST (Veda ran `staging-onboarding-at-scale.cmd`):** `RESULT: ONBOARDING AT SCALE ON
STAGING`; app commit `6d67915`; smoke 34 of 34; role checklists 4; no due dates moved (nobody was joining).

## 2026-10-13 — HR by geography (migration 39, open item 33): built and rehearsed on the local stack

Veda, 12 Oct, after seeing an HR resource made State Manager on staging (decisions G18). **Nothing of it is on
staging** (it waits for Veda's say-so, and for the HR Admin to end that seat first).

Ran:
- **Database**: `tests/run_local.sh`: **1,282** `ok` lines; every file passes, fresh and on the upgrade path, except
  one timing check in `tests/13_phase3_ops.sql` ("incoming list for a 500-lot scope in < 1000 ms": 1,090 and 1,194 ms).
  **That check fails the same way without migration 39** on this machine (a database of migrations 1–38: 1,063 and
  1,080 ms; it passed on 12 Oct at under 1,000 ms on the machine of that day): the machine, not the change. Not loosened.
  New `tests/33_hr_geography.sql` (**53 checks**): who gives an HR resource her states (not herself, not the admin
  while the seat is filled, only HR resources, not through the API), the base state and district kept and logged, an
  HR resource's reach (no person, HR record, checklist, document, joiner page, profile, list row, HR step, Mark as
  joined, suspension, edit, password reset, invite, stored file or base-location move for a person of another state;
  her own state's are), Add joiner and import only for her states, openings only in her states, the base location
  (set by HR of the state, not out of her states, not directly through the API, read by a manager), states given and
  taken back (history kept, both logged), HR holds no seat (no state seat, client account or stage; a seated person
  is not made HR or HR Admin; leaving HR ends the states), the Deputy only in her states, a person with no base state
  reached only by the HR Admin. **Controls** (ten broken versions, each caught). Tests 15, 24, 25 and 32 adapted.
  Smoke rows `hr by geography` and `HR holds no seat`: OK on the stack; caught a reopened table, the old store rule and
  an HR person with a seat.
- **A fault found on the way**: the Add joiner form's opening, role, stage and HR owner never reached the database
  (`create-user` passed only the older fields; since migration 38). A unit test of `create-user` failed before the fix
  and passes after it; `phase12` shows the opening on a joiner added on the form.
- **API on the local stack**: `tests/remote_create_user.mjs` **95 passed**; `tests/remote_rls.mjs --t1` **192 passed**
  (Imran reads the employees of his state and HR: 240 of 242).
- **Unit tests**: **315 passed**. Type check clean; `npm run build:ci` builds.
- **Screens**: default suite **65 passed (17.7 min)** on a stack built from nothing, including new `e2e/phase12.spec.ts`
  at 527 px: the HR Admin adds a joiner based in Assam (district shown); Imran (Uttar Pradesh) is told "You work for:
  Uttar Pradesh", does not find her and cannot open her page, is offered only his state on Add joiner, adds a joiner
  against an opening (the opening is on the record); Hindi; the HR Admin gives him Assam on HR · Team and he reaches
  her, then takes it back; his profile offers no assignment; the base location is edited and logged. A first run of
  the suite failed in 14 tests because the local functions runner had not started (its port was still held): the
  stack was restarted and the whole suite run again.
- **First day from nothing**: **1 passed** (after the fresh-start removal, which keeps the role checklists).
- **Built app**: **14 passed**; the public page first load **162 KB**.
- **`scripts/staging_hr_geography.ps1`** on stand-ins: the whole run; a second run; the stop while an HR person holds a
  seat (named); wrong words; another migration waiting; a smoke row not OK; a function that will not deploy;
  production; a changed function file; `-NoGit`. `staging-onboarding-at-scale.cmd` now refuses.

NOT run / not known:
- Nothing on staging. Windows PowerShell 5.1. Real phones. About 25 new Hindi strings unread (K57).

## 13 October 2026, 02:42 to 03:25 IST: HR by geography on staging (migration 39)

Veda's say-so; run from her computer, checked in her Chrome (signed in herself each time; Claude typed no password).
- **Before the run**: Neha held the Uttar Pradesh State Manager seat (given by Minal 11 Oct). The admin cannot end it
  (the admin gives nothing since migration 35); Minal ended it, reason "HR holds no seat".
- **Run 1** (02:42): `RESULT: STOPPED` at S0, naming Neha's seat (as designed; this was before the seat was ended).
- **Run 2** (02:49): S0 to S2 OK (six functions, build 2026-10-14; migration 39 pushed); **S3 stopped on a fault of
  the script**: all 36 smoke rows were OK, but the script looked for the check `HR holds no seat` and found the
  words first inside the result of the row before it ("OK an HR resource works for her states; HR holds no seat"),
  so it read that row as not OK. The stand-in smoke output used in the rehearsal printed a bare "OK" for that row.
  Fixed: a check's name is found only at the start of a table cell in the first column; the stand-in now prints the
  real result texts; reproduced (old script stops, new passes) and the second run from the stopped state rehearsed.
- **Run 3** (02:57): `RESULT: HR GEOGRAPHY ON STAGING`. S2 not run (already pushed); smoke 36 of 36; ledger audit no
  findings; no login without a person; functions current; base states filled 0 (2 people, neither on an opening or a
  seat); S4 pushed 48be0fc (42 files).
- **In the app** (Minal): HR · Team listed Neha with no state; Uttar Pradesh given; Neha based in Uttar Pradesh. Test
  opening UP-OPR-001 (Uttar Pradesh, operator, QC, 1 position). `TEST Other` added based in Bihar · Patna; `TEST Mine`
  added on the form against UP-OPR-001: role Operator · Quality Control and the opening on the record (**the Add
  joiner fault is fixed on staging**), based Uttar Pradesh · Gorakhpur. Audit log: every step logged.
- **In the app** (Neha): "You work for: Uttar Pradesh"; Joiners and People & access list TEST Mine and Neha only;
  TEST Other's joiner page and profile, opened by address: "Person not found"; Add joiner offers only Uttar Pradesh;
  Openings shows only UP-OPR-001. Her profile offers no Assign.
- **Clean-up** (Minal): TEST Other and TEST Mine offboarded (kept as records); UP-OPR-001 closed. Fake addresses at
  example.com and phones 9000000011/12 only.
- Small faults seen: open item 34. Not checked on staging: giving Neha a second state and her then reaching a person
  of it (checked on the local stack, `phase12`); the import with a state column; Hindi; a phone.

## 13 October 2026, 03:30 to 04:40 IST: small fixes (open item 34), local stack

App only: no migration, no server function (functions build stays 2026-10-14).
- (a) Audit: `fromTo` in `web/src/lib/format.ts`; the base-location line showed nothing because its "from" was an
  empty string. (b) People & access: the State filter uses `stateChoices` (an HR resource: her states). (c) `translate`
  uses the key's `.one` form when n is 1; `.one` added for `seats.code_refused`, `open.not_linked`, `imp.done`,
  `imp.invite`, `jl.count` (English and Hindi). (d) `todayIST()`: offboard exit date default, ledger CSV name, the
  onboarding overdue check (already IST, now the shared helper).
- **Unit tests**: **319 passed** (new `web/tests/fixes34.test.ts`, 4; its count test failed with the old `translate`).
  Type check clean; `npm run build:ci` builds.
- **Screens** (stack rebuilt from nothing): `phase12` + `phase8` **9 passed**, then the default suite **65 passed
  (16.7 min)**. New checks: Imran's State filter offers only Uttar Pradesh; the audit line reads "Uttar Pradesh ·
  Basti → Uttar Pradesh · Gorakhpur"; the offboard exit date defaults to the date in India (run at 03:45 IST, when the
  UTC date was the day before).
- **`scripts/staging_small_fixes.ps1`** (new; `staging-small-fixes.cmd`) on stand-ins: the run; a second run (nothing
  new); wrong words; a migration waiting; functions not current; production; app files not the tested ones; a migration
  file about to be committed. `staging-hr-geography.cmd` now refuses (the tested list changed). Sealed: 113 files.

NOT run / not known: nothing on staging yet. Windows PowerShell 5.1. Hindi of the five new ".one" strings unread.
- **On staging** 04:19 IST: `staging-small-fixes.cmd` `RESULT: SMALL FIXES ON STAGING` (head a36b635, 16 files). In the app
  (Minal): the audit line for Neha's base location reads "— → Uttar Pradesh". The other three were checked on the local
  stack only (the filter needs Neha's sign-in; no count of one on staging; the offboard date needs an offboarding).

## 13 October 2026, 04:40 to 05:30 IST: the admin sets where the HR Admin is based (migration 40), local stack

Found while setting Minal's base location (Delhi, added by Veda as a state): nobody could. Veda chose the admin.
- `supabase/migrations/20261015000100_hr_admin_base.sql`: `app.set_base_location` and `app.person_geo` replaced (from
  their migration-39 definitions, two conditions widened). Nothing else.
- **Database**: `tests/run_local.sh`: **1,294** `ok` lines (1,282 + 12); every file passes, fresh and on the upgrade
  path, except the timing check in `tests/13_phase3_ops.sql` (1,049 and 1,122 ms; environmental, as on 13 Oct, not
  loosened). New `tests/34_hr_admin_base.sql` (**12**): the admin offered and sets the HR Admin's base (logged); not
  anyone else's while the seat is filled; the HR Admin not her own; an HR resource and an operational person refused.
  Control: on a database with the migration-39 functions the file fails at its first check.
- **Screens**: `phase12` **2 passed** (new: the HR Admin is not offered her own; the admin sets it, Assam · Guwahati,
  and back; the admin is not offered Ravi's).
- **`scripts/staging_hr_admin_base.ps1`** (`staging-hr-admin-base.cmd`) on stand-ins: the run; a second run; wrong
  words; another migration waiting; the rule not in place after the push; a failed push; production; functions not
  current; a smoke row not OK; a changed migration file. The app files are unchanged (113, sealed with item 34).

NOT run / not known: nothing on staging yet. Windows PowerShell 5.1.
- **On staging** 04:43 IST: `staging-hr-admin-base.cmd` `RESULT: HR ADMIN BASE ON STAGING` (head f70d2a1, 8 files; smoke
  36/36; the new rule in place; ledger audit no findings). In the app (Veda, admin): Minal's profile offered Edit on
  Based in; set to Delhi (added by Veda as a state). Also checked as Neha after item 34: her State filter offers only
  Uttar Pradesh; the Joiners count reads "1 person".

## 13 October 2026, 05:30 to 08:30 IST: the State Manager, Release 1 (migration 41, open item 36), local stack

From Veda's brief "GrainVeda MVP — State Manager role" and her answers (a new scope in its client's home state; the
Client Manager drafts farmers, the State Manager verifies after him; a read-only ledger of his state). Parts A, B, E, F
and the crop's state. Parts C (crop registry) and D (farmer register) are Releases 2 and 3, not built.
- **Probe first** (as the demo UP State Manager, on a copy of the database, before any change): he could edit every
  crop; create and edit scopes, also of another state's client; seat HR, the admin and himself through a direct insert;
  activate a farmer from draft (skipping the Client Manager), and a blank state switched step 2's checks off; read
  another state's farmers through a scope; create and import farmers; see the admin, HR and other states' people;
  change the email of a client login shared with another state; override a QC verdict. All closed by migration 41.
- `supabase/migrations/20261016000100_state_manager.sql`: helpers, rules and the two read functions (`app.state_home`,
  `app.state_ledger_page`); changed functions patched from their current definitions with each substitution asserted.
  Additive: one column (`crops.state_id`), no row rewritten.
- **A fault found by the screen suite and fixed before delivery**: with 241 people (after `phase11`'s 205 joiners)
  People & access for the State Manager took **43.5 s** (the per-person check re-read his states for every row; the
  screen showed "Employees (…)" and the test timed out). Now `app.sm_seen_ids()` is asked once per statement and the
  read rules ask their no-argument helpers once: **0.34 s** (People & access), 0.48 s (directory), 25 ms (the people
  table), 21 ms (his overview), 15 ms (his ledger, 50 blocks), on the same data; the Client Manager's own People & access
  takes 0.33 s there. A control now breaks `sm_seen_ids`.
- **Database**: `tests/run_local.sh`: **1,370** `ok` lines; every file passes, fresh and on the upgrade path, except
  the timing check of `tests/13_phase3_ops.sql` (1,308 and 1,207 ms; 1,011 to 1,096 ms in three runs on their own;
  1,049 to 1,122 before migration 41; environmental, not loosened). New `tests/35_state_manager.sql` (**73**), with
  **16 controls** (each breaks one rule on a copy and the file fails at that rule's check): 16 of 16 caught. Changed
  expectations in tests 08 (API surface), 09, 24, 28 (the State Manager no longer builds scopes or adds farmers).
- **API with real logins** (local stack): `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **326 passed** (new `web/tests/state_manager.test.ts`, 7). Type check clean; `npm run build:ci` builds.
- **Screens** (stack rebuilt from nothing): default suite **68**: 67 passed, then `phase13` passed after its fix (it
  looked for the Client Manager on the first page of a list `phase11` had made long, and checked the crop before the
  list was in); `phase13` then passed twice more on the used stack. Four older tests changed to the new rules: Health
  (`phase4`) and States are the admin's; the State Manager's Crops link is "Crops" (`phase5`); State overview is not in
  his menu (`phase8`, the page still opens); he reads the ledger of his state (`phase9`). Production build **14
  passed**; the first day from nothing **1 passed** (the wizard shows the client's state as text). Screenshots looked at, 527
  and 1366 px: his overview and his ledger (the crops and Hindi checked by `phase13`, not by eye).
- **`scripts/staging_state_manager.ps1`** (`staging-state-manager.cmd`) on stand-ins: the run; a second run (nothing
  waiting, nothing to commit); wrong words; another migration waiting; the rules not in place after the push; a failed
  push; production; functions not current; a smoke row not OK; a changed migration; a changed app file; a `.env` file
  present (git-ignored, not committed). `staging-hr-admin-base.cmd`, `staging-small-fixes.cmd` and
  `staging-hr-geography.cmd` now refuse. Sealed: 115 files.

NOT run / not known: nothing on staging yet. Windows PowerShell 5.1. A real phone. The 66 new Hindi strings unread by
their users. Speed with thousands of people for the State Manager (measured with 241).
- **On staging** 08:39 IST: `staging-state-manager.cmd` `RESULT: STATE MANAGER ON STAGING` (head 555a7ef, 42 files; smoke
  37/37; the new rules in place; crops with no state 1, clients without a Client Manager 2, scopes outside their
  client's state 0; ledger audit no findings). **Vercel did not build the push**: ten minutes later its Deployments page
  still ended at f70d2a1 and the Git link showed connected. With Veda's OK Claude created the deployment by hand
  (Deployments → Create Deployment → `main` → Deploy to Production): Ready in 8 s. In the app as Ram (UP State Manager,
  a real account Veda set up): his home "Uttar Pradesh overview · State Manager · Ram", guide and checklist, 2 clients,
  "2 clients have no Client Manager yet"; menu by heading; `/states` and `/health` bring him home; People & access lists
  Ram only; scopes read-only; the farmers note; the ledger of his state (3 blocks, the check line); Hindi. Kalanamak
  saved as Ram (Veda's OK): Uttar Pradesh; his checklist 2 of 5. Seen: the ledger's "Signed by" listed only Ram (fixed in
  migration 42). Not checked: checks 4 and 8–10 (staging has no second person in Uttar Pradesh for a Client Manager);
  check 12 (the admin's Audit log line).

## 13 October 2026, 09:20 to 12:30 IST: the crop registry, Release 2 (migration 42, open item 37), local stack

From Veda's brief, part C, and her answers (GAP: required refuses, optional warns; ready = unit, yield, limits, chain;
harvest window warns; typed limits number / grade / yes-no; a crop per state; the admin removes an unused crop, retires
one in use, corrects an unused crop's state).
- `supabase/migrations/20261017000100_crop_registry.sql`: crop columns, `farmer_gap`, the checks, `app.judge_typed`, the
  ready trigger on scopes, the Procurement check (in `check_new_footprint`, after reconciliation, so the form's preview
  says the same), the admin's three acts, `app.crop_registry`; `judge_readings`, `derive_qc_verdict`, `crops_state_guard`,
  `crops_audit`, `state_home`, `state_ledger_page` patched from their current definitions, each substitution asserted.
  The ready rule is asked of a person acting (`auth.uid()`), so the demo seeds still load; seed 08 makes the demo crops
  ready (shortest recommended chain, so the wizard starts as before).
- **Database**: `tests/run_local.sh`: **1,436** `ok` lines (1,370 + 66); every file passes, fresh and on the upgrade path,
  except the timing check of `tests/13_phase3_ops.sql` (1,125 and 1,377 ms; environmental, as before; not loosened). New
  `tests/36_crop_registry.sql` (**66**) with **15 controls**: 15 of 15 caught; the 16 controls of test 35 still 16 of 16.
- **API with real logins** (local stack): `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **334 passed** (new `web/tests/crop_registry.test.ts`, 8). Type check clean; `npm run build:ci` builds.
- **Screens** (stack rebuilt from nothing): default suite **69 passed** (19.4 min), with the new `phase14` at 527 px: Ram
  makes a crop ready on the phone (number, grade and yes/no limits, two practices, harvest window, a document, the
  shortest chain); the wizard shows a crop that is not ready as disabled and starts from the recommended chain; the
  Client Manager answers a farmer's practice; Procurement refused for a farmer with the required practice open, saved
  with both warnings for the other; the lab record entered on the screen with the grade and the yes/no picked, the
  preview "domestic passed · export not met · Aroma (export)", the saved verdict pass / fail and the record showing "B"
  and "No"; Ram's "Signed by" lists the lab operator; Hindi; the admin removes the unused crop and retires the used one;
  both in the Audit log. A first full run found two faults of the release, fixed before this one: the test scope's seats
  stayed (`phase6`, `phase8` counted one scope too many: the test now closes its scope) and the demo Kalanamak's
  recommended chain changed the wizard's start (`phase1`: the seed now recommends the shortest chain). Older tests
  changed: `phase5` (the decimal limit on the new form), the first day from nothing (the crop made ready).
  Production build **14 passed**; the first day from nothing **1 passed**. Screenshots looked at, 527 and 1366 px: the
  Crops page and the form.
- **`scripts/staging_crop_registry.ps1`** (`staging-crop-registry.cmd`) on stand-ins: the run; a second run; wrong words;
  another migration waiting; the rules not in place after the push; a failed push; production; functions not current; a
  smoke row not OK; a changed migration; a changed app file. It ends by telling the person to check that Vercel shows the
  commit Ready. `staging-state-manager.cmd` and the earlier scripts now refuse. Sealed: 118 files.

NOT run / not known: nothing of Release 2 on staging yet. Windows PowerShell 5.1. A real phone. About 95 new Hindi
strings unread by their users.

## 13 October 2026, afternoon IST: the farmer register, Release 3 (migration 43, open item 38), local stack

From Veda's brief, part D, and her answers (a duplicate is the same phone in the same state, shown masked; flagged for
the State Manager, who decides before the Farmer ID; GI land × yield per acre per season, a lot past it warned and the
farmer flagged past 120 %; GI land needed before the Farmer ID, a draft may go without).
- `supabase/migrations/20261018000100_farmer_register.sql`: `farmers.gi_land_acres` (with a rule judging new and changed
  rows only), `farmer_dup_reviews`, `app.phone10`, `app.open_duplicates`, `app.mark_not_duplicate`, the Farmer ID rule
  (`farmers_z2_register_rules`, asked of a person acting), `app.season_sales`, `app.over_yield`, `app.farmer_register`;
  `procurement_crop_checks` (the yield warning, so the form's preview says the same), `import_farmers` (the GI land
  column) and `state_home` (duplicates, past 120 %, no GI land) patched from their current definitions, each substitution
  asserted. Older test files that issue a Farmer ID now give the farmer his GI land first.
- **Database**: `tests/run_local.sh`: **1,473** `ok` lines (1,436 + 37); every file passes, fresh and on the upgrade
  path, except the timing check of `tests/13_phase3_ops.sql` (1,140 and 1,232 ms; environmental, as before; not
  loosened). New `tests/37_farmer_register.sql` (**37**) with **11 controls**: 11 of 11 caught; tests 35 and 36's
  controls still 16 of 16 and 15 of 15.
- **API with real logins** (local stack): `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **340 passed** (new `web/tests/farmer_register.test.ts`, 6; `state_manager.test.ts`: the menu, "Needs my
  action"). Type check clean.
- **Screens** (stack rebuilt from nothing): default suite **70 passed** (21.4 min), with the new `phase15` at 527 px: the
  Client Manager's form refuses GI land above the land and saves a draft without it; Ram's step 2 is off until he adds
  it; a record of a second client with the same phone (seeded on the local stack only) refuses the Farmer ID; "Needs my
  action" counts it and opens the register on that flag; both cards name each other, the phone shown as `••••••` and its
  last four digits and nowhere whole; "Not the same person" needs a reason; the other pair: one record deactivated; then
  the Farmer ID; two lots of 98 kg against 100 kg expected, the second warned "196 of 100 kg"; flagged past 120 % on the
  register with "(196%)"; the admin reads with no decision buttons. A first full run found a fault of the app, fixed
  before this one: the farmer form loaded the farmer twice in development (React's double run) and the second load
  overwrote what had been typed (`phase1`: the GI land was lost); the form now ignores a load it no longer needs. Older
  tests changed: `phase1` (the State Manager adds the GI land at step 2), `phase4`, `phase7`, `phase9`, `phase13`, the
  first day from nothing (GI land typed). Production build **14 passed**; the first day from nothing **1 passed**.
  Screenshots looked at, 527 and 1366 px: the register and the form.
- **`scripts/staging_farmer_register.ps1`** (`staging-farmer-register.cmd`) on stand-ins: the run; a second run; wrong
  words; another migration waiting; the rules not in place after the push; a failed push; production; functions not
  current; a smoke row not OK; a changed migration; a changed app file. `staging-crop-registry.cmd` and the earlier
  scripts now refuse. Sealed: 121 files.

NOT run / not known: nothing of Release 3 on staging yet. Windows PowerShell 5.1. A real phone. About 60 new Hindi
strings unread by their users.
- **On staging** 17:44 IST: `staging-farmer-register.cmd` `RESULT: FARMER REGISTER ON STAGING` (head 365b307, 40 files;
  smoke 39/39; the new rules in place; farmers 0, so nothing without GI land, waiting or duplicated; ledger audit no
  findings). Vercel built 365b307 itself (Ready, 32 s). In the app as Ram: **Farmer register** in his menu, "Farmer
  register — Uttar Pradesh", every card 0, filters, the note; **Needs my action** lists "Possible duplicate farmers
  (same phone): 0" and "Farmers past 120% of their expected yield this season: 0" beside the two clients without a
  Client Manager. Release 2 checked at the same time: Kalanamak still **Not ready** ("Still needed: yield per acre,
  recommended chain"; Ram completes it himself); the state ledger's "Signed by" now lists Minal, who signed all three of
  its blocks (it listed Ram before migration 42). Not checked yet: everything that needs a Client Manager, a ready crop
  or a scope; the admin's view of the register and the admin's audit line (need Veda signed in as admin).

## 14 October 2026: rules and farmer IDs, Release 4 (migration 44, open item 39), local stack

From Veda's follow-up brief of 14 Oct (sections 0, A, E, D1, D2, D6, G) and her answer "go with your recommendations"
(test data hidden, not deleted; the State Manager reads scope records, K62 closed; the roster pool leaves out people
with no base; the order R4, R5, R6). **Nothing of it is on staging** (it waits for Veda's say-so).

The two checks of the brief, read from the practice data and the code:
- **TCUP-F-0001**: Lucky did step 1 ("Save and verify": `reviewed_at` 0.4 s after the record was made), Ram step 2.
  Step 1 wrote no ledger block (only step 2 did): from migration 44 step 1 writes `farmer_verified_client`.
- **The farmer ID scheme**: the client farmer ID (`PRSDM-F-0001`) at step 1; the state farmer ID `F-UP-00001` (state
  code, five digits, a counter per state) at step 2; the same phone already a state farmer's in the state: linked, or a
  new ID with the reason; a consent tick before a state farmer ID is ever shown publicly (Release 5).

Ran:
- `supabase/migrations/20261019000100_rules_and_farmer_ids.sql`: new parts (`app.stage_refusal`, `app.roster_pool`,
  `app.activation_missing`, `scopes_a3_staffed`, the Client Manager's view, `app.working_role_at`, test data, the state
  farmer IDs, `app.change_farmer`, `farmer_change_flags`, `app.farmer_history`, `app.practice_fix_14oct`) and functions
  patched from their current definitions, each substitution asserted.
- **Database**: `tests/run_local.sh`: **1,546** `ok` lines, **ALL TESTS PASSED**, fresh and on the upgrade path. New
  `tests/38_rules_and_farmer_ids.sql` (**67 checks**) with **17 controls**: 17 of 17 caught; tests 35, 36 and 37's
  controls 16/16, 15/15, 11/11. Older tests changed for the new rules: 04, 07, 08, 11, 14, 24, 25, 28, 32, 33, 35, 36, 37.
  The timing check of `tests/13_phase3_ops.sql` that failed on this machine since 13 Oct now passes: migration 44 first
  made the incoming list slower (620 → 900 ms), so `app.incoming_records` now asks who may see the list once instead of
  for every lot (the same answer: every row has that scope and stage): **8 ms**.
- **The practice corrections** on an upgraded copy of the practice-like data: the scope back to draft with its ledger
  block, UP-SM-001 to 1 position, TEST Mine hidden; a second run says "already"; the ledger audit: **NO FINDINGS**; the
  smoke row `rules and farmer ids` OK.
- **API with real logins** (local stack): `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **346 passed** (new `web/tests/rules_and_ids.test.ts`, 6). Type check clean; production build.
- **Screens** (stack rebuilt): default suite **71 passed** (14.5 min) with the new `phase16` at 527 px (the pool,
  activation waiting for people, the refusals in words, People & access, My guide, both IDs, the same phone linked, the
  history, a change with a reason accepted from the register, the working role on the ledger, one position on a State
  Manager opening). Older tests changed for the new rules: `phase1`, `phase4`, `phase6`, `phase7`, `phase8`, `phase12`,
  `phase14`, `phase15` (rewritten to the new duplicate model). Production build **14 passed**; the first day from nothing
  **1 passed** (the first state farmer ID is `F-UP-00001`). Two faults of the app found and fixed on the way: a
  correction's form could take typing into the empty new-record form while the record loaded (`phase1` failed once);
  the farmer list showed the previous client's farmers while another client's loaded, so a click could act on the
  wrong one. Screenshots looked at, 527 and 1366 px: the People step, the State Manager's scope, the farmer's page, the
  register, the ledger, My guide.
- **`scripts/staging_rules_and_ids.ps1`** (`staging-rules-and-ids.cmd`) on stand-ins: the run (S1b reports the three
  corrections); a second run ("already"); wrong words; another migration waiting; the rules not in place after the
  push; a failed push; the corrections failing; production; functions not current; a smoke row not OK; a changed
  migration; a changed app file. `staging-farmer-register.cmd` and the earlier scripts now refuse. Sealed: 122 files.

NOT run / not known: nothing of Release 4 on staging yet. Windows PowerShell 5.1. A real phone. About 80 new or changed
Hindi strings unread by their users. Not built: Release 5 (openings, the scope wizard, the GI badge kept off Lot
Inward, the public state farmer ID) and Release 6 (the Client Manager's home, menu and ledger; ranges, required limits,
units).
- **On staging** 14 Oct 07:29 IST: `staging-rules-and-ids.cmd` `RESULT: RULES AND IDS ON STAGING` (head 49adf35, 59
  files; one migration waiting and pushed; S1b: scope TCUP KH26 gkp back to draft with its ledger block, UP-SM-001 10 →
  1 position, TEST Mine marked as test data; smoke 40/40; the new rules in place; farmers 1, with a state farmer ID 1,
  verified without one 0, changes to accept 0, active scopes not fully staffed 0; ledger audit NO FINDINGS (29 blocks);
  NO LOGIN WITHOUT A PERSON; functions current). Vercel built 49adf35 itself (Ready, 10 s, the current Production).
  Not checked yet: the 14 checks in the app (`docs/RUNSHEET_rules_and_ids.md`, Afterwards).
- **In the app as Lucky** (14 Oct, after the run): check 1 — TCUP KH26 gkp is **Draft**, the People step lists the 7
  stages with nobody, **Activate** off. Check 2 — the pool offers only "Lucky (you)": nobody else on staging is an
  operational person based in Uttar Pradesh (no Veda, HR or Ram). Check 4 — People & access lists Lucky alone; the
  filters offer Test Client UP and Uttar Pradesh only. Farmer 1 shows TCUP-F-0001 and F-UP-00001 and its history
  (drafted by Lucky; verified by Ram; the state ID given by the push, with its reason); Lucky's step 1 of 13 Oct is not
  its own line (it wrote no block then). Check 7 as written cannot pass: one client uses a phone once (`farmers_client_phone_key`,
  since phase 1), so Lucky's same-phone farmer was refused, "This already exists (same phone, email or code)", nothing
  saved. The run sheet now asks for the Client Manager of a second UP client. Not done yet: 3 (activation: needs stage
  people based in UP, or Lucky on every stage), 5–6, 8–14.
- **As Ram**: check 5 — the scope reads "You read this scope…", no lists, no Remove; on a person's Assign page only "A
  client's account" (Demo Client 1, Test Client UP). Check 6 — farmer 1 with both IDs and its history. Check 11 — the
  state ledger's new Role column (Client Manager, State Manager, HR Admin). Found: the S1b block 29 ("Activation
  reversed") names **Lucky** as signer (the correction chose the scope's Client Manager first, then the admin); its reason
  says it was the practice correction of migration 44, but the name is misleading. Not changed (a block is never
  edited); asked Veda whether to add a correcting block.
- **As Veda (admin)**: check 12 — My guide opens the admin's guide. Check 14 — People & access lists 6 employees,
  TEST Mine not among them (TEST Other, left, still listed: only TEST Mine was decided); Openings: UP-SM-001 has 1
  position; the closed UP-OPR-001 is left out of the totals (12 = 1 + 10 + 1).
- Open: 3 (stage people based in UP), 7–8 (a second UP client's Client Manager; Demo Client 1 exists), 9–10 (Lucky
  changes, Ram accepts), 13 (HR Admin).


## 14 October 2026: production safeguards (migration 45, open item 40), local stack

Veda, after Release 4: "when in production and in real time can such thing happen and not recorded? … ok go ahead".
The go-live checklist: `docs/PRODUCTION_SAFEGUARDS.md`. **Nothing of it is on staging** (it waits for Veda's say-so).

Ran:
- `supabase/migrations/20261020000100_production_safeguards.sql`: `change_log` (21 tables, `app.log_change`,
  `app.change_path`, `app.verify_change_log`), `corrections` (`request_correction`, `decide_correction`,
  `open_correction`, `close_correction`, `owner_correction`), `ledger_head`, `anchor_check`, `safeguards_report`,
  `practice_note_15oct`, the ledger's truncate guard.
- **Database**: `tests/run_local.sh`: **1,611** `ok` lines, **ALL TESTS PASSED**, fresh and on the upgrade path, with
  four sessions at once. New `tests/39_production_safeguards.sql` (**63 checks**) with **17 controls**: 17 of 17
  caught; the controls of tests 35–38 still 16/16, 15/15, 11/11, 17/17. A first run found a fault of the migration,
  fixed before this one: the change log had its own lock, and four sessions that saved lots and verified farmers at
  once took the two locks in either order and deadlocked (`tests/concurrency`); the change log now waits for the
  ledger's lock, and the concurrency test also checks the change log's chain. The timing check: incoming list 8 ms.
- **API with real logins**: `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **350 passed** (new `web/tests/safeguards.test.ts`, 4; the menus; `vercel.json` may now hold `git`, and
  holds exactly "do not build the branch ledger-anchors").
- **Screens**: default suite **72 passed** (15.0 min) with the new `phase17` at 527 px (the admin's page: the log
  intact, how changes came, ten changes behind the app then the rest, the fingerprints; a correction asked with a reason,
  not approvable by the asker; a Client Manager refused, no menu entry; the HR Admin approves, a refusal needs a reason).
  Production build **14 passed**; the first day from nothing **1 passed**, after a fix: emptying the practice system
  truncates every table, and the ledger and change log now refuse truncate; `empty_staging.sql` sets those two guards
  aside for that one statement, as it already did for the audit log, and reports them back on (K93). Screenshots
  looked at, 527 and 1366 px; the list of changes behind the app was shortened to ten at first after the first look (on a
  phone it pushed the corrections out of sight).
- **The daily outside copy**: `scripts/anchor_ledger.mjs` against the local stack: first run adds the line; second run
  "2 earlier fingerprints still match", nothing added; a copy changed by hand: `ANCHOR MISMATCH`, exit 1; not set up:
  skipped. The GitHub job's branch handling on a local repository, three days: the branch `ledger-anchors` holds only
  `staging.csv`, three commits, main untouched. GitHub Actions itself not run.
- **`scripts/staging_safeguards.ps1`** (`staging-safeguards.cmd`) on stand-ins: the run (S1b adds the correcting block;
  "statement logging" listed as a set-up row, not stopping; S3 installs the job and commits it); a second run
  ("explained already"); wrong words; another migration waiting; the safeguards not in place after the push; a failed
  push; the correcting block failing; production; functions not current; a smoke row not OK; a changed migration; a
  changed app file. `staging-rules-and-ids.cmd` and the earlier scripts now refuse. Sealed: 124 files.

NOT run / not known: nothing of it on staging; GitHub Actions; pgaudit (not on this machine); Windows PowerShell 5.1;
about 50 new Hindi strings unread by their users.
- **On staging** 14 Oct 10:15 IST: `staging-safeguards.cmd` `RESULT: SAFEGUARDS ON STAGING` (head 5c75525, 31 files, among
  them `.github/workflows/ledger-anchor.yml`; migration 45 alone waiting and pushed; S1b: block 29 explained, correction
  40e098ae…, signed by the admin; smoke 41 of 42, `statement logging` NOT SET (a go-live step, standing); the safeguards
  in place and the change log intact (0 lines: nothing had changed yet); corrections 1; two-person approval off; ledger
  audit NO FINDINGS (34 blocks); logins and functions as before). The summary's "ledger_head=9" is wrong: the script's
  query sorted the block number as text (9 after 34); the Safeguards page's own `app.ledger_head()` sorts numbers.
  Fixed in the next release script. Not checked yet: Vercel built 5c75525 (Chrome could not be reached), the GitHub
  variables and the first run of the daily copy, the run-sheet checks in the app.
- **The daily copy set up** (14 Oct, at Veda's word, in her Chrome): GitHub repository variables `GV_STAGING_URL` and
  `GV_STAGING_ANON_KEY` (the public key, copied with Supabase's Copy button, never typed; its token says role "anon");
  Actions → "ledger anchor" → Run workflow: **Success** (17 s); the branch `ledger-anchors` holds `staging.csv` with
  ledger block #34 and change-log line #10. Found: Vercel tried to build the new branch (a preview, "Error", 1 s): it
  reads `git.deploymentEnabled` from the branch it builds, and `web/vercel.json` of main does not reach it. Fixed with
  Veda's yes: commit 7180b72 on `ledger-anchors` only adds `web/vercel.json` = never build this branch; Vercel made no
  deployment for it. The job's template now writes that file itself when the branch is new (for production);
  simulated on a local repository. The app as Lucky: no Safeguards entry; the page refuses him.


## 14 October 2026: HR requirements and staffing a scope (migration 46, open item 41), local stack

Veda's brief "GrainVeda MVP — HR requirements list and staffing a scope" (it replaces section B of the follow-up brief).

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,679 ok** (was 1,611), with the upgrade path, the production
  build and four sessions at once. New `tests/40_requirements.sql`: **68 checks** (lines raised by the People step and
  not before; closed "filled from the pool" and withdrawn when the chain or the scope changes; a client with no Client
  Manager in the State Manager's name; by hand, refused for the wrong person, stage, number or date; HR's figure, her
  states only, the HR Admin all; return, answer, publish in one act as one group with a correction logged, decline,
  hold, every status in the Audit log; Joining and Ready to assign with names; ready people first in the pool; a
  multi-stage opening; two stages in a row allowed, warned, verified by its maker, marked in both ledgers, on the public
  page and in the counts). **17 controls**, each caught. Older tests updated: the API allowlist (nine functions), the
  public page's keys (`same_person`), the change-log trigger count (21 → at least 21).
- **API with real logins**: `remote_create_user.mjs` **95 passed**; `remote_rls.mjs --t1` **192 passed**.
- **Unit**: **359 passed** (new `web/tests/requirements.test.ts`, 9; the menus: Requirements first for HR).
- **Screens**: default suite **74 passed** (16.2 min) with `phase18` at 527 px: brief F (a reopened draft reaches step 4
  and is activated by clicks; the Roster offers Activate) and A–E end to end (Save People step → five Requested lines;
  Procurement and Packing to one person, then QC next to Procurement: the warning in the brief's words; Request people;
  HR's badge and figure; return with a question, the answer, publish the scope in one act as one opening of three
  stages "From requirement by Prasaadam Client Manager"; a new opening from a scope for two stages, "Created by HR";
  decline with a reason; the State Manager's open requirements). Three older screens updated: the two-stages warning's
  new words (phase8), the ledger export's two new columns (phase9), the pool's "ready for" mark (phase11). Production
  build **14 passed**; the first day from nothing **1 passed**. Screenshots looked at, 527 and 1366 px: "Save People
  step" was shown when every empty stage was already asked for; now only when one is not.
- **`scripts/staging_requirements.ps1`** (`staging-requirements.cmd`) on stand-ins: the run (S1b reads back what the
  migration raised; smoke 42 of 43 with `statement logging` standing; S3 42 files); a second run; wrong words; another
  migration waiting; the requirements not in place after the push; a failed push; the read-back failing; production;
  functions not current; a smoke row not OK; a changed migration; a changed app file. `staging-safeguards.cmd` and the
  earlier scripts now refuse. Sealed: 129 files.

NOT run / not known: nothing of it on staging; the 400 Veda saw on staging when a reopened draft was saved (brief F) was
not reproduced locally: the wizard now shows the server's words, so the run sheet's step 12 will show it if it comes
back; the ledger's "same person, next stage" mark is tested in the database and the export, not by a screen test;
about 85 new Hindi strings unread by their users; Windows PowerShell 5.1.
- **On staging** 14 Oct 17:34 IST: `staging-requirements.cmd` `RESULT: REQUIREMENTS ON STAGING` (head 4a70907, 42 files;
  smoke 42 of 43, `statement logging` standing; S1b `scopes=0 clients=1 requested_lines=1`: no scope being set up had an
  empty stage; KH26 gkp is fully staffed (p on Procurement, Lucky on the other six), so it raised no lines, as designed;
  one Client Manager line for a client without one). The summary's `ledger_head=9` was again the text sort of the
  number (34 blocks): fixed in the next script (`max(seq)`). In the app (browser pane, as Lucky): the new build live;
  KH26 gkp's Roster "Every stage has someone", Activate, "People asked from HR: nothing is asked". p's home and menu
  right once the scope was active. p's lot for TCUP-F-0001: "The database will refuse this: good farming practice not
  complete … GAP 1, gap 2", and nothing let p fill it in: open item 42.

## 14 October 2026, evening: farmer corrections (migration 47, open item 42), local stack

Veda: "give access to Good farming practice section only. also if other details need omission then if p does it it
should go to lucky for verification"; then "count at once" and "propose; Lucky approves".

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,705 ok**. New `tests/41_farmer_proposals.sql`: **26 checks**
  (a lot refused without the required practice; Procurement answers it and the lot is saved; QC cannot; a correction
  proposed with only what differs and the values it replaces; nothing changes until approved; refused without a reason,
  for the status, for bad acres, by the CM himself, by QC, by another client's operator; the CM reads and approves: made
  in his name, "proposed by …" in the farmer's history; GI land then waits for the State Manager; refused with a reason;
  withdrawn by its own proposer only; every step in the Audit log). **10 controls**, each caught.
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. **Unit**: 361 passed (new
  `farmer_proposals.test.ts`, 2).
- **Screens**: default suite **75 passed** (17.8 min) with the new `phase19` at 527 px (the refused lot links to the
  practice; answered, the lot is saved; a correction proposed from the Farmers list, not approvable by p; the Client
  Manager approves it on his Farmers page). Production build 14 passed; the first day from nothing 1 passed.
- **`scripts/staging_farmer_corrections.ps1`** on stand-ins: the run, a second run, and the ten refusals as before;
  `staging-requirements.cmd` and the earlier scripts now refuse. Sealed: 131 files.

NOT run / not known: nothing of it on staging; about 30 new Hindi strings unread by their users.
- **On staging** 15 Oct (IST): `staging-farmer-corrections.cmd` `RESULT: FARMER CORRECTIONS ON STAGING` (head c2b852e;
  smoke 43 of 44, `statement logging` standing; S1b `crops_with_required_practice=1 active_farmers=2
  farmers_with_practice=1 proposals=0`; `ledger_head=79`, the newest block's number at last; ledger audit 79 blocks, 10
  records, 2 seals, no findings). The run sheet in the app (Claude in the browser pane after each signed in): p's lot
  for TCUP-F-0001 refused for GAP 1 and gap 2 with the link; practice answered; lot `TCUP-KNM-KH26-P-0004` saved; a
  correction proposed by p and approved by Lucky (in Lucky's name, "proposed by p: …" in the history); the lot verified
  at Milling. Seen there and held for the next release: a blank line in the farmer's history (p's lot) and every time
  in UTC in the browser pane (item 43).

## 15 October 2026: the operator template, release 1 (migration 48, open item 43), local stack

Veda: "yes but with this i have one more prompt / combine both" (the operator-stages brief with D3–D5), "share again
before building", then "ok complete everything" (decision G19: nine releases, the recommendations for the Owner-decides
items).

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,752 ok**. New `tests/42_operator_template.sql`: **47 checks**
  (short codes from place names, unique, fixed once used, in every new record number; "On" today by default, never
  ahead, 31 days back at most, before its source refused, corrected by the sender; a manager at a stage he does not hold
  refused without 10 characters, then "supervisory" with the reason; return to sender: 10 characters, once at a time,
  never by its own maker or a later stage, nobody verifies it while open, the sender's correction or withdrawal closes
  it, "return" blocks; a manager's verification with a reason; a condition = verified + an open condition, in the block;
  the client's ledger for its Client Manager only, the return's reason as its note; the farmer's history: practice
  answered and lots, no blank line; "Needs my action" for the sender, QC and the Client Manager). **15 controls**, each
  caught. Tests 02, 05, 07, 14 now expect the scope in record numbers; 08 the six new functions.
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. **Unit**: 374 passed (new
  `operator_template.test.ts`, 13: plain words in both languages, never the database's inside words; IST on screen
  and in exports; "Needs my action" lines; the Client Manager's menu; the farmer's history lines; the date bounds).
- **Screens**: default suite **76 passed** (17.3 min) with the new `phase20` at 527 px (a lot "on" yesterday numbered
  `…-SDR-P-…`; QC returns it with a reason; the sender sees it first at home, corrects it; QC verifies with a condition;
  the Client Manager's menu, "Needs my action", his client's ledger with the reason; his own record at Procurement only
  with his reason; the farmer's history named). Production build 14 passed; the first day from nothing 1 passed.
  Ten screen tests adapted to the new words (record numbers with the scope, the CSV headers, the gate's message, the
  Client Manager's menu and ledger).
- **`scripts/staging_operator_template.ps1`** on stand-ins: the run, a second run, and eleven refusals (wrong words,
  another migration waiting, rule not in place, push fails, read-back fails, a scope without a short code, production,
  functions not current, a smoke row not OK, a changed migration, a changed app file); the earlier scripts now refuse.
  Sealed: 134 files.

NOT run / not known: nothing of it on staging; the staging scopes' short codes are what S1b prints (gkp → GKP and
Bansi → BNS expected); about 150 new Hindi strings unread by their users; a manager who verifies at a stage he does not
hold is refused by the old app for the minute between S1 and S3.

## 15 October 2026: numbers you can trust and packs, proof and blocks, releases 2 and 3 (migrations 49 and 50, open items 44 and 45), local stack

Veda: "ok complete everything" (decision G19). Built after release 1 and delivered with it as **one** release script
(`staging-packs-release.cmd`), which pushes whatever of 48, 49 and 50 is waiting, in order.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,794 ok** on the fresh build; production build (no demo data;
  the demo seed refuses); **upgrade path** (migrations 1–30 with the demo data, then 31–50 one transaction each, then
  all 44 test files again) passed; concurrency passed. New `tests/43_trust_numbers.sql` (**24 checks, 13 controls**,
  each caught) and `tests/44_packs_and_release.sql` (**34 checks, 23 controls**, each caught: the batch code the
  system's and kept, the preview without one, packs and their voids, best-before, reprint and void reasons, "not yet
  released", scans counted, the summary before release, recall by the CM only, with a reason, final, on every pack, the
  delivery's bounds and loss, the lab report's fields, date and number, the file before verification (a photo only when
  named the lab report), GI and non-GI kept apart, the acceptance before an export release, no farmer name in public,
  the lab-report setting fixed after activation). Tests 01, 02, 05, 07, 08, 12, 15, 19, 35, 36, 42 adapted.
- **Two faults found and fixed with a test that failed first**: (1) `release_events` ordered by time and a random id:
  a seal and a recall in one transaction could read back "active" (test 44 failed once, then the `seq` column);
  (2) the packing preview still asked for the batch code the form no longer has (a test of the preview failed, then
  passed). **One fault from release 1**: `tests/remote_ledger_audit.sql` had no line for `return` blocks and called a
  sender's own withdrawal "without its block"; on data committed by tests 42 and 44 the old audit reported 5 + 1 (and a
  `delivery` block), the new one none.
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed (the public journey now checked for the
  village, not the name). `scripts/restore_drill.mjs`: RESTORE DRILL PASSED.
- **Unit**: 418 passed (new `trust_numbers.test.ts` 8, `packs_release.test.ts` 36: every release-summary line and
  refusal in both languages, each refusal of the migration's new functions has its plain words, the lab report fields
  by the scope's setting, label sheets, no farmer's name on the public page).
- **Screens**: default suite **79 passed** (18.5 min) with `phase21` and `phase22` at 527 px (`phase22`: the batch code
  from the system, 158 serials, labels 1–120 then 121–158, a reprint with a reason, a pack voided; a pack scanned
  before release; the shipment without transit loss and the delivery with its proof (refused without it); the summary
  before release, the seal waiting for it; the pack page after release, no farmer's name; the Client Manager's recall
  on every pack, in Hindi too; an export release waiting for the client's acceptance). Production build 14 passed;
  the first day from nothing 1 passed (its lab now names its report and attaches it). Screens looked at at 527 px:
  the pack page, the labels sheet, the packs, delivery and release panels.
- **`scripts/staging_packs_release.ps1`** on stand-ins, 21 scenarios: 48+49+50, 49+50 and 50 alone waiting each run
  through to `RESULT: PACKS AND RELEASE ON STAGING`; a second run; refused: 48 and 50 without 49, 48 alone, another
  migration, wrong words, rule not in place, push fails, read-back fails, a scope without a short code, a record without
  its link, a seal without a release status, production, functions not current, a smoke row not OK, a changed
  migration (48 or 50), a changed app file; the earlier scripts now refuse. Sealed: 139 files.

NOT run / not known: nothing of 48–50 on staging; about 250 new Hindi strings unread by their users; real label
printing on a real printer (the sheet is the browser's print of an A4 grid); the staging gkp scope asks for the lab
report from now on (a scope made before keeps the default, which is to ask).


## 15 October 2026, evening: set-up lists, release 4 (migration 51, open item 46), local stack

Veda: "ok complete everything" (G19), the brief pasted again ("kindly check for 1 … 2- yes, 3- ok ill do, 4- ok ill
see"). Releases 1–3 are on staging (15 Oct 17:01, b3ce4d8); `staging-setup-lists.cmd` expects only migration 51.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,875 ok** on the fresh build; production build (no demo data;
  the demo seed refuses); **upgrade path** (migrations 1–30 with the demo data, then 31–51 one transaction each, then
  all 45 test files again) passed; concurrency passed. New `tests/45_setup_lists.sql` (**65 checks, 26 controls**, each
  caught: the state list for a state made later, districts from the list only, who adds a place, who added a list row,
  never moved, the library's params and limits, who keeps a profile, activation only with its source, one draft, the
  old version retired, the audit line, no GI area without a GI number, a crop of before not refused, the reference
  photo, the farm GPS and the listed district at step 1, the farmers of before not refused, GI area, the GPS check, the
  ledger banner, work elsewhere in the pool, the state's count, the carried profiles of a removed crop, a crop with
  documents in use, the GPS through the one door). Tests 08, 09, 14, 24, 28, 35, 37, 38 adapted (the new API
  functions; GPS on the farmers they verify).
- **Faults found and fixed with a test that failed first**: (1) a crop added by mistake could not be removed once it
  had its carried market profiles (`tests/36` failed on the foreign key); the carried profiles now go with it, and a
  crop with documents or profiles of its own is in use. (2) Found in review, before release: a crop of before with GI
  districts and no GI number would have been refused for any change; the rule now asks only when the GI number or area
  changes (test and control added).
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. `scripts/restore_drill.mjs`:
  RESTORE DRILL PASSED, now with the reference files (1/1 re-hashed; a damaged copy makes it fail: control run).
  `scripts/backup.mjs` and `restore_evidence.mjs` copy and put back the `reference` store.
- **Smoke check**: the new row `setup lists` (48 rows): MISSING on a database at migration 50, OK at 51, NOT OK with the
  library emptied or a crop's Domestic profile removed (controls run).
- **Unit**: 463 passed (new `setup_lists.test.ts` 45: the GPS box, places, list shapes and every word of them, market
  profile rules, shelf life, the banner, the pool, 30 refusals in plain English and Hindi; four controls each caught).
- **Screens**: default suite 82 tests: **78 passed** in the full run; the 4 that failed picked a person in the roster
  pool by the option's whole text, which now carries the person's work on other scopes: they pick by the name the
  option starts with (`pickFromPool`), and the 4 files (phase1, phase4, phase18, phase23: 20 tests) **passed** on a
  rebuilt stack. Production build 14 passed; the first day from nothing 1 passed (its farmer picked from the state's
  district list, with GPS). New `phase23` at 527 px: the Client Manager's lists (GPS pasted, a buyer in India refused
  without GSTIN, a pack retired), the State Manager reads them and changes none; a lab, the library, a market profile
  activated only with its PDF, then version 2 while 1 stays in use; shelf life per material; Needs my action → the
  farmers without GPS; a farmer from the district list with a new block (added to the list) and the GPS pasted, Save
  and verify waiting for it; the banner's count growing; the GPS check at step 2; the State Manager's count; the
  roster pool's groups and the soft note. Seven farmer forms in the older tests now pick the district and give the GPS.
  Screens looked at at 390 and 1366 px: the lists, the list form, the farmer form, the roster, the profiles, places,
  the crop form, both home screens. One layout fault found that way and fixed: a long pool line widened the roster
  page on a phone (the slot grid now shrinks).
- **`scripts/staging_setup_lists.ps1`** on stand-ins, 17 scenarios: 51 waiting runs through to `RESULT: SET-UP LISTS ON
  STAGING`; a second run; refused: 50 and 51 waiting, 50 alone, another migration, wrong words, rule not in place, push
  fails, read-back fails, a crop without its profiles, the library empty, production, functions not current, a smoke
  row not OK, a changed migration, a changed smoke check, a changed app file; the earlier scripts now refuse. Sealed:
  143 files.

NOT run / not known: nothing of 51 on staging; about 245 new Hindi strings unread by their users (K95); only Uttar
Pradesh's districts are loaded and the GPS check is against the district's other farms, not its boundary (K96); the
phone's "Use where I am now" was not tried on a real phone outdoors (the e2e types the numbers).

## 15 October 2026, night: Procurement and Collection Batch, release 5 (migration 52, open item 47), local stack

Veda: "ok great proceed" (G19), after the release-4 checks on staging. Release 4 is on staging (15 Oct 19:54,
544b45d); `staging-procurement-batch.cmd` expects only migration 52.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,881 ok** on the fresh build; production build; **upgrade
  path** (1–30 with demo data, then 31–52 one transaction each, then all test files again); concurrency. New
  `tests/46_procurement_batch.sql` (**47 checks, 26 controls**, each caught: where / GPS / who delivered asked only
  where the scope says so, a point of another client or retired, GPS abroad, an agent unnamed, the condition, the
  moisture warnings, the point's name on the lot, price and payment out of the record and its ledger block, kept in
  `lot_payments` and read only by the recorder and the Client Manager (and not by the next stages or another client),
  paid later only by them, a transaction ID never an account number, only the Client Manager turns price recording on
  (also on an active scope), the farmer card, two collection points in a batch refused, single origin, re-weighed above
  the lots, the loss, the villages and the distinct farmers from the lots, the weighted moisture, the journey forward
  and who may read it, the library's second names). Tests 01, 08 and 36 adapted (where/GPS/who on the helper's lots;
  the four new API functions).
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. `scripts/restore_drill.mjs`: RESTORE
  DRILL PASSED.
- **Smoke check**: the new row `procurement batch` (49 rows): MISSING before 52, OK after.
- **Unit**: 480 passed (new `procurement_batch.test.ts`: the form's fields by the scope's settings, the GPS in the
  record, the offline mirror refusing what the save refuses in the save's own words (where / GPS / who, agent,
  condition, moisture warnings, price and payment), the Collection Batch worked out on the phone (one place, villages
  and shares, single origin, loss, GI mix, a lot the phone does not know), 27 messages in plain English and Hindi,
  how the new values read, Places on the person's own state). `phase3.test.ts` holds the procurement mirror too.
- **Screens**: default suite 84 tests: **81 passed** in the full run; the 3 that failed (phase6: the form now has two
  more section headings; phase7 and phase14: a scope made in the test asks where / GPS / who, the test did not give
  them) were adapted and **passed** (10 tests) on a rebuilt stack. Production build 14 passed; the first day from
  nothing 1 passed (its lot now says where it was weighed). New `phase24` at 527 px: the Client Manager turns both
  settings on for an active scope; a lot at a collection point with the farmer card, the GPS typed key by key (not
  split until the box is left), an agent, a UPI payment (the transaction ID and the agent asked in plain words), the
  receipt; a second lot paid later in cash; the Collection Batch person reads no payment; with no network, two places
  refused at once, the batch of one place worked out on the phone (villages, loss warning), saved on the phone and
  sent when the network is back; the journey forward on the record and the trace. `phase2` (Collection Batch, no
  village typed), `phase23` (GPS split on leaving the box) adapted. Screens looked at at 527 px: the scope's settings,
  Places (opens on Uttar Pradesh for the Client Manager), the farm-gate form, the receipt, the batch picker. One
  wording fault found that way and fixed: the farmer card said "GI land — acres … of — kg expected" for a farmer with
  no GI land recorded.
- **`scripts/staging_procurement_batch.ps1`** on stand-ins, 18 scenarios: 52 waiting runs through to `RESULT:
  PROCUREMENT AND BATCH ON STAGING`; a second run; refused: 51 and 52 waiting, 51 alone, another migration, wrong
  words, rule not in place, push fails, read-back fails, a scope already recording prices, a payment already there,
  the old batch form, production, functions not current, a smoke row not OK, a changed migration, a changed smoke
  check, a changed app file; the earlier scripts now refuse. Its read-back queries run on a migrated local database.
  Sealed: 146 files.

NOT run / not known: nothing of 52 on staging; about 110 new Hindi strings unread by their users; the phone's own GPS
taken when the form opens was not tried on a real phone (the e2e types the numbers); the receipt is on screen and
printed from the browser (no PDF of its own); a receipt for a lot still waiting on the phone appears only once it is
sent.

## 15 October 2026, 22:43 IST: the first staging run of release 5 stopped; migration 52b

- **Staging**: `staging-procurement-batch.cmd` pushed migration 52 (S1b: scopes=3, asking_where=3, recording_price=0,
  library=12, library_second_names=1, payments=0, batch_form=new) and **stopped at S2**: smoke row `public page data` =
  OPEN. Nothing else was changed; the app was not pushed. Record:
  `release-evidence\staging-procurement-batch-20261015-224334.log`.
- **Cause**: migration 52 had the public page read a Collection Batch's villages from `computed.villages`; the smoke rule
  of migration 28 asks that `app.public_lot_journey` reads nothing of `computed` (where a buyer's name is). Only village
  names were read, but the rule stands. **Why the tests missed it**: the smoke check was run locally only for its new
  row (the run's other rows were not read), and the release rehearsal's stand-in answers every row OK.
- **Fix**: migration 52b (`20261027000200_public_batch_villages`): `app.batch_villages` (village names only, closed to
  the API); the public page calls it. Test 46 §8 (3 checks; 2 controls, caught). `tests/run_local.sh` now runs the
  smoke check on the fresh build and fails on any row not OK but the standing ones (statement logging, reminder round,
  nightly ledger check, and the local login shim's auth.uid mapping).
- **Re-run**: all DB tests 1,884 ok; controls 28/28; `run_local.sh` ALL TESTS PASSED with the smoke step "every row OK
  but the standing ones"; e2e phase2 (the public page counts the batch's farmers and names its villages), phase22,
  phase24: 7 passed. The script now expects 52b waiting (52 on staging), or both in order; rehearsed in 21 scenarios.
  No app file changed (the sealed list stands, 146 files).

## 15 October 2026, 22:55 IST: release 5 on staging, and its checks

- `RESULT: PROCUREMENT AND BATCH ON STAGING` (migration 52b pushed, 52 already there; app a231413, Vercel Ready).
  Smoke 48/49 (statement logging); change log intact; ledger audit NO FINDINGS (131 blocks, 24 records, 3 seals).
- Run-sheet checks in KH26 Bansi (Lucky signed in by Veda; Claude in Chrome): all passed (see FIX_LIST item 47).
  Practice records: TCUP-KNM-KH26-BNS-P-0001 (UPI, receipt), P-0002 (cash, paid later), VB-0001 (247 kg).
- Found: the menu line "Collection Batch (one collection point)" overlaps the next one on a laptop; `app.norm_place`
  merges villages that differ only by a number. Not tried on staging: two places in one batch, airplane mode (both in
  `e2e/phase24`).

## 16 October 2026, early: Milling, Quality Control and Packing, release 6 (migration 53, open item 48), local stack

Veda: "ok proceed ahead with release 53" (G19), after the release-5 checks on staging. Release 5 is on staging (15 Oct
22:55, a231413); `staging-milling-qc-packing.cmd` expects only migration 53.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED, 1,974 ok** on the fresh build; the smoke check on the fresh
  build (every row OK but the standing ones); production build; **upgrade path** (1–30 with demo data, then 31–53, then
  all 47 test files again: it first failed because seed 01's new "pack count per size" check needs the physical checks
  of migration 49; the seed now skips it on a database from before); concurrency. New
  `tests/47_milling_qc_packing.sql` (**65 checks, 32 controls**, each caught): the scope's settings; the sample drawn
  first (who, when, how much, the state's lab, the counter-sample, a buyer's sample, keep-until, disposal); the lab
  record on the sample (once; results in; superseded back), a lab test never in-house, a verdict per market of the
  scope, the export release naming who accepted it; Milling (the client's mill, the operator, the line clearance,
  "dedicated", the outputs never more than the paddy, recovery from head rice and broken, sent vs received, the mill's
  own range); Packing (the unit, packs from the list keeping their size, the wastage worked out and its reason,
  best-before by material, the net weight check before verification, a short pack fails); closing a lot with 2 % or
  less left; the public page's markets. Tests 08, 19 and 36 adapted.
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. `scripts/restore_drill.mjs`: RESTORE
  DRILL PASSED.
- **Smoke check**: the new row `milling qc packing` (50 rows): MISSING before 53, OK after.
- **Unit**: 513 passed (new `milling_qc_packing.test.ts`, 33: the three forms by the scope's setting, the packs from the
  list in the record, the order and words of the worked-out values, plain words for every refusal the migration raises
  for these stages (read from the migration's text) and the two warnings, every new word in English and Hindi, the
  panels and the scope's settings wired, the public page reading no `computed`, the menu fix).
- **Screens**: default suite 85 tests: **83 passed** in the full run; the 2 that failed (phase1, t3_t5: "Domestic
  Pass" now also in the markets line) were adapted and passed on a rebuilt stack. Before that, phase22 (an export
  release on the demo scope, which asks no stage details: the client's names were required by the screen; now only
  where the scope asks) and phase5 (a lot captured three hours back across midnight, India time: a test fault, fixed in
  the test) were fixed and passed. Production build 14 passed; the first day from nothing 1 passed (its scope unticks
  the stage details). New `phase25` at 527 px: the Client Manager ticks the stage details on an active scope; the lab
  on the state's list, the mill, packing unit and packs on the client's; QC verifies the lot and draws the sample (sent
  to the lab, awaiting results), records the results on it (results in), a verdict per market; Milling with the mill,
  line clearance and operator, head rice, broken, husk and bran (loss 3 kg, recovery 68.06 %); the 3 kg left of the lab
  lot closed as floor loss; Packing from the pack list (wastage worked out); the net weight check failed by one short
  pack, passed when weighed again; Commercial verifies after counting the packs per size. Screens looked at at 527 px:
  the scope's settings, the sample form on the QC screen, the lab record's markets line, the milling form, the packing
  record with the net weight check. One wording fault found that way and fixed: two lines both said "Wastage" (the
  share is now "Wastage share").
- **`scripts/staging_milling_qc_packing.ps1`** on stand-ins, 18 scenarios: 53 waiting runs through to `RESULT: MILLING
  QC PACKING ON STAGING`; a second run; refused: 52b and 53 waiting, 52b alone, another migration, wrong words, rule
  not in place, push fails, read-back fails, an old form, a sample already there, production, functions not current, a
  smoke row not OK, a changed migration, a changed smoke check, a changed or a new app file; the earlier scripts now
  refuse. Its read-back queries run on a migrated local database. Sealed: 148 files.
- **Not done**: the brief's deferred items (broken rice as its own lot, variety in the mill's range, the buyer's
  specification in QC, telling the State Manager of an export release, a counter-sample photo); the net weight check on
  a real scale.

## 16 October 2026, 00:59 IST: release 6 on staging

`staging-milling-qc-packing.cmd` (Veda): **`RESULT: MILLING QC PACKING ON STAGING`**, head **a49f01e** (44 files),
Vercel Ready (Production) within minutes. S0 tested files (148 app and function files), only migration 53 waiting,
functions current; S1 53 pushed; S1b `scopes=3 asking_details=3 markets=3 milling_form=new qc_form=new
packing_form=new samples=0 market_verdicts=0 closed_lots=0 weight_checks=0`; S2 smoke 49 of 50 OK (standing: statement
logging), the new rules in place, change log intact (46 tables), `samples=0 payments=2 packs=344 change_log_lines=1027
ledger_head=138`, ledger audit NO FINDINGS (138 blocks, 27 records, 3 seals), NO LOGIN WITHOUT A PERSON, FUNCTIONS
DEPLOYED AND CURRENT. Record: `release-evidence\staging-milling-qc-packing-20261016-005946.log` on Veda's machine.
Next: the run sheet's Afterwards.

## 16 October 2026, 01:00–01:40 IST: release 6 run-sheet checks on staging (KH26 Bansi)

Lucky (Client Manager, holds every stage of KH26 Bansi) and Ram (State Manager) signed in by Veda; Claude drove the
steps in Chrome, practice data only.

- Menu at 1366 px: "Collection Batch (one collection point)" 48 px high (two lines), no overlap with the next line.
- Scope page: "Milling, Quality Control and Packing" card; details on; Domestic and Export ticked; Practice EU (test)
  ticked, still ticked after a reload.
- Set-up lists (Lucky): Practice mill (test), Practice packing (test), packs 1 kg and 500 g pouch. Labs (Ram): UP's
  Practice lab (test) was retired (release-4 checks); brought back. The sample form had rightly not offered it.
- Milling: VB-0001 verified; M-0001 recorded: mill, fully cleaned (empty first: "Say how the line was cleared (the
  mill is not dedicated to this crop)."), operator, 243 kg in, 150 / 12 / 60 / 18 out; loss 3 kg, recovery 66.67 %,
  head-rice share 61.73 %; 150 kg forward. VB-0001 then offered "4 kg is left of this lot"; closed, 4 kg floor loss.
- Quality Control: M-0001 verified; sample M-0001-S1 drawn on the QC screen (1 kg, Practice lab, seal CS-TEST-1, QC
  shelf, kept until 16 Oct 2027): "sent to the lab, awaiting results". QC-0001 on that sample (no typed sample or lab
  name), moisture 12.5, aflatoxin 1.5, the practice report PDF attached by Veda: 149 kg forward; "By market: Domestic
  PASS · Export (general) PASS · Practice EU (test) PASS"; the sample then "results in (QC-0001)".
- Packing: QC-0001 verified; PK-0001 from the pack list, 100 × 1 kg + 90 × 500 g = 145 kg; the wastage 2.7 % asked a
  reason in plain words, then saved with the warning; batch B0001 with its serials.
- Commercial before the check: "Weigh the packs the system picked (net weight check) before this record is verified."
  Net weight: 5 packs picked; one 500 g pack at 460 g: Failed; weighed again: Passed. Commercial then verified,
  ticking "Pack count per size matches the packing record".
- Found (for release 54): the Collection Batch system check "✗ Village named" (looks for the old typed village);
  "Yield" shown beside "Recovery (head + broken)" on a new milling record; on the QC form a market profile's test with
  no crop limit reads "domestic <= undefined · export <= undefined".

## 16 October 2026, morning: Commercial and Shipment, release 7 (migration 54, open item 49), local stack

Veda: "continue with release 54" (G19), with her four points on release 6's checks (villages from the list; the
Collection Batch's collection point; the farmer from a list; labs kept on GrainVeda's side, the client's too) and her
answers ("Client Manager too", "List only", "Village, then farmer"). Release 6 is on staging (16 Oct 00:59, a49f01e);
`staging-commercial-shipment.cmd` expects only migration 54.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED** (2,048 checks on the fresh build; the smoke check on the fresh
  build, every row OK but the standing ones; production build; **upgrade path**, all 48 test files again: it first
  failed because seed 01's new Commercial hand-off check needs migration 49's column; the seed now skips it on a
  database from before; concurrency). Every test file on a migrated copy: 2,023 checks, no failure. New
  `tests/48_commercial_shipment.sql` (**74 checks, 40 controls**, each caught; one control first missed: a pack code
  of another batch was refused only because it did not exist, so a real pack of another batch was added): client labs
  (who keeps them, their state, never moved, the lab for a scope); villages from the list at step 1 (a state with no
  list as before); the Collection Batch's point (only its lots; required where the details are asked); the chain to
  packs with profiles and their limits on the QC form; Commercial (the buyer from the list, the order number, an export
  market the batch passed, the destination, packs by type from what is left, the price kept out of the record and the
  ledger, the total value, who reads it); export documents (received with a file, not required with why, only the
  market's, only Commercial or a manager); Shipment (partial shipments, the domestic papers, the export papers, pack
  codes of the batch once each, the loading photo before verification, the bill of lading once); the old path. Tests
  08, 45 and 47 adapted. The ledger audit knows the new `bill_of_lading` block (a control without that line reports it).
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. `scripts/restore_drill.mjs`: RESTORE
  DRILL PASSED.
- **Smoke check**: the new row `commercial shipment` (51 rows): MISSING before 54, OK after.
- **Unit**: 576 passed (new `commercial_shipment.test.tsx`, 63: the Commercial and Shipment forms by the scope's setting
  and by the lot (its market, its packs), the packs and pack codes in the record, the worked-out values in order and in
  words, the market profile's limits on the lab form, the batch's point offline in the save's words, the farmer by
  village, villages on the list, the labs, plain words for every new refusal checked against the migration's own
  sentences (with a control), every new word in English and Hindi). `setup_lists.test.ts` now holds that the farmer
  form never adds a place.
- **Screens**: default suite 87 tests: **82 passed** in the full run; 5 failed on the farmer picker the tests still
  waited for (phase3 ×2, phase5 ×2: "the list is loaded" read the old button; phase26: the village list read before it
  filled). Fixed in the tests and run again on a rebuilt stack: 16 of 17 passed; the one left (phase3 "Dashboards")
  needs the sealed lots the earlier files make and passed in the full run. Production build 14 passed; the first day
  from nothing 1 passed (the Client Manager adds the farmer's village in Places first). Every spec that picks a farmer
  now picks his village, then him (`pickFarmer`). New `phase26` at 527 px (also run at 390 and 1366 px for pictures):
  a client lab added in Set-up lists and offered to QC beside the state's; farmers picked by village; a Collection
  Batch whose point offers only its lots; a domestic order of 10 × 1 kg and 4 × 500 g (12 kg, INR 1,440 kept apart);
  an export order with its four documents (one received with its file, three not required); a domestic shipment with
  the vehicle and LR; an export shipment refused with 9 codes for 10 packs, saved with 10, the loading photo, then the
  bill of lading added once. A control: with the batch's point filter taken out, phase26 fails. Pictures looked at:
  the forms and record pages at 390 px; one fault found that way and fixed: the record showed the export market's code
  beside its name.
- **`scripts/staging_commercial_shipment.ps1`** on stand-ins, 18 scenarios: 54 waiting runs through to `RESULT:
  COMMERCIAL SHIPMENT ON STAGING` (51 files committed); a second run; refused: 53 and 54 waiting, 53 alone, another
  migration, wrong words, rule not in place, push fails, read-back fails, an old form, sale terms already there,
  production, functions not current, a smoke row not OK, a changed migration, a changed smoke check, a changed or a new
  app file; the earlier scripts now refuse. Its read-back queries run on a migrated local database (and fail on one of
  release 6). Sealed: 149 files.
- **Not done**: one order from several batches; a buyer's own specification in QC; on a domestic order the export
  fields (market profile, destination) still show, empty and not asked.

## 16 October 2026, 03:56 IST: release 7 on staging

Veda ran `staging-commercial-shipment.cmd`: `RESULT: COMMERCIAL SHIPMENT ON STAGING`, head **d4efafb** (52 files),
Vercel Ready (checked on its Deployments page). S1b: `commercial_form=new shipment_form=new batch_form=new villages=3
state_labs=1 client_labs=0 draft_farmers=0 sale_terms=0 export_documents=0 bills_of_lading=0`. S2: smoke 50 of 51 OK
(not OK: `statement logging`, a go-live step); the new rules in place, the change log intact; ledger audit NO FINDINGS
(187 blocks, 39 records, 4 seals, 3 evidence files); NO LOGIN WITHOUT A PERSON; FUNCTIONS DEPLOYED AND CURRENT. The
52nd file was `Claude outputs/practice_lab_report_test.pdf` (the made-up report of release 6's checks), committed because
that folder is not git-ignored.

## 16 October 2026, 04:00–04:25 IST: release 7 run-sheet checks on staging (KH26 Bansi)

Lucky signed in by Veda; Claude drove the checks in Chrome; practice data named "(test)". Passed: Places (a block and a
village added); the farmer form's lists (not saved); a client lab offered to QC as "client's own"; buyers (one brought
back, one export buyer added); Procurement by village, then farmer (P-0003, P-0004); the Collection Batch's point and
its lots only (VB-0002); "Villages taken from the lots" at Milling; Recovery once on M-0001; CM-0001 domestic by packs
with the price apart; CM-0002 export with its document received (file attached by Veda); SH-0001 domestic papers only;
the export shipment refused without the document and with 9 codes for 10 packs; SH-0002 with 10 codes and the loading
photo (attached by Veda); the bill of lading added once. Seen: a second, unlabelled document on SH-0002 (a file put in
the form's "Documents" box too); the domestic order's form still shows the export fields, empty (known, listed).

## 16 October 2026, morning: the Warehouse, release 8 (migrations 55a and 55, open item 50), local stack

Veda: "yes proceed" (G19), to release 8 as proposed (C3 the Warehouse) and her two points on release 7's run (a domestic
order without the export fields; `Claude outputs/` git-ignored). Release 7 is on staging (16 Oct 03:56, d4efafb);
`staging-warehouse.cmd` expects only migrations 55a and 55.

- **Database**: `tests/run_local.sh` **ALL TESTS PASSED** (2,122 checks on the fresh build; the smoke check on the fresh
  build, every row OK but the standing ones; production build, now 17 stage definitions; upgrade path, all 49 test
  files again; concurrency). Every test file on a migrated copy: 2,097 checks, no failure. New `tests/49_warehouse.sql`
  (**74 checks, 31 controls**, each caught; one control first missed: "stored but not recorded" at once could not be
  told from "after 0 days" inside one transaction, so the control sets the limit below 0): where the Warehouse sits in
  a chain; a scope built with one, staffed and activated; the interval (1 to 120, its Client Manager only, the chain
  frozen); the arrival (sent, received, never more received, the reason, the condition, whole bags, the place), the
  flag above 2 % (once, in the recorder's name, with the reason), the system checks and their figures; inspections
  (who: the Warehouse or a manager, not QC, Milling or the client's viewer; the dates; what was found), due and
  overdue, in "Needs my action"; bags out (the Warehouse or the next stage, never more than came in); days in storage;
  Milling taking the stored lot; "stored but not recorded" (16 days; not for a scope with a Warehouse, not for an
  operator, not once Milling took some); the public page's days in storage (5), never the place or the reason. Test 08
  knows the two new functions.
- **API**: `remote_create_user.mjs` 95 passed; `remote_rls.mjs --t1` 192 passed. `scripts/restore_drill.mjs`: RESTORE
  DRILL PASSED.
- **Smoke check**: `stage_definitions (17)` and the new row `warehouse` (52 rows): MISSING before 55, OK after.
- **Unit**: 614 passed (new `warehouse.test.tsx`, 37: the chain the wizard builds and reads back, the form and its
  sections, what was sent opened from the lot, the hand-off words in Hindi, the worked-out values in order and words, a
  domestic order without the export fields, the record panel (days, bags, state; who may inspect or record bags out;
  an inspection that found something asks what; no more bags out than are left), "Needs my action", the public page's
  words, plain words for every refusal of the migration (checked against its own sentences)).
- **Screens**: default suite **88 passed** (in the first full run 86: T5 found phase27 had left the Grading operator on
  a second stage, so phase27 now takes its people off its scope afterwards; phase4's farmer checks waited on lists still
  loading on a busy machine, now they wait for them; both re-run and passed). Production build 14 passed; the first
  day from nothing 1 passed. New `phase27` at 527 px: the Warehouse ticked in the wizard's chain (the preview, "valid");
  two lots and their batch; the arrival 200 kg sent, 194 received: the reason asked, then saved, "flagged for the
  manager", the flag with the reason; 0 days, 4 in; an inspection "minor" refused until what was found is said; the
  Client Manager sets 1 day, "inspection due" on his home; Milling records 5 bags out (refused), then 4, and takes the
  lot: "done". `phase26` now holds that a domestic order shows no export market, country or Incoterms. Pictures looked
  at (390 px): the wizard, the form, the record, the settings, the home; one fault found that way and fixed: the system
  check said "6.000 kg, 3.00 %" (now "6 kg, 3.06 %", with a check in test 49; that change came after the screen runs and
  is covered by test 49, the controls and `run_local`, run again after it). Found while building: a link to the
  chain step put the draft back on it after "Save draft" (fixed, WH9).
- **`scripts/staging_warehouse.ps1`** on stand-ins, 22 scenarios: 55a and 55 waiting run through to `RESULT: WAREHOUSE
  ON STAGING` (the practice PDF leaves the repository, stays on disk; 43 files committed); a second run; only 55 waiting
  (a run stopped after 55a) runs through; refused: only 55a, 54 too, out of order, another migration, wrong words,
  rule not in place, push fails, read-back fails, the old stage, a scope with a Warehouse already, production,
  functions not current, a smoke row not OK, a changed 55a, 55 or smoke check, a changed or a new app file; the earlier
  scripts now refuse. Its read-back queries run on a migrated local database (and fail on one of release 7). Sealed:
  151 files.
- **Not done**: a warehouse from the client's lists (typed, with its stack); moves between warehouses; fumigation
  records (an inspection's note); "stored but not recorded" and the public page's days cannot be shown on staging
  without waiting (the tests cover them).

## 16 October 2026, 07:22 IST: release 8 on staging

`staging-warehouse.cmd`: `RESULT: WAREHOUSE ON STAGING`, head 9cfe6c9 (Vercel built it: the wizard offers the Warehouse).
S0 both migrations waiting; S1 55a then 55 pushed; S1b warehouse_stage=new commercial_form=new stages=17 scopes=4
warehouse_scopes=0 inspections=0 bags_out=0; S2 smoke 51/52 (statement logging, a go-live step), the new rules in place,
the change log intact, ledger audit NO FINDINGS (207 blocks, 46 records, 4 seals, 6 evidence files), logins and
functions current; S3 77 files: the 42 delivered and 35 files of `Claude outputs/` taken out of git (they stay on disk).
Record: `release-evidence/staging-warehouse-20261016-072234.log`.

## 16 October 2026, 07:25–07:45 IST: release 8 run-sheet checks on staging (KH26 · Practice godown (test))

Lucky signed in by Veda; Claude drove the 13 rows in Chrome at laptop width; practice data.

| # | Result |
|---|---|
| 1 | Wizard: Collection Batch, Warehouse, Milling ticked → "Procurement → Collection Batch → Warehouse → Milling → Quality Control → QR Activation", "This chain is valid" |
| 2 | Saved draft opened on People; Lucky on all six stages (the four "verifies his own records" warnings shown); activated |
| 3 | Inspection interval 1 day, kept after a reload |
| 4 | P-0001, P-0002 (farmers 1 and 2, 100 kg each, at the farm, GPS) |
| 5 | Both checked in at the Collection Batch; VB-0001 at the farm, 200 kg |
| 6 | Warehouse checked VB-0001 in; the form opened with Sent 200; Received 194 refused in plain words ("Say why 6 kg less …"); with the reason saved WH-0001, "flagged for the manager" |
| 7 | Record: 6 kg, 3 %, Good, 4 bags in, Practice godown (test), S-1; system check "Received within the limit … (6 kg, 3 %)" ✗ |
| 8 | Flags: "Warehouse: received 194 kg, 3 % less than was sent (200 kg); more than 2 %. Reason given: dried on the way (practice)" |
| 9 | 0 days; 4 in · 0 out · 4 left; DUE by 17 Oct; Minor deterioration: Save off with "damp", on with the full note; listed with the date and Lucky |
| 10 | Home: "TCUP-KNM-KH26-PRC-WH-0001: inspection due by 17 Oct 2026" (and "1 from Warehouse waiting … at Milling") |
| 11 | Milling's check-in asked "Bags counted out of the warehouse" and "The grain looks and smells sound"; bags out 5: Save off ("4 still in"); 4 saved: 4 in · 4 out · 0 left |
| 12 | M-0001 from WH-0001 (194 kg in, 120 head rice); WH-0001 "DONE nothing is left in storage" |
| 13 | KH26 Bansi, PK-0001 → Commercial: Domestic: no Export market, Destination country or Incoterms; Export: all three shown (not saved) |

Found, small, for release 56: "every 1 days" on the record; at Procurement the farmer picker says "No active farmer of
this client yet" for a moment while the client's farmers load. Not checked on staging (waiting needed): "stored but
not recorded" and the public page's days in storage (`tests/49` §7–8).


## 16 October 2026, morning: share with the buyer, scans and copies, release 9 (migration 56, open item 51), local stack

Veda, 16 Oct: "ok / also check that one client data should not be visible to another client. / also during collection
there can be filter use such as village … / proceed with 56". Everything below ran on the local stack (a rehearsal);
nothing ran on staging yet.

- **Database tests**: every test file on a template built from all migrations and seeds: **2,174 checks**, all ok (2,097
  before release 9). New: `tests/51_buyer_link_scans.sql` **59 checks**, **29 negative controls** (`controls56.py`, each
  breaks one rule in the function's own text: 29 of 29 caught); `tests/50_client_isolation.sql` **18 checks**, with
  three leaks put in on purpose inside the test (a table opened to all, `activation_missing` without its guard, a new
  function answering for any record): each caught.
- **The isolation probe** on a populated copy (two clients): 15 people bound to a client, 39 tables, 9,120 calls with the other
  client's ids before the fixes found three leaks (another client's lab; a scope's activation list; the roster pool's
  work elsewhere naming the other client and scope); after migration 56: `leaks: []`.
- **run_local**: ALL TESTS PASSED (2,215 checks; the smoke check every row OK but the standing ones; the production
  build; the upgrade path, 51 test files again) — run before the pgcrypto fix below and again after it (see the last line).
- **Unit**: 638 tests (24 new in `buyer_link_scans.test.tsx`: the link and token, the buyer-file function with fetch
  stubbed, the scan function's headers, the scan flag's words, the lot filters, the three fixes, every refusal's plain
  words, every new key in both languages). Typecheck clean.
- **End to end**: main suite **90 passed** (21.1 min; new `e2e/phase28.spec.ts`: a shipment shared, the buyer's page at
  527 px without a sign-in, no price or farmer's name, a lab report opened through `buyer-file` (signed address answered
  200), the evidence pack downloaded, three views listed, revoked → "This link does not open"; a pack scanned in Delhi
  and Rotterdam → "Needs my action", the Flags page with both places, the pack page's warning naming the seller,
  cleared → gone; the Collection Batch's village filter, search by code and by farmer, "Choose the 1 shown", "1 chosen
  lots are hidden"); built app **14 passed** (public page 174 KB, 1.7 s on slow 4G); first day from nothing **1 passed**.
- **API checks**: `remote_rls.mjs --t1` 192 passed; `remote_create_user.mjs` 95 passed.
- **Restore drill**: FAILED at first: `function digest(text, unknown) does not exist` at migration 56 (the drill places
  pgcrypto as Supabase does, in `extensions`; the two link functions had `search_path = public`). Fixed (`public,
  extensions`, FIX_LIST FX2); then the database tests (2,174), phase27 + phase28 and the drill: **RESTORE DRILL PASSED**.
- **Release script rehearsal** (`scripts/staging_buyer_link_scans.ps1` on stand-ins, from the release-8 state): the full
  run ends `RESULT: BUYER LINK AND SCANS ON STAGING` (S0, S1, S1c, S1b, S2 with `leaks=0`, S3, 40 files); 26 more
  scenarios each stop where they should (wrong words; 55 or another migration waiting; production; the six functions
  not current; push fails; buyer-file deploy fails or is not current after; the read-back fails, old form, a link or a
  scan with a place already there; rule not in place; **a leak**; the probe cannot run; a smoke row not OK; a changed
  migration, smoke check, `check_functions.mjs`, `web/api` file or `buyer-file`; a new file under `web/api`); a rerun
  after a full run deploys `buyer-file` again and commits nothing.
- **Part H**: pictures of the Collection Batch and Lot Inward operators at 390 px, report `docs/PART_H_OPERATOR_VIEW.md`.

NOT run / not known: nothing on staging yet; the scan's place from Vercel's headers (only the function's text is
tested; staging shows it, run-sheet row 6); about 130 new Hindi strings unread by their users.
- **After the pgcrypto fix**: run_local again: ALL TESTS PASSED (2,215 checks), exit 0. The app files were sealed after
  it (157 files, `scripts/tested_app_files.txt`).

## 16 October 2026, 09:59 IST: release 9 on staging, first run: STOPPED at S2 (the isolation check), as designed

Veda ran `staging-buyer-link-scans.cmd`. S0, S1 (migration 56 pushed), S1c (`buyer-file` deployed, build 2026-10-16;
FUNCTIONS DEPLOYED AND CURRENT), S1b (`commercial_form=new stages=17 links=0 link_views=0 scan_flags=0 scans=1
scans_with_place=0`) OK. S2: `A CLIENT CAN SEE ANOTHER CLIENT'S DATA: leaks=2 people=7 tables=40 calls=7440
own_rows=2147 clients=3 what=table:openings. The app was not pushed`. The old app works on the new database meanwhile.

Cause: `openings_read` (migration 39) let every Client Manager (`app.can_assign()`) read every opening, and an opening
made from a scope's requirement names its client and scope. The local data had no opening of any client, so the probe
had nothing to find there. Reproduced locally first: `tests/50_client_isolation.sql`, with every table the probe reads
given a row of each client (37 tables) and a Client Manager for the second client, failed with exactly that:
`[{"kind": "table", "role": "client_manager", "what": "openings"}, {"kind": "table", "role": "operator", "what": "openings"}]`
(the second is the other client's Client Manager, whose summary role still says operator).

Fixed by **migration 56b** (`20261031000200_openings_isolation`): a manager reads the openings of the clients he may see
(and GrainVeda's own, of no client); HR and the admin as before; the probe also reads `buyer_links` (open by column) and
traces a link's views. Then, local stack:

- test 50: 23 checks (+5: each Client Manager reads only his client's openings, HR both; a control puts the old rule back
  and the probe catches it); every database test 2,179; `controls56.py` 29 of 29; smoke row `client isolation`
  (negative control: the old rule → `MISSING (push migration 56b …)`).
- run_local: ALL TESTS PASSED (2,220 checks, upgrade path, production build), exit 0.
- e2e phase11 (HR openings), phase18 (requirements → openings), phase27, phase28: 6 passed; `remote_rls --t1` 192
  passed; restore drill PASSED.
- The release script (`patch56b.py` after `mkrel56.py`): 29 rehearsal scenarios; the case of staging now (56 in,
  `buyer-file` deployed, only 56b waiting) ends `RESULT: BUYER LINK AND SCANS ON STAGING`; 56b changed, 56 alone or out
  of order waiting, a leak: each stops.
