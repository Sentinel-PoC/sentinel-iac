# Deployment

## Infrastructure

Wazuh runs on **VM 111** on Proxmox node **208-pve2** (`192.168.12.56`).

| Property | Value |
|----------|-------|
| VM ID | 111 |
| Proxmox Node | 208-pve2 |
| IP Address | 192.168.12.100 |
| OS | Ubuntu 22.04 LTS |
| SSH User | `koiakoia` |
| SSH Key | `~/.ssh/id_wazuh` (NOT id_sentinel) |
| Wazuh Version | 4.14.1 |
| Services | Native systemd (not containerized) |

**SSH Access** (from iac-control):

```bash
ssh -i ~/.ssh/id_wazuh koiakoia@192.168.12.100
# Or via SSH config alias:
ssh wazuh
```

The SSH key for the Wazuh server is stored in Vault at `secret/wazuh/ssh-key`. This is the only VM that uses `id_wazuh` instead of `id_sentinel`.

## Ansible Role: wazuh-server

### Role Structure

```
ansible/roles/wazuh-server/
  defaults/main.yml          # Default variables
  tasks/main.yml             # Installation and configuration
  templates/
    ossec-server.conf.j2     # Manager ossec.conf template
  files/
    local_rules.xml          # Custom Sentinel rules
    custom-matrix            # Matrix alert integration script
  handlers/main.yml          # Service restart handlers
```

### Default Variables

From `defaults/main.yml`:

```yaml
wazuh_manager_version: "4.x"
wazuh_indexer_hosts: ["127.0.0.1"]
wazuh_dashboard_hosts: ["127.0.0.1"]
wazuh_server_config_path: "/var/ossec/etc/ossec.conf"

# Vulnerability detection (Wazuh 4.8+ native module)
wazuh_vuln_detection_enabled: true
wazuh_vuln_feed_interval: "60m"

# Matrix alert integration (via Sentinel Matrix Bot on iac-control)
wazuh_matrix_integration_enabled: true
wazuh_matrix_hook_url: "http://192.168.12.210:9095/wazuh"
wazuh_matrix_alert_level: "10"

# Indexer SSL certificate paths
wazuh_indexer_ssl_ca: "/etc/filebeat/certs/root-ca.pem"
wazuh_indexer_ssl_cert: "/etc/filebeat/certs/wazuh-server.pem"
wazuh_indexer_ssl_key: "/etc/filebeat/certs/wazuh-server-key.pem"
```

### Task Flow

The `tasks/main.yml` executes in this order:

1. **Install dependencies** -- `gnupg`, `apt-transport-https`, `curl`
2. **Add Wazuh GPG key** -- from `packages.wazuh.com`
3. **Add Wazuh repository** -- `deb https://packages.wazuh.com/4.x/apt/ stable main`
4. **Install packages** -- `wazuh-manager`, `wazuh-indexer`, `wazuh-dashboard`
5. **Deploy ossec.conf** -- Templates `ossec-server.conf.j2` to `/var/ossec/etc/ossec.conf` (notifies manager restart)
6. **Deploy local_rules.xml** -- Copies custom rules to `/var/ossec/etc/rules/local_rules.xml` (notifies manager restart)
7. **Deploy custom-matrix script** -- Copies integration script to `/var/ossec/integrations/custom-matrix`
8. **Start services** -- Ensures `wazuh-indexer`, `wazuh-manager`, `wazuh-dashboard` are started and enabled

### Handlers

Three restart handlers are defined, each triggered by their respective configuration changes:

```yaml
- name: Restart wazuh-manager
  ansible.builtin.service:
    name: wazuh-manager
    state: restarted

- name: Restart wazuh-indexer
  ansible.builtin.service:
    name: wazuh-indexer
    state: restarted

- name: Restart wazuh-dashboard
  ansible.builtin.service:
    name: wazuh-dashboard
    state: restarted
```

### Running the Playbook

```bash
# From iac-control, in ~/sentinel-repo/ansible/
# Full deployment (common + wazuh roles):
ansible-playbook -i inventory/hosts.ini playbooks/wazuh-server.yml

# Wazuh role only (skip CIS hardening):
ansible-playbook -i inventory/hosts.ini playbooks/wazuh-server.yml --tags wazuh

# Drift check (dry run):
ansible-playbook -i inventory/hosts.ini playbooks/wazuh-server.yml --check --diff
```

