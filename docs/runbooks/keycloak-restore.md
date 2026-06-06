# Keycloak Restore Runbook

**Issue:** OPS-632 — Keycloak backup procedure (Phase 4 prerequisite)
**Status:** UNVERIFIED — restore tests A/B/C require operator sign-off per OPS-632 acceptance criteria
**Last Updated:** 2026-05-14

---

## Overview

Keycloak has three restore paths corresponding to the three backup layers:

| Path | Source | RTO | Use When |
|------|--------|-----|----------|
| **Path A** | SQL dump (pg_dump -Fc) from MinIO | ≤4h | Preferred for full restore; data may be up to 24h old |
| **Path B** | Realm JSON export from MinIO | ≤4h | Keycloak config only (no user passwords); useful for config-only recovery |
| **Path C** | TrueNAS ZFS snapshot revert | ≤2h | Fastest path; requires TrueNAS .205 to be healthy |

**RPO:** ≤24h (daily backup at 03:00 UTC for Layers 1+2; ZFS snapshot at 04:00 UTC for Layer 3)

---

## Prerequisites (all paths)

```bash
# Verify MinIO backups exist
mc alias set minio http://192.168.12.58:9000 <access-key> <secret-key>
mc ls minio/keycloak-backups/daily/ | tail -5
mc ls minio/keycloak-backups/weekly/ | tail -3

# Fetch credentials from Vault
VAULT_SKIP_VERIFY=true vault kv get -address=https://192.168.12.206:8200 secret/keycloak/admin
VAULT_SKIP_VERIFY=true vault kv get -address=https://192.168.12.206:8200 secret/keycloak/postgresql
```

---

## Path A: SQL dump restore (RECOMMENDED)

### Step 1 — Stop Keycloak (prevent split-brain)

```bash
oc -n keycloak scale deploy/keycloak --replicas=0
# Wait for pod termination
oc -n keycloak get pods -w
```

**Expected output:** No pods in the `keycloak` namespace after ~30s.

### Step 2 — Download latest dump from MinIO

```bash
LATEST=$(mc ls minio/keycloak-backups/daily/ | sort | tail -1 | awk '{print $NF}')
mc cp "minio/keycloak-backups/daily/${LATEST}" /tmp/keycloak-restore.dump
echo "Downloaded: ${LATEST} ($(du -sh /tmp/keycloak-restore.dump | cut -f1))"
```

**Expected output:** File size typically 1–50MB depending on user count.

### Step 3 — Scale down postgres, drop+recreate DB

```bash
oc -n keycloak scale deploy/postgresql --replicas=0
# Wait for termination
oc -n keycloak get pods -w

oc -n keycloak scale deploy/postgresql --replicas=1
oc -n keycloak wait deploy/postgresql --for=condition=Available --timeout=120s

PG_POD=$(oc -n keycloak get pods -l app=postgresql -o jsonpath='{.items[0].metadata.name}')
oc -n keycloak exec "${PG_POD}" -- \
    sh -c 'psql -U ${POSTGRES_USER} -c "DROP DATABASE IF EXISTS ${POSTGRES_DB}" postgres && \
           psql -U ${POSTGRES_USER} -c "CREATE DATABASE ${POSTGRES_DB}" postgres'
```

**Expected output:** `DROP DATABASE`, `CREATE DATABASE`

### Step 4 — Restore the dump

```bash
# Copy dump into the postgres pod
oc -n keycloak cp /tmp/keycloak-restore.dump "${PG_POD}:/tmp/restore.dump"

# Restore
oc -n keycloak exec "${PG_POD}" -- \
    sh -c 'pg_restore -U ${POSTGRES_USER} -d ${POSTGRES_DB} --no-owner --role=${POSTGRES_USER} /tmp/restore.dump'
```

**Expected output:** No errors. Some ignorable warnings like `role "keycloak" already exists` are OK.

### Step 5 — Restart Keycloak

