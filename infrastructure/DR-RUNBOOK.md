# Sentinel Platform - Disaster Recovery Runbook

**Last Updated**: 2026-02-08
**Recovery Target**: Any single VM recoverable; full platform from B2 in ~2-3 hours (automated)

## 🚀 Quick Recovery Options

### Option 1: One-Click GitLab CI Recovery (RECOMMENDED)
Navigate to: **GitLab → sentinel-iac → CI/CD → Pipelines → disaster-recovery stage**

Available recovery jobs (manual trigger):
- `recover-vault-from-backup` - Restore Vault from MinIO backup
- `recover-gitlab-from-backup` - Restore GitLab from MinIO backup
- `bootstrap-from-b2` - Total recovery from B2 (requires Proton Pass secrets)
- `failover-to-minio-replica` - Switch to MinIO replica LXC 302

These use automated scripts in `infrastructure/recovery/`.

### Option 2: Snapshot-Based Quick Recovery
All critical VMs have daily snapshots (1AM UTC, 4-day retention):
- VM 200 (iac-control), VM 201 (gitlab-server), VM 205 (vault-server), VM 109 (seedbox-vm), VM 107 (pangolin-proxy)

To restore from snapshot (via Proxmox UI or API):
```bash
# Proxmox API snapshot restore
curl -sk -X POST "https://192.168.12.6:8006/api2/json/nodes/NODE/qemu/VMID/snapshot/SNAPNAME/rollback" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET"
```

### Option 3: Manual Procedures (Fallback)
See scenarios below for step-by-step manual recovery.

---

## Architecture Overview

```
                    Backblaze B2 (encrypted, off-site)
                         ↑ rclone hourly
            ┌────────────┼───────────────────┐
       MinIO Primary 301               MinIO Replica 302
       (192.168.12.58, pve3)          (192.168.12.59, pve)
            ├── terraform-state/              ↑
            ├── vault-backups/     (server-side replication)
            ├── gitlab-backups/               ↓
            └── etcd-backups/          (read-only failover)
                 ↑ automated timers
      ┌──────────┼──────────┬──────────┐
  Vault 205  GitLab 201  iac-control  etcd (master-1)
  (daily 2AM) (weekly Sun 3AM)  200   (daily 4AM)
```

### Recovery Dependency Chain
```
MinIO (FIRST - everything needs it for backup access)
  ├→ Vault (restore data from MinIO/B2)
  ├→ GitLab (restore data from MinIO/B2)
  ├→ iac-control (secrets from Vault, repos from GitLab)
  └→ pangolin-proxy (configs from Git, secrets from Vault)
```

### Backup Schedule (AUTOMATED)

| VM | Backup | Schedule | Retention | Size | Automation |
|----|--------|----------|-----------|------|------------|
| 205 vault-server | /opt/vault/data/ | Daily 2AM UTC | 7 days | ~35KB | systemd timer ✅ |
| 201 gitlab-server | App + config | Weekly Sun 3AM UTC | 14 days | ~400MB | systemd timer ✅ |
| 200 iac-control | etcd | Daily 4AM UTC | 7 days | varies | systemd timer ✅ |
| 107 pangolin-proxy | Proxmox snapshots | Daily 1AM UTC | 4 snapshots | N/A | systemd timer ✅ |
| ALL VMs | Proxmox snapshots | Daily 1AM UTC | 4 snapshots | N/A | systemd timer ✅ |
| MinIO buckets | → B2 sync | Hourly | All data | varies | rclone cron ✅ |
| MinIO 301 → 302 | Replication | Real-time | All data | varies | MinIO replication ✅ |

### Where Secrets Live

