#!/bin/bash
# =============================================================================
# SSH Certificate Auto-Renewal — Project Sentinel
# Signs a fresh SSH certificate via Vault SSH CA for automated SSH checks
# Runs before compliance checks and other scripts that SSH to managed hosts
# NIST Controls: IA-5(2) (PKI-Based Authentication), AC-17 (Remote Access)
# =============================================================================
set -euo pipefail

LOG_DIR="/var/log/sentinel"
LOG_FILE="${LOG_DIR}/ssh-cert-renew.log"
SSH_KEY="$HOME/.ssh/id_sentinel"
SSH_CERT="${SSH_KEY}-cert.pub"
VAULT_URL="https://vault.208.haist.farm"
VAULT_SSH_ROLE="admin"
CERT_TTL="2h"
PRINCIPALS="ubuntu,root,koiakoia"

log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# --- Get Vault token ---
# Priority: environment variable > compliance.env > fail
if [ -z "${VAULT_TOKEN:-}" ]; then
    if [ -f /etc/sentinel/compliance.env ]; then
        source /etc/sentinel/compliance.env
    fi
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    log "ERROR: VAULT_TOKEN not set. Cannot sign SSH certificate."
    log "  Set VAULT_TOKEN in environment or /etc/sentinel/compliance.env"
    exit 1
fi

# --- Check if current cert is still valid ---
if [ -f "$SSH_CERT" ]; then
    # Get cert expiry timestamp
    VALID_TO=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null | grep "Valid:" | sed 's/.*to //')
    if [ -n "$VALID_TO" ]; then
        EXPIRY_EPOCH=$(date -d "$VALID_TO" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        REMAINING=$((EXPIRY_EPOCH - NOW_EPOCH))
        if [ $REMAINING -gt 600 ]; then
            log "Current cert still valid for $((REMAINING / 60)) minutes, skipping renewal"
            exit 0
        fi
        log "Current cert expires in $((REMAINING / 60)) minutes, renewing"
    fi
else
    log "No existing cert, creating new one"
fi

# --- Read public key ---
if [ ! -f "${SSH_KEY}.pub" ]; then
    log "ERROR: SSH public key not found at ${SSH_KEY}.pub"
    exit 1
fi
PUBKEY=$(cat "${SSH_KEY}.pub")

# --- Sign via Vault API ---
log "Signing SSH certificate via Vault (role=${VAULT_SSH_ROLE}, ttl=${CERT_TTL})"
RESPONSE=$(curl -s -k -X POST \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"public_key\": \"${PUBKEY}\", \"valid_principals\": \"${PRINCIPALS}\", \"ttl\": \"${CERT_TTL}\"}" \
    "${VAULT_URL}/v1/ssh/sign/${VAULT_SSH_ROLE}" 2>/dev/null)

# --- Check response ---
SIGNED_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['signed_key'])" 2>/dev/null)

if [ -z "$SIGNED_KEY" ]; then
    ERRORS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors', d))" 2>/dev/null || echo "$RESPONSE")
    log "ERROR: Failed to sign SSH certificate: ${ERRORS}"
    exit 1
fi

# --- Write cert ---
echo "$SIGNED_KEY" > "$SSH_CERT"
chmod 600 "$SSH_CERT"

# --- Verify ---
SERIAL=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null | grep "Serial:" | awk '{print $2}')
VALID=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null | grep "Valid:")
log "Certificate renewed: serial=${SERIAL}"
log "  ${VALID}"

# --- Also sign id_wazuh if it exists ---
WAZUH_KEY="$HOME/.ssh/id_wazuh"
if [ -f "${WAZUH_KEY}.pub" ]; then
    WAZUH_PUBKEY=$(cat "${WAZUH_KEY}.pub")
    WAZUH_RESPONSE=$(curl -s -k -X POST \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"public_key\": \"${WAZUH_PUBKEY}\", \"valid_principals\": \"${PRINCIPALS}\", \"ttl\": \"${CERT_TTL}\"}" \
        "${VAULT_URL}/v1/ssh/sign/${VAULT_SSH_ROLE}" 2>/dev/null)

    WAZUH_SIGNED=$(echo "$WAZUH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['signed_key'])" 2>/dev/null)
    if [ -n "$WAZUH_SIGNED" ]; then
        echo "$WAZUH_SIGNED" > "${WAZUH_KEY}-cert.pub"
        chmod 600 "${WAZUH_KEY}-cert.pub"
        log "Also renewed id_wazuh cert"
    else
        log "WARNING: Failed to sign id_wazuh cert"
    fi
fi

exit 0
