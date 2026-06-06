# Kubernetes Authentication

## Overview

Vault's Kubernetes auth method allows OKD workloads to authenticate using their service account tokens. This is the foundation for the External Secrets Operator (ESO) integration that populates Kubernetes Secrets from Vault data.

```
  OKD Pod (e.g., ESO controller)
       |
  ServiceAccount token (JWT)
       |
       v
  Vault K8s auth (/auth/kubernetes/login)
       |
  Validates JWT against OKD API
       |
       v
  Returns Vault token with scoped policy
       |
       v
  Pod reads secrets via Vault API
```

## Auth Method Configuration

The Kubernetes auth method is mounted at `kubernetes/`. It validates service account JWTs against the OKD API server.

The Docker Compose configuration includes an `extra_hosts` entry that maps `api.overwatch.haist.farm` to `192.168.12.210` (iac-control, which runs the HAProxy load balancer for the OKD API on port 6443). This enables the Vault container to reach the Kubernetes API for token review.

[VERIFY: The exact Kubernetes auth configuration (host URL, CA cert, token reviewer JWT) should be confirmed via `vault read auth/kubernetes/config`.]

## Auth Roles

### external-secrets

| Setting | Value |
|---------|-------|
| Bound service account | `vault-auth` |
| Bound namespace | `external-secrets` |
| Policies | `external-secrets` |
| TTL | [VERIFY: Check via `vault read auth/kubernetes/role/external-secrets`] |

This role is used by the ESO `ClusterSecretStore` named `vault-backend`.

### sentinel-ops

| Setting | Value |
|---------|-------|
| Bound service account | `sentinel-ops-sa` |
| Bound namespace | `sentinel-ops` |
| Policies | `sentinel-ops` |
| TTL | [VERIFY: Check via `vault read auth/kubernetes/role/sentinel-ops`] |

Used by sentinel-ops CronJobs for accessing MinIO, Wazuh, GitLab, Proxmox, and Grafana credentials.

## ClusterSecretStore

The central ESO store definition lives at `overwatch-gitops/apps/external-secrets/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault-backend
spec:
  provider:
    vault:
      server: "https://vault.208.haist.farm"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "external-secrets"
          serviceAccountRef:
            name: "vault-auth"
            namespace: "external-secrets"
          secretRef:
            name: "vault-auth-token"
            namespace: "external-secrets"
            key: "token"
```

Key details:

- **`server`** -- Uses the Traefik-routed hostname (not direct IP), since OKD pods cannot reach `192.168.12.0/24` (management VLAN). Traffic routes via pangolin-proxy.
- **`path: "secret"`** -- KV v2 mount path.
- **`version: "v2"`** -- KV v2 engine.
- **`role: "external-secrets"`** -- Vault K8s auth role.
- **`vault-auth-token`** -- A Kubernetes Secret containing the service account token for Vault authentication.

## ExternalSecrets Inventory

34 ExternalSecrets across 12 namespaces, all using the `vault-backend` ClusterSecretStore:

| Namespace | ExternalSecret Name | Vault Path(s) |
|-----------|-------------------|---------------|
| **backstage** | backstage-credentials | `backstage` |
| **backstage** | backstage-postgresql | `keycloak/backstage` |
| **defectdojo** | defectdojo-credentials | `defectdojo` |
| **defectdojo** | defectdojo-extrasecrets | `defectdojo` |
| **defectdojo** | defectdojo-postgresql | `defectdojo` |
| **defectdojo** | defectdojo-postgresql-specific | `defectdojo` |
| **defectdojo** | defectdojo-valkey-specific | `defectdojo` |
| **defectdojo** | harbor-pull-secret | `harbor` |
| **haists-website** | haists-website-credentials | `keycloak/haists-website` |
| **harbor** | harbor-credentials | `harbor` |
| **harbor** | harbor-database | `harbor` |
| **harbor** | harbor-oidc | `keycloak/harbor` |
| **keycloak** | keycloak-admin-credentials | `keycloak/admin` |
| **keycloak** | postgresql-credentials | `keycloak/postgresql` |
| **matrix** | mas-credentials | `matrix/mas` |
| **matrix** | mas-oidc-credentials | `keycloak/mas` |
| **matrix** | mas-signing-keys | `matrix/mas` |
| **matrix** | matrix-oidc-credentials | `keycloak/synapse` |
| **matrix** | matrix-postgresql-credentials | `matrix/postgresql` |
| **matrix** | matrix-synapse-secrets | `matrix/synapse` |
| **monitoring** | grafana-admin-credentials | `grafana` |
| **netbox** | netbox-credentials | `netbox` |
| **netbox** | netbox-oidc | `keycloak/netbox` |
| **netbox** | netbox-postgresql | `netbox` |
| **netbox** | netbox-valkey | `netbox` |
| **openshift-gitops** | argocd-gitlab-repo | `gitlab` |
| **openshift-gitops** | argocd-oidc-keycloak | `keycloak/argocd` |
| **overwatch-console** | overwatch-console-credentials | `keycloak/overwatch-console` |
| **pangolin-internal** | newt-tunnel-credentials | `pangolin` |
| **sentinel-ops** | ops-gitlab-token | `gitlab` |
| **sentinel-ops** | ops-grafana-creds | `grafana` |
| **sentinel-ops** | ops-minio-creds | `minio` |
| **sentinel-ops** | ops-proxmox-creds | `proxmox` |
| **sentinel-ops** | ops-wazuh-creds | `wazuh/api` |