| Secret | Primary | Backup |
|--------|---------|--------|
| Vault root token | Proton Pass | Vault KV `secret/vault/root-token` |
| Vault unseal keys | Proton Pass | — |
| B2 rclone crypt passwords | Proton Pass | Vault KV `secret/minio-config/b2-encryption-keys` |
| MinIO credentials | Vault `secret/minio` | — |
| GitLab PAT | Vault `secret/gitlab` | — |
| Proxmox API token | Vault `secret/proxmox` | GitLab CI vars |
| SSH keys | Vault `secret/iac-control/*` | iac-control `~/.ssh/` |
| Kubeconfig | Vault `secret/iac-control/kubeconfig` | iac-control `~/.kube/config` |
| Pangolin server.secret | Vault `secret/pangolin` | config.yml on 192.168.12.168 |
| Newt credentials | Vault `secret/pangolin` | .env on 192.168.12.168 |
| Cloudflare DNS token | Vault `secret/cloudflare` | .env on 192.168.12.168 |
| rclone.conf | Vault `secret/minio-config/rclone-conf` | MinIO LXCs `/root/.config/rclone/` |

---

## Scenario 1: Single VM Loss — MinIO LXC 301

**RTO: ~15 minutes (with replica) | ~30 minutes (from B2)**

### Option 1A: Failover to MinIO Replica (FASTEST)
1. **Trigger CI job**: `failover-to-minio-replica` in GitLab disaster-recovery stage
2. **Manual alternative**:
   ```bash
   # Update DNS/aliases to point to replica
   ssh iac-control
   sed -i 's/192.168.12.58/192.168.12.59/' ~/.mc/config.json
   mc alias set minio http://192.168.12.59:9000 minio-admin PASSWORD
   ```
3. **Rebuild primary 301** in background (see Scenario 1B)

### Option 1B: Rebuild MinIO Primary 301
See `infrastructure/minio-dr/README.md` for details.

1. **Rebuild LXC** on pve3:
   ```bash
   sshpass -p 'PASSWORD' ssh root@192.168.12.57
   pct create 301 local:vztmpl/ubuntu-25.04*.tar.zst \
     --hostname minio-bootstrap --cores 2 --memory 1024 --storage local-lvm \
     --net0 name=eth0,bridge=vmbr0,ip=192.168.12.58/24,gw=192.168.12.1
   pct start 301
   ```
2. **Install MinIO** (see `infrastructure/minio-dr/README.md`)
3. **Restore config** from Vault: `secret/minio-config/*`
4. **Pull data from B2**: Use bootstrap-from-b2 script or:
   ```bash
   rclone sync b2-encrypted:sentinel-vault-backups/ minio:vault-backups/
   rclone sync b2-encrypted:sentinel-gitlab-backups/ minio:gitlab-backups/
   rclone sync b2-encrypted:sentinel-terraform-state/ minio:terraform-state/
   rclone sync b2-encrypted:sentinel-etcd-backups/ minio:etcd-backups/
   ```
5. **Re-enable replication** to replica 302

### If Vault is also lost (circular dependency)
Use B2 crypt passwords from **Proton Pass** to build rclone.conf manually:
```bash
rclone obscure "8dcMj+8nqcp5Za3BdhJmWqLQ2zOvu6MSFdiNu8jYi2s="  # password
rclone obscure "WR1MbVjFAA9+edlMt9vt+VMbdKcXi51QP/Vqy1d8Wco="  # password2
```
B2 account ID: `368fe76c3651`, bucket: `sentinel-backups`

---

## Scenario 2: Single VM Loss — Vault Server 205

**RTO: ~20 minutes (automated) | ~45 minutes (manual)**

### Option 2A: Automated CI Recovery (RECOMMENDED)
1. **Trigger CI job**: `recover-vault-from-backup` in GitLab disaster-recovery stage
2. **Job will**:
   - Download latest backup from MinIO
   - Extract to /opt/vault/data
   - Start Vault container
   - Wait for manual unseal
3. **Unseal Vault**: Use 3 of 5 unseal keys from Proton Pass

### Option 2B: Snapshot Rollback
```bash
# Find latest snapshot
curl -sk "https://192.168.12.6:8006/api2/json/nodes/pve2/qemu/205/snapshot" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET" | grep auto-

# Rollback (CAUTION: will lose changes since snapshot)
curl -sk -X POST "https://192.168.12.6:8006/api2/json/nodes/pve2/qemu/205/snapshot/auto-YYYYMMDD-HHMM/rollback" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET"
```

### Option 2C: Manual Recovery
See `infrastructure/vault-dr/` for docker-compose + config.

