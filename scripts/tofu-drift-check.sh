#!/usr/bin/env bash
# Terraform/OpenTofu drift detection for managed infrastructure layer
# Runs weekly via systemd timer, logs drift events to Wazuh
# NIST Controls: CM-3 (Configuration Change Control), CM-6 (Configuration Settings)
set -euo pipefail

TOFU_DIR="${HOME}/sentinel-repo/infrastructure/managed"
LOG_DIR="/var/log/sentinel"
LOG_FILE="${LOG_DIR}/tofu-drift-$(date +%Y-%m-%d).json"
MAINTENANCE_FILE="/tmp/sentinel-maintenance-mode"

# Check maintenance mode
if [[ -f "$MAINTENANCE_FILE" ]]; then
    echo "Maintenance mode active, skipping drift check"
    exit 0
fi

mkdir -p "$LOG_DIR"

cd "$TOFU_DIR" || {
    echo '{"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","event":"TOFU_DRIFT_CHECK_FAILED","error":"Cannot cd to '"$TOFU_DIR"'"}' | logger -t tofu-drift -p local0.warning
    exit 1
}

# Source Vault credentials for provider auth
if [[ -f /etc/sentinel/compliance.env ]]; then
    set -a
    # shellcheck source=/dev/null
    source /etc/sentinel/compliance.env
    set +a
fi

# Run tofu plan with detailed exit code
# Exit codes: 0=no changes, 1=error, 2=changes detected
PLAN_OUTPUT=$(tofu plan -detailed-exitcode -no-color -input=false 2>&1) || true
EXIT_CODE=${PIPESTATUS[0]:-$?}

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

case $EXIT_CODE in
    0)
        # No drift
        EVENT='{"timestamp":"'"$TIMESTAMP"'","event":"TOFU_DRIFT_CHECK_COMPLETE","drift":false,"changes":0}'
        echo "$EVENT" > "$LOG_FILE"
        echo "$EVENT" | logger -t tofu-drift -p local0.info
        echo "No drift detected"
        ;;
    2)
        # Drift detected — parse resource changes
        ADDS=$(echo "$PLAN_OUTPUT" | grep -oP '\d+ to add' | grep -oP '\d+' || echo 0)
        CHANGES=$(echo "$PLAN_OUTPUT" | grep -oP '\d+ to change' | grep -oP '\d+' || echo 0)
        DESTROYS=$(echo "$PLAN_OUTPUT" | grep -oP '\d+ to destroy' | grep -oP '\d+' || echo 0)
        TOTAL=$((ADDS + CHANGES + DESTROYS))

        # Extract resource names from plan output
        RESOURCES=$(echo "$PLAN_OUTPUT" | grep -E '^\s+#\s' | sed 's/^\s*#\s*//' | head -20 | tr '\n' ', ' | sed 's/,$//')

        EVENT='{"timestamp":"'"$TIMESTAMP"'","event":"TOFU_DRIFT_DETECTED","drift":true,"changes":'"$TOTAL"',"adds":'"$ADDS"',"updates":'"$CHANGES"',"destroys":'"$DESTROYS"'}'
        echo "$EVENT" > "$LOG_FILE"
        echo "$EVENT" | logger -t tofu-drift -p local0.warning

        # Log resource details separately for Wazuh parsing
        DETAIL='{"timestamp":"'"$TIMESTAMP"'","event":"TOFU_DRIFT_RESOURCES","resources":"'"$RESOURCES"'"}'
        echo "$DETAIL" | logger -t tofu-drift -p local0.warning

        echo "DRIFT DETECTED: $TOTAL resource(s) changed (add=$ADDS, change=$CHANGES, destroy=$DESTROYS)"
        ;;
    *)
        # Error
        ERROR_MSG=$(echo "$PLAN_OUTPUT" | tail -5 | tr '\n' ' ' | sed 's/"/\\"/g')
        EVENT='{"timestamp":"'"$TIMESTAMP"'","event":"TOFU_DRIFT_CHECK_FAILED","error":"'"$ERROR_MSG"'"}'
        echo "$EVENT" > "$LOG_FILE"
        echo "$EVENT" | logger -t tofu-drift -p local0.err
        echo "Drift check failed with exit code $EXIT_CODE"
        exit 1
        ;;
esac
