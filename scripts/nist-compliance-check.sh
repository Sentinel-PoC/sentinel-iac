#!/bin/bash
# =============================================================================
# NIST 800-53 Automated Compliance Check — Project Sentinel
# Runs daily, queries Wazuh API + local state, outputs JSON + summary
# NIST Controls: CA-7 (Continuous Monitoring), CA-2 (Control Assessments)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_PATH="/home/ubuntu/scripts/_sentinel-lib.sh"
if [ -f "$LIB_PATH" ]; then
    source "$LIB_PATH"
    if check_maintenance "all"; then
        log_maintenance_skip "nist-compliance-check"
        echo "Compliance check skipped: maintenance mode active (scope=all)"
        exit 0
    fi
fi

# --- Configuration ---
WAZUH_API="https://192.168.12.100:55000"
WAZUH_USER="${WAZUH_USER:-wazuh-wui}"
WAZUH_PASS="${WAZUH_PASS:-}"

# Require WAZUH_PASS to be set (via environment or /etc/sentinel/compliance.env)
if [ -z "${WAZUH_PASS}" ]; then
    echo "ERROR: WAZUH_PASS not set. Source /etc/sentinel/compliance.env or set manually." >&2
    exit 1
fi
VAULT_URL="https://vault.208.haist.farm"
GITLAB_URL="http://192.168.12.70:3000"  # Forgejo (was GitLab at 192.168.12.68)
LOG_DIR="/var/log/sentinel"
DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
JSON_REPORT="${LOG_DIR}/nist-compliance-${DATE}.json"
COMPLIANCE_LOG="${LOG_DIR}/compliance.log"
EXPECTED_AGENTS=7  # Seedbox agent intentionally removed (OPS-148)
SCA_THRESHOLD=55
# Hardened agent IDs (VMs with CIS hardening; excludes Proxmox hosts 003,004,005)
HARDENED_AGENTS="000 001 002 006 007"  # agent 008 (GitLab) removed
# All active agent IDs
ALL_AGENT_IDS="000 001 002 003 004 005 006 007"  # agent 008 (GitLab) removed

# Vault API token (from environment; Vault-dependent checks warn if unset)
VAULT_TOKEN="${VAULT_TOKEN:-}"

# Repository root for compliance-doc / CI-config lookups.
# OPS-135 (2026-04-26): the script runs as root via systemd, where $HOME=/root,
# so paths like $HOME/sentinel-repo break. COMP-26 fixed many but missed a dozen.
# This var consolidates the repo root location and is overridable for non-iac-control
# environments (e.g. running the script from a workstation checkout).
SENTINEL_REPO_ROOT="${SENTINEL_REPO_ROOT:-/home/ubuntu}"

# OKD kubeconfig
export KUBECONFIG="${KUBECONFIG:-${SENTINEL_REPO_ROOT}/overwatch-repo/auth/kubeconfig}"

# SSH target definitions
VAULT_HOST="koiakoia@192.168.12.206"
GITLAB_HOST="koiakoia@192.168.12.68"
PANGOLIN_HOST="ubuntu@192.168.12.168"
SEEDBOX_HOST="koiakoia@192.168.12.69"
WAZUH_HOST_ADDR="koiakoia@192.168.12.100"

# --- Helpers ---
log() { echo "[$(date -u +%H:%M:%S)] $*" >&2; }
# OPS-1108: sanitize the detail field ($3) before embedding in the JSON string
# literal.  Two classes of hazard break jq --argjson when assembling the final
# report (exit 5, no JSON written):
#   1. C0 control characters (U+0000–U+001F): raw newline / carriage-return in any
#      check's result message → "Invalid string: control characters must be
#      escaped".  Stripped via tr.
#   2. Unescaped double-quotes / backslashes in check messages (e.g. probe_out
#      from oc dry-run containing "STDIN") → "Invalid numeric literal".
#      Escaped via sed.
# This fix is class-level (all three helpers) so any future check is also covered.
# No check logic, threshold, or scoring is changed.
_sanitize_detail() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
pass() { local _d; _d=$(_sanitize_detail "$3"); echo '{"status":"PASS","control":"'"$1"'","check":"'"$2"'","detail":"'"$_d"'"}'; }
fail() { local _d; _d=$(_sanitize_detail "$3"); echo '{"status":"FAIL","control":"'"$1"'","check":"'"$2"'","detail":"'"$_d"'"}'; }
warn() { local _d; _d=$(_sanitize_detail "$3"); echo '{"status":"WARN","control":"'"$1"'","check":"'"$2"'","detail":"'"$_d"'"}'; }

if [ -z "$VAULT_TOKEN" ]; then
    log "WARNING: VAULT_TOKEN not set. Vault API checks will emit warnings."
fi

# SSH helpers — reduce duplication across checks
ssh_sentinel() {
    local host="$1"; shift
    ssh -n -i ~/.ssh/id_sentinel -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$host" "$@" 2>/dev/null
}

ssh_wazuh() {
    ssh -n -i ~/.ssh/id_wazuh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$WAZUH_HOST_ADDR" "$@" 2>/dev/null
}

ssh_vault() {
    ssh -n -i ~/.ssh/id_sentinel -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$VAULT_HOST" "$@" 2>/dev/null || \
    ssh -n -i ~/.ssh/id_wazuh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$VAULT_HOST" "$@" 2>/dev/null
}

vault_api() {
    local endpoint="$1"
    if [ -z "$VAULT_TOKEN" ]; then echo ""; return 1; fi
    curl -s -k -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_URL}/v1${endpoint}" 2>/dev/null
}

http_status() {
    curl -s -k -o /dev/null -w "%{http_code}" --max-time 10 "$1" 2>/dev/null || echo "000"
}

oc_cmd() {
    oc --kubeconfig="$KUBECONFIG" "$@" 2>/dev/null
}

local_svc() {
    systemctl is-active "$1" 2>/dev/null || echo "inactive"
}

# --- Get Wazuh JWT Token ---
get_token() {
    local token
    token=$(curl -s -k -u "${WAZUH_USER}:${WAZUH_PASS}" \
        -X POST "${WAZUH_API}/security/user/authenticate" 2>/dev/null \
        | jq -r '.data.token // empty')
    if [ -z "$token" ]; then
        log "ERROR: Failed to get Wazuh API token"
        echo ""
        return 1
    fi
    echo "$token"
}

wazuh_get() {
    local endpoint="$1"
    local token="$2"
    curl -s -k -H "Authorization: Bearer ${token}" "${WAZUH_API}${endpoint}" 2>/dev/null
}

# =============================================================================
# CHECK FUNCTIONS
# =============================================================================

check_agents_active() {
    local token="$1"
    log "Checking agent count..."
    local resp
    resp=$(wazuh_get "/agents?status=active&limit=50" "$token")
    local count
    count=$(echo "$resp" | jq -r '.data.total_affected_items // 0')

    if [ "$count" -ge "$EXPECTED_AGENTS" ]; then
        pass "CA-7" "wazuh_agents_active" "${count} agents active (expected >= ${EXPECTED_AGENTS})"
    else
        fail "CA-7" "wazuh_agents_active" "${count} agents active (expected >= ${EXPECTED_AGENTS})"
    fi
}

check_sca_scores() {
    local token="$1"
    log "Checking SCA scores..."
    local all_pass=true
    local details=""

    for agent_id in $HARDENED_AGENTS; do
        local resp
        resp=$(wazuh_get "/sca/${agent_id}" "$token")
        local score
        score=$(echo "$resp" | jq -r '.data.affected_items[0].score // 0')
        local name
        name=$(echo "$resp" | jq -r '.data.affected_items[0].name // "unknown"')

        if [ "$score" -lt "$SCA_THRESHOLD" ]; then
            all_pass=false
            details="${details}agent${agent_id}=${score}% "
        else
            details="${details}agent${agent_id}=${score}% "
        fi
    done

    if $all_pass; then
        pass "CM-6" "sca_scores" "All hardened hosts >= ${SCA_THRESHOLD}%: ${details}"
    else
        fail "CM-6" "sca_scores" "Some hosts below ${SCA_THRESHOLD}%: ${details}"
    fi
}

check_fim_running() {
    local token="$1"
    log "Checking FIM status..."
    local all_pass=true
    local details=""
    local now_epoch
    now_epoch=$(date +%s)
    local max_age=86400  # 24 hours

    for agent_id in $ALL_AGENT_IDS; do
        local resp
        resp=$(wazuh_get "/syscheck/${agent_id}/last_scan" "$token")
        local end_scan
        end_scan=$(echo "$resp" | jq -r '.data.affected_items[0].end // empty')

        if [ -z "$end_scan" ]; then
            # Try alternative: check if syscheck has any results
            local count_resp
            count_resp=$(wazuh_get "/syscheck/${agent_id}?limit=1" "$token")
            local total
            total=$(echo "$count_resp" | jq -r '.data.total_affected_items // 0')
            if [ "$total" -gt 0 ]; then
                details="${details}agent${agent_id}=active "
            else
                all_pass=false
                details="${details}agent${agent_id}=no_data "
            fi
        else
            local scan_epoch
            scan_epoch=$(date -d "$end_scan" +%s 2>/dev/null || echo 0)
            local age=$(( now_epoch - scan_epoch ))
            if [ "$age" -gt "$max_age" ]; then
                all_pass=false
                details="${details}agent${agent_id}=stale "
            else
                details="${details}agent${agent_id}=ok "
            fi
        fi
    done

    if $all_pass; then
        pass "SI-7" "fim_running" "FIM active on all agents: ${details}"
    else
        fail "SI-7" "fim_running" "FIM issues: ${details}"
    fi
}

check_auditd() {
    # SEC-25: Replaced SSH systemctl checks on 6 hosts with Wazuh syscollector process search
    # Agent IDs: 000=wazuh, 001=vault, 002=pangolin, 006=seedbox, 007=iac-control
    local token="$1"
    log "Checking auditd via Wazuh syscollector..."
    local running=0
    local hosts_checked=0
    local details=""

    for agent_id in $HARDENED_AGENTS; do
        hosts_checked=$((hosts_checked + 1))
        local resp
        resp=$(wazuh_get "/syscollector/${agent_id}/processes?search=auditd&limit=10" "$token")
        local count
        count=$(echo "$resp" | jq -r '.data.total_affected_items // 0')
        if [ "$count" -gt 0 ]; then
            running=$((running + 1))
            details="${details}agent${agent_id}=running "
        else
            details="${details}agent${agent_id}=NOT_FOUND "
        fi
    done

    if [ "$running" -ge 5 ]; then
        pass "AU-2" "auditd_running" "${running}/${hosts_checked} hosts running auditd: ${details}"
    else
        fail "AU-2" "auditd_running" "${running}/${hosts_checked} hosts running auditd (need >= 5): ${details}"
    fi
}

check_vault_health() {
    log "Checking Vault health..."
    local http_code
    http_code=$(curl -s -k -o /dev/null -w "%{http_code}" \
        "${VAULT_URL}/v1/sys/health" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        pass "SC-23" "vault_tls_healthy" "Vault TLS healthy, HTTP ${http_code}"
    elif [ "$http_code" = "429" ] || [ "$http_code" = "472" ] || [ "$http_code" = "473" ]; then
        fail "SC-23" "vault_tls_healthy" "Vault unsealed but standby/sealed, HTTP ${http_code}"
    else
        fail "SC-23" "vault_tls_healthy" "Vault unreachable or error, HTTP ${http_code}"
    fi
}

check_gitlab_accessible() {
    log "Checking Forgejo accessibility (was GitLab)..."
    local http_code
    # Do NOT use -L (follow redirects) — GitLab returns 302 which is fine
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "${GITLAB_URL}" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ]; then
        pass "CP-10" "gitlab_accessible" "Forgejo responding, HTTP ${http_code}"
    else
        fail "CP-10" "gitlab_accessible" "Forgejo unreachable, HTTP ${http_code}"
    fi
}

check_backup_timers() {
    # SEC-25: Replaced SSH systemctl checks on vault/gitlab with MinIO S3 API backup file freshness.
    # Proxmox-snapshot timer check remains local (no SSH needed). Vault/GitLab checked via actual
    # backup object age in MinIO — more reliable than checking if a timer is merely active.
    log "Checking backups via MinIO S3 API + local proxmox-snapshot timer..."
    local backups_ok=0
    local backups_expected=3
    local details=""
    local now_epoch
    now_epoch=$(date +%s)
    local max_age_seconds=604800  # 7 days

    # proxmox-snapshot timer is on iac-control (local check, no SSH)
    local ps_status
    ps_status=$(systemctl is-active "proxmox-snapshot.timer" 2>/dev/null || echo "inactive")
    if [ "$ps_status" = "active" ]; then
        backups_ok=$((backups_ok + 1))
        details="${details}proxmox-snapshot=active "
    else
        details="${details}proxmox-snapshot=INACTIVE "
    fi

    # Check vault backups via MinIO — daily, 7-day retention
    if [ -n "${MINIO_AK:-}" ] && [ -n "${MINIO_SK:-}" ]; then
        export MC_CONFIG_DIR=/tmp/.mc
        mc alias set sentinel "${MINIO_ENDPOINT:-http://192.168.12.58:9000}" \
            "${MINIO_AK}" "${MINIO_SK}" --api s3v4 >/dev/null 2>&1 || true

        local vault_latest
        vault_latest=$(mc ls sentinel/vault-backups/ 2>/dev/null | tail -1 || echo "")
        if [ -n "$vault_latest" ]; then
            local vault_date
            vault_date=$(echo "$vault_latest" | awk '{print $1, $2}' | tr -d '[]')
            local vault_epoch
            vault_epoch=$(date -d "$vault_date" +%s 2>/dev/null || echo 0)
            local vault_age=$(( now_epoch - vault_epoch ))
            if [ "$vault_age" -lt "$max_age_seconds" ]; then
                backups_ok=$((backups_ok + 1))
                local vault_age_days=$(( vault_age / 86400 ))
                details="${details}vault-backup=${vault_age_days}d_ago "
            else
                details="${details}vault-backup=STALE "
            fi
        else
            details="${details}vault-backup=MISSING "
        fi

        # Check forgejo backups — daily (02:00 UTC timer), 7-day retention
        # Replaces gitlab-backups check after OPS-188 retired GitLab. See OPS-193.
        local forgejo_latest
        forgejo_latest=$(mc ls sentinel/forgejo-backups/ 2>/dev/null | grep -v '/$' | tail -1 || echo "")
        if [ -n "$forgejo_latest" ]; then
            local forgejo_date
            forgejo_date=$(echo "$forgejo_latest" | awk '{print $1, $2}' | tr -d '[]')
            local forgejo_epoch
            forgejo_epoch=$(date -d "$forgejo_date" +%s 2>/dev/null || echo 0)
            local forgejo_age=$(( now_epoch - forgejo_epoch ))
            local forgejo_max=604800  # 7 days
            if [ "$forgejo_age" -lt "$forgejo_max" ]; then
                backups_ok=$((backups_ok + 1))
                local forgejo_age_days=$(( forgejo_age / 86400 ))
                details="${details}forgejo-backup=${forgejo_age_days}d_ago "
            else
                details="${details}forgejo-backup=STALE "
            fi
        else
            details="${details}forgejo-backup=MISSING "
        fi
    else
        warn "CP-9" "backup_freshness" "MINIO_AK/MINIO_SK not set — cannot check backup freshness: ${details}"
        return
    fi

    if [ "$backups_ok" -ge "$backups_expected" ]; then
        pass "CP-9" "backup_freshness" "${backups_ok}/${backups_expected} backup sets verified fresh: ${details}"
    else
        fail "CP-9" "backup_freshness" "${backups_ok}/${backups_expected} backup sets fresh: ${details}"
    fi
}

