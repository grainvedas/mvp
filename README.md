# GrainVeda MVP

Traceability-as-a-service for GI-certified crops: every lot is recorded stage by stage by the person who handled it,
checked by the next person before they take it over, written to an append-only ledger, and sealed behind a QR code
that anyone can scan. This repository is the MVP rebuild of the `GrainVeda_Platform_v1.html` prototype.

PRD (living doc): https://claude.ai/code/artifact/28bf2d7b-66e0-4580-a6c7-5b12a85eefeb

## Where things stand

| Phase (PRD §13) | Built and tested here | On the hosted project: its run-sheet |
|---|---|---|
| 0 Database foundation | done | migrations 1–13 applied on 27 Sep 2026; close-out: `docs/RUNSHEET_2026-10-01_security_and_phase0.md` |
| 1 Web app, generic stage engine, farmers, logins | done | `docs/RUNSHEET_phase1.md` |
| 2 Processing stages, sale, shipment, seal, labels, public page | done | `docs/RUNSHEET_phase2.md` |
| 3 Offline, Hindi, dashboards, exports, nightly ledger check | done | `docs/RUNSHEET_phase3.md` |
| 4 Deploy, acceptance, restore drill, handover | done on the local stack | `docs/RUNSHEET_phase4.md` |

Which run-sheets have been completed on the hosted project is recorded in `docs/VERIFICATION_LOG.md` by whoever runs
them; step A2 of the Phase 4 run-sheet shows it at a glance (the migrations still to be pushed).

"Done" means the tests pass on a local stand-in for the Supabase project. The release gate
(`node scripts/release_gate.mjs`) says REHEARSAL for every criterion that has not been met on staging, and PENDING for
the two that need a person. What was run, with numbers, and what was not: `docs/VERIFICATION_LOG.md`.
What is known to be missing or undecided: `docs/FIX_LIST.md`.

## Read this first

| You are | Read |
|---|---|
| Antigravity IDE, about to put Phase 4 on the hosted project | `docs/RUNSHEET_phase4.md`, then `docs/DEPLOY.md` |
| A coding agent changing anything | `AGENTS.md` |
| The person running the acceptance test | `docs/ACCEPTANCE.md` |
| The admin or a manager in a live season | `docs/OPERATIONS.md` |
| An operator | `docs/OPERATOR_GUIDE.md` (one sheet, Hindi and English) |
| Whoever looks after backups | `docs/RESTORE.md` |

## The model in one paragraph

A **scope** (client × crop × season × geography) owns a frozen **chain** of stage types: starts with `procurement` or
`lot_inward`, contains `qc`, ends with `qr_activation`, each type at most once. Every stage record is a **footprint** with
the sacred stamps `scope_id`, `client_id`, `qty_in`, `qty_out`, `prev_footprint_id`, stamped by trigger. A footprint is
created *pending* by the operator holding that stage's slot, and *verified* by the operator of the **next** stage (the
handoff is the coupling). Verified records are immutable; a wrong one is withdrawn with a reason and replaced, never
deleted. Every act appends a hash-chained **ledger** block; `app.verify_ledger()` recomputes the chain. Quantities
reconcile per stage (PRD §7) inside `app.reconcile()`. QC derives domestic and export verdicts from readings against the
crop's limits; any later lot resolves its verdict by walking back to QC. `app.seal_source()` records the QR stage and
seals in one transaction; `app.public_lot_journey(qr_code)` is what the public verify page shows. The rules live in
Postgres (triggers and row-level security); the screens mirror them and are never the only check.

## Layout

