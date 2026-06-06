# TrueNAS Upgrade + iSCSI Cascade Incident — 2026-05-25

**Act-Chain: human=jim orchestrator=team-lead-2026-05-25 executing=worker-948-truenas-upgrade action=create resource=sentinel-iac/docs/incidents/2026-05-25-truenas-upgrade-iscsi-cascade.md**

**Issue:** OPS-948  
**Agent:** worker-948-truenas-upgrade  
**Date:** 2026-05-25  
**Maintenance Window:** Operator-authorized 2026-05-25T19:15Z

---

## Upgrade Summary

| Property | Before | After |
|----------|--------|-------|
| Version | TrueNAS-25.10.1 | TrueNAS-25.10.3.1 |
| Train | TrueNAS-SCALE-Goldeye | TrueNAS-SCALE-Goldeye |
| Downtime | — | 3 min 8 sec (19:12:31Z → 19:15:39Z) |
| Boot env | 25.10.1 (active) | 25.10.3.1 (active), 25.10.1 (preserved) |
| Upgrade reason | — | CVE-2026-31431 (CVSS 7.8) kernel AEAD patch |

---

## Pre-flight Checklist

- PASS: DATA pool ONLINE, healthy, scrub May 24, 0 errors
- PASS: BACKUP pool ONLINE, healthy, scrub May 24, 0 errors
- PASS: SSD pool ONLINE, healthy, scrub Apr 26, 0 errors
- PASS: No active scrub or resilver
- PASS: 0 replication tasks / 0 cloud sync tasks
- PASS: Snapshots current (DATA@auto-20260525-1200-6h, ~7h old)
- PASS: Update pre-staged 100% (1.72 GiB)
- PASS: Release notes reviewed — no breaking changes for iSCSI/NFS/ZFS workload
- INFO: iSCSI portal config DB = 192.168.12.205:3260 (OPS-946 fix in DB, deferred state)

---

## Execution

- Job 99310 (update.run): 19:05:42Z start → 19:12:06Z SUCCESS
  - Stages: verify → extract (52→76%) → config DB migration → autotune → initramfs → grub
- Job 99324 (system.reboot): triggered 19:12:21Z
- TrueNAS API restored: 19:15:39Z
- **Actual downtime: 3 minutes 8 seconds**

---

## Post-Reboot: Non-OKD Fleet (auto-recovered)

| Consumer | Type | Status |
|----------|------|--------|
| MinIO LXC 301 (192.168.12.58) | iSCSI /dev/sda (xfs) | auto-reconnected |
| MinIO LXC 302 (192.168.12.59) | local disk (no iSCSI) | unaffected |
| Seedbox VM 109 (192.168.12.69) | NFS NFSv4.2 | auto-reconnected |

---

## Post-Reboot: OKD iSCSI Cascade (required manual recovery)

### Initial State After Reboot

OKD pods using iSCSI PVCs had moved nodes during TrueNAS downtime (kubelet eviction). When TrueNAS came back online, the OKD in-tree iSCSI plugin left stale state:

- harbor-database: ContainerCreating -- harbor-pg-iscsi stuck on master-2 (Multi-Attach)
- matrix-postgresql: ContainerCreating -- matrix-pg-iscsi stuck on master-2 (Multi-Attach)
- backstage-postgresql: ContainerCreating -- backstage-pg-iscsi stuck mount on master-1
- plane-postgresql: no pod -- Kyverno blocking (Harbor was down, cannot verify images)

### Root Cause Analysis

Three compounding layers:

1. **iscsid auto-reconnect**: After initial iSCSI logout attempt, iscsid on master-2 reconnected sessions for harbor-pg, matrix-pg, plane-pg automatically (node.startup=automatic default). Sessions [9],[10],[11] re-established.

2. **Stuck XFS mounts**: Kubelet on master-2 had mounted harbor-pg to /dev/sdf, matrix-pg to /dev/sdh, plane-pg to /dev/sdi at plugin state directories. After iSCSI logout, block devices disappeared but XFS mounts remained registered in the kernel. stat() on mount points returned Input/output error. The plugin state directories showed d?????????? in ls output.

3. **Kyverno circular dependency**: Harbor registry was down (harbor-database stuck) -> Kyverno could not verify images from harbor.208.haist.farm -> Kyverno blocked plane-postgresql pod creation -> plane-postgresql could not start -> Plane API returned HTTP 500.

### Recovery Sequence

