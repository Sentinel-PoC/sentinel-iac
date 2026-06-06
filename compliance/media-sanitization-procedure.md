# Media Sanitization Procedure (MP-6)

**Document ID**: PROC-MP-001
**Version**: 1.0
**Effective Date**: 2026-02-08
**Last Review**: 2026-02-08
**Next Review**: 2027-02-08
**Owner**: Haists Consulting
**Classification**: Internal
**System**: Overwatch Platform

---

## 1. Purpose

This procedure defines the step-by-step process for sanitizing digital storage media before disposal, reuse, or decommissioning. It ensures that sensitive data cannot be recovered from media leaving the platform's control.

## 2. Scope

This procedure covers sanitization of all media types used by the Overwatch Platform:

- Virtual disk images (VMs and LXC containers on Proxmox)
- Physical storage devices (SSDs and HDDs in Proxmox hosts)
- Removable media (USB drives used for key transport)
- Cloud storage (Backblaze B2 buckets)
- Object storage (MinIO buckets)

## 3. Sanitization Methods

Per NIST SP 800-88 Rev 1, the following sanitization levels apply:

| Level | Method | When to Use |
|-------|--------|-------------|
| **Clear** | Logical overwrite (single pass) | Reuse within the platform |
| **Purge** | Crypto-erase or multi-pass overwrite | Transfer outside the platform |
| **Destroy** | Physical destruction | End-of-life disposal |

## 4. Procedures by Media Type

### 4.1 Virtual Machine Decommission (Proxmox)

**Scenario**: VM is no longer needed or being rebuilt from scratch.

1. **Verify** no active services depend on this VM:
   ```bash
   # Check if VM is referenced in Ansible inventory or Terraform state
   grep -r "VM_IP_ADDRESS" ~/sentinel-repo/ansible/inventory/
   ```

2. **Backup** any data that needs to be preserved (if applicable):
   ```bash
   # Take a final snapshot before destruction
   pvesh create /nodes/NODE/qemu/VMID/snapshot --snapname pre-decommission
   ```

3. **Stop** the VM:
   ```bash
   qm stop VMID
   ```

4. **Destroy** the VM and all associated disks:
   ```bash
   qm destroy VMID --destroy-unreferenced-disks 1 --purge 1
   ```
   - `--destroy-unreferenced-disks 1` removes all disk images
   - `--purge 1` removes from replication, HA, backup jobs, and firewall

5. **Verify** removal:
   ```bash
   qm list | grep VMID  # Should return empty
   ls /var/lib/vz/images/VMID/  # Should not exist
   ```

6. **Record** sanitization in the log (Section 6).

**Note**: Proxmox thin-provisioned storage (LVM-thin, ZFS) does not guarantee zero-fill on delete. For sensitive VMs (vault-server), perform a pre-destroy wipe:
```bash
# SSH into the VM before stopping
ssh user@VM_IP "sudo dd if=/dev/zero of=/zero.fill bs=1M; sudo rm /zero.fill"
```

### 4.2 LXC Container Decommission

**Scenario**: LXC container (e.g., decommissioned MinIO node) being removed.

1. **Stop** the container:
   ```bash
   pct stop CTID
   ```

2. **Destroy** the container:
   ```bash
   pct destroy CTID --destroy-unreferenced-disks 1 --purge 1
   ```

3. **Verify** removal:
   ```bash
   pct list | grep CTID  # Should return empty
   ```

4. **Record** sanitization in the log (Section 6).

### 4.3 MinIO Bucket Purge

**Scenario**: Removing a MinIO bucket and all its contents (e.g., decommissioning a backup bucket).

1. **Verify** no active services depend on this bucket:
   ```bash
   mc ls minio/BUCKET_NAME --summarize
   ```

2. **Remove** all objects and the bucket:
   ```bash
   mc rb minio/BUCKET_NAME --force  # Removes bucket and all contents
   ```

3. **Verify** on replica (if applicable):
   ```bash
   mc rb minio-replica/BUCKET_NAME --force
   ```

4. **Record** sanitization in the log (Section 6).

### 4.4 Backblaze B2 Bucket Purge

**Scenario**: Removing offsite backup data from B2.

1. **Remove** rclone crypt remote configuration:
   ```bash
   rclone config delete b2-encrypted
   ```

2. **Delete** all objects in the B2 bucket:
   ```bash
   rclone purge b2:BUCKET_NAME
   ```

3. **Delete** the bucket via B2 dashboard or CLI:
   ```bash
   b2 delete-bucket BUCKET_NAME
   ```

4. **Revoke** the B2 application key:
   - Log in to Backblaze dashboard → App Keys → Delete key

5. **Remove** encryption keys from Vault:
   ```bash
   vault kv delete secret/backblaze
   vault kv delete secret/minio-config/b2-encryption-keys
   ```

6. **Record** sanitization in the log (Section 6).

