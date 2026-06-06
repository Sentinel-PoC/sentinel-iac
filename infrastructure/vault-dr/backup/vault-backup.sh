#!/bin/bash
# Vault Data Backup - Daily snapshot to MinIO
# Backs up /opt/vault/data/ (file storage backend)
# Data is already encrypted by Vault's master key
set -euo pipefail

BACKUP_DIR="/tmp"
DATE=$(date +%Y-%m-%d)
BACKUP_FILE="vault-backup-${DATE}.tar.gz"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.12.58:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-vault-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_FILE="/var/log/vault-backup.log"

log() { echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"; }

log "Starting Vault data backup"

# Create tar.gz of vault data
tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" -C /opt/vault data/
BACKUP_SIZE=$(stat -c%s "${BACKUP_DIR}/${BACKUP_FILE}")
log "Created ${BACKUP_FILE} (${BACKUP_SIZE} bytes)"

# Upload to MinIO via boto3
export BACKUP_FILE
python3 - <<'PYEOF'
import boto3, os, sys, datetime

s3 = boto3.client('s3',
    endpoint_url=os.environ.get('MINIO_ENDPOINT', 'http://192.168.12.58:9000'),
    aws_access_key_id=os.environ.get('MINIO_ACCESS_KEY', 'minio-admin'),
    aws_secret_access_key=os.environ.get('MINIO_SECRET_KEY'),
    region_name='us-east-1')

bucket = os.environ.get('MINIO_BUCKET', 'vault-backups')
backup_file = os.environ['BACKUP_FILE']
backup_path = f"/tmp/{backup_file}"

# Upload
s3.upload_file(backup_path, bucket, backup_file)
print(f"Uploaded {backup_file} to {bucket}")

# Clean old backups (retention)
retention = int(os.environ.get('RETENTION_DAYS', '7'))
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=retention)
resp = s3.list_objects_v2(Bucket=bucket)
for obj in resp.get('Contents', []):
    if obj['LastModified'] < cutoff and obj['Key'].startswith('vault-backup-'):
        s3.delete_object(Bucket=bucket, Key=obj['Key'])
        print(f"Deleted old backup: {obj['Key']}")
PYEOF

log "Upload complete"

# Clean local temp file
rm -f "${BACKUP_DIR}/${BACKUP_FILE}"
log "Backup complete"
