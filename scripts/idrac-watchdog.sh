#!/bin/bash
# =============================================================================
# iDRAC Watchdog — Automatic Node Recovery
# Monitors Proxmox API availability, triggers iDRAC power cycle after threshold
# Runs every 5 minutes (offset from health check) via systemd timer
# NIST Controls: CP-10 (System Recovery), CP-2 (Contingency Plan)
# =============================================================================
set -euo pipefail

# --- Configuration ---
ENV_FILE="/etc/idrac-recovery.env"
LIB_PATH="/home/ubuntu/scripts/_sentinel-lib.sh"
LOG_DIR="/var/log/sentinel/idrac"
RECOVERY_LOG="${LOG_DIR}/recovery.log"
STATE_DIR="/var/run/idrac-watchdog"
CURL_TIMEOUT=10
FAIL_THRESHOLD="${IDRAC_WATCHDOG_FAIL_THRESHOLD:-3}"
MAINTENANCE_FLAG="/tmp/sentinel-maintenance-mode"

# Node definitions: name|proxmox_ip|idrac_ip|generation
NODES=(
    "pve|192.168.12.6|192.168.12.10|14G"
    "208-pve2|192.168.12.56|192.168.12.50|14G"
    "pve3|192.168.12.57|192.168.12.202|12G"
)

# --- Helpers ---
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$RECOVERY_LOG"; }
error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "$RECOVERY_LOG" >&2; }

json_event() {
    local event="$1" node="$2" detail="$3"
    echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"$event\",\"node\":\"$node\",\"detail\":\"$detail\"}" >> "${LOG_DIR}/health.json"
}

# Check maintenance mode
if [ -f "$LIB_PATH" ]; then
    # shellcheck source=/dev/null
    source "$LIB_PATH"
    if check_maintenance "all" 2>/dev/null; then
        log "Watchdog skipped: maintenance mode active (scope=all)"
        exit 0
    fi
    if check_maintenance "remediation" 2>/dev/null; then
        log "Watchdog skipped: maintenance mode active (scope=remediation)"
        exit 0
    fi
fi

# Also check simple flag file
if [ -f "$MAINTENANCE_FLAG" ]; then
    log "Watchdog skipped: maintenance flag active"
    exit 0
fi

# Check if watchdog is globally disabled
if [ "${IDRAC_WATCHDOG_ENABLED:-true}" = "false" ]; then
    log "Watchdog disabled globally (IDRAC_WATCHDOG_ENABLED=false)"
    exit 0
fi

# Load credentials
if [ ! -f "$ENV_FILE" ]; then
    error "Credentials file not found: $ENV_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Redfish POST for power action
redfish_post() {
    local ip="$1" user="$2" pass="$3" action="$4"
    local path="/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"
    curl -sk --connect-timeout "$CURL_TIMEOUT" -m 30 \
        -u "${user}:${pass}" \
        -H "Content-Type: application/json" \
        -X POST "https://${ip}${path}" \
        -d "{\"ResetType\": \"$action\"}" \
        -o /dev/null -w "%{http_code}" 2>/dev/null
}

for node_entry in "${NODES[@]}"; do
    IFS='|' read -r name proxmox_ip idrac_ip generation <<< "$node_entry"

    # Check per-node disable flag
    disable_file="${STATE_DIR}/${name}.disabled"
    if [ -f "$disable_file" ]; then
        log "$name: watchdog disabled (${disable_file} exists)"
        continue
    fi

    fail_file="${STATE_DIR}/${name}.fails"
    cooldown_file="${STATE_DIR}/${name}.cooldown"

    # Check cooldown (don't retry recovery for 15 minutes after a power cycle)
    if [ -f "$cooldown_file" ]; then
        cooldown_time=$(cat "$cooldown_file")
        now=$(date +%s)
        elapsed=$((now - cooldown_time))
        if [ "$elapsed" -lt 900 ]; then
            remaining=$(( (900 - elapsed) / 60 ))
            log "$name: in cooldown (${remaining}min remaining after power cycle)"
            continue
        else
            rm -f "$cooldown_file"
        fi
    fi

    # Check Proxmox API
    http_code=$(curl -sk --connect-timeout "$CURL_TIMEOUT" -o /dev/null -w "%{http_code}" \
        "https://${proxmox_ip}:8006/api2/json/version" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ] || [ "$http_code" = "401" ]; then
        # Node is healthy — reset fail counter
        if [ -f "$fail_file" ]; then
            old_count=$(cat "$fail_file")
            rm -f "$fail_file"
            if [ "$old_count" -gt 0 ] 2>/dev/null; then
                log "$name: recovered (was at $old_count consecutive failures)"
                json_event "IDRAC_NODE_RECOVERED" "$name" "Recovered after $old_count failures"
            fi
        fi
        continue
    fi

    # Node is unreachable — increment fail counter
    current_fails=0
    if [ -f "$fail_file" ]; then
        current_fails=$(cat "$fail_file")
    fi
    current_fails=$((current_fails + 1))
    echo "$current_fails" > "$fail_file"

    log "$name: Proxmox API unreachable (HTTP $http_code) — failure $current_fails/$FAIL_THRESHOLD"
    json_event "IDRAC_NODE_UNREACHABLE" "$name" "HTTP $http_code, failure $current_fails/$FAIL_THRESHOLD"

    # Check if threshold reached
    if [ "$current_fails" -ge "$FAIL_THRESHOLD" ]; then
        log "ALERT: $name has been unreachable for $current_fails checks — triggering power cycle"
        json_event "IDRAC_AUTO_RECOVERY" "$name" "Triggering power cycle after $current_fails consecutive failures"

        # Get credentials
        case "$name" in
            pve)      user="${IDRAC_PVE_USER:-}"; pass="${IDRAC_PVE_PASS:-}" ;;
            208-pve2) user="${IDRAC_208_PVE2_USER:-}"; pass="${IDRAC_208_PVE2_PASS:-}" ;;
            pve3)     user="${IDRAC_PVE3_USER:-}"; pass="${IDRAC_PVE3_PASS:-}" ;;
        esac

        if [ -z "$user" ] || [ -z "$pass" ]; then
            error "$name: cannot power cycle — missing iDRAC credentials"
            continue
        fi

        if [ "$generation" = "12G" ]; then
            # 12G: ForceOff + On
            log "$name: 12G node — sending ForceOff"
            result=$(redfish_post "$idrac_ip" "$user" "$pass" "ForceOff")
            if [ "$result" = "204" ] || [ "$result" = "200" ]; then
                log "$name: ForceOff sent (HTTP $result), waiting 10s before power on"
                sleep 10
                result=$(redfish_post "$idrac_ip" "$user" "$pass" "On")
                log "$name: Power On sent (HTTP $result)"
            else
                error "$name: ForceOff failed (HTTP $result)"
            fi
        else
            # 14G: GracefulRestart
            log "$name: 14G node — sending GracefulRestart"
            result=$(redfish_post "$idrac_ip" "$user" "$pass" "GracefulRestart")
            if [ "$result" = "204" ] || [ "$result" = "200" ]; then
                log "$name: GracefulRestart sent (HTTP $result)"
            else
                error "$name: GracefulRestart failed (HTTP $result)"
            fi
        fi

        # Set cooldown and reset counter
        date +%s > "$cooldown_file"
        echo "0" > "$fail_file"

        json_event "IDRAC_POWER_CYCLE_SENT" "$name" "Power cycle triggered via iDRAC $idrac_ip"
    fi
done

log "Watchdog check complete"
