#!/usr/bin/env bash
# [OPS-201] forgejo-branch-protection.sh
# Idempotent: enforce branch protection on main across all sentinel repos.
#
# Usage:
#   FG_TOKEN=<token> ./scripts/forgejo-branch-protection.sh [--dry-run]
#
# Environment:
#   FG_TOKEN   Forgejo API token (required)
#   FG_HOST    Forgejo host (default: 192.168.12.70:3000)
#   FG_OWNER   Repo owner (default: sentinel-admin)
#
# Behavior:
#   - For repos with an existing 'main' protection rule: PATCH (update in place)
#   - For repos with no protection rule (claude-config): POST (create)
#   - Preserves protected_file_patterns=CLAUDE.md on all repos
#   - Security CI checks are required; lint/build checks are not (see OPS-201)
#   - See forgejo-branch-protection.md for exception list and reasoning
#
# Exit codes:
#   0 — all repos configured successfully (or dry-run)
#   1 — one or more repos failed

set -euo pipefail

FG_HOST="${FG_HOST:-192.168.12.70:3000}"
FG_OWNER="${FG_OWNER:-sentinel-admin}"
DRY_RUN=false
FAIL_COUNT=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  echo "[DRY-RUN] No API calls will be made"
fi

if [ -z "${FG_TOKEN:-}" ]; then
  echo "ERROR: FG_TOKEN is required"
  exit 1
fi

API_BASE="http://${FG_HOST}/api/v1"

# ────────────────────────────────────────────────────────────
# Per-repo configuration
# Keys: repo name
# Values:
#   enable_status_check  — true/false
#   status_check_contexts — space-separated list (empty = none)
#   enable_push_whitelist — true/false (sentinel-admin in whitelist when true)
#   note — reason for any non-default setting
# ────────────────────────────────────────────────────────────

declare -A REPO_STATUS_CHECK
declare -A REPO_STATUS_CONTEXTS
declare -A REPO_PUSH_WHITELIST
declare -A REPO_NOTE

# sentinel-iac: full security suite from security-scan.yml
# supply-chain-scan (if: false) and shellcheck (continue-on-error) excluded
REPO_STATUS_CHECK["sentinel-iac"]="true"
REPO_STATUS_CONTEXTS["sentinel-iac"]="gitleaks trivy-iac trivy-config trivy-vuln trivy-image checkov"
REPO_PUSH_WHITELIST["sentinel-iac"]="false"
REPO_NOTE["sentinel-iac"]="Full security scanner suite from security-scan.yml"

# overwatch-gitops: security jobs from lint.yml + judge-verify from judge-verify.yml
# EXCEPTION: push whitelist includes sentinel-admin — CI bot in overwatch-console
# and haists-website pushes image tags directly to overwatch-gitops main via GITOPS_TOKEN.
# Without this, buildah push → image-tag update → git push origin main breaks.
REPO_STATUS_CHECK["overwatch-gitops"]="true"
REPO_STATUS_CONTEXTS["overwatch-gitops"]="gitleaks trivy-config judge-verify"
REPO_PUSH_WHITELIST["overwatch-gitops"]="true"
REPO_NOTE["overwatch-gitops"]="push_whitelist=[sentinel-admin]: CI bot (GITOPS_TOKEN) pushes image tags from overwatch-console/haists-website build.yml"

# overwatch-console: gitleaks from build.yml (build-and-push is a build job, not a security gate)
REPO_STATUS_CHECK["overwatch-console"]="true"
REPO_STATUS_CONTEXTS["overwatch-console"]="gitleaks"
REPO_PUSH_WHITELIST["overwatch-console"]="false"
REPO_NOTE["overwatch-console"]=""

# haists-website: gitleaks from build.yml
REPO_STATUS_CHECK["haists-website"]="true"
REPO_STATUS_CONTEXTS["haists-website"]="gitleaks"
REPO_PUSH_WHITELIST["haists-website"]="false"
REPO_NOTE["haists-website"]=""

# overwatch: security jobs from lint.yml
REPO_STATUS_CHECK["overwatch"]="true"
REPO_STATUS_CONTEXTS["overwatch"]="gitleaks trivy-iac"
REPO_PUSH_WHITELIST["overwatch"]="false"
REPO_NOTE["overwatch"]=""

# compliance-vault: no .forgejo/workflows — status checks cannot be required
# (requiring a check that never runs bricks the merge path indefinitely)
REPO_STATUS_CHECK["compliance-vault"]="false"
REPO_STATUS_CONTEXTS["compliance-vault"]=""
REPO_PUSH_WHITELIST["compliance-vault"]="false"
REPO_NOTE["compliance-vault"]="No CI workflows — status checks disabled. Add workflow to enable."

# sentinel-cache: no .forgejo/workflows
REPO_STATUS_CHECK["sentinel-cache"]="false"
REPO_STATUS_CONTEXTS["sentinel-cache"]=""
REPO_PUSH_WHITELIST["sentinel-cache"]="false"
REPO_NOTE["sentinel-cache"]="No CI workflows — status checks disabled."

