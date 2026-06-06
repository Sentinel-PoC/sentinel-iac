# Runbook 10 — sentinel-agent Maintenance Lock

**Purpose:** Halt sentinel-agent automated remediations during operator hands-on work so the agent does not interfere with manual recovery.

**Issue:** OPS-233
**Implemented:** 2026-04-19
**Lock file:** `/var/run/sentinel-agent.halt` (symlink to `/run/sentinel-agent.halt`, tmpfs)

---

## When to use this

Set the maintenance lock before doing any of the following on iac-control or the OKD cluster:

- Manual `kubectl` applies, rollouts, or scale operations
- `ansible-playbook` convergence runs
- iSCSI / storage layer recovery (LUN resize, zvol expansion)
- Vault token/policy changes
- Forgejo / ArgoCD configuration changes
- Any action where a concurrent `kubectl rollout restart` or ArgoCD sync would make things worse

---

## Setting the lock

### Minimal (no metadata)

```bash
sudo touch /var/run/sentinel-agent.halt
```

### With metadata (recommended — appears in audit trail)

```bash
sudo bash -c 'echo "{\"by\":\"jim\",\"reason\":\"iSCSI recovery\",\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > /var/run/sentinel-agent.halt'
```

The agent logs the `by`, `reason`, and `at` fields on every cycle while the lock is held.

---

## Verifying the lock is active

Check journald — the agent runs every 5 minutes:

```bash
journalctl -u sentinel-agent.service -n 20 --no-pager | grep -i "maintenance lock"
```

Expected output when locked:

```
MAINTENANCE LOCK ACTIVE — skipping cycle. Lock file: /var/run/sentinel-agent.halt metadata={...}
```

Or check that the agent service exits 0 without emitting any "Polling input sources" line:

```bash
journalctl -u sentinel-agent.service -n 5 --no-pager
```

---

## Releasing the lock

```bash
sudo rm /var/run/sentinel-agent.halt
```

The next timer fire (within 5 minutes) resumes normal operation.

---

## Automatic expiry

`/var/run` (`/run`) is **tmpfs** on all systemd hosts. The lock file disappears automatically on host reboot. You do **not** need to remember to remove it after a reboot-based recovery.

If you want a time-based expiry without rebooting, the `maintenance-expire.timer` already deployed on iac-control can remove the file after N hours. Check `systemctl status maintenance-expire.timer` for its configuration.

---

## What the agent does when locked

1. Starts normally (reads config, sets up logging).
2. Checks for `/var/run/sentinel-agent.halt`.
3. If present: logs `MAINTENANCE LOCK ACTIVE`, emits a `maintenance_lock_active` research event (appears in `research-log.jsonl`), exits 0.
4. Does **not** poll Plane, Wazuh, or ArgoCD.
5. Does **not** authenticate to Vault.
6. Does **not** execute any Tier 2 or Tier 3 remediations.

The systemd timer fires again in 5 minutes regardless — each cycle performs the lock check again.

---

## Audit trail

Every cycle while locked emits an event to `/var/log/sentinel-agent/research-log.jsonl`:

```json
{"timestamp":"...","event_type":"maintenance_lock_active","source":"sentinel-agent","data":{"lock_file":"/var/run/sentinel-agent.halt","metadata":{"by":"jim","reason":"iSCSI recovery","at":"..."}},"narrative":"Operator maintenance lock active — cycle skipped"}
```

This means the duration of every maintenance window is recorded in the research log automatically.

---

## Troubleshooting

**Agent is not respecting the lock:**
- Confirm the file exists: `ls -la /var/run/sentinel-agent.halt`
- Confirm systemd can read it: `sudo -u sentinel-agent cat /var/run/sentinel-agent.halt`
- Confirm the deployed code is current: `grep -n "is_locked" /opt/sentinel-agent/agent.py`

**Lock file disappeared unexpectedly:**
- The host may have rebooted (tmpfs is cleared on reboot — this is expected behaviour).
- Re-create the lock if work is still ongoing.

**Agent exits 1 while lock is set:**
- A different error occurred before the lock check. Check journald: `journalctl -u sentinel-agent.service -n 50 --no-pager`
