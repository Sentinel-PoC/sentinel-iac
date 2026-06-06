# NIST 800-53 Compliance Gap Analysis

**Date**: 2026-03-11 (updated — COMP-5 stale metrics fix)
**Author**: J. Haist / Claude Code
**Status**: Authoritative source for compliance posture

This document is the single source of truth for Project Sentinel's NIST 800-53 compliance posture. All other documents (SSP, MEMORY.md, task-queue.md, briefing.md) should reference this document rather than stating independent scores.

---

## 1. Methodology

### 1.1 Automated Compliance Check

The script `scripts/nist-compliance-check.sh` runs **125 automated checks** across **17 NIST 800-53 control families**. Each check queries live infrastructure (Wazuh API, SSH to managed hosts, Vault API, OKD API, HTTP health endpoints) and produces a PASS/FAIL/WARN result. Each check maps to exactly one NIST 800-53 control, so 125 checks = 121 unique controls verified (some controls have multiple sub-checks).

The script runs daily at 6:00 AM UTC via systemd timer on iac-control. A separate 11-check API-only subset runs as an OKD CronJob in sentinel-ops namespace (no SSH dependencies).

### 1.2 What the Script Checks

| Family | Controls Checked | Check Count |
|--------|-----------------|-------------|
| AC (Access Control) | AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-6(1), AC-6(2), AC-7, AC-8, AC-10, AC-11, AC-12, AC-14, AC-17, AC-17(1) | 16 |
| AT (Awareness & Training) | AT-1, **AT-2**, **AT-3** | 3 |
| AU (Audit & Accountability) | AU-2, **AU-2(3)**, AU-3, AU-4, ***AU-5***, AU-6, AU-6(4), ***AU-7***, AU-8, AU-9, **AU-10**, AU-11, AU-12 | 13 |
| CA (Security Assessment) | CA-2, ***CA-5***, CA-7, CA-7(1), ***CA-9*** | 5 |
| CM (Configuration Management) | CM-2, CM-3, CM-3(2), **CM-3(3)**, CM-5, CM-6, CM-7, CM-7(2), CM-8 | 9 |
| CP (Contingency Planning) | CP-1, CP-2, CP-3, CP-4, **CP-6**, CP-7, CP-9, CP-9(1), CP-9(2), CP-10 | 10 |
| IA (Identification & Auth) | IA-2, IA-2(1), IA-2(12), IA-4, IA-5, IA-5(1), IA-5(2), IA-5(3), IA-5(13), IA-8 | 10 |
| IR (Incident Response) | IR-1, IR-4, IR-5, IR-6 | 4 |
| MA (Maintenance) | MA-2, ***MA-4*** | 2 |
| MP (Media Protection) | MP-5 | 1 |
| PE (Physical & Environmental) | PE-6, PE-14 | 2 |
| PL (Planning) | PL-1, PL-2, ***PL-4*** | 3 |
| **PM (Program Management)** | **PM-1**, **PM-2**, **PM-6** | **3** |
| RA (Risk Assessment) | ***RA-2***, RA-3, RA-5, **RA-5(3)** | 4 |
| SA (System & Services) | **SA-4**, ***SA-5***, **SA-8**, ***SA-10***, **SA-11**, SA-22 | 6 |
| SC (System & Communications) | SC-1, SC-2, SC-5, SC-7, SC-7(5), SC-7(7), SC-8, SC-8(1), SC-10, SC-12, SC-12(1), SC-13, ***SC-17***, **SC-20**, SC-23, SC-28, SC-39 | 17 |
| SI (System & Info Integrity) | SI-2, SI-3, SI-4, **SI-4(2)**, SI-4(4), SI-4(7), SI-5, SI-6, SI-7, SI-7(1), SI-7(2), SI-7(6), SI-16 | 13 |
| **Total** | **17 families** | **125** |

**Bold** entries are new checks added in Session 67 (15 checks across 2 new families: PM, expanded SA/AT/AU/CP/SC/SI).
***Bold italic*** entries are Phase 2 checks added in Issue #26 (10 checks: AU-5, AU-7, CA-5, CA-9, MA-4, PL-4, RA-2, SA-5, SA-10, SC-17).

### 1.3 What the Script Does NOT Check

The sentinel-moderate profile has approximately 226 applicable controls (after excluding N/A). The automated script checks 121 unique controls, leaving **105 controls with no automated verification** (53.5% coverage, 46.5% gap).

Notable unchecked areas:
- Remaining AC family (AC-19 mobile, AC-20 external systems)
- Most of AT (Awareness & Training) family beyond AT-1/2/3
- Remaining SA controls beyond SA-4/8/11/22
- Most of PM family beyond PM-1/2/6
- SC-4 (info in shared resources)
- Most of PS (Personnel Security) family
- Most of PE (Physical & Environmental) family beyond PE-6/14

### 1.4 Scoring Limitations

The automated check script tests *necessary conditions* for compliance, not *sufficient conditions*. A PASS on `AC-2` (Keycloak OIDC endpoint responding) confirms the IdP is running but does not prove all AC-2 sub-requirements (quarterly reviews, account disabling procedures, etc.) are met.

