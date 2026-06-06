# OPS-152 — OKD 4.19 → 4.20 → 4.21 Upgrade Runbook (MW2)

**Issue:** OPS-152 (MW2 of the post-power-incident recovery plan)
**Date authored:** 2026-04-27
**Status:** Draft / research + design only. No infra changes performed.
**Scope:** Step-by-step upgrade procedure for the 3-node compact OKD cluster
(`master-1/2/3.overwatch.haist.farm`), assuming MW1 (OPS-148/149/150) is complete:
out-of-band mirror-registry exists on a PVE VM, `ClusterImagePolicy` carries the
crypto load, and an `ImageDigestMirrorSet` lists Harbor primary / mirror-registry
fallback. Stateful workloads will be **scaled to zero** before MW2 starts; only
the control plane and gitops stay running.

**Cluster baseline (verified read-only via `iac-control` 2026-04-27):**

- ClusterVersion: `4.19.0-okd-scos.19` (Available=True, Progressing=False, 91d)
- 3× master+worker nodes, all Ready, kubelet `v1.32.7`, cri-o `1.32.4`, OS `CentOS Stream CoreOS 9.0.20250827-0`
- All 35 ClusterOperators Available=True, none Degraded
- No `00-override-{master,worker}-generated-crio-default-container-runtime` MachineConfigs present (cluster installed at 4.19; the runc→crun override only existed on clusters installed ≤4.18). The §6 risk in `RESEARCH-okd-upgrade.md` does not apply here. **Verified.**
- v1beta1 admission webhooks present that need vetting before the 4.19→4.20 ack:
  `cluster-baremetal-validating-webhook-configuration`, `externalsecret-validate`, `secretstore-validate`. None of these is Kyverno; Kyverno's webhooks are already v1-only on this cluster.

**Sibling research (cite, do not duplicate):**

- `/home/koiakoia/recovery-ledger/2026-04-27-power-incident/RESEARCH-okd-upgrade.md` — upgrade path, FCOS→SCOS-10, oc-mirror v2, prerequisites, per-version highlights, iSCSI uncertainty.
- `/home/koiakoia/recovery-ledger/2026-04-27-power-incident/RESEARCH-air-gapped-fail-secure.md` — registry split, IDMS, ClusterImagePolicy.

This runbook **assumes** the reader has read those. Where they cover something, this document references rather than restates.

---

## 1. Pre-mortem matrix

Each row: failure scenario → detection signal → exit/recovery path. The matrix is
ordered roughly by likelihood.

