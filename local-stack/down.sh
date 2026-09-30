#!/usr/bin/env bash
# Stops the local stack started by local-stack/up.sh.
cd "$(dirname "$0")"
for s in gateway functions postgrest auth; do
  [ -f "run/$s.pid" ] && kill "$(cat "run/$s.pid")" 2>/dev/null && rm -f "run/$s.pid"
done
echo "local stack stopped"
