#!/bin/bash
# External Vault sealed-state probe — runs FROM iac-control (192.168.12.210)
# NOT from vault-server itself (that host may be the failed one).
# OPS-143 / SEC-44 follow-up #2
#
# Probes https://vault.208.haist.farm/v1/sys/health (unauthenticated endpoint).
# Classifies result into info/warning/critical. Appends one JSON line per run
# to /var/log/vault-health-probe.json and emits a logger(1) entry for journalctl.
#
# Exit codes: 0=info, 1=warning, 2=critical
# Timer schedule: every 5 minutes (see vault-health-probe.timer).

set -uo pipefail

VAULT_HEALTH_URL="https://vault.208.haist.farm/v1/sys/health"
LOG_FILE="/var/log/vault-health-probe.json"

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Measure response time via curl write-out. Capture HTTP status code and body.
# --max-time 5: fail fast; a sealed or unreachable Vault returns quickly or not at all.
# --insecure is intentionally NOT used — TLS validation is part of the health check.
START_NS=$(date +%s%N)
HTTP_BODY=$(curl -s --max-time 5 \
    --write-out "\n__HTTP_CODE__:%{http_code}" \
    "$VAULT_HEALTH_URL" 2>/dev/null)
CURL_RC=$?
END_NS=$(date +%s%N)
RESPONSE_TIME_MS=$(( (END_NS - START_NS) / 1000000 ))

# Split body from the appended status code line
HTTP_CODE=$(echo "$HTTP_BODY" | grep "^__HTTP_CODE__:" | sed 's/__HTTP_CODE__://')
BODY=$(echo "$HTTP_BODY" | grep -v "^__HTTP_CODE__:" || true)

# Parse JSON fields (sealed, standby, version) if we have a body
SEALED="null"
STANDBY="null"
VERSION="null"

if [[ -n "$BODY" ]] && echo "$BODY" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    SEALED=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('sealed','')).lower())" 2>/dev/null || echo "null")
    STANDBY=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('standby','')).lower())" 2>/dev/null || echo "null")
    VERSION=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); v=d.get('version',''); print(v if v else 'null')" 2>/dev/null || echo "null")
fi

# Normalize booleans: python3 prints True/False; convert to true/false for JSON
[[ "$SEALED"  == "true"  ]] || [[ "$SEALED"  == "false"  ]] || SEALED="null"
[[ "$STANDBY" == "true"  ]] || [[ "$STANDBY" == "false"  ]] || STANDBY="null"

# Classify
LEVEL="info"
MESSAGE="Vault healthy"
EXIT_CODE=0

if [[ $CURL_RC -ne 0 ]]; then
    # curl failed: connection refused, timeout, no route, etc.
    LEVEL="critical"
    MESSAGE="Vault unreachable (curl rc=${CURL_RC})"
    EXIT_CODE=2
elif [[ -z "$HTTP_CODE" ]] || [[ "$HTTP_CODE" == "000" ]]; then
    LEVEL="critical"
    MESSAGE="Vault unreachable (no HTTP response)"
    EXIT_CODE=2
elif [[ "$HTTP_CODE" == "502" ]] || [[ "$HTTP_CODE" == "503" && "$SEALED" != "true" ]]; then
    # 502 = pangolin/proxy error. 503 without sealed=true = not-a-sealed-Vault 503.
    LEVEL="critical"
    MESSAGE="Vault unreachable (HTTP ${HTTP_CODE})"
    EXIT_CODE=2
elif [[ "$HTTP_CODE" == "503" && "$SEALED" == "true" ]]; then
    # Standard: Vault returns 503 when sealed
    LEVEL="critical"
    MESSAGE="Vault sealed"
    EXIT_CODE=2
elif [[ "$HTTP_CODE" == "200" && "$SEALED" == "true" ]]; then
    # Unusual: 200 but sealed field says true (shouldn't normally happen)
    LEVEL="critical"
    MESSAGE="Vault sealed (unusual: 200 with sealed=true)"
    EXIT_CODE=2
elif [[ "$HTTP_CODE" == "200" && "$STANDBY" == "true" ]]; then
    # Single-node deploy: standby=true is unusual (means HA passive node)
    LEVEL="warning"
    MESSAGE="Vault on standby (single-node deploy: this is unusual)"
    EXIT_CODE=1
elif [[ "$HTTP_CODE" == "200" && "$SEALED" == "false" && "$STANDBY" == "false" ]]; then
    LEVEL="info"
    MESSAGE="Vault healthy"
    EXIT_CODE=0
elif [[ "$HTTP_CODE" == "200" ]]; then
    # 200 but could not fully parse sealed/standby — treat as degraded warning
    LEVEL="warning"
    MESSAGE="Vault returned 200 but sealed/standby fields unclear"
    EXIT_CODE=1
else
    # Unexpected HTTP code
    LEVEL="critical"
    MESSAGE="Vault unexpected HTTP ${HTTP_CODE}"
    EXIT_CODE=2
fi

# Emit JSON log line
# Pass all values as arguments to Python to avoid shell/Python quoting conflicts.
# sealed/standby are "true"/"false"/"null" strings; Python converts them to proper JSON types.
HTTP_CODE_INT=${HTTP_CODE:-0}

JSON_LINE=$(python3 - "$TS" "$LEVEL" "$HTTP_CODE_INT" "$SEALED" "$STANDBY" "$VERSION" "$RESPONSE_TIME_MS" "$MESSAGE" <<'PYEOF'
import sys, json
ts, level, http_code_s, sealed_s, standby_s, version_s, rt_s, msg = sys.argv[1:]

def parse_bool_or_null(s):
    if s == "true":  return True
    if s == "false": return False
    return None

obj = {
    "ts":               ts,
    "level":            level,
    "http_code":        int(http_code_s) if http_code_s.isdigit() else 0,
    "sealed":           parse_bool_or_null(sealed_s),
    "standby":          parse_bool_or_null(standby_s),
    "version":          None if version_s == "null" else version_s,
    "response_time_ms": int(rt_s) if rt_s.lstrip('-').isdigit() else 0,
    "message":          msg,
}
print(json.dumps(obj))
PYEOF
)

echo "$JSON_LINE" >> "$LOG_FILE"

# Map level to syslog facility.priority
case "$LEVEL" in
    critical) SYSLOG_PRI="user.crit" ;;
    warning)  SYSLOG_PRI="user.warning" ;;
    *)        SYSLOG_PRI="user.info" ;;
esac

logger -t vault-health-probe -p "$SYSLOG_PRI" "${LEVEL}: ${MESSAGE} (http=${HTTP_CODE:-none} sealed=${SEALED} standby=${STANDBY} rt=${RESPONSE_TIME_MS}ms)"

exit $EXIT_CODE
