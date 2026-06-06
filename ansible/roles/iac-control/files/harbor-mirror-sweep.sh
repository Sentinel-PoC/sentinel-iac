#!/usr/bin/env bash
# harbor-mirror-sweep.sh — Harbor mirror sweep with upstream Cosign verification
#
# Deployed to: /usr/local/bin/harbor-mirror-sweep.sh
# Managed by: Ansible (iac-control role) — SEC-64
# Timer: harbor-sweep.timer (daily 03:00 UTC)
#
# Reads: /etc/harbor-sweep/image-manifest.txt (deployed by ansible)
# Calls: /usr/local/bin/mirror-upstream-image.sh for each entry (deployed by ansible)
# Policy: /etc/harbor-sweep/trust-policy.yaml (deployed by ansible)
#
# Logs: /var/log/harbor-sweep.log (appended)
#       /var/log/harbor-mirror-exceptions.log (exception uses)
#
# All three file paths match where the iac-control ansible role actually
# deploys them. Env overrides still supported via /etc/harbor-sweep/env for
# operator break-glass (e.g., testing a manifest outside /etc).

set -euo pipefail

MANIFEST="${MANIFEST:-/etc/harbor-sweep/image-manifest.txt}"
MIRROR_SCRIPT="${MIRROR_SCRIPT:-/usr/local/bin/mirror-upstream-image.sh}"
POLICY_FILE="${POLICY_FILE:-/etc/harbor-sweep/trust-policy.yaml}"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.208.haist.farm}"
UPSTREAM_SIG_VERIFY_ENABLED="${UPSTREAM_SIG_VERIFY_ENABLED:-true}"
# Feature flag: if true, fall through to mirror even when upstream verification fails.
# DEFAULT IS FALSE (fail-closed, NIST SR-11): a provenance-verification failure is
# alarm-level — a silent upstream compromise would fly through if this were true.
# Operator can override to true via /etc/harbor-sweep/env for a specific window
# (e.g., upstream key rotation) but must revert once resolved.
UPSTREAM_SIG_VERIFY_FALLTHROUGH="${UPSTREAM_SIG_VERIFY_FALLTHROUGH:-false}"
LOG_FILE="/var/log/harbor-sweep.log"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()      { echo -e "[$TIMESTAMP] $*" | tee -a "$LOG_FILE"; }
log_ok()   { log "${GREEN}[OK]${NC}    $*"; }
log_warn() { log "${YELLOW}[WARN]${NC}  $*"; }
log_err()  { log "${RED}[ERROR]${NC} $*"; }

check_prerequisites() {
    if [[ ! -f "$MANIFEST" ]]; then
        log_err "Manifest not found: $MANIFEST"
        exit 1
    fi
    if [[ ! -x "$MIRROR_SCRIPT" ]]; then
        log_err "Mirror script not found or not executable: $MIRROR_SCRIPT"
        exit 1
    fi
    if [[ ! -f "$POLICY_FILE" ]]; then
        log_warn "Trust policy not found: $POLICY_FILE — UPSTREAM_SIG_VERIFY_ENABLED forced to false"
        UPSTREAM_SIG_VERIFY_ENABLED=false
    fi
    if ! podman login --get-login "$HARBOR_REGISTRY" &>/dev/null; then
        log_err "Not logged into Harbor: $HARBOR_REGISTRY"
        exit 1
    fi
}

main() {
    log "=== Harbor mirror sweep START: $TIMESTAMP ==="
    log "UPSTREAM_SIG_VERIFY_ENABLED=${UPSTREAM_SIG_VERIFY_ENABLED}"
    log "UPSTREAM_SIG_VERIFY_FALLTHROUGH=${UPSTREAM_SIG_VERIFY_FALLTHROUGH}"

    check_prerequisites

    local total=0 success=0 failed=0 skipped=0

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local source target
        source="$(echo "$line" | awk '{print $1}')"
        target="$(echo "$line" | awk '{print $2}')"

        if [[ -z "$source" || -z "$target" ]]; then
            log_warn "Skipping malformed line: $line"
            ((skipped++)) || true
            continue
        fi

        ((total++)) || true
        log "--- [$total] ${source} -> ${target}"

        # Run mirror-upstream-image.sh which handles sig verification internally.
        # stdin redirected from /dev/null so interactive prompts inside cosign
        # (or any child process) don't consume the manifest file we're iterating.
        local exit_code=0
        UPSTREAM_SIG_VERIFY_ENABLED="${UPSTREAM_SIG_VERIFY_ENABLED}" \
        LOG_EXCEPTION_FILE="/var/log/harbor-mirror-exceptions.log" \
        HARBOR_REGISTRY="${HARBOR_REGISTRY}" \
            "${MIRROR_SCRIPT}" "${source}" "${target}" \
            --policy-file "${POLICY_FILE}" < /dev/null 2>&1 | tee -a "$LOG_FILE" || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            log_ok "Mirrored: ${source} -> ${HARBOR_REGISTRY}/${target}"
            ((success++)) || true
        elif [[ $exit_code -eq 2 && "${UPSTREAM_SIG_VERIFY_FALLTHROUGH}" == "true" ]]; then
            # Exit code 2 = upstream sig verification failed but fallthrough is enabled
            log_warn "Upstream sig verification failed for ${source} — FALLTHROUGH enabled, mirroring anyway"
            log_warn "This is the fallthrough behavior (SEC-64 feature flag). Review and fix trust-policy."
            # Re-run without upstream verification for this image only
            # (same stdin redirection reason as primary invocation above)
            UPSTREAM_SIG_VERIFY_ENABLED=false \
            LOG_EXCEPTION_FILE="/var/log/harbor-mirror-exceptions.log" \
            HARBOR_REGISTRY="${HARBOR_REGISTRY}" \
                "${MIRROR_SCRIPT}" "${source}" "${target}" \
                --policy-file "${POLICY_FILE}" < /dev/null 2>&1 | tee -a "$LOG_FILE" || true
            ((skipped++)) || true
        else
            log_err "Failed to mirror: ${source} (exit ${exit_code})"
            ((failed++)) || true
        fi

    done < "$MANIFEST"

    log ""
    log "=== Harbor mirror sweep COMPLETE: $(date -u +"%Y-%m-%dT%H:%M:%SZ") ==="
    log "Results: ${success} success, ${failed} failed, ${skipped} skipped, ${total} total"

    if [[ $failed -gt 0 ]]; then
        log_err "${failed} image(s) failed to mirror — review ${LOG_FILE}"
        exit 1
    fi
}

main "$@"
