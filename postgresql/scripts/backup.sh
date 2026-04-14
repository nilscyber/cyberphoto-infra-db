#!/usr/bin/env bash
#
# Logical backup of every database in the Patroni cluster.
#
# Runs from the host VM via cron. Uses `docker exec patroni` so pg_dump
# always matches the server version — no PostgreSQL client needed on the
# host. Dumps go through HAProxy's replica pool (127.0.0.1:5001) so the
# primary is not loaded, regardless of which node this script runs on.
#
# Install on ONE node's crontab (e.g. pg-node2):
#   0 2 * * *  /opt/cyberphoto-infra-db/postgresql/scripts/backup.sh >> /var/log/pg-backup.log 2>&1
#
# Runtime overrides — any of these can be set in the environment without
# editing the script. Defaults are in the Config block below.
#
#   BACKUP_ROOT      where dated backup dirs are written
#                    e.g.  BACKUP_ROOT=/mnt/nas/pg-backups ./backup.sh
#   RETENTION_DAYS   dated dirs older than this are deleted
#                    e.g.  RETENTION_DAYS=30 ./backup.sh
#   ENV_FILE         path to the docker-compose .env with POSTGRES_PASSWORD
#                    e.g.  ENV_FILE=/root/patroni/.env ./backup.sh
#   CONTAINER        name of the Patroni docker container
#                    e.g.  CONTAINER=patroni-prod ./backup.sh
#   PG_HOST          host pg_dump connects to (always inside the container)
#                    e.g.  PG_HOST=127.0.0.1 ./backup.sh
#   PG_PORT          5432 = local node direct, 5001 = HAProxy replica pool
#                    e.g.  PG_PORT=5001 ./backup.sh
#   PG_USER          superuser to dump as
#                    e.g.  PG_USER=postgres ./backup.sh
#   JOBS             parallelism hint (reserved — current dumps are serial)
#                    e.g.  JOBS=4 ./backup.sh
#   LOCK_FILE        flock path to prevent overlapping runs
#                    e.g.  LOCK_FILE=/tmp/pg-backup.lock ./backup.sh
#
# Combine as many as you like on one line:
#   BACKUP_ROOT=/mnt/nas/pg RETENTION_DAYS=30 PG_PORT=5001 ./backup.sh
# Or for crontagb
#   0 2 * * *  RETENTION_DAYS=30 /opt/cyberphoto-infra-db/postgresql/scripts/backup.sh >> /var/log/pg-backup.log 2>&1

set -Eeuo pipefail

# ─── Config ─────────────────────────────────────────────────────────────
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/postgres}"
ENV_FILE="${ENV_FILE:-/opt/patroni/.env}"
CONTAINER="${CONTAINER:-patroni}"
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"          # HAProxy replica pool
PG_USER="${PG_USER:-postgres}"
RETENTION_DAYS="${RETENTION_DAYS:-2}"
JOBS="${JOBS:-3}"                    # parallelism for directory-format dumps
LOCK_FILE="${LOCK_FILE:-/var/lock/pg-backup.lock}"
# ────────────────────────────────────────────────────────────────────────

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

trap 'die "failed at line $LINENO"' ERR

# Single-instance guard — skip if a previous run is still going.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another backup is running, exiting"; exit 0; }

[[ -r "$ENV_FILE" ]] || die "env file not readable: $ENV_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${POSTGRES_PASSWORD:-}" ]] || die "POSTGRES_PASSWORD missing from $ENV_FILE"

docker inspect -f '{{.State.Running}}' "$CONTAINER" >/dev/null 2>&1 \
    || die "container '$CONTAINER' is not running"

STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="$BACKUP_ROOT/$STAMP"
mkdir -p "$DEST"
chmod 700 "$BACKUP_ROOT" "$DEST"

# Helper: run a psql/pg_dump command inside the container, with password
# supplied via env var so it never appears in `ps`.
pg() {
    docker exec -i \
        -e PGPASSWORD="$POSTGRES_PASSWORD" \
        "$CONTAINER" "$@"
}

log "backup start → $DEST (host=$PG_HOST port=$PG_PORT)"

# 1. Globals: roles, tablespaces, privileges. Required before restoring
#    any individual database onto a fresh cluster.
log "dumping globals"
pg pg_dumpall \
    -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
    --globals-only \
    | zstd -q -19 -o "$DEST/_globals.sql.zst"

# 2. Enumerate user databases.
mapfile -t DBS < <(
    pg psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres \
        -XAtc "SELECT datname FROM pg_database
               WHERE datallowconn AND datname NOT IN ('template0','template1')
               ORDER BY datname;"
)
[[ ${#DBS[@]} -gt 0 ]] || die "no databases found"
log "databases: ${DBS[*]}"

# 3. Per-database custom-format dump with zstd compression.
#    -Fc is a single file, easy to ship around and restore selectively.
#    --compress=zstd:9 requires PG 16+ (we run 18).
for db in "${DBS[@]}"; do
    out="$DEST/${db}.dump"
    log "dumping $db"
    pg pg_dump \
        -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
        -d "$db" \
        --format=custom \
        --compress=zstd:9 \
        --no-owner \
        --no-sync \
        --verbose \
        --file=/dev/stdout \
        > "$out" 2> "$DEST/${db}.log"
done

# 4. Manifest with sizes + checksums for integrity verification.
(
    cd "$DEST"
    {
        echo "# pg-backup manifest $STAMP"
        echo "# host=$(hostname)  pg_host=$PG_HOST  pg_port=$PG_PORT"
        echo "# container=$CONTAINER"
        sha256sum _globals.sql.zst ./*.dump
    } > MANIFEST.txt
)

log "backup ok, size=$(du -sh "$DEST" | cut -f1)"

# 5. Retention: delete dated directories older than RETENTION_DAYS.
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' \
    -mtime "+$RETENTION_DAYS" -print -exec rm -rf {} +

log "backup done"