**Note**: B2 data encrypted with rclone crypt is cryptographically inaccessible once the encryption keys are destroyed (crypto-erase). Deleting keys from both Vault and Proton Pass constitutes effective sanitization even if B2 objects persist temporarily due to retention policies.

### 4.5 Physical SSD Sanitization

**Scenario**: Replacing or disposing of an SSD from a Proxmox host.

1. **Migrate** all VMs off the host or disk (Proxmox live migration or backup/restore).

2. **Perform ATA Secure Erase** (preferred for SSDs):
   ```bash
   # Identify the drive
   lsblk
   hdparm -I /dev/sdX | grep -i "security"

   # Set a temporary password and issue secure erase
   hdparm --user-master u --security-set-pass temp /dev/sdX
   hdparm --user-master u --security-erase temp /dev/sdX
   ```

3. **If ATA Secure Erase is not supported**, use full overwrite:
   ```bash
   dd if=/dev/urandom of=/dev/sdX bs=1M status=progress
   ```

4. **Verify** the drive is wiped:
   ```bash
   hexdump -C /dev/sdX | head -20  # Should show random/zero data
   ```

5. **For disposal**: Physical destruction (drill, shred) is recommended for SSDs due to potential wear-leveling remnants.

6. **Record** sanitization in the log (Section 6).

### 4.6 Physical HDD Sanitization

**Scenario**: Replacing or disposing of an HDD from a Proxmox host.

1. **Single-pass overwrite** (NIST 800-88 Clear):
   ```bash
   dd if=/dev/zero of=/dev/sdX bs=1M status=progress
   ```

2. **Verify**:
   ```bash
   hexdump -C /dev/sdX | head -20  # Should show all zeros
   ```

3. **For disposal**: Physical destruction (degauss + shred) or certified destruction service.

4. **Record** sanitization in the log (Section 6).

### 4.7 USB / Removable Media Sanitization

**Scenario**: Wiping a USB drive used for key transport or emergency recovery.

1. **Full overwrite**:
   ```bash
   dd if=/dev/urandom of=/dev/sdX bs=1M status=progress
   ```

2. **Reformat** (if reusing):
   ```bash
   mkfs.ext4 /dev/sdX1
   ```

3. **For disposal**: Physical destruction (cut/shred the USB drive).

4. **Record** sanitization in the log (Section 6).

### 4.8 Crypto-Erase (Encrypted Volumes)

**Scenario**: Data encrypted with known keys — destroy the keys to render data irrecoverable.

Applicable to:
- B2 backups encrypted with rclone crypt
- LUKS-encrypted volumes (if used in future)

**Procedure**:
1. Delete the encryption key from Vault.
2. Delete the encryption key from Proton Pass.
3. Confirm no other copies of the key exist.
4. Document the crypto-erase event.

**Note**: Crypto-erase is a valid NIST 800-88 Purge method when the encryption is AES-256 or stronger and key management is verified.

## 5. Sanitization Decision Matrix

| Scenario | Media Type | Minimum Level | Recommended Method |
|----------|-----------|---------------|-------------------|
| VM rebuild (same platform) | Virtual disk | Clear | `qm destroy` + rebuild |
| VM decommission (permanent) | Virtual disk | Clear | Pre-destroy zero-fill + `qm destroy` |
| SSD reuse (same host) | Physical SSD | Clear | ATA Secure Erase |
| SSD disposal | Physical SSD | Destroy | ATA Secure Erase + physical destruction |
| HDD reuse | Physical HDD | Clear | `dd if=/dev/zero` |
| HDD disposal | Physical HDD | Destroy | Degauss + physical destruction |
| USB after key transport | Removable | Purge | `dd if=/dev/urandom` |
| B2 bucket removal | Cloud | Purge | Crypto-erase (delete keys) + delete objects |
| MinIO bucket removal | Object store | Clear | `mc rb --force` |

## 6. Sanitization Log

All sanitization events SHALL be recorded with the following information:

| Field | Description |
|-------|------------|
| Date | Date of sanitization |
| Media ID | VM ID, disk serial, bucket name, or device path |
| Media Type | Virtual disk, SSD, HDD, USB, cloud bucket |
| Data Description | What data was stored (e.g., "Vault secrets", "GitLab backups") |
| Sanitization Method | Method used (e.g., ATA Secure Erase, dd zero-fill, crypto-erase) |
| NIST 800-88 Level | Clear, Purge, or Destroy |
| Operator | Person who performed sanitization |
| Verification | How sanitization was verified |

Sanitization logs SHALL be maintained in `compliance/sanitization-log.md` and retained for 1 year.

## 7. References

- NIST SP 800-88 Rev 1: Guidelines for Media Sanitization
- NIST SP 800-53 Rev 5: MP-6
- Media Protection Policy (`policies/media-protection-policy.md`)