# claude-config: no .forgejo/workflows, AND no existing protection rule (needs POST not PATCH)
REPO_STATUS_CHECK["claude-config"]="false"
REPO_STATUS_CONTEXTS["claude-config"]=""
REPO_PUSH_WHITELIST["claude-config"]="false"
REPO_NOTE["claude-config"]="No CI workflows — status checks disabled. No existing rule — will POST."

# Ordered list for deterministic output
REPOS=(
  sentinel-iac
  overwatch-gitops
  overwatch-console
  haists-website
  overwatch
  compliance-vault
  sentinel-cache
  claude-config
)

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────

check_existing_rule() {
  local repo="$1"
  curl -sf -u "sentinel-admin:${FG_TOKEN}" \
    "${API_BASE}/repos/${FG_OWNER}/${repo}/branch_protections" \
    2>/dev/null | python3 -c "
import json, sys
rules = json.load(sys.stdin)
for r in rules:
    if r.get('branch_name') == 'main':
        print('exists')
        sys.exit(0)
print('absent')
" 2>/dev/null || echo "absent"
}

build_payload() {
  local repo="$1"
  local enable_status="${REPO_STATUS_CHECK[$repo]}"
  local contexts="${REPO_STATUS_CONTEXTS[$repo]}"
  local push_whitelist="${REPO_PUSH_WHITELIST[$repo]}"

  python3 - <<PYEOF
import json

enable_status = "${enable_status}" == "true"
push_whitelist = "${push_whitelist}" == "true"
contexts_str = "${contexts}".strip()
ctx_list = contexts_str.split() if contexts_str else []

payload = {
    "branch_name": "main",
    "rule_name": "main",
    "enable_push": True,
    "enable_push_whitelist": push_whitelist,
    "push_whitelist_usernames": ["sentinel-admin"] if push_whitelist else [],
    "push_whitelist_deploy_keys": False,
    "enable_merge_whitelist": False,
    "merge_whitelist_usernames": [],
    "enable_status_check": enable_status,
    "status_check_contexts": ctx_list,
    "required_approvals": 1,
    "enable_approvals_whitelist": False,
    "approvals_whitelist_username": [],
    "block_on_rejected_reviews": False,
    # OPS-302: False — Judge approval IS the operator review; blocking on the
    # koiakoia review-request that auto-attaches at PR open is pure friction
    # with no security value. sentinel-judge posts APPROVED → merge proceeds.
    "block_on_official_review_requests": False,
    "block_on_outdated_branch": True,
    "dismiss_stale_approvals": True,
    "ignore_stale_approvals": False,
    "require_signed_commits": False,
    "protected_file_patterns": "CLAUDE.md",
    "unprotected_file_patterns": "",
    "apply_to_admins": False,
}
print(json.dumps(payload))
PYEOF
}

configure_repo() {
  local repo="$1"
  echo ""
  echo "── ${repo} ──────────────────────────────────"
  if [ -n "${REPO_NOTE[$repo]}" ]; then
    echo "   NOTE: ${REPO_NOTE[$repo]}"
  fi

  local existing
  existing=$(check_existing_rule "$repo")
  echo "   Rule status: ${existing}"

  local payload
  payload=$(build_payload "$repo")
  echo "   Payload: $(echo "$payload" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'required_approvals={d[\"required_approvals\"]} enable_status_check={d[\"enable_status_check\"]} contexts={d[\"status_check_contexts\"]} push_whitelist={d[\"push_whitelist_usernames\"]}')")"

  if $DRY_RUN; then
    echo "   [DRY-RUN] Would $([ "$existing" = "exists" ] && echo PATCH || echo POST)"
    return 0
  fi

  local http_code
  if [ "$existing" = "exists" ]; then
    http_code=$(curl -s -o /tmp/fg_resp.json \
      -w "%{http_code}" \
      -X PATCH \
      -u "sentinel-admin:${FG_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${API_BASE}/repos/${FG_OWNER}/${repo}/branch_protections/main")
  else
    http_code=$(curl -s -o /tmp/fg_resp.json \
      -w "%{http_code}" \
      -X POST \
      -u "sentinel-admin:${FG_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${API_BASE}/repos/${FG_OWNER}/${repo}/branch_protections")
  fi

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "   ✓ HTTP ${http_code} — OK"
  else
    echo "   ✗ HTTP ${http_code} — FAILED"
    echo "   Response: $(cat /tmp/fg_resp.json 2>/dev/null || echo '(empty)')"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────

echo "[OPS-201] Forgejo branch protection configuration"
echo "Host: ${FG_HOST}  Owner: ${FG_OWNER}  Dry-run: ${DRY_RUN}"
echo "Repos: ${REPOS[*]}"

for repo in "${REPOS[@]}"; do
  configure_repo "$repo"
done

echo ""
echo "──────────────────────────────────────────────"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL — ${FAIL_COUNT} repo(s) failed"
  exit 1
else
  echo "RESULT: OK — all ${#REPOS[@]} repos configured"
  exit 0
fi
