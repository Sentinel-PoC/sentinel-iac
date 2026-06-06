# Runbook 20 — TrueNAS SCALE Update Procedure

**Issue:** OPS-859  
**Criticality:** HIGH — TrueNAS is the iSCSI backend for all OKD persistent databases and three NFS mounts; any downtime cascades to the entire application stack  
**Authored:** 2026-05-23 by worker-ops-859-truenas-plan  
**NIST Controls:** CM-3, CM-4, CP-9, CP-10  
**Related:** OPS-482 (iSCSI LUN rebuild), HAIST-22 (power-incident recovery), `07-postgresql-crash-recovery.md`, `04-service-recovery-order.md`

> **PLANNING DOCUMENT — DO NOT EXECUTE without operator approval and a scheduled maintenance window.**  
> The actual upgrade happens in a follow-on issue after operator review of this plan.

---

## 1. Current State (verified 2026-05-23 via TrueNAS API; profile updated 2026-05-29 per OPS-860)

| Field | Value | Source |
|-------|-------|--------|
| Hostname | `data.haist.farm` | TrueNAS API `/system/info` |
| IP | `192.168.12.205` | sentinel-iac `hosts.ini` |
| PVE host | pve3 (`192.168.12.57`) | `hosts.ini` comment |
| PVE VMID | 205 | compliance-vault `truenas-iscsi-lun-rebuild.md` |
| OS type | TrueNAS SCALE (Linux-based) | API `system_product` = QEMU |
| Version | **25.10.3.1** | API `/system/version` (was 25.10.1 at initial inspection 2026-05-23) |
| RAM | 64 GiB (ECC) | `physmem` = 67,431,927,808 |
| vCPUs | 16 | `cores` = 16 |
| Uptime at inspection | 31 days | `uptime_seconds` ÷ 86400 (at 2026-05-23 inspection) |
| Update profile | **GENERAL** | API `/update` → `profile` field (migrated from EARLY_ADOPTER per OPS-860) |

### ZFS Pool Summary

| Pool | Total | Allocated | Free | % Used | Health |
|------|-------|-----------|------|--------|--------|
| SSD | 740 GB | 86 GB | 654 GB | 11.6% | ONLINE |
| DATA | 26,992 GB | 19,912 GB | 7,080 GB | 73.7% | ONLINE |
| BACKUP | 5,584 GB | 1,708 GB | 3,876 GB | 30.6% | ONLINE |

> **⚠ DATA pool at 73.7%** — not an immediate problem but worth monitoring. The `/mnt/DATA/data` NFS share holds ~11.9 TB of media (arr-stack). If seedbox-vm fills this faster than expected, thin-pool exhaustion (the cascade documented in `feedback_cascade_pve_truenas_iscsi_okd`) could occur. Pre-flight check required.

---

## 2. Dependent Inventory

### 2a. iSCSI LUNs (OKD persistent volumes)

All LUNs are on the **SSD pool**, ZFS volume type, LUN ID 0, portal `192.168.12.205:3260`.  
IQN basename: `iqn.2026-03.farm.haist`

| Target Name | IQN | ZFS Dataset | Provisioned Size | OKD Workload |
|-------------|-----|-------------|-----------------|--------------|
| `okd-harbor-pg` | `iqn.2026-03.farm.haist:okd-harbor-pg` | `SSD/iscsi-okd/harbor-pg` | 15 GB | Harbor registry PostgreSQL |
| `okd-matrix-pg` | `iqn.2026-03.farm.haist:okd-matrix-pg` | `SSD/iscsi-okd/matrix-pg` | 15 GB | Matrix/Synapse PostgreSQL |
| `okd-plane-pg` | `iqn.2026-03.farm.haist:okd-plane-pg` | `SSD/iscsi-okd/plane-pg` | 15 GB | Plane project-management PostgreSQL |
| `okd-defectdojo-pg` | `iqn.2026-03.farm.haist:okd-defectdojo-pg` | `SSD/iscsi-okd/defectdojo-pg` | 15 GB | DefectDojo PostgreSQL |
| `okd-netbox-pg` | `iqn.2026-03.farm.haist:okd-netbox-pg` | `SSD/iscsi-okd/netbox-pg` | 15 GB | NetBox PostgreSQL |
| `okd-keycloak-pg` | `iqn.2026-03.farm.haist:okd-keycloak-pg` | `SSD/iscsi-okd/keycloak-pg` | 10 GB | Keycloak SSO PostgreSQL |
| `okd-langfuse-pg` | `iqn.2026-03.farm.haist:okd-langfuse-pg` | `SSD/iscsi-okd/langfuse-pg` | 15 GB | Langfuse tracing PostgreSQL |
| `okd-langfuse-ch` | `iqn.2026-03.farm.haist:okd-langfuse-ch` | `SSD/iscsi-okd/langfuse-ch` | 100 GB | Langfuse ClickHouse |

