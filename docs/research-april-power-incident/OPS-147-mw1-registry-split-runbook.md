# OPS-147 — MW1 Registry Split Runbook

**Plane issue:** OPS-147
**Maintenance window:** MW1 (no cluster downtime — additive work only)
**Author:** agent-OPS-147-runbook-author, 2026-04-27
**Status:** DESIGN. YAML and commands in this document have NOT been applied. Do not apply outside of MW1.
**Sibling input:** `recovery-ledger/2026-04-27-power-incident/RESEARCH-air-gapped-fail-secure.md` §6 is the design baseline; this runbook operationalises it.
**Cluster facts (read 2026-04-27):**
- OKD `4.19.0-okd-scos.19` on three CoreOS nodes (`master-1/2/3.overwatch.haist.farm`, 10.0.0.221-223), kubelet `v1.32.7`, cri-o `1.32.4`.
- Harbor running on-cluster (`harbor` namespace), route `harbor.208.haist.farm`.
- Kyverno `verify-image-signatures` ClusterPolicy is currently `validationFailureAction: Enforce` with `failurePolicy: Ignore` and `useCache: true`. Cosign public key inlined in the policy.
- Kyverno `verify-attestations` ClusterPolicy is `validationFailureAction: Audit` (per CHANGE-002 and SEC-62) — same cosign key as `verify-image-signatures`.

---

## 0. Why this runbook exists

The April 2026 power incident (recovery-ledger/2026-04-27-power-incident) demonstrated that **placing image-signature verification at the admission webhook layer creates a recovery deadlock when the registry it depends on is itself an on-cluster pod.** Kyverno couldn't fetch signatures from Harbor; Harbor couldn't restart because Kyverno wouldn't admit its pods. The recovery action was a documented Kyverno `Enforce → Audit` flip (CHANGE-002).

MW1 closes that loop by:

1. Deploying an **off-cluster mirror-registry** that survives any cluster outage.
2. Adding an `ImageDigestMirrorSet` so cri-o falls back to that mirror when Harbor is down.
3. Migrating the cryptographic signature check from Kyverno admission to **`ClusterImagePolicy`** (cri-o pull-time).
4. Demoting Kyverno's `verify-image-signatures` to a non-cryptographic supply-chain audit role.

MW1 does **not** require any pod restarts beyond the MCO node rollout that IDMS triggers (one master at a time, drains and reboots — admission stays up). No application impact is expected.

**Authoritative references (Red Hat / OKD / Kubernetes blog):** see §11 of the sibling research doc.

---

## 1. Mirror-registry deployment

### 1.1 PVE VM creation

Stand up the registry on a PVE node whose storage is **independent of TrueNAS/iSCSI** — that independence is the entire point. Use Proxmox local-LVM (or a small dedicated zpool on local NVMe).

| Parameter | Value | Notes |
|---|---|---|
| Hostname | `mirror-registry-01.208.haist.farm` | New A record on the .208 internal DNS |
| FQDN exposed for pulls | `mirror.208.haist.farm` | CNAME → mirror-registry-01 |
| Static IP | `192.168.12.215` | Free as of 2026-04-27 — verify before allocating |
| Subnet/Gateway | 192.168.12.0/24, gw 192.168.12.1 | matches Harbor subnet for fewest firewall changes |
| OS | Rocky Linux 9.4 minimal | RH-family, podman ≥ 4.x ships in stream |
| vCPU | 4 | RH baseline is 2; we are over-provisioning a bit because oc-mirror is heavy on RAM |
| RAM | 16 GB | RH baseline is 8 GB; bumped for oc-mirror v2 buffer |
| Boot disk | 60 GB local-LVM | OS + binaries |
| Data disk | 1 TB local-LVM (`/var/lib/quay-storage`) | Mirror payload. NOT iSCSI. |
| Network | vmbr0, VLAN .208 | |
| Backup target | PBS daily, 14-day retention | Independent of cluster backup (Velero) |

