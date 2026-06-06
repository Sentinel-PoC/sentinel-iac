# TrueNAS NFS Export Inventory and Hardening Reference

**Last updated:** 2026-06-02 by worker-sec-106 (SEC-106)

TrueNAS NFS exports are managed via the TrueNAS API (`https://192.168.12.205/api/v2.0/sharing/nfs`).
There is no Ansible role or Terraform module that manages them; changes are applied via API call and
documented here. Any future hardening or new export MUST update this file.

API credentials: `secret/truenas.api_token` in Vault.

---

## Export id=1 — /mnt/DATA/data (primary storage)

| Field | Value |
|---|---|
| Path | `/mnt/DATA/data` |
| Networks | `192.168.12.0/24`, `192.168.30.0/24` |
| Hosts | `192.168.12.69`, `192.168.12.114`, `192.168.12.115`, `192.168.12.116` |
| mapall_user | `root` (maps all clients to root:root) |
| maproot_user | `null` |
| ro | false |

Used by: OKD cluster (via 192.168.30.0/24 — NFSv4.1 pinned per TrueNAS NFSv4.2 referral bug),
seedbox (192.168.12.69), pve hosts (.114/.115/.116). OPS-1096 applied mapall hardening.

---

## Export id=2 — /mnt/DATA/backups/langfuse-clickhouse (ORPHANED)

| Field | Value |
|---|---|
| Path | `/mnt/DATA/backups/langfuse-clickhouse` |
| Networks | `[]` (none) |
| Hosts | `192.168.12.210` (iac-control only) |
| maproot_user | `null` (standard root_squash applies) |
| maproot_group | `null` |
| ro | false |

**SEC-106 hardening applied 2026-06-02:**

BEFORE (insecure state):
- `networks: ["192.168.12.0/24"]` — any /24 host could mount
- `maproot_user: "root"`, `maproot_group: "wheel"` — root no-squash, any client wrote as real root

AFTER (current state):
- `networks: []`, `hosts: ["192.168.12.210"]` — only iac-control allowed
- `maproot_user: null`, `maproot_group: null` — standard root_squash active

**Status:** ORPHANED. The backup CronJob `langfuse-ch-backup` writes to S3/MinIO (not NFS).
The directory `/mnt/DATA/backups/langfuse-clickhouse` is empty (created 2026-04-25, never written).
Original backup design (OPS-111-A) used NFS; replaced by S3 approach.

**No active NFS clients mount this export** (confirmed 2026-06-02 via `/proc/fs/nfsd/clients/`).
langfuse-clickhouse pod data is on iSCSI (`iqn.2026-03.farm.haist:okd-langfuse-ch`), not NFS.

If future backup approach reuses NFS, re-evaluate host restriction to the specific backup
executor and set mapall_user to the clickhouse uid (101) rather than restoring root-no-squash.

---

## Export id=3 — /mnt/DATA/logs (VictoriaLogs)

| Field | Value |
|---|---|
| Path | `/mnt/DATA/logs` |
| Networks | `192.168.12.0/24`, `192.168.30.0/24` |
| Hosts | `[]` |
| maproot_user | `null` |
| mapall_user | `null` |
| ro | false |

Used by: VictoriaLogs pod on OKD (PV `victorialogs-nfs-pv` via 192.168.30.205). OPS-807/808.
No explicit user mapping — standard root_squash applies.

---

## IaC Gap

NFS exports are not codified in Ansible or Terraform. This file is the authoritative documentation.
To add programmatic management, create an Ansible role that calls `uri:` against
`https://192.168.12.205/api/v2.0/sharing/nfs` using the Vault token. Track as a future OPS issue.

## Platform Memory Notes

- TrueNAS is VM 108 (IP: 192.168.12.205, storage VLAN: 192.168.30.205).
- NFSv4.2 referral bug: multi-homed TrueNAS silently redirects clients on the 2nd bind IP back
  to the canonical IP. Pin `vers=4.1` on OKD PVs and verify live mount address (not PV nfs.server).
- TrueNAS API token: `secret/truenas.api_token` in Vault at `https://vault.208.haist.farm`.
