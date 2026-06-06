# Sentinel Infrastructure Ansible Playbooks

**NIST CM-2 Compliance**: Configuration Management - Baseline Configuration

## Overview

This directory contains Ansible playbooks and roles for managing the Sentinel infrastructure baseline configuration. All system configurations are version-controlled and applied through Infrastructure as Code to ensure consistency, traceability, and compliance with NIST 800-53 controls.

## Structure

```
ansible/
├── inventory/
│   ├── hosts.ini              # Active inventory (INI format) — CI and all playbooks use this
│   ├── hosts.yml              # Secondary inventory (YAML format) — older host definitions
│   └── netbox_inventory.yml   # Dynamic inventory (NetBox integration)
├── playbooks/
│   ├── iac-control.yml        # iac-control node
│   ├── vault-server.yml       # Vault server
│   ├── gitlab-server.yml      # GitLab CI/CD
│   ├── config-server.yml      # DNS/DHCP HA
│   ├── minio-bootstrap.yml    # MinIO primary
│   ├── pangolin-proxy.yml     # Pangolin reverse proxy
│   ├── crowdsec.yml           # CrowdSec IPS
│   ├── seedbox-vm.yml         # Seedbox VM
│   └── wazuh-server.yml       # Wazuh SIEM
└── roles/
    └── iac-control/
        ├── defaults/main.yml  # Default variables
        ├── vars/main.yml      # Configuration variables
        ├── tasks/main.yml     # Task definitions
        ├── handlers/main.yml  # Service handlers
        └── templates/         # Jinja2 configuration templates
```

## Prerequisites

1. **Ansible** installed on control node (e.g., iac-control or admin workstation)
   ```bash
   apt install ansible
   ```

2. **SSH access** to target hosts
   - Use Vault-signed SSH certificates for authentication
   - Ensure SSH key is available at `~/.ssh/id_sentinel`

3. **Vault access** (for SSH certificate signing)
   ```bash
   export VAULT_ADDR="http://192.168.12.206:8200"
   export VAULT_TOKEN="<retrieve from Vault or Proton Pass>"

   # Sign SSH certificate (valid for 30 minutes)
   curl -s -H "X-Vault-Token: $VAULT_TOKEN" \
     -X POST "$VAULT_ADDR/v1/ssh/sign/admin" \
     -d "{\"public_key\": \"$(cat ~/.ssh/id_sentinel.pub)\", \"valid_principals\": \"ubuntu,root,koiakoia,core\"}" \
     | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['signed_key'].strip())" \
     | tr -d '\n' > ~/.ssh/id_sentinel-cert.pub
   ```

## Usage

### Apply Full Configuration

```bash
cd /path/to/sentinel-iac/ansible
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml
```

### Check Mode (Dry Run)

```bash
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --check
```

### Apply Specific Components (Using Tags)

```bash
# Only configure firewall
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --tags firewall

# Only configure HAProxy
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --tags haproxy

# Only configure Squid
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --tags squid

# Available tags:
#   - packages
#   - network
#   - sysctl
#   - netplan
#   - dnsmasq
#   - haproxy
#   - squid
#   - egress
#   - firewall
#   - iptables
```

### Verify Configuration

```bash
# Check if configuration matches baseline
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml --check --diff
```

## iac-control Role

The `iac-control` role configures the infrastructure control node with:

### Network Stack
- **IP Forwarding**: Enabled via sysctl for routing/gateway functionality
- **Netplan**: Configures dual IPs on ens19 (10.0.0.1 gateway, 10.0.0.10 DHCP server)
- **iptables**: Stateful firewall with egress filtering, NAT, and transparent proxy redirection

### Services
- **HAProxy**: Load balancer for OKD API (6443), Machine Config (22623), and Ingress (80/443)
- **Squid**: Transparent HTTP proxy with domain allowlisting for egress control
- **dnsmasq**: DHCP/DNS/PXE server for OKD cluster provisioning

### Key Variables

Located in `inventory/hosts.ini` (active inventory):
- `ansible_host`: Target IP address
- `primary_interface`: WAN/management interface (eth0)
- `okd_interface`: OKD cluster interface (ens19)
- `okd_network`: OKD cluster CIDR (10.0.0.0/24)
- `okd_gateway_ip`: Gateway IP on OKD interface (10.0.0.1)
- `okd_dhcp_ip`: DHCP server IP on OKD interface (10.0.0.10)

Located in `roles/iac-control/vars/main.yml`:
- `okd_master_nodes`: List of control plane nodes with MACs and IPs
- `squid_allowed_domains`: Egress allowlist domains
- `nfs_server`, `minio_server`, `gitlab_server`: Infrastructure service IPs

## NIST CM-2 Compliance

This infrastructure-as-code approach satisfies:

- **CM-2(1)**: Reviews and updates baseline configurations
- **CM-2(2)**: Maintains current baseline configuration in version control
- **CM-2(3)**: Retains previous baseline configurations for rollback
- **CM-2(7)**: Issues and updates configuration items under configuration management

### Change Control Process

1. **Proposed Changes**: Submit merge request with rationale
2. **Review**: Security and operations review of changes
3. **Testing**: Apply in check mode, verify in test environment if available
4. **Approval**: Documented approval before merge
5. **Apply**: Execute playbook to enforce new baseline
6. **Verify**: Confirm services operational and compliant

### Rollback Procedure

```bash
# Revert to previous Git commit
git revert HEAD
git push origin main

# Re-apply configuration
ansible-playbook -i inventory/hosts.ini playbooks/iac-control.yml
```

## Maintenance

### Adding New Firewall Rules

Edit `roles/iac-control/templates/rules.v4.j2` and add rules in the appropriate section:
- INPUT chain: For services on iac-control itself
- FORWARD chain: For traffic routed between networks
- NAT chain: For REDIRECT/MASQUERADE rules

### Updating Squid Allowlist

Edit `roles/iac-control/vars/main.yml` and add domains to the `squid_allowed_domains` list.

### Adding OKD Nodes

Edit `roles/iac-control/vars/main.yml`:
```yaml
okd_master_nodes:
  - name: master-4
    mac: "AA:BB:CC:DD:EE:FF"
    ip: "10.0.0.224"
```

HAProxy backend configuration will automatically include the new node.

## Troubleshooting

### Playbook Fails on Validation

If HAProxy or Squid config validation fails:
```bash
# Test HAProxy config manually
haproxy -c -f /etc/haproxy/haproxy.cfg

# Test Squid config manually
squid -k parse -f /etc/squid/squid.conf
```

### Service Won't Start

Check systemd status:
```bash
systemctl status haproxy
systemctl status squid
systemctl status dnsmasq
journalctl -u haproxy -n 50
```

### Firewall Rules Not Applied

Manually restore rules:
```bash
sudo iptables-restore < /etc/iptables/rules.v4
sudo netfilter-persistent save
```

## References

- [Ansible Documentation](https://docs.ansible.com/)
- [NIST SP 800-53 CM-2](https://nvd.nist.gov/800-53/Rev4/control/CM-2)
- [HAProxy Documentation](https://www.haproxy.org/doc/)
- [Squid Proxy Wiki](http://wiki.squid-cache.org/)
