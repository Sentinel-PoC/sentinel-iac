# Power-Incident Post-Mortem — 2026-04-27

| Field | Value |
|---|---|
| Incident ID | HAIST-22 |
| Date | 2026-04-27 |
| Author | post-mortem agent (Claude opus 4.7), under operator authorization |
| Classification | Multi-service unplanned outage |
| Severity | Major — Plane (issue tracker), Harbor (registry), Matrix, Langfuse, ArgoCD admission path |
| NIST control families exercised | IR-4, IR-5, AU-6, AU-12, SI-7, CP-2, CM-3 |
| Source ledger | `~/recovery-ledger/2026-04-27-power-incident/` (PLAN, CHANGE-001, CHANGE-002, RESEARCH-air-gapped-fail-secure, RESEARCH-okd-upgrade) |

---

## 1. Incident Summary

A power loss to PVE node `pve1` (192.168.12.6) caused a brief network blip on the OKD cluster's air-gapped storage path; iSCSI sessions reconnected cleanly but kubelet's existing XFS mounts on `master-3` had shut down on metadata I/O errors. Postgres-backed services (Plane, Harbor, Matrix, Langfuse) wedged in `CreateContainerError`. Harbor's outage caused Kyverno's `verify-image-signatures` ClusterPolicy to fail closed against an unreachable registry, blocking all new pod admission cluster-wide. Recovery required umounting wedged volumes on master-3 and temporarily relaxing the Kyverno policy from Enforce to Audit to break the death-spiral. Total impact window: roughly two hours, ending ~21:30Z when pods stabilized.

## 2. Timeline (UTC)

All times 2026-04-27 unless stated. Timestamps marked "approx" are derived from ledger files; precise stamps come from `dmesg`, Kyverno status, and the recovery ledger.

| Time (UTC) | Event | Source |
|---|---|---|
| ~19:36 | Power loss on `pve1`. Hosted: master-1, iac-control, pangolin. | Operator account, ledger PLAN |
| 19:37:32–19:37:42 | Brief I/O error burst on master-3 `sdf` (iSCSI LUN backing `okd-plane-pg`). XFS shuts down on metadata errors on 4 LUNs (sdb langfuse-ch, sde harbor-pg, sdg matrix-pg, sdi plane-pg). | dmesg / PLAN.md §"Incident summary" |
| 19:38:12 | Kyverno `verify-image-signatures` ClusterPolicy last reconciles `Ready=True` (last status transition before the incident). | CHANGE-002-kyverno-before.yaml line 344 |
| ~19:40 | iSCSI sessions reconnect cleanly (LOGGED_IN, digest_err=0, timeout_err=0). LUN block devices show `State: running`. Kubelet mount entries remain wedged: `lstat .../kubernetes.io~iscsi/...: input/output error`. | PLAN.md |
| ~20:00 | Power restored to pve1. master-1, iac-control, pangolin boot. Cluster network path restored. Application admission still failing because Harbor postgres pod is wedged → Harbor `/v2/` returns 503 → Kyverno admission denies every new pod cluster-wide. | Operator account |
| ~20:55 | Operator notices ntfy alerts ("all services down"). Manual triage begins. Operator engages agent. Agent initially misreads `oc get pod` AGE field and asserts "Plane has been down for 2 days." Operator corrects: services were healthy until the power event tonight. | Operator account, agent self-report (logged in §7) |
| ~21:00 | PLAN posted (`recovery-ledger/2026-04-27-power-incident/PLAN.md`). Hypothesis: kubelet has stale wedged mount references; lazy-umount + reconcile will clear them. CORRECTION at 21:05Z expanded scope from 2 to 4 wedged LUNs (8 mountpoints). | PLAN.md headers + correction block |
| ~21:05 | CHANGE-001 — agent mounted `/dev/sdi` at `/tmp/fix-pg` on master-3 host and chowned the mount root to `70:70 mode 700` to match the postgres image's UID expectation. Operator-authorized "option B." Ultimately turned out to be irrelevant to the recovery (see §5). | CHANGE-001-plane-pg-chown.md |
| ~21:18 | CHANGE-002 — `oc patch cpol verify-image-signatures --type merge -p '{"spec":{"failureAction":"Audit"}}'`. Operator authorization: "bypass kyverno then work on restoring harbor." Pre-state YAML captured (CHANGE-002-kyverno-before.yaml). | CHANGE-002-kyverno-audit.md |
| ~21:18–21:25 | Eight lazy umounts on master-3 (`umount -l` against the four wedged plugin-global + four pod-bind mountpoints). Kubelet volume-manager reconciles and remounts; XFS journals replay cleanly. | PLAN.md "Order of operations" |
| ~21:30 | Pods (`plane-postgresql-*`, `harbor-database-*`, `matrix-postgresql-*`, `langfuse-clickhouse-*`) advance from `CreateContainerError` to `Running`. Harbor `/v2/` returns 200. Plane API HTTP 500 → 200. | PLAN.md "Expected control-delta evidence" |
| post-recovery | ArgoCD reconciled the Kyverno ClusterPolicy back to `failureAction: Enforce` automatically once the manifest in git diverged from cluster state. No human reversal required. | Observed; not separately captured in the ledger as a discrete CHANGE |

