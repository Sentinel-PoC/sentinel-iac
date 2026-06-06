#!/usr/bin/env bash
# [OPS-255] provision-ci-secrets.sh
# Idempotent: read standard CI secrets from Vault and PUT them to a Forgejo repo.
#
# Usage:
#   FG_TOKEN=<token> VAULT_TOKEN=<token> \
#     ./scripts/provision-ci-secrets.sh <org>/<repo> [--dry-run]
#
# Environment (required):
#   FG_TOKEN      Forgejo API token with repo secrets write access
#   VAULT_TOKEN   Vault token with read access to secret/harbor/robot,
#                 secret/cosign, and secret/defectdojo
#
# Environment (optional):
#   FG_HOST       Forgejo host (default: forgejo.208.haist.farm)
#   VAULT_ADDR    Vault address (default: https://vault.208.haist.farm)
#   VAULT_BIN     vault binary path (default: vault)
#
# Standard CI secret set (see docs/runbooks/22-provision-ci-secrets.md):
#   HARBOR_USERNAME    — Harbor robot account username
#   HARBOR_PASSWORD    — Harbor robot account password
#   COSIGN_KEY         — cosign private key (PEM; encrypted SIGSTORE format)
#   COSIGN_PASSWORD    — cosign key passphrase (empty string if unset)
#   DEFECTDOJO_API_KEY — DefectDojo API token
#
# Behavior:
#   - Reads secret values from Vault at runtime (never stores them on disk)
#   - PUT /api/v1/repos/{owner}/{repo}/actions/secrets/{name} (idempotent)
#   - Dry-run prints secret names and Vault paths without reading or writing values
#
# Exit codes:
#   0 — all secrets provisioned (or dry-run)
#   1 — one or more secrets failed

set -euo pipefail

FG_HOST="${FG_HOST:-forgejo.208.haist.farm}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.208.haist.farm}"
VAULT_BIN="${VAULT_BIN:-vault}"
DRY_RUN=false
FAIL_COUNT=0

# ────────────────────────────────────────────────────────────
# Argument parsing
# ────────────────────────────────────────────────────────────

if [ "${1:-}" = "--dry-run" ] || [ "${2:-}" = "--dry-run" ]; then
  DRY_RUN=true
fi

REPO_ARG="${1:-}"
if [ -z "$REPO_ARG" ] || [ "$REPO_ARG" = "--dry-run" ]; then
  echo "ERROR: repo argument required (format: <org>/<repo>)"
  echo "Usage: FG_TOKEN=<token> VAULT_TOKEN=<token> $0 <org>/<repo> [--dry-run]"
  exit 1
fi

REPO_ORG="${REPO_ARG%%/*}"
REPO_NAME="${REPO_ARG##*/}"

if [ -z "$REPO_ORG" ] || [ -z "$REPO_NAME" ] || [ "$REPO_ORG" = "$REPO_NAME" ]; then
  echo "ERROR: repo must be in <org>/<repo> format (got: ${REPO_ARG})"
  exit 1
fi

# ────────────────────────────────────────────────────────────
# Prerequisite checks
# ────────────────────────────────────────────────────────────

if [ -z "${FG_TOKEN:-}" ]; then
  echo "ERROR: FG_TOKEN is required"
  exit 1
fi

if $DRY_RUN; then
  echo "[DRY-RUN] No Vault reads or Forgejo API writes will be made"
else
  if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "ERROR: VAULT_TOKEN is required"
    exit 1
  fi
  if ! command -v "$VAULT_BIN" >/dev/null 2>&1; then
    echo "ERROR: vault binary not found (set VAULT_BIN if non-standard path)"
    exit 1
  fi
fi

FG_API="https://${FG_HOST}/api/v1"

# ────────────────────────────────────────────────────────────
# Secret definitions: name -> vault_path:vault_field
# ────────────────────────────────────────────────────────────

# Declare parallel arrays for portability (bash 3 compatible)
SECRET_NAMES=(
  HARBOR_USERNAME
  HARBOR_PASSWORD
  COSIGN_KEY
  COSIGN_PASSWORD
  DEFECTDOJO_API_KEY
)

