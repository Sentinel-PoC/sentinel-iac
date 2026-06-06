# Runbook 16 — OKD 4.19 sandbox cluster provisioning

> **Tracking:** Plane OPS-186. Sibling of OPS-184 (etcd restore drill rehearsal).
> **Estimated wall time:** 60–90 min from `make prereq` to `make smoke` green.
> **NIST controls:** CA-2 (assessments), CP-10 (recovery testing), SA-11 (developer security testing).

This runbook is the operator-facing companion to
[`infrastructure/okd-sandbox/`](../../infrastructure/okd-sandbox/). It captures
exactly what to run, what to verify, what to do when things go wrong, and how
to put the sandbox back to zero between drill iterations.

---

## 1. Prereqs

### 1.1 Workstation

Run from **iac-control** (`192.168.12.210`). Local laptop works for `make
render` / `make iso` but `make apply` requires the Vault-backed Proxmox token
and `make wait-*` benefits from being on the same broadcast domain as the
cluster API VIP.

Required CLI tools on the runner:

| Tool | Version | Notes |
|---|---|---|
| `openshift-install` | 4.19.x | Download from <https://github.com/okd-project/okd/releases>. The agent subcommand was promoted to GA in 4.13. |
| `oc` | 4.19.x | Same release as openshift-install. |
| `tofu` (or `terraform`) | ≥ 1.5 | OpenTofu is the platform default — see `infrastructure/managed/`. |
| `vault` | any | A `vault` binary that can talk to <https://vault.208.haist.farm>. |
| `jq`, `envsubst`, `nmap`, `scp`, `ssh` | — | `nmap` is optional; absence becomes a soft warn in `prereq.sh`. |

### 1.2 Vault

The session token must allow read on:

- `secret/proxmox/terraform-prov` field `api_token` — Proxmox API token in the
  form `user@realm!tokenid=secret`. **NOT** the root token. If this path is
  empty, populate with the existing terraform-prov token before `make apply`.
  (Operator follow-up — flagged in OPS-186 SESSION START comment.)
- `secret/okd-sandbox/ssh` — auto-created by `render.sh` on first run.
- `secret/okd-sandbox/pull` — optional. Empty `{}` is accepted by
  openshift-install per Q2 (OKD-SCOS pulls from quay.io/okd are anonymous).

And write on `secret/okd-sandbox` (for `make stash`).

### 1.3 Hosts and IPs

Reserved IP block per Q3, on the LAN-shared bridge `vmbr0`
(`192.168.12.0/24`):

| Role | IP | MAC | Proxmox node | VM ID |
|---|---|---|---|---|
| master-1 (rendezvous) | 192.168.12.220 | BC:24:11:00:01:20 | pve3 | 220 |
| master-2 | 192.168.12.221 | BC:24:11:00:01:21 | 208-pve2 | 221 |
| master-3 | 192.168.12.222 | BC:24:11:00:01:22 | 208-pve2 | 222 |
| API VIP | 192.168.12.223 | (keepalived) | — | — |
| Ingress VIP | 192.168.12.224 | (keepalived) | — | — |

`make prereq` runs an nmap sweep of `.220-.224`. If any host responds, the
script exits non-zero — free the address or revise `var.masters`.

### 1.4 `/etc/hosts` overrides (Q4)

The base domain `sandbox.208.haist.farm` is **not** in DNS. Add to
`/etc/hosts` on iac-control and any agent workstation that needs `oc` access:

```
192.168.12.223  api.okd-sandbox.sandbox.208.haist.farm
192.168.12.224  oauth-openshift.apps.okd-sandbox.sandbox.208.haist.farm
192.168.12.224  console-openshift-console.apps.okd-sandbox.sandbox.208.haist.farm
```

A separate Plane issue covers proper DNS — out of OPS-186 scope.

### 1.5 Proxmox storage

