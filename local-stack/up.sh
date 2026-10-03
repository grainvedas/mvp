#!/usr/bin/env bash
# Local stand-in for the Supabase project: Postgres + Supabase Auth + PostgREST + local Edge Function runner, all behind
# one URL (http://127.0.0.1:54321) exactly like https://<ref>.supabase.co. For end-to-end tests and front-end work
# without touching the live project. Linux/macOS (CI runs it on ubuntu). Storage is a small stand-in (storage.mjs) that
# keeps files on disk and lets the real evidence policies decide who may write and read them.
#
#   PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres local-stack/up.sh      # builds DB, starts services, seeds, writes .env.stack
#   STACK_DISABLE_SIGNUP=1 … local-stack/up.sh     # public sign-up OFF, as on the live projects (docs/DEPLOY.md step 4)
#   local-stack/down.sh
# Public sign-up is open by default here so that tests/remote_create_user.mjs can show that a sign-up never becomes a
# GrainVeda user (migration 23). With it off the same test shows that managers can still make and reset logins.
#
# Binaries (downloaded once into local-stack/bin, git-ignored):
#   PostgREST v12.2.3  https://github.com/PostgREST/postgrest/releases
#   Supabase Auth v2.197.0  https://github.com/supabase/auth/releases
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${STACK_DB:-grainveda_stack}
BIN=$(realpath -m "${STACK_BIN:-local-stack/bin}")
RUN=$(realpath -m "${STACK_RUN:-local-stack/run}")
: "${PGHOST:=127.0.0.1}" "${PGPORT:=5432}" "${PGUSER:=postgres}"
export PGHOST PGPORT PGUSER
DBHOST=${STACK_DBHOST:-127.0.0.1}
SECRET=${STACK_JWT_SECRET:-local-stack-jwt-secret-not-for-production-0001}
PSQL="psql -v ON_ERROR_STOP=1 -q -d $DB"
mkdir -p "$BIN" "$RUN"

# 0. binaries
if [ ! -x "$BIN/postgrest" ]; then
  curl -sSL https://github.com/PostgREST/postgrest/releases/download/v12.2.3/postgrest-v12.2.3-linux-static-x64.tar.xz | tar -xJ -C "$BIN"
fi
if [ ! -x "$BIN/auth" ]; then
  curl -sSL https://github.com/supabase/auth/releases/download/v2.197.0/auth-v2.197.0-x86.tar.gz | tar -xz -C "$BIN"
fi

local-stack/down.sh >/dev/null 2>&1 || true

# 1. database + Supabase roles
dropdb --if-exists "$DB"; createdb "$DB"
$PSQL -f local-stack/roles.sql
$PSQL -f local-stack/storage.sql
rm -rf "$RUN/storage"

# 2. Auth runs its own migrations (creates auth.users, auth.uid(), …)
ANON_KEY=$(node local-stack/jwt.mjs anon "$SECRET")
SERVICE_KEY=$(node local-stack/jwt.mjs service_role "$SECRET")
export GOTRUE_API_HOST=127.0.0.1 PORT=54331 API_EXTERNAL_URL=http://127.0.0.1:54321/auth/v1
export GOTRUE_DB_DRIVER=postgres DATABASE_URL="postgres://supabase_auth_admin:auth_admin@$DBHOST:$PGPORT/$DB?sslmode=disable"
export GOTRUE_SITE_URL=http://127.0.0.1:5173 GOTRUE_URI_ALLOW_LIST='*'
export GOTRUE_JWT_SECRET="$SECRET" GOTRUE_JWT_EXP=3600 GOTRUE_JWT_AUD=authenticated
export GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated GOTRUE_JWT_ADMIN_ROLES=service_role
if [ "${STACK_DISABLE_SIGNUP:-}" = 1 ]; then export GOTRUE_DISABLE_SIGNUP=true; fi
export GOTRUE_EXTERNAL_EMAIL_ENABLED=true GOTRUE_MAILER_AUTOCONFIRM=true
export GOTRUE_EXTERNAL_PHONE_ENABLED=true GOTRUE_SMS_AUTOCONFIRM=true GOTRUE_SMS_PROVIDER=twilio
export GOTRUE_SMS_TWILIO_ACCOUNT_SID=local GOTRUE_SMS_TWILIO_AUTH_TOKEN=local GOTRUE_SMS_TWILIO_MESSAGE_SERVICE_SID=local
export GOTRUE_DB_MIGRATIONS_PATH="$BIN/migrations" GOTRUE_LOG_LEVEL=warn
( cd "$BIN" && ./auth migrate > "$RUN/auth-migrate.log" 2>&1 ) || { echo "auth migrate failed"; tail -20 "$RUN/auth-migrate.log"; exit 1; }
# exec: the recorded pid must be the server's own, or down.sh stops a wrapper shell and leaves the server running
( cd "$BIN" && exec nohup ./auth serve > "$RUN/auth.log" 2>&1 ) & echo $! > "$RUN/auth.pid"
for i in $(seq 1 60); do curl -sf http://127.0.0.1:54331/health >/dev/null && break; sleep 0.5; done
curl -sf http://127.0.0.1:54331/health >/dev/null || { echo "auth did not start"; tail -20 "$RUN/auth.log"; exit 1; }

