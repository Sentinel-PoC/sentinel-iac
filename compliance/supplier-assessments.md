# Supplier / Vendor Assessment (SR-6)

**Document ID**: ASSESS-SR-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This document provides a structured assessment of all third-party suppliers and vendors whose products or services are used by the Overwatch Platform. Each assessment evaluates the vendor's trust level, risks, and available alternatives to support informed supply chain risk decisions.

## 2. Assessment Methodology

Each vendor is assessed on:

- **Trust Level**: High / Medium / Low — based on vendor maturity, security track record, and data exposure
- **Data Exposure**: What platform data the vendor can access
- **Licensing**: Open source vs. proprietary, license type
- **Alternatives**: Viable replacement options if the vendor becomes unavailable or compromised
- **Risk Notes**: Specific risks relevant to the Overwatch Platform deployment

---

## 3. Vendor Assessments

### 3.1 Proxmox Server Solutions — Proxmox VE

| Field | Assessment |
|-------|-----------|
| **Component** | Proxmox VE 8.x (Hypervisor) |
| **Trust Level** | High |
| **Licensing** | AGPLv3 (open source), optional commercial subscription |
| **Data Exposure** | Full — hypervisor has access to all VM/LXC data and memory |
| **Security Record** | Mature project (since 2008), Debian-based, regular security updates, CVE response process |
| **Deployment** | 3 bare-metal hosts (pve, 208-pve2, pve3), cluster mode |
| **Risk Notes** | Hypervisor compromise = total platform compromise. Physical access required for host-level attacks. No external management exposure. |
| **Mitigations** | Physical security of hosts, API token scoping (Vault-managed), no Proxmox web UI exposed externally |
| **Alternatives** | VMware ESXi (proprietary, expensive), XCP-ng (open source), bare-metal Kubernetes |
| **Assessment** | Appropriate choice. Open-source transparency, strong community, enterprise-grade features. Risk is inherent to any hypervisor. |

### 3.2 Red Hat / OKD Community — OKD 4.19

| Field | Assessment |
|-------|-----------|
| **Component** | OKD 4.19 (Container platform / Kubernetes distribution) |
| **Trust Level** | High |
| **Licensing** | Apache 2.0 (OKD community), based on Red Hat OpenShift |
| **Data Exposure** | High — runs all containerized workloads, manages cluster secrets |
| **Security Record** | Backed by Red Hat engineering, inherits RHEL CoreOS security posture, SELinux enforcing, SCC policies |
| **Deployment** | 3-node compact cluster (master-1/2/3) on 208-pve2 |
| **Risk Notes** | Community project — no commercial support SLA. OKD releases may lag OpenShift. Cluster upgrade complexity is high. |
| **Mitigations** | etcd backups (daily), Proxmox snapshots, ArgoCD GitOps for workload recovery, anyuid SCC (not privileged) for workloads |
| **Alternatives** | Vanilla Kubernetes (k3s, kubeadm), OpenShift (commercial), Nomad |
| **Assessment** | Good choice for portfolio demonstration. Red Hat upstream quality with no license cost. Community support is adequate for homelab. |

### 3.3 HashiCorp — Vault

| Field | Assessment |
|-------|-----------|
| **Component** | HashiCorp Vault 1.21.2 (Secrets management, SSH CA) |
| **Trust Level** | High |
| **Licensing** | BSL 1.1 (source-available, free for non-competing use) |
| **Data Exposure** | Critical — stores all platform secrets (API tokens, SSH keys, encryption keys) |
| **Security Record** | Industry standard for secrets management, regular security audits, active CVE process, SOC 2 compliant organization |
| **Deployment** | Docker container on vault-server (VM 205), Shamir unseal (3-of-5), audit logging enabled |
| **Risk Notes** | BSL license restricts competitive use (not relevant for homelab). Vault compromise = all secrets exposed. Single instance (no HA). |
| **Mitigations** | Shamir unseal keys in Proton Pass, daily encrypted backups to MinIO/B2, audit logging, scoped policies (claude-automation = read-only), JiT SSH certificates |
| **Alternatives** | CyberArk Conjur (open source), SOPS (file-based), AWS Secrets Manager (cloud), age/GPG (manual) |
| **Assessment** | Best-in-class for the use case. BSL license is acceptable for homelab. Audit logging and Shamir unseal provide strong security posture. |