### 1.2 Initial host bootstrap

Run on the new VM after first boot:

```bash
sudo dnf -y update
sudo dnf -y install podman openssl jq curl tar
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=8443/tcp   # quay https
sudo firewall-cmd --permanent --add-port=443/tcp    # haproxy/nginx fronting (optional, if we put a proxy in front)
sudo firewall-cmd --reload
sudo mkdir -p /var/lib/quay-storage /var/lib/quay-postgres /var/lib/sqlite /etc/quay-install
sudo chown -R 1001:0 /var/lib/quay-storage /var/lib/quay-postgres /var/lib/sqlite
```

### 1.3 TLS certificate provisioning

**Decision:** use a **Vault-issued cert from the existing internal PKI** (`pki_int` mount, role `208-haist-farm`). Reasons:
- Already trusted across the platform — every CoreOS node has the Vault PKI root in `/etc/pki/ca-trust/source/anchors/` via Ansible role `coreos-trust-bundle`. No additionalTrustBundle change required.
- Self-signed would require updating every node's trust bundle and rolling MachineConfig — defeats the "no cluster downtime" requirement of MW1.
- The Vault PKI root is offline-rooted, so trust does not depend on Vault liveness.

Issue + install the cert on the mirror VM:

```bash
# On the mirror VM, with VAULT_ADDR + VAULT_TOKEN set (claude-automation policy
# is sufficient — it has pki_int/issue/208-haist-farm).
vault write -format=json pki_int/issue/208-haist-farm \
  common_name=mirror.208.haist.farm \
  alt_names=mirror-registry-01.208.haist.farm \
  ttl=8760h > /tmp/mirror-cert.json

jq -r .data.certificate    /tmp/mirror-cert.json | sudo tee /etc/quay-install/quay.crt
jq -r .data.private_key    /tmp/mirror-cert.json | sudo tee /etc/quay-install/quay.key
jq -r .data.issuing_ca     /tmp/mirror-cert.json | sudo tee /etc/quay-install/ca.crt
sudo chmod 600 /etc/quay-install/quay.key
sudo chown 1001:0 /etc/quay-install/quay.{crt,key,ca.crt}
shred -u /tmp/mirror-cert.json
```

Renewal: write a cron + Vault renewal script (see OPS-148 follow-up — out of MW1 scope, document and queue).

### 1.4 mirror-registry install

Download mirror-registry and run install with explicit cert + storage paths:

```bash
curl -sLo mirror-registry.tar.gz \
  https://mirror.openshift.com/pub/cgw/mirror-registry/latest/mirror-registry-amd64.tar.gz
tar -xzf mirror-registry.tar.gz
chmod +x mirror-registry

sudo ./mirror-registry install \
  --quayHostname mirror.208.haist.farm \
  --quayRoot /var/lib/quay-storage \
  --quayStorage /var/lib/quay-storage \
  --pgStorage /var/lib/quay-postgres \
  --sqliteStorage /var/lib/sqlite \
  --sslCert /etc/quay-install/quay.crt \
  --sslKey  /etc/quay-install/quay.key \
  --initUser sentinel-mirror-admin \
  --initPassword "$(vault kv get -field=password secret/mirror-registry/admin)"
```

mirror-registry wires itself into systemd (`quay-pod.service`, `quay-app.service`, `quay-postgres.service`, `quay-redis.service`). Verify:

```bash
sudo systemctl status quay-pod.service quay-app.service quay-postgres.service quay-redis.service
curl -fsSL https://mirror.208.haist.farm:8443/health/instance
```

### 1.5 Persistent storage layout

| Path | Size budget | Backup |
|---|---|---|
| `/var/lib/quay-storage` | 800 GB used budget | PBS daily snapshot |
| `/var/lib/quay-postgres` | 5 GB | PBS daily + nightly `pg_dump` to `/srv/backup/postgres` (ages 14d, then PBS) |
| `/var/lib/sqlite` | <100 MB | Captured by PBS image-level snapshot |
| `/etc/quay-install` | < 1 MB | Captured by PBS |

