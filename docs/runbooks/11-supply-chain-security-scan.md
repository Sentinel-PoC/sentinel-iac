# Runbook 11 — Supply-chain Security Scan (SBOM + OSV + SLSA)

**Issues:** SEC-60 (SBOM), SEC-61 (OSV/language audit), SEC-62 (SLSA provenance)
**Scope:** Forgejo Actions composite action `.forgejo/actions/security-scan/action.yml`
**Last updated:** 2026-04-19

---

## What the composite action does

The `security-scan` composite action runs eight steps in order:

| Step | Tool | Output | Purpose |
|------|------|--------|---------|
| 1 | Syft | `sbom.cyclonedx.json` | CycloneDX SBOM of image filesystem |
| 2 | npm/pip/go/cargo | lang-specific report | Lockfile provenance + known vulns |
| 3 | OSV-Scanner | `osv.json` | Malicious + vulnerable package detection |
| 4 | curl | DefectDojo CycloneDX import | Persist SBOM findings |
| 5 | curl | DefectDojo OSV import | Persist OSV findings |
| 6 | python3 | `slsaprovenance.json` | SLSA v1.0 provenance predicate |
| 7 | cosign | Registry attestations | Sign image + attest SBOM + attest provenance |
| 8 | upload-artifact | Workflow artifacts (90d) | Audit trail |

The action is idempotent: running twice on the same image overwrites the existing
cosign signature and attestations (`--replace --yes`) rather than duplicating them.

---

## How to consume SBOM findings in DefectDojo

1. Log in to DefectDojo: `https://defectdojo.208.haist.farm`
2. Navigate to **Products** → **Sentinel Platform**
3. Open the engagement **sentinel-platform-sbom**
4. Each CI run creates or updates a test titled `SBOM: <image-ref>`
5. Findings represent every package in the image — filter by severity for actionable items

To query via API:
```bash
DD_TOKEN=$(vault kv get -field=api_token secret/defectdojo)
curl -sk -H "Authorization: Token $DD_TOKEN" \
  "https://defectdojo.208.haist.farm/api/v2/findings/?test__engagement__name=sentinel-platform-sbom&severity=Critical&active=true" \
  | jq '.results[] | {title, component_name, component_version}'
```

To check if a specific package is in any SBOM:
```bash
curl -sk -H "Authorization: Token $DD_TOKEN" \
  "https://defectdojo.208.haist.farm/api/v2/findings/?component_name=<pkg>&limit=50" \
  | jq '.count, [.results[] | .test_object_url]'
```

---

## How to consume OSV findings in DefectDojo

1. Navigate to **Products** → **Sentinel Platform** → engagement **sentinel-platform-osv**
2. OSV findings include both CVE-mapped and malicious-package entries (OSV IDs starting with `MAL-`)
3. Malicious package entries are highest priority — the build fails on these (Step 3 hard-fail)

OSV-Scanner output format: `osv.json` with `results[].packages[].vulnerabilities[]`.

To check for malicious package findings:
```bash
curl -sk -H "Authorization: Token $DD_TOKEN" \
  "https://defectdojo.208.haist.farm/api/v2/findings/?tag=osv&active=true&limit=100" \
  | jq '.results[] | select(.vuln_id_from_tool | startswith("MAL-")) | {title, component_name}'
```

---

## How to verify image attestations

### Check cosign signature
```bash
COSIGN_PUB=$(vault kv get -field=public_key secret/cosign)
cosign verify \
  --key <(echo "$COSIGN_PUB") \
  --insecure-ignore-tlog \
  harbor.208.haist.farm/sentinel/<image>:<tag>
```

### Check SLSA provenance attestation
```bash
cosign verify-attestation \
  --key <(echo "$COSIGN_PUB") \
  --type slsaprovenance \
  --insecure-ignore-tlog \
  harbor.208.haist.farm/sentinel/<image>:<tag> \
  | jq '.payload | @base64d | fromjson | .predicate.runDetails.builder.id'
```

Expected output: `https://forgejo.208.haist.farm/sentinel-admin/<repo>/actions/runner`

### Check SBOM attestation
```bash
cosign verify-attestation \
  --key <(echo "$COSIGN_PUB") \
  --type cyclonedx \
  --insecure-ignore-tlog \
  harbor.208.haist.farm/sentinel/<image>:<tag> \
  | jq '.payload | @base64d | fromjson | .predicate.components | length'
```

### Check Kyverno audit violations
```bash
# In OKD cluster
oc get policyreport -A -o json | jq '.items[].results[] | select(.policy == "verify-attestations") | {resource: .resources[0].name, message: .message}'
```

---

## Troubleshooting

### "syft not found on runner"

Install Syft on the iac-control runner host:
```bash
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin v1.21.0
syft --version
```

Or add to `ansible/roles/iac-control/tasks/services.yml` as a permanent install task.

### "cosign not found on runner"