1. **Create VM** on 208-pve2 (VMID 205)
2. **Install Docker**, deploy Vault container: `hashicorp/vault:1.15.4` (NOTE: EOL, upgrade to 1.21.x)
3. **Restore data** from MinIO:
   ```bash
   mc cp --recursive minio/vault-backups/vault-backup-$(date +%Y-%m-%d).tar.gz /tmp/
   tar -xzf /tmp/vault-backup-*.tar.gz -C /opt/vault/
   ```
4. **Start Vault**, unseal with 3 of 5 keys from Proton Pass
5. **Verify**: `vault status`, `vault kv list secret/`
6. **Re-deploy backup timer**: Already in systemd, just re-enable

---

## Scenario 3: Single VM Loss — GitLab Server 201

**RTO: ~30 minutes (automated) | ~1 hour (manual)**

### Option 3A: Automated CI Recovery
1. **Trigger CI job**: `recover-gitlab-from-backup` in GitLab disaster-recovery stage
2. **Job will**:
   - Download latest app + config backups from MinIO
   - Extract to GitLab data directory
   - Restore GitLab configuration
   - Restart GitLab
3. **Verify**: Access http://192.168.12.68, test git clone

### Option 3B: Snapshot Rollback
```bash
# Rollback to yesterday's snapshot
curl -sk -X POST "https://192.168.12.6:8006/api2/json/nodes/pve/qemu/201/snapshot/auto-YYYYMMDD-0100/rollback" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET"
```

### Option 3C: Manual Recovery
See `infrastructure/gitlab-dr/README.md`.

1. **Create VM** on pve (VMID 201)
2. **Install GitLab** CE
3. **Restore from backup**:
   ```bash
   mc cp minio/gitlab-backups/gitlab-backup-TIMESTAMP_gitlab_backup.tar /var/opt/gitlab/backups/
   mc cp minio/gitlab-backups/gitlab-backup-TIMESTAMP-config.tar.gz /tmp/
   gitlab-backup restore BACKUP=TIMESTAMP
   tar -xzf /tmp/gitlab-backup-*-config.tar.gz -C /
   gitlab-ctl reconfigure && gitlab-ctl restart
   ```
4. **Re-deploy backup timer**: Already in systemd, just re-enable

---

## Scenario 4: Single VM Loss — iac-control 200

**RTO: ~30 minutes (automated) | ~1 hour (manual)**

### Option 4A: Snapshot Rollback (FASTEST)
```bash
curl -sk -X POST "https://192.168.12.6:8006/api2/json/nodes/pve/qemu/200/snapshot/auto-YYYYMMDD-0100/rollback" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET"
```

### Option 4B: Manual Rebuild
1. **Create VM** on pve using Packer template (VMID 200)
2. **Clone repos** from GitLab:
   ```bash
   git clone http://192.168.12.68/root/sentinel-iac.git ~/sentinel-repo
   git clone http://192.168.12.68/root/overwatch.git ~/overwatch-repo
   ```
3. **Restore secrets** from Vault:
   ```bash
   vault kv get -field=ssh_private_key secret/iac-control/id_sentinel > ~/.ssh/id_sentinel
   vault kv get -field=kubeconfig secret/iac-control/kubeconfig > ~/.kube/config
   vault kv get -field=token secret/iac-control/gitlab-token > ~/.gitlab-token
   ```
4. **Restore etcd backup timer**: Already in systemd (from Ansible role)

---

## Scenario 5: Total Platform Loss

**RTO: ~2-3 hours (automated bootstrap)**

### Prerequisites from Proton Pass
- Proxmox root password
- Vault unseal keys (3 of 5)
- B2 rclone crypt passwords
- GitLab root password

### Recovery Steps

1. **Bootstrap MinIO from B2**:
   - Trigger CI job: `bootstrap-from-b2` OR
   - Run `infrastructure/recovery/bootstrap-from-b2.sh` from any machine with B2 access
   - Script will: create MinIO LXC 301, pull all B2 data, configure rclone hourly sync

