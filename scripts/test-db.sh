#!/usr/bin/env bash
# Applies every migration to a throwaway Postgres and runs the RLS tests.
# Needs Postgres server binaries (initdb, pg_ctl) and psql. Nothing touches
# your real Supabase project.
#
#   npm run test:db
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
PATH="${PG_BIN:+$PG_BIN:}$PATH"
PORT="${TEST_DB_PORT:-54329}"
DATA="$(mktemp -d)"

# Postgres refuses to run as root; use the postgres account when we are root.
run() {
  if [ "$(id -u)" = 0 ]; then su postgres -s /bin/bash -c "PATH='$PATH' $*"; else bash -c "$*"; fi
}
[ "$(id -u)" = 0 ] && chown postgres "$DATA"

cleanup() { run "pg_ctl -D '$DATA' -m immediate stop" >/dev/null 2>&1 || true; }
trap cleanup EXIT

run "initdb -D '$DATA' -U postgres --auth=trust" >/dev/null
run "pg_ctl -D '$DATA' -o '-p $PORT -k /tmp' -l '$DATA/log' -w start" >/dev/null

PSQL=(psql -X -q -v ON_ERROR_STOP=1 -h /tmp -p "$PORT" -U postgres -d postgres)
"${PSQL[@]}" -f "$ROOT/supabase/tests/supabase_stub.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do
  "${PSQL[@]}" -f "$f"
done
"${PSQL[@]}" -f "$ROOT/supabase/tests/rls_test.sql"
