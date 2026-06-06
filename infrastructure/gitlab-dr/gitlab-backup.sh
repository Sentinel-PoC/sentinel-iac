#!/bin/bash
# GitLab Data Backup - Weekly snapshot to MinIO
set -euo pipefail

BACKUP_DIR="/var/opt/gitlab/backups"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%s)
CONFIG_BACKUP_FILE="gitlab-config-${DATE}.tar.gz"
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.12.58:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-gitlab-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
LOG_FILE="/var/log/gitlab-backup.log"

log() { echo "[$(date -Iseconds)] $1" | tee -a "$LOG_FILE"; }

log "Starting GitLab backup"

# 1. Create GitLab app backup
log "Creating GitLab app backup..."
gitlab-backup create SKIP=artifacts,builds,pages,registry,packages,terraform_state STRATEGY=copy

# Find the most recent backup file
APP_BACKUP_FILE=$(ls -t ${BACKUP_DIR}/*_gitlab_backup.tar | head -1)
if [ ! -f "$APP_BACKUP_FILE" ]; then
    log "ERROR: GitLab app backup file not found"
    exit 1
fi
APP_BACKUP_NAME=$(basename "$APP_BACKUP_FILE")
APP_SIZE=$(stat -c%s "$APP_BACKUP_FILE")
log "Created ${APP_BACKUP_NAME} (${APP_SIZE} bytes)"

# 2. Create config backup
log "Creating GitLab config backup..."
tar -czf "/tmp/${CONFIG_BACKUP_FILE}" -C /etc/gitlab gitlab-secrets.json gitlab.rb
CONFIG_SIZE=$(stat -c%s "/tmp/${CONFIG_BACKUP_FILE}")
log "Created ${CONFIG_BACKUP_FILE} (${CONFIG_SIZE} bytes)"

# 3. Upload both to MinIO
log "Uploading to MinIO..."
export APP_BACKUP_FILE APP_BACKUP_NAME CONFIG_BACKUP_FILE
python3 - <<'PYEOF'
import boto3, os, sys, datetime

s3 = boto3.client('s3',
    endpoint_url=os.environ.get('MINIO_ENDPOINT', 'http://192.168.12.58:9000'),
    aws_access_key_id=os.environ.get('MINIO_ACCESS_KEY', 'minio-admin'),
    aws_secret_access_key=os.environ.get('MINIO_SECRET_KEY'),
    region_name='us-east-1')

bucket = os.environ.get('MINIO_BUCKET', 'gitlab-backups')

# Upload app backup
app_file = os.environ['APP_BACKUP_FILE']
app_name = os.environ['APP_BACKUP_NAME']
s3.upload_file(app_file, bucket, f"app/{app_name}")
print(f"Uploaded {app_name} to {bucket}/app/")

# Upload config backup
config_file = os.environ['CONFIG_BACKUP_FILE']
s3.upload_file(f"/tmp/{config_file}", bucket, f"config/{config_file}")
print(f"Uploaded {config_file} to {bucket}/config/")

# Cleanup old backups
retention = int(os.environ.get('RETENTION_DAYS', '14'))
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=retention)

for prefix in ['app/', 'config/']:
    resp = s3.list_objects_v2(Bucket=bucket, Prefix=prefix)
    for obj in resp.get('Contents', []):
        if obj['LastModified'] < cutoff:
            s3.delete_object(Bucket=bucket, Key=obj['Key'])
            print(f"Deleted old backup: {obj['Key']}")
PYEOF

log "Upload complete"

# 4. Cleanup local files
log "Cleaning up local files..."
rm -f "$APP_BACKUP_FILE"
rm -f "/tmp/${CONFIG_BACKUP_FILE}"

log "GitLab backup complete"
