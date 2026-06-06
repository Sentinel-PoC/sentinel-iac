#!/usr/bin/env bash
# vault-autounseal-rotate.sh — weekly rotation of the prod-Vault auto-unseal token.
# OPS-191 (design + implementation), follow-up to SEC-44 / OPS-190.
#
# Runs from iac-control (as ubuntu, via systemd timer vault-autounseal-rotate.timer).
# Connects to the Transit Vault on iac-control (http://192.168.12.210:8201) to issue
# a fresh periodic autounseal token, then SSHes to vault-server (192.168.12.206) to
# update /etc/vault/config/config.hcl and restart the Vault container.
#
# USAGE:
#   vault-autounseal-rotate.sh               # real rotation
#   vault-autounseal-rotate.sh --dry-run     # print plan, touch nothing
#
# REQUIRED FILES (deploy out-of-band — see docs/runbooks/15-vault-autounseal-rotation.md):
#   /etc/vault-unseal/rotation-token         (mode 0400 ubuntu:root)
#       Transit Vault orphan periodic token, policy autounseal-rotate, period=720h.
#       Must be used with token role autounseal-rotation on the transit vault.
#   /etc/vault-unseal/autounseal-accessor.token  (mode 0644 root:root)
#       Accessor of the CURRENT prod-Vault autounseal token (updated by this script).
#
# SSH ACCESS:
#   Uses ~/.ssh/id_sentinel + ~/.ssh/id_sentinel-cert.pub (Vault-signed, renewed 3h).
#   Connects as koiakoia@192.168.12.206, sudo for docker/config operations.
#
# EXIT CODES:
#   0  — rotation succeeded (or --dry-run completed)
#   1  — pre-flight failed (sealed, unreachable) — no changes made
#   2  — rotation failed mid-flight — CRIT alert; check /var/log/vault-autounseal-rotation.json
#   3  — config parse / file error
#
# LOG OUTPUT:
#   /var/log/vault-autounseal-rotation.json  — one JSON line per run
#   /var/log/vault-autounseal-debug-YYYYMMDD-HHMMSS.log  — set -x trace (600 ubuntu:ubuntu)
#   journald tag: vault-autounseal-rotate     — same JSON, decoded by vault-probe-decoders.xml
#
# SECURITY NOTE: xtrace (set -x) is enabled for diagnostics. All curls carrying
# X-Vault-Token and all token-value assignments are wrapped in { set +x; } 2>/dev/null
# to prevent hvs.* values from appearing in the debug log.
#
# NIST: SC-12 (cryptographic key management), IA-5 (authenticator management),
#       CP-2/CP-10 (contingency), CM-3 (change tracking)

set -uo pipefail

# ---------------------------------------------------------------------------
# Debug logging — persistent file outside journald (OPS-191 fix, 2026-05-06)
# chmod 600 ubuntu:ubuntu so only the service user can read traces.
# Falls back to /tmp if /var/log is not writable (best-effort, not fatal).
# Token values are NEVER written here — see set +x wraps throughout.
# ---------------------------------------------------------------------------
_DEBUG_LOG="/var/log/vault-autounseal-debug-$(date +%Y%m%d-%H%M%S).log"
# install -m 0600 creates the file with mode 0600 atomically (ignores umask).
# This replaces the old touch+chmod pattern which left a race in the /tmp
# fallback: touch never ran on the /tmp path, so chmod 600 was a no-op on a
# non-existent file, and exec 2>> created it at umask 022 (644). OPS-385 Bug 3.
if ! install -m 0600 /dev/null "$_DEBUG_LOG" 2>/dev/null; then
    _DEBUG_LOG="/tmp/vault-autounseal-debug-$(date +%Y%m%d-%H%M%S).log"
    install -m 0600 /dev/null "$_DEBUG_LOG" 2>/dev/null \
        || { echo "FATAL: cannot create debug log at $_DEBUG_LOG" >&2; exit 3; }