| # | Failure scenario | Detection signal | Exit / recovery path |
|---|---|---|---|
| 1 | **MCO drain stalls on a master** (PDB, stuck pod, finalizer, dynamic in-tree iSCSI inline volume not releasing) | `oc get mcp master` shows `UPDATING=True` for >25 min on the same node; `oc get nodes` shows the node `SchedulingDisabled` with pods still Terminating; MCO log in `openshift-machine-config-operator` shows "evicting pod" loops | (a) Identify stuck pod: `oc get pods -A --field-selector spec.nodeName=<node>` filter Terminating. (b) If it's a stateful workload that should already be scaled-to-zero, scale its owning Deployment/StatefulSet replicas=0 and let it terminate. (c) If it's a daemon with a finalizer, `oc patch ... -p '{"metadata":{"finalizers":[]}}' --type=merge`. (d) Last resort: cordon node, force-delete pod with `--grace-period=0 --force`. (e) If drain still won't progress after 45 min total, **abort the hop** — `oc adm upgrade --clear` and triage. Do not let MCO sit in this state across more than one master. |
| 2 | **Etcd quorum loss during a master reboot** (second master goes NotReady before the first is back) | `oc get cs` reports etcd unhealthy; `oc get etcd -o yaml` shows fewer than 2 healthy members; `kube-apiserver` starts returning 5xx; `oc` commands time out | This is the catastrophic case. Stop touching the cluster. (a) Wait 10 min — most often it self-heals once the rebooting master returns. (b) If a second reboot was triggered prematurely by MCO on a 1-master-Ready cluster, that's an MCO bug or a max-unavailable misconfig — verify `oc get mcp master -o yaml` shows `maxUnavailable: 1`. (c) If quorum is genuinely lost, **execute the etcd restore procedure** (§3) on the surviving master using the most recent verified backup. Document this in OPS-152 as a `BLOCKER` and ping operator. |
| 3 | **Image pull failure through the mirror** (mirror-registry down, IDMS misconfigured, network path to mirror VM broken) | Node events show `ErrImagePull` / `ImagePullBackOff`; cri-o journal: `unable to pull from any mirror`; pods stuck `ContainerCreating` after MCO reboot | (a) Verify mirror-registry health from `iac-control`: `curl -k https://mirror.208.haist.farm:8443/v2/_catalog`. (b) If unreachable: this blocks the upgrade until it returns. Do not initiate next hop. (c) On the cluster, verify IDMS reflected on disk: `oc debug node/master-1 -- chroot /host cat /etc/containers/registries.conf.d/01-image-searchRegistries.conf`. (d) If mirror is healthy but pulls still fail, check ClusterImagePolicy didn't inadvertently scope to the *wrong* mirror hostname. (e) Already-cached images on each master keep already-running pods alive; this only blocks new pulls (which is what MCO does on every node reboot). |
| 4 | **CRI-O fails to restart post-MachineConfig update** (config rendered with bad TOML, conflicting drop-in, kernel module missing on SCOS-10) | Node stuck `NotReady` post-reboot; `oc debug node/<node>` works (kubelet up partially) but `crictl ps` errors; node MCDaemon log: `crio.service: Failed with result 'exit-code'`; `journalctl -u crio` shows config parse error | (a) `oc debug node/<node>` → `chroot /host` → `journalctl -u crio --no-pager \| tail -200`. (b) Inspect `/etc/crio/crio.conf.d/` for the offending drop-in. (c) If a custom MC injected something incompatible with SCOS-10 (e.g., references runc binary), the fix is to delete that MC and let MCO re-roll. (d) Use rpm-ostree rollback as last resort: `rpm-ostree rollback` from the node console — **this rolls back only the OS deployment, not the rendered MC**, so MCO will try to re-apply on next reconcile. Buys time, doesn't fix root cause. |
| 5 | **OVN-Kubernetes plugin fails to come back** post-reboot | Node `NotReady` with `NetworkPluginNotReady`; pods on that node stuck `ContainerCreating` with `network: cni plugin not initialized`; `ovnkube-node` pod CrashLoopBackOff | (a) `oc -n openshift-ovn-kubernetes logs ovnkube-node-<id> -c ovnkube-controller`. (b) Common cause across major hops: OVS DB schema mismatch when northd version on master nodes drifts during rolling upgrade. Wait for all OVN pods to land on the new image; OVN tolerates one-version-skew. (c) If OVN northd never converges, `oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-control-plane` to force fresh leader election. (d) If only one node is broken: the broken node's `ovs-vswitchd` may need a restart from the host: `oc debug node/<node> -- chroot /host systemctl restart ovs-vswitchd` (no data loss; OVN reprograms flows from northd). |
| 6 | **Signature verification failure post-ClusterImagePolicy migration** (ClusterImagePolicy from MW1 doesn't match the new release image's actual cosign signature path / key) | Node events: `SignatureValidationFailed: failed to verify signature`; cri-o log: `image policy denied`; release-image pull denied even from the mirror | (a) Check the platform-image ClusterImagePolicy: `oc get clusterimagepolicy openshift-platform-image -o yaml`. The 4.20 release default policy targets the OKD release signing key. If MW1 tightened scopes, our policy may not cover the new release tag. (b) Workaround for the upgrade window: temporarily widen the scope to include `quay.io/okd` and the mirror release scope. (c) Permanent fix: update ClusterImagePolicy to include the 4.20/4.21 release-image scope before each hop. **Validate before each hop with a dry-run pull** from `iac-control`: `skopeo inspect --tls-verify=false docker://mirror.208.haist.farm:8443/okd-release@sha256:<digest>`. |
| 7 | **Custom MachineConfig conflicts with new RHCOS/SCOS layer** (especially 4.19→4.20 because OS base swaps from CentOS Stream CoreOS 9 to SCOS 10) | MCO degraded: `oc get co machine-config` shows DEGRADED=True; rendered MC fails to apply on first node; node stuck in `Working` MCD state | Custom MCs on this cluster (verified 2026-04-27): `99-master-iscsi-initiator`, `99-master-sysctl-ovs-buffer`, `99-master-ssh`, `99-worker-ssh`. (a) `99-master-iscsi-initiator` injects an `/etc/iscsi/initiatorname.iscsi` — **highest risk** for SCOS 10 because the iscsid systemd unit and config layout may have moved. Pre-check: `ssh core@10.0.0.221 sudo systemctl cat iscsid` against the SCOS-10 release image config. If the unit moved, this MC needs updating before the hop. (b) `99-master-sysctl-ovs-buffer` is a sysctl drop-in — low risk, sysctl format is stable. (c) SSH MCs — low risk, just authorized_keys. (d) If MCO degrades: `oc get mcp master -o yaml \| grep -A 5 conditions` for the specific reason; delete the offending MC and re-roll. |
| 8 | **`oc adm upgrade` rejects the target version** (no edge from current to target in the cincinnati graph reachable through the mirror) | `oc adm upgrade --to=...` returns "no upgrade can be made from ... to ...". | (a) Most likely cause: mirror-registry isn't serving the cincinnati graph for our channel. With oc-mirror v2 disconnected setup, you typically need `oc adm upgrade --to-image=<digest>` rather than `--to=<version>` because the cluster has no upstream graph URL. (b) Use the digest form (see §5 per-hop commands). (c) Confirm the channel: `oc get clusterversion -o jsonpath='{.spec.channel}'` should be `stable-4.19`/`stable-4.20`/etc. before each hop. |
| 9 | **GitOps reconciles a manifest mid-upgrade and forces a restart loop** | argocd-application-controller logs show OutOfSync→Sync→OutOfSync flapping during MCO reboots; healthy components keep getting their pods restarted | Pre-emptively suspend ArgoCD auto-sync for in-cluster apps before initiating the hop: `oc -n openshift-gitops patch applicationset/<name> --type=merge -p '{"spec":{"template":{"spec":{"syncPolicy":{"automated":null}}}}}'` or simpler — pause the relevant Applications via `argocd app set ... --sync-policy none`. Re-enable post-hop. |
| 10 | **In-tree iSCSI inline-volume pod fails to terminate during drain** | Pod Terminating for >5 min; PV finalizers stuck; iscsid sessions on the node still attached | This should not arise during MW2 because stateful workloads are scaled to zero before MW2 starts. If it does (e.g., a Deployment was forgotten): scale its replicas=0; if a finalizer is jammed, `oc patch pv/<name> -p '{"metadata":{"finalizers":null}}' --type=merge`. Sibling research §6 flags this as the highest-uncertainty class on this cluster — OPS-151 retires the risk by migrating to CSI before MW2; this runbook assumes that MW1.5 work is complete. **Confirm before MW2 begins:** `oc get pv -o json \| jq '.items[] \| select(.spec.iscsi != null) \| .metadata.name'` returns nothing. |

