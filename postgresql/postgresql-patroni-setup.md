# PostgreSQL Patroni HA Cluster — Setup Instructions

## Overview

This document describes how to set up a 3-node PostgreSQL 18.x HA cluster using
Patroni + etcd + HAProxy + keepalived, running on Docker containers across three
Proxmox VMs (one per physical node).

## Architecture

```
                    ┌─────────────────┐
                    │   Virtual IP     │
                    │  (keepalived)    │
                    └────────┬────────┘
                             │
            ┌────────────────┼────────────────┐
            │                │                │
     ┌──────┴──────┐  ┌─────┴───────┐  ┌─────┴───────┐
     │  HAProxy    │  │  HAProxy    │  │  HAProxy    │
     │  Node 1     │  │  Node 2     │  │  Node 3     │
     └──────┬──────┘  └─────┬───────┘  └─────┬───────┘
            │                │                │
     ┌──────┴──────┐  ┌─────┴───────┐  ┌─────┴───────┐
     │  Patroni    │  │  Patroni    │  │  Patroni    │
     │  + PG 18    │  │  + PG 18    │  │  + PG 18    │
     │  (primary)  │  │  (replica)  │  │  (replica)  │
     └──────┬──────┘  └─────┬───────┘  └─────┴───────┘
            │                │                │
     ┌──────┴──────┐  ┌─────┴───────┐  ┌─────┴───────┐
     │   etcd      │  │   etcd      │  │   etcd      │
     └─────────────┘  └─────────────┘  └─────────────┘
```

## Components per node

Each Proxmox VM runs a Docker Compose stack with these containers:

| Container      | Purpose                                           |
|----------------|---------------------------------------------------|
| etcd           | Distributed consensus store for leader election   |
| patroni-pg     | Patroni managing a PostgreSQL 18 instance         |
| haproxy        | Routes connections to the current primary          |
| keepalived     | Manages a floating virtual IP across HAProxy nodes |

## Important design decisions

- **Patroni is PID 1** (or managed via lightweight init) inside its container.
  Patroni owns the PostgreSQL process — it starts, stops, and configures it.
  Do NOT run PostgreSQL separately from Patroni.
- **etcd runs in its own container**, not together with Patroni/PostgreSQL.
  They have different lifecycle concerns.
- **Storage**: PostgreSQL data directory MUST be on a bind mount or named volume
  backed by the host's M.2 NVMe storage, not in the container's writable layer.
- **Signal handling**: Ensure SIGTERM propagates properly so PostgreSQL does a
  clean shutdown (not crash recovery on restart).

## Prerequisites

- 3 Proxmox VMs, one per physical node
- Docker and Docker Compose installed on each VM
- M.2 NVMe-backed storage on each node
- Network connectivity between all three VMs
- Decide on IP addresses:
  - Node 1: e.g. 10.0.0.11
  - Node 2: e.g. 10.0.0.12
  - Node 3: e.g. 10.0.0.13
  - Virtual IP: e.g. 10.0.0.10

## Step 1: etcd cluster

etcd provides the distributed consensus that makes automatic failover safe.
A 3-node etcd cluster tolerates 1 node failure.

### etcd environment variables (per node, adjust name and IPs)

Node 1 example:
```yaml
environment:
  ETCD_NAME: etcd1
  ETCD_DATA_DIR: /etcd-data
  ETCD_INITIAL_CLUSTER: etcd1=http://10.0.0.11:2380,etcd2=http://10.0.0.12:2380,etcd3=http://10.0.0.13:2380
  ETCD_INITIAL_CLUSTER_STATE: new
  ETCD_INITIAL_CLUSTER_TOKEN: pg-cluster-token
  ETCD_INITIAL_ADVERTISE_PEER_URLS: http://10.0.0.11:2380
  ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
  ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
  ETCD_ADVERTISE_CLIENT_URLS: http://10.0.0.11:2379
```

### etcd data persistence

Mount a volume for `/etcd-data` so etcd state survives container restarts.

### Verify etcd cluster health

```bash
docker exec etcd etcdctl member list
docker exec etcd etcdctl endpoint health
```

## Step 2: Patroni + PostgreSQL 18

Patroni manages the PostgreSQL instances, handles replication setup,
and orchestrates automatic failover via etcd.

