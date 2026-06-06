# Compliance

## NIST 800-53 Controls

Vault satisfies or contributes to the following NIST 800-53 controls in Project Sentinel's compliance framework.

### IA-2: Identification and Authentication (Organizational Users)

**How Vault satisfies this**: Vault SSH CA provides cryptographic identity verification for all SSH access. Every user must present a Vault-signed certificate that encodes their identity (principal). Keycloak handles web application authentication; Vault handles infrastructure-level identity.

**Evidence**:

- SSH CA public key deployed to all hosts: `/etc/ssh/trusted-ca.pem`
- `AuthorizedKeysFile none` enforced on all managed VMs
- `AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u` restricts which principals can log in as which user
- Certificate signing logged in Vault audit log at `/opt/vault/logs/audit.log`

**Automated check**: `nist-compliance-check.sh` validates Keycloak SSO is responsive (IA-2 check). The SSH CA component is checked under AC-17.

### IA-5: Authenticator Management

**How Vault satisfies this**: Vault manages the lifecycle of all authenticators:

- SSH certificates have enforced TTLs (30 min default, 2h for automation, 4h max)
- Secrets are versioned (KV v2) with audit trails
- Policies enforce least-privilege access to credentials
- Automated rotation via ESO refresh intervals

**Evidence**:

- Vault policy list (AC-6 check): confirms multiple scoped policies exist
- Certificate TTLs: `ssh-keygen -L -f <cert>` shows validity window
- ExternalSecret `refreshInterval: 1h` ensures credentials are not stale

**Sub-control IA-5(2) -- PKI-Based Authentication**: The SSH CA is a full PKI implementation with:

- CA key generation and storage in Vault
- Certificate signing with role-based constraints
- Short-lived certificates (2h TTL) eliminating the need for revocation lists
- Principal-based access control per host

**Sub-control IA-5(13) -- Token TTL**: The compliance check monitors Vault token TTLs. This is one of the 6 remaining WARNs (tokens with long TTLs exist for automation purposes).

### AC-6: Least Privilege

**How Vault satisfies this**: Vault ACL policies enforce least privilege for all secret access:

- Each consumer (ESO, sentinel-ops, MCP, CI) has a dedicated policy
- Policies scope access to specific paths
- K8s auth roles bind to specific service accounts and namespaces

**Automated check**: `nist-compliance-check.sh` runs `check_vault_policies()` -- confirms more than a threshold number of ACL policies are defined.

### AC-17: Remote Access

**How Vault satisfies this**: All remote SSH access uses Vault-signed certificates. No static keys.

**Automated check**: `check_vault_ssh_ca()` verifies the SSH CA public key is configured in Vault via the API (`/ssh/config/ca`).

### AU-2 / AU-12: Audit Events / Audit Generation

**How Vault contributes**: Vault audit logging records every API request (authentication, secret reads, writes, policy changes). The audit log at `/opt/vault/logs/audit.log` is:

- Rotated daily (30-day retention via logrotate)
- Monitored by Wazuh agent (ID 001) on vault-server
- Forwarded to Wazuh SIEM via rsyslog (to `192.168.12.100:514`)

**Evidence**: Audit log files, logrotate config, Wazuh agent status.

### CP-9: Information System Backup

**How Vault satisfies this**: Daily automated backups with 7-day retention to MinIO, replicated to secondary MinIO and B2 off-site.

**Automated check**: `nist-compliance-check.sh` checks `vault-backup.timer` is active on vault-server.

**Evidence**:

- `systemctl status vault-backup.timer` on vault-server
- MinIO bucket listing (`mc ls minio/vault-backups/`)
- Backup size verification (typical: ~34KB)

### SC-12: Cryptographic Key Establishment and Management

**How Vault satisfies this**: Vault manages all cryptographic keys:

- SSH CA signing key (generated and stored in Vault)
- Transit encryption key for auto-unseal
- Cosign image signing keys (stored in Vault KV)
- TLS certificates for Vault itself

**Evidence**: `vault read ssh/config/ca` (public key exists), transit key configuration.

### SC-13: Cryptographic Protection

**How Vault satisfies this**: Vault provides cryptographic operations using:

- AES-256-GCM for storage encryption (barrier)
- RSA-4096 for SSH CA signing
- TLS 1.2+ for API transport
- Transit engine for auto-unseal encryption

### SC-23: Session Authenticity

**Automated check**: `check_vault_health()` validates that Vault responds over TLS with HTTP 200:

```bash
# HTTP 200 = healthy, unsealed, active
curl -sk -o /dev/null -w '%{http_code}' \
  https://vault.208.haist.farm/v1/sys/health
```

## Compliance Check Functions

The following functions in `scripts/nist-compliance-check.sh` directly involve Vault:

| Function | Control | What It Checks |
|----------|---------|----------------|
| `check_vault_health` | SC-23 | TLS endpoint responds HTTP 200 |
| `check_vault_ssh_ca` | AC-17 | SSH CA public key is configured |
| `check_vault_policies` | AC-6 | Sufficient ACL policies are defined |
| `check_backup_timers` | CP-9 | vault-backup.timer is active |
| `check_audit_services` | AU-2 | Vault audit log container is running |
| `check_docker_services` | CM-2 | Vault container is running (expects 1 container) |

## Evidence Collection

The daily evidence pipeline (07:00 UTC) auto-commits compliance data to the `compliance-vault` GitLab repo. Vault-related evidence includes:

- Vault health status (HTTP code from `/v1/sys/health`)
- Backup timer status
- Docker container state
- Audit log presence

Reports are generated at `compliance-vault/reports/daily/` with trend tracking in `compliance-vault/reports/compliance-trend-summary.md`.

## Known Compliance Gaps

### IA-5(13) Token TTL (WARN)

Some automation tokens have long TTLs (e.g., `claude-automation` at 30 days). This is an accepted risk for operational continuity. Mitigation: tokens are renewable and monitored.

### AU-10 Audit Log Integrity (WARN)

The `logall_json` SSH logging check may WARN if the check format does not match expected output. This is a check-implementation issue, not a Vault gap.

## Audit Trail

Every Vault API operation is logged in the audit log with:

- Timestamp
- Client token (hashed)
- Operation type (read, write, delete, list)
- Path accessed
- Request and response data (sensitive fields HMAC'd)
- Source IP

Example audit entry (fields simplified):

```json
{
  "type": "response",
  "time": "2026-03-04T12:00:00Z",
  "auth": {
    "token_type": "service",
    "policies": ["external-secrets"]
  },
  "request": {
    "operation": "read",
    "path": "secret/data/gitlab",
    "remote_address": "10.0.0.221"
  },
  "response": {
    "data": { "keys": ["data", "metadata"] }
  }
}
```
