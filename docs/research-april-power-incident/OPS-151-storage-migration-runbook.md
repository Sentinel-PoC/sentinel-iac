# OPS-151 — iSCSI inline → CSI migration runbook

**Author:** opus-4.7 worker session
**Date:** 2026-04-27
**Mode:** Research + design only. No infra changes in this MR.
**Operating constraint:** This is **not** a live production environment. Uptime
is not a requirement during MW2. The migration model is:

1. Scale all stateful workloads to zero.
2. Quiesce iSCSI volumes (no writes during migration).
3. Migrate per workload.
4. Bring everything back up.

This runbook is written for the scaled-to-zero pattern. It does not design for
live migration.

**Cluster baseline (verified 2026-04-27):**

- 3-node compact OKD 4.19, kubelet `v1.32.7`, cri-o `1.32.4`, CentOS Stream
  CoreOS `9.0.20250827-0` on master-1/2/3 at `10.0.0.221/.222/.223`.
- Storage: TrueNAS at `192.168.12.205:3260` exporting iSCSI LUNs +
  `nfs-storage` provisioner backed by an NFS share on the same TrueNAS.
- Eight in-tree iSCSI inline-volume PVs (`*-iscsi`) bound, all 15 GiB, all
  XFS, all RWO, all reclaim policy `Retain`. The plain `nfs-storage` provisioner
  handles ~17 NFS-backed PVCs that are out of scope for this migration (they
  already use a dynamic provisioner, just not a CSI one).
- Vault, Forgejo, Wazuh, and Keycloak's *external* OIDC trust path live
  **off-cluster**. The only `keycloak-pg-iscsi` PVC is the *cluster's local*
  Keycloak Postgres (verify on the day of MW2 — see §8 risks).

---

## 1. CSI driver selection

### Candidates evaluated

| Driver | Source/topology | Compatible with our stack | Verdict |
|---|---|---|---|
| **`democratic-csi` (`freenas-iscsi` / `freenas-api-iscsi` / `freenas-nfs`)** | TrueNAS API-driven dynamic LUN/dataset provisioner; runs in-cluster as a CSI controller + node plugin DaemonSet | Yes — natively targets TrueNAS SCALE/CORE; iSCSI mode replaces what we have today, NFS mode replaces the existing nfs-subdir provisioner | **CHOSEN** for both iSCSI workloads and (optionally) NFS workloads |
| `rook-ceph` | Replaces TrueNAS with an in-cluster Ceph cluster; needs raw block devices on each node | No — we want to keep TrueNAS in the picture. Adding an SDS layer doubles the storage substrate and demands raw devices we don't have spare on a 3-node compact PVE-cluster reality | Rejected |
| `longhorn` | Replicated block storage from in-cluster nodes' local disks | No — same problem as rook: replaces TrueNAS, needs node-local capacity, adds replication overhead on a single-host PVE failure domain | Rejected |
| `synology-csi` | Synology DSM API | N/A — we don't run Synology. Listed because the issue scoped it. | Rejected |
| TrueNAS in-tree iSCSI plugin (status quo) | Kubernetes in-tree, deprecated | Slated for removal in upstream Kubernetes; OKD 4.20/4.21 published release notes do not pin the removal version — see RESEARCH-okd-upgrade.md §3. Cannot rely on it past 4.20 without a per-version dry run | The thing we are migrating *off* |

**Choice: `democratic-csi`, `freenas-api-iscsi` driver class for the eight
existing iSCSI workloads. NFS workloads stay on the existing
`nfs-subdir-external-provisioner` for now (separate decision; out of scope
for OPS-151).**

### Why democratic-csi

1. **Topology fit.** It is an API-driven proxy that calls TrueNAS over its
   REST API to create/destroy zvols and iSCSI extents on demand. The data
   plane stays on TrueNAS — same physical storage, same backup tooling, same
   ZFS snapshots. We are replacing the *Kubernetes-side glue* only. Source:
   `https://github.com/democratic-csi/democratic-csi#readme`.
2. **CSI-spec compliant.** Implements
   `ControllerPublishVolume` / `NodeStageVolume` / `NodePublishVolume`
   correctly, which means kubelet-mount lifecycle is owned by the CSI driver.
   The "wedged kubelet mount on EIO" failure mode of the in-tree driver
   (root cause of the 2026-04-27 incident, recovery-ledger PLAN.md §CORRECTION)
   becomes a CSI driver concern with explicit
   `NodeUnstageVolume` recovery semantics, not a kubelet-mount-table loop.
3. **Single-host PVE-cluster reality.** No SDS overhead. No raw-device
   requirement. No new offsite dependency. We keep the storage in one box on
   one PVE host, which is what we already have.
4. **Sigstore / disconnected install fit.** Driver image is small and pulled
   once per node. We can mirror it through the same Harbor + off-cluster
   mirror-registry pattern documented in RESEARCH-air-gapped-fail-secure.md §3.
5. **`freenas-api-iscsi` vs `freenas-iscsi`:** the API-driven driver class
   uses TrueNAS REST for zvol/extent management instead of SSH-driven
   provisioning. We already manage TrueNAS through its API; pick `freenas-api-iscsi`.
   Source: `https://github.com/democratic-csi/charts/tree/master/stable/democratic-csi`.

### Constraints worth flagging

- **TrueNAS API key required.** Generate a dedicated key for
  democratic-csi (TrueNAS UI: *Settings → API Keys*). Treat it as a privileged
  credential — it can create/destroy datasets and iSCSI shares. Store in Vault
  at `secret/data/okd/democratic-csi/truenas-api-key` and inject via
  `external-secrets` or sealed-secrets — do not commit the API key to
  Forgejo. (Project rule: secrets always come from Vault.)
