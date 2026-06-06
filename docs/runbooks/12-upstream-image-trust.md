# Runbook 12 — Upstream Image Trust and Mirror-Time Cosign Verification

**Status:** Active
**Scope:** Harbor mirror operations, upstream image trust management
**NIST controls:** SR-11 (Component Authenticity), SR-4 (Provenance), SA-12 (Supply Chain Protection)
**Related issues:** SEC-64

---

## Overview

When we pull an upstream image into Harbor (`harbor.208.haist.farm/sentinel/*`), we
verify the upstream's Cosign signature before re-signing with our own key. This prevents
a compromised upstream registry or Squid proxy from inserting a malicious image that we
then re-sign with our key and admit to the cluster.

The trust machinery:

```
upstream registry
      |
      | cosign verify (upstream sig)
      v
  [PASS] → podman pull → podman push to Harbor → cosign sign (our key) → admitted by Kyverno
  [FAIL] → halt (unless exception documented in trust-policy.yaml)
```

Files:

| File | Purpose |
|------|---------|
| `config/supply-chain/trust-policy.yaml` | Upstream signing keys + documented exceptions |
| `docs/supply-chain/upstream-image-inventory.md` | Full inventory with rationales |
| `scripts/mirror-upstream-image.sh` | Mirror helper (called by sweep) |
| `/usr/local/bin/harbor-mirror-sweep.sh` | Sweep runner (deployed by Ansible) |
| `/etc/systemd/system/harbor-sweep.timer` | Daily timer (03:00 UTC) |
| `/var/log/harbor-sweep.log` | Sweep run log |
| `/var/log/harbor-mirror-exceptions.log` | Exception uses log |

---

## 1. Adding a New Upstream Image to the Trust Policy

### Step 1: Check whether the upstream publishes Cosign signatures

On iac-control:

```bash
cosign tree <upstream-image-ref>
```

**If output shows no Supply Chain Security artifacts:**
The upstream does not sign. You must use an exception entry. Skip to Step 4.

**If output shows `.sig` or `.att` OCI tags:**
The upstream may sign. Continue to Step 2.

### Step 2: Identify the signing method

**Keyless (Sigstore/Fulcio — common for GitHub Actions):**

```bash
# Inspect the signature certificate to find the OIDC issuer and identity
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity-regexp='https://github.com/<org>/<repo>/.+' \
  <upstream-image-ref>
```

If this passes, the image uses keyless signing via GitHub Actions. Extract:
- `certificate_oidc_issuer` from the certificate
- `certificate_identity_regexp` that matches the workflow path

**Static key:**

```bash
# Download the upstream's published public key and verify
cosign verify --key <key-url> <upstream-image-ref>
```

Look for the key URL in the upstream project's documentation or security policy.

### Step 3: Add to trust-policy.yaml

For keyless signing:

```yaml
upstream_keys:
  myimage:
    source: "docker.io/myorg/myimage"
    harbor_target: "sentinel/myimage"
    method: cosign-keyless
    certificate_oidc_issuer: "https://token.actions.githubusercontent.com"
    certificate_identity_regexp: "https://github\\.com/myorg/myimage/.+"
    notes: "Verified YYYY-MM-DD with cosign vX.Y.Z"
    last_verified: "YYYY-MM-DD"
    verified_by: "<your-name or agent-id>"
```

For static key:

```yaml
upstream_keys:
  myimage:
    source: "docker.io/myorg/myimage"
    harbor_target: "sentinel/myimage"
    method: cosign-key
    key_url: "https://myproject.example.com/cosign.pub"
    notes: "Verified YYYY-MM-DD"
    last_verified: "YYYY-MM-DD"
    verified_by: "<your-name or agent-id>"
```

### Step 4: Add an exception (if upstream provides no signature)

