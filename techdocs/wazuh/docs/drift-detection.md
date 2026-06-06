# Drift Detection

## Overview

Project Sentinel implements automated configuration drift detection and remediation using a combination of Ansible, systemd timers, and Wazuh alerting. The system detects when managed VM configurations diverge from the Ansible-declared state and automatically remediates during a scheduled window.

```
+------------------+     +-------------------+     +------------------+
| Daily 8:00 UTC   |     | Daily 8:30 UTC    |     | Wazuh Server     |
| Drift Detection  |---->| Auto-Remediation  |---->| Alert Processing |
| (--check --diff) |     | (common role)     |     | Rules 100420+    |
+------------------+     +-------------------+     +------------------+
        |                         |                         |
        v                         v                         v
  Log to file              Apply common role         Matrix / Discord
  + Wazuh alert            if drift detected         notifications
```

## Daily Drift Detection (8:00 UTC)

A systemd timer on iac-control runs Ansible in check mode to detect configuration drift across all managed VMs:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/<vm>.yml --check --diff
```

The `--check` flag performs a dry run (no changes applied). The `--diff` flag shows exactly what would change. Results are logged and forwarded to Wazuh for alerting.

## Auto-Remediation (8:30 UTC)

If drift is detected in the 8:00 check, an auto-remediation timer at 8:30 UTC re-applies the `common` role (CIS hardening baseline) to bring VMs back into compliance:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/<vm>.yml
```

The remediation only applies the `common` role, not service-specific roles, to minimize risk of unintended side effects.

**Important**: The auto-remediation script shebang can get corrupted to `#\!/bin/bash` -- the `file` command shows "ASCII text" instead of "shell script", which causes systemd ExecStart failure (exit code 203/EXEC). Verify with `file` command if the timer fails.

## Maintenance Mode

Maintenance mode prevents automation from interfering during manual work on infrastructure.

### Commands

```bash
# Enter maintenance mode (blocks all automation)
~/scripts/sentinel-maintenance.sh enter --reason "manual patching" --timeout 4h

# Enter maintenance mode (blocks only remediation, detection still runs)
~/scripts/sentinel-maintenance.sh enter --reason "investigating drift" --timeout 2h --scope remediation

# Check status
~/scripts/sentinel-maintenance.sh status

# Exit maintenance mode
~/scripts/sentinel-maintenance.sh exit
```

### Scope Options

| Scope | Detection Timer | Remediation Timer |
|-------|----------------|-------------------|
| `all` | Blocked | Blocked |
| `remediation` | Runs normally | Blocked |

### Timeout

The `--timeout` flag automatically exits maintenance mode after the specified duration. If omitted, maintenance mode persists until manually exited.

## Wazuh Rules for Drift

### Ansible Drift Rules (100420-100428)

The CLAUDE.md references Wazuh rules 100420-100428 for Ansible drift detection, remediation, and maintenance mode events. These rules cover:

| Rule ID | Level | Description |
|---------|-------|-------------|
| 100420 | 3 | Drift check completed -- no changes detected |
| 100421 | 10 | Configuration drift detected on a managed VM |
| 100422 | 5 | Drift remediation started |
| 100423 | 3 | Drift remediation completed successfully |
| 100424 | 7 | Drift remediation failed |
| 100425 | 3 | Maintenance mode entered |
| 100426 | 3 | Maintenance mode exited |
| 100427 | 5 | Drift check skipped (maintenance mode active) |
| 100428 | 5 | Remediation skipped (maintenance mode active) |

[VERIFY] These rules are referenced in CLAUDE.md but are not present in the IaC-managed `local_rules.xml`. They may be deployed directly on the Wazuh server or in a separate rule file.

### Terraform Drift Rules (100430-100433)

Terraform/OpenTofu drift detection is also monitored via Wazuh. The `tofu-drift-check.sh` script runs `tofu plan` and writes JSON events that Wazuh processes:

| Rule ID | Level | Event | Description |
|---------|-------|-------|-------------|
| 100430 | 3 | `TOFU_DRIFT_CHECK_COMPLETE` | No drift detected |
| 100431 | 10 | `TOFU_DRIFT_DETECTED` | Resources changed (MITRE T1578) |
| 100432 | 7 | `TOFU_DRIFT_CHECK_FAILED` | Plan execution error |
| 100433 | 5 | `TOFU_DRIFT_RESOURCES` | Detailed resource change list |

Level 10 drift detection triggers Matrix and Discord notifications.

## What Drift Looks Like in the Dashboard

When drift is detected, you will see alerts in the Wazuh Dashboard with:

- **Rule group**: `drift` or `terraform,drift`
- **Agent**: The agent where drift was detected (typically `iac-control` for Ansible/Terraform checks)
- **Level**: 10 for detected drift, 3 for clean checks
- **Description**: Includes the number of changed resources or specific configuration details

### Investigating Drift

1. Check the Wazuh Dashboard for drift alerts (filter by group `drift`)
2. SSH to iac-control and review drift logs
3. Run a manual drift check for the specific VM:

```bash
# From iac-control:
cd ~/sentinel-repo/ansible
ansible-playbook -i inventory/hosts.ini playbooks/<vm>.yml --check --diff
```

4. If the drift is intentional (planned change not yet in IaC), enter maintenance mode
5. If the drift is unexpected, investigate root cause before remediation

## Timer Dependencies

The timers run in this order, each depending on the prior step:

| Time (UTC) | Timer | Dependency |
|------------|-------|------------|
| Every 90min | ssh-cert-renew | Must fire before 6:00 UTC (certs expire after 2h TTL) |
| 6:00 | nist-compliance-check | Requires valid SSH certs |
| 8:00 | drift-detection | Requires valid SSH certs |
| 8:30 | drift-remediation | Only runs if 8:00 check found drift |

**Critical**: Expired SSH certificates cause cascading false failures across drift detection and compliance checks (AU-2, SC-7, etc.). The `ssh-cert-renew.timer` runs every 90 minutes with a 2-hour TTL to ensure certs are always valid.

## NIST Control Mapping

| Control | Name | How Drift Detection Satisfies |
|---------|------|-------------------------------|
| CM-3 | Configuration Change Control | Detects unauthorized configuration changes |
| CM-3(2) | Configuration Change Control - Test/Validate | Ansible --check validates before applying |
| CM-6 | Configuration Settings | Enforces baseline settings via common role |
| SI-7 | Software, Firmware, and Information Integrity | FIM + drift detection catches unauthorized modifications |

## Operational Notes

- Auto-remediation only applies the `common` role. Service-specific drift (e.g., Wazuh config, Vault config) is not auto-remediated.
- Never use `date +%Y` in systemd ExecStart -- `%` is expanded as systemd specifiers. This is why the drift scripts use external script files, not inline commands.
- The sysctl hardening settings can revert after VM reboot. The `sentinel-sysctl-reapply.service` runs at boot to re-apply them.
