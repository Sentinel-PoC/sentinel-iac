#!/usr/bin/env bash
# Keycloak three-layer backup script (OPS-632)
# Layers 1 (pg_dump) + 2 (realm JSON) → upload to MinIO
#
# Required env vars (injected from ExternalSecret keycloak-backup-config):
#   MINIO_ENDPOINT    — e.g. http://192.168.12.58:9000
#   MINIO_ACCESS_KEY  — scoped MinIO access key
#   MINIO_SECRET_KEY  — scoped MinIO secret key
#   KC_ADMIN_USERNAME — Keycloak admin username (from secret/keycloak/admin)
#   KC_ADMIN_PASSWORD — Keycloak admin password
#   KC_REALM          — realm to export (default: sentinel)
#
# In-cluster: uses ServiceAccount token at /var/run/secrets/kubernetes.io/serviceaccount/
# kubectl exec is used for Layers 1+2 — bypasses NetworkPolicy (k8s API→kubelet path)

set -euo pipefail

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
DOW=$(date -u +%u)   # 1=Mon..7=Sun
DOM=$(date -u +%d)   # 01-31
KC_REALM="${KC_REALM:-sentinel}"
KEYCLOAK_NS="${KEYCLOAK_NS:-keycloak}"
MINIO_BUCKET="${MINIO_BUCKET:-keycloak-backups}"

# Determine upload tier by day
TIER="daily"
[[ "${DOW}" == "7" ]]  && TIER="weekly"
[[ "${DOM}" == "01" ]] && TIER="monthly"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

log "=== Keycloak backup started: tier=${TIER} timestamp=${TIMESTAMP} ==="

# ─── Layer 1: pg_dump via kubectl exec ────────────────────────────────────────
log "Layer 1: locating running postgresql pod in namespace ${KEYCLOAK_NS}"
PG_POD=$(kubectl -n "${KEYCLOAK_NS}" get pods \
    -l app=postgresql \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

[[ -z "${PG_POD}" ]] && die "no running postgresql pod found in namespace ${KEYCLOAK_NS}"
log "Layer 1: pg_dump from pod ${PG_POD}"

# pg_dump runs inside the postgresql container which already has POSTGRES_USER/DB/PASSWORD
# -Fc = custom format (restorable with pg_restore), -Z 9 = max compression
# stdout of the exec'd command flows to the backup container's stdout → local file
kubectl -n "${KEYCLOAK_NS}" exec "${PG_POD}" -- \
    sh -c 'pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc -Z 9' \
    > "/tmp/keycloak-${TIMESTAMP}.dump"

DUMP_SIZE=$(du -sh "/tmp/keycloak-${TIMESTAMP}.dump" | cut -f1)
log "Layer 1: complete — ${DUMP_SIZE} written to /tmp/keycloak-${TIMESTAMP}.dump"

# ─── Layer 2: Keycloak realm JSON export via kcadm.sh inside keycloak pod ─────
log "Layer 2: locating running keycloak pod in namespace ${KEYCLOAK_NS}"
KC_POD=$(kubectl -n "${KEYCLOAK_NS}" get pods \
    -l app=keycloak \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

LAYER2_OK=false
if [[ -z "${KC_POD}" ]]; then
    log "WARN: no running keycloak pod found; skipping Layer 2 (realm JSON export)"
else
    log "Layer 2: realm export from pod ${KC_POD} using kcadm.sh"
    # kcadm.sh is a REST API client in the Keycloak 26.x container.
    # Using --config /tmp/kcadm.config to avoid home-directory issues with random UIDs.
    # We exec with env vars injected so the password isn't exposed in process args.
    kubectl -n "${KEYCLOAK_NS}" exec "${KC_POD}" -- \
        env \
            _KC_ADMIN="${KC_ADMIN_USERNAME}" \
            _KC_PASS="${KC_ADMIN_PASSWORD}" \
            _KC_REALM="${KC_REALM}" \
        sh -c '
            set -e
            /opt/keycloak/bin/kcadm.sh config credentials \
                --config /tmp/kcadm.config \
                --server http://localhost:8080 \
                --realm master \
                --user "${_KC_ADMIN}" \
                --password "${_KC_PASS}"
            /opt/keycloak/bin/kcadm.sh create \
                "realms/${_KC_REALM}/partial-export?exportClients=true&exportGroupsAndRoles=true" \
                --config /tmp/kcadm.config \
                --format json
        ' > "/tmp/realm-${TIMESTAMP}.json"

    REALM_SIZE=$(du -sh "/tmp/realm-${TIMESTAMP}.json" | cut -f1)
    log "Layer 2: complete — ${REALM_SIZE} written to /tmp/realm-${TIMESTAMP}.json"
    LAYER2_OK=true
fi

# ─── Upload to MinIO ──────────────────────────────────────────────────────────
log "MinIO: configuring mc alias"
mc alias set minio "${MINIO_ENDPOINT}" "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" --quiet

log "MinIO: uploading Layer 1 dump to ${MINIO_BUCKET}/${TIER}/"
mc cp "/tmp/keycloak-${TIMESTAMP}.dump" \
    "minio/${MINIO_BUCKET}/${TIER}/keycloak-${TIMESTAMP}.dump"
log "MinIO: Layer 1 upload complete"

if [[ "${LAYER2_OK}" == "true" ]]; then
    log "MinIO: uploading Layer 2 realm JSON to ${MINIO_BUCKET}/${TIER}/"
    mc cp "/tmp/realm-${TIMESTAMP}.json" \
        "minio/${MINIO_BUCKET}/${TIER}/realm-${TIMESTAMP}.json"
    log "MinIO: Layer 2 upload complete"
fi

# Verify uploads
log "MinIO: verifying uploads"
mc ls "minio/${MINIO_BUCKET}/${TIER}/" | grep "${TIMESTAMP}" || \
    log "WARN: timestamp not found in listing — upload may have failed"

log "=== Backup complete: tier=${TIER} timestamp=${TIMESTAMP} layer2=${LAYER2_OK} ==="
