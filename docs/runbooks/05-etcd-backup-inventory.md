# etcd Backup Inventory — OKD Native vs Custom etcd-backup.sh

**Relates to:** OPS-939, OPS-921 (MinIO recovery), OPS-936 (etcd backup investigation)
**Last updated:** 2026-05-29

---

## Summary

Two independent etcd backup streams write to MinIO `etcd-backups`. This document inventories
both, identifies their sources from IaC evidence, and frames the Option A/B/C decision
the operator must make.

---

## Stream 1 — Custom `etcd-backup.sh` (IaC-managed, confirmed)

| Attribute | Value |
|-----------|-------|
| **Script** | `/usr/local/bin/etcd-backup.sh` |
| **Deployed by** | `ansible/roles/iac-control/tasks/services.yml` |
| **Systemd unit** | `etcd-backup.timer` + `etcd-backup.service` |
| **Schedule** | Daily at **04:00 UTC** (`OnCalendar=*-*-* 04:00:00`) |
| **Output format** | `etcd-snapshot-<YYYYMMDD-HHMMSS>.db` (plain, unencrypted) |
| **MinIO bucket** | `etcd-backups` |
| **MinIO endpoint** | `http://192.168.12.58:9000` (primary MinIO LXC) |
| **MinIO credentials** | Scoped `etcd-backup-prod` user (OPS-285); fetched from `secret/minio/etcd-backup` in Vault |
| **Source files** | `ansible/roles/iac-control/templates/etcd-backup.sh.j2`, `etcd-backup.timer.j2`, `etcd-backup.service.j2`, `etcd-backup.env.j2` |

**Mechanism:** Runs on `iac-control` (192.168.12.210). SSHs to the OKD master node,
invokes `/usr/local/bin/cluster-backup.sh` (OKD built-in snapshot utility), copies
the snapshot via SCP, and uploads to MinIO.

**Known issues:** OPS-936 found that prior to the OPS-936 fix, failed `mc cp` exits
did not clean up local temp files, causing disk accumulation. Fixed in same issue.

---

## Stream 2 — 6-hourly KMS-encrypted triplets (source unconfirmed — requires live cluster check)

| Attribute | Value |
|-----------|-------|
| **Output format** | `snapshot_<ts>.db.enc` + `snapshot_<ts>.db.enc.dek` + `snapshot_<ts>.db.enc.iv` |
| **Schedule** | Every 6 hours at **00:00, 06:00, 12:00, 18:00 UTC** |
| **MinIO bucket** | `etcd-backups` |
| **Encryption** | KMS-wrapped DEK + IV (distinct from Stream 1 which is unencrypted) |

**Hypothesis (from judge-936, 2026-05-25T15:55Z):** Almost certainly the OKD
`cluster-etcd-operator` auto-backup feature. Modern OKD/OCP ships an automated etcd
backup mechanism that writes snapshots to a configured S3 endpoint. The naming pattern
(`snapshot_<ts>.db.enc` + DEK + IV) matches OKD's KMS-encrypted backup format.

**No IaC trace found.** A search of sentinel-iac found no Kubernetes manifests,
CRD definitions, or `oc apply` scripts deploying an `EtcdBackup` resource or
configuring `cluster-etcd-operator` S3 output. This means either:
- The operator configured it directly on the cluster (not reflected in IaC), or
- OKD ships it pre-configured and it uses a MinIO endpoint set during cluster install.

**Live verification required before deciding:**

```bash
# From iac-control or a workstation with kubeconfig:
oc get etcdbackup --all-namespaces 2>/dev/null || echo "CRD not present"
oc get clusteretcdbackup --all-namespaces 2>/dev/null || echo "CRD not present"

# Check cluster-etcd-operator deployment for S3 env vars
oc -n openshift-etcd-operator describe deployment/etcd-operator | grep -i "s3\|minio\|bucket\|endpoint" || true
oc -n openshift-etcd get pods -l 'app=etcd-operator' -o json | jq '.items[].spec.containers[].env[] | select(.name | test("S3|MINIO|BUCKET|ENDPOINT"; "i"))'

# Trace MinIO access logs to confirm writer IP
# On iac-control (MinIO admin access):
mc admin trace minio --call PUTOBJECT --filter "etcd-backups/snapshot_" --json | head -20
```

---

## Decision Framework (Operator Action Required)

After running the live verification above, choose one of:

### Option A — Drop custom `etcd-backup.sh`, keep OKD-native

**Preconditions for choosing A:**
- `oc get etcdbackup` or cluster-etcd-operator env vars confirm OKD-native is active
- The 6-hourly cadence has been running reliably (check MinIO history: `mc ls minio/etcd-backups/ --json | jq .`)
- Operator is comfortable that OKD-native backup is auditable and alertable

