# Runbook 17 — Langfuse ClickHouse Schema Reinit

**Scenario:** After a ClickHouse data loss event (e.g., `mkfs.ext4 -F` on the
backing zvol during storage cascade recovery — OPS-237), the Langfuse schema
tables (`traces`, `observations`, `scores`, etc.) are missing. Langfuse-web or
langfuse-worker log errors such as `Unknown table expression identifier 'traces'`
or similar ClickHouse query failures.

**Caused by:** OPS-237 (2026-04-18) performed `mkfs.ext4 -F` on the
langfuse-clickhouse zvol during a storage cascade recovery. The data was wiped.
Langfuse schema migrations are run on startup by langfuse-web/langfuse-worker.
If those pods were already up when clickhouse data was wiped, migrations did not
re-run automatically.

---

## Key facts about this installation

- Langfuse is deployed via Helm chart (`langfuse-1.5.24`) in the `langfuse` namespace on OKD.
- ClickHouse is a **Deployment** (not a StatefulSet): `deploy/langfuse-clickhouse`.
- ClickHouse uses the **`default`** database, NOT a database named `langfuse`.
  - Env var: `CLICKHOUSE_DB=default` on all Langfuse containers.
  - All schema tables live in `default`: `traces`, `observations`, `scores`,
    `blob_storage_file_log`, `dataset_run_items`, `dataset_run_items_rmt`,
    `event_log`, `analytics_observations`, `analytics_scores`, `analytics_traces`,
    `project_environments`, `schema_migrations`.
- Langfuse auto-runs ClickHouse migrations on startup: `LANGFUSE_AUTO_CLICKHOUSE_MIGRATION_DISABLED=false`.
- Migration progress is tracked in `default.schema_migrations` (columns: `version`, `dirty`, `sequence`).

---

## 1. Diagnose schema state

```bash
# Get the clickhouse pod name (it changes on restart — it's a Deployment)
CH_POD=$(oc -n langfuse get pods -l app.kubernetes.io/component=clickhouse -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
  || oc -n langfuse get pods | grep clickhouse | grep Running | awk '{print $1}')
echo "ClickHouse pod: $CH_POD"

# Check databases present
oc -n langfuse exec $CH_POD -- clickhouse-client --query 'SHOW DATABASES'
# Expected: INFORMATION_SCHEMA, default, information_schema, system
# If you see a 'langfuse' database — that is unexpected; this install uses 'default'

# Check tables in default database
oc -n langfuse exec $CH_POD -- clickhouse-client --query 'SHOW TABLES FROM default'
# Expected: analytics_observations, analytics_scores, analytics_traces,
#           blob_storage_file_log, dataset_run_items, dataset_run_items_rmt,
#           event_log, observations, project_environments, schema_migrations,
#           scores, traces

# Confirm traces table exists
oc -n langfuse exec $CH_POD -- clickhouse-client --query 'EXISTS TABLE default.traces'
# 1 = present, 0 = missing

# Count migrations applied
oc -n langfuse exec $CH_POD -- clickhouse-client --query \
  "SELECT max(version), count() FROM default.schema_migrations WHERE dirty=0"
# Healthy: should show 34 migrations (as of Langfuse 3.162.0)

# Quick row count
oc -n langfuse exec $CH_POD -- clickhouse-client --query \
  "SELECT 'traces' as t, count() FROM default.traces \
   UNION ALL SELECT 'observations', count() FROM default.observations \
   UNION ALL SELECT 'scores', count() FROM default.scores"
```

---

## 2. Interpret the results

| Condition | What it means |
|-----------|---------------|
| `EXISTS TABLE default.traces` returns 1 | Schema is present. No schema fix needed. |
| `SHOW TABLES FROM default` returns empty | Schema missing — proceed to Fix A. |
| `schema_migrations` has dirty=1 rows | Migration partially applied — proceed to Fix B. |
| `UNKNOWN_DATABASE` error on `SHOW TABLES FROM langfuse` | Normal — this install uses `default`. |

---

## 3. Fix A — Bounce langfuse-web and langfuse-worker to re-run migrations

Langfuse auto-runs ClickHouse migrations at container startup. If the schema is
missing, a rolling restart of the web and worker pods will re-run them.

```bash
# Restart both deployments
oc -n langfuse rollout restart deploy/langfuse-web
oc -n langfuse rollout restart deploy/langfuse-worker

# Wait for rollout
oc -n langfuse rollout status deploy/langfuse-web --timeout=3m
oc -n langfuse rollout status deploy/langfuse-worker --timeout=3m

# Verify migration ran
oc -n langfuse logs deploy/langfuse-web 2>&1 | grep -E 'no change|migration|Applied'
# Expect: "no change" (if already current) or a list of applied migrations

# Confirm schema
oc -n langfuse exec $(oc -n langfuse get pods | grep clickhouse | grep Running | awk '{print $1}') \
  -- clickhouse-client --query 'EXISTS TABLE default.traces'
# Expect: 1
```

---

## 4. Fix B — If rollout restart does not trigger migrations

