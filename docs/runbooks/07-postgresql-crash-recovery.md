# Runbook 07 — PostgreSQL Crash Loop on iSCSI

**Scenario:** one or more PostgreSQL (or ClickHouse) pods backed by a TrueNAS iSCSI zvol are stuck in `CreateContainerError`, `Init:Error`, or `CrashLoopBackOff` after a pod reschedule or node reboot.

**Typical symptom in kubelet events (critical fingerprint):**

```
Warning  Failed  ... Error: relabel failed
  /var/lib/kubelet/pods/<POD_UID>/volumes/kubernetes.io~iscsi/<VOL_NAME>:
  readdirent .../<VOL_NAME>/lost+found: input/output error
```

The SELinux relabel step on the iSCSI-mounted ext4 filesystem fails reading `lost+found`. Kubelet cannot finish volume setup, so the container never starts. A pod that has not been rescheduled (e.g., running for weeks on the same node) will keep running — the issue only triggers on cold start.

**This is NOT an app bug, NOT a Harbor registry issue, NOT a Kyverno policy issue.** The Kyverno `verify-image-signatures` `PolicyViolation` that often accompanies this is downstream — it fires because `harbor-core` can't query its own database (which is this pod), so signature lookups time out.

---

## 1. Identify the scope

### 1a. Find all affected pods

From a host with `kubectl` + kubeconfig:

```bash
kubectl get pods --all-namespaces \
  --field-selector=status.phase!=Running,status.phase!=Succeeded \
  | grep -iE 'postgres|clickhouse|database'
```

### 1b. Confirm the relabel fingerprint

For one suspected pod:

```bash
kubectl -n <NS> describe pod <POD> | grep -A2 'relabel failed'
```

If you see `readdirent .../lost+found: input/output error` — this runbook applies.

### 1c. Map pods to their iSCSI zvols

```bash
kubectl get pv -o json | python3 -c '
import sys, json
d = json.load(sys.stdin)
for pv in d["items"]:
    iscsi = pv["spec"].get("iscsi")
    if not iscsi: continue
    claim = pv["spec"].get("claimRef", {})
    print(f"{pv[\"metadata\"][\"name\"]:30s} ns={claim.get(\"namespace\",\"?\"):12s} pvc={claim.get(\"name\",\"?\"):30s} iqn={iscsi.get(\"iqn\",\"?\")}")
'
```

Note the `iqn` for each affected pod — e.g. `iqn.2026-03.farm.haist:okd-harbor-pg` means zvol `SSD/harbor-pg` on TrueNAS.

---

## 2. Verify TrueNAS side is healthy

SSH to TrueNAS (192.168.12.205). If SSH is down, use Proxmox qemu-guest-agent on pve3 VM 108 — see Appendix A.

```bash
zpool status         # all pools ONLINE, zero errors
zpool list           # capacity sane
systemctl is-active scst   # active
```

If ZFS reports errors, STOP this runbook and invoke runbook 08 (break-glass) — the storage itself is compromised.

---

## 3. Recover each affected zvol

### For each affected zvol (e.g. harbor-pg, defectdojo-pg, etc):

#### 3a. Scale the Kubernetes deployment to 0

This ensures the pod releases the iSCSI session:

```bash
kubectl -n <NS> scale deployment <NAME> --replicas=0
# Wait for pod to terminate
kubectl -n <NS> get pods -w
```

For StatefulSets use `scale statefulset` instead.

#### 3b. Detach the iSCSI extent on TrueNAS

Via CLI (on TrueNAS):

```bash
# List extents to find the right one
cli -c 'sharing iscsi extent query' | grep <zvol-name>

# Disable the extent (prevents new initiator connections)
midclt call iscsi.extent.update <extent-id> '{"enabled": false}'
```

Via UI: Sharing → Block Shares (iSCSI) → Extents → disable the matching extent.

Confirm no initiator sessions are active:

```bash
ctladm islist
# Expect: no session for this LUN
```

If a session is stuck: `ctladm logout -a` will boot all initiator sessions for the target (disruptive to other volumes on same target).

#### 3c. Run fsck on the zvol

```bash
ZVOL=SSD/<name>          # e.g. SSD/harbor-pg
DEV=/dev/zvol/${ZVOL}

# Sanity: confirm device exists and is ext4
file -s $DEV
# Should say: "Linux rev 1.0 ext4 filesystem data, ..."

# Force check + auto-repair; ext4 corruption in /lost+found usually fixable
fsck.ext4 -y $DEV
```

Expect output like `/lost+found: Inode X has invalid mode (02000000)` or similar — fsck will repair. If fsck reports clean, the corruption may be at a deeper layer — consider option 3d.

#### 3d. Alternative: ZFS snapshot rollback

If fsck doesn't clear the corruption, or if the volume has been mostly idle:

```bash
# List snapshots
zfs list -t snapshot -o name,creation,used | grep $ZVOL

# Roll back to last known-good snapshot (destroys all data since)
zfs rollback -r $ZVOL@<snapshot-name>
```

Only roll back if the app can tolerate that point-in-time restore. For PostgreSQL, WAL may be lost — verify the app has backups first.

#### 3e. Re-enable the iSCSI extent

```bash
midclt call iscsi.extent.update <extent-id> '{"enabled": true}'
# Or via UI: toggle enabled back on
```