---

## 2. Current Automated Results

**Last run**: 2026-03-08 (125 checks — Phase 2 expansion)

### 2.1 Summary

| Status | Count | Description |
|--------|-------|-------------|
| PASS | 98 | Checks passing |
| FAIL | 18 | See 2.3 below |
| WARN | 9 | See 2.4 below |
| **Total** | **125** | **78% pass rate** |

**Coverage**: 121 unique controls checked out of ~226 applicable (53.5%). Phase 2 added AU-5, AU-7, CA-5, CA-9, MA-4, PL-4, RA-2, SA-5, SA-10, SC-17.

**Regression note**: Score dropped from 110/115 (96%) on 2026-03-07 to 98/125 (78%) on 2026-03-08. Primary causes: (1) SSH cert expiry cascading SSH-based check failures across multiple hosts, (2) 10 new Phase 2 checks added (some legitimately failing), (3) post-PG-crash service outages (Vault containers, CrowdSec, Cloudflare tunnel). Expected recovery to ~110+/125 once SSH certs are renewed and services restored.

**Note**: The OKD CronJob in sentinel-ops runs a separate 11-check API-only subset (no SSH). That subset may show different results due to MinIO connectivity from OKD pods.

### 2.2 Breakdown by Family (from 2026-03-08 run)

| Family | Checks | PASS | FAIL | WARN | Notes |
|--------|--------|------|------|------|-------|
| AC (16) | 16 | 13 | 3 | 0 | AC-6 (0 Vault policies), AC-6(2) (root SSH 1/5), AC-17 (SSH CA unreadable) |
| AT (3) | 3 | 2 | 0 | 1 | AT-2 WARN (no training records) |
| AU (13) | 13 | 10 | 1 | 2 | AU-2 FAIL (auditd 1/6), AU-5 FAIL (0/5 failure response), AU-6 WARN, AU-10 WARN |
| CA (5) | 5 | 3 | 1 | 0 | CA-9 FAIL (Vault k8s auth not detected) |
| CM (9) | 9 | 9 | 0 | 0 | All passing (ArgoCD 24/24 synced) |
| CP (10) | 10 | 9 | 1 | 0 | CP-9 FAIL (backup timers: vault-backup + gitlab-backup INACTIVE) |
| IA (10) | 10 | 8 | 1 | 1 | IA-2(12) FAIL (0 non-token auth), IA-5(13) WARN |
| IR (4) | 4 | 1 | 0 | 3 | IR-4 WARN (no AR blocks), IR-5 WARN (0 alerts), IR-6 WARN (no Discord webhook) |
| MA (2) | 2 | 1 | 1 | 0 | MA-4 FAIL (0/5 SSH-only maintenance) |
| MP (1) | 1 | 1 | 0 | 0 | Vault encryption active |
| PE (2) | 2 | 2 | 0 | 0 | iDRAC health + physical monitoring |
| PL (3) | 3 | 3 | 0 | 0 | Security plan + SSP + rules of behavior current |
| PM (3) | 3 | 2 | 0 | 1 | PM-2 WARN (no senior official in SSP) |
| RA (4) | 4 | 4 | 0 | 0 | Vulnerability + secret scanning + DefectDojo + risk categorization |
| SA (6) | 6 | 5 | 0 | 1 | SA-8 WARN (no secure dev lifecycle in CI) |
| SC (17) | 17 | 13 | 4 | 0 | SC-5 FAIL (CrowdSec down), SC-7 FAIL (UFW 1/6), SC-7(7) FAIL (CF tunnel down), SC-17 FAIL (no PKI engine) |
| SI (13) | 13 | 10 | 2 | 1 | SI-3 FAIL (ClamAV), SI-4(4) FAIL (Traefik down), SI-4(2) partial (custom rules) |
| **Total** | **125** | **98** | **18** | **9** | **78% pass rate** |

### 2.3 Known FAIL Causes (18 FAILs as of 2026-03-08)

**SSH cert expiry cascade (likely ~8 of 18):** AU-2, AC-6(2), SC-7 — checks that SSH into multiple hosts fail when JIT certs expire, reporting 1/N hosts instead of N/N.

**Post-PG-crash service outages:** CM-2 (Vault containers DOWN, seedbox 0/2), CP-9 (backup timers inactive), SC-5 (CrowdSec down), SC-7(7) (Cloudflare tunnel down), SI-4(4) (Traefik down on pangolin).

**Vault access issues:** AC-6 (0 Vault policies — token may lack list permission), AC-17 (SSH CA unreadable), IA-2(12) (0 auth methods detected), CA-9 (k8s auth not detected).

**New Phase 2 checks legitimately failing:** AU-5, MA-4, SC-17 — infrastructure gaps not yet addressed.

**SI-3 (ClamAV):** Script still checks for ClamAV which was replaced by Trivy/Kyverno/Cosign. See SEC-24.

### 2.4 Known WARN Causes

