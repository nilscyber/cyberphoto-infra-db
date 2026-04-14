#!/usr/bin/env bash
#
# Restore from a backup produced by backup.sh. Runs from the host VM,
# shells into the `patroni` container, and writes through HAProxy's
# primary pool (127.0.0.1:5000) so the restore always lands on the
# current Patroni leader.
#
# Usage:
#   restore.sh <backup_dir>                    # restore ALL databases + globals
#   restore.sh <backup_dir> <db> [<db>...]     # restore only these databases
#   restore.sh <backup_dir> --globals-only     # restore only roles/tablespaces
#
# Flags:
#   --yes          skip confirmation prompt
#   --verify       just verify MANIFEST.txt checksums, do nothing else
#
# Examples:
#   restore.sh /var/backups/postgres/2026-04-14_020000
#   restore.sh /var/backups/postgres/2026-04-14_020000 adempiere --yes
#

set -Eeuo pipefail

# ─── Config ─────────────────────────────────────────────────────────────
ENV_FILE="${ENV_FILE:-/opt/cyberphoto-infra-db/postgresql/.env}"
CONTAINER="${CONTAINER:-patroni}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5000}"          # HAProxy primary pool
PG_USER="${PG_USER:-postgres}"
JOBS="${JOBS:-4}"                    # pg_restore parallelism
# ────────────────────────────────────────────────────────────────────────

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "failed at line $LINENO"' ERR

ASSUME_YES=0
VERIFY_ONLY=0
GLOBALS_ONLY=0
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)        ASSUME_YES=1 ;;
        --verify)        VERIFY_ONLY=1 ;;
        --globals-only)  GLOBALS_ONLY=1 ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        -*)              die "unknown flag: $1" ;;
        *)               POSITIONAL+=("$1") ;;
    esac
    shift
done
set -- "${POSITIONAL[@]}"

[[ $# -ge 1 ]] || die "usage: $0 <backup_dir> [db ...] [--yes] [--verify]"
BACKUP_DIR="$1"; shift
REQUESTED_DBS=("$@")

[[ -d "$BACKUP_DIR" ]] || die "backup dir not found: $BACKUP_DIR"
[[ -f "$BACKUP_DIR/MANIFEST.txt" ]] || die "no MANIFEST.txt in $BACKUP_DIR"

# ─── Verify checksums ───────────────────────────────────────────────────
log "verifying checksums in $BACKUP_DIR"
(
    cd "$BACKUP_DIR"
    grep -E '^[0-9a-f]{64}  ' MANIFEST.txt | sha256sum -c --quiet
) || die "checksum verification failed — refusing to restore"
log "checksums ok"

[[ $VERIFY_ONLY -eq 1 ]] && { log "verify-only, exiting"; exit 0; }

# ─── Env + container checks ─────────────────────────────────────────────
[[ -r "$ENV_FILE" ]] || die "env file not readable: $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${POSTGRES_PASSWORD:-}" ]] || die "POSTGRES_PASSWORD missing from $ENV_FILE"

docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
    || die "container '$CONTAINER' is not running"

pg() {
    docker exec -i \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$CONTAINER" "$@"
}

pg_stdin() {
    docker exec -i \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$CONTAINER" "$@"
}

# Confirm we're actually pointed at the Patroni leader (HAProxy /primary
# health check gives us this implicitly, but double-check by asking PG).
IN_RECOVERY=$(pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
    -XAtc "SELECT pg_is_in_recovery();" | tr -d '[:space:]')
[[ "$IN_RECOVERY" == "f" ]] || die "target $PG_HOST:$PG_PORT is not a primary (in_recovery=$IN_RECOVERY)"

# ─── Decide what to restore ─────────────────────────────────────────────
if [[ $GLOBALS_ONLY -eq 1 ]]; then
    DBS=()
elif [[ ${#REQUESTED_DBS[@]} -gt 0 ]]; then
    DBS=("${REQUESTED_DBS[@]}")
    for db in "${DBS[@]}"; do
        [[ -f "$BACKUP_DIR/${db}.dump" ]] || die "no dump for db '$db' in $BACKUP_DIR"
    done
else
    mapfile -t DBS < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -printf '%f\n' \
            | sed 's/\.dump$//' | sort
    )
fi

# ─── Confirmation ───────────────────────────────────────────────────────
echo
echo "About to restore into $PG_HOST:$PG_PORT (container=$CONTAINER)"
echo "  source:  $BACKUP_DIR"
echo "  globals: $([[ ${#REQUESTED_DBS[@]} -eq 0 || $GLOBALS_ONLY -eq 1 ]] && echo yes || echo no)"
echo "  dbs:     ${DBS[*]:-<none>}"
echo
echo "Each target database will be DROPPED and recreated. Connections will be terminated."
if [[ $ASSUME_YES -ne 1 ]]; then
    read -r -p "Type 'RESTORE' to continue: " ans
    [[ "$ans" == "RESTORE" ]] || die "aborted"
fi

# ─── Globals ────────────────────────────────────────────────────────────
# Only restore globals when doing a full restore or --globals-only, to
# avoid stomping on live roles when you're just rolling back one db.
if [[ ${#REQUESTED_DBS[@]} -eq 0 || $GLOBALS_ONLY -eq 1 ]]; then
    log "restoring globals"
    zstd -dc "$BACKUP_DIR/_globals.sql.zst" \
        | pg_stdin psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
            -d postgres -v ON_ERROR_STOP=1 --quiet
fi

# ─── Per-database restore ──────────────────────────────────────────────
for db in "${DBS[@]}"; do
    dump="$BACKUP_DIR/${db}.dump"
    log "restoring $db from $dump"

    # Terminate existing sessions so DROP DATABASE can proceed.
    pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -v ON_ERROR_STOP=1 -XAtc \
        "SELECT pg_terminate_backend(pid)
           FROM pg_stat_activity
          WHERE datname = '$db' AND pid <> pg_backend_pid();" >/dev/null

    pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -v ON_ERROR_STOP=1 -XAtc "DROP DATABASE IF EXISTS \"$db\";"
    pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -v ON_ERROR_STOP=1 -XAtc "CREATE DATABASE \"$db\";"

    # pg_restore --jobs requires a seekable file, so stage the dump
    # inside the container instead of piping it over stdin.
    staged="/tmp/restore_${db}_$$.dump"
    docker cp "$dump" "$CONTAINER:$staged"
    pg pg_restore \
        -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
        -d "$db" \
        --jobs="$JOBS" \
        --no-owner \
        --exit-on-error \
        --verbose \
        "$staged" \
        && docker exec "$CONTAINER" rm -f "$staged" \
        || { docker exec "$CONTAINER" rm -f "$staged"; die "pg_restore failed for $db"; }

    pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" \
        -v ON_ERROR_STOP=1 -XAtc "ANALYZE;" >/dev/null
    log "$db restored"
done

log "restore done"
