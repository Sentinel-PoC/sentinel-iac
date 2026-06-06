#!/bin/bash
# MinIO Data Restoration Script
# Restores MinIO data from Backblaze B2
#
# USAGE:
#   ./restore-minio.sh [--bucket BUCKET]
#
# ENVIRONMENT:
#   MINIO_HOST        - MinIO LXC host (default: 192.168.12.58)
#   MINIO_USER        - SSH user for MinIO server (default: root)
#   B2_ACCOUNT_ID     - Backblaze B2 account ID (required)
#   B2_APP_KEY        - Backblaze B2 application key (required)
#   B2_BUCKET         - B2 bucket name (required)
#   RCLONE_CRYPT_PASS - Rclone encryption password (required)
#   RCLONE_CRYPT_SALT - Rclone encryption salt (required)
#
# PREREQUISITES:
#   - SSH access to MinIO server
#   - B2 credentials and encryption keys
#   - Rclone installed on MinIO server

set -euo pipefail

# Defaults
MINIO_HOST="${MINIO_HOST:-192.168.12.58}"
MINIO_USER="${MINIO_USER:-root}"
TARGET_BUCKET="${1:-all}"

log() { echo "[$(date -Iseconds)] $*"; }
error() { log "ERROR: $*" >&2; exit 1; }

show_help() {
    head -n 20 "$0" | grep "^#" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --bucket) TARGET_BUCKET="$2"; shift 2 ;;
        --minio-host) MINIO_HOST="$2"; shift 2 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Validate prerequisites
[[ -z "${B2_ACCOUNT_ID:-}" ]] && error "B2_ACCOUNT_ID not set"
[[ -z "${B2_APP_KEY:-}" ]] && error "B2_APP_KEY not set"
[[ -z "${B2_BUCKET:-}" ]] && error "B2_BUCKET not set"
[[ -z "${RCLONE_CRYPT_PASS:-}" ]] && error "RCLONE_CRYPT_PASS not set"
[[ -z "${RCLONE_CRYPT_SALT:-}" ]] && error "RCLONE_CRYPT_SALT not set"

log "Starting MinIO data restoration from B2"
log "Target: ${MINIO_USER}@${MINIO_HOST}"
log "Bucket filter: ${TARGET_BUCKET}"

# Check if rclone is installed on MinIO server
log "Checking rclone installation..."
ssh "${MINIO_USER}@${MINIO_HOST}" "command -v rclone >/dev/null" || error "rclone not installed on MinIO server"

# Create rclone config on MinIO server
log "Configuring rclone on MinIO server..."
ssh "${MINIO_USER}@${MINIO_HOST}" bash <<REMOTE_EOF
set -euo pipefail

mkdir -p ~/.config/rclone

cat > ~/.config/rclone/rclone.conf <<'RCLONE_CONFIG'
[b2]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APP_KEY}

[b2-crypt]
type = crypt
remote = b2:${B2_BUCKET}
password = ${RCLONE_CRYPT_PASS}
password2 = ${RCLONE_CRYPT_SALT}
RCLONE_CONFIG

echo "Rclone configured successfully"
REMOTE_EOF

# List available buckets in B2
log "Listing available buckets in B2..."
ssh "${MINIO_USER}@${MINIO_HOST}" "rclone lsd b2-crypt:" | tee /tmp/b2-buckets.txt

# Determine buckets to restore
if [[ "$TARGET_BUCKET" == "all" ]]; then
    BUCKETS=("terraform-state" "vault-backups" "gitlab-backups" "etcd-backups")
else
    BUCKETS=("$TARGET_BUCKET")
fi

# Stop MinIO service
log "Stopping MinIO service..."
ssh "${MINIO_USER}@${MINIO_HOST}" "systemctl stop minio" || error "Failed to stop MinIO"

# Restore each bucket
for bucket in "${BUCKETS[@]}"; do
    log "Restoring bucket: ${bucket}"
    
    # Create bucket directory
    ssh "${MINIO_USER}@${MINIO_HOST}" "mkdir -p /data/minio/${bucket}"
    
    # Sync from B2 to MinIO data directory
    log "Syncing ${bucket} from B2..."
    ssh "${MINIO_USER}@${MINIO_HOST}" "rclone sync -v --checksum b2-crypt:${bucket} /data/minio/${bucket}/"
    
    # Fix permissions
    ssh "${MINIO_USER}@${MINIO_HOST}" "chown -R minio-user:minio-user /data/minio/${bucket}"
    
    log "Bucket ${bucket} restored successfully"
done

# Start MinIO service
log "Starting MinIO service..."
ssh "${MINIO_USER}@${MINIO_HOST}" "systemctl start minio" || error "Failed to start MinIO"

# Wait for MinIO to be ready
log "Waiting for MinIO to start..."
for i in {1..30}; do
    if ssh "${MINIO_USER}@${MINIO_HOST}" "curl -s http://localhost:9000/minio/health/live" | grep -q "200"; then
        log "MinIO is responding"
        break
    fi
    [[ $i -eq 30 ]] && error "MinIO did not start within 30 seconds"
    sleep 1
done

# Cleanup rclone config (security)
log "Cleaning up rclone config..."
ssh "${MINIO_USER}@${MINIO_HOST}" "rm -f ~/.config/rclone/rclone.conf"

log "MinIO restoration complete!"
log ""
log "NEXT STEPS:"
log "1. Verify MinIO is accessible at http://${MINIO_HOST}:9000"
log "2. Test MinIO console at http://${MINIO_HOST}:9001"
log "3. Verify bucket contents with mc client"
log ""
log "Buckets restored: ${BUCKETS[*]}"
