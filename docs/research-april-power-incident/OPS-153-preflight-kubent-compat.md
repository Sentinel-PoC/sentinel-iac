# OPS-153 — Pre-flight kubent + Operator Compatibility for OKD 4.20 / 4.21

**Issue:** OPS-153 — MW2 pre-flight scan
**Cluster:** OKD 4.19.0-okd-scos.19, Kubernetes server v1.32.8
**Scan host:** iac-control (192.168.12.210), kubent v0.7.3
**Scan date:** 2026-04-27
**Targets:** k8s 1.33 (4.19 → 4.20 hop), k8s 1.34 (4.20 → 4.21 hop)

> **TL;DR**
> kubent: **0 deprecated APIs** found against either 1.33 or 1.34.
> Live cluster scanned 129 cluster-resources + 182 helm releases.
> Cluster-side: **no upgrade gate is currently blocking** (`oc adm upgrade` reports "no updates available" because OKD 4.20-scos has not yet shipped on the `stable-scos-4.19` channel — this is the upstream timeline, not a local blocker).
> **Must-fix-before-4.20: 2** (argocd-operator bump, kyverno bump). **Must-fix-before-4.21: 3** (re-validate ESO chart, sail/istio bump, recheck kubent with newer rules).
> **Highest-severity finding:** argocd-operator community chart v0.17.0 bundles ArgoCD v3.1, which is supported on k8s 1.33 but is **not yet validated** on 1.34 by upstream argo-cd at scan time — needs a forward-looking subscription bump before the second hop.

---

## 1. kube-no-trouble (kubent) Scan Results

**Tool:** kube-no-trouble v0.7.3 (git sha 57480c07), single Go binary installed to `/tmp/kubent` on iac-control.
**Invocation:**

```
/tmp/kubent --target-version=1.33 -o json
/tmp/kubent --target-version=1.34 -o json
```

**Coverage:** Cluster collector pulled 129 resources (Deployments, DaemonSets, Ingresses, etc.); Helm-v3 collector pulled 182 release manifests across all namespaces. Rulesets loaded: `deprecated-1-16`, `-1-22`, `-1-25`, `-1-26`, `-1-27`, `-1-29`, `-1-32`, `deprecated-future`, plus the custom-rego template.

**Result, both runs:** `[]` — empty findings array.

**Interpretation:**

- All workloads are already on the post-1.32 stable APIs (apps/v1 Deployments, networking.k8s.io/v1 Ingress / NetworkPolicy, policy/v1 PDB, autoscaling/v2 HPA, batch/v1 CronJob, rbac.authorization.k8s.io/v1, etc.).
- Helm release manifest content (the chart-as-rendered, not just live cluster state) is also clean. This catches the common gotcha where a chart still ships `policy/v1beta1 PodDisruptionBudget` even when the live object is `v1` — none observed.
- kubent v0.7.3's bundled rules go up to 1-32. Anything newly deprecated **between 1.33 and 1.34** would not be caught by these rules. The scan is necessary-but-not-sufficient for the 4.21 hop. See action item §4.B.5 (re-run with newer kubent before 4.21 cut).

Raw stderr/stdout in **Appendix A**.

**Deduplicated, prioritised action list from kubent:** none. Zero findings.

---

## 2. Operator and Workload Compatibility Matrix

Workloads listed in the issue are split between (a) operator-managed on this OpenShift cluster and (b) standalone workloads on dedicated VMs (not in scope for the cluster upgrade hop). I documented both for completeness.

### 2.A On-cluster — operator-managed (scope of this hop)

