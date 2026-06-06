# Component Lifecycle Tracker
## Overwatch Platform — NIST SP 800-53 Rev 5

**Document Classification**: INTERNAL — FOR PORTFOLIO USE
**Created**: 2026-02-07
**System**: Overwatch Platform (OKD 4.19 on Proxmox)
**Owner**: Haists Consulting
**Control Addressed**: SA-22 (Unsupported System Components)

---

## 1. Purpose

This document tracks all software components in the Overwatch Platform, their versions, release dates, end-of-life dates, and risk levels. It ensures that unsupported components are identified, assessed, and remediated in a timely manner.

## 2. Review Schedule

| Activity | Frequency | Next Due |
|----------|-----------|----------|
| Version audit (verify installed versions) | Monthly | 2026-03-07 |
| EOL date review | Monthly | 2026-03-07 |
| Component update planning | Quarterly | 2026-05-07 |

---

## 3. Component Inventory

### 3.1 Operating Systems

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Ubuntu (iac-control) | 24.04 LTS | 2024-04-25 | 2029-04-25 (standard), 2034-04 (ESM) | LOW | Long-term support. Regular `apt upgrade` maintenance. |
| Ubuntu (GitLab server) | 24.04 LTS | 2024-04-25 | 2029-04-25 | LOW | Same as above. |
| Fedora CoreOS (OKD nodes) | Stream | Rolling release | N/A (rolling) | LOW | Auto-updates via OKD machine-config-operator. |
| Debian 12 Bookworm (Proxmox) | 12 | 2023-06-10 | 2026-06 (EOL), 2028-06 (LTS) | MEDIUM | Proxmox VE 8 tied to Debian 12 lifecycle. |

### 3.2 Hypervisor / Platform

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Proxmox VE | 8.x | 2023-06 | ~2026-08 (when PVE 9 is 1yr old) | MEDIUM | PVE 9 released Nov 2025. Upgrade to PVE 9 recommended before mid-2026. |
| OKD | 4.19 | 2025-06-17 | 2026-12-17 (maintenance support) | LOW | Based on OpenShift 4.19 lifecycle. Next LTS: evaluate 4.20+. |

### 3.3 Core Infrastructure Services

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| HashiCorp Vault | 1.21.2 | 2025-04-02 (1.21.0) | ~2026-10 (est.) | LOW | Upgraded from 1.15.4 (EOL) to 1.21.2 on 2026-02-08. Actively supported. |
| GitLab CE | 18.8.2 | 2026-01-15 (18.8.0) | 2026-04-16 | MEDIUM | Maintenance support active. Update monthly to stay current. |
| MinIO | Latest | Rolling release | N/A (rolling, AGPL) | LOW | Community edition, rolling releases. Keep updated. |
| HAProxy | 2.x (system pkg) | TBD - verify | Per Ubuntu LTS | LOW | Ubuntu LTS provides security patches. |
| Squid | 6.x (system pkg) | TBD - verify | Per Ubuntu LTS | LOW | Ubuntu LTS provides security patches. |
| dnsmasq | 2.9x (system pkg) | TBD - verify | Per Ubuntu LTS | LOW | Ubuntu LTS provides security patches. |

### 3.4 Container & Orchestration

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Docker CE (Vault host) | TBD - verify | N/A | Ongoing | LOW | Keep updated via apt. |
| Podman (OKD nodes) | Bundled with FCOS | N/A | Per FCOS lifecycle | LOW | Managed by OKD updates. |
| ArgoCD | TBD - verify (OKD operator) | N/A | Per operator channel | LOW | Managed by OKD OpenShift GitOps operator. |

### 3.5 Monitoring Stack

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Grafana | TBD - verify (11.x) | N/A | ~18 months from release | LOW | Check version in OKD. Latest stable: 11.6.x. |
| Loki | TBD - verify (3.x) | N/A | Support for last 2 minors | MEDIUM | If below 3.5, upgrade needed. |
| Promtail | TBD - verify | N/A | Matches Loki lifecycle | MEDIUM | Same version as Loki recommended. |

### 3.6 Reverse Proxy / Ingress

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Traefik (Pangolin) | TBD - verify (3.x) | N/A | Only latest minor supported | MEDIUM | Check version. If below 3.6, update recommended. |
| OKD Router (HAProxy) | Bundled with OKD | N/A | Per OKD lifecycle | LOW | Managed by OKD. |

### 3.7 Security & DevOps Tools (on iac-control)

| Component | Installed Version | Release Date | EOL Date | Risk | Notes |
|-----------|------------------|-------------|----------|------|-------|
| Trivy | 0.69.1 | ~2025 | N/A (rolling) | LOW | Update quarterly. CVE database auto-updates on each CI run. |
| tflint | 0.61.0 | ~2025 | N/A (rolling) | LOW | Update when new Terraform providers need support. |
| gitleaks | 8.30.0 | ~2025 | N/A (rolling) | LOW | Update quarterly for latest detection rules. |
| yamllint | 1.38.0 | ~2025 | N/A (rolling, Python) | LOW | Stable tool, infrequent updates needed. |
| ansible-lint | 6.17.2 | ~2023 | N/A | LOW | Works with current Ansible version. |
| Ansible-core | 2.17+ | TBD - verify | ~2 years from release | LOW | Check version. Ubuntu 24.04 ships 2.16. |
| OpenTofu | 1.x | TBD - verify | N/A (FOSS fork) | LOW | Active development. Check version on server. |
| AIDE | System package | N/A | Per Ubuntu LTS | LOW | Ubuntu LTS provides security patches. |

