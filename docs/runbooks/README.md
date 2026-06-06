# Operational Runbooks — Project Sentinel

Standard operating procedures for the Overwatch platform.
These runbooks assume access to iac-control (192.168.12.210) and a valid Vault token.

## Runbook Index

| Runbook | Scenario | Criticality |
|---------|----------|-------------|
| [01-vault-unseal.md](01-vault-unseal.md) | Vault is sealed after restart | Critical |
| [02-okd-node-recovery.md](02-okd-node-recovery.md) | OKD node failure/drain/reboot | High |
| [03-wazuh-alert-response.md](03-wazuh-alert-response.md) | Responding to Wazuh security alerts | High |
| [04-service-recovery-order.md](04-service-recovery-order.md) | Full platform recovery after outage | Critical |
| [05-vault-root-token-rotation.md](05-vault-root-token-rotation.md) | Rotating the Vault root token | Medium |
| [06-certificate-renewal.md](06-certificate-renewal.md) | SSH cert / TLS cert expired | Medium |
| [07-postgresql-crash-recovery.md](07-postgresql-crash-recovery.md) | PostgreSQL crash loop on iSCSI | Medium |
| [08-break-glass.md](08-break-glass.md) | Emergency access without operator | Critical |
| [09-sentinel-agent-change-freeze.md](09-sentinel-agent-change-freeze.md) | sentinel-agent Tier 2 change-freeze | Medium |
| [10-sentinel-agent-maintenance-lock.md](10-sentinel-agent-maintenance-lock.md) | sentinel-agent halt lock for hands-on work | Medium |
| [11-supply-chain-security-scan.md](11-supply-chain-security-scan.md) | Supply-chain image scan + verification | Medium |
| [12-upstream-image-trust.md](12-upstream-image-trust.md) | Trust new upstream image / cosign keys | Medium |
| [13-vault-autounseal-token-ttl-monitor.md](13-vault-autounseal-token-ttl-monitor.md) | Vault auto-unseal token TTL early-warning monitor (deploy + interpret) | High |
| [14-iac-drift-detection.md](14-iac-drift-detection.md) | IaC drift detection harness (deploy + interpret + add rules) | High |
| [15-vault-autounseal-rotation.md](15-vault-autounseal-rotation.md) | Rotate Vault auto-unseal Transit key | Medium |
| [16-okd-sandbox-provisioning.md](16-okd-sandbox-provisioning.md) | Provision OKD sandbox environment | Medium |
| [17-langfuse-clickhouse-schema-reinit.md](17-langfuse-clickhouse-schema-reinit.md) | Langfuse ClickHouse schema re-initialisation | Medium |
| [18-falco-event-capture.md](18-falco-event-capture.md) | Capture and triage Falco runtime security events | Medium |
| [19-pve-vm-lock-recovery.md](19-pve-vm-lock-recovery.md) | PVE VM stale lock (snapshot-delete) recovery | Medium |
| [20-truenas-update.md](20-truenas-update.md) | Controlled TrueNAS SCALE update procedure | High |
| [30-renovate-deployment.md](30-renovate-deployment.md) | Renovate dependency-update bot deployment (planning) | Medium |

## Service Dependency Graph

```
Vault (must be unsealed first)
├── SSH Certificates (all remote access depends on Vault)
├── External Secrets Operator (pulls secrets for all apps)
│   ├── Keycloak (SSO for everything)
│   │   ├── Plane, Grafana, ArgoCD, Backstage, Element (OIDC)
│   │   └── oauth2-proxy (Pangolin ForwardAuth)
│   ├── Harbor (image registry — needed for pod restarts)
│   └── All app database credentials
├── Prometheus token (vault-token for metrics)
└── sentinel-agent (AppRole auth)

ArgoCD (manages all OKD workloads)
├── Depends on: Vault (ESO), Harbor (images)
└── Manages: all app deployments via GitOps

TrueNAS iSCSI (192.168.12.205:3260)
├── All PostgreSQL PVCs (7 databases)
└── If down: all DB-backed services fail

iac-control (192.168.12.210)
├── HAProxy → Istio IngressGateway (routes external traffic)
├── MinIO replication timer
├── Prometheus + exporters
├── sentinel-agent (autonomous monitoring)
└── SSH CA access point
```