| Control | Check | Root Cause | Severity |
|---------|-------|-----------|----------|
| AT-2 | training_records | No formal security awareness training records | Medium |
| AU-6 | wazuh_alerts_24h | No alerts found in Wazuh alerts.json | Low |
| AU-10 | non_repudiation | Wazuh logall_json not enabled | Low |
| IA-5(13) | vault_token_ttl | Cannot determine Vault token max TTL via API | Low |
| IR-4 | wazuh_ar_rules | No active-response blocks detected | Medium |
| IR-5 | alert_volume | Low alert volume (0) — may indicate gaps | Low |
| IR-6 | discord_alerting | No Discord webhook alerting found | Medium |
| PM-2 | senior_official | No senior security official documented in SSP | Low |
| SA-8 | secure_development | No secure development lifecycle checks in CI | Medium |

---

## 3. Coverage Gap

### 3.1 The Numbers

| Metric | Value | Change from v2.1 |
|--------|-------|-------------------|
| Total controls in sentinel-moderate profile | ~229 | — |
| Controls marked N/A | ~3 | — |
| Applicable controls | ~226 | — |
| Controls with automated checks | **121 (53.5%)** | was 111 (49%) |
| Controls without automated checks | **105 (46.5%)** | was 115 (51%) |
| Automated checks passing | **98 of 125 (78%)** | was 109 of 115 (95%) |
| Controls with automated evidence | **~98 of 226 (43%)** | was 109 of 226 (48%) |

**Note on regression**: Pass rate dropped from 95% to 78% between Mar 7 and Mar 8 due to SSH cert expiry cascade failures and post-PG-crash service outages. Expected recovery to ~110+/125 (88%+) once SSH certs are renewed (SEC-23) and services restored.

**Metric definitions** (these measure different things — do not conflate):
- **Check count** (125): Number of individual automated tests in the script
- **Control count** (121): Unique NIST controls verified (some controls have multiple sub-checks)
- **Pass rate** (78%): Percentage of automated checks that PASS (degraded — see regression note above)
- **Coverage** (53.5%): Percentage of applicable controls that have automated verification
- **Evidence rate** (~43%): Percentage of applicable controls with automated PASS evidence

### 3.2 Additional Coverage (Non-Automated)

Beyond the 125 automated checks, approximately 50 additional controls have narrative implementation descriptions in the SSP (SSP-overwatch-platform.md) but lack automated verification. These include:
- AC-1, AC-5, AC-17 policy and procedure documentation
- AT-1 through AT-4 awareness and training
- CP-1, CP-3, CP-6 contingency planning documentation
- PL-1, PL-2 security planning
- Various SA (System & Services Acquisition) controls

These narratives represent intent and partial implementation but are not independently verifiable without manual review.

### 3.3 Defensible Score Statement

> **121 of 226 applicable controls have automated compliance checks (53.5%). Of those, 98 currently PASS (78% pass rate, degraded by SSH cert expiry and service outages — see Section 2.3). An additional ~50 controls have narrative-only implementation descriptions in the SSP but lack automated verification. The remaining ~55 controls have no documentation or automation.**
>
> *Previous baseline (v2.1, 2026-03-07): 110/115 passing (96%), 111/226 coverage (49%). Score recovery expected after SSH cert renewal and service restoration.*

---

## 4. OSCAL Artifact Issues

### 4.1 System Security Plan (SSP)

The SSP in `compliance-vault` has the following status:
- **REPLACE_ME placeholders**: ~~Title, version, system-name, description, authorization-boundary, and system-id fields contain placeholder text~~ **FIXED (Session 60)**
- **Status honesty**: ~~39 "implemented" controls with admitted gaps~~ **FIXED (Session 67)** — 11 controls with genuine remaining gaps downgraded to "partial". 21 controls with resolved-but-lingering gap text cleaned up. 7 controls (cp-6, cp-7, cp-7.3, cp-8, cp-8.1, cp-8.2, au-3.1) were already correctly "implemented".
- **SC-8/SC-8.1 updated (Session 67)**: Added Istio mTLS evidence (STRICT mode, 10 services, 21 AuthorizationPolicies), Vault TLS, SSH CA, WireGuard. SC-8.1 changed from "planned" to "implemented" with full cipher suite documentation.
- **Status distribution** (253 implemented-requirements): 100 implemented, 89 partial, 34 not-applicable, 30 planned
- `trestle validate -a` passes clean

### 4.2 Component Definitions

Six components are defined in the OSCAL component-definition (iac-control, okd-cluster, vault-server, wazuh-siem, gitlab-ci, network-boundary), but all have **empty `implemented-requirements` arrays**. This means:
- `trestle ssp-assemble --compdefs` will fail
- No traceability from controls to implementing components
- The component definitions are structurally valid but semantically empty
- Populating requires mapping 253 SSP controls to components (8-12 hours)

### 4.3 Security Assessment Report (SAR)

The SAR has been reconciled with the SSP (Session 67):
- **SSP/SAR alignment**: ~~106 controls disagreed~~ **FIXED** — 61 SAR-only findings removed, 45 SSP-only findings added. Both now have exactly 253 controls.
- **Status**: 100 satisfied, 153 not-satisfied (aligned with SSP implementation status)
- **Evidence pipeline**: Running daily, generates OSCAL AR from compliance check output
- `trestle validate -a` passes clean on all artifacts

