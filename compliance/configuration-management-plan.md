# Configuration Management Plan
## Overwatch Platform — NIST SP 800-53 Rev 5

**Document Classification**: INTERNAL — FOR PORTFOLIO USE
**Created**: 2026-02-07
**System**: Overwatch Platform (OKD 4.19 on Proxmox)
**Owner**: Haists Consulting
**Control Addressed**: CM-9

---

## 1. Purpose and Scope

### 1.1 Purpose

This Configuration Management Plan (CMP) establishes the processes, tools, and responsibilities for managing configuration items across the Overwatch Platform. It ensures that all changes are tracked, validated, and applied in a controlled manner.

### 1.2 Scope

This plan covers all infrastructure and application components:
- **Physical layer**: 3 Proxmox hypervisors (pve, 208-pve2, pve3)
- **VM layer**: iac-control, GitLab, Vault, MinIO, OKD masters/workers
- **Container layer**: OKD workloads managed by ArgoCD
- **Network layer**: iptables, HAProxy, Squid, dnsmasq, Pangolin/Traefik
- **Secret layer**: Vault KV v2 secrets, SSH CA certificates
- **CI/CD layer**: GitLab pipelines, runners, CI variables
- **Monitoring layer**: Grafana, Loki, Promtail, alert rules

---

## 2. Roles and Responsibilities

| Role | Person / System | Responsibilities |
|------|-----------------|-----------------|
| **Configuration Manager / System Owner** | Haists Consulting | Approve all changes, maintain baselines, resolve deviations |
| **AI Configuration Agent** | Claude Code | Read-only assessment and recommendation under `claude-automation` Vault policy. Cannot make changes autonomously — all modifications require human approval. |
| **CI/CD Pipeline** | GitLab CI | Automated validation (lint, scan, test) on every commit |
| **GitOps Controller** | ArgoCD | Automated deployment of approved OKD configurations |
| **File Integrity Monitor** | AIDE | Detect unauthorized changes to managed hosts |

---

## 3. Configuration Items

### 3.1 Infrastructure Configuration Items

| CI Category | Items | Managed By | Baseline Location |
|-------------|-------|-----------|-------------------|
| **Proxmox VMs** | VM definitions, resource allocation, networks | Terraform/OpenTofu | `sentinel-iac/infrastructure/bootstrap/` |
| **iac-control** | Packages, services, firewall, proxy, DNS | Ansible | `sentinel-iac/ansible/` |
| **GitLab** | GitLab config, CI runners, variables | Manual + backup | `sentinel-iac/infrastructure/gitlab-dr/` |
| **Vault** | Docker compose, config, policies, auth methods | Manual + backup | `sentinel-iac/infrastructure/vault-dr/` |
| **MinIO** | Server config, buckets, rclone config | Manual + backup | `sentinel-iac/infrastructure/minio-dr/` |
| **OKD Cluster** | Cluster config, install config, ignition | Terraform | `overwatch/` |
| **OKD Workloads** | Deployments, services, routes, configmaps | ArgoCD | `overwatch-gitops/apps/` |
| **Network Rules** | iptables, HAProxy, Squid, dnsmasq configs | Ansible + manual | `sentinel-iac/ansible/` + host configs |
| **Pangolin/Traefik** | Dynamic routes, TLS certs, tunnel config | Manual + git | `sentinel-iac/infrastructure/pangolin/` |
| **Secrets** | Vault KV entries, SSH CA keys, API tokens | Vault | Vault KV v2 at `secret/` |

### 3.2 Software Configuration Items

| Component | Version Source | Update Method |
|-----------|---------------|---------------|
| OS packages | `apt list --installed` | `apt upgrade` with maintenance window |
| OKD platform | `oc version` | Cluster upgrade procedure |
| Container images | `oc get pods -o jsonpath` | ArgoCD image update |
| Vault | Docker image tag | Docker compose update |
| GitLab | `/opt/gitlab/version-manifest.txt` | `apt upgrade gitlab-ce` |
| Security tools | Binary versions on iac-control | Manual update + CI test |

See `compliance/component-lifecycle.md` for full version tracking and EOL dates.

---

## 4. Baseline Management

### 4.1 Current Baselines

