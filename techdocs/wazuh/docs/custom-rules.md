# Custom Rules

## Overview

The Sentinel Wazuh deployment includes 80+ custom rules deployed via `local_rules.xml` in the `wazuh-server` Ansible role. These rules are copied to `/var/ossec/etc/rules/local_rules.xml` on the Wazuh server. Combined with the default ruleset, there are 8616 total rules loaded.

Rules are organized into these functional groups:

| Range | Group | Purpose |
|-------|-------|---------|
| 100002-100006 | False-positive suppression + Vault | Noise reduction and Vault auth monitoring |
| 100430-100433 | Terraform drift detection | OpenTofu/Terraform state drift |
| 100600-100610 | iDRAC hardware | Proxmox hardware health monitoring |
| 100700-100702 | Vulnerability detection | CVE escalation and resolution tracking |
| 100800-100810 | Falco runtime security | Kubernetes container runtime alerts |

**Note**: The CLAUDE.md references additional rule ranges (100410-100417 for FIM expansion, 100420-100428 for Ansible drift, 100500-100513 for UniFi) that may be deployed directly on the server or in separate files not managed by the current `local_rules.xml`. The rules documented below are exactly what exists in the IaC-managed `local_rules.xml` and `wazuh/idrac_rules.xml` files. [VERIFY] Whether additional rules (FIM expansion, Ansible drift, UniFi) exist on the server outside of IaC management.

## False-Positive Suppressions (100002-100005)

These rules reduce noise from known-benign events by lowering their alert level to 3 (informational).

### Rule 100002 -- dpkg Half-Configured

```xml
<rule id="100002" level="3">
  <if_sid>2904</if_sid>
  <description>Dpkg: Package half-configured (routine apt operation, suppressed)</description>
  <group>dpkg,</group>
</rule>
```

Suppresses level-7 alerts for packages entering half-configured state during normal `apt` operations. Parent rule 2904 fires during routine package installation/upgrades.

### Rule 100003 -- dpkg New Package Installed

```xml
<rule id="100003" level="3">
  <if_sid>2902</if_sid>
  <description>Dpkg: New package installed (routine system maintenance, suppressed)</description>
  <group>dpkg,</group>
</rule>
```

Reduces alert level for new package installation events. Normal during Ansible-managed patching cycles.

### Rule 100004 -- Proxmox Rootcheck False Positive

```xml
<rule id="100004" level="3">
  <if_sid>510</if_sid>
  <field name="agent.name">^pve$|^pve3$|^208-pve2$</field>
  <description>Rootcheck: FALSE POSITIVE on Proxmox host - Generic signature matches
    /dev/null in clean passwd/chfn/chsh binaries. Verified via dpkg --verify.</description>
  <group>rootcheck,</group>
</rule>
```

Suppresses rootcheck alerts on the three Proxmox hypervisor agents. The rootcheck generic signatures match `/dev/null` references in stock Proxmox binaries (`passwd`, `chfn`, `chsh`), which were verified clean via `dpkg --verify`.

### Rule 100005 -- iac-control Port Changes

```xml
<rule id="100005" level="3">
  <if_sid>533</if_sid>
  <field name="agent.name">^iac-control$</field>
  <description>Network: Port change on iac-control - expected (socat/service management)</description>
  <group>network,</group>
</rule>
```

Suppresses port change alerts on iac-control. This VM runs HAProxy, Squid, dnsmasq, keepalived, and various socat tunnels -- port state changes are frequent and expected.

## Vault Authentication Monitoring (100006)

```xml
<rule id="100006" level="10">
  <decoded_as>json</decoded_as>
  <field name="type">response</field>
  <match>permission denied|invalid credentials|missing client token</match>
  <description>Vault: Authentication failure detected - potential unauthorized access attempt</description>
  <group>authentication_failed,vault,</group>
</rule>
```

Level 10 alert for Vault authentication failures. Triggers Matrix and Discord notifications. Matches JSON-formatted Vault audit log entries containing permission denied, invalid credentials, or missing client token errors.

## Terraform Drift Detection (100430-100433)

