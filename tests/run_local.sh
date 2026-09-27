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
# Four sessions at once: ledger appends and Farmer IDs under concurrency. Last, because it commits into the scratch DB.
echo "test     tests/concurrency (4 parallel sessions)"
$PSQL -d "$DB" -f tests/concurrency/setup.sql || fail=1
pids=()
for w in 1 2 3 4; do $PSQL -d "$DB" -v worker=$w -f tests/concurrency/worker.sql >/dev/null & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || { fail=1; echo "FAILED   tests/concurrency/worker.sql"; }; done
$PSQL -d "$DB" -f tests/concurrency/check.sql || { fail=1; echo "FAILED   tests/concurrency/check.sql"; }
[ $fail -eq 0 ] && echo "ALL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
