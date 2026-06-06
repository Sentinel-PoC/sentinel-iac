#!/usr/bin/env bash
# ci/harbor-image-scan.sh
#
# Discover all images in Harbor project 'sentinel', scan each unique digest
# with Trivy, and emit a single combined Trivy JSON report.
#
# Created by OPS-187. Replaces the previous static grep-based discovery
# (which found 0 images in this repo layout) with a registry-truth sweep.
#
# Environment:
#   HARBOR_URL          default https://harbor.208.haist.farm
#   HARBOR_PROJECT      default sentinel
#   HARBOR_ROBOT_USER   required — robot$sentinel+ci-trivy-scan
#   HARBOR_ROBOT_TOKEN  required — robot secret
#   OUTPUT              default trivy-image-report.json
#   TRIVY_CACHE_DIR     default ~/.cache/trivy
#   PAGE_SIZE           default 100
#   SEVERITY            default CRITICAL,HIGH,MEDIUM
#   TRIVY_TIMEOUT       default 10m  (per-image trivy call timeout; bump here
#                       or override via workflow env if a large registry causes
#                       timeouts on Trivy DB fetch or slow image pulls)
#   TRIVY_MAX_ATTEMPTS  default 3   (retry count on transient errors)
#   TRIVY_RETRY_SLEEP   default 30  (seconds between retry attempts)
#
# Exit codes:
#   0  success (report written with >=1 Results entry, or legitimately empty)
#   1  catastrophic failure (cannot reach Harbor, no creds, etc.)
#   2  config / arg error
#
# The script does NOT fail on per-image scan errors — those are logged to
# stderr and the sweep continues. This matches the design agreed in OPS-187
# PLAN: one bad image must not black-hole the whole registry snapshot.
#
# Robot token rotation: the robot is created with 180-day TTL. Plane will
# raise a reminder 14 days before expiry. Rotate via Harbor admin API,
# update Vault secret/data/harbor/ci-trivy-scan, update Forgejo Actions
# secrets HARBOR_ROBOT_USER / HARBOR_ROBOT_TOKEN.

set -euo pipefail

HARBOR_URL="${HARBOR_URL:-https://harbor.208.haist.farm}"
HARBOR_PROJECT="${HARBOR_PROJECT:-sentinel}"
OUTPUT="${OUTPUT:-trivy-image-report.json}"
TRIVY_CACHE_DIR="${TRIVY_CACHE_DIR:-${HOME}/.cache/trivy}"
PAGE_SIZE="${PAGE_SIZE:-100}"
SEVERITY="${SEVERITY:-CRITICAL,HIGH,MEDIUM}"
TRIVY_TIMEOUT="${TRIVY_TIMEOUT:-10m}"
TRIVY_MAX_ATTEMPTS="${TRIVY_MAX_ATTEMPTS:-3}"
TRIVY_RETRY_SLEEP="${TRIVY_RETRY_SLEEP:-30}"
# Cap artifacts scanned per repo (newest first by push_time). DefectDojo
# has a 100 MB reimport limit and an nginx proxy timeout that bites well
# before that on slow uploads. On a 42-repo sweep we saw 9632 findings
# and 128 MB output when unlimited — impossible to upload as one report.
# Default 5 keeps us to current + a handful of recent artifacts per repo,
# which matches the security goal (scan what's deployable now) without
# dragging in a year of commit-hash dev builds. Override to 0 for no cap.
MAX_ARTIFACTS_PER_REPO="${MAX_ARTIFACTS_PER_REPO:-5}"
# Drop verbose fields from the merged report before emit. DefectDojo's
# Trivy parser does not use these, and their absence keeps us under the
# upload size cap. Override to 0 to disable trimming (useful for local
# debugging where you want full context).
TRIM_OUTPUT="${TRIM_OUTPUT:-1}"
WORKDIR="$(mktemp -d -t harbor-scan-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# --- validation -------------------------------------------------------------

if [ -z "${HARBOR_ROBOT_USER:-}" ] || [ -z "${HARBOR_ROBOT_TOKEN:-}" ]; then
  log "ERROR: HARBOR_ROBOT_USER and HARBOR_ROBOT_TOKEN must be set"
  exit 2
fi

for bin in curl jq trivy; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    log "ERROR: required binary not found: $bin"
    exit 2
  fi
done

