# Runbook 09 — sentinel-agent Tier 2 Change-Freeze

**Relates to:** OPS-234
**Criticality:** Medium
**Audience:** Platform operator

---

## What is the change-freeze?

`sentinel-agent` runs a 5-minute remediation loop. Tier 2 actions are
**autonomous fixes** — pod restarts, ArgoCD syncs, Vault unseal. If the
operator is simultaneously making manual changes, the agent can collide
with that work (double-restart, overwriting a partially applied fix, etc.).

The change-freeze is an **automatic, passive safety net**: if the operator's
bash history file (`/home/ubuntu/.bash_history`) was modified within the
configured window (default 15 minutes), the agent skips Tier 2 for that
cycle. Tier 1 (observe), Tier 3 (PR proposals), and ESCALATE continue
unaffected.

Unlike the halt lock (OPS-233 / runbook 10), change-freeze requires no
operator action. It activates when the operator is active and clears
automatically when they are idle.

---

## When to use what

| Situation | Mechanism |
|-----------|-----------|
| Operator doing hands-on kubectl/oc/ansible work | Change-freeze (automatic, no action needed) |
| Extended maintenance window — agent must not touch anything | Halt lock (manual: `touch /var/run/sentinel-agent.halt`) |
| Both | Halt lock takes precedence (it halts the full cycle) |

---

## Observability

Every cycle where Tier 2 is frozen emits a research event:

```json
{
  "event_type": "tier2_change_freeze_skip",
  "data": {
    "signal": "<signal summary>",
    "reason": "change_freeze_operator_active",
    "last_activity_at_utc": "2026-04-19T17:45:00+00:00",
    "seconds_ago": 312,
    "window_seconds": 900,
    "source": "bash_history"
  }
}
```

Find these in `/var/log/sentinel-agent/research-log.jsonl`:

```bash
grep 'tier2_change_freeze_skip' /var/log/sentinel-agent/research-log.jsonl | tail -5 | jq .
```

The agent also logs at WARNING level:

```
CHANGE FREEZE — Tier 2 skipped for '<signal>': operator activity 312s ago (window=900s)
```

---

## Configuration

In `/opt/sentinel-agent/config.yaml`:

```yaml
change_freeze:
  change_freeze_seconds: 900   # seconds of inactivity before Tier 2 resumes
  change_freeze_sources:
    - bash_history
```

To lengthen the freeze window (e.g., for longer maintenance without a halt lock):

```bash
# On iac-control
sudo sed -i 's/change_freeze_seconds: 900/change_freeze_seconds: 1800/' \
    /opt/sentinel-agent/config.yaml
```

Restart is not needed — config is read at the start of each 5-minute cycle.

---

## Forcing the freeze to clear early

The freeze clears automatically once the operator stops running commands and
the window elapses. If you need Tier 2 to resume immediately (e.g., you are
done with manual work):

```bash
# On iac-control, update bash_history mtime to a past time so seconds_ago > window
touch -d "31 minutes ago" /home/ubuntu/.bash_history
```

This is safe — it only changes the modification timestamp, not the file content.

---

## If Tier 2 is stuck in freeze unexpectedly

1. Check bash_history mtime:

   ```bash
   stat /home/ubuntu/.bash_history
   ```

2. Calculate seconds since last modify and compare to the configured window.

3. If the timestamp looks wrong (e.g., set to the future by a clock skew), reset it:

   ```bash
   touch -d "now" /home/ubuntu/.bash_history
   ```

4. If the window is too conservative for your workflow, lower `change_freeze_seconds`
   in config.yaml (but do not go below 300 seconds / 5 minutes — shorter than
   one agent cycle is counterproductive).

---

## Interaction with OPS-233 halt lock

| State | Effect |
|-------|--------|
| Halt lock present | Full cycle halts. Change-freeze check never reached. |
| Change-freeze only | Tier 2 skipped. Tier 1/3/ESCALATE run normally. |
| Neither | Full agent cycle runs normally. |
| Both | Halt lock wins (cycle halts before freeze check). |

---

## Detection source limitations

Currently only `bash_history` mtime is checked. This means:

- **False positives:** Any shell command (not just kubectl/oc) updates mtime.
  The freeze is conservative — when in doubt, it pauses.
- **zsh users:** zsh appends history at session end by default. Mtime may not
  reflect real-time activity as accurately as bash. If the operator uses zsh,
  extend `change_freeze_seconds` or use the halt lock for precision.
- **Future:** Vault SSH audit log (JIT cert signing events) can be a second
  source once the AppRole policy grants read access to `sys/audit` or a
  dedicated Vault path. Filed as follow-up in OPS-234 comments.

---

## Files

| File | Purpose |
|------|---------|
| `/opt/sentinel-agent/operator_activity.py` | Detection module |
| `/opt/sentinel-agent/actions/tier2.py` | Wire-in point (top of `execute_tier2()`) |
| `/opt/sentinel-agent/config.yaml` | `change_freeze:` section |
| `/var/log/sentinel-agent/research-log.jsonl` | Audit trail of freeze events |
| `/home/ubuntu/.bash_history` | Detection source (read-only access) |
