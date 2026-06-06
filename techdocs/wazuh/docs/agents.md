# Agents

## Agent Inventory

Wazuh monitors 11 registered agents (9 active, 2 disconnected legacy agents).

### Active Agents

| Agent ID | Hostname | IP | OS | What It Monitors |
|----------|----------|-----|-----|------------------|
| 000 | wazuh (server) | 192.168.12.100 | Ubuntu 22.04 | Self-monitoring, manager health |
| 002 | 208-pve2 | 192.168.12.56 | Debian 13 | Proxmox hypervisor (72 CPU, 125GB) |
| 004 | seedbox | 192.168.12.69 | Ubuntu 22.04 | qBittorrent, gluetun VPN, Docker containers |
| 005 | iac-control | 192.168.12.210 | Ubuntu 24.04 | IaC orchestration, HAProxy, Squid, dnsmasq |
| 006 | pangolin-proxy | 192.168.12.168 | Ubuntu 24.04 | Traefik reverse proxy, cloudflared, CrowdSec |
| 007 | pve3 | 192.168.12.57 | Debian 13 | Proxmox hypervisor (32 CPU, 125GB) |
| 008 | pve | 192.168.12.6 | Debian 13 | Proxmox hypervisor (32 CPU, 62GB) |
| 009 | vault-server | 192.168.12.206 | Ubuntu 24.04 | HashiCorp Vault (Docker), secrets, SSH CA |
| 010 | gitlab-server | 192.168.12.68 | Ubuntu 24.04 | GitLab CI/CD, container registry |

### Disconnected Agents (Legacy)

| Agent ID | Hostname | OS | Notes |
|----------|----------|-----|-------|
| 001 | 208PC001 | Windows 11 Pro | Legacy Windows workstation, disconnected |
| 003 | haistswebsrv | Ubuntu 24.04 | Decommissioned web server, disconnected |

**Note on agent ID references**: The CLAUDE.md uses shorthand agent references (001=vault, 002=pangolin, 006=seedbox, 007=iac-control, 008=gitlab) that differ from the actual Wazuh agent IDs listed above. The table above reflects the authoritative agent inventory from the live deployment.

## SCA (CIS Benchmark) Scores

Security Configuration Assessment runs CIS benchmarks every 12 hours on all agents. Scores as of the most recent SCA remediation sprint (2026-02-21):

### Hardened VMs (Ubuntu 24.04, CIS v1.0.0)

| Agent | Score | Delta |
|-------|-------|-------|
| pangolin-proxy | **80%** | +1% from sprint |
| gitlab-server | **79%** | +1% from sprint |
| iac-control | **78%** | +1% from sprint |
| vault-server | **78%** | +1% from sprint |

### Other VMs

| Agent | Benchmark | Score | Notes |
|-------|-----------|-------|-------|
| wazuh (server) | CIS Ubuntu 22.04 v2.0.0 | 45% | Pending rescan after hardening |
| seedbox | CIS Ubuntu 22.04 v2.0.0 | 62% | +18% after initial hardening |
| 208-pve2 | CIS Debian 13 | 40% | Proxmox hypervisor, not hardened |
| pve3 | CIS Debian 13 | 40% | Proxmox hypervisor, not hardened |
| pve | CIS Debian 13 | 40% | Proxmox hypervisor, not hardened |

### Top CIS Failures (Common Across Ubuntu Servers)

1. Unused filesystem kernel modules not disabled
2. `/tmp` not on separate partition (nodev, nosuid, noexec)
3. `/dev/shm` noexec not set
4. `/home` not on separate partition
5. `/var` not on separate partition

Partition-related checks account for approximately 30% of all failures. These are architectural -- the VMs use single-disk cloud-init deployments and would require rebuilds to address.

### Risk-Accepted Items (~61 Checks)

Documented in the SCA Risk Acceptance Register:

| Category | Count | Rationale |
|----------|-------|-----------|
| Partition hardening | ~30 | Cloud-init single-disk, rebuild required |
| Bootloader password | ~4 | VMs, Proxmox console is authenticated |
| IPv6 firewall rules | ~20 | IPv6 not in use |
| Vault root login | 1 | Docker management, SSH CA enforced |
| IP forwarding | ~4 | Routing/proxy function on iac-control + pangolin |
| AIDE database format | ~2 | AIDE operational, format differs from CIS expectation |

