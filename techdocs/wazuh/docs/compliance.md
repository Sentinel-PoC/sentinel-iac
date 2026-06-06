# Compliance

## NIST 800-53 Control Mapping

Wazuh is a key component in satisfying NIST 800-53 Moderate controls for Project Sentinel. This page maps Wazuh capabilities to specific NIST controls.

## Control Coverage

### AU-2: Event Logging

**Status**: Implemented

Wazuh collects audit events from all 9 active agents. Each agent monitors:

- **journald** -- systemd service events, authentication, kernel messages
- **audit.log** -- Linux audit framework events (syscalls, file access, user actions)
- **dpkg.log** -- Package management activity
- **active-responses.log** -- Automated response actions
- **Command outputs** -- `df -P`, `netstat -tulpn`, `last -n 20` (every 6 minutes)

The manager configuration enables full JSON logging:

```xml
<logall_json>yes</logall_json>
```

**Evidence**: Alert logs at `/var/ossec/logs/alerts/alerts.json`, archived JSON at `/var/ossec/logs/archives/archives.json`.

**Compliance check note**: The NIST compliance check (AU-10) validates `logall_json` SSH configuration. Expired SSH certificates cause false failures on this check -- ensure the `ssh-cert-renew.timer` fires before the compliance check timer (6:00 UTC).

### AU-6: Audit Review, Analysis, and Reporting

**Status**: Implemented

Wazuh provides automated audit analysis through:

- **Rule-based correlation**: 8616 loaded rules analyze events in real-time
- **Dashboard visualization**: `wazuh.208.haist.farm` provides searchable, filterable audit data
- **Automated alerting**: Level 10+ events trigger immediate notification via Matrix and Discord
- **Custom rules**: 80+ Sentinel-specific rules for targeted analysis (drift, CVEs, hardware health, runtime security)

### AU-7: Audit Reduction and Report Generation

**Status**: Implemented

The Wazuh Indexer (OpenSearch) provides:

- Full-text search across all collected events
- Time-range filtering and aggregation
- Dashboard-based report generation
- API access for programmatic queries

### CA-7: Continuous Monitoring

**Status**: Implemented

Wazuh provides continuous monitoring across multiple dimensions:

| Dimension | Mechanism | Interval |
|-----------|-----------|----------|
| Security events | Real-time log analysis | Continuous |
| File integrity | Syscheck FIM | 12h full scan, real-time for critical paths |
| Configuration baseline | SCA (CIS Benchmarks) | 12h |
| Vulnerability posture | Native CVE scanning | 60m feed refresh |
| System inventory | Syscollector | 1h |
| Rootkit detection | Rootcheck | 12h |
| Configuration drift | Ansible --check --diff | Daily 8:00 UTC |

### SI-4: Information System Monitoring

**Status**: Implemented

Wazuh is the primary system monitoring tool, providing:

- **Intrusion detection**: Real-time log analysis with 8616 rules
- **File integrity monitoring**: Watches /etc, /usr/bin, /usr/sbin, /bin, /sbin, /boot
- **Active response**: firewall-drop, host-deny, disable-account commands configured
- **Network monitoring**: Port scan detection, listening port changes
- **Hardware monitoring**: iDRAC health rules (100600-100610) for physical infrastructure
- **Container runtime**: Falco rules (100800-100810) for OKD workloads

### CM-3: Configuration Change Control

**Status**: Partially Implemented

Drift detection satisfies configuration change control:

- Daily Ansible `--check --diff` at 8:00 UTC detects unauthorized changes
- Auto-remediation at 8:30 UTC restores baseline (common role)
- Terraform drift detection via `tofu plan` (rules 100430-100433)
- Wazuh rules alert on drift events for audit trail
- Maintenance mode prevents automation during planned changes

**NIST compliance check note**: CM-3(2) currently reports ArgoCD sync at 77%, which is one of the 6 remaining WARN items.

### RA-5: Vulnerability Monitoring and Scanning

**Status**: Implemented

The native vulnerability detection module (4.8+) provides:

- Continuous CVE scanning across all agents
- 60-minute feed update interval
- Custom rules escalating CRITICAL (100700) and HIGH (100701) CVEs
- CVE resolution tracking (rule 100702)
- Cross-reference with NVD MCP and Trivy MCP for deeper analysis

### SI-2: Flaw Remediation

**Status**: Implemented

Wazuh tracks vulnerability lifecycle:

- Detection: Rules 100700-100701 identify new CVEs
- Notification: Level 10+ alerts sent to Matrix and Discord
- Tracking: CVE indexed in OpenSearch for trending
- Resolution: Rule 100702 logs when CVEs are resolved

### SI-7: Software, Firmware, and Information Integrity

**Status**: Implemented

Multiple integrity verification mechanisms:

- **FIM (Syscheck)**: Monitors critical directories for unauthorized modifications
- **Rootcheck**: Detects rootkits, trojans, and system anomalies
- **SCA**: Validates CIS benchmark configuration compliance
- **Drift detection**: Ansible-based configuration verification

## Evidence Collection

### Daily Compliance Check

The `nist-compliance-check.sh` script runs 115 automated checks across 16 control families. It runs daily at 6:00 UTC on iac-control. Wazuh-specific checks include:

- Agent connectivity verification
- FIM status confirmation
- Log collection validation
- Vulnerability detection module status

### Evidence Pipeline

The evidence pipeline runs daily at 7:00 UTC:

1. Collects compliance check results
2. Auto-commits data to the `compliance-vault` GitLab repo
3. Generates daily reports in `compliance-vault/reports/daily/`
4. Tracks trends in `compliance-vault/reports/compliance-trend-summary.md`

### Wazuh as Evidence Source

Wazuh provides evidence artifacts for compliance audits:

| Artifact | Location | NIST Controls |
|----------|----------|---------------|
| Alert logs | `/var/ossec/logs/alerts/alerts.json` | AU-2, AU-6, SI-4 |
| Archive logs | `/var/ossec/logs/archives/archives.json` | AU-2, AU-7 |
| SCA results | Wazuh Dashboard / API | SI-2, CM-6 |
| FIM events | Wazuh Dashboard / API | SI-7 |
| Vulnerability data | Wazuh Dashboard / API | RA-5, SI-2 |
| Agent inventory | Wazuh Dashboard / API | CM-8, PM-5 |

## Current Compliance State

From the latest NIST gap analysis:

- **Overall**: 109 PASS / 0 FAIL / 6 WARN out of 115 automated checks
- **Wazuh-related WARNs**: AU-10 (`logall_json` SSH check -- can false-fail with expired SSH certs)
- **Total coverage**: 111 unique controls of ~226 applicable (49% automated verification)
- **SSP status**: 253 controls (100 implemented, 89 partial, 34 N/A, 30 planned)

### 6 Remaining WARN Items

| Control | Issue | Wazuh Relevance |
|---------|-------|-----------------|
| AT-2 | No training records | Not Wazuh-related |
| AT-3 | No training records | Not Wazuh-related |
| AU-10 | `logall_json` SSH check | Wazuh manager config, SSH cert dependency |
| CM-3(2) | ArgoCD sync 77% | Not Wazuh-related |
| IA-5(13) | Token TTL | Not Wazuh-related |
| PM-2 | No senior official | Not Wazuh-related |

## Compliance Source of Truth

The single source of truth for compliance status is `sentinel-iac-work/docs/nist-gap-analysis.md` (v2.2). All other documents reference it. For current pass/fail counts, check the latest daily report in `compliance-vault/reports/daily/` or run the compliance check manually:

```bash
# On iac-control:
~/sentinel-repo/scripts/nist-compliance-check.sh
```
