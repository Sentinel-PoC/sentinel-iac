#!/usr/bin/env bash
# cloudflare-waf-baseline.sh — Configure baseline Cloudflare WAF rules for haist.farm
#
# Manages 5 Custom WAF Rules + 1 Rate-Limiting rule for public-facing hostnames:
#   haist.farm, www.haist.farm, auth.haist.farm, oauth2.haist.farm, matrix.haist.farm
#
# NIST mapping: SC-7 (boundary protection), SI-4 (system monitoring), AC-7 (unsuccessful login attempts)
# Plane issue: OPS-171
#
# Usage:
#   ./cloudflare-waf-baseline.sh [--check] [--apply] [--rollback]
#   --check:    Verify current live state matches desired state (idempotent, no changes)
#   --apply:    Apply desired state (default if no flag given)
#   --rollback: Remove rules 4 and 5 (added by this script), restore to 3-rule baseline
#
# Prerequisites:
#   - vault CLI with VAULT_ADDR=https://vault.208.haist.farm
#   - curl, python3
#   - Vault path: secret/cloudflare/admin (fields: email, global_api_key)
#
# Free-tier constraints observed (2026-05-29):
#   - Custom firewall rules (http_request_firewall_custom): up to 5 rules
#   - Rate limiting (http_ratelimit): 1 rule max, period=10s, mitigation_timeout=10s only
#   - Rulesets API required (legacy /rate_limits endpoint is paid-only)
#   - No 'matches' operator (Business+ only)

set -euo pipefail

ZONE_ID="e1fd5bf02b06f54f655e91a98f3efc14"
CUSTOM_RULESET_ID="00b2c6a291ab4d3884de6286783a6bba"
RATE_LIMIT_RULESET_ID="875f250cff61428e8b12224f57c8c97a"
CF_API="https://api.cloudflare.com/client/v4"
VAULT_ADDR="${VAULT_ADDR:-https://vault.208.haist.farm}"
MODE="${1:---apply}"

