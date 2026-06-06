# Runbook 03 — Wazuh Security Alert Response

**Scenario:** Wazuh has generated an alert requiring investigation and triage. Alerts arrive via Wazuh dashboard (https://wazuh.208.haist.farm) or log forwarding.

This runbook covers the triage decision tree. Not all alerts require action — the goal is to classify, scope, and either dismiss with rationale or escalate to a tracked SEC issue.

---

## 1. Access the alert

Wazuh dashboard: https://wazuh.208.haist.farm (Keycloak SSO)

Or query via CLI on iac-control:

```bash
# Wazuh API (if configured)
# Alerts are also forwarded to OpenSearch/Grafana
```

Key fields in every alert:
- **Rule ID** — what rule triggered
- **Rule level** — 1-15 (3+ is typically visible; 7+ warrants review; 12+ is critical)
- **Agent** — which host generated the alert
- **Description** — what Wazuh thinks happened
- **MITRE ATT&CK** — tactic/technique if mapped

---

## 2. Triage classification

Classify each alert before acting:

| Level | Classification | Default action |
|-------|---------------|----------------|
| 1-6 | Informational / low | Log review only; no ticket unless pattern |
| 7-11 | Medium — investigate | Read alert context; open SEC issue if genuine |
| 12+ | High / Critical | Immediate investigation; open SEC issue; consider isolation |

### 2a. Common false-positive patterns

These are known sources of noise in this environment:

| Rule / Description | Likely cause | Action |
|--------------------|-------------|--------|
| SSHD auth failures | Internet-facing port scans | Verify source IP; dismiss if external scanner |
| Rootkit check failed | CIS benchmark check on OKD nodes (CoreOS) | Verify CoreOS integrity; typically dismiss |
| File integrity change — `/etc/` | Ansible run or OS update applied | Cross-reference with Ansible run logs |
| Process abnormal — docker / containerd | Container workload | Verify against known running containers |
| Sudo command | Legitimate operator action | Cross-reference with session logs |

### 2b. Investigate an alert

```bash
# SSH to the affected agent host
ssh ubuntu@<host-ip>   # or core@<okd-node-ip>

# Check relevant logs based on alert description
# Auth failures → 
sudo grep "Failed password\|Invalid user" /var/log/auth.log | tail -20

# File integrity changes →
sudo aide --check 2>/dev/null | tail -20

# Process alerts →
ps aux | grep <suspicious-process>
sudo ss -tlnp | grep <suspicious-port>
```

---

## 3. Specific alert types

### 3a. Authentication failure storm

Symptom: repeated rule 5503 (SSH brute force) from a single IP.

```bash
# Check if IP is already blocked by CrowdSec
docker exec crowdsec cscli decisions list | grep <source-ip>

# Check fail2ban status
sudo fail2ban-client status sshd

# If not blocked and ongoing
docker exec crowdsec cscli decisions add --ip <source-ip> --duration 24h --reason "brute-force OPS-triage"
```

### 3b. AIDE file integrity alert

Symptom: rule 550x — file added/changed/deleted.

```bash
# Check what changed
sudo aide --check 2>/dev/null | grep "^[!>]"

# Common legitimate causes:
# - Ansible run (check ansible log)
# - Package update (check /var/log/dpkg.log or /var/log/apt/)
# - Agent config push

# If unexpected and sensitive file (e.g. /etc/passwd, /etc/sudoers)
# → open SEC issue immediately
```

### 3c. Suspicious process or network connection

```bash
# Identify process
ps aux | grep <pid-or-name>
sudo ls -la /proc/<pid>/exe

# Check network connections
sudo ss -tlnp | grep <port>
sudo netstat -anp | grep ESTABLISHED | grep <pid>

# Check if container-related
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep <port>
```

### 3d. Wazuh agent offline

Symptom: alert showing an agent disconnected.

```bash
# Check Wazuh agent service on the host
ssh ubuntu@<host-ip> "systemctl status wazuh-agent"

# Restart if stopped
ssh ubuntu@<host-ip> "sudo systemctl restart wazuh-agent"

# Verify reconnected in Wazuh dashboard or via API
```

---

## 4. Escalation decision

**Open a SEC issue if:**
- Alert level 12+ and not a known false positive
- Authentication failure from an internal IP
- File integrity change in a sensitive path with no corresponding change-management trail
- Unexpected outbound network connection
- Any alert on the Vault VM (192.168.12.206) or iac-control (192.168.12.210)

**Dismiss without issue if:**
- External brute-force from internet IPs (already handled by CrowdSec)
- Ansible-correlated file changes
- OKD node CoreOS false positives for rootkit checks
- Level < 7 with obvious benign explanation

**Always document the decision.** Even a "dismiss" should be a brief note in the Plane issue or session log.

---

## 5. Containment actions

If a host is confirmed compromised:

```bash
# Isolate network (use with extreme caution — cuts access)
# Do NOT do this unless certain of compromise and operator is reachable
sudo iptables -I INPUT -j DROP
sudo iptables -I OUTPUT -j DROP

# Preserve evidence first
sudo tar -czf /tmp/evidence-$(hostname)-$(date +%Y%m%d%H%M%S).tar.gz \
  /var/log /tmp /home /root

# Copy evidence off-host before isolation
scp ubuntu@<host-ip>:/tmp/evidence-*.tar.gz ~/
```

File an SEC issue with `urgent` priority and notify the operator before taking containment action.

---

## Related Runbooks
- [08-break-glass.md](08-break-glass.md) — emergency access if Wazuh host is isolated
- [11-supply-chain-security-scan.md](11-supply-chain-security-scan.md) — check container image integrity after alert
- [18-falco-event-capture.md](18-falco-event-capture.md) — Falco runtime events for OKD containers