### 3.4 GitLab Inc. — GitLab CE

| Field | Assessment |
|-------|-----------|
| **Component** | GitLab CE Omnibus (Source control, CI/CD) |
| **Trust Level** | High |
| **Licensing** | MIT (Community Edition) |
| **Data Exposure** | High — stores all source code, CI/CD pipeline definitions, runner execution |
| **Security Record** | Monthly security releases, transparent CVE process, bug bounty program, widely audited |
| **Deployment** | Self-hosted on gitlab-server (VM 201), local network only |
| **Risk Notes** | Self-hosted CE lacks some security features of EE (audit streaming, advanced SAST). Large attack surface (Rails app). |
| **Mitigations** | Not exposed externally (local DNS only), PAT rotation schedule, weekly backups, gitleaks pipeline gate |
| **Alternatives** | Gitea (lightweight), GitHub (cloud), Forgejo (community fork) |
| **Assessment** | Comprehensive CI/CD platform appropriate for the complexity of this deployment. CE feature set is sufficient. |

### 3.5 MinIO Inc. — MinIO

| Field | Assessment |
|-------|-----------|
| **Component** | MinIO (S3-compatible object storage) |
| **Trust Level** | High |
| **Licensing** | AGPLv3 (open source) |
| **Data Exposure** | High — stores all backups (Vault, GitLab, etcd), Terraform state |
| **Security Record** | Well-tested, simple architecture, regular releases, used by major organizations |
| **Deployment** | Primary (LXC 301 on pve3), Replica (LXC 302 on pve), rclone sync to B2 |
| **Risk Notes** | Single-node deployment (not distributed mode). LXC containers cannot be Terraform-managed. |
| **Mitigations** | Replica on separate Proxmox host, B2 offsite encrypted backup, access keys rotated and stored in Vault |
| **Alternatives** | Ceph (distributed, complex), SeaweedFS (distributed), local NFS (simple) |
| **Assessment** | Excellent fit for homelab S3-compatible storage. Simple, reliable, performant. Replication strategy compensates for single-node deployment. |

### 3.6 Backblaze Inc. — Backblaze B2

| Field | Assessment |
|-------|-----------|
| **Component** | Backblaze B2 Cloud Storage (Offsite backup) |
| **Trust Level** | High |
| **Licensing** | Commercial cloud service |
| **Data Exposure** | None (effective) — all data encrypted client-side with rclone crypt (AES-256) before upload |
| **Security Record** | SOC 2 Type II compliant, established storage provider since 2007, transparent infrastructure |
| **Deployment** | rclone crypt → B2 bucket, daily sync from MinIO primary |
| **Risk Notes** | Vendor lock-in is low (S3-compatible API). Data is encrypted at rest with keys Backblaze never sees. |
| **Mitigations** | Client-side encryption (rclone crypt), encryption keys stored separately (Vault + Proton Pass), B2 does not have decryption capability |
| **Alternatives** | Wasabi, AWS S3 Glacier, rsync.net, self-hosted offsite NAS |
| **Assessment** | Cost-effective offsite backup with strong encryption. Zero-knowledge architecture (client-side encryption) eliminates data exposure risk. |

### 3.7 Cloudflare Inc. — Cloudflare DNS