```bash
oc -n keycloak scale deploy/keycloak --replicas=1
oc -n keycloak wait deploy/keycloak --for=condition=Available --timeout=300s
```

**Expected output:** Keycloak pod Running + Ready.

### Step 6 — Verify

```bash
# Verify admin console is accessible
curl -sf https://auth.208.haist.farm/realms/master/.well-known/openid-configuration | jq .issuer

# Check client count in sentinel realm (should be ~13)
KC_ADMIN=$(VAULT_SKIP_VERIFY=true vault kv get -field=username -address=https://192.168.12.206:8200 secret/keycloak/admin)
KC_PASS=$(VAULT_SKIP_VERIFY=true vault kv get -field=password -address=https://192.168.12.206:8200 secret/keycloak/admin)

TOKEN=$(curl -sf -X POST https://auth.208.haist.farm/realms/master/protocol/openid-connect/token \
    -d "grant_type=password&client_id=admin-cli&username=${KC_ADMIN}&password=${KC_PASS}" | \
    jq -r .access_token)

curl -sf "https://auth.208.haist.farm/admin/realms/sentinel/clients" \
    -H "Authorization: Bearer ${TOKEN}" | jq 'length'
```

**Expected output:** `issuer` matches `https://auth.208.haist.farm/realms/master`. Client count ≥ 13.

---

## Path B: Realm JSON restore (config-only, no user passwords)

Use this path when the database is healthy but realm configuration is corrupted/deleted.
User passwords are NOT restored (users must reset via email); session data is lost.

### Step 1 — Download realm JSON from MinIO

```bash
LATEST_REALM=$(mc ls minio/keycloak-backups/daily/ | grep '^.*realm-' | sort | tail -1 | awk '{print $NF}')
mc cp "minio/keycloak-backups/daily/${LATEST_REALM}" /tmp/realm-restore.json
```

### Step 2 — Import realm via Keycloak admin API

```bash
KC_ADMIN=$(VAULT_SKIP_VERIFY=true vault kv get -field=username -address=https://192.168.12.206:8200 secret/keycloak/admin)
KC_PASS=$(VAULT_SKIP_VERIFY=true vault kv get -field=password -address=https://192.168.12.206:8200 secret/keycloak/admin)

TOKEN=$(curl -sf -X POST https://auth.208.haist.farm/realms/master/protocol/openid-connect/token \
    -d "grant_type=password&client_id=admin-cli&username=${KC_ADMIN}&password=${KC_PASS}" | \
    jq -r .access_token)

# Import (this will OVERWRITE existing sentinel realm config)
curl -sf -X POST "https://auth.208.haist.farm/admin/realms/sentinel/partial-import" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d @/tmp/realm-restore.json \
    -d '?ifResourceExists=OVERWRITE'
```

**Expected output:** HTTP 200 or 204.

### Step 3 — Verify

Same as Path A Step 6.

---

## Path C: TrueNAS ZFS snapshot revert (FASTEST)

Use this path when the postgres PV data is corrupted and you need full point-in-time recovery.
**Requires TrueNAS .205 to be healthy.** This is a DISRUPTIVE operation — Keycloak and postgres must be stopped.

### Step 1 — Stop Keycloak and Postgres

```bash
oc -n keycloak scale deploy/keycloak --replicas=0
oc -n keycloak scale deploy/postgresql --replicas=0
oc -n keycloak get pods -w  # Wait for all pods gone
```

### Step 2 — List available snapshots on TrueNAS

```bash
TRUENAS_TOKEN=$(VAULT_SKIP_VERIFY=true vault kv get -field=api_token -address=https://192.168.12.206:8200 secret/truenas)

curl -sk -H "Authorization: Bearer ${TRUENAS_TOKEN}" \
    "https://data.haist.farm/api/v2.0/zfs/snapshot?dataset=tank%2Fiscsi%2Fkeycloak-pg" | \
    jq -r '.[] | "\(.name) created=\(.properties.creation.value)"' | sort
```

**Expected output:** List of snapshots like `tank/iscsi/keycloak-pg@backup-20260514T040000Z`.

