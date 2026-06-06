# Keycloak SSO Architecture
## Overwatch Platform — Identity Provider Design

**Document Classification**: INTERNAL — FOR PORTFOLIO USE
**Created**: 2026-02-09
**System**: Overwatch Platform (OKD 4.19 on Proxmox)
**Owner**: Haists Consulting
**Version**: 1.0

---

## 1. Architecture Overview

Keycloak 26.x serves as the centralized identity provider for the Overwatch platform, providing Single Sign-On (SSO) via OpenID Connect (OIDC) across all platform services.

```
                    ┌──────────────────────────────────────────┐
                    │           KEYCLOAK 26.x SSO               │
                    │        auth.208.haist.farm                 │
                    │     OKD namespace: keycloak                │
                    │                                            │
                    │  ┌──────────────────────────────────────┐ │
                    │  │  Sentinel Realm                       │ │
                    │  │  ┌─────────────────────────────────┐ │ │
                    │  │  │  Groups:                         │ │ │
                    │  │  │  ├── admin    → full access      │ │ │
                    │  │  │  ├── operator → read/write       │ │ │
                    │  │  │  └── viewer   → read-only        │ │ │
                    │  │  └─────────────────────────────────┘ │ │
                    │  │                                       │ │
                    │  │  Security:                            │ │
                    │  │  • Brute force: 5 attempts, 15m lock  │ │
                    │  │  • Password: 12-char, complexity      │ │
                    │  │  • Sessions: 10h max, 30m idle        │ │
                    │  └──────────────────────────────────────┘ │
                    └──────────────┬───────────────────────────┘
                                   │ OIDC
                    ┌──────────────┼───────────────────────────┐
                    │              │                            │
              ┌─────▼─────┐ ┌────▼────┐ ┌────▼────┐
              │  OKD      │ │ ArgoCD  │ │ Grafana │
              │  OAuth    │ │  OIDC   │ │  OAuth  │
              │           │ │         │ │         │
              │ +HTPasswd │ │ Replaced│ │ Generic │
              │  (backup) │ │   Dex   │ │  OAuth  │
              └───────────┘ └─────────┘ └─────────┘
```

### Deployment Details

| Component | Detail |
|-----------|--------|
| **Image** | `quay.io/keycloak/keycloak:26.0` |
| **Database** | PostgreSQL 16 (`docker.io/library/postgres:16`) |
| **Namespace** | `keycloak` on OKD |
| **Route** | `auth.208.haist.farm` (edge TLS, redirect insecure) |
| **Storage** | NFS PersistentVolumeClaim (`nfs-storage` StorageClass) |
| **DNS** | Internal override via dnsmasq (`auth.208.haist.farm → 10.0.0.1`) |
| **TLS** | Self-signed certificate on OKD route, CA trust configured for OAuth |

---

## 2. OIDC Client Configuration

### Client List

| Client ID | Service | Redirect URI | Token Settings |
|-----------|---------|--------------|----------------|
| `okd-console` | OKD Console/OAuth | `https://oauth-openshift.apps.overwatch.haist.farm/oauth2callback/keycloak` | Access: 5m, Refresh: 30m |
| `argocd` | ArgoCD | `https://argocd.208.haist.farm/auth/callback` | Access: 5m, Refresh: 30m |
| `grafana` | Grafana | `https://grafana.208.haist.farm/login/generic_oauth` | Access: 5m, Refresh: 30m |
| `forgejo` | Forgejo Git host | `https://forgejo.208.haist.farm/user/oauth2/keycloak/callback` | Access: 5m, Refresh: 30m |

### Protocol Mappers

All clients include a `groups` protocol mapper:
- Type: `oidc-group-membership-mapper`
- Claim name: `groups`
- Added to: ID token, access token, userinfo

### Secret Management

Client secrets are stored in HashiCorp Vault:
- `secret/keycloak/okd-console` — OKD OAuth client secret
- `secret/keycloak/argocd` — ArgoCD OIDC client secret
- `secret/keycloak/grafana` — Grafana OAuth client secret
- `secret/keycloak/forgejo` — Forgejo OIDC client secret

OKD-side secrets:
- `keycloak-okd-secret` in `openshift-config` namespace
- `argocd-keycloak-secret` in `openshift-gitops` namespace
- `grafana-keycloak-secret` in `monitoring` namespace

---

## 3. RBAC Mapping

### Group-to-Role Matrix

| Keycloak Group | OKD Role | ArgoCD Role | Grafana Role |
|----------------|----------|-------------|--------------|
| `admin` | cluster-admin | role:admin | Admin |
| `operator` | basic-user | role:operator | Editor |
| `viewer` | basic-user | role:viewer | Viewer |