Total incident duration (power loss → stable): ≈ 2 hours. Time from operator detection to first stabilizing change: ≈ 23 minutes. Time from first change to full restoration: ≈ 30 minutes.

## 3. Root Cause Analysis (5-Whys)

The incident has two converging causal chains: a storage-path chain triggered by power loss, and an admission-control chain that turned a recoverable storage outage into a cluster-wide death-spiral.

### Chain A — storage path

1. **Why did Plane go down?** The `plane-postgresql` pod was stuck in `CreateContainerError` because its iSCSI-backed PVC mount on master-3 was returning `EIO` on every `lstat`.
2. **Why was the mount returning EIO?** XFS on `/dev/sdi` had shut down following metadata I/O errors during the network blip at 19:37:32–19:37:42Z. Once XFS shuts down, every subsequent operation on the mount returns `EIO` until it is unmounted and remounted (which replays the journal).
3. **Why was there a network blip on master-3 (which did not lose power)?** The OKD cluster network is air-gapped and routes to TrueNAS through `iac-control` as a single gateway. `iac-control` was on `pve1`, which lost power; while it was down, master-2 and master-3 had no path to the iSCSI target.
4. **Why does that single gateway exist?** Architectural choice. `iac-control` was provisioned as the sole network bridge between the OKD inner network and the storage/management network. It was never made HA.
5. **Why was no HA designed in?** Not captured in any retrievable design document. The SPOF is acknowledged retroactively in `docs/iac-control-spof-assessment.md`; the original rationale is absent from the audit trail.

### Chain B — admission-control death-spiral