| Step | Action | Result |
|------|--------|--------|
| 1 | Patched stale volumesAttached from master-2 (harbor-pg, matrix-pg, plane-pg) | API server state clean |
| 2 | Patched stale volumesAttached from master-1 (backstage-pg) | API server state clean |
| 3 | Privileged pod on master-2: set node.startup=manual + logout + node-delete for harbor/matrix/plane-pg | Sessions cleared, auto-reconnect disabled |
| 4 | Lazy unmount stuck XFS filesystems on master-2 (umount -l for /dev/sdf,sdh,sdi plugin dirs) | /proc/mounts clear |
| 5 | Restarted kubelet on master-2 via privileged pod | volumesInUse cleared for harbor/matrix/plane |
| 6 | Removed orphaned kubelet plugin state dir for backstage-pg on master-1 (stuck mount /dev/sdd) | mkdir error cleared |
| 7 | Deleted and recreated stuck harbor-database and backstage-postgresql pods | Fresh ADC attachment cycle |

### Recovery Cascade

kubelet restart (step 5):
  -> master-2 volumesInUse clears for harbor-pg, matrix-pg, plane-pg
  -> ADC confirms attachment to master-1 for harbor-pg + matrix-pg
  -> harbor-database Running -- Harbor registry up
  -> Kyverno unblocked
  -> plane-postgresql pod admitted and Running
  -> Plane API HTTP 200
  -> matrix-postgresql Running
  -> backstage-postgresql Running (after plugin dir cleanup)

---

## OPS-946 Finding

Goal: Restrict iSCSI daemon to bind on 192.168.12.205 only.
Finding: Goal NOT achieved. TrueNAS starts iscsi-scstd as /sbin/iscsi-scstd -p 3260 with no -a <address> flag. The portal IP in config DB is advertisement-only, not a daemon bind address. Daemon always binds 0.0.0.0:3260.

Post-upgrade daemon state: 0.0.0.0:3260 (unchanged through upgrade).

See OPS-946 CORRECTION comment for remediation options.

---

## Final Fleet State (post-recovery, 2026-05-25T20:45Z)

| Component | Status |
|-----------|--------|
| TrueNAS 25.10.3.1 | Running |
| DATA/BACKUP/SSD pools | ONLINE, healthy |
| OKD nodes 3/3 | Ready |
| harbor-database | 1/1 Running (master-1) |
| matrix-postgresql | 1/1 Running (master-1) |
| plane-postgresql | 1/1 Running |
| backstage-postgresql | 1/1 Running (master-1) |
| Plane API | HTTP 200 |
| MinIO LXC 301 | iSCSI healthy |
| MinIO LXC 302 | local disk healthy |
| Seedbox NFS | mounted |

Pre-existing (NOT caused by upgrade), tracked in OPS-949:
- defectdojo-postgresql: CreateContainerError on master-3 since 2026-05-23
- langfuse-clickhouse: CreateContainerError on master-3 since 2026-05-23
- promtail DaemonSet: CrashLoopBackOff since 4d6h (pre-existing)

---

## Lessons Learned

1. **iscsid auto-reconnect**: After iscsiadm --logout, iscsid reconnects if node.startup=automatic (the default). Must --op delete the node record or set node.startup=manual before logout to prevent reconnect.

2. **Stuck mounts after logout**: When iSCSI session logs out while a filesystem is mounted at the plugin stage dir, the kernel mount entry survives with a dead device. umount -l (lazy) is the only reliable cleanup method.

3. **Kyverno-Harbor circular dependency**: Any OKD workload using Harbor-hosted images is blocked by Kyverno if Harbor's database is down. This creates a chicken-and-egg situation for plane-postgresql. Harbor must recover first.

4. **ADC vs kubelet state divergence**: Patching node.status.volumesAttached via the API server does NOT immediately update the ADC's in-memory actualStateOfWorld. The kubelet's volumesInUse state can lag behind physical state by minutes. Kubelet restart is the reliable clearing mechanism.

5. **Recovery order for OKD iSCSI cascade**: clean iSCSI sessions (with --op delete) -> lazy unmount stuck filesystems -> restart kubelet -> let ADC re-attach -> pods recover.

---

*Report generated by worker-948-truenas-upgrade, 2026-05-25T20:50Z*
*Act-Chain: human=jim orchestrator=team-lead-2026-05-25 executing=worker-948-truenas-upgrade action=create resource=sentinel-iac/docs/incidents/2026-05-25-truenas-upgrade-iscsi-cascade.md*