SECRET_VAULT_PATHS=(
  "secret/harbor/robot:username"
  "secret/harbor/robot:password"
  "secret/cosign:private_key"
  "secret/cosign:password"
  "secret/defectdojo:api_token"
)

# Secrets that are allowed to be empty/n/a in Vault — skip provisioning if unset.
# COSIGN_PASSWORD is optional: the cosign key may have no passphrase, and workflows
# fall back to '' via ${{ secrets.COSIGN_PASSWORD || '' }} when the secret is absent.
SECRET_OPTIONAL=(
  false
  false
  false
  true
  false
)

# ────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────

vault_read() {
  # vault_read <path> <field>
  # Returns field value or empty string if field is "n/a" (Vault sentinel for unset)
  local path="$1"
  local field="$2"
  local value
  value=$(VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_TOKEN" \
    "$VAULT_BIN" kv get -field="$field" "$path" 2>&1) || {
    echo "ERROR: vault read failed for ${path}#${field}: ${value}" >&2
    return 1
  }
  if [ "$value" = "n/a" ]; then
    # Vault stores n/a for empty optional fields (e.g. cosign password if unset)
    echo ""
  else
    echo "$value"
  fi
}

put_secret() {
  # put_secret <repo_org> <repo_name> <secret_name> <secret_value>
  local org="$1"
  local repo="$2"
  local name="$3"
  local value="$4"

  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'data': sys.argv[1]}))" "$value")

  local http_code
  http_code=$(curl -s -o /tmp/fg_secret_resp.json \
    -w "%{http_code}" \
    -X PUT \
    --header "Authorization: token ${FG_TOKEN}" \
    --header "Content-Type: application/json" \
    -d "$payload" \
    "${FG_API}/repos/${org}/${repo}/actions/secrets/${name}")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "   OK (HTTP ${http_code})"
  else
    echo "   FAILED (HTTP ${http_code})"
    echo "   Response: $(cat /tmp/fg_secret_resp.json 2>/dev/null || echo '(empty)')"
    return 1
  fi
}

# ────────────────────────────────────────────────────────────
# Main
# ────────────────────────────────────────────────────────────

echo "[OPS-255] CI secrets provisioning"
echo "Target:   ${REPO_ORG}/${REPO_NAME}"
echo "Host:     ${FG_HOST}"
echo "Vault:    ${VAULT_ADDR}"
echo "Dry-run:  ${DRY_RUN}"
echo ""

for i in "${!SECRET_NAMES[@]}"; do
  name="${SECRET_NAMES[$i]}"
  vault_ref="${SECRET_VAULT_PATHS[$i]}"
  vault_path="${vault_ref%%:*}"
  vault_field="${vault_ref##*:}"
  optional="${SECRET_OPTIONAL[$i]}"

  echo "── ${name} ──────────────────────────────────"
  echo "   Vault: ${vault_path} [field: ${vault_field}]"

  if $DRY_RUN; then
    echo "   [DRY-RUN] Would PUT ${name} to ${REPO_ORG}/${REPO_NAME}"
    continue
  fi

  secret_value=""
  if ! secret_value=$(vault_read "$vault_path" "$vault_field"); then
    echo "   ERROR: failed to read from Vault"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  if [ -z "$secret_value" ]; then
    if [ "$optional" = "true" ]; then
      echo "   SKIP: Vault value is empty and secret is optional"
      continue
    else
      echo "   ERROR: Vault value is empty for required secret"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      continue
    fi
  fi

  if put_secret "$REPO_ORG" "$REPO_NAME" "$name" "$secret_value"; then
    echo "   Provisioned: ${name}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo ""
echo "──────────────────────────────────────────────"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL — ${FAIL_COUNT} secret(s) failed"
  exit 1
else
  echo "RESULT: OK — all ${#SECRET_NAMES[@]} secrets provisioned to ${REPO_ORG}/${REPO_NAME}"
  exit 0
fi
