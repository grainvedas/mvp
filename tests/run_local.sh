#!/usr/bin/env bash
# Rebuilds a scratch database from the migrations + seeds and runs every test file. Exit code != 0 on any failure.
# Usage: PGHOST=/var/tmp/gvpg PGPORT=5433 PGUSER=postgres tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-grainveda_test}
PSQL="psql -v ON_ERROR_STOP=1 -q"

dropdb --if-exists "$DB"
createdb "$DB"
$PSQL -d "$DB" -f tests/00_local_auth_shim.sql
for f in supabase/migrations/*.sql; do echo "migrate  $f"; $PSQL -d "$DB" -f "$f"; done
for f in supabase/seeds/*.sql;      do echo "seed     $f"; $PSQL -d "$DB" -f "$f"; done
fail=0
for f in tests/0[1-9]*.sql tests/[1-9]*.sql; do [ -e "$f" ] || continue
  echo "test     $f"
  if ! $PSQL -d "$DB" -f "$f"; then fail=1; echo "FAILED   $f"; fi
done
# Self-test of the live-project T1 check on this fresh build, so it is proven here before it runs remotely.
echo "test     tests/remote_t1_rollback.sql (local self-test)"
if ! $PSQL -d "$DB" -f tests/remote_t1_rollback.sql; then fail=1; echo "FAILED   tests/remote_t1_rollback.sql"; fi
# Production build: every migration + stage definitions + the production seed on a second scratch database. No demo
# data may be in it, and the demo seed must refuse to run on it.
echo "test     production build (no demo data; the demo seed must refuse)"
PDB="${DB}_prod"
dropdb --if-exists "$PDB"; createdb "$PDB"
prod_ok=1
$PSQL -d "$PDB" -f tests/00_local_auth_shim.sql || prod_ok=0
for f in supabase/migrations/*.sql; do $PSQL -d "$PDB" -f "$f" 2>/dev/null || prod_ok=0; done
for f in supabase/seeds/01_stage_definitions.sql supabase/seeds/production/10_reference.sql tests/01_helpers.sql; do
  $PSQL -d "$PDB" -f "$f" >/dev/null || prod_ok=0
done
$PSQL -d "$PDB" -f tests/production_seed_check.sql || prod_ok=0
if [ $prod_ok -eq 0 ]; then fail=1; echo "FAILED   production build"
elif $PSQL -d "$PDB" -f supabase/seeds/02_kalanamak_demo.sql >/dev/null 2>"/tmp/gv_prod_seed.$$"; then
  fail=1; echo "FAILED   the demo seed ran on a production build"
elif grep -q 'demo seed refused' "/tmp/gv_prod_seed.$$"; then echo "ok   production: the demo seed refuses to run"
else fail=1; echo "FAILED   the demo seed failed for another reason"; cat "/tmp/gv_prod_seed.$$"; fi
rm -f "/tmp/gv_prod_seed.$$"; dropdb --if-exists "$PDB"
# Upgrade path: what a project already in use gets. The database as it stood before the identity layer (migrations up
# to 30, the demo people and their stages), then the later migrations on top, each in ONE transaction as
# `supabase db push` runs them, then the whole suite again. A migration that moves existing rows is never exercised by
# the fresh build above: on 6 Oct 2026 migration 31 passed every test and would have stopped on any database with a
# stage row in it.
echo "test     upgrade path (migrations 1-30 and the demo data first, then 31 onwards on top, then every test again)"
UDB="${DB}_upgrade"
dropdb --if-exists "$UDB"; createdb "$UDB"
up_ok=1
QUIET="env PGOPTIONS=-cclient_min_messages=warning $PSQL"
later() { case "$(basename "$1")" in 2026100[6-9]*|202610[1-9]*|20261[1-2]*|202[7-9]*) return 0;; *) return 1;; esac; }
$QUIET -d "$UDB" -f tests/00_local_auth_shim.sql || up_ok=0
for f in supabase/migrations/*.sql; do later "$f" && continue; $QUIET -1 -d "$UDB" -f "$f" || up_ok=0; done
for f in supabase/seeds/0[1-5]*.sql; do $QUIET -d "$UDB" -f "$f" || up_ok=0; done
for f in supabase/migrations/*.sql; do later "$f" || continue
  $QUIET -1 -d "$UDB" -f "$f" || { up_ok=0; echo "FAILED   upgrade: $f does not apply to a database in use"; }; done
for f in supabase/seeds/0[6-9]*.sql; do [ -e "$f" ] || continue; $QUIET -d "$UDB" -f "$f" || up_ok=0; done
n_up=0
if [ $up_ok -eq 1 ]; then
  for f in tests/0[1-9]*.sql tests/[1-9]*.sql; do [ -e "$f" ] || continue
    if $QUIET -d "$UDB" -f "$f"; then n_up=$((n_up+1)); else up_ok=0; echo "FAILED   upgrade: $f on the upgraded database"; fi
  done
fi
if [ $up_ok -eq 1 ]; then echo "ok   upgrade: the later migrations apply to a database in use, and all $n_up test files pass on it"
else fail=1; echo "FAILED   upgrade path"; fi
dropdb --if-exists "$UDB"
# Four sessions at once: ledger appends and Farmer IDs under concurrency. Last, because it commits into the scratch DB.
echo "test     tests/concurrency (4 parallel sessions)"
$PSQL -d "$DB" -f tests/concurrency/setup.sql || fail=1
pids=()
for w in 1 2 3 4; do $PSQL -d "$DB" -v worker=$w -f tests/concurrency/worker.sql >/dev/null & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || { fail=1; echo "FAILED   tests/concurrency/worker.sql"; }; done
$PSQL -d "$DB" -f tests/concurrency/check.sql || { fail=1; echo "FAILED   tests/concurrency/check.sql"; }
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