fi
chown ubuntu:ubuntu "$_DEBUG_LOG" 2>/dev/null || true
exec 2>>"$_DEBUG_LOG"
set -x
printf '%s SCRIPT_START pid=%d user=%s log=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$(id -un)" "$_DEBUG_LOG" >&2

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TRANSIT_VAULT_ADDR="${VAULT_AUTOUNSEAL_TRANSIT_ADDR:-http://192.168.12.210:8201}"
PROD_VAULT_HEALTH="${VAULT_AUTOUNSEAL_PROD_HEALTH:-https://vault.208.haist.farm/v1/sys/health}"
PROD_VAULT_INTERNAL="${VAULT_AUTOUNSEAL_PROD_INTERNAL:-http://192.168.12.206:8200}"

ROTATION_TOKEN_FILE="${VAULT_AUTOUNSEAL_ROTATION_TOKEN_FILE:-/etc/vault-unseal/rotation-token}"
ACCESSOR_FILE="${VAULT_AUTOUNSEAL_ACCESSOR_FILE:-/etc/vault-unseal/autounseal-accessor.token}"

VAULT_SERVER_SSH_HOST="192.168.12.206"
VAULT_SERVER_SSH_USER="koiakoia"
VAULT_SERVER_CONFIG="/etc/vault/config/config.hcl"

SSH_KEY="$HOME/.ssh/id_sentinel"
SSH_CERT="$HOME/.ssh/id_sentinel-cert.pub"
SSH_OPTS="-i $SSH_KEY -o CertificateFile=$SSH_CERT -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

LOG_FILE="${VAULT_AUTOUNSEAL_ROTATE_LOG:-/var/log/vault-autounseal-rotation.json}"

# Token role on transit vault that issues autounseal tokens.
# Role defines: allowed_policies=[autounseal], orphan=true, period=800h, renewable=true.
# Must be created before first real run — see Ansible playbook
# ansible/playbooks/vault-transit-tokenrole.yml (OPS-191).
TOKEN_ROLE="autounseal-rotation"

# How long to wait for Vault to unseal after restart (seconds)
HEALTH_POLL_TIMEOUT=60
HEALTH_POLL_INTERVAL=3

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Log SSH cert validity at script start — safe, no secrets in cert metadata.
# Captures the cert window so post-mortem can confirm cert was valid at fire time.
if [[ -f "$SSH_CERT" ]]; then
    _CERT_VALID=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null | grep -E 'Valid:' | head -1 | tr -s ' ' || echo 'unreadable')
    printf '%s CERT_CHECK: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_CERT_VALID" >&2
else
    printf '%s CERT_MISSING: %s not found\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SSH_CERT" >&2
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
RUN_ID=$(python3 -c 'import uuid; print(str(uuid.uuid4())[:8])')

emit_log() {
    local status="$1" level="$2" message="$3"
    shift 3
    # Extra key=value pairs as a JSON object string
    local extras="${1:-}"
    local json
    json=$(python3 - "$status" "$level" "$message" "$extras" "$RUN_ID" "$TS" \
        "$TRANSIT_VAULT_ADDR" "$DRY_RUN" <<'PYEOF'
import sys, json
status, level, message, extras_str, run_id, ts, transit, dry_run_s = sys.argv[1:]
dry_run = dry_run_s.lower() == "true"

obj = {
    "check":   "vault_autounseal_rotate",
    "run_id":  run_id,
    "ts":      ts,
    "status":  status,
    "level":   level,
    "message": message,
    "transit_vault": transit,
    "dry_run": dry_run,
}
if extras_str.strip():
    try:
        obj.update(json.loads(extras_str))
    except Exception:
        obj["extras_raw"] = extras_str

print(json.dumps(obj))
PYEOF
)
    # Append to log file; fall back to /tmp if the main path is not writable
    # (OPS-191 fix: log file is root:root by default, ubuntu cannot write).
    if ! echo "$json" >> "$LOG_FILE" 2>/dev/null; then
        echo "$json" >> "/tmp/vault-autounseal-rotation-fallback.json" 2>/dev/null || true
    fi
    # Emit to journald
    local syslog_pri
    case "$level" in
        critical) syslog_pri="user.crit" ;;
        warning)  syslog_pri="user.warning" ;;
        *)        syslog_pri="user.info" ;;
    esac
    logger -t vault-autounseal-rotate -p "$syslog_pri" "$json" 2>/dev/null || true
    echo "$json"
}

