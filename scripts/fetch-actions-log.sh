#!/bin/bash
# =============================================================================
# fetch-actions-log.sh — Project Sentinel
# Workaround for OPS-271: Forgejo 14.x REST API does not expose Actions log
# download endpoints (GET /actions/tasks/{id}/logs returns 404).
#
# Fetches Actions job logs directly from the Forgejo server's filesystem via
# SSH and decompresses the zstd-compressed log file.
#
# Log storage path on forgejo-server (192.168.12.70):
#   /opt/forgejo/data/gitea/data/actions_log/{owner}/{repo}/{shard}/{task_id}.log.zst
# where shard = printf '%02x' $((task_id & 0xFF))
#
# Usage:
#   fetch-actions-log.sh <task_id> [owner] [repo]
#
# Examples:
#   fetch-actions-log.sh 25829
#   fetch-actions-log.sh 25829 sentinel-admin sentinel-iac
#   fetch-actions-log.sh 302 sentinel-admin sentinel-iac | grep -i error
#
# Prerequisites:
#   - SSH access to koiakoia@192.168.12.70 with a valid JIT cert
#   - zstd installed on the forgejo host (confirmed present at /usr/bin/zstd)
#   - The calling user's SSH key is ~/.ssh/claude_jit with cert at
#     ~/.ssh/claude_jit-cert.pub, OR the SSH agent has the JIT key loaded.
#
# NIST relevance: AU-12 (Audit Record Generation) — supports programmatic
# post-mortem retrieval of CI/CD job evidence.
# =============================================================================
set -euo pipefail

FORGEJO_HOST="192.168.12.70"
FORGEJO_USER="koiakoia"
FORGEJO_DATA_ROOT="/opt/forgejo/data/gitea/data/actions_log"
SSH_KEY="${CLAUDE_JIT_KEY:-${HOME}/.ssh/claude_jit}"
SSH_CERT="${CLAUDE_JIT_CERT:-${HOME}/.ssh/claude_jit-cert.pub}"

usage() {
    echo "Usage: $0 <task_id> [owner] [repo]" >&2
    echo "  task_id  : Forgejo Actions task ID (from /api/v1/repos/.../actions/tasks)" >&2
    echo "  owner    : Repo owner (default: sentinel-admin)" >&2
    echo "  repo     : Repo name (default: sentinel-iac)" >&2
    exit 1
}

[[ $# -lt 1 ]] && usage

TASK_ID="$1"
OWNER="${2:-sentinel-admin}"
REPO="${3:-sentinel-iac}"

# Validate task_id is numeric
if ! [[ "$TASK_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: task_id must be a positive integer, got: ${TASK_ID}" >&2
    exit 1
fi

# Calculate shard directory: low byte of task_id in hex, zero-padded to 2 chars
SHARD=$(printf '%02x' $((TASK_ID & 0xFF)))
LOG_PATH="${FORGEJO_DATA_ROOT}/${OWNER}/${REPO}/${SHARD}/${TASK_ID}.log.zst"

echo "# Forgejo Actions log — task ${TASK_ID}" >&2
echo "# Owner: ${OWNER}  Repo: ${REPO}" >&2
echo "# Remote path: ${FORGEJO_HOST}:${LOG_PATH}" >&2
echo "" >&2

# Build SSH options — support both JIT-cert and plain key (agent) auth
SSH_OPTS=(
    -o ConnectTimeout=10
    -o StrictHostKeyChecking=no
    -o PKCS11Provider=none
    -o BatchMode=yes
)

if [[ -f "$SSH_KEY" && -f "$SSH_CERT" ]]; then
    SSH_OPTS+=(-i "$SSH_KEY" -o "CertificateFile=${SSH_CERT}")
fi

# Check the log file exists, then decompress to stdout
ssh "${SSH_OPTS[@]}" "${FORGEJO_USER}@${FORGEJO_HOST}" \
    "test -f '${LOG_PATH}' || { echo 'Log file not found: ${LOG_PATH}' >&2; exit 1; }; zstd -d --stdout '${LOG_PATH}' 2>/dev/null"
