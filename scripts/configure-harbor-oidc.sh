#!/usr/bin/env bash
# configure-harbor-oidc.sh — Configure Harbor OIDC authentication via API
# Pulls secrets from Vault, configures Harbor to use Keycloak SSO
# Idempotent: checks current config before applying changes
#
# Usage: ./configure-harbor-oidc.sh [--force]
#   --force: Apply even if OIDC is already configured
#
# Prerequisites:
#   - vault CLI with access to secret/harbor and secret/keycloak/harbor
#   - curl, python3
#   - Network access to Harbor and Vault

set -euo pipefail

HARBOR_URL="https://harbor.208.haist.farm"
VAULT_ADDR="${VAULT_ADDR:-https://192.168.12.206:8200}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-true}"
FORCE="${1:-}"

export VAULT_ADDR VAULT_SKIP_VERIFY

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

# --- Retrieve secrets from Vault ---
log "Retrieving secrets from Vault..."

HARBOR_ADMIN_PASSWORD=$(vault kv get -field=admin_password secret/harbor 2>/dev/null) || {
    err "Failed to retrieve Harbor admin password from Vault"
    exit 1
}

OIDC_CLIENT_SECRET=$(vault kv get -field=client_secret secret/keycloak/harbor 2>/dev/null) || {
    err "Failed to retrieve OIDC client secret from Vault"
    exit 1
}

log "Secrets retrieved successfully"

# --- Check current configuration ---
log "Checking current Harbor auth configuration..."

CURRENT_AUTH=$(curl -sk -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    "${HARBOR_URL}/api/v2.0/configurations" 2>/dev/null | \
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("auth_mode",{}).get("value","unknown"))' 2>/dev/null)

if [ "$CURRENT_AUTH" = "oidc_auth" ] && [ "$FORCE" != "--force" ]; then
    log "Harbor is already configured with OIDC authentication"
    log "Use --force to reconfigure"

    # Show current OIDC settings
    curl -sk -u "admin:${HARBOR_ADMIN_PASSWORD}" \
        "${HARBOR_URL}/api/v2.0/configurations" 2>/dev/null | \
        python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  Provider:", d.get("oidc_name",{}).get("value",""))
print("  Endpoint:", d.get("oidc_endpoint",{}).get("value",""))
print("  Client ID:", d.get("oidc_client_id",{}).get("value",""))
print("  Admin Group:", d.get("oidc_admin_group",{}).get("value",""))
print("  Auto Onboard:", d.get("oidc_auto_onboard",{}).get("value",""))
' 2>/dev/null
    exit 0
fi

log "Current auth mode: ${CURRENT_AUTH}"
log "Configuring OIDC authentication..."

# --- Apply OIDC configuration ---
HTTP_CODE=$(curl -sk -o /tmp/harbor-oidc-response.json -w '%{http_code}' \
    -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    -X PUT "${HARBOR_URL}/api/v2.0/configurations" \
    -H "Content-Type: application/json" \
    -d "{
        \"auth_mode\": \"oidc_auth\",
        \"oidc_name\": \"Keycloak\",
        \"oidc_endpoint\": \"https://auth.208.haist.farm/realms/sentinel\",
        \"oidc_client_id\": \"harbor\",
        \"oidc_client_secret\": \"${OIDC_CLIENT_SECRET}\",
        \"oidc_groups_claim\": \"groups\",
        \"oidc_admin_group\": \"admin\",
        \"oidc_scope\": \"openid,profile,email,offline_access\",
        \"oidc_user_claim\": \"preferred_username\",
        \"oidc_auto_onboard\": true,
        \"oidc_verify_cert\": true
    }" 2>/dev/null)

if [ "$HTTP_CODE" -eq 200 ]; then
    log "OIDC configuration applied successfully (HTTP ${HTTP_CODE})"
else
    err "Failed to apply OIDC configuration (HTTP ${HTTP_CODE})"
    cat /tmp/harbor-oidc-response.json 2>/dev/null
    rm -f /tmp/harbor-oidc-response.json
    exit 1
fi

rm -f /tmp/harbor-oidc-response.json

# --- Verify configuration ---
log "Verifying OIDC configuration..."

VERIFY_AUTH=$(curl -sk -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    "${HARBOR_URL}/api/v2.0/configurations" 2>/dev/null | \
    python3 -c '
import sys, json
d = json.load(sys.stdin)
auth = d.get("auth_mode",{}).get("value","")
name = d.get("oidc_name",{}).get("value","")
endpoint = d.get("oidc_endpoint",{}).get("value","")
client = d.get("oidc_client_id",{}).get("value","")
admin_grp = d.get("oidc_admin_group",{}).get("value","")
auto_ob = d.get("oidc_auto_onboard",{}).get("value","")
print(f"auth_mode={auth}")
print(f"oidc_name={name}")
print(f"oidc_endpoint={endpoint}")
print(f"oidc_client_id={client}")
print(f"oidc_admin_group={admin_grp}")
print(f"oidc_auto_onboard={auto_ob}")
' 2>/dev/null)

echo "$VERIFY_AUTH" | while IFS= read -r line; do
    log "  $line"
done

if echo "$VERIFY_AUTH" | grep -q "auth_mode=oidc_auth"; then
    log "Harbor OIDC configuration verified successfully!"
    log ""
    log "Login URL: ${HARBOR_URL}"
    log "Users can click 'LOGIN VIA OIDC PROVIDER' to authenticate via Keycloak"
    log "Admin group: 'admin' (Keycloak group -> Harbor admin)"
else
    err "Verification failed — auth_mode is not oidc_auth"
    exit 1
fi