accessor_fp() {
    # Last 8 chars of an accessor — non-secret fingerprint safe to log
    local acc="${1:-}"
    [[ -n "$acc" ]] && echo "${acc: -8}" || echo "unknown"
}

die() {
    local exit_code=$1 status=$2 msg=$3 extras="${4:-}"
    emit_log "$status" "critical" "$msg" "$extras"
    exit "$exit_code"
}

run_ssh() {
    # Run a command on vault-server; in dry-run mode just print it
    local cmd="$1"
    if $DRY_RUN; then
        echo "[dry-run] ssh $VAULT_SERVER_SSH_USER@$VAULT_SERVER_SSH_HOST: $cmd"
        return 0
    fi
    ssh $SSH_OPTS "${VAULT_SERVER_SSH_USER}@${VAULT_SERVER_SSH_HOST}" "$cmd"
}

# ---------------------------------------------------------------------------
# Phase 0: dry-run header
# ---------------------------------------------------------------------------
if $DRY_RUN; then
    echo "=== vault-autounseal-rotate.sh --dry-run ==="
    echo "Transit Vault:      $TRANSIT_VAULT_ADDR"
    echo "Prod Vault health:  $PROD_VAULT_HEALTH"
    echo "Rotation token:     $ROTATION_TOKEN_FILE"
    echo "Accessor file:      $ACCESSOR_FILE"
    echo "SSH target:         $VAULT_SERVER_SSH_USER@$VAULT_SERVER_SSH_HOST"
    echo "Config path:        $VAULT_SERVER_CONFIG"
    echo "Token role:         $TOKEN_ROLE"
    echo "Run ID:             $RUN_ID"
    echo ""
fi

# ---------------------------------------------------------------------------
# Phase 0.5: Refresh SSH cert before any SSH operations (OPS-477)
# ---------------------------------------------------------------------------
# Re-sign id_sentinel-cert.pub via Vault at the very start of each run.
# This ensures every execution — including retries triggered hours after the
# initial rotation fired — begins with a fresh 4h cert window, preventing
# cert-expired failures regardless of when the jit-ssh-cert-renew timer last
# fired. Self-healing: no operator action needed after a retry gap.
#
# Uses /usr/local/bin/jit-ssh-cert-renew (deployed by iac-control role).
# That script reads /home/ubuntu/.vault-token and signs id_sentinel.pub via
# the Vault SSH CA (ssh/sign/admin, principals: ubuntu,koiakoia, ttl=4h).
# Aborts rotation (exit 1 — no changes made) if the refresh fails, so the
# operator knows the cert lifecycle is broken before any SSH ops are attempted.
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    if /usr/local/bin/jit-ssh-cert-renew >> "$_DEBUG_LOG" 2>&1; then
        _CERT_FRESH=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null \
            | grep -E 'Valid:' | head -1 | tr -s ' ' || echo 'unreadable')
        emit_log "SSH_CERT_REFRESHED" "info" \
            "id_sentinel SSH cert refreshed at rotation start (OPS-477)" \
            "{\"cert_window\": \"$_CERT_FRESH\"}"
    else
        die 1 "SSH_CERT_REFRESH_FAILED" \
            "jit-ssh-cert-renew failed — aborting rotation to prevent cert-expired SSH failure. Check ~/.vault-token and ssh/sign/admin endpoint reachability."
    fi
else
    echo "[dry-run] Would refresh id_sentinel SSH cert via /usr/local/bin/jit-ssh-cert-renew (OPS-477)"
fi

