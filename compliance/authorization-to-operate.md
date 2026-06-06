# Authorization to Operate (ATO) Memo (CA-6, PM-10)

**Document ID**: ATO-OWP-001
**Version**: 1.0
**Issue Date**: 2026-02-08
**Review Date**: 2026-05-08 (Quarterly)
**Classification**: Internal
**System**: Overwatch Platform

---

## Authorization Decision

### System Identification

| Field | Value |
|-------|-------|
| **System Name** | Overwatch Platform |
| **System Owner / Authorizing Official** | Haists Consulting |
| **System Type** | Hybrid-cloud AI/DevOps homelab platform |
| **Authorization Boundary** | 3 Proxmox hosts, 6 VMs, 3 LXC containers, 3-node OKD cluster, external services (Backblaze B2, Cloudflare DNS) |
| **NIST Baseline** | SP 800-53 Rev 5 Moderate (tailored for single-operator homelab) |
| **Data Classification** | Internal — personal projects, learning platform, portfolio demonstration |

### Authorization Statement

**Haists Consulting** as the system owner and sole operator of the Overwatch Platform, hereby authorize this system to operate under the following conditions:

**Authorization Type**: Self-Authorization (Homelab / Portfolio Use)

**Authorization Decision**: **AUTHORIZED TO OPERATE**

**Effective Date**: 2026-02-08
**Expiration Date**: 2026-08-08 (6 months, renewable)

This authorization is based on:
1. The Security Assessment Report (SAR) findings dated 2026-02-08
2. The current Plan of Action & Milestones (POA&M) status
3. The accepted residual risk level documented below

---

## Risk Assessment Summary

### Current Security Posture

| Metric | Value |
|--------|-------|
| NIST 800-53 Controls Applicable | 276 |
| Controls Compliant | 144 (52%) |
| Controls Partially Compliant | 58 (21%) |
| Controls Non-Compliant | 74 (27%) |
| Open POA&M Items | Tracked in POA&M document |
| Critical/High Findings | 0 critical, remaining items are moderate/low priority |

### Completed Security Sprints

| Sprint | Focus | Controls Addressed |
|--------|-------|-------------------|
| Sprint 1 | Documentation (SSP, IRP, CM Plan) | +16 controls |
| Sprint 2 | DevSecOps Pipeline (Trivy, gitleaks, CI/CD) | +18 controls |
| Sprint 3 | POA&M Remediation (AIDE, etcd backup, alerts) | +13 controls |
| Sprint 4 | DR Automation + Vault Upgrade | +12 controls |

### Key Security Controls in Place

- **Access Control**: Vault-signed SSH certificates (JiT), scoped API tokens, single-operator access
- **Audit & Accountability**: Vault audit logging, systemd journal, 30-day log retention
- **Configuration Management**: Full IaC (Ansible/Terraform/Packer), GitLab CI validation pipeline
- **Contingency Planning**: Automated backups (Vault daily, GitLab weekly, etcd daily), Proxmox snapshots, MinIO replication, B2 offsite encrypted backups, tested DR procedures
- **Identification & Authentication**: Vault SSH CA, GitLab PAT rotation, Proxmox API tokens
- **Incident Response**: AIDE FIM, Grafana alerting, gitleaks pipeline gate, documented IRP
- **System Integrity**: Trivy scanning (IaC + filesystem), AIDE baseline monitoring
- **Supply Chain**: Approved registries, vendor trust assessments, component lifecycle tracking

---

## Accepted Risks

The following residual risks are accepted for continued operation:

| Risk ID | Description | Justification |
|---------|-------------|---------------|
| AR-01 | 27% of NIST controls are non-compliant | Many non-compliant controls address federal-specific requirements (personnel security, physical facility controls) that are not applicable to a single-operator homelab. Remaining gaps are tracked in POA&M for continued remediation. |
| AR-02 | OKD community edition (not commercially supported) | Acceptable for homelab use. etcd backups and Proxmox snapshots provide recovery capability. Platform is not business-critical. |
| AR-03 | Single-operator environment (no separation of duties) | Inherent to homelab architecture. Mitigated by audit logging, automated compliance checks, and AI-assisted operations review. |
| AR-04 | No dedicated SIEM or SOC | Disproportionate for homelab scope. Mitigated by Vault audit logs, AIDE FIM, Grafana alerts, and gitleaks pipeline gates. |
| AR-05 | Local network exposure (no external access except via Pangolin tunnel) | All services are local-only. Cloudflare DNS A records deleted per SC-7(16). Wildcard DNS resolves via local dnsmasq only. |
| AR-06 | Newt tunnel credentials not rotatable (paid Pangolin feature) | Risk accepted — credentials are local-only, not in git history, exposure limited to trusted network. |

---

## Conditions and Constraints

This authorization is subject to the following conditions:

1. **Continued POA&M Remediation**: The system owner SHALL continue addressing POA&M items per the sprint schedule (target: 57-60% compliance by Sprint 6).
2. **Quarterly Review**: This ATO SHALL be reviewed quarterly. The next review is **2026-05-08**.
3. **Incident Reporting**: Any security incident SHALL be documented per the Incident Response Plan and may trigger early ATO review.
4. **Component Currency**: All critical components SHALL remain within vendor-supported versions per the Maintenance Policy.
5. **Backup Verification**: DR procedures SHALL be tested at least annually with results documented.
6. **Credential Rotation**: Vault automation tokens, GitLab PATs, and Proxmox API tokens SHALL be rotated per their defined schedules.
7. **No Production Data**: This system SHALL NOT process, store, or transmit data subject to regulatory requirements (HIPAA, PCI-DSS, FedRAMP). It operates as a personal learning and portfolio platform only.

---

## Authorization Renewal

This ATO expires on **2026-08-08** and SHALL be renewed by:

1. Reviewing the current SAR and POA&M status
2. Confirming no new critical or high-severity findings
3. Verifying continued compliance with the conditions above
4. Updating this document with a new effective/expiration date
5. Committing the updated document to the `sentinel-iac` repository

---

## Signatures

| Role | Name | Date |
|------|------|------|
| **System Owner / Authorizing Official** | Haists Consulting | 2026-02-08 |

*This is a self-authorization for a personal homelab platform. It demonstrates NIST 800-53 ATO process compliance for portfolio and learning purposes.*

---

## References

- NIST SP 800-53 Rev 5: CA-6 (Authorization), PM-10 (Authorization Process)
- Security Assessment Report (SAR)
- Plan of Action & Milestones (POA&M)
- System Security Plan (SSP)
