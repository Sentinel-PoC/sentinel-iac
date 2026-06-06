#!/usr/bin/env bash
# harbor-to-mirror-sync.sh — Sync Harbor sentinel images to mirror-registry-01
#
# OPS-624: Mirror-registry VM 215 was empty; this script populates it.
# Deployed to: /usr/local/bin/harbor-to-mirror-sync.sh
# Managed by: Ansible (iac-control role, platform-timers.yml) — OPS-624
# Timer: harbor-mirror-sync.timer (daily 04:00 UTC)
#
# Direction: harbor.208.haist.farm/sentinel → mirror.208.haist.farm:8443/sentinel
# Scope: ALL repositories in the Harbor sentinel project (all tags, all platforms).
# Cosign signatures are stored as sha256-<digest>.sig tags and are copied by
# skopeo sync --all automatically — no separate signature copy step needed.
#
# Auth (out-of-band, operator-managed, NOT Ansible-deployed):
#   /etc/harbor-mirror-sync/env (mode 0400 root:root) must contain:
#     HARBOR_ROBOT_PASSWORD  — password for robot$ci-system (Harbor pull scope)
#     MIRROR_ADMIN_PASSWORD  — password for mirror-registry admin user
#
# Logs: /var/log/harbor-mirror-sync.log (appended each run)
#
# NOTE: First sync will take significant time (~45 repos, multi-GB total).
# Subsequent syncs are incremental (skopeo skips already-synced digests).

set -euo pipefail

ENV_FILE="${ENV_FILE:-/etc/harbor-mirror-sync/env}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.208.haist.farm}"
HARBOR_PROJECT="${HARBOR_PROJECT:-sentinel}"
HARBOR_ROBOT_USER="${HARBOR_ROBOT_USER:-robot\$ci-system}"
MIRROR_REGISTRY="${MIRROR_REGISTRY:-mirror.208.haist.farm:8443}"
MIRROR_ADMIN_USER="${MIRROR_ADMIN_USER:-admin}"
LOG_FILE="/var/log/harbor-mirror-sync.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()      { echo -e "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"; }
log_ok()   { log "${GREEN}[OK]${NC}    $*"; }
log_warn() { log "${YELLOW}[WARN]${NC}  $*"; }
log_err()  { log "${RED}[ERROR]${NC} $*"; }

# ---- Preflight ---------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
    log_err "Env file not found: $ENV_FILE"
    log_err "Deploy it out-of-band (mode 0400 root:root) with:"
    log_err "  HARBOR_ROBOT_PASSWORD=<robot\$ci-system password>"
    log_err "  MIRROR_ADMIN_PASSWORD=<mirror admin password>"
    exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${HARBOR_ROBOT_PASSWORD:-}" ]]; then
    log_err "HARBOR_ROBOT_PASSWORD not set in $ENV_FILE"
    exit 1
fi
if [[ -z "${MIRROR_ADMIN_PASSWORD:-}" ]]; then
    log_err "MIRROR_ADMIN_PASSWORD not set in $ENV_FILE"
    exit 1
fi

if ! command -v skopeo &>/dev/null; then
    log_err "skopeo not found in PATH — install it: apt install skopeo (or dnf install skopeo)"
    exit 1
fi

if ! command -v curl &>/dev/null; then
    log_err "curl not found in PATH"
    exit 1
fi

# ---- Fetch repo list from Harbor API ----------------------------------------

log "=== Harbor→mirror sync START: $TIMESTAMP ==="
log "Source: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}  →  Dest: ${MIRROR_REGISTRY}"

REPOS=$(curl -sf \
    --max-time 30 \
    -u "${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASSWORD}" \
    "https://${HARBOR_REGISTRY}/api/v2.0/projects/${HARBOR_PROJECT}/repositories?page_size=100" \
    | python3 -c "
import sys, json
repos = json.load(sys.stdin)
for r in repos:
    # name is 'sentinel/repo-name' — extract just 'repo-name'
    name = r.get('name', '').split('/')[-1]
    if name:
        print(name)
" 2>&1) || {
    log_err "Failed to fetch repository list from Harbor API"
    exit 1
}

REPO_COUNT=$(echo "$REPOS" | grep -c . || true)
log "Found ${REPO_COUNT} repositories in ${HARBOR_PROJECT} project"

if [[ $REPO_COUNT -eq 0 ]]; then
    log_warn "No repositories found — nothing to sync"
    exit 0
fi

# ---- Sync each repository ---------------------------------------------------

total=0
success=0
failed=0

while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    ((total++)) || true

    SRC="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${repo}"
    log "--- [$total/${REPO_COUNT}] Syncing ${SRC}"

    exit_code=0
    skopeo sync \
        --src docker \
        --dest docker \
        --src-creds "${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_PASSWORD}" \
        --dest-creds "${MIRROR_ADMIN_USER}:${MIRROR_ADMIN_PASSWORD}" \
        --src-tls-verify=true \
        --dest-tls-verify=true \
        --all \
        "${SRC}" \
        "${MIRROR_REGISTRY}" \
        < /dev/null 2>&1 | tee -a "$LOG_FILE" || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_ok "Synced: ${SRC} → ${MIRROR_REGISTRY}/${HARBOR_PROJECT}/${repo}"
        ((success++)) || true
    else
        log_err "Failed to sync ${SRC} (exit ${exit_code}) — continuing with remaining repos"
        ((failed++)) || true
    fi

done <<< "$REPOS"

# ---- Summary ----------------------------------------------------------------

log ""
log "=== Harbor→mirror sync COMPLETE: $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
log "Results: ${success} synced, ${failed} failed, ${total} total"

if [[ $failed -gt 0 ]]; then
    log_err "${failed} repo(s) failed to sync — review ${LOG_FILE}"
    exit 1
fi
