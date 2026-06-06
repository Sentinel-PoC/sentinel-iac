#!/bin/bash
# =============================================================================
# Evidence Pipeline — Project Sentinel
# Runs daily at 7 AM UTC on iac-control (after compliance check at 6 AM)
# Copies compliance JSON + OSCAL AR to compliance-vault repo, commits, pushes
# NIST Controls: CA-2 (Control Assessments), CA-7 (Continuous Monitoring)
# =============================================================================
set -euo pipefail

DATE=$(date +%Y-%m-%d)
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="/var/log/sentinel"
COMPLIANCE_VAULT_DIR="$HOME/compliance-vault"
COMPLIANCE_JSON="${LOG_DIR}/nist-compliance-${DATE}.json"
OSCAL_SCRIPT="${SCRIPT_DIR}/convert-to-oscal-ar.sh"
LOG_FILE="${LOG_DIR}/evidence-pipeline.log"

# --- Helpers ---
log() { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }

# --- Maintenance Mode Check ---
LIB_PATH="/home/ubuntu/scripts/_sentinel-lib.sh"
if [ -f "$LIB_PATH" ]; then
    source "$LIB_PATH"
    if check_maintenance "all"; then
        log_maintenance_skip "evidence-pipeline"
        log "Evidence pipeline skipped: maintenance mode active (scope=all)"
        exit 0
    fi
fi

# =============================================================================
# MAIN
# =============================================================================

log "=========================================="
log "Evidence Pipeline starting — ${DATE}"
log "=========================================="

# --- Step 1: Verify compliance JSON exists ---
if [ ! -f "$COMPLIANCE_JSON" ]; then
    log "WARNING: Compliance JSON not found at ${COMPLIANCE_JSON}"
    log "The 6 AM compliance check may not have run today. Exiting gracefully."
    exit 0
fi

log "Found compliance JSON: ${COMPLIANCE_JSON}"
log "  Size: $(stat -c %s "$COMPLIANCE_JSON" 2>/dev/null || echo 'unknown') bytes"

# --- Step 2: Verify compliance-vault repo exists ---
if [ ! -d "$COMPLIANCE_VAULT_DIR/.git" ]; then
    log "ERROR: compliance-vault repo not found at ${COMPLIANCE_VAULT_DIR}"
    log "Clone it first: git clone <gitlab-url>/admin1/compliance-vault.git ~/compliance-vault"
    exit 1
fi

# --- Step 3: Pull latest from compliance-vault to avoid conflicts ---
log "Pulling latest from compliance-vault..."
if ! git -C "$COMPLIANCE_VAULT_DIR" pull --rebase origin main 2>&1 | tee -a "$LOG_FILE"; then
    log "WARNING: git pull failed, attempting to continue anyway"
fi

# --- Step 4: Create directories if needed ---
mkdir -p "${COMPLIANCE_VAULT_DIR}/evidence"
mkdir -p "${COMPLIANCE_VAULT_DIR}/assessment-results"

# --- Step 5: Copy compliance JSON to evidence/ ---
log "Copying compliance JSON to evidence/"
cp "$COMPLIANCE_JSON" "${COMPLIANCE_VAULT_DIR}/evidence/nist-compliance-${DATE}.json"
log "  -> evidence/nist-compliance-${DATE}.json"

# --- Step 6: Run OSCAL AR conversion ---
OSCAL_SUCCESS=false
if [ -x "$OSCAL_SCRIPT" ]; then
    log "Running OSCAL AR converter..."
    OSCAL_AR_OUTPUT="${LOG_DIR}/oscal-ar-${DATE}.json"

    if "$OSCAL_SCRIPT" "$DATE" 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "$OSCAL_AR_OUTPUT" ]; then
            # Validate it's valid JSON
            if jq empty "$OSCAL_AR_OUTPUT" 2>/dev/null; then
                OSCAL_SUCCESS=true
                log "OSCAL AR conversion successful"

                # Copy OSCAL AR to compliance-vault
                cp "$OSCAL_AR_OUTPUT" "${COMPLIANCE_VAULT_DIR}/assessment-results/sentinel-ar-${DATE}.json"
                log "  -> assessment-results/sentinel-ar-${DATE}.json"

                # Maintain latest.json
                cp "$OSCAL_AR_OUTPUT" "${COMPLIANCE_VAULT_DIR}/assessment-results/latest.json"
                log "  -> assessment-results/latest.json (updated)"
            else
                log "WARNING: OSCAL AR output is not valid JSON, skipping"
            fi
        else
            log "WARNING: OSCAL AR output file not found at ${OSCAL_AR_OUTPUT}"
        fi
    else
        log "WARNING: OSCAL AR converter returned non-zero exit code"
    fi
