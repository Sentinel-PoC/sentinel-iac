#!/bin/bash
# Auto-unseal the Transit Vault (lightweight Vault on iac-control)
# Key sourced from /etc/vault-unseal/transit.key (0400 root:root)
# OPS-224 (externalized key) + OPS-214 (curl timeouts prevent service hangs)
#
# The Transit Vault is the Shamir-sealed companion Vault that the main
# Vault uses for auto-unseal. If the Transit Vault itself is sealed
# (e.g., after a container restart), this script submits the stored
# unseal key. Timer schedule: every 2 minutes (see
# vault-unseal-transit.timer).

set -uo pipefail

KEY_FILE=/etc/vault-unseal/transit.key
# SEC-89: https — transit listener now has TLS enabled.
VAULT_ADDR="${VAULT_ADDR:-https://192.168.12.210:8201}"
# SEC-89: CA cert for transit Vault's self-signed TLS cert. Deployed by
# iac-control role (Phase A). Must be on disk before this timer fires.
VAULT_CACERT="${VAULT_CACERT:-/opt/vault-unseal/config/tls/cert.pem}"

if [[ ! -r "$KEY_FILE" ]]; then
    echo "ERROR: cannot read $KEY_FILE (service must run as root)" >&2
    exit 2
fi
UNSEAL_KEY=$(cat "$KEY_FILE")

HEALTH=$(curl -s -m 5 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/health" 2>&1)
CURL_RC=$?
if [[ $CURL_RC -ne 0 ]]; then
    echo "ERROR: curl failed rc=$CURL_RC reaching $VAULT_ADDR" >&2
    exit 3
fi

SEALED=$(echo "$HEALTH" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sealed",True))' 2>/dev/null || echo "ERROR")
case "$SEALED" in
    True)
        echo "Transit Vault sealed; submitting unseal key..."
        RESP=$(curl -s -m 5 --cacert "$VAULT_CACERT" -X PUT "$VAULT_ADDR/v1/sys/unseal" -d "{\"key\":\"$UNSEAL_KEY\"}" 2>&1)
        NEW_SEAL=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sealed","?"))' 2>/dev/null)
        echo "Post-unseal: sealed=$NEW_SEAL"
        [[ "$NEW_SEAL" == "False" ]] || { echo "ERROR: unseal did not succeed" >&2; exit 4; }
        ;;
    False)
        echo "Transit Vault already unsealed"
        ;;
    *)
        echo "ERROR: could not parse sealed status from health response" >&2
        echo "raw: $HEALTH" >&2
        exit 5
        ;;
esac
