# Configuration Management Policy (CM-1)

**Document ID**: POL-CM-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for managing configuration of all Overwatch Platform components. It ensures that system baselines are defined, changes are controlled, and configuration drift is detected and corrected.

## 2. Scope

This policy applies to all Overwatch Platform infrastructure, including:

- Proxmox hypervisors (pve, 208-pve2, pve3)
- Virtual machines (iac-control, vault-server, gitlab-server, seedbox-vm)
- LXC containers (config-server, minio-bootstrap, minio-replica)
- OKD cluster nodes (master-1 through master-3)
- Container workloads managed by ArgoCD
- Network devices and firewall rules
- IaC artifacts (Ansible roles, Terraform modules, Packer templates)

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve configuration baselines, authorize changes, review policy annually |
| **Automated Tooling** (Claude Code / claude-automation) | Execute configuration checks, generate compliance reports, propose changes via git |
| **GitLab CI/CD** | Validate all configuration changes (yamllint, ansible-lint, tflint, trivy, gitleaks) |
| **ArgoCD** | Enforce desired state for OKD workloads via GitOps |

## 4. Policy Statements

### 4.1 Baseline Configuration (CM-2)

- All VM configurations SHALL be defined as Ansible roles in the `sentinel-iac` repository.
- Baseline configurations SHALL be version-controlled in git with full commit history.
- The system owner SHALL review and approve baselines before deployment.

### 4.2 Configuration Change Control (CM-3)

- All configuration changes SHALL be committed to git before deployment.
- Changes SHALL pass automated validation (lint, security scan) via GitLab CI before merge to `main`.
- Emergency changes MAY bypass CI but MUST be committed and validated within 24 hours.

### 4.3 Impact Analysis (CM-4)

- Changes to shared infrastructure (HAProxy, dnsmasq, iptables, Vault) SHALL be tested with `--check --diff` before live application.
- OKD workload changes SHALL be previewed via ArgoCD diff before sync.

### 4.4 Access Restrictions for Change (CM-5)

- Only the system owner and authorized automation (claude-automation Vault policy) SHALL modify production configurations.
- Git repository access is restricted via GitLab authentication.
- Proxmox API tokens are scoped to specific operations and stored in Vault.

### 4.5 Configuration Settings (CM-6)

- Security-relevant settings SHALL be enforced by Ansible:
  - SSH session timeouts (15 minutes)
  - Login banners (legal notice)
  - Log retention (30 days)
  - AIDE file integrity monitoring
  - Docker daemon configuration (json-file log driver with rotation)
- Drift from Ansible-defined baselines SHALL be detected via periodic `--check --diff` runs.

### 4.6 Software Usage Restrictions (CM-10)

- Only software defined in Ansible roles and Packer templates SHALL be installed on production VMs.
- Container images SHALL be pulled from trusted registries only.
- Trivy filesystem scanning SHALL detect unauthorized or vulnerable packages.

### 4.7 Information Location (CM-12)

- All IaC code: `sentinel-iac` GitLab repository
- OKD workload definitions: `overwatch-gitops` GitLab repository
- Cluster bootstrap: `overwatch` GitLab repository
- Secrets: HashiCorp Vault (KV v2 at `secret/`)
- Backups: MinIO (primary) with Backblaze B2 (offsite, encrypted)

## 5. Enforcement

- Non-compliant changes SHALL be blocked by GitLab CI pipeline (gitleaks, trivy with `allow_failure: false`).
- Configuration drift detected by Ansible or AIDE SHALL be investigated and corrected within 72 hours.
- Unauthorized software detected by Trivy SHALL be removed or documented with a risk acceptance.

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- Reviews SHALL be triggered earlier if there are significant infrastructure changes.
- Review evidence SHALL be recorded via git commit updating the review date in this document.

## 7. References

- NIST SP 800-53 Rev 5: CM-1, CM-2, CM-3, CM-4, CM-5, CM-6, CM-10, CM-12
- Overwatch Configuration Management Plan (`compliance/configuration-management-plan.md`)
- Infrastructure Deployment Guide (`compliance/infrastructure-deployment-guide.md`)