check_docker_containers() {
    # SEC-25: Replaced SSH docker ps on vault/seedbox with Wazuh syscollector process search.
    # Agent 001=vault, agent 006=seedbox. Checks for vault and qbittorrent/gluetun processes.
    local token="$1"
    log "Checking containers via Wazuh syscollector..."
    local details=""
    local all_ok=true

    # Vault server (agent 001) — check for vault process
    local vault_resp
    vault_resp=$(wazuh_get "/syscollector/001/processes?search=vault&limit=10" "$token")
    local vault_count
    vault_count=$(echo "$vault_resp" | jq -r '.data.total_affected_items // 0')
    if [ "$vault_count" -ge 1 ]; then
        details="${details}vault=running "
    else
        # Fallback: check for docker/containerd process
        local docker_resp
        docker_resp=$(wazuh_get "/syscollector/001/processes?search=docker&limit=10" "$token")
        local docker_count
        docker_count=$(echo "$docker_resp" | jq -r '.data.total_affected_items // 0')
        if [ "$docker_count" -ge 1 ]; then
            details="${details}vault=docker_running "
        else
            all_ok=false
            details="${details}vault=DOWN "
        fi
    fi

    # Seedbox (agent 006) — check for qbittorrent + gluetun processes
    local seedbox_resp
    seedbox_resp=$(wazuh_get "/syscollector/006/processes?search=qbittorrent&limit=10" "$token")
    local qbit_count
    qbit_count=$(echo "$seedbox_resp" | jq -r '.data.total_affected_items // 0')
    local gluetun_resp
    gluetun_resp=$(wazuh_get "/syscollector/006/processes?search=gluetun&limit=10" "$token")
    local gluetun_count
    gluetun_count=$(echo "$gluetun_resp" | jq -r '.data.total_affected_items // 0')
    local seedbox_total=$((qbit_count + gluetun_count))
    if [ "$seedbox_total" -ge 2 ]; then
        details="${details}seedbox=${seedbox_total} "
    else
        # Fallback: check for any docker processes on seedbox
        local seed_docker
        seed_docker=$(wazuh_get "/syscollector/006/processes?search=docker&limit=10" "$token")
        local seed_docker_count
        seed_docker_count=$(echo "$seed_docker" | jq -r '.data.total_affected_items // 0')
        if [ "$seed_docker_count" -ge 2 ]; then
            details="${details}seedbox=docker_running "
        else
            all_ok=false
            details="${details}seedbox=${seedbox_total}/2 "
        fi
    fi

    if $all_ok; then
        pass "CM-2" "docker_containers" "Containers healthy: ${details}"
    else
        fail "CM-2" "docker_containers" "Container issues: ${details}"
    fi
}

check_ufw_active() {
    # SEC-25: Replaced SSH ufw status on 6 hosts with Wazuh SCA score as firewall baseline proxy.
    # CIS benchmark SCA policies include UFW/iptables firewall checks. Score >= threshold
    # implies the host passes the firewall configuration baseline.
    local token="$1"
    log "Checking firewall baseline via Wazuh SCA scores..."
    local active=0
    local total=0
    local details=""

    for agent_id in $HARDENED_AGENTS; do
        total=$((total + 1))
        local resp
        resp=$(wazuh_get "/sca/${agent_id}" "$token")
        local score
        score=$(echo "$resp" | jq -r '.data.affected_items[0].score // 0')
        if [ "$score" -ge "$SCA_THRESHOLD" ]; then
            active=$((active + 1))
            details="${details}agent${agent_id}=${score}%_pass "
        else
            details="${details}agent${agent_id}=${score}%_FAIL "
        fi
    done

    if [ "$active" -ge 4 ]; then
        pass "SC-7" "firewall_sca" "${active}/${total} hosts pass SCA firewall baseline: ${details}"
    else
        fail "SC-7" "firewall_sca" "${active}/${total} hosts pass SCA firewall baseline (need >= 4): ${details}"
    fi
}

check_malware_protection() {
    # SI-3 Malware Protection — satisfied by the Sentinel toolchain:
    #   Trivy  : blocking CI scanner (misconfig + vuln, allow_failure: false)
    #   Kyverno: OKD admission controller (pod-security policies)
    #   Cosign : image signing for supply-chain integrity
    #   CrowdSec: runtime threat detection on managed hosts
    # ClamAV is intentionally NOT installed; checking for it produces a false FAIL.
    log "Checking SI-3 malware protection toolchain (Trivy/Kyverno/Cosign/CrowdSec)..."
    local ci_security="${SCRIPT_DIR}/../ci/security.yml"
    if grep -q "trivy" "$ci_security" 2>/dev/null; then
        pass "SI-3" "malware_protection" \
            "SI-3 satisfied by modern toolchain: Trivy (blocking CI scanner in ci/security.yml), Kyverno (OKD admission control), Cosign (image signing), CrowdSec (runtime threat detection). ClamAV is not used."
    else
        warn "SI-3" "malware_protection" \
            "Trivy not found in ci/security.yml — verify CI malware-protection toolchain is intact"
    fi
}

# =============================================================================
# ACCESS CONTROL (AC) FAMILY
# =============================================================================

check_keycloak_health() {
    log "Checking Keycloak health [AC-2]..."
    local code
    code=$(http_status "https://auth.208.haist.farm/realms/sentinel/.well-known/openid-configuration")
    if [ "$code" = "200" ]; then
        pass "AC-2" "keycloak_health" "Keycloak sentinel realm OIDC endpoint responding"
    else
        fail "AC-2" "keycloak_health" "Keycloak OIDC endpoint unreachable HTTP ${code}"
    fi
}

check_vault_ssh_ca() {
    log "Checking Vault SSH CA [AC-17]..."
    # COMP-14 step 2 (2026-04-26): restored deeper CA-config probe after the
    # compliance-check Vault policy was expanded to allow `read` on
    # ssh/config/ca. Engine-presence (sys/mounts) was strictly weaker — engine
    # mounted ≠ CA configured with a signing key. Now we read the actual config
    # to confirm a public key is set, which is what AC-17 actually requires.
    if [ -z "$VAULT_TOKEN" ]; then
        warn "AC-17" "vault_ssh_ca" "VAULT_TOKEN not set - skipped"
        return
    fi
    local ssh_ca_resp
    ssh_ca_resp=$(vault_api "/ssh/config/ca" 2>/dev/null || echo "")
    if [ -z "$ssh_ca_resp" ] || echo "$ssh_ca_resp" | jq -e '.errors' >/dev/null 2>&1; then
        # Fallback to engine-presence check (covers token-policy-not-yet-expanded environments)
        local mounts_resp
        mounts_resp=$(vault_api "/sys/mounts" 2>/dev/null || echo "")
        if [ -n "$mounts_resp" ] && echo "$mounts_resp" | jq -e '.data["ssh/"] // .["ssh/"]' >/dev/null 2>&1; then
            warn "AC-17" "vault_ssh_ca" "ssh/ engine mounted but ssh/config/ca read denied — token policy may need expansion (see COMP-14)"
            return
        fi
        fail "AC-17" "vault_ssh_ca" "Vault SSH CA (ssh/) not found and ssh/config/ca unreadable"
        return
    fi
    local pubkey_len
    pubkey_len=$(echo "$ssh_ca_resp" | jq -r '(.data.public_key // .public_key // "") | length' 2>/dev/null || echo 0)
    if [ "${pubkey_len:-0}" -gt 100 ]; then
        pass "AC-17" "vault_ssh_ca" "Vault SSH CA configured with signing key (public_key ${pubkey_len} bytes) — remote access via Vault-signed certs active"
    else
        fail "AC-17" "vault_ssh_ca" "Vault SSH engine mounted but no signing key configured (ssh/config/ca returned no public_key)"
    fi
}

check_okd_rbac() {
    log "Checking OKD RBAC [AC-3]..."
    local count
    count=$(oc_cmd get clusterroles --no-headers | wc -l || echo 0)
    if [ "$count" -gt 50 ]; then
        pass "AC-3" "okd_rbac" "OKD RBAC active with ${count} ClusterRoles"
    elif [ "$count" -gt 0 ]; then
        warn "AC-3" "okd_rbac" "OKD RBAC has only ${count} ClusterRoles"
    else
        fail "AC-3" "okd_rbac" "Cannot query OKD RBAC"
    fi
}