All ExternalSecrets have `refreshInterval: 1h` (except `argocd-gitlab-repo` at `30m`) and all currently show `STATUS: SecretSynced, READY: True`.

## ExternalSecret Example

A typical ExternalSecret that pulls an OIDC client secret from Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-oidc-keycloak
  namespace: openshift-gitops
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: argocd-secret
    creationPolicy: Merge    # Merges into existing Secret
    deletionPolicy: Retain   # Keeps Secret if ExternalSecret is deleted
  data:
    - secretKey: oidc.keycloak.clientSecret
      remoteRef:
        key: keycloak/argocd          # Vault KV path (under secret/)
        property: client_secret       # Field within the KV entry
```

### Creation Policies

- **`Owner`** (default) -- ESO creates and owns the Secret. Deleting the ExternalSecret deletes the Secret.
- **`Merge`** -- ESO adds/updates keys in an existing Secret without removing other keys. Used for ArgoCD where the `argocd-secret` has additional operator-managed keys.
- **`Retain`** -- Secret persists even if the ExternalSecret is deleted.

## Secret Rotation Flow

When a secret is updated in Vault:

1. ESO polls Vault every `refreshInterval` (1h default).
2. ESO detects the new version and updates the Kubernetes Secret.
3. Stakater Reloader (v1.3.0, `reloader` namespace) detects the Secret change.
4. Reloader triggers a rolling restart of Pods that reference the Secret (if annotated).

For immediate rotation (skip the 1h wait):

```bash
# Force ESO to reconcile immediately
oc annotate externalsecret <name> -n <namespace> \
  reconcile.external-secrets.io/trigger=$(date +%s)
```

## Troubleshooting

### ExternalSecret Not Syncing

```bash
# Check ExternalSecret status
oc get externalsecret -A
# Look for STATUS != SecretSynced or READY != True

# Check ESO controller logs
oc logs -n external-secrets -l app.kubernetes.io/name=external-secrets

# Verify Vault connectivity from ESO pod
oc exec -n external-secrets deploy/external-secrets -- \
  wget -qO- --no-check-certificate https://vault.208.haist.farm/v1/sys/health
```

### ESO in Backoff

If ESO hits errors repeatedly, it enters exponential backoff. Force recovery:

```bash
oc annotate externalsecret <name> -n <namespace> \
  reconcile.external-secrets.io/trigger=$(date +%s)
```

### New Namespace Not Working

For ArgoCD to manage ExternalSecrets in a new namespace:

1. Add the `argocd.argoproj.io/managed-by=openshift-gitops` label to the namespace.
2. Add the namespace to the ArgoCD cluster secret's `namespaces` field.
3. ESO uses a ClusterSecretStore (cluster-scoped), so no per-namespace store is needed.

### OKD Pods Cannot Reach Vault

OKD pods cannot reach `192.168.12.0/24` (management VLAN) directly. Vault is accessed via `https://vault.208.haist.farm` which routes through pangolin-proxy (Traefik). If pangolin-proxy is down, ExternalSecrets will fail to refresh but existing Kubernetes Secrets remain until their data is deleted.

### Adding New ExternalSecrets

When adding a field to an existing ExternalSecret, be aware that ArgoCD SSA (Server-Side Apply) reorders `data[]` entries. If the live state differs from the git manifest due to field ordering, ArgoCD may show the resource as OutOfSync. Fix by matching git manifest order to the SSA-normalized live state. If `ignoreDifferences` with `RespectIgnoreDifferences` is set, new data entries may be blocked -- apply manually with `oc apply` when adding fields.
