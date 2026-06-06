#!/bin/bash
# =============================================================================
# iDRAC Node Recovery — Redfish API
# Power management for Proxmox hosts via Dell iDRAC
# Supports iDRAC 14G (Redfish 1.17) and 12G (Redfish 1.4)
# NIST Controls: CP-10 (System Recovery), IR-4 (Incident Handling)
# =============================================================================
set -euo pipefail

# --- Configuration ---
ENV_FILE="/etc/idrac-recovery.env"
LOG_DIR="/var/log/sentinel/idrac"
RECOVERY_LOG="${LOG_DIR}/recovery.log"
CURL_TIMEOUT=15

# Node definitions: name|proxmox_ip|idrac_ip|generation
NODES=(
    "pve|192.168.12.6|192.168.12.10|14G"
    "208-pve2|192.168.12.56|192.168.12.50|14G"
    "pve3|192.168.12.57|192.168.12.202|12G"
)

# --- Helpers ---
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$RECOVERY_LOG"; }
error() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" | tee -a "$RECOVERY_LOG" >&2; }

usage() {
    cat <<'USAGE'
Usage: idrac-node-recovery.sh <command> [node]

Commands:
  status <node>       Check node power state + health via Redfish
  power-cycle <node>  GracefulRestart (14G) or ForceOff+On (12G)
  force-off <node>    Force power off
  power-on <node>     Power on
  nmi <node>          Send NMI diagnostic interrupt
  all-status          Status of all nodes

Nodes: pve, 208-pve2, pve3
USAGE
    exit 1
}

# Load credentials from env file
load_credentials() {
    if [ ! -f "$ENV_FILE" ]; then
        error "Credentials file not found: $ENV_FILE"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$ENV_FILE"
}

# Get node info by name
get_node() {
    local name="$1"
    for node in "${NODES[@]}"; do
        IFS='|' read -r n_name n_proxmox n_idrac n_gen <<< "$node"
        if [ "$n_name" = "$name" ]; then
            NODE_NAME="$n_name"
            NODE_PROXMOX_IP="$n_proxmox"
            NODE_IDRAC_IP="$n_idrac"
            NODE_GEN="$n_gen"
            return 0
        fi
    done
    error "Unknown node: $name (valid: pve, 208-pve2, pve3)"
    exit 1
}

# Get iDRAC credentials for a node
get_idrac_creds() {
    local name="$1"
    case "$name" in
        pve)      IDRAC_USER="${IDRAC_PVE_USER:-}"; IDRAC_PASS="${IDRAC_PVE_PASS:-}" ;;
        208-pve2) IDRAC_USER="${IDRAC_208_PVE2_USER:-}"; IDRAC_PASS="${IDRAC_208_PVE2_PASS:-}" ;;
        pve3)     IDRAC_USER="${IDRAC_PVE3_USER:-}"; IDRAC_PASS="${IDRAC_PVE3_PASS:-}" ;;
        *)        error "No credentials for node: $name"; exit 1 ;;
    esac
    if [ -z "$IDRAC_USER" ] || [ -z "$IDRAC_PASS" ]; then
        error "Missing credentials for $name in $ENV_FILE"
        exit 1
    fi
}

# Redfish GET request
redfish_get() {
    local ip="$1" path="$2"
    curl -sk --connect-timeout "$CURL_TIMEOUT" -m 30 \
        -u "${IDRAC_USER}:${IDRAC_PASS}" \
        "https://${ip}${path}" 2>/dev/null
}

# Redfish POST request (actions)
redfish_post() {
    local ip="$1" path="$2" data="$3"
    curl -sk --connect-timeout "$CURL_TIMEOUT" -m 30 \
        -u "${IDRAC_USER}:${IDRAC_PASS}" \
        -H "Content-Type: application/json" \
        -X POST "https://${ip}${path}" \
        -d "$data" \
        -w "\n%{http_code}" 2>/dev/null
}

# --- Commands ---