```yaml
exceptions:
  myimage:
    source: "docker.io/myorg/myimage"
    harbor_target: "sentinel/myimage"
    rationale: >
      myorg/myimage does not publish Cosign signatures as of YYYY-MM-DD.
      Confirmed by cosign tree returning no artifacts.
      <any other relevant context>
    compensating_controls:
      - "SEC-61: OSV-Scanner + Trivy at mirror time"
      - "Pinned tag :X.Y.Z"
    reviewed_by: "<operator name> YYYY-MM-DD"
    review_date: "YYYY-MM-DD"
    next_review_date: "YYYY-MM-DD"  # +90 days
```

### Step 5: Add to image-manifest.txt

```
docker.io/myorg/myimage:X.Y.Z  sentinel/myimage:X.Y.Z
```

### Step 6: Test locally before merging

```bash
# Dry run
./scripts/mirror-upstream-image.sh \
  docker.io/myorg/myimage:X.Y.Z \
  sentinel/myimage:X.Y.Z \
  --dry-run \
  --policy-file config/supply-chain/trust-policy.yaml

# Live test (requires Harbor login and Cosign key)
./scripts/mirror-upstream-image.sh \
  docker.io/myorg/myimage:X.Y.Z \
  sentinel/myimage:X.Y.Z \
  --policy-file config/supply-chain/trust-policy.yaml \
  --skip-resign  # omit to also test re-signing
```

### Step 7: Commit and open MR

Branch: `worker/SEC-NNN-add-<imagename>-trust`
Commit message: `[SEC-NNN] Add <imagename> to trust-policy (verified/exception)`
MR body: reference SEC-64, paste cosign verify output or exception rationale.

---

## 2. Verifying an Image Currently in Harbor

To verify that a specific image in Harbor carries our Cosign signature:

```bash
# Verify our re-signature on a Harbor image
cosign verify \
  --key /etc/harbor-cosign/cosign.key \
  harbor.208.haist.farm/sentinel/<image>:<tag>

# Verify by digest (preferred — tag-independent)
cosign verify \
  --key /etc/harbor-cosign/cosign.key \
  harbor.208.haist.farm/sentinel/<image>@<digest>

# Get the current digest of a tagged image
cosign triangulate harbor.208.haist.farm/sentinel/<image>:<tag>
# or
podman manifest inspect harbor.208.haist.farm/sentinel/<image>:<tag> | \
  python3 -c "import sys,json; m=json.load(sys.stdin); print(m.get('Digest',''))"
```

To check the cosign tree (shows all sig/attestation artifacts):

```bash
cosign tree harbor.208.haist.farm/sentinel/<image>:<tag>
```

---

## 3. Quarterly Exception List Review

**Due date:** Every 90 days from `review_date` in trust-policy.yaml.
**Current next review:** 2026-07-19

**Process:**

1. For each entry in `exceptions:` block, re-run `cosign tree`:

```bash
# On iac-control
for entry in postgres keycloak homepage busybox \
             hello-openshift newt jellyfin jaeger grafana k8s-sidecar \
             netbox valkey ntfy; do
  # Get source from policy
  source=$(python3 -c "
import yaml
with open('/opt/sentinel-iac/config/supply-chain/trust-policy.yaml') as f:
  p = yaml.safe_load(f)
print(p['exceptions']['${entry}']['source'])
" 2>/dev/null)
  echo "=== ${entry}: ${source} ==="
  cosign tree "${source}:latest" 2>&1 | tail -3
done
```

2. For any image where `cosign tree` now shows artifacts (previously returned nothing):
   - Test `cosign verify` to confirm the signing method
   - Add to `upstream_keys:` in trust-policy.yaml
   - Remove from `exceptions:`
   - Update `docs/supply-chain/upstream-image-inventory.md`
   - Open an MR referencing the quarterly review

3. For any image where `next_review_date` has passed without being reviewed:
   - This is a compliance finding — open a SEC issue

4. **Special priority — valkey (Bitnami):** Bitnami has `.sig` artifacts but uses a static
   key (not keyless). In each quarterly review, attempt to locate the Bitnami key URL and
   enable static-key verification.

5. Update `review_date` and `next_review_date` for all reviewed exceptions.

---

## 4. Responding to cosign verify Failure on a Previously Passing Image