These rules process JSON events from the `tofu-drift-check.sh` script. NIST controls: CM-3 (Configuration Change Control), CM-6 (Configuration Settings).

### Rule 100430 -- No Drift

```xml
<rule id="100430" level="3">
  <decoded_as>json</decoded_as>
  <field name="event">TOFU_DRIFT_CHECK_COMPLETE</field>
  <description>Terraform drift check completed - no drift detected</description>
  <group>terraform,drift,</group>
</rule>
```

Informational confirmation that the OpenTofu drift check found no changes.

### Rule 100431 -- Drift Detected (Level 10)

```xml
<rule id="100431" level="10">
  <decoded_as>json</decoded_as>
  <field name="event">TOFU_DRIFT_DETECTED</field>
  <description>Terraform drift detected: $(changes) resource(s) changed</description>
  <group>terraform,drift,</group>
  <mitre>
    <id>T1578</id>
  </mitre>
</rule>
```

Level 10 alert with MITRE ATT&CK mapping to T1578 (Modify Cloud Compute Infrastructure). Triggers Matrix/Discord notifications when Terraform state diverges from expected.

### Rule 100432 -- Check Failed

```xml
<rule id="100432" level="7">
  <decoded_as>json</decoded_as>
  <field name="event">TOFU_DRIFT_CHECK_FAILED</field>
  <description>Terraform drift check failed: $(error)</description>
  <group>terraform,drift,error,</group>
</rule>
```

### Rule 100433 -- Drift Resource Details

```xml
<rule id="100433" level="5">
  <decoded_as>json</decoded_as>
  <field name="event">TOFU_DRIFT_RESOURCES</field>
  <description>Terraform drift details: $(resources)</description>
  <group>terraform,drift,</group>
</rule>
```

## iDRAC Hardware Monitoring (100600-100610)

These rules are defined in `wazuh/idrac_rules.xml` (separate from `local_rules.xml`). They process JSON events from the `idrac-health-check.sh` and `idrac-watchdog.sh` scripts. The event source is `/var/log/sentinel/idrac/health.json` on iac-control.

NIST controls: SI-4 (System Monitoring), PE-14 (Environmental Controls).

**Monitored iDRAC endpoints**:

| Host | Proxmox IP | iDRAC IP |
|------|-----------|----------|
| pve | 192.168.12.6 | 192.168.12.10 |
| 208-pve2 | 192.168.12.56 | 192.168.12.50 |
| pve3 | 192.168.12.57 | 192.168.12.202 |

### Rule 100600 -- Health Check Complete (Level 3)

```xml
<rule id="100600" level="3">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_CHECK_COMPLETE</field>
  <description>iDRAC health check completed</description>
  <group>idrac,</group>
</rule>
```

### Rule 100601 -- Health Warning (Level 5)

```xml
<rule id="100601" level="5">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_HEALTH_WARNING</field>
  <description>iDRAC node health WARNING: $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100602 -- Health Critical (Level 7)

```xml
<rule id="100602" level="7">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_HEALTH_CRITICAL</field>
  <description>iDRAC node health CRITICAL: $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100603 -- Node Unreachable via Proxmox API (Level 8)

```xml
<rule id="100603" level="8">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_NODE_UNREACHABLE</field>
  <description>Proxmox node unreachable via API: $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100604 -- Auto Recovery (Level 10, Triggers Notification)

```xml
<rule id="100604" level="10">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_AUTO_RECOVERY</field>
  <description>Automatic iDRAC power cycle triggered for $(node)</description>
  <group>idrac,</group>
</rule>
```

Level 10 triggers Matrix and Discord alerts. This fires when the watchdog automatically power-cycles a node after 3 consecutive health check failures.

### Rule 100605 -- PSU Failure (Level 8)

```xml
<rule id="100605" level="8">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_PSU_DEGRADED|IDRAC_PSU_FAILURE</field>
  <description>PSU failure or redundancy lost on $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100606 -- Temperature Critical (Level 9)

```xml
<rule id="100606" level="9">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_TEMP_CRITICAL</field>
  <description>Temperature CRITICAL on $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100607 -- Temperature Warning (Level 7)

```xml
<rule id="100607" level="7">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_TEMP_WARNING</field>
  <description>Temperature warning on $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100608 -- Node Recovered (Level 5)