Install cosign on iac-control:
```bash
curl -sSfL https://github.com/sigstore/cosign/releases/download/v2.4.3/cosign-linux-amd64 \
  -o /usr/local/bin/cosign && chmod +x /usr/local/bin/cosign
cosign version
```

### "osv-scanner not found — skipping"

OSV-Scanner missing generates a warning (not failure). Install:
```bash
curl -sSfL https://github.com/google/osv-scanner/releases/download/v1.9.1/osv-scanner_linux_amd64 \
  -o /usr/local/bin/osv-scanner && chmod +x /usr/local/bin/osv-scanner
```

### "OSV-Scanner detected N malicious package entries. Build failed."

This is a hard-fail (Step 3). The image was NOT attested. Actions:
1. Check `osv.json` artifact for `MAL-*` vulnerability IDs
2. Identify the affected package: `jq '.results[].packages[] | select(.vulnerabilities[].id | startswith("MAL-"))' osv.json`
3. Open a SEC issue with evidence
4. If this is a false positive (upstream OSV DB error), set `hard-fail-on-critical: "false"` temporarily and document the exception in a SEC issue

### "DefectDojo SBOM upload failed (HTTP 400)"

Check scan_type validity:
```bash
DD_TOKEN=$(vault kv get -field=api_token secret/defectdojo)
# Test CycloneDX import returns "product_name parameter missing" = scan type OK
# Returns "Invalid scan_type" = DefectDojo version too old
curl -sk -X POST "https://defectdojo.208.haist.farm/api/v2/import-scan/" \
  -H "Authorization: Token $DD_TOKEN" \
  -F "scan_type=CycloneDX Scan" | jq .
```

If DefectDojo returns "Invalid scan_type", the DefectDojo installation may be outdated.
Current supported scan types for this platform: `CycloneDX Scan`, `OSV Scan`.

### "cosign: UNAUTHORIZED" when pushing attestations

The Forgejo Actions runner must have Harbor credentials available:
```bash
# On iac-control as the runner user
podman login harbor.208.haist.farm --username <robot> --password <pw>
# Or: buildah login harbor.208.haist.farm ...
```

The cosign commands require push permissions to the image's repository to attach
attestations as OCI artifacts.

### Kyverno audit violations showing for existing images

Expected initially — existing images built before SEC-62 will have signatures but
no attestations. The policy is in **audit** mode (admits pods, logs violations).

To flip to enforce mode after images have been re-attested:
```bash
# In overwatch-gitops repo, edit apps/kyverno-policies/verify-attestations.yaml:
# Change: validationFailureAction: Audit
# To:     validationFailureAction: Enforce
# Then open a PR and request operator review. DO NOT merge without Judge approval.
```

---

## How to approve an image without provenance (exception path)

If an image cannot have a SLSA attestation (upstream image, no build pipeline access):

1. Open a SEC issue documenting: image name+digest, reason no attestation, risk accepted
2. Add the image to a Kyverno PolicyException:

```yaml
apiVersion: kyverno.io/v2beta1
kind: PolicyException
metadata:
  name: upstream-image-exception-<name>
  namespace: <target-namespace>
spec:
  exceptions:
    - policyName: verify-attestations
      ruleNames:
        - verify-slsa-provenance-attestation
  match:
    any:
      - resources:
          kinds: [Pod]
          namespaces: [<target-namespace>]
          selector:
            matchLabels:
              app: <app-name>
```

3. Reference the SEC issue in the PolicyException metadata annotations
4. Review exception quarterly

---

## DefectDojo engagement bootstrap (one-time)

If the `sentinel-platform-sbom` or `sentinel-platform-osv` engagements do not exist:

```bash
DD_TOKEN=$(vault kv get -field=api_token secret/defectdojo)

# Get or create "Sentinel Platform" product ID
PRODUCT_ID=$(curl -sk -H "Authorization: Token $DD_TOKEN" \
  "https://defectdojo.208.haist.farm/api/v2/products/?name=Sentinel+Platform" \
  | jq '.results[0].id')

# Create SBOM engagement
curl -sk -X POST "https://defectdojo.208.haist.farm/api/v2/engagements/" \
  -H "Authorization: Token $DD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"sentinel-platform-sbom\", \"product\": ${PRODUCT_ID}, \"target_start\": \"$(date +%Y-%m-%d)\", \"target_end\": \"2099-12-31\", \"status\": \"In Progress\", \"engagement_type\": \"CI/CD\"}"

# Create OSV engagement
curl -sk -X POST "https://defectdojo.208.haist.farm/api/v2/engagements/" \
  -H "Authorization: Token $DD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"sentinel-platform-osv\", \"product\": ${PRODUCT_ID}, \"target_start\": \"$(date +%Y-%m-%d)\", \"target_end\": \"2099-12-31\", \"status\": \"In Progress\", \"engagement_type\": \"CI/CD\"}"
```

The composite action uses `auto_create_context=true` when no engagement ID is
specified, so the engagements are also created automatically on first run.
