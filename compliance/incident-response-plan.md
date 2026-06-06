# Incident Response Plan
## Overwatch Platform — NIST SP 800-61 Rev 2

**Document Classification**: INTERNAL — FOR PORTFOLIO USE
**Created**: 2026-02-07
**System**: Overwatch Platform (OKD 4.19 on Proxmox)
**Owner**: Haists Consulting
**Controls Addressed**: IR-1, IR-8, IR-2, IR-3

---

## 1. Introduction

### 1.1 Purpose

This Incident Response Plan (IRP) establishes procedures for detecting, analyzing, containing, eradicating, and recovering from security incidents affecting the Overwatch Platform. It follows the NIST SP 800-61 Rev 2 framework adapted for a single-operator homelab environment.

### 1.2 Scope

This plan covers all Overwatch Platform infrastructure:

| Component | IP / Location | Role |
|-----------|---------------|------|
| iac-control | 192.168.12.210 | Sole gateway, IaC orchestration, monitoring |
| GitLab CE | 192.168.12.68 | CI/CD, source control |
| Vault | 192.168.12.206 | Secrets management, SSH CA |
| MinIO | 192.168.12.58 | Object storage, backup hub |
| OKD Cluster | 10.0.0.221-223 | Container orchestration (3 masters) |
| Pangolin | 192.168.12.168 | Zero-trust external access tunnel |
| Proxmox Hosts | .6 (pve), .56 (pve2), .57 (pve3) | Hypervisors |

### 1.3 Applicability

This plan applies to all security events that could compromise the confidentiality, integrity, or availability of the Overwatch Platform. While this is a homelab with no PII or regulated data, the platform demonstrates enterprise security patterns and treats incidents with appropriate rigor.

### 1.4 Plan Maintenance

This plan is reviewed:
- **Quarterly** (next: 2026-05-07)
- After any incident
- After significant infrastructure changes
- After IR test exercises

---

## 2. Roles and Responsibilities

### 2.1 Incident Response Team

| Role | Person | Responsibilities |
|------|--------|-----------------|
| **System Owner / Incident Commander** | Haists Consulting | All IR decisions, containment actions, recovery, communications |
| **AI Configuration Agent** | Claude Code (claude-automation) | Read-only assessment, log analysis, configuration review. Cannot make changes autonomously — all actions require human approval. |

### 2.2 Authority Levels

| Action | Authority |
|--------|-----------|
| Declare an incident | System Owner |
| Isolate a system (firewall block) | System Owner |
| Rotate credentials | System Owner |
| Restore from backup | System Owner |
| Accept residual risk | System Owner |
| Read logs, query APIs, assess state | AI Agent (read-only via claude-automation policy) |

### 2.3 Contact Information

| Contact | Method | When |
|---------|--------|------|
| System Owner | Local (homelab operator) | All incidents |
| ISP (T-Mobile/Frontier) | Provider support line | Network-level incidents |
| Cloudflare | Dashboard / support | DNS or tunnel issues |

---

## 3. Preparation

### 3.1 Monitoring Infrastructure

| Tool | Location | What It Monitors |
|------|----------|-----------------|
| **Grafana** | OKD cluster | Dashboards, alert rules |
| **Loki** | OKD cluster | Centralized log aggregation |
| **Promtail** | All hosts | Log shipping to Loki |
| **Alert Rules (3)** | Grafana | Firewall denies, HAProxy blocks, Squid denied requests |
| **Vault Audit Log** | /vault/logs/audit.log | All Vault API operations |
| **AIDE** | iac-control, GitLab | File integrity monitoring (daily scans) |
| **Gitleaks** | GitLab CI | Secrets detection in code |

### 3.2 Access and Tools

| Requirement | Location / Method |
|-------------|-------------------|
| SSH to iac-control | `ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210` |
| SSH to other VMs | JIT certificates via Vault SSH CA (30-min TTL) |
| Proxmox console | Web UI at pve (.6), pve2 (.56), pve3 (.57) — out-of-band access |
| Vault root access | Token in Proton Pass + `secret/vault/root-token` |
| Firewall rollback | `/opt/rollback/rollback-firewall.sh` on iac-control |
| Full service rollback | `/opt/rollback/rollback-all.sh` on iac-control |

### 3.3 Documentation

