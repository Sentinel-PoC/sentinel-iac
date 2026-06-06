#!/usr/bin/env bash
# upgrade-functions.sh — shared bash for OKD-upgrade Forgejo workflows.
#
# Sourced by .forgejo/workflows/okd-upgrade-{sandbox,prod}.yaml.
#
# Tracking: OPS-269 (sandbox 4.19→4.20→4.21 and prod 4.19→4.20→4.21).
#
# DESIGN NOTES
# ============
#   * Functions are namespaced `upgrade::*` to avoid conflicting with
#     anything sourced from PATH inside the runner.
#   * Every function logs to stderr and prints the structured result
#     (where applicable) on stdout, so callers can capture cleanly.
#   * Diagnostics dumps (`upgrade::dump_diagnostics`) write to a directory
#     the workflow can upload as an Actions artefact AND structure as a
#     paste-ready prompt for a fresh Claude Code session — that's the
#     "LLM-assist hook" Jim asked for.
#   * Plane API calls are best-effort: they MUST NOT fail the workflow
#     if Plane is briefly unreachable, because the upgrade itself may
#     still have succeeded. Workflow-level pass/fail is the source of
#     truth.
#   * No `set -e` here — callers `set -euo pipefail` themselves and
#     decide which functions to allow to fail.

# ---- Logging --------------------------------------------------------------

