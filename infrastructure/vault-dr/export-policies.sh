#\!/bin/bash
# Export Vault policies to the policies/ directory
# Requires: VAULT_ADDR and VAULT_TOKEN environment variables
#
# Usage:
#   export VAULT_ADDR=http://192.168.12.206:8200
#   export VAULT_TOKEN=hvs.xxxxx
#   ./export-policies.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="${SCRIPT_DIR}/policies"

if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_TOKEN:-}" ]; then
    echo "Error: VAULT_ADDR and VAULT_TOKEN must be set"
    exit 1
fi

echo "Exporting Vault policies to ${POLICY_DIR}..."
mkdir -p "${POLICY_DIR}"

for policy in $(vault policy list); do
    if [ "$policy" = "root" ]; then
        continue  # root policy cannot be exported
    fi
    echo "  Exporting: ${policy}"
    vault policy read "$policy" > "${POLICY_DIR}/${policy}.hcl"
done

echo "Done. Exported policies:"
ls -la "${POLICY_DIR}"/*.hcl 2>/dev/null || echo "  (none)"