---

## 2. Wall-clock per hop

Estimates assume:
- Mirror-registry is **warm** (release content already mirrored before MW2; not pulling from internet during the upgrade).
- Stateful workloads are scaled to zero (drain is fast).
- 1 master at a time (default `maxUnavailable: 1` on the master MCP — do not change).

| Phase | Duration | Notes |
|---|---|---|
| **Hop A: 4.19 → 4.20 (the structural hop)** | | |
| Pre-flight (admin-acks, custom MC audit, etcd backup, IDMS validation, dry-run image pulls) | 30–45 min | One-time per hop. See §4. |
| `oc adm upgrade` accepted, control plane operators upgrade (kube-apiserver, etcd, etc.) | 25–40 min | Rolling restarts of static pods on each master, one at a time. Most cluster operators settle here before MCO touches nodes. |
| MCO master rollout (3 nodes × ~20 min each, serial) | 60–75 min | Each node: drain (fast, since scaled-to-zero) + rpm-ostree stage (FCOS→SCOS-10 is a base swap, **adds 5–10 min vs. patch hop**) + reboot + crio + kubelet + Ready. |
| Cluster operator stabilisation post-MCO | 15–25 min | OVN reprograms, image-registry, console, monitoring catch up. |
| Smoke test (§6) | 10–15 min | |
| **Hop A total** | **~2.5–3.5 hours** | Drive this estimate with the OS-base-swap as the slowest factor. |
| **Hop B: 4.20 → 4.21** | | |
| Pre-flight (mirror 4.21 release content, refresh IDMS, etcd backup, ClusterImagePolicy scope check) | 20–30 min | Less work than Hop A — no new admin-ack class expected; verify against the 4.20→4.21 prep doc at upgrade time. |
| Control plane operators upgrade | 20–30 min | |
| MCO master rollout (3 × ~15 min) | 45–55 min | Patch-style hop within SCOS-10 line; no OS-base swap; faster. |
| Cluster operator stabilisation | 10–20 min | |
| Smoke test | 10–15 min | |
| **Hop B total** | **~2 hours** | |
| **Inter-hop verification window** | 30–60 min | Do not chain hops back-to-back. Confirm Hop A is genuinely stable (clusteroperators idle for ≥30 min, no pod restart spam) before initiating Hop B. |
| **Grand total (Hop A + window + Hop B + final smoke + bring-up)** | **~6–8 hours** | Plan for a single-day MW with a 2-hour buffer. |

