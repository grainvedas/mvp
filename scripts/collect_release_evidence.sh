#!/usr/bin/env bash
# Runs every check that can be run on the LOCAL STACK and writes the result files that scripts/release_gate.mjs reads
# into ./release-evidence (git-ignored). Linux / macOS / CI. About 20 minutes.
#
#   PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres scripts/collect_release_evidence.sh            uses the stack as it is
#   PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres scripts/collect_release_evidence.sh --fresh    rebuilds the stack first
#
# What it cannot produce (they need the staging project, a real backup, or a person) stays REHEARSAL / PENDING in the
# gate: see docs/RUNSHEET_phase4.md for those steps.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/release-evidence"; mkdir -p "$OUT"
: "${PGHOST:=127.0.0.1}" "${PGPORT:=5432}" "${PGUSER:=postgres}"; export PGHOST PGPORT PGUSER
export ENV_FILE=.env.stack
step() { printf '\n== %s\n' "$*"; }
status=0
note() { if [ "$1" -ne 0 ]; then echo "   -> FAILED (exit $1): $2"; status=1; else echo "   -> ok: $2"; fi; }

if [ "${1:-}" = "--fresh" ]; then
  step "rebuild the local stack from the migrations and seeds"
  local-stack/down.sh >/dev/null 2>&1
  local-stack/up.sh > "$OUT/stack-up.log" 2>&1; note $? "local stack up"
  node scripts/create_demo_logins.mjs > "$OUT/demo-logins.log" 2>&1; note $? "demo logins"
fi

step "1/9 database suite (migrations + seeds on a scratch database, every tests/*.sql, production build, concurrency)"
tests/run_local.sh > "$OUT/sql.log" 2>&1; note $? "$(grep -c 'ok   ' "$OUT/sql.log") assertions"

step "2/9 unit tests"
(cd web && npx vitest run --reporter=json --outputFile="$OUT/unit.json" > "$OUT/unit.log" 2>&1); note $? "vitest"

step "3/9 end-to-end, whole suite, run 1 of 2"
(cd web && PLAYWRIGHT_JSON_OUTPUT_NAME="$OUT/e2e-run1.json" npx playwright test --reporter=list,json > "$OUT/e2e-run1.log" 2>&1); note $? "$(tail -3 "$OUT/e2e-run1.log" | tr '\n' ' ')"
step "4/9 end-to-end, whole suite, run 2 of 2"
(cd web && PLAYWRIGHT_JSON_OUTPUT_NAME="$OUT/e2e.json" npx playwright test --reporter=list,json > "$OUT/e2e-run2.log" 2>&1); note $? "$(tail -3 "$OUT/e2e-run2.log" | tr '\n' ' ')"

step "5/9 production build behind a host-like server: page budget on throttled 3G, security policy, a day in the field without network"
(cd web && npx playwright test -c playwright.prod.config.ts > "$OUT/prod.log" 2>&1); note $? "$(grep -o 'public page: .*' "$OUT/prod.log" | head -1)"

step "6/9 acceptance rehearsal: T1–T5 against the BUILT app, two consecutive runs"
(cd web && exec node scripts/serve-dist.mjs > "$OUT/serve.log" 2>&1) & SERVE=$!
for i in $(seq 1 40); do curl -sf http://127.0.0.1:4173/ >/dev/null && break; sleep 0.5; done
for n in 1 2; do
  (cd web && ACCEPTANCE_URL=http://127.0.0.1:4173 GV_LOGINS_FILE=.env.demo-logins.stack ACCEPTANCE_RUN=$n ACCEPTANCE_REPORT="$OUT/acceptance-$n.json" \
     npx playwright test -c playwright.acceptance.config.ts > "$OUT/acceptance-$n.log" 2>&1); note $? "acceptance run $n: $(tail -6 "$OUT/acceptance-$n.log" | grep -E 'passed|failed' | tr '\n' ' ')"
done

step "7/9 Lighthouse accessibility on the public verify page"
CODE=$(psql -At -d "${STACK_DB:-grainveda_stack}" -c "select qr_code from public.qr_seals order by sealed_at desc limit 1")
CHROME=$(ls -d "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"/chromium-*/chrome-linux/chrome 2>/dev/null | head -1)
( cd "$OUT" && CHROME_PATH="${CHROME_PATH:-$CHROME}" npx --yes lighthouse@12 "http://127.0.0.1:4173/verify/$CODE" --only-categories=accessibility \
    --output=json --output-path="$OUT/lighthouse.json" --chrome-flags="--headless=new --no-sandbox --disable-gpu" --quiet > "$OUT/lighthouse.log" 2>&1 )
note $? "$(node -e "try{const r=require('$OUT/lighthouse.json');console.log('accessibility '+Math.round(r.categories.accessibility.score*100))}catch(e){console.log('no result')}")"
fuser -k 4173/tcp >/dev/null 2>&1 || kill "$SERVE" 2>/dev/null

step "8/9 permissions with real logins through the API, ledger audit, smoke check, functions"
node tests/remote_rls.mjs --t1 > "$OUT/rls.log" 2>&1; note $? "$(tail -2 "$OUT/rls.log" | tr '\n' ' ')"
node tests/remote_create_user.mjs > "$OUT/create-user.log" 2>&1; note $? "$(tail -2 "$OUT/create-user.log" | tr '\n' ' ')"
node tests/remote_ledger_check.mjs --tamper-local > "$OUT/ledger-check.log" 2>&1; note $? "$(tail -1 "$OUT/ledger-check.log")"
psql -X -At -v ON_ERROR_STOP=1 -d "${STACK_DB:-grainveda_stack}" -f tests/remote_ledger_audit.sql > "$OUT/audit.log" 2>&1; note $? "$(cat "$OUT/audit.log" | head -2 | tr '\n' ' ')"
psql -X -At -v ON_ERROR_STOP=1 -d "${STACK_DB:-grainveda_stack}" -f tests/remote_smoke.sql > "$OUT/smoke.log" 2>&1; note $? "$(grep -c '|OK' "$OUT/smoke.log") of $(wc -l < "$OUT/smoke.log") smoke rows OK (pg_cron is not on the local stack)"

step "9/9 backup and restore drill"
node scripts/restore_drill.mjs > "$OUT/restore-drill.log" 2>&1; note $? "$(tail -2 "$OUT/restore-drill.log" | head -1)"

step "release gate"
node scripts/release_gate.mjs --dir "$OUT" > "$OUT/gate.log" 2>&1
cat "$OUT/GATE.md"
echo
[ $status -eq 0 ] && echo "EVERY LOCAL CHECK RAN GREEN (the gate above still needs the staging and human steps)" || echo "SOME LOCAL CHECKS FAILED: see the lines marked FAILED above"
exit $status
