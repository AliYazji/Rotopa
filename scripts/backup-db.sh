#!/usr/bin/env bash
# Take a full pg_dump -Fc backup of the Rotopa database, timestamped, kept
# under backups/ (gitignored). Formalizes the manual `docker exec ... pg_dump`
# routine this project has run by hand before every destructive DB action
# all session — same command, now a single reusable script with retention.
#
#   scripts/backup-db.sh                       # local dev container, db "postgres"
#   PGCONTAINER=supabase_db_rotopa-erp scripts/backup-db.sh
#   PGURL="postgres://postgres:<pw>@db.<ref>.supabase.co:5432/postgres" scripts/backup-db.sh
#     (PGURL mode needs a native pg_dump on PATH — not available in every
#     dev environment; the default docker-exec mode needs none)
#
# KEEP defaults to 10 — older backups beyond that are deleted automatically.
set -euo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1   # Git Bash on Windows otherwise mangles /tmp/... into a Windows path

CONTAINER="${PGCONTAINER:-supabase_db_rotopa-erp}"
DB="${PGDATABASE:-postgres}"
KEEP="${KEEP:-10}"

mkdir -p backups
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT="backups/rotopa_backup_${STAMP}.dump"

# Scoped to the schemas this app actually owns: public (all app tables),
# app (SECURITY DEFINER auth helpers), auth (Supabase Auth's real users —
# genuinely needed, logins live there). Deliberately EXCLUDES Supabase's own
# service schemas (storage/vault/realtime/_realtime/supabase_functions/
# graphql/pgbouncer/supabase_migrations) — this app never uses them, they're
# owned by supabase_admin (not the postgres role backups run as), and
# including them produced 600+ permission-denied/missing-extension errors on
# restore for objects that carry no application data at all (verified
# directly). Every one of those schemas is reprovisioned identically by the
# Supabase image's own boot-time init scripts on any fresh target anyway.
SCHEMAS=(-n public -n app -n auth)
# GRANT/REVOKE statements are kept (no --no-privileges): every migration in
# this project pairs each function with its own explicit "revoke all ...
# from public, anon; grant execute ... to authenticated" — those are
# load-bearing, not redundant scaffolding. Verified directly: a restore
# uses pg_restore --clean, which DROPS and RECREATES each object; a
# recreated function in this Supabase image gets NO default execute grant
# for a role other than its owner, so without the dump's own GRANT
# statements, every RPC becomes uncallable by "authenticated" after
# restore ("function ... does not exist", since an inaccessible overload is
# excluded from resolution — not the more obvious "permission denied").
# restore-db.sh's own comment explains the small number of harmless,
# unavoidable warnings this still produces for Supabase-internal
# "ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin" statements.
DUMP_OPTS=("${SCHEMAS[@]}" -Fc)

if [ -n "${PGURL:-}" ]; then
  command -v pg_dump >/dev/null 2>&1 || { echo "pg_dump not found on PATH — use the default docker-exec mode instead, or install the postgresql-client tools." >&2; exit 1; }
  pg_dump "$PGURL" "${DUMP_OPTS[@]}" -f "$OUT"
else
  docker exec "$CONTAINER" pg_dump -U postgres -d "$DB" "${DUMP_OPTS[@]}" -f "/tmp/rotopa_backup_${STAMP}.dump"
  docker cp "$CONTAINER:/tmp/rotopa_backup_${STAMP}.dump" "$OUT"
  docker exec "$CONTAINER" rm -f "/tmp/rotopa_backup_${STAMP}.dump"
fi

SIZE="$(du -h "$OUT" | cut -f1)"
echo "backed up: $OUT ($SIZE)"

# retention — keep only the newest $KEEP dumps
mapfile -t OLD < <(ls -1t backups/rotopa_backup_*.dump 2>/dev/null | tail -n +$((KEEP + 1)))
if [ "${#OLD[@]}" -gt 0 ]; then
  echo "pruning ${#OLD[@]} backup(s) older than the newest $KEEP:"
  for f in "${OLD[@]}"; do echo "  - $f"; rm -f "$f"; done
fi