### Step 3 — Disconnect iSCSI target from OKD (if still attached)

```bash
# Get the PV name
oc get pv -o json | jq -r '.items[] | select(.spec.iscsi.iqn == "iqn.2026-03.farm.haist:okd-keycloak-pg") | .metadata.name'
# The PV has reclaimPolicy: Retain — it stays even if the PVC is deleted
```

If the iSCSI LUN is still mounted on an OKD node, the ZFS rollback may fail. Ensure no node has the LUN mounted before proceeding.

### Step 4 — Roll back ZFS snapshot on TrueNAS

```bash
SNAPSHOT_NAME="tank/iscsi/keycloak-pg@backup-<TIMESTAMP>"  # Replace with chosen snapshot

curl -sk -H "Authorization: Bearer ${TRUENAS_TOKEN}" \
    -H "Content-Type: application/json" \
    -X POST "https://data.haist.farm/api/v2.0/zfs/snapshot/rollback" \
    -d "{\"id\": \"${SNAPSHOT_NAME}\", \"options\": {\"recursive\": false, \"force\": false}}"
```

**Expected output:** Job ID (TrueNAS 2.0 API returns job ID for long-running operations).

```bash
# Monitor job completion
JOB_ID=<from above>
curl -sk -H "Authorization: Bearer ${TRUENAS_TOKEN}" \
    "https://data.haist.farm/api/v2.0/core/get_jobs?id=${JOB_ID}" | jq '.[0].state'
```

### Step 5 — Restart Postgres and Keycloak

```bash
oc -n keycloak scale deploy/postgresql --replicas=1
oc -n keycloak wait deploy/postgresql --for=condition=Available --timeout=120s

oc -n keycloak scale deploy/keycloak --replicas=1
oc -n keycloak wait deploy/keycloak --for=condition=Available --timeout=300s
```

### Step 6 — Verify

Same as Path A Step 6.

---

## Restore Test Staging Environment

A pre-configured staging environment exists in the `keycloak-staging` namespace for testing restore paths A and B without touching production.

```bash
# Scale up staging postgres (it defaults to 0 replicas)
oc -n keycloak-staging scale deploy/postgresql-staging --replicas=1
oc -n keycloak-staging wait deploy/postgresql-staging --for=condition=Available --timeout=120s

# Restore into staging postgres (use same steps as Path A but target keycloak-staging namespace)
PG_STAGING_POD=$(oc -n keycloak-staging get pods -l app=postgresql-staging -o jsonpath='{.items[0].metadata.name}')
oc -n keycloak-staging cp /tmp/keycloak-restore.dump "${PG_STAGING_POD}:/tmp/restore.dump"
oc -n keycloak-staging exec "${PG_STAGING_POD}" -- \
    sh -c 'pg_restore -U ${POSTGRES_USER} -d ${POSTGRES_DB} --no-owner /tmp/restore.dump'

# Scale up staging Keycloak
oc -n keycloak-staging scale deploy/keycloak-staging --replicas=1

# Scale back down when done
oc -n keycloak-staging scale deploy/postgresql-staging --replicas=0
oc -n keycloak-staging scale deploy/keycloak-staging --replicas=0
```

---

## Vault secrets required for restore

All of these should already exist; verify before starting:

```bash
VAULT_SKIP_VERIFY=true vault kv list -address=https://192.168.12.206:8200 secret/keycloak/
```

Expected keys: `admin`, `postgresql`, `jwt-signing.pubkey`, `clients/`

---

## Acceptance criteria (from OPS-632)

- [ ] Test A: SQL dump restore to staging + admin console login + 13 clients visible
- [ ] Test B: Realm JSON import to fresh staging Keycloak + OIDC handshake
- [ ] Test C: ZFS clone revert (not live snapshot) + postgres + Keycloak up
- [ ] All three paths complete within 4h RTO

**Status:** UNVERIFIED — requires operator maintenance window per OPS-632.
