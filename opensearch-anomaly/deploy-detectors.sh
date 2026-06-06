#!/usr/bin/env bash
# OPS-575: Deploy OpenSearch RCF anomaly detectors
# Usage: ./deploy-detectors.sh [--dry-run] [--opensearch-host HOST] [--opensearch-port PORT]
#
# Prerequisites:
#   - OpenSearch running and reachable
#   - python3 and yq (or python3-yaml) installed
#   - Credentials available via environment:
#       OPENSEARCH_USER (default: admin)
#       OPENSEARCH_PASS (pulled from Vault: secret/opensearch/admin)
#
# This script converts the YAML detector definitions to JSON and POSTs
# them to the OpenSearch Anomaly Detection API.
# See compliance-vault/runbooks/rcf-tuning.md for full deployment procedure.

set -euo pipefail

OPENSEARCH_HOST="${OPENSEARCH_HOST:-opensearch.208.haist.farm}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
OPENSEARCH_USER="${OPENSEARCH_USER:-admin}"
DRY_RUN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --opensearch-host=*) OPENSEARCH_HOST="${arg#*=}" ;;
    --opensearch-port=*) OPENSEARCH_PORT="${arg#*=}" ;;
  esac
done

# Pull password from Vault if not set
if [[ -z "${OPENSEARCH_PASS:-}" ]]; then
  if command -v vault &>/dev/null && [[ -n "${VAULT_TOKEN:-}" ]]; then
    OPENSEARCH_PASS=$(vault kv get -field=password secret/opensearch/admin 2>/dev/null || echo "")
  fi
fi

if [[ -z "${OPENSEARCH_PASS:-}" ]]; then
  echo "ERROR: OPENSEARCH_PASS not set and Vault not available." >&2
  echo "  Set OPENSEARCH_PASS env var or ensure Vault is reachable with VAULT_TOKEN." >&2
  exit 1
fi

BASE_URL="https://${OPENSEARCH_HOST}:${OPENSEARCH_PORT}/_plugins/_anomaly_detection/detectors"

echo "=== OpenSearch RCF Detector Deployment ==="
echo "Host: ${OPENSEARCH_HOST}:${OPENSEARCH_PORT}"
echo "Dry-run: ${DRY_RUN}"
echo ""

# Convert YAML detector defs to JSON and deploy
for det_file in "${SCRIPT_DIR}"/det-*.yaml; do
  det_name=$(basename "$det_file" .yaml)
  echo "--- Processing: ${det_name} ---"

  # Convert YAML to JSON using Python
  det_json=$(python3 -c "
import yaml, json, sys
with open('${det_file}') as f:
    data = yaml.safe_load(f)
# Extract the 'detector' key and flatten to API payload
payload = data.get('detector', data)
print(json.dumps(payload, indent=2))
")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would POST to: ${BASE_URL}"
    echo "Payload:"
    echo "$det_json" | head -20
    echo "..."
  else
    echo "Checking if detector '${det_name}' exists..."
    # Check if detector already exists by name
    existing=$(curl -sk -u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}" \
      "${BASE_URL}/_search" \
      -H "Content-Type: application/json" \
      -d "{\"query\": {\"term\": {\"name.keyword\": \"${det_name}\"}}}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('hits',{}).get('total',{}).get('value',0))" 2>/dev/null || echo "0")

    if [[ "$existing" -gt 0 ]]; then
      echo "  Detector '${det_name}' already exists — skipping (use --update to overwrite)"
    else
      echo "  Creating detector '${det_name}'..."
      HTTP_STATUS=$(curl -sk -o /tmp/det_create_out.json -w "%{http_code}" \
        -X POST "${BASE_URL}" \
        -H "Content-Type: application/json" \
        -u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}" \
        -d "$det_json")

      if [[ "$HTTP_STATUS" == "201" ]] || [[ "$HTTP_STATUS" == "200" ]]; then
        DET_ID=$(python3 -c "import json; d=json.load(open('/tmp/det_create_out.json')); print(d.get('_id','unknown'))" 2>/dev/null)
        echo "  Created: _id=${DET_ID} (HTTP ${HTTP_STATUS})"

        # Start the detector
        echo "  Starting detector ${DET_ID}..."
        START_STATUS=$(curl -sk -o /tmp/det_start_out.json -w "%{http_code}" \
          -X POST "${BASE_URL}/${DET_ID}/_start" \
          -u "${OPENSEARCH_USER}:${OPENSEARCH_PASS}")
        echo "  Start response: HTTP ${START_STATUS}"
      else
        echo "  ERROR: HTTP ${HTTP_STATUS}"
        cat /tmp/det_create_out.json
      fi
    fi
  fi
  echo ""
done

echo "=== Deployment complete ==="
echo "Monitor detector status in OpenSearch Dashboards > Anomaly Detection"
echo "Training takes approximately 14 days for stable baselines."
echo "See compliance-vault/runbooks/rcf-tuning.md for threshold tuning procedure."