1. **Why couldn't the cluster self-heal?** Harbor's `/v2/` was returning 503 (its own postgres was wedged via the same mechanism as Plane's). Kyverno's `verify-image-signatures` ClusterPolicy could not fetch image signatures from Harbor, and was configured `failureAction: Enforce`.
2. **Why did Harbor being down block recovery of unrelated pods?** Kyverno's `verifyImages` rule runs at admission. With Harbor unreachable and `failureAction: Enforce`, the admission decision is "deny." Every new Pod creation cluster-wide failed admission, including the pods needed to bring Harbor's database back.
3. **Why was signature verification at admission instead of at image pull?** The cluster uses a custom Kyverno-based `verifyImages` ClusterPolicy rather than OKD's documented `ClusterImagePolicy` (cri-o pull-time) pattern that has been GA since OCP 4.13.
4. **Why was the documented pattern not used?** Background context (per `RESEARCH-air-gapped-fail-secure.md`): the cluster predates first-class OKD/cri-o sigstore support being widely-known operator knowledge, and Kyverno was already in place for other supply-chain policies. The decision to keep cryptographic verification in Kyverno was never re-evaluated against the death-spiral risk.
5. **Why does the policy fail closed against the registry it depends on?** The Kyverno annotation states `failurePolicy: Ignore` was chosen for the *webhook* (so Kyverno being unhealthy doesn't block admission), but `validationFailureAction: Enforce` is unconditional — i.e. a *successful* admission evaluation that finds "no signature reachable because registry returned 503" is treated as a failure-to-validate. There is no carve-out for "registry temporarily unreachable."

**Combined root cause statement:** A single power-domain event on `pve1` exposed two independent design flaws: (a) `iac-control` is a non-HA SPOF on the cluster's storage path; (b) cluster-wide admission depends on a registry that itself runs on the cluster, with no documented failure mode for "registry unreachable but signature policy still wants to run."

## 4. Detection

- **Trigger of detection:** Operator received ntfy alerts after power was restored. The alerts indicated "all services down" without further granularity. The operator's first awareness was via the ntfy push, not via a structured monitoring dashboard.
- **Time-to-detect (event → first human action):** Approximately 1 hour 20 minutes (19:37Z storage event → ~20:55Z operator engagement). The actual power-loss event itself was likely earlier; ntfy's alert cadence and operator availability extended the gap.
- **Monitoring gaps exposed:**
  - ntfy notifications grouped multi-service failure into a single "everything is down" signal. They did not distinguish "33% of OKD ingress paths are failing" from "all of OKD is failing." This delayed correct triage.
  - No dedicated alert fired for the upstream condition (UPS state, pve1 power loss). The first observable signal was downstream service failure.
  - No alert distinguished "Kyverno admission denying due to registry-unreachable" from generic pod-creation failure. The agent had to reason backward from `kubectl describe pod` output to identify the admission denial.
  - Pod-creation events on the cluster were not surfaced via push monitoring at all; they had to be queried interactively.

## 5. Response Actions

Each action is logged with timestamp, attribution (operator/agent), and outcome.

- **~20:55Z — Operator: detection and triage.** Operator notices ntfy alerts, opens session with agent, provides initial context (power blip on pve1, services down). [Successful — engaged the response.]
- **~20:55Z — Agent: cluster survey.** Agent queried `oc get pods -A`, dmesg on master nodes, iSCSI session state on master-3.
  - **Misstep — agent initially asserted "Plane has been down for 2 days."** Cause: agent misread the pod `AGE` column (`AGE` of the *current* CreateContainerError pod reflected the time since the most recent re-attempt, which combined with a misread of the controller's older pod history led to a "2 days" claim). Operator corrected: services were healthy until the power event. Agent acknowledged the correction and re-grounded on the dmesg I/O-error timestamps (19:37:32–42Z) as the authoritative event start. This correction was the first time in the session the agent's model of incident scope diverged from reality and was pulled back by the operator.
  - **Misstep — agent did not check pod-creation events early.** Had `oc get events --sort-by .lastTimestamp` been one of the first commands, the Kyverno admission denial cascade would have been visible immediately. The agent surfaced the Kyverno path only after the chown experiment (CHANGE-001) failed to revive Plane's pod, costing ~10 minutes.
- **~21:00Z — Agent: PLAN posted to `recovery-ledger/2026-04-27-power-incident/PLAN.md`.** Hypothesis: stale wedged kubelet mounts; lazy-umount will clear them. Operator-authorized.
- **~21:05Z — Agent (operator-authorized "option B"): CHANGE-001 — chown of `/dev/sdi` mount root.**
  - Action: Mounted `/dev/sdi` RW at `/tmp/fix-pg` on master-3 host. `chown 70:70 /tmp/fix-pg/`, `chmod 700 /tmp/fix-pg/`. Mount root only — not recursive. No data files modified.
  - **This change turned out to be unnecessary for the recovery.** The Alpine postgres image runs as UID 70, but the pod's SCC is `anyuid` and the container had `DAC_OVERRIDE`, meaning the original `root:root mode 755` mount root would not have blocked the postgres entrypoint from `mkdir -p .../pgdata` once the mount itself was healthy. The agent did not verify the SCC and capabilities before proposing the chown. Operator authorized the change as low-risk (mount-root permission only, easily reversible). The chown is preserved on disk; not reversed because (a) it has no functional impact on the running postgres, (b) reverting requires another offline mount and the cost-benefit does not justify it.
  - Outcome: did not directly contribute to recovery; preserved as a documented but irrelevant change.
- **~21:05Z — Agent: CORRECTION block appended to PLAN.md.** Inspection found 4 wedged iSCSI mountpoints, not 2 (added langfuse-ch and matrix-pg to the original harbor-pg + plane-pg pair). Eight umounts total (plugin-global + pod-bind per LUN).
- **~21:18Z — Agent (operator-authorized): CHANGE-002 — Kyverno `verify-image-signatures` Enforce → Audit.**
  - Action: `oc patch cpol verify-image-signatures --type merge -p '{"spec":{"failureAction":"Audit"}}'`. Pre-state YAML captured to `CHANGE-002-kyverno-before.yaml`.
  - Justification: break the deadlock — Harbor's pods cannot be admitted because Kyverno cannot fetch their signatures from Harbor itself. Audit mode preserves the audit trail (Kyverno still logs the violations) without blocking pod creation.
  - Time-bounded: reverted to Enforce post-recovery (see ArgoCD note below).
- **~21:18–21:25Z — Agent: eight lazy umounts on master-3 host.** `umount -l` against the four plugin-global mountpoints and the four pod-bind mountpoints for the wedged LUNs. Kubelet volume-manager reconciles within ~60–90s; XFS remounts and replays journals.
- **~21:30Z — Recovery confirmation.**
  - `oc get pod plane-postgresql-*` → `Running`.
  - `oc get pod harbor-database-*` → `Running`.
  - `curl https://harbor.208.haist.farm/v2/` → 200.
  - Plane API → 200.
  - dmesg on master-3: no new I/O errors.
- **post-recovery — ArgoCD: automatic reversal of CHANGE-002.** ArgoCD detected the cluster-state divergence from the git manifest (which has `failureAction: Enforce`) and reconciled back. No manual `oc patch` required. The audit window was short and operator-authorized.
- **Operator pacing interventions during the response.** The operator pulled the agent back twice with "stop and ask before more changes" — once before CHANGE-001 was elaborated, once when the agent considered restarting kubelet on master-3 (which was discussed as a fallback in PLAN.md but not executed because the umount path worked). These interventions were correct; the framework's slowness is the point.

## 6. What Went Well

- **ArgoCD automatically restored the Kyverno policy to Enforce** when Harbor recovered. The agent did not need to remember to revert the temporary loosening; declarative reconciliation handled it. This is the intended fail-safe shape of GitOps for security policy.
- **The bedrock recovery path (PVE root + qm guest exec, and direct host SSH to master-3 via `core@10.0.0.223`) stayed available** throughout the incident. The recovery did not depend on Kubernetes admission being functional. Reference: `MEMORY.md` → `reference_pve_qemu_access.md`.
- **Vault never went down.** Secrets, including the Plane API key needed for retroactive issue creation, remained available. The Vault tier was correctly architected outside the OKD cluster's failure domain.
- **The recovery-ledger pattern produced a clean audit trail despite Plane being the broken thing.** The PLAN.md → CHANGE-NNN-*.md → CORRECTION-block convention captured pre-state, action, expected control delta, and reversal procedure for every change while the issue tracker itself was unavailable. The retroactive HAIST-22 issue (and this post-mortem) reconstruct the audit chain without invented detail.
- **Lazy umount + kubelet reconcile worked exactly as hypothesized.** `umount -l` does not modify on-disk state; the recovery was reversible up to the moment kubelet remounted, which itself is non-destructive. The operator-authorized risk envelope was respected.

## 7. What Went Poorly

- **The agent went deep on the chown theory before checking SCC and container capabilities.** A 30-second `oc get pod plane-postgresql-* -o yaml | grep -A5 securityContext` and `oc describe scc anyuid` would have shown that the postgres container had effective root + `DAC_OVERRIDE` and could not have been blocked by mount-root permissions. The agent skipped that check and authored CHANGE-001 against a hypothesis it had not falsified. Operator-authorized "option B" approved the change in good faith based on the agent's framing.
- **The agent missed checking pod-creation events early.** `oc get events -A --sort-by .lastTimestamp | grep -i kyverno` would have surfaced the admission denial cascade in the first minute. The Kyverno path was identified later than it should have been.
- **Initial cluster surveys included guessed IP addresses.** The agent referenced node IPs the operator had to correct. The agent should have queried `oc get node -o wide` before naming any IP.
- **The "2 days down" misread of pod AGE.** Documented in §5. The agent stated a confident incorrect claim about incident duration before grounding on dmesg. The recovery proceeded correctly only because the operator pushed back; in a less-supervised session this could have driven hours of misdirected work.
- **Pace was sometimes too fast.** The operator pulled the agent back twice with "stop and ask before more changes." The CLAUDE.md framework's slowness is intentional and the agent under-respected it.
- **No runbook existed for this scenario.** The agent reasoned from first principles. While the reasoning produced a correct outcome, a runbook for "post-power-event iSCSI/XFS wedge on master-3" or "registry unreachable + admission cascade" would have shortened detection-to-resolution by an hour or more.

## 8. Lessons Learned and Action Items

Each item is tracked in Plane.

- **Move signature crypto from Kyverno admission to `ClusterImagePolicy` (cri-o pull-time).** The cri-o path stores the public key on local disk via MCO, has no Harbor dependency at admission time, and fails per-pod (not cluster-wide) on legitimate signature failures. Tracked in **OPS-147** (signature-verification migration plan), **OPS-149** (implementation), grouped under MW1.
- **Stand up an out-of-band registry mirror** (`mirror-registry` on a non-OKD VM) so platform images don't depend on the cluster being healthy. Combined with `ImageDigestMirrorSet` listing Harbor first, off-cluster mirror second, `mirrorSourcePolicy: NeverContactSource`. Tracked in **OPS-148** (mirror-registry standup) and **OPS-150** (IDMS rollout). MW1.
- **Eliminate `iac-control` as the OKD network SPOF.** HA the gateway role; or move the OKD storage path off the iac-control-mediated network entirely. Tracked in **OPS-157**. Reference: `docs/iac-control-spof-assessment.md`.
- **Migrate iSCSI from in-tree inline volumes to a CSI driver** (democratic-csi for TrueNAS). Inline iSCSI couples the volume to the node and gives kubelet no clean attach/detach semantic on network blip. CSI decouples the volume lifecycle. Tracked in **OPS-151**. MW2; also a prerequisite for the OKD 4.20 upgrade per `RESEARCH-okd-upgrade.md` §6.
- **Improve monitoring granularity.** ntfy alerts must distinguish "OKD ingress N% failure" from "all of OKD is failing"; UPS / power-domain state should fire its own alert ahead of downstream service failures; pod-creation event abnormalities should surface to push-channel. Tracked in **OPS-158** (open: monitoring-granularity review).
- **Build a runbook for "incident under multi-agent framework when Plane itself is the outage."** The recovery-ledger pattern worked but was reinvented mid-incident. A runbook codifying it (filesystem layout, retroactive Plane-issue creation, ArgoCD as reconciliation safety net) shortens future responses. Tracked in **OPS-159** (open: post-power-outage runbook + Plane-down playbook).
- **Codify the agent missteps in the operator playbook.** Specifically: "always check pod events and SCC before authoring file-system changes," "always ground incident timing in dmesg/audit timestamps before claiming duration," and "the agent's pacing instinct is faster than the framework requires — operator pacing interventions are correct." Tracked in **OPS-160** (open: agent-framework lessons-learned codification).

## 9. NIST 800-53 Control Mapping

| Control | Status during incident | Notes |
|---|---|---|
| **IR-4 (Incident Handling)** | Exercised | Operator + agent collaboration produced documented PLAN, two CHANGE artifacts with pre/post evidence, and structured corrections. Deviations from plan (CORRECTION block expanding scope from 2 to 4 LUNs) were captured in-line. |
| **IR-5 (Incident Monitoring)** | Partially failed | ntfy alerts fired but lacked granularity to differentiate partial-failure modes. Time-to-detect was 1h20m; goal should be <15m for total-cluster impact. Action item: OPS-158. |
| **AU-6 (Audit Review)** | Worked via the recovery-ledger pattern | The on-disk PLAN.md / CHANGE-NNN.md ledger preserved structured pre/post evidence even with the issue tracker (Plane) itself unavailable. Rule of thumb established: always log structured pre/post evidence to filesystem-local ledger when the issue tracker is the broken thing. |
| **AU-12 (Audit Record Generation)** | Worked | dmesg, oc events, Kyverno status, iSCSI session state, mount tables, and the ledger's command captures all generated audit records with UTC timestamps. CHANGE-002-kyverno-before.yaml is a complete pre-patch snapshot. |
| **SI-7 (Software/Firmware Integrity)** | Failure mode revealed | The verify-image-signatures Enforce-against-unreachable-registry produced a fail-closed cascade. Recommendation: move cryptographic verification to `ClusterImagePolicy` (cri-o pull-time, fails per-pod on real signature failure, does not fail-closed cluster-wide on registry unreachability). Audit-mode loosening during recovery was time-bounded and operator-authorized; preserved Kyverno's logging path so no audit record was lost. Action items: OPS-147, OPS-149, OPS-148, OPS-150. |
| **CP-2 (Contingency Plan)** | Inadequate | No runbook existed for "registry-down" or "post-power-event iSCSI wedge" scenarios. Recovery succeeded by reasoning from first principles, which is not a contingency plan. Action item: OPS-159. |
| **CM-3 (Configuration Change Control)** | Operated under exception | CLAUDE.md §1 hard gate option (B) was invoked (operator authorized "fix Plane first" as a session-explicit exception, since Plane — the issue tracker — was the outage). Both CHANGE-001 and CHANGE-002 were captured with operator-authorization quotes, before/after state, and reversal procedures. CM-3(2) verification evidence was captured pre/post for each change. CM-3 was not skipped — it was carried out via the on-disk ledger, with the retroactive HAIST-22 Plane issue and this post-mortem closing the audit loop. |
| **CM-4 (Security Impact Analysis)** | Partial | PLAN.md analyzed expected impact and rollback for the umount path. CHANGE-001 was authored without an SCC / capability impact analysis (see §7). CHANGE-002's impact analysis was complete and correct (Audit mode preserves logging; time-bounded; ArgoCD reverts on Harbor-recovery). |
| **AC-5 (Separation of Duties)** | Held | Agent proposed; operator authorized each change explicitly ("option B" for CHANGE-001, "bypass kyverno then work on restoring harbor" for CHANGE-002). No agent-self-authorized cluster mutation occurred. |

---

## Appendix A — Source Ledger

All artifacts in `~/recovery-ledger/2026-04-27-power-incident/`:

- `PLAN.md` — initial plan, hypothesis, action sequence, CORRECTION block.
- `CHANGE-001-plane-pg-chown.md` — first manual change (the chown that turned out unnecessary).
- `CHANGE-002-kyverno-audit.md` — second manual change (Kyverno Enforce → Audit).
- `CHANGE-002-kyverno-before.yaml` — pre-patch ClusterPolicy snapshot.
- `RESEARCH-air-gapped-fail-secure.md` — root-cause architecture brief informing OPS-147..150.
- `RESEARCH-okd-upgrade.md` — sibling OKD-upgrade research informing OPS-151 sequencing.

## Appendix B — Authoring Note

This post-mortem was authored retroactively under operator-authorized session exception per CLAUDE.md §1 option (B): the Plane issue tracker was the outage, so prior-issue tracking was not possible during response; HAIST-22 was created retroactively and this document was authored against it. Times marked "approx" reflect the granularity available in the source ledger. Where the ledger does not capture a fact ("not captured in the recovery ledger"), no detail has been invented.
