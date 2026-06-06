# Backstage Catalog Schema — Project Sentinel

This document describes the conventions for `catalog-info.yaml` entities in the
Project Sentinel platform. All catalog entities live in
[`overwatch-gitops/backstage-catalog/`](https://forgejo.208.haist.farm/sentinel-admin/overwatch-gitops/src/branch/main/backstage-catalog/)
and per-service `catalog-info.yaml` files in the apps tree.

A machine-readable JSON Schema is provided at
[`tooling/catalog-schema/schema.json`](../tooling/catalog-schema/schema.json)
and is consumed by the L1 CI composite (OPS-232).

---

## Quick Reference

| Field | Required? | Notes |
|---|---|---|
| `apiVersion` | **Required** | Must be `backstage.io/v1alpha1` |
| `kind` | **Required** | `Component`, `Resource`, `API`, `System`, `Group`, `User`, or `Location` |
| `metadata.name` | **Required** | Lowercase, hyphens only, max 63 chars |
| `metadata.description` | Recommended | One sentence describing the entity |
| `spec.type` | **Required** (Component/Resource/API) | See per-kind type enums below |
| `spec.lifecycle` | **Required** (Component/Resource/API) | `production`, `experimental`, or `deprecated` |
| `spec.owner` | **Required** (Component/Resource/API) | Must be `platform-team` for sentinel infra |
| `spec.system` | **Required** (Component/Resource/API) | Must be `sentinel-platform` |

---

## API Version

All sentinel platform catalog entities use:

```yaml
apiVersion: backstage.io/v1alpha1
```

---

## Kinds

### `Component` — Deployed Services

Use `Component` for software that runs somewhere: OKD workloads, VM daemons,
LXC services.

**Required spec fields:** `type`, `lifecycle`, `owner`, `system`

**Allowed `spec.type` values:**

| Type | Use case |
|---|---|
| `service` | Any deployed backend service or OKD workload |
| `website` | User-facing web applications |
| `library` | Shared code libraries |
| `pipeline` | CI/CD pipelines |
| `database` | Database backends |
| `operator` | Kubernetes Operators (OLM or Helm) |
| `proxy` | Reverse proxies, ingress controllers |
| `agent` | Background agents, automation workers |

**Optional spec fields:**

- `dependsOn`: list of `component:<name>` or `resource:<name>` refs
- `providesApis`: list of API entity names this component exposes
- `consumesApis`: list of API entity names this component consumes
- `subcomponentOf`: parent component name (for subcomponents)

**Example:**

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: grafana
  description: Observability dashboards and alerting platform
  annotations:
    backstage.io/kubernetes-namespace: monitoring
    backstage.io/kubernetes-label-selector: app.kubernetes.io/name=grafana
    backstage.io/techdocs-ref: "dir:../../techdocs/grafana"
    argocd/app-name: grafana
    grafana/dashboard-url: https://grafana.208.haist.farm
  tags:
    - monitoring
    - observability
    - overwatch
spec:
  type: service
  lifecycle: production
  owner: platform-team
  system: sentinel-platform
  dependsOn:
    - component:keycloak
  providesApis:
    - grafana-api
```

---

### `Resource` — Infrastructure

Use `Resource` for infrastructure that services depend on: VMs, LXC containers,
Proxmox hypervisors, the OKD cluster, storage systems, network devices.

**Required spec fields:** `type`, `lifecycle`, `owner`, `system`

**Allowed `spec.type` values:**

| Type | Use case |
|---|---|
| `vm` | Virtual machines (Vault, Wazuh, pangolin-proxy, etc.) |
| `lxc` | LXC containers |
| `hypervisor` | Proxmox VE hosts |
| `compute-cluster` | Proxmox cluster, OKD cluster aggregate |
| `kubernetes-cluster` | OKD 4.x / Kubernetes cluster |
| `database` | External databases (PostgreSQL, etc.) |
| `storage` | NFS, MinIO, TrueNAS, PVC |
| `network-device` | Switches, routers, UCG-Fiber |
| `nas` | TrueNAS SCALE |
| `ups` | UPS power supply units |
| `pdu` | Power distribution units |

**Example:**

```yaml
apiVersion: backstage.io/v1alpha1
kind: Resource
metadata:
  name: vault-server
  description: HashiCorp Vault secrets management and JIT SSH certificate authority
  annotations:
    sentinel.platform/lan-ip: "192.168.12.206"
    sentinel.platform/vlan: servers
    sentinel.platform/runbook-url: https://forgejo.208.haist.farm/sentinel-admin/sentinel-iac/src/branch/main/docs/runbooks/vault.md
  links:
    - url: https://vault.208.haist.farm
      title: Vault UI
      icon: dashboard
  tags:
    - secrets
    - security
    - vm-service
    - overwatch
spec:
  type: vm
  lifecycle: production
  owner: platform-team
  system: sentinel-platform
  dependsOn:
    - resource:proxmox-208-pve2
```

---

### `API` — Service Interfaces

Use `API` for formal API contracts: REST APIs, OIDC providers, S3 endpoints.

**Required spec fields:** `type`, `lifecycle`, `owner`, `system`, `definition`

**Allowed `spec.type` values:**

| Type | Use case |
|---|---|
| `openapi` | OpenAPI/Swagger REST APIs (most common) |
| `asyncapi` | Event-driven / messaging APIs |
| `graphql` | GraphQL APIs |
| `grpc` | gRPC services |

**Example:**

```yaml
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: vault-secrets-api
  description: HashiCorp Vault KV v2 secrets API
  tags:
    - secrets
    - vault
    - overwatch
spec:
  type: openapi
  lifecycle: production
  owner: platform-team
  system: sentinel-platform
  definition: |
    openapi: 3.0.0
    info:
      title: Vault Secrets API
      version: "v2"
    servers:
      - url: https://vault.208.haist.farm/v1
    paths:
      /secret/data/{path}:
        get:
          summary: Read a secret
```

---

### `System` — Platform Grouping

The top-level system entity. All sentinel platform entities must set
`spec.system: sentinel-platform`.

The system entity itself lives at
[`overwatch-gitops/catalog-info.yaml`](https://forgejo.208.haist.farm/sentinel-admin/overwatch-gitops/src/branch/main/catalog-info.yaml).

---

### `Group` and `User` — Org Entities

Org entities live in
[`backstage-catalog/org/`](https://forgejo.208.haist.farm/sentinel-admin/overwatch-gitops/src/branch/main/backstage-catalog/org/).

- **Groups:** `platform-team`, `admin`
- **Users:** `koiakoia`, `admin`

`spec.owner` on all Component/Resource/API entities must reference a Group or
User name defined here. Current sentinel platform owner: `platform-team`.

---

## Standard Annotations

### Backstage Built-in Annotations

| Annotation | Kind | Description |
|---|---|---|
| `backstage.io/source-location` | All | Source code URL, e.g. `url:https://forgejo.208.haist.farm/sentinel-admin/<repo>` |
| `backstage.io/techdocs-ref` | All | TechDocs source. Use `dir:<relative-path>` for same-repo docs or `url:https://...` for cross-repo. |
| `backstage.io/kubernetes-namespace` | Component | K8s namespace the workload runs in |
| `backstage.io/kubernetes-label-selector` | Component | K8s label selector for workload discovery, e.g. `app.kubernetes.io/name=grafana` |
| `argocd/app-name` | Component | ArgoCD application name (ArgoCD-managed components only) |
| `grafana/dashboard-url` | Component/Resource | URL to the Grafana dashboard for this service |

### Sentinel Platform Custom Annotations (Net-New)

These are operator-defined annotations introduced in OPS-227. They use the
`sentinel.platform/` prefix (not `backstage.io/*`) to avoid namespace collision.

| Annotation | Kind | Description |
|---|---|---|
| `sentinel.platform/lan-ip` | Resource (VM/LXC) | LAN IP of the service or VM, e.g. `192.168.12.206` |
| `sentinel.platform/vlan` | Resource | VLAN name or ID, e.g. `servers`, `iot`, `mgmt` |
| `sentinel.platform/runbook-url` | All | Full URL to the operational runbook in Forgejo |

---

## Tags

Tags are lowercase, hyphenated strings. The tag `overwatch` is a platform-wide
convention applied to all sentinel entities to enable cross-catalog filtering.

**Common tags in use:**

`monitoring`, `observability`, `security`, `networking`, `gitops`, `infrastructure`,
`messaging`, `database`, `identity`, `oidc`, `sso`, `secrets`, `operator`,
`overwatch`, `homelab`, `okd`, `proxmox`, `istio`, `service-mesh`, `storage`,
`vm-service`, `argocd`

---

## Naming Conventions

- Names must be **lowercase alphanumeric with hyphens** only: `^[a-z0-9-]+$`
- Maximum 63 characters (Kubernetes label constraint; Backstage EntityRef inherits it)
- Names must be unique within a `(kind, namespace)` pair
- Use the service's canonical short name: `grafana`, `vault-server`, `okd-cluster`
- Multi-instance services append a suffix: `proxmox-pve`, `proxmox-208-pve2`, `proxmox-pve3`

---

## `spec.system` Constraint

All Component, Resource, and API entities in the sentinel platform **must** set:

```yaml
spec:
  system: sentinel-platform
```

The `sentinel-platform` System entity is defined in
`overwatch-gitops/catalog-info.yaml`.

---

## `spec.lifecycle` Values

| Value | Meaning |
|---|---|
| `production` | Live, operator-dependent service |
| `experimental` | Development/staging, not critical-path |
| `deprecated` | Sunset pending, no new dependsOn allowed |

---

## Validation

The JSON Schema at `tooling/catalog-schema/schema.json` can be used to validate
catalog entries with [ajv-cli](https://github.com/ajv-validator/ajv-cli):

```bash
# Install ajv-cli (node >= 18)
npm install -g ajv-cli

# Validate a single file (YAML must be pre-converted to JSON, or use ajv with --spec=draft2020)
ajv validate \
  --spec=draft2020 \
  -s tooling/catalog-schema/schema.json \
  -d <(python3 -c "import sys,yaml,json; print(json.dumps(yaml.safe_load(open('$FILE'))))")

# Or use the L1 CI composite (OPS-232)
# .forgejo/actions/backstage-validate/action.yml
```

Example fixtures are in `tooling/catalog-schema/examples/`:

| File | Validates? | Purpose |
|---|---|---|
| `component-example.yaml` | PASS | Minimal valid Component entity |
| `resource-example.yaml` | PASS | Valid Resource (VM) with net-new annotations |
| `api-example.yaml` | PASS | Valid API entity with inline definition |
| `invalid-example.yaml` | **FAIL** | Missing required `spec.lifecycle`, `spec.owner`, `spec.system` |

---

## Related Issues

- **OPS-227** — Backstage catalog health + schema: master tracking issue
- **OPS-230** (this work) — Schema doc + JSON Schema authoring
- **OPS-231** — Add catalog-info.yaml to apps/ dirs in overwatch-gitops
- **OPS-232** — L1 CI composite: schema-lint + catalog-API registration check
