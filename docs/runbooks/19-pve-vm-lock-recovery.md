# Runbook 19 — PVE VM Stale Lock Recovery

**Issue:** OPS-732
**Criticality:** Medium — VM operations blocked until lock cleared; running VMs are unaffected
**Host:** PVE node (typically `pve4`, 192.168.12.4) via SSH as `root`

---

## What this is

When a Proxmox VE snapshot-delete operation is interrupted (most commonly by storage pressure —
thin pool fill, iSCSI timeout, or LMDB GC stall), the VM config is left with a stale
`lock: snapshot-delete` flag. The VM continues running normally; only PVE management
operations (new snapshots, config changes, migrations) are blocked until the lock is cleared.

**This is a PVE config-layer artefact, not a VM crash.**

---

## Symptom

`qm status <vmid>` shows a lock field alongside `status: running`:

```
status: running
lock: snapshot-delete
```

Or from the shell loop (see §1), a VM appears in the locked column while its qemu process
is healthy.

The automated snapshot script logs this fingerprint when the delete timeout fires:

```
ERROR: Delete of <snapname> timed out or failed for VM <vmid>
RECOVERY: ssh root@<node> 'qm unlock <vmid>' to clear any stale lock (OPS-732)
```

Check the snapshot log on iac-control:

```bash
grep -E 'ERROR|RECOVERY|lock' /var/log/proxmox-snapshot.log | tail -40
```

---

## Critical constraint

**PVE API tokens with `privsep=1` cannot clear locks.** The platform's API token
(`root@pam!Claudette`, privsep=1) returns HTTP 500 on `PUT /qemu/{vmid}/config?delete=lock`.
`qm unlock` has **no REST API equivalent**. You must SSH to the PVE host CLI as `root`.

---

## 1. Find all locked VMs

SSH to the PVE node (`ssh root@pve4`):

```bash
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
  lock=$(qm status "$vmid" 2>/dev/null | awk -F': ' '/^lock/{print $2}')
  [ -n "$lock" ] && echo "LOCKED  vmid=$vmid  lock=$lock"
done
```

Or via the PVE config directory directly:

```bash
grep -rH '^lock:' /etc/pve/qemu-server/
```

Each line like `/etc/pve/qemu-server/200.conf:lock: snapshot-delete` identifies a locked VM.

---

## 2. Verify the lock is stale (not an active operation)

Before unlocking, confirm:

### 2a. The VM is running (not mid-operation)

```bash
qm status <vmid>
```

Expected: `status: running` with a non-zero uptime. If status is `stopped` or
`paused`, the lock may be from an in-progress restore/clone — do **not** unlock
without confirming no active task (see §2b).

### 2b. No active PVE task is running for this VM

```bash
# List running tasks on the node
pvesh get /nodes/pve4/tasks --running true --vmid <vmid> 2>/dev/null \
  | python3 -m json.tool | grep -E 'starttime|type|status'
```

If any task shows `type: vzdump`, `type: qmclone`, or `type: qmdelsnapshot` with
`status: running` — **stop here**. The lock is legitimate; wait for the task to finish
or investigate why it is hung before unlocking.

If the task list is empty (or all tasks are stopped/OK), the lock is stale. Proceed.

### 2c. Check the snapshot was actually removed

```bash
qm listsnapshot <vmid>
```

If the snapshot that was being deleted still appears, the delete did not complete.
After unlocking, re-trigger the delete:

```bash
qm delsnapshot <vmid> <snapname>
```

---

## 3. Clear the stale lock

```bash
qm unlock <vmid>
```

Expected output: silent (no output = success). The command exits 0.

---

## 4. Verify recovery

```bash
# Lock field should be absent
qm status <vmid>
```

Expected:

```
status: running
```

No `lock:` line = recovered. If the lock field still appears, re-check for an active
task (§2b) — a concurrent process may be re-acquiring it.

### 4a. Confirm VM operations unblocked

```bash
# A no-op config touch should succeed without "VM is locked" error
qm config <vmid> | head -5
```

---

## 5. Post-recovery — check all VMs

After a storage-pressure event, multiple VMs may be locked. Run the full sweep:

```bash
for vmid in $(qm list | awk 'NR>1 {print $1}'); do
  status_out=$(qm status "$vmid" 2>/dev/null)
  lock=$(echo "$status_out" | awk -F': ' '/^lock/{print $2}')
  if [ -n "$lock" ]; then
    echo "vmid=$vmid  lock=$lock  $(echo "$status_out" | awk -F': ' '/^status/{print "status="$2}')"
  fi
done
```

Unlock each one that passes the §2a/2b checks. Log the VMID and lock type in the
relevant Plane issue comment for the audit trail.

---

## Root cause context (OPS-732 discovery)

- **Date:** 2026-05 — Session-020 storage-recovery work (lvremove to reclaim LVM thin pool)
- **Affected VM:** VMID 200 (iac-control, 192.168.12.210)
- **Mechanism:** Thin pool filled to 100% during a CoW/LMDB GC pass triggered by the
  snapshot-delete task. Proxmox UPID task stalled; the snapshot-delete task exceeded the
  300s `wait_for_task` timeout in the automated snapshot script; PVE left the lock in
  `/etc/pve/qemu-server/200.conf` without clearing it.
- **Detection:** `qm status 200` showed `lock: snapshot-delete` while the VM was running
  normally with 100% availability.
- **Resolution:** `qm unlock 200` on the PVE host CLI. No VM disruption.

### IaC fix applied (PR #271, merged 2026-05-18)

`ansible/roles/iac-control/templates/proxmox-snapshot.sh.j2` was updated:

- `wait_for_task()` now accepts an optional `$3 timeout_seconds` parameter (default 300s,
  backward-compatible).
- Snapshot-delete calls use 600s timeout (2× the create timeout) to accommodate CoW GC
  under moderate storage pressure.
- On timeout, the script logs `RECOVERY: ssh root@${node} 'qm unlock ${vmid}'` and
  increments `failure_count` so systemd surfaces the failure.

---

## Related runbooks

| Runbook | When to use |
|---------|-------------|
| [07-postgresql-crash-recovery.md](07-postgresql-crash-recovery.md) | Storage pressure causing iSCSI/PVC failures |
| [04-service-recovery-order.md](04-service-recovery-order.md) | Full platform recovery after major outage |
| [08-break-glass.md](08-break-glass.md) | Emergency access when normal SSH paths unavailable |
