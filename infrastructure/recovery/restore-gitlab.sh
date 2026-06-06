#!/bin/bash
# GitLab Data Restoration Script
# Restores GitLab application and configuration from MinIO backup
#
# USAGE:
#   ./restore-gitlab.sh [--date YYYY-MM-DD] [--gitlab-host HOST]
#
# ENVIRONMENT:
#   MINIO_ENDPOINT    - MinIO API endpoint (default: http://192.168.12.58:9000)
#   MINIO_ACCESS_KEY  - MinIO access key (required)
#   MINIO_SECRET_KEY  - MinIO secret key (required)
#   GITLAB_HOST       - GitLab server host (default: 192.168.12.68)
#   GITLAB_USER       - SSH user for GitLab server (default: koiakoia)
#
# PREREQUISITES:
#   - SSH access to GitLab server
#   - MinIO credentials configured
#   - Python3 with boto3 installed
#   - GitLab service must be running

set -euo pipefail

# Defaults
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.12.58:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-gitlab-backups}"
GITLAB_HOST="${GITLAB_HOST:-192.168.12.68}"
GITLAB_USER="${GITLAB_USER:-koiakoia}"
BACKUP_DATE="${1:-latest}"
TEMP_DIR="/tmp/gitlab-restore-$$"

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
        --gitlab-host) GITLAB_HOST="$2"; shift 2 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Validate prerequisites
[[ -z "${MINIO_ACCESS_KEY:-}" ]] && error "MINIO_ACCESS_KEY not set"
[[ -z "${MINIO_SECRET_KEY:-}" ]] && error "MINIO_SECRET_KEY not set"
command -v python3 >/dev/null || error "python3 not found"

log "Starting GitLab data restoration"
log "Target: ${GITLAB_USER}@${GITLAB_HOST}"
log "Backup date: ${BACKUP_DATE}"

# Create temp directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Download backups from MinIO
log "Downloading backups from MinIO..."
export BACKUP_DATE TEMP_DIR MINIO_ENDPOINT MINIO_BUCKET MINIO_ACCESS_KEY MINIO_SECRET_KEY
python3 - <<'PYEOF'
import boto3, os, sys

s3 = boto3.client('s3',
    endpoint_url=os.environ['MINIO_ENDPOINT'],
    aws_access_key_id=os.environ['MINIO_ACCESS_KEY'],
    aws_secret_access_key=os.environ['MINIO_SECRET_KEY'],
    region_name='us-east-1')

bucket = os.environ['MINIO_BUCKET']
backup_date = os.environ['BACKUP_DATE']
temp_dir = os.environ['TEMP_DIR']

# Download app backup
app_resp = s3.list_objects_v2(Bucket=bucket, Prefix='app/')
if not app_resp.get('Contents'):
    print("ERROR: No app backups found", file=sys.stderr)
    sys.exit(1)

app_backups = sorted(app_resp['Contents'], key=lambda x: x['LastModified'], reverse=True)
if backup_date == 'latest':
    app_selected = app_backups[0]
else:
    app_selected = next((b for b in app_backups if backup_date in b['Key']), None)
    if not app_selected:
        print(f"ERROR: No app backup found for date {backup_date}", file=sys.stderr)
        sys.exit(1)

app_file = app_selected['Key']
app_local = f"{temp_dir}/{os.path.basename(app_file)}"
print(f"Downloading {app_file} ({app_selected['Size']} bytes)...", file=sys.stderr)
s3.download_file(bucket, app_file, app_local)
print(f"APP_BACKUP={app_local}")

# Download config backup
config_resp = s3.list_objects_v2(Bucket=bucket, Prefix='config/')
if not config_resp.get('Contents'):
    print("ERROR: No config backups found", file=sys.stderr)
    sys.exit(1)

config_backups = sorted(config_resp['Contents'], key=lambda x: x['LastModified'], reverse=True)
if backup_date == 'latest':
    config_selected = config_backups[0]
