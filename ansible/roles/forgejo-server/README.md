# forgejo-server role

Deploys Forgejo (self-hosted git) on a Docker Compose stack with postgres and
redis sidecars, plus an nginx TLS-terminating sidecar for artifact uploads.

## Host: VM110 (192.168.12.70)

**PVE-level facts — documented here, not Ansible-applied:**

| Parameter | Value |
|-----------|-------|
| vCPU | 8 |
| RAM | 16 GB |
| Swap | 8 GB |
| OS disk | pve4-ssd-thin (iSCSI SAS-SSD via TrueNAS) |
| Data disk | pve4-ssd-thin (iSCSI SAS-SSD via TrueNAS) |
| PVE host | pve4 |

These were applied under OPS-1061 (2026-05-29). Changing these requires PVE-level
`qm set 110 ...` commands; they are not reflected by an Ansible play.

---

## Postgres tuning — required live settings (not Ansible-applied)

The Docker postgres:16-alpine image manages `postgresql.conf` inside its data
volume (`/opt/forgejo/postgres`). The recommended way to tune it is `ALTER SYSTEM`
(writes to `postgresql.auto.conf` in the data volume) or a custom config mount.

The following settings were applied via `ALTER SYSTEM` under OPS-1061 and are
**required for agentic-scale workloads**. They survive container restarts but
**not** a fresh data-volume wipe (e.g. disaster recovery rebuild). After any
rebuild, re-apply:

```sql
-- Connect as postgres superuser inside the container:
-- docker exec -it forgejo-postgres psql -U forgejo

ALTER SYSTEM SET shared_buffers             = '2GB';
ALTER SYSTEM SET effective_cache_size       = '8GB';
ALTER SYSTEM SET work_mem                   = '16MB';
ALTER SYSTEM SET maintenance_work_mem       = '256MB';
ALTER SYSTEM SET wal_buffers                = '64MB';
ALTER SYSTEM SET checkpoint_completion_target = '0.9';
-- SSD cost params (disks are on pve4-ssd-thin iSCSI SSD):
ALTER SYSTEM SET random_page_cost           = '1.5';
ALTER SYSTEM SET effective_io_concurrency   = '200';
SELECT pg_reload_conf();
```

> If the data disks are ever migrated OFF pve4-ssd-thin to a HDD spindle, revert
> to `random_page_cost = 4.0` and `effective_io_concurrency = 1` before the move.

---

## Postgres autovacuum — per-table settings for action_* tables

Default autovacuum `scale_factor=0.2` (20% of table size) never fires under
agentic insert/complete churn, causing planner stats to degrade and the
`/actions/tasks` API endpoint to slow to 30+ seconds. Apply after each
disaster-recovery rebuild or after a new Forgejo major-version migration creates
fresh tables:

```sql
ALTER TABLE action_task
  SET (autovacuum_vacuum_scale_factor=0.01,
       autovacuum_vacuum_threshold=100,
       autovacuum_analyze_scale_factor=0.01);

ALTER TABLE action_run
  SET (autovacuum_vacuum_scale_factor=0.01,
       autovacuum_vacuum_threshold=100,
       autovacuum_analyze_scale_factor=0.01);

ALTER TABLE action_run_job
  SET (autovacuum_vacuum_scale_factor=0.01,
       autovacuum_vacuum_threshold=100,
       autovacuum_analyze_scale_factor=0.01);

ALTER TABLE action_task_step
  SET (autovacuum_vacuum_scale_factor=0.01,
       autovacuum_vacuum_threshold=100,
       autovacuum_analyze_scale_factor=0.01);

ALTER TABLE action_artifact
  SET (autovacuum_vacuum_scale_factor=0.01,
       autovacuum_vacuum_threshold=100,
       autovacuum_analyze_scale_factor=0.01);
```

These settings are stored in the postgres catalog (survive restarts); they do
not survive a fresh data-volume wipe.

---

## Redis sidecar

Added under OPS-1063. In-memory only (`--save ""` disables RDB persistence).
Uses three logical databases:

| DB index | Purpose |
|----------|---------|
| 0 | queue (CI webhooks, push events) |
| 1 | cache (tokens, permissions, repo metadata) |
| 2 | session |

---

## Key variables (defaults/main.yml)

| Variable | Default | Description |
|----------|---------|-------------|
| `forgejo_redis_image` | `redis:7-alpine` | Redis image |
| `forgejo_redis_maxmemory` | `256mb` | Redis max memory cap |
| `forgejo_redis_maxmemory_policy` | `allkeys-lru` | Redis eviction policy |
| `forgejo_db_max_open_conns` | `80` | Forgejo DB pool max open |
| `forgejo_db_max_idle_conns` | `20` | Forgejo DB pool max idle |
| `forgejo_db_conn_max_lifetime` | `3600` | DB connection max lifetime (seconds) |
| `forgejo_queue_length` | `1000` | Redis queue depth |
| `forgejo_queue_batch_length` | `20` | Redis queue batch size |
| `forgejo_git_timeout_default` | `120` | Git default subprocess timeout (s) |
| `forgejo_git_timeout_clone` | `120` | Git clone timeout (s) |
| `forgejo_git_timeout_fetch` | `120` | Git fetch timeout (s) |
| `forgejo_git_timeout_gc` | `120` | Git GC timeout (s) |
| `forgejo_git_timeout_migrate` | `300` | Git migrate timeout (s) |
| `forgejo_git_timeout_mirror` | `300` | Git mirror timeout (s) |

---

## Tracking

- OPS-1061: on-host tuning applied 2026-05-29
- OPS-1063: codified into this role