### Patroni configuration (patroni.yml)

Create a `patroni.yml` file per node. Key sections explained:

```yaml
scope: pg-cluster          # Cluster name — same on all nodes
namespace: /db/            # etcd key prefix
name: pg-node1             # Unique name per node (pg-node1, pg-node2, pg-node3)

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.11:8008    # This node's IP

etcd3:
  hosts: 10.0.0.11:2379,10.0.0.12:2379,10.0.0.13:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576  # 1MB — replica won't be promoted if further behind
    postgresql:
      use_pg_rewind: true             # Allows former primary to rejoin as replica
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 1GB
        hot_standby_feedback: "on"
        # Tune these for your hardware:
        shared_buffers: 8GB           # Set for smallest node that could host this
        effective_cache_size: 24GB
        work_mem: 64MB
        maintenance_work_mem: 512MB
  initdb:
    - encoding: UTF8
    - data-checksums                  # Default in PG18, but be explicit
  pg_hba:
    - host replication replicator 10.0.0.0/24 scram-sha-256
    - host all all 10.0.0.0/24 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256
  users:
    admin:
      password: CHANGE_ME
      options:
        - createrole
        - createdb
    replicator:
      password: CHANGE_ME
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.11:5432    # This node's IP
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/18/bin
  pgpass: /tmp/pgpass0
  authentication:
    replication:
      username: replicator
      password: CHANGE_ME
    superuser:
      username: postgres
      password: CHANGE_ME
    rewind:
      username: rewind_user
      password: CHANGE_ME

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
```

### Container setup notes

- Mount the PostgreSQL data directory to host storage:
  `./pgdata:/var/lib/postgresql/data`
- Mount the patroni.yml config file into the container
- The container image needs both PostgreSQL 18 and Patroni installed
  (build a custom image, or use an image like `patroni/patroni` with PG18)
- Use host networking or fixed container IPs so nodes can reach each other

### Bootstrap the cluster

1. Start etcd on all three nodes first
2. Start Patroni on node 1 — it will initialize as primary
3. Start Patroni on nodes 2 and 3 — they will clone from the primary
   via pg_basebackup (at 100GB this takes just a few minutes on M.2)

### Verify cluster status

```bash
docker exec patroni-pg patronictl -c /etc/patroni.yml list
```

Expected output shows one leader and two replicas:
```
+ Cluster: pg-cluster (1234567890) ---+----+-----------+
| Member   | Host       | Role    | State     | TL | Lag in MB |
+----------+------------+---------+-----------+----+-----------+
| pg-node1 | 10.0.0.11  | Leader  | running   |  1 |           |
| pg-node2 | 10.0.0.12  | Replica | streaming |  1 |         0 |
| pg-node3 | 10.0.0.13  | Replica | streaming |  1 |         0 |
+----------+------------+---------+-----------+----+-----------+
```

## Step 3: HAProxy

HAProxy routes application connections to whichever node is currently the
Patroni leader. It uses Patroni's REST API health checks to determine this.

### HAProxy configuration (haproxy.cfg)

```cfg
global
    maxconn 1000

defaults
    log global
    mode tcp
    retries 3
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen postgresql
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg-node1 10.0.0.11:5432 maxconn 300 check port 8008
    server pg-node2 10.0.0.12:5432 maxconn 300 check port 8008
    server pg-node3 10.0.0.13:5432 maxconn 300 check port 8008

listen postgresql-replicas
    bind *:5001
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server pg-node1 10.0.0.11:5432 maxconn 300 check port 8008
    server pg-node2 10.0.0.12:5432 maxconn 300 check port 8008
    server pg-node3 10.0.0.13:5432 maxconn 300 check port 8008

listen stats
    bind *:7000
    mode http
    stats enable
    stats uri /
```

### How it works

- HAProxy checks each node's Patroni REST API (port 8008)
- `/primary` returns HTTP 200 only on the current leader
- `/replica` returns HTTP 200 only on replicas
- Applications connect to HAProxy on port 5000 (read-write) or 5001 (read-only)
- When failover happens, HAProxy detects the change within seconds

### HAProxy stats

Access `http://<any-node>:7000` for a web dashboard showing which backend
nodes are up/down and current connections.