| Component | Deployed version | Source | k8s 1.33 | k8s 1.34 | Citation / Notes |
|---|---|---|---|---|---|
| **openshift-gitops (argocd-operator)** | argocd-operator.v0.17.0 (community-operators), bundles ArgoCD **v3.1.11** | OLM subscription `argocd-operator` channel `alpha`, ns `openshift-operators` | **YES** — ArgoCD v3.1 supports k8s 1.30–1.33 | **NEEDS BUMP** — ArgoCD v3.1 has no published 1.34 testing; argocd-operator v0.18.x / ArgoCD v3.2 is the line that adds 1.34 | https://argo-cd.readthedocs.io/en/stable/operator-manual/installation/#supported-versions, https://github.com/argoproj-labs/argocd-operator/releases |
| **Kyverno** | helm chart `kyverno-3.3.4`, image `ghcr.io/kyverno/kyverno:v1.13.2` | Helm release `kyverno/kyverno` | **YES** — Kyverno 1.13 compat matrix lists k8s 1.27–1.32 as **fully supported** and 1.33 as **community-tested**. **Action: bump to Kyverno 1.14.x** (chart 3.4.x), which formally supports 1.33. | **NO** — Kyverno 1.13 will not be validated against 1.34. Kyverno 1.15.x (chart 3.5.x) is the line that supports 1.33–1.34. | https://kyverno.io/docs/installation/#compatibility-matrix |
| **Cert-Manager** | **NOT INSTALLED on cluster** (cert serving via OpenShift router/route + ingress operator). | — | n/a | n/a | No cert-manager namespace, no jetstack CRDs in `oc get crd`. |
| **External Secrets Operator** | helm chart `external-secrets-0.11.0` (image v0.11.0) | Helm release `external-secrets/cluster` | **YES** — ESO 0.11 supports k8s 1.27–1.33 | **LIKELY YES, NEEDS BUMP** — ESO 0.12.x adds 1.34 to test matrix | https://github.com/external-secrets/external-secrets/blob/main/README.md#stability-and-support |
| **Sail (Istio) operator** | sailoperator.v1.29.1; in-cluster Istio v1.28.3 (base + cni + istiod) | OLM subscription | **YES** — Istio 1.28 supports k8s 1.30–1.33 | **NEEDS BUMP** — Istio 1.30+ supports k8s 1.34. Sail-operator tracks Istio quarterly. | https://istio.io/latest/docs/releases/supported-releases/ |
| **Jaeger operator** | jaeger-operator.v1.65.0 (status: Installing — pre-existing condition flag, not new) | OLM subscription | YES | YES | https://github.com/jaegertracing/jaeger-operator/releases |
| **Kiali** | helm chart `kiali-server-2.21.0` | Helm | YES | YES (tracked by Sail/Istio bump) | https://kiali.io/docs/installation/installation-guide/install-with-helm/ |
| **Grafana (community chart)** | helm chart `grafana-10.5.15`, app v12.3.1 | Helm `monitoring/grafana` | YES — pure Deployment, no apiVersion concerns | YES | https://artifacthub.io/packages/helm/grafana/grafana |

### 2.B On-cluster — application workloads (image-based, not API-version-sensitive)

These are plain Deployments/StatefulSets. They have no operator and use only stable core APIs. kubent confirmed clean. They will continue to run on 1.33 and 1.34 unchanged. Listed for inventory traceability:

| Workload | ns | Image | Notes |
|---|---|---|---|
| Keycloak | keycloak | `harbor.208.haist.farm/sentinel/keycloak:26.1.4` | Standalone container (not the keycloak-operator). k8s-version-agnostic. |
| Harbor | harbor | `goharbor/harbor-core:v2.14.2` (helm-templated Deployments) | k8s-version-agnostic. |
| Plane | plane | `plane-frontend:v0.24.0` (+ api/admin/space/web/worker) | k8s-version-agnostic. |
| Langfuse | langfuse | `langfuse:3.169.0` | k8s-version-agnostic. |
| DefectDojo | defectdojo | `defectdojo/defectdojo-django:2.55.2` | k8s-version-agnostic. |
| NetBox | netbox | `netbox:v4.5.3` | k8s-version-agnostic. |
| Matrix Synapse / Element Web / MAS | matrix | `synapse:v1.151.0`, `element-web:v1.12.15`, `mas:v0.12.0` | k8s-version-agnostic. |

### 2.C Off-cluster (dedicated VMs — out of scope for OKD upgrade)

Per platform topology: **Vault**, **Forgejo**, and **Wazuh (manager + indexer + dashboard)** run on dedicated VMs, not on the OKD cluster. No pods found in any namespace matching those names (`oc get pods -A | grep -iE "vault|forgejo|wazuh"` returned empty). They are unaffected by k8s 1.33/1.34. Their own version lifecycles tracked in their respective infra issues, not OPS-153.

---

## 3. CRD Inventory — v1beta1 Storage Versions