---

## 4. Risk Assessment

### 4.1 Risk Levels

| Risk Level | Definition | Action Required |
|------------|-----------|----------------|
| **CRITICAL** | Component is past EOL, no security patches available | Upgrade within 30 days or implement compensating controls |
| **HIGH** | Component EOL within 3 months | Plan and schedule upgrade |
| **MEDIUM** | Component EOL within 6 months, or version significantly behind latest | Schedule upgrade in next maintenance window |
| **LOW** | Component actively supported with 6+ months remaining | Monitor for updates, apply security patches |

### 4.2 Current Critical Items

| Component | Issue | Remediation | Target Date |
|-----------|-------|-------------|-------------|
| ~~Vault 1.15.4~~ | RESOLVED — Upgraded to 1.21.2 on 2026-02-08 | Docker image swapped, unsealed, health verified, all secrets and SSH CA operational | CLOSED |
| **Proxmox VE 8** | EOL ~mid-2026. PVE 9 available. | Plan upgrade to PVE 9 (Debian 13). Requires maintenance window per host. | 2026-Q2 |

### 4.3 Compensating Controls for EOL Components

~~**Vault 1.15.4**~~ (RESOLVED — upgraded to 1.21.2 on 2026-02-08):
- Network isolation: Vault only accessible from iac-control (iptables FORWARD rules)
- No direct internet access (behind Squid proxy)
- Vault audit logging enabled (monitors all API calls)
- JIT SSH certificates limit credential exposure (30-min TTL)
- Regular backup to MinIO → B2 enables rapid rebuild if compromised
- Read-only automation policy limits blast radius

---

## 5. Update Procedures

### 5.1 Ubuntu Packages (iac-control, GitLab)

```bash
# Check for updates
sudo apt update && apt list --upgradable

# Apply updates (schedule maintenance window for kernel updates)
sudo apt upgrade -y

# Reboot if kernel updated
sudo reboot
```

### 5.2 Vault Upgrade

```bash
# On vault server (192.168.12.206)
# 1. Backup current data
docker exec vault vault operator raft snapshot save /vault/data/backup.snap

# 2. Update docker-compose.yml image tag
# 3. docker compose pull && docker compose up -d
# 4. Unseal with Shamir keys
# 5. Verify health: curl http://localhost:8200/v1/sys/health
```

### 5.3 GitLab Upgrade

```bash
# On GitLab server (192.168.12.68)
sudo apt update
sudo apt install gitlab-ce
# GitLab auto-runs migrations on restart
```

### 5.4 OKD Upgrade

OKD cluster upgrades follow the OpenShift update process:
```bash
oc adm upgrade --to=<version>
# Monitor: oc get clusterversion
```

### 5.5 Proxmox VE Upgrade

Follow official Proxmox VE upgrade guide. Upgrade one host at a time:
1. Backup all VMs on the host
2. Follow `pve7to8` or `pve8to9` checklist
3. Run upgrade
4. Verify all VMs start correctly
5. Proceed to next host

---

## 6. Version Verification Commands

Run these commands to verify current installed versions:

```bash
# iac-control (192.168.12.210)
ssh ubuntu@192.168.12.210 "
  lsb_release -ds                    # Ubuntu version
  haproxy -v | head -1               # HAProxy version
  squid --version | head -1          # Squid version
  dnsmasq --version | head -1        # dnsmasq version
  ansible --version | head -1        # Ansible version
  tofu version 2>/dev/null || terraform version | head -1  # OpenTofu/Terraform
  trivy --version                    # Trivy version
  tflint --version                   # tflint version
  gitleaks version                   # gitleaks version
  aide --version 2>&1 | head -1      # AIDE version
"

# Vault (192.168.12.206)
ssh root@192.168.12.206 "docker exec vault vault version"

# GitLab (192.168.12.68)
ssh koiakoia@192.168.12.68 "cat /opt/gitlab/version-manifest.txt | head -1"

# Proxmox hosts
ssh root@192.168.12.6 "pveversion"
ssh root@192.168.12.56 "pveversion"
ssh root@192.168.12.57 "pveversion"

# OKD
oc version  # Client and server versions

# Grafana/Loki (from OKD)
oc get pods -n monitoring -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
```

---

## Document Control

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-02-07 | Compliance Team | Initial component lifecycle inventory |
| 1.1 | 2026-02-08 | Compliance Team | Vault upgraded 1.15.4 to 1.21.2 (Session 6). Critical EOL resolved. No EOL components remaining. |

---

*Generated 2026-02-07 | Updated 2026-02-08 | NIST SP 800-53 Rev 5 | Control: SA-22*
