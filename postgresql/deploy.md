# Patroni HA PostgreSQL — Deployment Guide

## VM Setup (repeat on all 3 nodes)

### 1. Create Proxmox VMs

Create 3 VMs. The primary needs the most resources; replicas can be smaller.

| Setting  | Node 1 (primary)       | Nodes 2 & 3 (replicas)   |
|----------|------------------------|--------------------------|
| OS       | Ubuntu 24.04 LTS       | Ubuntu 24.04 LTS         |
| CPU      | 8 vCPUs                | 4+ vCPUs                 |
| RAM      | 50 GB                  | 16–32 GB                 |
| Disk     | 250 GB (NVMe-backed)   | 250 GB (NVMe-backed)     |
| Network  | Bridge to 172.16.0.0/16 | Bridge to 172.16.0.0/16  |

Note: Replicas need the same disk size as the primary (they hold a full copy),
but can run with less RAM and CPU. PostgreSQL memory settings are configured
per node via `.env` — see step 5. Since the Proxmox hosts use M.2 NVMe
storage, a single disk is sufficient.

Assign static IPs:

| Node   | IP            |
|--------|---------------|
| Node 1 | 172.16.0.201  |
| Node 2 | 172.16.0.202  |
| Node 3 | 172.16.0.203  |
| VIP    | 172.16.0.200  |

### 2. Install Docker

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

### 3. Create patroni user and directories

```bash
# Create a dedicated user (no login shell needed)
useradd -r -m -d /opt/patroni -s /usr/sbin/nologin patroni

# Add to docker group (docker group exists now that Docker is installed)
usermod -aG docker patroni

# Create data directories
mkdir -p /var/lib/patroni/pgdata /var/lib/patroni/etcd-data

# pgdata is mounted as /var/lib/postgresql in the container.
# Patroni/initdb creates the "data" subdirectory inside it, so the
# mount point itself must be owned by UID 999 (postgres in the container).
chown 999:999 /var/lib/patroni/pgdata

# etcd-data owned by the patroni user
chown patroni:patroni /var/lib/patroni/etcd-data
```

### 4. Copy project files

Copy the entire `postgresql/` directory to each node:

```bash
scp -r postgresql/ root@172.16.0.201:/opt/patroni/
scp -r postgresql/ root@172.16.0.202:/opt/patroni/
scp -r postgresql/ root@172.16.0.203:/opt/patroni/
```

Then on each node, set ownership:

```bash
chown -R patroni:patroni /opt/patroni
chmod 600 /opt/patroni/.env    # restrict .env since it contains passwords
```

### 5. Create .env per node

On each node, copy `.env.example` to `.env` and configure:

```bash
sudo -u patroni cp /opt/patroni/.env.example /opt/patroni/.env
```

**Node 1** (primary, 50 GB RAM) — `.env`:
```
NODE_NAME=pg-node1
NODE_IP=172.16.0.201
ETCD_NAME=etcd1
KEEPALIVED_STATE=MASTER
KEEPALIVED_PRIORITY=150
KEEPALIVED_INTERFACE=ens19
PG_SHARED_BUFFERS=10GB
PG_EFFECTIVE_CACHE_SIZE=40GB
PG_WORK_MEM=64MB
PG_MAINTENANCE_WORK_MEM=2GB
POSTGRES_PASSWORD=<your-superuser-password>
REPLICATION_PASSWORD=<your-replication-password>
REWIND_PASSWORD=<your-rewind-password>
ADEMPIERE_PASSWORD=<your-adempiere-password>
KEEPALIVED_PASSWORD=<your-keepalived-password>
```

