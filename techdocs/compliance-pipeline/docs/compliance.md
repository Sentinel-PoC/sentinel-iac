# Pipeline Compliance

## Meta-Compliance: What the Pipeline Itself Satisfies

The compliance pipeline is not just a tool for checking compliance -- it is itself evidence of compliance with several NIST 800-53 controls. This page documents which controls the pipeline satisfies and the evidence supporting each.

## CA-2: Security Assessments

**Requirement**: Develop a control assessment plan; assess controls with the defined frequency; produce an assessment report; provide results to designated personnel.

**How the pipeline satisfies CA-2**:

- The compliance check script (`nist-compliance-check.sh`) IS the assessment plan, codified as executable checks.
- It runs daily at 6:00 AM UTC via systemd timer (`nist-compliance-check.timer`), satisfying the "defined frequency" requirement.
- It produces a JSON assessment report with per-check pass/fail/warn results and overall coverage metrics.
- Results are committed to the `compliance-vault` GitLab repo for review by the platform operator.

**Evidence**:

- systemd timer unit: `nist-compliance-check.timer` (active on iac-control)
- Script: `scripts/nist-compliance-check.sh` (115 checks, 111 controls)
- Output: `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json`
- Git evidence: Daily commits to compliance-vault repo

## CA-7: Continuous Monitoring

**Requirement**: Develop a continuous monitoring strategy; implement a monitoring program with established frequencies; assess controls on an ongoing basis; maintain awareness of threats and vulnerabilities.

**How the pipeline satisfies CA-7**:

- The daily compliance check execution constitutes ongoing control assessment.
- Wazuh SIEM with 9 active agents provides continuous threat and vulnerability monitoring.
- The CI pipeline runs security scans (trivy, gitleaks, checkov) on every code change.
- DefectDojo aggregates vulnerability findings for tracking over time.
- Grafana dashboards and alerting provide real-time operational awareness.

**Evidence**:

- Daily execution: systemd timer with 6:00 AM UTC schedule
- Wazuh monitoring: 9 agents active, 8600+ rules loaded, FIM on all hosts
- CI security scanning: 7 security jobs per pipeline run
- DefectDojo: 5 scan types uploaded per pipeline
- Trend tracking: `compliance-vault/reports/compliance-trend-summary.md`

## CA-7(1): Independent Assessment

**Requirement**: Employ independent assessors to monitor controls on an ongoing basis.

**How the pipeline satisfies CA-7(1)**:

- The drift detection timer (`sentinel-drift-detection.timer`) runs independently from the compliance check, providing a separate assessment of infrastructure configuration state.
- Ansible `--check --diff` mode detects configuration drift without applying changes.
- Wazuh custom rules (100420-100428) alert on drift detection results, providing independent notification through a separate channel.

**Evidence**:

- Drift detection timer: `sentinel-drift-detection.timer` (daily 8:00 AM UTC)
- Drift alerting: Wazuh rules 100420-100428
- Separation of duties: Drift detection uses Ansible playbooks (declarative state) while compliance checks use direct queries (observed state). Two independent methods for verifying the same infrastructure.

## Additional Controls Supported

The pipeline provides supporting evidence for several other controls, though it is not the primary satisfying mechanism:

### AU-2: Audit Events

The compliance log (`/var/log/sentinel/compliance.log`) itself is an audited event. Wazuh monitors this log file and can trigger alerts on NON-COMPLIANT status.

### CM-3(2): Test/Validate/Document Changes

The CI pipeline ensures all IaC changes are tested (lint), validated (security scan), and documented (compliance report artifact) before deployment.

### SA-11: Developer Testing and Evaluation

The CI pipeline includes static code analysis (ansible-lint, tflint, checkov), vulnerability scanning (trivy), and secret detection (gitleaks) -- satisfying developer-level security testing requirements.

### RA-5: Vulnerability Scanning

Trivy scans in CI (IaC misconfig + filesystem vulns) and the DefectDojo integration provide automated vulnerability scanning and tracking as required by RA-5.

## Pipeline Resilience

### Failure Modes and Mitigations

| Failure | Impact | Mitigation |
|---------|--------|------------|
| SSH cert expiry | Remote host checks fail | ssh-cert-renew.timer runs every 90min, before 6AM check |
| Wazuh API down | Script exits with FATAL | Wazuh server monitored by iDRAC watchdog |
| VAULT_TOKEN expired | Vault checks emit WARN | Token stored in /etc/sentinel/compliance.env, renewable |
| OKD API unreachable | K8s checks fail | HAProxy LB + keepalived HA for API access |
| GitLab unreachable | Evidence pipeline cannot push | GitLab backup timer + DR scripts in place |
| Maintenance mode active | Script skips entirely | Intentional -- prevents false failures during manual work |

### Audit Trail Integrity

The compliance-vault GitLab repo provides tamper-evident storage for compliance evidence:

- Branch protection prevents force-push to `main`
- Push restricted to Maintainers role
- Git history provides an immutable audit trail of all compliance state changes
- Daily commits by the evidence pipeline create a timestamped evidence chain

### No Single Point of Failure for Detection

The pipeline uses multiple independent detection mechanisms:

```
Detection Layer 1: nist-compliance-check.sh (direct queries)
Detection Layer 2: Wazuh SIEM (agent-based monitoring)
Detection Layer 3: Ansible drift detection (declarative state comparison)
Detection Layer 4: CI security scanning (code-level analysis)
Detection Layer 5: ArgoCD sync monitoring (GitOps state comparison)
```

A compliance failure would need to evade all five detection layers to go unnoticed.
