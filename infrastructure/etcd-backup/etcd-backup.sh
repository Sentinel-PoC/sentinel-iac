#!/bin/bash
# etcd-backup.sh - OKD etcd backup to MinIO
# Runs on iac-control, SSHs to a master to take snapshot, uploads to MinIO
# Addresses NIST 800-53 CP-9 (Information System Backup)

set -euo pipefail

# Configuration
MASTER_NODE="10.0.0.221"
MASTER_USER="core"
SSH_KEY="/home/ubuntu/.ssh/id_sentinel"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"
REMOTE_BACKUP_DIR="/home/core/etcd-backup"
LOCAL_BACKUP_DIR="/tmp/etcd-backup"
MINIO_ALIAS="minio"
MINIO_BUCKET="etcd-backups"
RETENTION_DAYS=7
LOG_TAG="etcd-backup"

log() { logger -t "$LOG_TAG" "$1"; echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1"; }

cleanup() {
    log "Cleaning up local temp files"
    rm -rf "$LOCAL_BACKUP_DIR"
    ssh -i "$SSH_KEY" $SSH_OPTS "${MASTER_USER}@${MASTER_NODE}" "sudo rm -rf ${REMOTE_BACKUP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

# Step 1: Clean remote dir and run backup on master
log "Starting etcd backup on $MASTER_NODE"
ssh -i "$SSH_KEY" $SSH_OPTS "${MASTER_USER}@${MASTER_NODE}" \
    "sudo rm -rf ${REMOTE_BACKUP_DIR} && sudo /usr/local/bin/cluster-backup.sh $REMOTE_BACKUP_DIR" 2>&1 | while read line; do log "[master] $line"; done

# Step 2: Fix permissions so we can scp
ssh -i "$SSH_KEY" $SSH_OPTS "${MASTER_USER}@${MASTER_NODE}" \
    "sudo chmod 644 ${REMOTE_BACKUP_DIR}/*"

# Step 3: Copy to iac-control
mkdir -p "$LOCAL_BACKUP_DIR"
scp -i "$SSH_KEY" $SSH_OPTS "${MASTER_USER}@${MASTER_NODE}:${REMOTE_BACKUP_DIR}/*" "$LOCAL_BACKUP_DIR/"
log "Backup files copied to $LOCAL_BACKUP_DIR"
ls -lh "$LOCAL_BACKUP_DIR/"

# Step 4: Upload to MinIO
log "Uploading to MinIO ${MINIO_ALIAS}/${MINIO_BUCKET}/"
mc cp "$LOCAL_BACKUP_DIR/"* "${MINIO_ALIAS}/${MINIO_BUCKET}/"
log "Upload complete"

# Step 5: Prune old backups (keep RETENTION_DAYS days)
log "Pruning backups older than $RETENTION_DAYS days"
mc ls "${MINIO_ALIAS}/${MINIO_BUCKET}/" --json 2>/dev/null | \
    python3 -c "
import sys, json
from datetime import datetime, timedelta, timezone
cutoff = datetime.now(timezone.utc) - timedelta(days=$RETENTION_DAYS)
for line in sys.stdin:
    try:
        obj = json.loads(line)
        ts = datetime.fromisoformat(obj['lastModified'].replace('Z', '+00:00'))
        if ts < cutoff:
            print(obj['key'])
    except: pass
" | while read key; do
    mc rm "${MINIO_ALIAS}/${MINIO_BUCKET}/$key" 2>/dev/null && log "Pruned: $key" || true
done

log "etcd backup completed successfully"