cmd_status() {
    local name="$1"
    get_node "$name"
    get_idrac_creds "$name"

    log "Querying status for $NODE_NAME (iDRAC: $NODE_IDRAC_IP, Gen: $NODE_GEN)"

    # Get system info
    local system_data
    system_data=$(redfish_get "$NODE_IDRAC_IP" "/redfish/v1/Systems/System.Embedded.1")
    if [ -z "$system_data" ]; then
        error "iDRAC unreachable at $NODE_IDRAC_IP"
        echo "  Node: $NODE_NAME — iDRAC UNREACHABLE"
        return 1
    fi

    local power_state health model
    power_state=$(echo "$system_data" | jq -r '.PowerState // "Unknown"')
    health=$(echo "$system_data" | jq -r '.Status.Health // "Unknown"')
    model=$(echo "$system_data" | jq -r '.Model // "Unknown"')

    echo "=== $NODE_NAME ==="
    echo "  Model:       $model"
    echo "  iDRAC:       $NODE_IDRAC_IP ($NODE_GEN)"
    echo "  Power State: $power_state"
    echo "  Health:      $health"

    # Get chassis thermal data
    local thermal_data
    thermal_data=$(redfish_get "$NODE_IDRAC_IP" "/redfish/v1/Chassis/System.Embedded.1/Thermal")
    if [ -n "$thermal_data" ]; then
        local inlet_temp
        inlet_temp=$(echo "$thermal_data" | jq -r '
            .Temperatures[]? |
            select(.Name | test("Inlet"; "i")) |
            .ReadingCelsius // "N/A"' 2>/dev/null | head -1)
        echo "  Inlet Temp:  ${inlet_temp:-N/A}°C"

        local fan_health
        fan_health=$(echo "$thermal_data" | jq -r '
            [.Fans[]?.Status.Health // "Unknown"] | unique | join(", ")' 2>/dev/null)
        echo "  Fan Health:  ${fan_health:-N/A}"
    fi

    # Get power/PSU data
    local power_data
    power_data=$(redfish_get "$NODE_IDRAC_IP" "/redfish/v1/Chassis/System.Embedded.1/Power")
    if [ -n "$power_data" ]; then
        local power_watts
        power_watts=$(echo "$power_data" | jq -r '
            .PowerControl[0]?.PowerConsumedWatts // "N/A"' 2>/dev/null)
        echo "  Power Draw:  ${power_watts}W"

        local psu_count psu_ok
        psu_count=$(echo "$power_data" | jq '[.PowerSupplies[]?] | length' 2>/dev/null)
        psu_ok=$(echo "$power_data" | jq '[.PowerSupplies[]? | select(.Status.Health == "OK")] | length' 2>/dev/null)
        echo "  PSUs:        ${psu_ok:-0}/${psu_count:-0} OK"

        # List PSU details
        echo "$power_data" | jq -r '
            .PowerSupplies[]? |
            "    PSU \(.MemberId // .Name // "?"): \(.Status.Health // "Unknown") (\(.PowerCapacityWatts // "?")W)"' 2>/dev/null
    fi

    # Check Proxmox API reachability
    local proxmox_status
    proxmox_status=$(curl -sk --connect-timeout 5 -o /dev/null -w "%{http_code}" \
        "https://${NODE_PROXMOX_IP}:8006/api2/json/version" 2>/dev/null || echo "000")
    if [ "$proxmox_status" = "200" ] || [ "$proxmox_status" = "401" ]; then
        echo "  Proxmox API: OK (HTTP $proxmox_status)"
    else
        echo "  Proxmox API: UNREACHABLE (HTTP $proxmox_status)"
    fi

    echo ""
}

cmd_power_action() {
    local name="$1" action="$2"
    get_node "$name"
    get_idrac_creds "$name"

    local reset_type="$action"
    local action_path="/redfish/v1/Systems/System.Embedded.1/Actions/ComputerSystem.Reset"

    log "Executing $reset_type on $NODE_NAME via iDRAC $NODE_IDRAC_IP"

    local response http_code body
    response=$(redfish_post "$NODE_IDRAC_IP" "$action_path" \
        "{\"ResetType\": \"$reset_type\"}")

    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log "SUCCESS: $reset_type sent to $NODE_NAME (HTTP $http_code)"
        echo "Power action $reset_type sent to $NODE_NAME successfully"
    else
        error "FAILED: $reset_type on $NODE_NAME — HTTP $http_code"
        echo "Failed to send $reset_type to $NODE_NAME (HTTP $http_code)"
        echo "$body" | jq -r '.error.message // .' 2>/dev/null || echo "$body"
        return 1
    fi
}

cmd_power_cycle() {
    local name="$1"
    get_node "$name"
    get_idrac_creds "$name"

    if [ "$NODE_GEN" = "12G" ]; then
        # 12G doesn't support GracefulRestart reliably — ForceOff + On
        log "12G node $NODE_NAME: using ForceOff + On sequence"
        echo "Node $NODE_NAME is 12G — using ForceOff + On (no GracefulRestart)"

        cmd_power_action "$name" "ForceOff"
        echo "Waiting 10s for power off..."
        sleep 10

        cmd_power_action "$name" "On"
    else
        # 14G supports GracefulRestart
        cmd_power_action "$name" "GracefulRestart"
    fi
}

cmd_all_status() {
    log "Querying all node status"
    for node in "${NODES[@]}"; do
        IFS='|' read -r n_name _ _ _ <<< "$node"
        cmd_status "$n_name" || true
    done
}

# --- Main ---
mkdir -p "$LOG_DIR"

if [ $# -lt 1 ]; then
    usage
fi

COMMAND="$1"
NODE_ARG="${2:-}"

load_credentials

case "$COMMAND" in
    status)
        [ -z "$NODE_ARG" ] && { error "Node name required"; usage; }
        cmd_status "$NODE_ARG"
        ;;
    power-cycle)
        [ -z "$NODE_ARG" ] && { error "Node name required"; usage; }
        cmd_power_cycle "$NODE_ARG"
        ;;
    force-off)
        [ -z "$NODE_ARG" ] && { error "Node name required"; usage; }
        cmd_power_action "$NODE_ARG" "ForceOff"
        ;;
    power-on)
        [ -z "$NODE_ARG" ] && { error "Node name required"; usage; }
        cmd_power_action "$NODE_ARG" "On"
        ;;
    nmi)
        [ -z "$NODE_ARG" ] && { error "Node name required"; usage; }
        cmd_power_action "$NODE_ARG" "Nmi"
        ;;
    all-status)
        cmd_all_status
        ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        ;;
esac
