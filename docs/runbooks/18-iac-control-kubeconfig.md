# Runbook 18 — iac-control Authoritative Kubeconfig

**Scope:** Cluster admin access from iac-control (ubuntu user)
**Added:** OPS-450 (2026-05-08)

## Authoritative Kubeconfig

The production kubeconfig for the `overwatch` cluster lives at:

```
/home/ubuntu/overwatch-repo/auth/kubeconfig
```

This file uses the **`system:admin` context** (admin client certificate, non-expiring). It is generated during cluster install and is the canonical source of truth for cluster admin access from iac-control.

`~/.kube/config` is a symlink to this file:
```
/home/ubuntu/.kube/config -> /home/ubuntu/overwatch-repo/auth/kubeconfig
```

Verify with:
```bash
ls -la ~/.kube/config
oc whoami          # should return: system:admin
oc get nodes       # should return 3 Ready masters
```

## Cluster Details

- **Cluster name:** `overwatch`
- **API server:** `https://api.overwatch.haist.farm:6443`
- **API VIP (HAProxy):** `192.168.12.223`
- **Apps ingress VIP:** `192.168.12.224`
- **DNS resolution (via dnsmasq overwatch.conf):**
  - `api.overwatch.haist.farm` → `10.0.0.1` (iac-control OKD interface, HAProxy listens on all addresses)
  - `*.apps.overwatch.haist.farm` → `10.0.0.1`

## Vault Secret

The authoritative kubeconfig is also stored at:

```
secret/iac-control/kubeconfig  (field: value)
```

This was refreshed in OPS-450 (2026-05-09, v3). Update it when the kubeconfig changes:
```bash
vault kv put secret/iac-control/kubeconfig value=@/home/ubuntu/overwatch-repo/auth/kubeconfig
```

## Contexts in Kubeconfig

| Context | User | Notes |
|---------|------|-------|
| `system:admin` | Client cert (non-expiring) | **Default — use this for admin work** |
| `default/api-overwatch-haist-farm:6443/admin` | Token (may expire) | |
| `default/api-overwatch-haist-farm:6443/kube:admin` | Token (may expire) | |

The `system:admin` context uses a client certificate signed by the cluster admin CA — it does not expire and does not rely on Vault or an oauth token.

## IaC Enforcement

The Ansible role `iac-control` enforces the correct symlink and removes stale entries via:

```bash
ansible-playbook ansible/playbooks/iac-control.yml --tags kubeconfig-drift
```

This idempotently:
1. Removes stale `/etc/hosts` entries for `okd-sandbox.sandbox.208.haist.farm` (added in OPS-186)
2. Removes `/etc/dnsmasq.d/okd-sandbox.conf` if it exists (added during OPS-293)
3. Creates the `~/.kube/config` symlink to the authoritative file

## History

- OPS-186 (Phase 2): Original cluster install used name `okd-sandbox` with domain `okd-sandbox.sandbox.208.haist.farm`
- OPS-293 (2026-05-02): Recovery added `/etc/dnsmasq.d/okd-sandbox.conf` with stale cluster DNS entries
- OPS-450 (2026-05-08): Cluster rename to `overwatch`; stale references cleaned from `/etc/hosts`, dnsmasq, `~/.kube/config`, and Vault