# ---------------------------------------------------------------------------
# Phase 1: Pre-flight checks
# ---------------------------------------------------------------------------

# 1a. Read rotation token
# set +x: token value must not appear in xtrace (grep hvs. check)
if [[ ! -r "$ROTATION_TOKEN_FILE" ]]; then
    die 3 "ERROR" "rotation-token file unreadable: $ROTATION_TOKEN_FILE (mode 0400 ubuntu:root required)"
fi
{ set +x; } 2>/dev/null
ROTATION_TOKEN=$(tr -d '[:space:]' < "$ROTATION_TOKEN_FILE")
{ set +x; } 2>/dev/null
# OPS-385 Bug 1: test token emptiness inside the guard — [[ -z "$ROTATION_TOKEN" ]]
# with xtrace on would expand the token value into the trace log.
_rotation_token_empty=false
[[ -z "$ROTATION_TOKEN" ]] && _rotation_token_empty=true || true
{ set -x; } 2>/dev/null
if $_rotation_token_empty; then
    die 3 "ERROR" "rotation-token file is empty: $ROTATION_TOKEN_FILE"
fi

# 1b. Read current accessor
if [[ ! -r "$ACCESSOR_FILE" ]]; then
    die 3 "ERROR" "accessor file unreadable: $ACCESSOR_FILE"
fi
OLD_ACCESSOR=$(tr -d '[:space:]' < "$ACCESSOR_FILE")
if [[ -z "$OLD_ACCESSOR" ]]; then
    die 3 "ERROR" "accessor file is empty: $ACCESSOR_FILE"
fi
OLD_ACCESSOR_FP=$(accessor_fp "$OLD_ACCESSOR")

if $DRY_RUN; then
    echo "[dry-run] Old accessor fingerprint: ...${OLD_ACCESSOR_FP}"
fi

# 1c. Renew rotation-token to reset its period
if ! $DRY_RUN; then
    { set +x; } 2>/dev/null
    RENEW_RESP=$(curl -s --max-time 10 \
        -H "X-Vault-Token: $ROTATION_TOKEN" \
        -X POST \
        "${TRANSIT_VAULT_ADDR}/v1/auth/token/renew-self" 2>/dev/null)
    RENEW_CODE=$?
    { set -x; } 2>/dev/null
    # OPS-385 Bug 1: RENEW_RESP contains client_token in the JSON body.
    # Echo-ing it under xtrace leaks the token value. Extract TTL inside guard.
    { set +x; } 2>/dev/null
    RENEW_TTL=$(echo "$RENEW_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth"]["lease_duration"])' 2>/dev/null || echo "0")
    { set -x; } 2>/dev/null
    if [[ $RENEW_CODE -ne 0 ]] || [[ "$RENEW_TTL" == "0" ]]; then
        die 1 "PREFLIGHT_FAILED" "Failed to renew rotation-token (lease_duration=0 or curl error $RENEW_CODE). Re-bootstrap required." \
            "{\"renew_ttl\": \"$RENEW_TTL\"}"
    fi
    emit_log "ROTATION_TOKEN_RENEWED" "info" "rotation-token renewed, new TTL ${RENEW_TTL}s" \
        "{\"renew_ttl\": $RENEW_TTL}"
else
    echo "[dry-run] Would renew rotation-token at $TRANSIT_VAULT_ADDR/v1/auth/token/renew-self"
fi

# 1d. Check transit vault health
TRANSIT_HEALTH=$(curl -s --max-time 5 "${TRANSIT_VAULT_ADDR}/v1/sys/health" 2>/dev/null)
TRANSIT_SEALED=$(echo "$TRANSIT_HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sealed","?"))' 2>/dev/null || echo "?")
if [[ "$TRANSIT_SEALED" != "False" ]]; then
    die 1 "PREFLIGHT_FAILED" "Transit Vault not healthy or sealed (sealed=$TRANSIT_SEALED). Aborting." \
        "{\"transit_sealed\": \"$TRANSIT_SEALED\"}"
fi