else:
    config_selected = next((b for b in config_backups if backup_date in b['Key']), None)
    if not config_selected:
        print(f"ERROR: No config backup found for date {backup_date}", file=sys.stderr)
        sys.exit(1)

config_file = config_selected['Key']
config_local = f"{temp_dir}/{os.path.basename(config_file)}"
print(f"Downloading {config_file} ({config_selected['Size']} bytes)...", file=sys.stderr)
s3.download_file(bucket, config_file, config_local)
print(f"CONFIG_BACKUP={config_local}")
PYEOF

# Parse downloaded files
eval "$(python3 - <<'PYEOF'
import os, sys
temp_dir = os.environ['TEMP_DIR']
app_files = [f for f in os.listdir(temp_dir) if f.endswith('_gitlab_backup.tar')]
config_files = [f for f in os.listdir(temp_dir) if f.startswith('gitlab-config-')]
if not app_files or not config_files:
    print("ERROR: Backup files not found after download", file=sys.stderr)
    sys.exit(1)
print(f"APP_BACKUP={temp_dir}/{app_files[0]}")
print(f"CONFIG_BACKUP={temp_dir}/{config_files[0]}")
PYEOF
)"

[[ -z "$APP_BACKUP" ]] && error "Failed to download app backup"
[[ -z "$CONFIG_BACKUP" ]] && error "Failed to download config backup"
log "Downloaded: $(basename $APP_BACKUP), $(basename $CONFIG_BACKUP)"

# Copy backups to GitLab server
log "Uploading backups to GitLab server..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo mkdir -p /var/opt/gitlab/backups /tmp/gitlab-config-restore"
scp "$APP_BACKUP" "${GITLAB_USER}@${GITLAB_HOST}:/tmp/$(basename $APP_BACKUP)"
scp "$CONFIG_BACKUP" "${GITLAB_USER}@${GITLAB_HOST}:/tmp/$(basename $CONFIG_BACKUP)"

# Move app backup to correct location
log "Preparing backups on server..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo mv /tmp/$(basename $APP_BACKUP) /var/opt/gitlab/backups/ && sudo chown git:git /var/opt/gitlab/backups/$(basename $APP_BACKUP)"

# Stop GitLab services
log "Stopping GitLab services..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo gitlab-ctl stop puma && sudo gitlab-ctl stop sidekiq"

# Restore configuration
log "Restoring GitLab configuration..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo tar -xzf /tmp/$(basename $CONFIG_BACKUP) -C /tmp/gitlab-config-restore && sudo cp /tmp/gitlab-config-restore/gitlab-secrets.json /etc/gitlab/ && sudo cp /tmp/gitlab-config-restore/gitlab.rb /etc/gitlab/"

# Restore application data
log "Restoring GitLab application data..."
APP_BACKUP_NAME=$(basename "$APP_BACKUP" | sed 's/_gitlab_backup.tar$//')
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo gitlab-backup restore BACKUP=${APP_BACKUP_NAME} force=yes"

# Reconfigure and restart
log "Reconfiguring GitLab..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo gitlab-ctl reconfigure"

log "Starting GitLab services..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo gitlab-ctl start"

# Check GitLab health
log "Checking GitLab health..."
sleep 10
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo gitlab-rake gitlab:check SANITIZE=true" || log "WARNING: Health check had warnings (may be normal)"

# Cleanup
log "Cleaning up temporary files..."
ssh "${GITLAB_USER}@${GITLAB_HOST}" "sudo rm -rf /tmp/gitlab-config-restore /tmp/$(basename $CONFIG_BACKUP)"

log "GitLab restoration complete!"
log ""
log "NEXT STEPS:"
log "1. Verify GitLab is accessible at http://${GITLAB_HOST}"
log "2. Test authentication and repository access"
log "3. Check CI/CD pipelines are functioning"
log ""
log "Health check command:"
log "  ssh ${GITLAB_USER}@${GITLAB_HOST} 'sudo gitlab-rake gitlab:check'"
