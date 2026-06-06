#!/bin/bash
# =============================================================================
# iDRAC Health Monitor — Redfish API
# Queries hardware health for all Proxmox hosts
# Outputs JSON to /var/log/sentinel/idrac/health.json (Wazuh-parseable)
# Runs every 5 minutes via systemd timer
# NIST Controls: SI-4 (System Monitoring), PE-14 (Environmental Controls)
# =============================================================================
set -euo pipefail

# --- Configuration ---
ENV_FILE="/etc/idrac-recovery.env"
LIB_PATH="/home/ubuntu/scripts/_sentinel-lib.sh"
LOG_DIR="/var/log/sentinel/idrac"
HEALTH_LOG="${LOG_DIR}/health.json"
CURL_TIMEOUT=15

# Thresholds
TEMP_WARN=35
TEMP_CRIT=40

# Node definitions: name|proxmox_ip|idrac_ip|generation
NODES=(
    "pve|192.168.12.6|192.168.12.10|14G"
    "208-pve2|192.168.12.56|192.168.12.50|14G"
    "pve3|192.168.12.57|192.168.12.202|12G"
)

# --- Helpers ---
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }

# Check maintenance mode
if [ -f "$LIB_PATH" ]; then
    # shellcheck source=/dev/null
    source "$LIB_PATH"
    if check_maintenance "all" 2>/dev/null; then
        log "Health check skipped: maintenance mode active"
        exit 0
    fi
fi

# Load credentials from env file
if [ ! -f "$ENV_FILE" ]; then
    log "ERROR: Credentials file not found: $ENV_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

mkdir -p "$LOG_DIR"

# Redfish GET request
redfish_get() {
    local ip="$1" path="$2" user="$3" pass="$4"
    curl -sk --connect-timeout "$CURL_TIMEOUT" -m 30 \
        -u "${user}:${pass}" \
        "https://${ip}${path}" 2>/dev/null
}

# Emit a JSON health record (appended to health.json, one line per record)
emit_record() {
    echo "$1" >> "$HEALTH_LOG"
    echo "$1"
}

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OVERALL_STATUS="OK"
ALERT_NODES=""

