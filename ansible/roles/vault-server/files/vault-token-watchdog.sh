#!/bin/bash
# vault-token-watchdog.sh
# Checks the auto-unseal token's TTL on the Transit Vault.
# OPS-142 (SEC-44 follow-up #1): catches token revocation or non-renewal.
#
# Reads /etc/vault/config/config.hcl to extract the transit address and
# token from the seal "transit" block. Calls lookup-self against the
# Transit Vault. Emits a structured JSON log line to
# /var/log/vault-token-watchdog.json and to the systemd journal.
#
# Exit codes:
#   0 — TTL >= 7 days (healthy)
#   1 — TTL < 7 days (warning)
#   2 — HTTP error or token revoked (critical)
#   3 — config parse error

set -uo pipefail

CONFIG=/etc/vault/config/config.hcl
LOG=/var/log/vault-token-watchdog.json
WARN_THRESHOLD=$((7 * 86400))  # 7 days in seconds

# ---- parse config -------------------------------------------------------

if [[ ! -r "$CONFIG" ]]; then
    echo "CRITICAL: cannot read $CONFIG" >&2
    exit 3
fi

# Extract address from seal "transit" block
# Matches: address         = "http://..."
TRANSIT_ADDR=$(grep -A20 '^seal "transit"' "$CONFIG" | grep '^\s*address\s*=' | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')

# Extract token from seal "transit" block
TOKEN=$(grep -A20 '^seal "transit"' "$CONFIG" | grep '^\s*token\s*=' | head -1 | sed 's/.*=\s*"\(.*\)".*/\1/')

if [[ -z "$TRANSIT_ADDR" || -z "$TOKEN" ]]; then
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    LOG_LINE="{\"ts\":\"${TS}\",\"level\":\"critical\",\"ttl_seconds\":null,\"ttl_human\":null,\"token_accessor\":null,\"transit_addr\":null,\"message\":\"Failed to parse transit address or token from ${CONFIG}\"}"
    echo "$LOG_LINE" >> "$LOG"
    echo "$LOG_LINE" | logger -t vault-token-watchdog -p daemon.crit
    exit 3
fi

# ---- lookup-self --------------------------------------------------------

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -m 10 \
    --header "X-Vault-Token: ${TOKEN}" \
    "${TRANSIT_ADDR}/v1/auth/token/lookup-self" 2>&1)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ---- parse response -----------------------------------------------------

if [[ "$HTTP_CODE" != "200" ]]; then
    LOG_LINE="{\"ts\":\"${TS}\",\"level\":\"critical\",\"ttl_seconds\":null,\"ttl_human\":null,\"token_accessor\":null,\"transit_addr\":\"${TRANSIT_ADDR}\",\"message\":\"lookup-self returned HTTP ${HTTP_CODE} - token may be revoked or transit vault unreachable\",\"http_body\":$(echo "$HTTP_BODY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo '"<unparseable>"')}"
    echo "$LOG_LINE" >> "$LOG"
    echo "$LOG_LINE" | logger -t vault-token-watchdog -p daemon.crit
    exit 2
fi

TTL_SECONDS=$(echo "$HTTP_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"]["ttl"])' 2>/dev/null || echo "")
ACCESSOR=$(echo "$HTTP_BODY" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["data"]["accessor"])' 2>/dev/null || echo "unknown")

if [[ -z "$TTL_SECONDS" ]]; then
    LOG_LINE="{\"ts\":\"${TS}\",\"level\":\"critical\",\"ttl_seconds\":null,\"ttl_human\":null,\"token_accessor\":\"${ACCESSOR}\",\"transit_addr\":\"${TRANSIT_ADDR}\",\"message\":\"lookup-self returned 200 but ttl field missing or unparseable\"}"
    echo "$LOG_LINE" >> "$LOG"
    echo "$LOG_LINE" | logger -t vault-token-watchdog -p daemon.crit
    exit 2
fi

# ---- format human TTL ---------------------------------------------------

TTL_HUMAN=$(python3 -c "
s = int($TTL_SECONDS)
days = s // 86400
hours = (s % 86400) // 3600
mins = (s % 3600) // 60
print(f'{days}d {hours}h {mins}m')
" 2>/dev/null || echo "${TTL_SECONDS}s")

# ---- threshold check ----------------------------------------------------

if [[ "$TTL_SECONDS" -lt "$WARN_THRESHOLD" ]]; then
    LEVEL="warn"
    MSG="Auto-unseal token TTL is ${TTL_HUMAN} - below 7-day warning threshold. Renew via Transit Vault."
    LOG_LINE="{\"ts\":\"${TS}\",\"level\":\"${LEVEL}\",\"ttl_seconds\":${TTL_SECONDS},\"ttl_human\":\"${TTL_HUMAN}\",\"token_accessor\":\"${ACCESSOR}\",\"transit_addr\":\"${TRANSIT_ADDR}\",\"message\":\"${MSG}\"}"
    echo "$LOG_LINE" >> "$LOG"
    echo "$LOG_LINE" | logger -t vault-token-watchdog -p daemon.warning
    exit 1
else
    LEVEL="info"
    MSG="Auto-unseal token TTL is ${TTL_HUMAN} - healthy."
    LOG_LINE="{\"ts\":\"${TS}\",\"level\":\"${LEVEL}\",\"ttl_seconds\":${TTL_SECONDS},\"ttl_human\":\"${TTL_HUMAN}\",\"token_accessor\":\"${ACCESSOR}\",\"transit_addr\":\"${TRANSIT_ADDR}\",\"message\":\"${MSG}\"}"
    echo "$LOG_LINE" >> "$LOG"
    echo "$LOG_LINE" | logger -t vault-token-watchdog -p daemon.info
    exit 0
fi
