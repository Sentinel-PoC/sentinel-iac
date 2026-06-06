#!/usr/bin/env bash
# mirror-upstream-image.sh — Mirror upstream image to Harbor with upstream Cosign verification
#
# SEC-64: Verifies upstream Cosign signature BEFORE re-signing with our key.
# For images on the documented exception list, proceeds with warning and logs exception use.
#
# Usage:
#   ./mirror-upstream-image.sh <upstream-ref> <harbor-ref> [--policy-file <path>]
#
# Arguments:
#   upstream-ref   Full upstream image reference (e.g., docker.io/matrixdotorg/synapse:v1.139.2)
#   harbor-ref     Harbor target reference (e.g., sentinel/synapse:v1.139.2)
#
# Options:
#   --policy-file  Path to trust-policy.yaml (default: config/supply-chain/trust-policy.yaml
#                  relative to script's repo root)
#   --dry-run      Show what would happen without making changes
#   --skip-resign  Skip re-signing with our Cosign key (for testing)
#   --help         Show this help
#
# Feature flag:
#   UPSTREAM_SIG_VERIFY_ENABLED=true (default) — verify before mirror
#   UPSTREAM_SIG_VERIFY_ENABLED=false — skip upstream verification (degraded mode, logs warning)
#
# Environment:
#   COSIGN_KEY_PATH     Path to our Cosign private key (for re-signing)
#   COSIGN_KEY_PASSWORD Password for our Cosign key (or use COSIGN_KEY_PATH_PASSWORD)
#   HARBOR_REGISTRY     Harbor hostname (default: harbor.208.haist.farm)
#   LOG_EXCEPTION_FILE  File to append exception uses to (default: /var/log/harbor-mirror-exceptions.log)

set -euo pipefail

# --- Constants ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_POLICY_FILE="${REPO_ROOT}/config/supply-chain/trust-policy.yaml"
HARBOR_REGISTRY="${HARBOR_REGISTRY:-harbor.208.haist.farm}"
LOG_EXCEPTION_FILE="${LOG_EXCEPTION_FILE:-/var/log/harbor-mirror-exceptions.log}"
UPSTREAM_SIG_VERIFY_ENABLED="${UPSTREAM_SIG_VERIFY_ENABLED:-true}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Globals set by parse_args ---
UPSTREAM_REF=""
HARBOR_REF=""
POLICY_FILE="${DEFAULT_POLICY_FILE}"
DRY_RUN=false
SKIP_RESIGN=false

# --- Logging ---
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <upstream-ref> <harbor-ref> [OPTIONS]

Mirror an upstream image to Harbor with upstream Cosign signature verification.

Arguments:
  upstream-ref    Full upstream reference (e.g., docker.io/matrixdotorg/synapse:v1.139.2)
  harbor-ref      Harbor target (e.g., sentinel/synapse:v1.139.2)

Options:
  --policy-file <path>  Trust policy file (default: config/supply-chain/trust-policy.yaml)
  --dry-run             Show what would happen without changes
  --skip-resign         Skip re-signing with our Cosign key
  -h, --help            Show this help

Feature flag:
  UPSTREAM_SIG_VERIFY_ENABLED=false  Skip upstream verification (logs WARNING)

Examples:
  # Mirror synapse with full upstream verification + re-sign
  $(basename "$0") docker.io/matrixdotorg/synapse:v1.139.2 sentinel/synapse:v1.139.2

  # Dry run to see what would happen
  $(basename "$0") docker.io/library/postgres:16 sentinel/postgres:16 --dry-run

  # Override policy file location
  $(basename "$0") docker.io/grafana/grafana:12.3.1 sentinel/grafana:12.3.1 \\
    --policy-file /etc/sentinel/trust-policy.yaml
EOF
}

