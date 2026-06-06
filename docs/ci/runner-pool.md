# CI Runner Pool — Topology, Label Taxonomy, and Operator Runbook

**OPS-582 / OPS-618** | Last updated: 2026-05-29

## Overview

The Overwatch platform CI runner pool consists of 4 runners:

| Runner | Host | VMID | IP | Status |
|--------|------|------|----|--------|
| `iac-control` | iac-control (192.168.12.210) | N/A | 192.168.12.210 | **Persistent** — primary site |
| `runner-pve4-1` | pve4-alienware (192.168.12.60) | 210 | 192.168.12.82 | **Online** — OPS-582 deployed 2026-05-18 |
| `runner-pve4-2` | pve4-alienware (192.168.12.60) | 211 | 192.168.12.85 | **Online** — OPS-582 deployed 2026-05-18 (IP .85, not .83; .83 is authentik-server LXC 300) |
| `runner-pve4-3` | pve4-alienware (192.168.12.60) | 212 | 192.168.12.84 | **Online** — OPS-582 deployed 2026-05-18 |

**Maximum concurrency: 4 jobs** (1 capacity per runner, no queue contention when pool has capacity).

## Label Taxonomy

Labels follow the [Forgejo runner label format](https://forgejo.org/docs/next/admin/actions/configuration/#choosing-labels):  
`<label-name>:<type>` for host-type or `<label-name>:<type>://<image>` for Docker-type.

### Labels on `iac-control` runner

| Label | Type | Purpose |
|-------|------|---------|
| `iac` | host | **All existing sentinel-iac workflows** use `runs-on: iac` |
| `self-hosted` | host | Standard self-hosted label |
| `ubuntu-latest` | host | GitHub Actions compatibility |

### Labels on `runner-pve4-1/2/3` (new pool)

| Label | Type | Purpose |
|-------|------|---------|
| `iac` | host | Matches existing `runs-on: iac` workflows — distributes load across pool |
| `self-hosted` | host | Standard self-hosted label |
| `ubuntu-latest` | host | GitHub Actions compatibility |
| `linux` | host | Generic Linux target |
| `cpu-heavy` | host | CPU-intensive jobs: semgrep, trivy-image, checkov |
| `runner-pve4-N` | host | Unique per-runner; use for targeted dispatch or debugging |
| `docker` | docker | Docker-containerised jobs using `ghcr.io/catthehacker/ubuntu:act-22.04` |

## Workflow Dispatch Rules (Implemented — OPS-618)

**Label routing** (all 4 runners have `iac:host`; pve4 runners also have `cpu-heavy:host`):
- `runs-on: iac` → Forgejo dispatches to any of the 4 runners (load-balanced)
- `runs-on: cpu-heavy` → dispatches to any of the 3 pve4 runners only (iac-control excluded)
- `runs-on: runner-pve4-1` → dispatches to runner-pve4-1 exclusively

**Routing decision matrix** (implemented in `.forgejo/workflows/` as of OPS-618):

| Workflow | Job(s) | Label | Rationale |
|----------|--------|-------|-----------|
| `security-scan.yml` | trivy-iac, trivy-config, trivy-vuln, trivy-image-pr, trivy-image-nightly, gitleaks, checkov, shellcheck, semgrep | `cpu-heavy` | CPU-intensive scans; no iac-control local filesystem deps |
| `security-scan.yml` | supply-chain-matrix | `iac` | Lightweight matrix generation |
| `security-scan.yml` | supply-chain-scan | `iac` | Requires `/etc/cosign/cosign.key` on iac-control |
| `security-scan.yml` | check-defectdojo-health | `iac` | Lightweight health check |
| `sast-semgrep.yml` | semgrep | `cpu-heavy` | CPU-intensive SAST scan |
| `ansible-lint.yml` | syntax-check, ansible-lint | `cpu-heavy` | CPU-intensive lint |
| `gitleaks-full-history.yml` | gitleaks-full-history | `cpu-heavy` | CPU-intensive full-history scan |
| `compliance-heartbeat.yml` | compliance-heartbeat | `iac` | Requires `/etc/sentinel/compliance.env` on iac-control |
| `compliance-regression-alert.yml` | compliance-regression-alert | `iac` | Reads iac-control compliance state |
| `compliance-report.yml` | compliance-report | `iac` | Reads iac-control compliance state |
| `disaster-recovery.yml` | disaster-recovery | `iac` | Backup operations from iac-control |
| `okd-upgrade-prod.yaml` | okd-upgrade-prod | `iac` | Requires kubeconfig on iac-control |
| `okd-upgrade-sandbox.yaml` | okd-upgrade-sandbox | `iac` | Requires kubeconfig on iac-control |
| `lint.yml` | all jobs | `iac` | Lightweight YAML/terraform lint |
| `terraform.yml` | all jobs | `iac` | Lightweight terraform validate |
| `agent-state-guard.yml` | agent-state-guard | `iac` | Lightweight guard script |
| `rebuild.yml` | rebuild | `iac` | Build orchestration |

## pve4 Resource Budget

pve4-alienware: AMD Ryzen 9 5900X (12 cores), 64 GB RAM

| Consumer | Cores | RAM |
|----------|-------|-----|
| ai-tier1 LXC (Ollama/GPU) | 8 | 16 GB |
| home-assistant LXC | 4 | 4 GB |
| runner-pve4-1 | 2 | 4 GB |
| runner-pve4-2 | 2 | 4 GB |
| runner-pve4-3 | 2 | 4 GB |
| **Total allocated** | **18/12 (overcommit)** | **32/64 GB** |

Note: CPU overcommit to 18 on a 12-core host is safe for CI workloads — jobs are rarely all CPU-pinned simultaneously. RAM is within budget (32/64 GB, 50%).

## Ansible Role Reference

Role: `ansible/roles/forgejo-runner-pool`  
Playbook: `ansible/playbooks/forgejo-runner-pool.yml`  
Host vars: `ansible/inventory/host_vars/pve4-alienware/main.yml`

### Tags

| Tag | What it runs |
|-----|--------------|
| `forgejo-runner-pool` | Full role |
| `lxc` | LXC provisioning only |
| `docker` | Docker install only |
| `runner-install` | Binary + service install only |
| `runner-register` | Registration only (requires Vault tokens) |
| `verify` | Verification checks only |

## Operator Runbook

### Initial Deployment (post-merge)

1. **Provision LXCs and install software** (no tokens needed):
   ```bash
   VAULT_TOKEN=$(cat ~/.vault-token) VAULT_ADDR=https://192.168.12.206:8200 \
     VAULT_SKIP_VERIFY=true ansible-playbook \
     -i ansible/inventory/hosts.yml --limit pve4-alienware \
     ansible/playbooks/forgejo-runner-pool.yml \
     --tags "lxc,docker,runner-install,verify"
   ```

2. **Add registration tokens to Vault** (see README.md in the role for full instructions):
   - Go to <https://forgejo.208.haist.farm/admin/actions/runners>
   - Create 3 runners, get tokens
   - `vault kv put secret/forgejo-runner/pve4-N token=<TOKEN>` for N=1,2,3

3. **Register runners**:
   ```bash
   VAULT_TOKEN=$(cat ~/.vault-token) VAULT_ADDR=https://192.168.12.206:8200 \
     VAULT_SKIP_VERIFY=true ansible-playbook \
     -i ansible/inventory/hosts.yml --limit pve4-alienware \
     ansible/playbooks/forgejo-runner-pool.yml \
     --tags runner-register
   ```

4. **Verify in Forgejo UI**: <https://forgejo.208.haist.farm/admin/actions/runners>

### Runner Restart (if stuck/wedged)

```bash
# Restart a specific runner (replace 210 with target VMID):
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 \
  "pct exec 210 -- systemctl restart forgejo-runner"

# Check status:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 \
  "pct exec 210 -- systemctl status forgejo-runner --no-pager -l"

# Check logs:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 \
  "pct exec 210 -- journalctl -u forgejo-runner -n 50 --no-pager"
```

### Runner Emergency Drain (graceful shutdown for maintenance)

```bash
# The forgejo-runner service has Restart=on-failure.
# To drain gracefully (let running jobs finish):
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 \
  "pct exec 210 -- systemctl stop forgejo-runner"
# Runner will appear offline in Forgejo UI; pending jobs re-queue to other runners.
# Re-enable after maintenance: systemctl start forgejo-runner
```

### LXC Maintenance

```bash
# Stop LXC:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct stop 210"

# Start LXC:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct start 210"

# Access LXC shell:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct enter 210"
```

### DR Site (810) Transfer (OPS-598)

When pve4 moves to the DR Site (810):
1. Ensure runner LXCs are stopped cleanly: `pct stop 210 211 212`
2. After physical move, start pve4: runners will boot and re-register with Forgejo on their own
3. No configuration changes needed — `forgejo_runner_instance_url` is a DNS name, not IP
4. `iac-control` runner at the primary site continues handling `iac` jobs during the transfer window

## Security Notes

- Each runner LXC is **unprivileged** with minimal features (nesting=1, keyctl=1)
- Registration tokens are single-use and stored in Vault (`secret/forgejo-runner/pve4-N`)
- Long-lived runner credentials (UUID + token) are in `.runner` file inside each LXC at `/opt/forgejo-runner/.runner`
- Runner-to-Forgejo connection uses HTTPS with TLS verification enabled (`insecure: false` in config.yaml)
- Each runner has isolated Docker socket — container escapes stay within the LXC boundary
- For SPIRE/mTLS runner identity, see future hardening issue (referenced in OPS-582 out-of-scope section)