### ArgoCD RBAC Policy

```csv
g, admin, role:admin
g, operator, role:operator
g, viewer, role:viewer
p, role:operator, applications, *, */*, allow
p, role:operator, logs, get, */*, allow
p, role:viewer, applications, get, */*, allow
p, role:viewer, logs, get, */*, allow
```

**AppProject RBAC** (Task #10 — CM-3/AC-3 improvement):
- `default` AppProject: application-scoped resources only
- `infra` AppProject: cluster-scoped resources (Namespaces, ClusterRoles, etc.)
- Admin group has access to both projects; operator/viewer restricted to `default`

### Grafana Role Mapping

Grafana `auth.generic_oauth` configuration maps Keycloak groups to org roles:
- `role_attribute_path`: JMESPath expression evaluating `groups` claim
- Admin group → GrafanaAdmin, Operator → Editor, Viewer → Viewer

---

## 4. Security Controls

### Authentication Security

| Control | Implementation |
|---------|---------------|
| **Password Policy** | 12 characters minimum, uppercase, lowercase, digit, special character required |
| **Brute Force Protection** | Max 5 failed attempts, 15-minute lockout, permanent lockout after 30 failures |
| **Session Max Lifetime** | 10 hours |
| **Session Idle Timeout** | 30 minutes |
| **MFA Support** | TOTP and WebAuthn supported (not yet enforced — Phase 2) |

### NIST 800-53 Controls Addressed

| Control | Title | How Addressed |
|---------|-------|---------------|
| IA-2 | Identification and Authentication | Centralized OIDC SSO for all platform services |
| IA-2(1) | MFA to Privileged Accounts | MFA capability deployed, enforcement planned Phase 2 |
| IA-5 | Authenticator Management | Password policy, brute force protection, credential rotation |
| IA-5(1) | Password-Based Authentication | 12-char min, complexity, aging requirements |
| AC-2 | Account Management | Centralized identity with group-based RBAC |
| AC-2(1) | Automated Account Management | OIDC federation auto-provisions users |
| AC-3 | Access Enforcement | Group claims enforce RBAC across services |
| AC-7 | Unsuccessful Logon Attempts | Brute force protection (5 attempts, 15-min lockout) |
| AC-11 | Device Lock | SSO idle timeout (30 min) |
| AC-12 | Session Termination | SSO session max lifetime (10h), idle timeout (30m) |

---

## 5. Phase Rollout Plan

### Phase 1: Core Platform SSO (COMPLETE — Session 17)

| Service | Status | Notes |
|---------|--------|-------|
| Keycloak deployment | COMPLETE | OKD namespace, PostgreSQL backend |
| Sentinel realm config | COMPLETE | Groups, password policy, brute force protection |
| OKD OAuth | COMPLETE | Keycloak + HTPasswd (backup) |
| ArgoCD OIDC | COMPLETE | Replaced Dex, full RBAC mapping |
| Grafana OIDC | COMPLETE | Generic OAuth, role mapping |
| Homepage dashboard | COMPLETE | Keycloak entry added |

### Phase 2: MFA Enforcement + Extended SSO

| Service | Status | Effort |
|---------|--------|--------|
| Enable MFA (TOTP) for admin group | PLANNED | 2 hrs |
| Vault OIDC integration | PLANNED | 4 hrs |
| Wazuh SSO | PLANNED | 3 hrs |

### Phase 3: External Access SSO

| Service | Status | Effort |
|---------|--------|--------|
| Pangolin external tunnel SSO via Keycloak | PLANNED | 4 hrs |
| Replace Pangolin cloud SSO with self-hosted | PLANNED | 3 hrs |

### Phase 4: Media Services SSO

| Service | Status | Effort |
|---------|--------|--------|
| Jellyfin SSO | PLANNED | 3 hrs |
| Sonarr/Radarr/Prowlarr SSO (if supported) | PLANNED | 4 hrs |

---

## 6. Known Limitations

| Limitation | Impact | Mitigation |
|-----------|--------|------------|
| Self-signed TLS on Keycloak route | OAuth requires explicit CA trust configuration | CA cert injected into OKD OAuth config; internal DNS override via dnsmasq |
| MFA not yet enforced | IA-2(1)/IA-2(2) remain Partial | Planned for Phase 2 |
| HTPasswd retained as OKD backup | Dual authentication path | Required for break-glass access if Keycloak is down |
| Keycloak first boot ~75s | Longer initial startup due to `--optimized=false` | Subsequent boots ~14s; liveness/readiness probes tuned accordingly |

---

*Created 2026-02-09 | Session 17 — Keycloak SSO Phase 1 Deployment | Based on SSP-overwatch-platform.md v1.5, SAR v1.9*
