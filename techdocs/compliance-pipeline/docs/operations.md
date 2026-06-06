# Operations

## Running Checks Manually

### On iac-control

```bash
# SSH to iac-control
ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210

# Set required environment variables
source /etc/sentinel/compliance.env   # Loads WAZUH_PASS
export VAULT_TOKEN="<your-vault-token>"
export KUBECONFIG=~/overwatch-repo/auth/kubeconfig

# Run the compliance check
~/sentinel-repo/scripts/nist-compliance-check.sh
```

The script requires:

- **WAZUH_PASS**: Wazuh API password (loaded from `/etc/sentinel/compliance.env`)
- **VAULT_TOKEN** (optional): Enables Vault API checks. If unset, Vault-dependent checks emit WARN instead of FAIL.
- **KUBECONFIG** (defaults to `~/overwatch-repo/auth/kubeconfig`): OKD cluster access for ArgoCD, Kyverno, Istio, SCC checks.
- **SSH keys**: `~/.ssh/id_sentinel` and `~/.ssh/id_wazuh` must have valid Vault-signed certificates.

### Maintenance Mode

If you need to run manual infrastructure work without triggering compliance check failures:

```bash
# Enter maintenance mode (blocks all automation)
~/scripts/sentinel-maintenance.sh enter --reason "manual patching" --timeout 4h

# Enter maintenance mode (blocks only auto-remediation)
~/scripts/sentinel-maintenance.sh enter --reason "testing" --scope remediation

# Check status
~/scripts/sentinel-maintenance.sh status

# Exit maintenance mode
~/scripts/sentinel-maintenance.sh exit
```

The compliance check script respects maintenance mode: if `scope=all` is active, the script skips execution entirely.

## Understanding Output

### Console Output

The script prints a human-readable summary at the end:

```
==============================================
  NIST 800-53 Compliance Report - 2026-03-01
==============================================
  Status:   COMPLIANT
  Passed:   109/115
  Failed:   0
  Warnings: 6
  Coverage: 111/226 controls (49%)
==============================================

WARNINGS:
  [AT-2] training_records: No formal security awareness training records found
  [AT-3] role_based_training: No role-based security training records found
  ...
```

### JSON Output

Each check produces a JSON object:

```json
{
  "status": "PASS",
  "control": "CA-7",
  "check": "wazuh_agents_active",
  "detail": "9 agents active (expected >= 9)"
}
```

The full report is written to `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json` with this structure:

```json
{
  "timestamp": "2026-03-01T06:00:00Z",
  "date": "2026-03-01",
  "framework": "NIST 800-53 Rev 5",
  "project": "Sentinel",
  "overall_status": "COMPLIANT",
  "summary": {
    "pass": 109,
    "fail": 0,
    "warn": 6,
    "total": 115,
    "pass_rate": 94,
    "coverage": {
      "controls_checked": 111,
      "controls_applicable": 226,
      "coverage_pct": 49
    }
  },
  "checks": [ ... ]
}
```

### Compliance Log

A one-line summary is appended to `/var/log/sentinel/compliance.log`:

```
2026-03-01T06:00:00Z NIST-COMPLIANCE: COMPLIANT - 109/115 checks passed (0 failed, 6 warnings)
```

This log line is monitored by Wazuh for alerting.

## Adding a New Check

All check functions follow this pattern:

```bash
check_example_thing() {
    log "Checking something [CONTROL-ID]..."

    # Query infrastructure state
    local result
    result=$(some_command || echo "fallback")

    # Evaluate and emit result
    if [ "$result" = "expected" ]; then
        pass "CONTROL-ID" "check_name" "Description of what passed"
    else
        fail "CONTROL-ID" "check_name" "Description of what failed"
    fi
}
```

### Helper Functions

The script provides these helpers for querying remote systems:

| Helper | Purpose | Example |
|--------|---------|---------|
| `ssh_sentinel "$host" "cmd"` | SSH with id_sentinel key | `ssh_sentinel "$PANGOLIN_HOST" "systemctl is-active crowdsec"` |
| `ssh_wazuh "cmd"` | SSH to Wazuh server with id_wazuh key | `ssh_wazuh "sudo grep -c '<rule' /var/ossec/etc/rules/local_rules.xml"` |
| `ssh_vault "cmd"` | SSH to Vault server (tries id_sentinel, falls back to id_wazuh) | `ssh_vault "docker ps --format '{{.Names}}'"` |
| `vault_api "/endpoint"` | Vault HTTPS API call with token | `vault_api "/sys/policy"` |
| `http_status "url"` | HTTP status code probe | `http_status "https://auth.208.haist.farm/health"` |
| `oc_cmd "args..."` | OKD oc command with kubeconfig | `oc_cmd get pods -n openshift-gitops` |
| `local_svc "name"` | Check systemd service status locally | `local_svc "keepalived"` |
| `wazuh_get "/endpoint" "$token"` | Wazuh API call with JWT token | `wazuh_get "/agents?status=active" "$token"` |
| `pass "CTRL" "name" "detail"` | Emit PASS JSON | `pass "SC-7" "ufw_active" "6/6 hosts active"` |
| `fail "CTRL" "name" "detail"` | Emit FAIL JSON | `fail "SC-7" "ufw_active" "2/6 hosts active"` |
| `warn "CTRL" "name" "detail"` | Emit WARN JSON | `warn "SC-7" "ufw_active" "VAULT_TOKEN not set"` |

### Steps to Add a Check

1. Write the check function in the appropriate family section of `nist-compliance-check.sh`.
2. Add the function call to the `main()` function in the results array.
3. Update `docs/nist-gap-analysis.md` with the new control in the family table.
4. Push to GitLab to trigger CI validation.
5. Verify the check runs correctly on next daily execution or manual run.

### Check Design Principles

- Each check maps to exactly one NIST 800-53 control ID.
- Checks should test *necessary conditions*, not sufficient ones. A PASS means the technical prerequisite is present, not that the full control is satisfied.
- Use `warn` (not `fail`) when a check cannot execute due to missing credentials or connectivity issues. This distinguishes "we cannot verify" from "we verified and it failed."
- SSH commands must use `ssh -n` (or `< /dev/null`) to prevent stdin consumption by nested SSH calls.
- Timeout all external queries (SSH: `-o ConnectTimeout=5`, curl: `--max-time 10`).

## CI vs. Manual Execution

| Aspect | Manual (iac-control) | CI Pipeline |
|--------|---------------------|-------------|
| Script | `nist-compliance-check.sh` | `ci/security.yml` + `ci/compliance.yml` |
| Trigger | Daily timer or manual | Every push to main |
| Scope | 115 live infrastructure checks | Static analysis + scan of IaC code |
| Checks | Wazuh, SSH, Vault, OKD, HTTP | yamllint, ansible-lint, tflint, trivy, gitleaks, checkov, shellcheck |
| Output | JSON report + compliance.log | CI artifacts (JSON reports) |
| Uploads to | compliance-vault (via evidence pipeline) | DefectDojo (via ci/defectdojo.yml) |
| Runner | iac-control systemd | iac-control GitLab runner (tag: `iac`) |

The CI pipeline validates IaC code quality and security posture of the codebase itself. The compliance check script validates the live deployed infrastructure state. Both are necessary; neither alone is sufficient.

## Evidence Pipeline Workflow

The evidence pipeline runs daily at 7:00 AM UTC, one hour after the compliance check:

1. Reads the latest JSON report from `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json`.
2. Converts it to OSCAL Assessment Results format using `convert-to-oscal-ar.sh`.
3. Generates a markdown daily report using `compliance-vault/scripts/generate-daily-report.py`.
4. Updates the trend summary at `compliance-vault/reports/compliance-trend-summary.md`.
5. Commits and pushes all artifacts to the `compliance-vault` GitLab repo.

## Troubleshooting

### Common Failure Modes

**SSH certificate expiry**: If multiple remote-host checks suddenly FAIL, the JiT SSH certificates have likely expired. The `ssh-cert-renew.timer` runs every 90 minutes and must fire before the compliance check timer at 6:00 AM UTC.

```bash
# Check certificate validity
ssh-keygen -L -f ~/.ssh/id_sentinel-cert.pub
ssh-keygen -L -f ~/.ssh/id_wazuh-cert.pub

# Force renewal
~/sentinel-repo/scripts/ssh-cert-renew.sh
```

**VAULT_TOKEN expired**: Vault-dependent checks (AC-6, AC-17, IA-2(12), IA-5(13), MP-5) will emit WARN. Renew the token and update `/etc/sentinel/compliance.env`.

**Wazuh API authentication failure**: If the Wazuh JWT token cannot be obtained, the script exits with FATAL. Check that `WAZUH_PASS` is set correctly and the Wazuh API at `192.168.12.100:55000` is reachable.

**OKD API unreachable**: ArgoCD, Kyverno, Istio, SCC, and NetworkPolicy checks will fail. Verify `KUBECONFIG` points to a valid kubeconfig and that the OKD API server is accessible.