for node_entry in "${NODES[@]}"; do
    IFS='|' read -r name proxmox_ip idrac_ip generation <<< "$node_entry"

    # Get credentials
    case "$name" in
        pve)      user="${IDRAC_PVE_USER:-}"; pass="${IDRAC_PVE_PASS:-}" ;;
        208-pve2) user="${IDRAC_208_PVE2_USER:-}"; pass="${IDRAC_208_PVE2_PASS:-}" ;;
        pve3)     user="${IDRAC_PVE3_USER:-}"; pass="${IDRAC_PVE3_PASS:-}" ;;
    esac

    if [ -z "$user" ] || [ -z "$pass" ]; then
        emit_record "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"IDRAC_CHECK\",\"node\":\"$name\",\"status\":\"ERROR\",\"detail\":\"Missing credentials\"}"
        OVERALL_STATUS="ERROR"
        continue
    fi

    # Query system info
    system_data=$(redfish_get "$idrac_ip" "/redfish/v1/Systems/System.Embedded.1" "$user" "$pass")
    if [ -z "$system_data" ]; then
        emit_record "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"IDRAC_UNREACHABLE\",\"node\":\"$name\",\"idrac_ip\":\"$idrac_ip\",\"status\":\"CRITICAL\"}"
        OVERALL_STATUS="CRITICAL"
        ALERT_NODES="${ALERT_NODES} $name"
        continue
    fi

    power_state=$(echo "$system_data" | jq -r '.PowerState // "Unknown"')
    health=$(echo "$system_data" | jq -r '.Status.Health // "Unknown"')
    model=$(echo "$system_data" | jq -r '.Model // "Unknown"')

    # Query thermal data
    thermal_data=$(redfish_get "$idrac_ip" "/redfish/v1/Chassis/System.Embedded.1/Thermal" "$user" "$pass")
    inlet_temp="null"
    exhaust_temp="null"
    fan_health="Unknown"

    if [ -n "$thermal_data" ]; then
        inlet_temp=$(echo "$thermal_data" | jq -r '
            [.Temperatures[]? | select(.Name | test("Inlet"; "i")) | .ReadingCelsius // null][0] // "null"' 2>/dev/null)
        exhaust_temp=$(echo "$thermal_data" | jq -r '
            [.Temperatures[]? | select(.Name | test("Exhaust"; "i")) | .ReadingCelsius // null][0] // "null"' 2>/dev/null)
        fan_health=$(echo "$thermal_data" | jq -r '
            if [.Fans[]?.Status.Health // "Unknown"] | all(. == "OK") then "OK"
            elif [.Fans[]?.Status.Health // "Unknown"] | any(. == "Critical") then "Critical"
            else "Warning" end' 2>/dev/null || echo "Unknown")
    fi

    # Query power/PSU data
    power_data=$(redfish_get "$idrac_ip" "/redfish/v1/Chassis/System.Embedded.1/Power" "$user" "$pass")
    power_watts="null"
    psu_total=0
    psu_ok=0
    psu_status="Unknown"

    if [ -n "$power_data" ]; then
        power_watts=$(echo "$power_data" | jq -r '.PowerControl[0]?.PowerConsumedWatts // "null"' 2>/dev/null)
        psu_total=$(echo "$power_data" | jq '[.PowerSupplies[]?] | length' 2>/dev/null || echo 0)
        psu_ok=$(echo "$power_data" | jq '[.PowerSupplies[]? | select(.Status.Health == "OK")] | length' 2>/dev/null || echo 0)

        if [ "$psu_ok" -eq "$psu_total" ] && [ "$psu_total" -gt 0 ]; then
            psu_status="OK"
        elif [ "$psu_ok" -gt 0 ]; then
            psu_status="Degraded"
        else
            psu_status="Critical"
        fi
    fi

    # Check Proxmox API
    proxmox_http=$(curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" \
        "https://${proxmox_ip}:8006/api2/json/version" 2>/dev/null || echo "000")
    if [ "$proxmox_http" = "200" ] || [ "$proxmox_http" = "401" ]; then
        proxmox_status="OK"
    else
        proxmox_status="UNREACHABLE"
    fi

    # Determine node alert level
    node_status="OK"
    node_event="IDRAC_HEALTH_OK"

    if [ "$health" = "Critical" ] || [ "$fan_health" = "Critical" ] || [ "$psu_status" = "Critical" ]; then
        node_status="CRITICAL"
        node_event="IDRAC_HEALTH_CRITICAL"
        OVERALL_STATUS="CRITICAL"
        ALERT_NODES="${ALERT_NODES} $name"
    elif [ "$health" = "Warning" ] || [ "$fan_health" = "Warning" ] || [ "$psu_status" = "Degraded" ]; then
        node_status="WARNING"
        node_event="IDRAC_HEALTH_WARNING"
        [ "$OVERALL_STATUS" = "OK" ] && OVERALL_STATUS="WARNING"
    fi

    # Temperature alerts
    if [ "$inlet_temp" != "null" ] && [ "$inlet_temp" != "" ]; then
        if [ "$inlet_temp" -ge "$TEMP_CRIT" ] 2>/dev/null; then
            node_status="CRITICAL"
            node_event="IDRAC_TEMP_CRITICAL"
            OVERALL_STATUS="CRITICAL"
            ALERT_NODES="${ALERT_NODES} $name"
        elif [ "$inlet_temp" -ge "$TEMP_WARN" ] 2>/dev/null; then
            [ "$node_status" = "OK" ] && node_status="WARNING"
            [ "$node_event" = "IDRAC_HEALTH_OK" ] && node_event="IDRAC_TEMP_WARNING"
        fi
    fi

    # PSU redundancy alert
    psu_event=""
    if [ "$psu_total" -gt 1 ] && [ "$psu_ok" -lt "$psu_total" ]; then
        psu_event="IDRAC_PSU_DEGRADED"
        if [ "$psu_ok" -eq 0 ]; then
            psu_event="IDRAC_PSU_FAILURE"
        fi
    fi

    # Emit main health record
    emit_record "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"$node_event\",\"node\":\"$name\",\"model\":\"$model\",\"generation\":\"$generation\",\"power_state\":\"$power_state\",\"health\":\"$health\",\"inlet_temp_c\":$inlet_temp,\"exhaust_temp_c\":$exhaust_temp,\"fan_health\":\"$fan_health\",\"power_watts\":$power_watts,\"psu_ok\":$psu_ok,\"psu_total\":$psu_total,\"psu_status\":\"$psu_status\",\"proxmox_api\":\"$proxmox_status\",\"status\":\"$node_status\"}"

    # Emit separate PSU event if degraded
    if [ -n "$psu_event" ]; then
        emit_record "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"$psu_event\",\"node\":\"$name\",\"psu_ok\":$psu_ok,\"psu_total\":$psu_total,\"status\":\"$node_status\"}"
    fi

    log "$name: power=$power_state health=$health inlet=${inlet_temp}C fans=$fan_health psu=${psu_ok}/${psu_total} watts=$power_watts proxmox=$proxmox_status"
done

# Summary log entry
emit_record "{\"timestamp\":\"$TIMESTAMP\",\"event\":\"IDRAC_CHECK_COMPLETE\",\"overall_status\":\"$OVERALL_STATUS\",\"nodes_checked\":${#NODES[@]}}"

if [ "$OVERALL_STATUS" != "OK" ]; then
    log "ALERT: Overall hardware status is $OVERALL_STATUS — affected nodes:${ALERT_NODES}"
fi

# Rotate health log if > 10MB
if [ -f "$HEALTH_LOG" ]; then
    size=$(stat -f%z "$HEALTH_LOG" 2>/dev/null || stat -c%s "$HEALTH_LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt 10485760 ]; then
        mv "$HEALTH_LOG" "${HEALTH_LOG}.1"
        log "Rotated health log (was ${size} bytes)"
    fi
fi
