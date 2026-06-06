# Secrets Management

## KV v2 Secret Engine

Vault's primary secret engine is KV v2 mounted at `secret/`. All platform credentials, API tokens, OIDC client secrets, and database passwords are stored here.

The KV v2 engine provides:

- **Versioning** -- Previous secret versions are retained (configurable).
- **Check-and-Set** -- Prevents accidental overwrites via CAS parameter.
- **Soft delete** -- Deleted secrets can be recovered within the retention window.

### API Path Prefix

KV v2 uses a `data/` prefix in the API path:

```bash
# CLI (no prefix needed)
vault kv get secret/gitlab

# API (requires data/ prefix)
curl -sk -H "X-Vault-Token: $TOKEN" \
  https://vault.208.haist.farm/v1/secret/data/gitlab
```

## Secret Path Structure

The following paths are referenced across the platform (discovered from Ansible roles, CI pipelines, ExternalSecrets, scripts, and the MCP configuration).

### Infrastructure Credentials

| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/minio` | MinIO access/secret keys, endpoint | Backup scripts, sentinel-ops CronJobs |
| `secret/proxmox` | Proxmox API token | sentinel-ops CronJobs, snapshot scripts |
| `secret/infrastructure/vrrp` | VRRP (keepalived) password | iac-control and config-server Ansible roles |
| `secret/packer/build` | Packer SSH password (`PKR_VAR_ssh_password`) | Packer image builds |
| `secret/unifi` | UniFi Network API key | sentinel-unifi CLI and collector |

### Application Credentials

| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/gitlab` | GitLab PAT | CI pipelines, MCP server, sentinel-ops |
| `secret/grafana` | Grafana API key | MCP server, sentinel-ops health checks |
| `secret/backstage` | Backstage MCP token | MCP server |
| `secret/netbox` | NetBox admin API token | MCP server |
| `secret/cosign` | Cosign signing key/password | Image signing CI pipeline |
| `secret/crowdsec` | CrowdSec bouncer API key | Overwatch Console |
| `secret/harbor` | Harbor credentials | ExternalSecrets (harbor namespace) |
| `secret/defectdojo` | DefectDojo credentials | ExternalSecrets (defectdojo namespace) |

### Keycloak OIDC Client Secrets

| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/keycloak/admin` | Keycloak admin credentials | ExternalSecrets (keycloak namespace) |
| `secret/keycloak/argocd` | ArgoCD OIDC client secret | ExternalSecrets (openshift-gitops) |
| `secret/keycloak/backstage` | Backstage OIDC client secret | ExternalSecrets (backstage namespace) |
| `secret/keycloak/defectdojo` | DefectDojo OIDC client secret | ExternalSecrets (defectdojo namespace) |
| `secret/keycloak/harbor` | Harbor OIDC client secret | ExternalSecrets (harbor namespace) |
| `secret/keycloak/netbox` | NetBox OIDC client secret | ExternalSecrets (netbox namespace) |
| `secret/keycloak/haists-website` | Website OIDC client credentials | ExternalSecrets (haists-website namespace) |
| `secret/keycloak/overwatch-console` | Console OIDC client secret | ExternalSecrets (overwatch-console namespace) |
| `secret/keycloak/mas` | Matrix Auth Service OIDC | ExternalSecrets (matrix namespace) |
| `secret/keycloak/synapse` | Synapse OIDC client secret | ExternalSecrets (matrix namespace) |
| `secret/keycloak/postgresql` | Keycloak PostgreSQL password | ExternalSecrets (keycloak namespace) |

### Database and Service Secrets

| Path | Purpose | Consumers |
|------|---------|-----------|
| `secret/matrix/postgresql` | Matrix PostgreSQL credentials | ExternalSecrets (matrix namespace) |
| `secret/matrix/synapse` | Synapse signing keys, secrets | ExternalSecrets (matrix namespace) |
| `secret/matrix/mas` | MAS signing keys | ExternalSecrets (matrix namespace) |
| `secret/matrix/bot` | Matrix alert bot credentials | sentinel-matrix-bot on iac-control |
| `secret/pangolin` | Newt tunnel credentials, oauth2-proxy | ExternalSecrets (pangolin-internal) |

### MCP Server Credentials

| Path | Purpose |
|------|---------|
| `secret/mcp` | ArgoCD, Backstage, Keycloak, NVD tokens |
| `secret/gitlab` | GitLab PAT (shared with above) |
| `secret/grafana` | Grafana API key (shared with above) |
| `secret/netbox` | NetBox API token (shared with above) |

### Operational Secrets

| Path | Purpose |
|------|---------|
| `secret/vault/root-token` | Vault root token (emergency use) |
| `secret/iac-control/gitlab-token` | GitLab token on iac-control |
| `secret/iac-control/id_sentinel` | SSH private key backup |
| `secret/iac-control/kubeconfig` | OKD kubeconfig |
| `secret/backblaze` | B2 credentials for off-site DR |
| `secret/cloudflare` | Cloudflare API token |
| `secret/minio-config/b2-encryption-keys` | B2 encryption keys for rclone |
| `secret/minio-config/rclone-conf` | rclone configuration |
| `secret/wazuh/api` | Wazuh API credentials |
| `secret/wazuh/indexer` | Wazuh Indexer (OpenSearch) credentials |

## Policies

Vault ACL policies control access scoping. Key policies include:

### claude-automation

Used by the Claude Code MCP integration. Provides read/delete on secrets, list capability, and SSH cert signing:

- **Read/list**: `secret/data/*`, `secret/metadata/*`
- **Cannot**: List `sys/mounts` (permission denied)
- **Can**: Sign SSH certificates via `ssh/sign/admin`
- **TTL**: 30 days (renewable), token held in Proton Pass

### external-secrets

Used by the External Secrets Operator in OKD via Kubernetes auth:

- **Read**: `secret/data/*`
- **List**: `secret/metadata/*`
- Bound to the `vault-auth` service account in `external-secrets` namespace

### sentinel-ops

Used by sentinel-ops CronJobs in OKD via Kubernetes auth:

- **Read**: Scoped to specific paths needed by CronJobs
- Bound to the `sentinel-ops-sa` service account in `sentinel-ops` namespace

[VERIFY: Full policy definitions should be retrieved from `vault policy list` and `vault policy read <name>` to confirm exact capabilities.]

## Secret Hygiene Rules

1. **Never output raw secret values.** Summarize (e.g., "token exists, 36 chars") or show first 8 characters only.
2. **Never commit secrets to git.** Gitleaks runs in CI as a hard block.
3. **Use ExternalSecrets for OKD workloads.** Never bake secrets into container images or ConfigMaps.
4. **Rotate on compromise.** If a secret is exposed, rotate immediately in Vault; ESO will auto-sync within 1 hour (`refreshInterval: 1h`).
5. **Vault token in env, not in files.** Automation tokens come from `/etc/sentinel/compliance.env` (mode 0600) or environment variables, never hardcoded.

## Reading Secrets

### CLI (from iac-control)

```bash
source ~/sentinel-repo/scripts/vault-env.sh
vault kv get secret/gitlab
vault kv get -field=pat secret/gitlab
```

### API (from scripts)

```bash
curl -sk -H "X-Vault-Token: ${VAULT_TOKEN}" \
  https://vault.208.haist.farm/v1/secret/data/gitlab | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['pat'])"
```

### MCP (from Claude Code)

The Vault MCP server provides `read_secret` and `list_secrets` tools. Note: `list_mounts` is blocked by the `claude-automation` policy (returns 403).

## Writing Secrets

```bash
# Set a new secret
vault kv put secret/myapp/creds username="admin" password="s3cret"

# Update a single field (preserves other fields via patch)
vault kv patch secret/myapp/creds password="new-password"
```

## Troubleshooting

### ESO ExternalSecret Stuck in Error

If an ExternalSecret shows error status, check the Vault path exists and the `external-secrets` policy has access:

```bash
vault kv get secret/<path-from-externalsecret>
```

Force ESO to re-reconcile:

```bash
oc annotate externalsecret <name> -n <namespace> \
  reconcile.external-secrets.io/trigger=$(date +%s)
```

### MCP Token Expired

If MCP tools return authentication errors, refresh tokens:

```bash
source ~/sentinel-cache/scripts/load-mcp-tokens.sh
```

Restart Claude Code to pick up the new `~/.mcp.json`.
