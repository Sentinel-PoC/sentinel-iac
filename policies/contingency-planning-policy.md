# Contingency Planning Policy (CP-1)

**Document ID**: POL-CP-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for contingency planning, backup, and disaster recovery for the Overwatch Platform. It ensures that critical systems can be restored within acceptable timeframes following any disruption.

## 2. Scope

This policy applies to all Overwatch Platform components, backup systems, and recovery procedures including:

- All production VMs and LXC containers
- OKD cluster and containerized workloads
- Data stores (Vault secrets, GitLab repositories, MinIO object storage)
- Backup infrastructure (MinIO primary/replica, Backblaze B2)
- Recovery automation (CI/CD recovery jobs, restore scripts)

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve contingency plan, initiate recovery, hold Vault unseal keys |
| **Automated Backups** (systemd timers) | Execute scheduled backups per retention schedule |
| **MinIO Replication** | Mirror backup data between primary (pve3) and replica (pve) |
| **GitLab CI/CD** | Provide one-click recovery jobs for each VM |

## 4. Policy Statements

### 4.1 Contingency Plan (CP-2)

- A documented contingency plan SHALL exist covering all critical systems.
- The plan SHALL define Recovery Time Objectives (RTO) and Recovery Point Objectives (RPO) for each component.
- The DR Runbook (`infrastructure/DR-RUNBOOK.md`) SHALL be the authoritative recovery reference.

### 4.2 Contingency Plan Testing (CP-4)

- DR procedures SHALL be tested at least annually.
- Tests SHALL include at minimum: backup integrity verification and single-VM restore.
- Test results SHALL be documented with date, scope, and outcome.

### 4.3 Backup Policy (CP-9)

- Automated backups SHALL run on the following schedule:

| Component | Frequency | Retention | Storage |
|-----------|-----------|-----------|---------|
| Vault data | Daily 2:00 AM | 30 days | MinIO `vault-backups` bucket |
| GitLab data + config | Weekly Sunday 3:00 AM | 4 copies | MinIO `gitlab-backups` bucket |
| Proxmox VM snapshots | Daily 1:00 AM | 4 snapshots | Local Proxmox storage |
| etcd (OKD) | Daily 4:00 AM | 30 days | MinIO `etcd-backups` bucket |
| MinIO data | Continuous (6h mirror) | Mirrored | Replica LXC 302 on pve |
| All MinIO buckets | Daily rclone sync | Versioned | Backblaze B2 (encrypted) |

- Backup integrity SHALL be verified during DR tests.
- Offsite backups (B2) SHALL be encrypted with keys stored separately in Vault and Proton Pass.

### 4.4 System Recovery (CP-10)

- Recovery Time Objectives:

| Scenario | RTO |
|----------|-----|
| Single VM failure | 10-30 minutes (CI pipeline rebuild) |
| Two VM failure | 30-90 minutes |
| Total platform loss | 3-4 hours (bootstrap-from-b2) |

- Recovery SHALL follow the dependency order: MinIO → Vault → GitLab → iac-control → OKD → seedbox.
- Five manual one-click recovery jobs SHALL be maintained in GitLab CI (`ci/disaster-recovery.yml`).

### 4.5 Alternative Processing Site (CP-7)

- MinIO replica on a separate Proxmox host (pve) provides geographic redundancy within the cluster.
- Backblaze B2 provides offsite backup for total site loss recovery.
- The bootstrap-from-b2 script SHALL be capable of restoring the platform from scratch using only B2 data and Proton Pass credentials.

## 5. Enforcement

- Backup timer failures SHALL generate alerts via systemd `OnFailure` handlers.
- Missing backups SHALL be investigated within 24 hours of detection.
- DR tests that reveal recovery failures SHALL result in immediate remediation tracked in the POA&M.

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- The contingency plan SHALL be updated after any significant infrastructure change.
- DR tests SHALL be conducted annually at minimum, with results documented.

## 7. References

- NIST SP 800-53 Rev 5: CP-1, CP-2, CP-4, CP-6, CP-7, CP-9, CP-10
- DR Runbook (`infrastructure/DR-RUNBOOK.md`)
- Backup restore scripts (`infrastructure/recovery/`)
