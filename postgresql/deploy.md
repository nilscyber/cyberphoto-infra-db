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

### 2. Create patroni user and directories

```bash
# Create a dedicated user (no login shell needed)
useradd -r -m -d /opt/patroni -s /usr/sbin/nologin patroni

# Add to docker group so it can run docker compose
usermod -aG docker patroni

# Create data directories
mkdir -p /var/lib/patroni/pgdata /var/lib/patroni/etcd-data

# pgdata must be owned by UID 999 (postgres user inside the container)
chown 999:999 /var/lib/patroni/pgdata

# etcd-data owned by the patroni user
chown patroni:patroni /var/lib/patroni/etcd-data
```

### 3. Install Docker

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
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