### Inventory Entry

From `ansible/inventory/hosts.ini`:

```ini
[wazuh]
wazuh-server ansible_host=192.168.12.100 ansible_user=koiakoia ansible_ssh_private_key_file=~/.ssh/id_wazuh firewall_allowed_ports='[22,443,1514,1515,55000]'
```

**Firewall ports**:

- **22** -- SSH
- **443** -- Wazuh Dashboard (HTTPS)
- **1514** -- Agent communication (TCP, encrypted)
- **1515** -- Agent enrollment (authd)
- **55000** -- Wazuh REST API

## Key ossec.conf Settings

The `ossec-server.conf.j2` template configures the manager with these important settings:

### Global

```xml
<global>
  <jsonout_output>yes</jsonout_output>
  <alerts_log>yes</alerts_log>
  <logall>no</logall>
  <logall_json>yes</logall_json>   <!-- Full JSON logging for compliance (AU-10) -->
  <agents_disconnection_time>15m</agents_disconnection_time>
</global>
```

### Remote (Agent Communication)

```xml
<remote>
  <connection>secure</connection>
  <port>1514</port>
  <protocol>tcp</protocol>
  <queue_size>131072</queue_size>
</remote>
```

### Vulnerability Detection

```xml
<vulnerability-detection>
  <enabled>yes</enabled>
  <index-status>yes</index-status>
  <feed-update-interval>60m</feed-update-interval>
</vulnerability-detection>
```

### Agent Enrollment (authd)

```xml
<auth>
  <disabled>no</disabled>
  <port>1515</port>
  <use_source_ip>no</use_source_ip>
  <purge>yes</purge>
  <use_password>no</use_password>
  <ciphers>HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH</ciphers>
</auth>
```

### Matrix Alert Integration

```xml
<integration>
  <name>custom-matrix</name>
  <hook_url>http://192.168.12.210:9095/wazuh</hook_url>
  <level>10</level>
  <alert_format>json</alert_format>
</integration>
```

This forwards all level 10+ alerts to the Sentinel Matrix Bot running on iac-control.

### Log Sources

The manager monitors these local log sources:

- `journald` -- systemd journal
- `/var/log/audit/audit.log` -- Linux audit log
- `/var/ossec/logs/active-responses.log` -- Active response actions
- `/var/log/dpkg.log` -- Package management
- `df -P` command output (every 6 minutes)
- `netstat -tulpn` listening ports (every 6 minutes)
- `last -n 20` login history (every 6 minutes)

## OIDC Integration (Dashboard)

The Wazuh Dashboard supports OIDC authentication via Keycloak. The OpenSearch configuration requires:

- PEM CA certificate **must** be inside the `/etc/wazuh-indexer/` directory tree
- After changing security configuration, run `securityadmin.sh` to apply changes

## Credentials

All credentials are stored in HashiCorp Vault:

| Secret Path | Contents |
|-------------|----------|
| `secret/wazuh/dashboard` | Dashboard admin password, API (wazuh-wui) password |
| `secret/wazuh/api` | API access credentials |
| `secret/wazuh/ssh-key` | SSH private key for Wazuh server |
| `secret/wazuh/indexer` | OpenSearch indexer credentials |

**Important**: The Wazuh API uses JWT authentication. You authenticate with wazuh-wui credentials to get a short-lived token -- there are no persistent API keys in Wazuh v4.x.

## Emergency Access

If SSH is unavailable, use `qm guest exec` on the Proxmox host (208-pve2):

```bash
# From 208-pve2 (192.168.12.56):
qm guest exec 111 -- bash -c "systemctl status wazuh-manager"
```

Note: `qm list` on Proxmox shows cluster-wide VMs. Verify you are on the correct node (208-pve2) before running `qm guest exec`.

## Validation Playbooks

Two test playbooks exist at the `ansible/` root (not in `playbooks/`):

```bash
# Test wazuh-server role (runs locally)
ansible-playbook ansible/test_wazuh_server.yml

# Test wazuh-agent role (runs locally)
ansible-playbook ansible/test_wazuh_agent.yml
```

These apply the roles against localhost for syntax/logic validation.