mkdir -p "$TRIVY_CACHE_DIR"

# --- Harbor helpers ---------------------------------------------------------

# Never echo credentials. curl_harbor writes response body to stdout and
# HTTP status to ${WORKDIR}/last_status so callers can check it.
curl_harbor() {
  local path="$1"
  local url="${HARBOR_URL}/api/v2.0/${path}"
  curl -sk \
    -o "${WORKDIR}/curl.body" \
    -w '%{http_code}' \
    -u "${HARBOR_ROBOT_USER}:${HARBOR_ROBOT_TOKEN}" \
    "$url" \
    > "${WORKDIR}/last_status" \
    2>"${WORKDIR}/curl.err"
  cat "${WORKDIR}/curl.body"
}

harbor_status() { cat "${WORKDIR}/last_status" 2>/dev/null || echo 000; }

# --- discovery --------------------------------------------------------------

log "Harbor sweep starting: project=${HARBOR_PROJECT} url=${HARBOR_URL}"

# 1) list repositories (paginated)
REPO_LIST="${WORKDIR}/repos.json"
echo "[]" > "$REPO_LIST"
page=1
while true; do
  body="$(curl_harbor "projects/${HARBOR_PROJECT}/repositories?page=${page}&page_size=${PAGE_SIZE}")"
  code="$(harbor_status)"
  if [ "$code" != "200" ]; then
    log "ERROR: repo list failed page=${page} http=${code}"
    exit 1
  fi
  count="$(echo "$body" | jq 'length')"
  if [ "$count" = "0" ]; then break; fi
  jq -s '.[0] + .[1]' "$REPO_LIST" <(echo "$body") > "${REPO_LIST}.tmp"
  mv "${REPO_LIST}.tmp" "$REPO_LIST"
  if [ "$count" -lt "$PAGE_SIZE" ]; then break; fi
  page=$((page + 1))
  sleep 0.1
done

total_repos="$(jq 'length' "$REPO_LIST")"
log "Discovered ${total_repos} repositories under ${HARBOR_PROJECT}/"

# 2) for each repo, list artifacts and collect (repo, digest, tags)
#    Output lines: repo<TAB>digest<TAB>comma_separated_tags
ARTIFACTS="${WORKDIR}/artifacts.tsv"
: > "$ARTIFACTS"

# jq filter: print repo short names (name after project/) one per line
repo_short_names() {
  jq -r --arg p "${HARBOR_PROJECT}/" '.[] | .name | sub($p; "")' "$REPO_LIST"
}

while IFS= read -r repo_short; do
  [ -z "$repo_short" ] && continue
  # Harbor requires URL-encoded repo name when it contains slashes
  enc_repo="$(jq -rn --arg s "$repo_short" '$s | @uri')"
  # Harbor supports sort=-push_time to get newest first. Combined with
  # MAX_ARTIFACTS_PER_REPO, we only need one page at the cap size for
  # most repos.
  eff_page_size="$PAGE_SIZE"
  if [ "$MAX_ARTIFACTS_PER_REPO" != "0" ] && [ "$MAX_ARTIFACTS_PER_REPO" -lt "$PAGE_SIZE" ]; then
    eff_page_size="$MAX_ARTIFACTS_PER_REPO"
  fi
  page=1
  this_repo_count=0
  while true; do
    body="$(curl_harbor "projects/${HARBOR_PROJECT}/repositories/${enc_repo}/artifacts?with_tag=true&sort=-push_time&page=${page}&page_size=${eff_page_size}")"
    code="$(harbor_status)"
    if [ "$code" != "200" ]; then
      log "WARN: artifact list failed repo=${repo_short} page=${page} http=${code} — skipping repo"
      break
    fi
    count="$(echo "$body" | jq 'length')"
    if [ "$count" = "0" ]; then break; fi
    echo "$body" \
      | jq -r --arg r "$repo_short" '.[] | [$r, .digest, ((.tags // []) | map(.name) | join(","))] | @tsv' \
      >> "$ARTIFACTS"
    this_repo_count=$((this_repo_count + count))
    # Stop early if we hit the per-repo cap
    if [ "$MAX_ARTIFACTS_PER_REPO" != "0" ] && [ "$this_repo_count" -ge "$MAX_ARTIFACTS_PER_REPO" ]; then
      break
    fi
    if [ "$count" -lt "$eff_page_size" ]; then break; fi
    page=$((page + 1))
    sleep 0.1
  done
