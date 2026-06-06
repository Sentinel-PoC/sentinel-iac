# Vault Operations -- Project Sentinel

## Architecture Overview

HashiCorp Vault v1.21.2 runs as a Docker container on VM 205 (`vault-server`), hosted on the `208-pve2` Proxmox node. It is the central secrets management, SSH certificate authority, and cryptographic services platform for Project Sentinel.

```
+------------------------------------------------------+
|  208-pve2 (Proxmox)  --  192.168.12.56               |
|                                                      |
|  +--------------------------------------------------+|
|  |  VM 205 -- vault-server (192.168.12.206)         ||
|  |                                                  ||
|  |  +--------------------------------------------+  ||
|  |  | Docker: hashicorp/vault:1.21.2             |  ||
|  |  |   Port: 8200 (API + UI)                    |  ||
|  |  |   Storage: file backend (/vault/file)      |  ||
|  |  |   TLS: cert.pem + key.pem (/vault/tls/)   |  ||
|  |  +--------------------------------------------+  ||
|  |                                                  ||
|  |  Transit auto-unseal <-- iac-control:8201        ||
|  +--------------------------------------------------+|
+------------------------------------------------------+
```

### Access

| Method | URL |
|--------|-----|
| Web UI | `https://vault.208.haist.farm` |
| API (direct) | `https://192.168.12.206:8200` |
| API (from OKD pods) | `https://vault.208.haist.farm` (via pangolin-proxy Traefik) |

The UI is enabled (`ui = true` in config.hcl). Access is routed through Traefik on pangolin-proxy (`192.168.12.168`) using the `vault.208.haist.farm` hostname.

### What Vault Provides

**Secrets Management (KV v2)** -- Centralized storage for all platform credentials. 34 ExternalSecrets across 12 OKD namespaces pull secrets via the External Secrets Operator. Ansible playbooks, CI pipelines, and automation scripts all retrieve credentials from Vault.

**SSH Certificate Authority** -- Every SSH connection to managed VMs uses Vault-signed certificates. Static `authorized_keys` is disabled on all hosts (`AuthorizedKeysFile none`). The cert renewal timer signs fresh certs every 90 minutes with a 2-hour TTL.

**Transit Auto-Unseal** -- A dedicated Transit Vault instance on iac-control provides auto-unseal so the primary Vault automatically unseals after container restarts without operator intervention.

**Kubernetes Authentication** -- OKD workloads authenticate to Vault using Kubernetes service account tokens. Two roles (`external-secrets` and `sentinel-ops`) grant scoped access to secrets.

### Key Files and Paths

| Location | Purpose |
|----------|---------|
| `/opt/vault/data/` | Vault file storage backend (host) |
| `/etc/vault/config/config.hcl` | Vault configuration (host) |
| `/opt/vault/logs/audit.log` | Audit log (host) |
| `/opt/vault/docker-compose.yml` | Docker Compose definition (host) |
| `/etc/vault-backup.env` | MinIO credentials for backups (host, mode 0600) |
| `/usr/local/bin/vault-backup.sh` | Backup script (host) |

### Ansible Role

The `vault-server` Ansible role (`sentinel-iac/ansible/roles/vault-server/`) manages this deployment. The playbook applies three roles in sequence:

1. **`common`** -- CIS hardening baseline (SSH, PAM, auditd, firewall, AIDE)
2. **`docker-host`** -- Docker engine installation
3. **`vault-server`** -- Vault-specific config, compose file, backup timer

### Inventory Entry

```ini
[vault]
vault-server ansible_host=192.168.12.206 ansible_user=root \
  sshd_permit_root_login=prohibit-password \
  sshd_allow_groups="sudo root" \
  firewall_allowed_ports='[22,8200]'
```

Note: `ansible_user=root` and `sshd_allow_groups="sudo root"` are required because Vault runs as Docker containers requiring root-level management. The `sshd_permit_root_login=prohibit-password` setting allows certificate-based root SSH only.

### Dependencies

```
                     iac-control (192.168.12.210)
                          |
               Transit Vault (:8201)
                          |
                    auto-unseal
                          |
                          v
    vault-server (192.168.12.206:8200) <--- pangolin-proxy (Traefik)
         |              |                        |
         |              |                   vault.208.haist.farm
         v              v
    OKD (ESO)     iac-control
    34 secrets    (SSH certs, compliance checks, MCP)
```

If iac-control is down, Transit auto-unseal fails on Vault restart, and SSH certificate renewal stops. If pangolin-proxy is down, OKD pods lose Vault API access via the `.208.haist.farm` hostname (but direct IP still works from the management VLAN).
