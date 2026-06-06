# Backup & Restore

## Backup Architecture

Vault data is backed up daily to MinIO object storage, with cross-host replication for redundancy.

```
vault-server (192.168.12.206)
  vault-backup.timer (daily 2AM UTC)
    |
    v
  vault-backup.sh
    1. docker stop vault
    2. tar -czf /opt/vault/data/
    3. docker start vault
    4. mc cp -> MinIO primary
    5. Prune backups older than 7 days
    |
    v
MinIO primary (192.168.12.58, LXC 301, pve3)
  Bucket: vault-backups/
    |
    v (mc mirror, every 6h via iac-control timer)
MinIO replica (192.168.12.59, LXC 302, pve)
  Bucket: vault-backups/
```

Additionally, Proxmox VM snapshots of VM 205 are taken daily at 01:00 UTC (4 snapshots retained), providing a full-VM point-in-time recovery option.

## Backup Details

### Timer

The backup runs on vault-server itself via a systemd timer:

```ini
# /etc/systemd/system/vault-backup.timer
[Timer]
OnCalendar=*-*-* 02:00:00 UTC
Persistent=true
RandomizedDelaySec=300
```

The `Persistent=true` flag ensures missed backups (e.g., from downtime) run at next boot. `RandomizedDelaySec=300` adds up to 5 minutes of jitter.

### Backup Script

`/usr/local/bin/vault-backup.sh` performs these steps:

1. **Stop Vault** -- `docker stop vault` to ensure a consistent file-level snapshot.
2. **Create tarball** -- `tar -czf /tmp/vault-backup-YYYYMMDD-HHMMSS.tar.gz -C /opt/vault/data .`
3. **Start Vault** -- `docker start vault` immediately after tar completes.
4. **Upload to MinIO** -- Uses `mc` (MinIO client) to copy the tarball to the `vault-backups` bucket.
5. **Prune old backups** -- Deletes backups older than 7 days (`vault_backup_retention_days: 7`).
6. **Cleanup** -- Removes the local tarball.

The MinIO credentials are sourced from `/etc/vault-backup.env` (mode 0600):

```
MINIO_ENDPOINT="http://192.168.12.58:9000"
MINIO_ACCESS_KEY="<key>"
MINIO_SECRET_KEY="<secret>"
```

### Downtime Window

Vault is stopped during the backup. The stop-tar-start cycle typically takes 5-15 seconds for a ~34KB data directory. During this window:

- API requests return connection refused.
- ESO refresh attempts will retry on next interval.
- Transit auto-unseal handles re-seal after restart.

### Verifying Backups

```bash
# On vault-server, check timer status
ssh -i ~/.ssh/id_sentinel root@192.168.12.206 \
  "systemctl status vault-backup.timer"

# Check last run
ssh -i ~/.ssh/id_sentinel root@192.168.12.206 \
  "journalctl -u vault-backup.service --since '24 hours ago' --no-pager"

# List backups in MinIO (from iac-control)
mc ls minio/vault-backups/
```

The NIST compliance check (CP-9 control) verifies the backup timer is active:

```bash
# From nist-compliance-check.sh
systemctl is-active vault-backup.timer
```

## Restore Procedure

### Automated Restore (from MinIO)

The restore script at `infrastructure/recovery/restore-vault.sh` handles the full restore process.

**Prerequisites:**