done < <(repo_short_names)

total_artifacts="$(wc -l < "$ARTIFACTS" | tr -d ' ')"
log "Discovered ${total_artifacts} artifacts across ${total_repos} repositories"

# 3) dedupe by digest — same manifest may have multiple tags
#    Pick the first tag for ArtifactName display (Trivy likes a human-readable ref).
DIGESTS="${WORKDIR}/digests.tsv"
awk -F'\t' '
  !seen[$2]++ {
    split($3, tags, ",")
    printf "%s\t%s\t%s\n", $1, $2, tags[1]
  }
' "$ARTIFACTS" > "$DIGESTS"

unique_digests="$(wc -l < "$DIGESTS" | tr -d ' ')"
log "Unique digests to scan: ${unique_digests}"

if [ "$unique_digests" = "0" ]; then
  log "No artifacts found — writing empty Trivy report shape"
  # Emit nothing (caller's has_report gate will skip upload). We return 0.
  echo '{"SchemaVersion":2,"Results":[]}' > "$OUTPUT"
  exit 0
fi

# --- scan each unique digest ------------------------------------------------

SCAN_DIR="${WORKDIR}/scans"
mkdir -p "$SCAN_DIR"

# Export Trivy registry creds once. Trivy reads these from env.
export TRIVY_USERNAME="${HARBOR_ROBOT_USER}"
export TRIVY_PASSWORD="${HARBOR_ROBOT_TOKEN}"
# Disable Trivy's own stderr color codes; keep output parseable.
export TRIVY_NO_PROGRESS=true
export TRIVY_CACHE_DIR

HARBOR_HOST="${HARBOR_URL#https://}"
HARBOR_HOST="${HARBOR_HOST#http://}"

scanned=0
failed=0
i=0
# Optional: SMOKE_LIMIT=N caps the number of digests scanned. Used only for
# local smoke testing; unset in CI.
smoke_limit="${SMOKE_LIMIT:-0}"
while IFS=$'\t' read -r repo digest first_tag; do
  i=$((i + 1))
  if [ "$smoke_limit" != "0" ] && [ "$i" -gt "$smoke_limit" ]; then
    log "SMOKE_LIMIT=${smoke_limit} reached; stopping"
    break
  fi
  # Pin to digest at scan time (tag mutation safe). Keep a human-readable
  # ArtifactName by setting --image-src remote and passing digest ref.
  image_ref="${HARBOR_HOST}/${HARBOR_PROJECT}/${repo}@${digest}"
  display_ref="${HARBOR_HOST}/${HARBOR_PROJECT}/${repo}:${first_tag:-untagged}"
  out="${SCAN_DIR}/$(printf '%s' "${repo}_${digest}" | tr '/:@' '___').json"
  log "[${i}/${unique_digests}] trivy image ${display_ref}"
  # Retry wrapper: transient Harbor/Trivy-DB issues (network blips, DB fetch
  # timeouts) cause spurious single-attempt failures. Retry up to
  # TRIVY_MAX_ATTEMPTS times with TRIVY_RETRY_SLEEP seconds between each.
  # Added by OPS-311 Fix 1; operator-authorized 2026-05-03.
  trivy_exit=1
  for _attempt in $(seq 1 "$TRIVY_MAX_ATTEMPTS"); do
    if trivy image \
          --format json \
          --severity "$SEVERITY" \
          --ignore-unfixed \
          --scanners vuln \
          --timeout "$TRIVY_TIMEOUT" \
          --cache-dir "$TRIVY_CACHE_DIR" \
          --output "$out" \
          "$image_ref" 2>>"${WORKDIR}/trivy.err"
    then
      trivy_exit=0
      break
    fi
    if [ "$_attempt" -lt "$TRIVY_MAX_ATTEMPTS" ]; then
      log "  RETRY [${_attempt}/${TRIVY_MAX_ATTEMPTS}] ${display_ref} — sleeping ${TRIVY_RETRY_SLEEP}s before attempt $((_attempt + 1))"
      sleep "$TRIVY_RETRY_SLEEP"
    fi
  done
  if [ "$trivy_exit" = "0" ]; then
    # Rewrite ArtifactName so DefectDojo shows a useful name (not just digest)
    jq --arg name "$display_ref" '.ArtifactName = $name' "$out" > "${out}.tmp" \
      && mv "${out}.tmp" "$out"
    scanned=$((scanned + 1))
  else
    failed=$((failed + 1))
    log "  FAIL (all ${TRIVY_MAX_ATTEMPTS} attempts exhausted): ${display_ref} — see trivy.err"
    rm -f "$out"
  fi