**Node 2** (replica, 32 GB RAM) — `.env`:
```
NODE_NAME=pg-node2
NODE_IP=172.16.0.202
ETCD_NAME=etcd2
KEEPALIVED_STATE=BACKUP
KEEPALIVED_PRIORITY=100
KEEPALIVED_INTERFACE=ens19
PG_SHARED_BUFFERS=6GB
PG_EFFECTIVE_CACHE_SIZE=24GB
PG_WORK_MEM=32MB
PG_MAINTENANCE_WORK_MEM=1GB
POSTGRES_PASSWORD=<same-superuser-password>
REPLICATION_PASSWORD=<same-replication-password>
REWIND_PASSWORD=<same-rewind-password>
ADEMPIERE_PASSWORD=<same-adempiere-password>
KEEPALIVED_PASSWORD=<same-keepalived-password>
```

**Node 3** (replica, 16 GB RAM) — `.env`:
```
NODE_NAME=pg-node3
NODE_IP=172.16.0.203
ETCD_NAME=etcd3
KEEPALIVED_STATE=BACKUP
KEEPALIVED_PRIORITY=50
KEEPALIVED_INTERFACE=ens19
PG_SHARED_BUFFERS=3GB
PG_EFFECTIVE_CACHE_SIZE=12GB
PG_WORK_MEM=16MB
PG_MAINTENANCE_WORK_MEM=512MB
POSTGRES_PASSWORD=<same-superuser-password>
REPLICATION_PASSWORD=<same-replication-password>
REWIND_PASSWORD=<same-rewind-password>
ADEMPIERE_PASSWORD=<same-adempiere-password>
KEEPALIVED_PASSWORD=<same-keepalived-password>
```

All passwords must be identical across all 3 nodes. The `PG_*` memory
settings are per-node overrides — adjust to match each node's actual RAM.
A good rule of thumb: `shared_buffers` = ~25% of RAM,
`effective_cache_size` = ~75% of RAM.

---

## Deployment

All remaining commands should be run as the patroni user:

```bash
sudo -u patroni -i
cd /opt/patroni
```

### Step 1: Build images (on each node)

```bash
docker compose build
```

### Step 2: Start etcd on ALL 3 nodes first

```bash
docker compose up -d etcd
```

Wait until the etcd cluster is healthy:

```bash
docker exec etcd etcdctl member list
docker exec etcd etcdctl endpoint health
```

All 3 members should be listed and healthy before proceeding.

### Step 3: Start Patroni on Node 1

Node 1 will bootstrap as the primary and create the `adempiere` database:

```bash
docker compose up -d patroni
```

Watch the logs until it reports itself as the leader:

```bash
docker compose logs -f patroni
```

Verify:

```bash
docker exec patroni patronictl -c /tmp/patroni.yml list
```

### Step 4: Start Patroni on Nodes 2 and 3

Once Node 1 is running as leader, start Patroni on the other nodes.
They will automatically clone from the primary via pg_basebackup.

```bash
docker compose up -d patroni
```

Monitor cloning progress:

```bash
docker compose logs -f patroni
```

### Step 5: Start HAProxy on all 3 nodes

```bash
docker compose up -d haproxy
```

Verify HAProxy stats at `http://172.16.0.201:7000` — you should see
one green (primary) backend on port 5000 and two green (replica) backends
on port 5001.

### Step 6: Start keepalived on all 3 nodes

```bash
docker compose up -d keepalived
```

Verify the VIP is active:

```bash
ip addr show ens19 | grep 172.16.0.200
```

This should show the VIP on the MASTER node (Node 1).

### Step 7: Test connectivity

```bash
# Read-write via VIP
psql -h 172.16.0.200 -p 5000 -U adempiere -d adempiere -c "SELECT 1;"

# Read-only via VIP
psql -h 172.16.0.200 -p 5001 -U adempiere -d adempiere -c "SELECT 1;"
```

---

## Application connection strings

| Purpose    | Connection string                                          |
|------------|------------------------------------------------------------|
| Read-write | `postgresql://adempiere:<password>@172.16.0.200:5000/adempiere` |
| Read-only  | `postgresql://adempiere:<password>@172.16.0.200:5001/adempiere` |

---

