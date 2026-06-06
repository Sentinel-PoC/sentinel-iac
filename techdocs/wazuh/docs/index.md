# Wazuh SIEM Operations

## Architecture Overview

Wazuh v4.14.1 is the central SIEM platform for Project Sentinel, providing real-time security monitoring across all managed infrastructure. It runs as a single all-in-one deployment (Manager + Indexer + Dashboard) on a dedicated VM.

```
+-----------------------------------------------------------+
|  VM 111 (208-pve2) - 192.168.12.100                      |
|                                                           |
|  +------------------+  +------------------+               |
|  | Wazuh Manager    |  | Wazuh Indexer    |               |
|  | :1514 (agents)   |  | :9200 (local)    |               |
|  | :1515 (authd)    |  | OpenSearch       |               |
|  | :55000 (API)     |  +------------------+               |
|  +------------------+                                     |
|  +------------------+                                     |
|  | Wazuh Dashboard  |                                     |
|  | :443 (HTTPS)     |                                     |
|  +------------------+                                     |
+-----------------------------------------------------------+
          |
          | TCP :1514 (encrypted)
          |
    +-----+-----+-----+-----+-----+-----+-----+-----+
    |     |     |     |     |     |     |     |     |
   000   002   004   005   006   007   008   009   010
  wazuh  208-  seed  iac-  pang  pve3  pve  vault  git
  self   pve2  box   ctrl  olin              srv   lab
```

### What Wazuh Provides

| Capability | Description | Configuration |
|------------|-------------|---------------|
| **SIEM** | Centralized log analysis, alert correlation, threat detection | ossec.conf ruleset, 8616 total rules loaded |
| **FIM** | File Integrity Monitoring on /etc, /usr/bin, /usr/sbin, /bin, /sbin, /boot | syscheck module, 12h scan interval |
| **SCA** | Security Configuration Assessment (CIS Benchmarks) | SCA module, 12h interval |
| **Vulnerability Detection** | Native CVE scanning (Wazuh 4.8+) with feed updates | vulnerability-detection module, 60m feed refresh |
| **Rootcheck** | Rootkit and anomaly detection | rootcheck module, 12h frequency |
| **Syscollector** | Hardware, OS, packages, ports, processes, users inventory | syscollector module, 1h interval |
| **Active Response** | Automated threat response (firewall-drop, host-deny, account disable) | Configured but not enabled for auto-trigger |
| **Drift Detection** | Ansible configuration drift detection and auto-remediation | Custom rules 100420-100428 |

### Key URLs and Access

| Resource | URL / Address |
|----------|---------------|
| Dashboard | `https://wazuh.208.haist.farm` (via Traefik on pangolin-proxy) |
| Dashboard (direct) | `https://192.168.12.100` (port 443) |
| API | `https://192.168.12.100:55000` |
| SSH | `ssh -i ~/.ssh/id_wazuh koiakoia@192.168.12.100` (from iac-control) |

**Dashboard credentials** are stored in Vault at `secret/wazuh/dashboard`. API credentials (wazuh-wui user) are at the same path. The Wazuh API uses JWT authentication with short-lived tokens -- there are no persistent API keys in v4.x.

### Services (Native, Not Containerized)

All three Wazuh components run as native systemd services:

- `wazuh-manager` -- Core analysis engine, rule processing, agent communication
- `wazuh-indexer` -- OpenSearch-based data store (bound to localhost:9200)
- `wazuh-dashboard` -- Web UI on port 443

### Custom Rules Summary

The deployment includes 80+ custom rules across these ranges:

| Range | Purpose | Alert Level |
|-------|---------|-------------|
| 100002-100006 | False-positive suppression + Vault auth | 3-10 |
| 100420-100435 | Ansible/Terraform drift detection | 3-10 |
| 100600-100610 | iDRAC hardware monitoring | 3-10 |
| 100700-100702 | Vulnerability detection escalation | 3-14 |
| 100800-100810 | Falco runtime security alerts | 3-14 |

See [Custom Rules](custom-rules.md) for full documentation of every rule.

### IaC Management

Wazuh server configuration is managed by the `wazuh-server` Ansible role in `sentinel-iac`. The role deploys:

- `ossec-server.conf.j2` template to `/var/ossec/etc/ossec.conf`
- `local_rules.xml` to `/var/ossec/etc/rules/local_rules.xml`
- `custom-matrix` integration script to `/var/ossec/integrations/custom-matrix`

The Wazuh server playbook applies both the `common` (CIS hardening) and `wazuh-server` roles:

```yaml
# ansible/playbooks/wazuh-server.yml
- name: Configure Wazuh SIEM server
  hosts: wazuh
  become: true
  roles:
    - role: common
      tags: [common]
    - role: wazuh-server
      tags: [wazuh, siem]
```

**Important**: Do not edit files directly on the Wazuh server. Changes are managed through the Ansible role and will be overwritten on the next playbook run.
