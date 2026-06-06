#!/bin/bash
# Upload latest compliance report to MinIO for the evidence pipeline.
# Runs as ExecStartPost in nist-compliance-check.service (User=ubuntu).
#
# OPS-737: Do NOT source /etc/sentinel/compliance.env here. The service unit
# declares EnvironmentFile=/etc/sentinel/compliance.env, so systemd injects
# MINIO_ENDPOINT, MINIO_AK, MINIO_SK into the process environment before this
# script runs. The file is root:root 0600 and cannot be read by the ubuntu user.
set -euo pipefail
DATE=$(date +%Y-%m-%d)
REPORT="/var/log/sentinel/nist-compliance-${DATE}.json"

if [ ! -f "$REPORT" ]; then
    echo "No compliance report for ${DATE}, skipping upload"
    exit 0
fi

export MC_CONFIG_DIR=/tmp/.mc-upload
mc alias set sentinel "${MINIO_ENDPOINT}" "${MINIO_AK}" "${MINIO_SK}" --api s3v4 >/dev/null 2>&1
mc cp "$REPORT" "sentinel/compliance-reports/nist-compliance-${DATE}.json"
echo "Uploaded ${REPORT} to MinIO compliance-reports bucket"
rm -rf "$MC_CONFIG_DIR"
