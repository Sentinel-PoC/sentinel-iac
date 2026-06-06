#!/bin/bash
# OPS-42: MinIO bucket replication — primary (192.168.12.58) to replica (192.168.12.59)
# Runs on iac-control via systemd timer (minio-replicate.timer, every 6h).
# Credentials injected by systemd EnvironmentFile=/etc/sentinel/minio-replicate.env.
#
# Migrated from OKD CronJob (sentinel-ops/minio-replicate) to iac-control
# because OKD pod-to-LXC (mgmt VLAN) connectivity is intermittent/unreliable.
# iac-control has reliable direct access to 192.168.12.58 and .59.
#
# Env vars required (from /etc/sentinel/minio-replicate.env):
#   MINIO_PRIMARY_URL   — e.g. http://192.168.12.58:9000
#   MINIO_REPLICA_URL   — e.g. http://192.168.12.59:9000
#   MINIO_AK            — access key (shared between primary and replica)
#   MINIO_SK            — secret key (shared between primary and replica)

set -euo pipefail

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# mc needs a writable config dir; use a temp dir isolated per run
export MC_CONFIG_DIR
MC_CONFIG_DIR=$(mktemp -d /tmp/.mc-replicate-XXXXXX)

cleanup() {
    rm -rf "${MC_CONFIG_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

log "Configuring mc aliases (primary=${MINIO_PRIMARY_URL} replica=${MINIO_REPLICA_URL})..."
mc alias set primary "${MINIO_PRIMARY_URL}" "${MINIO_AK}" "${MINIO_SK}" --api s3v4 >/dev/null 2>&1 \
    || { log "FATAL: Cannot configure primary MinIO alias at ${MINIO_PRIMARY_URL}"; exit 1; }
mc alias set replica "${MINIO_REPLICA_URL}" "${MINIO_AK}" "${MINIO_SK}" --api s3v4 >/dev/null 2>&1 \
    || { log "FATAL: Cannot configure replica MinIO alias at ${MINIO_REPLICA_URL}"; exit 1; }

# Verify connectivity before attempting replication
log "Testing primary MinIO connectivity..."
if ! mc ls primary/ --connect-timeout 10 >/dev/null 2>&1; then
    log "FATAL: Cannot reach primary MinIO at ${MINIO_PRIMARY_URL}"
    exit 1
fi
log "Primary MinIO reachable."

log "Testing replica MinIO connectivity..."
if ! mc ls replica/ --connect-timeout 10 >/dev/null 2>&1; then
    log "FATAL: Cannot reach replica MinIO at ${MINIO_REPLICA_URL}"
    exit 1
fi
log "Replica MinIO reachable."

BUCKETS="vault-backups etcd-backups terraform-state"
FAILURES=0

for bucket in $BUCKETS; do
    log "Replicating ${bucket}..."
    if mc mirror --overwrite "primary/${bucket}" "replica/${bucket}" 2>&1; then
        log "${bucket}: OK"
    else
        log "${bucket}: FAILED"
        FAILURES=$((FAILURES + 1))
    fi
done

if [ "${FAILURES}" -gt 0 ]; then
    log "Replication completed with ${FAILURES} bucket failure(s)"
    exit 1
fi
log "All buckets replicated successfully."
