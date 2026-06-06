#!/bin/bash
# vault-env.sh - Pull secrets from Vault and export as environment variables
#
# Usage: source scripts/vault-env.sh
#
# Prerequisites:
#   export VAULT_ADDR=http://192.168.12.206:8200
#   export VAULT_TOKEN=<your-token>
#
# This script exports:
#   - TF_VAR_proxmox_api_token     (for OpenTofu/Terraform)
#   - AWS_ACCESS_KEY_ID             (for S3/MinIO backend)
#   - AWS_SECRET_ACCESS_KEY         (for S3/MinIO backend)
#   - PKR_VAR_proxmox_token_secret  (for Packer)
#   - CLOUDFLARE_DNS_API_TOKEN      (for Ansible/Pangolin playbook)
#   - PANGOLIN_SERVER_SECRET        (for Ansible/Pangolin playbook)
#   - NEWT_ID                       (for Ansible/Pangolin playbook)
#   - NEWT_SECRET                   (for Ansible/Pangolin playbook)

set -euo pipefail

# Check prerequisites
if [ -z "${VAULT_ADDR:-}" ]; then
    echo "ERROR: VAULT_ADDR is not set"
    echo "  export VAULT_ADDR=http://192.168.12.206:8200"
    return 1 2>/dev/null || exit 1
fi

if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "ERROR: VAULT_TOKEN is not set"
    echo "  export VAULT_TOKEN=\$(vault login -method=userpass -token-only username=<user>)"
    return 1 2>/dev/null || exit 1
fi

vault_get() {
    local path="$1"
    local field="$2"
    curl -sf -H "X-Vault-Token: $VAULT_TOKEN" "${VAULT_ADDR}/v1/secret/data/${path}" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['${field}'])"
}

echo "Fetching secrets from Vault at ${VAULT_ADDR}..."

# Proxmox credentials
PROXMOX_TOKEN_ID=$(vault_get proxmox api_token_id)
PROXMOX_TOKEN_SECRET=$(vault_get proxmox api_token_secret)
export TF_VAR_proxmox_api_token="${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
export PKR_VAR_proxmox_token_secret="${PROXMOX_TOKEN_SECRET}"
echo "  [OK] Proxmox credentials loaded"

# MinIO/S3 credentials
export AWS_ACCESS_KEY_ID=$(vault_get minio access_key)
export AWS_SECRET_ACCESS_KEY=$(vault_get minio secret_key)
echo "  [OK] MinIO/S3 credentials loaded"

# Cloudflare credentials
export CLOUDFLARE_DNS_API_TOKEN=$(vault_get cloudflare api_token)
echo "  [OK] Cloudflare credentials loaded"

# Pangolin credentials (optional - only needed for pangolin playbook)
export PANGOLIN_SERVER_SECRET=$(vault_get pangolin server_secret 2>/dev/null || echo "")
export NEWT_ID=$(vault_get pangolin newt_id 2>/dev/null || echo "")
export NEWT_SECRET=$(vault_get pangolin newt_secret 2>/dev/null || echo "")
if [ -n "${NEWT_ID}" ]; then
    echo "  [OK] Pangolin credentials loaded"
else
    echo "  [WARN] Pangolin secrets not found in Vault (optional)"
fi

echo ""
echo "Environment ready. You can now run:"
echo "  cd infrastructure/managed && tofu plan"
echo "  cd infrastructure/bootstrap && tofu plan"
echo "  cd packer && packer build fedora-coreos.pkr.hcl"
echo "  ansible-playbook -i inventory.ini playbook.yml"
