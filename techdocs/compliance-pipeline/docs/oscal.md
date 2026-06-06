# OSCAL Artifacts

## Overview

Project Sentinel tracks NIST 800-53 compliance via OSCAL (Open Security Controls Assessment Language) JSON artifacts stored in the `compliance-vault` GitLab repository (project 5).

- **Tooling**: NIST `trestle` v3.11.0
- **Profile**: `sentinel-moderate` (~226 applicable controls after N/A exclusions)
- **Components**: 6 (iac-control, okd-cluster, vault-server, wazuh-siem, gitlab-ci, network-boundary)
- **Repository**: `compliance-vault` on GitLab at `192.168.12.68` (project 5)

## Artifact Inventory

### System Security Plan (SSP)

**Path**: `compliance-vault/system-security-plans/sentinel-ssp/system-security-plan.json`

The SSP contains 253 implemented-requirements with the following status distribution:

| Status | Count |
|--------|-------|
| implemented | 100 |
| partial | 89 |
| not-applicable | 34 |
| planned | 30 |
| **Total** | **253** |

The SSP passes `trestle validate -a` clean. All REPLACE_ME placeholders in title, version, system-name, description, authorization-boundary, and system-id were resolved.

### Component Definitions

**Path**: `compliance-vault/component-definitions/sentinel-platform/`

Six components are defined with 296 total implemented-requirements (253 unique controls mapped):

| Component | Impl-Reqs | Purpose |
|-----------|-----------|---------|
| iac-control | 122 | IaC orchestration, networking, compliance automation |
| okd-cluster | 53 | OKD/Kubernetes workload platform |
| vault-server | 36 | Secrets management, PKI, SSH CA |
| wazuh-siem | 31 | SIEM, FIM, vulnerability detection |
| gitlab-ci | 29 | CI/CD, version control, pipeline security |
| network-boundary | 25 | Traefik, CrowdSec, Cloudflare, Istio |

SSP assembly with the `--compdefs` flag succeeds:

```bash
trestle ssp-assemble -n sentinel-ssp -cd sentinel-platform
```

### Assessment Results

**Path**: `compliance-vault/assessment-results/`

Generated daily by the evidence pipeline using `convert-to-oscal-ar.sh`. Produces OSCAL 1.1.2 Assessment Results JSON from the compliance check output.

### Security Assessment Report (SAR)

Reconciled with the SSP. Both contain exactly 253 controls with zero mismatch:

- 100 satisfied (aligned with SSP "implemented")
- 153 not-satisfied (aligned with SSP partial/planned)

## Trestle Commands

All trestle commands run on iac-control in the compliance-vault repo:

```bash
# Navigate to repo
cd ~/compliance-vault

# Activate virtualenv
source .venv/bin/activate

# Validate all OSCAL artifacts
trestle validate -a

# Assemble SSP (with component definitions)
trestle ssp-assemble -n sentinel-ssp -cd sentinel-platform

# Assemble SSP (without component definitions)
trestle ssp-assemble -n sentinel-ssp
```

### Known Gotchas

**Do NOT use `--compdefs` with empty implemented-requirements**: If any component-definition has empty `implemented-requirements` arrays, `trestle ssp-assemble --compdefs` will fail. As of Session 67, all 6 components are populated, so this is no longer an issue.

**Branch protection**: The compliance-vault repo has branch protection on `main`:

- Push restricted to Maintainers
- Force push disabled
- This ensures audit trail integrity for compliance evidence

## Evidence Pipeline and OSCAL

The evidence pipeline converts daily compliance check JSON into OSCAL Assessment Results:

```
nist-compliance-check.sh
  -> /var/log/sentinel/nist-compliance-YYYY-MM-DD.json

convert-to-oscal-ar.sh
  -> compliance-vault/assessment-results/ar-YYYY-MM-DD.json

evidence-pipeline.sh
  -> git commit + push to compliance-vault
```

The converter (`convert-to-oscal-ar.sh`) maps each check result to an OSCAL observation:

- PASS checks become "satisfied" findings
- FAIL checks become "not-satisfied" findings
- WARN checks become "not-satisfied" findings with a note about the limitation

## Coverage Analysis

### What OSCAL Covers vs. What Automation Covers

| Scope | Controls | Source |
|-------|----------|--------|
| SSP total | 253 | system-security-plan.json |
| SSP implemented | 100 | Status = "implemented" |
| SSP partial | 89 | Status = "partial" |
| SSP planned | 30 | Status = "planned" |
| SSP N/A | 34 | Status = "not-applicable" |
| Automated checks | 111 unique | nist-compliance-check.sh |
| Automated passing | 109 | Daily report |
| Narrative-only | ~50 | SSP descriptions without automated verification |
| No coverage | ~65 | Neither automated nor narrative |

### Coverage Ceiling

| Scenario | Coverage | What Is Needed |
|----------|----------|---------------|
| Current | 49% (111/226) | Achieved |
| +Medium effort | 53% (120/226) | 9 more checks with multi-host queries |
| +Documentation | 58% (132/226) | 12 policy/procedure document checks |
| +New capabilities | 62% (140/226) | Log signing, OSINT scanning, DNSSEC |
| Maximum automatable | ~62% (140/226) | All of the above |
| Remaining 38% | Organizational | PM, PS, PE, AT families requiring human attestation |

## Scoring Limitations

The automated check script tests *necessary conditions* for compliance, not *sufficient conditions*:

- A PASS on AC-2 (Keycloak OIDC endpoint responding) confirms the IdP is running but does not prove all AC-2 sub-requirements (quarterly reviews, account disabling procedures) are met.
- The 95% automated pass rate (109/115) is NOT the same as 95% overall compliance.
- The 49% coverage (111/226) means over half of applicable controls have no automated verification.

The authoritative compliance posture is documented in `sentinel-iac-work/docs/nist-gap-analysis.md` (v2.2). All other documents should reference it rather than stating independent scores.
