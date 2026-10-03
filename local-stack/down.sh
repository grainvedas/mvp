#!/usr/bin/env bash
# Stops the local stack started by local-stack/up.sh.
cd "$(dirname "$0")"
pids=""
for s in gateway functions storage postgrest auth; do
  [ -f "run/$s.pid" ] && { p=$(cat "run/$s.pid"); kill "$p" 2>/dev/null && pids="$pids $p"; rm -f "run/$s.pid"; }
done
# An auth server whose pid was not recorded (an interrupted start) would keep answering on the same port and keep
# the database open: stop any that still runs from this folder. (Linux only; elsewhere the pid file is the record.)
for p in $(pgrep -x auth 2>/dev/null); do
  [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$PWD/bin" ] && kill "$p" 2>/dev/null && pids="$pids $p"
done
for i in $(seq 1 20); do
  alive=0; for p in $pids; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ $alive -eq 0 ] && break; sleep 0.25
done
echo "local stack stopped"
