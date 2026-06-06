# Ansible Roles

## Overview

Ansible manages configuration for all VMs via a role-based architecture. Each VM has a dedicated playbook that applies the `common` CIS hardening role plus a service-specific role.

### Inventory

The inventory file at `ansible/inventory/hosts.ini` defines all managed hosts with per-host variables controlling behavior:

```ini
[vm_name]
192.168.12.x ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_sentinel

[vm_name:vars]
firewall_enabled=True
firewall_allowed_ports=[22, 443]
auditd_enabled=True
sshd_permit_root_login=False
```

Key host vars: `firewall_enabled`, `firewall_allowed_ports`, `auditd_enabled`, `sshd_permit_root_login`, `ansible_user`, `ansible_ssh_private_key_file`.

> **Note**: INI booleans must use `True`/`False` (capitalized), not `true`/`false`.

## Common Role (CIS Hardening Baseline)

Applied to every VM via the `common` role. Tasks are split across focused files:

| Task File | Purpose |
|-----------|---------|
| `main.yml` | Task orchestration and includes |
| `sshd-hardening.yml` | SSH server hardening (key-only auth, protocol 2, idle timeout) |
| `pam-hardening.yml` | PAM configuration (password complexity, login limits) |
| `auditd.yml` | Audit daemon rules (file access, privilege escalation, syscalls) |
| `firewall.yml` | UFW firewall configuration (per-host allowed ports) |
| `os-hardening.yml` | Kernel sysctl tuning, filesystem hardening, login banners |

### Tag-Based Execution

The `common` role supports selective application via tags:

```bash
# Apply only CIS hardening
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --tags common

# Apply only firewall rules
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --tags firewall
```

## Service Roles

| Role | Target VM | Purpose |
|------|-----------|---------|
| `iac-control` | 192.168.12.210 | HAProxy, dnsmasq, Squid, keepalived, nginx PXE, iptables, Tailscale |
| `vault-server` | 192.168.12.206 | HashiCorp Vault (Docker), TLS cert management, backup cron |
| `gitlab-server` | 192.168.12.68 | GitLab CE, OIDC config, backup schedule |
| `docker-host` | Multiple | Shared Docker CE installation (used by vault-server, seedbox, etc.) |
| `config-server` | 10.0.0.2 | HA failover node (keepalived BACKUP, DNS-only dnsmasq) |
| `minio-server` | 192.168.12.58/59 | MinIO object storage, replication config |
| `seedbox` | 192.168.12.69 | qBittorrent + gluetun VPN container |
| `wazuh-server` | 192.168.12.100 | Wazuh manager, custom rules, agent enrollment |
| `wazuh-agent` | Multiple | Wazuh agent deployment |
| `crowdsec` | Multiple | CrowdSec intrusion prevention |

### iac-control Role Tags

The `iac-control` role supports granular tag-based execution:

```
packages, network, sysctl, netplan, dnsmasq, haproxy, squid, egress, firewall, iptables
```

## Playbooks

Each VM has a dedicated playbook in `ansible/playbooks/`:

```
config-server.yml    gitlab-server.yml    pangolin-proxy.yml    vault-server.yml
crowdsec.yml         iac-control.yml      seedbox-vm.yml        wazuh-server.yml
                     minio-bootstrap.yml
```

### Running Playbooks

```bash
# From iac-control:
cd ~/sentinel-repo/ansible

# Full apply
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml

# Drift check (dry run)
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --check --diff
```

## Automation

Drift detection and remediation run as systemd timers on iac-control:

| Timer | Schedule (UTC) | Action |
|-------|---------------|--------|
| Drift detection | 8:00 AM | `--check --diff`, logs results, Wazuh alerts (rules 100420-100428) |
| Drift remediation | 8:30 AM | Auto-applies `common` role if drift detected |

Remediation respects maintenance mode — use `~/scripts/sentinel-maintenance.sh enter --reason "..." --scope remediation` to block auto-fix during manual work.