else
    log "WARNING: OSCAL converter not found or not executable at ${OSCAL_SCRIPT}"
    log "  Only compliance JSON will be committed"
fi

# --- Step 7: Generate human-readable daily report ---
REPORT_GENERATOR="${COMPLIANCE_VAULT_DIR}/scripts/generate-daily-report.py"
REPORT_DIR="${COMPLIANCE_VAULT_DIR}/reports/daily"
REPORT_SUCCESS=false

if [ -f "$REPORT_GENERATOR" ]; then
    log "Generating human-readable daily report..."
    mkdir -p "$REPORT_DIR"

    REPORT_FILE="${REPORT_DIR}/compliance-report-${DATE}.md"

    if python3 "$REPORT_GENERATOR" "$COMPLIANCE_JSON" "$REPORT_DIR" 2>&1 | tee -a "$LOG_FILE"; then
        if [ -f "$REPORT_FILE" ]; then
            REPORT_SUCCESS=true
            log "  -> reports/daily/compliance-report-${DATE}.md"

            # Also regenerate the trend summary from all available check data
            SUMMARY_FILE="${COMPLIANCE_VAULT_DIR}/reports/compliance-trend-summary.md"
            if python3 "$REPORT_GENERATOR" --batch "${COMPLIANCE_VAULT_DIR}/evidence" "$REPORT_DIR" 2>&1 | tee -a "$LOG_FILE"; then
                log "  -> reports/compliance-trend-summary.md (updated)"
            fi
        else
            log "WARNING: Report file not generated at ${REPORT_FILE}"
        fi
    else
        log "WARNING: Report generator returned non-zero exit code"
    fi
else
    log "WARNING: Report generator not found at ${REPORT_GENERATOR}"
    log "  Human-readable reports will not be generated"
fi

# --- Step 8: Git commit and push ---
log "Committing to compliance-vault..."
cd "$COMPLIANCE_VAULT_DIR"

# Stage all changes
git add evidence/ assessment-results/ reports/ 2>&1 | tee -a "$LOG_FILE"

# Check if there are changes to commit
if git diff --cached --quiet 2>/dev/null; then
    log "No changes to commit — evidence may already be up to date"
else
    # Build commit message
    COMMIT_MSG="Evidence pipeline: ${DATE} compliance data"
    if $OSCAL_SUCCESS; then
        COMMIT_MSG="${COMMIT_MSG} + OSCAL AR"
    fi
    if $REPORT_SUCCESS; then
        COMMIT_MSG="${COMMIT_MSG} + daily report"
    fi

    # Extract summary from compliance JSON if available
    PASS_RATE=$(jq -r '.summary.pass_rate // "unknown"' "$COMPLIANCE_JSON" 2>/dev/null || echo "unknown")
    OVERALL=$(jq -r '.overall_status // "unknown"' "$COMPLIANCE_JSON" 2>/dev/null || echo "unknown")
    COMMIT_MSG="${COMMIT_MSG}

Status: ${OVERALL} (${PASS_RATE}% pass rate)
Generated: ${TIMESTAMP}
Source: nist-compliance-check.sh automated run"

    if git commit -m "$COMMIT_MSG" 2>&1 | tee -a "$LOG_FILE"; then
        log "Commit successful"

        # Push to GitLab
        if git push origin main 2>&1 | tee -a "$LOG_FILE"; then
            log "Push to GitLab successful"
        else
            log "ERROR: git push failed — manual push required"
            log "  Run: git -C ${COMPLIANCE_VAULT_DIR} push origin main"
        fi
    else
        log "ERROR: git commit failed"
    fi
fi

# --- Summary ---
log "=========================================="
log "Evidence Pipeline complete — ${DATE}"
log "  Compliance JSON: evidence/nist-compliance-${DATE}.json"
if $OSCAL_SUCCESS; then
    log "  OSCAL AR:        assessment-results/sentinel-ar-${DATE}.json"
    log "  Latest AR:       assessment-results/latest.json"
else
    log "  OSCAL AR:        SKIPPED (converter unavailable or failed)"
fi
if $REPORT_SUCCESS; then
    log "  Daily Report:    reports/daily/compliance-report-${DATE}.md"
    log "  Trend Summary:   reports/compliance-trend-summary.md"
else
    log "  Daily Report:    SKIPPED (generator unavailable or failed)"
fi
log "=========================================="

exit 0