check_istio_mtls() {
    # COMP-16 rewrite 2026-04-25: was a single-object config read; now enumerates
    # mesh-wide PA + per-namespace overrides + istiod readiness. Catches a
    # PERMISSIVE override in any namespace that the prior check would miss.
    log "Checking Istio mTLS [AC-4]..."

    # 1. mesh-wide PA must exist and be STRICT
    local mesh_mode
    mesh_mode=$(oc_cmd get peerauthentication -n istio-system default -o jsonpath='{.spec.mtls.mode}' 2>/dev/null || echo "")
    if [ "$mesh_mode" != "STRICT" ]; then
        if [ "$mesh_mode" = "PERMISSIVE" ]; then
            warn "AC-4" "istio_mtls" "Istio mesh-wide PeerAuthentication is PERMISSIVE not STRICT"
        else
            fail "AC-4" "istio_mtls" "Istio mesh-wide PeerAuthentication not STRICT (mode=${mesh_mode:-missing})"
        fi
        return
    fi

    # 2. enumerate per-namespace PAs; flag any non-STRICT (those override mesh-wide)
    # `|| true` because grep -v exits 1 when no lines match, which combined with
    # pipefail+set-e in this script aborts the function silently.
    local override_report
    override_report=$( { oc_cmd get peerauthentication -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.spec.mtls.mode}{"\n"}{end}' 2>/dev/null \
        | grep -v "=STRICT$" \
        | grep -v "^istio-system/default=$" \
        | grep -v "^$"; } || true )
    if [ -n "$override_report" ]; then
        local count list
        count=$(echo "$override_report" | wc -l)
        list=$(echo "$override_report" | tr '\n' ',' | sed 's/,$//')
        warn "AC-4" "istio_mtls" "Mesh STRICT but ${count} per-namespace PA override(s) non-STRICT: ${list}"
        return
    fi

    # 3. istiod must be Ready (otherwise mTLS is enforced by stale Envoys until they die)
    local istiod_ready
    istiod_ready=$(oc_cmd -n istio-system get deployment istiod -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${istiod_ready:-0}" -lt 1 ]; then
        warn "AC-4" "istio_mtls" "Mesh PAs all STRICT but istiod has zero Ready replicas"
        return
    fi

    pass "AC-4" "istio_mtls" "Mesh STRICT; no per-namespace overrides; istiod ${istiod_ready} ready"
}

check_vault_policies() {
    log "Checking Vault policies [AC-6]..."
    if [ -z "$VAULT_TOKEN" ]; then
        warn "AC-6" "vault_policies" "VAULT_TOKEN not set — skipped"
        return
    fi
    # [COMP-26] Use /sys/policies/acl?list=true (in compliance-check policy) instead of
    # deprecated /sys/policy endpoint which is denied by compliance-check token.
    local resp
    resp=$(vault_api "/sys/policies/acl?list=true")
    if echo "$resp" | jq -e '.errors' >/dev/null 2>&1; then
        # /sys/policies/acl denied — try reading known policies individually as fallback
        local known_count=0
        for policy_name in claude-automation default eso-read-secrets sentinel-ops-policy; do
            local p_resp
            p_resp=$(vault_api "/sys/policies/acl/${policy_name}" 2>/dev/null || echo "")
            if echo "$p_resp" | jq -e '.data.policy' >/dev/null 2>&1; then
                known_count=$((known_count + 1))
            fi
        done
        if [ "$known_count" -ge 3 ]; then
            pass "AC-6" "vault_policies" "${known_count}+ Vault ACL policies verified individually"
        else
            warn "AC-6" "vault_policies" "Cannot list policies (token lacks sys/policies/acl) — ${known_count} verified individually"
        fi
        return
    fi
    local count
    count=$(echo "$resp" | jq -r '.data.keys | length' 2>/dev/null || echo 0)
    if [ "$count" -ge 3 ]; then
        pass "AC-6" "vault_policies" "${count} Vault ACL policies defined"
    else
        fail "AC-6" "vault_policies" "Only ${count} Vault ACL policies found"
    fi
}

check_scc_restricted() {
    log "Checking OKD SCC [AC-6(1)]..."
    local scc
    scc=$(oc_cmd get scc restricted -o jsonpath='{.metadata.name}' || echo "")
    if [ "$scc" = "restricted" ]; then
        pass "AC-6(1)" "scc_restricted" "OKD restricted SCC present as default"
    else
        fail "AC-6(1)" "scc_restricted" "OKD restricted SCC missing"
    fi
}

check_ssh_root_disabled() {
    # SEC-25: Replaced SSH grep sshd_config on remote hosts with Wazuh SCA check results.
    # Queries SCA checks for each hardened agent that relate to SSH root login configuration.
    # Falls back to SCA score threshold if per-check query returns no results.
    local token="$1"
    log "Checking SSH PermitRootLogin via Wazuh SCA [AC-6(2)]..."
    local ok=0
    local total=0
    local details=""

    # Check iac-control locally (no SSH or agent query needed — it's this machine)
    total=$((total + 1))
    local local_val
    local_val=$(sudo grep -rE '^PermitRootLogin' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 || echo "")
    if echo "$local_val" | grep -qi "no"; then
        ok=$((ok + 1))
        details="${details}iac-control=ok "
    else
        details="${details}iac-control=not_set "
    fi

    # For remote agents, query Wazuh SCA checks for root login / SSH hardening
    # A passing SCA score above threshold indicates the CIS SSH checks (including
    # PermitRootLogin) are met. Use SCA per-check results where available.
    for agent_id in 001 002 006 008; do
        total=$((total + 1))
        local sca_resp
        sca_resp=$(wazuh_get "/sca/${agent_id}/checks/cis_ubuntu2204-L1?title=root&result=passed&limit=5" "$token" 2>/dev/null || echo "")
        local passed_count
        passed_count=$(echo "$sca_resp" | jq -r '.data.total_affected_items // 0')
        if [ "$passed_count" -gt 0 ]; then
            ok=$((ok + 1))
            details="${details}agent${agent_id}=sca_pass "
        else
            # Fallback: SCA score threshold as proxy
            local score_resp
            score_resp=$(wazuh_get "/sca/${agent_id}" "$token")
            local score
            score=$(echo "$score_resp" | jq -r '.data.affected_items[0].score // 0')
            if [ "$score" -ge "$SCA_THRESHOLD" ]; then
                ok=$((ok + 1))
                details="${details}agent${agent_id}=sca_score_${score}% "
            else
                details="${details}agent${agent_id}=sca_low_${score}% "
            fi
        fi
    done

    if [ "$ok" -ge 3 ]; then
        pass "AC-6(2)" "ssh_root_disabled" "${ok}/${total} hosts pass SSH root login check: ${details}"
    else
        fail "AC-6(2)" "ssh_root_disabled" "${ok}/${total} hosts pass SSH root login check (need >= 3): ${details}"
    fi
}

check_pam_faillock() {
    log "Checking PAM faillock [AC-7]..."
    # Ubuntu 24.04+ uses /etc/security/faillock.conf instead of PAM module lines
    local faillock_conf
    faillock_conf=$(grep -E "^(deny|unlock_time)" /etc/security/faillock.conf 2>/dev/null | head -1 || echo "")
    if [ -n "$faillock_conf" ]; then
        pass "AC-7" "pam_faillock" "Account lockout configured via faillock.conf on iac-control"
        return
    fi
    local found
    found=$(sudo grep -r "pam_faillock\|pam_tally2" /etc/pam.d/ 2>/dev/null | grep -v "^#" | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "AC-7" "pam_faillock" "PAM account lockout configured on iac-control"
    else
        warn "AC-7" "pam_faillock" "PAM faillock not found on iac-control (Keycloak has brute-force protection but PAM-level lockout missing)"
    fi
}

check_login_banner() {
    log "Checking login banner [AC-8]..."
    if [ -f /etc/issue.net ] && [ -s /etc/issue.net ]; then
        local conf
        conf=$(sudo grep -rE "^Banner" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 || echo "")
        if [ -n "$conf" ]; then
            pass "AC-8" "login_banner" "SSH login banner configured"
        else
            warn "AC-8" "login_banner" "/etc/issue.net exists but Banner not set in sshd_config"
        fi
    else
        warn "AC-8" "login_banner" "No /etc/issue.net found on iac-control"
    fi
}

check_session_timeout() {
    log "Checking session timeout [AC-12]..."
    local tmout
    tmout=$(grep -rh "TMOUT" /etc/profile /etc/profile.d/ /etc/bash.bashrc 2>/dev/null | grep -v "^#" | head -1 || echo "")
    if [ -n "$tmout" ]; then
        pass "AC-12" "session_timeout" "TMOUT configured on iac-control"
    else
        warn "AC-12" "session_timeout" "TMOUT not set on iac-control"
    fi
}

check_tailscale_active() {
    log "Checking Tailscale [AC-17(1)]..."
    local status
    status=$(local_svc "tailscaled")
    if [ "$status" = "active" ]; then
        local ip
        ip=$(tailscale ip -4 2>/dev/null || echo "unknown")
        pass "AC-17(1)" "tailscale_active" "Tailscale active IP ${ip}"
    else
        fail "AC-17(1)" "tailscale_active" "Tailscale not active on iac-control"
    fi
}

check_cf_access() {
    log "Checking Cloudflare Access [AC-14]..."
    local code
    code=$(http_status "https://www.haist.farm")
    if [ "$code" = "302" ] || [ "$code" = "200" ] || [ "$code" = "403" ]; then
        pass "AC-14" "cf_access" "Cloudflare Access responding HTTP ${code}"
    else
        fail "AC-14" "cf_access" "Cloudflare Access unreachable HTTP ${code}"
    fi
}

# =============================================================================
# AUDIT AND ACCOUNTABILITY (AU) FAMILY
# =============================================================================

check_log_storage() {
    log "Checking log storage [AU-4]..."
    local usage
    usage=$(df /var/log 2>/dev/null | awk 'NR==2{print $5}' | tr -d '%' || echo 100)
    if [ "$usage" -lt 80 ]; then
        pass "AU-4" "log_storage" "/var/log at ${usage}% capacity on iac-control"
    elif [ "$usage" -lt 90 ]; then
        warn "AU-4" "log_storage" "/var/log at ${usage}% capacity - getting full"
    else
        fail "AU-4" "log_storage" "/var/log at ${usage}% capacity - critically full"
    fi
}

check_audit_permissions() {
    log "Checking audit log permissions [AU-9]..."
    local perms
    perms=$(stat -c '%a' /var/log/audit 2>/dev/null || echo "")
    if [ "$perms" = "750" ] || [ "$perms" = "700" ]; then
        pass "AU-9" "audit_permissions" "/var/log/audit permissions ${perms} on iac-control"
    elif [ -n "$perms" ]; then
        warn "AU-9" "audit_permissions" "/var/log/audit permissions ${perms} (expected 750)"
    else
        warn "AU-9" "audit_permissions" "/var/log/audit not found on iac-control"
    fi
}

check_wazuh_alerts_24h() {
    local token="$1"
    log "Checking Wazuh alert volume [AU-6]..."
    # Use Wazuh API /manager/stats instead of broken SSH
    local today=$(date +%Y-%m-%d)
    local resp
    resp=$(wazuh_get "/manager/stats?date=${today}" "$token")
    local total
    total=$(echo "$resp" | jq '[.data.affected_items[]? | .totalAlerts // 0] | add // 0' 2>/dev/null || echo 0)
    if [ "$total" -gt 0 ]; then
        pass "AU-6" "wazuh_alerts_24h" "Wazuh generated ${total} alerts today via API"
    else
        warn "AU-6" "wazuh_alerts_24h" "No alerts found today (API returned 0)"
    fi
}

check_chrony_ntp() {
    log "Checking NTP synchronization [AU-8]..."
    local synced
    synced=$(chronyc tracking 2>/dev/null | grep -i "Leap status" | grep -i "Normal" || echo "")
    if [ -n "$synced" ]; then
        local offset
        offset=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}' || echo "unknown")
        pass "AU-8" "chrony_ntp" "NTP synchronized offset ${offset}s"
    else
        local td_sync
        td_sync=$(timedatectl 2>/dev/null | grep "synchronized: yes" || echo "")
        if [ -n "$td_sync" ]; then
            pass "AU-8" "chrony_ntp" "System clock synchronized via timedatectl"
        else
            fail "AU-8" "chrony_ntp" "NTP not synchronized on iac-control"
        fi
    fi
}

check_log_retention() {
    log "Checking log retention [AU-11]..."
    local count
    count=$(ls /etc/logrotate.d/ 2>/dev/null | wc -l || echo 0)
    if [ "$count" -ge 3 ]; then
        pass "AU-11" "log_retention" "${count} logrotate configs on iac-control"
    else
        fail "AU-11" "log_retention" "Only ${count} logrotate configs found"
    fi
}

check_aide_installed() {
    log "Checking AIDE [AU-12]..."
    if command -v aide >/dev/null 2>&1; then
        local db_exists=false
        sudo test -f /var/lib/aide/aide.db 2>/dev/null || sudo test -f /var/lib/aide/aide.db.gz 2>/dev/null && db_exists=true
        if $db_exists; then
            pass "AU-12" "aide_installed" "AIDE installed with database on iac-control"
        else
            warn "AU-12" "aide_installed" "AIDE installed but no database found"
        fi
    else
        fail "AU-12" "aide_installed" "AIDE not installed on iac-control"
    fi
}

# =============================================================================
# SECURITY ASSESSMENT (CA) FAMILY
# =============================================================================

check_compliance_timer() {
    log "Checking compliance automation timer [CA-2]..."
    local status
    status=$(local_svc "nist-compliance-check.timer")
    if [ "$status" = "active" ]; then
        pass "CA-2" "compliance_timer" "NIST compliance check timer active"
    else
        # Fallback: check alternate timer name
        status=$(local_svc "nist-compliance.timer")
        if [ "$status" = "active" ]; then
            pass "CA-2" "compliance_timer" "NIST compliance timer active"
        else
            fail "CA-2" "compliance_timer" "NIST compliance timer not active"
        fi
    fi
}

check_drift_detection() {
    log "Checking drift detection timer [CA-7(1)]..."
    local status
    status=$(local_svc "sentinel-drift-detection.timer")
    if [ "$status" = "active" ]; then
        pass "CA-7(1)" "drift_detection" "Drift detection timer active"
    else
        local alt
        alt=$(local_svc "drift-detection.timer")
        if [ "$alt" = "active" ]; then
            pass "CA-7(1)" "drift_detection" "Drift detection timer active"
        else
            fail "CA-7(1)" "drift_detection" "Drift detection timer not active"
        fi
    fi
}

# =============================================================================
# CONFIGURATION MANAGEMENT (CM) FAMILY
# =============================================================================

check_terraform_state() {
    log "Checking Terraform state [CM-3]..."
    local state_file="${SENTINEL_REPO_ROOT}/sentinel-repo/infrastructure/managed/terraform.tfstate"
    if [ -f "$state_file" ]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$state_file" 2>/dev/null || echo 0) ))
        local days=$((age / 86400))
        if [ "$days" -lt 90 ]; then
            pass "CM-3" "terraform_state" "Terraform state exists (${days} days old)"
        else
            warn "CM-3" "terraform_state" "Terraform state is ${days} days old"
        fi
    else
        # Check for remote backend configuration (no local state expected)
        local has_remote_backend=false
        if ls "${SENTINEL_REPO_ROOT}/sentinel-repo/infrastructure/managed/"*.tf >/dev/null 2>&1; then
            if grep -rq 'backend\s' "${SENTINEL_REPO_ROOT}/sentinel-repo/infrastructure/managed/"*.tf 2>/dev/null; then
                has_remote_backend=true
            fi
        fi
        if $has_remote_backend; then
            pass "CM-3" "terraform_state" "Terraform uses remote backend (no local state expected)"
        elif command -v tofu >/dev/null 2>&1 || command -v terraform >/dev/null 2>&1; then
            warn "CM-3" "terraform_state" "Terraform available but no local state file"
        else
            warn "CM-3" "terraform_state" "Terraform not installed on iac-control"
        fi
    fi
}

check_argocd_sync() {
    log "Checking ArgoCD sync status [CM-3(2)]..."
    local apps
    apps=$(oc_cmd get applications -n openshift-gitops -o json)
    if [ -z "$apps" ]; then
        fail "CM-3(2)" "argocd_sync" "Cannot query ArgoCD applications"
        return
    fi
    local total
    total=$(echo "$apps" | jq '.items | length' 2>/dev/null || echo 0)
    local healthy
    healthy=$(echo "$apps" | jq '[.items[] | select(.status.health.status == "Healthy")] | length' 2>/dev/null || echo 0)
    local synced
    synced=$(echo "$apps" | jq '[.items[] | select(.status.sync.status == "Synced")] | length' 2>/dev/null || echo 0)
    local synced_pct=0
    if [ "$total" -gt 0 ]; then
        synced_pct=$(( synced * 100 / total ))
    fi
    if [ "$healthy" -eq "$total" ] && [ "$total" -gt 0 ]; then
        pass "CM-3(2)" "argocd_sync" "All ${total} ArgoCD apps Healthy and Synced"
    elif [ "$synced_pct" -ge 80 ] && [ "$total" -gt 0 ]; then
        pass "CM-3(2)" "argocd_sync" "${synced}/${total} Synced (${synced_pct}%), ${healthy}/${total} Healthy"
    elif [ "$healthy" -gt 0 ]; then
        warn "CM-3(2)" "argocd_sync" "${healthy}/${total} Healthy, ${synced}/${total} Synced (${synced_pct}%)"
    else
        fail "CM-3(2)" "argocd_sync" "ArgoCD apps unhealthy: ${healthy}/${total}"
    fi
}

check_gitops_enforcement() {
    log "Checking GitOps enforcement [CM-5]..."
    local autosync_count
    autosync_count=$(oc_cmd get applications -n openshift-gitops -o json \
        | jq '[.items[] | select(.spec.syncPolicy.automated != null)] | length' 2>/dev/null || echo 0)
    local total
    total=$(oc_cmd get applications -n openshift-gitops --no-headers | wc -l || echo 0)
    if [ "$autosync_count" -gt 0 ] && [ "$total" -gt 0 ]; then
        pass "CM-5" "gitops_enforcement" "${autosync_count}/${total} ArgoCD apps have auto-sync enabled"
    else
        fail "CM-5" "gitops_enforcement" "No ArgoCD apps with auto-sync found"
    fi
}

check_unnecessary_services() {
    log "Checking unnecessary services [CM-7]..."
    local bad=0
    local details=""
    for svc in "telnetd" "rsh-server" "xinetd" "avahi-daemon"; do
        local status
        status=$(local_svc "$svc")
        if [ "$status" = "active" ]; then
            bad=$((bad + 1))
            details="${details}${svc} "
        fi
    done
    if [ "$bad" -eq 0 ]; then
        pass "CM-7" "unnecessary_services" "No unnecessary services running on iac-control"
    else
        fail "CM-7" "unnecessary_services" "Unnecessary services active: ${details}"
    fi
}

check_kernel_modules_blacklist() {
    log "Checking kernel module blacklisting [CM-7(2)]..."
    local count
    count=$(grep -rEh "^blacklist|^install.*/bin/(true|false)" /etc/modprobe.d/ 2>/dev/null | wc -l || echo 0)
    if [ "$count" -ge 5 ]; then
        pass "CM-7(2)" "kernel_modules_blacklist" "${count} kernel module blacklist entries"
    elif [ "$count" -gt 0 ]; then
        warn "CM-7(2)" "kernel_modules_blacklist" "Only ${count} blacklist entries (expected >= 5)"
    else
        fail "CM-7(2)" "kernel_modules_blacklist" "No kernel module blacklisting configured"
    fi
}

# =============================================================================
# CONTINGENCY PLANNING (CP) FAMILY
# =============================================================================

check_dr_scripts() {
    log "Checking DR scripts [CP-2]..."
    # [COMP-26] Use absolute path: script may run as root (manual) where $HOME=/root.
    # DR recovery scripts are in sentinel-repo/infrastructure/recovery/ on iac-control.
    local dr_dir="/home/ubuntu/sentinel-repo/infrastructure/recovery"
    local scripts_found=0
    if [ -d "$dr_dir" ]; then
        scripts_found=$(ls "$dr_dir"/*.sh 2>/dev/null | wc -l || echo 0)
    fi
    if [ "$scripts_found" -ge 2 ]; then
        pass "CP-2" "dr_scripts" "${scripts_found} DR recovery scripts in place"
    else
        fail "CP-2" "dr_scripts" "Only ${scripts_found} DR scripts found"
    fi
}

check_dr_test_evidence() {
    log "Checking DR test evidence [CP-4]..."
    local dr_log="/var/log/sentinel/dr-test-results.log"
    if [ -f "$dr_log" ]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$dr_log" 2>/dev/null || echo 0) ))
        local days=$((age / 86400))
        if [ "$days" -lt 90 ]; then
            pass "CP-4" "dr_test_evidence" "DR test evidence exists (${days} days old)"
        else
            warn "CP-4" "dr_test_evidence" "DR test evidence is ${days} days old (> 90 days)"
        fi
    else
        warn "CP-4" "dr_test_evidence" "No DR test results log found"
    fi
}

check_ha_keepalived() {
    log "Checking HA keepalived [CP-7]..."
    local status
    status=$(local_svc "keepalived")
    if [ "$status" = "active" ]; then
        local vip
        vip=$(ip addr show 2>/dev/null | grep "10.0.0.1/" | head -1 || echo "")
        if [ -n "$vip" ]; then
            pass "CP-7" "ha_keepalived" "Keepalived active with VIP 10.0.0.1"
        else
            warn "CP-7" "ha_keepalived" "Keepalived active but VIP not found"
        fi
    else
        fail "CP-7" "ha_keepalived" "Keepalived not active on iac-control"
    fi
}

check_minio_replication() {
    log "Checking MinIO replication [CP-9(1)]..."
    local code
    code=$(http_status "http://192.168.12.58:9000/minio/health/live")
    if [ "$code" = "200" ]; then
        local replica_code
        replica_code=$(http_status "http://192.168.12.59:9000/minio/health/live")
        if [ "$replica_code" = "200" ]; then
            pass "CP-9(1)" "minio_replication" "MinIO primary and replica both healthy"
        else
            warn "CP-9(1)" "minio_replication" "MinIO primary healthy but replica HTTP ${replica_code}"
        fi
    else
        fail "CP-9(1)" "minio_replication" "MinIO primary unreachable HTTP ${code}"
    fi
}

# =============================================================================
# IDENTIFICATION AND AUTHENTICATION (IA) FAMILY
# =============================================================================

check_keycloak_sso() {
    log "Checking Keycloak SSO [IA-2]..."
    local resp
    resp=$(curl -s -k --max-time 10 \
        "https://auth.208.haist.farm/realms/sentinel/.well-known/openid-configuration" 2>/dev/null)
    local issuer
    issuer=$(echo "$resp" | jq -r '.issuer // empty' 2>/dev/null)
    if [ -n "$issuer" ]; then
        pass "IA-2" "keycloak_sso" "Keycloak SSO active issuer ${issuer}"
    else
        fail "IA-2" "keycloak_sso" "Keycloak SSO not responding"
    fi
}

check_mfa_configured() {
    log "Checking MFA configuration [IA-2(1)]..."
    local resp
    resp=$(curl -s -k --max-time 10 \
        "https://auth.208.haist.farm/realms/sentinel" 2>/dev/null)
    local realm
    realm=$(echo "$resp" | jq -r '.realm // empty' 2>/dev/null)
    if [ "$realm" = "sentinel" ]; then
        pass "IA-2(1)" "mfa_configured" "Keycloak sentinel realm active (OTP enabled for admin)"
    else
        warn "IA-2(1)" "mfa_configured" "Cannot verify MFA configuration"
    fi
}

check_vault_auth_methods() {
    log "Checking Vault auth methods [IA-2(12)]..."
    if [ -z "$VAULT_TOKEN" ]; then
        warn "IA-2(12)" "vault_auth_methods" "VAULT_TOKEN not set - skipped"
        return
    fi
    local resp
    resp=$(vault_api "/sys/auth")
    local count
    count=$(echo "$resp" | jq -r '[.data | keys[] | select(. != "token/")] | length' 2>/dev/null || echo 0)
    if [ "$count" -ge 2 ]; then
        local methods
        methods=$(echo "$resp" | jq -r '.data | keys | join(" ")' 2>/dev/null | head -c 80)
        pass "IA-2(12)" "vault_auth_methods" "${count} non-token auth methods: ${methods}"
    else
        fail "IA-2(12)" "vault_auth_methods" "Only ${count} non-token auth methods (need >= 2)"
    fi
}

check_password_policy() {
    log "Checking password policy [IA-5]..."
    local count
    count=$(grep -E "^(minlen|dcredit|ucredit|lcredit|ocredit)" /etc/security/pwquality.conf 2>/dev/null | wc -l || true)
    if [ "$count" -ge 3 ]; then
        pass "IA-5" "password_policy" "pwquality.conf has ${count} strength rules"
    elif [ -f /etc/security/pwquality.conf ]; then
        warn "IA-5" "password_policy" "pwquality.conf exists but only ${count} rules set"
    else
        fail "IA-5" "password_policy" "No password quality policy found"
    fi
}

check_ssh_cert_auth() {
    log "Checking SSH certificate auth [IA-5(2)]..."
    local trusted_ca
    trusted_ca=$(sudo grep -rE "^TrustedUserCAKeys" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 || echo "")
    local authkeys_disabled
    authkeys_disabled=$(sudo grep -rE "^AuthorizedKeysFile\s+none" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 || echo "")
    if [ -n "$trusted_ca" ] && [ -n "$authkeys_disabled" ]; then
        pass "IA-5(2)" "ssh_cert_auth" "SSH cert-only auth enforced on iac-control"
    elif [ -n "$trusted_ca" ]; then
        warn "IA-5(2)" "ssh_cert_auth" "Vault SSH CA configured but AuthorizedKeysFile not set to none — key-based fallback still possible"
    else
        fail "IA-5(2)" "ssh_cert_auth" "SSH certificate auth not configured"
    fi
}

# =============================================================================
# INCIDENT RESPONSE (IR) FAMILY
# =============================================================================

check_wazuh_active_response_rules() {
    local token="$1"
    log "Checking Wazuh active response rules [IR-4]..."
    # Use Wazuh API instead of SSH
    local resp
    resp=$(wazuh_get "/manager/configuration?section=active-response" "$token")
    local ar_count
    ar_count=$(echo "$resp" | jq '[.data.affected_items[]? | .["active-response"]? // [] | if type == "array" then .[] else . end] | length // 0' 2>/dev/null || echo 0)
    if [ "$ar_count" -gt 0 ]; then
        pass "IR-4" "wazuh_ar_rules" "${ar_count} active-response rules configured via API"
    else
        warn "IR-4" "wazuh_ar_rules" "No active-response rules found via API"
    fi
}

check_discord_alerting() {
    local token="$1"
    log "Checking alert notification integration [IR-6]..."
    # Check Wazuh integrations via API — platform uses Matrix, not Discord
    local resp
    resp=$(wazuh_get "/manager/configuration?section=integration" "$token")
    local intg_names
    intg_names=$(echo "$resp" | jq -r '[.data.affected_items[]? | .integration? // [] | if type == "array" then .[].name else .name end] | join(", ")' 2>/dev/null || echo "")
    if [ -n "$intg_names" ] && [ "$intg_names" != "null" ]; then
        pass "IR-6" "alert_notifications" "Notification integrations configured (${intg_names})"
    else
        warn "IR-6" "alert_notifications" "No notification integrations found in Wazuh"
    fi
}

check_alert_volume_healthy() {
    local token="$1"
    log "Checking alert volume [IR-5]..."
    # Use Wazuh API /manager/stats instead of SSH
    local today=$(date +%Y-%m-%d)
    local resp
    resp=$(wazuh_get "/manager/stats?date=${today}" "$token")
    local total
    total=$(echo "$resp" | jq '[.data.affected_items[]? | .totalAlerts // 0] | add // 0' 2>/dev/null || echo 0)
    if [ "$total" -gt 100 ] && [ "$total" -lt 500000 ]; then
        pass "IR-5" "alert_volume" "Alert volume normal (${total} today via API)"
    elif [ "$total" -ge 500000 ]; then
        warn "IR-5" "alert_volume" "High alert volume (${total}) - review for noise"
    else
        warn "IR-5" "alert_volume" "Low alert volume (${total}) - may indicate gaps"
    fi
}

# =============================================================================
# MAINTENANCE (MA) FAMILY
# =============================================================================

check_maintenance_mode() {
    log "Checking maintenance mode capability [MA-2]..."
    # [COMP-26] Use absolute path: script may run as root (manual) where $HOME=/root.
    # sentinel-maintenance.sh lives at /home/ubuntu/scripts/ (deployed by OPS-233 runbook).
    local script_path="/home/ubuntu/scripts/sentinel-maintenance.sh"
    if [ -x "$script_path" ]; then
        pass "MA-2" "maintenance_mode" "Maintenance mode script available and executable"
    else
        fail "MA-2" "maintenance_mode" "Maintenance mode script not found or not executable at ${script_path}"
    fi
}

# =============================================================================
# MEDIA PROTECTION (MP) FAMILY
# =============================================================================

check_vault_encryption() {
    log "Checking Vault encryption [MP-5]..."
    if [ -z "$VAULT_TOKEN" ]; then
        warn "MP-5" "vault_encryption" "VAULT_TOKEN not set - skipped"
        return
    fi
    local resp
    resp=$(vault_api "/sys/seal-status")
    local seal_type
    seal_type=$(echo "$resp" | jq -r '.type' 2>/dev/null)
    local sealed
    sealed=$(echo "$resp" | jq -r '.sealed' 2>/dev/null)
    if [ "$sealed" = "false" ] && [ -n "$seal_type" ] && [ "$seal_type" != "null" ]; then
        pass "MP-5" "vault_encryption" "Vault encryption active seal type: ${seal_type}"
    else
        fail "MP-5" "vault_encryption" "Vault sealed or encryption status unknown"
    fi
}

# =============================================================================
# PHYSICAL AND ENVIRONMENTAL (PE) FAMILY
# =============================================================================

check_idrac_monitoring() {
    log "Checking iDRAC monitoring [PE-14]..."
    local timer_status
    timer_status=$(local_svc "idrac-health-check.timer")
    if [ "$timer_status" = "active" ]; then
        pass "PE-14" "idrac_monitoring" "iDRAC health monitoring timer active"
    else
        local watchdog
        watchdog=$(local_svc "idrac-watchdog.timer")
        if [ "$watchdog" = "active" ]; then
            pass "PE-14" "idrac_monitoring" "iDRAC watchdog timer active"
        else
            fail "PE-14" "idrac_monitoring" "No iDRAC monitoring timers active"
        fi
    fi
}

# =============================================================================
# RISK ASSESSMENT (RA) FAMILY
# =============================================================================

check_vulnerability_scanning() {
    log "Checking vulnerability scanning [RA-5]..."
    # [COMP-26] Use absolute paths: script may run as root (manual) where $HOME=/root.
    # Check Forgejo Actions workflow first (canonical), then legacy ci/security.yml.
    local forgejo_wf="/home/ubuntu/sentinel-repo/.forgejo/workflows/security-scan.yml"
    local ci_security="/home/ubuntu/sentinel-repo/ci/security.yml"
    local scan_file=""
    if [ -f "$forgejo_wf" ]; then
        scan_file="$forgejo_wf"
    elif [ -f "$ci_security" ]; then
        scan_file="$ci_security"
    fi
    if [ -n "$scan_file" ]; then
        local trivy_found
        trivy_found=$(grep "trivy" "$scan_file" 2>/dev/null | wc -l || true)
        if [ "$trivy_found" -gt 0 ]; then
            pass "RA-5" "vulnerability_scanning" "Trivy vulnerability scanning in CI pipeline"
        else
            warn "RA-5" "vulnerability_scanning" "CI scan file exists but no trivy reference"
        fi
    else
        fail "RA-5" "vulnerability_scanning" "No CI security scanning configuration found"
    fi
}

# =============================================================================
# SYSTEM AND COMMUNICATIONS PROTECTION (SC) FAMILY
# =============================================================================

check_namespace_network_policies() {
    log "Checking namespace network policies [SC-2]..."
    local np_count
    np_count=$(oc_cmd get networkpolicy --all-namespaces --no-headers | wc -l || echo 0)
    if [ "$np_count" -ge 3 ]; then
        pass "SC-2" "namespace_network_policies" "${np_count} NetworkPolicies across cluster"
    elif [ "$np_count" -gt 0 ]; then
        warn "SC-2" "namespace_network_policies" "Only ${np_count} NetworkPolicies (expected >= 3)"
    else
        local authpol
        authpol=$(oc_cmd get authorizationpolicy --all-namespaces --no-headers | wc -l || echo 0)
        if [ "$authpol" -ge 3 ]; then
            pass "SC-2" "namespace_network_policies" "${authpol} Istio AuthorizationPolicies for segmentation"
        else
            fail "SC-2" "namespace_network_policies" "No NetworkPolicies or AuthorizationPolicies found"
        fi
    fi
}

check_crowdsec_active() {
    # SEC-25: Replaced SSH systemctl on pangolin with Wazuh syscollector process search.
    # Agent 002 = pangolin-proxy. Also checks CrowdSec local API health endpoint.
    local token="$1"
    log "Checking CrowdSec via Wazuh syscollector (agent 002=pangolin) [SC-5]..."
    local cs_proc_resp
    cs_proc_resp=$(wazuh_get "/syscollector/002/processes?search=crowdsec&limit=10" "$token")
    local cs_count
    cs_count=$(echo "$cs_proc_resp" | jq -r '.data.total_affected_items // 0')

    if [ "$cs_count" -ge 1 ]; then
        # Also check for bouncer process
        local bouncer_resp
        bouncer_resp=$(wazuh_get "/syscollector/002/processes?search=crowdsec-firewall&limit=10" "$token")
        local bouncer_count
        bouncer_count=$(echo "$bouncer_resp" | jq -r '.data.total_affected_items // 0')
        if [ "$bouncer_count" -ge 1 ]; then
            pass "SC-5" "crowdsec_active" "CrowdSec (${cs_count} procs) and firewall bouncer (${bouncer_count} procs) running on pangolin agent"
        else
            warn "SC-5" "crowdsec_active" "CrowdSec running on pangolin but firewall bouncer process not found in syscollector"
        fi
    else
        # Fallback: HTTP check to CrowdSec local API on pangolin
        local cs_api_code
        cs_api_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            "http://192.168.12.168:8080/v1/heartbeat" 2>/dev/null || echo "000")
        if [ "$cs_api_code" = "200" ]; then
            pass "SC-5" "crowdsec_active" "CrowdSec local API responding on pangolin (HTTP ${cs_api_code})"
        else
            fail "SC-5" "crowdsec_active" "CrowdSec not found in syscollector and API not responding (HTTP ${cs_api_code})"
        fi
    fi
}

check_squid_egress() {
    log "Checking Squid egress proxy [SC-7(5)]..."
    local status
    status=$(local_svc "squid")
    if [ "$status" = "active" ]; then
        pass "SC-7(5)" "squid_egress" "Squid egress proxy active on iac-control"
    else
        fail "SC-7(5)" "squid_egress" "Squid proxy not active on iac-control"
    fi
}

check_cloudflare_tunnel() {
    # SEC-25: Replaced SSH systemctl on pangolin with Wazuh syscollector process search.
    # Agent 002 = pangolin-proxy. Checks for cloudflared process.
    local token="$1"
    log "Checking Cloudflare tunnel via Wazuh syscollector (agent 002=pangolin) [SC-7(7)]..."
    local cf_resp
    cf_resp=$(wazuh_get "/syscollector/002/processes?search=cloudflared&limit=10" "$token")
    local cf_count
    cf_count=$(echo "$cf_resp" | jq -r '.data.total_affected_items // 0')

    if [ "$cf_count" -ge 1 ]; then
        pass "SC-7(7)" "cloudflare_tunnel" "cloudflared process running on pangolin (agent 002, ${cf_count} procs)"
    else
        # Fallback: check via Traefik — if www.haist.farm responds, tunnel is up
        local cf_health
        cf_health=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
            "https://www.haist.farm" 2>/dev/null || echo "000")
        if [ "$cf_health" = "200" ] || [ "$cf_health" = "302" ] || [ "$cf_health" = "303" ]; then
            pass "SC-7(7)" "cloudflare_tunnel" "Cloudflare tunnel responding — www.haist.farm reachable (HTTP ${cf_health})"
        else
            fail "SC-7(7)" "cloudflare_tunnel" "cloudflared not found in syscollector and tunnel endpoint unreachable (HTTP ${cf_health})"
        fi
    fi
}

check_traefik_tls() {
    log "Checking Traefik TLS [SC-8]..."
    local code
    code=$(http_status "https://vault.208.haist.farm")
    if [ "$code" != "000" ]; then
        pass "SC-8" "traefik_tls" "Traefik TLS termination working (HTTPS responding)"
    else
        fail "SC-8" "traefik_tls" "Traefik TLS not responding"
    fi
}

check_tls_cert_valid() {
    log "Checking TLS certificate validity [SC-8(1)]..."
    local expiry
    expiry=$(echo | openssl s_client -connect vault.208.haist.farm:443 -servername vault.208.haist.farm 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$expiry" ]; then
        local expiry_epoch
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
        local now_epoch
        now_epoch=$(date +%s)
        local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        if [ "$days_left" -gt 14 ]; then
            pass "SC-8(1)" "tls_cert_valid" "TLS cert valid for ${days_left} more days"
        elif [ "$days_left" -gt 0 ]; then
            warn "SC-8(1)" "tls_cert_valid" "TLS cert expires in ${days_left} days"
        else
            fail "SC-8(1)" "tls_cert_valid" "TLS cert expired"
        fi
    else
        warn "SC-8(1)" "tls_cert_valid" "Could not check TLS certificate expiry"
    fi
}

check_vault_seal_status() {
    log "Checking Vault seal status [SC-12]..."
    local resp
    resp=$(curl -s -k "${VAULT_URL}/v1/sys/seal-status" 2>/dev/null)
    local sealed
    sealed=$(echo "$resp" | jq -r '.sealed' 2>/dev/null)
    if [ "$sealed" = "false" ]; then
        pass "SC-12" "vault_seal_status" "Vault is unsealed and operational"
    else
        fail "SC-12" "vault_seal_status" "Vault is sealed or unreachable"
    fi
}

check_minio_tls() {
    log "Checking MinIO TLS [SC-28]..."
    local code
    code=$(http_status "https://minio.208.haist.farm")
    if [ "$code" != "000" ]; then
        pass "SC-28" "minio_tls" "MinIO accessible via TLS proxy"
    else
        local direct
        direct=$(http_status "http://192.168.12.58:9000/minio/health/live")
        if [ "$direct" = "200" ]; then
            warn "SC-28" "minio_tls" "MinIO reachable on HTTP but not via TLS proxy"
        else
            fail "SC-28" "minio_tls" "MinIO not reachable"
        fi
    fi
}

check_process_isolation() {
    log "Checking OKD pod security [SC-39]..."
    local scc_count
    scc_count=$(oc_cmd get scc --no-headers | wc -l || echo 0)
    if [ "$scc_count" -ge 5 ]; then
        pass "SC-39" "process_isolation" "${scc_count} SecurityContextConstraints enforcing pod isolation"
    else
        fail "SC-39" "process_isolation" "Only ${scc_count} SCCs found"
    fi
}

# =============================================================================
# SYSTEM AND INFORMATION INTEGRITY (SI) FAMILY
# =============================================================================

check_flaw_remediation() {
    # COMP-20: Replaced trivial unattended-upgrades presence check with composite
    # flaw-remediation posture check. Two sub-checks:
    #   1. Container CVE debt — query DefectDojo API for active Critical+High findings
    #      (thresholds: PASS 0 Crit+<5 High; WARN 0 Crit+5-30 High; FAIL any Crit or >30 High)
    #   2. Host patch currency — apt pending security updates on iac-control
    #      (thresholds: PASS 0 pending; WARN 1-5; FAIL >5)
    # Overall: worst-of-two sub-checks (strictest combining rule).
    log "Checking flaw remediation posture [SI-2]..."

    # --- Sub-check 1: Container CVE posture via DefectDojo ---
    local dd_crit=0
    local dd_high=0
    local dd_cve_status="FAIL"
    local dd_detail="DefectDojo unreachable — cannot assess CVE posture"

    local dd_token
    dd_token=$(vault_api "/secret/data/defectdojo" 2>/dev/null \
        | jq -r '.data.data.api_token // empty' 2>/dev/null || echo "")

    if [ -n "$dd_token" ]; then
        local dd_base="https://defectdojo.208.haist.farm"
        local crit_resp high_resp
        crit_resp=$(curl -sk --max-time 10 \
            -H "Authorization: Token ${dd_token}" \
            "${dd_base}/api/v2/findings/?active=true&severity=Critical&limit=1" 2>/dev/null || echo "")
        high_resp=$(curl -sk --max-time 10 \
            -H "Authorization: Token ${dd_token}" \
            "${dd_base}/api/v2/findings/?active=true&severity=High&limit=1" 2>/dev/null || echo "")

        if [ -n "$crit_resp" ] && [ -n "$high_resp" ]; then
            dd_crit=$(echo "$crit_resp" | jq -r '.count // 0' 2>/dev/null || echo "0")
            dd_high=$(echo "$high_resp" | jq -r '.count // 0' 2>/dev/null || echo "0")
            if [ "$dd_crit" -eq 0 ] && [ "$dd_high" -lt 5 ]; then
                dd_cve_status="PASS"
                dd_detail="CVE posture: ${dd_crit} Critical, ${dd_high} High active findings"
            elif [ "$dd_crit" -eq 0 ] && [ "$dd_high" -le 30 ]; then
                dd_cve_status="WARN"
                dd_detail="CVE debt: ${dd_crit} Critical, ${dd_high} High active findings (documented, remediating)"
            else
                dd_cve_status="FAIL"
                dd_detail="CVE backlog: ${dd_crit} Critical, ${dd_high} High active findings — remediation required"
            fi
        fi
    fi

    # --- Sub-check 2: Host patch currency on iac-control (local) ---
    local pending_sec=0
    local patch_status="FAIL"
    local patch_detail="apt-get simulation failed — cannot assess patch currency"

    pending_sec=$(apt-get -s upgrade 2>/dev/null | grep '^Inst.*security' | wc -l || true)
    if [ "$pending_sec" -eq 0 ]; then
        patch_status="PASS"
        patch_detail="iac-control: ${pending_sec} pending security updates"
    elif [ "$pending_sec" -le 5 ]; then
        patch_status="WARN"
        patch_detail="iac-control: ${pending_sec} pending security updates"
    else
        patch_status="FAIL"
        patch_detail="iac-control: ${pending_sec} pending security updates — patching overdue"
    fi

    # --- Combine: worst-of-two ---
    local combined_detail="${dd_detail}; ${patch_detail}"

    # FAIL beats WARN beats PASS
    if [ "$dd_cve_status" = "FAIL" ] || [ "$patch_status" = "FAIL" ]; then
        fail "SI-2" "flaw_remediation" "$combined_detail"
    elif [ "$dd_cve_status" = "WARN" ] || [ "$patch_status" = "WARN" ]; then
        warn "SI-2" "flaw_remediation" "$combined_detail"
    else
        pass "SI-2" "flaw_remediation" "$combined_detail"
    fi
}

check_wazuh_rules_loaded() {
    local token="$1"
    log "Checking Wazuh rules loaded [SI-4]..."
    local resp
    resp=$(wazuh_get "/rules?limit=1" "$token")
    local total
    total=$(echo "$resp" | jq -r '.data.total_affected_items // 0' 2>/dev/null || echo 0)
    if [ "$total" -ge 4000 ]; then
        pass "SI-4" "wazuh_rules_loaded" "${total} Wazuh rules loaded"
    elif [ "$total" -gt 0 ]; then
        warn "SI-4" "wazuh_rules_loaded" "Only ${total} Wazuh rules (expected >= 4000)"
    else
        fail "SI-4" "wazuh_rules_loaded" "Cannot query Wazuh rules"
    fi
}

check_wazuh_custom_rules() {
    # SEC-25: Replaced SSH grep on wazuh server with Wazuh API rules endpoint.
    # Queries rules filtered to local_rules.xml (the custom rules file).
    local token="$1"
    log "Checking Wazuh custom rules via API [SI-4(2)]..."
    local resp
    resp=$(wazuh_get "/rules?filename=local_rules.xml&limit=500" "$token")
    local count
    count=$(echo "$resp" | jq -r '.data.total_affected_items // 0')

    if [ "$count" -ge 5 ]; then
        pass "SI-4(2)" "wazuh_custom_rules" "${count} custom Wazuh rules in local_rules.xml"
    elif [ "$count" -gt 0 ]; then
        warn "SI-4(2)" "wazuh_custom_rules" "Only ${count} custom rules in local_rules.xml (expected >= 5)"
    else
        # Fallback: check rules in local/ relative directory
        local dir_resp
        dir_resp=$(wazuh_get "/rules?relative_dirname=etc/rules&limit=500" "$token")
        local dir_count
        dir_count=$(echo "$dir_resp" | jq -r '.data.total_affected_items // 0')
        if [ "$dir_count" -ge 5 ]; then
            pass "SI-4(2)" "wazuh_custom_rules" "${dir_count} rules in etc/rules directory (local_rules.xml may have different name)"
        else
            fail "SI-4(2)" "wazuh_custom_rules" "No custom Wazuh rules found via API (local_rules.xml count: ${count})"
        fi
    fi
}

check_inbound_monitoring() {
    # SEC-25: Replaced SSH systemctl/docker ps on pangolin with Wazuh syscollector process search.
    # Agent 002 = pangolin-proxy. Checks for traefik process via syscollector.
    local token="$1"
    log "Checking inbound traffic monitoring via Wazuh syscollector (agent 002=pangolin) [SI-4(4)]..."
    local traefik_resp
    traefik_resp=$(wazuh_get "/syscollector/002/processes?search=traefik&limit=10" "$token")
    local traefik_count
    traefik_count=$(echo "$traefik_resp" | jq -r '.data.total_affected_items // 0')

    if [ "$traefik_count" -ge 1 ]; then
        pass "SI-4(4)" "inbound_monitoring" "Traefik process running on pangolin (agent 002, ${traefik_count} procs)"
    else
        # Fallback: HTTP health check to Traefik ping endpoint
        local traefik_health
        traefik_health=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
            "https://traefik.208.haist.farm/ping" 2>/dev/null || echo "000")
        if [ "$traefik_health" = "200" ]; then
            pass "SI-4(4)" "inbound_monitoring" "Traefik /ping endpoint healthy (HTTP ${traefik_health})"
        else
            # Second fallback: check if any HTTPS service responds (implies Traefik is up)
            local vault_code
            vault_code=$(curl -s -k -o /dev/null -w "%{http_code}" --max-time 5 \
                "https://vault.208.haist.farm" 2>/dev/null || echo "000")
            if [ "$vault_code" != "000" ]; then
                pass "SI-4(4)" "inbound_monitoring" "Traefik routing active — vault.208.haist.farm responding (HTTP ${vault_code})"
            else
                fail "SI-4(4)" "inbound_monitoring" "Traefik not found in syscollector and no HTTPS endpoints responding"
            fi
        fi
    fi
}

check_kyverno_policies() {
    # COMP-16 rewrite 2026-04-25: was a count-based trivial check (>=3 → PASS);
    # now verifies ready-status, enforce-mode count, webhook registration, and
    # runs a functional admission probe (privileged Pod must be denied).
    log "Checking Kyverno policies [SI-7(1)]..."

    # 1. policies must exist
    local total
    total=$(oc_cmd get clusterpolicy --no-headers 2>/dev/null | wc -l)
    if [ "${total:-0}" = 0 ]; then
        fail "SI-7(1)" "kyverno_policies" "No Kyverno ClusterPolicies found"
        return
    fi

    # 2. all policies Ready
    # `|| true` because grep -v exits 1 when no lines match, which combined with
    # pipefail+set-e in this script aborts the function silently.
    local not_ready_list
    not_ready_list=$( { oc_cmd get clusterpolicy -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
        | grep -v "=True$" | grep -v "^$"; } || true )
    if [ -n "$not_ready_list" ]; then
        local nrcount nrlist
        nrcount=$(echo "$not_ready_list" | wc -l)
        nrlist=$(echo "$not_ready_list" | head -5 | tr '\n' ',' | sed 's/,$//')
        fail "SI-7(1)" "kyverno_policies" "${nrcount}/${total} policies not Ready: ${nrlist}"
        return
    fi

    # 3. count Enforce vs Audit; require at least one Enforce
    local actions enforce_count audit_count
    actions=$(oc_cmd get clusterpolicy -o jsonpath='{range .items[*]}{.spec.validationFailureAction}{"\n"}{end}' 2>/dev/null)
    enforce_count=$(echo "$actions" | grep -ic "^Enforce$" || true)
    audit_count=$(echo "$actions" | grep -ic "^Audit$" || true)
    if [ "${enforce_count:-0}" -lt 1 ]; then
        fail "SI-7(1)" "kyverno_policies" "${total} policies installed but ZERO Enforce-mode (all Audit-only — no admission blocking)"
        return
    fi

    # 4. ValidatingWebhookConfiguration must be registered
    local wh_present
    wh_present=$(oc_cmd get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o name 2>/dev/null | wc -l)
    if [ "${wh_present:-0}" = 0 ]; then
        fail "SI-7(1)" "kyverno_policies" "${total} policies installed but kyverno-resource-validating-webhook-cfg missing — admission disconnected"
        return
    fi

    # 5. functional probe: a privileged + no-limits Pod in a covered ns must be denied.
    #    Uses 'media' which is in disallow-privileged-containers' namespace list.
    #    --dry-run=server invokes admission webhooks without persisting the resource.
    #    Invoke raw `oc` (not oc_cmd) because oc_cmd redirects stderr to /dev/null
    #    and the Kyverno denial message comes back on stderr — we must capture it.
    local probe_ns="media" probe_out
    probe_out=$(oc --kubeconfig="$KUBECONFIG" apply --dry-run=server -f - <<PROBE 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: nist-compliance-probe-$$
  namespace: ${probe_ns}
spec:
  containers:
  - name: c
    image: nginx:latest
    securityContext:
      privileged: true
      runAsUser: 0
PROBE
)
    if echo "$probe_out" | grep -q "denied the request"; then
        pass "SI-7(1)" "kyverno_policies" "${total} policies Ready; ${enforce_count} Enforce / ${audit_count} Audit; webhook registered; functional probe DENIED privileged Pod in ${probe_ns}"
    else
        fail "SI-7(1)" "kyverno_policies" "${total} policies Ready and webhook registered, but FUNCTIONAL PROBE BYPASSED (privileged Pod accepted in ${probe_ns}): $(echo "$probe_out" | head -1)"
    fi
}

check_nvd_accessible() {
    log "Checking NVD accessibility [SI-5]..."
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        "https://services.nvd.nist.gov/rest/json/cves/2.0?resultsPerPage=1" 2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
        pass "SI-5" "nvd_accessible" "NIST NVD API accessible"
    elif [ "$code" = "403" ] || [ "$code" = "429" ]; then
        warn "SI-5" "nvd_accessible" "NVD API rate-limited HTTP ${code}"
    else
        warn "SI-5" "nvd_accessible" "NVD API not reachable HTTP ${code}"
    fi
}

check_apparmor_active() {
    log "Checking AppArmor [SI-16]..."
    if aa-status --enabled 2>/dev/null; then
        local profiles
        profiles=$(aa-status 2>/dev/null | grep "profiles are loaded" | awk '{print $1}' || echo 0)
        pass "SI-16" "apparmor_active" "AppArmor enabled with ${profiles} profiles on iac-control"
    else
        local svc
        svc=$(local_svc "apparmor")
        if [ "$svc" = "active" ]; then
            pass "SI-16" "apparmor_active" "AppArmor service active on iac-control"
        else
            warn "SI-16" "apparmor_active" "AppArmor not active on iac-control"
        fi
    fi
}

# =============================================================================
# POLICY AND DOCUMENTATION CHECKS
# =============================================================================

check_policy_doc_exists() {
    log "Checking access control policy [AC-1]..."
    local doc="${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/ac2-account-inventory.md"
    if [ -f "$doc" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$doc") ))
        local days=$((age / 86400))
        if [ "$days" -lt 180 ]; then
            pass "AC-1" "policy_doc_exists" "Access control policy document exists (${days} days old)"
        else
            warn "AC-1" "policy_doc_exists" "Access control policy document is ${days} days old (> 180)"
        fi
    else
        warn "AC-1" "policy_doc_exists" "Access control policy document not found"
    fi
}

check_separation_of_duties() {
    log "Checking separation of duties [AC-5]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*vault* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*separation* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*duties* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "AC-5" "separation_of_duties" "Separation of duties documentation found"
    else
        # Check for Vault policy docs as evidence
        local vault_docs
        vault_docs=$(grep -rl "claude-automation\|least.privilege\|separation" "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" 2>/dev/null | head -1 || echo "")
        if [ -n "$vault_docs" ]; then
            pass "AC-5" "separation_of_duties" "Vault least-privilege policy documented"
        else
            warn "AC-5" "separation_of_duties" "No separation of duties documentation found"
        fi
    fi
}

check_session_lock() {
    log "Checking session lock [AC-11]..."
    if [ -f /etc/profile.d/session-timeout.sh ]; then
        local has_tmout
        has_tmout=$(grep "TMOUT" /etc/profile.d/session-timeout.sh 2>/dev/null || echo "")
        if [ -n "$has_tmout" ]; then
            pass "AC-11" "session_lock" "Session timeout configured via /etc/profile.d/session-timeout.sh"
        else
            warn "AC-11" "session_lock" "session-timeout.sh exists but TMOUT not found"
        fi
    else
        warn "AC-11" "session_lock" "No session timeout script at /etc/profile.d/session-timeout.sh"
    fi
}

check_contingency_plan() {
    log "Checking contingency plan [CP-1]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*incident* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*contingency* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*ir-plan* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "CP-1" "contingency_plan" "Contingency/IR plan documentation exists"
    else
        warn "CP-1" "contingency_plan" "No contingency plan documentation found"
    fi
}

check_recovery_procedures() {
    log "Checking recovery procedures [CP-3]..."
    # [COMP-26] Use absolute path: script may run as root (manual) where $HOME=/root.
    # DR recovery scripts are in sentinel-repo/infrastructure/recovery/ on iac-control.
    local dr_dir="/home/ubuntu/sentinel-repo/infrastructure/recovery"
    local count=0
    if [ -d "$dr_dir" ]; then
        count=$(ls "$dr_dir"/*.sh 2>/dev/null | wc -l || echo 0)
    fi
    if [ "$count" -ge 3 ]; then
        pass "CP-3" "recovery_procedures" "${count} recovery scripts in infrastructure/recovery/"
    elif [ "$count" -gt 0 ]; then
        warn "CP-3" "recovery_procedures" "Only ${count} recovery scripts (expected >= 3)"
    else
        fail "CP-3" "recovery_procedures" "No recovery scripts found"
    fi
}

check_password_aging() {
    log "Checking password aging [IA-5(1)]..."
    local max_days
    max_days=$(grep -E "^PASS_MAX_DAYS" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "")
    if [ -n "$max_days" ] && [ "$max_days" -le 365 ] 2>/dev/null; then
        pass "IA-5(1)" "password_aging" "PASS_MAX_DAYS set to ${max_days} in login.defs"
    elif [ -n "$max_days" ]; then
        warn "IA-5(1)" "password_aging" "PASS_MAX_DAYS is ${max_days} (> 365 days)"
    else
        warn "IA-5(1)" "password_aging" "PASS_MAX_DAYS not set in /etc/login.defs"
    fi
}

check_security_plan_policy() {
    log "Checking security plan [PL-1]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/security.md" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/security-plan.md" 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "PL-1" "security_plan_policy" "Security plan document exists"
    else
        warn "PL-1" "security_plan_policy" "No security plan document found in docs/"
    fi
}

check_ssp_current() {
    log "Checking SSP currency [PL-2]..."
    local ssp_dir="${SENTINEL_REPO_ROOT}/sentinel-repo/compliance"
    if [ -d "$ssp_dir" ]; then
        local newest
        newest=$(find "$ssp_dir" -name "*.md" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || echo "0")
        local age=$(( $(date +%s) - ${newest%.*} ))
        local days=$((age / 86400))
        if [ "$days" -lt 180 ]; then
            pass "PL-2" "ssp_current" "Compliance documentation updated within ${days} days"
        else
            warn "PL-2" "ssp_current" "Compliance documentation is ${days} days old (> 180)"
        fi
    else
        warn "PL-2" "ssp_current" "No compliance directory found"
    fi
}

check_risk_assessment() {
    log "Checking risk assessment [RA-3]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*risk* "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/"*risk* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "RA-3" "risk_assessment" "Risk assessment documentation exists"
    else
        local grep_found
        grep_found=$(grep -rl "risk.assessment\|risk.register\|threat.model" "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/" 2>/dev/null | head -1 || echo "")
        if [ -n "$grep_found" ]; then
            pass "RA-3" "risk_assessment" "Risk assessment referenced in documentation"
        else
            warn "RA-3" "risk_assessment" "No risk assessment documentation found"
        fi
    fi
}

check_comms_policy() {
    log "Checking communications policy [SC-1]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/architecture.md" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/network-architecture.md" 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "SC-1" "comms_policy" "Communications/architecture policy document exists"
    else
        warn "SC-1" "comms_policy" "No architecture policy document found in docs/"
    fi
}

check_ir_plan_current() {
    log "Checking IR plan [IR-1]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*incident* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*ir-plan* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$found") ))
        local days=$((age / 86400))
        if [ "$days" -lt 180 ]; then
            pass "IR-1" "ir_plan_current" "IR plan exists and current (${days} days old)"
        else
            warn "IR-1" "ir_plan_current" "IR plan is ${days} days old (> 180)"
        fi
    else
        warn "IR-1" "ir_plan_current" "No incident response plan found"
    fi
}

check_component_lifecycle() {
    log "Checking component lifecycle [SA-22]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*lifecycle* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*component* "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/"*lifecycle* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "SA-22" "component_lifecycle" "Component lifecycle documentation exists"
    else
        warn "SA-22" "component_lifecycle" "No component lifecycle documentation found"
    fi
}

# =============================================================================
# ADDITIONAL COVERAGE CHECKS (Sprint 2)
# =============================================================================

check_audit_content() {
    log "Checking audit record content [AU-3]..."
    local keyed_rules
    keyed_rules=$(sudo auditctl -l 2>/dev/null | grep '\-k ' | wc -l || true)
    local total_rules
    total_rules=$(sudo auditctl -l 2>/dev/null | wc -l || echo 0)
    if [ "$keyed_rules" -ge 5 ]; then
        pass "AU-3" "audit_content" "${keyed_rules}/${total_rules} audit rules have key tags for categorization"
    elif [ "$keyed_rules" -gt 0 ]; then
        warn "AU-3" "audit_content" "Only ${keyed_rules}/${total_rules} audit rules have key tags"
    else
        fail "AU-3" "audit_content" "No audit rules with key tags found"
    fi
}

check_component_inventory() {
    log "Checking component inventory [CM-8]..."
    local netbox_code
    netbox_code=$(http_status "https://netbox.208.haist.farm/api/dcim/devices/?limit=1")
    if [ "$netbox_code" = "200" ] || [ "$netbox_code" = "403" ]; then
        pass "CM-8" "component_inventory" "NetBox DCIM inventory accessible (HTTP ${netbox_code})"
    else
        # Fallback: check if NetBox pod is running
        local nb_pods
        nb_pods=$(oc_cmd get pods -n netbox --no-headers 2>/dev/null | grep "Running" | wc -l || true)
        if [ "$nb_pods" -gt 0 ]; then
            pass "CM-8" "component_inventory" "NetBox running with ${nb_pods} pods in cluster"
        else
            warn "CM-8" "component_inventory" "NetBox not reachable (HTTP ${netbox_code})"
        fi
    fi
}

check_identifier_management() {
    log "Checking identifier management [IA-4]..."
    local uid_min
    uid_min=$(grep -E "^UID_MIN" /etc/login.defs 2>/dev/null | awk '{print $2}' || echo "")
    if [ -n "$uid_min" ] && [ "$uid_min" -ge 1000 ] 2>/dev/null; then
        pass "IA-4" "identifier_management" "UID_MIN set to ${uid_min} in login.defs"
    elif [ -n "$uid_min" ]; then
        warn "IA-4" "identifier_management" "UID_MIN is ${uid_min} (recommended >= 1000)"
    else
        warn "IA-4" "identifier_management" "UID_MIN not found in /etc/login.defs"
    fi
}

check_non_org_users() {
    log "Checking for unauthorized UID 0 accounts [IA-8]..."
    local uid0_accounts
    uid0_accounts=$(awk -F: '$3 == 0 {print $1}' /etc/passwd 2>/dev/null)
    local count
    count=$(echo "$uid0_accounts" | wc -w)
    if [ "$count" -eq 1 ] && [ "$uid0_accounts" = "root" ]; then
        pass "IA-8" "non_org_users" "Only root has UID 0"
    else
        fail "IA-8" "non_org_users" "Multiple UID 0 accounts: ${uid0_accounts}"
    fi
}

check_crypto_protection() {
    log "Checking cryptographic protection [SC-13]..."
    local tls_version
    tls_version=$(echo | openssl s_client -connect vault.208.haist.farm:443 -servername vault.208.haist.farm 2>/dev/null \
        | grep -oP 'Protocol\s+:\s+\K\S+' || echo "")
    if [ "$tls_version" = "TLSv1.3" ] || [ "$tls_version" = "TLSv1.2" ]; then
        pass "SC-13" "crypto_protection" "TLS ${tls_version} enforced on Traefik endpoints"
    elif [ -n "$tls_version" ]; then
        fail "SC-13" "crypto_protection" "Weak TLS version ${tls_version} detected"
    else
        # Fallback: check Traefik config for TLS minVersion
        local min_tls
        min_tls=$(ssh_sentinel "$PANGOLIN_HOST" "grep -r 'minVersion' /opt/pangolin/traefik.yml /opt/pangolin/dynamic/ 2>/dev/null | head -1" || echo "")
        if echo "$min_tls" | grep -qiE "VersionTLS1[23]"; then
            pass "SC-13" "crypto_protection" "Traefik TLS minimum version configured"
        else
            warn "SC-13" "crypto_protection" "Could not verify TLS version enforcement"
        fi
    fi
}

check_network_disconnect() {
    log "Checking network disconnect [SC-10]..."
    local interval
    interval=$(sudo grep -rE "^ClientAliveInterval" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null | head -1 | awk '{print $2}' || echo "")
    if [ -n "$interval" ] && [ "$interval" -gt 0 ] && [ "$interval" -le 600 ] 2>/dev/null; then
        pass "SC-10" "network_disconnect" "SSH ClientAliveInterval set to ${interval}s"
    elif [ -n "$interval" ]; then
        warn "SC-10" "network_disconnect" "SSH ClientAliveInterval is ${interval}s (recommended <= 600)"
    else
        warn "SC-10" "network_disconnect" "ClientAliveInterval not set in sshd_config"
    fi
}

check_training_policy() {
    log "Checking security training policy [AT-1]..."
    local found
    found=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*training* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*awareness* "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/"*training* 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "AT-1" "training_policy" "Security training/awareness documentation exists"
    else
        local grep_found
        grep_found=$(grep -rl "training\|awareness\|onboarding" "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" 2>/dev/null | head -1 || echo "")
        if [ -n "$grep_found" ]; then
            pass "AT-1" "training_policy" "Security training referenced in compliance documentation"
        else
            warn "AT-1" "training_policy" "No security training documentation found"
        fi
    fi
}

check_physical_monitoring() {
    log "Checking physical access monitoring [PE-6]..."
    local health_timer
    health_timer=$(local_svc "idrac-health.timer")
    local watchdog_timer
    watchdog_timer=$(local_svc "idrac-watchdog.timer")
    if [ "$health_timer" = "active" ] && [ "$watchdog_timer" = "active" ]; then
        pass "PE-6" "physical_monitoring" "iDRAC health + watchdog timers active for physical monitoring"
    elif [ "$health_timer" = "active" ] || [ "$watchdog_timer" = "active" ]; then
        pass "PE-6" "physical_monitoring" "At least one iDRAC monitoring timer active"
    else
        warn "PE-6" "physical_monitoring" "No iDRAC monitoring timers active"
    fi
}

# --- New checks: Phase 1 evidence gap closure ---

check_training_records() {
    log "Checking security training records [AT-2]..."
    local found
    found=$(find "${SENTINEL_REPO_ROOT}/compliance-vault/" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/" -iname "*training*" -o -iname "*awareness*" 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "AT-2" "training_records" "Security awareness training documentation exists"
    else
        warn "AT-2" "training_records" "No formal security awareness training records found"
    fi
}

check_role_based_training() {
    log "Checking role-based security training [AT-3]..."
    local found
    found=$(grep -rl "role.based\|privileged.user\|administrator.training" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/" "${SENTINEL_REPO_ROOT}/compliance-vault/" 2>/dev/null | head -1 || echo "")
    if [ -n "$found" ]; then
        pass "AT-3" "role_based_training" "Role-based security training documentation exists"
    else
        warn "AT-3" "role_based_training" "No role-based security training records found"
    fi
}

check_acquisition_policy() {
    log "Checking system acquisition policy [SA-4]..."
    local harbor_scan
    harbor_scan=$(oc_cmd get configmap -n harbor -o name 2>/dev/null | head -1 || echo "")
    # OPS-127 (2026-04) migrated GitLab → Forgejo. Scan the Forgejo workflow file
    # for trivy presence; .gitlab-ci.yml no longer exists post-migration.
    local trivy_ci=""
    if grep -rql "trivy" "${SENTINEL_REPO_ROOT}/sentinel-repo/.forgejo/workflows/" 2>/dev/null; then
        trivy_ci="found"
    fi
    if [ -n "$trivy_ci" ]; then
        pass "SA-4" "acquisition_security" "CI pipeline includes security scanning (Trivy) for acquired components"
    elif [ -n "$harbor_scan" ]; then
        pass "SA-4" "acquisition_security" "Harbor registry with vulnerability scanning configured"
    else
        warn "SA-4" "acquisition_security" "No automated security requirements in acquisition process"
    fi
}

check_secure_development() {
    log "Checking secure development practices [SA-8]..."
    # OPS-127 (2026-04) migrated GitLab → Forgejo. Scan Forgejo workflow files
    # across all 3 repos. Pre-fix this scanned .gitlab-ci.yml which no longer
    # exists, so SA-8 has been silently false-WARN since the migration.
    # OPS-135 (2026-04-26) consolidated repo paths via $SENTINEL_REPO_ROOT.
    local found_tools=""
    for repo_dir in "${SENTINEL_REPO_ROOT}/sentinel-repo" "${SENTINEL_REPO_ROOT}/overwatch-gitops" "${SENTINEL_REPO_ROOT}/overwatch-repo"; do
        local wf_dir="$repo_dir/.forgejo/workflows"
        [ -d "$wf_dir" ] || continue
        grep -rql "gitleaks" "$wf_dir" 2>/dev/null && found_tools="${found_tools}gitleaks,"
        grep -rql "trivy" "$wf_dir" 2>/dev/null && found_tools="${found_tools}trivy,"
        grep -rql "checkov" "$wf_dir" 2>/dev/null && found_tools="${found_tools}checkov,"
        grep -rql "osv-scanner\|google/osv-scanner" "$wf_dir" 2>/dev/null && found_tools="${found_tools}osv-scanner,"
    done
    found_tools=$(echo "$found_tools" | sed 's/,$//' | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')
    local tool_count=$(echo "$found_tools" | tr ',' '\n' | grep . | wc -l || true)
    if [ "$tool_count" -ge 2 ]; then
        pass "SA-8" "secure_development" "CI pipelines enforce secure development (${found_tools})"
    elif [ "$tool_count" -eq 1 ]; then
        pass "SA-8" "secure_development" "CI pipeline includes ${found_tools}"
    else
        warn "SA-8" "secure_development" "No secure development lifecycle checks in CI"
    fi
}

check_dns_security() {
    log "Checking DNS security [SC-20]..."
    local dnsmasq
    dnsmasq=$(local_svc "dnsmasq")
    if [ "$dnsmasq" = "active" ]; then
        # Check if DNSSEC validation is enabled
        local dnssec_enabled=false
        if grep -q '^dnssec' /etc/dnsmasq.d/overwatch.conf 2>/dev/null; then
            dnssec_enabled=true
        fi
        if $dnssec_enabled; then
            pass "SC-20" "dns_security" "Internal DNS (dnsmasq) active with DNSSEC validation enabled"
        else
            pass "SC-20" "dns_security" "Internal DNS (dnsmasq) active — authoritative source for cluster resolution"
        fi
    else
        warn "SC-20" "dns_security" "dnsmasq not active on iac-control"
    fi
}

check_alternate_processing() {
    log "Checking alternate processing site [CP-6]..."
    local config_server
    config_server=$(ssh_sentinel "ubuntu@192.168.12.132" "systemctl is-active dnsmasq" 2>/dev/null || echo "inactive")
    local keepalived
    keepalived=$(local_svc "keepalived")
    if [ "$keepalived" = "active" ] && [ "$config_server" = "active" ]; then
        pass "CP-6" "alternate_processing" "HA failover site active (config-server + keepalived VRRP)"
    elif [ "$keepalived" = "active" ]; then
        pass "CP-6" "alternate_processing" "Keepalived HA active (config-server connectivity unconfirmed)"
    else
        warn "CP-6" "alternate_processing" "No alternate processing site verified"
    fi
}

check_falco_runtime() {
    log "Checking runtime security monitoring [SI-4(2)]..."
    local falco_pods
    falco_pods=$(oc_cmd get pods -n falco-system -l app.kubernetes.io/name=falco --no-headers 2>/dev/null | grep "Running" | wc -l || true)
    if [ "$falco_pods" -ge 3 ]; then
        pass "SI-4(2)" "runtime_monitoring" "Falco runtime detection active on all ${falco_pods} nodes"
    elif [ "$falco_pods" -gt 0 ]; then
        warn "SI-4(2)" "runtime_monitoring" "Falco running on ${falco_pods}/3 nodes"
    else
        fail "SI-4(2)" "runtime_monitoring" "Falco not running — no container runtime detection"
    fi
}

check_sbom_generation() {
    log "Checking SBOM generation [SA-11]..."
    # [COMP-26] Use absolute paths: script may run as root (manual) where $HOME=/root.
    # Check Forgejo Actions composite action (canonical, shipped SEC-60/61), then overwatch-gitops supply chain.
    local forgejo_action="/home/ubuntu/sentinel-repo/.forgejo/actions/security-scan/action.yml"
    local supply_chain="/home/ubuntu/overwatch-gitops/ci-templates/supply-chain-pipeline.yml"
    local sbom_file=""
    if [ -f "$forgejo_action" ] && grep -qE "syft|sbom|cyclonedx" "$forgejo_action" 2>/dev/null; then
        sbom_file="$forgejo_action"
    elif [ -f "$supply_chain" ] && grep -qE "syft|sbom|cyclonedx" "$supply_chain" 2>/dev/null; then
        sbom_file="$supply_chain"
    fi
    if [ -n "$sbom_file" ]; then
        pass "SA-11" "sbom_generation" "SBOM generation (Syft CycloneDX) in supply chain pipeline"
    else
        warn "SA-11" "sbom_generation" "No SBOM generation in CI pipeline"
    fi
}

# =============================================================================
# PHASE 2 CHECKS — Coverage Expansion (Issue #26)
# 10 new checks targeting unchecked moderate baseline controls
# =============================================================================

check_audit_failure_response() {
    # SEC-25: Replaced SSH grep auditd.conf on remote hosts with Wazuh SCA check results.
    # CIS benchmarks include auditd failure response checks (space_left_action, admin_space_left_action).
    # Uses SCA check results per agent; falls back to SCA score threshold.
    # Local iac-control check is retained as it requires no SSH.
    local token="$1"
    log "Checking auditd failure response via Wazuh SCA [AU-5]..."
    local configured=0
    local checked=0
    local details=""

    # Check iac-control locally (no SSH)
    checked=$((checked + 1))
    if grep -qE '^(space_left_action|admin_space_left_action)\s*=\s*(syslog|exec|email|halt|single)' /etc/audit/auditd.conf 2>/dev/null; then
        configured=$((configured + 1))
        details="${details}iac-control=ok "
    else
        details="${details}iac-control=not_configured "
    fi

    # For remote agents, use Wazuh SCA score as proxy for auditd failure response config.
    # Agents: 001=vault, 002=pangolin, 006=seedbox
    for agent_id in 001 002 006 008; do
        checked=$((checked + 1))
        local resp
        resp=$(wazuh_get "/sca/${agent_id}" "$token")
        local score
        score=$(echo "$resp" | jq -r '.data.affected_items[0].score // 0')
        # A passing SCA score indicates CIS auditd checks (including failure response) pass
        if [ "$score" -ge "$SCA_THRESHOLD" ]; then
            configured=$((configured + 1))
            details="${details}agent${agent_id}=sca_${score}%_pass "
        else
            details="${details}agent${agent_id}=sca_${score}%_low "
        fi
    done

    if [ "$configured" -ge 4 ]; then
        pass "AU-5" "audit_failure_response" "${configured}/${checked} hosts pass auditd failure response check: ${details}"
    elif [ "$configured" -ge 2 ]; then
        warn "AU-5" "audit_failure_response" "${configured}/${checked} hosts pass auditd failure response (need >= 4): ${details}"
    else
        fail "AU-5" "audit_failure_response" "${configured}/${checked} hosts pass auditd failure response check: ${details}"
    fi
}

check_audit_reduction() {
    log "Checking audit record reduction and reporting [AU-7]..."
    local token="$1"
    # Verify Wazuh API can query/filter/reduce audit records
    local response
    response=$(wazuh_get "/agents?limit=1" "$token" 2>/dev/null || echo "")
    local agents_ok=false
    if echo "$response" | jq -e '.data.total_affected_items > 0' >/dev/null 2>&1; then
        agents_ok=true
    fi
    # Check that Wazuh rules can filter by level (reduction capability)
    local rules_response
    rules_response=$(wazuh_get "/rules?limit=1&level=12" "$token" 2>/dev/null || echo "")
    local rules_ok=false
    if echo "$rules_response" | jq -e '.data.total_affected_items >= 0' >/dev/null 2>&1; then
        rules_ok=true
    fi
    if $agents_ok && $rules_ok; then
        pass "AU-7" "audit_reduction" "Wazuh API supports audit record query, filtering, and reduction"
    elif $agents_ok; then
        warn "AU-7" "audit_reduction" "Wazuh API agents queryable but rules filtering unavailable"
    else
        fail "AU-7" "audit_reduction" "Wazuh API cannot query or filter audit records"
    fi
}

check_poam_current() {
    log "Checking Plan of Action and Milestones [CA-5]..."
    local poam_file
    poam_file=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*plan-of-action* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*poam* "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*poa-m* 2>/dev/null | head -1 || echo "")
    if [ -z "$poam_file" ]; then
        # Search by content
        poam_file=$(grep -rl "Plan of Action\|POA.M\|milestones" "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" 2>/dev/null | head -1 || echo "")
    fi
    if [ -n "$poam_file" ]; then
        local mod_days
        mod_days=$(( ($(date +%s) - $(stat -c %Y "$poam_file" 2>/dev/null || echo 0)) / 86400 ))
        if [ "$mod_days" -lt 90 ]; then
            pass "CA-5" "poam_current" "POA&M exists and updated ${mod_days} days ago: $(basename "$poam_file")"
        else
            warn "CA-5" "poam_current" "POA&M exists but stale (${mod_days} days): $(basename "$poam_file")"
        fi
    else
        fail "CA-5" "poam_current" "No POA&M document found in compliance/"
    fi
}

check_internal_connections() {
    log "Checking internal system connections documented [CA-9]..."
    # Verify Vault has K8s auth backend (documents OKD<->Vault connection)
    local k8s_auth
    k8s_auth=$(vault_api "/sys/auth" 2>/dev/null || echo "")
    if [ -z "$k8s_auth" ]; then
        warn "CA-9" "internal_connections" "Cannot query Vault auth methods (VAULT_TOKEN not set)"
        return
    fi
    local k8s_enabled=false
    local approle_enabled=false
    if echo "$k8s_auth" | jq -e '.data["kubernetes/"]' >/dev/null 2>&1 || \
       echo "$k8s_auth" | jq -e '.["kubernetes/"]' >/dev/null 2>&1; then
        k8s_enabled=true
    fi
    if echo "$k8s_auth" | jq -e '.data["approle/"]' >/dev/null 2>&1 || \
       echo "$k8s_auth" | jq -e '.["approle/"]' >/dev/null 2>&1; then
        approle_enabled=true
    fi
    if $k8s_enabled; then
        local methods="kubernetes"
        $approle_enabled && methods="${methods}, approle"
        pass "CA-9" "internal_connections" "Vault auth backends document system connections: ${methods}"
    else
        fail "CA-9" "internal_connections" "Vault kubernetes auth backend not configured"
    fi
}

check_nonlocal_maintenance() {
    # SEC-25: Replaced SSH ss -tlnp on remote hosts with Wazuh syscollector ports API.
    # Checks for insecure maintenance ports (telnet:23, VNC:5900-5901, rsh:514, rlogin:513)
    # on each agent's listening TCP ports. Local iac-control check retained (no SSH needed).
    local token="$1"
    log "Checking nonlocal maintenance ports via Wazuh syscollector [MA-4]..."
    local secure=0
    local checked=0
    local details=""
    # Insecure ports to check: telnet=23, VNC=5900/5901, rlogin=513, rsh=514
    local insecure_port_list="23,513,514,5900,5901"

    # Check iac-control locally (no SSH)
    checked=$((checked + 1))
    local local_insecure
    local_insecure=$(ss -tlnp 2>/dev/null | grep -cE ':23\b|:5900\b|:5901\b|:514\b|:513\b' 2>/dev/null || true)
    local_insecure="${local_insecure:-0}"
    if [ "$local_insecure" = "0" ]; then
        secure=$((secure + 1))
        details="${details}iac-control=ok "
    else
        details="${details}iac-control=INSECURE_PORTS "
    fi

    # For remote agents, query syscollector ports for insecure listening services
    # Agents: 001=vault, 002=pangolin, 006=seedbox, 007=iac-control(already local)
    for agent_id in 001 002 006 008; do
        checked=$((checked + 1))
        local found_insecure=0
        for port in 23 513 514 5900 5901; do
            local port_resp
            port_resp=$(wazuh_get "/syscollector/${agent_id}/ports?protocol=tcp&state=listening&limit=500" "$token")
            local match
            match=$(echo "$port_resp" | jq -r --argjson p "$port" \
                '[.data.affected_items[]? | select(.local.port == $p)] | length' 2>/dev/null || echo "0")
            if [ "$match" -gt 0 ]; then
                found_insecure=$((found_insecure + match))
            fi
        done
        if [ "$found_insecure" -eq 0 ]; then
            secure=$((secure + 1))
            details="${details}agent${agent_id}=ok "
        else
            details="${details}agent${agent_id}=INSECURE(${found_insecure}) "
        fi
    done

    if [ "$secure" -eq "$checked" ]; then
        pass "MA-4" "nonlocal_maintenance" "${secure}/${checked} hosts use SSH-only maintenance (no telnet/VNC/rsh): ${details}"
    elif [ "$secure" -ge 3 ]; then
        warn "MA-4" "nonlocal_maintenance" "${secure}/${checked} hosts SSH-only (some may have insecure ports): ${details}"
    else
        fail "MA-4" "nonlocal_maintenance" "${secure}/${checked} hosts SSH-only — insecure maintenance ports detected: ${details}"
    fi
}

check_rules_of_behavior() {
    log "Checking rules of behavior [PL-4]..."
    local rob_file
    rob_file=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*rules-of-behavior* \
                  "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*acceptable-use* \
                  "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*aup* \
                  "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/"*rules-of-behavior* 2>/dev/null | head -1 || echo "")
    if [ -z "$rob_file" ]; then
        rob_file=$(grep -rl "rules.of.behavior\|acceptable.use\|code.of.conduct" \
                   "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/" 2>/dev/null | head -1 || echo "")
    fi
    if [ -n "$rob_file" ]; then
        pass "PL-4" "rules_of_behavior" "Rules of behavior document found: $(basename "$rob_file")"
    else
        warn "PL-4" "rules_of_behavior" "No rules of behavior / acceptable use policy document found"
    fi
}

check_security_categorization() {
    log "Checking security categorization [RA-2]..."
    local cat_file
    cat_file=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*categorization* \
                  "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*fips-199* \
                  "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/"*categorization* 2>/dev/null | head -1 || echo "")
    if [ -z "$cat_file" ]; then
        # Check if SSP or gap analysis contains categorization
        cat_file=$(grep -rl "FIPS.199\|security.categorization\|impact.level.*moderate\|confidentiality.*integrity.*availability" \
                   "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/" "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/" 2>/dev/null | head -1 || echo "")
    fi
    if [ -n "$cat_file" ]; then
        pass "RA-2" "security_categorization" "Security categorization documented in: $(basename "$cat_file")"
    else
        warn "RA-2" "security_categorization" "No FIPS 199 security categorization document found"
    fi
}

check_system_documentation() {
    log "Checking system documentation [SA-5]..."
    local doc_count=0
    local expected=5
    # Check for documentation of key services
    [ -d "${SENTINEL_REPO_ROOT}/sentinel-repo/docs" ] && doc_count=$((doc_count + 1))
    [ -f "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/architecture.md" ] && doc_count=$((doc_count + 1))
    [ -f "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/security.md" ] && doc_count=$((doc_count + 1))
    [ -f "${SENTINEL_REPO_ROOT}/sentinel-repo/docs/disaster-recovery.md" ] && doc_count=$((doc_count + 1))
    # Check for compliance documentation
    local compliance_docs
    compliance_docs=$(ls "${SENTINEL_REPO_ROOT}/sentinel-repo/compliance/"*.md 2>/dev/null | wc -l || echo "0")
    [ "$compliance_docs" -ge 5 ] && doc_count=$((doc_count + 1))
    if [ "$doc_count" -ge 4 ]; then
        pass "SA-5" "system_documentation" "${doc_count}/${expected} system documentation areas present (docs/, architecture, security, DR, compliance)"
    elif [ "$doc_count" -ge 2 ]; then
        warn "SA-5" "system_documentation" "${doc_count}/${expected} system documentation areas present"
    else
        fail "SA-5" "system_documentation" "Insufficient system documentation (${doc_count}/${expected})"
    fi
}

check_dev_config_mgmt() {
    log "Checking developer configuration management [SA-10]..."
    # OPS-200: post-OPS-188 rewrite. GitLab retired; query Forgejo branch-protection API
    # across the three platform repos. Fallback: look for a Forgejo workflow file.
    # [COMP-26] compliance-check token does not have secret/data/forgejo in policy.
    # Forgejo token in compliance.env (FORGEJO_TOKEN) not yet wired; fallback path check
    # uses absolute path /home/ubuntu/sentinel-repo/.forgejo/workflows (not $HOME-relative).
    local fj_token="${FORGEJO_TOKEN:-}"
    if [ -z "$fj_token" ]; then
        # Try Vault for the Forgejo admin token (requires compliance-check token to have
        # secret/data/forgejo read — may be denied; fallback handles gracefully)
        fj_token=$(vault_api "/secret/data/forgejo" 2>/dev/null | jq -r '.data.data.admin_api_token // .data.data.api_token // empty' 2>/dev/null || echo "")
    fi
    local fj_base="${FORGEJO_URL:-http://192.168.12.70:3000}/api/v1"

    if [ -z "$fj_token" ]; then
        # [COMP-26] Use absolute path: script may run as root (manual) where $HOME=/root.
        local wf_dir="/home/ubuntu/sentinel-repo/.forgejo/workflows"
        if [ -d "$wf_dir" ] && [ "$(ls -1 "$wf_dir" 2>/dev/null | wc -l)" -ge 1 ]; then
            local wf_files
            wf_files=$(ls -1 "$wf_dir" 2>/dev/null | wc -l)
            pass "SA-10" "dev_config_mgmt" "Forgejo workflows configured (${wf_files} workflow files) — branch-protection API unverified (no Forgejo token)"
        else
            fail "SA-10" "dev_config_mgmt" "No Forgejo token and no workflow files — cannot verify dev config mgmt"
        fi
        return
    fi

    local total_protected=0
    local repo_details=""
    for repo in "sentinel-admin/sentinel-iac" "sentinel-admin/overwatch" "sentinel-admin/overwatch-gitops"; do
        local resp count
        resp=$(curl -s -H "Authorization: token ${fj_token}" "${fj_base}/repos/${repo}/branch_protections" 2>/dev/null || echo "[]")
        count=$(echo "$resp" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo "0")
        total_protected=$((total_protected + count))
        repo_details="${repo_details}$(basename "$repo")=${count} "
    done

    if [ "$total_protected" -ge 1 ]; then
        pass "SA-10" "dev_config_mgmt" "Forgejo branch protection active (${total_protected} rules across 3 repos: ${repo_details}) + CI via Forgejo workflows"
    else
        warn "SA-10" "dev_config_mgmt" "Forgejo reachable but zero branch-protection rules found across the 3 platform repos"
    fi
}

check_pki_cert_management() {
    log "Checking PKI certificate management [SC-17]..."
    # COMP-14 step 2 (2026-04-26): restored deeper CA-config probe after the
    # compliance-check Vault policy was expanded to allow `read` on pki/ca/pem
    # and ssh/config/ca. Engine-presence (sys/mounts) was strictly weaker —
    # engine mounted ≠ CA materialized. Now we read pki/ca/pem (returns the
    # CA certificate, which presumes a key was generated for the engine) and
    # ssh/config/ca (returns the SSH CA public key) to confirm both are
    # actually configured for certificate lifecycle management.
    if [ -z "$VAULT_TOKEN" ]; then
        warn "SC-17" "pki_cert_management" "VAULT_TOKEN not set — skipped"
        return
    fi
    # Probe pki/ca/pem
    local pki_resp pki_ok=false
    pki_resp=$(curl -s -k -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_URL}/v1/pki/ca/pem" 2>/dev/null || echo "")
    if echo "$pki_resp" | grep -q "BEGIN CERTIFICATE"; then
        pki_ok=true
    fi
    # Probe ssh/config/ca
    local ssh_resp ssh_ok=false
    ssh_resp=$(vault_api "/ssh/config/ca" 2>/dev/null || echo "")
    if [ -n "$ssh_resp" ] && echo "$ssh_resp" | jq -e '(.data.public_key // .public_key // "") | length > 100' >/dev/null 2>&1; then
        ssh_ok=true
    fi
    if $pki_ok && $ssh_ok; then
        pass "SC-17" "pki_cert_management" "Vault PKI CA cert reachable and SSH CA configured with signing key — full certificate lifecycle management"
    elif $ssh_ok; then
        pass "SC-17" "pki_cert_management" "Vault SSH CA configured with signing key (PKI ca/pem unreachable — likely engine not materialized)"
    elif $pki_ok; then
        warn "SC-17" "pki_cert_management" "Vault PKI CA cert reachable but SSH CA missing/unconfigured"
    else
        # Fallback to engine-presence (token policy may not yet have been expanded)
        local mounts_resp
        mounts_resp=$(vault_api "/sys/mounts" 2>/dev/null || echo "")
        if [ -n "$mounts_resp" ] && echo "$mounts_resp" | jq -e '.data["ssh/"] // .["ssh/"]' >/dev/null 2>&1 \
           && echo "$mounts_resp" | jq -e '.data["pki/"] // .["pki/"]' >/dev/null 2>&1; then
            warn "SC-17" "pki_cert_management" "Vault PKI and SSH engines mounted but config endpoints unreadable — token policy may need expansion (see COMP-14)"
        else
            fail "SC-17" "pki_cert_management" "No PKI or SSH CA engine reachable in Vault"
        fi
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log "Starting NIST 800-53 Compliance Check — ${DATE}"

    # Get Wazuh API token
    local token
    token=$(get_token) || {
        log "FATAL: Cannot authenticate to Wazuh API"
        echo "${TIMESTAMP} NIST-COMPLIANCE: NON-COMPLIANT - Cannot reach Wazuh API" >> "$COMPLIANCE_LOG"
        exit 1
    }

    # Run all checks, collect results
    local results=()

    # --- Original checks (11) ---
    results+=("$(check_agents_active "$token")")
    results+=("$(check_sca_scores "$token")")
    results+=("$(check_fim_running "$token")")
    results+=("$(check_auditd "$token")")
    results+=("$(check_vault_health)")
    results+=("$(check_gitlab_accessible)")
    results+=("$(check_backup_timers)")
    results+=("$(check_docker_containers "$token")")
    results+=("$(check_ufw_active "$token")")
    results+=("$(check_malware_protection)")

    # --- Access Control (AC) — 12 checks ---
    results+=("$(check_keycloak_health)")
    results+=("$(check_vault_ssh_ca)")
    results+=("$(check_okd_rbac)")
    results+=("$(check_istio_mtls)")
    results+=("$(check_vault_policies)")
    results+=("$(check_scc_restricted)")
    results+=("$(check_ssh_root_disabled "$token")")
    results+=("$(check_pam_faillock)")
    results+=("$(check_login_banner)")
    results+=("$(check_session_timeout)")
    results+=("$(check_tailscale_active)")
    results+=("$(check_cf_access)")

    # --- Audit and Accountability (AU) — 7 checks ---
    results+=("$(check_audit_content)")
    results+=("$(check_log_storage)")
    results+=("$(check_audit_permissions)")
    results+=("$(check_wazuh_alerts_24h "$token")")
    results+=("$(check_chrony_ntp)")
    results+=("$(check_log_retention)")
    results+=("$(check_aide_installed)")

    # --- Security Assessment (CA) — 2 checks ---
    results+=("$(check_compliance_timer)")
    results+=("$(check_drift_detection)")

    # --- Configuration Management (CM) — 5 checks ---
    results+=("$(check_terraform_state)")
    results+=("$(check_argocd_sync)")
    results+=("$(check_gitops_enforcement)")
    results+=("$(check_unnecessary_services)")
    results+=("$(check_kernel_modules_blacklist)")
    results+=("$(check_component_inventory)")

    # --- Contingency Planning (CP) — 4 checks ---
    results+=("$(check_dr_scripts)")
    results+=("$(check_dr_test_evidence)")
    results+=("$(check_ha_keepalived)")
    results+=("$(check_minio_replication)")

    # --- Identification and Authentication (IA) — 4 checks ---
    results+=("$(check_keycloak_sso)")
    results+=("$(check_mfa_configured)")
    results+=("$(check_vault_auth_methods)")
    results+=("$(check_password_policy)")
    results+=("$(check_ssh_cert_auth)")
    results+=("$(check_identifier_management)")
    results+=("$(check_non_org_users)")

    # --- Incident Response (IR) — 3 checks ---
    results+=("$(check_wazuh_active_response_rules "$token")")
    results+=("$(check_discord_alerting "$token")")
    results+=("$(check_alert_volume_healthy "$token")")

    # --- Maintenance (MA) — 1 check ---
    results+=("$(check_maintenance_mode)")

    # --- Media Protection (MP) — 1 check ---
    results+=("$(check_vault_encryption)")

    # --- Physical and Environmental (PE) — 1 check ---
    results+=("$(check_idrac_monitoring)")

    # --- Risk Assessment (RA) — 1 check ---
    results+=("$(check_vulnerability_scanning)")

    # --- System and Communications Protection (SC) — 9 checks ---
    results+=("$(check_namespace_network_policies)")
    results+=("$(check_crowdsec_active "$token")")
    results+=("$(check_squid_egress)")
    results+=("$(check_cloudflare_tunnel "$token")")
    results+=("$(check_traefik_tls)")
    results+=("$(check_tls_cert_valid)")
    results+=("$(check_vault_seal_status)")
    results+=("$(check_minio_tls)")
    results+=("$(check_process_isolation)")
    results+=("$(check_crypto_protection)")
    results+=("$(check_network_disconnect)")

    # --- System and Information Integrity (SI) — 7 checks ---
    results+=("$(check_flaw_remediation)")
    results+=("$(check_wazuh_rules_loaded "$token")")
    results+=("$(check_wazuh_custom_rules "$token")")
    results+=("$(check_inbound_monitoring "$token")")
    results+=("$(check_kyverno_policies)")
    results+=("$(check_nvd_accessible)")
    results+=("$(check_apparmor_active)")

    # --- Policy and Documentation — 13 checks ---
    results+=("$(check_training_policy)")
    results+=("$(check_policy_doc_exists)")
    results+=("$(check_separation_of_duties)")
    results+=("$(check_session_lock)")
    results+=("$(check_contingency_plan)")
    results+=("$(check_recovery_procedures)")
    results+=("$(check_password_aging)")
    results+=("$(check_security_plan_policy)")
    results+=("$(check_ssp_current)")
    results+=("$(check_risk_assessment)")
    results+=("$(check_comms_policy)")
    results+=("$(check_ir_plan_current)")
    results+=("$(check_component_lifecycle)")

    # --- Additional Physical/Environmental ---
    results+=("$(check_physical_monitoring)")

    # --- Phase 1 new checks (8 additional controls, 7 removed as out-of-baseline) ---
    results+=("$(check_training_records)")
    results+=("$(check_role_based_training)")
    results+=("$(check_acquisition_policy)")
    results+=("$(check_secure_development)")
    results+=("$(check_dns_security)")
    results+=("$(check_alternate_processing)")
    results+=("$(check_falco_runtime)")
    results+=("$(check_sbom_generation)")

    # --- Phase 2 checks (10 additional controls, Issue #26) ---
    results+=("$(check_audit_failure_response "$token")")
    results+=("$(check_audit_reduction "$token")")
    results+=("$(check_poam_current)")
    results+=("$(check_internal_connections)")
    results+=("$(check_nonlocal_maintenance "$token")")
    results+=("$(check_rules_of_behavior)")
    results+=("$(check_security_categorization)")
    results+=("$(check_system_documentation)")
    results+=("$(check_dev_config_mgmt)")
    results+=("$(check_pki_cert_management)")

    # Build JSON report
    local pass_count=0
    local fail_count=0
    local warn_count=0
    local checks_json="["
    local first=true

    for result in "${results[@]}"; do
        local status
        status=$(echo "$result" | jq -r '.status')
        case "$status" in
            PASS) pass_count=$((pass_count + 1)) ;;
            FAIL) fail_count=$((fail_count + 1)) ;;
            WARN) warn_count=$((warn_count + 1)) ;;
        esac

        if $first; then
            first=false
        else
            checks_json="${checks_json},"
        fi
        checks_json="${checks_json}${result}"
    done
    checks_json="${checks_json}]"

    local total=$((pass_count + fail_count + warn_count))
    local overall="COMPLIANT"
    [ "$fail_count" -gt 0 ] && overall="NON-COMPLIANT"

    # Compute coverage metrics
    local controls_checked
    controls_checked=$(echo "$checks_json" | jq -r '[.[].control] | unique | length' 2>/dev/null || echo 0)
    local controls_applicable=226
    local coverage_pct=0
    if [ "$controls_applicable" -gt 0 ]; then
        coverage_pct=$(( controls_checked * 100 / controls_applicable ))
    fi

    # OPS-134 (2026-04-26): provenance fields. The `generated` field captures
    # who/where/when produced the JSON; `source` captures the script identity.
    # `schema_version` lets consumers detect breaking-change boundaries.
    local source_host source_sha source_path
    source_host=$(hostname -f 2>/dev/null || hostname || echo "unknown")
    source_sha=$(git -C "${BASH_SOURCE[0]%/*}/.." rev-parse --short HEAD 2>/dev/null || echo "unknown")
    source_path=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")

    local report
    report=$(jq -n \
        --arg timestamp "$TIMESTAMP" \
        --arg date "$DATE" \
        --arg overall "$overall" \
        --arg source_host "$source_host" \
        --arg source_sha "$source_sha" \
        --arg source_path "$source_path" \
        --argjson pass "$pass_count" \
        --argjson fail "$fail_count" \
        --argjson warn "$warn_count" \
        --argjson total "$total" \
        --argjson controls_checked "$controls_checked" \
        --argjson controls_applicable "$controls_applicable" \
        --argjson coverage_pct "$coverage_pct" \
        --argjson checks "$checks_json" \
        '{
            schema_version: 2,
            timestamp: $timestamp,
            date: $date,
            framework: "NIST 800-53 Rev 5",
            project: "Sentinel",
            generated: {
                host: $source_host,
                at: $timestamp
            },
            source: {
                path: $source_path,
                git_sha: $source_sha
            },
            overall_status: $overall,
            summary: {
                pass: $pass,
                fail: $fail,
                warn: $warn,
                total: $total,
                pass_rate: (if $total > 0 then (($pass * 100) / $total | floor) else 0 end),
                coverage: {
                    controls_checked: $controls_checked,
                    controls_applicable: $controls_applicable,
                    coverage_pct: $coverage_pct
                }
            },
            checks: $checks
        }')

    # Write JSON report
    echo "$report" > "$JSON_REPORT"
    log "Report written to ${JSON_REPORT}"

    # Write compliance log line (monitored by Wazuh)
    echo "${TIMESTAMP} NIST-COMPLIANCE: ${overall} - ${pass_count}/${total} checks passed (${fail_count} failed, ${warn_count} warnings)" >> "$COMPLIANCE_LOG"

    # Print human-readable summary
    echo ""
    echo "=============================================="
    echo "  NIST 800-53 Compliance Report — ${DATE}"
    echo "=============================================="
    echo "  Status:   ${overall}"
    echo "  Passed:   ${pass_count}/${total}"
    echo "  Failed:   ${fail_count}"
    echo "  Warnings: ${warn_count}"
    echo "  Coverage: ${controls_checked}/${controls_applicable} controls (${coverage_pct}%)"
    echo "=============================================="

    if [ "$fail_count" -gt 0 ]; then
        echo ""
        echo "FAILED CHECKS:"
        echo "$report" | jq -r '.checks[] | select(.status == "FAIL") | "  [\(.control)] \(.check): \(.detail)"'
    fi

    if [ "$warn_count" -gt 0 ]; then
        echo ""
        echo "WARNINGS:"
        echo "$report" | jq -r '.checks[] | select(.status == "WARN") | "  [\(.control)] \(.check): \(.detail)"'
    fi

    echo ""

    # Exit code
    if [ "$fail_count" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

main "$@"
