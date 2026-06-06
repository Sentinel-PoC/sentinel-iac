#!/usr/bin/env bash
# netbox-sync-proxmox.sh — Sync VM state from Proxmox API to NetBox IPAM
# Runs as systemd timer on iac-control every 15 minutes
#
# OPS-369: Added auto-create for VMs/CTs present in Proxmox but absent from NetBox.
# Auto-created records are tagged with 'auto-created' for operator review.
# Idempotent: re-runs find and update (not re-create) previously created records.
set -euo pipefail

# --- Configuration from environment ---
NETBOX_API_TOKEN="${NETBOX_API_TOKEN:?NETBOX_API_TOKEN not set}"
NETBOX_API_ENDPOINT="${NETBOX_API_ENDPOINT:-https://netbox.208.haist.farm}"
PROXMOX_API_TOKEN_ID="${PROXMOX_API_TOKEN_ID:?PROXMOX_API_TOKEN_ID not set}"
PROXMOX_API_TOKEN_SECRET="${PROXMOX_API_TOKEN_SECRET:?PROXMOX_API_TOKEN_SECRET not set}"

LOG_DIR="/var/log/sentinel/netbox-sync"
LOG_FILE="${LOG_DIR}/sync-$(date +%Y%m%d).log"

# Proxmox nodes
declare -A PVE_NODES
PVE_NODES=(
    ["pve"]="192.168.12.6"
    ["208-pve2"]="192.168.12.56"
    ["pve3"]="192.168.12.57"
)

# --- Functions ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

# Check maintenance mode
# Use ${HOME:-/root} because systemd service environments do not set HOME;
# set -u would cause "HOME: unbound variable" if we use bare $HOME here.
if [ -x "${HOME:-/root}/scripts/sentinel-maintenance.sh" ]; then
    if "${HOME:-/root}/scripts/sentinel-maintenance.sh" status 2>/dev/null | grep -q "active"; then
        echo "Maintenance mode active, skipping NetBox sync"
        exit 0
    fi
fi

mkdir -p "${LOG_DIR}"
log "Starting Proxmox → NetBox sync"

# Map Proxmox status to NetBox status
map_status() {
    case "$1" in
        running) echo "active" ;;
        stopped) echo "offline" ;;
        paused)  echo "offline" ;;
        *)       echo "offline" ;;
    esac
}

# --- OPS-369: Cluster ID cache for auto-create ---
# Populated on first use per node; avoids repeated API calls for same cluster.
declare -A NB_CLUSTER_CACHE