| Baseline | Tool | Repository | Last Validated |
|----------|------|-----------|----------------|
| **iac-control system config** | Ansible | `sentinel-iac/ansible/` | 2026-02-07 |
| **Proxmox VM definitions** | Terraform/OpenTofu | `sentinel-iac/infrastructure/bootstrap/` | 2026-02-07 |
| **OKD cluster definition** | Terraform | `overwatch/` | 2026-02-07 |
| **OKD workloads** | ArgoCD + Helm/Kustomize | `overwatch-gitops/apps/` | 2026-02-07 |
| **Vault configuration** | Docker Compose + policies | `sentinel-iac/infrastructure/vault-dr/` | 2026-02-07 |
| **CI/CD pipelines** | `.gitlab-ci.yml` | All 3 repos | 2026-02-07 |

### 4.2 Baseline Documentation

All baselines are stored in Git across three repositories:

| Repository | Contents | URL |
|------------|----------|-----|
| **sentinel-iac** | Terraform, Ansible, compliance docs, DR configs, CI pipelines | GitLab /root/sentinel-iac |
| **overwatch** | OKD cluster Terraform, install configs | GitLab /root/overwatch |
| **overwatch-gitops** | ArgoCD app definitions, Helm values, K8s manifests | GitLab /root/overwatch-gitops |

### 4.3 Baseline Updates

Baselines are updated when:
1. A change is approved and applied successfully
2. Post-change validation passes (CI pipeline, smoke test)
3. The git commit representing the new baseline is pushed to `main`

---

## 5. Change Control Process

### 5.1 Change Request

All changes originate as git commits or merge requests:

```
Developer/Operator → Git commit → Push to main (or MR)
```

For single-operator environments, direct commits to `main` are acceptable for routine changes. Merge requests are used for significant changes that benefit from CI validation before merge.

### 5.2 Change Workflow

```
┌─────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐    ┌──────────────┐
│  1. Request  │───→│ 2. Validate  │───→│  3. Approve  │───→│ 4. Apply  │───→│  5. Verify   │
│  (git commit)│    │ (GitLab CI)  │    │ (human review│    │ (Ansible/ │    │ (pipeline +  │
│              │    │              │    │  of CI result│    │  ArgoCD/  │    │  smoke test) │
│              │    │              │    │  + diff)     │    │  Terraform│    │              │
└─────────────┘    └──────────────┘    └──────────────┘    └───────────┘    └──────────────┘
```

### 5.3 Validation Gates (GitLab CI)

Every commit triggers automated validation:

| Gate | Tool | Repos | Blocks Merge |
|------|------|-------|-------------|
| **YAML syntax** | yamllint | All 3 | Yes |
| **IaC linting** | tflint | sentinel-iac, overwatch | Yes |
| **Ansible linting** | ansible-lint | sentinel-iac | Yes |
| **Security scanning** | Trivy (IaC + filesystem) | sentinel-iac, overwatch | Yes |
| **Secrets detection** | gitleaks | All 3 | Yes (hard block) |
| **Compliance report** | Custom (main only) | sentinel-iac | No (report artifact) |

### 5.4 Approval Criteria

A change is approved when:
1. All CI pipeline gates pass (no failures in security or lint jobs)
2. Human reviews the diff and CI results
3. Change is consistent with documented baselines
4. Rollback procedure is understood (for significant changes)

### 5.5 Implementation Methods

| Scope | Tool | Command |
|-------|------|---------|
| iac-control config | Ansible | `ansible-playbook -i inventory site.yml` |
| Proxmox VMs | Terraform | `tofu plan && tofu apply` |
| OKD workloads | ArgoCD | Auto-sync from overwatch-gitops, or manual sync |
| Vault policies | Vault CLI | `vault policy write <name> <file>` |
| Manual changes | SSH + commands | Documented in commit message, captured in Ansible later |

### 5.6 Emergency Changes

For urgent changes (security patches, incident response):
1. Apply change directly (bypass CI if necessary)
2. Document the change immediately in git
3. Run CI pipeline retroactively to validate
4. Update baselines to reflect the emergency change
5. Conduct post-change review within 24 hours

---

## 6. Configuration Monitoring

### 6.1 File Integrity Monitoring (AIDE)

| Host | Scope | Schedule | Alerting |
|------|-------|----------|----------|
| iac-control | System binaries, configs, SSH keys | Daily cron | Logs to syslog → Loki → Grafana |
| GitLab | System binaries, GitLab configs, SSH keys | Daily cron | Logs to syslog → Loki → Grafana |

AIDE detects unauthorized changes to:
- `/etc/` (system configuration)
- `/usr/bin/`, `/usr/sbin/` (system binaries)
- `/opt/` (application binaries)
- SSH authorized keys and host keys

**Response to AIDE alerts**: See Incident Response Plan, Section 7.3.

