# Runbook: Falco Event Capture Path

**Issue:** OPS-205 — Falco event receiver decision + deploy
**Date:** 2026-04-30
**Author:** worker-c (WORKER agent, OPS-200 CI/CD security hardening program)

---

## Summary

This runbook documents how Falco runtime security events are captured and persisted
in the Overwatch platform. It also records the path-selection decision made under OPS-205.

---

## Architecture (as of 2026-04-30)

```
Falco DaemonSet (falco-system)
  └─ stdout_output: enabled (local container log, ephemeral)
  └─ http_output: enabled → http://falcosidekick.falco-system.svc.cluster.local:2801/
       │
       ▼
  falcosidekick Deployment (falco-system, port 2801)
       │
       └─ Elasticsearch output → https://192.168.12.100:9200
              │
              ▼
         Wazuh Indexer (OpenSearch)
           Index: falco-events
```

Events are queryable via the Wazuh Dashboard (OpenSearch Dashboards) at the
standard Wazuh UI, or via direct OpenSearch queries against the `falco-events` index.

---

## Path Selection Decision (OPS-205)

Three paths were evaluated during OPS-205:

### Path C — Wazuh node-agent stdout capture (EVALUATED FIRST, FAILED)

**Test performed 2026-04-30:**
1. Listed Wazuh agents via API (`GET /agents`): 8 agents found, all in 192.168.12.x network.
   OKD nodes (master-1: 10.128.0.246, master-2: 10.130.1.29, master-3: 10.129.0.107) have
   **no Wazuh agents**.
2. Queried Wazuh Indexer (`https://192.168.12.100:9200/wazuh-alerts-*/_search`) for Falco
   events over 48h: **0 hits**.
3. iac-control agent (ID 007) localfile config: **empty** — no /var/log/containers/* collection.

**Result: Path C NOT viable.** Falco stdout is ephemeral with no persistent capture path.

### Path B — Loki deployment (NOT selected)

No Loki deployed in overwatch-gitops. Would require a separate issue and significant
infra work. Deferred.

### Path A — falcosidekick → Wazuh Indexer (SELECTED)

**Rationale:**
- No changes to OKD nodes or Wazuh server required (all changes stay in overwatch-gitops)
- Uses existing Wazuh Indexer infrastructure
- Standard falcosidekick Elasticsearch output — no custom code
- Events are persistent and queryable via Wazuh Dashboard
- Falcosidekick port 2801 becomes the http_output target for OPS-206

---

## Falcosidekick Configuration

### Location
`overwatch-gitops/apps/falcosidekick/` — deployed by ArgoCD Application `falcosidekick`
in namespace `falco-system`.

### Key settings (from ConfigMap `falcosidekick-config`)
| Variable | Value |
|---|---|
| `ELASTICSEARCH_HOSTPORT` | `https://192.168.12.100:9200` |
| `ELASTICSEARCH_INDEX` | `falco-events` |
| `ELASTICSEARCH_TYPE` | `_doc` |
| `ELASTICSEARCH_TLSVERIFICATION` | `false` (Wazuh Indexer self-signed cert) |
| `ELASTICSEARCH_MINIMUMPRIORITY` | `notice` |
| `LISTENPORT` | `2801` |

### Credentials
Wazuh Indexer credentials are sourced from Vault at `secret/wazuh/indexer` via
ExternalSecret `falcosidekick-wazuh-indexer` in namespace `falco-system`.

---

## Verification

### 1. Check falcosidekick is running

```bash
oc -n falco-system get deploy falcosidekick
# Expected: READY 1/1

oc -n falco-system get pods -l app.kubernetes.io/name=falcosidekick
# Expected: 1/1 Running
```

### 2. Check Wazuh Indexer for Falco events

```bash
# Via iac-control (Wazuh Indexer not accessible from workstation directly)
ssh ubuntu@192.168.12.210 \
  "curl -sk -u 'admin:<password>' \
    'https://192.168.12.100:9200/falco-events/_count' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"Event count:\", d.get(\"count\", 0))'"
```

### 3. Trigger a synthetic Falco event

```bash
# Spawn a shell in any non-system container — triggers "Shell Spawned in Application Container"
oc -n <any-user-namespace> exec <any-pod> -- /bin/sh -c 'echo synthetic-test'

# Wait 30s, then verify event landed:
ssh ubuntu@192.168.12.210 \
  "curl -sk -u 'admin:<password>' \
    -X POST 'https://192.168.12.100:9200/falco-events/_search' \
    -H 'Content-Type: application/json' \
    -d '{\"query\":{\"match_phrase\":{\"output\":\"Shell spawned\"}},\"size\":1}' \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(\"Hits:\", d[\"hits\"][\"total\"][\"value\"])'"
```

---

## Troubleshooting

### falcosidekick pod not starting

```bash
oc -n falco-system describe pod -l app.kubernetes.io/name=falcosidekick
oc -n falco-system logs -l app.kubernetes.io/name=falcosidekick --previous
```

Common causes:
- ExternalSecret not synced → check `oc get externalsecret falcosidekick-wazuh-indexer -n falco-system`
- Image pull failure → check Harbor proxy or image availability

### No events in Wazuh Indexer

1. Confirm Falco http_output is enabled (OPS-206): `oc -n falco-system exec <falco-pod> -- cat /etc/falco/falco.yaml | grep -A3 http_output`
2. Check falcosidekick logs for Elasticsearch write errors: `oc -n falco-system logs -l app.kubernetes.io/name=falcosidekick`
3. Confirm NetworkPolicy allows falcosidekick → 192.168.12.100:9200 egress

### Wazuh Indexer TLS errors

If TLS verification is enabled in the future, ensure the Wazuh Indexer certificate
chain is trusted. Current setting: `ELASTICSEARCH_TLSVERIFICATION=false` (self-signed).

---

## Future improvements

1. **TLS verification**: Obtain Wazuh Indexer CA cert and enable `ELASTICSEARCH_TLSVERIFICATION=true`
2. **falcosidekick UI**: Deploy `falcosidekick-ui` for a built-in event browser (optional)
3. **Wazuh rules**: Create a Wazuh decoder + rules for the `falco-events` index so
   Falco events trigger Wazuh alerts (currently events are indexed but not rules-processed)
4. **Retention policy**: Configure OpenSearch ISM policy for `falco-events` index retention

---

## Related issues

- OPS-200: CI/CD security hardening program (parent)
- OPS-205: This issue — Falco receiver decision + deploy
- OPS-206: Enable Falco http_output → falcosidekick (HARD-BLOCKED on OPS-205)
- OPS-138: Historical — Falco crashes during configmap edits (do NOT touch plugins/engine stanzas)