log()  { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err()  { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
ok()   { echo "[$(date '+%Y-%m-%dT%H:%M:%SZ')] OK: $*"; }
fail() { err "$*"; exit 1; }

# --- Retrieve secrets from Vault ---
log "Retrieving Cloudflare credentials from Vault..."
CF_EMAIL=$(vault kv get -field=email secret/cloudflare/admin 2>/dev/null) \
    || fail "Failed to retrieve CF email from Vault (secret/cloudflare/admin)"
CF_GLOBAL_KEY=$(vault kv get -field=global_api_key secret/cloudflare/admin 2>/dev/null) \
    || fail "Failed to retrieve CF global_api_key from Vault (secret/cloudflare/admin)"
log "Credentials retrieved."

cf_api() {
    local method="$1" path="$2" data="${3:-}"
    local args=(-s --request "$method"
        --header "X-Auth-Email: ${CF_EMAIL}"
        --header "X-Auth-Key: ${CF_GLOBAL_KEY}"
        --header "Content-Type: application/json")
    if [[ -n "$data" ]]; then
        args+=(--data "$data")
    fi
    curl "${args[@]}" "${CF_API}/${path}"
}

check_success() {
    local resp="$1" context="$2"
    local ok
    ok=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null)
    if [[ "$ok" != "True" ]]; then
        local errs
        errs=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors','?'))" 2>/dev/null)
        fail "${context}: API returned success=false. Errors: ${errs}"
    fi
}

# --- Desired state definitions ---

# 5 custom firewall rules (http_request_firewall_custom phase)
# Rules 1-3 were pre-existing (created 2026-03-04). Rules 4-5 added by OPS-171 (2026-05-29).
CUSTOM_RULES_JSON=$(python3 -c "
import json
rules = [
    {
        'id': '467f8e66ba194044abafed156a4b2d84',
        'action': 'managed_challenge',
        'description': 'Challenge high threat score visitors',
        'expression': '(cf.threat_score gt 14)',
        'enabled': True
    },
    {
        'id': '94e64cbdda6e45a1b0afe121241c9a41',
        'action': 'block',
        'description': 'Block exploit path probing',
        'expression': '(http.request.uri.path contains \"/wp-login\" or http.request.uri.path contains \"/wp-admin\" or http.request.uri.path contains \"/.env\" or http.request.uri.path contains \"/phpMyAdmin\" or http.request.uri.path contains \"/phpmyadmin\" or http.request.uri.path contains \"/.git\" or http.request.uri.path contains \"/xmlrpc.php\" or http.request.uri.path contains \"/wp-content\" or http.request.uri.path contains \"/wp-includes\")',
        'enabled': True
    },
    {
        'id': '713d609bb7b44941b9b343506350b090',
        'action': 'managed_challenge',
        'description': 'Challenge empty or suspicious user agents',
        'expression': '(http.user_agent eq \"\" or http.user_agent contains \"sqlmap\" or http.user_agent contains \"nikto\" or http.user_agent contains \"nmap\" or http.user_agent contains \"masscan\" or http.user_agent contains \"zgrab\")',
        'enabled': True
    },
    {
        'action': 'block',
        'description': 'Block credential stuffing bots targeting auth endpoints',
        'expression': '((http.user_agent contains \"python-requests\" or http.user_agent contains \"Go-http-client/1.1\" or http.user_agent contains \"curl/\") and (http.host eq \"auth.haist.farm\" or http.host eq \"oauth2.haist.farm\") and (http.request.uri.path contains \"/token\" or http.request.uri.path contains \"/login\"))',
        'enabled': True
    },
    {
        'action': 'block',
        'description': 'Block direct access to Keycloak admin console from non-internal IPs',
        'expression': '(http.host eq \"auth.haist.farm\" and http.request.uri.path contains \"/auth/admin\" and not ip.src in {192.168.12.0/24})',
        'enabled': True
    }
]
print(json.dumps({
    'name': 'default',
    'kind': 'zone',
    'phase': 'http_request_firewall_custom',
    'description': 'Sentinel WAF Custom Rules',
    'rules': rules
}))
")

# 1 rate-limit rule covering auth + matrix endpoints
# Free-tier constraints: period=10s, mitigation_timeout=10s, 1 rule max, must include cf.colo.id
RATELIMIT_RULES_JSON=$(python3 -c "
import json
ruleset = {
    'name': 'Rate Limiting Rules',
    'kind': 'zone',
    'phase': 'http_ratelimit',
    'description': 'Rate limiting for auth and matrix login endpoints',
    'rules': [
        {
            'action': 'block',
            'action_parameters': {
                'response': {
                    'status_code': 429,
                    'content_type': 'text/plain',
                    'content': 'Too many requests. Please slow down.'
                }
            },
            'ratelimit': {
                'characteristics': ['cf.colo.id', 'ip.src'],
                'period': 10,
                'requests_per_period': 2,
                'mitigation_timeout': 10
            },
            'expression': '(http.request.method eq \"POST\" and http.host eq \"auth.haist.farm\" and http.request.uri.path contains \"/protocol/openid-connect/token\") or (http.request.method eq \"POST\" and http.host eq \"matrix.haist.farm\" and http.request.uri.path contains \"/_matrix/client\" and http.request.uri.path contains \"/login\")',
            'description': 'Rate limit auth (Keycloak token) and Matrix login endpoints - 2 req/10s/IP',
            'enabled': True
        }
    ]
}
print(json.dumps(ruleset))
")

# --- Check mode: verify live state ---
do_check() {
    log "--- CHECK MODE: verifying live state ---"

    local custom_resp
    custom_resp=$(cf_api GET "zones/${ZONE_ID}/rulesets/${CUSTOM_RULESET_ID}")
    check_success "$custom_resp" "GET custom ruleset"
    local custom_count
    custom_count=$(echo "$custom_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',{}).get('rules',[])))")
    if [[ "$custom_count" -eq 5 ]]; then
        ok "Custom WAF rules: ${custom_count}/5 present"
    else
        err "Custom WAF rules: ${custom_count}/5 present (DRIFT)"
        return 1
    fi

    local rl_resp
    rl_resp=$(cf_api GET "zones/${ZONE_ID}/rulesets/${RATE_LIMIT_RULESET_ID}")
    check_success "$rl_resp" "GET rate limit ruleset"
    local rl_count
    rl_count=$(echo "$rl_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',{}).get('rules',[])))")
    if [[ "$rl_count" -eq 1 ]]; then
        ok "Rate limit rules: ${rl_count}/1 present"
    else
        err "Rate limit rules: ${rl_count}/1 present (DRIFT)"
        return 1
    fi

    # Verify via legacy /firewall/rules (acceptance criteria from OPS-171)
    local legacy_resp
    legacy_resp=$(cf_api GET "zones/${ZONE_ID}/firewall/rules")
    check_success "$legacy_resp" "GET firewall/rules"
    local legacy_count
    legacy_count=$(echo "$legacy_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))")
    ok "Legacy /firewall/rules count: ${legacy_count} (acceptance criteria: 5)"

    ok "CHECK PASSED: All rules present and accounted for"
}

# --- Apply mode: enforce desired state ---
do_apply() {
    log "--- APPLY MODE: enforcing desired state ---"

    # Step 1: Apply custom WAF rules (PUT replaces entire ruleset)
    log "Applying 5 custom WAF rules to ruleset ${CUSTOM_RULESET_ID}..."
    local custom_resp
    custom_resp=$(cf_api PUT "zones/${ZONE_ID}/rulesets/${CUSTOM_RULESET_ID}" "$CUSTOM_RULES_JSON")
    check_success "$custom_resp" "PUT custom ruleset"
    local custom_count
    custom_count=$(echo "$custom_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',{}).get('rules',[])))")
    ok "Custom WAF rules applied: ${custom_count} rules active"

    # Step 2: Apply rate limiting ruleset (PUT replaces entire ruleset)
    log "Applying rate limit ruleset ${RATE_LIMIT_RULESET_ID}..."
    local rl_resp
    rl_resp=$(cf_api PUT "zones/${ZONE_ID}/rulesets/${RATE_LIMIT_RULESET_ID}" "$RATELIMIT_RULES_JSON")
    check_success "$rl_resp" "PUT rate limit ruleset"
    local rl_count
    rl_count=$(echo "$rl_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',{}).get('rules',[])))")
    ok "Rate limit rules applied: ${rl_count} rule active"

    # Step 3: Verify via legacy /firewall/rules endpoint (acceptance criterion)
    local legacy_resp
    legacy_resp=$(cf_api GET "zones/${ZONE_ID}/firewall/rules")
    check_success "$legacy_resp" "GET firewall/rules"
    local legacy_count
    legacy_count=$(echo "$legacy_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))")
    ok "Verification: /firewall/rules shows ${legacy_count} rules"
    if [[ "$legacy_count" -ne 5 ]]; then
        err "Expected 5 rules in /firewall/rules, got ${legacy_count}"
        exit 1
    fi

    log "APPLY COMPLETE: 5 custom WAF rules + 1 rate-limit rule active"
    log ""
    log "OPERATOR HANDOFF REQUIRED (per OPS-171 acceptance criteria):"
    log "  1. Synthetic load test: send 10+ POST requests to https://auth.haist.farm/realms/haist/protocol/openid-connect/token"
    log "     Expected: requests 3+ should return HTTP 429 within the 10-second window"
    log "  2. Browser smoke test: confirm Matrix SSO login at https://matrix.haist.farm still works"
    log "  3. Confirm Keycloak admin console accessible from internal network (192.168.12.0/24 only)"
}

# --- Rollback mode: remove rules 4 and 5 only ---
do_rollback() {
    log "--- ROLLBACK MODE: removing rules 4 and 5, restoring 3-rule baseline ---"

    local rollback_json
    rollback_json=$(python3 -c "
import json
rules = [
    {
        'id': '467f8e66ba194044abafed156a4b2d84',
        'action': 'managed_challenge',
        'description': 'Challenge high threat score visitors',
        'expression': '(cf.threat_score gt 14)',
        'enabled': True
    },
    {
        'id': '94e64cbdda6e45a1b0afe121241c9a41',
        'action': 'block',
        'description': 'Block exploit path probing',
        'expression': '(http.request.uri.path contains \"/wp-login\" or http.request.uri.path contains \"/wp-admin\" or http.request.uri.path contains \"/.env\" or http.request.uri.path contains \"/phpMyAdmin\" or http.request.uri.path contains \"/phpmyadmin\" or http.request.uri.path contains \"/.git\" or http.request.uri.path contains \"/xmlrpc.php\" or http.request.uri.path contains \"/wp-content\" or http.request.uri.path contains \"/wp-includes\")',
        'enabled': True
    },
    {
        'id': '713d609bb7b44941b9b343506350b090',
        'action': 'managed_challenge',
        'description': 'Challenge empty or suspicious user agents',
        'expression': '(http.user_agent eq \"\" or http.user_agent contains \"sqlmap\" or http.user_agent contains \"nikto\" or http.user_agent contains \"nmap\" or http.user_agent contains \"masscan\" or http.user_agent contains \"zgrab\")',
        'enabled': True
    }
]
print(json.dumps({
    'name': 'default',
    'kind': 'zone',
    'phase': 'http_request_firewall_custom',
    'description': 'Sentinel WAF Custom Rules',
    'rules': rules
}))
")
    local resp
    resp=$(cf_api PUT "zones/${ZONE_ID}/rulesets/${CUSTOM_RULESET_ID}" "$rollback_json")
    check_success "$resp" "PUT rollback custom ruleset"
    ok "ROLLBACK COMPLETE: custom rules restored to 3-rule baseline"
    log "Note: rate-limit ruleset ${RATE_LIMIT_RULESET_ID} NOT removed by rollback (delete manually if needed)"
}

# --- Main ---
case "$MODE" in
    --check)   do_check   ;;
    --apply)   do_apply   ;;
    --rollback) do_rollback ;;
    *)
        echo "Usage: $0 [--check|--apply|--rollback]"
        echo "  --check:    Verify live state matches desired state"
        echo "  --apply:    Enforce desired state (default)"
        echo "  --rollback: Remove rules 4-5, restore 3-rule pre-OPS-171 baseline"
        exit 1
        ;;
esac
