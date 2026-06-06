# Compliance Pipeline Overview

## What Is the Compliance Pipeline?

The Compliance Pipeline is Project Sentinel's automated NIST 800-53 compliance verification system. It runs **115 automated checks** across **17 control families**, covering **111 unique NIST 800-53 controls** out of approximately 226 applicable controls in the `sentinel-moderate` profile (49% coverage).

**Current state**: 109 PASS / 0 FAIL / 6 WARN (95% pass rate).

## Components

The pipeline consists of three interconnected subsystems:

```
+-------------------------------+       +---------------------------+
| nist-compliance-check.sh      |       | GitLab CI Pipeline        |
| (Daily 6AM UTC, iac-control)  |       | (On every push to main)   |
|                               |       |                           |
| - 115 live infra checks       |       | - yamllint                |
| - Wazuh API queries           |       | - ansible-lint            |
| - SSH to managed hosts        |       | - tflint                  |
| - Vault API queries           |       | - trivy-iac               |
| - OKD API queries             |       | - trivy-config            |
| - HTTP health probes          |       | - gitleaks                |
|                               |       | - checkov                 |
| Output: JSON + compliance.log |       | - shellcheck              |
+---------------+---------------+       +-------------+-------------+
                |                                     |
                v                                     v
+-------------------------------+       +---------------------------+
| Evidence Pipeline             |       | DefectDojo Upload         |
| (Daily 7AM UTC, iac-control)  |       | (ci/defectdojo.yml)       |
|                               |       |                           |
| - Converts JSON to OSCAL AR   |       | - Trivy IaC findings      |
| - Commits to compliance-vault |       | - Trivy config findings   |
| - Generates daily MD report   |       | - Gitleaks results        |
| - Updates trend summary       |       | - Ansible-lint results    |
|                               |       | - Checkov results         |
+-------------------------------+       +---------------------------+
```

### 1. nist-compliance-check.sh

The primary compliance engine. A Bash script on iac-control that queries live infrastructure state through multiple channels:

- **Wazuh API**: Agent health, SCA scores, FIM status, rule counts, alert volume
- **SSH**: auditd status, UFW firewall, Docker containers, SSH config, service states across 6 managed hosts
- **Vault API**: Seal status, policies, auth methods, SSH CA, token TTL, encryption
- **OKD API**: RBAC, ArgoCD sync, Kyverno policies, Istio mTLS, SCCs, NetworkPolicies, Falco
- **HTTP probes**: Keycloak, GitLab, Traefik TLS, CrowdSec, Cloudflare tunnel, MinIO, NVD, Harbor, DefectDojo, NetBox
- **Local state**: systemd timers, audit rules, AIDE, AppArmor, ClamAV, chrony, log storage, kernel modules

Runs daily at 6:00 AM UTC via systemd timer. Outputs JSON to `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json` and appends to `/var/log/sentinel/compliance.log` (monitored by Wazuh).

### 2. Evidence Pipeline

Runs daily at 7:00 AM UTC, after the compliance check completes. Converts the JSON output to OSCAL Assessment Results format, generates a markdown daily report, and commits everything to the `compliance-vault` GitLab repo (project 5).

### 3. CI Security Scanning

The sentinel-iac GitLab CI pipeline (`ci/security.yml`) runs on every push to `main`. Security scan results are uploaded to DefectDojo (`ci/defectdojo.yml`) for centralized vulnerability tracking at `https://defectdojo.208.haist.farm`.

## Coverage Summary

| Metric | Value |
|--------|-------|
| Automated checks | 115 |
| Unique NIST controls verified | 111 |
| Applicable controls (sentinel-moderate) | ~226 |
| Coverage percentage | 49% |
| Pass rate | 95% (109/115) |
| Control families covered | 17 |
| FAIL checks | 0 |
| WARN checks | 6 |

### The 6 Known WARNs

| Control | Check | Root Cause |
|---------|-------|------------|
| AT-2 | training_records | No formal security awareness training records |
| AT-3 | role_based_training | No role-based training documentation |
| AU-10 | non_repudiation | Wazuh logall_json SSH detection unreliable |
| CM-3(2) | argocd_sync | ArgoCD sync below 80% (some apps out of sync) |
| IA-5(13) | vault_token_ttl | Vault token max TTL query returns empty |
| PM-2 | senior_official | No senior security official designated in SSP |

## Where Results Go

| Destination | Format | Purpose |
|-------------|--------|---------|
| `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json` | JSON | Raw check results with per-check detail |
| `/var/log/sentinel/compliance.log` | One-line summary | Wazuh monitoring trigger |
| `compliance-vault/reports/daily/` | Markdown | Human-readable daily report |
| `compliance-vault/assessment-results/` | OSCAL JSON | Machine-readable OSCAL Assessment Results |
| `compliance-vault/reports/compliance-trend-summary.md` | Markdown | Historical trend tracking |
| DefectDojo | JSON uploads | CI scan finding aggregation |

## Source of Truth

The authoritative compliance posture document is `sentinel-iac-work/docs/nist-gap-analysis.md` (v2.2). All other documents should reference it rather than stating independent scores.
