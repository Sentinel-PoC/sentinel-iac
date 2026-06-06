#!/usr/bin/env bash
# forgejo-update-branch.sh — Update a PR's head branch with style=merge (OPS-602)
#
# Always passes style=merge to /pulls/N/update, ensuring merge-commit semantics
# (preserves history and approvals). Never omit or change this parameter unless
# rebase is explicitly desired and the approval-dismissal consequence is accepted.
#
# Usage:
#   forgejo-update-branch.sh <host> <owner> <repo> <pr_number> <token>
#
# Example:
#   forgejo-update-branch.sh forgejo.208.haist.farm sentinel-admin sentinel-iac 198 "${FORGEJO_JUDGE_TOKEN}"
#
# Exit codes:
#   0  — HTTP 200 (update accepted)
#   1  — unexpected HTTP status (conflict, forbidden, etc.) or bad args
#
# Source reference: Forgejo v11.0.10 routers/api/v1/repo/pull.go:1309
#   rebase := ctx.FormString("style") == "rebase"
#   Omitting style defaults to merge on v11.0.10+, but explicit is required by SOP.

set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "Usage: $0 <host> <owner> <repo> <pr_number> <token>" >&2
  exit 1
fi

FORGEJO_HOST="$1"
FORGEJO_OWNER="$2"
FORGEJO_REPO="$3"
PR_NUMBER="$4"
FORGEJO_TOKEN="$5"

URL="https://${FORGEJO_HOST}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/pulls/${PR_NUMBER}/update?style=merge"

http_code=$(curl -s -o /tmp/forgejo-update-branch-resp.json -w "%{http_code}" \
  --request POST \
  --header "Authorization: token ${FORGEJO_TOKEN}" \
  "${URL}")

if [[ "${http_code}" == "200" ]]; then
  echo "OK: PR #${PR_NUMBER} branch updated (style=merge, HTTP 200)"
  exit 0
else
  echo "ERROR: HTTP ${http_code} from ${URL}" >&2
  cat /tmp/forgejo-update-branch-resp.json >&2
  exit 1
fi