- **OCP/OKD security context constraints (SCC).** The democratic-csi node plugin
  needs `privileged` SCC because it runs `iscsiadm` and mounts. The chart
  documents the ServiceAccount that needs `privileged` binding. OKD's default
  SCC is `restricted-v2`; the operator binds explicitly via
  `oc adm policy add-scc-to-user privileged -z <sa>` (or via a generated
  RoleBinding from the chart's `rbac` mode). Source: democratic-csi chart
  `values.yaml` `controller.driver.privileged` and `node.driver.privileged`.
- **OKD CSI driver enablement.** The Kubernetes Storage Operator handles CSI
  driver registration via the `CSIDriver` object the chart installs. No
  cluster-storage-operator change needed for a third-party driver. Source:
  `https://docs.okd.io/4.19/storage/container_storage_interface/persistent-storage-csi.html`.

### Sources cited in §1

- democratic-csi GitHub README: `https://github.com/democratic-csi/democratic-csi`
- democratic-csi Helm charts: `https://github.com/democratic-csi/charts`
- OKD 4.19 CSI overview: `https://docs.okd.io/4.19/storage/container_storage_interface/persistent-storage-csi.html`
- OCP storage / CSI migration: `https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/storage/using-container-storage-interface-csi`
- TrueNAS iSCSI API docs: `https://www.truenas.com/docs/api/`

---

## 2. Live PVC inventory

Inventory captured `2026-04-27` from iac-control via
`oc get pvc -A -o wide` and `oc get pv -o wide` (full output is in this MR's
gather notes). Eight iSCSI-backed PVCs are in scope. NFS-backed PVCs
(provisioner `cluster.local/nfs-provisioner-nfs-subdir-external-provisioner`)
are listed as context but stay where they are.

### iSCSI-backed PVCs (in scope — these get migrated)

| Namespace | PVC | PV (iSCSI IQN) | Size | Workload (Deployment/StatefulSet) | Data shape | Backup primitive | Live size (du -sh) |
|---|---|---|---|---|---|---|---|
| `defectdojo` | `defectdojo-postgresql-data` | `iqn.2026-03.farm.haist:okd-defectdojo-pg` | 15 GiB | Deployment `defectdojo-postgresql` | Postgres | `pg_dumpall` (logical) | 337 MB |
| `harbor` | `harbor-postgresql-data` | `iqn.2026-03.farm.haist:okd-harbor-pg` | 15 GiB | Deployment `harbor-database` | Postgres (Harbor) | `pg_dumpall` | 424 MB |
| `keycloak` | `postgresql-data` | `iqn.2026-03.farm.haist:okd-keycloak-pg` | 15 GiB | Deployment `postgresql` (Keycloak's local PG) | Postgres | `pg_dumpall` | 69 MB |
| `langfuse` | `langfuse-clickhouse-data` | `iqn.2026-03.farm.haist:okd-langfuse-ch` | 15 GiB | Deployment `langfuse-clickhouse` | ClickHouse | `clickhouse-backup create + upload`, OR cold rsync at scale=0 | n/a (scale-0 path: rsync) |
| `langfuse` | `langfuse-postgresql-data` | `iqn.2026-03.farm.haist:okd-langfuse-pg` | 15 GiB | Deployment `langfuse-postgresql` | Postgres | `pg_dumpall` | 67 MB |
| `matrix` | `matrix-postgresql-data` | `iqn.2026-03.farm.haist:okd-matrix-pg` | 15 GiB | Deployment `matrix-postgresql` | Postgres (Synapse) | `pg_dumpall` | 85 MB |
| `netbox` | `netbox-postgresql-data` | `iqn.2026-03.farm.haist:okd-netbox-pg` | 15 GiB | Deployment `netbox-postgresql` | Postgres | `pg_dumpall` | 82 MB |
| `plane` | `plane-postgresql-data` | `iqn.2026-03.farm.haist:okd-plane-pg` | 15 GiB | Deployment `plane-postgresql` | Postgres | `pg_dumpall` | 408 MB |

All eight share these properties: RWO, XFS, reclaim policy **Retain**, target
portal `192.168.12.205:3260`, statically provisioned (PV name == LUN name,
not a `pvc-<uuid>` style).

**Total live data:** ~1.5 GB across the eight Postgres dumps + a single
ClickHouse instance whose live size we could not measure (the
`langfuse-clickhouse` pod's image doesn't expose `du`); reserve 15 GiB headroom
for it. **Total backup volume needed: ~20 GiB** (see §7 sizing).

### NFS-backed PVCs (context only — out of scope)

These already use a dynamic provisioner (`nfs-subdir-external-provisioner`).
They are not affected by MW2. Listed for completeness:

- `backstage/backstage-postgresql-data` (15 Gi)
- `defectdojo/data-defectdojo-valkey-0` (8 Gi)
- `harbor/data-harbor-redis-0` (1 Gi), `harbor/data-harbor-trivy-0` (5 Gi),
  `harbor/harbor-jobservice` (1 Gi), `harbor/harbor-registry` (100 Gi)
- `health-monitoring/ntfy-cache` (1 Gi)
- `langfuse/langfuse-ch-backup` (200 Gi, RWX, manual-nfs PV — **this is the
  backup target candidate; see §7**)
- `langfuse/langfuse-s3-data` (5 Gi)
- `matrix/synapse-media-store` (5 Gi)
- `media/jellyfin-cache` (10 Gi), `media/jellyfin-config` (2 Gi),
  `media/jellyfin-media` (20 Ti, RWX, manual-nfs PV)
- `netbox/data-netbox-postgresql-0` (10 Gi — note: this is netbox's *valkey*
  primary's claim path, the actual netbox postgres data is the iSCSI one
  above), `netbox/netbox-media` (5 Gi),
  `netbox/valkey-data-netbox-valkey-primary-0` (8 Gi)
- `openshift-image-registry/image-registry-storage` (100 Gi, RWX)
- `plane/pvc-plane-minio-vol-plane-minio-wl-0` (10 Gi),
  `plane/pvc-plane-rabbitmq-vol-plane-rabbitmq-wl-0` (1 Gi),
  `plane/pvc-plane-redis-vol-plane-redis-wl-0` (2 Gi)

### Data shape → backup primitive rationale

- **Postgres (7 of 8):** `pg_dumpall` is the safe primitive at scale=0. We
  considered `pg_basebackup` but the migration target is a fresh PVC with a
  different storage class, so a logical dump and `psql` restore is simpler and
  doesn't carry physical layout assumptions. Filesystem-level copy of
  `/var/lib/postgresql/data` would also work because all eight pods are scaled
  to zero during MW2 (no concurrent writes), but a logical dump is portable
  across PG minor-version drift if any image bumped between backup and restore.
- **ClickHouse:** `clickhouse-backup` is the documented tool, but it requires
  a sidecar config and an S3 (or local) target. Because workload is at
  scale=0, the simpler primitive is **`tar` of the on-disk
  `/bitnami/clickhouse` directory while the deployment is at replicas=0**.
  No concurrent writes = the same flat-tar pattern that works for any cold
  filesystem. Source:
  `https://clickhouse.com/docs/en/operations/backup` notes that BACKUP/RESTORE
  requires a running server; cold copy is the documented alternative for
  offline migrations.

### Sources cited in §2

- `pg_dumpall` docs: `https://www.postgresql.org/docs/current/app-pg-dumpall.html`
- ClickHouse backup docs: `https://clickhouse.com/docs/en/operations/backup`
- democratic-csi static-PV migration discussion (issue thread):
  `https://github.com/democratic-csi/democratic-csi/issues/233`

---

## 3. Per-workload migration recipes

All recipes assume:

- The democratic-csi driver is installed and a `StorageClass` named
  `truenas-iscsi-csi` with `reclaimPolicy: Retain` exists. Verified by §5
  pre-flight before MW2 begins.
- A backup share is mounted on iac-control at `/srv/mw2-backup` (NFS export
  from TrueNAS — see §7).
- Argo CD applications for each namespace are paused
  (`argocd app sync --auto-prune=false` and `app set --sync-policy=none`)
  for the duration of MW2. Otherwise GitOps will fight the manual operations.
- The operator (Jim) has the cluster-admin kubeconfig on iac-control.

The general pattern for every workload is:

1. **Dump** the data from the running pod (logical dump for PG, cold copy for
   CH).
2. **Scale to zero.**
3. **Quiesce iSCSI** (verify no writes; the kubelet should detach within
   ~60s of scale-0).
4. **Detach the iSCSI inline PV from its PVC** (delete the PVC; PV stays
   `Released` due to `Retain`).
5. **Create a new PVC** under `truenas-iscsi-csi` with the same name. The
   driver provisions a fresh zvol on TrueNAS.
6. **Restore** data into the new PVC.
7. **Scale back to one** and validate.

### 3.1 plane-postgresql

```bash
# 1. Dump (while the pod is still running; backup will catch the live state)
oc -n plane exec deploy/plane-postgresql -- \
  pg_dumpall -U postgres > /srv/mw2-backup/plane-postgresql.sql

# Verify dump size > 0 and ends with PostgreSQL database cluster dump complete
ls -lh /srv/mw2-backup/plane-postgresql.sql
tail -1 /srv/mw2-backup/plane-postgresql.sql

# 2. Scale to zero (also scale Plane workloads that depend on PG)
oc -n plane scale deploy plane-postgresql --replicas=0
oc -n plane scale deploy plane-api-wl plane-web-wl plane-admin-wl \
  plane-space-wl plane-live-wl plane-worker-wl plane-beat-worker-wl \
  --replicas=0

# 3. Wait for the volumeattachment to drain
oc get volumeattachment -o wide | grep plane-pg-iscsi   # should be empty within ~90s
# Cross-check on the master that had it: ssh -i ~/.ssh/okd_key core@10.0.0.222 \
#   sudo iscsiadm -m session   # iqn:okd-plane-pg should be gone or idle

# 4. Detach the inline iSCSI PV
oc -n plane delete pvc plane-postgresql-data
# PV plane-pg-iscsi → status Released (reclaim=Retain). Do NOT delete the PV.
# Do NOT delete the LUN on TrueNAS until §6 rollback window passes.

# 5. Create new PVC under CSI storage class
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: plane-postgresql-data
  namespace: plane
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi-csi
  resources:
    requests:
      storage: 15Gi
EOF

# Wait for PVC Bound
oc -n plane get pvc plane-postgresql-data -w   # Ctrl-C when Bound

# 6. Restore. We restore into a temporary "init" pod that mounts the new PVC
# at /var/lib/postgresql/data and runs initdb + psql. The cleanest way:
oc -n plane scale deploy plane-postgresql --replicas=1
oc -n plane wait --for=condition=Available deploy/plane-postgresql --timeout=180s

# Bootstrap is now an empty PG; load the dump
oc -n plane exec -i deploy/plane-postgresql -- \
  psql -U postgres < /srv/mw2-backup/plane-postgresql.sql

# 7. Validate
oc -n plane exec deploy/plane-postgresql -- \
  psql -U postgres -c "SELECT count(*) FROM pg_database;"
oc -n plane exec deploy/plane-postgresql -- \
  psql -U plane -d plane -c "SELECT count(*) FROM users;"  # workload-specific

# Bring up dependent workloads
oc -n plane scale deploy plane-api-wl --replicas=2
oc -n plane scale deploy plane-web-wl plane-admin-wl plane-space-wl \
  plane-live-wl plane-worker-wl plane-beat-worker-wl --replicas=1

# Validate Plane API end-to-end
curl -sk -H "x-api-key: $PLANE_KEY" \
  https://plane.208.haist.farm/api/v1/workspaces/$WORKSPACE_SLUG/projects/ \
  | jq '.results | length'
```

**Estimated time: 25 min** (5 dump, 2 scale-0, 5 PVC swap, 5 restore, 8 validate).

### 3.2 harbor-database

Identical shape to plane-postgresql. Differences:

```bash
# Dump
oc -n harbor exec deploy/harbor-database -- pg_dumpall -U postgres \
  > /srv/mw2-backup/harbor-postgresql.sql

# Scale to zero — harbor has more deps; do them all
oc -n harbor scale deploy harbor-database harbor-core harbor-jobservice \
  harbor-portal harbor-registry harbor-nginx harbor-exporter --replicas=0

# After PVC swap and restore (same as 3.1), bring back up:
oc -n harbor scale deploy harbor-database --replicas=1
oc -n harbor wait --for=condition=Available deploy/harbor-database --timeout=180s
oc -n harbor exec -i deploy/harbor-database -- psql -U postgres \
  < /srv/mw2-backup/harbor-postgresql.sql
oc -n harbor scale deploy harbor-core harbor-jobservice harbor-portal \
  harbor-registry harbor-nginx harbor-exporter --replicas=1

# Validate
curl -sk https://harbor.208.haist.farm/v2/      # 200
curl -sk https://harbor.208.haist.farm/api/v2.0/health | jq .status   # healthy
```

**Estimated time: 30 min** (Harbor has more dependents to wait on).

### 3.3 keycloak postgresql

```bash
oc -n keycloak exec deploy/postgresql -- pg_dumpall -U postgres \
  > /srv/mw2-backup/keycloak-postgresql.sql
oc -n keycloak scale deploy keycloak postgresql --replicas=0
# … standard PVC swap …
oc -n keycloak scale deploy postgresql --replicas=1
oc -n keycloak wait --for=condition=Available deploy/postgresql --timeout=180s
oc -n keycloak exec -i deploy/postgresql -- psql -U postgres \
  < /srv/mw2-backup/keycloak-postgresql.sql
oc -n keycloak scale deploy keycloak --replicas=1

# Validate — OIDC well-known endpoint
curl -sk https://keycloak.208.haist.farm/realms/master/.well-known/openid-configuration \
  | jq .issuer   # = "https://keycloak.208.haist.farm/realms/master"
```

**Estimated time: 20 min.**

### 3.4 matrix-postgresql

```bash
oc -n matrix exec deploy/matrix-postgresql -- pg_dumpall -U postgres \
  > /srv/mw2-backup/matrix-postgresql.sql
oc -n matrix scale deploy matrix-postgresql synapse mas element-web --replicas=0
# … swap …
oc -n matrix scale deploy matrix-postgresql --replicas=1
oc -n matrix wait --for=condition=Available deploy/matrix-postgresql --timeout=180s
oc -n matrix exec -i deploy/matrix-postgresql -- psql -U postgres \
  < /srv/mw2-backup/matrix-postgresql.sql
oc -n matrix scale deploy synapse mas element-web --replicas=1

# Validate — federation API
curl -sk https://matrix.208.haist.farm/_matrix/client/versions | jq .versions
```

**Estimated time: 20 min.**

### 3.5 netbox-postgresql

```bash
oc -n netbox exec deploy/netbox-postgresql -- pg_dumpall -U postgres \
  > /srv/mw2-backup/netbox-postgresql.sql
oc -n netbox scale deploy netbox-postgresql netbox netbox-worker --replicas=0
oc -n netbox scale statefulset netbox-valkey-primary --replicas=0
# … swap …
oc -n netbox scale deploy netbox-postgresql --replicas=1
oc -n netbox wait --for=condition=Available deploy/netbox-postgresql --timeout=180s
oc -n netbox exec -i deploy/netbox-postgresql -- psql -U postgres \
  < /srv/mw2-backup/netbox-postgresql.sql
oc -n netbox scale statefulset netbox-valkey-primary --replicas=1
oc -n netbox scale deploy netbox netbox-worker --replicas=1

# Validate
curl -sk https://netbox.208.haist.farm/api/status/ | jq .
```

**Estimated time: 20 min.**

### 3.6 langfuse-postgresql

```bash
oc -n langfuse exec deploy/langfuse-postgresql -- pg_dumpall -U postgres \
  > /srv/mw2-backup/langfuse-postgresql.sql
# … same shape as 3.1; deps to scale-0:
oc -n langfuse scale deploy langfuse-postgresql langfuse-web langfuse-worker \
  langfuse-clickhouse langfuse-redis langfuse-s3 --replicas=0
# … swap PG, restore PG …
# Validate
curl -sk https://langfuse.208.haist.farm/api/public/health | jq .
```

**Estimated time: 20 min** (does not include ClickHouse — see 3.7).

### 3.7 langfuse-clickhouse (cold-copy, not pg_dump)

```bash
# Already at replicas=0 from 3.6. Backup directly via a dump pod.
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ch-dump
  namespace: langfuse
spec:
  restartPolicy: Never
  containers:
    - name: ch
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: ch-data, mountPath: /data }
        - { name: backup, mountPath: /backup }
  volumes:
    - name: ch-data
      persistentVolumeClaim: { claimName: langfuse-clickhouse-data }
    - name: backup
      nfs:
        server: 192.168.12.205
        path: /mnt/tank/mw2-backup
EOF

oc -n langfuse wait --for=condition=Ready pod/ch-dump --timeout=120s
oc -n langfuse exec ch-dump -- tar czf /backup/langfuse-clickhouse.tgz -C /data .
oc -n langfuse delete pod ch-dump

# Verify size > 0
ls -lh /srv/mw2-backup/langfuse-clickhouse.tgz

# Detach old PV, create new PVC, then restore via a sibling pod
oc -n langfuse delete pvc langfuse-clickhouse-data
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: langfuse-clickhouse-data, namespace: langfuse }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi-csi
  resources: { requests: { storage: 15Gi } }
EOF
oc -n langfuse get pvc langfuse-clickhouse-data -w   # Ctrl-C when Bound

# Restore
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata: { name: ch-restore, namespace: langfuse }
spec:
  restartPolicy: Never
  containers:
    - name: ch
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: ch-data, mountPath: /data }
        - { name: backup, mountPath: /backup }
  volumes:
    - name: ch-data
      persistentVolumeClaim: { claimName: langfuse-clickhouse-data }
    - name: backup
      nfs: { server: 192.168.12.205, path: /mnt/tank/mw2-backup }
EOF
oc -n langfuse wait --for=condition=Ready pod/ch-restore --timeout=120s
oc -n langfuse exec ch-restore -- tar xzf /backup/langfuse-clickhouse.tgz -C /data
oc -n langfuse delete pod ch-restore

oc -n langfuse scale deploy langfuse-clickhouse --replicas=1
oc -n langfuse wait --for=condition=Available deploy/langfuse-clickhouse --timeout=300s

# Validate
oc -n langfuse exec deploy/langfuse-clickhouse -- \
  clickhouse-client -q "SELECT count() FROM system.tables"

# Bring back langfuse stack
oc -n langfuse scale deploy langfuse-redis langfuse-s3 langfuse-web \
  langfuse-worker --replicas=1
```

**Estimated time: 35 min** (ClickHouse on-disk format is fussy about exact
mount semantics; budget extra).

### 3.8 defectdojo-postgresql

```bash
oc -n defectdojo exec deploy/defectdojo-postgresql -- pg_dumpall -U postgres \
  > /srv/mw2-backup/defectdojo-postgresql.sql
oc -n defectdojo scale deploy defectdojo-postgresql defectdojo-django \
  defectdojo-celery-beat defectdojo-celery-worker --replicas=0
oc -n defectdojo scale statefulset defectdojo-valkey --replicas=0
# … swap …
oc -n defectdojo scale deploy defectdojo-postgresql --replicas=1
oc -n defectdojo wait --for=condition=Available deploy/defectdojo-postgresql --timeout=180s
oc -n defectdojo exec -i deploy/defectdojo-postgresql -- psql -U postgres \
  < /srv/mw2-backup/defectdojo-postgresql.sql
oc -n defectdojo scale statefulset defectdojo-valkey --replicas=1
oc -n defectdojo scale deploy defectdojo-django defectdojo-celery-beat \
  defectdojo-celery-worker --replicas=1

curl -sk https://defectdojo.208.haist.farm/  # HTTP 200
```

**Estimated time: 20 min.**

### Total MW2 wall-clock estimate

Sequenced with 30-min buffer between phases: **~5 hours**, including the
pre-flight check (§5) and post-MW2 validation pass.

### Sources cited in §3

- ClickHouse cold backup: `https://clickhouse.com/docs/en/operations/backup#duplicating-data-with-rsync`
- `pg_dumpall` then `psql -U postgres -f` restore pattern: postgres docs
  `https://www.postgresql.org/docs/current/backup-dump.html#BACKUP-DUMP-ALL`
- democratic-csi static-PV provisioning: chart `values.yaml`
  `https://github.com/democratic-csi/charts/blob/master/stable/democratic-csi/values.yaml`

---

## 4. Order of migration (dependency-aware)

The operator framing notes Vault, Forgejo, Keycloak as the trust roots; in
this cluster only **`keycloak`** has an iSCSI PVC (its local Postgres). Vault
and Forgejo are off-cluster, so they don't appear in MW2 ordering.

Two coupling concerns inside the cluster:

1. **Keycloak is the OIDC trust root** for `harbor`, `plane`, `langfuse`,
   `matrix`, `netbox`, `defectdojo`, ArgoCD console — basically everything
   user-facing. If Keycloak is broken, the *applications* still run, but
   logins via OIDC fail. Migrate Keycloak first so it has the longest
   stabilization window before anything else needs it.
2. **Harbor is the workload-image registry.** Pods that scale back up need to
   pull images. If Harbor is migrating and a workload is stuck restarting,
   that workload's pod will fail `ContainerCreating`. Migrate Harbor early so
   image pulls work for the rest of the migration. (This is the death-spiral
   pattern from RESEARCH-air-gapped-fail-secure.md §4 — not full mitigation
   yet, but ordering reduces the blast radius during MW2 itself.)

### Recommended order

| Phase | Workload | Rationale |
|---|---|---|
| 1 | `keycloak/postgresql` | OIDC trust root; smallest data (~69 MB); validate first |
| 2 | `harbor/harbor-database` | Image registry for the rest of MW2 |
| 3 | `langfuse/langfuse-postgresql` | Less critical; warm up the recipe before the bigger moves |
| 4 | `langfuse/langfuse-clickhouse` | Most fragile recipe (cold tar) — do while operator is fresh |
| 5 | `matrix/matrix-postgresql` | Independent |
| 6 | `netbox/netbox-postgresql` | Independent (depends on Vault for some integrations, but Vault is off-cluster) |
| 7 | `defectdojo/defectdojo-postgresql` | Independent |
| 8 | `plane/plane-postgresql` | Most-used internally; do last so the operator has the longest debug window |

After phase 8, run a cluster-wide validation pass (§5 includes the suite).

---

## 5. Pre-flight check (sandbox PVC) — must pass before MW2 starts

The pre-flight has two stages: install the driver in a sandbox namespace, and
verify static-PV migration works end-to-end on a representative volume.

### 5.1 Driver install (in a sandbox namespace, separate from MW2 day)

```bash
# Helm chart from democratic-csi/charts. Set values per cluster:
helm repo add democratic-csi https://democratic-csi.github.io/charts/
helm repo update
helm upgrade --install zfs-iscsi democratic-csi/democratic-csi \
  --namespace democratic-csi --create-namespace \
  -f values-truenas.yaml
```

`values-truenas.yaml` essentials:

```yaml
csiDriver:
  name: org.democratic-csi.iscsi
storageClasses:
  - name: truenas-iscsi-csi
    defaultClass: false
    reclaimPolicy: Retain
    volumeBindingMode: Immediate
    allowVolumeExpansion: true
    parameters:
      fsType: xfs
driver:
  config:
    driver: freenas-api-iscsi
    instance_id: okd
    httpConnection:
      protocol: https
      host: 192.168.12.205
      port: 443
      apiKey: ${TRUENAS_API_KEY}   # injected from Vault via external-secrets
      allowInsecure: true
    zfs:
      datasetParentName: tank/k8s/iscsi
      detachedSnapshotsDatasetParentName: tank/k8s/iscsi-snapshots
    iscsi:
      targetPortal: "192.168.12.205:3260"
      targetPortals: []
      interface: ""
      namePrefix: csi-
      nameSuffix: ""
      targetGroups:
        - targetGroupPortalGroup: 1
          targetGroupInitiatorGroup: 1
          targetGroupAuthType: None
          targetGroupAuthGroup:
      extentInsecureTpc: true
      extentXenCompat: false
      extentDisablePhysicalBlocksize: true
      extentBlocksize: 512
      extentRpm: SSD
      extentAvailThreshold: 0
```

Note: replace `${TRUENAS_API_KEY}` via external-secrets pulling from
`secret/data/okd/democratic-csi/truenas-api-key` in Vault — never inline it.

### 5.2 Sandbox PVC validation

```bash
# Create a 1Gi PVC, mount it in a busybox, write/read, snapshot, restore.
oc new-project csi-sandbox

cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: sandbox-pvc, namespace: csi-sandbox }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: truenas-iscsi-csi
  resources: { requests: { storage: 1Gi } }
---
apiVersion: v1
kind: Pod
metadata: { name: sandbox, namespace: csi-sandbox }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: registry.access.redhat.com/ubi9/ubi-minimal
      command: ["sh","-c","echo hello-csi > /data/marker && sleep 3600"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: sandbox-pvc }
EOF

# Verify everything works
oc -n csi-sandbox wait --for=condition=Ready pod/sandbox --timeout=120s
oc -n csi-sandbox exec sandbox -- cat /data/marker     # = "hello-csi"

# Verify on TrueNAS UI: a new zvol under tank/k8s/iscsi/csi-* exists
# Verify on the master node: iscsiadm session shows the new IQN
ssh -i ~/.ssh/okd_key core@10.0.0.221 sudo iscsiadm -m session

# Cleanup
oc delete project csi-sandbox
```

### 5.3 Pre-flight pass criteria

All must be true before MW2 starts:

- [ ] PVC binds within 30s.
- [ ] Pod mounts and writes successfully.
- [ ] Marker file readable after pod restart.
- [ ] zvol visible on TrueNAS under the configured parent dataset.
- [ ] iSCSI session visible on the master that scheduled the pod.
- [ ] `oc delete pvc sandbox-pvc` cleanly releases (and, with a separate PVC
      that uses `reclaimPolicy: Delete`, deletes) the zvol on TrueNAS.
- [ ] Driver pods restart cleanly under load (`oc -n democratic-csi delete pod
      -l app.kubernetes.io/name=democratic-csi-controller`; volumes still
      attached).

### Sources cited in §5

- democratic-csi installation guide:
  `https://github.com/democratic-csi/democratic-csi#freenas-iscsi`
- democratic-csi `values.yaml`:
  `https://github.com/democratic-csi/charts/blob/master/stable/democratic-csi/values.yaml`
- TrueNAS API auth:
  `https://www.truenas.com/docs/scale/scaletutorials/toptoolbar/managingapikeys/`

---

## 6. Per-workload rollback

The general rollback is short because the in-tree iSCSI PV is on `Retain` and
the LUN on TrueNAS is untouched until the operator explicitly deletes it.

### 6.1 Restore failure (psql / tar load errors)

```bash
# Truncate and retry
oc -n <ns> scale deploy <pg> --replicas=0
oc -n <ns> delete pvc <data-pvc>
# Recreate fresh CSI PVC (same YAML as before)
oc -n <ns> apply -f new-pvc.yaml
oc -n <ns> scale deploy <pg> --replicas=1
oc -n <ns> exec -i deploy/<pg> -- psql -U postgres < /srv/mw2-backup/<dump>
```

If a second restore attempt fails, the dump is suspect. **Do not delete the
old in-tree PV.** Skip to 6.2.

### 6.2 Restore failure twice → roll back to in-tree PV

```bash
# Drop the new CSI PVC
oc -n <ns> delete pvc <data-pvc>

# Re-bind the original in-tree PV to a new PVC of the same name
# (PV is in Released state with Retain. Patch out claimRef so it's Available.)
oc patch pv <pv-name> --type=merge -p '{"spec":{"claimRef":null}}'

# Recreate the original PVC manifest (no storageClassName, just the inline
# match)
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: <pvc>, namespace: <ns> }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 15Gi } }
  volumeName: <pv-name>
EOF

# Scale workload back up; data is the pre-MW2 state
oc -n <ns> scale deploy <pg> --replicas=1
```

### 6.3 democratic-csi driver itself fails mid-MW2

If the controller pod crashloops:

1. Stop further MW2 phases.
2. Roll back the workloads already migrated using 6.2 (their original
   in-tree PVs and LUNs are still intact on TrueNAS because we kept reclaim
   policy `Retain` and never deleted the LUN).
3. File a separate OPS issue against the driver install. Re-attempt MW2 only
   after a clean pre-flight (§5) on the next maintenance window.

### 6.4 Cleanup of old in-tree PVs (do NOT do during MW2)

The eight in-tree PVs and their TrueNAS LUNs stay around until the operator
explicitly approves cleanup, which should happen **only after a full week of
the migrated workloads running cleanly**. Cleanup steps (separate runbook):

```bash
# For each migrated workload
oc delete pv <pv-name>
# On TrueNAS: delete the iSCSI extent + zvol
# Suggested: keep a TrueNAS snapshot of the pre-MW2 zvol for 30 days
```

---

## 7. Disk space sizing and backup destination

### 7.1 Total backup volume needed

| Workload | Live data (du) | Dump format | Dump size estimate |
|---|---|---|---|
| harbor-postgresql | 424 MB | pg_dumpall (compressed text) | ~250 MB |
| plane-postgresql | 408 MB | pg_dumpall | ~250 MB |
| defectdojo-postgresql | 337 MB | pg_dumpall | ~200 MB |
| matrix-postgresql | 85 MB | pg_dumpall | ~50 MB |
| netbox-postgresql | 82 MB | pg_dumpall | ~50 MB |
| keycloak postgresql | 69 MB | pg_dumpall | ~40 MB |
| langfuse-postgresql | 67 MB | pg_dumpall | ~40 MB |
| langfuse-clickhouse | unknown (PVC=15 Gi) | tar.gz cold copy | reserve 15 Gi |

**Total reserved: 20 GiB.** The Postgres dumps total well under 1 GB — the
ClickHouse reservation dominates.

### 7.2 Where backups go

The cluster already has an NFS-backed PVC `langfuse/langfuse-ch-backup`
(200 GiB, RWX, manual-nfs PV) that is in use as a TrueNAS NFS share. We have
two options:

**Option A (recommended): a dedicated MW2 backup NFS dataset on TrueNAS.**

- TrueNAS UI → *Datasets* → create `tank/mw2-backup` (50 GiB quota).
- Share via NFS, allow `192.168.12.0/24` and the OKD nodes' IPs.
- Mount on iac-control: `mount -t nfs 192.168.12.205:/mnt/tank/mw2-backup
  /srv/mw2-backup`.
- ZFS snapshots before each per-workload restore (so a second-attempt restore
  doesn't lose the dump).

**Option B: reuse `langfuse/langfuse-ch-backup`.** Lazy but adequate. PVC
already exists. Downsides: it's tagged for langfuse, not generic, and the
naming would be misleading. Use only if creating a new dataset is blocked.

**Choose Option A.** 50 GiB quota is generous (3× the reserved 20 GiB) so
ZFS snapshots have room.

### 7.3 TrueNAS capacity

Operator should verify before MW2:

```
ssh root@192.168.12.205 zpool list -o name,size,allocated,free,fragmentation
ssh root@192.168.12.205 zfs list tank
```

A 50 GiB allocation on a `tank` pool sized in TiB is non-issue capacity-wise.
The check is more about confirming the pool is healthy (`zpool status -v`)
before MW2.

### Sources cited in §7

- TrueNAS NFS share docs:
  `https://www.truenas.com/docs/scale/scaletutorials/shares/nfs/`

---

## 8. Risks specific to our setup

### 8.1 Vault auto-unseal — verify path before MW2

Vault is **off-cluster** — it is not in the iSCSI PVC inventory above. The
auto-unseal mechanism for Vault is operator-side concern, not MW2's. **However,**
the runbook should NOT touch any cluster workloads that hold Vault transit
keys until the operator confirms Vault is healthy, because some workloads
(notably ones using `external-secrets`) re-read Vault on pod restart. If Vault
is wedged for unrelated reasons during MW2, those workloads will not come back
cleanly even on the new CSI PV.

**Pre-MW2 check:**
```bash
curl -sk https://vault.208.haist.farm/v1/sys/seal-status | jq .sealed   # = false
```

Confirm the Vault transit key used for auto-unseal is itself NOT on iSCSI
storage (it shouldn't be — Vault is off-cluster — but verify the off-cluster
Vault host's storage is not iSCSI to the same TrueNAS).

### 8.2 Wazuh agent enrolment — N/A on cluster

Wazuh has no PVC in the cluster inventory. Wazuh agents on OKD nodes report
to an off-cluster Wazuh manager. No MW2 impact, but flag for separate
verification: agent reports continue post-MW2 (`/var/ossec/logs/ossec.log`
on each master).

### 8.3 Plane MinIO sidecar — already on NFS, no impact

`plane-minio-wl-0` uses `pvc-plane-minio-vol-plane-minio-wl-0` on
`nfs-storage`, NOT iSCSI. It is unaffected by MW2. Plane's persistent state
that does ride iSCSI is only the Postgres (`plane-pg-iscsi`).

### 8.4 OpenShift image registry NOT on iSCSI

`openshift-image-registry/image-registry-storage` is on `nfs-storage`. Out
of scope — but confirm it stays healthy through MW2 (it will: nothing changes
for it).

### 8.5 OKD upgrade ordering

The sibling research (RESEARCH-okd-upgrade.md §3, §6) flags in-tree iSCSI
plugin removal as the highest-uncertainty item for the 4.19 → 4.20 hop.
**OPS-151 is the prerequisite for that upgrade.** Do not begin a 4.20
upgrade with any in-tree iSCSI PVCs still in use.

### 8.6 Argo CD will fight the manual changes

All eight migrated PVCs are tracked by Argo CD applications (visible from
the `argocd.argoproj.io/tracking-id` annotations on the in-tree PVs). Before
MW2 begins:

```bash
for app in defectdojo harbor keycloak langfuse matrix netbox plane; do
  argocd app set $app --sync-policy=none
done
```

After MW2, update the source manifests in Forgejo to reflect the new
`storageClassName: truenas-iscsi-csi` and removal of the static iSCSI PV
manifests, then re-enable auto-sync. **The post-MW2 manifest update is itself
a tracked OPS issue (separate from OPS-151).**

### 8.7 Kyverno admission and image signature verification

Independent of OPS-151 but could bite during MW2: when Harbor is at scale=0,
any pod restart that needs to *pull* a Harbor image will be denied by the
Kyverno `verify-image-signatures` ClusterPolicy if the policy still
fail-closes against an unreachable Harbor (this is exactly the death-spiral
the 2026-04-27 incident exposed).

**Mitigation for MW2:** check what's already cached on each master before
phase 2 (Harbor migration):

```bash
ssh -i ~/.ssh/okd_key core@10.0.0.221 \
  sudo crictl images | grep harbor.208.haist.farm
# Confirm at least the Harbor pod images are cached locally on every master
```

If a node lacks a cached image, force-schedule a pod that pulls it before
MW2, OR (preferred medium-term) implement the off-cluster mirror-registry
fallback from RESEARCH-air-gapped-fail-secure.md §3 *before* MW2.

### 8.8 Static iSCSI PVs do not have CSI snapshots

The in-tree iSCSI inline-volume PVs cannot be CSI-snapshotted (the CSI
snapshot machinery only works on CSI-provisioned PVs). For MW2, "snapshot"
means a TrueNAS-side ZFS snapshot of the LUN's underlying zvol, taken via
TrueNAS UI or `zfs snapshot tank/<lun>@pre-mw2-2026-04-27`. Take one for each
of the eight LUNs immediately before MW2 begins. Retain for 30 days.

```bash
# On TrueNAS as root
for lun in defectdojo-pg harbor-pg keycloak-pg langfuse-ch langfuse-pg \
           matrix-pg netbox-pg plane-pg; do
  zfs snapshot tank/iscsi/okd-${lun}@pre-mw2-2026-04-27
done
```

(Adjust `tank/iscsi/okd-*` to the actual zvol path — verify with
`zfs list -t volume` first.)

---

## Appendix A: source citations consolidated

- democratic-csi GitHub README and chart:
  `https://github.com/democratic-csi/democratic-csi`,
  `https://github.com/democratic-csi/charts/tree/master/stable/democratic-csi`,
  `https://github.com/democratic-csi/charts/blob/master/stable/democratic-csi/values.yaml`
- democratic-csi static-PV migration discussion:
  `https://github.com/democratic-csi/democratic-csi/issues/233`
- OKD 4.19 CSI overview:
  `https://docs.okd.io/4.19/storage/container_storage_interface/persistent-storage-csi.html`
- OCP storage / CSI migration:
  `https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/storage/using-container-storage-interface-csi`
- OKD CSI migration tracker (release-notes section in 4.20/4.21 release notes):
  `https://okd.io/blog/2025/09/30/okd-4.20-release-notes/`,
  `https://okd.io/blog/2026/01/26/okd-4.21-release-notes/`
- Postgres `pg_dumpall` and restore:
  `https://www.postgresql.org/docs/current/app-pg-dumpall.html`,
  `https://www.postgresql.org/docs/current/backup-dump.html`
- ClickHouse cold-copy backup pattern:
  `https://clickhouse.com/docs/en/operations/backup`
- TrueNAS API key management:
  `https://www.truenas.com/docs/scale/scaletutorials/toptoolbar/managingapikeys/`
- TrueNAS NFS share docs:
  `https://www.truenas.com/docs/scale/scaletutorials/shares/nfs/`
- Sibling research: RESEARCH-okd-upgrade.md §3, §6
  (recovery-ledger/2026-04-27-power-incident/)
- Sibling research: RESEARCH-air-gapped-fail-secure.md §3, §4
  (recovery-ledger/2026-04-27-power-incident/)
- Power-incident PLAN: PLAN.md §CORRECTION
  (recovery-ledger/2026-04-27-power-incident/) — the failure mode that motivated MW2

## Appendix B: things this runbook deliberately does NOT cover

- Live migration. Not in scope (operator framing: scaled-to-zero pattern).
- NFS-backed PVCs. They use a dynamic provisioner already and are not part
  of the iSCSI deprecation risk. Separate decision.
- Vault, Forgejo, Wazuh. Off-cluster. Not in PVC inventory.
- Off-cluster mirror-registry standup. Tracked separately (see
  RESEARCH-air-gapped-fail-secure.md §6a).
- Kyverno → ClusterImagePolicy migration. Tracked separately (see
  RESEARCH-air-gapped-fail-secure.md §6b).
- Manifest updates in Forgejo to remove the static iSCSI PV YAMLs. Will be a
  follow-up OPS issue once MW2 completes successfully.