```
supabase/
  migrations/                      27 files, applied in name order. Never edit an applied one.
    20260927000100 … 001300        Phase 0: tables, integrity triggers, RLS, seal, login linking, counters, ledger hash
    20261001000100_api_surface     every app function closed by default, granted by name
    20261001000200 … 000500        Phase 1: preview (review = save), stage_form, farmers, corrections, scope reads
    20261001000600_grade_split     Phase 2: grade lots A / B / C
    20261001000700_village_batch   Phase 2: one batch from several farmers' lots
    20261001000800_phase3_ops      Phase 3: nightly ledger check, save ids for offline sync, journey export
    20261002000100_integrity_guards   Phase 4: direct writes closed; withdraw and replace
    20261002000200_phase4_ops         practice / production marker, problems from phones, reset rules, check on demand
    20261002000300_atomic_saves       record + seal in one transaction; grade lots made by the save
    20261002000400_access_rules       ledger read by stage; assignments removable; people in the ledger
    20261002000500 … 000600           evidence fingerprints in the ledger
  seeds/
    01_stage_definitions.sql       the one stage registry (16 stage types): forms, hand-off checks
    02 … 05                        demo data for staging and tests. They refuse to run on production
    production/10_reference.sql    what a real season starts from; marks the project as production
  functions/                       Edge Functions: create-user, reset-password, ledger-check
tests/
  00_local_auth_shim.sql           LOCAL ONLY: stands in for Supabase Auth
  01 … 18_*.sql, concurrency/      the database suite (plain SQL assertions)
  run_local.sh / run_local.ps1     rebuilds a scratch database and runs all of it
  remote_smoke.sql                 read-only check of a hosted project (21 rows)
  remote_ledger_audit.sql          read-only: every ledger block has a real counterpart, and the reverse
  remote_rls.mjs                   permissions with real logins through the API (refuses production)
  remote_auth_settings.mjs         read-only: who can get a login
  remote_ledger_check.mjs          the monitor function
  remote_create_user.mjs           LOCAL STACK ONLY: makes and resets logins
local-stack/                       Postgres + Supabase Auth + PostgREST + functions + storage stand-in behind one URL
scripts/
  create_demo_logins.mjs           demo logins for staging and the stack (refuses production)
  bootstrap_admin.mjs              the first admin of a project
  make_ledger_token.mjs            the monitor's token
  backup.mjs, restore_drill.mjs, restore_evidence.mjs      off-platform backup, proven by restoring it
  collect_release_evidence.sh      every check that can run on the local stack, with result files
  release_gate.mjs                 PRD §12, criterion by criterion, from the result files
web/
  src/engine/                      ONE generic 8-step stage component, driven by stage_definitions
  src/offline/                     outbox (saves kept on the phone), copy of forms for work without network
  src/lib/keptLogin.ts             who is signed in on this phone, whatever the network says
  src/lib/i18n.en.ts, i18n.hi.ts   every visible string
  public/sw.js                     lets the app open with no network
  tests/                           unit tests (vitest)
  e2e/                             end-to-end through the screens (Playwright, phone-sized); T1–T5 are the acceptance tests
  e2e-prod/                        the BUILT app behind a host-like server: budgets, security policy, a day in the field
  wrangler.jsonc, netlify.toml, vercel.json     hosting (Cloudflare is the default)
docs/                              run-sheets per phase, DEPLOY, ACCEPTANCE, RESTORE, OPERATIONS, OPERATOR_GUIDE, FIX_LIST,
                                   VERIFICATION_LOG, ci/database-tests.yml (copy to .github/workflows/)
AGENTS.md                          rules for coding agents working in this repository
```

## Run it

Database suite, any Postgres 16 or 17 with `pgcrypto` (Windows: `tests/run_local.ps1`, its header says how):

```bash
export PGHOST=localhost PGPORT=5432 PGUSER=postgres
tests/run_local.sh                  # … ALL TESTS PASSED
```

The whole system on one machine (Linux, macOS, CI), without touching any hosted project:

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres local-stack/up.sh
ENV_FILE=.env.stack node scripts/create_demo_logins.mjs
cd web && npm ci
npx vite --mode stack               # http://127.0.0.1:5173
npx vitest run                      # unit tests
npx playwright test                 # end-to-end, whole suite
npx playwright test -c playwright.prod.config.ts    # the built app: budgets, security policy, a day in the field
```

Everything at once, with the result files the release gate reads (about 20 minutes):

```bash
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres scripts/collect_release_evidence.sh --fresh
```

Against the hosted staging project (Windows): `cd web; npm ci; npm run dev` reads `../.env.local`.

## Two systems, never mixed

| | Staging (practice) | Production (real lots) |
|---|---|---|
| Env file (git-ignored) | `.env.local` | `.env.production` |
| App build | `npm run build` | `npm run build:production` (stops without `.env.production`) |
| Shows | gold strip PRACTICE SYSTEM | no strip |
| Demo and test scripts | allowed | refuse to run |

Secrets live only in git-ignored `.env.*` files. The service key never reaches the browser or git; a test fails the
build if any secret of the env file is found in the built app.