2. **Restore Vault**:
   - Run CI job `recover-vault-from-backup` OR
   - Manual: VM 205 + docker-compose + latest backup from MinIO
   - Unseal with Proton Pass keys

3. **Restore GitLab**:
   - Run CI job `recover-gitlab-from-backup` OR
   - Manual: VM 201 + GitLab CE + latest backup from MinIO

4. **Restore iac-control**:
   - Snapshot rollback OR rebuild VM 200 from Packer template
   - Pull secrets from Vault, repos from GitLab

5. **Restore Pangolin proxy** (VM 107):
   - Snapshot rollback OR rebuild from sentinel-iac/pangolin/ configs
   - Populate secrets from Vault, start docker compose
   - Wait for Let's Encrypt cert re-issuance (~5-10 min)

6. **Restore OKD cluster** (if needed):
   - Run restore scripts in `infrastructure/recovery/`
   - Restore etcd from MinIO backup
   - Re-deploy ArgoCD applications from overwatch-gitops

7. **Verify all services**:
   - Check https://home.208.haist.farm dashboard
   - Test CI/CD pipeline
   - Verify all ArgoCD apps are Synced/Healthy

---

## Scenario 6: Pangolin/Traefik Proxy Loss (VM 107)

**Impact**: All external access to `*.208.haist.farm` and `*.haist.farm` services is lost. All backend services continue to work on LAN IPs.
**RTO: ~30 minutes (manual) | ~15 minutes (with IaC)**

### Option 6A: Snapshot Rollback (FASTEST)
```bash
# Find latest snapshot for VM 107 on pve node
curl -sk "https://PROXMOX_API/nodes/pve/qemu/107/snapshot" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET" | grep auto-

# Rollback
curl -sk -X POST "https://PROXMOX_API/nodes/pve/qemu/107/snapshot/auto-YYYYMMDD-HHMM/rollback" \
  -H "Authorization: PVEAPIToken=terraform-prov@pve!api-token=SECRET"
```

### Option 6B: Manual Rebuild
1. **Create VM** on pve (VMID 107, 2 cores, 4GB RAM, 32GB disk, Ubuntu 24.04)
   - Static IP: 192.168.12.168/24, gateway 192.168.12.1
2. **Install Docker**:
   ```bash
   curl -fsSL https://get.docker.com | sh
   ```
3. **Copy configs from Git**:
   ```bash
   # On iac-control or any machine with repo access:
   scp -r sentinel-repo/pangolin/* ubuntu@192.168.12.168:/opt/pangolin/
   ```
4. **Populate secrets from Vault**:
   ```bash
   # Get server.secret from Vault
   vault kv get -field=server_secret secret/pangolin
   # Replace placeholder in /opt/pangolin/config.yml
   sed -i "s/REPLACE_WITH_VAULT_SECRET/ACTUAL_SECRET/" /opt/pangolin/config.yml
   
   # Create .env with secrets
   cat > /opt/pangolin/.env << EOF
   CLOUDFLARE_DNS_API_TOKEN=$(vault kv get -field=cloudflare_dns_token secret/cloudflare)
   NEWT_ID=$(vault kv get -field=newt_id secret/pangolin)
   NEWT_SECRET=$(vault kv get -field=newt_secret secret/pangolin)
   EOF
   ```
5. **Start services**:
   ```bash
   cd /opt/pangolin && docker compose up -d
   ```
6. **Wait for Let's Encrypt cert re-issuance** (~5-10 minutes for DNS-01 challenge via Cloudflare)
7. **Verify routes**:
   ```bash
   curl -sk https://home.208.haist.farm   # Should return 200
   curl -sk https://grafana.208.haist.farm # Should return 302
   ```

### Post-Recovery Checks
- All 3 containers running: `docker ps` (traefik, pangolin, newt)
- TLS certs valid: `curl -sv https://home.208.haist.farm 2>&1 | grep "SSL certificate"`
- All 15+ services accessible via `*.208.haist.farm` routes
- Traefik dynamic configs present in `/opt/pangolin/dynamic/`

---

## Certificate Recovery Reference

This section covers certificate recovery across all platform components.