**How to remove custom backup:**
1. Comment out or remove the `etcd backup` block in `ansible/roles/iac-control/tasks/services.yml`
2. Run the iac-control playbook: `ansible-playbook ansible/playbooks/iac-control.yml --tags services`
3. On iac-control: `systemctl disable --now etcd-backup.timer && systemctl disable --now etcd-backup.service`
4. Remove orphaned files: `rm /usr/local/bin/etcd-backup.sh /etc/sentinel/etcd-backup.env`
5. Create a Plane issue tracking the removal (so it's not re-deployed on next Ansible run)

**Risk:** If OKD-native breaks silently, there is no backup path. Consider adding a Wazuh
rule or MinIO bucket-level alert that fires if no new snapshot lands in `etcd-backups`
within 25 hours.

### Option B — Keep both (defense-in-depth, recommended default)

**Rationale:** Two independent backup paths from different processes. OPS-936 showed
the custom backup had a silent failure mode (orphaned temp files + upload failure
leaving the LAST good snapshot stale). Having OKD-native as a second stream means
a failure in one path does not leave the cluster unprotected.

**Cost:** Minor operational complexity — two different backup formats in the same bucket
requires operators to know which to use for restore. The custom stream produces
`etcd-snapshot-*.db` (usable directly with `etcdctl snapshot restore`). The OKD-native
produces `snapshot_*.db.enc` (requires KMS DEK/IV for decryption before restore).

**Recommended:** Add a comment to `services.yml` cross-referencing Stream 2, so future
operators know both streams exist and why.

### Option C — Drop OKD-native, keep custom

**When to choose C:** Only if live verification shows OKD-native was manually configured
by a previous operator using a now-lost credential or config that cannot be reproduced.
In that case, replacing it with the explicit, IaC-managed custom backup is safer.

**How to disable OKD-native backup** (if it is a CRD-based resource):
```bash
oc delete etcdbackup --all -n openshift-etcd-operator 2>/dev/null || true
# Or: patch the cluster-etcd-operator to disable S3 export
# (specific method depends on OKD version — verify with `oc version`)
```

---

## Restore Procedures

### Restore from Stream 1 (custom, unencrypted `etcd-snapshot-*.db`)

```bash
# Copy snapshot from MinIO to master node
mc cp minio/etcd-backups/etcd-snapshot-<TIMESTAMP>.db /tmp/etcd-restore/snapshot.db

# On master node:
sudo /usr/local/bin/restore-etcd.sh /tmp/etcd-restore/snapshot.db
```

See `docs/disaster-recovery.md` for full multi-master restore procedure.

### Restore from Stream 2 (OKD-native, KMS-encrypted)

Requires access to the KMS DEK and IV stored alongside the snapshot:

```bash
# Decrypt the snapshot using the DEK and IV
# (Exact command depends on KMS implementation — check cluster-etcd-operator docs
#  or `oc -n openshift-etcd-operator logs` for encryption method details)
mc cp minio/etcd-backups/snapshot_<TS>.db.enc /tmp/snapshot.enc
mc cp minio/etcd-backups/snapshot_<TS>.db.enc.dek /tmp/snapshot.dek
mc cp minio/etcd-backups/snapshot_<TS>.db.enc.iv  /tmp/snapshot.iv

# Decrypt (example with openssl AES-256-CBC — verify actual method from operator logs):
# openssl enc -d -aes-256-cbc -in /tmp/snapshot.enc -out /tmp/snapshot.db \
#   -K "$(xxd -p /tmp/snapshot.dek)" -iv "$(xxd -p /tmp/snapshot.iv)"

# Then restore as for Stream 1
```

**NOTE:** The decryption method for Stream 2 snapshots has NOT been tested end-to-end
on this platform. Operator must validate Stream 2 restorability before relying on it.
This is a follow-up action regardless of which Option (A/B/C) is chosen.

---

## Cross-references

- `ansible/roles/iac-control/tasks/services.yml` — deploys Stream 1
- `ansible/roles/iac-control/templates/etcd-backup.sh.j2` — Stream 1 script source
- `ansible/roles/iac-control/templates/etcd-backup.timer.j2` — Stream 1 schedule (04:00 UTC daily)
- `docs/disaster-recovery.md` — OKD restore procedure
- OPS-921 — first observation of Stream 2 encrypted snapshots during MinIO recovery
- OPS-936 — Stream 1 fix (orphaned temp files + cleanup trap); stream identification
- OPS-939 — this document's parent issue; decision tracking
