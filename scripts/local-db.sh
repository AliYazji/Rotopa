#!/usr/bin/env bash
# Create/refresh a PERSISTENT local dev database (separate from the ephemeral
# test DB that supabase/tests/run.sh wipes). Applies the auth shim + migrations.
#
#   scripts/local-db.sh                # create/replace rotopa_dev on rotopa-pgtest
#   DB=rotopa_dev PGCONTAINER=... scripts/local-db.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DB="${DB:-rotopa_dev}"
CONTAINER="${PGCONTAINER:-rotopa-pgtest}"
IMAGE="public.ecr.aws/supabase/postgres:15.6.1.139"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -p 55432:5432 "$IMAGE" >/dev/null
  until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
fi

docker exec "$CONTAINER" psql -U postgres -q -c "drop database if exists $DB" -c "create database $DB" >/dev/null
for f in supabase/tests/00_shim.sql supabase/migrations/*.sql; do
  docker exec -i "$CONTAINER" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -q < "$f"
done
echo "ready: postgres://postgres:postgres@localhost:55432/$DB"