### 4.4 Evidence Pipeline

- **Status**: ~~FAILING since 2026-02-21~~ **OPERATIONAL (Session 67)** — GitLab PAT renewed, evidence pipeline running successfully
- **Production script** (`~/sentinel-repo/scripts/evidence-pipeline.sh`): Runs compliance check, generates OSCAL AR via converter, commits daily reports to compliance-vault
- **OSCAL AR converter** (`~/sentinel-repo/scripts/convert-to-oscal-ar.sh`): Producing valid OSCAL 1.1.2 Assessment Results
- **OKD CronJob version**: Separate 11-check API-only subset

---

## 5. Infrastructure Blockers

### 5.1 SSH Certificate Expiry — RESOLVED (Session 59)

~~JiT SSH certificates on iac-control have expired.~~ Renewed. All 6 remote hosts reachable.

### 5.2 VAULT_TOKEN Not Set — RESOLVED (Session 59)

~~`/etc/sentinel/compliance.env` does not have VAULT_TOKEN set.~~ Token configured. Vault API checks now produce definitive results.

### 5.3 Backup Timers Inactive — RESOLVED (Session 59)

~~vault-backup.timer and gitlab-backup.timer inactive.~~ Restarted on both hosts.

### 5.4 OKD CronJob MinIO Connectivity — PARTIALLY FIXED (Session 60)

The sentinel-ops OKD CronJob had two issues:
1. **MC_CONFIG_DIR**: `mc` binary couldn't write config to `/` (OKD non-root containers). **FIXED** — Added `export MC_CONFIG_DIR=/tmp/.mc` to minio-replicate.sh, compliance-scripts.yaml, and evidence-pipeline.sh.
2. **Silent crash**: `mc alias set` errors suppressed by `>/dev/null 2>&1` + `set -euo pipefail`. **FIXED** — Added visible error logging with proper `|| { log "FATAL: ..."; exit 1; }`.
3. **nist-compliance-check CronJob exit code**: Script exited 1 on any FAIL check, causing CronJob "Error" status. **FIXED** — Changed to always exit 0 (report captures failures, CronJob success means script ran).

**Still active**: MinIO network connectivity from OKD pods to 192.168.12.58:9000 may still have issues. The mc config fix resolves the immediate crash but actual bucket operations need verification on next CronJob run.

### 5.5 Expired GitLab PAT for compliance-vault — RESOLVED (Session 67)

~~The git remote URL for `~/compliance-vault` on iac-control contains expired PAT.~~ **FIXED** — New PAT generated and stored in Vault. Git remote updated. Evidence pipeline, SSP updates, and all OSCAL artifact work now operational.

### 5.6 Wazuh MCP Container Auth — FIXED (Session 60)

The Wazuh MCP Docker container on iac-control was running with default credentials (`WAZUH_USER=wazuh`, `WAZUH_PASS=wazuh`) instead of the actual Vault credentials (`wazuh-wui`). This caused 7868 consecutive 401 auth failures and a permanent circuit breaker open state. **FIXED** — Container recreated with correct credentials from `secret/wazuh/api`.

### 5.7 Grafana MCP Token — FIXED (Session 60)

Grafana MCP was returning 401 Unauthorized. **FIXED** — Created new service account `mcp-readonly` (Viewer role) with 90-day token. Updated `~/.mcp.json`. Requires Claude Code restart to take effect.

---

## 6. Score History Correction

### 6.1 Previous Claims

Prior scores of "64-65% (176-180/276)" were propagated from an informal estimate in the SSP (line 12: "Full SAR: ~185/276 ~67%"). This number:
- Was never computed from an authoritative source
- Did not distinguish between automated evidence and narrative claims
- Was copied across MEMORY.md, task-queue.md, briefing.md, nist-score-history.md, and compliance.md without verification
- Conflated "controls mentioned in documentation" with "controls with evidence of compliance"

### 6.2 Corrected Posture

| Metric | Old Claim (pre-Session 56) | v1.0 (Session 56-58) | v1.1 Current (Session 59+) |
|--------|---------------------------|----------------------|----------------------------|
| Compliance score | 64-65% (176-180/276) | 24-26% automated evidence | 53.5% coverage (121/226), 78% pass rate (98/125) |
| Automated check pass rate | Not distinguished | 71-77% of 77 checks | **98% of 100 checks** (98 PASS) |
| Total applicable controls | 276 | ~226 | ~226 |
| Controls with any evidence | "176-180" | ~105 (55 auto + ~50 narrative) | ~148 (98 automated + ~50 narrative) |

---

## 7. Phased Remediation Plan

### Phase 1: Fix Infrastructure Blockers (Quick Wins) — COMPLETED

~~**Goal**: Unblock 6+ FAIL checks, maximize PASS rate of existing checks.~~

