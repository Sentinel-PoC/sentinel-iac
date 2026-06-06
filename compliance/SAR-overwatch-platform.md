# Security Assessment Report (SAR)
## Overwatch Platform — NIST 800-53 Rev 5 Moderate Baseline

**Document Classification**: INTERNAL — FOR PORTFOLIO USE
**Assessment Date**: 2026-02-06
**System Name**: Overwatch Platform (OKD 4.19 on Proxmox)
**System Owner**: Haists Consulting
**Assessment Methodology**: Live system inspection (READ-ONLY), documentation review, API interrogation
**Baseline**: NIST SP 800-53 Rev 5, Moderate Impact

---

## Table of Contents
1. [Executive Summary](#1-executive-summary)
2. [System Description](#2-system-description)
3. [Assessment Scope and Methodology](#3-assessment-scope-and-methodology)
4. [Results Summary](#4-results-summary)
5. [Detailed Control Assessments by Family](#5-detailed-control-assessments-by-family)
   - 5.1 [AC — Access Control](#51-ac--access-control)
   - 5.2 [AT — Awareness and Training](#52-at--awareness-and-training)
   - 5.3 [AU — Audit and Accountability](#53-au--audit-and-accountability)
   - 5.4 [CA — Assessment, Authorization, and Monitoring](#54-ca--assessment-authorization-and-monitoring)
   - 5.5 [CM — Configuration Management](#55-cm--configuration-management)
   - 5.6 [CP — Contingency Planning](#56-cp--contingency-planning)
   - 5.7 [IA — Identification and Authentication](#57-ia--identification-and-authentication)
   - 5.8 [IR — Incident Response](#58-ir--incident-response)
   - 5.9 [MA — Maintenance](#59-ma--maintenance)
   - 5.10 [MP — Media Protection](#510-mp--media-protection)
   - 5.11 [PE — Physical and Environmental Protection](#511-pe--physical-and-environmental-protection)
   - 5.12 [PL — Planning](#512-pl--planning)
   - 5.13 [PM — Program Management](#513-pm--program-management)
   - 5.14 [PS — Personnel Security](#514-ps--personnel-security)
   - 5.15 [PT — PII Processing and Transparency](#515-pt--pii-processing-and-transparency)
   - 5.16 [RA — Risk Assessment](#516-ra--risk-assessment)
   - 5.17 [SA — System and Services Acquisition](#517-sa--system-and-services-acquisition)
   - 5.18 [SC — System and Communications Protection](#518-sc--system-and-communications-protection)
   - 5.19 [SI — System and Information Integrity](#519-si--system-and-information-integrity)
   - 5.20 [SR — Supply Chain Risk Management](#520-sr--supply-chain-risk-management)
6. [Risk Analysis and Prioritized Findings](#6-risk-analysis-and-prioritized-findings)
7. [Recommendations](#7-recommendations)
8. [Appendix A — Scoping Justifications](#appendix-a--scoping-justifications)
9. [Appendix B — Evidence Sources](#appendix-b--evidence-sources)

---

## 1. Executive Summary

### Overview

This Security Assessment Report (SAR) presents the results of a comprehensive assessment of the Overwatch Platform against the NIST SP 800-53 Rev 5 Moderate baseline. The assessment covered all 20 control families and evaluated **366 individual controls** through live system inspection of all infrastructure components.

### System Context

The Overwatch Platform is a hybrid-cloud container orchestration environment built on OKD 4.19 (Kubernetes) running across three Proxmox hypervisors in a private datacenter environment. The platform demonstrates enterprise-grade security architecture patterns including:

- **Zero-trust external access** via Cloudflare Tunnel with Keycloak SSO authentication (Sprint 22)
- **Centralized identity management** via Keycloak SSO with 4 OIDC clients (OKD, ArgoCD, Grafana, Cloudflare Access)
- **Network micro-segmentation** with isolated OKD cluster (10.0.0.0/24) behind a hardened gateway
- **Just-in-Time SSH certificates** via HashiCorp Vault (30-minute TTL)
- **Defense-in-depth** with layered firewalling, egress proxy, and centralized logging
- **Infrastructure as Code** with GitLab CI/CD, Ansible, and Terraform/OpenTofu
- **Network monitoring** via UniFi Network integration with Prometheus/Grafana (Sprint 21)

### Assessment Results at a Glance

| Rating | Count | Percentage | Description |
|--------|-------|------------|-------------|
| **Compliant** | **~185** | **~51%** | Control fully implemented and operating effectively |
| **Partial** | **~64** | **~17%** | Control partially implemented; gaps identified |
| **Non-Compliant** | **~27** | **~7%** | Control not implemented or significant gaps |
| **Not Applicable** | **70** | **19%** | Control scoped out with documented justification |
| **Inherited** | **15** | **4%** | Control satisfied by physical environment |
| **Pending (RA-5)** | **5** | **1%** | Blocked by prerequisite (vulnerability scanning) |
| **TOTAL** | **366** | **100%** | |

### Effective Compliance Rate

Of the **276 applicable controls** (excluding N/A, Inherited, and Pending):
- **Compliant**: ~185 (~67%)
- **Partial**: ~64 (~23%)
- **Non-Compliant**: ~27 (~10%)
- **Compliant + Partial**: ~249 (~90%)

### Key Strengths

1. **Exceptional network boundary protection** — SC family scores 77% compliant (24/31), with iac-control as sole gateway, deny-by-default firewall, Cloudflare Zero Trust external access with Keycloak SSO
2. **Strong cryptographic posture** — Modern TLS 1.3, ChaCha20-Poly1305, post-quantum KEX (sntrup761x25519), FIPS-capable algorithms throughout
3. **Certificate-based authentication** — Vault SSH CA with automatic expiration eliminates credential persistence
4. **Comprehensive security monitoring** — Wazuh SIEM with 9 agents across all VMs, 77+ custom rules, Active Response, Discord alerting, UniFi network monitoring via Prometheus/Grafana
5. **Centralized identity and access management** — Keycloak SSO with OIDC federation to OKD, ArgoCD, Grafana, and Cloudflare Access; group-based RBAC (admin/operator/viewer)
6. **Proper scoping** — 72 controls appropriately scoped out (no PII, single operator, no employees) with documented justification

### Key Gaps

1. **Multi-Factor Authentication** — Keycloak supports MFA (TOTP/WebAuthn) but not yet enforced for all users; admin group should require MFA for privileged access (IA-2(1)).
2. **Configuration Management** — CM plan in place, Ansible coverage expanding, AIDE FIM active, Kyverno policy engine enforcing 5 cluster policies. Remaining: full IaC coverage (P3-2).
3. **Contingency Planning** — DR Runbook, automated backup/restore, and validated DR testing now in place. Remaining gaps: recurring DR test schedule (CP-4), alternate site testing (CP-4(1)/CP-4(2)).
4. **Supply Chain** — SCRM plan and vendor assessments complete. Remaining: component provenance verification.
5. **Incident Response** — IRP created. Wazuh SIEM operational with 9 agents, 77+ custom rules, Active Response, Discord alerting for level 10+ events.
6. **Vulnerability Management** — Wazuh vulnerability detection active (23,198 records baselined). Host-level OpenVAS scanning still needed.
7. **Privileged Access Controls** — Vault root token exposure (AC-6(1)), anyuid SCC usage for Postgres/seedbox needs review for least privilege compliance.

---

## 2. System Description

### 2.1 Architecture Overview

```
                    ┌──────────────────────────────────────────────┐
                    │              EXTERNAL ACCESS                  │
                    │   Pangolin Zero-Trust Tunnel (pangolin.net)   │
                    │   SSO Passkey Authentication Required         │
                    └──────────────────┬───────────────────────────┘
                                       │ WireGuard (ChaCha20-Poly1305)
                    ┌──────────────────▼───────────────────────────┐
                    │         MANAGEMENT LAN (192.168.12.0/24)      │
                    │                                               │
                    │  ┌─────────┐  ┌─────────┐  ┌──────────────┐ │
                    │  │ GitLab  │  │  Vault   │  │  Trusted     │ │
                    │  │ .68     │  │  .206    │  │  Pangolin    │ │
                    │  │ CI/CD   │  │  SSH CA  │  │  .168        │ │
                    │  │ Source  │  │  Secrets │  │  Traefik     │ │
                    │  └─────────┘  └─────────┘  └──────────────┘ │
                    │                                               │
                    │  ┌─────────┐  ┌──────────────────────────┐   │
                    │  │ MinIO   │  │  seedbox-vm (.69/pve3)   │   │
                    │  │ .58     │  │  qBittorrent + gluetun   │   │
                    │  │ S3/B2   │  │  ProtonVPN WireGuard     │   │
                    │  └─────────┘  └──────────────────────────┘   │
                    │                                               │
                    │  ┌────────────────────────────────────────┐   │
                    │  │  PROXMOX HYPERVISORS                   │   │
                    │  │  pve (.6) | 208-pve2 (.56) | pve3 (.57)│   │
                    │  └────────────────────────────────────────┘   │
                    └──────────────────┬───────────────────────────┘
                                       │
                    ┌──────────────────▼───────────────────────────┐
                    │     iac-control (.210 mgmt / 10.0.0.1 OKD)   │
                    │     ═══════════════════════════════════════   │
                    │     SOLE GATEWAY — SECURITY BOUNDARY          │
                    │     HAProxy | Squid | iptables | dnsmasq      │
                    │     socat :18080→.69:8080 (seedbox proxy)    │
                    │     13 INPUT + 22 FORWARD rules (DROP default)│
                    └──────────────────┬───────────────────────────┘
                                       │ vmbr1 (isolated bridge)
                    ┌──────────────────▼───────────────────────────┐
                    │         OKD CLUSTER (10.0.0.0/24)             │
                    │              NO DIRECT INTERNET                │
                    │                                               │
                    │  ┌──────────┐ ┌──────────┐ ┌──────────┐     │
                    │  │master-1  │ │master-2  │ │master-3  │     │
                    │  │10.0.0.221│ │10.0.0.222│ │10.0.0.223│     │
                    │  │12c/32GB  │ │12c/32GB  │ │12c/32GB  │     │
                    │  └──────────┘ └──────────┘ └──────────┘     │
                    │                                               │
                    │  Services: Grafana, Sonarr, Radarr, Prowlarr  │
                    │  Seedbox arr stack (anyuid SCC, no privileged)│
                    │  Networking: OVNKubernetes, HAProxy Ingress   │
                    │  Storage: NFS PVs (192.168.12.205:2049)       │
                    └──────────────────────────────────────────────┘
```

### 2.2 Component Inventory

| VMID | Name | IP | OS | Purpose | Hypervisor |
|------|------|----|----|---------|------------|
| 200 | iac-control | 192.168.12.210 / 10.0.0.1 | Ubuntu 24.04.3 LTS | Gateway, IaC orchestration, socat proxy | pve |
| 201 | gitlab-server | 192.168.12.68 | Ubuntu 24.04.3 LTS | GitLab CE 18.8.2, CI/CD | 208-pve2 |
| 109 | seedbox-vm | 192.168.12.69 | Ubuntu | qBittorrent + gluetun VPN (Docker) | pve3 |
| 205 | vault-server | 192.168.12.206 | Ubuntu | HashiCorp Vault, SSH CA | pve |
| 300 | config-server | 10.0.0.2 | LXC | DHCP/Config for OKD | pve |
| 301 | minio-bootstrap | 192.168.12.58 | LXC | MinIO S3 + B2 backup (primary) | pve3 |
| 302 | minio-replica | 192.168.12.59 | LXC | MinIO S3 replica (cross-site) | pve |
| — | master-1 | 10.0.0.221 | SCOS 9.0 | OKD control plane | 208-pve2 |
| — | master-2 | 10.0.0.222 | SCOS 9.0 | OKD control plane | pve3 |
| — | master-3 | 10.0.0.223 | SCOS 9.0 | OKD control plane | pve |

### 2.3 Security Categorization (FIPS 199)

| Dimension | Rating | Justification |
|-----------|--------|---------------|
| **Confidentiality** | Low | No PII, no regulated data. Infrastructure telemetry and media content only. |
| **Integrity** | Moderate | IaC correctness and configuration integrity critical to platform stability. |
| **Availability** | Low | Private platform, not providing critical services to external parties. |

**Overall Impact Level**: **Moderate** (highest watermark)

---

## 3. Assessment Scope and Methodology

### 3.1 Scope

- **All 20 NIST 800-53 Rev 5 control families** assessed
- **366 individual controls** evaluated against the Moderate impact baseline
- **All infrastructure components** inspected (iac-control, GitLab, Vault, Pangolin, OKD masters, Proxmox)

### 3.2 Methodology

| Method | Description |
|--------|-------------|
| **SSH Inspection** | Vault-signed certificates used to SSH to each host; examined sshd_config, iptables, AppArmor, packages, log files, crontabs |
| **API Interrogation** | Vault API for auth/audit config; OKD API (oc commands) for RBAC, SCC, operators, cluster config |
| **Git Repository Analysis** | sentinel-iac repo inspected for Ansible playbooks, CI/CD pipelines, compliance artifacts |
| **Documentation Review** | SSP, network-hardening-docs.md, break-glass procedures, rollback scripts reviewed |
| **Network Testing** | TLS cipher verification, DNS resolution testing, firewall rule analysis |
| **Log Analysis** | Loki/Promtail configuration, Grafana alert rules, log retention policies examined |

### 3.3 Assessment Team

| Assessor | Scope | Controls Assessed |
|----------|-------|-------------------|
| ac-ia-auditor | Access Control, Identification & Authentication | 61 |
| au-ir-auditor | Audit & Accountability, Incident Response | 39 |
| cm-cp-ma-auditor | Configuration Management, Contingency Planning, Maintenance | 71 |
| sc-auditor | System & Communications Protection | 31 |
| si-ra-auditor | System & Information Integrity, Risk Assessment | 30 |
| governance-auditor | PL, PM, SA, SR, AT, PS, PE, PT, MP, CA | 134 |

### 3.4 Scoping Decisions

Controls were scoped using the following categories:
- **N/A (Not Applicable)**: Control does not apply to the system context (e.g., PT family when no PII is processed)
- **Inherited**: Control satisfied by the physical environment (e.g., PE controls in residential setting)

Detailed scoping justifications are provided in [Appendix A](#appendix-a--scoping-justifications).

---

## 4. Results Summary

### 4.1 Overall Results by Rating

| Rating | Count | % of Total | % of Applicable |
|--------|-------|------------|-----------------|
| Compliant | ~185 | 51% | 67% |
| Partial | ~64 | 17% | 23% |
| Non-Compliant | ~27 | 7% | 10% |
| Not Applicable | 70 | 19% | — |
| Inherited | 15 | 4% | — |
| Pending | 5 | 1% | — |
| **TOTAL** | **366** | **100%** | |

### 4.2 Results by Control Family

| Family | Total | Compliant | Partial | Non-Compliant | N/A | Inherited |
|--------|-------|-----------|---------|---------------|-----|-----------|
| **AC** (Access Control) | 40 | 12 | 17 | 6 | 5 | 0 |
| **AT** (Training) | 6 | 0 | 0 | 0 | 6 | 0 |
| **AU** (Audit) | 22 | 10 | 11 | 1 | 0 | 0 |
| **CA** (Assessment) | 11 | 3 | 6 | 2 | 0 | 0 |
| **CM** (Config Mgmt) | 30 | 5 | 14 | 8 | 1 | 0 |
| **CP** (Contingency) | 29 | 19 | 3 | 5 | 2 | 0 |
| **IA** (Auth) | 21 | 8 | 9 | 1 | 3 | 0 |
| **IR** (Incident Resp) | 17 | 5 | 8 | 4 | 0 | 0 |
| **MA** (Maintenance) | 12 | 2 | 4 | 4 | 2 | 0 |
| **MP** (Media) | 8 | 0 | 3 | 4 | 1 | 0 |
| **PE** (Physical) | 23 | 0 | 8 | 0 | 0 | 15 |
| **PL** (Planning) | 8 | 4 | 2 | 0 | 2 | 0 |
| **PM** (Program Mgmt) | 22 | 4 | 5 | 3 | 10 | 0 |
| **PS** (Personnel) | 9 | 0 | 0 | 0 | 9 | 0 |
| **PT** (PII) | 13 | 0 | 0 | 0 | 13 | 0 |
| **RA** (Risk) | 10 | 4 | 4 | 1 | 1 | 0 |
| **SA** (Acquisition) | 22 | 9 | 3 | 3 | 7 | 0 |
| **SC** (Sys/Comms) | 31 | 24 | 5 | 0 | 2 | 0 |
| **SI** (Sys Integrity) | 20 | 11 | 5 | 2 | 2 | 0 |
| **SR** (Supply Chain) | 12 | 0 | 2 | 7 | 3 | 0 |
| **TOTAL** | **366** | **~185** | **~64** | **~27** | **70** | **15** |

### 4.3 Compliance Heatmap

```
Family          ████████████████████ Compliance Bar (Compliant = ■, Partial = ▒, NC = ░)
──────────────────────────────────────────────────────────────────────────
SC  (Sys/Comms) ■■■■■■■■■■■■■■■■■■■■■■■■▒▒▒▒▒                          77% ■
PL  (Planning)  ■■■■■■■■▒▒▒▒                                           67% ■
SI  (Integrity) ■■■■■■■■■■■▒▒▒▒▒░░                                     61% ■
AU  (Audit)     ■■■■■■■■■■▒▒▒▒▒▒▒▒▒▒▒░                                45% ■
IA  (Auth)      ■■■■■■■▒▒▒▒▒▒▒▒▒░░                                    39% ■
RA  (Risk)      ■■■■▒▒▒░░                                              44% ■
AC  (Access)    ■■■■■■■■■■■■▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░                  34% ■
CP  (Conting)   ■■■■■■■■■■■■■■■■■■■▒▒▒░░░░░                          70% ■
MA  (Maint)     ■■▒▒▒▒░░░░                                             25% ■
SA  (Acquis)    ■■■■■▒▒▒▒░░░░░░                                        33% ■
CA  (Assess)    ■■▒▒▒▒▒▒░░░                                            18% ■
PM  (Program)   ■■▒▒▒▒▒░░░░░                                           17% ■
IR  (Incident)  ■▒▒▒▒▒▒▒▒░░░░░░░░                                      6% ■
MP  (Media)     ▒▒▒░░░░                                                 0% ■
CM  (Config)    ■▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░░░░░░░                         3% ■
SR  (Supply)    ▒▒░░░░░░░                                               0% ■
PE  (Physical)  [15 Inherited] ▒▒▒▒▒▒▒▒                                 0% ■
AT  (Training)  [All N/A - single operator]
PS  (Personnel) [All N/A - single operator]
PT  (PII)       [All N/A - no PII processed]
```

---

## 5. Detailed Control Assessments by Family

### 5.1 AC — Access Control

**Summary**: 16 Compliant | 13 Partial | 6 Non-Compliant | 5 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| AC-1 | Policy and Procedures | Partial | SSP documents access control. No standalone AC policy. | No formal AC policy document. No review schedule. |
| AC-2 | Account Management | **Compliant** | Vault SSH CA for JIT accounts (30min-4hr TTL). Keycloak SSO provides centralized identity management with sentinel realm, group-based RBAC (admin/operator/viewer), OIDC federation to OKD/ArgoCD/Grafana. Brute force protection (5 attempts, 15-min lockout). Password policy (12-char min, complexity). | Session 17: Keycloak SSO centralizes account management across platform. |
| AC-2(1) | Automated Account Management | **Compliant** | Vault automates SSH cert lifecycle. OKD service accounts automated. Keycloak OIDC federation provides automated account provisioning — users authenticated via Keycloak are automatically provisioned in OKD, ArgoCD, and Grafana with role mappings from group claims. | Session 17: Keycloak OIDC federation automates provisioning. |
| AC-2(2) | Automated Temp/Emergency Account Removal | **Compliant** | Vault certs auto-expire. No reuse without re-signing. | None. |
| AC-2(3) | Disable Accounts | Partial | Vault cert expiry disables access automatically. | No process for compromised accounts. No dormant account detection. |
| AC-2(4) | Automated Audit Actions | Non-Compliant | No automated account lifecycle event logging. | No SIEM for account events. |
| AC-2(5) | Inactivity Logout | Compliant | TMOUT=900 on iac-control, GitLab, Vault. ClientAliveInterval=300 with ClientAliveCountMax=2 in sshd_config. | Sprint 3: Session timeouts deployed on all managed hosts. |
| AC-3 | Access Enforcement | **Compliant** | iptables network enforcement. OKD RBAC. Vault principal-based SSH. SELinux on OKD. Keycloak OIDC group claims enforce RBAC across OKD, ArgoCD, and Grafana. ArgoCD `infra` AppProject restricts cluster-scoped resource access (CM-3/AC-3). | Session 17: Keycloak RBAC + ArgoCD AppProject RBAC. |
| AC-4 | Information Flow Enforcement | **Compliant** | iptables FORWARD chain. OKD isolation. Squid proxy. | None. |
| AC-5 | Separation of Duties | Partial | AI operating model provides functional separation of duties: Human operator holds full admin (Vault root, Proxmox console), AI agent (Claude Code) operates under `claude-automation` Vault policy with read-only secrets, SSH cert signing, no write. All AI changes require human approval. | Not traditional role-based separation. Single human operator. |
| AC-6 | Least Privilege | **Compliant** | Vault principal constraints. OKD RBAC. Kyverno disallow-privileged-containers policy enforced cluster-wide. sudo logging enabled. CIS-based privilege restrictions via Ansible common role. | Session 13: Kyverno least-privilege enforcement. |
| AC-6(1) | Authorize Access to Security Functions | Partial | Vault token controls SSH CA. OKD cluster-admin restricted. | No authorization matrix. Vault root token exposed. |
| AC-6(2) | Non-Privileged Access for Nonsecurity Functions | **Compliant** | Regular users exist. OKD basic-user role. PermitRootLogin disabled on all hosts via Ansible sshd drop-in config. vault-server uses `prohibit-password` (required for Ansible connectivity as root, compensated by Vault SSH CA cert-only access). | vault-server exemption documented — prohibit-password with cert-only auth. Sprint 6: SSH hardening deployed. |
| AC-6(5) | Privileged Accounts | Partial | Time-limited Vault certs. OKD cluster-admin documented. | No MFA for privileged access. No session logging. |
| AC-6(9) | Log Privileged Functions | Non-Compliant | No sudo logging. No Vault audit device. | No centralized privilege logging. |
| AC-6(10) | Prohibit Non-Privileged Execution | **Compliant** | sudo required. OKD RBAC enforced. | None. |
| AC-7 | Unsuccessful Logon Attempts | **Compliant** | PAM faillock on hosts (5 attempts, 15min lockout, even_deny_root). Keycloak brute force protection: max 5 failures, 15-minute lockout, applies to all OIDC-authenticated services (OKD, ArgoCD, Grafana). | Session 17: Keycloak brute force protection provides centralized lockout. |
| AC-8 | System Use Notification | Compliant | Authorized-use warning banner deployed via /etc/issue.net and /etc/motd on iac-control, GitLab, Vault. SSH Banner directive configured. | Sprint 3: Banners deployed on all managed hosts. |
| AC-11 | Device Lock | **Compliant** | TMOUT=900 terminates idle shell sessions. ClientAliveInterval=300 disconnects idle SSH. Keycloak SSO session idle timeout (30 minutes) terminates web-based sessions for OKD, ArgoCD, Grafana. Server-only environment (no GUI). | Session 17: Keycloak session timeouts for web services. |
| AC-11(1) | Pattern-Hiding Displays | N/A | Server-only environment, no GUI. | N/A. |
| AC-12 | Session Termination | **Compliant** | Vault certs expire (30min TTL). SSH ClientAliveInterval=300 terminates idle connections. Keycloak SSO session max lifetime (10h) and idle timeout (30min) enforce automatic session termination for all web-based platform access (OKD, ArgoCD, Grafana). | Session 17: Keycloak session lifecycle management. |
| AC-14 | Permitted Actions Without Auth | **Compliant** | All access requires certificate authentication. | None. |
| AC-17 | Remote Access | **Compliant** | Vault SSH certs. Pangolin zero-trust with SSO. | None. |
| AC-17(1) | Monitoring / Control | Partial | iptables logs denied connections. HAProxy logs requests. | No centralized remote access monitoring. |
| AC-17(2) | Encryption for Remote Access | **Compliant** | SSH hardened via CIS benchmarks (MaxAuthTries=4, PermitEmptyPasswords no, DisableForwarding, MaxStartups, LoginGraceTime). Pangolin TLS. OKD TLS. Vault TLS. | None. Session 13: SSH CIS hardening. |
| AC-17(3) | Managed Access Control Points | **Compliant** | iac-control single gateway. Pangolin single external entry. | None. |
| AC-17(4) | Privileged Commands / Access | Partial | Vault certs time-limited. | No audit of privileged remote sessions. No MFA. |
| AC-18 | Wireless Access | N/A | No wireless infrastructure. | N/A. |
| AC-18(1) | Authentication and Encryption | N/A | No wireless. | N/A. |
| AC-19 | Mobile Device Access Control | N/A | No mobile device management. | N/A. |
| AC-19(5) | Full Device Encryption | N/A | No managed mobile devices. | N/A. |
| AC-20 | Use of External Systems | Partial | Egress filtering. No formal policy. | No acceptable use policy. |
| AC-20(1) | Limits on Authorized Use | Partial | Squid enforces egress. iptables drops unauthorized. | No user agreement. |
| AC-20(2) | Portable Storage Devices | N/A | Server infrastructure, no USB in typical use. | N/A. |
| AC-21 | Information Sharing | N/A | Single-tenant. No cross-org sharing. | N/A. |
| AC-22 | Publicly Accessible Content | **Compliant** | All services behind authentication. No public content. | None. |

### 5.2 AT — Awareness and Training

**Summary**: 0 Compliant | 0 Partial | 0 Non-Compliant | 6 N/A

All AT controls scoped out. Single-operator environment with no employees, contractors, or users requiring security awareness training. See [Appendix A](#appendix-a--scoping-justifications) for full justification.

| Control | Title | Status | Justification |
|---------|-------|--------|---------------|
| AT-1 | Policy and Procedures | N/A | No workforce to train. |
| AT-2 | Literacy Training and Awareness | N/A | Single operator with technical expertise. |
| AT-2(2) | Insider Threat | N/A | No insiders. |
| AT-2(3) | Social Engineering and Mining | N/A | No phishing targets. |
| AT-3 | Role-Based Training | N/A | No roles, single operator. |
| AT-4 | Training Records | N/A | No training program. |

### 5.3 AU — Audit and Accountability

**Summary**: 10 Compliant | 11 Partial | 1 Non-Compliant

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| AU-1 | Policy and Procedures | Partial | SSP documents logging architecture. | No standalone AU policy. |
| AU-2 | Event Logging | **Partial** | iptables, Squid, HAProxy, dnsmasq, OKD API audit. Loki aggregation. Wazuh SIEM collects audit events from 9 agents. auditd deployed on VM hosts via Ansible common role. | auditd missing on LXC containers (minio-bootstrap, config-server) due to kernel limitations. See Risk Acceptance in Appendix A. |
| AU-2(3) | Reviews and Updates | Partial | Event types documented in SSP. | No periodic review schedule. |
| AU-3 | Content of Audit Records | **Compliant** | Timestamp, source IP, event type, outcome in all logs. | None. |
| AU-3(1) | Additional Content | **Partial** | Protocol, ports, interface (iptables); URL, method (Squid); timing, TLS version (HAProxy). Application-level logs comprehensive. auditd deployed on VM hosts with CIS-based rules. | Auditd content missing on LXC hosts. Compensated by VM-level auditing on hypervisor. |
| AU-4 | Audit Log Storage | Partial | /var/log + Loki local volumes. | Single point of failure. No off-system storage. |
| AU-5 | Response to Audit Failure | Partial | Rsyslog disk queue. Docker restart for Loki. | No alerting on logging failures. |
| AU-5(1) | Storage Capacity Warnings | Non-Compliant | No threshold alerts for log disk usage. | Missing disk monitoring for audit volumes. |
| AU-5(2) | Real-time Alerts | **Compliant** | 3 Grafana alerts: firewall deny >100/5m, HAProxy block >50/5m, Squid denied >50/5m. | None. |
| AU-6 | Audit Review, Analysis, Reporting | Partial | Grafana dashboards. No review schedule. | No formal reporting mechanism. |
| AU-6(1) | Automated Analysis | Partial | Grafana threshold rules. No anomaly detection. | No behavioral analysis or correlation. |
| AU-6(3) | Correlation | Partial | Loki allows LogQL correlation. Not pre-configured. | No automated correlation rules. |
| AU-7 | Audit Reduction and Report Generation | **Compliant** | Grafana filtering, aggregation, visualization. LogQL queries for application logs. auditd deployed with aureport/ausearch for kernel audit record reduction and reporting. Wazuh SIEM provides centralized SCA and log correlation across 9 agents. | None. Sprint 6: auditd + Wazuh provide full audit reduction capability. |
| AU-7(1) | Automatic Processing | Partial | Grafana auto-processes high deny rates. | No scheduled reports or digests. |
| AU-8 | Time Stamps | **Compliant** | systemd-timesyncd active. All nodes synchronized. | None. |
| AU-8(1) | Synchronization with Authoritative Source | **Compliant** | Public NTP (pool.ntp.org). OKD nodes sync via iac-control. | None. |
| AU-9 | Protection of Audit Information | Partial | Log permissions correct (0640, syslog:adm). No encryption at rest. | No integrity checking. |
| AU-9(4) | Access by Privileged Users | Partial | Only root/adm can read logs. SSH requires Vault certs. | gitlab-runner account needs nologin shell (AC-2 finding). |
| AU-11 | Audit Record Retention | Compliant | All logrotate configs standardized to 30-day retention. Vault audit log: 30-day logrotate. Loki retention configured. | Sprint 3: Log retention consolidated to 30 days across all services. |
| AU-12 | Audit Record Generation | **Compliant** | All system events generated. Promtail ships to Loki. | None. |
| AU-12(1) | System-Wide Capability | **Compliant** | Network, proxy, LB, DNS, Kubernetes API all covered. | None. |
| AU-12(3) | Changes by Authorized Individuals | Partial | Logrotate/iptables require root. Grafana admin-protected. | No change tracking for audit config. |

**Critical Finding (RESOLVED Sprint 1)**: Vault audit logging was not enabled. **Now active** at /vault/logs/audit.log with 30-day logrotate.

**Wazuh Cross-Reference (v1.6)**: AU-3(1) and AU-7 downgraded to Partial (no auditd). **v1.7**: Upgraded back to Compliant after auditd deployment via Ansible common role on all managed hosts. POA&M P2-11 closed.

### 5.4 CA — Assessment, Authorization, and Monitoring

**Summary**: 3 Compliant | 6 Partial | 2 Non-Compliant | 0 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| CA-1 | Policy and Procedures | Partial | SSP serves as assessment documentation. Quarterly account review scheduled. | No formal assessment policy. |
| CA-2 | Control Assessments | **Compliant** | This assessment (366 controls). Previous assessment (10 controls, 8 compliant). | None. |
| CA-2(1) | Independent Assessors | Partial | AI agent (Claude Code) acts as a semi-independent assessor with a different access level (read-only Vault policy) than the human operator (full admin). The AI performs automated assessment and audit while the human reviews findings. Provides functional independence though not organizational independence. | Not truly independent — same operator controls both human and AI access. AI independence is functional, not organizational. |
| CA-3 | Information Exchange | Partial | External connections documented (Pangolin, Cloudflare, Backblaze). | No formal ISAs/MOUs. |
| CA-3(6) | Transfer Authorizations | Non-Compliant | No authorization for data transfers to Backblaze. | No documented data transfer approvals. |
| CA-5 | Plan of Action and Milestones | Partial | Risk register tracks 5 risks. | No formal POA&M with milestones/owners. |
| CA-6 | Authorization | Non-Compliant | No formal ATO decision. Self-operated, self-authorized. | No ATO or authorization package. |
| CA-7 | Continuous Monitoring | **Compliant** | DevSecOps pipeline provides continuous security monitoring on every commit via GitLab CI. Trivy, tflint, ansible-lint, yamllint, gitleaks run automatically. Grafana/Loki/Promtail 30-day retention. 3 alert rules. Wazuh SIEM: 11/11 automated compliance checks running daily across 9 agents. Wazuh CIS SCA, FIM, vulnerability detection (23,198 records), Active Response. | Session 11: Wazuh automated compliance monitoring. |
| CA-7(4) | Risk Monitoring | Partial | Static risk register in SSP (5 risks). | No continuous risk re-assessment. |
| CA-8 | Penetration Testing | Non-Compliant | No pentesting performed. | No internal or external pentest. |
| CA-9 | Internal System Connections | **Compliant** | Internal connections documented. Firewall rules restrict per connection. | None. |

### 5.5 CM — Configuration Management

**Summary**: 5 Compliant | 14 Partial | 8 Non-Compliant | 1 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| CM-1 | Policy and Procedures | Non-Compliant | No documented CM policy. | No formal CM procedures. |
| CM-2 | Baseline Configuration | Partial | Ansible playbook for iac-control. iptables persisted. | Only iac-control has IaC. 90% of infra manual. |
| CM-2(2) | Automation Support | Partial | Ansible for iac-control. GitLab CI/CD exists. | Only iac-control automated. No drift detection. |
| CM-2(3) | Retention of Previous Configs | **Compliant** | Git version control in sentinel-iac. Full history. | None. |
| CM-2(7) | High-Risk Areas | N/A | Not deployed to high-risk areas. | N/A. |
| CM-3 | Configuration Change Control | Partial | Git workflow. Structured commits. | No formal approval process. Direct commits to main. |
| CM-3(1) | Automated Change Implementation | **Compliant** | GitLab CI/CD automates validation workflow: tflint, ansible-lint, yamllint, trivy run on every commit. Pipeline #41 all security jobs PASS. | Most deployment still manual after validation. |
| CM-3(2) | Test/Validate/Document Changes | **Compliant** | Every change validated by CI pipeline stages before merge. Pipeline includes: tflint (Terraform), ansible-lint (Ansible), yamllint (YAML), trivy (IaC/filesystem scanning). All repos protected. | No test environment. |
| CM-3(4) | Security Representative Approval | Partial | AI agent (Claude Code) operates under read-only Vault policy (`claude-automation`), effectively acting as a constrained configuration agent. Human operator reviews and approves all changes before execution (plan→approve→implement model). | Not a formal security representative role. AI approval is functional, not organizational. |
| CM-3(6) | Cryptography Management | Partial | SSH CA via Vault. Cloudflare token rotated. | No crypto inventory. No rotation schedule. |
| CM-4 | Impact Analyses | Non-Compliant | No documented impact analysis process. | Changes applied without formal assessment. |
| CM-5 | Access Restrictions for Change | Partial | Git auth required. Vault SSH certs for system access. | No separation of duties. GitLab no MFA. |
| CM-5(1) | Automated Access Enforcement | Partial | Vault automates cert expiry. | No enforcement of change windows. |
| CM-6 | Configuration Settings | **Compliant** | Ansible vars. SSH hardened (CIS benchmarks). AppArmor (121 profiles). Kyverno enforces 5 cluster policies (disallow-privileged, require-labels, require-run-as-nonroot, restrict-image-registries, require-resource-limits). auditd with CIS-based rules. PAM hardened. | Session 13: Kyverno policy engine + Sprint 6 CIS hardening. |
| CM-6(1) | Automated Management | Partial | Ansible can apply baseline. netfilter-persistent. unattended-upgrades. | Not run regularly. No scheduled enforcement. |
| CM-6(2) | Respond to Unauthorized Changes | Compliant | AIDE installed on iac-control and GitLab with daily cron scans. Baseline initialized. Changes detected and reported. | Sprint 3: AIDE FIM deployed on managed hosts. |
| CM-7 | Least Functionality | **Compliant** | 797 packages (lean). AppArmor. Squid allowlist (23 domains). Kyverno restricts image registries and disallows privileged containers in OKD. telnet removed from Proxmox hosts. | Session 13: Kyverno policy enforcement. |
| CM-7(1) | Periodic Review | Non-Compliant | No review schedule. | No evidence of prior reviews. |
| CM-7(2) | Prevent Program Execution | Partial | AppArmor (26 enforce profiles). | No allowlisting beyond AppArmor. |
| CM-7(5) | Authorized Software | Non-Compliant | No software inventory or allowlist. | Cannot verify all software authorized. |
| CM-8 | System Component Inventory | Partial | Components in code/diagrams. OKD operators enumerated (35). | No formal inventory document. |
| CM-8(1) | Updates During Install/Remove | Non-Compliant | No automated inventory updates. | Manual changes don't trigger updates. |
| CM-8(3) | Automated Unauthorized Detection | Non-Compliant | No network scanning. | Cannot detect rogue devices. |
| CM-9 | Configuration Management Plan | Compliant | CM Plan created covering baselines, change control, AIDE monitoring, deviation handling, tool inventory. Stored in sentinel-iac/compliance/configuration-management-plan.md. | Sprint 3: Formal CM Plan per NIST requirements. |
| CM-10 | Software Usage Restrictions | Partial | OSS used. No licensing concerns. | No license compliance tracking. |
| CM-11 | User-Installed Software | Partial | Root required for install. No sudo for gitlab-runner. | No policy. |
| CM-12 | Information Location | Non-Compliant | No documented data locations. | Unknown sensitive data locations. |
| CM-12(1) | Automated Location | Non-Compliant | No data discovery tools. | Cannot locate sensitive data. |

### 5.6 CP — Contingency Planning

**Summary**: 19 Compliant | 3 Partial | 5 Non-Compliant | 2 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| CP-1 | Policy and Procedures | Non-Compliant | No CP policy. | None documented. |
| CP-2 | Contingency Plan | **Compliant** | DR Runbook (sentinel-iac/infrastructure/DR-RUNBOOK.md) documents full contingency plan with automated recovery procedures. Break-glass procedures + rollback scripts + restore scripts for all critical systems. | Sprint 4: DR Runbook deployed with comprehensive procedures. |
| CP-2(1) | Coordinate with Related Plans | **Compliant** | DR Runbook references IRP (sentinel-iac/compliance/incident-response-plan.md), CM Plan, and backup schedules. All plans cross-reference each other. | Sprint 4: DR Runbook coordinates with existing IRP and CM Plan. |
| CP-2(2) | Capacity Planning | Non-Compliant | No capacity planning. Terraform state stale. | No growth planning documented. |
| CP-2(3) | Resume Mission Functions | **Compliant** | RTO targets documented: single VM 10-30min (CI one-click), two VMs 30-90min, total loss 3-4hr (bootstrap-from-b2). Restore scripts automate recovery of all critical services. | Sprint 4: RTO/RPO documented, automated restore scripts deployed. |
| CP-2(5) | Continue Mission Functions | Partial | DR Site (810) provides alternate processing capability with RPi 5 cluster and workstations. UniFi site-to-site VPN capable. | Full failover not yet tested. DR runbook not documented. |
| CP-2(8) | Identify Critical Assets | **Compliant** | DR Runbook identifies all critical assets (Vault, GitLab, MinIO, OKD etcd) with restoration priority ordering and RTO per service. iac-control SPOF documented as risk. | Sprint 4: Formal asset criticality in DR Runbook. |
| CP-3 | Contingency Training | N/A | Single operator. | N/A. |
| CP-3(1) | Simulated Events | **Compliant** | DR drill executed 2026-02-08: Vault full VM clone restore on 208-pve2 (VM 9990), unsealed, all secrets verified. GitLab backup integrity validated. CI DR jobs provide repeatable drill infrastructure. | Sprint 4: DR drill completed successfully. |
| CP-4 | Contingency Plan Testing | **Compliant** | DR test executed 2026-02-08: Vault full VM clone restore tested (unseal + secret access verified, ~10min RTO). GitLab backup integrity verified (tarball structure validated). Firewall rollback tested 2026-02-06. CI DR jobs enable repeatable testing. | Sprint 4: Full system DR test completed. |
| CP-4(1) | Coordinate with Related Plans | Non-Compliant | No related plans. | N/A. |
| CP-4(2) | Alternate Processing Site | Non-Compliant | No alternate site. | Single site. |
| CP-6 | Alternate Storage Site | **Compliant** | Backblaze B2 provides geographically separate cloud storage. Terraform state backed up via MinIO replication to B2. Encrypted in transit (TLS). Verified operational 2026-02-06. | None. B2 satisfies offsite storage requirement. |
| CP-6(1) | Separation from Primary | **Compliant** | B2 storage is in Backblaze data centers, geographically separate from primary site. Different facility, different utility grid, different geographic region. | None. |
| CP-6(3) | Accessibility | **Compliant** | B2 is internet-accessible, enabling recovery from any location including DR Site (810). Recovery requires only B2 credentials (stored in Vault KV). | None. |
| CP-7 | Alternate Processing Site | **Compliant** | DR Site (810), geographically separated from primary site. Separate utility grid provider. Natural gas generator + UPS for continuous power. RPi 5 cluster (dedicated 1Gbps Ethernet) + workstations provide Kubernetes-capable compute. | None. DR site exists and is equipped. |
| CP-7(1) | Separation from Primary | **Compliant** | DR Site (810) is geographically separated from primary site. Separate utility provider. Regional outage at primary does not affect DR site. | None. |
| CP-7(2) | Accessibility | **Compliant** | DR Site (810) accessible via physical travel (30-100mi drive) and remotely via UniFi site-to-site VPN when internet is available at both sites. | None. |
| CP-7(3) | Priority of Service | **Compliant** | DR Runbook (sentinel-iac/infrastructure/DR-RUNBOOK.md) documents service restoration priority: 1) Vault (secrets/SSH CA), 2) MinIO (backup storage), 3) GitLab (CI/CD), 4) OKD etcd. RTO per service defined. | Sprint 4: Priority ordering formalized in DR Runbook. |
| CP-8 | Telecommunications Services | **Compliant** | Dual WAN: T-Mobile/Metronet 1Gbps symmetric (WAN 1) + Frontier/Verizon 7Gbps symmetric (WAN 2). Different upstream networks (T-Mobile vs Verizon backbone). UniFi gateway manages automatic failover. Combined 8Gbps symmetric. | None. Dual WAN with separate upstream providers satisfies telecom redundancy. |
| CP-8(1) | Priority of Service Provisions | **Compliant** | Two separate ISPs (T-Mobile via Metronet, Frontier via Verizon) provide redundancy. Loss of either ISP maintains connectivity. Residential SLAs but dual-provider architecture eliminates single-ISP dependency. | No formal SLA but redundancy compensates. |
| CP-8(2) | Single Points of Failure | **Compliant** | Dual WAN eliminates single-ISP SPOF for internet connectivity. Each link uses different upstream backbone (T-Mobile vs Verizon). UniFi gateway auto-failover. iac-control remains a compute SPOF but telecom path is redundant. | iac-control compute SPOF documented separately (R-3 in risk register). |
| CP-9 | System Backup | Compliant | Terraform state → MinIO → B2 (hourly). Vault data → MinIO → B2 (daily). GitLab → MinIO → B2 (weekly). etcd → MinIO (daily CronJob). All critical data backed up with offsite copies. | Sprint 3: etcd backup deployed. All backup gaps closed. |
| CP-9(1) | Testing for Reliability | **Compliant** | DR restore tested 2026-02-08: Vault full VM clone restored on 208-pve2, unsealed, all secrets readable (~10min). GitLab backup integrity verified (tarball structure). Restore scripts validated operational. CI one-click jobs provide repeatable testing. | Sprint 4: Backup restoration verified. |
| CP-9(8) | Cryptographic Protection | **Compliant** | Vault backups encrypted before upload to MinIO. B2 uses TLS in transit + server-side encryption. MinIO replica over LAN (private network). All backup pipelines use encrypted transport. | Sprint 4: Vault backup encryption verified. B2 encryption confirmed. |
| CP-10 | System Recovery and Reconstitution | **Compliant** | Restore scripts for all critical systems: vault, gitlab, minio, etcd, bootstrap-from-b2 (total loss recovery). CI one-click recovery jobs. DR Runbook documents full recovery procedures. Proxmox snapshots provide VM-level recovery. | Sprint 4: Complete restore automation deployed. |
| CP-10(2) | Transaction Recovery | N/A | No transactional workloads. | N/A. |
| CP-10(4) | Restore Within Time Period | **Compliant** | RTO validated 2026-02-08: Vault full VM clone restore achieved ~10min RTO (target 10-30min — within target). GitLab backup integrity confirmed. DR Runbook RTO targets validated against actual test results. | Sprint 4: RTO target validated by DR test. |

### 5.7 IA — Identification and Authentication

**Summary**: 11 Compliant | 6 Partial | 1 Non-Compliant | 3 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| IA-1 | Policy and Procedures | Partial | SSP documents SSH cert auth model. | No formal IA policy. |
| IA-2 | Identification and Authentication | **Compliant** | Vault SSH certs for infrastructure. Keycloak OIDC SSO for platform services (OKD, ArgoCD, Grafana). HTPasswd retained as backup. No anonymous access. All users identified via Keycloak `sentinel` realm. | Session 17: Keycloak SSO provides centralized identification. |
| IA-2(1) | MFA to Privileged Accounts | Partial | Pangolin external: SSO + passkeys (2FA). Keycloak supports MFA (TOTP/WebAuthn) — not yet enforced for all users. Internal SSH: single-factor cert. | Keycloak MFA capability deployed but not mandated. Phase 2: enforce MFA for admin group. |
| IA-2(2) | MFA to Non-Privileged | Partial | Pangolin passkeys for external. Keycloak supports MFA (TOTP/WebAuthn) for internal web services. Not yet enforced as required authentication flow. | Phase 2: enforce MFA for all Keycloak users. |
| IA-2(8) | Replay Resistant | **Compliant** | SSH cert nonces. TLS prevents replay. | None. |
| IA-2(12) | PIV Credentials | N/A | Non-federal. | N/A. |
| IA-3 | Device Identification | Partial | OKD node certs. MAC-based PXE. | MAC easily spoofed. |
| IA-4 | Identifier Management | Partial | Vault principals defined. OKD htpasswd. | No identifier assignment process. |
| IA-4(4) | Identify User Status | Non-Compliant | No user status indicators. | No identity attributes. |
| IA-5 | Authenticator Management | **Compliant** | Vault manages SSH certs. Keycloak manages OIDC credentials with password policy (12-char min, uppercase, lowercase, digit, special char), password history, and brute force protection. Client secrets stored in Vault. Root token rotated. | Session 17: Keycloak password policy + Vault secret management. |
| IA-5(1) | Password-Based Authentication | **Compliant** | PAM pam_pwquality (14-char min, complexity) on hosts. Keycloak password policy: 12 characters minimum, uppercase, lowercase, digit, special character required. Password aging via PAM (PASS_MAX_DAYS=90). HTPasswd retained as OKD backup. | Session 17: Keycloak enforces comprehensive password policy. |
| IA-5(2) | Public Key-Based Auth | **Compliant** | Vault SSH CA. TrustedUserCAKeys. Principal enforcement. | None. |
| IA-5(6) | Protection of Authenticators | **Compliant** | SSH keys user-only permissions. Gitleaks blocks pipeline on detected secrets in all 3 repos (sentinel-iac, overwatch, overwatch-gitops). `allow_failure: false` enforces hard block. | No HSM. Vault root token in Proton Pass. |
| IA-6 | Authentication Feedback | **Compliant** | SSH/console obscure password entry. | None. |
| IA-7 | Cryptographic Module Auth | **Compliant** | OpenSSH (FIPS-capable). OKD x509. | None. |
| IA-8 | Non-Organizational Users | **Compliant** | Pangolin SSO (passkey) for external. No guest accounts. | None. |
| IA-8(1) | PIV from Other Agencies | N/A | Non-federal. | N/A. |
| IA-8(2) | External Authenticators | **Compliant** | Pangolin accepts external SSO (FIDO2 passkeys). | None. |
| IA-8(4) | Use of Defined Profiles | Partial | SSH uses OpenSSH defaults. TLS for HTTPS/OKD. | No explicit FIPS 140-2 validation. |
| IA-11 | Re-Authentication | Non-Compliant | No re-auth for privileged operations. | No re-auth beyond cert expiry. |
| IA-12 | Identity Proofing | N/A | Single operator. | N/A. |

### 5.8 IR — Incident Response

**Summary**: 5 Compliant | 8 Partial | 4 Non-Compliant

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| IR-1 | Policy and Procedures | Compliant | Formal Incident Response Plan per NIST SP 800-61 Rev 2 at sentinel-iac/compliance/incident-response-plan.md. Covers all phases: Preparation, Detection & Analysis, Containment/Eradication/Recovery, Post-Incident Activity. | Sprint 3: IRP created with 6 category playbooks. |
| IR-2 | IR Training | Partial | IRP serves as training material. Quarterly tabletop exercises planned. Single-operator context means formal training program not applicable. | Sprint 3: IRP documents training approach and schedule. |
| IR-2(1) | Simulated Events | Non-Compliant | No tabletop exercises. | No IR drills. |
| IR-2(2) | Automated Training Environments | Non-Compliant | No simulation tools. | N/A for homelab. |
| IR-3 | IR Testing | Compliant | IRP includes testing schedule: annual tabletop, quarterly rollback tests, semi-annual backup restore, monthly alert verification. Rollback scripts tested 2026-02-06. | Sprint 3: IRP includes comprehensive testing procedures and schedule. |
| IR-3(2) | Coordination with Related Plans | Partial | Break-glass references CP-2. | No documented coordination. |
| IR-4 | Incident Handling | Partial | Break-glass for 5 scenarios. Grafana detection. | No ticket system. No escalation path. |
| IR-4(1) | Automated Incident Handling | Partial | Grafana auto-detects. Docker auto-recovers. | No automated remediation. |
| IR-5 | Incident Monitoring | Partial | Grafana + Loki visibility. 3 alert rules. | No incident register. |
| IR-5(1) | Automated Tracking | Partial | Loki collects. Grafana stores alert state. | No incident database. |
| IR-6 | Incident Reporting | Partial | Single operator self-reports. Grafana alerts visible. | Email contact placeholder. |
| IR-6(1) | Automated Reporting | Compliant | Grafana alerts configured with contact point delivering notifications. Three alert rules active: firewall denies, HAProxy blocks, Squid denied requests. | Sprint 3: Alert delivery configured and tested. |
| IR-6(3) | Supply Chain Coordination | Non-Compliant | No supply chain IR process. | No suppliers to report to. |
| IR-7 | IR Assistance | Partial | Break-glass self-service. Proxmox out-of-band. | No external IR assistance. |
| IR-7(1) | Automation Support for Availability | **Compliant** | Proxmox console available even if network fails. Break-glass readable offline. | None. |
| IR-8 | IR Plan | Compliant | Formal IRP with all NIST SP 800-61 Rev 2 phases: Preparation, Detection & Analysis, Containment, Eradication, Recovery, Post-Incident Activity. Includes communication plan and evidence handling. | Sprint 3: Complete IRP created. |
| IR-8(1) | Breaches | Non-Compliant | No breach response plan. | No data breach procedures. |

### 5.9 MA — Maintenance

**Summary**: 2 Compliant | 4 Partial | 4 Non-Compliant | 2 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| MA-1 | Policy and Procedures | Non-Compliant | No maintenance policy. | None documented. |
| MA-2 | Controlled Maintenance | Partial | Ansible playbooks. Rollback scripts. | No maintenance schedule. All ad-hoc. |
| MA-3 | Maintenance Tools | Partial | Ansible, Terraform, oc/kubectl, Proxmox API, Git. | No tool inventory or approval process. |
| MA-3(1) | Inspect Tools | Non-Compliant | No tool inspection for malware. | Tools from repos but not verified. |
| MA-3(2) | Inspect Media | N/A | No removable media. All SSH-based. | N/A. |
| MA-4 | Nonlocal Maintenance | **Compliant** | All via SSH with Vault certs. Pangolin for console. | None. |
| MA-4(3) | Comparable Security | **Compliant** | Same Vault certs for remote as local. | None. |
| MA-5 | Maintenance Personnel | Partial | Single operator. Vault certs provide auditability. | No separation of duties. |
| MA-5(1) | Individuals Without Access | N/A | No third-party maintenance. | N/A. |
| MA-6 | Timely Maintenance | Partial | unattended-upgrades enabled. 24 packages pending iac-control, 49 on GitLab. | No patching SLA. Security patches pending. |

### 5.10 MP — Media Protection

**Summary**: 0 Compliant | 3 Partial | 4 Non-Compliant | 1 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| MP-1 | Policy and Procedures | Non-Compliant | No media protection policy. | No handling procedures. |
| MP-2 | Media Access | Partial | Physical access via residential security. B2 backups encrypted in transit. | No media tracking. |
| MP-3 | Media Marking | Non-Compliant | No labeling of drives or backups. | No classification markings. |
| MP-4 | Media Storage | Partial | Residential access control. B2 encrypted offsite. | No secure storage for removable media. |
| MP-5 | Media Transport | Non-Compliant | No transport controls documented. | No physical media transport policy. |
| MP-6 | Media Sanitization | Non-Compliant | VM deletion via Proxmox (qm destroy). No NIST 800-88 wiping. | No secure erase process. |
| MP-7 | Media Use | Partial | No removable media in production. | No policy restricting removable media. |
| MP-7(1) | Prohibit Use Without Owner | N/A | All media owned by operator. | N/A. |

### 5.11 PE — Physical and Environmental Protection

**Summary**: 0 Compliant | 8 Partial | 0 Non-Compliant | 15 Inherited

Physical security is inherited from the residential environment. Homelab servers are located in a private residence with residential security controls (locks, alarm system). Datacenter-grade controls (mantraps, fire suppression, redundant power) are not applicable or cost-effective.

| Control | Title | Status | Justification |
|---------|-------|--------|---------------|
| PE-1 | Policy and Procedures | Inherited | Residential physical security. |
| PE-2 | Physical Access Authorizations | Inherited | Homeowner controls. |
| PE-3 | Physical Access Control | Inherited | Home entry controls. |
| PE-3(1) | System Access | Inherited | Requires building entry. |
| PE-4 | Access for Transmission | N/A | No dedicated transmission rooms. |
| PE-5 | Access for Output Devices | Inherited | Home office. |
| PE-6 | Monitoring Physical Access | Partial | Proxmox console logged. No cameras on rack. |
| PE-6(1) | Intrusion Alarms | Partial | Residential alarm assumed. No server surveillance. |
| PE-6(4) | Monitoring Access to Systems | Partial | Console logged. No tamper detection. |
| PE-8 | Visitor Access Records | Inherited | Homeowner controls visitors. |
| PE-9 | Power Equipment/Cabling | Partial | Standard residential power. APC SmartUPS LiPo at primary provides power conditioning (surge/sag protection) with outlet-level control. | No dedicated server room power distribution. |
| PE-10 | Emergency Shutoff | Inherited | Residential circuit breakers. |
| PE-11 | Emergency Power | Partial | Primary site: APC SmartUPS LiPo with outlet-level power control, battery backup for graceful shutdown, SmartUPS Cloud monitoring (NMC upgrade planned for SNMP). DR Site (810) DR: natural gas generator + UPS for whole-site power. | Primary UPS provides graceful shutdown, not extended runtime. NMC upgrade pending. |
| PE-11(1) | Alternate Power | Partial | DR Site (810) DR site has natural gas generator (auto-start on grid failure) providing indefinite alternate power. Primary site SmartUPS provides short-term battery backup. | Primary site lacks generator. DR Site (810) generator covers DR site only. |
| PE-12 | Emergency Lighting | Inherited | Servers operate unattended. |
| PE-13 | Fire Protection | Inherited | Residential smoke detectors. |
| PE-13(1) | Detection/Auto-Activation | Inherited | Smoke detectors. |
| PE-14 | Environmental Controls | Partial | Home HVAC. No server-specific cooling. |
| PE-14(2) | Monitoring with Alarms | Partial | Proxmox CPU/disk temps. No alerts. |
| PE-15 | Water Damage Protection | Inherited | Servers not near plumbing (assumed). |
| PE-16 | Delivery and Removal | Inherited | Homeowner controls deliveries. |
| PE-17 | Alternate Work Site | Inherited | Home IS the work site. |

### 5.12 PL — Planning

**Summary**: 4 Compliant | 2 Partial | 0 Non-Compliant | 2 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| PL-1 | Policy and Procedures | Partial | SSP as planning documentation. | No formal policy framework. |
| PL-2 | System Security Plan | **Compliant** | SSP at ~/claude-memory/SSP-overwatch-platform.md. Updated 2026-02-06. | None. |
| PL-4 | Rules of Behavior | N/A | Single operator. | N/A. |
| PL-4(1) | Social Media Restrictions | N/A | Not an organization. | N/A. |
| PL-8 | Security & Privacy Architectures | Partial | Architecture in SSP Section 3. Security zones defined. | Created retrospectively. |
| PL-8(1) | Defense in Depth | **Compliant** | Network isolation, zero-trust, egress filtering, JIT certs, logging. | None. |
| PL-10 | Baseline Selection | **Compliant** | NIST 800-53 Rev 5 Moderate explicitly selected in SSP. | None. |
| PL-11 | Baseline Tailoring | **Compliant** | Controls tailored via scoping. Risk-based approach documented. | None. |

### 5.13 PM — Program Management

**Summary**: 4 Compliant | 5 Partial | 3 Non-Compliant | 10 N/A

Most PM controls are organizational-level and scoped out for single-operator environment.

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| PM-1 | Security Program Plan | N/A | No organization. | N/A. |
| PM-2 | Security Program Leadership | N/A | Single operator is de facto security lead. | N/A. |
| PM-3 | Security Resources | N/A | Self-funded homelab. | N/A. |
| PM-4 | POA&M | Partial | Risk register in SSP. | No formal POA&M with milestones. |
| PM-5 | System Inventory | **Compliant** | SSP Section 6.1. VM inventory with VMID/IP/function. | None. |
| PM-5(1) | PII Inventory | N/A | No PII processed. | N/A. |
| PM-6 | Security Metrics | Non-Compliant | No security KPIs tracked. | No metrics defined. |
| PM-7 | Enterprise Architecture | N/A | Homelab, not enterprise. | N/A. |
| PM-7(1) | Offloading | **Compliant** | Pangolin SaaS, Cloudflare DNS. Documented. | None. |
| PM-8 | Critical Infrastructure Plan | N/A | Not critical infrastructure. | N/A. |
| PM-9 | Risk Management Strategy | Partial | Risk register. No formal framework. | No risk appetite statement. |
| PM-10 | Authorization Process | Non-Compliant | No ATO process. | Self-authorized. |
| PM-11 | Mission/Business Definition | Partial | SSP Section 2.1 defines purpose. | No business process mapping. |
| PM-13 | Security Workforce | N/A | Single operator. | N/A. |
| PM-14 | Testing/Training/Monitoring | **Compliant** | DevSecOps pipeline provides automated testing on every commit (ansible-lint, tflint, yamllint, trivy). Grafana alerting for continuous monitoring. Rollback scripts tested. | No formal test plan document. |
| PM-15 | Security Groups | N/A | Single operator. | N/A. |
| PM-16 | Threat Awareness | Non-Compliant | No threat intelligence feeds. No CVE monitoring. | Reactive, not proactive. |
| PM-17 | CUI Protection | N/A | Not federal. No CUI. | N/A. |
| PM-25 | PII Minimization | N/A | No PII. | N/A. |
| PM-28 | Risk Framing | Non-Compliant | No risk assumptions documented. | Risks tracked but not framed. |
| PM-30 | SCRM Strategy | Non-Compliant | No SCRM strategy. | No supply chain visibility. |
| PM-31 | Continuous Monitoring | **Compliant** | DevSecOps pipeline is the ISCM mechanism: Trivy/tflint/ansible-lint run on every commit. Grafana/Loki/Promtail 30-day retention. 3 alert rules. Pipeline provides continuous security monitoring. | No formal ISCM strategy document. |
| PM-32 | Purposing | N/A | No PII. | N/A. |

### 5.14 PS — Personnel Security

**Summary**: 0 Compliant | 0 Partial | 0 Non-Compliant | 9 N/A

All PS controls scoped out. Single-operator environment with no employees, contractors, or hiring processes. See [Appendix A](#appendix-a--scoping-justifications).

### 5.15 PT — PII Processing and Transparency

**Summary**: 0 Compliant | 0 Partial | 0 Non-Compliant | 13 N/A

Entire PT family scoped out. System does NOT process personally identifiable information. Operational scope is infrastructure telemetry and media content only. See [Appendix A](#appendix-a--scoping-justifications).

### 5.16 RA — Risk Assessment

**Summary**: 4 Compliant | 4 Partial | 1 Non-Compliant | 1 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| RA-1 | Policy and Procedures | **Compliant** | SSP includes risk register. Risk acceptance documented. | None. |
| RA-2 | Security Categorization | **Compliant** | FIPS 199 categorization in SSP. Low/Moderate/Low. | Recommend formalizing ratings. |
| RA-3 | Risk Assessment | **Compliant** | 5 risks identified with likelihood/impact/severity. Mitigations documented. | None. |
| RA-3(1) | Supply Chain Risk Assessment | Partial | Trusted registries used. GPG verification. | No SBOM. No vendor assessment. |
| RA-5 | Vulnerability Scanning | **Compliant** | Trivy IaC scanning + filesystem scanning via GitLab CI. Wazuh vulnerability detection active on 9 agents (23,198 vulnerability records baselined). Proxmox CVE patching: OpenSSL 3.5.4 on all 3 hosts, inetutils-telnet removed. | OpenVAS not deployed but Wazuh provides equivalent host-level vulnerability detection. Session 11: Wazuh vulnerability baseline. Session 13: Proxmox CVE remediation. |
| RA-5(2) | Update Vulnerability Feeds | Partial | Trivy auto-updates vulnerability database on each run (pulls latest from GitHub). | No host scanner to update. |
| RA-5(5) | Privileged Access for Scanning | Partial | Vault infrastructure exists for authenticated scans. Trivy runs in CI with repo access. | No authenticated host scanning. |
| RA-5(11) | Public Disclosure Program | N/A | Not public-facing. | N/A. |
| RA-7 | Risk Response | **Compliant** | Responses documented per risk. Accept/mitigate decisions. | None. |
| RA-9 | Criticality Analysis | Partial | iac-control identified as SPOF. Break-glass documented. | No formal criticality matrix. |

### 5.17 SA — System and Services Acquisition

**Summary**: 9 Compliant | 3 Partial | 3 Non-Compliant | 7 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| SA-1 | Policy and Procedures | N/A | No procurement org. FOSS only. | N/A. |
| SA-2 | Resource Allocation | N/A | Self-funded homelab. | N/A. |
| SA-3 | System Development Life Cycle | Partial | GitOps via GitLab/ArgoCD. IaC in sentinel-iac. | No formal SDLC phases. |
| SA-3(1) | Security in SDLC | Non-Compliant | No security design reviews. | No security baked into development. |
| SA-4 | Acquisition Process | N/A | FOSS only. | N/A. |
| SA-4(1) | Functional Properties | N/A | No procurement. | N/A. |
| SA-4(2) | Design/Implementation Info | Partial | Ansible templates. GitLab source. | Design rationale not documented. |
| SA-4(5) | System Documentation | **Compliant** | SSP, hardening docs, audit docs. | None. |
| SA-4(9) | Functions/Ports/Protocols | **Compliant** | SSP Section 3.2 documents all ports. iptables defines allowed. | None. |
| SA-4(10) | PIV Products | N/A | Non-federal. | N/A. |
| SA-5 | System Documentation | **Compliant** | Comprehensive documentation suite. | None. |
| SA-8 | Security Engineering Principles | Partial | Defense in depth, least functionality, deny-by-default. | Not codified as design tenets. |
| SA-9 | External System Services | **Compliant** | Pangolin, Cloudflare documented. SSO enforced. | None. |
| SA-9(2) | Functions/Ports/Protocols for External | **Compliant** | All external traffic documented in SSP. | None. |
| SA-10 | Developer Config Management | **Compliant** | GitLab CI validates all IaC/K8s configs before merge. Version control in Git. Pipeline enforces validation on every commit. | No formal code review gates (single operator). |
| SA-11 | Developer Testing | **Compliant** | Automated testing via GitLab CI: ansible-lint, tflint, yamllint, trivy. All 3 repos have pipeline coverage. Pipeline #41 (sentinel-iac) all jobs PASS. | No functional/unit tests. Validation only. |
| SA-11(1) | Static Code Analysis | **Compliant** | Trivy provides IaC SAST (Terraform misconfigs, K8s security issues). Tflint for Terraform. Ansible-lint for Ansible. All run on every commit via CI. | No code-level SAST (no SonarQube). IaC SAST only. |
| SA-15 | Development Process/Standards | Non-Compliant | No documented standards. | No development process docs. |
| SA-15(1) | Quality Metrics | Non-Compliant | No code quality metrics. | Nothing tracked. |
| SA-17 | Developer Security Architecture | Non-Compliant | Architecture retrospective. | Not proactive developer artifact. |
| SA-22 | Unsupported Components | **Compliant** | Component lifecycle tracker at sentinel-iac/compliance/component-lifecycle.md. All platform software versions tracked with EOL dates and risk levels. Vault upgraded from 1.15.4 (EOL Oct 2024) to 1.21.2 (supported ~Oct 2026). No EOL components remaining. Monthly review scheduled. | Sprint 4/Session 6: Vault upgrade resolved only EOL component. |

### 5.18 SC — System and Communications Protection

**Summary**: 24 Compliant | 5 Partial | 0 Non-Compliant | 2 N/A

**Strongest family in assessment.** The Overwatch platform demonstrates exceptional network boundary protection and cryptographic implementation.

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| SC-1 | Policy and Procedures | **Compliant** | SSP + hardening docs. | None. |
| SC-2 | Separation of System/User | **Compliant** | OKD isolated from management LAN. HAProxy stats 127.0.0.1 only. | None. |
| SC-3 | Security Function Isolation | **Compliant** | HAProxy, Squid, iptables, dnsmasq, Vault all separate. | None. |
| SC-4 | Shared System Resources | **Compliant** | Container isolation. etcd encrypted. Dedicated VMs per function. | None. |
| SC-5 | DoS Protection | Partial | tcp_syncookies, ICMP limits, HAProxy connection limits. | No DDoS mitigation at edge. |
| SC-7 | Boundary Protection | **Compliant** | iac-control sole gateway. 22 FORWARD rules, default DROP. Zero-trust external. OKD NetworkPolicies implement default-deny ingress/egress with explicit allow rules across 6 namespaces (homepage, media, monitoring, demo, observability, istio-system). ufw deployed on managed hosts. | None. |
| SC-7(3) | Access Points | **Compliant** | 3 documented access points. No undocumented ingress. | None. |
| SC-7(4) | External Telecom Services | **Compliant** | Pangolin outbound-only WireGuard. TLS 1.3 enforced. | None. |
| SC-7(5) | Deny by Default / Allow by Exception | Partial | iptables default DROP. Squid HTTP allowlist. HTTPS broadly allowed (TLS limitation). 8 compensating controls. OKD NetworkPolicies provide per-namespace egress control with default-deny in 6 namespaces. ufw deployed on managed hosts (iac-control, vault, gitlab, seedbox + OKD nodes). | HTTPS egress still broadly allowed at network layer. Risk accepted. |
| SC-7(7) | Split Tunneling Prevention | **Compliant** | OKD single gateway. No VPN or alternate routes. | None. |
| SC-7(8) | Route Traffic to Proxy | **Compliant** | HTTP NAT-redirected to Squid. | HTTPS bypasses (protocol limitation). |
| SC-7(18) | Fail Secure | **Compliant** | iptables default DROP. Squid default deny. HAProxy 503 on backend failure. | None. |
| SC-7(21) | Isolation of Components | **Compliant** | OKD fully isolated on dedicated bridge. No physical uplink. | None. |
| SC-8 | Transmission Confidentiality/Integrity | **Compliant** | TLS 1.3 external. TLS 1.2+ internal. WireGuard. Modern SSH ciphers. Vault TLS enabled (commit 6b1f71c). Istio mTLS (PERMISSIVE mode) provides encryption in transit for all meshed services in OKD. | None. Vault HTTP gap resolved. |
| SC-8(1) | Cryptographic Protection | **Compliant** | AES-GCM, ChaCha20-Poly1305, no weak algorithms. Post-quantum KEX. | None. |
| SC-10 | Network Disconnect | Compliant | SSH ClientAliveInterval=300, ClientAliveCountMax=2 disconnects idle sessions. TMOUT=900 terminates idle shells. Vault SSH certs expire in 30 minutes. | Sprint 3: SSH idle timeout configured on all managed hosts. |
| SC-12 | Crypto Key Management | **Compliant** | Vault SSH CA. ACME auto-renew. WireGuard managed by Pangolin. | None. |
| SC-12(1) | Availability | **Compliant** | Vault HA unseal. ACME auto-renew 30 days early. | None. |
| SC-13 | Cryptographic Protection | **Compliant** | FIPS 140-2 validated algorithms. OpenSSL 3.x FIPS-capable. | None. |
| SC-15 | Collaborative Computing Devices | N/A | No webcams/microphones in scope. | N/A. |
| SC-17 | PKI Certificates | **Compliant** | Let's Encrypt for TLS. Vault for SSH. Short-lived certs. | None. |
| SC-18 | Mobile Code | N/A | No mobile code (Java applets, etc.). | N/A. |
| SC-20 | Secure Name Resolution (Auth) | **Compliant** | dnsmasq authoritative for overwatch.haist.farm. Cloudflare DNSSEC. | None. |
| SC-21 | Secure Name Resolution (Recursive) | **Compliant** | Forward to 1.1.1.1/8.8.8.8. DNS logged. DNS egress restricted. | None. |
| SC-22 | DNS Architecture/Provisioning | **Compliant** | Split-horizon. Authoritative zones by boundary. | None. |
| SC-23 | Session Authenticity | **Compliant** | SSH host key verification. TLS certificates. WireGuard crypto. Istio mTLS provides cryptographic session authenticity between all meshed services (SPIFFE identity). Vault TLS enabled. | None. |
| SC-28 | Protection at Rest | Partial | OKD etcd encrypted. Vault encrypted. VM disks not LUKS. | Disk encryption not enabled. |
| SC-28(1) | Cryptographic Protection at Rest | Partial | etcd AES. Vault AES-GCM. | VM/NFS/GitLab unencrypted. |
| SC-39 | Process Isolation | **Compliant** | Container isolation (cgroups, namespaces, seccomp, AppArmor). KVM at hypervisor level. Hybrid seedbox architecture: P2P/VPN workloads isolated on dedicated VM (109), OKD workloads use standard anyuid SCC only (no privileged containers). | None. |

### 5.19 SI — System and Information Integrity

**Summary**: 11 Compliant | 5 Partial | 2 Non-Compliant | 2 N/A

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| SI-1 | Policy and Procedures | **Compliant** | SSP documents SI policies. | None. |
| SI-2 | Flaw Remediation | Partial | Ubuntu 24.04.3. Kernel patches available. unattended-upgrades enabled. Vault upgraded 1.15.4→1.21.2 (Session 6). | OS patches still pending (19+ iac-control, 50+ GitLab). Vault EOL resolved. |
| SI-2(2) | Automated Flaw Remediation | Partial | unattended-upgrades present. | No centralized dashboard. |
| SI-3 | Malicious Code Protection | **Compliant** | ClamAV on iac-control and GitLab (daily scans). AppArmor active (121 profiles). OKD SCC enforced (anyuid only). Wazuh VirusTotal integration for suspicious file analysis. Kyverno restricts image registries. | None. Session 11: Wazuh VirusTotal integration. |
| SI-3(7) | Nonsignature-Based Detection | **Compliant** | Wazuh SIEM provides behavioral analysis with 60+ custom detection rules, Active Response, FIM with realtime monitoring, and CIS SCA compliance checks. AIDE provides secondary FIM. | Session 11: Wazuh full deployment provides behavioral/anomaly detection. |
| SI-4 | System Monitoring | **Compliant** | Grafana/Loki/Promtail. 3 alert rules. 30-day retention. Wazuh SIEM with 60+ custom rules (Vault, GitLab, Traefik, UniFi), FIM, Active Response, VirusTotal integration, Docker monitoring across 9 agents. Kiali service mesh visualization for OKD traffic. Discord webhook alerting. | None. Session 11: Wazuh full deployment. |
| SI-4(2) | Automated Real-Time Analysis | **Compliant** | Grafana real-time alerts. Promtail continuous shipping. | None. |
| SI-4(4) | Inbound/Outbound Monitoring | **Compliant** | All OKD egress logged. HAProxy inbound logged. Squid HTTP logged. | None. |
| SI-4(5) | System-Generated Alerts | Compliant | 3 alert rules configured in Grafana (firewall denies, HAProxy blocks, Squid denied). Contact point configured and delivering notifications. | Sprint 3: Alert delivery configured and tested. |
| SI-5 | Security Alerts/Advisories | Partial | Ubuntu via apt updates. No formal CVE tracking. | No CVE feed subscription. |
| SI-5(1) | Automated Alerts | Partial | unattended-upgrades automatic. No CVE notification system. | No automated CVE alerting. |
| SI-7 | Software/Firmware Integrity | **Compliant** | GPG verified repos. OKD SHA256 image digests. Wazuh FIM on all 9 agents (realtime, SHA256 checksums). | None. Session 11: Wazuh FIM deployed platform-wide. |
| SI-7(1) | Integrity Checks | **Compliant** | AIDE on iac-control and GitLab with daily cron scans. Wazuh FIM on all 9 agents provides realtime file integrity monitoring with SHA256 verification. | Sprint 3: AIDE deployed. Session 11: Wazuh FIM on all agents. |
| SI-7(7) | Detection and Response Integration | **Compliant** | Grafana alerts on anomalies. Centralized logs in Loki. | None. |
| SI-8 | Spam Protection | N/A | No email services. | N/A. |
| SI-8(2) | Automatic Updates | N/A | No spam filtering. | N/A. |
| SI-10 | Information Input Validation | Partial | OKD admission controllers. HAProxy protocol validation. | No WAF. |
| SI-11 | Error Handling | **Compliant** | HAProxy generic 503. OKD sanitized errors. Squid standard codes. | None. |
| SI-12 | Information Management/Retention | **Compliant** | Loki 30-day. Logrotate. Git history indefinite. | None. |
| SI-16 | Memory Protection | **Compliant** | ASLR=2. NX active. SELinux/AppArmor enforcing. OKD SCC restrictive. | None. |

### 5.20 SR — Supply Chain Risk Management

**Summary**: 0 Compliant | 2 Partial | 7 Non-Compliant | 3 N/A

**Weakest technical family.** Supply chain risk management is the largest gap area.

| Control | Title | Status | Evidence | Gaps |
|---------|-------|--------|----------|------|
| SR-1 | Policy and Procedures | Non-Compliant | No SCRM policy. | No framework. |
| SR-2 | SCRM Plan | Non-Compliant | No SCRM plan. Container images from quay.io/ghcr.io/docker.io not risk-assessed. | No vendor risk management. |
| SR-2(1) | Establish SCRM Team | N/A | Single operator. | N/A. |
| SR-3 | Supply Chain Controls | Partial | Squid allowlist limits registries. OKD uses official Red Hat images. | No cryptographic verification (cosign). |
| SR-5 | Acquisition Strategies | N/A | FOSS only. | N/A. |
| SR-6 | Supplier Assessments | Non-Compliant | No vendor assessments (Proxmox, Pangolin, Cloudflare). | No supplier risk assessment. |
| SR-8 | Notification Agreements | Non-Compliant | No supplier notification agreements. | Reliance on public disclosure only. |
| SR-10 | Inspection of Components | Non-Compliant | No inspection process. No tamper checks. | No hardware verification. |
| SR-11 | Component Authenticity | Partial | Official sources used (Red Hat, Ubuntu). | No signature verification. |
| SR-11(1) | Anti-Counterfeit Training | N/A | Single operator. | N/A. |
| SR-11(2) | Config Control for Repair | N/A | Self-serviced. | N/A. |
| SR-12 | Component Disposal | Non-Compliant | No disposal process. No sanitization. | No secure disposal. |

---

## 6. Risk Analysis and Prioritized Findings

### 6.1 Critical Findings (Require Immediate Attention)

| # | Finding | Controls | Risk | Recommendation |
|---|---------|----------|------|----------------|
| F-1 | **No vulnerability scanning** | RA-5, RA-5(2) | Unknown vulnerabilities undetected | Deploy Trivy for containers, consider OpenVAS for hosts |
| F-2 | **Vault audit logging disabled** | AU-2, AC-6(9) | Vault operations (cert signing, secret access) completely unaudited | Enable Vault file audit device |
| F-3 | **No file integrity monitoring** | CM-6(2), SI-3(7), SI-7(1) | Cannot detect unauthorized system changes | Deploy AIDE with daily scans |
| F-4 | **Patches pending** | SI-2 | 19+ packages on iac-control, 50+ on GitLab including kernel and GitLab CE | Apply security patches |
| F-5 | **~~Limited backup strategy~~** (FULLY RESOLVED) | CP-9, CP-9(1) | Sprint 4: All critical systems backed up. DR restore tested 2026-02-08: Vault full VM clone restored (~10min RTO), GitLab backup integrity verified. Both CP-9 and CP-9(1) now Compliant. | ~~All items~~ DONE. Backup + restore fully validated. |

### 6.2 High Findings (Address Within 30 Days)

| # | Finding | Controls | Risk | Recommendation |
|---|---------|----------|------|----------------|
| F-6 | **No Incident Response Plan** | IR-1, IR-8 | Operational procedures exist but not organized as formal IRP | Create IRP with standard phases |
| F-7 | **No session timeout** | AC-2(5), AC-11, SC-10 | SSH sessions persist indefinitely | Set TMOUT=900 and SSH ClientAliveInterval |
| F-8 | **Alert notifications not delivered** | SI-4(5), IR-6(1) | Grafana alerts fire but contact point is placeholder | Configure email/webhook delivery |
| F-9 | **No Configuration Management Plan** | CM-9 | No formal CM process documented | Create CM plan document |
| F-10 | **No system use banner** | AC-8 | No legal notice or consent banner on login | Add banner to /etc/issue, /etc/issue.net |
| F-11 | **HTTPS egress broadly allowed** | SC-7(5) | OKD can reach any HTTPS destination (TLS limitation) | Implement DNS-based filtering as compensating control |
| F-12 | **~~No component lifecycle tracking~~** (RESOLVED) | SA-22 | Lifecycle tracker created (Sprint 3). Vault 1.15.4 EOL resolved — upgraded to 1.21.2 (Session 6). No EOL components remaining. | ~~Create lifecycle inventory~~ DONE. Vault upgraded. |
| F-13 | **No MFA for internal admin** | IA-2(1) | Internal SSH uses single-factor (cert only) | Consider TOTP as second factor |
| F-14 | **Vault root token exposed** | IA-5(6) | Token in cleartext in environment/memory | Implement token rotation policy |

### 6.3 Medium Findings (Address Within 90 Days)

| # | Finding | Controls | Risk | Recommendation |
|---|---------|----------|------|----------------|
| F-15 | No SCRM plan | SR-2 | Container registries not risk-assessed | Create lightweight SCRM plan |
| F-16 | No formal policies (CM/CP/MA/IR/MP) | Various -1 | Procedures exist informally | Create policy documents |
| F-17 | Limited IaC coverage | CM-2 | Only iac-control in Ansible (10% of infra) | Expand to GitLab, OKD, Proxmox |
| F-18 | No automated testing | SA-11 | No CI/CD test gates | Add Ansible-lint, smoke tests |
| F-19 | No security metrics | PM-6 | Cannot measure security posture over time | Define 3-5 KPIs |
| F-20 | No CVE tracking | PM-16, SI-5 | Reactive to vulnerabilities | Subscribe to security mailing lists |
| F-21 | Inconsistent log retention | AU-11 | Conflicting logrotate configs (2-30 days) | Standardize to 30-day retention |
| F-22 | Vault uses HTTP internally | SC-8 | Internal network only but still unencrypted | Enable TLS on Vault |
| F-23 | No disk encryption | SC-28 | VM disks unencrypted on Proxmox | Consider LUKS or accept risk |
| F-24 | No media sanitization | MP-6 | Deleted VMs may leave data | Document VM secure erase process |

### 6.4 Low Findings (Address Within 180 Days or Accept Risk)

| # | Finding | Controls | Risk | Recommendation |
|---|---------|----------|------|----------------|
| F-25 | No penetration testing | CA-8 | External attack surface limited (zero-trust) | Run nmap external scan |
| F-26 | No formal ATO | CA-6 | Self-authorized (appropriate for homelab) | Document self-authorization |
| F-27 | No DNSSEC on dnsmasq | SC-20 | Internal zone only | Consider enabling |
| F-28 | NFS not encrypted | SC-8 | NFSv3 without Kerberos | Consider NFSv4/Kerberos |
| F-29 | No supplier assessments | SR-6 | Third-party risks not evaluated | Lightweight vendor review |
| F-30 | Password policy weak | IA-5(1) | 99999-day max age, no complexity | Enforce password policy |

---

## 7. Recommendations

### 7.1 Priority Remediation Roadmap

#### Phase 1: Critical (Week 1-2)

| Action | Effort | Controls Addressed |
|--------|--------|-------------------|
| Enable Vault audit logging | 30 min | AU-2, AC-6(9) |
| Apply pending security patches | 1 hour | SI-2 |
| Deploy Trivy container scanner | 2 hours | RA-5, RA-5(2) |
| Install AIDE file integrity monitoring | 2 hours | CM-6(2), SI-3(7), SI-7(1) |
| Implement etcd backup cronjob | 1 hour | CP-9 |
| Configure GitLab backup automation | 2 hours | CP-9 |

#### Phase 2: High (Week 2-4)

| Action | Effort | Controls Addressed |
|--------|--------|-------------------|
| Create Incident Response Plan | 4 hours | IR-1, IR-8, IR-2, IR-3 |
| Set SSH session timeouts | 30 min | AC-2(5), AC-11, SC-10 |
| Configure Grafana alert delivery | 1 hour | SI-4(5), IR-6(1) |
| Add system use banner | 30 min | AC-8 |
| Create Configuration Management Plan | 3 hours | CM-9 |
| Implement DNS-based egress filtering | 3 hours | SC-7(5) |
| Create component lifecycle inventory | 2 hours | SA-22 |
| Enable TLS on Vault | 2 hours | SC-8 |

#### Phase 3: Medium (Month 2-3)

| Action | Effort | Controls Addressed |
|--------|--------|-------------------|
| Create formal policy documents (CM/CP/MA/IR/MP) | 8 hours | Various -1 controls |
| Expand Ansible to all systems | 16 hours | CM-2, CM-6(1) |
| Add CI/CD test gates (Ansible-lint, smoke tests) | 4 hours | SA-11, SA-11(1) |
| Create SCRM plan | 4 hours | SR-2, PM-30 |
| Define security metrics | 2 hours | PM-6 |
| Subscribe to security advisories | 1 hour | PM-16, SI-5 |
| Standardize log retention to 30 days | 1 hour | AU-11 |
| Implement ClamAV scanning | 2 hours | SI-3 |

#### Phase 4: Low (Month 3-6)

| Action | Effort | Controls Addressed |
|--------|--------|-------------------|
| Run initial penetration test | 4 hours | CA-8 |
| Document self-authorization decision | 1 hour | CA-6, PM-10 |
| Upgrade SmartUPS NMC card for SNMP management | Hardware | PE-11 |
| Consider LUKS disk encryption | 4 hours | SC-28 |
| Document media sanitization procedure | 2 hours | MP-6 |
| Implement OKD NetworkPolicies for egress | 4 hours | SC-7(5) |

### 7.2 Quick Wins (Minimal Effort, High Impact)

1. **Enable Vault audit logging** (30 min) — Addresses F-2, closes major blind spot
2. **Set TMOUT=900 in /etc/profile** (5 min per host) — Addresses F-7, multiple controls
3. **Add login banner** (5 min per host) — Addresses F-10
4. **Apply apt upgrade** (30 min) — Addresses F-4
5. **Configure Grafana contact point** (15 min) — Addresses F-8

### 7.3 Projected Compliance After Phase 1+2

| Rating | Current | After Phase 1+2 (Projected) |
|--------|---------|------------------------------|
| Compliant | 101 (37%) | ~130 (47%) |
| Partial | 108 (39%) | ~100 (36%) |
| Non-Compliant | 67 (24%) | ~46 (17%) |
| N/A + Inherited | 85 | 85 (no change) |

---

## Appendix A — Scoping Justifications

### Controls Scoped as Not Applicable (72 controls)

**AT Family (6 controls)** — All controls require multi-user environment with employees. Single-operator homelab has no workforce to train. Operator possesses technical expertise equivalent to role-based training.

**PS Family (9 controls)** — All controls require organizational personnel management (hiring, screening, termination, sanctions). Single operator with no employees, contractors, or external personnel.

**PT Family (13 controls)** — Entire family addresses PII processing and transparency. System processes only infrastructure telemetry and media content. No personal data is collected, stored, processed, or transmitted.

**PM Organizational Controls (10 controls)** — PM-1/2/3/7/8/13/15/17/25/32 are organizational-level controls requiring CISO roles, budgets, enterprise architecture, workforce programs, and privacy management. Not applicable to single-operator homelab.

**Other Scoped Controls (34 controls across AC, IA, CP, CM, SA, SR, MP, PE, RA, CA)** — Individual justifications documented per control in Sections 5.1-5.20. Common reasons: no wireless (AC-18/19), no mobile devices (AC-19), server-only environment (AC-11(1)), non-federal (IA-2(12), IA-8(1), SA-4(10)), FOSS-only (SA-1/2/4/4(1)), no transactional workloads (CP-10(2)), etc.

**LXC Audit Acceptance (AU-2, AU-3)** — LXC containers (`minio-bootstrap`, `config-server`) share the host kernel and cannot run independent `auditd` services. Risk is accepted as these are internal-only infrastructure components. Compensating control: Auditd is active on the Proxmox hypervisor hosting these LXCs.

### Controls Inherited from Environment (15 controls)

All PE family inheritances from residential physical security. Justification: Homelab servers in private residence. Physical access requires building entry (locks, alarm). Datacenter-grade controls (mantraps, biometrics, fire suppression, redundant power, humidity control) are not applicable or cost-effective for the risk level. Physical security posture is commensurate with data sensitivity (Low confidentiality, no regulated data).

---

## Appendix A.1 — CIS Risk Acceptances (Sprint 6)

The following Wazuh CIS benchmark failures are accepted with documented justification. Approximately 200 CIS check failures across 9 agents fall into these categories:

| Category | CIS Failures | Justification | Revisit Trigger |
|----------|-------------|---------------|-----------------|
| **Partition hardening** | ~153 (17 checks x 9 agents) | VMs use cloud-init single-disk layouts. Repartitioning requires full VM rebuild. Risk: low (no multi-tenant, physical security compensates). | VM rebuild/migration to partitioned layout |
| **AppArmor on Proxmox** | ~27 (3 checks x 9 agents) | Proxmox hypervisors use their own security model (cgroups, namespaces, KVM isolation). CIS Debian expects userspace AppArmor which conflicts with Proxmox architecture. Ubuntu VMs have AppArmor active. | Proxmox upstream changes or security incident |
| **Bootloader password** | ~9 (1 check x 9 agents) | Proxmox console access requires hypervisor authentication. VMs don't expose GRUB to end users. Physical security (residential, locked) compensates. | Remote console exposure or physical security change |
| **IPv6 firewall** | ~9 (1 check x 9 agents) | IPv6 not deployed on this network. No IPv6 addresses assigned, no IPv6 routing configured. | IPv6 deployment on any infrastructure segment |

**Total risk-accepted**: ~200 CIS failures documented. These do not represent NIST control gaps — they are CIS benchmark checks that don't apply to this architecture.

---

## Appendix B — Evidence Sources

### Live System Inspection

| System | Method | Items Inspected |
|--------|--------|----------------|
| iac-control (192.168.12.210) | SSH (Vault cert) | iptables (35 rules), sshd_config, Squid config + allowlist (24 domains), HAProxy config, dnsmasq config, /etc/passwd, /etc/shadow, /etc/sudoers, AppArmor (121 profiles), kernel params (sysctl), unattended-upgrades, logrotate, Loki/Promtail (Docker), /var/log/* |
| GitLab (192.168.12.68) | SSH (Vault cert) | sshd_config, /etc/passwd, AppArmor (119 profiles), GitLab config (/etc/gitlab/), unattended-upgrades, packages (dpkg -l) |
| Pangolin (192.168.12.168) | SSH (Vault cert) | Traefik config, TLS ciphers, WireGuard status |
| Vault (192.168.12.206) | API | /v1/sys/health, /v1/sys/audit, /v1/ssh/config/ca, /v1/ssh/roles/admin, auth methods, policy configuration |
| OKD Masters (10.0.0.221-223) | SSH via jump + oc CLI | RBAC (clusterrolebindings, rolebindings), SCC (SecurityContextConstraints), OAuth config, clusteroperators (35), disk encryption (LUKS check), SELinux status, OVNKubernetes config, etcd encryption, image.config, MachineConfigs |
| Proxmox (192.168.12.6/.56/.57) | Terraform state analysis | VM inventory, resource allocation, network configuration |

### Documentation Reviewed

| Document | Location | Purpose |
|----------|----------|---------|
| SSP-overwatch-platform.md | ~/claude-memory/ | System Security Plan |
| network-hardening-docs.md | ~/claude-memory/ | Architecture, hardening, break-glass |
| network-hardening-state.md | ~/claude-memory/ | NIST compliance matrix |
| ac2-account-inventory.md | sentinel-iac/compliance/ | Account inventory |
| sc7-5-implementation.md | sentinel-iac/compliance/ | SC-7(5) HTTPS gap documentation |
| rollback-firewall.sh | /opt/rollback/ | Firewall rollback script (tested) |
| rollback-all.sh | /opt/rollback/ | Full rollback script |
| iac-control.yml | sentinel-iac/ansible/ | Ansible baseline playbook |

### API/CLI Queries

| Tool | Queries |
|------|---------|
| oc (OKD CLI) | get clusterrolebindings, get rolebindings -A, get scc, get oauth cluster, get clusteroperators, get csv -A, get image.config, get machineconfigs, get peerauthentication -A, get clusterpolicy -A, get networkpolicy -A |
| curl (Vault API) | /v1/sys/health, /v1/sys/audit, /v1/ssh/config/ca, /v1/ssh/roles/admin |
| curl (Grafana) | /api/v1/provisioning/alert-rules, /api/datasources |
| Wazuh API | Agent status (9 connected), SCA results (11/11 checks), FIM configuration, vulnerability records (23,198), Active Response rules, custom rules (60+), decoders |
| Istio/Kiali | PeerAuthentication mesh-wide config, mTLS status, traffic visualization |
| Kyverno | 5 cluster policies: disallow-privileged-containers, require-labels, require-run-as-nonroot, restrict-image-registries, require-resource-limits |
| Jaeger | Distributed tracing spans for meshed services |

---

## Document Control

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-02-06 | Automated Assessment Team | Initial full NIST 800-53 assessment |
| 1.1 | 2026-02-07 | Automated Assessment Team | Sprint 1 documentation remediation: Updated 16 control ratings based on documenting existing infrastructure (dual WAN, DR Site (810), B2 backup, UPS, AI operating model). CP family +8C, PE +2P, AC/CM/CA +1P each. Overall: 92→101 Compliant, 77→67 NC. |
| 1.2 | 2026-02-07 | Automated Assessment Team | Sprint 2 DevSecOps pipeline implementation: Updated 13 control ratings based on GitLab CI/CD security scanning deployment (Trivy, tflint, ansible-lint, yamllint, gitleaks). SA family +3C/-3NC, CM +2C/-2NC, RA +1P/-1NC, CA +1C, IA +1C/-1NC, PM +2C/-2NC. Overall: 101→~119 Compliant, 67→~55 NC (+18 Compliant, -12 NC). |
| 1.3 | 2026-02-07 | Automated Assessment Team | Sprint 3 Infrastructure Hardening & Compliance Documentation: Updated 17 control ratings. Session security (AC-2(5), AC-8, AC-11, SC-10), FIM (CM-6(2), SI-3(7), SI-7(1)), backups (CP-9), IR plan (IR-1, IR-2, IR-3, IR-8), CM plan (CM-9), lifecycle tracking (SA-22), alert delivery (SI-4(5), IR-6(1)), log retention (AU-11). Overall: ~119→~129 Compliant, ~55→~46 NC (+10C, -9NC). |
| 1.4 | 2026-02-07 | Automated Assessment Team | Hybrid seedbox architecture: qBittorrent+gluetun VPN migrated from OKD privileged pod to dedicated VM 109 (pve3). Sonarr/Radarr/Prowlarr remain on OKD with standard anyuid SCC. Privileged SCC removed from OKD — compliance improvement for SC-39, SI-3. Removed decommissioned n8n (202) and ManageIQ (203) from inventory. No control rating changes (already compliant). |
| 1.5 | 2026-02-08 | Automated Assessment Team | Sprint 4 DR Automation + Vault Upgrade + DR Testing. DR Runbook, backup timers, MinIO replication, restore scripts, CI DR jobs all deployed. Vault upgraded 1.15.4→1.21.2 (SA-22→C). DR test validated: Vault full VM clone restored in ~10min, GitLab backup integrity confirmed. Controls improved: CP-2→C, CP-2(1)→C, CP-2(3)→C, CP-2(8)→C, CP-3(1)→C, CP-4→C, CP-7(3)→C, CP-9(1)→C, CP-9(8)→C, CP-10→C, CP-10(4)→C, SA-22→C. CP family: 8→19 Compliant, 10→3 Partial, 9→5 NC. IR family summary corrected: 5C/8P/4NC. CM family summary corrected: 5C/14P/8NC. Overall: ~132→~144 Compliant, ~98→~90 Partial, ~46→~42 NC (+12C, -4NC). |
| 1.6 | 2026-02-08 | Automated Assessment Team | Wazuh CIS SCA cross-reference: Downgraded 3 controls based on Wazuh evidence from 9 agents (1,012 CIS failures analyzed). AU-3(1): Compliant→Partial (no auditd, 98% CIS fail rate). AU-7: Compliant→Partial (no kernel audit reduction, 73% CIS fail rate). AC-6(2): Compliant→Partial (PermitRootLogin enabled, NOPASSWD sudo). AU family: 10C/11P→8C/13P. AC family: 12C/17P→11C/18P. Added POA&M item P2-11 (deploy auditd). Net: ~160→~157 Compliant (-3). Wazuh SIEM deployment (9 agents) added to evidence base. |
| 1.7 | 2026-02-08 | Automated Assessment Team | Sprint 6 Wazuh/NIST CIS Remediation: Upgraded AU-3(1), AU-7, AC-6(2) back to Compliant after deploying via Ansible common role: SSH hardening (MACs, MaxAuthTries, PermitRootLogin, DisableForwarding, MaxStartups, LoginGraceTime, ClientAliveInterval), PAM hardening (faillock, pwquality, pwhistory, login.defs, nullok removal), OS hardening (cron perms, su restriction, sudo logging, 14 sysctl params, insecure pkg removal), auditd (comprehensive CIS rules, immutable), ufw firewall (default-deny on 6 managed VMs). Inventory expanded: +pangolin-proxy, +wazuh-server (7 total). Risk acceptances documented: partition hardening, AppArmor/Proxmox, bootloader, IPv6. AU family: 8C/13P→10C/11P. AC family: 11C/18P→12C/17P. Net: ~157→~162 Compliant (+5). Projected CIS failures: 1,012→~638. |
| 1.8 | 2026-02-09 | Automated Assessment Team | Sessions 11-13 update: Wazuh SIEM full deployment (9 agents, 8 phases, 60+ custom rules, FIM, Active Response, VirusTotal, compliance automation 11/11 daily, vulnerability baseline 23,198 records). Istio v1.28.3 service mesh with mTLS (PERMISSIVE). Kyverno policy engine (5 cluster policies). OKD NetworkPolicies (default-deny + allow in 6 namespaces). Jaeger distributed tracing. Kiali mesh visualization. Sprint 6 CIS hardening (auditd, PAM, SSH, ufw, OS). Proxmox CVE patching (OpenSSL 3.5.4, telnet removed). Vault TLS enabled (commit 6b1f71c). Controls improved: SI-3→C, SI-3(7)→C, SI-4 enhanced, SI-7(1) enhanced, CM-6→C, CM-7→C, AC-6→C, CA-7 enhanced, RA-5→C, SC-7/SC-8/SC-23 enhanced. Overall: ~162→~175 Compliant (~63%). |
| 1.9 | 2026-02-09 | Automated Assessment Team | Session 17 Keycloak SSO deployment (Sprint 8): Keycloak 26.x deployed on OKD with PostgreSQL 16 backend. Sentinel realm with admin/operator/viewer groups. OIDC integration with OKD (OAuth provider alongside HTPasswd), ArgoCD (replaced Dex), and Grafana (generic_oauth). Client secrets in Vault. Password policy (12-char, complexity), brute force protection (5 attempts, 15-min lockout), session timeouts (10h max, 30m idle). ArgoCD RBAC improved with `infra` AppProject for cluster-scoped resources. Controls improved: AC-2→C (centralized identity), AC-2(1)→C (automated provisioning), AC-7→C (brute force protection), AC-12→C (session termination), IA-2 enhanced (SSO), IA-5→C (password policy), IA-5(1)→C (password requirements). AC family: 12C/17P→16C/13P. IA family: 8C/9P→11C/6P. Overall: ~175→~185 Compliant (~67%). |
| 2.0 | 2026-02-13 | Governance Auditor (Conductor) | SIEM & Governance Remediation: Updated AU-2 and AU-3(1) to Partial for LXC containers. Added LXC Audit Risk Acceptance to Appendix A. Validated Wazuh manager and agent IaC roles. Remediated config-server auditd failure. |

**Assessment Certification**: This Security Assessment Report documents the findings of a comprehensive assessment of the Overwatch Platform against the NIST SP 800-53 Rev 5 Moderate baseline. The assessment was conducted using live system inspection, documentation review, and API interrogation. All findings are based on evidence observed during the assessment period.

---

*Generated 2026-02-06 | Updated 2026-02-09 (v1.9: Session 17 — Keycloak SSO, OIDC integration OKD/ArgoCD/Grafana, ArgoCD RBAC improvement) | NIST SP 800-53 Rev 5 Moderate Baseline | 366 Controls Assessed*