## Backups

Logical backups are produced by [`scripts/backup.sh`](scripts/backup.sh),
which shells into the `patroni` container via `docker exec` so `pg_dump`
always matches the running server version (no host PostgreSQL client
needed). Each run creates a timestamped directory containing:

- `_globals.sql.zst` — roles, tablespaces, privileges (from `pg_dumpall --globals-only`)
- `<dbname>.dump` — one custom-format, zstd-compressed dump per user database
- `MANIFEST.txt` — SHA-256 checksums for integrity verification
- `<dbname>.log` — per-database `pg_dump` verbose log

A `flock` on `/var/lock/pg-backup.lock` prevents overlapping runs, and
dated directories older than `RETENTION_DAYS` are removed automatically.

### Install on ONE node (e.g. pg-node2)

Run the script on a single designated node — not all three. A replica is
the natural choice so dumps never load the primary.

```bash
# Create the backup destination, lock down the script and .env
sudo install -d -m 750 -o root -g root /var/backups/postgres
sudo chmod 750 /opt/patroni/scripts/backup.sh
sudo chmod 750 /opt/patroni/scripts/restore.sh
sudo chmod 600 /opt/patroni/.env
```

### Cron entry

Install as a drop-in under `/etc/cron.d/` so it runs as root (needed for
`docker exec`, reading `.env`, and writing to `/var/backups/postgres`):

```
# /etc/cron.d/pg-backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 2 * * * root ENV_FILE=/opt/patroni/.env RETENTION_DAYS=30 /opt/patroni/scripts/backup.sh >> /var/log/pg-backup.log 2>&1
```

All knobs can be set as env vars on the cron line — see the header
comment in [backup.sh](scripts/backup.sh) for the full list
(`BACKUP_ROOT`, `RETENTION_DAYS`, `ENV_FILE`, `CONTAINER`, `PG_HOST`,
`PG_PORT`, `PG_USER`, `LOCK_FILE`). Defaults target `127.0.0.1:5432`
(the local node) and `/var/backups/postgres`.

### Manual run

```bash
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/backup.sh
ls -lh /var/backups/postgres/
```

---

## Restoring from a backup

Restores are driven by [`scripts/restore.sh`](scripts/restore.sh). It
verifies the `MANIFEST.txt` checksums before touching anything, sanity-
checks that the target is actually the Patroni leader
(`pg_is_in_recovery() = f`), then for each requested database:
terminates existing sessions → `DROP DATABASE` → `CREATE DATABASE` →
`pg_restore --jobs=4` → `ANALYZE`.

Dumps are staged inside the container via `docker cp` so `pg_restore`'s
parallel mode (which needs a seekable file) works — stdin would force
serial restore.

By default the script connects to `127.0.0.1:5000` (HAProxy primary
pool), so it always lands on whichever node currently holds the leader
role, regardless of which node you run it from.

### Usage

```bash
# Full restore: all databases + globals
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/restore.sh \
    /var/backups/postgres/2026-04-14_020000

# Selective: restore only one database (globals untouched)
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/restore.sh \
    /var/backups/postgres/2026-04-14_020000 adempiere

# Only restore roles/tablespaces
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/restore.sh \
    /var/backups/postgres/2026-04-14_020000 --globals-only

# Just verify the backup's checksums — touches nothing
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/restore.sh \
    /var/backups/postgres/2026-04-14_020000 --verify

# Non-interactive (skip "type RESTORE to continue" prompt)
sudo ENV_FILE=/opt/patroni/.env /opt/patroni/scripts/restore.sh \
    /var/backups/postgres/2026-04-14_020000 adempiere --yes
```

The replicas pick up the restored data automatically via streaming
replication — no action needed on the other two nodes.

### Verify

```bash
docker exec patroni psql -U adempiere -d adempiere -c "\dt" | head -20
```

---

## Disaster recovery on a single VM

