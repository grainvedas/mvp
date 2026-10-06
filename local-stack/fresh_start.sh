#!/usr/bin/env bash
# The fresh start, on the LOCAL STACK: what scripts/staging_fresh_start.ps1 does to the practice system, step for
# step with the same files. Leaves the stack with nothing in it but the rules, the stage definitions, the standard
# joining checklist and one admin (temporary password in .env.admin-login). After it the default suite cannot run
# (no demo data): local-stack/up.sh brings the demo stack back.
#   PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres local-stack/fresh_start.sh
#   cd web && npx playwright test -c playwright.fresh.config.ts
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${STACK_DB:-grainveda_stack}
: "${PGHOST:=127.0.0.1}" "${PGPORT:=5432}" "${PGUSER:=postgres}"
export PGHOST PGPORT PGUSER ENV_FILE=.env.stack
node scripts/fresh_start/export_rows.mjs | tail -2
psql -v ON_ERROR_STOP=1 -q -At -d "$DB" -f scripts/fresh_start/empty_staging.sql
node scripts/fresh_start/clear_logins_and_files.mjs --empty-staging | tail -1
node scripts/bootstrap_admin.mjs --email "${FRESH_ADMIN_EMAIL:-grainvedas+admin@gmail.com}" --name "${FRESH_ADMIN_NAME:-Veda}" | head -2
psql -q -At -d "$DB" -c "select 'in the system now: ' || (select count(*) from public.app_users) || ' person, ' || (select count(*) from auth.users) || ' login, ' || (select count(*) from public.states) || ' states, ' || (select count(*) from public.ledger) || ' ledger block(s)'"
echo "LOCAL STACK EMPTIED: one admin, nothing else"
