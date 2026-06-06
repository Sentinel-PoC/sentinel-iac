#!/usr/bin/env bash
# ansible-drift-remediate.sh — pull sentinel-iac main and apply Ansible roles on iac-control.
# OPS-476 (root cause: PR #149 vault-autounseal-rotate.sh fix sat in main 4 days without deploy)
#
# Runs daily at 08:30 UTC on iac-control (as ubuntu, via ansible-drift-remediate.timer).
# Pulls /home/ubuntu/sentinel-repo to HEAD then runs the iac-control playbook with
# safe tags that cover platform-timers and common configuration.
#
# USAGE:
#   ansible-drift-remediate.sh            # pull + apply
#   ansible-drift-remediate.sh --dry-run  # pull + ansible --check (no changes applied)
#   ansible-drift-remediate.sh --pull-only # git pull only, no playbook run
#
# TAGS APPLIED: platform-timers,common
#   platform-timers — deploys scripts + unit files (vault-autounseal-rotate.sh, etc.)
#   common          — packages, sshd hardening, ubuntu admin user
#   These tags are safe to run self-hosted: they do not touch netplan, UFW,
#   keepalived, or vault-unseal-transit (which requires /etc/vault-unseal/transit.key).
#
# EXIT CODES:
#   0  — pull + apply succeeded (or --dry-run completed)
#   1  — git pull failed (uncommitted local changes or network error)
#   2  — ansible-playbook failed
#   3  — sentinel-repo directory missing / not a git repo

set -euo pipefail

# --- Configuration ---
SENTINEL_REPO="/home/ubuntu/sentinel-repo"
ANSIBLE_PLAYBOOK="${SENTINEL_REPO}/ansible/playbooks/iac-control.yml"
ANSIBLE_INVENTORY="${SENTINEL_REPO}/ansible/inventory/hosts.yml"
LOG_DIR="/var/log/sentinel"
LOG_FILE="${LOG_DIR}/ansible-drift-remediate.log"
APPLY_TAGS="platform-timers,common"

DRY_RUN=false
PULL_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=true ;;
        --pull-only) PULL_ONLY=true ;;
    esac
done

# --- Helpers ---
log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Maintenance Mode Check ---
LIB_PATH="/home/ubuntu/scripts/_sentinel-lib.sh"
if [ -f "$LIB_PATH" ]; then
    # shellcheck source=/dev/null
    source "$LIB_PATH"
    if check_maintenance "all" 2>/dev/null; then
        log "ansible-drift-remediate: maintenance mode active (scope=all) — skipping"
        exit 0
    fi
fi

# --- Setup ---
mkdir -p "$LOG_DIR" 2>/dev/null || true
log "=== ansible-drift-remediate starting ==="
log "Mode: $([ "$DRY_RUN" = true ] && echo dry-run || [ "$PULL_ONLY" = true ] && echo pull-only || echo apply)"

# --- Preflight: verify sentinel-repo ---
if [ ! -d "${SENTINEL_REPO}/.git" ]; then
    log "ERROR: ${SENTINEL_REPO} is not a git repository — cannot pull"
    exit 3
fi

# --- Preflight: check for uncommitted local changes ---
cd "$SENTINEL_REPO"
if ! git diff --quiet HEAD 2>/dev/null; then
    log "WARNING: ${SENTINEL_REPO} has uncommitted local changes — skipping pull to avoid clobber"
    log "  Run 'git status' in ${SENTINEL_REPO} to inspect, then commit or stash before next run"
    exit 1
fi

# --- Git Pull ---
log "Pulling sentinel-iac main from origin..."
BEFORE_SHA=$(git rev-parse HEAD)
git fetch origin main 2>&1 | while read -r line; do log "  git: $line"; done

ORIGIN_SHA=$(git rev-parse origin/main)
if [ "$BEFORE_SHA" = "$ORIGIN_SHA" ]; then
    log "Already at HEAD ($BEFORE_SHA) — no new commits to apply"
    if [ "$PULL_ONLY" = true ] || [ "$DRY_RUN" = false ]; then
        log "No changes — nothing to apply"
        log "=== ansible-drift-remediate done (no-op) ==="
        exit 0
    fi
fi

git merge --ff-only origin/main 2>&1 | while read -r line; do log "  git: $line"; done
AFTER_SHA=$(git rev-parse HEAD)
log "Pulled: ${BEFORE_SHA:0:12} -> ${AFTER_SHA:0:12}"

if [ "$PULL_ONLY" = true ]; then
    log "Pull-only mode — not running ansible-playbook"
    log "=== ansible-drift-remediate done (pull-only) ==="
    exit 0
fi

# --- Ansible Apply ---
ANSIBLE_CMD=(
    ansible-playbook
    --limit iac-control
    --tags "${APPLY_TAGS}"
    --inventory "${ANSIBLE_INVENTORY}"
    "${ANSIBLE_PLAYBOOK}"
)
if [ "$DRY_RUN" = true ]; then
    ANSIBLE_CMD+=(--check --diff)
    log "DRY RUN: ${ANSIBLE_CMD[*]}"
else
    log "Applying: ${ANSIBLE_CMD[*]}"
fi

export ANSIBLE_HOST_KEY_CHECKING=False
export ANSIBLE_STDOUT_CALLBACK=default

if "${ANSIBLE_CMD[@]}" 2>&1 | while read -r line; do log "  ansible: $line"; done; then
    log "ansible-playbook succeeded"
else
    RC=${PIPESTATUS[0]}
    log "ERROR: ansible-playbook exited $RC"
    exit 2
fi

log "=== ansible-drift-remediate done ==="
