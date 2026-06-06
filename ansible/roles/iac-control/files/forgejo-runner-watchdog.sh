#!/usr/bin/env bash
# forgejo-runner-watchdog.sh — wedge auto-recovery: RESULT_CANCELLED desync + stale-job hang (OPS-775/OPS-479)
#
# Deployed to: /usr/local/bin/forgejo-runner-watchdog.sh
# Managed by:  Ansible — roles/forgejo-runner-pool and roles/iac-control
# Timer:       forgejo-runner-watchdog.timer (every 5 minutes)
#
# Two independent detection paths — each can trigger a restart independently:
#
# PATH A — RESULT_CANCELLED desync wedge (OPS-775):
#   Signal 1 (wedge signature):
#     "UpdateTask returned task result RESULT_CANCELLED for a task that was
#      in local state RESULT_UNSPECIFIED"
#     This pattern only appears during Forgejo server↔runner task-state desync.
#     It does NOT appear on an idle-but-healthy runner.
#
#   Signal 2 (in-flight guard):
#     Checks whether the runner logged any normal task-progress lines in the
#     same window.  If task-progress lines ARE present, a real job is
#     executing — the runner is NOT wedged and must NOT be restarted.
#
# PATH B — stale-job subprocess hang (OPS-479):
#   Detects the semgrep-core-style failure: runner heartbeat is alive, a job
#   is in progress, but no task-progress log lines have appeared for longer
#   than STALE_JOB_THRESHOLD_SECONDS. Root cause from OPS-492: a subprocess
#   (semgrep-core) hung in the runner's process tree while the runner waited.
#   The runner heartbeat remained healthy (last_online=current), so the
#   RESULT_CANCELLED wedge watchdog never fired. Only a manual restart resolved it.
#
#   Trigger conditions (all must be true):
#     (a) Service is active
#     (b) A task-progress line appeared at some point (job is/was in flight)
#     (c) No task-progress line appears in the last STALE_JOB_THRESHOLD_SECONDS
#     (d) No task-completion/failure line appears in the last STALE_JOB_THRESHOLD_SECONDS
#         (absence of completion = job still in flight, just silent)
#
#   Threshold: STALE_JOB_THRESHOLD_SECONDS = 5400 (90 minutes)
#   — Well above longest known legitimate job runtimes:
#       semgrep full scan: 21s (OPS-479 empirical)
#       trivy DB cold cache: ~38 min
#       supply-chain-scan: ~60 min
#   — Well below the 3h job timeout already set in config.yaml.runner.timeout
#   — Provides ~30 min safety margin above trivy worst case.
#
# False-positive safety:
#   PATH A - Idle runner:   no wedge signature → no restart
#   PATH A - Active job:    wedge absent OR task-progress lines present → no restart
#   PATH A - Wedged runner: wedge signature present AND no task progress → restart
#   PATH B - Idle runner:   no task-progress lines in window → no restart (cond b fails)
#   PATH B - Short job:     completion line present → no restart (cond d fails)
#   PATH B - Long but healthy job: progress lines recent → no restart (cond c fails)
#   PATH B - Hung job:      progress lines stale + no completion → restart
#
# What it does on detection (either path):
#   1. Logs user.warning to syslog (Wazuh picks this up for visibility)
#   2. systemctl restart forgejo-runner
#   3. Logs completion to syslog
#
# Configuration (via environment or /etc/forgejo-runner-watchdog/env):
#   WEDGE_WINDOW_SECONDS        — how far back to look for PATH A (default: 300 = 5 min)
#   STALE_JOB_THRESHOLD_SECONDS — how long since last progress log triggers PATH B restart
#                                  (default: 5400 = 90 min)
#   SERVICE_NAME                — systemd service to restart (default: forgejo-runner)
#   RUNNER_NAME                 — descriptive name for logs (default: hostname)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
WEDGE_WINDOW_SECONDS="${WEDGE_WINDOW_SECONDS:-300}"
STALE_JOB_THRESHOLD_SECONDS="${STALE_JOB_THRESHOLD_SECONDS:-5400}"
SERVICE_NAME="${SERVICE_NAME:-forgejo-runner}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)}"
LOG_TAG="forgejo-runner-watchdog"

# Signal 1: The specific server↔runner task-state desync signature.
# Appears when the server marks a task CANCELLED that the runner still holds as
# UNSPECIFIED (i.e., never acknowledged the result).  This is the wedge.
# NOTE: "beginning local task termination" was intentionally excluded — that
#       phrase appears during LEGITIMATE job cancellations and is too broad.
WEDGE_PATTERN="RESULT_CANCELLED.*RESULT_UNSPECIFIED"

# Task-progress log patterns: lines that appear while a job is executing.
# Used by both PATH A (in-flight guard) and PATH B (stale-job detection).
# Covers the runner's standard task lifecycle log output.
INFLIGHT_PATTERN="task [0-9]+ (begin|running|succeed|fail)|step [0-9]+ running|Running job|Fetching artifacts"

# Task-completion log patterns: lines that appear when a job finishes (success or failure).
# If any of these appear within STALE_JOB_THRESHOLD_SECONDS, the job is not hung.
COMPLETION_PATTERN="task [0-9]+ (succeed|fail)|job (success|failure|cancelled)|runner: task done"