Total CRDs on cluster: **216**. Of those, **18 have `v1beta1` as the storage version** for their custom group. **None use the deprecated `apiextensions.k8s.io/v1beta1` CRD-definition API** (that was removed in k8s 1.22; we are well past that). All flagged CRDs use `apiextensions.k8s.io/v1` to define a custom-group `v1beta1`. This is allowed in 1.33/1.34.

**Group A — vendor-owned, will move to v1 with operator upgrades:**

| CRD | Group | Owner | Hop where it should move to v1 |
|---|---|---|---|
| `argocds.argoproj.io` | argoproj.io | argocd-operator | 4.20 (operator bump moves stored to v1beta1→v1) |
| `namespacemanagements.argoproj.io` | argoproj.io | argocd-operator | 4.20 |
| `clusterexternalsecrets.external-secrets.io` | external-secrets.io | ESO | 4.20 (ESO 0.12 storage migration) |
| `clustersecretstores.external-secrets.io` | external-secrets.io | ESO | 4.20 |
| `externalsecrets.external-secrets.io` | external-secrets.io | ESO | 4.20 |
| `secretstores.external-secrets.io` | external-secrets.io | ESO | 4.20 |
| `proxyconfigs.networking.istio.io` | networking.istio.io | sail/istio | 4.21 |
| `referencegrants.gateway.networking.k8s.io` | gateway.networking.k8s.io | OCP gateway-api | tracked by OKD release |

**Group B — OpenShift-owned, will be migrated by the OCP CVO during upgrade automatically:**

| CRD | Group |
|---|---|
| `helmchartrepositories.helm.openshift.io` | helm.openshift.io |
| `projecthelmchartrepositories.helm.openshift.io` | helm.openshift.io |
| `machines.machine.openshift.io` | machine.openshift.io |
| `machinesets.machine.openshift.io` | machine.openshift.io |
| `machineautoscalers.autoscaling.openshift.io` | autoscaling.openshift.io |
| `machinehealthchecks.machine.openshift.io` | machine.openshift.io |
| `metal3remediations.infrastructure.cluster.x-k8s.io` | (cluster-api) |
| `metal3remediationtemplates.infrastructure.cluster.x-k8s.io` | (cluster-api) |
| `ipaddresses.ipam.cluster.x-k8s.io` | (cluster-api) |
| `ipaddressclaims.ipam.cluster.x-k8s.io` | (cluster-api) |

**Verdict:** No manual CRD storage-version migrations required pre-hop. The OCP `kube-storage-version-migrator` operator handles Group B. Group A migrates when the operator subscription bumps. No CRD on the cluster blocks 1.33 or 1.34.

(There are additional CRDs that *serve* v1beta1 alongside v1 — e.g. monitoring.coreos.com `alertmanagerconfigs`, several Istio + Gateway-API resources — but their **storage** version is already `v1`. Listed in Appendix B for completeness; nothing to do.)

---

## 4. Action List Per Hop

Each item is tagged with a Plane issue identifier (existing) or "**filing recommended**" if no parent issue covers it.

### 4.A 4.19 → 4.20 (k8s 1.32 → 1.33) — **2 must-fix items**

| # | Action | Files / objects | Tracking |
|---|---|---|---|
| **A.1** | **Bump argocd-operator subscription** from v0.17.0 → v0.18.x (or whatever channel `alpha` ships matching ArgoCD v3.2) before cluster upgrade. ArgoCD v3.1 is supported on 1.33 but argocd-operator v0.17.0 is the last release before the 3.1→3.2 switch; carrying it forward is fine for 1.33 but constrains 4.21. | `Subscription/argocd-operator` in `openshift-operators` ns | filing recommended (child of OPS-153) |
| **A.2** | **Bump Kyverno helm chart** from `kyverno-3.3.4` (Kyverno v1.13.2) → `kyverno-3.4.x` (Kyverno v1.14.x). 1.13 has 1.33 only as community-tested; 1.14 is GA-supported. | Helm release `kyverno/kyverno`; chart values pinned in Forgejo IaC repo | filing recommended (child of OPS-153) |
| A.3 (info) | OCP CVO will migrate Group-B CRD storage versions automatically. No operator action. | — | n/a |
| A.4 (info) | `oc adm upgrade` shows no 4.20-scos release on `stable-scos-4.19` channel yet. **Cannot start 4.20 hop until upstream OKD-SCOS 4.20 ships.** Track upstream. | `clusterversion.spec.channel` | OPS-153 (this issue) |

