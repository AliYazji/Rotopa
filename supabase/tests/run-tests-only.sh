#!/usr/bin/env bash
# Run every test file against a database that ALREADY has the full schema
# (and, usually, real data) — unlike run.sh, this never touches migrations
# or drops/recreates anything. Each test file is self-contained (creates
# its own org via create_organization() inside begin;...rollback;), so it
# doesn't care what else is already in the database.
#
# The one legitimate use for this instead of run.sh: proving an EXISTING
# database (a restored backup, a Supabase Cloud project already pushed to)
# is still fully functional, without wiping it first.
#
#   PGURL=postgres://... supabase/tests/run-tests-only.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ -z "${PGURL:-}" ]; then
  echo "PGURL is required — this script never manages its own throwaway container (see run.sh for that)." >&2
  exit 1
fi

fail=0
for t in supabase/tests/[0-9]*_*.sql; do
  [ "$(basename "$t")" = "00_shim.sql" ] && continue
  out=$(psql "$PGURL" -v ON_ERROR_STOP=1 < "$t" 2>&1) || { echo "  ✗ $(basename "$t")"; echo "$out" | sed 's/^/      /'; fail=1; continue; }
  echo "  ✓ $(basename "$t")"
  echo "$out" | grep -E 'NOTICE' | sed 's/^/      /' || true
done
exit $fail
