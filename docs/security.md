# Security Architecture

## Keycloak SSO

**URL**: `https://auth.208.haist.farm` (internal) / `https://auth.haist.farm` (external)

Keycloak provides centralized identity management for all platform services via OIDC.

### Realm Configuration

- **Realm**: `sentinel`
- **Groups**: `admin`, `operator`, `viewer` (RBAC)
- **OIDC Clients**:

| Client | Service | Redirect URI |
|--------|---------|-------------|
| grafana | Grafana | `https://grafana.208.haist.farm/login/generic_oauth` |
| argocd | ArgoCD | `https://argocd.208.haist.farm/auth/callback` |
| okd-console | OKD Console | `https://console.208.haist.farm/auth/callback` |
| cloudflare-access | Cloudflare Access | Cloudflare callback URL |

### External Access

GitLab and Keycloak are accessible externally via Cloudflare Tunnel with Cloudflare Access providing an additional authentication layer using Keycloak as the OIDC identity provider.

## HashiCorp Vault

**URL**: `https://vault.208.haist.farm` | **Version**: 1.21.2

Vault manages all platform secrets with KV v2 secret engine.

### Secret Paths

| Path | Contents |
|------|----------|
| `secret/gitlab` | GitLab PAT and runner tokens |
| `secret/proxmox*` | Proxmox API credentials |
| `secret/minio*` | MinIO access keys |
| `secret/backblaze` | B2 backup credentials |
| `secret/cloudflare/*` | Tunnel tokens, API keys |
| `secret/unifi` | UniFi API key |
| `secret/wazuh/*` | Wazuh API credentials |
| `secret/keycloak/*` | OIDC client secrets |
| `secret/harbor` | Harbor admin + secret key |
| `secret/defectdojo` | DefectDojo admin + API token |
| `secret/ssh/sentinel` | SSH signing CA |
| `secret/vault/root-token` | Vault root token (emergency use) |

### Auth Methods

- **Token**: Automation token (`claude-automation` policy) for CI/CD
- **Kubernetes**: OKD service accounts via External Secrets Operator (ESO)
- **SSH signing**: JIT SSH certificates for time-limited access

### External Secrets Operator

ESO (v0.11.0) bridges Vault secrets into OKD:

- **ClusterSecretStore**: `vault-backend` (Vault kubernetes auth, role `external-secrets`)
- **Policy**: `eso-read-keycloak` (read-only on `secret/data/keycloak/*`)
- Manages ArgoCD OIDC secret via `creationPolicy: Merge` on `argocd-secret`

## Wazuh SIEM

**URL**: `https://wazuh.208.haist.farm` | **Version**: 4.14.1

### Deployment

- **Server**: 192.168.12.100 (VM 111 on 208-pve2)
- **Agents**: 9 deployed across all managed VMs
- **Rules**: 8616 total (77+ custom)

### Custom Rule Ranges

| Range | Purpose |
|-------|---------|
| 100410–100417 | FIM expansion (sshd, pam, sudoers, cron) |
| 100420–100428 | Drift detection + remediation + maintenance mode |
| 100500–100513 | UniFi network monitoring |

### Alerting

Level 10+ alerts are forwarded to Discord via webhook for real-time notification.

## Kyverno Policy Enforcement

Kyverno enforces OKD cluster policies:

- Pod security standards
- Image pull policies (require Harbor registry)
- Resource quota enforcement
- Label requirements

Policies are managed in `overwatch-gitops/apps/kyverno-policies/` and synced by ArgoCD.

## Network Security

### Firewall

- UFW enabled on all VMs (per-host port allowlists via Ansible)
- iptables on iac-control for Squid transparent proxy and OKD traffic routing

### Egress Control

- Squid proxy on iac-control allowlists outbound domains for the OKD cluster
- iptables redirects port 80 traffic through Squid

### TLS

- All internal services use Let's Encrypt wildcard certificate for `*.208.haist.farm`
- Certificate obtained via Cloudflare DNS-01 challenge on Traefik
- Vault has direct TLS on port 8200 (same wildcard cert)

### CrowdSec

CrowdSec provides intrusion prevention via community blocklists and local log analysis. Deployed via Ansible role on select VMs.