# 3. GrainVeda migrations + seeds (same files as the live project)
for f in supabase/migrations/*.sql; do echo "migrate  $f"; $PSQL -f "$f"; done
for f in supabase/seeds/*.sql;      do echo "seed     $f"; $PSQL -f "$f"; done
$PSQL -f local-stack/after.sql

# 4. PostgREST
export PGRST_DB_URI="postgres://authenticator:authenticator@$DBHOST:$PGPORT/$DB?sslmode=disable"
export PGRST_DB_SCHEMAS=public,app,storage PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$SECRET"
export PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT=54330 PGRST_DB_EXTRA_SEARCH_PATH=public,extensions PGRST_LOG_LEVEL=warn
nohup "$BIN/postgrest" > "$RUN/postgrest.log" 2>&1 & echo $! > "$RUN/postgrest.pid"

# 5. Edge Functions (local runner) + gateway
LEDGER_CHECK_TOKEN=$(node -e "console.log(require('crypto').randomBytes(24).toString('hex'))")
export SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_ANON_KEY="$ANON_KEY" SUPABASE_SERVICE_ROLE_KEY="$SERVICE_KEY" FUNCTIONS_PORT=54332 LEDGER_CHECK_TOKEN
nohup node --experimental-strip-types --no-warnings local-stack/functions.mjs > "$RUN/functions.log" 2>&1 & echo $! > "$RUN/functions.pid"
STORAGE_JWT_SECRET="$SECRET" STORAGE_DIR="$RUN/storage" nohup node local-stack/storage.mjs > "$RUN/storage.log" 2>&1 & echo $! > "$RUN/storage.pid"
nohup node local-stack/gateway.mjs > "$RUN/gateway.log" 2>&1 & echo $! > "$RUN/gateway.pid"
for i in $(seq 1 60); do curl -sf -H "apikey: $ANON_KEY" http://127.0.0.1:54321/rest/v1/ >/dev/null && break; sleep 0.5; done
curl -sf -H "apikey: $ANON_KEY" http://127.0.0.1:54321/rest/v1/ >/dev/null || { echo "rest did not start"; tail -20 "$RUN/postgrest.log"; exit 1; }

cat > .env.stack <<ENV
# Written by local-stack/up.sh. Local keys only: they open nothing outside this machine.
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_SERVICE_ROLE_KEY=$SERVICE_KEY
LEDGER_CHECK_TOKEN=$LEDGER_CHECK_TOKEN
VITE_SUPABASE_URL=http://127.0.0.1:54321
VITE_SUPABASE_ANON_KEY=$ANON_KEY
SUPABASE_DB_URL=postgresql://$PGUSER@$DBHOST:$PGPORT/$DB
ENV
echo "LOCAL STACK UP  http://127.0.0.1:54321  (keys in .env.stack)"