**Total iSCSI provisioned: 200 GB across 8 LUNs**

> **NOTE:** The older `compliance-vault/runbooks/truenas-iscsi-lun-rebuild.md` (OPS-482) references ZFS paths as `tank/iscsi/...`. Live API inspection on 2026-05-23 shows the correct pool name is **SSD** and dataset prefix is **`SSD/iscsi-okd/`**. The OPS-482 runbook should be updated separately. Use this runbook's paths for any live operation.

**Impact of iSCSI service outage:** All 8 PostgreSQL/ClickHouse PVs become unavailable → Keycloak, Harbor, Plane, NetBox, DefectDojo, Matrix, Langfuse all enter crash loops. OKD is still running but all DB-backed services fail.

### 2b. NFS Shares

| Share | Mount Path | Consumers | Purpose |
|-------|-----------|-----------|---------|
| NFS ID 1 | `/mnt/DATA/data` | `192.168.12.69` (seedbox-vm/arr-stack), `.114`, `.115`, `.116` | Media library + general data |
| NFS ID 2 | `/mnt/DATA/backups/langfuse-clickhouse` | All hosts in `192.168.12.0/24` | Langfuse ClickHouse native backup destination (OPS-111-A) |
| NFS ID 3 | `/mnt/DATA/logs` | All hosts in `192.168.12.0/24` | VictoriaLogs centralized log storage (OPS-807/808) |
| SMB share | `/mnt/DATA/data` | Windows clients | Same data directory as NFS ID 1 |

> **Hosts .114/.115/.116:** Not explicitly named in `hosts.ini` at time of this writing; likely OKD nodes (or future nodes). They appear in NFS ID 1 allowlist. Confirm before maintenance window — if they are OKD nodes, unmounting NFS before the update prevents stale file handles.

**Impact of NFS outage:**
- `.69` (seedbox-vm): arr-stack (Sonarr/Radarr/qBittorrent) becomes unavailable — low-priority, non-production
- VictoriaLogs log shipping pauses (logs buffer in-memory on agents, risk of loss on crash)
- Langfuse ClickHouse native backups fail until NFS restored

### 2c. Backups TO TrueNAS (risk: colocated backup)

| Backup type | Destination on TrueNAS | Schedule | Status |
|-------------|------------------------|----------|--------|
| Keycloak PostgreSQL ZFS snapshot (Layer 3) | `SSD/iscsi-okd/keycloak-pg@backup-<ts>` | Daily 04:00 UTC | **ACTIVE** — `truenas-backup` role via iac-control |
| Langfuse ClickHouse native backup | `/mnt/DATA/backups/langfuse-clickhouse` NFS share | Per OPS-111-A schedule | **ACTIVE** |
| Forgejo git backup | Not yet implemented | — | **NOT ACTIVE** (OPS-827 TODO) |
| etcd backup | Not targeting TrueNAS — goes to MinIO | — | No change needed |
| Velero | Not targeting TrueNAS | — | No change needed |

