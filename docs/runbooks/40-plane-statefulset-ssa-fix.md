# Runbook 40 — plane StatefulSet SSA Fix: Labels + Resource Limits

**Issue:** OPS-858  
**Criticality:** MEDIUM — plane Healthy but ArgoCD Unknown; PolicyException gap if exception is retired  
**Authored:** 2026-05-23 by worker-ops-858-plane-statefulsets  
**NIST Controls:** CM-8 (app.kubernetes.io/name inventory label), SC-6 (resource limits)  
**Related:** OPS-785 (SSA patch removal, PR #287), OPS-822 (StatefulSet selector mismatch), OPS-126 (original PolicyException), OPS-878 (kustomization.yaml dangling refs — prerequisite)

> **PLANNING DOCUMENT — operator approval required before any step is executed.**  
> Manifests under `kubernetes/` are inert skeletons with PLANNING ONLY headers.  
> No live infrastructure changes until this runbook is reviewed and a child execution issue is filed.

---

## Table of Contents

1. [Background: Why SSA Cannot Fix This](#1-background-why-ssa-cannot-fix-this)
2. [Live State Evidence](#2-live-state-evidence)
3. [Prerequisites](#3-prerequisites)
4. [Option A — Kyverno MutateExisting Policy](#4-option-a--kyverno-mutateexisting-policy)
5. [Option B — ArgoCD PostSync Hook Job](#5-option-b--argocd-postsync-hook-job)
6. [Option C — Status Quo (Do Nothing)](#6-option-c--status-quo-do-nothing)
7. [Recommendation](#7-recommendation)
8. [Required ignoreDifferences Updates](#8-required-ignoredifferences-updates)
9. [Rollback Procedure (Option A)](#9-rollback-procedure-option-a)
10. [Testing Plan](#10-testing-plan)
11. [Execution Gate — Child Issue](#11-execution-gate--child-issue)

---

## 1. Background: Why SSA Cannot Fix This

### 1.1 The Prior Approach (OPS-126)

The plane-ce 1.4.1 Helm chart creates three StatefulSets — `plane-minio-wl`,
`plane-rabbitmq-wl`, `plane-redis-wl` — without `app.kubernetes.io/name` metadata
labels or container resource limits. These absences cause:

- `require-labels` ClusterPolicy violations (CM-8 inventory compliance)
- `require-resource-limits` ClusterPolicy violations (SC-6 resource isolation)

OPS-126 attempted to resolve this via SSA overlay patches: standalone partial-spec
YAML files referencing the StatefulSets, marked with
`argocd.argoproj.io/sync-options: ServerSideApply=true` and
`argocd.argoproj.io/compare-options: IgnoreExtraneous`. These files were added to
`apps/plane/kustomization.yaml` in overwatch-gitops and listed as chart resources.

### 1.2 Why K8s 1.34 SSA Blocks the Prior Approach

**Confirmed via `kubectl apply --server-side --dry-run=server` (OPS-785, 2026-05-22):**

K8s 1.34 Server-Side Apply imposes a mutually contradictory constraint on
StatefulSet patches that include `spec.template.*` fields:

1. **`spec.selector` required**: If the patch includes any `spec.template.*` field,
   the API requires `spec.selector` in the payload ("Required value").
2. **`spec.selector` forbidden**: `spec.selector` is an immutable field; the API
   rejects any patch that changes it ("spec: Forbidden: updates to statefulset spec
   for fields other than...").

This constraint applies even with `--validate=false` (`fieldValidation=Ignore`).
The three SSA patches for minio/rabbitmq/redis were removed by PR #287 because
there is no SSA workaround — the API simultaneously demands and forbids the same
field when patching StatefulSet spec.template.

Note: **Strategic merge patch (`kubectl patch --type=strategic`) works fine** for
these fields. The limitation is SSA-specific. ArgoCD's `ServerSideApply=true`
syncOption is what exposes this: ArgoCD applies all managed resources via SSA.
A separate mechanism (Kyverno or hook job) that uses the regular Update API is
the correct escape hatch.

### 1.3 Current ArgoCD App State

The plane ArgoCD Application (`openshift-gitops/plane`) shows
**Unknown sync / Progressing health** rather than the expected OutOfSync.
This is caused by **OPS-878**: `apps/plane/kustomization.yaml` still references
the 3 deleted patch files; `kustomize build` fails before ArgoCD can compute any
diff. OPS-878 is a prerequisite fix for this runbook.

---

## 2. Live State Evidence

Captured 2026-05-23T09:20Z from iac-control (`KUBECONFIG=/home/ubuntu/overwatch-repo/auth/kubeconfig.new`).

### 2.1 StatefulSet Metadata Labels

```
$ oc get statefulset plane-minio-wl -n plane \
    -o jsonpath='{.metadata.labels}' | python3 -m json.tool
{}
```

All three StatefulSets return empty `metadata.labels`. The `app.kubernetes.io/name`
label required by the `require-labels` ClusterPolicy is absent. The pod template
carries a non-standard `app.name` label (not the Kubernetes-standard key):

```
spec.template.metadata.labels:
  app.name: plane-plane-minio     # plane-minio-wl
  app.name: plane-plane-rabbitmq  # plane-rabbitmq-wl
  app.name: plane-plane-redis     # plane-redis-wl
```

### 2.2 Container Resource Limits

```
container plane-minio resources: {}
container plane-rabbitmq resources: {}
container plane-redis resources: {}
```

No `limits` or `requests` on any of the three sub-chart containers.

### 2.3 ArgoCD Application Status

```
$ oc get applications -n openshift-gitops
NAME    SYNC STATUS  HEALTH STATUS
plane   Unknown      Progressing
```

Root cause: `apps/plane/kustomization.yaml` references three missing files
(`plane-{redis,rabbitmq,minio}-wl-patch.yaml`). kustomize build fails.
See OPS-878.

### 2.4 Kyverno PolicyException (Interim Protection)

```
$ oc get policyexceptions -n kyverno | grep plane
plane-chart-hygiene-exception   26d
```

The `plane-chart-hygiene-exception` PolicyException (kyverno namespace) exempts
all `Pod`, `StatefulSet`, and `Deployment` kinds in the `plane` namespace from:
- `require-labels / require-app-label`
- `require-resource-limits / require-limits`

This was added during OPS-126 break-glass recovery and persists because the ArgoCD
plane app uses `prune: false` — ArgoCD will not garbage-collect the object even
though it is no longer in the desired-state kustomization. The PolicyException is
actively protecting the plane StatefulSet pods from admission-time enforcement.
**Do not retire this exception until labels + limits are confirmed present.**

### 2.5 Kyverno Version

```
$ oc get pod kyverno-admission-controller-... -n kyverno \
    -o jsonpath='{.spec.containers[0].image}'
ghcr.io/kyverno/kyverno:v1.13.2
```

Kyverno v1.13.2 fully supports `mutateExisting` with
`mutateExistingOnPolicyUpdate: true`.

---

## 3. Prerequisites

| # | Task | Issue | Owner |
|---|------|-------|-------|
| 1 | Remove dangling refs from `apps/plane/kustomization.yaml` in overwatch-gitops | **OPS-878** | WORKER |
| 2 | Confirm ArgoCD plane app returns to Synced/OutOfSync (not Unknown) after OPS-878 merge | OPS-878 | operator |
| 3 | Operator approves this runbook and files a child execution issue | this doc §11 | operator |

---

## 4. Option A — Kyverno MutateExisting Policy

### 4.1 Mechanism

Add a new `ClusterPolicy` with `mutate` rules targeting the existing StatefulSets.
Kyverno `mutateExisting` fires via the Background Controller (not admission)
and uses the regular Kubernetes Update API — bypassing the SSA ownership conflict
that blocked the prior approach. Setting `mutateExistingOnPolicyUpdate: true`
causes Kyverno to retroactively apply the mutation to all matching existing
resources when the policy is created or updated.

**Field manager**: The Kyverno Background Controller applies its mutations as field
manager `kyverno`. This is separate from the ArgoCD/Helm field manager. Since
resource limits and metadata labels are fields Helm does not set (they are absent
from the rendered chart output), there is no ownership conflict with Helm.

### 4.2 What Gets Added

**Metadata label** (on StatefulSet object itself):
```yaml
metadata:
  labels:
    app.kubernetes.io/name: plane-minio  # or plane-rabbitmq / plane-redis
```

**Container resource limits** (in spec.template.spec.containers[]):

| StatefulSet | Memory Limit | Memory Request | CPU Limit | CPU Request |
|-------------|-------------|----------------|-----------|-------------|
| plane-minio-wl | 1Gi | 256Mi | 500m | 50m |
| plane-rabbitmq-wl | 512Mi | 128Mi | 500m | 50m |
| plane-redis-wl | 512Mi | 128Mi | 500m | 50m |

Values match the original OPS-126 intent (same as the deleted SSA patches).

### 4.3 Inert Manifest Skeleton

See `kubernetes/manifests/kyverno/policies/plane-statefulset-labels.yaml`
in this PR. The manifest is marked `PLANNING ONLY` and is not referenced by
any ArgoCD Application until the operator merges the execution child issue.

### 4.4 ArgoCD ignoreDifferences Required

After Kyverno adds labels/limits, ArgoCD will see a perpetual diff (Helm renders
no labels/limits; live state has them). Add to the `ignoreDifferences` block of
`clusters/overwatch/apps/plane-app.yaml` in overwatch-gitops:

```yaml
  - group: apps
    kind: StatefulSet
    name: plane-minio-wl
    jqPathExpressions:
    - .spec.selector
    - .spec.template.metadata.labels
    - .spec.volumeClaimTemplates[].metadata
    - .spec.volumeClaimTemplates[].spec.storageClassName
    # ADD THESE:
    - .metadata.labels["app.kubernetes.io/name"]
    - .spec.template.spec.containers[].resources
  # (same additions for plane-rabbitmq-wl and plane-redis-wl)
```

This change goes into the overwatch-gitops PR (separate from this sentinel-iac PR).

### 4.5 PolicyException Retirement

Once the mutation policy is confirmed active and all three StatefulSets carry the
required label + limits, the `plane-chart-hygiene-exception` PolicyException can be
removed from `apps/plane/kyverno-exception.yaml` in overwatch-gitops. The tombstone
file can be deleted entirely, or updated to reflect the new state. This step belongs
in the execution child issue.

### 4.6 Blast Radius

- **Policy scope**: Precisely scoped to 3 named StatefulSets in the `plane` namespace.
  No other workloads affected.
- **Mutation is additive**: Labels and resource limits are added; no existing fields
  removed. Pods that are already running are not restarted by the metadata mutation.
  Resource limits on the StatefulSet spec are applied when pods are next restarted
  (e.g., rolling update, node drain, manual deletion).
- **No admission-time enforcement change**: The new policy uses `mutateExisting`
  (background), not admission mutation. The `require-resource-limits` ClusterPolicy
  enforces on new pod admission. The PolicyException covers existing pods until they
  cycle through with the new limits.

---

## 5. Option B — ArgoCD PostSync Hook Job

### 5.1 Mechanism

Add a Kubernetes `Job` with ArgoCD hook annotations to `apps/plane/` in
overwatch-gitops. The job runs `kubectl patch --type=strategic` (not SSA) after
every ArgoCD sync to apply labels and limits to the three StatefulSets.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: plane-sts-patch-hook
  namespace: plane
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      serviceAccountName: plane-sts-patcher  # needs RBAC to patch StatefulSets
      restartPolicy: OnFailure
      containers:
      - name: patcher
        image: harbor.208.haist.farm/sentinel/kubectl:latest
        command:
        - sh
        - -c
        - |
          kubectl label sts plane-minio-wl -n plane \
            app.kubernetes.io/name=plane-minio --overwrite
          kubectl patch sts plane-minio-wl -n plane \
            --type=strategic \
            -p '{"spec":{"template":{"spec":{"containers":[{"name":"plane-minio",
              "resources":{"limits":{"memory":"1Gi","cpu":"500m"},
                           "requests":{"memory":"256Mi","cpu":"50m"}}}]}}}}'
          # ... repeated for rabbitmq and redis
```

Same `ignoreDifferences` additions to `plane-app.yaml` are required (§4.4).

### 5.2 Additional Considerations

- Requires a `ServiceAccount` + `ClusterRole`/`Role` with `patch` permission on
  StatefulSets in the `plane` namespace — additional RBAC objects to manage.
- The hook runs after **every sync**, even when there is no diff to apply. This adds
  Job overhead (kubectl image pull, API call) to every sync cycle.
- If the ArgoCD sync fails before PostSync phase, the labels/limits won't be applied.
  Unlike Kyverno (background controller), the hook is tightly coupled to the sync
  cycle.
- `HookSucceeded` delete policy: the Job and its pod are garbage-collected on success,
  keeping the namespace clean. If the hook fails, the Job persists for inspection.
- Requires adding a `kubectl` image to Harbor mirror (or use an existing image that
  includes kubectl, e.g., an OKD utility image).

---

## 6. Option C — Status Quo (Do Nothing)

Accept the persistent lack of `app.kubernetes.io/name` labels and resource limits
on the three plane StatefulSets, and retain the `plane-chart-hygiene-exception`
PolicyException indefinitely.

**Why this is not acceptable:**

1. **Observability gap (CM-8)**: The `app.kubernetes.io/name` label is the canonical
   Kubernetes inventory label. Grafana, Prometheus (kube-state-metrics), and any
   label-selector-based tooling that queries `plane` namespace workloads will miss
   these three StatefulSets in aggregated views. HPA targets also rely on this label.

2. **Resource isolation gap (SC-6)**: StatefulSets without memory limits can OOM-kill
   the OKD node if a workload (particularly MinIO) consumes unbounded memory during
   a bulk upload or compaction. The platform has experienced OOM events on plane nodes
   before (OPS-764 addressed the API tier; the sub-chart StatefulSets are not covered).

3. **PolicyException scope creep**: The `plane-chart-hygiene-exception` currently
   exempts **all** Pods, StatefulSets, and Deployments in the plane namespace from
   both `require-labels` and `require-resource-limits`. Retaining it indefinitely
   means the 7 Deployment patches that already have `app.kubernetes.io/name` labels
   and resource limits are also silently excepted — masking any future regression.
   A targeted exception or no exception at all is the correct steady state.

4. **Compliance drift**: `require-labels` maps to NIST CM-8; `require-resource-limits`
   maps to NIST SC-6. The Kyverno policies generate background-scan violation reports.
   Persistent violations against the `plane` namespace will surface in any future NIST
   compliance assessment.

---

## 7. Recommendation

**Recommendation: Option A — Kyverno MutateExisting Policy**

Rationale:
1. **Kyverno is already in cluster** (v1.13.2, 8 ClusterPolicies, all Ready). No new
   tooling to install.
2. **Declarative, policy-as-code**: consistent with the existing `require-labels` and
   `require-resource-limits` posture. The new mutate policy lives in the same
   `kyverno-policies` ArgoCD Application that manages the existing policies.
3. **Background controller, not admission**: the mutation fires via the Background
   Controller on policy creation and on resource update — independent of the sync cycle.
   No tight coupling to ArgoCD sync timing.
4. **Precise blast radius**: scoped to 3 named StatefulSets. No RBAC, no ServiceAccount,
   no additional images needed.
5. **One-time application**: unlike the PostSync hook which runs on every sync,
   Kyverno applies the mutation once and the Background Controller re-applies only if
   the fields drift away (e.g., a Helm upgrade resets them).
6. **Enables PolicyException retirement**: once mutation is confirmed, the broad
   PolicyException can be replaced with zero exceptions (the correct steady state).

**Against PostSync hook**: The hook adds operational overhead (Job runs every sync),
requires additional RBAC, and is more tightly coupled to sync failures. It is the
correct fallback if the Kyverno mutation turns out to interfere with the StatefulSet
controller (e.g., due to Kyverno's field manager conflicting with OpenShift's), but
that scenario is unlikely given the additive nature of the patch.

---

## 8. Required ignoreDifferences Updates

After the Kyverno mutation applies, ArgoCD will detect these fields as live-differs-from-desired. The following `ignoreDifferences` additions are needed in
`clusters/overwatch/apps/plane-app.yaml` in overwatch-gitops (separate PR):

```yaml
# Replace existing per-StatefulSet ignoreDifferences entries with:
  - group: apps
    kind: StatefulSet
    name: plane-minio-wl
    jqPathExpressions:
    - .spec.selector
    - .spec.template.metadata.labels
    - .spec.volumeClaimTemplates[].metadata
    - .spec.volumeClaimTemplates[].spec.storageClassName
    - .metadata.labels["app.kubernetes.io/name"]          # Kyverno-added
    - .spec.template.spec.containers[].resources           # Kyverno-added
  - group: apps
    kind: StatefulSet
    name: plane-rabbitmq-wl
    jqPathExpressions:
    - .spec.selector
    - .spec.template.metadata.labels
    - .spec.volumeClaimTemplates[].metadata
    - .spec.volumeClaimTemplates[].spec.storageClassName
    - .metadata.labels["app.kubernetes.io/name"]          # Kyverno-added
    - .spec.template.spec.containers[].resources           # Kyverno-added
  - group: apps
    kind: StatefulSet
    name: plane-redis-wl
    jqPathExpressions:
    - .spec.selector
    - .spec.template.metadata.labels
    - .spec.volumeClaimTemplates[].metadata
    - .spec.volumeClaimTemplates[].spec.storageClassName
    - .metadata.labels["app.kubernetes.io/name"]          # Kyverno-added
    - .spec.template.spec.containers[].resources           # Kyverno-added
```

Note: `RespectIgnoreDifferences=true` is already in the plane app `syncOptions`,
so ArgoCD's SSA apply will exclude these fields from the apply payload and will not
overwrite the Kyverno-applied values.

---

## 9. Rollback Procedure (Option A)

### If the mutation causes unexpected behavior after operator confirms execution:

1. **Delete the Kyverno ClusterPolicy** (removes mutation enforcement):
   ```bash
   oc delete clusterpolicy plane-statefulset-hygiene-mutate
   ```
   This stops further mutations. Existing labels/limits on the StatefulSets persist
   (Kyverno deletion does not revert mutations already applied).

2. **If revert of labels/limits is needed** (e.g., resource limits are too low):
   ```bash
   kubectl patch sts plane-minio-wl -n plane --type=strategic \
     -p '{"spec":{"template":{"spec":{"containers":[{"name":"plane-minio","resources":{}}]}}}}'
   # repeat for rabbitmq, redis
   kubectl label sts plane-minio-wl -n plane app.kubernetes.io/name- # remove label
   ```

3. **Re-add the PolicyException** if Kyverno enforcement would now block admission:
   Restore `plane-chart-hygiene-exception` in `apps/plane/kyverno-exception.yaml`
   and re-add it to `kustomization.yaml` resources list.

4. **Revert the `ignoreDifferences` additions** in `plane-app.yaml` to the previous
   set (without the Kyverno-added fields).

---

## 10. Testing Plan

### Step 0: Prerequisite — Fix OPS-878 first

Merge OPS-878 to restore ArgoCD's ability to build the `apps/plane` kustomization.
Confirm plane app returns to `Synced` or `OutOfSync` (not `Unknown`) before
proceeding.

### Step 1: Dry-run the mutation on one StatefulSet

Before merging the Kyverno policy, test the strategic merge patch manually on a
single StatefulSet to confirm no unexpected behavior:

```bash
# Dry run only — does not apply
kubectl patch sts plane-redis-wl -n plane \
  --type=strategic \
  --dry-run=server \
  -p '{"metadata":{"labels":{"app.kubernetes.io/name":"plane-redis"}},
       "spec":{"template":{"spec":{"containers":[{"name":"plane-redis",
         "resources":{"limits":{"memory":"512Mi","cpu":"500m"},
                      "requests":{"memory":"128Mi","cpu":"50m"}}}]}}}}'
```

Expected: `statefulset.apps/plane-redis-wl patched (dry run)` — no error.

### Step 2: Apply Kyverno policy with validationFailureAction: Audit

The inert manifest sets `validationFailureAction: Audit`. Apply it:

1. Remove the `PLANNING ONLY` header comment from the manifest.
2. Apply via ArgoCD (add to a kyverno-policies ArgoCD Application or apply manually):
   ```bash
   oc apply -f kubernetes/manifests/kyverno/policies/plane-statefulset-labels.yaml
   ```
3. Watch the Kyverno Background Controller logs:
   ```bash
   oc logs -n kyverno -l app.kubernetes.io/component=background-controller -f
   ```
   Expected: `mutateExisting triggered for plane-{minio,rabbitmq,redis}-wl`.

### Step 3: Verify labels and limits are present

```bash
oc get sts plane-minio-wl -n plane \
  -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}'
# Expected: plane-minio

oc get sts plane-minio-wl -n plane \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
# Expected: {"limits":{"cpu":"500m","memory":"1Gi"},"requests":{"cpu":"50m","memory":"256Mi"}}
```

### Step 4: Confirm ArgoCD sync transition

After adding the `ignoreDifferences` entries to `plane-app.yaml`:

1. Trigger an ArgoCD sync on the plane app.
2. Expected: ArgoCD transitions from OutOfSync (for the label/limit fields) to
   `Synced` (with `RespectIgnoreDifferences=true`, those fields are excluded from
   the diff computation).

### Step 5: Retire PolicyException

Once Steps 2–4 pass for all 3 StatefulSets, the `plane-chart-hygiene-exception`
PolicyException can be removed. Confirm after removal that no new admission failures
appear in Kyverno reports:

```bash
oc get policyreport -n plane
```

No new `FAIL` entries for `require-labels` or `require-resource-limits`.

---

## 11. Execution Gate — Child Issue

This runbook is a **planning artifact only**. No live cluster changes are made here.

To execute:
1. Operator reviews this runbook and the inert manifest skeleton.
2. Operator files a child execution issue referencing this runbook and OPS-878 as prerequisite.
3. WORKER assigned to child issue removes the `# PLANNING ONLY` header from the manifest,
   wires it into the kyverno-policies ArgoCD Application in overwatch-gitops, and opens
   a PR following the testing plan above.
4. Same PR (or a companion overwatch-gitops PR) adds the `ignoreDifferences` entries
   from §8 to `plane-app.yaml`.
5. Judge verifies and merges; operator confirms via cluster observation.
