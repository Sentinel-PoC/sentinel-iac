# Vault Disaster Recovery

## Overview
This directory contains the running configuration of the Vault server (VM 205, 192.168.12.206).
It does NOT contain secret data - only service structure for rebuilding.

## Files
- `docker-compose.yml` - Docker Compose configuration (reconstructed from running container)
- `config.hcl` - Vault server configuration (`/etc/vault/config/config.hcl`)
- `policies/` - All Vault policy definitions
  - `default.hcl` - Default Vault policy
  - `claude-automation.hcl` - Read-only access for Claude Code agent
- `auth-methods.json` - Enabled auth methods (token only)
- `secret-engines.json` - Enabled secret engines (cubbyhole, identity, kv-v2, ssh, sys)
- `ssh-ca-public-key.pub` - SSH CA public key (deploy to target hosts as trusted-ca.pem)
- `ssh-role-admin.json` - SSH admin role configuration
- `export-policies.sh` - Helper script to re-export policies

## Current Setup
- **Image:** hashicorp/vault:1.15.4
- **Host:** VM 205 on 208-pve2 (192.168.12.56)
- **IP:** 192.168.12.206
- **Storage:** File backend at /opt/vault/data (mounted as /vault/file in container)
- **Config:** /etc/vault/config (mounted as /vault/config in container)
- **Seal:** Shamir (5 shares, 3 threshold)
- **SSH CA:** Configured, trusted-ca.pem deployed to target hosts
- **Audit:** Enabled (file backend at /vault/logs/audit.log)

## Secret Engines
- `secret/` - KV v2 (infrastructure secrets)
- `ssh/` - SSH secrets engine (JiT certificate signing)
- `cubbyhole/` - Per-token private storage
- `identity/` - Identity store

## Auth Methods
- `token/` - Token-based auth (default)
- `kubernetes/` - OKD service account auth (ExternalSecrets, Sentinel-Ops)
- `approle/` - AppRole auth for CI/CD automation (role: ci-automation)

## Policies
- `default` - Standard Vault default policy (token self-management, cubbyhole)
- `claude-automation` - Read secrets, sign SSH certs (no write, limited sys read)
- `eso-read-secrets` - ExternalSecrets operator read-only access
- `sentinel-ops-policy` - Sentinel-Ops CronJob read access
- `root` - Built-in root policy (cannot be exported)

## Manual Recovery Procedure
1. Provision VM from Terraform (infrastructure/bootstrap/)
2. Install Docker: `apt-get install docker.io docker-compose-plugin`
3. Create directories: `mkdir -p /opt/vault/data /etc/vault/config`
4. Copy `config.hcl` to `/etc/vault/config/config.hcl`
5. Copy `docker-compose.yml` and run: `docker compose up -d`
6. Initialize Vault: `vault operator init` (save unseal keys!)
7. Unseal Vault: `vault operator unseal` (3 of 5 keys)
8. Apply policies: `vault policy write claude-automation policies/claude-automation.hcl`
9. Re-enable secret engines: `vault secrets enable -path=secret kv-v2`, `vault secrets enable -path=ssh ssh`
10. Configure SSH CA: `vault write ssh/config/ca generate_signing_key=true` (or import existing key)
11. Create SSH role: `vault write ssh/roles/admin @ssh-role-admin.json`
12. Deploy `ssh-ca-public-key.pub` as `/etc/ssh/trusted-ca.pem` on target hosts
13. Enable Kubernetes auth: `vault auth enable kubernetes`, configure with OKD API host
14. Enable AppRole auth: `vault auth enable approle`, create ci-automation role
15. Restore secrets from backup (if available)

## Automated Data Backup

Daily encrypted snapshots of Vault data (`/opt/vault/data/`) are backed up to MinIO and replicated to B2.

**Pipeline:**
```
Vault VM (daily, 2 AM UTC)
  tar+gzip /opt/vault/data/ -> /tmp/vault-backup-YYYY-MM-DD.tar.gz
    | boto3 upload
MinIO (vault-backups/ bucket, 7-day retention)
    | rclone sync (hourly, on MinIO LXC)
B2 (haist-terraform-backup/encrypted/vault-backups/, rclone crypt)
```

**Security:** Vault file backend data is already encrypted with the master key (requires 3-of-5 unseal keys to decrypt). B2 replication adds a second encryption layer via rclone crypt.

**Files:**
- `backup/vault-backup.sh` - Backup script (tar + boto3 upload + retention cleanup)
- `backup/vault-backup.service` - Systemd oneshot service
- `backup/vault-backup.timer` - Daily timer (02:00 UTC + 5min random delay)
- `backup/vault-backup.env.example` - Environment template (credentials redacted)

**Operations:**
- Manual run: `systemctl start vault-backup.service`
- Check status: `systemctl status vault-backup.service`
- Check timer: `systemctl list-timers vault-backup.timer`
- View logs: `journalctl -u vault-backup.service` or `cat /var/log/vault-backup.log`

## Restore from Backup

1. Download latest backup from MinIO (use boto3 or aws CLI)
2. Stop Vault: `docker stop vault`
3. Clear data: `rm -rf /opt/vault/data/*`
4. Extract: `tar -xzf /tmp/vault-backup-YYYY-MM-DD.tar.gz -C /opt/vault/`
5. Start Vault: `docker start vault`
6. Unseal: `vault operator unseal` (3 of 5 keys from Proton Pass)

## What is NOT backed up here
- ~~Encrypted secret data~~ **NOW BACKED UP** - daily to MinIO + B2 (see above)
- Unseal keys (stored in Proton Pass)
- Root token (stored in Proton Pass)
- Audit logs
