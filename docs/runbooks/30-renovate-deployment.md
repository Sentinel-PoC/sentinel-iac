# Runbook 30 — Renovate Deployment on Forgejo + OKD

**Issue:** OPS-866  
**Criticality:** MEDIUM — dependency-update automation; no production traffic served by Renovate itself  
**Authored:** 2026-05-23 by worker-ops-866-renovate-plan  
**NIST Controls:** CM-3, CM-3(2), SA-10, SI-2  
**Related:** OPS-865 (CVE-2026-31789 OpenSSL), OPS-863 (DefectDojo fingerprinting), OPS-489 (DefectDojo triage), OPS-288/OPS-289 (sandbox cluster)

> **PLANNING DOCUMENT — operator approval required before any step is executed.**  
> Manifests under `kubernetes/` are inert skeletons with PLANNING ONLY headers.  
> No live infrastructure changes until this runbook is reviewed and a child execution issue is filed per §13.

---

## Table of Contents

1. [Why Renovate, Why Now](#1-why-renovate-why-now)
2. [Tool Selection Rationale](#2-tool-selection-rationale)
3. [Prerequisites](#3-prerequisites)
4. [Deployment Architecture](#4-deployment-architecture)
5. [Phase 1 — Identity Provisioning](#5-phase-1--identity-provisioning)
6. [Phase 2 — Deploy Renovate Operator](#6-phase-2--deploy-renovate-operator)
7. [Phase 3 — Configure Auto-Merge Ruleset](#7-phase-3--configure-auto-merge-ruleset)
8. [Phase 4 — Telegram/ntfy Alert Wiring](#8-phase-4--telegramntfy-alert-wiring)
9. [Phase 5 — Repo Enablement (opt-in)](#9-phase-5--repo-enablement-opt-in)
10. [Blast Radius + RTO/RPO](#10-blast-radius--rtorpo)
11. [Rollback Procedure](#11-rollback-procedure)
12. [Dev/Sandbox Dependency Gate](#12-devsandbox-dependency-gate)
13. [Execution Gate — Child Issue](#13-execution-gate--child-issue)

---

## 1. Why Renovate, Why Now

OPS-489 phase-1 triage found:

- 132 of 140 closed Critical findings in DefectDojo were **stale-SHA cruft** — images rebuilt
  from the same base but fingerprints not stable (OPS-863 blocker).
- The remaining 160 open Criticals are dominated by **one OS-level CVE** (CVE-2026-31789,
  OpenSSL — OPS-865) repeated across 20+ images because base images have not been updated.

Manual mass-rebuild is the wrong approach. The correct fix is a **per-image PR-bot pipeline**:
Renovate opens a PR when an updated base image is published, CI validates, auto-merges if green.

**Once Renovate is live:**

- OPS-865 (OpenSSL) becomes a one-week pipeline sweep — Renovate opens one PR per image, CI
  validates, auto-merges if OS patch level.
- OPS-489 phase-2 becomes self-maintaining as long as CI includes an image scan step.

---

## 2. Tool Selection Rationale

| Option | Status | Reason |
|--------|--------|--------|
| **Renovate** | **Selected** | AGPL-3.0, free self-host, native Forgejo/Gitea support. 90+ package managers: Dockerfile FROM scanning, K8s image: scanning, Helm chart deps + values, Ansible Galaxy, pip, Go, npm. |
| Dependabot | Rejected | GitHub-only officially; self-host on non-GitHub unsupported |
| Watchtower | Rejected | Operates on running containers — does not integrate with CI gates or code review |
| Renovate Operator | **Selected for K8s deploy** | 3.2.1 (March 2026); K8s-native CronJob; --autodiscover for Forgejo orgs; dashboard + metrics; Helm chart available |

**Version pinned:** Renovate Operator **3.2.1** (Helm chart `renovate/renovate-operator`).  
Source: https://github.com/renovatebot/renovate/releases  
**Before execution:** verify 3.2.1 is still current; check changelog for Forgejo/OKD breaking changes.

---

## 3. Prerequisites

### 3.1 Forgejo renovate-bot User

| Field | Value |
|-------|-------|
| Username | `renovate-bot` |
| Email | `renovate-bot@haist.farm` |
| Admin | **No** (least privilege) |
| Org membership | `sentinel-admin` with write access on target repos |
| Token scope | `repo` (read/write) |

**Vault path:** `secret/renovate/forgejo-token` (key: `api_token`)

```bash
# Create after provisioning renovate-bot Forgejo user + token
vault kv put secret/renovate/forgejo-token api_token="<token>"
vault kv get secret/renovate/forgejo-token   # verify
```

**ExternalSecret stub (real manifest in execution child issue):**

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: renovate-forgejo-token
  namespace: renovate
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: renovate-forgejo-token
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: secret/renovate/forgejo-token
        property: api_token
```

### 3.2 OKD Namespace

Target namespace: `renovate`  
Created by ArgoCD on first sync (`CreateNamespace=true` in syncOptions).

### 3.3 Helm Repository

Renovate Operator chart: `https://docs.renovatebot.com/helm-charts/` (alias `renovate`).  
Add as Harbor proxy project if Helm proxy cache is in use.

---

## 4. Deployment Architecture

```
OKD cluster (openshift-gitops)
  └── ArgoCD root-app  [clusters/overwatch/root-app.yaml in overwatch-gitops]
       └── renovate-app.yaml  [created in execution child issue in overwatch-gitops]
            └── apps/renovate/  [Helm chart + values in overwatch-gitops]
                 └── Renovate Operator CronJob
                      ├── ServiceAccount (renovate, least-privilege)
                      ├── ExternalSecret → Vault secret/renovate/forgejo-token
                      ├── ConfigMap (renovate-config.js)
                      └── NetworkPolicy (egress to Forgejo/ntfy/Vault only)
```

**Planning skeletons in this PR** (`kubernetes/argocd/applications/renovate.yaml` and
`kubernetes/manifests/renovate/`) are review artifacts only. They carry `PLANNING ONLY` headers.
They are never applied. Real deployable manifests land in overwatch-gitops in the execution child
issue (§13).

---

## 5. Phase 1 — Identity Provisioning

**Executed by:** Operator (or provisioning worker with explicit operator authorization)  
**Gate:** Must complete before Phase 2.

```bash
# 1. Create renovate-bot user
curl -s -X POST \
  -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"renovate-bot","email":"renovate-bot@haist.farm",
        "password":"<strong-random>","must_change_password":false,
        "login_name":"renovate-bot","source_id":0}' \
  "https://forgejo.208.haist.farm/api/v1/admin/users"

# 2. Add to sentinel-admin org with write access
#    Forgejo UI: Organization → sentinel-admin → Members → Add → renovate-bot

# 3. Generate API token (via Forgejo UI as renovate-bot)
#    Settings → Applications → Generate token → scope: repo

# 4. Store in Vault
vault kv put secret/renovate/forgejo-token api_token="<token>"
```

---

## 6. Phase 2 — Deploy Renovate Operator

**Sync policy at first deploy:** `syncPolicy: {}` (manual sync; no automated/selfHeal).  
**Enable auto-sync only after:** successful dry-run observation week (see First Sync Checklist).

### Helm Values Stub (operator finalizes in execution child issue)

```yaml
# apps/renovate/values.yaml in overwatch-gitops
# PLANNING ONLY — do not apply until OPS-866 runbook is operator-approved
renovate:
  config: |
    module.exports = {
      platform: "forgejo",
      endpoint: "https://forgejo.208.haist.farm",
      token: process.env.RENOVATE_TOKEN,
      autodiscover: true,
      autodiscoverFilter: ["sentinel-admin/*"],
      onboarding: true,
      requireConfig: "optional",
      dryRun: "full",  // OBSERVE ONLY for first week; remove after review
    };
  existingSecret: "renovate-forgejo-token"
  secretKey: "token"

cronjob:
  schedule: "0 2 * * *"  # nightly 02:00 UTC

resources:
  limits:
    cpu: "1"
    memory: "2Gi"
  requests:
    cpu: "100m"
    memory: "512Mi"
```

### First Sync Checklist

- [ ] `oc get externalsecret renovate-forgejo-token -n renovate` → `Synced / Secret Created`
- [ ] `oc get cronjob -n renovate` → CronJob `renovate` exists
- [ ] Trigger smoke: `oc create job --from=cronjob/renovate renovate-smoke-1 -n renovate`
- [ ] `oc logs -f job/renovate-smoke-1 -n renovate` — authenticated, no fatal errors
- [ ] With dryRun: confirm Renovate logs what PRs it *would* open but does NOT open them
- [ ] Review dry-run output; confirm no surprising repos or managers discovered
- [ ] After one clean dry-run week: remove `dryRun: "full"` and enable auto-sync

---

## 7. Phase 3 — Configure Auto-Merge Ruleset

### Policy Matrix

| Update Type | Examples | Auto-Merge? | Gate |
|-------------|----------|-------------|------|
| OS package patch | `libssl 3.0.7→3.0.8`, `libxml2 2.11.4→2.11.5` | **YES** | CI green (Trivy + build) |
| Container image patch | `alpine:3.19.0→3.19.1` | **YES** | CI green |
| Container image minor | `alpine:3.19→3.20` | NO | Human approval |
| Container image major | `alpine:3→4` | NO | Human approval + smoke test |
| Helm chart patch | `chart 1.2.3→1.2.4` | **YES** | CI green |
| Helm chart minor | `chart 1.2→1.3` | NO | Human approval |
| Helm chart major | `chart 1→2` | NO | Human approval + staging deploy |
| Ansible Galaxy role | any | NO | Human approval |
| pip / Go / npm | any | NO | Human approval (out of scope phase 1) |

### Per-Repo `renovate.json` Template

```json
{
  "$schema": "https://docs.renovatebot.com/renovate-schema.json",
  "extends": ["config:base"],
  "platform": "forgejo",
  "endpoint": "https://forgejo.208.haist.farm",
  "schedule": ["before 4am on Monday"],
  "packageRules": [
    {
      "description": "Auto-merge OS package patches if CI green",
      "matchDepTypes": ["os-package"],
      "matchUpdateTypes": ["patch"],
      "automerge": true,
      "automergeType": "pr",
      "requiredStatusChecks": ["ci/build", "ci/trivy"]
    },
    {
      "description": "Auto-merge container image patches if CI green",
      "matchDatasources": ["docker"],
      "matchUpdateTypes": ["patch"],
      "automerge": true,
      "automergeType": "pr",
      "requiredStatusChecks": ["ci/build", "ci/trivy"]
    },
    {
      "description": "Auto-merge Helm chart patches if CI green",
      "matchDatasources": ["helm"],
      "matchUpdateTypes": ["patch"],
      "automerge": true,
      "automergeType": "pr",
      "requiredStatusChecks": ["ci/build"]
    },
    {
      "description": "Human review for minor and major bumps",
      "matchUpdateTypes": ["minor", "major"],
      "automerge": false,
      "reviewers": ["koiakoia"]
    }
  ],
  "dependencyDashboard": true,
  "dependencyDashboardTitle": "Renovate Dependency Dashboard",
  "prHourlyLimit": 5,
  "prConcurrentLimit": 10
}
```

### Schedule Split

| Schedule | Cron | Scope |
|----------|------|-------|
| Weekly sweep | `0 2 * * 1` (Mon 02:00 UTC) | All dependency categories |
| Nightly security advisory | `0 3 * * *` (daily 03:00 UTC) | `matchCategories: ["security"]` only |

---

## 8. Phase 4 — Telegram/ntfy Alert Wiring

### Current Notification Pipeline

The platform uses **ntfy** (`https://ntfy.208.haist.farm`, namespace `health-monitoring`) as the
notification bus. Reference: `apps/health-checker/configmap.yaml` (`NTFY_URL` + `NTFY_TOPIC`).

### Renovate Alert Config Addition

```json
{
  "notifications": [
    {
      "type": "onError",
      "webhook": {
        "url": "https://ntfy.208.haist.farm/renovate-alerts",
        "method": "POST",
        "headers": {
          "Title": "Renovate error on {{repository}}",
          "Priority": "high",
          "Tags": "warning,renovate"
        },
        "body": "{{message}}"
      }
    }
  ]
}
```

**ntfy topic:** `renovate-alerts` (new; auto-creates on first POST).

**What fires:** runner errors (auth failure, rate limit, unreachable); CI failure blocking auto-merge.  
**What does NOT fire:** successful auto-merges; new minor/major PRs opened; dry-run observations.

---

## 9. Phase 5 — Repo Enablement (opt-in)

With `onboarding: true`, Renovate opens an onboarding PR per repo on first discovery. Operator
reviews and merges to activate.

### Rollout Priority

| Repo | Phase | Managers |
|------|-------|----------|
| `sentinel-admin/sentinel-iac` | **Phase 1** | Dockerfile, Ansible Galaxy |
| `sentinel-admin/overwatch-gitops` | **Phase 1** | Helm, K8s image: |
| `sentinel-admin/overwatch-console` | Phase 2 | Dockerfile, npm |
| `sentinel-admin/overwatch` | Phase 2 | pip, Dockerfile |
| `sentinel-admin/haists-website` | Phase 2 | Dockerfile |
| `sentinel-admin/compliance-vault` | Phase 3 | None (docs-only) |

### Deferred — Do Not Opt In

| Repo | Reason |
|------|--------|
| `sentinel-admin/claude-config` | Agent framework — changes affect all running sessions; manual updates only |
| `sentinel-admin/claude-memory` | Config/data, no package managers |
| `sentinel-admin/sentinel-sigma-rules` | Detection rules, not build artifacts |

---

## 10. Blast Radius + RTO/RPO

### Failure Scenarios

| Scenario | Probability | Impact | Mitigation |
|----------|-------------|--------|------------|
| Bad auto-merged image (CI false-pass) | Low | One workload degraded | Trivy + build CI gates; ArgoCD health check; revert < 30 min |
| 50+ PRs on first onboard | Medium | PR-list noise | `prConcurrentLimit: 10`; dry-run first week; staged opt-in |
| renovate-bot token invalid → 401 | Medium | Renovate silent failure | CronJob logs; ntfy error within 24 h; no prod impact |
| Major bump auto-merged (misconfigured) | Low | Breaking change | Policy matrix (§7) blocks majors; validate config before enabling |

### RTO / RPO

**RTO:** < 30 min (operator reverts to prior working image via `git revert` or Forgejo Revert button)  
**RPO:** N/A — Renovate holds no persistent data; platform services' RPO unchanged

### Renovate Isolation

CronJob in namespace `renovate` with:

- No `cluster-admin`; ServiceAccount scoped to own namespace
- NetworkPolicy: egress Forgejo (443) + ntfy (8080 in-cluster) + Vault (8200) only; deny all ingress
- Vault policy: read-only `secret/renovate/*`

---

## 11. Rollback Procedure

### Pause Auto-Merge (instant)

```bash
oc edit configmap renovate-config -n renovate
# Set "automerge": false in all packageRules
# Trigger immediate reload:
oc create job --from=cronjob/renovate renovate-reload-$(date +%s) -n renovate
```

### Suspend All Runs

```bash
oc patch cronjob renovate -n renovate -p '{"spec":{"suspend":true}}'
# Resume:
oc patch cronjob renovate -n renovate -p '{"spec":{"suspend":false}}'
```

### Full Uninstall

```bash
argocd app delete renovate --cascade
# Or: oc delete application renovate -n openshift-gitops && oc delete namespace renovate
```

### Revert a Specific Auto-Merged PR

```bash
# In the affected repo:
git revert <merge-commit-sha>
git push origin <branch>   # open PR, operator reviews
# Or: Forgejo UI → merged PR → Revert button
```

---

## 12. Dev/Sandbox Dependency Gate

### OPS-288 Status

The ideal CI gate for Renovate PRs is an integration smoke test (build image → deploy to sandbox →
hit `/healthz`). This requires OPS-288 (sandbox cluster) to be ready.

**Status as of 2026-05-23:** OPS-288 status **UNKNOWN** from this worker's vantage.

### Gate Options (operator chooses)

| Option | Condition | Approach | Trade-off |
|--------|-----------|----------|-----------|
| **A — Wait for OPS-288** | Sandbox not ready | Hold Renovate until OPS-288 done | Full smoke gate; no risk; delays benefit |
| **B — Phased pilot** | OPS-288 delayed > 2 weeks | Deploy with Trivy-only CI; auto-merge on sentinel-iac Dockerfiles only; disable overwatch-gitops auto-merge until sandbox ready | Faster; slightly higher runtime-break risk |
| **C — Workstation podman smoke** | Fast path needed | `podman pull + run --rm /healthcheck` as CI step | Cheaper than OPS-288; misses K8s-specific failures |

**Recommendation:** Option B if OPS-288 is > 2 weeks out. Start with `dryRun: "full"` first week
regardless of option chosen — operator reviews what Renovate would do before enabling any automation.

**Explicit gate:** §6 First Sync Checklist requires successful dry-run week before any PR-opening
or auto-merge. No auto-merge without that gate passing.

---

## 13. Execution Gate — Child Issue

This runbook is the planning artifact. Before executing §5–§9:

1. **Operator approves this PR** (OPS-866 → Judge review → merge)
2. **Verify OPS-863 status** — resolve before enabling auto-merge to avoid stale-fingerprint
   accumulation in DefectDojo
3. **Confirm OPS-288 status** and choose §12 option; document in child issue
4. **File execution child issue** in Plane:
   - Title: `Execute Renovate deployment — Phase 1 (sentinel-iac + overwatch-gitops)`
   - Priority: `high`
   - `modifies_files`:
     - `overwatch-gitops: clusters/overwatch/apps/renovate-app.yaml` (new)
     - `overwatch-gitops: apps/renovate/` (new directory)
     - `sentinel-iac: kubernetes/manifests/renovate/configmap.yaml` (real config values)
   - Gate: Phase 1 identity provisioning complete (renovate-bot user + Vault secret)

The planning manifests in `kubernetes/` in this PR are **never applied directly** — they exist
as review artifacts to document the intended shape before the execution child issue is filed.
