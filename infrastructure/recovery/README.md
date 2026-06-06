# Disaster Recovery Scripts

This directory contains automated restoration scripts for all Sentinel infrastructure components.

## Overview

Each script is designed to be:
- **Self-contained**: All logic in a single executable file
- **Idempotent**: Safe to run multiple times
- **CI-compatible**: Can be used standalone or in GitLab pipelines
- **Well-documented**: Built-in help text and usage examples

## Scripts

### restore-vault.sh
Restores Vault data from MinIO backup.

**Usage:**
```bash
export MINIO_ACCESS_KEY="minio-admin"
export MINIO_SECRET_KEY="your-secret"
./restore-vault.sh --date 2026-02-07

# Or use latest backup
./restore-vault.sh
```

**Environment Variables:**
- `MINIO_ENDPOINT` - MinIO API (default: http://192.168.12.58:9000)
- `MINIO_ACCESS_KEY` - MinIO access key (required)
- `MINIO_SECRET_KEY` - MinIO secret key (required)
- `VAULT_HOST` - Vault server IP (default: 192.168.12.206)
- `VAULT_USER` - SSH user (default: root)

**Post-restore:**
Vault will be sealed and require 3 of 5 unseal keys:
```bash
ssh root@192.168.12.206
export VAULT_ADDR=http://localhost:8200
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
vault status
```

---

### restore-gitlab.sh
Restores GitLab application data and configuration from MinIO backup.

**Usage:**
```bash
export MINIO_ACCESS_KEY="minio-admin"
export MINIO_SECRET_KEY="your-secret"
./restore-gitlab.sh --date 2026-02-08

# Or use latest backup
./restore-gitlab.sh
```

**Environment Variables:**
- `MINIO_ENDPOINT` - MinIO API (default: http://192.168.12.58:9000)
- `MINIO_ACCESS_KEY` - MinIO access key (required)
- `MINIO_SECRET_KEY` - MinIO secret key (required)
- `GITLAB_HOST` - GitLab server IP (default: 192.168.12.68)
- `GITLAB_USER` - SSH user (default: koiakoia)

**Post-restore:**
Verify GitLab health:
```bash
ssh koiakoia@192.168.12.68
sudo gitlab-rake gitlab:check SANITIZE=true
```

---

### restore-minio.sh
Restores MinIO data from Backblaze B2 encrypted storage.

**Usage:**
```bash
export B2_ACCOUNT_ID="your-account-id"
export B2_APP_KEY="your-app-key"
export B2_BUCKET="your-bucket-name"
export RCLONE_CRYPT_PASS="your-encryption-password"
export RCLONE_CRYPT_SALT="your-encryption-salt"

# Restore all buckets
./restore-minio.sh

# Restore specific bucket
./restore-minio.sh --bucket vault-backups
```

**Environment Variables:**
- `MINIO_HOST` - MinIO LXC IP (default: 192.168.12.58)
- `MINIO_USER` - SSH user (default: root)
- `B2_ACCOUNT_ID` - B2 account ID (required)
- `B2_APP_KEY` - B2 application key (required)
- `B2_BUCKET` - B2 bucket name (required)
- `RCLONE_CRYPT_PASS` - Rclone encryption password (required)
- `RCLONE_CRYPT_SALT` - Rclone encryption salt (required)

**Post-restore:**
Verify MinIO is accessible:
```bash
mc alias set minio http://192.168.12.58:9000 minio-admin your-password
mc ls minio
```

---

### restore-etcd.sh
Restores OKD cluster etcd snapshot from MinIO backup.

**⚠️ WARNING:** This is a DESTRUCTIVE operation. All cluster state changes after the backup point will be LOST.

**Usage:**
```bash
export MINIO_ACCESS_KEY="minio-admin"
export MINIO_SECRET_KEY="your-secret"
export KUBECONFIG="$HOME/.kube/config"
./restore-etcd.sh --date 2026-02-08

# Or use latest backup
./restore-etcd.sh
```

**Environment Variables:**
- `MINIO_ENDPOINT` - MinIO API (default: http://192.168.12.58:9000)
- `MINIO_ACCESS_KEY` - MinIO access key (required)
- `MINIO_SECRET_KEY` - MinIO secret key (required)
- `OKD_MASTER` - Master node hostname (default: master-1.okd4.haist.farm)
- `KUBECONFIG` - Path to kubeconfig (default: ~/.kube/config)

**Post-restore:**
Monitor cluster recovery (may take 10-20 minutes):
```bash
watch oc get clusteroperators
oc get nodes
oc get pods -A
```

---

## Hung Node Recovery (iDRAC Redfish)

If a Proxmox host is hung or unresponsive, use iDRAC out-of-band management before attempting full DR:

```bash
# Check all node status from iac-control
idrac-node-recovery.sh all-status

# Power cycle a hung node (GracefulRestart on 14G, ForceOff+On on 12G)
idrac-node-recovery.sh power-cycle pve

# Force off if graceful fails
idrac-node-recovery.sh force-off pve
idrac-node-recovery.sh power-on pve

# Send NMI for crash dump
idrac-node-recovery.sh nmi pve
```

**iDRAC endpoints:**
| Node | iDRAC IP | Model | Generation |
|------|----------|-------|------------|
| pve | 192.168.12.10 | PowerEdge R440 | 14G |
| 208-pve2 | 192.168.12.50 | Precision 7920 Rack | 14G |
| pve3 | 192.168.12.202 | PowerEdge R720xd | 12G |

**Automated watchdog:** The `idrac-watchdog` timer on iac-control checks Proxmox API reachability every 5 minutes and auto-triggers a power cycle after 3 consecutive failures. Disable with `touch /var/run/idrac-watchdog/<node>.disabled`.

**Health monitoring:** The `idrac-health` timer runs every 5 minutes, logging hardware health (temps, fans, PSUs, power draw) to `/var/log/sentinel/idrac/health.json`. Wazuh alerts fire for Critical health (rule 100602) and auto-recovery events (rule 100604, level 10 — Discord alert).

---

## Recovery Order

For complete disaster recovery, restore components in this order:

0. **Node Recovery** (`idrac-node-recovery.sh`) - Power cycle hung nodes via iDRAC first
1. **MinIO** (`restore-minio.sh`) - Restore backup storage first
2. **Vault** (`restore-vault.sh`) - Restore secrets management
3. **GitLab** (`restore-gitlab.sh`) - Restore CI/CD and repositories
4. **etcd** (`restore-etcd.sh`) - Restore OKD cluster state (if needed)

## GitLab CI Integration

These scripts are integrated into the GitLab CI disaster-recovery stage:

- `recover-vault` - Manual job to restore Vault
- `recover-gitlab` - Manual job to restore GitLab
- `recover-minio-from-b2` - Manual job to restore MinIO from B2
- `recover-etcd` - Manual job to restore OKD etcd

All CI jobs automatically inject credentials from CI/CD variables.

## Credentials

All scripts require credentials via environment variables. In GitLab CI, these are automatically set from:

- `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` - CI/CD variables
- Vault credentials - Retrieved from Vault via automation token
- B2 credentials - Stored in Vault at `secret/backblaze`
- Rclone keys - Stored in Vault at `secret/minio-config/b2-encryption-keys`

For manual execution, retrieve credentials from:
- Vault: `vault kv get secret/minio`
- Vault: `vault kv get secret/backblaze`
- Vault: `vault kv get secret/minio-config/b2-encryption-keys`

## Testing

To test scripts without affecting production:

1. **Dry-run mode**: Read the script source and comment out destructive operations
2. **Test VM**: Create a test VM and restore to it (modify HOST variables)
3. **Date selection**: Use `--date` to restore old backups instead of latest

## Troubleshooting

**SSH connection failures:**
- Verify SSH key access: `ssh -i ~/.ssh/id_sentinel user@host`
- Check JIT SSH certificate validity: `ssh-keygen -L -f ~/.ssh/id_sentinel-cert.pub`

**MinIO download failures:**
- Verify MinIO credentials: `mc alias set test http://192.168.12.58:9000 $MINIO_ACCESS_KEY $MINIO_SECRET_KEY`
- Check bucket contents: `mc ls test/vault-backups`

**B2 sync failures:**
- Test rclone config manually on MinIO server
- Verify encryption keys are correct

**Vault unsealing:**
- Vault uses Transit auto-unseal via Transit Vault on iac-control (:8201)
- Old Shamir keys are now recovery keys (stored in Proton Pass)
- If Transit Vault is sealed, the `vault-unseal-transit.timer` auto-unseals it every 2 min

**Hung node (not full DR):**
- Try `idrac-node-recovery.sh power-cycle <node>` before full restore
- Check `idrac-node-recovery.sh all-status` to verify power state first

**GitLab restore failures:**
- Check disk space on GitLab server: `df -h`
- Verify backup file permissions after upload
- Review GitLab logs: `sudo gitlab-ctl tail`

**etcd restore failures:**
- Ensure all master nodes are reachable
- Verify kubeconfig has admin permissions
- Check etcd pod logs: `oc logs -n openshift-etcd etcd-master-1`

## See Also

- [DR Runbook](../DR-RUNBOOK.md) - Master disaster recovery procedures
- [Vault DR](../vault-dr/) - Vault backup automation
- [GitLab DR](../gitlab-dr/) - GitLab backup automation
- [MinIO DR](../minio-dr/) - MinIO backup and B2 sync
