# Forgejo Branch Protection — OPS-201

## Purpose

Idempotent enforcement of `main` branch protection across all sentinel repos.
Prevents direct pushes of unreviewed or security-scan-failing code to main,
which ArgoCD would then deploy.

**Plane issue:** OPS-201 — [OPS-200/Gap5] Enforce branch protection on main across all sentinel repos

## Quick start

```bash
FG_TOKEN=$(vault kv get -field=token secret/forgejo/admin-token) \
  ./scripts/forgejo-branch-protection.sh
```

Dry-run (no API calls, shows what would happen):

```bash
FG_TOKEN=<token> ./scripts/forgejo-branch-protection.sh --dry-run
```

## What the script enforces

For every repo in scope:

| Setting | Value | Reason |
|---------|-------|--------|
| `required_approvals` | 1 | Operator review of agent MRs (CLAUDE.md §8: "You do not merge your own MRs") |
| `enable_status_check` | true (where CI exists) | Security scans must pass before merge |
| `dismiss_stale_approvals` | true | Re-review required if PR is updated after approval |
| `block_on_outdated_branch` | true | PR must be rebased onto latest main before merge |
| `block_on_official_review_requests` | true | Requested-review dismissal does not bypass protection |
| `protected_file_patterns` | `CLAUDE.md` | CLAUDE.md requires explicit operator authorization to modify (CLAUDE.md §10) |
| `require_signed_commits` | false | Lab does not yet enforce signed commits (separate issue if desired) |

## Per-repo status check contexts (security-only)

Only security-relevant CI jobs are required. Lint, build, and test jobs are
advisory only — this avoids bricking the merge path on transient flakes.

| Repo | Required checks | Source workflow |
|------|----------------|-----------------|
| sentinel-iac | `gitleaks`, `trivy-iac`, `trivy-config`, `trivy-vuln`, `trivy-image`, `checkov` | security-scan.yml |
| overwatch-gitops | `gitleaks`, `trivy-config`, `judge-verify` | lint.yml, judge-verify.yml |
| overwatch-console | `gitleaks` | build.yml |
| haists-website | `gitleaks` | build.yml |
| overwatch | `gitleaks`, `trivy-iac` | lint.yml |
| compliance-vault | _(none — see Exception 2)_ | — |
| sentinel-cache | _(none — see Exception 2)_ | — |
| claude-config | _(none — see Exception 2)_ | — |

**Jobs intentionally excluded from required list:**

- `shellcheck` (sentinel-iac) — has `continue-on-error: true`; blocking on it adds friction without blocking merges currently
- `supply-chain-scan` (sentinel-iac) — has `if: ${{ false }}`; never runs; cannot be required
- `build-and-push` (overwatch-console, haists-website) — build/deploy job, not a security gate
- `yamllint`, `ansible-lint`, `tflint` (various) — lint jobs; non-required to reduce friction

## Exception list

### Exception 1 — Push whitelist on overwatch-gitops

**Repos affected:** `overwatch-gitops`

**Setting:** `enable_push_whitelist: true`, `push_whitelist_usernames: ["sentinel-admin"]`

**Reason:** The `build.yml` workflows in `overwatch-console` and `haists-website` push
image tag updates directly to `overwatch-gitops/main` using the `GITOPS_TOKEN` credential
(which is the `sentinel-admin` account). This is the standard GitOps promotion pattern:

```
build.yml (overwatch-console) ──buildah push──► Harbor
                               ──git push──────► overwatch-gitops/apps/overwatch-console/deployment.yaml
```

Without this exception, every CI-triggered image promotion would fail with a branch
protection rejection. This would break the automated deployment pipeline.

**Audit trail:** All CI-triggered pushes are visible in the overwatch-gitops commit log
as `[ci] Update sentinel/overwatch-console to <sha>` commits.

**Mitigation:** The GITOPS_TOKEN is scoped to the CI bot account; no human uses it for
direct pushes. All human changes to overwatch-gitops go through MRs.

### Exception 2 — Status checks disabled for no-workflow repos

**Repos affected:** `compliance-vault`, `sentinel-cache`, `claude-config`

**Setting:** `enable_status_check: false`

**Reason:** These repos have no `.forgejo/workflows/` directory. If we set
`enable_status_check: true` with a non-empty `status_check_contexts` list, Forgejo
will require a check that never runs — permanently blocking all MR merges.

**Action to re-enable:** Add a minimal security workflow to each repo (e.g., gitleaks scan)
then re-run this script to update the protection rule.

Suggested minimal workflow for these repos:

```yaml
# .forgejo/workflows/security-scan.yml
---
name: Security Scan
on:
  push:
    branches: [main]
  pull_request:
jobs:
  gitleaks:
    runs-on: iac
    steps:
      - uses: actions/checkout@v4
      - name: Gitleaks secret detection
        run: gitleaks detect --source . --report-format json --report-path gitleaks-report.json --no-git
```

File child issues against the appropriate repos; add `gitleaks` to
`status_check_contexts` for each repo once the workflow lands.

## Acceptance criteria verification

Run after script to confirm all repos are correctly configured:

```bash
FG_TOKEN=<token>
FG_HOST=192.168.12.70:3000

for repo in sentinel-iac overwatch-gitops overwatch-console haists-website overwatch; do
  echo -n "${repo}: "
  curl -s -u "sentinel-admin:${FG_TOKEN}" \
    "http://${FG_HOST}/api/v1/repos/sentinel-admin/${repo}/branch_protections" \
    | jq -r '.[] | select(.branch_name=="main")
        | "approvals=\(.required_approvals) status_check=\(.enable_status_check) contexts=\(.status_check_contexts | length) stale_dismiss=\(.dismiss_stale_approvals)"'
done

# Repos without CI (status check disabled by design):
for repo in compliance-vault sentinel-cache claude-config; do
  echo -n "${repo}: "
  curl -s -u "sentinel-admin:${FG_TOKEN}" \
    "http://${FG_HOST}/api/v1/repos/sentinel-admin/${repo}/branch_protections" \
    | jq -r '.[] | select(.branch_name=="main")
        | "approvals=\(.required_approvals) status_check=\(.enable_status_check) stale_dismiss=\(.dismiss_stale_approvals)"'
done
```

Expected output for CI repos: `approvals=1 status_check=true contexts>0 stale_dismiss=true`
Expected output for no-CI repos: `approvals=1 status_check=false stale_dismiss=true`

## Re-running the script

The script is fully idempotent — re-running after adding new CI workflows to a
repo will pick up the latest job names automatically (update `REPO_STATUS_CONTEXTS`
in the script first).

Safe to run from any workstation with `FG_TOKEN` in environment.
Does not modify any files in any repo.

## Open MRs and rebase friction (operator action)

**IMPORTANT:** Once this script runs and status checks are required, any open MRs
in sentinel repos that were created before the security scans last passed will be
blocked from merging until they rebase onto a commit where all required checks pass.

**Operator options:**
1. Drain existing open MRs before running the script (recommended)
2. Run the script, then rebase each blocked MR
3. Run the script after all critical MRs are merged

The script does not affect currently-open MRs — it only gates new merge attempts.
