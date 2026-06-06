# OKD 4.19 Sandbox Cluster — IaC

> **Status:** Phase 1 (IaC authoring). Phase 2 (live provisioning) runs after
> Judge merges this PR.
> **Tracking:** [Plane OPS-186](https://plane.208.haist.farm/haists-it-consulting/projects/223c0b66-4255-406e-932f-3b50c0e93543/issues/67dc8866-cfa9-42f9-bd1b-1b1264963b79/).

A 3-master compact OKD-SCOS cluster on the existing Proxmox fleet, used for:

- **OPS-184** — etcd restore drill rehearsal
- **MW2** — OKD upgrade dry-run
- General "destroy and rebuild a real OKD cluster" testbed

The sandbox is shaped after the Red Hat compact-cluster reference: 3 masters,
no separate workers, Local Storage Operator providing a default `local-storage`
StorageClass backed by a 50 GB blank disk per master.

## Operator decisions (Q1-Q7) baked in

| Q | Decision | Where it lives |
|---|---|---|
| Q1 | 12 GB RAM per master (deviation from OKD 4.19's 16 GB minimum — works in lab) | `terraform/variables.tf` `master_memory` |
| Q2 | First bring-up pulls from `quay.io/okd` over the LAN. Mirror cutover is a follow-up issue. | `install/install-config.yaml.tpl` (imageContentSources commented) |
| Q3 | LAN-shared 192.168.12.0/24, reserved IPs `.220-.224` (3 masters + API + Ingress) | `terraform/variables.tf` `masters` |
| Q4 | `/etc/hosts` overrides on iac-control + agent workstations. No DNS edit. | runbook §Prereqs |
| Q5 | Local Storage Operator + LocalVolume + default-SC patch | `post-install/0[1-3]-*` |
| Q6 | Idempotent Makefile teardown (soft + hard) | `scripts/teardown.sh`, `Makefile` |
| Q7 | Terraform (`bpg/proxmox`) + Makefile + `openshift-install agent` from iac-control. No Packer cycle. | this directory |

## Layout

```
.
├── README.md                          you are here
├── Makefile                           operator entry points (prereq, render, iso, apply, ...)
├── terraform/                         Proxmox VM definitions
│   ├── provider.tf                    bpg/proxmox 0.70.0 + MinIO S3 backend
│   ├── variables.tf                   sizing, datastores, per-master IP/MAC/node map
│   ├── main.tf                        3 master VMs (raw resource — see DEVIATION note)
│   └── outputs.tf
├── install/                           openshift-install inputs
│   ├── install-config.yaml.tpl
│   ├── agent-config.yaml.tpl
│   └── render.sh                      Vault → envsubst → _work/{install,agent}-config.yaml
├── scripts/
│   ├── prereq.sh                      fail-fast checks before apply
│   ├── make-iso.sh                    openshift-install agent create image
│   ├── stash-kubeconfig.sh            credentials → Vault secret/okd-sandbox
│   └── teardown.sh                    soft + hard
└── post-install/                      Q5 — Local Storage Operator
    ├── 01-local-storage-operator.yaml
    ├── 02-local-volume.yaml
    └── 03-default-storageclass.sh
```

## DEVIATION from the architect's plan: vm module reuse

The architect's §3 layout said the Terraform should call into
`infrastructure/modules/vm/`. The existing `vm` module is template-clone +
cloud-init: `clone { vm_id = ... }`, single scsi0 disk, no MAC override. The
agent-based installer needs ISO boot, a stable MAC per master (so
`agent-config.yaml.hosts[].interfaces.macAddress` matches), and a second blank
disk. Generalising the module would have been a breaking change to a
5-VM-consumer module. `terraform/main.tf` therefore uses
`proxmox_virtual_environment_vm` directly. Conventions match the module
(named map, `lifecycle { ignore_changes }`, per-host `node_name`) so future
consolidation is straightforward. Documented in PR description.

## Operator entry points

```bash
make help            # show all targets
make prereq          # validate Vault, Proxmox token, mirror, IP collisions
make render          # populate templates from Vault into _work/
make iso             # produce _work/agent.x86_64.iso (~1 GB, ~5 min)
make upload-iso      # scp ISO to /var/lib/vz/template/iso on pve3 + 208-pve2
make apply           # terraform apply — create the 3 master VMs
make wait-bootstrap  # 35-min timeout
make wait-install    # 90-min timeout
make post-install    # Q5: LSO + LocalVolume + default SC
make stash           # write kubeconfig + kubeadmin-password to Vault
make smoke           # validation suite
make teardown        # soft (terraform destroy)
make teardown-hard   # + drop Vault stash, _work/, ISOs from PVE
make all             # full bring-up sequence
```

Full prereq list, validation evidence to capture, and known issues live in
[`docs/runbooks/16-okd-sandbox-provisioning.md`](../../docs/runbooks/16-okd-sandbox-provisioning.md).

## Upgrades (OPS-269)

OKD minor-version upgrades on the sandbox are driven by a Forgejo Actions
pipeline. The change-control gate is **the commit itself** — bumping
`cluster-version.yaml` IS the operator-approved request for an upgrade
(NIST CM-3, CM-3(4)).

### Files

- [`cluster-version.yaml`](cluster-version.yaml) — declares the desired
  release-image **digest** + version label.  Pin the digest, not a tag, so
  the upgrade is reproducible even if release-channel `stable-4.20` rolls
  forward mid-upgrade.
- [`.forgejo/workflows/okd-upgrade-sandbox.yaml`](../../.forgejo/workflows/okd-upgrade-sandbox.yaml)
  — the pipeline. 5 phases (preflight / upgrade / poll / validate / notify),
  single `runs-on: iac` job so kubeconfig + diagnostics dir flow through.
- [`.forgejo/workflows/lib/upgrade-functions.sh`](../../.forgejo/workflows/lib/upgrade-functions.sh)
  — shared bash. Sourced by both sandbox + prod workflows.
- [`.forgejo/workflows/okd-upgrade-prod.yaml`](../../.forgejo/workflows/okd-upgrade-prod.yaml)
  — prod variant; same phases, env diffs (Vault path, MCP budgets, default
  `dry_run=true`). Currently dormant — fires only when
  `infrastructure/okd-prod/cluster-version.yaml` exists.

### Trigger model

```text
Operator edits cluster-version.yaml
   ↓
Open PR; Judge validates the digest is in `oc adm upgrade --include-not-recommended`
   ↓
Merge to main
   ↓
.forgejo/workflows/okd-upgrade-sandbox.yaml fires (push paths matcher)
   ↓
preflight → upgrade → poll → validate → notify (Plane comment)
```

`workflow_dispatch` is also wired with two inputs:

| input                    | default | effect                                                                      |
|--------------------------|---------|-----------------------------------------------------------------------------|
| `dry_run`                | `true`  | Run preflight + validate against current cluster; **never** `oc adm upgrade` |
| `allow_not_recommended`  | `true`  | Pass `--allow-not-recommended` (sparse OKD-SCOS upgrade graph)              |

### Local convenience

```bash
make upgrade-dry-run    # workflow_dispatch with dry_run=true
make upgrade            # refuses; tells you to commit cluster-version.yaml
```

### LLM-assist hook

If the `poll` phase exceeds its budget (see env vars in the workflow), the
pipeline calls `upgrade::dump_diagnostics` which:

1. Captures `clusterversion.yaml`, `clusteroperators.json`,
   `machineconfigpools.json`, `nodes.txt`, `events.txt`,
   `upgrade-status.txt`, `upgrade-graph.txt`,
   `mco-operator.log`, and per-node `mcd-<node>.log`.
2. Writes a paste-ready Markdown prompt at
   `${DIAGNOSTICS_DIR}/llm-assist-prompt.md` that the operator can drop
   verbatim into a fresh Claude Code session.
3. Uploads the directory as the `okd-upgrade-diagnostics-<run-id>` workflow
   artefact for download.

The shell pipeline does not modify cluster state past `oc adm upgrade`. All
recovery decisions are operator-driven.

### Required Forgejo repository secrets

The upgrade pipeline reads the following secrets from the Forgejo repository
settings (`Settings → Secrets → Actions`). All are on the `sentinel-iac` repo.

| Secret | Required | Description |
|--------|----------|-------------|
| `VAULT_ROOT_TOKEN` | **Yes** | Vault token with `secret/okd-sandbox` read access. Used by all phases to pull kubeconfig and etcd backup metadata. |
| `PLANE_API_KEY` | **Yes** | Plane API key used by the Phase 5 notify step to post upgrade outcome as a comment on the tracking issue. |
| `TELEGRAM_BOT_TOKEN` | Optional | Bot token for the Overwatch Telegram bot (already provisioned for overwatch-harness). If absent, the Telegram notify step emits a warning and exits 0 — the pipeline continues normally. |
| `TELEGRAM_OPS_CHAT_ID` | Optional | Numeric chat ID of the ops channel where the operator/Claude session lives. Required alongside `TELEGRAM_BOT_TOKEN` for Telegram posts to work. |

**Telegram secrets are optional.** The pipeline runs to completion without
them; you simply do not receive chat notifications. Set both or neither —
if only one is present the step warns and skips.

### Phase budgets (env-overridable in workflow_dispatch follow-up)

| env var                       | default (sandbox) | default (prod) |
|-------------------------------|-------------------|----------------|
| `ETCD_BACKUP_MAX_AGE_HOURS`   | 24                | 12             |
| `MASTER_MCP_BUDGET_MIN`       | 60                | 90             |
| `WORKER_MCP_BUDGET_MIN`       | 90                | 180            |
| `OPERATOR_STUCK_BUDGET_MIN`   | 30                | 45             |
| `ETCD_LATENCY_MAX_MS`         | 100               | 50             |