| Document | Location |
|----------|----------|
| DR Runbook | `sentinel-iac/infrastructure/DR-RUNBOOK.md` |
| Rollback Scripts | `/opt/rollback/` on iac-control |
| Network Topology | `sentinel-iac/compliance/sc7-5-implementation.md` |
| Account Inventory | `sentinel-iac/compliance/ac2-account-inventory.md` |
| Configuration Management Plan | `sentinel-iac/compliance/configuration-management-plan.md` |
| Component Lifecycle | `sentinel-iac/compliance/component-lifecycle.md` |
| Vault DR Config | `sentinel-iac/infrastructure/vault-dr/` |
| GitLab DR Config | `sentinel-iac/infrastructure/gitlab-dr/` |

### 3.4 Preparation Checklist

- [ ] Verify Grafana alerts are delivering notifications
- [ ] Confirm Vault audit logging is active
- [ ] Verify AIDE baselines are current
- [ ] Confirm backup jobs are running (Vault daily, GitLab weekly, MinIO→B2 hourly)
- [ ] Test rollback scripts quarterly
- [ ] Verify Proton Pass contains current emergency credentials
- [ ] Confirm Proxmox console access works (out-of-band)

---

## 4. Detection and Analysis

### 4.1 Detection Sources

| Source | Indicators | Check Method |
|--------|-----------|--------------|
| **Grafana Alerts** | Firewall deny spikes, HAProxy blocks, Squid denied | Grafana UI or alert notification |
| **Loki Logs** | Auth failures, unusual processes, error patterns | `logcli query` or Grafana Explore |
| **Vault Audit** | Unauthorized API calls, token misuse | `/vault/logs/audit.log` on Vault server |
| **AIDE Reports** | Unexpected file changes on iac-control/GitLab | Daily cron output, check `/var/lib/aide/` |
| **GitLab CI** | Gitleaks finding secrets, Trivy finding vulnerabilities | Pipeline status in GitLab |
| **System Logs** | Failed SSH attempts, sudo abuse, service crashes | `journalctl` on affected host |
| **OKD Events** | Pod crashes, unauthorized API calls, RBAC denials | `oc get events`, audit logs |

### 4.2 Indicators of Compromise (IOCs)

**High Confidence:**
- Vault audit log shows unauthorized token use
- AIDE reports changes to system binaries or SSH configs
- Gitleaks detects credentials in committed code
- Multiple SSH auth failures from unexpected IPs
- iptables deny count spike (>100/hour from single source)

**Medium Confidence:**
- New user accounts created outside of IaC
- Unexpected outbound connections (Squid proxy logs)
- OKD pods running unexpected images
- Unusual cron jobs or systemd services

**Low Confidence:**
- Service performance degradation
- Disk usage anomalies
- DNS query anomalies

### 4.3 Analysis Procedures

1. **Triage**: Determine if the event is a true incident or false positive
2. **Scope**: Identify which systems are affected
3. **Impact**: Assess confidentiality, integrity, availability impact
4. **Classify**: Assign severity (see Section 4.4)
5. **Document**: Record timeline, evidence, initial assessment

### 4.4 Severity Classification

| Severity | Definition | Examples | Response Time |
|----------|-----------|----------|---------------|
| **Critical** | Active compromise, data exfiltration, system destruction | Root access gained, ransomware, credential theft | Immediate |
| **High** | Imminent threat, vulnerability being exploited | Brute-force succeeding, known CVE exploit attempt | < 1 hour |
| **Medium** | Suspicious activity, potential threat | Port scans, unusual login patterns, AIDE alerts | < 4 hours |
| **Low** | Policy violation, minor anomaly | Failed login attempts, configuration drift | < 24 hours |

---

## 5. Containment, Eradication, and Recovery

### 5.1 Short-Term Containment

**Goal**: Stop the incident from spreading while preserving evidence.

| Action | Command | When |
|--------|---------|------|
| **Block source IP** | `sudo iptables -I INPUT -s <IP> -j DROP` | External attack identified |
| **Isolate VM network** | `sudo iptables -I FORWARD -d <VM_IP> -j DROP` | VM compromised |
| **Disable Pangolin tunnel** | Stop Newt service on 192.168.12.168 | External access abuse |
| **Lock Vault** | `vault operator seal` | Vault token compromise |
| **Disable GitLab user** | GitLab admin UI or API | Account compromise |
| **OKD namespace isolation** | `oc adm policy add-network-policy` | Container breakout |

### 5.2 Evidence Preservation

**Before eradication**, preserve evidence:

1. **Snapshot affected VM** via Proxmox:
   ```bash
   # From Proxmox host
   qm snapshot <VMID> incident-$(date +%Y%m%d-%H%M) --description "IR evidence"
   ```

2. **Copy logs** to safe location:
   ```bash
   # On affected host
   sudo tar czf /tmp/incident-logs-$(date +%Y%m%d).tar.gz \
     /var/log/auth.log /var/log/syslog /var/log/kern.log \
     /var/log/haproxy/ /var/log/squid/ 2>/dev/null
   # Copy to iac-control
   scp /tmp/incident-logs-*.tar.gz ubuntu@192.168.12.210:/tmp/
   ```

3. **Export Vault audit log**:
   ```bash
   # On Vault server
   docker cp vault:/vault/logs/audit.log /tmp/vault-audit-$(date +%Y%m%d).log
   ```

4. **Capture running state**:
   ```bash
   # Process list, network connections, open files
   ps auxf > /tmp/ps-$(date +%Y%m%d).txt
   ss -tulnp > /tmp/ss-$(date +%Y%m%d).txt
   lsof -i > /tmp/lsof-$(date +%Y%m%d).txt
   ```

### 5.3 Eradication

| Scenario | Eradication Steps |
|----------|-------------------|
| **Compromised credentials** | Rotate all affected secrets in Vault. Revoke old tokens/keys. Update GitLab CI variables. Force new SSH CA certificates. |
| **Unauthorized changes** | Restore from AIDE baseline. Re-run Ansible playbook. Verify with `aide --check`. |
| **Malware/suspicious process** | Kill process, remove files, restore from clean backup/snapshot. |
| **Vulnerable software** | Apply patch/update. If no patch available, implement compensating control or disable service. |
| **Container compromise** | Delete pod, rebuild image, scan with Trivy, redeploy via ArgoCD. |

### 5.4 Recovery

Recovery follows the DR Runbook (`infrastructure/DR-RUNBOOK.md`):

| System | Recovery Method | RTO |
|--------|----------------|-----|
| MinIO | Rebuild LXC, restore from B2 | 30 min |
| Vault | Restore docker-compose + data from MinIO/B2 | 45 min |
| GitLab | Restore from MinIO backup (`gitlab-backup restore`) | 1 hour |
| iac-control | Re-provision, pull secrets from Vault | 1 hour |
| OKD workloads | ArgoCD auto-sync from overwatch-gitops | 10 min |
| Full platform | Sequential rebuild per DR runbook | 3-4 hours |

**Recovery Verification Checklist:**
- [ ] All services reachable (ping, HTTP health checks)
- [ ] Vault unsealed and serving requests
- [ ] GitLab CI pipelines passing
- [ ] ArgoCD apps synced and healthy
- [ ] Grafana dashboards showing data
- [ ] Firewall rules correct (`iptables -L -n`)
- [ ] AIDE baseline updated post-recovery
- [ ] New credentials rotated if old ones were compromised

---

## 6. Post-Incident Activity

### 6.1 Lessons Learned

After every incident (within 48 hours):

1. **Timeline**: Document complete timeline from detection to resolution
2. **Root cause**: Identify how the incident occurred
3. **Detection gap**: How could we have detected it sooner?
4. **Prevention**: What changes prevent recurrence?
5. **Process improvement**: What worked well? What didn't?

### 6.2 Documentation

Create an incident record in `sentinel-iac/compliance/incidents/` with:
- Incident ID (YYYY-MM-DD-NNN)
- Severity, category, affected systems
- Timeline of events and actions taken
- Root cause analysis
- Remediation actions taken
- Follow-up actions and their status

### 6.3 Plan Updates

After each incident, review and update:
- This IRP (if procedures were inadequate)
- Rollback scripts (if new scenarios identified)
- Alert rules (if detection gaps found)
- DR Runbook (if recovery procedures need refinement)
- AIDE baselines (if file integrity scope needs expansion)

---

## 7. Incident Category Playbooks

### 7.1 Unauthorized Access Attempt

**Indicators**: Failed SSH attempts, iptables deny logs, HAProxy 403s
**Severity**: Medium (attempts) / Critical (success)

1. Check `journalctl -u sshd` and `/var/log/auth.log` for source IPs
2. Check iptables deny counter: `iptables -L INPUT -n -v | grep DROP`
3. If brute-force: Block source IP (`iptables -I INPUT -s <IP> -j DROP`)
4. If successful login from unknown source:
   - Immediately change affected passwords
   - Check `last` and `lastb` for session history
   - Check `history` for commands executed
   - Snapshot VM for evidence
   - Rotate all SSH keys and Vault tokens