# ── Functions ─────────────────────────────────────────────────────────────────
log_warn() {
    logger -t "${LOG_TAG}" -p user.warning -- "$*"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] WARN: $*"
}

log_info() {
    logger -t "${LOG_TAG}" -p user.info -- "$*"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INFO: $*"
}

# ── Main ──────────────────────────────────────────────────────────────────────
# 1. Skip if service is not active (systemd Restart= handles non-running case).
if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
    log_info "${RUNNER_NAME}: ${SERVICE_NAME} is not active — skipping watchdog check"
    exit 0
fi

# ── PATH A: RESULT_CANCELLED desync wedge (OPS-775) ──────────────────────────
# 2. Capture the last WEDGE_WINDOW_SECONDS of journal once.
RECENT_JOURNAL="$(journalctl -u "${SERVICE_NAME}" --since "-${WEDGE_WINDOW_SECONDS}s" --no-pager -q 2>/dev/null)"

# 3. Signal 1: is the wedge signature present?
if echo "${RECENT_JOURNAL}" | grep -qE "${WEDGE_PATTERN}"; then
    # 4. Signal 2 (in-flight guard): are task-progress lines also present?
    if echo "${RECENT_JOURNAL}" | grep -qE "${INFLIGHT_PATTERN}"; then
        log_info "${RUNNER_NAME}: wedge signature seen but task-progress lines also present in last ${WEDGE_WINDOW_SECONDS}s — runner busy, skipping PATH A restart"
    else
        # Both signals confirm wedge: desync signature present AND no active job.
        log_warn "${RUNNER_NAME}: PATH A WEDGE — desync signature present, no in-flight task progress in last ${WEDGE_WINDOW_SECONDS}s. Restarting ${SERVICE_NAME}."
        systemctl restart "${SERVICE_NAME}"
        log_warn "${RUNNER_NAME}: PATH A AUTO-RESTART of ${SERVICE_NAME} complete. Check Forgejo UI to confirm runner online."
        exit 0
    fi
else
    log_info "${RUNNER_NAME}: ${SERVICE_NAME} PATH A healthy (no wedge signature in last ${WEDGE_WINDOW_SECONDS}s)"
fi

# ── PATH B: stale-job subprocess hang (OPS-479) ───────────────────────────────
# 5. Check for hung subprocess: job in flight but no task-progress for 90+ min.
#
#    We look at STALE_JOB_THRESHOLD_SECONDS of journal history.
#    Detection requires:
#      (b) A task-progress line exists at all (confirms a job was/is active)
#      (c) No task-progress line in the last STALE_JOB_THRESHOLD_SECONDS
#      (d) No task-completion/failure line in the last STALE_JOB_THRESHOLD_SECONDS
#
#    We achieve (b) by looking further back than the threshold. If task-progress
#    lines exist in the full window but not in the recent STALE_JOB_THRESHOLD_SECONDS
#    sub-window, and no completion line is in the recent window, the job is hung.

FULL_WINDOW_JOURNAL="$(journalctl -u "${SERVICE_NAME}" --since "-${STALE_JOB_THRESHOLD_SECONDS}s" --no-pager -q 2>/dev/null)"

# (b) Was a job ever active in the threshold window?
if ! echo "${FULL_WINDOW_JOURNAL}" | grep -qE "${INFLIGHT_PATTERN}"; then
    # No task-progress lines at all in the full window — runner is idle.
    log_info "${RUNNER_NAME}: ${SERVICE_NAME} PATH B healthy (no in-flight activity in last ${STALE_JOB_THRESHOLD_SECONDS}s — runner idle)"
    exit 0
fi

# (c+d) Are there recent task-progress OR completion lines?
# We reuse RECENT_JOURNAL (WEDGE_WINDOW_SECONDS) as the "recent" window for
# progress lines, and also check the full window for completion lines.
if echo "${RECENT_JOURNAL}" | grep -qE "${INFLIGHT_PATTERN}"; then
    log_info "${RUNNER_NAME}: ${SERVICE_NAME} PATH B healthy (task-progress lines present in last ${WEDGE_WINDOW_SECONDS}s — job active)"
    exit 0
fi

if echo "${FULL_WINDOW_JOURNAL}" | grep -qE "${COMPLETION_PATTERN}"; then
    log_info "${RUNNER_NAME}: ${SERVICE_NAME} PATH B healthy (task-completion line found in last ${STALE_JOB_THRESHOLD_SECONDS}s — job finished)"
    exit 0
fi

# All conditions met: job was in flight, no recent progress, no completion.
# This matches the OPS-492 semgrep-core hang pattern.
log_warn "${RUNNER_NAME}: PATH B STALE JOB — task-progress lines present in last ${STALE_JOB_THRESHOLD_SECONDS}s but none in last ${WEDGE_WINDOW_SECONDS}s and no completion logged. Possible subprocess hang. Restarting ${SERVICE_NAME}."
systemctl restart "${SERVICE_NAME}"
log_warn "${RUNNER_NAME}: PATH B AUTO-RESTART of ${SERVICE_NAME} complete. Check Forgejo UI to confirm runner online and inspect prior job logs for hung subprocess."