# 1e. Check prod Vault health — must be unsealed
PROD_HEALTH=$(curl -sk --max-time 10 "$PROD_VAULT_HEALTH" 2>/dev/null)
PROD_SEALED=$(echo "$PROD_HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sealed","?"))' 2>/dev/null || echo "?")
if [[ "$PROD_SEALED" != "False" ]]; then
    die 1 "PREFLIGHT_FAILED" "Prod Vault is sealed or unreachable (sealed=$PROD_SEALED). Aborting rotation — do not touch config while sealed." \
        "{\"prod_sealed\": \"$PROD_SEALED\"}"
fi

emit_log "PREFLIGHT_OK" "info" "Pre-flight passed: transit unsealed, prod Vault unsealed, rotation-token valid" \
    "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\"}"

# ---------------------------------------------------------------------------
# Phase 2: Issue new autounseal token on transit vault via token role
# ---------------------------------------------------------------------------
# Uses /v1/auth/token/create/autounseal-rotation (role-based create).
# The role defines: allowed_policies=[autounseal], orphan=true, period=800h,
# renewable=true — no inline policy/period/no_parent needed in the request body.
# Root cause of 5/3 failure: plain /v1/auth/token/create with no_parent=true
# requires sudo capability or create-orphan path; rotation-token has neither.
# Token role is the correct fix (OPS-191 root cause analysis 2026-05-06).
NEW_TOKEN=""
NEW_ACCESSOR=""