### Vault SSH CA Certificates
- **Type**: Internal CA, generated at Vault initialization
- **Recovery**: Preserved in Vault data backup. **NEVER re-initialize Vault** — always restore from backup.
  Same CA key = same trust chain. Re-initialization would break all existing SSH trust.
- **Location**: Vault secrets engine `ssh-client-signer`
- **Verification**: `vault read ssh-client-signer/config/ca`

### Let's Encrypt Wildcard Certificates
- **Type**: `*.haist.farm` and `*.208.haist.farm` via Cloudflare DNS-01 challenge
- **Recovery**: Auto-renewed by Traefik. Requires `CLOUDFLARE_DNS_API_TOKEN` in `.env`.
- **Re-issuance time**: 5-10 minutes after Traefik starts (DNS propagation + ACME challenge)
- **Stored at**: `/opt/pangolin/letsencrypt/acme.json` on VM 107
- **If acme.json is lost**: Traefik will automatically request new certs on startup.
  Rate limit: 5 duplicate certs per week (Let's Encrypt). Unlikely to hit in DR scenario.

### OKD Internal Certificates
- **Type**: Operator-managed (service-serving-signer, ingress, API server)
- **Recovery**: After etcd restore, cluster operators auto-reconcile certificates.
  Allow 10-20 minutes for full stabilization.
- **ArgoCD TLS**: Uses `argocd-server-tls` secret signed by `openshift-service-serving-signer`.
  Auto-regenerated by the service CA operator.
- **Verification**: `oc get secret -n openshift-gitops argocd-server-tls`

### Kubeconfig
- **Type**: Client certificate for cluster API access
- **Recovery**: After cluster CA rotation, refresh from master node:
  ```bash
  ssh core@master-1.overwatch.local "sudo cat /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig"
  ```
- **Backup location**: Vault `secret/iac-control/kubeconfig`

---

## Recovery Scripts

All automated recovery scripts are in `infrastructure/recovery/`:

| Script | Purpose | Usage |
|--------|---------|-------|
| `bootstrap-from-b2.sh` | Total recovery from Backblaze B2 | CI job or standalone |
| `restore-vault.sh` | Restore Vault from MinIO backup | CI job or standalone |
| `restore-gitlab.sh` | Restore GitLab from MinIO backup | CI job or standalone |
| `restore-minio.sh` | Rebuild MinIO primary from replica/B2 | CI job or standalone |
| `failover-minio-replica.sh` | Switch to MinIO replica LXC 302 | CI job or standalone |

Run any script with `--help` for detailed usage.

---

## Testing DR Procedures

### Monthly DR Test Checklist
- [ ] Snapshot rollback test (non-prod VM)
- [ ] MinIO replica failover test
- [ ] Restore one VM from backup (in isolated environment)
- [ ] Verify all CI recovery jobs are green
- [ ] Update RTO/RPO metrics based on test results

### Last DR Test: TBD
### Next Scheduled Test: TBD

---

## Contacts & Escalation

- **Primary Admin**: Check Proton Pass for emergency contact
- **Proxmox Access**: Root password in Proton Pass
- **Backblaze Support**: https://www.backblaze.com/company/contact.html
- **GitLab Docs**: https://docs.gitlab.com/ee/raketasks/backup_restore.html

---

## Appendix: Updated RTO/RPO Targets

| Scenario | Old RTO | New RTO (Automated) | RPO |
|----------|---------|---------------------|-----|
| MinIO loss | 30 min | 15 min (replica) | 1 hour (B2 sync) |
| Vault loss | 45 min | 20 min (CI job) | 1 day (daily backup) |
| GitLab loss | 1 hour | 30 min (CI job) | 1 week (weekly backup) |
| iac-control loss | 1 hour | 30 min (snapshot) | 1 day (snapshot) |
| Pangolin proxy loss | 30 min | 15 min (snapshot) | 1 day (snapshot) |
| Total loss | 4 hours | 2-3 hours (bootstrap) | 1 day (B2 sync) |

**Improvements from automation**:
- Snapshots provide ~1-day RPO for quick rollback
- MinIO replication eliminates SPOF, 15min failover
- CI-driven recovery reduces human error
- Automated timers ensure backups never missed