5. Review AIDE report for any changes made during unauthorized session
6. Update firewall rules to permanently block source

### 7.2 Credential Compromise

**Indicators**: Vault audit log unusual operations, GitLab API calls from unknown sources
**Severity**: High / Critical

| Credential Type | Immediate Actions |
|-----------------|-------------------|
| **Vault root token** | `vault token revoke <token>`, generate new root token, update Proton Pass |
| **Vault automation token** | Revoke and recreate, update all automation that uses it |
| **SSH private key** | Remove from `authorized_keys`, rotate key pair, update Vault `secret/ssh/sentinel` |
| **GitLab PAT** | Revoke in GitLab Settings → Access Tokens, create new PAT, update CI vars and Vault |
| **Proxmox API token** | Revoke in Proxmox UI, create new token, update Vault + GitLab CI vars |
| **MinIO credentials** | Change password in MinIO, update Vault `secret/minio`, update rclone configs |
| **Cloudflare API token** | Revoke in Cloudflare Dashboard, create new scoped token, update Vault + CI vars |

After rotating credentials:
1. Verify all services can authenticate with new credentials
2. Run GitLab CI pipelines to confirm CI vars work
3. Test backup jobs (Vault, GitLab, MinIO→B2)
4. Update `secret/` paths in Vault with new values
5. Document rotation in incident record

### 7.3 Malware or Suspicious Process

**Indicators**: AIDE changes to binaries, unexpected processes, unusual CPU/memory usage
**Severity**: Critical

1. **Do not reboot** — preserve evidence first
2. Capture process info: `ps auxf`, `lsof -p <PID>`, `ls -la /proc/<PID>/exe`
3. Snapshot VM in Proxmox
4. Kill suspicious process: `kill -9 <PID>`
5. Check persistence mechanisms:
   - `crontab -l` and `/etc/cron.*`
   - `systemctl list-unit-files --state=enabled`
   - `/etc/rc.local`, `~/.bashrc`, `~/.profile`
6. Run AIDE check to identify all changed files
7. If scope is unclear, rebuild VM from clean state using DR runbook

### 7.4 Service Degradation / DoS

**Indicators**: Slow response times, connection timeouts, high resource usage
**Severity**: Medium / High

1. Check resource usage: `top`, `iostat`, `free -h`, `df -h`
2. Check network: `ss -s`, `conntrack -L | wc -l`
3. Check Grafana dashboards for anomalies
4. If external DoS:
   - Identify source IPs from HAProxy/Squid logs
   - Block at firewall: `iptables -I INPUT -s <IP> -j DROP`
   - If distributed, disable Pangolin tunnel temporarily
5. If internal resource exhaustion:
   - Identify resource-hungry process/pod
   - Apply resource limits or kill offending workload
   - Check for container resource limits in ArgoCD apps

### 7.5 Data Breach

**Indicators**: Unusual data transfers, unauthorized Vault reads, git clone from unknown source
**Severity**: Critical

**Note**: The Overwatch Platform contains no PII or regulated data. A breach primarily concerns credential exposure and infrastructure configuration leakage.

1. Identify what data was accessed (Vault audit log, GitLab access log)
2. Assume all accessed credentials are compromised — rotate immediately
3. Check for data exfiltration: outbound traffic logs in Squid
4. If git repos were cloned:
   - Rotate all secrets that may appear in git history
   - Review `gitleaks` scan results for exposed secrets
5. Document scope of exposure
6. No external notification required (no PII, single operator)

### 7.6 Infrastructure Failure

**Indicators**: VM unreachable, Proxmox host down, storage failure
**Severity**: Low (single workload) / High (host failure) / Critical (multi-host)

1. Identify scope: single VM, single host, or multi-host
2. Check Proxmox web UI for host status
3. For single VM failure:
   - Check VM status in Proxmox: `qm status <VMID>`
   - Attempt restart: `qm start <VMID>`
   - If corrupt, restore from snapshot or rebuild per DR runbook
4. For host failure:
   - Use out-of-band access (IPMI/iLO if available, or physical console)
   - Check hardware diagnostics
   - If host unrecoverable, VMs can be migrated to surviving hosts
