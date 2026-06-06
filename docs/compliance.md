# NIST 800-53 Compliance

## Overview

Project Sentinel implements NIST 800-53 Moderate controls tracked via OSCAL artifacts in the `compliance-vault` GitLab repository (project 5).

- **Framework**: NIST SP 800-53 Rev 5
- **Profile**: `sentinel-moderate`
- **Applicable controls**: ~226 (after N/A exclusions)
- **Automated evidence coverage**: ~26% (59 of 226 controls have automated checks that pass)
- **Automated check pass rate**: ~76% (59 of 77 checks pass)
- **Tooling**: NIST trestle v3.11.0
- **Authoritative posture document**: [`docs/nist-gap-analysis.md`](nist-gap-analysis.md)

### Scoring Methodology

The compliance score is based on `scripts/nist-compliance-check.sh`, which runs 77 automated checks across 13 control families. Each check queries live infrastructure (Wazuh API, SSH, Vault API, OKD API, HTTP endpoints) and produces PASS/FAIL/WARN.

**Important**: The 77 automated checks cover only 34% of the ~226 applicable controls. The pass rate of those checks (76%) should not be conflated with overall compliance. An additional ~50 controls have narrative descriptions in the SSP but no automated verification.

## Compliance Automation

Four systemd timers run daily on iac-control:

| Timer | Schedule (UTC) | Action |
|-------|---------------|--------|
| Compliance check | 6:00 AM | Runs `nist-compliance-check.sh`, generates report |
| Evidence pipeline | 7:00 AM | Designed but not yet deployed to systemd |
| Drift detection | 8:00 AM | Ansible `--check --diff`, alerts via Wazuh (rules 100420-100428) |
| Drift remediation | 8:30 AM | Auto-applies `common` role if drift detected |

### Compliance Check Script

```bash
# On iac-control:
~/sentinel-repo/scripts/nist-compliance-check.sh
```

Validates 13 control families (77 checks) and outputs PASS/FAIL/WARN for each. Results are written to `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json`.

### Known Infrastructure Blockers

- **SSH certificate expiry**: Blocks remote host checks (6+ checks affected)
- **VAULT_TOKEN not set**: Blocks Vault API checks (5 checks affected)
- **Backup timers inactive**: Some VM backup timers not running

See [`docs/nist-gap-analysis.md`](nist-gap-analysis.md) for full details and remediation plan.

## OSCAL Artifacts

The `compliance-vault` repo (GitLab project 5) contains OSCAL JSON documents:

- **System Security Plan (SSP)**: `sentinel-ssp` (has REPLACE_ME placeholders, needs cleanup)
- **Component Definitions**: 6 components defined (implemented-requirements currently empty)
- **Assessment Results**: Converter created but pipeline not yet deployed

### Known OSCAL Issues

- SSP has REPLACE_ME placeholders in title, version, system-name, description, authorization-boundary, system-id
- 39 controls marked "implemented" but descriptions admit gaps — should be "partial"
- Component definitions have empty `implemented-requirements` arrays
- SAR from Feb 6 is stale and disagrees with SSP on 106 controls

### Trestle Commands

```bash
# On iac-control, in compliance-vault repo:
source .venv/bin/activate
trestle validate -a                                               # Validate all artifacts
trestle ssp-assemble -n sentinel-ssp -cd sentinel-platform        # Assemble SSP
```

> **Note**: Do not use `--compdefs` flag with `ssp-assemble` if component definitions have empty implemented-requirements — it will fail.

## Branch Protection

The compliance-vault repo has branch protection on `main`:

- Push restricted to Maintainers
- Force push disabled
- Ensures audit trail integrity

## CI Integration

Security scan results from the sentinel-iac CI pipeline are uploaded to DefectDojo (`https://defectdojo.208.haist.farm`) for centralized vulnerability tracking:

- **Trivy IaC scan** — Infrastructure misconfigurations
- **Trivy filesystem scan** — Dependency vulnerabilities
- **Gitleaks** — Secret detection (hard block)

CI includes are defined in `ci/security.yml`, `ci/compliance.yml`, and `ci/defectdojo.yml`.
