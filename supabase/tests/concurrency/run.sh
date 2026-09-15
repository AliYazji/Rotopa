#!/usr/bin/env bash
# Real concurrency test: two genuinely simultaneous attempts to sell 8 units
# each from a 10-unit stock fixture (16 > 10 — only one may legitimately
# succeed). Proves post_stock_move()'s `select ... for update` row lock on
# item_warehouse_balances actually serializes concurrent access instead of
# both transactions reading the same stale balance and both succeeding
# (a classic lost-update overselling bug). No artificial pg_sleep is
# injected into the critical section (that would mean patching app code
# just for a test) — real OS/network/DB concurrency from two backgrounded
# processes is enough to exercise it, and Postgres's row-level locking
# guarantees the correct outcome under ANY interleaving the OS produces.
#
#   supabase/tests/concurrency/run.sh                    (local Docker container)
#   PGURL=postgres://postgres:postgres@localhost:5432/postgres supabase/tests/concurrency/run.sh
#     (CI mode — same dual-mode pattern as supabase/tests/run.sh; needs a
#     native psql on PATH, and connects to a database it creates itself:
#     "rotopa_concurrency" alongside whatever database PGURL points at)
set -euo pipefail
cd "$(dirname "$0")/../../.."

DB="rotopa_concurrency"

if [ -z "${PGURL:-}" ]; then
  IMAGE="public.ecr.aws/supabase/postgres:15.6.1.139"
  CONTAINER="rotopa-pgtest"
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -p 55432:5432 "$IMAGE" >/dev/null
    until docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
  fi
  docker exec "$CONTAINER" psql -U postgres -q -c "drop database if exists $DB" -c "create database $DB" >/dev/null
  RUN() { docker exec -i "$CONTAINER" psql -U postgres -d "$DB" "$@"; }
  TARGET_URL="postgres://postgres:postgres@localhost:55432/$DB"
else
  BASE_URL="${PGURL%/*}"
  psql "$PGURL" -q -c "drop database if exists $DB" -c "create database $DB" >/dev/null
  TARGET_URL="$BASE_URL/$DB"
  RUN() { psql "$TARGET_URL" "$@"; }
fi

echo "── applying migrations ──"
for f in supabase/tests/00_shim.sql supabase/migrations/*.sql; do
  RUN -v ON_ERROR_STOP=1 -q < "$f"
done

echo "── fixture: 10 units on hand ──"
RUN -v ON_ERROR_STOP=1 -q < supabase/tests/concurrency/setup.sql

echo "── launching two concurrent 8-unit sell attempts ──"
RUN < supabase/tests/concurrency/attempt.sql > /tmp/attempt_a.out 2>&1 &
PID_A=$!
RUN < supabase/tests/concurrency/attempt.sql > /tmp/attempt_b.out 2>&1 &
PID_B=$!
wait "$PID_A" "$PID_B"

RESULT_A=$(grep -o 'RESULT: [a-z_]*' /tmp/attempt_a.out || echo "RESULT: NONE")
RESULT_B=$(grep -o 'RESULT: [a-z_]*' /tmp/attempt_b.out || echo "RESULT: NONE")
echo "  attempt A: $RESULT_A"
echo "  attempt B: $RESULT_B"

FINAL_QTY=$(RUN -t -A -c "select qty from item_warehouse_balances where item_id = (select v from concurrency_handshake where k='item_id');" | tr -d '[:space:]')
echo "  final on-hand: $FINAL_QTY"

FAIL=0
SUCCESSES=$(printf '%s\n%s\n' "$RESULT_A" "$RESULT_B" | grep -c 'RESULT: success' || true)
REJECTIONS=$(printf '%s\n%s\n' "$RESULT_A" "$RESULT_B" | grep -c 'RESULT: insufficient_stock' || true)

if [ "$SUCCESSES" -ne 1 ]; then
  echo "  ✗ expected exactly 1 success, got $SUCCESSES — an oversell race condition would show 2"
  FAIL=1
fi
if [ "$REJECTIONS" -ne 1 ]; then
  echo "  ✗ expected exactly 1 insufficient_stock rejection, got $REJECTIONS"
  FAIL=1
fi
if [ "$FINAL_QTY" != "2.0000" ]; then
  echo "  ✗ expected final on-hand to be exactly 2 (10 - 8), got $FINAL_QTY"
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "✓ CONCURRENCY: STOCK OVERSELL GUARD HOLDS UNDER REAL CONCURRENT ACCESS"
else
  echo "✗ CONCURRENCY TEST FAILED — see output above"
  echo "--- attempt A full output ---"; cat /tmp/attempt_a.out
  echo "--- attempt B full output ---"; cat /tmp/attempt_b.out
fi
rm -f /tmp/attempt_a.out /tmp/attempt_b.out
exit $FAIL