parse_args() {
    if [[ $# -lt 2 ]]; then
        log_error "Missing required arguments"
        usage
        exit 1
    fi

    UPSTREAM_REF="$1"
    HARBOR_REF="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --policy-file) POLICY_FILE="$2"; shift 2 ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --skip-resign) SKIP_RESIGN=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

check_prerequisites() {
    local missing=false

    for cmd in cosign podman python3; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            missing=true
        fi
    done

    if [[ ! -f "$POLICY_FILE" ]]; then
        log_error "Trust policy file not found: $POLICY_FILE"
        missing=true
    fi

    if [[ "$missing" == "true" ]]; then
        exit 1
    fi

    # Verify Harbor login
    if ! $DRY_RUN; then
        if ! podman login --get-login "$HARBOR_REGISTRY" &>/dev/null; then
            log_error "Not logged into Harbor: $HARBOR_REGISTRY"
            log_error "Run: podman login $HARBOR_REGISTRY"
            exit 1
        fi
    fi
}

# Extract the image name key from the upstream ref for policy lookup
# e.g., docker.io/matrixdotorg/synapse:v1.139.2 -> synapse
get_policy_key() {
    local upstream="$1"
    # Strip tag/digest
    local name="${upstream%%:*}"
    name="${name%%@*}"
    # Get the last path component
    echo "${name##*/}"
}

# Look up a field from the trust policy YAML using Python (no yq dependency)
policy_get() {
    local section="$1"  # "upstream_keys" or "exceptions"
    local key="$2"      # image key (e.g., "synapse")
    local field="$3"    # field name (e.g., "method")

    python3 - <<PYEOF
import sys, os
try:
    import yaml
    with open("${POLICY_FILE}") as f:
        policy = yaml.safe_load(f)
    section = policy.get("${section}", {}) or {}
    entry = section.get("${key}") or {}
    val = entry.get("${field}", "")
    print(val if val is not None else "")
except ImportError:
    # Fallback: simple grep-based extraction (fragile but works for flat values)
    import re
    in_section = False
    in_entry = False
    indent_section = 0
    indent_entry = 0
    with open("${POLICY_FILE}") as f:
        for line in f:
            stripped = line.rstrip()
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            if stripped.rstrip(':') == "${section}":
                in_section = True
                indent_section = indent
                continue
            if in_section and indent <= indent_section and stripped.rstrip(':') != "${section}":
                if not stripped.startswith(' ') and not stripped.startswith('\t'):
                    in_section = False
                    in_entry = False
            if in_section:
                if indent == indent_section + 2 and stripped.rstrip(':') == "${key}":
                    in_entry = True
                    indent_entry = indent
                    continue
                if in_entry and indent == indent_entry + 2:
                    m = re.match(r'\s*${field}:\s*["\']?(.+?)["\']?\s*$', line)
                    if m:
                        print(m.group(1))
                        sys.exit(0)
                elif in_entry and indent <= indent_entry and stripped.rstrip(':') != "${key}":
                    in_entry = False
    print("")
except Exception as e:
    print("", file=sys.stderr)
    sys.exit(0)
PYEOF
}

# Check if an image key is in the exception list
is_exception() {
    local key="$1"
    local rationale
    rationale=$(policy_get "exceptions" "$key" "rationale")
    [[ -n "$rationale" ]]
}

# Check if an image key is in the verified upstream_keys list
is_verified_upstream() {
    local key="$1"
    local method
    method=$(policy_get "upstream_keys" "$key" "method")
    [[ -n "$method" ]]
}

# Log an exception use to the audit log
log_exception_use() {
    local upstream="$1"
    local key="$2"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local rationale
    rationale=$(policy_get "exceptions" "$key" "rationale" | head -1)

    local log_entry="${timestamp} EXCEPTION_USED upstream=${upstream} policy_key=${key} rationale=${rationale}"

    if $DRY_RUN; then
        log_warn "[DRY RUN] Would log exception use: ${log_entry}"
        return 0
    fi

    echo "$log_entry" >> "$LOG_EXCEPTION_FILE" 2>/dev/null || \
        log_warn "Could not write to exception log: ${LOG_EXCEPTION_FILE}"
    log_warn "Exception use logged: ${log_entry}"
}

# Verify upstream Cosign signature
verify_upstream_signature() {
    local upstream="$1"
    local key="$2"
    local method
    method=$(policy_get "upstream_keys" "$key" "method")

    log_step "Verifying upstream signature for: ${upstream} (key=${key}, method=${method})"

    case "$method" in
        cosign-keyless)
            local issuer identity_regexp
            issuer=$(policy_get "upstream_keys" "$key" "certificate_oidc_issuer")
            identity_regexp=$(policy_get "upstream_keys" "$key" "certificate_identity_regexp")

            if [[ -z "$issuer" || -z "$identity_regexp" ]]; then
                log_error "trust-policy entry '${key}' missing certificate_oidc_issuer or certificate_identity_regexp"
                return 1
            fi

            log_info "Running: cosign verify --certificate-oidc-issuer=${issuer} --certificate-identity-regexp=${identity_regexp} ${upstream}"

            if $DRY_RUN; then
                log_info "[DRY RUN] Would run cosign verify (keyless)"
                return 0
            fi

            if COSIGN_NO_COLOR=1 cosign verify \
                --certificate-oidc-issuer="${issuer}" \
                --certificate-identity-regexp="${identity_regexp}" \
                "${upstream}" >/dev/null 2>&1; then
                log_info "Upstream signature verified (keyless): ${upstream}"
                return 0
            else
                log_error "Upstream signature verification FAILED for: ${upstream}"
                log_error "Run manually: cosign verify --certificate-oidc-issuer=${issuer} --certificate-identity-regexp=${identity_regexp} ${upstream}"
                return 1
            fi
            ;;

        cosign-key)
            local key_url
            key_url=$(policy_get "upstream_keys" "$key" "key_url")

            if [[ -z "$key_url" ]]; then
                log_error "trust-policy entry '${key}' missing key_url"
                return 1
            fi

            log_info "Running: cosign verify --key=${key_url} ${upstream}"

            if $DRY_RUN; then
                log_info "[DRY RUN] Would run cosign verify (static key)"
                return 0
            fi

            if COSIGN_NO_COLOR=1 cosign verify \
                --key="${key_url}" \
                "${upstream}" >/dev/null 2>&1; then
                log_info "Upstream signature verified (static key): ${upstream}"
                return 0
            else
                log_error "Upstream signature verification FAILED for: ${upstream}"
                log_error "Run manually: cosign verify --key=${key_url} ${upstream}"
                return 1
            fi
            ;;

        *)
            log_error "Unknown verification method '${method}' for key '${key}'"
            return 1
            ;;
    esac
}

