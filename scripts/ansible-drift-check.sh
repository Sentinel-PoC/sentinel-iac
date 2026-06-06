#!/usr/bin/env bash
# ansible-drift-check.sh — report whether sentinel-iac main has undeployed commits on iac-control.
# OPS-476 (root cause: PR #149 vault-autounseal-rotate.sh fix sat in main 4 days without deploy)
#
# Runs daily at 08:00 UTC on iac-control (as ubuntu, via ansible-drift-check.timer).
# Does NOT modify the system — reports drift to the journal and log file only.
# The remediate timer at 08:30 UTC acts on what this check finds.
#
# EXIT CODES:
#   0  — local HEAD matches origin/main (no drift)
#   1  — local HEAD is behind origin/main (drift detected)
#   2  — git fetch failed (network error)
#   3  — sentinel-repo directory missing / not a git repo

set -euo pipefail

# --- Configuration ---
SENTINEL_REPO="/home/ubuntu/sentinel-repo"
LOG_DIR="/var/log/sentinel"
LOG_FILE="${LOG_DIR}/ansible-drift-check.log"

# --- Helpers ---
log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Setup ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log "=== ansible-drift-check starting ==="

# --- Preflight: verify sentinel-repo ---
if [ ! -d "${SENTINEL_REPO}/.git" ]; then
    log "ERROR: ${SENTINEL_REPO} is not a git repository — cannot check drift"
    exit 3
fi

cd "$SENTINEL_REPO"
LOCAL_SHA=$(git rev-parse HEAD)

# --- Fetch origin/main ---
log "Fetching origin/main..."
if ! git fetch origin main 2>&1 | while read -r line; do log "  git: $line"; done; then
    log "ERROR: git fetch failed — check network connectivity and Forgejo access"
    exit 2
fi

ORIGIN_SHA=$(git rev-parse origin/main)

if [ "$LOCAL_SHA" = "$ORIGIN_SHA" ]; then
    log "DRIFT: none — local HEAD matches origin/main (${LOCAL_SHA:0:12})"
    log "=== ansible-drift-check done (clean) ==="
    exit 0
fi

# Count commits behind
COMMITS_BEHIND=$(git rev-list --count HEAD..origin/main)
log "DRIFT DETECTED: local is ${COMMITS_BEHIND} commit(s) behind origin/main"
log "  Local:  ${LOCAL_SHA:0:12}"
log "  Origin: ${ORIGIN_SHA:0:12}"

# Log commit summary
log "Undeployed commits:"
git log --oneline HEAD..origin/main | while read -r line; do log "  $line"; done

# Check for uncommitted local changes that would block auto-apply
if ! git diff --quiet HEAD 2>/dev/null; then
    log "WARNING: local uncommitted changes detected — ansible-drift-remediate will skip pull"
fi

log "=== ansible-drift-check done (DRIFT: ${COMMITS_BEHIND} commits behind) ==="
exit 1