# lookup_cluster_id NODE_NAME
# Queries NetBox for a cluster matching the Proxmox node name.
# Prints the NetBox cluster ID (integer) or empty string if not found.
# Result is cached in NB_CLUSTER_CACHE.
lookup_cluster_id() {
    local node_name="$1"

    # Return cached result if available
    if [ -n "${NB_CLUSTER_CACHE[$node_name]+_}" ]; then
        echo "${NB_CLUSTER_CACHE[$node_name]}"
        return
    fi

    local response cluster_id
    response=$(curl -sk --connect-timeout 10 \
        -H "Authorization: Token ${NETBOX_API_TOKEN}" \
        -H "Content-Type: application/json" \
        "${NETBOX_API_ENDPOINT}/api/virtualization/clusters/?name=${node_name}" 2>/dev/null) || true

    cluster_id=$(echo "${response}" | python3 -c "
import sys, json
try:
    results = json.load(sys.stdin).get('results', [])
    if results:
        print(results[0]['id'])
except Exception:
    pass
" 2>/dev/null)

    NB_CLUSTER_CACHE[$node_name]="${cluster_id}"
    echo "${cluster_id}"
}

# --- OPS-369: Ensure auto-created tag exists in NetBox ---
# Idempotent: GETs first, only POSTs if the tag is absent.
ensure_nb_tag() {
    local tag_slug="auto-created"
    local tag_name="auto-created"

    local check_response tag_count
    check_response=$(curl -sk --connect-timeout 10 \
        -H "Authorization: Token ${NETBOX_API_TOKEN}" \
        "${NETBOX_API_ENDPOINT}/api/extras/tags/?slug=${tag_slug}" 2>/dev/null) || true

    tag_count=$(echo "${check_response}" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('count', 0))
except Exception:
    print(0)
" 2>/dev/null)

    if [ "${tag_count:-0}" = "0" ]; then
        log "Creating NetBox tag '${tag_slug}' for auto-created records"
        curl -sk --connect-timeout 10 -X POST \
            -H "Authorization: Token ${NETBOX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"name\": \"${tag_name}\", \"slug\": \"${tag_slug}\", \"color\": \"9e9e9e\", \"description\": \"Auto-created by netbox-sync-proxmox (OPS-369)\"}" \
            "${NETBOX_API_ENDPOINT}/api/extras/tags/" 2>/dev/null || true
    fi
}

# Ensure the auto-created tag is present before the main sync loop.
ensure_nb_tag

SYNC_COUNT=0
CREATE_COUNT=0
ERROR_COUNT=0

for node in "${!PVE_NODES[@]}"; do
    node_ip="${PVE_NODES[$node]}"
    pve_url="https://${node_ip}:8006/api2/json"
    pve_auth="PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}"

    log "Querying node: ${node} (${node_ip})"

    # --- QEMU VMs ---
    qemu_response=$(curl -sk --connect-timeout 10 -H "Authorization: ${pve_auth}" \
        "${pve_url}/nodes/${node}/qemu" 2>/dev/null) || {
        log "ERROR: Failed to query QEMU VMs on ${node}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    }

    qemu_vms=$(echo "${qemu_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for vm in data:
        name = vm.get('name', '')
        status = vm.get('status', 'unknown')
        vcpus = vm.get('cpus', 0)
        maxmem = vm.get('maxmem', 0)
        maxdisk = vm.get('maxdisk', 0)
        # maxmem and maxdisk are in bytes
        mem_mb = int(maxmem / 1048576)
        disk_gb = int(maxdisk / 1073741824)
        print(f'{name}|{status}|{vcpus}|{mem_mb}|{disk_gb}')
except Exception:
    pass
" 2>/dev/null)

    while IFS='|' read -r vm_name vm_status vm_vcpus vm_mem vm_disk; do
        [ -z "${vm_name}" ] && continue

        netbox_status=$(map_status "${vm_status}")

        # Look up VM in NetBox by name
        nb_response=$(curl -sk --connect-timeout 10 \
            -H "Authorization: Token ${NETBOX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/?name=${vm_name}" 2>/dev/null) || {
            log "ERROR: Failed to query NetBox for VM ${vm_name}"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        vm_id=$(echo "${nb_response}" | python3 -c "
import sys, json
try:
    results = json.load(sys.stdin).get('results', [])
    if results:
        print(results[0]['id'])
except Exception:
    pass
" 2>/dev/null)

        if [ -z "${vm_id}" ]; then
            # OPS-369: Auto-create VM in NetBox when not found.
            cluster_id=$(lookup_cluster_id "${node}")

            create_data=$(python3 -c "
import json
payload = {
    'name': '${vm_name}',
    'status': '${netbox_status}',
    'vcpus': ${vm_vcpus},
    'memory': ${vm_mem},
    'disk': ${vm_disk},
    'tags': [{'slug': 'auto-created'}],
}
if '${cluster_id}':
    payload['cluster'] = int('${cluster_id}')
print(json.dumps(payload))
")

            create_response=$(curl -sk --connect-timeout 10 -X POST \
                -H "Authorization: Token ${NETBOX_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "${create_data}" \
                "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/" 2>/dev/null) || {
                log "ERROR: Failed to POST NetBox VM ${vm_name}"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                continue
            }

            new_vm_id=$(echo "${create_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    vid = data.get('id')
    if vid:
        print(vid)
except Exception:
    pass
" 2>/dev/null)

            if [ -n "${new_vm_id}" ]; then
                log "CREATED: VM ${vm_name} (QEMU/${node}) → id=${new_vm_id}, status=${netbox_status}, vcpus=${vm_vcpus}, mem=${vm_mem}MB, disk=${vm_disk}GB, cluster=${cluster_id:-unset}"
                CREATE_COUNT=$((CREATE_COUNT + 1))
            else
                log "ERROR: Create failed for VM ${vm_name} — $(echo "${create_response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d)[:200])" 2>/dev/null)"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
            continue
        fi

        # PATCH VM in NetBox
        patch_data=$(python3 -c "
import json
print(json.dumps({
    'status': '${netbox_status}',
    'vcpus': ${vm_vcpus},
    'memory': ${vm_mem},
    'disk': ${vm_disk}
}))
")

        patch_response=$(curl -sk --connect-timeout 10 -X PATCH \
            -H "Authorization: Token ${NETBOX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${patch_data}" \
            "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/${vm_id}/" 2>/dev/null) || {
            log "ERROR: Failed to PATCH NetBox VM ${vm_name} (id=${vm_id})"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        log "SYNCED: ${vm_name} → status=${netbox_status}, vcpus=${vm_vcpus}, mem=${vm_mem}MB, disk=${vm_disk}GB"
        SYNC_COUNT=$((SYNC_COUNT + 1))

    done <<< "${qemu_vms}"

    # --- LXC Containers ---
    lxc_response=$(curl -sk --connect-timeout 10 -H "Authorization: ${pve_auth}" \
        "${pve_url}/nodes/${node}/lxc" 2>/dev/null) || {
        log "ERROR: Failed to query LXC containers on ${node}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        continue
    }

    lxc_cts=$(echo "${lxc_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for ct in data:
        name = ct.get('name', '')
        status = ct.get('status', 'unknown')
        vcpus = ct.get('cpus', 0)
        maxmem = ct.get('maxmem', 0)
        maxdisk = ct.get('maxdisk', 0)
        mem_mb = int(maxmem / 1048576)
        disk_gb = int(maxdisk / 1073741824)
        print(f'{name}|{status}|{vcpus}|{mem_mb}|{disk_gb}')
except Exception:
    pass
" 2>/dev/null)

    while IFS='|' read -r ct_name ct_status ct_vcpus ct_mem ct_disk; do
        [ -z "${ct_name}" ] && continue

        netbox_status=$(map_status "${ct_status}")

        nb_response=$(curl -sk --connect-timeout 10 \
            -H "Authorization: Token ${NETBOX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/?name=${ct_name}" 2>/dev/null) || {
            log "ERROR: Failed to query NetBox for CT ${ct_name}"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        vm_id=$(echo "${nb_response}" | python3 -c "
import sys, json
try:
    results = json.load(sys.stdin).get('results', [])
    if results:
        print(results[0]['id'])
except Exception:
    pass
" 2>/dev/null)

        if [ -z "${vm_id}" ]; then
            # OPS-369: Auto-create LXC container in NetBox when not found.
            cluster_id=$(lookup_cluster_id "${node}")

            create_data=$(python3 -c "
import json
payload = {
    'name': '${ct_name}',
    'status': '${netbox_status}',
    'vcpus': ${ct_vcpus},
    'memory': ${ct_mem},
    'disk': ${ct_disk},
    'tags': [{'slug': 'auto-created'}],
}
if '${cluster_id}':
    payload['cluster'] = int('${cluster_id}')
print(json.dumps(payload))
")

            create_response=$(curl -sk --connect-timeout 10 -X POST \
                -H "Authorization: Token ${NETBOX_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "${create_data}" \
                "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/" 2>/dev/null) || {
                log "ERROR: Failed to POST NetBox CT ${ct_name}"
                ERROR_COUNT=$((ERROR_COUNT + 1))
                continue
            }

            new_vm_id=$(echo "${create_response}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    vid = data.get('id')
    if vid:
        print(vid)
except Exception:
    pass
" 2>/dev/null)

            if [ -n "${new_vm_id}" ]; then
                log "CREATED: CT ${ct_name} (LXC/${node}) → id=${new_vm_id}, status=${netbox_status}, vcpus=${ct_vcpus}, mem=${ct_mem}MB, disk=${ct_disk}GB, cluster=${cluster_id:-unset}"
                CREATE_COUNT=$((CREATE_COUNT + 1))
            else
                log "ERROR: Create failed for CT ${ct_name} — $(echo "${create_response}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d)[:200])" 2>/dev/null)"
                ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
            continue
        fi

        patch_data=$(python3 -c "
import json
print(json.dumps({
    'status': '${netbox_status}',
    'vcpus': ${ct_vcpus},
    'memory': ${ct_mem},
    'disk': ${ct_disk}
}))
")

        patch_response=$(curl -sk --connect-timeout 10 -X PATCH \
            -H "Authorization: Token ${NETBOX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${patch_data}" \
            "${NETBOX_API_ENDPOINT}/api/virtualization/virtual-machines/${vm_id}/" 2>/dev/null) || {
            log "ERROR: Failed to PATCH NetBox CT ${ct_name} (id=${vm_id})"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            continue
        }

        log "SYNCED: ${ct_name} (LXC) → status=${netbox_status}, vcpus=${ct_vcpus}, mem=${ct_mem}MB, disk=${ct_disk}GB"
        SYNC_COUNT=$((SYNC_COUNT + 1))

    done <<< "${lxc_cts}"
done

log "Sync complete: ${SYNC_COUNT} VMs synced, ${CREATE_COUNT} VMs auto-created, ${ERROR_COUNT} errors"
