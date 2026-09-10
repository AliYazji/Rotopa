#!/usr/bin/env bash
# Apply every migration to a throwaway Postgres and run the test suite.
# Usage:  supabase/tests/run.sh            (uses docker container rotopa-pgtest)
#         PGURL=postgres://... supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

IMAGE="public.ecr.aws/supabase/postgres:15.6.1.139"
CONTAINER="rotopa-pgtest"

if [ -z "${PGURL:-}" ]; then
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -p 55432:5432 "$IMAGE" >/dev/null
    until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  fi
  RUN() { docker exec -i "$CONTAINER" psql -U postgres "$@"; }
  RESET() { docker exec "$CONTAINER" psql -U postgres -q -c "drop database if exists rotopa" -c "create database rotopa" >/dev/null; }
  DB=(-d rotopa)
else
  RUN() { psql "$PGURL" "$@"; }
  RESET() { :; }
  DB=()
fi

RESET
echo "── applying migrations ──"
for f in supabase/tests/00_shim.sql supabase/migrations/*.sql; do
  printf '  %s\n' "$(basename "$f")"
  RUN "${DB[@]}" -v ON_ERROR_STOP=1 -q < "$f"
done

echo "── running tests ──"
fail=0
for t in supabase/tests/[0-9][0-9]_*.sql; do
  [ "$(basename "$t")" = "00_shim.sql" ] && continue
  out=$(RUN "${DB[@]}" -v ON_ERROR_STOP=1 < "$t" 2>&1) || { echo "  ✗ $(basename "$t")"; echo "$out" | sed 's/^/      /'; fail=1; continue; }
  echo "  ✓ $(basename "$t")"
  echo "$out" | grep -E 'NOTICE' | sed 's/^/      /' || true
done
exit $fail