5. For storage failure:
   - Check ZFS/LVM status on affected host
   - Restore data from MinIO → B2 backup chain
6. Follow DR Runbook for systematic recovery

---

## 8. Communication

### 8.1 Internal Communication

As a single-operator homelab, communication is simplified:

| Situation | Action |
|-----------|--------|
| Incident detected | Self-notification (Grafana alerts, email, webhook) |
| During response | Document actions in real-time in incident log |
| Post-incident | Write lessons-learned document |

### 8.2 External Communication

| Party | When to Contact |
|-------|----------------|
| ISP | If attack originates from or targets ISP infrastructure |
| Cloudflare | If DNS or tunnel is used as attack vector |
| Law Enforcement | If criminal activity is suspected (extremely unlikely for homelab) |

**Note**: No regulatory notification requirements apply (no PII, no regulated industry, no SLA obligations).

---

## 9. Evidence Handling

### 9.1 Evidence Types

| Evidence | Collection Method | Retention |
|----------|-------------------|-----------|
| VM snapshots | Proxmox `qm snapshot` | Until incident closed |
| System logs | tar archive of /var/log/ | 90 days |
| Vault audit logs | Copy from /vault/logs/audit.log | 90 days |
| Network captures | `tcpdump -w` on iac-control | 30 days |
| Process dumps | `ps`, `lsof`, `ss` output | Until incident closed |
| AIDE reports | `/var/lib/aide/aide.db*` | 90 days |
| Git history | GitLab repository | Permanent |

### 9.2 Chain of Custody

For a single-operator environment, chain of custody is simplified:
1. All evidence stored on iac-control in `/home/ubuntu/incidents/YYYY-MM-DD/`
2. Evidence files are read-only (`chmod 444`)
3. SHA256 hash recorded for each evidence file
4. Timeline documented in incident log
5. Backups of evidence pushed to MinIO `incident-evidence/` bucket

---

## 10. IR Training and Testing (IR-2, IR-3)

### 10.1 Training Approach

As a single-operator platform, formal classroom training is replaced by:
- **This document**: Serves as the primary training material
- **DR Runbook exercises**: Quarterly walkthroughs of recovery procedures
- **Rollback testing**: Quarterly execution of `/opt/rollback/` scripts
- **Tabletop exercises**: Annual review of incident scenarios (Section 7)
- **Lessons learned**: Post-incident reviews update procedures and knowledge

### 10.2 Testing Schedule

| Test | Frequency | Next Due | Description |
|------|-----------|----------|-------------|
| **Tabletop exercise** | Annual | 2027-02-07 | Walk through each scenario in Section 7 |
| **Rollback test** | Quarterly | 2026-05-07 | Execute rollback scripts, verify recovery |
| **Backup restore test** | Semi-annual | 2026-08-07 | Restore Vault and GitLab from backup |
| **Credential rotation drill** | Quarterly | 2026-05-07 | Practice emergency credential rotation |
| **Alert verification** | Monthly | 2026-03-07 | Verify Grafana alerts fire and deliver |

### 10.3 Test Documentation

Each test produces a record in `sentinel-iac/compliance/ir-tests/`:
- Test date and type
- Scenario tested
- Results (pass/fail, time to complete)
- Issues discovered
- Improvements made

---

## 11. References

| Document | Location |
|----------|----------|
| NIST SP 800-61 Rev 2 | Computer Security Incident Handling Guide |
| DR Runbook | `sentinel-iac/infrastructure/DR-RUNBOOK.md` |
| Rollback Scripts | `/opt/rollback/` on iac-control |
| Vault DR Config | `sentinel-iac/infrastructure/vault-dr/` |
| GitLab DR Config | `sentinel-iac/infrastructure/gitlab-dr/` |
| MinIO DR Config | `sentinel-iac/infrastructure/minio-dr/README.md` |
| SC-7(5) Network Docs | `sentinel-iac/compliance/sc7-5-implementation.md` |
| Account Inventory | `sentinel-iac/compliance/ac2-account-inventory.md` |
| Pipeline Controls | `sentinel-iac/compliance/pipeline-controls-mapping.md` |

---

## Document Control

| Version | Date | Author | Description |
|---------|------|--------|-------------|
| 1.0 | 2026-02-07 | Compliance Team | Initial IRP per NIST SP 800-61 Rev 2 |

---

*Generated 2026-02-07 | NIST SP 800-61 Rev 2 | Controls: IR-1, IR-8, IR-2, IR-3*
