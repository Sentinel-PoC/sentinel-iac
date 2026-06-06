# System Maintenance Policy (MA-1)

**Document ID**: POL-MA-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for performing controlled, timely, and secure maintenance on the Overwatch Platform. It covers patching, upgrades, and routine system upkeep.

## 2. Scope

This policy applies to all maintenance activities on Overwatch Platform components:

- Operating system patching (Ubuntu 24.04 on all VMs)
- Application upgrades (Vault, GitLab CE, MinIO, Docker, ArgoCD)
- Container image updates (OKD workloads, qBittorrent, gluetun)
- Proxmox hypervisor updates
- OKD cluster upgrades
- Hardware maintenance (physical hosts)
- Security tool updates (Trivy, gitleaks, tflint, AIDE)

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve maintenance windows, perform upgrades, verify post-maintenance |
| **Automated Tooling** (Claude Code) | Identify EOL components, propose upgrade paths, update Ansible defaults |
| **Component Lifecycle Tracker** | Track versions, EOL dates, and upgrade urgency (`compliance/component-lifecycle.md`) |
| **Trivy** | Scan for known vulnerabilities in OS packages and container images |

## 4. Policy Statements

### 4.1 Controlled Maintenance (MA-2)

- All maintenance activities SHALL be planned and documented.
- For critical components (Vault, GitLab, OKD), a Proxmox snapshot SHALL be taken before maintenance begins.
- Maintenance on Vault SHALL include a MinIO backup in addition to the snapshot.
- Post-maintenance verification SHALL confirm service availability and data integrity.

### 4.2 Maintenance Tools (MA-3)

- Maintenance SHALL be performed using approved tools:
  - Ansible playbooks for configuration updates
  - GitLab CI/CD pipeline for automated deployments
  - Proxmox web UI or API for hypervisor-level operations
  - `docker pull` / `docker run` for container-based services (Vault, seedbox)
  - `apt` for OS-level package management
- Ad-hoc SSH access for maintenance SHALL use JiT certificates signed by Vault SSH CA.

### 4.3 Timely Maintenance (MA-6)

- **Critical security patches** (CVSS >= 9.0): Apply within 72 hours.
- **High security patches** (CVSS 7.0-8.9): Apply within 30 days.
- **Routine OS updates**: Apply monthly.
- **EOL components**: Upgrade before EOL date or within 30 days of EOL notification, whichever comes first.
- The Component Lifecycle Tracker SHALL be reviewed monthly to identify upcoming EOL dates.

### 4.4 Maintenance Records

- Maintenance activities SHALL be recorded via:
  - Git commits in the `sentinel-iac` repository (Ansible/Terraform changes)
  - Change records in `compliance/` for significant upgrades
  - Component Lifecycle Tracker updates with new version numbers and dates

### 4.5 Remote Maintenance (MA-4)

- All remote maintenance SHALL occur over encrypted channels (SSH with Vault-signed certificates).
- Proxmox API access SHALL use scoped API tokens stored in Vault.
- The `claude-automation` Vault policy provides read-only access for automated assessment; write operations require the system owner.

### 4.6 Nonlocal Maintenance (MA-4(3))

- Remote maintenance from outside the local network is NOT permitted.
- All maintenance SHALL originate from the local network or via VPN.
- The Pangolin reverse proxy does NOT expose management interfaces externally.

## 5. Enforcement

- Components past EOL SHALL be flagged in the POA&M with a remediation deadline.
- Unpatched critical vulnerabilities SHALL block deployment via Trivy pipeline checks.
- Maintenance without a pre-activity snapshot SHALL be considered a policy violation.

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- The Component Lifecycle Tracker SHALL be reviewed monthly.
- Maintenance procedures SHALL be updated when new components are added to the platform.

## 7. References

- NIST SP 800-53 Rev 5: MA-1, MA-2, MA-3, MA-4, MA-6
- Component Lifecycle Tracker (`compliance/component-lifecycle.md`)
- Infrastructure Deployment Guide (`compliance/infrastructure-deployment-guide.md`)