# Pull, tag, and push the image to Harbor
mirror_image() {
    local upstream="$1"
    local harbor_target="${HARBOR_REGISTRY}/$2"

    log_step "Mirroring: ${upstream} -> ${harbor_target}"

    if $DRY_RUN; then
        log_info "[DRY RUN] Would run:"
        log_info "  podman pull ${upstream}"
        log_info "  podman tag ${upstream} ${harbor_target}"
        log_info "  podman push ${harbor_target}"
        return 0
    fi

    log_info "Pulling: ${upstream}"
    if ! podman pull "${upstream}"; then
        log_error "Failed to pull: ${upstream}"
        return 1
    fi

    log_info "Tagging: ${harbor_target}"
    podman tag "${upstream}" "${harbor_target}"

    log_info "Pushing: ${harbor_target}"
    if ! podman push "${harbor_target}"; then
        log_error "Failed to push: ${harbor_target}"
        return 1
    fi

    log_info "Mirrored: ${upstream} -> ${harbor_target}"
}

# Re-sign with our Cosign key
resign_with_our_key() {
    local harbor_target="${HARBOR_REGISTRY}/$1"

    if $SKIP_RESIGN; then
        log_info "Skipping re-sign (--skip-resign flag set)"
        return 0
    fi

    if [[ -z "${COSIGN_KEY_PATH:-}" ]]; then
        log_warn "COSIGN_KEY_PATH not set — skipping re-sign with our key"
        log_warn "Set COSIGN_KEY_PATH to enable: cosign sign --key <path> ${harbor_target}"
        return 0
    fi

    log_step "Re-signing with our Cosign key: ${harbor_target}"

    if $DRY_RUN; then
        log_info "[DRY RUN] Would run: cosign sign --key ${COSIGN_KEY_PATH} ${harbor_target}"
        return 0
    fi

    if COSIGN_NO_COLOR=1 cosign sign \
        --key "${COSIGN_KEY_PATH}" \
        "${harbor_target}" 2>&1; then
        log_info "Re-signed with our key: ${harbor_target}"
    else
        log_error "Re-signing FAILED for ${harbor_target} — aborting mirror to prevent unsigned image in registry"
        return 1
    fi
}

main() {
    parse_args "$@"
    check_prerequisites

    local policy_key
    policy_key=$(get_policy_key "${UPSTREAM_REF}")

    log_info "Processing: ${UPSTREAM_REF} -> ${HARBOR_REGISTRY}/${HARBOR_REF}"
    log_info "Policy key: ${policy_key}"

    # Feature flag check
    if [[ "${UPSTREAM_SIG_VERIFY_ENABLED}" != "true" ]]; then
        log_warn "UPSTREAM_SIG_VERIFY_ENABLED=false — upstream signature verification DISABLED"
        log_warn "This is degraded mode. Verify this is intentional."
    else
        # Determine verification path
        if is_verified_upstream "${policy_key}"; then
            # Full upstream signature verification
            if ! verify_upstream_signature "${UPSTREAM_REF}" "${policy_key}"; then
                log_error "Upstream verification failed — NOT mirroring: ${UPSTREAM_REF}"
                log_error "If the upstream has rotated their signing key, check trust-policy.yaml"
                log_error "If this is a known exception, add to exceptions: block with reviewed rationale"
                exit 2
            fi
        elif is_exception "${policy_key}"; then
            # Exception path: log use and proceed with warning
            log_warn "Image ${policy_key} is on the exception list — no upstream sig verification"
            log_exception_use "${UPSTREAM_REF}" "${policy_key}"

            local compensating
            compensating=$(policy_get "exceptions" "${policy_key}" "compensating_controls")
            log_warn "Compensating controls: ${compensating}"
        else
            # Not in verified list and not in exception list — FAIL
            log_error "Image '${policy_key}' not found in trust-policy.yaml"
            log_error "Either:"
            log_error "  1. Add upstream_keys entry if the upstream publishes Cosign signatures"
            log_error "  2. Add exceptions entry with documented rationale"
            log_error "See docs/runbooks/12-upstream-image-trust.md for the process"
            exit 3
        fi
    fi

    # Mirror the image
    mirror_image "${UPSTREAM_REF}" "${HARBOR_REF}"

    # Re-sign with our key — FATAL if re-sign fails (SEC-99: enforced self-sovereign model)
    resign_with_our_key "${HARBOR_REF}" || exit 1

    log_info "Done: ${UPSTREAM_REF} -> ${HARBOR_REGISTRY}/${HARBOR_REF}"
}

main "$@"