### 6.2 GitLab CI Continuous Validation

Every commit to any repository triggers full validation:
- **sentinel-iac**: 7 security jobs
- **overwatch**: 4 security jobs
- **overwatch-gitops**: 3 security jobs

Pipeline failures indicate configuration drift or policy violations.

### 6.3 ArgoCD Drift Detection

ArgoCD continuously compares desired state (git) with actual state (OKD cluster):
- **Sync status**: Shows if cluster matches git
- **Health status**: Shows if resources are functioning
- **Auto-sync**: Automatically corrects drift for managed applications

Current ArgoCD-managed applications (all Synced/Healthy):
grafana, hello-world, homepage, jellyfin, newt-tunnel, nfs-provisioner, pangolin-internal, seedbox

### 6.4 Log-Based Monitoring

| Monitor | Source | Alert Condition |
|---------|--------|----------------|
| Firewall denies | iac-control iptables | Spike in deny count |
| HAProxy blocks | iac-control HAProxy | Repeated 403/429 |
| Squid denied | iac-control Squid | Unauthorized egress attempts |
| Vault API calls | Vault audit log | Unauthorized operations |

---

## 7. Tools

| Tool | Purpose | Version | Location |
|------|---------|---------|----------|
| **Git** | Version control, change tracking | System | All hosts |
| **GitLab CE** | Repository hosting, CI/CD | 18.8.2 | 192.168.12.68 |
| **Ansible** | Configuration management (iac-control) | 2.17+ | iac-control |
| **Terraform/OpenTofu** | Infrastructure provisioning (Proxmox, OKD) | OpenTofu 1.x | iac-control |
| **ArgoCD** | Kubernetes GitOps (OKD workloads) | Latest | OKD cluster |
| **AIDE** | File integrity monitoring | System | iac-control, GitLab |
| **Trivy** | Vulnerability and IaC scanning | 0.69.1 | iac-control (CI runner) |
| **tflint** | Terraform linting | 0.61.0 | iac-control |
| **ansible-lint** | Ansible linting | 6.17.2 | iac-control |
| **yamllint** | YAML syntax validation | 1.38.0 | iac-control |
| **gitleaks** | Secrets detection in git | 8.30.0 | iac-control |
| **Vault** | Secrets management, SSH CA | 1.15.4 | 192.168.12.206 |

---

## 8. Deviation Handling

### 8.1 Types of Deviations

| Type | Detection Method | Response |
|------|-----------------|----------|
| **AIDE alert** (file changed) | AIDE daily scan | Investigate: was it an approved change? If not, treat as incident (IRP Section 7.3) |
| **ArgoCD OutOfSync** | ArgoCD dashboard | Investigate: manual cluster change? Sync from git or update git to match |
| **CI pipeline failure** | GitLab pipeline status | Fix the issue, re-run pipeline. Do not merge with failures. |
| **Unauthorized user/process** | Log monitoring, AIDE | Treat as security incident (IRP Section 7.1) |
| **Configuration drift** | Manual audit, Ansible check mode | Re-apply baseline: `ansible-playbook --check` then `--diff` |

### 8.2 Deviation Resolution Process

1. **Detect**: AIDE, ArgoCD, CI pipeline, or manual inspection identifies deviation
2. **Assess**: Determine if deviation is authorized (known change) or unauthorized
3. **Authorized deviation**: Update baseline to match (git commit documenting the change)
4. **Unauthorized deviation**: 
   - Revert to baseline (Ansible apply, ArgoCD sync, or manual restore)
   - Investigate root cause
   - If malicious, escalate to Incident Response Plan
5. **Document**: Record deviation and resolution in git commit message

### 8.3 Exceptions

Documented exceptions to baseline configurations:
- Emergency changes during incident response (documented retroactively)
- Temporary debug configurations (must be removed within 24 hours)
- Hardware-specific configurations that vary per host

All exceptions must be documented in the git commit that introduces them.

---

## 9. Plan Maintenance

| Activity | Frequency | Next Due |
|----------|-----------|----------|
| CMP review and update | Quarterly | 2026-05-07 |
| Baseline validation (Ansible check mode) | Monthly | 2026-03-07 |
| AIDE baseline refresh | After approved changes | As needed |
| Component lifecycle review | Monthly | 2026-03-07 |
| Tool version updates | As released | Ongoing |

---

## Document Control

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-02-07 | Compliance Team | Initial CM Plan per NIST 800-53 CM-9 |

---

*Generated 2026-02-07 | NIST SP 800-53 Rev 5 | Control: CM-9*