**Cluster gates:** `oc adm upgrade` text was: "*No updates available. You may still upgrade to a specific release image with --to-image or wait for new updates to be available.*" `clusterversion.status.conditions`: `Available=True`, `Failing=False`, `Progressing=False`, `RetrievedUpdates=True`. **No "before upgrading you must..." gate.**

### 4.B 4.20 → 4.21 (k8s 1.33 → 1.34) — **3 must-fix items**

| # | Action | Files / objects | Tracking |
|---|---|---|---|
| **B.1** | **ArgoCD must reach v3.2+ (argocd-operator v0.18+).** v3.1 has no published 1.34 testing. | `Subscription/argocd-operator` | filing recommended |
| **B.2** | **Sail / Istio bump from 1.28.3 → 1.30+.** Istio 1.28 max-supported is k8s 1.33. | `sailoperator` subscription, `IstioOperator` in `istio-system` (or sail-operator-managed Istio CR), Helm releases `istio-system/default-istiod`, `istio-cni/istio-cni`, `openshift-operators/default-base` (all show chart `1.28.3`) | filing recommended |
| **B.3** | **Kyverno 1.14 → 1.15.x bump.** 1.14 covers 1.33 only; 1.15 covers 1.33+1.34. | Helm release `kyverno/kyverno` | filing recommended |
| B.4 (info) | **Re-validate External Secrets Operator (chart 0.11 → 0.12+).** ESO 0.11 supports through 1.33; 0.12 is the line for 1.34. Verify Vault provider compat at the same time. | Helm release `external-secrets/cluster` | filing recommended |
| B.5 (verify) | **Re-run kubent with a newer release** before scheduling the 4.21 hop. v0.7.3's rules cover up to 1-32; new rules will be needed for 1.33→1.34 deprecations. | Run `/tmp/kubent --target-version=1.34` after `kubent` is itself upgraded. | OPS-153 successor issue |

### 4.C Highest-severity finding

**ArgoCD chain (A.1 + B.1)** is the single highest-severity item: it is the only operator that is both (a) on the cluster's critical path (it manages every other workload via GitOps) and (b) on a release line that does not yet have published 1.34 compatibility. Carrying argocd-operator v0.17.0 / ArgoCD v3.1.11 across the 4.20 hop is acceptable; carrying it across the 4.21 hop is **not**.

**Severity: HIGH (not URGENT)** because the constraint is far-side-of-4.20, not blocking. Once the operator is bumped during the A-window, it removes the 4.21 risk.

---

## 5. Cluster-side Deprecation Timers / Upgrade Gates

Pulled from `oc get clusterversion -o yaml`:

```
status.conditions:
  - type: Available             status: True   "Done applying 4.19.0-okd-scos.19"
  - type: Failing               status: False
  - type: Progressing           status: False
  - type: ReleaseAccepted       status: True
  - type: RetrievedUpdates      status: True
  - type: ImplicitlyEnabledCapabilities  status: False  reason: AsExpected
```

`oc adm upgrade` output:

```
Cluster version is 4.19.0-okd-scos.19
Upstream: https://amd64.origin.releases.ci.openshift.org/graph
Channel: stable-scos-4.19
No updates available.
```

**No gates active.** No `Upgradeable=False` conditions on any clusteroperator. No "you must remove X before upgrading" admin advisories.

The only timer is the **upstream OKD-SCOS release timeline** — 4.20-scos has not yet been published on the stable channel, so the 4.20 hop is gated on upstream, not local state. Action: monitor the OKD release graph; revisit OPS-153 successor issue once 4.20-scos ships.

---

## Appendix A — Raw kubent output

### A.1 `--target-version=1.33`

```
>>> Kube No Trouble `kubent` <<<
version 0.7.3 (git sha 57480c07b3f91238f12a35d0ec88d9368aae99aa)
Initializing collectors and retrieving data
Target K8s version is 1.33.0
Retrieved 129 resources from collector name=Cluster
Retrieved 182 resources from collector name="Helm v3"
Loaded ruleset name=custom.rego.tmpl
Loaded ruleset name=deprecated-1-16.rego
Loaded ruleset name=deprecated-1-22.rego
Loaded ruleset name=deprecated-1-25.rego
Loaded ruleset name=deprecated-1-26.rego
Loaded ruleset name=deprecated-1-27.rego
Loaded ruleset name=deprecated-1-29.rego
Loaded ruleset name=deprecated-1-32.rego
Loaded ruleset name=deprecated-future.rego
```