All Phase 1 items completed in Session 59:
1. ~~Renew JiT SSH certs~~ — Done
2. ~~Set VAULT_TOKEN in compliance.env~~ — Done
3. ~~Restart backup timers~~ — Done
4. ~~Verify UFW active~~ — Done (6/6 hosts)

**Result**: 98/100 PASS (98% pass rate), up from ~55/77 (71%)

### Phase 2: OSCAL Artifact Cleanup

**Goal**: Make OSCAL artifacts internally consistent and defensible.
**Effort**: 4-8 hours.

1. Fix SSP REPLACE_ME placeholders (title, version, system-name, description, authorization-boundary, system-id)
2. Downgrade 39 "implemented-with-gaps" controls to "partial" in SSP
3. Reconcile SSP vs SAR (106 controls disagree — resolve each one)
4. Populate component-definition `implemented-requirements` for 6 components

### Phase 3: Evidence Pipeline Deployment

**Goal**: Automated daily OSCAL Assessment Results from compliance check output.
**Effort**: 2-4 hours.

1. Clone compliance-vault repo on iac-control
2. Deploy `convert-to-oscal-ar.sh` and `evidence-pipeline.sh` to systemd timer paths
3. Verify OSCAL AR converter produces valid output
4. Run `trestle validate` on updated artifacts
5. Set up evidence-pipeline systemd timer (daily 7AM UTC)

### Phase 4: Expand Automated Coverage (Ongoing)

**Goal**: Increase from 100 to 120+ automated checks (~53% coverage).
**Effort**: Ongoing, incremental.

Priority controls to add automated checks for:
- AT-2, AT-3, AT-4 (training records, role-based training)
- AC-19 (mobile access controls), AC-20 (external systems)
- PM family (program management controls)
- SC-4 (info in shared resources)
- Additional SA controls (SA-4 acquisition process, SA-8 security engineering)

**Target**: 120+ automated checks covering 53%+ of 226 applicable controls.

---

## 8. CIS Benchmark Status (Wazuh SCA)

### 8.1 Current Scores

| Agent | Host | Benchmark | Score | Pass | Fail | Total |
|-------|------|-----------|-------|------|------|-------|
| 007 | iac-control | CIS Ubuntu 24.04 v1.0.0 | 78% | 209 | 57 | 279 |
| 001 | vault-server | CIS Ubuntu 24.04 v1.0.0 | 79% | 211 | 55 | 279 |
| 002 | pangolin-proxy | CIS Ubuntu 24.04 v1.0.0 | 80% | 214 | 52 | 279 |
| 008 | gitlab-server | CIS Ubuntu 24.04 v1.0.0 | 79% | 211 | 55 | 279 |
| 000 | wazuh-server | CIS Ubuntu 22.04 v2.0.0 | 68% | 137 | 62 | 207 |
| 006 | seedbox-vm | CIS Ubuntu 22.04 v2.0.0 | 68% | 136 | 63 | 207 |

Proxmox hosts (pve, 208-pve2, pve3) are not Wazuh-managed and have no SCA data.

### 8.2 Failure Categories (iac-control, representative)

57 failing checks fall into these categories:

**Partition layout (24 checks) — NOT REMEDIABLE without rebuild:**
Checks 35510-35535: Separate partitions for /tmp, /home, /var, /var/tmp, /var/log, /var/log/audit with nodev/nosuid/noexec options. VMs were provisioned from cloud-init templates with single-partition layout. Repartitioning requires rebuilding the VM.

**Firewall framework confusion (14 checks) — BY DESIGN:**
Checks 35619-35638: CIS expects a single firewall framework (nftables OR iptables OR ufw). iac-control uses both UFW and raw iptables (for Squid transparent proxy redirect). These are complementary, not conflicting, but CIS flags them as failures.

**dnsmasq/squid/rpcbind services (3 checks) — BY DESIGN:**
Checks 35565, 35572, 35577: CIS says these services should not be running. iac-control runs them intentionally (dnsmasq=DHCP/DNS for OKD, squid=egress proxy, rpcbind=NFS client).

**AppArmor not all enforcing (1 check) — PARTIAL:**
Check 35539: Some AppArmor profiles in complain mode. Can be fixed by enforcing all profiles.

**GRUB bootloader password (1 check) — DEFERRED:**
Check 35540: No GRUB password set. Requires physical/console access to set, low risk for VMs.

**IP forwarding enabled (1 check) — BY DESIGN:**
Check 35608: iac-control forwards traffic between vmbr0 (LAN) and vmbr1 (OKD internal).

**PAM modules (4 checks) — FIXABLE:**
Checks 35672-35689: pam_unix, pam_faillock, pam_pwhistory not enabled/configured per CIS spec. Can be added to `common` Ansible role.

**systemd-timesyncd vs chrony (1 check) — BY DESIGN:**
Check 35589: CIS expects systemd-timesyncd but hosts use chrony (configured in Session 55).

**Logging/audit (8 checks) — PARTIALLY FIXABLE:**
Checks 35710-35760: Remote journal upload auth, rsyslog remote host, logfile permissions, audit log deletion policy, audit tools permissions. Some are fixable via Ansible, others require centralized log infrastructure.

