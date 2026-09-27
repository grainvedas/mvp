# GrainVeda MVP — Phase 0 (database foundation)

Traceability-as-a-service for GI-certified crops. This repository is the funded MVP rebuild of the
`GrainVeda_Platform_v1.html` prototype. Phase 0 = the Postgres/Supabase foundation: schema, integrity
rules, ledger, RLS, seeds and a test harness. No front-end yet.

PRD (living doc): https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb

## Layout

```
supabase/
  migrations/
    20260927000100_extensions_enums.sql    enums, app schema, tolerance constant
    20260927000200_core_tables.sql         states, crops, clients, stage_definitions, scopes, app_users, slot_assignments, farmers
    20260927000300_footprints_ledger.sql   footprints (universal stage record), qc_verdicts, qr_seals, flags, attachments, ledger
    20260927000400_integrity_triggers.sql  helpers, chain rules, per-stage reconciliation, QC verdict engine, ledger chain, seal RPC
    20260927000500_rls_policies.sql        row-level security per PRD §4/§9
    20260927000600_views_rpc.sql           incoming_records, public_lot_journey (verify page), pipeline_summary
    20260927000700_extensions_search_path.sql  adds `extensions` to search_path (Supabase keeps pgcrypto there)
    20260927000800_seal_lot_restore.sql    restores the tested seal_lot that migration 7 broke
    20260927000900_login_linking.sql       unique phone/email; links a confirmed login to its app_users row
    20260927001000_app_users_guard.sql     who may write app_users (no self-promotion, auth_uid only via linking)
    20260927001100_actor_is_caller.sql     signed-in callers act only as themselves (verify, seal, override, farmers)
    20260927001200_identifier_counters.sql Farmer ID counter; codes past 9999 never truncate
    20260927001300_ledger_hash_time_zone.sql ledger hashing independent of the session time zone
  seeds/
    01_stage_definitions.sql               the single stage registry (16 stage types)
    02_kalanamak_demo.sql                  UP + Kalanamak, Prasaadam client, 12 users, 3 active scopes, 5 farmers
tests/
  00_local_auth_shim.sql                   LOCAL ONLY: fakes auth.uid() and the Supabase roles
  01_helpers.sql … 07_server_paths.sql     plain-SQL assertions (168), no pgTAP dependency
  concurrency/                             4 parallel sessions: ledger chain and Farmer IDs under concurrent writes
  run_local.sh / run_local.ps1             rebuilds a scratch DB, applies everything, runs the tests (bash / Windows)
  remote_smoke.sql                         read-only check of the live project
  remote_t1_rollback.sql                   T1 seal on the live project, undone afterwards
  remote_api_check.ps1                     app schema reachable over REST with the public key
docs/
  VERIFICATION_LOG.md                      what was actually run, and what was not
AGENTS.md                                  rules for Antigravity IDE / any coding agent working in this repo
```

## Run the tests locally (any Postgres 16 with pgcrypto)

```bash
export PGHOST=localhost PGPORT=5432 PGUSER=postgres   # or a socket dir
tests/run_local.sh
# … ALL TESTS PASSED
```

`run_local.sh` drops and recreates `grainveda_test`, applies the shim, migrations, seeds, then every `tests/0N_*.sql`.
Each test file runs inside a transaction and rolls back.

## Apply to a Supabase project

1. `supabase init` (if not done) and link the project: `supabase link --project-ref <ref>`.
2. Seeds: in `supabase/config.toml` set
   ```toml
   [db.seed]
   enabled = true
   sql_paths = ["./seeds/*.sql"]
   ```
3. `supabase db push` applies `supabase/migrations/*`; `supabase db reset` applies migrations + seeds locally in the CLI's Docker DB.
4. **Expose the `app` schema to the API** (Dashboard → Settings → API → Exposed schemas, add `app`), or the RPCs
   (`app.verify_footprint`, `app.seal_lot`, `app.incoming_records`, `app.public_lot_journey`, `app.pipeline_summary`) are not callable
   from `supabase-js`. Phase 1 decision: keep them in `app` and expose it, or add thin `public.*` wrappers.
5. Create the auth users (phone OTP for operators, email for managers) and set `app_users.auth_uid` to each `auth.users.id`.
   The seed's `auth_uid` values are local placeholders equal to the row ids.
6. Never run `tests/00_local_auth_shim.sql` against Supabase.

## The model in one paragraph

A **scope** (client × crop × season × geography) owns a frozen **chain** of stage types: starts with `procurement` or
`lot_inward`, contains `qc`, ends with `qr_activation`, each type at most once. Every stage record is a **footprint** with
the sacred stamps `scope_id`, `client_id`, `qty_in`, `qty_out`, `prev_footprint_id`, stamped by trigger. A footprint is
created *pending* by the operator holding that stage's slot, and *verified* by the operator of the **next** stage (the
handoff is the coupling). Verified records are immutable. Every create / verify / seal / override / close / supervisory act
appends a hash-chained **ledger** block; `app.verify_ledger()` recomputes the chain. Quantities reconcile per stage
(PRD §7) inside `app.reconcile()`. QC derives domestic and export verdicts from readings against the crop's structured
limits; any downstream lot resolves its verdict by walking back to QC (`app.resolve_market_verdict`). `app.seal_lot()` re-walks
the whole chain and mints the QR; `app.public_lot_journey(qr_code)` is what the public verify page renders.

## Phase 0 exit gate (PRD §13)

- [x] Integrity rules 1–9 enforced in Postgres and covered by tests (`tests/02_integrity_rules.sql`)
- [x] Ledger append-only + tamper detection (`tests/03_ledger.sql`)
- [x] RLS tenant/scope/stage isolation (`tests/04_rls.sql`)
- [x] T1, T2 (grading split), T3 (market fork + override) chains pass end-to-end in SQL (`tests/05_chains.sql`)
- [x] Applied to the Supabase dev project `zogkrhgzatplarimbmxk`: migrations 1–8 + seeds; `tests/remote_t1_rollback.sql` passes; `app` schema exposed (`tests/remote_api_check.ps1` OK); smoke 12/13 (auth mapping pending)
- [ ] Auth flows (phone OTP, email) — not yet
- [ ] CI running `run_local.sh` — not yet