If all three Patroni nodes are lost and you only have a backup produced
by `backup.sh`, you can bring a standalone PostgreSQL up on any VM with
Docker and restore into it using `restore.sh`. No etcd, no HAProxy, no
keepalived, no Patroni — just one container serving the data until you
rebuild the full cluster later.

The key insight: `restore.sh` only assumes a PG container it can
`docker exec` into. Override `CONTAINER`, `PG_HOST`, and `PG_PORT` to
point at a vanilla `postgres:18` container and everything else works as
written.

### 1. Provision a fresh VM

Ubuntu 24.04, Docker installed (same one-liner block as step 2 of the
main deployment). Give it enough disk for the restored data.

### 2. Copy the backup and scripts to the VM

```bash
scp -r /path/to/2026-04-14_020000/ root@<new-vm>:/var/backups/postgres/
scp /opt/patroni/scripts/restore.sh   root@<new-vm>:/opt/dr/
```

### 3. Start a standalone PostgreSQL 18 container

**Important:** use the *original* cluster's superuser password as
`POSTGRES_PASSWORD`. The globals file from the backup contains an
`ALTER ROLE postgres` that resets the password on restore — if the new
container is initialized with a different password, the script will
fail partway through when it reconnects for the per-database restores.

```bash
# Data dir for the new instance (owned by UID 999, matching postgres in the image)
sudo install -d -m 700 -o 999 -g 999 /var/lib/pg-dr

# Start PG 18 — same version as the original cluster
docker run -d \
    --name patroni-dr \
    --restart unless-stopped \
    -p 5432:5432 \
    -v /var/lib/pg-dr:/var/lib/postgresql/data \
    -e POSTGRES_PASSWORD='<original-superuser-password>' \
    postgres:18

# Wait until it's ready
until docker exec patroni-dr pg_isready -U postgres; do sleep 1; done
```

Note: the container name `patroni-dr` is arbitrary — any name works as
long as you pass it via `CONTAINER=` below.

### 4. Create a minimal .env for restore.sh

`restore.sh` only reads `POSTGRES_PASSWORD` from its env file:

```bash
sudo tee /opt/dr/.env > /dev/null <<EOF
POSTGRES_PASSWORD=<original-superuser-password>
EOF
sudo chmod 600 /opt/dr/.env
```

### 5. Run the restore

```bash
sudo chmod 750 /opt/dr/restore.sh
sudo \
    ENV_FILE=/opt/dr/.env \
    CONTAINER=patroni-dr \
    PG_HOST=127.0.0.1 \
    PG_PORT=5432 \
    /opt/dr/restore.sh /var/backups/postgres/2026-04-14_020000 --yes
```

`restore.sh` will verify checksums, restore globals, then DROP/CREATE
and `pg_restore` each database in the backup. The `pg_is_in_recovery()`
leader check passes automatically on a standalone instance.

### 6. Verify and point applications at the new VM

```bash
docker exec patroni-dr psql -U postgres -c "\l"
docker exec patroni-dr psql -U adempiere -d adempiere -c "\dt" | head -20
```

Update application connection strings from the old VIP
(`172.16.0.200:5000`) to the new VM's address:

```
postgresql://adempiere:<password>@<new-vm-ip>:5432/adempiere
```

This gets you read-write service back on a single node in minutes.
Rebuild the full 3-node Patroni cluster from the main deployment guide
when time allows — once it's running as primary, stop `patroni-dr` and
cut applications back over to the VIP.

---

## Verification checklist

```bash
# Cluster status
docker exec patroni patronictl -c /tmp/patroni.yml list

# etcd health
docker exec etcd etcdctl endpoint health

# HAProxy stats
curl -s http://localhost:7000/

# VIP location
ip addr show ens19 | grep 172.16.0.200

# Failover test: stop patroni on the primary node
docker compose stop patroni
# Then check cluster status from another node — a new leader should be elected
```

---

## Failover and switchover

### Failover timeout