> **⚠ COLOCATED BACKUP RISK:** Keycloak Layer 3 ZFS snapshots live on the same TrueNAS host as the LUN they protect. If TrueNAS is unrecoverable, both the LUN and the Layer 3 snapshot are lost simultaneously. Layer 1+2 (MinIO → B2) are off-host and protect against this. Before the update window, verify Layers 1+2 are current and successfully replicated to B2.

---

## 3. Target Version & Upgrade Path

### Current: TrueNAS SCALE 25.10.3.1 (GENERAL/stable profile)

TrueNAS SCALE 25.10.x is the **Goldeye** release line (Linux/Debian-based). Version 25.10.3.1 is a point release in this line.

> **Profile note (OPS-860):** The host was on EARLY_ADOPTER at initial runbook creation (2026-05-23). The operator confirmed this was not deliberate. The profile was migrated to GENERAL/stable (OPS-860, 2026-05-29). Target version queries now reference the GENERAL channel — any `update/check_available` call will return the next GENERAL release, not an EA pre-release.

### Recommended Target: Next stable 25.10.x patch release

- **Upgrade path:** In-place, within the 25.10.x line. No major-version jump needed.
- **Train:** GENERAL receives 25.10.x stable releases (not EA pre-releases). This is the correct and intended profile for this host.
- **Core→Scale migration:** NOT applicable. The system is already on SCALE. This is an irreversible migration and has already been performed.
- **Multi-step jumps:** Not required for 25.10.x → 25.10.y within the same minor line.

### Version research constraints

At inspection time (2026-05-23), the TrueNAS API endpoint `/api/v2.0/update/check_available` (POST) was not queried (read-only session). The operator should run:

```bash
# From iac-control or directly on TrueNAS:
curl -sk -X POST \
  -H "Authorization: Bearer $(vault kv get -field=api_token secret/truenas)" \
  https://192.168.12.205/api/v2.0/update/check_available | jq .
```