## Step 4: keepalived (Virtual IP)

keepalived provides a floating virtual IP (VIP) so applications only need
one address to connect to. If the HAProxy node holding the VIP goes down,
another node takes over.

### keepalived configuration

Node 1 (MASTER):
```conf
vrrp_instance VI_1 {
    state MASTER
    interface eth0              # Adjust to your network interface
    virtual_router_id 51
    priority 150                # Highest priority = preferred master
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass CHANGE_ME
    }
    virtual_ipaddress {
        10.0.0.10/24            # The floating VIP
    }
}
```

Node 2 and 3 (BACKUP):
```conf
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100                # Lower priority (use 100 and 50 for nodes 2 and 3)
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass CHANGE_ME
    }
    virtual_ipaddress {
        10.0.0.10/24
    }
}
```

### Note on keepalived in Docker

keepalived needs NET_ADMIN capability to manage the VIP:
```yaml
cap_add:
  - NET_ADMIN
network_mode: host
```

Alternatively, run keepalived directly on the VM host instead of in Docker.
This is actually simpler and avoids the capability issues.

## Application connection

Applications connect to:
- **Read-write**: `postgresql://user:pass@10.0.0.10:5000/dbname`
- **Read-only**: `postgresql://user:pass@10.0.0.10:5001/dbname`

The VIP (10.0.0.10) → HAProxy → current Patroni leader.
Applications don't need to know about failover — it's transparent.

## Day-to-day operations

### Check cluster status
```bash
docker exec patroni-pg patronictl -c /etc/patroni.yml list
```

### Manual switchover (planned, zero downtime)
```bash
docker exec patroni-pg patronictl -c /etc/patroni.yml switchover
```
Patroni will prompt for which node to promote.

### Restart a node (rolling restart)
```bash
docker exec patroni-pg patronictl -c /etc/patroni.yml restart pg-cluster --member pg-node1
```

### Reinitialize a failed replica
```bash
docker exec patroni-pg patronictl -c /etc/patroni.yml reinit pg-cluster pg-node2
```

## Failover behavior

When the primary goes down:
1. etcd detects the leader key is not being renewed
2. Patroni on the replicas initiates a leader election
3. The most up-to-date replica (within `maximum_lag_on_failover`) is promoted
4. The former primary is fenced (stopped if reachable)
5. HAProxy detects the change via REST API health checks
6. Traffic is routed to the new primary within seconds
7. When the old primary comes back, Patroni uses pg_rewind to rejoin it as a replica

## Major version upgrades (e.g. PG 18 → 19)

At 100GB, the simplest approach:
1. Build new Docker images with PG 19 + Patroni
2. Create a new Patroni cluster with the new images
3. pg_dump from old cluster, pg_restore into new cluster (15-30 min)
4. Switch application connection string to new cluster
5. Verify and tear down old cluster

Both clusters can run side by side temporarily on the same nodes.

## Minor version upgrades (e.g. 18.3 → 18.4)

1. Update the Docker image tag
2. Rolling restart via patronictl:
   ```bash
   docker exec patroni-pg patronictl -c /etc/patroni.yml restart pg-cluster
   ```
   Patroni restarts each node one at a time, maintaining availability.

## Backups

Patroni does NOT manage backups. Set up separately using one of:
- **pgBackRest** — most feature-complete, supports incremental backups
- **WAL-G** — simpler, good S3 integration
- **pg_dump** on a schedule — simplest, fine for 100GB

At 100GB, even a plain pg_dump to a mounted backup volume on a cron schedule
is a viable strategy. Run it from one of the replica nodes to avoid
impacting the primary.

## Monitoring

- **Patroni REST API**: `http://<node>:8008/patroni` returns JSON with node state
- **HAProxy stats**: `http://<node>:7000` shows backend health
- **etcd health**: `etcdctl endpoint health`
- **PostgreSQL**: standard pg_stat views, or add Prometheus with postgres_exporter

## Security reminders

- Change all CHANGE_ME passwords before deploying
- Use scram-sha-256 authentication (not md5)
- Consider TLS for etcd and Patroni REST API in production
- Restrict pg_hba.conf to your actual network ranges
- etcd communication should ideally be encrypted in production