### 8.3 Remediation Priority

| Category | Checks | Effort | Impact |
|----------|--------|--------|--------|
| PAM modules | 4 | Low (Ansible) | +1-2% per host |
| AppArmor enforcement | 1 | Low (Ansible) | +0.4% per host |
| Audit/log permissions | 4 | Low (Ansible) | +1.5% per host |
| rsyslog remote logging | 2 | Medium (needs log server) | +0.7% per host |
| Partition layout | 24 | NOT REMEDIABLE (VM rebuild) | +8.6% per host |
| Firewall framework | 14 | NOT REMEDIABLE (by design) | N/A |
| Required services | 4 | NOT REMEDIABLE (by design) | N/A |

**Achievable target**: ~84-85% CIS score on Ubuntu 24.04 hosts (from 78-80%) by fixing PAM, AppArmor, and audit checks. Partition and firewall checks are structural and accepted as-is.

---

## 9. Non-Remediable Items

This section documents controls and checks that **cannot be remediated** without fundamental infrastructure changes, and what those changes would require.

### 9.1 CIS Benchmark — Structural Limitations

**Partition layout (24 checks per host, ~8.6% of CIS score):**
All VMs use single-partition cloud-init layout. Fixing requires: new Packer templates with custom partition tables (separate /tmp, /home, /var, /var/tmp, /var/log, /var/log/audit), then rebuild every VM. This is a 2-3 day effort affecting 6+ VMs with downtime.

**Firewall framework (14 checks per iac-control):**
iac-control intentionally uses UFW + raw iptables. CIS requires choosing one framework. Fixing requires: migrating all iptables rules to ufw or nftables, removing the other framework. Risk: Squid transparent proxy redirect rules are complex iptables chains that may not translate cleanly to ufw.

**Required services (4 checks on iac-control):**
dnsmasq, squid, rpcbind are architectural requirements. dnsmasq provides DHCP/DNS/PXE for the OKD cluster. Squid provides egress allowlisting. These cannot be removed without replacing with equivalent services.

### 9.2 NIST Controls — Organizational/Process Controls

These NIST 800-53 controls require organizational processes that do not apply to a single-operator homelab:

**Personnel Security (PS family, ~8 controls):**
PS-1 through PS-8 require background checks, personnel screening, termination procedures, and access agreements. Not applicable to single-operator environment. **To become compliant**: Document self-attestation processes, formalize access agreements even for sole operator.

**Program Management (PM family, ~16 controls):**
PM-1 through PM-16 require a formal security program with dedicated staff, risk management framework, enterprise architecture, and critical infrastructure plan. **To become compliant**: Create formal security program documentation. Most can be addressed with policy documents alone (~8 hours of writing).

**Training (AT-2 through AT-4, 3 controls):**
Require formal training programs, role-based curricula, and training records. **To become compliant**: Document self-training schedule, maintain training log (spreadsheet or Mattermost channel), link to relevant certifications/courses.

**Physical Security (PE family beyond PE-6/PE-14, ~16 controls):**
PE-1 through PE-20 cover physical access control, visitor records, environmental protections (fire, water, temperature), delivery/removal tracking. Limited applicability in home environment. **To become compliant**: Document physical security of server room/closet, add temperature monitoring (iDRAC already provides this), document visitor access procedures.

### 9.3 NIST Controls — Technology Gaps

These controls require new services or capabilities not currently deployed:

**AU-10 Non-repudiation (requires log signing):**
Need: Digital signing of audit logs using Vault transit engine or Sigstore. Effort: Medium (2-4 hours to implement, ongoing maintenance). Would add tamper-evident audit trail.

**CP-6 Alternate Storage Site (requires offsite backup):**
Need: Backblaze B2 or similar offsite replication of critical backups. Effort: Low-Medium (Backblaze integration exists, need to wire to MinIO replication). Would satisfy geographic separation requirement.

**RA-5(4) Discoverable Information (requires OSINT scanning):**
Need: Shodan/Censys API integration to check external exposure. Effort: Medium (API integration + scheduled scan). Would validate that internal services aren't accidentally exposed.

**SC-20/21/22 Secure DNS (requires DNSSEC):**
Need: DNSSEC validation in dnsmasq or switch to a DNSSEC-validating resolver. Effort: Low (dnsmasq supports DNSSEC validation). Would protect against DNS spoofing.

**SA-4 Acquisition Process (requires vendor assessment):**
Need: Formal process for evaluating third-party software/services. Effort: Low (documentation only). Create a template for evaluating new tools.

### 9.4 OSCAL Artifacts — Blocking Issues

~~**Expired GitLab PAT for compliance-vault:**~~ **RESOLVED (Session 67)**.

~~**SSP/SAR mismatch (106 controls):**~~ **RESOLVED (Session 67)** — Both now have exactly 253 controls, zero mismatch.

~~**Empty component definitions:**~~ **RESOLVED (Session 67)** — All 6 components populated with 296 implemented-requirements (253 unique controls mapped). Distribution: iac-control (122), okd-cluster (53), vault-server (36), wazuh-siem (31), gitlab-ci (29), network-boundary (25). SSP assembled with `--compdefs` flag successfully.