if ! $DRY_RUN; then
    { set +x; } 2>/dev/null
    # Token value and accessor must not appear in xtrace
    CREATE_RESP=$(curl -s --max-time 10 \
        -H "X-Vault-Token: $ROTATION_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        --data "{}" \
        "${TRANSIT_VAULT_ADDR}/v1/auth/token/create/${TOKEN_ROLE}" 2>/dev/null)
    CREATE_CODE=$?
    NEW_TOKEN=$(echo "$CREATE_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth"]["client_token"])' 2>/dev/null || echo "")
    NEW_ACCESSOR=$(echo "$CREATE_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["auth"]["accessor"])' 2>/dev/null || echo "")
    { set -x; } 2>/dev/null

    # OPS-385 Bug 1: [[ -z "$NEW_TOKEN" ]] under xtrace expands the full token
    # value into the trace log. Set a boolean flag inside the guard instead.
    { set +x; } 2>/dev/null
    _create_failed=false
    [[ $CREATE_CODE -ne 0 || -z "$NEW_TOKEN" || -z "$NEW_ACCESSOR" ]] && _create_failed=true || true
    { set -x; } 2>/dev/null
    if $_create_failed; then
        die 2 "TOKEN_CREATE_FAILED" "Failed to create new autounseal token via role ${TOKEN_ROLE} (curl rc=$CREATE_CODE). Check role exists on transit vault." \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"token_role\": \"$TOKEN_ROLE\"}"
    fi
    NEW_ACCESSOR_FP=$(accessor_fp "$NEW_ACCESSOR")
    emit_log "NEW_TOKEN_CREATED" "info" "New autounseal token created on transit vault via role ${TOKEN_ROLE}" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"token_role\": \"$TOKEN_ROLE\"}"
else
    echo "[dry-run] Would create new token via role $TOKEN_ROLE on transit vault"
    NEW_ACCESSOR_FP="DRYR-UNN"
fi

# ---------------------------------------------------------------------------
# Phase 3: Update config.hcl on vault-server
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    # 3a. Backup the current config
    run_ssh "sudo cp -p $VAULT_SERVER_CONFIG ${VAULT_SERVER_CONFIG}.pre-rotation" || {
        # If we can't backup, abort and revoke the new (unused) token
        { set +x; } 2>/dev/null
        curl -s --max-time 5 \
            -H "X-Vault-Token: $ROTATION_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            --data "{\"accessor\": \"$NEW_ACCESSOR\"}" \
            "${TRANSIT_VAULT_ADDR}/v1/auth/token/revoke-accessor" >/dev/null 2>&1 || true
        { set -x; } 2>/dev/null
        die 2 "SSH_BACKUP_FAILED" "Could not backup config on vault-server; new token revoked, no changes made" \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    }

    # 3b. Replace the token line in config.hcl
    # The seal "transit" block contains:  token           = "<value>"
    # We escape the new token value for sed (it starts with hvs. and contains only alphanum+.)
    # set +x: ESCAPED_TOKEN contains the raw token value — must not appear in trace
    { set +x; } 2>/dev/null
    ESCAPED_TOKEN=$(printf '%s\n' "$NEW_TOKEN" | sed 's/[[\.*^$()+?{|]/\\&/g')
    _sed_cmd="sudo sed -i 's|^\(\s*token\s*=\s*\)\".*\"|\1\"$ESCAPED_TOKEN\"|' $VAULT_SERVER_CONFIG"
    { set -x; } 2>/dev/null
    # Run the sed via SSH; the token value is inside the quoted command string
    # and is NOT echoed by set -x (run_ssh receives the pre-substituted string)
    { set +x; } 2>/dev/null
    run_ssh "$_sed_cmd"
    _sed_rc=$?
    { set -x; } 2>/dev/null
    if [[ $_sed_rc -ne 0 ]]; then
        # Revert backup and revoke new token
        run_ssh "sudo cp -p ${VAULT_SERVER_CONFIG}.pre-rotation $VAULT_SERVER_CONFIG" 2>/dev/null || true
        { set +x; } 2>/dev/null
        curl -s --max-time 5 \
            -H "X-Vault-Token: $ROTATION_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            --data "{\"accessor\": \"$NEW_ACCESSOR\"}" \
            "${TRANSIT_VAULT_ADDR}/v1/auth/token/revoke-accessor" >/dev/null 2>&1 || true
        { set -x; } 2>/dev/null
        die 2 "CONFIG_UPDATE_FAILED" "sed failed on vault-server config; reverted backup, new token revoked" \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    fi
    emit_log "CONFIG_UPDATED" "info" "config.hcl updated on vault-server with new autounseal token" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"config_path\": \"$VAULT_SERVER_CONFIG\"}"
else
    echo "[dry-run] Would backup $VAULT_SERVER_CONFIG → ${VAULT_SERVER_CONFIG}.pre-rotation"
    echo "[dry-run] Would sed-replace token line in $VAULT_SERVER_CONFIG with new token"
fi

# ---------------------------------------------------------------------------
# Phase 4: Restart vault container
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    run_ssh "sudo docker restart vault" || {
        # Revert and revoke
        run_ssh "sudo cp -p ${VAULT_SERVER_CONFIG}.pre-rotation $VAULT_SERVER_CONFIG" 2>/dev/null || true
        run_ssh "sudo docker restart vault" 2>/dev/null || true  # restart with old config
        { set +x; } 2>/dev/null
        curl -s --max-time 5 \
            -H "X-Vault-Token: $ROTATION_TOKEN" \
            -H "Content-Type: application/json" \
            -X POST \
            --data "{\"accessor\": \"$NEW_ACCESSOR\"}" \
            "${TRANSIT_VAULT_ADDR}/v1/auth/token/revoke-accessor" >/dev/null 2>&1 || true
        { set -x; } 2>/dev/null
        die 2 "VAULT_RESTART_FAILED" "docker restart vault failed on vault-server; reverted config, new token revoked" \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    }
    emit_log "VAULT_RESTARTED" "info" "vault container restarted on vault-server" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
else
    echo "[dry-run] Would: sudo docker restart vault on vault-server"
fi

# ---------------------------------------------------------------------------
# Phase 5: Poll prod Vault until unsealed (or timeout)
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    ELAPSED=0
    POST_RESTART_SEALED="?"
    while (( ELAPSED < HEALTH_POLL_TIMEOUT )); do
        sleep "$HEALTH_POLL_INTERVAL"
        ELAPSED=$(( ELAPSED + HEALTH_POLL_INTERVAL ))
        POLL_HEALTH=$(curl -sk --max-time 5 "$PROD_VAULT_HEALTH" 2>/dev/null)
        POST_RESTART_SEALED=$(echo "$POLL_HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sealed","?"))' 2>/dev/null || echo "?")
        if [[ "$POST_RESTART_SEALED" == "False" ]]; then
            break
        fi
    done

    if [[ "$POST_RESTART_SEALED" != "False" ]]; then
        # Vault did not unseal — this is the critical failure path
        # NOTE: do NOT revert config here; the vault-unseal-transit.timer on iac-control
        # is running every 2 minutes and may unseal the transit vault. We log CRIT and
        # let the operator investigate. Reverting config at this point is risky if vault
        # is mid-startup. The old token is still intact (not yet revoked).
        die 2 "HEALTH_CHECK_FAILED" \
            "Prod Vault did not unseal within ${HEALTH_POLL_TIMEOUT}s after restart. NOT revoking old token. Manual intervention required." \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"poll_elapsed_seconds\": $ELAPSED}"
    fi
    emit_log "HEALTH_OK" "info" "Prod Vault unsealed after restart (${ELAPSED}s)" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"elapsed_seconds\": $ELAPSED}"
else
    echo "[dry-run] Would poll $PROD_VAULT_HEALTH for up to ${HEALTH_POLL_TIMEOUT}s until sealed=false"
fi

# ---------------------------------------------------------------------------
# Phase 6: Encrypt/decrypt probe to verify unseal is actually working
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    PROBE_PLAINTEXT_B64=$(printf 'vault-autounseal-rotation-probe-%s' "$RUN_ID" | base64 -w0)
    { set +x; } 2>/dev/null
    ENCRYPT_RESP=$(curl -s --max-time 10 \
        -H "X-Vault-Token: $NEW_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        --data "{\"plaintext\": \"$PROBE_PLAINTEXT_B64\"}" \
        "${TRANSIT_VAULT_ADDR}/v1/transit/encrypt/autounseal" 2>/dev/null)
    { set -x; } 2>/dev/null
    CIPHERTEXT=$(echo "$ENCRYPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["ciphertext"])' 2>/dev/null || echo "")

    if [[ -z "$CIPHERTEXT" ]]; then
        die 2 "PROBE_ENCRYPT_FAILED" \
            "Encrypt probe failed with new token — transit key may be inaccessible. NOT revoking old token." \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    fi

    { set +x; } 2>/dev/null
    DECRYPT_RESP=$(curl -s --max-time 10 \
        -H "X-Vault-Token: $NEW_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        --data "{\"ciphertext\": \"$CIPHERTEXT\"}" \
        "${TRANSIT_VAULT_ADDR}/v1/transit/decrypt/autounseal" 2>/dev/null)
    { set -x; } 2>/dev/null
    ROUNDTRIP=$(echo "$DECRYPT_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["plaintext"])' 2>/dev/null || echo "")

    if [[ "$ROUNDTRIP" != "$PROBE_PLAINTEXT_B64" ]]; then
        die 2 "PROBE_DECRYPT_FAILED" \
            "Decrypt probe mismatch — transit key roundtrip failed. NOT revoking old token." \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    fi
    emit_log "PROBE_OK" "info" "Encrypt/decrypt roundtrip on transit key passed with new token" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
else
    echo "[dry-run] Would run encrypt/decrypt probe on transit key autounseal with new token"
fi

# ---------------------------------------------------------------------------
# Phase 7: Revoke old token by accessor
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    { set +x; } 2>/dev/null
    REVOKE_RESP=$(curl -s --max-time 10 \
        -H "X-Vault-Token: $ROTATION_TOKEN" \
        -H "Content-Type: application/json" \
        -X POST \
        --data "{\"accessor\": \"$OLD_ACCESSOR\"}" \
        "${TRANSIT_VAULT_ADDR}/v1/auth/token/revoke-accessor" 2>/dev/null)
    REVOKE_CODE=$?
    { set -x; } 2>/dev/null

    if [[ $REVOKE_CODE -ne 0 ]]; then
        # Non-fatal: old token will expire naturally (period=768h). Log warning.
        emit_log "REVOKE_WARN" "warning" \
            "Old token revoke failed (curl rc=$REVOKE_CODE). Old token will expire naturally. Non-fatal." \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    else
        emit_log "OLD_TOKEN_REVOKED" "info" "Old autounseal token revoked by accessor" \
            "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\"}"
    fi
else
    echo "[dry-run] Would revoke old accessor ...${OLD_ACCESSOR_FP} on transit vault"
fi

# ---------------------------------------------------------------------------
# Phase 8: Update accessor file with new accessor
# ---------------------------------------------------------------------------
if ! $DRY_RUN; then
    # OPS-385 Bug 2: install -o root fails EPERM as ubuntu (service User=ubuntu).
    # set -uo pipefail without -e means the EPERM is silently swallowed and
    # ACCESSOR_UPDATED was logged regardless of success.
    # Fix: sudo install (ubuntu has NOPASSWD sudo on iac-control, confirmed Stage B).
    # Additional hardening: capture exit code, read-back verify content, die on
    # failure, emit ACCESSOR_UPDATED only after verified write. All done inside
    # set+x guard to prevent $NEW_ACCESSOR expanding in xtrace. OPS-385.
    { set +x; } 2>/dev/null
    printf '%s\n' "$NEW_ACCESSOR" | sudo install -m 0644 -o root -g root /dev/stdin "$ACCESSOR_FILE"
    _install_rc=$?
    _accessor_readback=$(sudo cat "$ACCESSOR_FILE" 2>/dev/null | tr -d '[:space:]')
    _accessor_match=false
    [[ "$_accessor_readback" == "$NEW_ACCESSOR" ]] && _accessor_match=true || true
    { set -x; } 2>/dev/null
    if [[ $_install_rc -ne 0 ]] || ! $_accessor_match; then
        die 2 "ACCESSOR_WRITE_FAILED" \
            "Failed to write or verify accessor file $ACCESSOR_FILE (install_rc=$_install_rc, readback_match=$_accessor_match). Manual update required." \
            "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"accessor_path\": \"$ACCESSOR_FILE\"}"
    fi
    emit_log "ACCESSOR_UPDATED" "info" "accessor file updated with new token's accessor (verified by read-back)" \
        "{\"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"accessor_path\": \"$ACCESSOR_FILE\"}"
else
    echo "[dry-run] Would write new accessor (...${NEW_ACCESSOR_FP}) to $ACCESSOR_FILE"
fi

# ---------------------------------------------------------------------------
# Phase 9: Completion
# ---------------------------------------------------------------------------
emit_log "ROTATION_COMPLETE" "info" \
    "Auto-unseal token rotation complete" \
    "{\"old_accessor_fp\": \"$OLD_ACCESSOR_FP\", \"new_accessor_fp\": \"$NEW_ACCESSOR_FP\", \"dry_run\": $( $DRY_RUN && echo 'true' || echo 'false' )}"

# ---------------------------------------------------------------------------
# Post-run: debug log token leak scan (OPS-385 Bug 1 — defence in depth).
# Runs even on --dry-run since the log always exists.
# Non-fatal: emit a warning log entry if any hvs.* token pattern is found.
# This catches future regressions where a new code path leaks a token value.
# ---------------------------------------------------------------------------
if grep -qE 'hvs\.[A-Za-z0-9]{20,}' "$_DEBUG_LOG" 2>/dev/null; then
    emit_log "TOKEN_LEAK_WARN" "warning" \
        "WARN: hvs.* token pattern detected in debug log after rotation — review $_DEBUG_LOG and rotate any affected tokens" \
        "{\"debug_log\": \"$_DEBUG_LOG\"}"
fi

exit 0
