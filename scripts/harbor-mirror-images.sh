#!/usr/bin/env bash
# harbor-mirror-images.sh — Mirror public container images to Harbor
#
# Reads image-manifest.txt and uses podman to pull, tag, and push
# each image to harbor.208.haist.farm.
#
# Prerequisites:
#   - podman installed
#   - Logged into Harbor: podman login harbor.208.haist.farm
#   - Network access to source registries (Squid allowlist must include them)
#
# Usage:
#   ./harbor-mirror-images.sh                    # Mirror all images
#   ./harbor-mirror-images.sh --dry-run          # Show what would be done
#   ./harbor-mirror-images.sh --check            # Check which images exist in Harbor

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/image-manifest.txt"
HARBOR_REGISTRY="harbor.208.haist.farm"
DRY_RUN=false
CHECK_ONLY=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Mirror public container images to Harbor registry."
    echo ""
    echo "Options:"
    echo "  --dry-run    Show what would be done without executing"
    echo "  --check      Check which images already exist in Harbor"
    echo "  --manifest   Path to image manifest (default: image-manifest.txt)"
    echo "  -h, --help   Show this help message"
}

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=true; shift ;;
            --check)    CHECK_ONLY=true; shift ;;
            --manifest) MANIFEST="$2"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            *)          log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

check_prerequisites() {
    if ! command -v podman &>/dev/null; then
        log_error "podman is not installed"
        exit 1
    fi

    if [[ ! -f "$MANIFEST" ]]; then
        log_error "Manifest file not found: $MANIFEST"
        exit 1
    fi

    # Verify Harbor login
    if ! podman login --get-login "$HARBOR_REGISTRY" &>/dev/null; then
        log_warn "Not logged into $HARBOR_REGISTRY"
        echo "Run: podman login $HARBOR_REGISTRY"
        exit 1
    fi
}

mirror_image() {
    local source="$1"
    local target="${HARBOR_REGISTRY}/$2"

    if $DRY_RUN; then
        echo "  podman pull $source"
        echo "  podman tag $source $target"
        echo "  podman push $target"
        echo ""
        return 0
    fi

    log_info "Pulling: $source"
    if ! podman pull "$source"; then
        log_error "Failed to pull: $source"
        return 1
    fi

    log_info "Tagging: $target"
    podman tag "$source" "$target"

    log_info "Pushing: $target"
    if ! podman push "$target"; then
        log_error "Failed to push: $target"
        return 1
    fi

    log_info "Mirrored: $source -> $target"
}

check_image() {
    local target="${HARBOR_REGISTRY}/$1"

    if podman manifest inspect "$target" &>/dev/null || \
       podman pull --quiet "$target" &>/dev/null 2>&1; then
        echo -e "  ${GREEN}EXISTS${NC}  $target"
    else
        echo -e "  ${RED}MISSING${NC} $target"
    fi
}

main() {
    parse_args "$@"
    check_prerequisites

    local total=0
    local success=0
    local failed=0

    if $DRY_RUN; then
        log_info "DRY RUN — no changes will be made"
        echo ""
    fi

    if $CHECK_ONLY; then
        log_info "Checking Harbor for existing images..."
        echo ""
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        local source target
        source="$(echo "$line" | awk '{print $1}')"
        target="$(echo "$line" | awk '{print $2}')"

        if [[ -z "$source" || -z "$target" ]]; then
            log_warn "Skipping malformed line: $line"
            continue
        fi

        ((total++)) || true

        if $CHECK_ONLY; then
            check_image "$target"
            continue
        fi

        echo "---"
        log_info "[$total] $source -> $target"

        if mirror_image "$source" "$target"; then
            ((success++)) || true
        else
            ((failed++)) || true
        fi
    done < "$MANIFEST"

    echo ""
    echo "=============================="
    if $CHECK_ONLY; then
        log_info "Checked $total images"
    elif $DRY_RUN; then
        log_info "Would mirror $total images (dry run)"
    else
        log_info "Results: $success succeeded, $failed failed, $total total"
        if [[ $failed -gt 0 ]]; then
            log_error "Some images failed to mirror — check output above"
            exit 1
        fi
    fi
}

main "$@"