```xml
<rule id="100608" level="5">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_NODE_RECOVERED</field>
  <description>Node $(node) recovered after power cycle</description>
  <group>idrac,</group>
</rule>
```

### Rule 100609 -- iDRAC Management Unreachable (Level 3)

```xml
<rule id="100609" level="3">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_UNREACHABLE</field>
  <description>iDRAC management interface unreachable: $(node)</description>
  <group>idrac,</group>
</rule>
```

### Rule 100610 -- Power Cycle Sent (Level 6)

```xml
<rule id="100610" level="6">
  <decoded_as>json</decoded_as>
  <field name="event">IDRAC_POWER_CYCLE_SENT</field>
  <description>Power cycle command sent to $(node) via iDRAC</description>
  <group>idrac,</group>
</rule>
```

## Vulnerability Detection Rules (100700-100702)

These rules escalate the built-in Wazuh vulnerability detection alerts to ensure critical and high CVEs trigger Matrix/Discord notifications.

### Rule 100700 -- CRITICAL CVE (Level 14)

```xml
<rule id="100700" level="14">
  <if_sid>23506</if_sid>
  <description>SENTINEL: CRITICAL CVE detected - $(vulnerability.cve) on $(agent.name)</description>
  <group>vulnerability-detection,critical_cve,</group>
  <mitre>
    <id>T1190</id>
  </mitre>
</rule>
```

Escalates critical CVEs from the built-in level 13 (rule 23506) to level 14 to ensure they always trigger Discord notifications. Mapped to MITRE T1190 (Exploit Public-Facing Application).

### Rule 100701 -- HIGH CVE (Level 11)

```xml
<rule id="100701" level="11">
  <if_sid>23505</if_sid>
  <description>SENTINEL: HIGH CVE detected - $(vulnerability.cve) on $(agent.name)</description>
  <group>vulnerability-detection,high_cve,</group>
  <mitre>
    <id>T1190</id>
  </mitre>
</rule>
```

Escalates high CVEs from built-in level 10 (rule 23505) to level 11.

### Rule 100702 -- CVE Resolved (Level 3)

```xml
<rule id="100702" level="3">
  <if_sid>23501</if_sid>
  <match>resolved</match>
  <description>SENTINEL: CVE resolved on $(agent.name)</description>
  <group>vulnerability-detection,cve_resolved,</group>
</rule>
```

Tracks vulnerability resolution events at informational level.

## Falco Runtime Security Rules (100800-100810)

These rules process Falco alerts forwarded from OKD via a falco-wazuh-forwarder. NIST controls: SI-4 (System Monitoring), AU-2 (Audit Events).

### Rule 100800 -- Base Falco Alert (Level 3)

```xml
<rule id="100800" level="3">
  <decoded_as>json</decoded_as>
  <field name="source">falco</field>
  <description>Falco: $(rule) in $(output_fields.k8s.ns.name)/$(output_fields.k8s.pod.name)</description>
  <group>falco,</group>
</rule>
```

### Rule 100801 -- Critical Priority (Level 10)

```xml
<rule id="100801" level="10">
  <if_sid>100800</if_sid>
  <field name="priority">Emergency|Alert|Critical</field>
  <description>Falco CRITICAL: $(rule) in $(output_fields.k8s.ns.name)/$(output_fields.k8s.pod.name)</description>
  <group>falco,critical,</group>
  <mitre><id>T1059</id></mitre>
</rule>
```

MITRE T1059 (Command and Scripting Interpreter).

### Rule 100802 -- Error Priority (Level 7)

```xml
<rule id="100802" level="7">
  <if_sid>100800</if_sid>
  <field name="priority">Error</field>
  <description>Falco ERROR: $(rule) in $(output_fields.k8s.ns.name)/$(output_fields.k8s.pod.name)</description>
  <group>falco,error,</group>
</rule>
```

### Rule 100803 -- Warning Priority (Level 5)

