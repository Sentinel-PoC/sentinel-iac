#!/usr/bin/env bash
# iac-disk-sweep.sh — periodic disk cleanup for iac-control
#
# Deployed to: /usr/local/bin/iac-disk-sweep.sh
# Managed by:  Ansible (iac-control role) — OPS-776
# Timer:       iac-disk-sweep.timer (weekly Saturday 02:00 UTC)
#
# What it cleans:
#   1. Dangling podman images (ubuntu user context via runuser)
#   2. Unused podman volumes (ubuntu user context)
#   3. journald logs — vacuum to 500 MiB max
#
# Alerting:
#   After cleanup, checks disk usage against DISK_ALERT_THRESHOLD_PCT (default 75).
#   If usage exceeds threshold: logs user.crit to syslog → Wazuh picks it up.
#
# What it deliberately does NOT touch:
#   - Named (tagged) podman images — operator-approved removal only
#   - /var/log/audit — auditd logs (AU-9 NIST requirement; managed by auditd)
#   - Git repos in /home/ubuntu — operator-approved cleanup only
#   - /home/ubuntu/.cache — runner action caches (CI functional dependency)
#
# Idempotent: safe to run at any time, no destructive side-effects.

set -euo pipefail

LOG_TAG="iac-disk-sweep"
DISK_ALERT_THRESHOLD_PCT="${DISK_ALERT_THRESHOLD_PCT:-75}"
RUNUSER_UBUNTU="runuser -u ubuntu --"

log() {
    logger -t "${LOG_TAG}" -- "$*"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

disk_usage_pct() {
    df / | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

main() {
    log "=== iac-disk-sweep START (OPS-776) ==="
    BEFORE=$(disk_usage_pct)
    log "Disk usage before sweep: ${BEFORE}%"

    # ── 1. Podman dangling images ────────────────────────────────────────────
    log "Pruning dangling podman images (ubuntu context)..."
    PRUNE_OUT=$(${RUNUSER_UBUNTU} podman image prune -f 2>&1 || true)
    if [[ -n "${PRUNE_OUT}" ]]; then
        log "podman image prune output: ${PRUNE_OUT}"
    else
        log "podman image prune: no dangling images removed"
    fi

    # ── 2. Podman unused volumes ─────────────────────────────────────────────
    log "Pruning unused podman volumes (ubuntu context)..."
    VOL_OUT=$(${RUNUSER_UBUNTU} podman volume prune -f 2>&1 || true)
    if [[ -n "${VOL_OUT}" ]]; then
        log "podman volume prune output: ${VOL_OUT}"
    else
        log "podman volume prune: no unused volumes removed"
    fi

    # ── 3. journald vacuum ───────────────────────────────────────────────────
    log "Vacuuming journald to 500 MiB..."
    JRNL_OUT=$(journalctl --vacuum-size=500M 2>&1 || true)
    log "journalctl --vacuum-size=500M: ${JRNL_OUT}"

    # ── 4. Post-sweep disk report and alerting ───────────────────────────────
    AFTER=$(disk_usage_pct)
    log "Disk usage after sweep: ${AFTER}%"

    if [[ "${AFTER}" -ge "${DISK_ALERT_THRESHOLD_PCT}" ]]; then
        MSG="ALERT: iac-control root disk usage ${AFTER}% >= threshold ${DISK_ALERT_THRESHOLD_PCT}%. Manual cleanup required. Top consumers:"
        log "${MSG}"
        logger -t "${LOG_TAG}" -p user.crit -- "${MSG}"
        TOP=$(du -sh /home/ubuntu/.local/share/containers /home/ubuntu/.cache/trivy /home/ubuntu/.cache/act /var/log/audit /home/ubuntu 2>/dev/null | sort -rh | head -8 || true)
        log "${TOP}"
        logger -t "${LOG_TAG}" -p user.crit -- "Top disk consumers: ${TOP}"
    else
        log "Disk usage ${AFTER}% is below alert threshold ${DISK_ALERT_THRESHOLD_PCT}% — no alert"
    fi

    log "=== iac-disk-sweep DONE ==="
}

main "$@"