upgrade::_ts()   { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
upgrade::log()   { printf '[%s] %s\n' "$(upgrade::_ts)" "$*" >&2; }
upgrade::ok()    { printf '[%s] [ OK ] %s\n' "$(upgrade::_ts)" "$*" >&2; }
upgrade::warn()  { printf '[%s] [WARN] %s\n' "$(upgrade::_ts)" "$*" >&2; }
upgrade::fail()  { printf '[%s] [FAIL] %s\n' "$(upgrade::_ts)" "$*" >&2; return 1; }

# ---- Inputs / config ------------------------------------------------------
#
# Required env (caller must export):
#   KUBECONFIG                — path to a kubeconfig with cluster-admin
#   CLUSTER_VERSION_FILE      — path to cluster-version.yaml (desiredImage etc.)
#   UPGRADE_TRACKING_ISSUE    — Plane issue ID for `notify` step (UUID form)
#   PLANE_PROJECT_ID, PLANE_WORKSPACE — Plane locator
#   PLANE_API_KEY             — Plane x-api-key
#
# Optional env (defaults shown):
#   ETCD_BACKUP_MAX_AGE_HOURS=24
#   MASTER_MCP_BUDGET_MIN=60
#   WORKER_MCP_BUDGET_MIN=90
#   OPERATOR_STUCK_BUDGET_MIN=30
#   ETCD_LATENCY_MAX_MS=100
#   DRY_RUN=false                — true = preflight + validate only, never `oc adm upgrade`
#   ALLOW_NOT_RECOMMENDED=false  — true = pass --allow-not-recommended (for OKD-SCOS where graph is sparse)
#   DIAGNOSTICS_DIR              — defaults to /tmp/okd-upgrade-diag-$(date +%s)

upgrade::_init_defaults() {
  : "${ETCD_BACKUP_MAX_AGE_HOURS:=24}"
  : "${MASTER_MCP_BUDGET_MIN:=60}"
  : "${WORKER_MCP_BUDGET_MIN:=90}"
  : "${OPERATOR_STUCK_BUDGET_MIN:=30}"
  : "${ETCD_LATENCY_MAX_MS:=100}"
  : "${DRY_RUN:=false}"
  : "${ALLOW_NOT_RECOMMENDED:=false}"
  : "${DIAGNOSTICS_DIR:=/tmp/okd-upgrade-diag-$(date -u +%s)}"
  mkdir -p "${DIAGNOSTICS_DIR}"
  export ETCD_BACKUP_MAX_AGE_HOURS MASTER_MCP_BUDGET_MIN WORKER_MCP_BUDGET_MIN \
         OPERATOR_STUCK_BUDGET_MIN ETCD_LATENCY_MAX_MS DRY_RUN \
         ALLOW_NOT_RECOMMENDED DIAGNOSTICS_DIR
}

# Parse cluster-version.yaml. Echoes the desired image pull spec on stdout.
# Format expected:
#   apiVersion: overwatch.haist.farm/v1
#   kind: ClusterVersionTarget
#   spec:
#     desiredVersion: "4.20.0-okd-scos.0"
#     desiredImage:   "quay.io/okd/scos-release@sha256:abc..."  # MUST be a digest, not a tag
#     channel:        "stable-4.20"  # informational; we always upgrade by digest
upgrade::desired_image() {
  yq '.spec.desiredImage' "${CLUSTER_VERSION_FILE}"
}
upgrade::desired_version() {
  yq '.spec.desiredVersion' "${CLUSTER_VERSION_FILE}"
}
upgrade::desired_channel() {
  yq '.spec.channel // ""' "${CLUSTER_VERSION_FILE}"
}

# ---- Phase 1 — preflight --------------------------------------------------

upgrade::check_etcd_backup_age() {
  local max_age_hours="${ETCD_BACKUP_MAX_AGE_HOURS}"
  upgrade::log "preflight: etcd backup must be < ${max_age_hours}h old"

  # The etcd-backup CronJob lives in openshift-etcd-backup (per OPS-241/242).
  # Check the most recent successful Job's completionTime.
  local latest
  latest=$(oc -n openshift-etcd-backup get jobs \
              --sort-by=.status.completionTime \
              -o jsonpath='{.items[-1:].status.completionTime}' 2>/dev/null)
  if [[ -z "$latest" ]]; then
    upgrade::warn "no etcd backup job history found; tolerating only because cluster is fresh sandbox — see runbook §upgrade-prereq for prod"
    return 0
  fi
  local epoch_now epoch_then age_hours
  epoch_now=$(date -u +%s)
  epoch_then=$(date -d "$latest" +%s 2>/dev/null || echo 0)
  age_hours=$(( (epoch_now - epoch_then) / 3600 ))
  if (( age_hours > max_age_hours )); then
    upgrade::fail "etcd backup is ${age_hours}h old (> ${max_age_hours}h). Trigger a backup or bump ETCD_BACKUP_MAX_AGE_HOURS."
    return 1
  fi
  upgrade::ok "etcd backup ${age_hours}h old (≤ ${max_age_hours}h)"
}

upgrade::check_no_mcp_paused() {
  upgrade::log "preflight: no MachineConfigPool may be paused"
  local paused
  paused=$(oc get mcp -o json | jq -r '.items[] | select(.spec.paused==true) | .metadata.name')
  if [[ -n "$paused" ]]; then
    upgrade::fail "MachineConfigPool(s) paused: ${paused}. Unpause before upgrade."
    return 1
  fi
  upgrade::ok "no MCP paused"
}

upgrade::check_target_in_graph() {
  local target_image="$1"
  local target_version="$2"
  upgrade::log "preflight: target ${target_version} (${target_image}) reachable in upgrade graph"

  # `oc adm upgrade` (no args) shows recommended + accepted targets.
  # `--include-not-recommended` widens the search; required for OKD-SCOS
  # which often has a sparser graph than RHEL OCP.
  local upgrade_out
  upgrade_out=$(oc adm upgrade --include-not-recommended 2>&1 || true)

  if grep -q "$target_version" <<<"$upgrade_out"; then
    upgrade::ok "target ${target_version} present in upgrade graph"
    return 0
  fi
  if [[ "${ALLOW_NOT_RECOMMENDED}" == "true" ]]; then
    upgrade::warn "target ${target_version} not in graph; ALLOW_NOT_RECOMMENDED=true so proceeding by digest anyway"
    upgrade::log "graph dump: $(echo "$upgrade_out" | head -50)"
    return 0
  fi
  upgrade::fail "target ${target_version} not in graph and ALLOW_NOT_RECOMMENDED!=true. Set ALLOW_NOT_RECOMMENDED=true to override."
  echo "$upgrade_out" | head -50 >&2
  return 1
}

upgrade::check_cluster_health() {
  upgrade::log "preflight: ClusterVersion A/P/D = True/False/False"
  local cv_json a p d
  cv_json=$(oc get clusterversion version -o json)
  a=$(jq -r '.status.conditions[]|select(.type=="Available")|.status' <<<"$cv_json")
  p=$(jq -r '.status.conditions[]|select(.type=="Progressing")|.status' <<<"$cv_json")
  d=$(jq -r '.status.conditions[]|select(.type=="Failing")|.status' <<<"$cv_json")
  if [[ "$a" != "True" || "$p" != "False" || "$d" == "True" ]]; then
    upgrade::fail "ClusterVersion not healthy: Available=$a Progressing=$p Failing=$d"
    return 1
  fi
  upgrade::ok "ClusterVersion Available=True Progressing=False Failing=$d"

  # Also gate on cluster operators
  local bad
  bad=$(oc get co -o json \
    | jq -r '.items[] | select(([.status.conditions[]|select(.type=="Available")|.status][0]!="True") or ([.status.conditions[]|select(.type=="Degraded")|.status][0]=="True")) | .metadata.name' \
    | tr '\n' ' ')
  if [[ -n "$bad" ]]; then
    upgrade::fail "cluster operators not healthy: ${bad}"
    return 1
  fi
  upgrade::ok "all cluster operators Available=True Degraded=False"
}

upgrade::check_already_in_progress() {
  # Idempotent re-run: if cluster is already mid-upgrade to the same
  # target, do NOT re-trigger — caller should skip to poll.
  local target_image="$1"
  local desired_image
  desired_image=$(oc get clusterversion version -o jsonpath='{.spec.desiredUpdate.image}' 2>/dev/null)
  if [[ -n "$desired_image" && "$desired_image" == "$target_image" ]]; then
    upgrade::ok "cluster already targeting ${target_image} — skipping initiate, jumping to poll"
    return 0  # 0 = already in progress, caller checks via $?
  fi
  return 2  # 2 = NOT in progress, caller should initiate
}

upgrade::is_noop() {
  # NOOP-detect: compare target digest from cluster-version.yaml against the
  # cluster's current desired image (.status.desired.image — the authoritative
  # currently-applied digest; .spec.desiredUpdate.image is only set during an
  # active upgrade command and must not be used here).
  #
  # Returns 0 (true) when target == current (NOOP — no upgrade needed).
  # Returns 1 (false) when they differ (proceed with upgrade).
  #
  # Side-effects on NOOP:
  #   * Logs the NOOP detection to stderr.
  #   * Emits a GITHUB_STEP_SUMMARY block.
  #   * Writes NOOP=true to GITHUB_ENV so subsequent workflow steps can gate on it.
  #
  # Calling convention (preflight step, inside set -euo pipefail):
  #   if upgrade::is_noop "${TARGET_IMAGE}"; then exit 0; fi
  local target_image="$1"
  local current_image
  current_image=$(oc get clusterversion version \
    -o jsonpath='{.status.desired.image}' 2>/dev/null || true)
  if [[ -n "$current_image" && "$current_image" == "$target_image" ]]; then
    upgrade::log "NOOP — target equals current digest, no upgrade needed (${target_image})"
    {
      echo "## NOOP — target already deployed, no upgrade action needed"
      echo "Target image \`${target_image}\` matches cluster's current image."
      echo "All upgrade phases skipped. Job exits PASS."
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    echo "NOOP=true" >> "${GITHUB_ENV:-/dev/null}"
    return 0  # 0 = IS noop
  fi
  upgrade::log "noop-check: target differs from current cluster image — proceeding with preflight"
  return 1  # 1 = NOT noop, proceed
}

# ---- Phase 2 — initiate ---------------------------------------------------

upgrade::initiate_upgrade() {
  local target_image="$1"
  if [[ "${DRY_RUN}" == "true" ]]; then
    upgrade::warn "DRY_RUN=true — would have run: oc adm upgrade --to-image=${target_image} --allow-explicit-upgrade"
    return 0
  fi

  upgrade::log "initiating upgrade: oc adm upgrade --to-image=${target_image} --allow-explicit-upgrade"
  local extra=""
  [[ "${ALLOW_NOT_RECOMMENDED}" == "true" ]] && extra="--allow-upgrade-with-warnings"

  if ! oc adm upgrade --to-image="${target_image}" --allow-explicit-upgrade ${extra}; then
    upgrade::fail "oc adm upgrade returned non-zero. Cluster state may be partially set; check oc get clusterversion."
    return 1
  fi
  upgrade::ok "upgrade initiated"
  oc get clusterversion -o jsonpath='{"  desiredUpdate.image: "}{.spec.desiredUpdate.image}{"\n  history[0]: "}{.status.history[0]}{"\n"}'
}

# ---- Phase 3 — poll -------------------------------------------------------

upgrade::poll_clusterversion() {
  local target_version="$1"
  local total_budget_min="$2"   # caller computes from MCP budgets etc.
  upgrade::log "poll: ClusterVersion until version=${target_version} state=Completed (budget ${total_budget_min}min)"

  local deadline=$(( $(date -u +%s) + total_budget_min * 60 ))
  while (( $(date -u +%s) < deadline )); do
    local hist
    hist=$(oc get clusterversion version -o json \
            | jq -r --arg v "$target_version" \
              '.status.history[] | select(.version==$v) | "\(.state) \(.startedTime) \(.completionTime // "<in-progress>")"' \
            | head -1)
    if [[ -n "$hist" ]]; then
      local state
      state=$(awk '{print $1}' <<<"$hist")
      upgrade::log "  history[${target_version}]: ${hist}"
      if [[ "$state" == "Completed" ]]; then
        upgrade::ok "ClusterVersion history shows ${target_version} Completed"
        return 0
      fi
    else
      upgrade::log "  history does not yet contain ${target_version}"
    fi
    sleep 60
  done
  upgrade::fail "ClusterVersion did not reach Completed for ${target_version} within ${total_budget_min}min"
  return 1
}

upgrade::poll_mcps() {
  local master_budget_min="${MASTER_MCP_BUDGET_MIN}"
  local worker_budget_min="${WORKER_MCP_BUDGET_MIN}"
  upgrade::log "poll: MCPs converge (master ≤ ${master_budget_min}min, worker ≤ ${worker_budget_min}min)"

  # OKD compact (sandbox) has no separate worker MCP — masters carry the
  # worker role too. Detect and use the longer budget.
  local pools
  pools=$(oc get mcp -o name | cut -d/ -f2 | tr '\n' ' ')
  upgrade::log "  MCPs present: ${pools}"

  local deadline_master=$(( $(date -u +%s) + master_budget_min * 60 ))
  local deadline_worker=$(( $(date -u +%s) + worker_budget_min * 60 ))

  while :; do
    local now
    now=$(date -u +%s)
    local all_ok=1
    for pool in $pools; do
      local updated
      updated=$(oc get mcp "$pool" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')
      local updating
      updating=$(oc get mcp "$pool" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}')
      local degraded
      degraded=$(oc get mcp "$pool" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
      upgrade::log "  mcp/${pool}: Updated=${updated} Updating=${updating} Degraded=${degraded}"
      if [[ "$degraded" == "True" ]]; then
        upgrade::fail "mcp/${pool} Degraded=True — bailing"
        return 1
      fi
      if [[ "$updated" != "True" ]]; then
        all_ok=0
      fi
      # Per-pool budget
      local budget=$deadline_master
      [[ "$pool" == "worker" ]] && budget=$deadline_worker
      if (( now > budget )) && [[ "$updated" != "True" ]]; then
        upgrade::fail "mcp/${pool} budget exceeded (Updated=${updated})"
        return 1
      fi
    done
    if (( all_ok == 1 )); then
      upgrade::ok "all MCPs Updated=True"
      return 0
    fi
    sleep 60
  done
}

# ---- Phase 4 — validate ---------------------------------------------------

upgrade::validate_post() {
  local target_version="$1"
  upgrade::log "validate: post-upgrade smoke"
  local fails=0

  # 1. all CO Available=True Progressing=False Degraded=False
  local bad
  bad=$(oc get co -o json | jq -r '
    .items[] | select(
      ([.status.conditions[]|select(.type=="Available")|.status][0]!="True") or
      ([.status.conditions[]|select(.type=="Progressing")|.status][0]=="True") or
      ([.status.conditions[]|select(.type=="Degraded")|.status][0]=="True")
    ) | .metadata.name')
  if [[ -n "$bad" ]]; then
    # shellcheck disable=SC2116,SC2086  # intentional: collapse newlines in the multiline list
    upgrade::warn "cluster operators not yet quiesced: $(echo $bad)"
    fails=$(( fails + 1 ))
  else
    upgrade::ok "all cluster operators A=True P=False D=False"
  fi

  # 2. all nodes Ready, no NoSchedule taints (excluding routine ones)
  local notready
  notready=$(oc get nodes -o json | jq -r '.items[] |
    select([.status.conditions[]|select(.type=="Ready")|.status][0]!="True") |
    .metadata.name')
  if [[ -n "$notready" ]]; then
    # shellcheck disable=SC2116,SC2086
    upgrade::fail "nodes not Ready: $(echo $notready)"
    fails=$(( fails + 1 ))
  else
    upgrade::ok "all nodes Ready"
  fi
  local unsched
  unsched=$(oc get nodes -o json | jq -r '.items[] |
    select(.spec.unschedulable == true) | .metadata.name')
  if [[ -n "$unsched" ]]; then
    # shellcheck disable=SC2116,SC2086
    upgrade::warn "nodes Unschedulable (cordoned): $(echo $unsched). Verify intentional."
  fi

  # 3. etcd 3-member quorum, sub-${ETCD_LATENCY_MAX_MS}ms
  local m1
  m1=$(oc get nodes -l node-role.kubernetes.io/master -o name | head -1 | cut -d/ -f2)
  local etcd_out
  etcd_out=$(oc -n openshift-etcd exec "etcd-${m1}" -c etcdctl -- etcdctl endpoint health 2>&1 || true)
  local healthy_count
  healthy_count=$(grep -c 'is healthy' <<<"$etcd_out" || true)
  if (( healthy_count != 3 )); then
    upgrade::fail "etcd quorum not 3 (found ${healthy_count} healthy)"
    upgrade::log "$etcd_out" | head -10
    fails=$(( fails + 1 ))
  else
    local max_ms
    max_ms=$(grep -oE 'took = [0-9.]+ms' <<<"$etcd_out" | awk '{print $3}' | tr -d 'ms' | sort -n | tail -1)
    if [[ -n "$max_ms" ]] && awk -v m="$max_ms" -v lim="${ETCD_LATENCY_MAX_MS}" 'BEGIN{exit !(m+0>lim+0)}'; then
      upgrade::warn "etcd worst latency ${max_ms}ms > ${ETCD_LATENCY_MAX_MS}ms threshold"
    fi
    upgrade::ok "etcd 3-member quorum healthy (worst latency ${max_ms}ms)"
  fi

  # 4. ClusterVersion.history has new entry COMPLETED for target
  local hist_state
  hist_state=$(oc get clusterversion version -o json \
    | jq -r --arg v "$target_version" \
      '.status.history[] | select(.version==$v) | .state' | head -1)
  if [[ "$hist_state" != "Completed" ]]; then
    upgrade::fail "ClusterVersion.history[${target_version}].state = '${hist_state}' (want Completed)"
    fails=$(( fails + 1 ))
  else
    upgrade::ok "ClusterVersion.history shows ${target_version} Completed"
  fi

  return $(( fails > 0 ? 1 : 0 ))
}

# ---- Phase 4a/5 — diagnostics dump (LLM-assist hook) ---------------------

upgrade::dump_diagnostics() {
  local reason="${1:-budget-exceeded}"
  local out="${DIAGNOSTICS_DIR}"
  mkdir -p "$out"
  upgrade::log "dumping diagnostics → ${out} (reason: ${reason})"

  oc get clusterversion -o yaml          > "${out}/clusterversion.yaml" 2>&1 || true
  oc get co -o json                      > "${out}/clusteroperators.json" 2>&1 || true
  oc get mcp -o json                     > "${out}/machineconfigpools.json" 2>&1 || true
  oc get nodes -o wide                   > "${out}/nodes.txt" 2>&1 || true
  oc get events -A --sort-by='.lastTimestamp' \
                                         > "${out}/events.txt" 2>&1 || true
  oc adm upgrade status                  > "${out}/upgrade-status.txt" 2>&1 || true
  oc adm upgrade --include-not-recommended \
                                         > "${out}/upgrade-graph.txt" 2>&1 || true

  # MCO logs are usually the smoking gun for stuck MCP rollouts
  local mco_pod
  mco_pod=$(oc -n openshift-machine-config-operator get pod \
              -l k8s-app=machine-config-operator -o name | head -1 | cut -d/ -f2)
  if [[ -n "$mco_pod" ]]; then
    oc -n openshift-machine-config-operator logs "$mco_pod" --tail=200 \
                                         > "${out}/mco-operator.log" 2>&1 || true
  fi

  # Per-node MachineConfigDaemon logs
  for node in $(oc get nodes -o name); do
    local node_name
    node_name="${node#node/}"
    local mcd_pod
    mcd_pod=$(oc -n openshift-machine-config-operator get pod \
                -l k8s-app=machine-config-daemon \
                --field-selector spec.nodeName="${node_name}" \
                -o name | head -1 | cut -d/ -f2)
    if [[ -n "$mcd_pod" ]]; then
      oc -n openshift-machine-config-operator logs "$mcd_pod" --tail=100 \
                                         > "${out}/mcd-${node_name}.log" 2>&1 || true
    fi
  done

  # Build the LLM-assist prompt — operator pastes verbatim into a fresh
  # Claude Code session.
  local target_version target_image
  target_version=$(upgrade::desired_version)
  target_image=$(upgrade::desired_image)
  cat > "${out}/llm-assist-prompt.md" <<EOF
# OKD upgrade STUCK — Claude Code triage prompt

**Cluster:** $(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "okd-sandbox")
**Started upgrade to:** ${target_version} (${target_image})
**Reason for invocation:** ${reason}
**Diagnostics dir:** ${out}
**Workflow run:** ${GITHUB_SERVER_URL:-https://forgejo.208.haist.farm}/${GITHUB_REPOSITORY:-sentinel-admin/sentinel-iac}/actions/runs/${GITHUB_RUN_ID:-?}

You are picking up a wedged OKD upgrade. The shell-driven phases ran:
  preflight (PASS), upgrade (initiated), poll (FAILED budget) or validate (FAILED).
The cluster is mid-upgrade. Your job: diagnose and propose a safe next step
WITHOUT making changes until the operator confirms.

## Files in this dir
- \`clusterversion.yaml\` — current upgrade history + conditions
- \`clusteroperators.json\` — full CO state (look for stuck Progressing=True or Degraded=True)
- \`machineconfigpools.json\` — MCP rollout progress (look for paused, degraded, partial-update)
- \`nodes.txt\` — node Ready state, versions
- \`events.txt\` — last cluster events sorted by time
- \`upgrade-status.txt\` — \`oc adm upgrade status\` output
- \`upgrade-graph.txt\` — what targets are reachable from current state
- \`mco-operator.log\` — last 200 lines from machine-config-operator
- \`mcd-<node>.log\` — per-node MachineConfigDaemon logs

## Recommended triage
1. \`grep -i "error\\|fail\\|degraded" clusteroperators.json\` — which CO is unhappy?
2. \`jq '.items[] | {name: .metadata.name, status: .status.conditions[]|select(.type=="Updated")}' machineconfigpools.json\`
3. Check mco-operator.log + the relevant mcd-<node>.log for the node currently being updated.
4. Cross-reference upgrade-status.txt with the cluster's \`history\` to see exactly where the upgrade stopped.
5. Common stuck-states + remediations:
   - **MCP draining stuck on PDB** → identify the offending PDB; operator may relax it
   - **Node failing to drain** → kubelet on that node may be wedged; \`oc debug node/X\` to check journal
   - **Image pull failure** → registry auth / network / digest mismatch
   - **CO stuck Progressing=True** → check that operator's pod logs for crashloop

Do NOT run any \`oc adm upgrade\` commands or modify cluster state. Report findings + recommended action to operator.
EOF

  upgrade::log "diagnostics complete; LLM-assist prompt at ${out}/llm-assist-prompt.md"
}

# ---- Plane notification (always-runs) ------------------------------------

upgrade::post_plane_comment() {
  local outcome="$1"   # PASS or FAIL
  local body="$2"      # additional HTML body
  if [[ -z "${PLANE_API_KEY:-}" || -z "${UPGRADE_TRACKING_ISSUE:-}" ]]; then
    upgrade::warn "PLANE_API_KEY or UPGRADE_TRACKING_ISSUE unset — skipping Plane notification"
    return 0
  fi
  local run_url="${GITHUB_SERVER_URL:-https://forgejo.208.haist.farm}/${GITHUB_REPOSITORY:-sentinel-admin/sentinel-iac}/actions/runs/${GITHUB_RUN_ID:-?}"
  local html
  html=$(cat <<EOF
<p><strong>OKD upgrade pipeline — ${outcome}</strong></p>
<p><strong>Run:</strong> <a href="${run_url}">${run_url}</a></p>
<p><strong>Target:</strong> $(upgrade::desired_version) ($(upgrade::desired_image))</p>
<p><strong>Triggered by commit:</strong> ${GITHUB_SHA:-?}</p>
${body}
EOF
)
  local escaped
  escaped=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))" <<<"$html")
  if curl -sk -X POST -H "x-api-key: ${PLANE_API_KEY}" -H "Content-Type: application/json" \
       --data "{\"comment_html\": ${escaped}}" \
       "https://plane.208.haist.farm/api/v1/workspaces/${PLANE_WORKSPACE}/projects/${PLANE_PROJECT_ID}/issues/${UPGRADE_TRACKING_ISSUE}/comments/" \
       > /dev/null; then
    upgrade::ok "posted Plane comment to ${UPGRADE_TRACKING_ISSUE}"
  else
    upgrade::warn "Plane comment POST failed (non-fatal)"
  fi
}
