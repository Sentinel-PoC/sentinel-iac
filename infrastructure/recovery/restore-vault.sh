#!/bin/bash
# Vault Data Restoration Script
# Restores Vault data from MinIO backup
#
# USAGE:
#   ./restore-vault.sh [--date YYYY-MM-DD] [--vault-host HOST]
#
# ENVIRONMENT:
#   MINIO_ENDPOINT    - MinIO API endpoint (default: http://192.168.12.58:9000)
#   MINIO_ACCESS_KEY  - MinIO access key (required)
#   MINIO_SECRET_KEY  - MinIO secret key (required)
#   VAULT_HOST        - Vault server host (default: 192.168.12.206)
#   VAULT_USER        - SSH user for Vault server (default: root)
#
# PREREQUISITES:
#   - SSH access to Vault server
#   - MinIO credentials configured
#   - Python3 with boto3 installed
#   - Vault service must be stopped before restore

set -euo pipefail

# Defaults
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.12.58:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-vault-backups}"
VAULT_HOST="${VAULT_HOST:-192.168.12.206}"
VAULT_USER="${VAULT_USER:-root}"
BACKUP_DATE="${1:-latest}"
TEMP_DIR="/tmp/vault-restore-$$"

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
        --date) BACKUP_DATE="$2"; shift 2 ;;
        --vault-host) VAULT_HOST="$2"; shift 2 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Validate prerequisites
[[ -z "${MINIO_ACCESS_KEY:-}" ]] && error "MINIO_ACCESS_KEY not set"
[[ -z "${MINIO_SECRET_KEY:-}" ]] && error "MINIO_SECRET_KEY not set"
command -v python3 >/dev/null || error "python3 not found"

log "Starting Vault data restoration"
log "Target: ${VAULT_USER}@${VAULT_HOST}"
log "Backup date: ${BACKUP_DATE}"

# Create temp directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Download backup from MinIO
log "Downloading backup from MinIO..."
export BACKUP_DATE TEMP_DIR MINIO_ENDPOINT MINIO_BUCKET MINIO_ACCESS_KEY MINIO_SECRET_KEY
BACKUP_FILE=$(python3 - <<'PYEOF'
import boto3, os, sys

s3 = boto3.client('s3',
    endpoint_url=os.environ['MINIO_ENDPOINT'],
    aws_access_key_id=os.environ['MINIO_ACCESS_KEY'],
    aws_secret_access_key=os.environ['MINIO_SECRET_KEY'],
    region_name='us-east-1')

bucket = os.environ['MINIO_BUCKET']
backup_date = os.environ['BACKUP_DATE']
temp_dir = os.environ['TEMP_DIR']

# List backups
resp = s3.list_objects_v2(Bucket=bucket, Prefix='vault-backup-')
if not resp.get('Contents'):
    print("ERROR: No backups found", file=sys.stderr)
    sys.exit(1)

backups = sorted(resp['Contents'], key=lambda x: x['LastModified'], reverse=True)

# Select backup
if backup_date == 'latest':
    selected = backups[0]
else:
    selected = next((b for b in backups if backup_date in b['Key']), None)
    if not selected:
        print(f"ERROR: No backup found for date {backup_date}", file=sys.stderr)
        sys.exit(1)

backup_file = selected['Key']
local_path = f"{temp_dir}/{backup_file}"

print(f"Downloading {backup_file} ({selected['Size']} bytes)...", file=sys.stderr)
s3.download_file(bucket, backup_file, local_path)
print(local_path)
PYEOF
)

[[ -z "$BACKUP_FILE" ]] && error "Failed to download backup"
log "Downloaded: $(basename $BACKUP_FILE)"

# Stop Vault service on target
log "Stopping Vault service on ${VAULT_HOST}..."
ssh "${VAULT_USER}@${VAULT_HOST}" "systemctl stop vault" || error "Failed to stop Vault"

# Backup existing data
log "Backing up existing Vault data..."
ssh "${VAULT_USER}@${VAULT_HOST}" "tar -czf /tmp/vault-data-pre-restore.tar.gz -C /opt/vault data/ || true"

# Clear existing data
log "Clearing existing Vault data..."
ssh "${VAULT_USER}@${VAULT_HOST}" "rm -rf /opt/vault/data/*"

# Copy and extract backup
log "Uploading and extracting backup..."
scp "$BACKUP_FILE" "${VAULT_USER}@${VAULT_HOST}:/tmp/vault-restore.tar.gz"
ssh "${VAULT_USER}@${VAULT_HOST}" "tar -xzf /tmp/vault-restore.tar.gz -C /opt/vault && chown -R vault:vault /opt/vault/data && rm -f /tmp/vault-restore.tar.gz"

# Start Vault service
log "Starting Vault service..."
ssh "${VAULT_USER}@${VAULT_HOST}" "systemctl start vault"

# Wait for Vault to be ready
log "Waiting for Vault to start..."
for i in {1..30}; do
    if ssh "${VAULT_USER}@${VAULT_HOST}" "curl -s http://localhost:8200/v1/sys/health || true" | grep -q "initialized"; then
        log "Vault is responding"
        break
    fi
    [[ $i -eq 30 ]] && error "Vault did not start within 30 seconds"
    sleep 1
done

log "Vault restoration complete!"
log ""
log "NEXT STEPS:"
log "1. Unseal Vault with 3 of 5 unseal keys"
log "2. Verify Vault health: vault status"
log "3. Test secret access: vault kv get secret/test"
log ""
log "Unseal command example:"
log "  ssh ${VAULT_USER}@${VAULT_HOST}"
log "  export VAULT_ADDR=http://localhost:8200"
log "  vault operator unseal <key1>"
log "  vault operator unseal <key2>"
log "  vault operator unseal <key3>"