```xml
<rule id="100803" level="5">
  <if_sid>100800</if_sid>
  <field name="priority">Warning</field>
  <description>Falco WARNING: $(rule) in $(output_fields.k8s.ns.name)/$(output_fields.k8s.pod.name)</description>
  <group>falco,warning,</group>
</rule>
```

### Rule 100804 -- Terminal Shell in Container (Level 12)

```xml
<rule id="100804" level="12">
  <if_sid>100800</if_sid>
  <field name="rule">Terminal shell in container</field>
  <description>Falco: Interactive shell opened in container $(output_fields.k8s.pod.name)</description>
  <group>falco,shell,</group>
  <mitre><id>T1059.004</id></mitre>
</rule>
```

MITRE T1059.004 (Command and Scripting Interpreter: Unix Shell).

### Rule 100805 -- Sensitive File Read (Level 12)

```xml
<rule id="100805" level="12">
  <if_sid>100800</if_sid>
  <field name="rule">Read sensitive file</field>
  <description>Falco: Sensitive file access in container $(output_fields.k8s.pod.name)</description>
  <group>falco,credential_access,</group>
  <mitre><id>T1003</id></mitre>
</rule>
```

MITRE T1003 (OS Credential Dumping).

### Rule 100806 -- Binary Directory Write (Level 14)

```xml
<rule id="100806" level="14">
  <if_sid>100800</if_sid>
  <field name="rule">Write below binary dir</field>
  <description>Falco: Binary directory modification in $(output_fields.k8s.pod.name) - potential malware</description>
  <group>falco,persistence,</group>
  <mitre><id>T1554</id></mitre>
</rule>
```

Level 14 -- highest alert level. MITRE T1554 (Compromise Client Software Binary).

### Rule 100807 -- Privileged Container (Level 14)

```xml
<rule id="100807" level="14">
  <if_sid>100800</if_sid>
  <field name="rule">Launch Privileged Container</field>
  <description>Falco: Privileged container launched in $(output_fields.k8s.ns.name)</description>
  <group>falco,privilege_escalation,</group>
  <mitre><id>T1610</id></mitre>
</rule>
```

MITRE T1610 (Deploy Container).

### Rule 100808 -- K8s API Access (Level 10)

```xml
<rule id="100808" level="10">
  <if_sid>100800</if_sid>
  <field name="rule">Contact K8S API Server From Container</field>
  <description>Falco: K8s API access from container $(output_fields.k8s.pod.name)</description>
  <group>falco,discovery,</group>
  <mitre><id>T1613</id></mitre>
</rule>
```

MITRE T1613 (Container and Resource Discovery).

### Rule 100809 -- Reverse Shell Attempt (Level 12)

```xml
<rule id="100809" level="12">
  <if_sid>100800</if_sid>
  <field name="rule">Netcat Remote Code Execution</field>
  <description>Falco: Reverse shell attempt in $(output_fields.k8s.pod.name)</description>
  <group>falco,command_and_control,</group>
  <mitre><id>T1059</id></mitre>
</rule>
```

### Rule 100810 -- Informational Falco Events (Level 3)

```xml
<rule id="100810" level="3">
  <if_sid>100800</if_sid>
  <field name="priority">Notice|Informational|Debug</field>
  <description>Falco INFO: $(rule)</description>
  <group>falco,informational,</group>
</rule>
```

## Alert Level Reference

| Level | Meaning | Notification Channels |
|-------|---------|----------------------|
| 0-2 | Suppressed / No alert | None |
| 3 | Informational | Dashboard only |
| 5-7 | Medium severity | Dashboard only |
| 8-9 | High severity | Dashboard only |
| 10+ | Critical / Active threat | Dashboard + Matrix + Discord |
| 14 | Maximum custom level | Dashboard + Matrix + Discord (immediate) |

## Rule Writing Gotchas

Lessons learned from developing custom Wazuh rules:

- `<field name="status">` crashes the Wazuh manager -- avoid using status as a field name
- `<decoded_as>syslog</decoded_as>` does not exist as a valid decoder reference
- OSSEC regex does not support `\[` bracket escaping -- use character classes or different patterns
- Always test rules with `wazuh-logtest` before deploying to production