The whole VM is a single PBS-backed snapshot target — that is the recovery story. We are explicitly **not** putting any of this on TrueNAS.

### 1.6 quay-postgres backup strategy

Daily logical dump, in addition to PBS image-level:

```bash
# /etc/cron.d/quay-postgres-dump
0 2 * * * root /usr/local/bin/quay-pg-dump.sh

# /usr/local/bin/quay-pg-dump.sh
#!/bin/bash
set -euo pipefail
ts=$(date +%F)
podman exec quay-postgres pg_dumpall -U quayuser \
  > /srv/backup/postgres/quay-${ts}.sql
find /srv/backup/postgres -name 'quay-*.sql' -mtime +14 -delete
```

Plus a once-weekly **restore drill** to a scratch namespace on the same VM (queued as a follow-up ops task — does not gate MW1).

---

## 2. Image content seeding

We mirror **only what the cluster needs to recover itself and run platform components**. Application images stay in Harbor.

### 2.1 What gets mirrored

- OKD 4.19 release content (`stable-4.19` channel, `quay.io/openshift-release-dev` and `quay.io/okd`).
- Operator catalog images for: Kyverno, ArgoCD, cert-manager, Keycloak.
- Platform pods we deploy directly (Kyverno controller set, cert-manager controller/webhook/cainjector, Bitnami postgres + redis as used by app charts).
- **Harbor's own image set** (so Harbor can be recovered when Harbor is down — eliminating the recursive dependency).

What does NOT get mirrored:
- Application images (`harbor.208.haist.farm/sentinel/*`) — they live in Harbor.
- Anything we don't actually run.

### 2.2 oc-mirror v2 invocation

ImageSetConfiguration: `yaml/imageset-config.yaml` (committed).

Two-step disconnected flow:

```bash
# On a workstation that has both internet egress and oc 4.19+:
oc-mirror --v2 \
  --config docs/research-april-power-incident/yaml/imageset-config.yaml \
  file:///tmp/mirror-out

# Move the resulting bundle (~50-80 GB) to the mirror VM, then on the mirror VM:
oc-mirror --v2 \
  --from file:///mnt/transfer/mirror-out \
  docker://mirror.208.haist.farm
```

oc-mirror v2 emits, alongside the push:
- `idms-oc-mirror.yaml` — cross-check against `yaml/idms.yaml` (this runbook's hand-written IDMS may add scopes oc-mirror doesn't know about, e.g. Bitnami).
- `itms-oc-mirror.yaml` — apply alongside IDMS for any image references that use tags rather than digests.
- A `cluster-resources/` directory with `signature-*` ConfigMaps that store sigstore-format signatures alongside the manifests.

### 2.3 Sigstore signatures

oc-mirror v2 mirrors the cosign signatures **alongside** the manifests in the mirror's `/v2/<repo>/manifests/sha256-<hash>.sig` storage path, so when cri-o pulls an image it can find the signature on the same registry without contacting Sigstore Rekor. This is the disconnected-friendly default for v2.

For platform-images-mirror-only (§4.1), this is the critical path: sigs come from the mirror, key is on the node, no live Sigstore call ever happens.

---

## 3. Cosign / signing key setup for `ClusterImagePolicy`

### 3.1 Two keys, two policies

**Decision: maintain two separate cosign keypairs.**