The Terraform default is `local-lvm` for both OS and LSO disks on every node.
Override per-host with `TF_VAR_os_disk_datastore` / `TF_VAR_lso_disk_datastore`
if `pve3` and `208-pve2` use different names (current audit: both have
`local-lvm`; `208-pve2` also has `vast` for production). The ISO datastore
default is `local` (Proxmox's built-in templates location).

---

## 2. Run command

The shortest path from a fresh checkout to a smoke-green cluster:

```bash
ssh ubuntu@192.168.12.210
cd /tmp/sentinel-iac && git pull origin main
cd infrastructure/okd-sandbox

VAULT_ADDR=https://vault.208.haist.farm vault login -method=token -no-print

make all     # prereq → render → iso → upload-iso → apply → wait-bootstrap →
             # wait-install → post-install → stash → smoke
```

If a step fails, `make` stops there. Re-run that step (and only that step)
after fixing the cause — every target is idempotent.

Expected timings on the lab fleet:

| Step | Wall time |
|---|---|
| `prereq` | < 30s |
| `render` | < 5s |
| `iso` | 3–5 min (download of base ISO + assembly) |
| `upload-iso` | 30–60s per host |
| `apply` | 30–60s |
| `wait-bootstrap` | 15–25 min |
| `wait-install` | 30–60 min |
| `post-install` | 3–5 min (CSV install dominates) |
| `stash` | < 5s |
| `smoke` | < 30s |

---

## 3. Validation steps

`make smoke` runs the bare minimum. For a drill or release sign-off, also walk
this checklist by hand.

### 3.1 Cluster reachability

```bash
KUBECONFIG=$(pwd)/_work/auth/kubeconfig oc whoami       # → system:admin
oc cluster-info                                          # → API at https://api.okd-sandbox....:6443
```

### 3.2 Nodes ready

```bash
oc get nodes
# Expect 3 nodes, all Ready, role master, version v1.32.x (OKD 4.19 ships k8s 1.32).
```

### 3.3 Cluster operators

```bash
oc get co
# Expect every operator AVAILABLE=True PROGRESSING=False DEGRADED=False.
# OPS-186 acceptance criterion: all CO Available=True.
```

### 3.4 Storage

```bash
oc get sc
# Expect:
#   local-storage   (default) kubernetes.io/no-provisioner ...
oc get pv
# Expect 3 PVs, one per master, capacity 50G, status Available.
```

Bind a test PVC to confirm the default SC works:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: smoke-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
EOF
oc get pvc smoke-pvc -w   # Bound within ~5s
oc delete pvc smoke-pvc
```

### 3.5 etcd member health

```bash
oc -n openshift-etcd rsh etcd-$(oc get nodes -l node-role.kubernetes.io/master -o name | head -1 | cut -d/ -f2) \
  etcdctl --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
          --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-NODE.crt \
          --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-NODE.key \
          endpoint health --cluster
# Expect 3 endpoints, all is healthy: ... took = NNms
```

### 3.6 Vault stash

```bash
vault kv get -field=api_url secret/okd-sandbox
# → https://api.okd-sandbox.sandbox.208.haist.farm:6443
vault kv get -field=kubeconfig secret/okd-sandbox > /tmp/kc-sandbox && \
  KUBECONFIG=/tmp/kc-sandbox oc whoami    # → system:admin
```

### 3.7 Network isolation from production OKD

Production OKD lives on a separate vmbr1 VxLAN with no LAN-side NIC, so
isolation is by construction (Q3). To confirm there is no rogue path:

```bash
# from a production OKD master:
oc debug node/<prod-master> -- chroot /host curl -m 3 -k https://192.168.12.223:6443/healthz 2>&1
# → expect connect timeout / no route. NOT 200 / 401.
```

---

## 4. Teardown

Between drill iterations, choose:

```bash
make teardown        # soft — terraform destroy only, leave Vault + ISOs
make teardown-hard   # also drop Vault secret/okd-sandbox, _work/, ISOs from PVE
```

Both are idempotent. After `teardown-hard`, the next `make all` will recreate
the SSH keypair in Vault (`render.sh` checks for `secret/okd-sandbox/ssh` and
auto-generates if absent).

---

## 5. Known issues / risks

### 5.1 12 GB master memory deviation (Q1)

OKD 4.19 documents a 16 GB minimum per master. We run 12 GB based on operator
decision and confirmed working configurations in the OKD community
discussions. Symptoms if 12 GB proves insufficient at this OKD revision:

- `kube-apiserver` OOMKilled under load — `oc -n openshift-kube-apiserver
  describe pod` shows `Reason: OOMKilled`.
- `etcd` slow-fdatasync warnings in `oc -n openshift-etcd logs etcd-...`.

Remediation: bump `var.master_memory` in `terraform/variables.tf` to 16384,
`make apply` (Terraform will hot-resize without recreate per `bpg/proxmox`
behaviour — confirm with `qm config <vmid>` post-apply).

### 5.2 quay.io/okd egress dependency (Q2)

First bring-up pulls from `quay.io/okd` over the LAN. If quay.io is
unreachable (outage, DNS fail, or upstream rate-limit), bootstrap will hang at
"Pulling release image". The internal mirror cutover is a follow-up issue;
when ready, uncomment `imageContentSources` and `additionalTrustBundle` in
`install/install-config.yaml.tpl` and re-render.

### 5.3 Agent ISO is per-cluster

The rendered agent ISO embeds the install-config and a one-time auth bundle.
Re-rendering for a different cluster name or different masters produces a new
ISO; always re-run `make iso && make upload-iso` after changing
`var.masters` or `install-config.yaml.tpl`.

### 5.4 LocalVolume PVs not appearing (Q5)

Symptom: after `make post-install`, `oc get pv` is empty.

Logs-first diagnosis:

```bash
oc -n openshift-local-storage get csv     # CSV must be Succeeded
oc -n openshift-local-storage get pods    # diskmaker-manager-* DaemonSet pods must be Running
for n in $(oc get nodes -l node-role.kubernetes.io/master -o name | cut -d/ -f2); do
  POD=$(oc -n openshift-local-storage get pod -l app=diskmaker-manager --field-selector spec.nodeName=$n -o name | head -1)
  echo "==== $n ===="
  oc -n openshift-local-storage logs $POD --tail=50
done
```

Most common cause: the second disk landed at a path other than `/dev/sdb` (for
example, when the OS disk ends up on `vda`/`vdb` because of virtio-blk vs.
virtio-scsi). Update `post-install/02-local-volume.yaml` `devicePaths` to
match what `oc debug node/<master> -- lsblk` reports.

### 5.5 Bootstrap hang past 35 min

Logs-first:

```bash
tail -200 _work/.openshift_install.log
# Then SSH to a master via the agent-generated key:
ssh -i _work/ssh_key core@192.168.12.220
journalctl -u kubelet --no-pager | tail -100
journalctl -u crio    --no-pager | tail -100
sudo crictl ps
```

If `crio` is throwing image-pull errors against `quay.io/okd`, see §5.2.

### 5.6 Dual-IP-collision after partial teardown

If `make teardown` was killed mid-flight, Proxmox may still hold the VM. The
re-apply will fail with "VM 220 already exists." Recovery:

```bash
ssh root@pve3 'qm stop 220; qm destroy 220'
ssh root@208-pve2 'qm stop 221; qm destroy 221; qm stop 222; qm destroy 222'
cd terraform && tofu state rm 'proxmox_virtual_environment_vm.master["master-1"]' \
                                'proxmox_virtual_environment_vm.master["master-2"]' \
                                'proxmox_virtual_environment_vm.master["master-3"]'
make apply
```

---

## 6. Acceptance criteria mapping (OPS-186)

| Criterion | Verified by |
|---|---|
| 3 masters Up, all CO Available=True | §3.2, §3.3 |
| Cluster reachable via kubeconfig stored in Vault | §3.6 |
| (Cluster pulls images exclusively from mirror-registry) | **DEFERRED** per Q2 — follow-up issue |
| Sandbox isolated from production OKD network | §3.7 |
| Teardown procedure documented and tested | §4 |