The cluster is configured with a `ttl` of 120 seconds. This means the primary
can be down for up to ~2 minutes before a replica is promoted. This gives enough
time to restart a node without triggering an automatic failover.

### Automatic failover

There are two scenarios:

**Clean shutdown** (`docker compose stop patroni`): Patroni voluntarily releases
the leader key — failover happens **immediately**. This is by design.

**Crash / network loss** (VM dies, kill -9, network partition): The leader key
expires after the ttl (120s) — failover happens after **~2 minutes**.

In both cases:
1. The most up-to-date replica is promoted
2. HAProxy routes traffic to the new primary within seconds
3. When the old primary comes back, it rejoins as a **replica** (not primary)

Patroni does **not** automatically switch back to the original primary. This is
by design — automatic switchbacks risk data inconsistency.

### Manual switchover (move primary back)

To move the primary role to a specific node (e.g. back to pg-node1 after it
recovers), run from any node:

```bash
docker exec patroni patronictl -c /tmp/patroni.yml switchover
```

Patroni will prompt for the target node and perform a graceful switchover
with zero downtime. You can also specify it directly:

```bash
docker exec patroni patronictl -c /tmp/patroni.yml switchover --leader pg-node2 --candidate pg-node1 --force
```

### Restarting the primary without failover

Since a clean shutdown triggers immediate failover, use **pause** to
prevent promotion during planned maintenance:

```bash
# Pause the cluster (disables all automatic failover)
docker exec patroni patronictl -c /tmp/patroni.yml pause

# Do your maintenance / restart
docker compose restart patroni

# Resume automatic failover after the node is back
docker exec patroni patronictl -c /tmp/patroni.yml resume
```

For replicas, a simple `docker compose restart patroni` is fine — no
pause needed since restarting a replica doesn't trigger any failover.

---

## Prolonged replica outage

When a replica goes down, the primary keeps all WAL (write-ahead log) files
that the replica hasn't consumed yet. This is because Patroni uses **replication
slots** — the slot forces WAL retention regardless of `wal_keep_size`.

### The risk: disk space on the primary

A replica that is down for days or weeks causes WAL to accumulate on the
primary's disk. If the disk fills up, the primary stops accepting writes
and the entire cluster is affected.

### Monitor WAL retention

Check how much WAL is being retained for offline replicas:

```bash
docker exec patroni psql -U postgres -c \
  "SELECT slot_name, active,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
   FROM pg_replication_slots;"
```

### When the replica comes back

If the primary still has all the WAL, the replica reconnects and catches up
automatically — no action needed.

### If the outage will be long (days/weeks)

To protect the primary's disk, drop the replica's replication slot:

```bash
docker exec patroni psql -U postgres -c \
  "SELECT pg_drop_replication_slot('pg_node3');"
```

The slot name matches the Patroni node name (with `-` replaced by `_`).
After dropping the slot, the primary can clean up old WAL files.

When the replica comes back, it won't be able to catch up via streaming.
Reinitialize it with a fresh copy from the primary:

```bash
docker exec patroni patronictl -c /tmp/patroni.yml reinit pg-cluster pg-node3
```

This runs a full `pg_basebackup` from the primary. At 100 GB on NVMe storage
this takes just a few minutes.

---

## Troubleshooting

### etcd won't form cluster
- Ensure all 3 nodes can reach each other on ports 2379 and 2380
- If restarting after a failed first attempt, clear `/mnt/nvme/etcd-data/*`
  and set `ETCD_INITIAL_CLUSTER_STATE: new`

### Patroni replicas won't join
- Check that the primary is fully running first
- Verify network connectivity on port 5432 between nodes
- Check logs: `docker compose logs patroni`

### keepalived VIP not working
- Verify the interface name: `ip link show`
- Ensure `NET_ADMIN` capability is granted (check docker compose)
- Check that `virtual_router_id` (51) doesn't conflict with other VRRP
  instances on the network
