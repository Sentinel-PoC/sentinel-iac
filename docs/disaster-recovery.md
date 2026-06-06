# Disaster Recovery

## Backup Schedule

| System | Schedule | Retention | Location |
|--------|----------|-----------|----------|
| Vault | Daily 2:00 AM UTC | 7 days | MinIO + Backblaze B2 |
| GitLab | Weekly Sun 3:00 AM UTC | 4 weeks | MinIO + Backblaze B2 |
| Proxmox snapshots | Daily 1:00 AM UTC | 4 snapshots | Local Proxmox storage |
| MinIO mirror | Every 6 hours | Continuous | Cross-site replication (primary→replica) |
| AIDE FIM | Daily baseline check | — | iac-control local |

## Recovery Time Objectives

### Infrastructure-Level RTOs

| Scenario | RTO | Notes |
|----------|-----|-------|
| Single VM failure | 10–30 min | Restore from golden image + Ansible apply |
| Two VM failure | 30–90 min | Sequential restore, priority by dependency |
| Total loss (all infra) | 3–4 hours | Bootstrap from Backblaze B2, full rebuild |

### Application-Level RTOs (Measured 2026-03-07 Incident)

| Scenario | RTO | Notes |
|----------|-----|-------|
| Harbor PG clean restart (preStop hook) | Seconds | Graceful shutdown, no crash recovery |
| Harbor PG unclean crash (post-fix) | ~20 min | NFS fsync recovery completes uninterrupted with tcpSocket probes + startupProbe (2410s budget) |
| Harbor PG unclean crash (pre-fix) | ~3 hours | Liveness probes killed PG during recovery, each restart added debt. Cascade: all image pulls fail cluster-wide |
| Matrix (dependent on PG + Harbor) | +10–30 min after PG | MAS db-migrate + synapse startup after PG ready |

**Critical Dependency — Harbor Registry**: Harbor is a cluster-wide critical service. When harbor-database is unavailable, Harbor registry auth fails and ALL image pulls from `harbor.208.haist.farm` fail across every namespace. This causes ImagePullBackOff cascade on any pod restart or rollout.

**Incident Reference**: `sentinel-cache/incidents/2026-03-07-pg-crash-loop.md`

**Mitigations Deployed (2026-03-07)**:
- tcpSocket probes replace exec probes (avoids PG backend SIGKILL)
- startupProbe with failureThreshold=240 (2410s budget for NFS recovery)
- preStop lifecycle hook for graceful PG shutdown
- terminationGracePeriodSeconds=120

**Planned Mitigation**: OPS-18 — Migrate PG PVCs from NFS to iSCSI on TrueNAS VAST SSD. Expected to reduce unclean crash recovery from ~20 min to seconds (local filesystem fsync vs NFS protocol overhead).

## Restore Procedures

All restore scripts are in `infrastructure/recovery/`:

### Vault Restore

```bash
./restore-vault.sh <backup-file>
```

Restores Vault data directory from encrypted backup. Requires unseal keys after restore. Vault backup includes all KV secrets, auth methods, and policies.

### GitLab Restore

```bash
./restore-gitlab.sh <backup-file>
```

Restores GitLab from `gitlab-backup-create` archive. Includes repositories, CI/CD config, user data, and OIDC settings. Requires matching GitLab version.

### MinIO Restore

```bash
./restore-minio.sh <backup-file>
```

Restores MinIO object storage from mirror. Primary at 192.168.12.58, replica at 192.168.12.59.

### etcd Restore (OKD)

```bash
./restore-etcd.sh <snapshot-file>
```

Restores OKD cluster etcd from snapshot. Requires all 3 master nodes to be accessible. Follow OKD disaster recovery procedures for cluster-wide restore.

### Bootstrap from Backblaze B2

```bash
./bootstrap-from-b2.sh
```

Full infrastructure rebuild from offsite backups. Use when local backups are unavailable (total site loss). Pulls encrypted backups from Backblaze B2 and bootstraps core services in dependency order.

## DR Automation

Backup jobs run as systemd timers on their respective VMs:

- **Vault backup timer** on vault-server (192.168.12.206)
- **GitLab backup timer** on gitlab-server (192.168.12.68)
- **Proxmox snapshot jobs** configured per-host

### DR Testing

DR procedures are validated in CI via the `disaster-recovery` stage in the sentinel-iac pipeline. Vault and GitLab restore have been tested and confirmed working.

## Maintenance Mode

During manual infrastructure work, disable automated remediation to prevent conflicts:

```bash
# On iac-control:
~/scripts/sentinel-maintenance.sh enter --reason "DR testing" --timeout 4h --scope all
~/scripts/sentinel-maintenance.sh status
~/scripts/sentinel-maintenance.sh exit
```

Scope options: `all` (blocks all automation), `remediation` (blocks auto-fix only, allows monitoring).