#### 3f. Scale the Kubernetes deployment back up

```bash
kubectl -n <NS> scale deployment <NAME> --replicas=1
kubectl -n <NS> get pods -w
# Expect Running + Ready within 60s
```

If the pod comes up but is still crashing, the corruption may have affected app data (not just `lost+found`). Inspect pod logs:

```bash
kubectl -n <NS> logs <POD> -c <CONTAINER> --previous
```

---

## 4. Verify downstream

Once each DB pod is Healthy, the dependent apps will recover:

```bash
# ArgoCD app status (via sentinel-agent's kubeconfig/credentials)
sudo -u sentinel-agent bash -c '
  export KUBECONFIG=/opt/sentinel-agent/.kube/config
  ARGOCD_PW=$(kubectl -n openshift-gitops get secret openshift-gitops-cluster -o jsonpath="{.data.admin\.password}" | base64 -d)
  TOKEN=$(curl -sk -X POST -H "Content-Type: application/json" -d "{\"username\":\"admin\",\"password\":\"${ARGOCD_PW}\"}" https://argocd.208.haist.farm/api/v1/session | python3 -c "import sys,json;print(json.load(sys.stdin)[\"token\"])")
  curl -sk -H "Cookie: argocd.token=${TOKEN}" https://argocd.208.haist.farm/api/v1/applications | python3 -c "
import sys, json
for a in json.load(sys.stdin)[\"items\"]:
    h = a[\"status\"].get(\"health\",{}).get(\"status\",\"?\")
    s = a[\"status\"].get(\"sync\",{}).get(\"status\",\"?\")
    print(f\"  {a[\"metadata\"][\"name\"]:20s} health={h:12s} sync={s}\")"
'
```

For Harbor specifically, recovery sequence is:
1. harbor-database Running + Ready
2. harbor-core restarts on its own (detects DB up)
3. harbor-registry, harbor-jobservice, harbor-nginx, harbor-portal all recover
4. Kyverno `verify-image-signatures` PolicyViolations stop firing on new pods
5. Downstream apps (which couldn't pull signed images) can deploy

---

## 5. Prevention

The relabel failure is repeated: kubelet runs SELinux relabel on every container create when the volume has SELinux labels. Options to reduce blast radius:

- **fsGroupChangePolicy: OnRootMismatch** in the pod spec — skips relabel if root is already the right group. Reduces relabel frequency but doesn't fix corrupted `lost+found`.
- **mountOptions: [nolock]** or **seLinuxRelabel: false** — not supported for iSCSI by default.
- **Bitnami postgres chart**: consider moving to `fsGroupChangePolicy: OnRootMismatch` globally via chart values.
- **Long term**: a scheduled fsck on each zvol while the app is quiesced for maintenance. See runbook 04 for rolling maintenance order.

---

## Appendix A — TrueNAS via Proxmox qemu-guest-agent

If SSH to 192.168.12.205 is unreachable:

```bash
# From iac-control
export VAULT_ADDR=https://192.168.12.206:8200 VAULT_SKIP_VERIFY=true
PROXMOX_TOKEN=$(vault kv get -field=api_token_secret secret/proxmox)
AUTH="PVEAPIToken=terraform-prov@pve!api-token=${PROXMOX_TOKEN}"
PVE=https://192.168.12.6:8006/api2/json
NODE=pve3; VMID=108

# Submit a command, then fetch status by pid:
PID=$(curl -sk -H "Authorization: $AUTH" -X POST \
  --data-urlencode "command=/sbin/zpool" \
  --data-urlencode "command=status" \
  "$PVE/nodes/$NODE/qemu/$VMID/agent/exec" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["pid"])')
sleep 3
curl -sk -H "Authorization: $AUTH" "$PVE/nodes/$NODE/qemu/$VMID/agent/exec-status?pid=$PID" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d.get("out-data",""))'
```

The qemu-guest-agent runs as root inside the VM — no `sudo` needed.

---

## Appendix B — Incident reference

Origin incident: 2026-04-18 diagnosis during OPS-213/215/216 convergence revealed 6 database pods in `CreateContainerError` state persisting 13–28 days. sentinel-agent had been blind to ArgoCD health for 3+ weeks (OPS-214 + OPS-226) so no alerts surfaced. Fingerprint across all failing pods: `relabel failed .../lost+found: input/output error`.

**Affected at time of discovery:** harbor-database, backstage-postgresql, keycloak-postgresql, matrix-postgresql, langfuse-clickhouse, defectdojo-postgresql, plane-postgresql (29d — initially missed because Plane API kept responding via connection cache until the cache exhausted around 17:50 UTC today, at which point Plane itself started returning 500s).

**Verified healthy and on same iSCSI target:** langfuse-postgresql (13d uptime, never rescheduled), netbox-pg. These two prove the iSCSI protocol + SCST daemon are fine — the failure is SELinux relabel on cold container start, not the underlying storage.

**Also observed: Plane API (plane.208.haist.farm) started returning "Something went wrong please try again later" for most API calls once Plane's DB-cache exhausted. If you cannot file new Plane issues or add comments, run this runbook on plane-postgresql first to restore Plane itself, then file follow-up issues for the other 6 databases.**

**Confirms this is a relabel-on-cold-start issue, not an iSCSI protocol issue.**