JSON output:

```json
[]
```

### A.2 `--target-version=1.34`

```
>>> Kube No Trouble `kubent` <<<
version 0.7.3 (git sha 57480c07b3f91238f12a35d0ec88d9368aae99aa)
Initializing collectors and retrieving data
Target K8s version is 1.34.0
Retrieved 129 resources from collector name=Cluster
Retrieved 182 resources from collector name="Helm v3"
Loaded ruleset name=custom.rego.tmpl
Loaded ruleset name=deprecated-1-16.rego
Loaded ruleset name=deprecated-1-22.rego
Loaded ruleset name=deprecated-1-25.rego
Loaded ruleset name=deprecated-1-26.rego
Loaded ruleset name=deprecated-1-27.rego
Loaded ruleset name=deprecated-1-29.rego
Loaded ruleset name=deprecated-1-32.rego
Loaded ruleset name=deprecated-future.rego
```

JSON output:

```json
[]
```

Raw scan files saved on iac-control: `/tmp/kubent-1.33.json`, `/tmp/kubent-1.33.stderr`, `/tmp/kubent-1.34.json`, `/tmp/kubent-1.34.stderr`. Copies pulled to this branch's `/tmp/sentinel-iac-OPS-153/data/` during the run; not committed (raw-data files, not docs).

## Appendix B — All v1beta1-served CRDs (informational)

Storage column shows the **storage** version. CRDs whose v1beta1 is **served=true, stored=false** are dual-served for client compatibility but are already storing as v1; they are safe across upgrades. CRDs with **stored=true** v1beta1 are listed in §3.

| CRD | v1beta1 stored | Group |
|---|---|---|
| alertmanagerconfigs.monitoring.coreos.com | false | monitoring.coreos.com |
| argocds.argoproj.io | **true** | argoproj.io |
| authorizationpolicies.security.istio.io | false | security.istio.io |
| clusterexternalsecrets.external-secrets.io | **true** | external-secrets.io |
| clustersecretstores.external-secrets.io | **true** | external-secrets.io |
| destinationrules.networking.istio.io | false | networking.istio.io |
| externalsecrets.external-secrets.io | **true** | external-secrets.io |
| gatewayclasses.gateway.networking.k8s.io | false | gateway.networking.k8s.io |
| gateways.gateway.networking.k8s.io | false | gateway.networking.k8s.io |
| gateways.networking.istio.io | false | networking.istio.io |
| helmchartrepositories.helm.openshift.io | **true** | helm.openshift.io |
| httproutes.gateway.networking.k8s.io | false | gateway.networking.k8s.io |
| ipaddressclaims.ipam.cluster.x-k8s.io | **true** | ipam.cluster.x-k8s.io |
| ipaddresses.ipam.cluster.x-k8s.io | **true** | ipam.cluster.x-k8s.io |
| machineautoscalers.autoscaling.openshift.io | **true** | autoscaling.openshift.io |
| machinehealthchecks.machine.openshift.io | **true** | machine.openshift.io |
| machinesets.machine.openshift.io | **true** | machine.openshift.io |
| machines.machine.openshift.io | **true** | machine.openshift.io |
| metal3remediations.infrastructure.cluster.x-k8s.io | **true** | infrastructure.cluster.x-k8s.io |
| metal3remediationtemplates.infrastructure.cluster.x-k8s.io | **true** | infrastructure.cluster.x-k8s.io |
| namespacemanagements.argoproj.io | **true** | argoproj.io |
| peerauthentications.security.istio.io | false | security.istio.io |
| projecthelmchartrepositories.helm.openshift.io | **true** | helm.openshift.io |
| proxyconfigs.networking.istio.io | **true** | networking.istio.io |
| referencegrants.gateway.networking.k8s.io | **true** | gateway.networking.k8s.io |
| requestauthentications.security.istio.io | false | security.istio.io |
| secretstores.external-secrets.io | **true** | external-secrets.io |
| serviceentries.networking.istio.io | false | networking.istio.io |
| sidecars.networking.istio.io | false | networking.istio.io |
| updaterequests.kyverno.io | false | kyverno.io |