- SSH access to vault-server (as root)
- MinIO credentials (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`)
- Python3 with boto3 installed (on the machine running the script)

**Usage:**

```bash
# From iac-control
cd ~/sentinel-repo/infrastructure/recovery

# Restore latest backup
export MINIO_ACCESS_KEY="<key>"
export MINIO_SECRET_KEY="<secret>"
./restore-vault.sh

# Restore specific date
./restore-vault.sh --date 2026-03-01

# Restore to a different host (e.g., rebuilt VM)
./restore-vault.sh --vault-host 192.168.12.207
```

**What the script does:**

1. Downloads the backup tarball from MinIO (`vault-backups` bucket) using Python boto3.
2. Stops Vault service on the target host via SSH.
3. Backs up the current data directory (`/tmp/vault-data-pre-restore.tar.gz`).
4. Clears `/opt/vault/data/*`.
5. Uploads and extracts the backup tarball to `/opt/vault`.
6. Sets ownership: `chown -R vault:vault /opt/vault/data`.
7. Starts Vault service.
8. Waits up to 30 seconds for Vault to respond.

**Post-Restore Steps (manual):**

After the script completes, you must verify Vault is unsealed:

```bash
ssh -i ~/.ssh/id_sentinel root@192.168.12.206
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true

# If Transit auto-unseal is working, Vault unseals automatically.
# Verify:
vault status

# If Transit is down, use Shamir keys:
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>

# Verify secret access
vault kv get secret/test
```

**Note:** The restore script uses `systemctl stop/start vault`, but the current deployment uses Docker Compose (not a systemd unit). [VERIFY: The restore script may need updating to use `docker compose stop/start` or `docker stop/start vault` instead of `systemctl`. A systemd wrapper unit may exist on the host.]

### Manual Restore

If the restore script fails or is unavailable:

```bash
# SSH to vault-server
ssh -i ~/.ssh/id_sentinel root@192.168.12.206

# Stop Vault
cd /opt/vault && docker compose stop

# Download backup manually (if mc is installed)
mc cp minio/vault-backups/vault-backup-20260301-020000.tar.gz /tmp/

# Backup existing data
tar -czf /tmp/vault-data-pre-restore.tar.gz -C /opt/vault data/

# Clear and restore
rm -rf /opt/vault/data/*
tar -xzf /tmp/vault-backup-20260301-020000.tar.gz -C /opt/vault/data/

# Fix permissions (container runs as uid 100)
chown -R 100:100 /opt/vault/data/

# Start Vault
docker compose start
```

### Full Rebuild via Ansible

If the VM itself is lost, rebuild from golden image and Ansible:

1. Clone VM from golden image 9205 on 208-pve2.
2. Set the IP to `192.168.12.206`.
3. Run the Ansible playbook:
   ```bash
   cd ~/sentinel-repo/ansible
   ansible-playbook -i inventory/hosts.ini playbooks/vault-server.yml \
     -e minio_access_key="<key>" \
     -e minio_secret_key="<secret>" \
     -e vault_transit_unseal_token="<transit-token>"
   ```
4. Ansible deploys Docker, Vault config, compose file, and backup timer.
5. Restore data from MinIO using the restore script.
6. Verify Vault unseals via Transit auto-unseal.
7. Verify SSH CA, K8s auth, and ESO connectivity.

**What Ansible rebuilds:**

- Docker engine and compose
- Vault configuration (config.hcl, docker-compose.yml)
- Backup timer and script
- CIS hardening (common role)
- Wazuh agent

**What needs manual intervention after rebuild:**

- TLS certificates (not managed by the Ansible role) [VERIFY: confirm TLS cert provisioning method]
- Vault data (restored from backup)
- Transit unseal token in config.hcl (must be provided as extra var)
- Vault initialization (only if no backup exists -- requires generating new unseal keys)

## GitLab CI DR Jobs

The `disaster-recovery` stage in the sentinel-iac CI pipeline includes manual-trigger jobs:

| Job | Action |
|-----|--------|
| `recover-vault` | Runs the restore script with CI-provided MinIO credentials |
| `full-disaster-recovery` | Sequential recovery of all services (MinIO first, then Vault, then GitLab) |

Trigger via GitLab CI (manual job on `main` branch).

## Recovery Time Objectives

| Scenario | RTO |
|----------|-----|
| Vault container restart | ~30 seconds (auto-unseal) |
| Data restore from MinIO | 10-15 minutes |
| Full VM rebuild + restore | 30-60 minutes |
| Total platform loss (bootstrap from B2) | 3-4 hours |

## Off-Site Backup

MinIO buckets (including `vault-backups`) are replicated to Backblaze B2 via rclone with client-side encryption. This provides geographic redundancy for total-site-loss scenarios. The `bootstrap-from-b2.sh` script handles recovery from B2 (interactive, 529 lines).
