#!/bin/bash
# vault-autounseal-token-ttl.sh — early-warning monitor for the prod-Vault
# auto-unseal token's remaining lease against the Transit Vault on iac-control.
# OPS-190, follow-up to SEC-44.
#
# Reads:
#   /etc/vault-unseal/autounseal-accessor.token  (mode 0644 root:root) — the
#       non-secret token accessor of the auto-unseal token currently configured
#       in /etc/vault/config/config.hcl on vault-server.
#   /etc/vault-unseal/lookup-token              (mode 0400 root:root) — a
#       Transit Vault token bound to a tight policy that allows only
#       `update` on auth/token/lookup-accessor. Used to query metadata
#       about the auto-unseal token without holding its value.
#
# Asks Transit Vault: POST /v1/auth/token/lookup-accessor {"accessor": ...}
# Computes remaining_seconds from the response's `ttl` field.
# Emits one JSON line per run to /var/log/vault-autounseal-token-ttl.json
# and a logger(1) entry under tag `vault-autounseal-token-ttl`.
#
# Exit codes (matching vault-health-probe):
#   0 — OK     (remaining > WARN threshold)
#   1 — WARN   (remaining < WARN threshold but > CRIT)
#   2 — CRIT   (remaining < CRIT threshold)
#
# Thresholds default to 7d (WARN) / 24h (CRIT). Override with env vars:
#   VAULT_AUTOUNSEAL_WARN_SEC  (default 604800)
#   VAULT_AUTOUNSEAL_CRIT_SEC  (default 86400)
#
# Usage:
#   vault-autounseal-token-ttl.sh
#   vault-autounseal-token-ttl.sh --simulate <seconds>   # test alerting paths

set -uo pipefail

# SEC-89: https — transit listener now has TLS enabled.
VAULT_ADDR="${VAULT_ADDR:-https://192.168.12.210:8201}"
# SEC-89: CA cert for transit Vault's self-signed TLS cert. Deployed by
# iac-control role (Phase A). Can be overridden via env.
VAULT_CACERT="${VAULT_CACERT:-/opt/vault-unseal/config/tls/cert.pem}"
ACCESSOR_FILE="${VAULT_AUTOUNSEAL_ACCESSOR_FILE:-/etc/vault-unseal/autounseal-accessor.token}"
LOOKUP_TOKEN_FILE="${VAULT_AUTOUNSEAL_LOOKUP_TOKEN_FILE:-/etc/vault-unseal/lookup-token}"
LOG_FILE="${VAULT_AUTOUNSEAL_LOG_FILE:-/var/log/vault-autounseal-token-ttl.json}"

WARN_SEC="${VAULT_AUTOUNSEAL_WARN_SEC:-604800}"
CRIT_SEC="${VAULT_AUTOUNSEAL_CRIT_SEC:-86400}"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Simulation mode --------------------------------------------------------
SIMULATE_SEC=""
if [[ "${1:-}" == "--simulate" ]]; then
    SIMULATE_SEC="${2:-}"
    if ! [[ "$SIMULATE_SEC" =~ ^-?[0-9]+$ ]]; then
        echo "ERROR: --simulate requires an integer (seconds remaining)" >&2
        exit 64
    fi
fi

# --- Real-mode input gathering ----------------------------------------------
ACCESSOR=""
TTL=""
PERIOD=""
RENEWABLE=""
EXPIRE_TIME=""
HTTP_CODE=""
ERROR_REASON=""

if [[ -z "$SIMULATE_SEC" ]]; then
    if [[ ! -r "$ACCESSOR_FILE" ]]; then
        ERROR_REASON="accessor file unreadable: $ACCESSOR_FILE"
    elif [[ ! -r "$LOOKUP_TOKEN_FILE" ]]; then
        ERROR_REASON="lookup-token file unreadable: $LOOKUP_TOKEN_FILE (must be 0400 root:root)"
    fi

    if [[ -z "$ERROR_REASON" ]]; then
        ACCESSOR=$(tr -d '[:space:]' < "$ACCESSOR_FILE")
        LOOKUP_TOKEN=$(tr -d '[:space:]' < "$LOOKUP_TOKEN_FILE")

        if [[ -z "$ACCESSOR" ]]; then
            ERROR_REASON="accessor file is empty"
        elif [[ -z "$LOOKUP_TOKEN" ]]; then
            ERROR_REASON="lookup-token file is empty"
        fi
    fi

    if [[ -z "$ERROR_REASON" ]]; then
        REQ_BODY=$(printf '{"accessor":"%s"}' "$ACCESSOR")
        # SEC-89: --cacert for transit Vault's self-signed TLS cert
        RESP=$(curl -s --max-time 5 \
            --cacert "$VAULT_CACERT" \
            --write-out "\n__HTTP_CODE__:%{http_code}" \
            -H "X-Vault-Token: ${LOOKUP_TOKEN}" \
            -X POST \
            --data "$REQ_BODY" \
            "${VAULT_ADDR}/v1/auth/token/lookup-accessor" 2>/dev/null)
        CURL_RC=$?

        HTTP_CODE=$(echo "$RESP" | grep "^__HTTP_CODE__:" | sed 's/__HTTP_CODE__://')
        BODY=$(echo "$RESP" | grep -v "^__HTTP_CODE__:" || true)

        if [[ $CURL_RC -ne 0 ]]; then
            ERROR_REASON="curl failed rc=${CURL_RC} reaching ${VAULT_ADDR}"
        elif [[ "$HTTP_CODE" != "200" ]]; then
            ERROR_REASON="lookup-accessor returned HTTP ${HTTP_CODE}"
        else
            TTL=$(echo "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["ttl"])' 2>/dev/null)
            PERIOD=$(echo "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"].get("period",0))' 2>/dev/null)
            RENEWABLE=$(echo "$BODY" | python3 -c 'import sys,json; print(str(json.load(sys.stdin)["data"].get("renewable",False)).lower())' 2>/dev/null)
            EXPIRE_TIME=$(echo "$BODY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"].get("expire_time",""))' 2>/dev/null)
            if ! [[ "$TTL" =~ ^-?[0-9]+$ ]]; then
                ERROR_REASON="could not parse ttl from lookup-accessor response"
            fi
        fi
    fi