**Symptom:** `harbor-sweep.service` fails. Log at `/var/log/harbor-sweep.log` shows:
```
[ERROR] Upstream signature verification FAILED for: docker.io/...
```

**Differential diagnosis:**

### 4a. Transient network error

```bash
# Retry manually
cosign verify --certificate-oidc-issuer=... --certificate-identity-regexp=... <image>
```

If it passes on retry: transient Rekor/Fulcio connectivity issue. Re-run the sweep.

### 4b. Upstream rotated their signing key

**Signs:** Old tags no longer verify; new tags (if any) verify with different identity.

**Action:**
1. Check upstream project's security advisories or release notes
2. If key rotation is announced and legitimate:
   - Update `certificate_identity_regexp` in trust-policy.yaml to match new identity
   - Verify the new identity against multiple recent tags
   - Open MR with rationale citing upstream announcement + link
3. If no announced rotation: treat as potential compromise — see 4c

### 4c. Potential upstream registry compromise

**Signs:** Signature is missing or invalid with no upstream announcement. Image digest
differs from what release notes document.

**Immediate actions:**
1. Do NOT mirror the image (leave current Harbor copy in place)
2. Open a `urgent` priority SEC issue with evidence
3. Check if existing Harbor copy of the image (previous digest) is safe:
   ```bash
   cosign verify --key /etc/harbor-cosign/cosign.key \
     harbor.208.haist.farm/sentinel/<image>:<tag>
   ```
   The Harbor copy carries our re-signature if mirrored correctly — but if it was
   mirrored BEFORE this runbook was in place, it may not have been upstream-verified.
4. If the Harbor copy is suspected compromised: coordinate with operator to quarantine
   (remove from Harbor or relabel) and rebuild dependent pods from a safe image

### 4d. Image policy entry out of date

**Signs:** Signature exists but `certificate_identity_regexp` does not match (e.g.,
the upstream moved their GitHub organization or workflow path).

**Action:**
1. Inspect the actual certificate: `cosign verify ... 2>&1 | python3 -m json.tool | grep Subject`
2. Update `certificate_identity_regexp` in trust-policy.yaml
3. Verify new pattern against the image: `cosign verify --certificate-identity-regexp=<new> ...`
4. Open MR documenting the change

---

## 5. Feature Flags

The mirror sweep has two feature flags in `/etc/harbor-sweep/env` (or set via systemd
drop-in override):

| Variable | Default | Effect |
|----------|---------|--------|
| `UPSTREAM_SIG_VERIFY_ENABLED` | `true` | Enable/disable upstream signature verification globally |
| `UPSTREAM_SIG_VERIFY_FALLTHROUGH` | `true` | If `true`, a sig verification failure falls through to mirror anyway (with warning); if `false`, fails hard |

**To disable verification globally (emergency only):**

```bash
# Create override
mkdir -p /etc/systemd/system/harbor-sweep.service.d
cat > /etc/systemd/system/harbor-sweep.service.d/override.conf <<EOF
[Service]
Environment=UPSTREAM_SIG_VERIFY_ENABLED=false
EOF
systemctl daemon-reload
systemctl start harbor-sweep.service
```

**Document this as an exception** — create a SEC issue with rationale and timeline.

**To harden (disable fallthrough — hard-fail on sig verification failure):**

```bash
cat > /etc/systemd/system/harbor-sweep.service.d/harden.conf <<EOF
[Service]
Environment=UPSTREAM_SIG_VERIFY_FALLTHROUGH=false
EOF
systemctl daemon-reload
```

---

## 6. Checking the Exception Audit Log

Every time a mirrored image uses an exception (no upstream sig), the use is logged:

```bash
cat /var/log/harbor-mirror-exceptions.log
```

Format: `TIMESTAMP EXCEPTION_USED upstream=<ref> policy_key=<key> rationale=<first-line>`

This log should be reviewed during quarterly reviews. Unexpected entries (an image that
should have been verified but hit the exception path) indicate a trust-policy misconfiguration.