| Field | Assessment |
|-------|-----------|
| **Component** | Cloudflare DNS (DNS management, Let's Encrypt DNS-01 validation) |
| **Trust Level** | High |
| **Licensing** | Commercial cloud service (free tier) |
| **Data Exposure** | Low — DNS records only, no traffic proxied (DNS-only mode) |
| **Security Record** | Major infrastructure provider, SOC 2 compliant, transparent incident reporting |
| **Deployment** | DNS-scoped API token for `208.haist.farm` zone, used by Traefik for Let's Encrypt DNS-01 |
| **Risk Notes** | DNS compromise could redirect traffic. API token is DNS-scoped only (cannot access other Cloudflare services). Public A records deleted (SC-7(16)) — wildcard resolves locally only. |
| **Mitigations** | Minimum-privilege API token (DNS edit only for one zone), token rotation, separate admin token for management |
| **Alternatives** | Self-hosted DNS (BIND, PowerDNS), Route 53, DigitalOcean DNS |
| **Assessment** | Industry-standard DNS with excellent API. Minimal data exposure. Scoped token limits blast radius. |

### 3.8 Pangolin Project — Pangolin + Traefik

| Field | Assessment |
|-------|-----------|
| **Component** | Pangolin (tunnel management) + Traefik 3.x (reverse proxy) |
| **Trust Level** | Medium |
| **Licensing** | Open source (Pangolin), Apache 2.0 (Traefik) |
| **Data Exposure** | Medium — reverse proxy sees all HTTP traffic for routed services |
| **Security Record** | Traefik is well-established (CNCF project). Pangolin is a newer, smaller project with less audit history. |
| **Deployment** | pangolin-proxy VM (107, 192.168.12.168), Traefik with Let's Encrypt wildcard cert, Newt tunnels for OKD |
| **Risk Notes** | Pangolin is less mature than alternatives. Newt credential rotation requires paid tier. Reverse proxy is a high-value target. |
| **Mitigations** | No management UI exposed externally, TLS enforced on all routes, Traefik access logs, firewall rules on Proxmox |
| **Alternatives** | Nginx Proxy Manager, Caddy, Cloudflare Tunnel (commercial), WireGuard + HAProxy |
| **Assessment** | Functional for the use case. Traefik is production-grade. Pangolin adds tunnel convenience but is the least mature component. Monitor for security updates. |

### 3.9 Proton AG — ProtonVPN

| Field | Assessment |
|-------|-----------|
| **Component** | ProtonVPN WireGuard (VPN tunnel for seedbox) |
| **Trust Level** | High |
| **Licensing** | Commercial VPN service |
| **Data Exposure** | Low — only seedbox download traffic routes through VPN, no platform management data |
| **Security Record** | Swiss privacy laws, open-source clients, independent audits, established provider |
| **Deployment** | WireGuard tunnel via gluetun container on seedbox-vm (VM 109) |
| **Risk Notes** | VPN failure = seedbox traffic on local IP. Kill switch (gluetun) prevents this. |
| **Mitigations** | gluetun kill switch (blocks traffic if VPN drops), isolated to seedbox VM only, no platform data exposure |
| **Alternatives** | Mullvad, IVPN, self-hosted WireGuard |
| **Assessment** | Appropriate for seedbox use case. Strong privacy track record. Isolated deployment limits risk to non-critical workload. |

---

## 4. Assessment Summary

| Vendor | Component | Trust | Risk Level | Action |
|--------|-----------|-------|-----------|--------|
| Proxmox | Hypervisor | High | Accepted | Monitor advisories |
| Red Hat/OKD | Container platform | High | Accepted | Track releases, maintain backups |
| HashiCorp | Vault | High | Accepted | Keep current, audit logging |
| GitLab | CI/CD + SCM | High | Accepted | Monthly security updates |
| MinIO | Object storage | High | Accepted | Maintain replica + B2 sync |
| Backblaze | Offsite backup | High | Accepted | Client-side encryption verified |
| Cloudflare | DNS | High | Accepted | Scoped tokens, rotation |
| Pangolin/Traefik | Reverse proxy | Medium | Accepted with monitoring | Watch for security updates |
| ProtonVPN | VPN tunnel | High | Accepted | Isolated to seedbox only |

**Overall Supply Chain Risk**: **Low-Medium** — All critical components are from established vendors with strong security records. The highest-risk component (Pangolin) is limited to the reverse proxy role with no direct data access. Client-side encryption for offsite backups eliminates cloud provider trust requirements.

## 5. Review Schedule

- This document SHALL be reviewed annually by the system owner.
- Individual vendor assessments SHALL be updated when:
  - A component is upgraded to a new major version
  - A vendor experiences a significant security incident
  - A new component is added to the platform
  - A vendor changes licensing terms

## 6. References

- NIST SP 800-53 Rev 5: SR-6 (Supplier Assessments and Reviews)
- NIST SP 800-161 Rev 1: Cybersecurity Supply Chain Risk Management
- Supply Chain Risk Management Plan (`compliance/supply-chain-risk-management-plan.md`)
- Component Lifecycle Tracker (`compliance/component-lifecycle.md`)