- **Harbor key (existing)** — already in use signing `harbor.208.haist.farm/sentinel/*` images via the Forgejo CI pipeline. Public key is currently inlined in `kyverno/ClusterPolicy/verify-image-signatures` (extracted 2026-04-27). Source of truth for the private half: Vault transit at `secret/data/cosign/harbor` (verify location during MW1 — if it's only inline in Kyverno, capture it back into Vault as a hardening fix in OPS-149).
- **Mirror-registry key (new)** — generated during MW1, signs images uploaded to `mirror.208.haist.farm`. Used for platform/release images going forward.

**Why two and not one:** the threat models differ. Harbor key signs developer-built app images and rotates with the CI pipeline. The mirror key signs upstream platform content we re-sign as we mirror it (so the cluster doesn't have to trust every upstream key — Quay, Red Hat, Kyverno, Bitnami). Single-key-for-everything would couple their rotation lifecycles.

### 3.2 Extract the Harbor cosign public key (already done)

```bash
ssh -i ~/.ssh/claude_jit -o CertificateFile=~/.ssh/claude_jit-cert.pub \
    ubuntu@192.168.12.210 \
    "oc get cpol verify-image-signatures -o jsonpath='{.spec.rules[0].verifyImages[0].attestors[0].entries[0].keys.publicKeys}'" \
    > /tmp/harbor-cosign.pub
base64 -w0 /tmp/harbor-cosign.pub > /tmp/harbor-cosign.pub.b64
```

The PEM:

```
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEeoZ6uG2ZJhmfixK+kqpiKQlWwJIb
n/B7orsb2bAk8l/mlmsd1jebbdtNLoG1F6qgbvqOXLDwwSqlS/qXR5kUrg==
-----END PUBLIC KEY-----
```

This is already inlined (base64) in `yaml/cip-app-images-harbor.yaml` — no further action needed before applying.

### 3.3 Generate the mirror-registry cosign key

On the mirror VM (or a workstation with cosign installed):

```bash
export COSIGN_PASSWORD="$(vault kv get -field=password secret/cosign/mirror-registry)"
cosign generate-key-pair
mv cosign.key mirror-cosign.key
mv cosign.pub mirror-cosign.pub

# Store both halves in Vault (private encrypted with the password above):
vault kv put secret/cosign/mirror-registry \
    private_key=@mirror-cosign.key \
    public_key=@mirror-cosign.pub \
    password="${COSIGN_PASSWORD}"

# Inline the public key into the CIP YAML:
KEYDATA=$(base64 -w0 mirror-cosign.pub)
sed -i "s|KEYDATA_PLACEHOLDER_BASE64_OF_MIRROR_COSIGN_PUB|${KEYDATA}|" \
    docs/research-april-power-incident/yaml/cip-platform-images-mirror.yaml
```

### 3.4 Re-sign mirrored images

After `oc-mirror --v2 ... docker://mirror.208.haist.farm` completes, re-sign the platform images with the new mirror key:

```bash
export COSIGN_PASSWORD="$(vault kv get -field=password secret/cosign/mirror-registry)"

# Iterate over manifests in the mirror under the platform paths:
for repo in openshift-release-dev okd redhat kyverno jetstack bitnami; do
  for digest in $(curl -fs -u "sentinel-mirror-admin:${MIRROR_PW}" \
        "https://mirror.208.haist.farm:8443/v2/${repo}/_catalog" \
        | jq -r '.repositories[]'); do
    cosign sign --key vault://secret/cosign/mirror-registry \
                "mirror.208.haist.farm/${repo}@sha256:${digest}"
  done
done
```

(The exact loop will be tightened during MW1 against actual catalog output — this is the shape.)

### 3.5 Key rotation story

| Key | Rotation cadence | Mechanism | Affects |
|---|---|---|---|
| Harbor cosign | Annual or on suspected compromise | New key generated, new key added as a second `publicKey` entry in `cip-app-images-harbor.yaml`, all new builds signed with new key, old key removed after 90-day overlap | App image signing |
| Mirror cosign | Annual | Same dual-publish pattern in `cip-platform-images-mirror.yaml`; re-sign mirror content with new key before retiring old | Platform/release image signing |
| Vault PKI (TLS for mirror) | 1y cert TTL, renew at 30d remaining | Cron on mirror VM, restart `quay-app.service` | Mirror TLS only |

---

## 4. ClusterImagePolicy YAML drafts

Drafted in `yaml/`:

- `yaml/cip-platform-images-mirror.yaml` — scope `mirror.208.haist.farm`, mirror cosign public key (placeholder until generated in MW1).
- `yaml/cip-app-images-harbor.yaml` — scope `harbor.208.haist.farm/sentinel`, Harbor cosign public key (extracted from existing Kyverno policy, inlined as base64).

Both use `apiVersion: config.openshift.io/v1alpha1`, `policyType: PublicKey`, `signedIdentity.matchPolicy: MatchRepoDigestOrExact` (per OKD 4.19 sigstore-using guide). PKI policyType is left for a future change (it is Developer Preview in 4.19 — do not adopt now).

---

## 5. `ImageDigestMirrorSet` YAML draft

Drafted in `yaml/idms.yaml`. Two intents bundled:

- **App images** (`harbor.208.haist.farm/sentinel`): primary = Harbor, mirror = `mirror.208.haist.farm/sentinel-mirror`, `mirrorSourcePolicy: AllowContactingSource` (so we keep using Harbor when it is healthy — fallback is for outage only).
- **Platform images** (`quay.io/openshift-release-dev`, `registry.redhat.io`, `quay.io/okd`, `ghcr.io/kyverno`, `quay.io/jetstack`, `docker.io/bitnami`): primary = mirror, **no fallback** (`mirrorSourcePolicy: NeverContactSource`). Cluster has no public-internet egress in the target air-gapped posture.

oc-mirror v2 will emit its own `idms-oc-mirror.yaml`. **Reconcile by hand** before applying — oc-mirror's output covers what oc-mirror itself mirrored, but it does not know about our `harbor → mirror` app fallback. Apply the union.

---

## 6. Kyverno demotion plan

Once `cip-app-images-harbor-signed` is rolled by MCO and verified (§7 step c), the cryptographic signature check moves to cri-o and Kyverno's signature rule becomes redundant.

### 6.1 What gets removed from `verify-image-signatures`

The entire `rules[0].verifyImages[0].attestors` block (the cosign public-key check) is removed — it is now in `cip-app-images-harbor.yaml`.

### 6.2 What gets demoted to Audit (and renamed)

The remaining policy intent is **non-cryptographic supply-chain hygiene**: that images come from the allowed Harbor path (`harbor.208.haist.farm/sentinel/*`) and are digest-pinned. Rewrite the policy to:

- Drop the `verifyImages` rule entirely (cosign moves to CIP).
- Keep / re-author a `validate` rule that asserts:
  - `image` matches `harbor.208.haist.farm/sentinel/*` for any non-system namespace.
  - `image` is digest-pinned (`@sha256:...`), not tag-only.
- Set `validationFailureAction: Audit` with `failurePolicy: Ignore`.
- Rename to `audit-image-source-allowlist` to make the new role obvious in dashboards.

### 6.3 `verify-attestations` — keep, demote, rewrite

Currently in `Audit` (per CHANGE-002 / SEC-62). It still serves a purpose cri-o cannot: parsing SLSA v1.0 provenance JSON predicates and checking `predicate.runDetails.builder.id` and `predicate.buildDefinition.externalParameters.source.repository`. cri-o does signature verification but does **not** evaluate attestation contents.

Plan:
- Keep `verify-attestations` running.
- Remove its **signature verification** clause (the `attestors` block — same key as Harbor CIP, redundant once CIP is enforcing).
- Keep its `attestations.conditions` block (the SLSA predicate check) — that is the unique value Kyverno provides here.
- Stays in `Audit` until SEC-62 follow-up confirms zero false positives.

### 6.4 Sequencing inside MW1

1. Apply IDMS, wait for MCO rollout.
2. Apply both ClusterImagePolicy CRs.
3. Run validation §7.a–§7.d.
4. Once §7.a passes (CIP enforcing on Harbor), patch `verify-image-signatures` per §6.2 (remove `verifyImages`, add `validate` block, `Audit` mode).
5. Patch `verify-attestations` per §6.3 (remove `attestors`, keep `attestations.conditions`).
6. Commit Kyverno policy changes to `overwatch-gitops` for ArgoCD sync (do not hand-patch live — both policies are ArgoCD-tracked per `argocd.argoproj.io/tracking-id`).

---

## 7. Validation procedure

Run inside MW1, after each apply step, in order:

### a. Valid signed Harbor pod admits

```bash
oc create ns mw1-test-valid
oc -n mw1-test-valid run signed-pod \
  --image=harbor.208.haist.farm/sentinel/postgres@sha256:<known-signed-digest> \
  --restart=Never -- sleep 3600
oc -n mw1-test-valid get pod signed-pod -o wide
oc -n mw1-test-valid wait --for=condition=Ready pod/signed-pod --timeout=60s
```

Expected: `Ready=True`. Cri-o log on the scheduled node should show signature verification passed (`crio[...]: Image accepted by signature policy`).

### b. Unsigned pull is denied at the runtime

```bash
# Push an unsigned test image to harbor.208.haist.farm/sentinel/mw1-unsigned:test first
# (out-of-band — operator action, not part of this script).
oc -n mw1-test-valid run unsigned-pod \
  --image=harbor.208.haist.farm/sentinel/mw1-unsigned:test \
  --restart=Never -- sleep 3600
sleep 30
oc -n mw1-test-valid describe pod unsigned-pod | grep -A5 -i 'Failed\|signature'
```

Expected: pod stuck in `ContainerCreating`; event log shows `SignatureValidationFailed` from cri-o (NOT a Kyverno admission denial — Kyverno is no longer doing this check).

### c. Harbor 503 — admission still works (the whole point)

```bash
# Save Harbor deployment scale before:
oc -n harbor get deploy -o name | xargs -I{} oc -n harbor get {} -o jsonpath='{.metadata.name} {.spec.replicas}{"\n"}' > /tmp/harbor-scale.txt
# Scale Harbor to zero:
oc -n harbor scale deploy --all --replicas=0
# Try to schedule a NEW pod from a CACHED Harbor image (one already on the node):
oc create ns mw1-test-503
oc -n mw1-test-503 run cached-app \
  --image=harbor.208.haist.farm/sentinel/<image-known-cached>@sha256:<digest> \
  --restart=Never -- sleep 3600
oc -n mw1-test-503 wait --for=condition=Ready pod/cached-app --timeout=120s
# Restore Harbor:
while read -r name replicas; do oc -n harbor scale deploy "$name" --replicas="$replicas"; done < /tmp/harbor-scale.txt
```

Expected: `cached-app` reaches Ready. With CIP, signature policy is consulted from `/etc/containers/policy.json` on local disk; with `useCache: true` no longer relevant (because Kyverno isn't gating), cri-o uses the cached image and the cached-on-disk signature blob. Admission is no longer registry-dependent.

### d. IDMS fallback works at the runtime

```bash
oc -n harbor scale deploy --all --replicas=0
oc debug node/master-1.overwatch.haist.farm -- chroot /host bash -c \
  'crictl pull harbor.208.haist.farm/sentinel/postgres:15.17-alpine3.23'
```

Expected: success. cri-o log on master-1 shows the request was redirected to `mirror.208.haist.farm/sentinel-mirror/postgres:15.17-alpine3.23`. Restore Harbor when done.

### e. Cri-o `policy.json` reflects the CIP

```bash
oc debug node/master-1.overwatch.haist.farm -- cat /host/etc/containers/policy.json | jq '.transports.docker'
oc debug node/master-1.overwatch.haist.farm -- ls -la /host/etc/containers/registries.d/
```

Expected: entries for `harbor.208.haist.farm/sentinel` and `mirror.208.haist.farm` keyed to `signedBy.publicKey` matching our keys.

### f. Compliance check unchanged

```bash
ssh ubuntu@192.168.12.210 'sudo -u sentinel /opt/sentinel/bin/nist-compliance-check.sh --json' \
  | jq '[.checks[] | select(.status=="PASS")] | length'
```

Expected: same count as pre-MW1 baseline (recorded in AGENT-STATE.md when MW1 starts). **WORKER does not assert PASS — Judge does.** Report the number, hand off.

---

## 8. Rollback procedure

If MW1 introduces an unexpected regression (e.g., a niche operator pod uses an unsigned image we forgot about and gets stuck `ContainerCreating`), back out in reverse-apply order:

```bash
# 1. Drop ClusterImagePolicy enforcement (instant — no MCO rollout needed for a CIP delete).
oc delete clusterimagepolicy app-images-harbor-signed
oc delete clusterimagepolicy platform-images-mirror-only

# 2. Drop IDMS (MCO will roll out the removal — masters drain one at a time).
oc delete imagedigestmirrorset harbor-primary-mirror-fallback

# 3. Restore Kyverno verify-image-signatures to Enforce with the original verifyImages block.
#    The original YAML is captured pre-change at: yaml/kyverno-verify-image-signatures-pre-mw1.yaml
#    (Capture during MW1 step 0 before applying anything.)
oc apply -f yaml/kyverno-verify-image-signatures-pre-mw1.yaml

# 4. Verify Kyverno is enforcing again:
oc get cpol verify-image-signatures -o jsonpath='{.spec.validationFailureAction}'  # → Enforce
```

The mirror-registry VM and its content stay up — they cause no harm even if we roll back the cluster-side changes. They just sit unused until the next attempt.

**Test pod cleanup:**

```bash
oc delete ns mw1-test-valid mw1-test-503
```

---

## Appendix A — Files in this changeset

| File | Purpose | Apply target |
|---|---|---|
| `OPS-147-mw1-registry-split-runbook.md` | This document | n/a — design only |
| `yaml/imageset-config.yaml` | oc-mirror v2 input | workstation, not cluster |
| `yaml/idms.yaml` | ImageDigestMirrorSet | cluster (MCO triggered) |
| `yaml/cip-platform-images-mirror.yaml` | ClusterImagePolicy for mirror-registry images | cluster (MCO triggered) |
| `yaml/cip-app-images-harbor.yaml` | ClusterImagePolicy for Harbor app images | cluster (MCO triggered) |

## Appendix B — Open follow-ups (file as separate Plane issues during MW1)

- **OPS-148** — Vault PKI cert renewal automation for `mirror.208.haist.farm`.
- **OPS-149** — Capture Harbor cosign private key into Vault if it is currently only inline in Kyverno (treat as hardening — out of MW1 scope).
- **SEC-62 follow-up** — flip `verify-attestations` to `Enforce` once 24h of clean Audit data confirms zero false positives. Independent of MW1.
- **OPS-150** — weekly `pg_dump` restore drill for mirror-registry quay-postgres.

## Appendix C — Why NOT just delete Kyverno's signature policy

Two reasons we keep it (in Audit, rewritten):

1. **Defense in depth at the namespace boundary.** ClusterImagePolicy enforces at the node, but namespace-scoped `ImagePolicy` per-namespace overrides exist. A Kyverno audit gives us a second observation point that does not depend on per-node MCO rollouts being in sync.
2. **Audit log continuity.** AU-12 maps onto the Kyverno PolicyReports that downstream reporting tools already consume. Switching cleanly to a cri-o-only model would orphan that pipeline. Keep Kyverno emitting reports while we migrate consumers.

The new role of Kyverno here is **policy-on-top-of-signatures**, not the signatures themselves — which matches both the K8s sig-node blog framing and the Red Hat Developers article on disconnected signature verification (sources in sibling §7).
