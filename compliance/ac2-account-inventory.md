# iac-control Account Inventory (AC-2)
**System:** iac-control.haist.farm (192.168.12.210)  
**Date:** 2026-06-02  
**Compliance:** NIST 800-53 AC-2

## Shell-Enabled Accounts

### root
- **UID:** 0
- **Shell:** /bin/bash
- **Auth Method:** SSH key only (via Vault-signed certificates)
- **Purpose:** System administration, emergency break-glass access
- **Access:** Vault-authenticated principals only (30-min JIT cert TTL)
- **Status:** ACTIVE, REQUIRED

### ubuntu
- **UID:** 1000
- **Shell:** /bin/bash
- **Auth Method:** SSH key only (via Vault-signed certificates)
- **Purpose:** Primary administrative account for Ansible automation and routine operations; also runs the forgejo-runner CI/CD service (OPS-319)
- **Access:** Vault-authenticated principals only (30-min JIT cert TTL)
- **IaC Source:** `roles/common/tasks/main.yml` (OPS-232)
- **Status:** ACTIVE, REQUIRED

### koiakoia
- **UID:** auto-assigned (1002+ range; uid 1001 taken by historical gitlab-runner)
- **Shell:** /bin/bash
- **Auth Method:** SSH key only (via Vault-signed certificates)
- **Purpose:** Operator interactive access; principal `koiakoia` must exist as Linux user for Vault JIT SSH cert auth to succeed (OPS-712)
- **Groups:** sudo, adm, docker
- **Access:** Vault-authenticated principals only (30-min JIT cert TTL)
- **IaC Source:** `roles/common/tasks/main.yml` (OPS-712)
- **Status:** ACTIVE, REQUIRED

### sync
- **UID:** 4
- **Shell:** /bin/sync
- **Auth Method:** N/A (system account)
- **Purpose:** System utility for syncing filesystems
- **Status:** ACTIVE, SYSTEM ACCOUNT

## Service Accounts (No Shell)

### forgejo-runner (service, runs as ubuntu)
- **System User:** No dedicated system user; service runs as `ubuntu` (UID 1000)
- **Shell:** N/A — runs as ubuntu user per systemd `User=ubuntu` in service file
- **Auth Method:** Forgejo API token stored in /opt/forgejo-runner/.runner (runner-generated)
- **Purpose:** Forgejo Actions CI/CD pipeline execution on iac-control
- **Access:** Automated processes only; binary at /usr/local/bin/forgejo-runner
- **IaC Source:** `roles/iac-control/files/forgejo-runner.service` (OPS-319)
- **Status:** ACTIVE — runs under ubuntu account, not a separate system user
- **Note:** The `forgejo-runner` service does not create a separate OS account;
  it reuses the `ubuntu` account. This is documented to distinguish from the
  former `gitlab-runner` OS account (now removed).

## Removed Accounts

### gitlab-runner (REMOVED)
- **Former UID:** 1001
- **Reason for Removal:** GitLab decommissioned; all CI/CD migrated to Forgejo.
  References to `gitlab-runner` in older issues/scripts are stale residue.
- **Status:** REMOVED — account should not exist on production hosts

## Authentication Summary

| Account | Interactive Shell | SSH Allowed | Vault-Signed Required | Password Auth |
|---------|------------------|-------------|----------------------|---------------|
| root | Yes | Yes | Yes (JIT 30-min) | No |
| ubuntu | Yes | Yes | Yes (JIT 30-min) | No |
| koiakoia | Yes | Yes | Yes (JIT 30-min) | No |
| sync | System only | No | N/A | No |
| forgejo-runner | No (runs as ubuntu) | No | N/A | No |

## Access Control Mechanisms

1. **Vault SSH CA:** All interactive access requires Vault-signed SSH certificates (30-min TTL)
2. **No Password Auth:** Password authentication disabled system-wide (`PasswordAuthentication no` enforced by Ansible)
3. **Service Isolation:** Forgejo CI runner uses no dedicated OS account; runs as ubuntu with working directory `/opt/forgejo-runner`
4. **Principal Mapping:** sshd `AuthorizedPrincipalsFile` enforces that cert principal matches Linux username; unknown principals are denied at sshd level
5. **Key-Based Only:** All authentication uses SSH keys or Vault-signed certificates

## Compliance Notes

- ✅ AC-2(1): Automated account management via Vault and Ansible IaC
- ✅ AC-2(2): Temporary/emergency accounts via short-lived Vault JIT certs (30-min TTL)
- ✅ AC-2(3): No service accounts with interactive shell (forgejo-runner runs as ubuntu but via systemd, not interactive login)
- ✅ AC-2(4): Automated audit capability through Vault audit logging and Wazuh syscheck

## Review Schedule
- **Last Review:** 2026-06-02
- **Next Review:** 2026-09-02 (quarterly)
- **Owner:** Haists Consulting