done < "$DIGESTS"

# --- merge ------------------------------------------------------------------

# Merge strategy: collect all Results[] arrays, keep top-level metadata from
# the first successful scan (SchemaVersion etc.). Preserve per-image
# ArtifactName inside each Result entry so DefectDojo can attribute findings
# to the source image.
#
# [OPS-863] SHA-stable Target rewriting:
# Trivy sets each Result's Target to the digest-based image ref
# (e.g. "harbor.../repo@sha256:abc123 (alpine 3.19.0)"). DefectDojo's
# Trivy parser uses Target as file_path in its deduplication hash code.
# Since the digest changes on every image rebuild, old findings cannot be
# matched to new ones — close_old_findings=true never fires, and stale
# findings accumulate indefinitely.
#
# Fix: rewrite Target to use the tag-based display_ref (already stored as
# ArtifactName per-image) while preserving the OS/type suffix in parens.
# Only Results whose Target contains "@sha256:" are rewritten — file-path
# targets (lang-pkgs, node-modules, etc.) are left unchanged.
#
# After this fix, the deduplication key (CVE + component + tag-based path)
# is stable across rebuilds, so reimport correctly closes findings that
# are no longer present in the current scan.
if ls "${SCAN_DIR}"/*.json >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  jq -s '
    (.[0] // {}) as $first
    | {
        SchemaVersion: ($first.SchemaVersion // 2),
        CreatedAt: ($first.CreatedAt // (now | todate)),
        ArtifactName: "harbor-sentinel-sweep",
        ArtifactType: "container_image",
        Results: (
          [ .[] as $r
            | ($r.Results // [])
            | map(. + {
                ArtifactName: $r.ArtifactName,
                Target: (
                  if (.Target | contains("@sha256:")) then
                    $r.ArtifactName + (
                      .Target | split(" (") |
                      if length > 1 then " (" + (.[1:] | join(" (")) else "" end
                    )
                  else .Target end
                )
              })
            | .[]
          ]
        )
      }
  ' "${SCAN_DIR}"/*.json > "$OUTPUT"
else
  echo '{"SchemaVersion":2,"Results":[]}' > "$OUTPUT"
fi

# Trim verbose fields before emit. DefectDojo's Trivy parser reads only a
# small subset — everything else is noise that inflates the payload past
# both DD's 100 MB hard cap and its nginx proxy timeout. Keeping this
# step in the script (not the workflow) makes the size-safety property
# robust to downstream consumers that call the script directly.
if [ "$TRIM_OUTPUT" = "1" ]; then
  jq '
    .Results = (.Results | map(
      .Vulnerabilities = ((.Vulnerabilities // []) | map({
        VulnerabilityID, PkgName, PkgID, InstalledVersion, FixedVersion,
        Severity, Title, PrimaryURL, Status, SeveritySource
      }))
    ))
  ' "$OUTPUT" > "${OUTPUT}.trim" && mv "${OUTPUT}.trim" "$OUTPUT"
fi

result_count="$(jq '.Results | length' "$OUTPUT")"
finding_count="$(jq '[.Results[].Vulnerabilities // [] | length] | add // 0' "$OUTPUT")"

log "------------------------------------------------------------"
log "Sweep complete"
log "  repositories:   ${total_repos}"
log "  artifacts:      ${total_artifacts}"
log "  unique digests: ${unique_digests}"
log "  scanned ok:     ${scanned}"
log "  failed:         ${failed}"
log "  Results[]:      ${result_count}"
log "  findings:       ${finding_count}"
log "  output:         ${OUTPUT}"
log "------------------------------------------------------------"

# Do NOT fail on per-image scan failures — partial sweep is still useful.
# Fail only if EVERY scan failed (sweep produced nothing).
if [ "$scanned" = "0" ] && [ "$unique_digests" != "0" ]; then
  log "ERROR: every scan failed — emitting empty report and exiting non-zero"
  exit 1
fi

exit 0