Check whether `LANGFUSE_AUTO_CLICKHOUSE_MIGRATION_DISABLED` is set to `true`:

```bash
oc -n langfuse exec deploy/langfuse-web -- env | grep AUTO_CLICK
```

If disabled, you have two options:

### Option B1 — Drop and re-create the default database

Only do this if you confirm no clickhouse data exists (e.g., after a fresh mkfs):

```bash
oc -n langfuse exec $CH_POD -- clickhouse-client --query 'DROP DATABASE IF EXISTS default'
# WARNING: this drops ALL tables in default. Only do this if data is already lost.

# Then bounce to re-init
oc -n langfuse rollout restart deploy/langfuse-web deploy/langfuse-worker
```

### Option B2 — Apply migrations manually from the container

```bash
# Find migration scripts inside the web container
oc -n langfuse exec deploy/langfuse-web -- find /app -name '*.sql' -path '*/clickhouse/*' 2>/dev/null | head -10

# Or check for a Langfuse migrate CLI
oc -n langfuse exec deploy/langfuse-web -- npx langfuse --help 2>/dev/null || true
```

As of Langfuse 3.162.0 on this platform, Fix A (rollout restart) was sufficient
and triggered automatic migration on startup.

---

## 5. Verify end-to-end trace ingestion

After schema is confirmed present, run a smoke-test trace:

```bash
# Retrieve credentials
VAULT_ADDR=https://vault.208.haist.farm
VAULT_TOKEN=$(cat ~/.vault-token)
export VAULT_ADDR VAULT_TOKEN
PK=$(vault kv get -field=public_key secret/langfuse/overwatch-agents)
SK=$(vault kv get -field=secret_key secret/langfuse/overwatch-agents)
LANGFUSE_HOST="https://langfuse.208.haist.farm"

# Pre-test count
oc -n langfuse exec $(oc -n langfuse get pods | grep clickhouse | grep Running | awk '{print $1}') \
  -- clickhouse-client --query "SELECT count() FROM default.traces"

# Post a test trace
curl -s -X POST "${LANGFUSE_HOST}/api/public/ingestion" \
  -H "Content-Type: application/json" \
  -u "${PK}:${SK}" \
  -d '{
    "batch": [{
      "id": "schema-reinit-smoke-test-001",
      "type": "trace-create",
      "timestamp": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
      "body": {
        "id": "schema-reinit-smoke-trace-001",
        "name": "schema-reinit-smoke-test",
        "metadata": {"source": "runbook-17"},
        "input": "smoke test",
        "output": "smoke test"
      }
    }]
  }'
# Expected response: {"successes":[{"id":"schema-reinit-smoke-test-001","status":201}],"errors":[]}

# Wait 10 seconds for worker to process, then check
sleep 10
oc -n langfuse exec $(oc -n langfuse get pods | grep clickhouse | grep Running | awk '{print $1}') \
  -- clickhouse-client --query "SELECT count() FROM default.traces"
# Count should have incremented by 1

# Confirm no Unknown table errors in web logs
oc -n langfuse logs deploy/langfuse-web --tail=50 | grep -i 'Unknown table' \
  && echo "STILL BROKEN" || echo "schema ok - no Unknown table errors"
```

---

## 6. Known noise: Redis socket timeout errors in langfuse-worker

After schema reinit, you may see log entries like:

```
Queue job llm-as-a-judge-execution-queue errored: Error: Socket timeout.
Expecting data, but didn't receive any in 30000ms.
```

These are **not** a schema issue and **not** a ClickHouse problem. They are
BullMQ queue subscriber connections timing out their blocking Redis reads when
no jobs are in the queue. The ioredis client reconnects automatically. This is
expected behavior when Langfuse queue jobs are idle.

Evidence of correct operation: look for `Processing ingestion event` and
`Flushed N records to Clickhouse observations` in the worker logs — these indicate
the primary ingestion path is healthy.

---

## 7. Related issues and history

> **Note (2026-05-22):** The OPS-NNN references originally in this table were mislabeled due
> to a Plane sequence_id allocator race (April 2026, tracked in OPS-383). Those IDs now point
> to unrelated issues. References below use event descriptions, dates, and the runbook commit
> SHA instead. The actual tracker for this runbook's creation is OPS-121.

| Event | Date | Summary |
|-------|------|---------|
| ClickHouse zvol storage cascade | 2026-04-18 | `mkfs.ext4 -F` on langfuse-clickhouse zvol during storage cascade recovery; data wiped cleanly; schema tables lost |
| langfuse-postgresql crash loop | 2026-04-19 | langfuse-postgresql crash loop after iSCSI lost+found relabel; PVC deleted+recreated; postgres recovered |
| Schema reinit — this runbook | 2026-04-19 | Schema confirmed present after restart; smoke test passed; no manual schema action needed. Runbook delivered in PR #69 (commit `84544b66`), tracked as OPS-121 |
| ClickHouse OOM — MergeTree merges | 2026-04-19 | ClickHouse OOM during MergeTree merges (2Gi limit); issue separate from schema loss; addressed independently |