~~**39 "implemented" controls with admitted gaps:**~~ **RESOLVED (Session 67)** — 11 genuine gaps downgraded to "partial", 21 resolved gaps cleaned, 7 correctly "implemented".

### 9.5 Coverage Ceiling

| Scenario | Coverage | What's Needed |
|----------|----------|---------------|
| Current | 53.5% (121/226) | Achieved via Phase 2 expansion (Issue #26) |
| ~~+Priority 2 medium effort~~ | ~~53% (120/226)~~ | ~~9 more checks with multi-host queries~~ **DONE** |
| +Priority 3 documentation | 58% (132/226) | 12 policy/procedure document checks (4-8 hrs) |
| +New capabilities | 62% (140/226) | Log signing, OSINT, DNSSEC (days of work) |
| **Maximum automatable** | **~62% (140/226)** | All of the above |
| Remaining 38% | 100% (226/226) | Organizational processes, formal program, physical security — not automatable |

The ~86 controls (38%) that cannot be automated are primarily PM, PS, PE, AT families requiring human attestation, physical measures, or formal organizational processes.

---

## 10. Recommendations

1. **This document is the single source of truth** for compliance posture. Other files should reference it, not state independent scores.
2. **Do not conflate automated check pass rate with overall compliance**. 98% of 100 checks passing is not the same as 98% of 226 controls being compliant.
3. **Narrative-only controls should be clearly labeled** as such in any reporting.
4. **Phase 1 blockers are resolved** — focus now shifts to OSCAL artifact cleanup (Phase 2) and evidence pipeline (Phase 3).
5. **Score targets should be stated in terms of automated evidence coverage**, not informal estimates.
6. **OKD CronJob failures** (MinIO connectivity) should be fixed to ensure the sentinel-ops monitoring pipeline works end-to-end.
7. **CIS hardening**: Focus PAM, AppArmor enforcement, and audit permission fixes to reach 84-85% on Ubuntu 24.04 hosts. Accept partition layout and firewall framework failures as structural.
8. **Compliance-vault PAT**: Must be renewed immediately — blocks evidence pipeline, SSP updates, and all OSCAL artifact work.
9. **SSP honesty**: Downgrade the 39 "implemented-with-gaps" controls to "partial" before any external reporting.
10. **Coverage expansion**: Priority 1 quick wins (+10 checks, 2-3 hours) offer the best ROI for improving coverage from 44% to 49%.
11. **Squid egress**: Deploy corrected UFW before.rules and squid.conf via `ansible-playbook --tags squid,egress` on iac-control. HTTPS remains unfiltered (transparent proxy limitation).
12. **Kyverno enforcement**: Resolve existing policy violations (nfs-provisioner, seedbox, homepage) before switching from Audit to Enforce. Document violations as POA&M items if unfixable.

---

## 11. Backup and DR Verification (v1.3)

### 11.0 Backup Systems Status (2026-02-22)

| Backup | Schedule | Last Success | Replicated | DR Tested |
|--------|----------|-------------|------------|-----------|
| Vault (Raft) | Daily 02:00 | 2026-02-22 02:04 | Yes | Yes |
| GitLab (app+config) | Weekly Sun 03:00 | 2026-02-22 03:08 | Yes | Yes |
| etcd (OKD snapshot) | Daily 04:00 | 2026-02-22 04:02 | Yes | **No** |
| Proxmox snapshots | Daily 01:00 | 2026-02-22 01:02 | No (local only) | N/A |
| MinIO replication | Every 6h | 2026-02-22 12:30 | N/A (is the replica) | No |
| Terraform state | Manual | 2026-02-04 (18 days stale) | Yes | No |

**Critical backup gaps:**
- Vault backup reports FAILURE despite successful upload (pruning loop bug with `set -euo pipefail` when encountering filenames without date patterns like `test-replication.txt`)
- Wazuh VM (111) not included in Proxmox snapshot automation (only VMs 200, 201, 205, 109, 107 covered)
- LXC containers (300 config-server, 301 minio-bootstrap, 302 minio-replica) have no snapshots
- Mattermost MinIO bucket (38 MiB) not included in replication script
- etcd restore has never been tested (restore script exists but unvalidated)
- OKD minio-replicate CronJob failing (container crashes, empty logs) — systemd timer works fine
- NIST compliance check OKD CronJob can't verify backup freshness (MinIO credential/network issue from pod)
- `compliance-reports` and `proxmox-snapshots` MinIO buckets referenced in code but don't exist

## 12. Improvements Applied This Session (v1.3)

### 11.1 Squid Egress Filtering Fix (SC-7)

**Problem**: Live Squid config was the 9000+ line default config (not the Ansible template) with allowlist rules appended AFTER `deny all` — making domain filtering dead code. No PREROUTING redirect existed, and port 80/443 were directly forwarded past Squid.

**Fix**: Updated `ufw-before.rules.j2`:
- Added PREROUTING REDIRECT rule for port 80 → Squid port 3128
- Removed direct port 80 FORWARD rule (HTTP now goes through Squid)
- Documented HTTPS limitation (port 443 cannot be domain-filtered without SSL bumping)

**Status**: Template fixed in git. Requires deployment via `ansible-playbook --tags squid,egress`.

### 11.2 Kubernetes NetworkPolicies (SC-7, AC-4)

**Before**: 6 of 12 application namespaces had default-deny NetworkPolicies (homepage, media, monitoring, netbox, nfs-provisioner, pangolin-internal).

**After**: All 12 application namespaces have default-deny + allow-list NetworkPolicies. Added:
- backstage: default-deny, allow-backstage (7007), allow-postgresql, allow-istio-control-plane
- defectdojo: default-deny, allow-django (8080), allow-celery, allow-postgresql, allow-valkey, allow-istio-control-plane
- keycloak: default-deny, allow-keycloak (8080), allow-postgresql, allow-istio-control-plane
- mattermost: default-deny, allow-mattermost (8065), allow-postgresql, allow-istio-control-plane
- sentinel-ops: default-deny, allow-cronjobs (egress-only to Vault/Grafana/MinIO/GitLab/Wazuh)
- harbor: default-deny, allow-harbor-internal (intra-namespace), allow-postgresql, allow-istio-control-plane

Also added Prometheus Istio scrape policies for all 5 new meshed namespaces.

**Status**: In git, pending push. ArgoCD will auto-sync on merge.

### 11.3 Kyverno Policies Git-Sync (CM-3, SI-7)

**Before**: 2 of 6 live ClusterPolicies tracked in git (restrict-image-registries, verify-image-signatures).

**After**: All 6 ClusterPolicies tracked in git:
- disallow-privileged-containers (CM-7, SI-7)
- require-labels (CM-8)
- require-resource-limits (SC-6)
- require-run-as-nonroot (CM-7, AC-6)
- restrict-image-registries (CM-7, SI-7)
- verify-image-signatures (SI-7, CM-14, SA-12)

All remain in Audit mode — existing violations must be resolved before Enforce.

### 11.4 Wazuh MCP Fix (Prior session continuation)

Wazuh MCP container recreated with correct credentials from Vault. 7868 auth failures resolved.

### 11.5 Grafana MCP Token (Prior session continuation)

New service account `mcp-readonly` created with 90-day token. Updated `~/.mcp.json`.

---

## Document Control

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-21 | Initial gap analysis — methodology correction, score correction, phased remediation |
| 1.1 | 2026-02-22 | Reconciled with actual script: 90→100 checks, 77→100 controls, 16 families (AT added), 98% pass rate. Phase 1 blockers marked resolved. Added OKD CronJob MinIO blocker. Updated all metrics and coverage numbers. |
| 1.2 | 2026-02-22 | Added CIS benchmark status (Section 8), non-remediable items (Section 9), coverage ceiling analysis, OSCAL artifact issues from compliance agent deep-dive (SSP REPLACE_ME fixed, 39 gap controls, 106 SSP/SAR mismatches, empty component-defs, expired compliance-vault PAT). Updated recommendations. |
| 1.3 | 2026-02-22 | Squid egress fix (SC-7), NetworkPolicies for 6 namespaces (12/12 coverage), 4 Kyverno policies synced to git (6/6 tracked), Prometheus/Istio scrape policies expanded, Wazuh+Grafana MCP fixes documented. |
| 2.0 | 2026-03-01 | Phase 1 complete: 115 checks (was 100), 111 controls (49% coverage, was 44%). SC-8/SC-8.1 updated with Istio mTLS. SSP status honesty: 11 controls downgraded to partial, 21 cleaned. SSP/SAR reconciled (253/253, 0 mismatch). Evidence pipeline operational. Falco deployed (Phase 3). Keycloak audit, Wazuh logall_json, image signature enforcement, Terraform drift, Syft SBOM (Phase 2). |
| 2.1 | 2026-03-01 | Phase 4 tooling evaluation: Compliance Operator SKIP (not available on OKD, SCAP targets RHCOS not SCOS), Lula SKIP (Go version maintenance mode, TS v2 dropped OSCAL, 26 stars), C2P deferred. Unified compliance Grafana dashboard deployed (ArgoCD sync, Kyverno violations, Istio mTLS, Falco runtime, data freshness). Falco NetworkPolicy fixed for user-workload Prometheus scraping. K8s v1.32 confirms VAP GA support. |
| 2.2 | 2026-03-01 | Phase 5 component-definitions populated: 253 controls mapped to 6 components (296 total implemented-requirements). SSP assembled with `--compdefs` flag. trestle validate passes clean. All 5 phases of Zero-Drift plan complete. |
| 2.3 | 2026-03-05 | Phase 2 coverage expansion: 10 new checks (AU-5, AU-7, CA-5, CA-9, MA-4, PL-4, RA-2, SA-5, SA-10, SC-17). Coverage 49% → 53.5% (121/226 controls). Multi-host SSH + Vault API + file checks. Issue #26. |