else
    TTL="$SIMULATE_SEC"
    ACCESSOR="SIMULATED"
    PERIOD="0"
    RENEWABLE="true"
    EXPIRE_TIME=""
    HTTP_CODE="200"
fi

# --- Classification ---------------------------------------------------------
LEVEL="info"
STATUS="OK"
MESSAGE=""
EXIT_CODE=0

if [[ -n "$ERROR_REASON" ]]; then
    LEVEL="critical"
    STATUS="ERROR"
    MESSAGE="$ERROR_REASON"
    EXIT_CODE=2
    TTL="${TTL:-0}"
elif (( TTL < CRIT_SEC )); then
    LEVEL="critical"
    STATUS="CRIT"
    MESSAGE="auto-unseal token expires in ${TTL}s (< ${CRIT_SEC}s critical threshold)"
    EXIT_CODE=2
elif (( TTL < WARN_SEC )); then
    LEVEL="warning"
    STATUS="WARN"
    MESSAGE="auto-unseal token expires in ${TTL}s (< ${WARN_SEC}s warning threshold)"
    EXIT_CODE=1
else
    LEVEL="info"
    STATUS="OK"
    MESSAGE="auto-unseal token TTL ${TTL}s (above ${WARN_SEC}s warning threshold)"
    EXIT_CODE=0
fi

# --- Human-readable remaining ----------------------------------------------
human_duration() {
    local s=$1
    if (( s < 0 )); then echo "expired"; return; fi
    local d=$(( s / 86400 ))
    local h=$(( (s % 86400) / 3600 ))
    local m=$(( (s % 3600) / 60 ))
    if (( d > 0 )); then printf '%dd %dh %dm' "$d" "$h" "$m"; return; fi
    if (( h > 0 )); then printf '%dh %dm' "$h" "$m"; return; fi
    printf '%dm' "$m"
}
HUMAN=$(human_duration "${TTL:-0}")

# --- Accessor short fingerprint (last 8 chars) — never log full accessor ---
ACCESSOR_FP=""
if [[ -n "$ACCESSOR" && "$ACCESSOR" != "SIMULATED" ]]; then
    ACCESSOR_FP="${ACCESSOR: -8}"
fi

# --- Emit JSON --------------------------------------------------------------
JSON=$(python3 - "$TS" "$STATUS" "$LEVEL" "$MESSAGE" "$TTL" "$HUMAN" "$WARN_SEC" "$CRIT_SEC" "$VAULT_ADDR" "$ACCESSOR_FP" "$PERIOD" "$RENEWABLE" "$EXPIRE_TIME" "$HTTP_CODE" "${SIMULATE_SEC}" <<'PYEOF'
import sys, json
ts, status, level, msg, ttl_s, human, warn_s, crit_s, addr, accfp, period_s, renewable_s, expire, http, sim = sys.argv[1:]

def to_int(s, d=0):
    try: return int(s)
    except: return d

def to_bool_or_none(s):
    if s == "true": return True
    if s == "false": return False
    return None

obj = {
    "check":                "vault_autounseal_token_ttl",
    "ts":                   ts,
    "status":               status,
    "level":                level,
    "message":              msg,
    "remaining_seconds":    to_int(ttl_s),
    "remaining_human":      human,
    "threshold_warn_seconds": to_int(warn_s),
    "threshold_crit_seconds": to_int(crit_s),
    "vault_addr":           addr,
    "accessor_last8":       accfp or None,
    "period":               to_int(period_s),
    "renewable":            to_bool_or_none(renewable_s),
    "expire_time":          expire or None,
    "http_code":            to_int(http),
    "simulated":            bool(sim),
}
print(json.dumps(obj))
PYEOF
)

# Append to log file (best-effort; do NOT fail if the directory isn't writable
# in unprivileged smoke tests — the systemd unit runs as root and writes succeed).
if [[ -w "$(dirname "$LOG_FILE")" ]] || [[ -w "$LOG_FILE" ]]; then
    echo "$JSON" >> "$LOG_FILE"
fi

# Map level to syslog facility.priority (mirror vault-health-probe)
case "$LEVEL" in
    critical) SYSLOG_PRI="user.crit" ;;
    warning)  SYSLOG_PRI="user.warning" ;;
    *)        SYSLOG_PRI="user.info" ;;
esac

# Emit to journald via logger; vault-probe-decoders.xml will parse the JSON line.
if command -v logger >/dev/null 2>&1; then
    logger -t vault-autounseal-token-ttl -p "$SYSLOG_PRI" "$JSON"
fi

# Always print JSON to stdout — useful for CronJob mode and ad-hoc invocation.
echo "$JSON"

exit $EXIT_CODE
