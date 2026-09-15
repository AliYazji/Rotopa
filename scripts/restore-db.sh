#!/usr/bin/env bash
# Restore a pg_dump -Fc backup taken by scripts/backup-db.sh.
#
#   scripts/restore-db.sh backups/rotopa_backup_20260101_120000.dump
#   PGURL="postgres://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" scripts/restore-db.sh <file>
#
# IMPORTANT — restores IN PLACE (pg_restore --clean --if-exists) against an
# ALREADY-RUNNING, already-Supabase-scaffolded, already Rotopa-MIGRATED
# target database. It does NOT drop/recreate the database itself, and the
# target must already have had supabase/migrations/*.sql applied at least
# once. Two things verified directly, the hard way:
#   1) Dropping/recreating the database first throws away Supabase's own
#      scaffolding (extensions, storage/realtime/vault schemas, roles,
#      event triggers) set up ONCE by the image's init scripts at first
#      boot — restoring an app-only dump into a bare database then fails on
#      objects this app never uses. backup-db.sh dumps ONLY the schemas
#      this app owns (public/app/auth) to sidestep that entirely.
#   2) The target needs Rotopa's own migrations already applied so the
#      extensions THEY create (btree_gist etc., needed by e.g.
#      fiscal_periods' exclusion constraint) already exist — a restore
#      only recreates tables/functions/data, never extensions.
# A handful of "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin ... must
# be member of role" warnings are expected and harmless — those are
# Supabase's own public-schema boot scaffolding, unrelated to any of this
# app's own grants (which restore correctly, see backup-db.sh's comment).
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "usage: scripts/restore-db.sh <path-to-.dump-file>" >&2
  ls -1t backups/rotopa_backup_*.dump 2>/dev/null | head -5 | sed 's/^/  available: /' >&2
  exit 1
fi

CONTAINER="${PGCONTAINER:-supabase_db_rotopa-erp}"
DB="${PGDATABASE:-postgres}"

if [ -n "${PGURL:-}" ]; then
  TARGET_DESC="$PGURL"
else
  TARGET_DESC="database \"$DB\" in container \"$CONTAINER\" (must already exist and be Supabase-scaffolded)"
fi

echo "This will overwrite every application table in $TARGET_DESC with the contents of:"
echo "  $FILE"
echo "Type the database name (\"$DB\") to confirm, or anything else to cancel:"
read -r CONFIRM
if [ "$CONFIRM" != "$DB" ]; then
  echo "cancelled — no changes made."
  exit 1
fi

command_missing() { ! command -v "$1" >/dev/null 2>&1; }

if [ -n "${PGURL:-}" ]; then
  command_missing pg_restore && { echo "pg_restore not found on PATH." >&2; exit 1; }
  pg_restore -d "$PGURL" --clean --if-exists --no-owner "$FILE"
else
  docker cp "$FILE" "$CONTAINER:/tmp/restore.dump"
  docker exec "$CONTAINER" pg_restore -U postgres -d "$DB" --clean --if-exists --no-owner /tmp/restore.dump
  docker exec "$CONTAINER" rm -f /tmp/restore.dump
fi

echo "restore complete."
echo "reminder: a whole-database dump/restore includes the auth schema too — logins now match the BACKUP's point in time, not whatever existed right before this restore."