**Justification:** Per-master MCO-driven reboot of 15–25 min is the OKD-documented
ballpark for compact-cluster master upgrades (sibling research §3, citing
[OKD 4.20 release notes](https://okd.io/blog/2025/09/30/okd-4.20-release-notes/)
and [node rebooting docs](https://docs.okd.io/latest/nodes/nodes/nodes-nodes-rebooting.html)).
The 4.19→4.20 hop adds OS-base-swap time because rpm-ostree must lay down a fresh
SCOS-10 deployment alongside the running CSCOS-9 deployment before flipping the
bootloader (sibling §4). Image pull time is dominated by the new release image
(~1 GB) plus per-component images (~20–30 images, mostly cached) — at gigabit LAN
speed from the mirror VM that's tens of seconds per node, not the bottleneck.
Stabilisation windows are operator-experience estimates; OKD does not document
fixed SLAs.

---

## 3. Etcd backup + restore rehearsal

### 3.1 Backup procedure

Mandatory before each hop. One backup from each of the three masters; pull all
three off-cluster.

```bash
# From iac-control, for each master in master-1/master-2/master-3:
NODE=master-1.overwatch.haist.farm
oc debug node/${NODE} -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
# Output: snapshot db file + static-kuberesources tarball in /home/core/assets/backup/<timestamp>/
```

Pull off the node:

```bash
mkdir -p ~/etcd-backups/$(date +%Y%m%d)-pre-4.20
for n in 221 222 223; do
  scp -i ~/.ssh/okd_key -r core@10.0.0.${n}:/home/core/assets/backup/* \
    ~/etcd-backups/$(date +%Y%m%d)-pre-4.20/${n}/
done
```

### 3.2 Validating the backup is good (not a placebo)

A backup that exists but is corrupt or wrong-version is worse than no backup.
Before MW2, confirm each backup with:

```bash
# 1. File presence and non-zero size:
ls -la ~/etcd-backups/<dir>/<host>/<timestamp>/
# Expect: snapshot_<timestamp>.db   (typically 80–500 MB on a healthy cluster)
#         static_kuberesources_<timestamp>.tar.gz

# 2. Snapshot integrity:
etcdutl snapshot status snapshot_<timestamp>.db --write-out=table
# Expect: hash, revision, total keys, size in bytes — all populated, no error.

# 3. Snapshot corruption check:
etcdutl snapshot status --check snapshot_<timestamp>.db
# Expect: clean exit, no "checksum mismatch".

# 4. Rough sanity on key count: should be in the same order of magnitude across
#    all three masters (one master holds the leader's view but all serve the same
#    raft log). A backup with 1/10 the keys of the others is suspect.
```

If any of those fail, **discard that backup and re-take from that master.** A
backup from a master with a degraded etcd member is not a recovery option.

### 3.3 Restore rehearsal — the test-restore problem

The OKD doc procedure is "stop kubelet on all masters, run `cluster-restore.sh`
on one master, restart everything." Doing this on the actual production cluster
to "test" is not a rehearsal — it's a production outage with extra steps. So:

**Recommended rehearsal model: sandbox single-node OKD on PVE.**

- Stand up a single-node OKD cluster (SNO) on a small PVE VM. Same major version
  (4.19) as the source.
- Take an etcd backup on that SNO.
- Run `/usr/local/bin/cluster-restore.sh` on the SNO using the backup. Confirm
  the cluster comes back. This validates the operator's muscle memory and the
  command sequence; it does **not** validate that *our specific cluster's*
  backup will restore (different cert chains, different cluster ID), but that's
  a structural limitation of restore-rehearsal.
- This SNO can be reused as a general staging cluster after MW2.

**Alternative if SNO sandbox isn't available:** do a "paper rehearsal" — walk
through the [OKD 4.19 disaster-recovery doc](https://docs.okd.io/4.19/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-2-restoring-cluster-state.html)
step-by-step with one operator reading and one operator confirming "yes I have
that file / yes I know which master will be primary." This is weaker than
a real rehearsal but better than no rehearsal.

**Cadence:** Once before MW2 starts. Then a fresh backup (no rehearsal needed
again) immediately before each hop. The rehearsal builds operator confidence;
the per-hop backups are the actual recovery artifacts.

### 3.4 Restore procedure (only invoked under §1 row 2, etcd quorum loss)

Reference: [OKD 4.19 restore docs](https://docs.okd.io/4.19/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-2-restoring-cluster-state.html).
Summary, not substitute:

1. Choose the master that will host the restored etcd. Prefer the master with
   the most recent backup file already on disk.
2. SSH to it as `core`, `sudo` the rest.
3. On the **other two masters**: stop the static pods (`mv` the manifests out
   of `/etc/kubernetes/manifests/`).
4. On the **chosen master**: run `/usr/local/bin/cluster-restore.sh /home/core/assets/backup/<latest>`.
   This restarts etcd as a single-member cluster from the snapshot.
5. On the other two masters: re-add their etcd manifests; they rejoin as new
   members and resync from the leader.
6. `oc get etcd -o yaml` should eventually show 3 members all `Ready=True`.
7. Cluster operators may show degraded for a long time (cert rotation runs
   automatically); leave it for at least 30 min before manual intervention.

**Restore is destructive** to any cluster state that changed between the backup
time and the restore time. If MW2 was the cause of the quorum loss, no
work-state was at risk (workloads scaled to zero), so "lost data since the
backup" is irrelevant — the only loss is upgrade progress, which is exactly
what we want to lose.

---

## 4. Pre-flight steps (in order)

Verified-applicable items in **bold**; sibling-research items are referenced not
restated.

1. **Confirm MW1 prerequisites are in place:**
   - `oc get clusterimagepolicy` returns at least one policy covering Harbor and the off-cluster mirror (OPS-149).
   - `oc get imagedigestmirrorset` shows Harbor primary, mirror.208.haist.farm fallback (OPS-150).
   - `curl -kI https://mirror.208.haist.farm:8443/v2/` returns 200/401 (registry alive).
   - Mirror-registry contains both 4.20 *and* 4.21 release content, plus operator catalogs, plus signatures (oc-mirror v2 output verified).
2. **Confirm OPS-151 (in-tree iSCSI → CSI migration) is complete:** `oc get pv -o json | jq '[.items[] | select(.spec.iscsi != null)] | length'` returns `0`. Sibling research §6 marks this as the highest-uncertainty risk; if not done, do not start MW2.
3. **Scale stateful workloads to zero** (operator framing — MW2 doesn't plan around live data plane). Track which were scaled in a list to drive §8 bring-up order. Suspend ArgoCD automated sync on the affected Applications so they don't immediately re-scale.
4. **Etcd backup × 3 masters, validated per §3.2.** Confirm files exist off-cluster.
5. **Custom MachineConfig audit** (cluster has 4 custom MCs; see §1 row 7):
   - `oc get mc 99-master-iscsi-initiator -o yaml` — confirm it's only writing `/etc/iscsi/initiatorname.iscsi`. After OPS-151 the iscsi-initiator MC may itself be removable; if so, delete it pre-flight to eliminate the SCOS-10 risk class.
   - `99-master-sysctl-ovs-buffer`, `99-master-ssh`, `99-worker-ssh` — quick visual scan, low risk.
6. **runc-override MachineConfig check (sibling research §6):** `oc get mc | grep override` — **already verified empty on this cluster on 2026-04-27**. No deletion needed. The risk class doesn't apply because this cluster was installed at 4.19.
7. **v1beta1 admissionregistration audit + admin-ack (sibling research §2):**
   - Cluster currently has v1beta1 webhooks: `cluster-baremetal-validating-webhook-configuration` (platform-managed, becomes v1-only when the operator upgrades — safe), `externalsecret-validate` and `secretstore-validate` (both from external-secrets-operator — needs ESO version bump if it's an old v1beta1-only build; check `oc -n external-secrets get pods -o yaml | grep image:`).
   - After confirming nothing user-managed depends on v1beta1 admission, apply the ack:
     ```bash
     oc -n openshift-config patch cm admin-acks --type=merge \
       --patch '{"data":{"ack-4.19-admissionregistration-v1beta1-api-removals-in-4.20":"true"}}'
     ```
   - Source: [OKD 4.20 upgrade prep](https://docs.okd.io/4.20/updating/preparing_for_updates/updating-cluster-prepare.html).
8. **Operator compatibility check (sibling research §4):** Confirm OpenShift GitOps subscription is on a channel that supports both 4.19 and 4.20 (1.19.x or 1.20.x). Confirm Kyverno version supports k8s 1.33. If Kyverno needs a bump, do that *before* the OKD upgrade, not during.
9. **Run `kubent` against the cluster** (OPS-153 deliverable) to surface any remaining v1beta1/v1alpha1 API usage in user manifests. Resolve hits or accept them as known issues.
10. **Confirm cluster channel:**
    ```bash
    oc patch clusterversion/version --type=merge --patch '{"spec":{"channel":"stable-4.19"}}'
    # or for hop B: stable-4.20
    ```
    In a fully disconnected setup, the cluster will not actually fetch the cincinnati graph from the channel — the channel string is metadata only — but having it set correctly avoids confusion in `oc adm upgrade` output.
11. **Pause GitOps automated sync for in-cluster Applications.** ArgoCD doesn't know that a rolling reboot of the masters means "don't reconcile the world right now." Pause Applications that touch `openshift-*` namespaces.
12. **Final go/no-go on iac-control health:** since iac-control is the only path to the cluster console + the SSH bastion, a brownout there during MW2 is unrecoverable. Verify Vault is unsealed, SSH CA cert is valid for the duration, NFS/iSCSI to TrueNAS is healthy.

---

## 5. Per-hop step-by-step

### 5.1 Hop A: 4.19.0 → 4.20.x

**Identify target version and digest.** From the mirror-registry, find the 4.20.z
that was mirrored (assume `4.20.0-okd-scos.10` or whatever was selected at
mirror time):

```bash
# On iac-control:
skopeo inspect --tls-verify=false \
  docker://mirror.208.haist.farm:8443/okd-release:4.20.0-okd-scos.10 \
  | jq '.Digest'
# → sha256:<digest>
```

**Validate ClusterImagePolicy will permit this digest** (§1 row 6):

```bash
oc image extract mirror.208.haist.farm:8443/okd-release@sha256:<digest> --file=/release-manifests/image-references --to=- > /dev/null
# If this fails with SignatureValidationFailed, fix ClusterImagePolicy scope before continuing.
```

**Initiate upgrade by digest** (disconnected-friendly form):

```bash
oc adm upgrade --to-image=mirror.208.haist.farm:8443/okd-release@sha256:<digest> \
  --allow-explicit-upgrade --force=false
```

`--allow-explicit-upgrade` is required because the cluster has no upstream graph
in disconnected mode. `--force=false` is the default — keep it; do not use
`--force` unless explicitly recovering from a stuck state.

**Monitor:**

```bash
# In one terminal:
watch -n 30 'oc get clusterversion; echo; oc get co | grep -v "True .*False .*False"; echo; oc get mcp; echo; oc get nodes'
# In another:
oc -n openshift-machine-config-operator logs -f deployment/machine-config-operator
```

**Cluster operator stabilisation check (gate before MCO touches nodes):**

```bash
# All COs Available=True, none Progressing, none Degraded:
oc get co -o json | jq -r '.items[] | select(.status.conditions[] | (.type=="Progressing" and .status=="True") or (.type=="Degraded" and .status=="True")) | .metadata.name'
# Expect: empty
```

**Wait for MCO to roll all 3 masters serially.** `oc get mcp master` shows
`UPDATING=True` then `UPDATED=True` after the third node returns Ready. Do not
intervene unless §1 rows 1, 4, 5, 7 trigger.

**Smoke test (§6).** Then proceed to inter-hop verification window (30–60 min
of "leave it alone and watch nothing degrade").

### 5.2 Hop B: 4.20.x → 4.21.x

**Refresh IDMS / mirror content if needed:** if 4.21 release content was already
mirrored alongside 4.20 in MW1, this is a no-op. Otherwise, re-run oc-mirror v2
on the workstation, transfer to the mirror VM, refresh IDMS:

```bash
oc apply -f idms-oc-mirror.yaml
oc apply -f itms-oc-mirror.yaml
```

**Re-check admin-acks** for 4.20→4.21 transition. As of authoring this runbook,
no specific admin-ack class has been observed in the 4.21 release notes
beyond what was acked at 4.20, but **re-check at upgrade time** by reading the
`admin-gates` ConfigMap:

```bash
oc -n openshift-config-managed get cm admin-gates -o yaml
```

Any unacked gate keys → audit, then ack with the same patch pattern as §4 step 7.

**Etcd backup × 3 (per §3.1).**

**Initiate:**

```bash
TARGET_DIGEST=$(skopeo inspect --tls-verify=false \
  docker://mirror.208.haist.farm:8443/okd-release:4.21.0-okd-scos.<n> | jq -r '.Digest')

oc adm upgrade --to-image=mirror.208.haist.farm:8443/okd-release@${TARGET_DIGEST} \
  --allow-explicit-upgrade
```

Same monitoring + smoke test as Hop A.

---

## 6. Post-upgrade validation checklist (per hop)

A hop succeeded if **all** of these are true:

```bash
# 1. ClusterVersion reports the new version, not progressing:
oc get clusterversion
# version  4.20.0-okd-scos.10  True  False  Cluster version is 4.20.0-okd-scos.10

# 2. All cluster operators Available=True, Progressing=False, Degraded=False:
oc get co | grep -v "Available .*Progressing .*Degraded\|True .*False .*False"
# Header line plus nothing else.

# 3. All MachineConfigPools updated, no degraded:
oc get mcp
# master  rendered-master-...   True  False  False  ...  3  3  3  0
# worker  rendered-worker-...   True  False  False  ...  3  3  3  0
#                                                                 ^ degradedMachineCount = 0

# 4. All nodes Ready, on the new kubelet version:
oc get nodes -o wide
# Expect kubelet v1.33.x for 4.20, v1.34.x for 4.21.

# 5. Etcd member health:
oc -n openshift-etcd get pods
# All 3 etcd-master-N pods Running 5/5
oc -n openshift-etcd rsh etcd-master-1.overwatch.haist.farm \
  etcdctl --endpoints=https://localhost:2379 --cacert=... --cert=... --key=... endpoint health --cluster
# All members healthy, low latency.

# 6. Sample pod scheduling test:
oc create ns post-upgrade-smoke-$(date +%s)
oc -n post-upgrade-smoke-* run smoke --image=mirror.208.haist.farm:8443/quay-mirror/centos:stream10 -- sleep 60
oc -n post-upgrade-smoke-* get pod smoke
# Running within 30 sec; image pulled from mirror; ClusterImagePolicy permitted it.

# 7. Image signature path exercised:
oc -n openshift-machine-config-operator get pods
# Pods Running, recently restarted (post-upgrade), pulled fresh — implies signature path worked end-to-end.

# 8. No unexpected pod restart spam in core namespaces:
oc get pods -A --sort-by=.status.containerStatuses[0].restartCount | tail -20
# Looking for pods with restart counts climbing during the verification window.

# 9. No degraded conditions in network or storage operators (these are slowest to settle):
oc get co network storage -o yaml | grep -A 2 "type: Degraded"
```

If any of 1–5 fails, **do not proceed to the next hop.** Triage with the
pre-mortem matrix (§1).

---

## 7. Rollback decision tree

The decision is "abort and restore from etcd" vs. "wait it out." Once MCO has
started rebooting masters, "rollback" via downgrade is **not supported** by
OKD — minor versions only go forward. Etcd restore is the only true rollback
path, and it returns the cluster to pre-hop state (lose upgrade progress, keep
no-data-loss because workloads were scaled to zero).

```
Symptom assessment after MCO has touched at least one master:
│
├── 1 master post-reboot in NotReady, others healthy
│   └─→ WAIT (up to 30 min). NotReady on first reboot is normal during cri-o restart.
│       └── Still NotReady after 30 min? → Triage §1 rows 4, 5, 7. Try targeted fix.
│           └── Targeted fix doesn't recover within 60 min total? → Hold MCO, do not let
│               it reboot the second master. Escalate to operator. Decision: wait longer
│               (cert rotation slow) or abort.
│
├── 2 masters NotReady (etcd at quorum-of-1)
│   └─→ ABORT. Stop everything. Do not let MCO reboot the third. Investigate which master
│       has the most recent etcd backup. If quorum returns within 5 min naturally, breathe.
│       If not, execute restore (§3.4).
│
├── 3 masters NotReady
│   └─→ Quorum lost. Execute restore (§3.4). This is the catastrophic case;
│       expect 1–2 hour recovery.
│
├── All masters Ready but ClusterOperator(s) Degraded for >30 min
│   ├── Network/OVN degraded → Try §1 row 5 remediation. If no improvement in 30 more
│   │   min → abort, restore. The cluster is functional but won't progress past here.
│   ├── Etcd degraded → Inspect etcd member health. If members are flapping, prefer
│   │   abort + restore over letting MCO advance.
│   └── Other CO degraded (image-registry, monitoring, console) → wait. These are
│       resilient to slow recovery. Most settle in 30–60 min.
│
├── ImagePullBackOff cluster-wide on new pods
│   └─→ §1 rows 3, 6. Likely mirror or signature issue. The cluster keeps running
│       on cached images; fix the mirror/policy and the next reboot recovers. Do
│       not abort — abort would not change this class of problem.
│
└── MCO degraded with custom-MC conflict
    └─→ §1 row 7. Identify offending MC, delete, let MCO re-roll. If that
        sequence doesn't converge in 60 min, abort.
```

**Hard abort criteria — restore etcd if any of:**

- Etcd member count drops to 1 for >5 min during a master reboot window.
- 2+ masters NotReady simultaneously.
- MCO degraded *and* won't progress *and* simple MC remediation didn't help in 60 min.
- Cluster operator `kube-apiserver` degraded for >15 min (no targeted fix has good
  history at that layer; the cluster is dying).

**Don't abort for:**

- ImagePullBackOff (recoverable by fixing mirror, no data risk).
- Application-namespace pod failures (out of MW2 scope; workloads should be scaled to zero).
- Slow CO settle (give it the full hour budget).
- One master taking 30 min instead of 20 (within ballpark).

---

## 8. Operator + workload bring-up order after final hop

Inverse of the scale-to-zero ordering — bottom-up, validate each layer before
moving to the next. Estimated 1–2 hours total.

1. **Storage substrate:**
   - Confirm TrueNAS is reachable on its iSCSI (3260) and NFS (2049) ports from each master.
   - `iscsiadm -m session` on each master shows the expected target sessions (or, if OPS-151 migration is complete, democratic-csi or whichever CSI is in use shows a healthy controller pod).
   - Sanity-mount: create a tiny PVC bound to a CSI/iSCSI class and confirm it goes Bound.

2. **Vault** (cluster-critical for ExternalSecret resolution):
   - Vault VM up, unsealed (auto-unseal should have worked on a clean cluster; verify).
   - `vault status` returns healthy.
   - Confirm cluster's `external-secrets-operator` is back to Healthy: `oc -n external-secrets get pods`.
   - Test one ExternalSecret resolution: `oc -n <ns> get externalsecret <name>` should be `SecretSynced=True`.

3. **Keycloak** (auth backbone for many platform components):
   - Scale up Keycloak StatefulSet/Deployment (replicas back to original).
   - Postgres comes up first; then Keycloak; smoke a login at `keycloak.208.haist.farm`.

4. **Forgejo** (gitops source of truth):
   - Scale up Forgejo and its Postgres.
   - Confirm git operations work (a clone from iac-control).
   - This is what ArgoCD reads, so it must be alive before ArgoCD un-pauses.

5. **Harbor** (workload-image registry):
   - Scale up Harbor's Postgres, Redis, and the Harbor pods.
   - Smoke: `crane catalog harbor.208.haist.farm` from iac-control.
   - **Validate the IDMS still routes correctly:** trigger a pull through Harbor (already running on cached images? force a cri-o pull by recreating a pod) — verify it pulls from Harbor first, only failing-over to mirror if Harbor is unreachable.

6. **ClusterImagePolicy validation:**
   - `oc get clusterimagepolicy -o yaml` — confirm the policies survived the upgrade unchanged.
   - The 4.20+ default `openshift-platform-image` policy may have been auto-installed by the new platform; reconcile any conflicts with our MW1 policies.
   - Confirm signature verification still fires by attempting to pull an unsigned test image and observing `SignatureValidationFailed`.

7. **Kyverno** (policy layer, sigstore-decoupled per MW1):
   - Confirm Kyverno controllers are Running and reports/cleanup pods aren't crashing (per the OPS-108 recovery work).
   - Re-enable any policies that were paused for MW2.

8. **Application namespaces** (everything else: matrix, plane, langfuse, netbox, defectdojo, monitoring, supplementary services):
   - Un-pause ArgoCD Applications one by one, oldest-stable first.
   - Confirm each settles to `Synced=True / Healthy=True` within 5 min before un-pausing the next.
   - Anything that doesn't settle: capture state, file a child OPS issue, move on.

9. **Final cluster-level smoke:**
   - End-to-end test: log in to one user-facing service at its public hostname (e.g., matrix or plane through the ingress).
   - Confirm Wazuh is receiving heartbeats from all 3 masters.
   - Confirm the `sentinel-agent` loop is running and not flooding alerts.

10. **Close MW2:** post `COMPLETION` comment on OPS-152 with cluster version, all
    CO statuses, smoke test results, and a list of any deferred follow-ups
    (each as a separate child Plane issue per §4 of CLAUDE.md).

---

## Sources cited (in addition to those in sibling research)

- OKD 4.19 control-plane backup/restore: `https://docs.okd.io/4.19/backup_and_restore/control_plane_backup_and_restore/`
- OKD 4.19 etcd backup: `https://docs.okd.io/4.19/backup_and_restore/control_plane_backup_and_restore/backing-up-etcd.html`
- OKD 4.19 disaster recovery scenario 2 (restoring cluster state): `https://docs.okd.io/4.19/backup_and_restore/control_plane_backup_and_restore/disaster_recovery/scenario-2-restoring-cluster-state.html`
- OKD 4.20 upgrade prep (admin-acks): `https://docs.okd.io/4.20/updating/preparing_for_updates/updating-cluster-prepare.html`
- `oc adm upgrade --to-image` form for disconnected: `https://docs.okd.io/4.20/updating/updating_a_cluster/updating-disconnected-cluster.html`
- Sibling research: `~/recovery-ledger/2026-04-27-power-incident/RESEARCH-okd-upgrade.md`, `RESEARCH-air-gapped-fail-secure.md`
