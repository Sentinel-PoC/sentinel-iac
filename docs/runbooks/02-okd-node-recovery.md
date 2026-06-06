# Runbook 02 — OKD Node Failure, Drain, and Reboot

**Scenario:** An OKD cluster node (master or worker, in this homelab all nodes are masters) is NotReady, needs draining for maintenance, or needs a controlled reboot.

**Cluster topology:** 3-node control-plane-only cluster. All nodes are masters. Losing 2+ nodes will lose etcd quorum.

---

## 1. Assess node status

From iac-control:

```bash
export KUBECONFIG=/home/ubuntu/overwatch-repo/auth/kubeconfig.new
oc get nodes -o wide
```

Expected: all 3 nodes `Ready`. A `NotReady` node requires investigation before action.

### 1a. Get node condition details

```bash
oc describe node <node-name> | grep -A 10 "Conditions:"
```

Common conditions causing NotReady:
- `KubeletNotReady` — kubelet stopped communicating
- `DiskPressure` — node disk full (check `df -h` on the node)
- `MemoryPressure` — node RAM exhausted
- `NetworkUnavailable` — OVN networking issue

### 1b. Check kubelet on the node

SSH to the affected node (requires valid Vault SSH cert):

```bash
# Get SSH cert first (if not already signed)
vault write ssh/sign/admin public_key=@~/.ssh/id_ed25519.pub valid_principals=core ttl=1h

ssh -i ~/.ssh/id_ed25519 -i ~/.ssh/signed_cert.pub core@<node-ip>

# On node
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 50 --no-pager | grep -iE 'error|fail|panic'
```

OKD node IPs: check `oc get nodes -o wide` for InternalIP.

---

## 2. Diagnose before taking action

**Do not drain or delete a node until you understand why it is NotReady.**

Common causes and fixes:

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| kubelet not running | OOM kill or crash | `sudo systemctl restart kubelet` |
| cri-o not running | Container runtime crash | `sudo systemctl restart crio` |
| OVN pods not running | OVN-Kubernetes issue | See OVN recovery below |
| Node unresponsive via SSH | Hardware/VM issue | Check Proxmox console |
| etcd errors in kubelet | etcd member unhealthy | See etcd recovery below |

---

## 3. Controlled node reboot (planned maintenance)

### 3a. Drain the node

```bash
# Cordon to prevent new pods being scheduled
oc adm cordon <node-name>

# Drain (evicts pods gracefully; DaemonSet pods stay)
oc adm drain <node-name> --ignore-daemonsets --delete-emptydir-data --force --timeout=5m
```

Note: with a 3-node control-plane-only cluster, draining a node may cause etcd leader election and brief API server unavailability (~10-30s). Drain one node at a time; never drain 2 simultaneously.

### 3b. Reboot the node

```bash
ssh core@<node-ip> "sudo systemctl reboot"
```

### 3c. Wait for node to rejoin

```bash
# Watch until Ready
watch -n 10 "oc get nodes"
```

Typical reboot time: 3-5 minutes. Node will show `NotReady` during boot then transition to `Ready` once kubelet and etcd rejoin.

### 3d. Uncordon

```bash
oc adm uncordon <node-name>
```

---

## 4. OVN networking recovery

If OVN pods are crashing or OVN-related:

```bash
# Check OVN pods
oc get pods -n openshift-ovn-kubernetes

# Restart ovnkube-node on the affected node (DaemonSet pod)
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=<node-name>

# If ovnkube-master is crashing (leader election)
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-master
```

Do not delete all OVN pods simultaneously. Delete one ovnkube-master pod at a time.

---

## 5. etcd member recovery

etcd requires 2 of 3 members healthy for quorum.

### 5a. Check etcd health

```bash
# From any running master node
oc rsh -n openshift-etcd $(oc get pods -n openshift-etcd -l app=etcd --field-selector spec.nodeName=<healthy-node> -o name | head -1) \
  etcdctl --cacert /etc/etcd/ca/ca.crt \
          --cert /etc/etcd/certs/etcd-all-serving/etcd-serving-*.crt \
          --key /etc/etcd/certs/etcd-all-serving/etcd-serving-*.key \
          endpoint health --cluster
```

### 5b. If an etcd member is unhealthy

If the node is back online but etcd member is stuck:

```bash
# Restart the etcd static pod by touching the manifest
ssh core@<node-ip> "sudo touch /etc/kubernetes/manifests/etcd-pod.yaml"
```

Wait 60 seconds and check `endpoint health` again.

For deeper etcd recovery, see runbook 05-etcd-backup-inventory.md.

---

## 6. Node offline and irrecoverable

If a node is permanently lost (hardware failure):

1. Remove the etcd member before it can be replaced:
   ```bash
   # From a healthy node — find the member ID
   oc rsh -n openshift-etcd <etcd-pod> etcdctl member list
   oc rsh -n openshift-etcd <etcd-pod> etcdctl member remove <member-id>
   ```
2. File an OPS issue for node reprovisioning (requires Proxmox VM rebuild + OKD node join)

---

## Related Runbooks
- [04-service-recovery-order.md](04-service-recovery-order.md) — full recovery order after node rejoins
- [05-etcd-backup-inventory.md](05-etcd-backup-inventory.md) — etcd backup and restore
- [08-break-glass.md](08-break-glass.md) — Proxmox console access when SSH is unavailable
