# Sentinel IaC Platform

Infrastructure-as-Code repository for **Project Sentinel** — a hybrid-cloud homelab platform built on Proxmox virtualization, OKD 4.19 Kubernetes, and GitOps automation.

## Platform Overview

Sentinel is a 3-site hybrid-cloud deployment managing 42+ services across:

- **3 Proxmox hosts** — `pve` (32 CPU/62GB), `208-pve2` (36 CPU/125GB), `pve3` (32 CPU/125GB)
- **OKD 4.19 cluster** (Overwatch) — 3 master nodes on internal network `10.0.0.0/24`
- **9 VMs + 2 LXC containers** — purpose-built infrastructure nodes
- **18 internal services** at `*.208.haist.farm` + 2 external at `*.haist.farm`

## GitOps Workflow

```
Edit locally → git push → GitLab CI (lint/scan) → Manual trigger (build/provision/configure)
                                                  → ArgoCD auto-sync (overwatch-gitops)
```

- **sentinel-iac** — Ansible, Terraform, Packer. CI runs lint + security scans on every push. Build/provision/configure stages are manual-trigger on `main`.
- **overwatch-gitops** — OKD manifests. Pushing to `main` triggers ArgoCD auto-sync (pushing is deploying).

## Quick Links

| Service | URL | Purpose |
|---------|-----|---------|
| GitLab | [gitlab.haist.farm](https://gitlab.haist.farm) | CI/CD and source control |
| ArgoCD | [argocd.208.haist.farm](https://argocd.208.haist.farm) | GitOps deployment |
| Grafana | [grafana.208.haist.farm](https://grafana.208.haist.farm) | Observability dashboards |
| Vault | [vault.208.haist.farm](https://vault.208.haist.farm) | Secrets management |
| Keycloak | [auth.208.haist.farm](https://auth.208.haist.farm) | SSO identity provider |
| Harbor | [harbor.208.haist.farm](https://harbor.208.haist.farm) | Container registry |
| DefectDojo | [defectdojo.208.haist.farm](https://defectdojo.208.haist.farm) | Vulnerability management |
| Wazuh | [wazuh.208.haist.farm](https://wazuh.208.haist.farm) | SIEM |
| Homepage | [home.208.haist.farm](https://home.208.haist.farm) | Service dashboard |

## Repository Structure

```
sentinel-iac/
├── ansible/              # Configuration management
│   ├── inventory/        # Host definitions (hosts.ini)
│   ├── playbooks/        # Per-VM playbooks
│   └── roles/            # Reusable roles (common, docker-host, etc.)
├── infrastructure/       # Provisioning and recovery
│   ├── managed/          # Terraform (OpenTofu) VM definitions
│   ├── modules/vm/       # Reusable VM module
│   ├── bootstrap/        # DR-only bootstrap layer
│   └── recovery/         # Restore scripts (vault, gitlab, minio, etcd)
├── packer/               # Golden image templates
├── ci/                   # CI pipeline includes (security, compliance, DR)
├── pangolin/             # Traefik reverse proxy config (mirrors live)
├── compliance/           # NIST 800-53 artifacts
├── scripts/              # Utility scripts (compliance, vault, mesh)
└── policies/             # Kyverno and security policies
```

## CI Pipeline

**Stages**: `lint` → `security-scan` → `upload-to-defectdojo` → `packer-validate` → `build-templates` → `provision` → `configure` → `compliance-report` → `disaster-recovery`

Automated on every push: yamllint, ansible-lint, gitleaks (secret detection), trivy (IaC + filesystem scan). Results uploaded to DefectDojo for tracking.