This returns the available update version. Compare against [https://www.truenas.com/truenas-scale-release-notes/](https://www.truenas.com/truenas-scale-release-notes/) for the release notes of the target version.

### EoL consideration

TrueNAS SCALE maintains each major release for approximately 12 months from GA. 25.10.x (Goldeye) will receive security patches until approximately Q4 2026. The next major (26.x) should not be targeted until operator review of migration requirements.

---

## 4. Snapshot & Rollback Strategy

Three independent layers must be in place before clicking "Update":

### Layer A — TrueNAS Boot Environment (automatic, verify before proceeding)

TrueNAS SCALE automatically creates a new boot environment (BE) when applying an update. The previous BE remains bootable. On reboot after update, if the new BE fails:

```
# From TrueNAS web UI: System > Boot Environments > Activate previous BE > Reboot
# Or from SSH:
midclt call bootenv.activate <previous_be_name>
reboot
```

**Verify current BEs before update:**

```bash
# TrueNAS API (note: some SCALE versions use /api/v2.0/bootenv, check via web UI if 404)
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  https://192.168.12.205/api/v2.0/bootenv | jq -r '.[].id'
```

At inspection time the `/api/v2.0/bootenv` endpoint returned 404 (endpoint may have moved in 25.10.x). Use the web UI: **System → Boot** to list and verify current boot environments.

### Layer B — PVE VM Snapshot (operator must take before update)

TrueNAS runs as VMID 205 on pve3 (`192.168.12.57`). A full VM-level snapshot captures disk + RAM state before update begins.

```bash
# From iac-control or via PVE API:
# First gracefully quiesce TrueNAS (iSCSI must be idle — see §5 pre-flight)
ssh root@192.168.12.57 'qm snapshot 205 pre-truenas-update-$(date +%Y%m%d) \
  --description "OPS-859 pre-update snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"'

# Verify snapshot was created:
ssh root@192.168.12.57 'qm listsnapshot 205'
```

> **WARNING:** Taking a VM snapshot while iSCSI LUNs are actively mounted on OKD nodes causes the snapshot to include a write-in-progress state. Always quiesce OKD workloads (scale to 0) BEFORE taking the VM snapshot. See §5 Step 4.

**Rollback via PVE snapshot:**

```bash
# Shut down TrueNAS first
ssh root@192.168.12.57 'qm shutdown 205 --timeout 120'
# Roll back to pre-update snapshot
ssh root@192.168.12.57 'qm rollback 205 pre-truenas-update-<date>'
# Start TrueNAS
ssh root@192.168.12.57 'qm start 205'
```

### Layer C — ZFS Data Snapshots (optional but recommended for DATA pool)

The SSD pool (iSCSI LUNs) changes are configuration-only during an update; data is not expected to change. However, if desired:

```bash
# Snapshot all SSD pool datasets before update (read-only, for belt-and-suspenders)
curl -sk -X POST \
  -H "Authorization: Bearer $TRUENAS_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"dataset": "SSD/iscsi-okd", "name": "pre-update-20260523", "recursive": true}' \
  https://192.168.12.205/api/v2.0/zfs/snapshot
```

> Leave these snapshots intact. Prune manually after the update is verified stable (>24h uptime, all iSCSI sessions reconnected, all OKD pods Running).

---

## 5. Pre-Flight Checklist

Run all checks from iac-control (`192.168.12.210`). Do not proceed if any check fails.

### 5a. Backup verification (must complete before maintenance window opens)

```bash
# 1. Verify MinIO is healthy (Keycloak Layer 1+2 backup destination)
mc alias set minio http://192.168.12.58:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY
mc admin info minio
# Expected: healthy, no offline drives

# 2. Check Keycloak backup bucket is non-empty and recent
mc ls minio/keycloak-backup/ | sort | tail -5
# Expected: objects within last 24 hours

# 3. Check Langfuse ClickHouse backup destination
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/pool/dataset?id=DATA%2Fbackups%2Flangfuse-clickhouse" | \
  jq '.[].used.parsed'
# Expected: > 0 (backups exist)

# 4. Verify B2 replication is current (off-host)
# Check MinIO ILM/replication target status — consult OPS-111-A runbook
```

### 5b. Disk space — DATA pool pre-flight

```bash
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/pool" | \
  jq '.[] | {name, free: (.free/1073741824|floor), pct_used: ((.allocated/.size*100)|floor)}'
# Go/no-go: DATA pool must be < 85% used. Currently 73.7% — acceptable.
# If DATA > 85%: reclaim space on seedbox-vm before proceeding.
```

### 5c. SSD pool thin-pool headroom

```bash
# SSD pool currently: 86 GB allocated / 740 GB total (11.6%) — well within limits
# The iSCSI zvols are thick-provisioned (not thin); no thin-pool exhaustion risk on SSD.
# Verify:
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/pool" | jq '.[] | select(.name=="SSD") | .free'
# Expected: > 500 GB free (currently 653 GB)
```

### 5d. All OKD nodes Ready

```bash
export KUBECONFIG=/home/ubuntu/.kube/config
oc get nodes
# Expected: all nodes STATUS=Ready, no NotReady/SchedulingDisabled
oc get pods -A | grep -v Running | grep -v Completed | grep -v Pending
# Expected: no CrashLoopBackOff, no ImagePullBackOff
```

### 5e. Vault is unsealed

```bash
curl -sk https://192.168.12.206:8200/v1/sys/health | jq '{sealed, version}'
# Expected: sealed=false
```

### 5f. SSH access to TrueNAS verified

```bash
# Sign JIT cert (required before each SSH session)
vault write -field=signed_key ssh/sign/admin \
  public_key=@~/.ssh/claude_jit.pub \
  valid_principals=koiakoia > ~/.ssh/claude_jit-cert.pub
chmod 600 ~/.ssh/claude_jit-cert.pub

# Test SSH access
ssh -i ~/.ssh/claude_jit \
    -o CertificateFile=~/.ssh/claude_jit-cert.pub \
    root@192.168.12.205 'truenas-version && echo SSH_OK'
# Expected: version string + SSH_OK
```

### 5g. SSH access to pve3 verified (for VM snapshot)

```bash
ssh root@192.168.12.57 'qm status 205'
# Expected: status: running
```

---

## 6. Update Procedure (Step-by-Step)

> Estimated elapsed time per step is shown. Total window: **~90 minutes** plus OKD recovery time.

### Step 0 — Announce maintenance window (T-60 min)

Post to Plane OPS-859 with exact start time. No automated announcement system; manual coordination only.

### Step 1 — Scale down non-essential OKD workloads (T+0, ~10 min)

Lower-priority workloads first to reduce iSCSI I/O during quiesce:

```bash
export KUBECONFIG=/home/ubuntu/.kube/config

# Scale down Langfuse (highest I/O - ClickHouse 100GB LUN)
oc scale deployment -n langfuse --all --replicas=0
oc scale statefulset -n langfuse --all --replicas=0

# Scale down DefectDojo, NetBox, Matrix (lower-priority services)
for ns in defectdojo netbox matrix; do
  oc scale deployment -n $ns --all --replicas=0
  oc scale statefulset -n $ns --all --replicas=0
done

# Verify pods terminating
oc get pods -n langfuse -n defectdojo -n netbox -n matrix
```

**Keep running:** Keycloak, Harbor, Plane, ArgoCD (these are needed for recovery orchestration)

### Step 2 — Stop NFS-dependent services (T+10, ~5 min)

```bash
# Stop arr-stack on seedbox-vm (NFS /mnt/DATA/data consumer)
ssh koiakoia@192.168.12.69 'docker compose -f ~/arr-stack/docker-compose.yml down' 2>/dev/null || \
  ssh koiakoia@192.168.12.69 'systemctl stop arr-stack.service' 2>/dev/null
# If neither works, note it — arr-stack downtime is acceptable
```

### Step 3 — Quiesce remaining iSCSI workloads (T+15, ~10 min)

```bash
# Gracefully stop the PostgreSQL pods with PVCs (they will remount on recovery)
for ns in harbor keycloak plane; do
  oc scale statefulset -n $ns --all --replicas=0
  oc scale deployment -n $ns --all --replicas=0
done

# Wait for all pods in iSCSI namespaces to terminate
oc wait --for=delete pod --all \
  -n langfuse -n defectdojo -n netbox -n matrix -n harbor -n keycloak -n plane \
  --timeout=120s

# Verify no iSCSI writes in-flight (check iscsid state on OKD nodes)
# From each OKD master (if accessible):
# iscsiadm -m session -P 0
# Expected: sessions still listed but idle (no writes since pods terminated)
```

### Step 4 — Take PVE VM snapshot (T+25, ~3 min)

```bash
SNAP_DATE=$(date +%Y%m%d)
ssh root@192.168.12.57 \
  "qm snapshot 205 pre-truenas-update-${SNAP_DATE} \
   --description 'OPS-859 pre-update $(date -u +%Y-%m-%dT%H:%M:%SZ)'"

# Verify
ssh root@192.168.12.57 'qm listsnapshot 205'
# Expected: new snapshot listed with date
```

### Step 5 — Apply TrueNAS update (T+28, ~20–30 min)

**Option A (Web UI — recommended):** Navigate to `https://192.168.12.205` → System → Update → click "Apply Pending Update". TrueNAS will download (if needed), apply, and prompt to reboot.

**Option B (API):** Not recommended for major updates; use web UI for visibility into progress and boot environment management.

**During update:**
- TrueNAS web UI will show update progress
- iSCSI service will be offline for the reboot phase (~5 min)
- OKD will show pods in `ContainerCreating` / `Pending` — this is expected

> The update applies to a NEW boot environment. The running OS is not modified. TrueNAS reboots into the new BE.

### Step 6 — Verify TrueNAS post-reboot (T+55, ~5 min)

```bash
# Check version
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  https://192.168.12.205/api/v2.0/system/version
# Expected: new version string (e.g. "TrueNAS-25.10.2")

# Check pool status
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/pool" | jq -r '.[] | "\(.name): \(.status) healthy=\(.healthy)"'
# Expected: all ONLINE, healthy=true

# Check iSCSI service
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/service?service=iscsitarget" | jq '.[].state'
# Expected: "RUNNING"
```

### Step 7 — iSCSI session recovery on OKD nodes (T+60, ~10 min)

After TrueNAS reboots, iscsid on OKD nodes will attempt automatic reconnection. For persistent PVs this is usually transparent. If pods remain stuck in `ContainerCreating`:

```bash
export KUBECONFIG=/home/ubuntu/.kube/config

# Check for stuck pods
oc get pods -A | grep ContainerCreating

# If pods are stuck, describe to confirm iSCSI mount failure:
oc describe pod -n <namespace> <pod-name> | grep -A5 Events

# Force iscsid to re-login (if needed — from OKD node directly):
# Note: OKD nodes may not have SSH accessible; use oc debug node/ instead
oc debug node/<node-name> -- chroot /host iscsiadm -m session -R

# Alternative: delete and let OKD recreate the pod
oc delete pod -n <namespace> <stuck-pod-name>
```

See `07-postgresql-crash-recovery.md` for detailed iSCSI reconnect procedure.

### Step 8 — Restore scaled-down workloads (T+70, ~10 min)

```bash
export KUBECONFIG=/home/ubuntu/.kube/config

# Scale up in priority order
# 1. Keycloak first (SSO dependency)
oc scale statefulset -n keycloak --all --replicas=1
oc rollout status statefulset -n keycloak postgresql --timeout=120s

# 2. Harbor (needed for any pod restarts)
oc scale statefulset -n harbor --all --replicas=1

# 3. Plane + NetBox (ops tools)
oc scale statefulset -n plane --all --replicas=1
oc scale statefulset -n netbox --all --replicas=1

# 4. Remaining services
for ns in defectdojo matrix langfuse; do
  oc scale statefulset -n $ns --all --replicas=1
  oc scale deployment -n $ns --all --replicas=1
done

# Restart arr-stack on seedbox-vm
ssh koiakoia@192.168.12.69 'docker compose -f ~/arr-stack/docker-compose.yml up -d' 2>/dev/null
```

### Step 9 — Post-update verification (T+80, ~10 min)

```bash
# All OKD pods running
oc get pods -A | grep -v Running | grep -v Completed | grep -v Pending

# Keycloak SSO health
curl -sk https://auth.208.haist.farm/realms/sentinel/.well-known/openid-configuration | python3 -c "import sys,json; d=json.load(sys.stdin); print('Keycloak OK:', d['issuer'])"

# Harbor
curl -sk https://harbor.208.haist.farm/api/v2.0/health | python3 -c "import sys,json; d=json.load(sys.stdin); print('Harbor:', d.get('status'))"

# Plane (iSCSI LUN functional)
curl -sk https://plane.208.haist.farm/api/v1/ | python3 -c "import sys; r=sys.stdin.read(); print('Plane OK' if '200' in r or len(r)>10 else 'Plane FAIL')"

# TrueNAS pools still healthy after workload re-attach
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "https://192.168.12.205/api/v2.0/pool" | jq -r '.[] | "\(.name): \(.status)"'
```

---

## 7. Failure Modes & Mitigations

### 7a. iSCSI Reconnection Storm

**Scenario:** TrueNAS reboots; all 8 iSCSI targets go offline simultaneously. OKD nodes issue parallel REOPEN/reconnect attempts. If reconnect storm overwhelms iscsid, sessions may not re-establish cleanly.

**Mitigation:**
1. Pre-quiesce (Step 1–3 above) reduces active sessions to near-zero before reboot
2. After TrueNAS is back: scale up workloads one namespace at a time (Step 8), not all at once
3. If storm occurs despite pre-quiesce: `oc delete pod -n <ns> <stuck-pod>` to force a clean remount attempt per pod
4. See `07-postgresql-crash-recovery.md` §iSCSI-reconnect for the manual `iscsiadm -m node -T <iqn> -p 192.168.12.205:3260 --login` procedure

**Estimated recovery time if storm occurs:** 10–20 additional minutes

### 7b. Thin-Pool Exhaustion During Update

**Scenario:** DATA pool at 73.7% used. If a large ZFS operation (snapshot, scrub) runs simultaneously with the update download, DATA pool could fill, pausing the TrueNAS middleware.

**Mitigation:**
1. Pre-flight check §5b: confirm DATA < 85% before proceeding
2. Disable any scheduled ZFS scrubs on DATA pool before the maintenance window
3. Stop active NFS writes (Step 2) before initiating update

**Detection:** TrueNAS web UI shows "pool is read-only" warning. Recovery: free space before retrying.

### 7c. Update Download Failure / Partial Apply

**Scenario:** Network interruption during update package download. TrueNAS may be left in a partial state.

**Mitigation:**
1. TrueNAS SCALE applies updates atomically to a new boot environment; the running BE is never modified during download
2. If download fails: retry via web UI. The old BE remains active and iSCSI continues running during download
3. Only the reboot phase causes downtime

### 7d. Web UI Lockout After Update

**Scenario:** TrueNAS middleware fails to start on the new BE. Web UI is unreachable at `https://192.168.12.205`.

**Mitigation — SSH access:**
```bash
# Sign JIT cert (Vault SSH CA is on pve3, independent of TrueNAS middleware)
vault write -field=signed_key ssh/sign/admin \
  public_key=@~/.ssh/claude_jit.pub \
  valid_principals=koiakoia > ~/.ssh/claude_jit-cert.pub

ssh -i ~/.ssh/claude_jit \
    -o CertificateFile=~/.ssh/claude_jit-cert.pub \
    root@192.168.12.205

# From TrueNAS shell — check middleware status:
systemctl status truenas-middleware.service

# Activate previous boot environment and reboot:
midclt call bootenv.activate <previous_be_name>
reboot
```

**Mitigation — PVE console:**
```bash
# If SSH also fails, access via Proxmox console:
ssh root@192.168.12.57 'qm terminal 205'
# Or use PVE web UI: https://192.168.12.57:8006 → VMID 205 → Console
```

**Nuclear option — PVE VM rollback:**
```bash
ssh root@192.168.12.57 'qm shutdown 205 --timeout 120'
ssh root@192.168.12.57 'qm rollback 205 pre-truenas-update-<date>'
ssh root@192.168.12.57 'qm start 205'
# TrueNAS returns to pre-update state. iSCSI recovers as normal.
```

### 7e. ZFS Pool Import Failure After Update

**Scenario:** After update, TrueNAS reboots but fails to import a ZFS pool (rare; typically caused by incompatible ZFS feature flags between kernel versions).

**Mitigation:**
1. TrueNAS SCALE 25.10.x in-place patch updates do not change the ZFS feature set; this is a risk only when jumping major versions
2. If it occurs: rollback via PVE VM snapshot (§4, Option C) is the fastest recovery path
3. If pools do not import on the rolled-back BE: follow `compliance-vault/runbooks/truenas-iscsi-lun-rebuild.md` for full reconstruction from backups

---

## 8. Rollback Decision Tree

```
TrueNAS web UI accessible after reboot?
├── YES → check version (§6) → proceed to §7 iSCSI recovery
└── NO (SSH still works)
    ├── middleware failed → activate previous BE + reboot (§7d)
    └── pools not imported → check 'zpool status -v' → rollback if errors
        └── NO (SSH also fails)
            ├── PVE console accessible → enter shell → activate previous BE
            └── PVE console also fails → PVE VM rollback (§4 rollback commands)
                └── Still stuck → escalate; use MinIO backups for data recovery
```

**Rollback SLA target:** < 20 minutes from decision to iSCSI service restored (via PVE VM rollback path)

---

## 9. Maintenance Window Estimate

| Phase | Duration | Notes |
|-------|----------|-------|
| Pre-flight checks (§5) | 15 min | Do before window opens |
| Scale down workloads (Steps 1–3) | 25 min | OKD pods terminating |
| PVE VM snapshot (Step 4) | 3 min | — |
| TrueNAS update + download (Step 5) | 20–30 min | Depends on package size and connection |
| TrueNAS reboot + pool import (Step 5–6) | 5–10 min | — |
| iSCSI session recovery (Step 7) | 10 min | Usually automatic; allow 10 min |
| Workload scale-up (Step 8) | 10 min | Sequential, priority-ordered |
| Post-update verification (Step 9) | 10 min | — |
| **Total maintenance window** | **~90–105 min** | |
| **Hard downtime (iSCSI offline)** | **~20–30 min** | Steps 5–7 only |
| **Application downtime** | **~60–75 min** | Steps 1–8 (pre-quiesce + recovery) |

**Recommend scheduling:** Saturday or Sunday, 02:00–04:00 local time (09:00–11:00 UTC) to minimize impact.

---

## 10. Go / No-Go Criteria

| Criterion | Go | No-Go |
|-----------|-----|-------|
| MinIO backup current (< 24h old) | ✓ | ✗ → delay until backup completes |
| DATA pool < 85% used | ✓ | ✗ → reclaim space first |
| SSD pool > 200 GB free | ✓ | ✗ → investigate zvol growth |
| All OKD nodes Ready | ✓ | ✗ → fix cluster first |
| Vault unsealed | ✓ | ✗ → fix Vault first |
| SSH to TrueNAS works (JIT cert) | ✓ | ✗ → fix SSH CA or re-run truenas-jit-ssh.yml |
| PVE VM snapshot created | ✓ | ✗ → do not proceed without rollback layer B |
| Release notes reviewed for this version | ✓ | ✗ → read before applying |

---

## 11. Post-Update Tasks (after stable for 24h)

1. **Delete PVE VM snapshot** once TrueNAS stability is confirmed (snapshots consume disk on pve3)
2. **Delete ZFS pre-update snapshots** (if taken in Layer C of §4)
3. **Update this runbook** with actual elapsed times from the maintenance window
4. **Update `compliance-vault/runbooks/truenas-iscsi-lun-rebuild.md`** — the ZFS dataset paths there (`tank/iscsi/...`) are stale; correct paths are `SSD/iscsi-okd/...` (create a separate OPS issue)
5. **Open follow-on OPS issue** for the actual upgrade execution, linking this runbook

---

## Appendix: Quick Reference

```bash
# TrueNAS API token (from Vault)
TRUENAS_TOKEN=$(VAULT_ADDR=https://vault.208.haist.farm VAULT_TOKEN=$(cat ~/.vault-token) \
  vault kv get -field=api_token secret/truenas)

# TrueNAS API base URL
TRUENAS_URL=https://192.168.12.205

# Sign JIT SSH cert
vault write -field=signed_key ssh/sign/admin \
  public_key=@~/.ssh/claude_jit.pub \
  valid_principals=koiakoia > ~/.ssh/claude_jit-cert.pub

# SSH to TrueNAS
ssh -i ~/.ssh/claude_jit -o CertificateFile=~/.ssh/claude_jit-cert.pub root@192.168.12.205

# SSH to pve3 (TrueNAS host)
ssh root@192.168.12.57

# Check TrueNAS version
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" $TRUENAS_URL/api/v2.0/system/version

# Check all pools
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" $TRUENAS_URL/api/v2.0/pool | \
  jq -r '.[] | "\(.name): \(.status) free=\(.free/1073741824|floor)GB"'

# Check iSCSI service
curl -sk -H "Authorization: Bearer $TRUENAS_TOKEN" \
  "$TRUENAS_URL/api/v2.0/service?service=iscsitarget" | jq '.[].state'

# OKD quick health
export KUBECONFIG=/home/ubuntu/.kube/config
oc get nodes && oc get pods -A | grep -v Running | grep -v Completed | wc -l
```
