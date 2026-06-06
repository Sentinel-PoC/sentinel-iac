# Ansible Role: mirror-registry

**Status: PLACEHOLDER — OPS-148 capacity BLOCKER pending operator decision**
See Plane issue OPS-148, BLOCKER comment ID `699f948a-bf13-4a01-920e-be880776a2cf`.

---

## Purpose

Automate the deployment of the out-of-band OKD mirror registry described in the
MW1 runbook (`docs/research-april-power-incident/OPS-147-mw1-registry-split-runbook.md`).

This registry is a `mirror-registry` (Red Hat / Quay) instance running on a dedicated
PVE VM, independent of the OKD cluster, providing:
- Offline OKD 4.19 release image mirror
- Platform operator catalog mirror (Kyverno, ArgoCD, cert-manager, Keycloak)
- Harbor image fallback for cluster recovery when Harbor is down
- Cosign-signed image hosting for `ClusterImagePolicy` (cri-o pull-time verification)

## VM Spec (pending capacity decision)

| Parameter | Value |
|-----------|-------|
| Hostname | `mirror-registry-01.208.haist.farm` |
| FQDN | `mirror.208.haist.farm` |
| IP | `192.168.12.215` |
| OS | Rocky Linux 9.4 minimal |
| vCPU | 4 |
| RAM | 16 GB |
| Boot disk | 60 GB (local-LVM) |
| Data disk | 1,000 GB (**node/pool TBD — see BLOCKER**) |

**Capacity blocker summary:**

- `pve3` (.57): memory passes (23.2% free post-VM) but local-lvm only has 271 GB free — max data disk ~211 GB.
- `208-pve2` (.56): storage fits (BACKUP_PROX local ZFS, 3.73 TB free) but memory fails by 3.5 GB (17.4% vs 20% rule). Fix: reduce wazuh (VMID 111) from 16→12 GB.
- `pve` (.6): SPOF-excluded by operator.
- VAST pool: active on 208-pve2, 1.91 TB free, but TrueNAS-backed — conflicts with §1.1 storage-independence requirement.

## Role Tasks (when implemented)

1. Install packages: `podman`, `openssl`, `jq`, `curl`, `tar`
2. Enable and configure `firewalld` (ports 8443/tcp, 443/tcp)
3. Create storage directories, set ownership for UID 1001
4. Issue TLS certificate from Vault PKI (`pki_int/issue/208-haist-farm`)
5. Download `mirror-registry` binary and run install
6. Verify systemd service health (`quay-pod`, `quay-app`, `quay-postgres`, `quay-redis`)
7. Deploy `quay-pg-dump.sh` and cron entry for daily logical backup

## References

- Runbook: `docs/research-april-power-incident/OPS-147-mw1-registry-split-runbook.md`
- Plane issue: OPS-148
- Related: OPS-147 (MW1 design), SEC-62 (attestation flip to Enforce)
