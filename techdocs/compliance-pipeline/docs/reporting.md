# Reporting

## Report Formats

The compliance pipeline produces reports in three formats:

1. **JSON** -- Machine-readable per-check results with full detail
2. **Markdown** -- Human-readable daily reports with trend data
3. **OSCAL Assessment Results** -- Standards-compliant format for audit tooling

## JSON Report

### Structure

Written to `/var/log/sentinel/nist-compliance-YYYY-MM-DD.json` by the compliance check script:

```json
{
  "timestamp": "2026-03-01T06:00:00Z",
  "date": "2026-03-01",
  "framework": "NIST 800-53 Rev 5",
  "project": "Sentinel",
  "overall_status": "COMPLIANT|NON-COMPLIANT",
  "summary": {
    "pass": 109,
    "fail": 0,
    "warn": 6,
    "total": 115,
    "pass_rate": 94,
    "coverage": {
      "controls_checked": 111,
      "controls_applicable": 226,
      "coverage_pct": 49
    }
  },
  "checks": [
    {
      "status": "PASS|FAIL|WARN",
      "control": "CA-7",
      "check": "wazuh_agents_active",
      "detail": "9 agents active (expected >= 9)"
    }
  ]
}
```

### Status Semantics

| Status | Meaning | Exit Code Impact |
|--------|---------|-----------------|
| PASS | Check verified and condition met | None |
| FAIL | Check verified and condition NOT met | Script exits 1 |
| WARN | Check could not complete (missing creds, connectivity) or condition partially met | None |

The `overall_status` is `COMPLIANT` if there are zero FAILs. Any FAIL makes it `NON-COMPLIANT`. WARNs do not affect overall status.

### Coverage Metrics

The JSON includes computed coverage metrics:

- **controls_checked**: Unique NIST control IDs across all checks (111)
- **controls_applicable**: Total controls in sentinel-moderate profile (~226)
- **coverage_pct**: Percentage of applicable controls with automated checks (49%)

These are distinct from the pass rate (109/115 = 95%), which measures how many of the automated checks succeed.

## Compliance Log

A single-line summary is appended to `/var/log/sentinel/compliance.log`:

```
2026-03-01T06:00:00Z NIST-COMPLIANCE: COMPLIANT - 109/115 checks passed (0 failed, 6 warnings)
```

This log line is monitored by Wazuh. A NON-COMPLIANT status triggers alerting.

## Daily Report Generation

The evidence pipeline runs `compliance-vault/scripts/generate-daily-report.py` to convert the JSON report into a markdown daily report.

### Pipeline Schedule

```
06:00 UTC  nist-compliance-check.sh runs
           -> /var/log/sentinel/nist-compliance-YYYY-MM-DD.json
           -> /var/log/sentinel/compliance.log (append)

07:00 UTC  evidence-pipeline.sh runs
           -> Reads JSON report
           -> Runs convert-to-oscal-ar.sh (OSCAL Assessment Results)
           -> Runs generate-daily-report.py (markdown)
           -> Updates compliance-trend-summary.md
           -> git commit + push to compliance-vault
```

### Daily Report Content

Each daily report in `compliance-vault/reports/daily/` includes:

- Date and overall status
- Summary counts (PASS/FAIL/WARN)
- Coverage metrics
- List of any FAILs with control ID and detail
- List of any WARNs with control ID and detail
- Comparison to previous day (delta)

### Trend Tracking

The file `compliance-vault/reports/compliance-trend-summary.md` maintains a historical table showing:

- Date
- Pass count
- Fail count
- Warn count
- Total checks
- Coverage percentage
- Notable changes

This allows tracking compliance posture over time and identifying regressions.

## DefectDojo Upload

CI security scan results are uploaded to DefectDojo at `https://defectdojo.208.haist.farm` via `ci/defectdojo.yml`. This happens automatically on every push to `main`.

### Upload Jobs

| Job | Scan Type | Source Artifact | Test Title |
|-----|-----------|-----------------|------------|
| `upload-trivy-iac` | Trivy Scan | `trivy-iac-report.json` | Trivy IaC Misconfig |
| `upload-trivy-config` | Trivy Scan | `trivy-config-report.json` | Trivy Filesystem Vuln |
| `upload-gitleaks` | Gitleaks Scan | `gitleaks-report.json` | Gitleaks Secret Detection |
| `upload-ansible-lint` | SARIF | `ansible-lint-report.json` | Ansible Lint |
| `upload-checkov` | Checkov Scan | `checkov-report.json` | Checkov IaC Analysis |

### DefectDojo Configuration

All uploads use the reimport-scan API with:

- `auto_create_context=true` -- Creates product/engagement/test if not existing
- `close_old_findings=true` -- Deduplicates by closing findings no longer in latest scan
- `product_name=Sentinel IaC`
- `engagement_name=Main Branch CI/CD`

Each scan type gets a unique `test_title` so DefectDojo can match and update the existing test rather than creating a new one each run.

### DefectDojo Access

- **URL**: `https://defectdojo.208.haist.farm`
- **API credentials**: Stored in GitLab CI variables (`DEFECTDOJO_URL`, `DEFECTDOJO_API_KEY`)
- **Note**: Uploads use `curl -sk` (insecure TLS) because DefectDojo uses an internal TLS cert. This is an accepted risk for private LAN-only traffic (ref: L-16).

## CI Compliance Report

The `ci/compliance.yml` generates a `compliance-report.md` artifact on every `main` branch run. This report maps CI jobs to NIST controls:

| NIST Control | Title | CI Job |
|-------------|-------|--------|
| SA-11 | Developer Testing | ansible-lint, tflint, yamllint |
| SA-11(1) | Static Code Analysis | trivy-iac, tflint |
| RA-5 | Vulnerability/Config Scanning | trivy-config, trivy-iac |
| IA-5(6) | Authenticator Protection | gitleaks |
| CM-3(2) | Test/Validate Changes | All lint + scan jobs |
| CA-7 | Continuous Monitoring | Pipeline execution |

The report also includes summaries of Trivy IaC and config findings counts, extracted from the JSON artifacts.

## Accessing Reports

### On iac-control

```bash
# Latest JSON report
ls -lt /var/log/sentinel/nist-compliance-*.json | head -1

# Parse with jq
jq '.summary' /var/log/sentinel/nist-compliance-$(date +%Y-%m-%d).json

# List all FAILs
jq '.checks[] | select(.status == "FAIL")' /var/log/sentinel/nist-compliance-$(date +%Y-%m-%d).json

# List all WARNs
jq '.checks[] | select(.status == "WARN")' /var/log/sentinel/nist-compliance-$(date +%Y-%m-%d).json

# Compliance log tail
tail -20 /var/log/sentinel/compliance.log
```

### In compliance-vault repo

```bash
# Daily reports
ls ~/compliance-vault/reports/daily/

# Trend summary
cat ~/compliance-vault/reports/compliance-trend-summary.md

# OSCAL Assessment Results
ls ~/compliance-vault/assessment-results/
```

### In GitLab CI

CI artifacts (JSON reports, compliance-report.md) are retained for 90 days and available through the GitLab pipeline UI at `http://192.168.12.68/admin1/sentinel-iac/-/pipelines`.
