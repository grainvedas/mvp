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
