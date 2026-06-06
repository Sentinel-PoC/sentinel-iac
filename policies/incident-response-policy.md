# Incident Response Policy (IR-1)

**Document ID**: POL-IR-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for detecting, responding to, and recovering from security incidents on the Overwatch Platform. It defines incident categories, response expectations, and reporting obligations.

## 2. Scope

This policy applies to all security events and incidents affecting the Overwatch Platform, including:

- Unauthorized access attempts to any system component
- Malware or ransomware detection
- Data breaches or unauthorized data exfiltration
- Denial of service against platform services
- Configuration tampering or unauthorized changes
- Vault seal events or secret compromise
- Supply chain compromise of upstream packages or images

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Incident commander, final authority on containment/eradication decisions |
| **AIDE** | File integrity monitoring — detect unauthorized changes on iac-control and GitLab |
| **Vault Audit Log** | Record all secret access and authentication events |
| **Grafana Alerts** | Forward threshold-based alerts to webhook receiver on iac-control |
| **Gitleaks** | Detect secrets committed to repositories (pipeline gate) |
| **Trivy** | Detect vulnerabilities in IaC and filesystem scans |

## 4. Policy Statements

### 4.1 Incident Detection (IR-4)

- The following detection mechanisms SHALL be active at all times:
  - AIDE file integrity checks (daily cron on iac-control and GitLab)
  - Vault audit logging (`/vault/logs/audit.log`, 30-day retention)
  - Grafana alerting with webhook receiver (iac-control:9095)
  - Gitleaks scanning on every git push (all 3 repositories)
  - Trivy vulnerability scanning on every pipeline run
- Detection mechanisms SHALL be verified during annual DR tests.

### 4.2 Incident Classification

| Severity | Definition | Response Time |
|----------|-----------|---------------|
| **Critical** | Active compromise, data breach, Vault unsealed by unauthorized party | Immediate (< 1 hour) |
| **High** | Successful unauthorized access, malware detection, AIDE alert on critical files | < 4 hours |
| **Medium** | Failed access attempts (brute force), vulnerability with known exploit | < 24 hours |
| **Low** | Policy violation, non-exploitable vulnerability, misconfiguration | < 72 hours |

### 4.3 Incident Response Procedures (IR-4)

All incidents SHALL follow the four-phase response process documented in the Incident Response Plan:

1. **Detection & Analysis** — Confirm the incident, determine scope and severity.
2. **Containment** — Isolate affected systems. For Vault compromise: seal Vault immediately. For network intrusion: isolate VM via Proxmox firewall.
3. **Eradication & Recovery** — Remove threat, restore from known-good backups, rotate compromised credentials in Vault.
4. **Post-Incident Review** — Document lessons learned, update detection rules, revise this policy if needed.

### 4.4 Incident Reporting (IR-6)

- All incidents SHALL be documented with: date/time, severity, affected systems, actions taken, and resolution.
- Incident records SHALL be retained for a minimum of 1 year.
- For a single-operator environment, incident reports are self-documented in the `sentinel-iac` repository under `compliance/incidents/`.

### 4.5 Incident Response Training (IR-2)

- The system owner SHALL review the Incident Response Plan at least annually.
- DR tests SHALL include incident response scenarios (e.g., simulated Vault compromise, backup restore).

### 4.6 Information Spillage (IR-9)

- If secrets are detected in git commits (by gitleaks or manual review), the following procedure applies:
  1. Rotate the exposed credential immediately via Vault.
  2. Update the credential in all consuming systems.
  3. If the commit is not yet pushed, use `git rebase` to remove it.
  4. If the commit is pushed, rotate the credential and document in an incident report.

## 5. Enforcement

- Gitleaks findings SHALL block pipeline execution (`allow_failure: false`).
- AIDE alerts SHALL be investigated within 24 hours.
- Failure to respond to a Critical incident within 1 hour SHALL trigger a post-incident review to improve detection/notification.

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- This policy SHALL be reviewed after every significant security incident.
- The Incident Response Plan SHALL be tested during annual DR exercises.

## 7. References

- NIST SP 800-53 Rev 5: IR-1, IR-2, IR-4, IR-5, IR-6, IR-8, IR-9
- Incident Response Plan (`compliance/incident-response-plan.md`)
- Vault Audit Log (`/vault/logs/audit.log` on vault-server)
