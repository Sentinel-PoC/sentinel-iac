#!/bin/bash
# OKD etcd Data Restoration Script
# Restores etcd snapshot from MinIO backup
#
# USAGE:
#   ./restore-etcd.sh [--date YYYY-MM-DD]
#
# ENVIRONMENT:
#   MINIO_ENDPOINT    - MinIO API endpoint (default: http://192.168.12.58:9000)
#   MINIO_ACCESS_KEY  - MinIO access key (required)
#   MINIO_SECRET_KEY  - MinIO secret key (required)
#   OKD_MASTER        - OKD master node (default: master-1.okd4.haist.farm)
#   KUBECONFIG        - Path to kubeconfig (default: ~/.kube/config)
#
# PREREQUISITES:
#   - SSH access to OKD master nodes (via iac-control)
#   - MinIO credentials configured
#   - Python3 with boto3 installed
#   - Valid kubeconfig with admin access
#
# WARNING: This is a DESTRUCTIVE operation. Restoring etcd will reset
#          the cluster state to the backup point. All changes after
#          the backup will be LOST.

set -euo pipefail

# Defaults
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://192.168.12.58:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-etcd-backups}"
OKD_MASTER="${OKD_MASTER:-master-1.okd4.haist.farm}"
BACKUP_DATE="${1:-latest}"
TEMP_DIR="/tmp/etcd-restore-$$"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

log() { echo "[$(date -Iseconds)] $*"; }
error() { log "ERROR: $*" >&2; exit 1; }

show_help() {
    head -n 35 "$0" | grep "^#" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help ;;
        --date) BACKUP_DATE="$2"; shift 2 ;;
        --master) OKD_MASTER="$2"; shift 2 ;;
        *) error "Unknown option: $1" ;;
    esac
done

# Validate prerequisites
[[ -z "${MINIO_ACCESS_KEY:-}" ]] && error "MINIO_ACCESS_KEY not set"
[[ -z "${MINIO_SECRET_KEY:-}" ]] && error "MINIO_SECRET_KEY not set"
[[ ! -f "$KUBECONFIG" ]] && error "kubeconfig not found at $KUBECONFIG"
command -v python3 >/dev/null || error "python3 not found"
command -v oc >/dev/null || error "oc CLI not found"

log "WARNING: This will restore etcd to a previous state"
log "All cluster changes after the backup will be LOST"
log ""
read -p "Type 'yes' to confirm etcd restore: " confirm
[[ "$confirm" != "yes" ]] && error "Restore cancelled by user"

log "Starting etcd restoration"
log "Target master: ${OKD_MASTER}"
log "Backup date: ${BACKUP_DATE}"

# Create temp directory
mkdir -p "$TEMP_DIR"
trap "rm -rf $TEMP_DIR" EXIT

# Download backup from MinIO
log "Downloading etcd backup from MinIO..."
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
resp = s3.list_objects_v2(Bucket=bucket, Prefix='etcd-snapshot-')
if not resp.get('Contents'):
    print("ERROR: No etcd backups found", file=sys.stderr)
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

# Copy backup to master node
log "Uploading backup to master node..."
scp "$BACKUP_FILE" "core@${OKD_MASTER}:/tmp/etcd-snapshot.db"

# Run etcd restore on master
log "Running etcd restore on ${OKD_MASTER}..."
ssh "core@${OKD_MASTER}" sudo bash <<'REMOTE_SCRIPT'
set -euo pipefail

echo "[$(date -Iseconds)] Starting etcd restore process"

# Stop all etcd-related pods
echo "[$(date -Iseconds)] Stopping static pods..."
mkdir -p /etc/kubernetes/manifests-stopped
mv /etc/kubernetes/manifests/etcd-pod.yaml /etc/kubernetes/manifests-stopped/ || true
mv /etc/kubernetes/manifests/kube-apiserver-pod.yaml /etc/kubernetes/manifests-stopped/ || true
mv /etc/kubernetes/manifests/kube-controller-manager-pod.yaml /etc/kubernetes/manifests-stopped/ || true
mv /etc/kubernetes/manifests/kube-scheduler-pod.yaml /etc/kubernetes/manifests-stopped/ || true

sleep 10

# Backup existing etcd data
echo "[$(date -Iseconds)] Backing up existing etcd data..."
mv /var/lib/etcd/member /var/lib/etcd/member.backup.$(date +%s) || true

# Restore etcd from snapshot
echo "[$(date -Iseconds)] Restoring etcd from snapshot..."
export ETCDCTL_API=3
etcdctl snapshot restore /tmp/etcd-snapshot.db \
  --data-dir /var/lib/etcd/member \
  --skip-hash-check

# Fix permissions
chown -R etcd:etcd /var/lib/etcd/member

# Restart static pods
echo "[$(date -Iseconds)] Restarting static pods..."
mv /etc/kubernetes/manifests-stopped/* /etc/kubernetes/manifests/
rmdir /etc/kubernetes/manifests-stopped

echo "[$(date -Iseconds)] etcd restore complete"
REMOTE_SCRIPT

# Wait for cluster to recover
log "Waiting for cluster to recover (this may take several minutes)..."
sleep 30

for i in {1..60}; do
    if oc get nodes >/dev/null 2>&1; then
        log "Cluster is responding"
        break
    fi
    [[ $i -eq 60 ]] && error "Cluster did not recover within 10 minutes"
    sleep 10
done

# Verify cluster health
log "Checking cluster health..."
oc get clusteroperators

log "etcd restoration complete!"
log ""
log "NEXT STEPS:"
log "1. Monitor cluster operators: oc get co"
log "2. Check all operators reach Available=True"
log "3. Verify pod deployments are healthy"
log "4. Test application functionality"
log ""
log "NOTE: It may take 10-20 minutes for all operators to stabilize"
