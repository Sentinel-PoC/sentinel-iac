# Media Protection Policy (MP-1)

**Document ID**: POL-MP-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This policy establishes the requirements for protecting, handling, transporting, and sanitizing digital media containing Overwatch Platform data. It ensures that sensitive information is protected throughout the media lifecycle.

## 2. Scope

This policy applies to all digital storage media associated with the Overwatch Platform:

- Proxmox host local storage (SSDs/HDDs in pve, 208-pve2, pve3)
- Virtual disk images (qcow2, raw) for all VMs and LXC containers
- USB drives or portable media used for key transport or backup
- Backblaze B2 cloud storage (offsite backups)
- MinIO object storage volumes (primary LXC 301, replica LXC 302)
- NFS shares used by OKD persistent volumes

## 3. Roles and Responsibilities

| Role | Responsibility |
|------|---------------|
| **System Owner** (Haists Consulting) | Approve media handling procedures, perform physical media sanitization, manage encryption keys |
| **Vault** | Store and control access to encryption keys (B2 crypt passwords, SSH keys) |
| **rclone** | Encrypt data in transit and at rest for Backblaze B2 offsite backups |
| **Proxmox** | Manage virtual disk lifecycle (create, snapshot, destroy) |

## 4. Policy Statements

### 4.1 Media Access (MP-2)

- Physical access to Proxmox hosts SHALL be restricted to the system owner.
- Proxmox web UI and API access SHALL require authentication (API tokens stored in Vault).
- MinIO bucket access SHALL require access keys managed via MinIO admin console.

### 4.2 Media Marking (MP-3)

- Physical media (drives, USB sticks) containing platform data SHALL be labeled with:
  - System name ("Overwatch Platform")
  - Data classification ("Internal")
  - Date of creation
- Virtual media does not require marking — managed via Proxmox inventory and VM naming conventions.

### 4.3 Media Storage (MP-4)

- Physical hosts SHALL be located in a physically secured area.
- Offsite backups (Backblaze B2) SHALL be encrypted at rest using rclone crypt with keys stored in Vault (`secret/backblaze` and `secret/minio-config/b2-encryption-keys`).
- Encryption keys for B2 SHALL be backed up in Proton Pass (separate from the encrypted data).

### 4.4 Media Transport (MP-5)

- Digital data in transit SHALL be encrypted:
  - SSH (SCP/SFTP) for VM-to-VM transfers
  - HTTPS/TLS for MinIO API, Vault API, GitLab
  - rclone crypt for B2 uploads
- Physical media transport (e.g., USB with Vault unseal keys) SHALL be hand-carried by the system owner only.

### 4.5 Media Sanitization (MP-6)

- Before decommissioning or repurposing any storage media:

| Media Type | Sanitization Method |
|-----------|-------------------|
| Virtual disks (VM decommission) | Delete VM in Proxmox (zeroes on thin provision), remove snapshots |
| LXC container storage | Destroy LXC in Proxmox |
| Physical SSD | ATA Secure Erase or physical destruction |
| Physical HDD | NIST 800-88 Clear (single-pass overwrite) or physical destruction |
| USB drives | Full overwrite (`dd if=/dev/urandom`) or physical destruction |
| Cloud storage (B2) | Delete all objects, delete bucket, confirm via B2 dashboard |

- Sanitization SHALL be documented with date, media identifier, method used, and operator.
- See the Media Sanitization Procedure (`compliance/media-sanitization-procedure.md`) for step-by-step instructions.

### 4.6 Media Use (MP-7)

- Removable media SHALL NOT be connected to production systems except for:
  - Initial Proxmox host installation
  - Emergency recovery operations (documented in DR Runbook)
- USB autorun SHALL be disabled on all systems.

## 5. Enforcement

- Unsanitized media SHALL NOT leave the system owner's physical control.
- Unencrypted offsite backups SHALL be considered a policy violation.
- Media sanitization records SHALL be retained for 1 year.

## 6. Review Schedule

- This policy SHALL be reviewed annually by the system owner.
- Media handling procedures SHALL be updated when new storage types are introduced.
- Encryption key rotation SHALL be performed annually or upon suspected compromise.

## 7. References

- NIST SP 800-53 Rev 5: MP-1, MP-2, MP-3, MP-4, MP-5, MP-6, MP-7
- NIST SP 800-88 Rev 1: Guidelines for Media Sanitization
- Media Sanitization Procedure (`compliance/media-sanitization-procedure.md`)
- DR Runbook (`infrastructure/DR-RUNBOOK.md`)
