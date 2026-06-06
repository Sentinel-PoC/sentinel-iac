# Integrations

## Matrix Bot (sentinel-matrix-bot)

The primary alert notification channel. The sentinel-matrix-bot runs on iac-control (192.168.12.210) on port 9095, receiving JSON-formatted alerts from Wazuh and posting them to Matrix rooms.

### Architecture

```
Wazuh Manager                    iac-control (:9095)           Matrix (Synapse)
+------------------+             +-------------------+         +----------------+
| Alert (level 10+)|-- HTTP ---->| sentinel-matrix   |-------->| #wazuh-alerts  |
| custom-matrix    |   POST      | -bot              |         | #gitlab-alerts |
| integration      |             | /wazuh endpoint   |         | #grafana-alerts|
+------------------+             +-------------------+         +----------------+
```

### Wazuh Configuration

From `ossec-server.conf.j2`:

```xml
<integration>
  <name>custom-matrix</name>
  <hook_url>http://192.168.12.210:9095/wazuh</hook_url>
  <level>10</level>
  <alert_format>json</alert_format>
</integration>
```

All alerts at level 10 or above are forwarded to the Matrix bot. The `custom-matrix` integration script at `/var/ossec/integrations/custom-matrix` is a Python 3 script that:

1. Reads the alert JSON file (passed as argument by Wazuh)
2. POSTs the full alert payload to the hook URL
3. Times out after 10 seconds

### Integration Script

Deployed via the `wazuh-server` Ansible role to `/var/ossec/integrations/custom-matrix`:

```python
#!/usr/bin/env python3
# Arguments:
#   $1 = alert file path (JSON)
#   $2 = API key (unused)
#   $3 = hook URL (e.g., http://192.168.12.210:9095/wazuh)

import json
import sys
from urllib.request import Request, urlopen
from urllib.error import URLError

TIMEOUT = 10

def main():
    if len(sys.argv) < 4:
        sys.exit("Usage: custom-matrix <alert_file> <api_key> <hook_url>")

    alert_file = sys.argv[1]
    hook_url = sys.argv[3]

    with open(alert_file, "r") as f:
        alert = json.load(f)

    payload = json.dumps(alert).encode()
    req = Request(hook_url, data=payload, method="POST")
    req.add_header("Content-Type", "application/json")

    with urlopen(req, timeout=TIMEOUT) as resp:
        if resp.status != 200:
            sys.exit(f"Webhook returned HTTP {resp.status}")

if __name__ == "__main__":
    main()
```

### Matrix Rooms

| Room | Purpose |
|------|---------|
| `#wazuh-alerts` | Wazuh SIEM alerts (level 10+) |
| `#gitlab-alerts` | GitLab CI/CD events |
| `#grafana-alerts` | Grafana alerting rules |

### Ansible Variables

```yaml
wazuh_matrix_integration_enabled: true          # Toggle on/off
wazuh_matrix_hook_url: "http://192.168.12.210:9095/wazuh"
wazuh_matrix_alert_level: "10"                  # Minimum alert level
```

## Discord Alerts

Discord notifications are triggered for level 10+ alerts via a `custom-discord.py` webhook integration. [VERIFY] The discord integration script location and configuration -- it is referenced in auto-memory but not present in the current IaC `local_rules.xml` or `wazuh-server` role files.

### Alert Triggers

Any Wazuh alert at level 10 or above triggers Discord notifications, including:

- Vault authentication failures (rule 100006, level 10)
- Terraform drift detected (rule 100431, level 10)
- iDRAC auto-recovery (rule 100604, level 10)
- HIGH CVE detected (rule 100701, level 11)
- CRITICAL CVE detected (rule 100700, level 14)
- Falco critical/shell/binary-write events (rules 100801-100809, levels 10-14)

## VirusTotal Integration

VirusTotal integration is enabled on the Wazuh manager for malware hash lookups. When FIM detects new or modified files, their hashes can be checked against the VirusTotal database.

[VERIFY] Specific VirusTotal configuration details and API key location.

## UniFi Syslog Forwarding

UniFi network devices forward syslog data to the Wazuh server on UDP port 514.

### Configuration

- **Source**: UniFi Controller (UCG-Fiber at 192.168.12.1)
- **Protocol**: UDP on port 514
- **Decoders**: 5 custom decoders for UniFi log format
- **Rules**: Referenced as range 100100-100199 and 100500-100513

[VERIFY] UniFi syslog rules are referenced in auto-memory (100100-100199 and 100500-100513) but are not present in the current IaC-managed `local_rules.xml`. They may be deployed directly on the server or in separate rule files.

### UniFi Monitoring Capabilities

The UniFi integration monitors:

- Device state changes (online/offline, adoption, firmware updates)
- Client connect/disconnect events
- Firewall rule hits
- DNS resolution events
- WiFi authentication events

The full UniFi monitoring stack also includes a separate collector (5-minute systemd timer), Prometheus exporter (:9120), and a dedicated Prometheus instance (:9099) on iac-control feeding Grafana.

## Rsyslog Forwarding

All hardened VMs forward syslog data to the Wazuh server as part of the SCA remediation:

```
Managed VMs                    Wazuh Server
+------------------+           +------------------+
| rsyslog          |-- UDP --->| :514             |
| forwarding       |  :514    | Syslog receiver  |
| (all CIS hosts)  |           |                  |
+------------------+           +------------------+
```

This was configured during the SCA hardening sprint to satisfy CIS benchmark requirements for centralized logging.

## Falco Runtime Security

Falco alerts from the OKD cluster are forwarded to Wazuh via a falco-wazuh-forwarder. Custom rules 100800-100810 process these events. See [Custom Rules](custom-rules.md#falco-runtime-security-rules-100800-100810) for full rule documentation.

### Alert Flow

```
OKD Cluster                    Wazuh Agent              Wazuh Manager
+------------------+           +-----------------+      +------------------+
| Falco DaemonSet  |-- JSON -->| iac-control     |----->| Rules            |
| Runtime events   |           | forwarder       |      | 100800-100810    |
+------------------+           +-----------------+      +------------------+
```

## Wazuh MCP Server

A Wazuh MCP (Model Context Protocol) server is available for querying Wazuh data from Claude Code sessions:

- **Transport**: HTTP
- **Purpose**: Security alerts, agent health, compliance data
- **When to use**: Security alert investigation, agent status checks, threat analysis

## Alert Level Summary

| Level | Channels | Examples |
|-------|----------|---------|
| 3 | Dashboard only | Clean drift checks, CVE resolved, info events |
| 5-7 | Dashboard only | Warnings, temp alerts, drift details |
| 8-9 | Dashboard only | Node unreachable, PSU failure |
| 10+ | Dashboard + Matrix + Discord | Auth failures, drift detected, CVEs, Falco critical |
| 14 | Dashboard + Matrix + Discord | CRITICAL CVE, binary dir write, privileged container |
