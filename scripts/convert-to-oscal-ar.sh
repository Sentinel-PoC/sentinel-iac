#!/bin/bash
# =============================================================================
# OSCAL Assessment Results Converter — Project Sentinel
# Converts nist-compliance-check.sh JSON output to OSCAL 1.1.2 Assessment Results
# NIST Controls: CA-2 (Control Assessments), CA-7 (Continuous Monitoring)
# =============================================================================
set -euo pipefail

# --- Configuration ---
LOG_DIR="/var/log/sentinel"
DATE="${1:-$(date +%Y-%m-%d)}"
INPUT_FILE="${LOG_DIR}/nist-compliance-${DATE}.json"
OUTPUT_FILE="${LOG_DIR}/oscal-ar-${DATE}.json"

# --- Validation ---
if [ ! -f "$INPUT_FILE" ]; then
    echo "ERROR: Input file not found: ${INPUT_FILE}" >&2
    echo "Usage: $0 [YYYY-MM-DD]" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required but not installed" >&2
    exit 1
fi

if ! command -v uuidgen >/dev/null 2>&1; then
    echo "ERROR: uuidgen is required but not installed" >&2
    exit 1
fi

# --- Read input ---
INPUT=$(cat "$INPUT_FILE")
TIMESTAMP=$(echo "$INPUT" | jq -r '.timestamp')
CHECK_COUNT=$(echo "$INPUT" | jq '.checks | length')

# Generate top-level UUIDs
AR_UUID=$(uuidgen)
RESULT_UUID=$(uuidgen)

# --- Build OSCAL AR using jq ---
# Strategy: build findings and observations arrays by iterating checks,
# generating a UUID pair (finding + observation) for each check.

# First, generate all UUID pairs upfront (one finding UUID + one observation UUID per check)
FINDING_UUIDS=()
OBSERVATION_UUIDS=()
for (( i=0; i<CHECK_COUNT; i++ )); do
    FINDING_UUIDS+=("$(uuidgen)")
    OBSERVATION_UUIDS+=("$(uuidgen)")
done

# Build the UUID arrays as JSON for jq consumption
if [ "$CHECK_COUNT" -eq 0 ]; then
    FINDING_UUIDS_JSON='[]'
    OBSERVATION_UUIDS_JSON='[]'
else
    FINDING_UUIDS_JSON=$(printf '%s\n' "${FINDING_UUIDS[@]}" | jq -R . | jq -s .)
    OBSERVATION_UUIDS_JSON=$(printf '%s\n' "${OBSERVATION_UUIDS[@]}" | jq -R . | jq -s .)
fi

# Build the complete OSCAL AR document in a single jq invocation
jq -n \
    --arg ar_uuid "$AR_UUID" \
    --arg result_uuid "$RESULT_UUID" \
    --arg timestamp "$TIMESTAMP" \
    --arg date "$DATE" \
    --argjson checks "$INPUT" \
    --argjson finding_uuids "$FINDING_UUIDS_JSON" \
    --argjson observation_uuids "$OBSERVATION_UUIDS_JSON" \
'
# Extract the checks array and timestamp from input
($checks.checks // []) as $check_list |
($checks.timestamp // $timestamp) as $ts |

# Build reviewed-controls: unique lowercase control IDs
[
    $check_list[].control |
    ascii_downcase
] | unique | map({"control-id": .}) as $control_ids |

# Build findings array
[
    range($check_list | length) as $i |
    $check_list[$i] as $check |
    $finding_uuids[$i] as $f_uuid |
    $observation_uuids[$i] as $o_uuid |
    ($check.control | ascii_downcase) as $ctrl_id |

    # Map status to OSCAL state
    (if $check.status == "PASS" then "satisfied"
     elif $check.status == "FAIL" then "not-satisfied"
     else "satisfied"
     end) as $state |

    # Build target object
    {
        "type": "objective-id",
        "target-id": $ctrl_id,
        "status": {"state": $state}
    } as $target |

    # Build finding
    {
        "uuid": $f_uuid,
        "title": ($check.control + ": " + $check.check),
        "description": $check.detail,
        "target": $target,
        "related-observations": [{"observation-uuid": $o_uuid}]
    } |

    # Add warning prop for WARN status
    if $check.status == "WARN" then
        . + {"props": [{"name": "warning", "ns": "https://sentinel.haist.farm", "value": "true"}]}
    else .
    end
] as $findings |

# Build observations array
[
    range($check_list | length) as $i |
    $check_list[$i] as $check |
    $observation_uuids[$i] as $o_uuid |
    {
        "uuid": $o_uuid,
        "description": $check.detail,
        "methods": ["AUTOMATED"],
        "types": ["finding"],
        "collected": $ts
    }
] as $observations |

# Assemble the complete OSCAL AR document
{
    "assessment-results": {
        "uuid": $ar_uuid,
        "metadata": {
            "title": "Sentinel Platform Automated Assessment",
            "last-modified": $ts,
            "version": "1.0.0",
            "oscal-version": "1.1.2",
            "props": [
                {"name": "assessment-date", "value": $date},
                {"name": "tool", "value": "nist-compliance-check.sh"}
            ]
        },
        "import-ap": {
            "href": "#"
        },
        "results": [
            {
                "uuid": $result_uuid,
                "title": ("Automated Assessment " + $date),
                "start": $ts,
                "end": $ts,
                "reviewed-controls": {
                    "control-selections": [
                        {
                            "include-controls": $control_ids
                        }
                    ]
                },
                "findings": $findings,
                "observations": $observations
            }
        ]
    }
}
' > "$OUTPUT_FILE"

# --- Summary ---
PASS_COUNT=$(echo "$INPUT" | jq '[.checks[] | select(.status == "PASS")] | length')
FAIL_COUNT=$(echo "$INPUT" | jq '[.checks[] | select(.status == "FAIL")] | length')
WARN_COUNT=$(echo "$INPUT" | jq '[.checks[] | select(.status == "WARN")] | length')

echo "Converted ${CHECK_COUNT} checks → OSCAL AR: ${OUTPUT_FILE}"
echo "  Findings: ${PASS_COUNT} satisfied, ${FAIL_COUNT} not-satisfied, ${WARN_COUNT} warnings"