### SCA Remediation Applied

The following hardening categories were applied during the SCA remediation sprint:

1. **NTP/Chrony** -- Chrony package installed, configured with NTP pool sources, service enabled
2. **AppArmor Enforce** -- All loaded AppArmor profiles switched from complain to enforce mode
3. **Audit Tool Permissions** -- `/sbin/auditctl`, `/sbin/auditd`, `/sbin/ausearch`, `/sbin/aureport` tightened to 0750
4. **Remote Syslog** -- rsyslog forwarding configured to Wazuh server (192.168.12.100:514)
5. **SSH AllowGroups** -- `AllowGroups` directive added to sshd_config (per-host group lists)
6. **UFW Logging + IPv6** -- UFW logging set to medium, IPv6=yes in `/etc/default/ufw`

**Gotcha**: `AllowGroups sudo` breaks root SSH if root is not in the sudo group. Override with `sshd_allow_groups="sudo root"` in Ansible inventory for root-login VMs (vault, minio).

## Agent Deployment

### Ansible Role: wazuh-agent

Agent deployment is managed by the `wazuh-agent` Ansible role.

**Role structure**:

```
ansible/roles/wazuh-agent/
  defaults/main.yml          # Manager IP, config path, LXC detection
  tasks/main.yml             # Package install + config deployment
  templates/ossec.conf.j2    # Agent ossec.conf template
  handlers/main.yml          # Agent restart handler
```

**Default variables** (`defaults/main.yml`):

```yaml
wazuh_manager_ip: "192.168.12.100"
wazuh_agent_config_path: "/var/ossec/etc/ossec.conf"
# This ensures we don't try to run auditd on LXC where it's not supported
is_lxc: "{{ ansible_virtualization_type == 'lxc' }}"
```

### Agent Configuration

From `ossec.conf.j2`, each agent is configured with:

```xml
<client>
  <server>
    <address>192.168.12.100</address>
    <port>1514</port>
    <protocol>tcp</protocol>
  </server>
  <config-profile>ubuntu, ubuntu24, ubuntu24.04</config-profile>
  <notify_time>20</notify_time>
  <time-reconnect>60</time-reconnect>
  <auto_restart>yes</auto_restart>
  <crypto_method>aes</crypto_method>
  <enrollment>
    <enabled>yes</enabled>
    <agent_name>{{ inventory_hostname }}</agent_name>
  </enrollment>
</client>
```

Key agent settings:

- **Communication**: TCP on port 1514, AES encryption
- **Auto-enrollment**: Enabled via authd (port 1515)
- **Reconnect**: 60-second reconnect interval
- **Notify**: 20-second keepalive interval
- **Active response**: Enabled with CA verification

### Agent Monitoring Capabilities

Each agent monitors:

| Module | Interval | What |
|--------|----------|------|
| FIM (syscheck) | 12h | /etc, /usr/bin, /usr/sbin, /bin, /sbin, /boot |
| Rootcheck | 12h | Rootkit files/trojans, system anomalies |
| SCA | 12h | CIS Benchmark checks |
| Syscollector | 1h | Hardware, OS, packages, ports, processes, users, services |
| Log analysis | Continuous | journald, dpkg.log, active-responses.log |
| Commands | 6min | `df -P`, `netstat -tulpn`, `last -n 20` |

### Docker Monitoring

Docker container monitoring is enabled on:

- **seedbox** (192.168.12.69) -- qBittorrent + gluetun containers
- **vault-server** (192.168.12.206) -- Vault container

The rootcheck module ignores Docker overlay paths (`/var/lib/containerd`, `/var/lib/docker/overlay2`) to suppress false positives from container filesystem changes.

### Deploying a New Agent

To add a Wazuh agent to a new VM:

1. Add the VM to `ansible/inventory/hosts.ini` with appropriate group membership
2. Include the `wazuh-agent` role in the VM's playbook
3. Run the playbook:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/<vm-name>.yml --tags wazuh-agent
```

The agent will auto-enroll with the manager via authd (port 1515, no password required).

### LXC Considerations

The `is_lxc` variable automatically detects LXC containers. On LXC, auditd is not supported, so the role skips audit-related configuration. This applies to:

- **minio-bootstrap** (LXC 301, 192.168.12.58)
- **minio-replica** (LXC 302, 192.168.12.59)
