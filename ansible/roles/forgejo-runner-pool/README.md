# forgejo-runner-pool

**OPS-582** — pve4 CI runner pool: 3 runner LXCs on pve4-alienware to eliminate single-runner CI bottleneck.

## Architecture

| Runner | VMID | IP | Cores | RAM | Labels |
|--------|------|----|-------|-----|--------|
| runner-pve4-1 | 210 | 192.168.12.82 | 2 | 4GB | iac, self-hosted, ubuntu-latest, linux, cpu-heavy, runner-pve4-1, docker |
| runner-pve4-2 | 211 | 192.168.12.83 | 2 | 4GB | iac, self-hosted, ubuntu-latest, linux, cpu-heavy, runner-pve4-2, docker |
| runner-pve4-3 | 212 | 192.168.12.84 | 2 | 4GB | iac, self-hosted, ubuntu-latest, linux, cpu-heavy, runner-pve4-3, docker |

Plus existing `iac-control` runner (VMID N/A, runs on 192.168.12.210, labels: `iac`, `self-hosted`, `ubuntu-latest`) providing geographic redundancy when pve4 moves to the DR Site (810).

## Upstream References

- Forgejo Actions admin guide: <https://forgejo.org/docs/next/admin/actions/>
- Runner registration docs: <https://forgejo.org/docs/next/admin/actions/registration/>
- forgejo-runner source + README: <https://code.forgejo.org/forgejo/runner>

## Docker-in-LXC Cgroup Requirements

The runner LXCs are **unprivileged** (Proxmox default, security baseline) with `features: nesting=1,keyctl=1`.

On **Proxmox 9.1.1 (kernel 6.17+)**, Docker CE works in unprivileged LXC with these features:
- `nesting=1` enables Linux namespace nesting for Docker's overlay2 storage driver
- `keyctl=1` allows the keyctl() syscall needed by Docker credential helpers

**If Docker fails** (symptom: `docker info` returns EPERM or `Failed to connect to bus`):
1. Check `pct exec <vmid> -- journalctl -u docker -n 30`
2. If overlay2 EPERM: add `lxc.apparmor.profile: unconfined` to `/etc/pve/lxc/<vmid>.conf` and restart the LXC
3. If AppArmor isn't the issue: flip to privileged LXC: `pct stop <vmid> && pct set <vmid> --unprivileged 0 && pct start <vmid>`

Note: Docker-in-privileged-LXC is the pattern used by `ha-lxc` (OPS-585) which hosts Docker CE for Home Assistant. The unprivileged approach is tried first per security-default principle.

## Operator Post-Merge Steps (Registration Tokens Required)

Registration tokens are NOT in Vault yet (confirmed: `vault kv list secret/forgejo` shows no runner tokens). The operator must complete these steps before runners can accept jobs:

### Step 1: Create runner registration tokens in Forgejo

1. Log in to <https://forgejo.208.haist.farm> as admin
2. Navigate to **Settings → Actions → Runners** (`/admin/actions/runners`)
3. Click **"Create new runner"** for each of the 3 runners
4. Note the **registration token** displayed (single-use, expires in ~24h)

### Step 2: Store tokens in Vault

```bash
export VAULT_ADDR=https://192.168.12.206:8200
export VAULT_SKIP_VERIFY=true

vault kv put secret/forgejo-runner/pve4-1 token=<TOKEN_FOR_RUNNER_1>
vault kv put secret/forgejo-runner/pve4-2 token=<TOKEN_FOR_RUNNER_2>
vault kv put secret/forgejo-runner/pve4-3 token=<TOKEN_FOR_RUNNER_3>
```

### Step 3: Run the registration playbook

```bash
cd ~/repos/sentinel-iac
VAULT_TOKEN=$(cat ~/.vault-token) VAULT_ADDR=https://192.168.12.206:8200 VAULT_SKIP_VERIFY=true \
  ansible-playbook ansible/playbooks/forgejo-runner-pool.yml \
    --tags runner-register
```

### Step 4: Verify runners appear in Forgejo UI

1. Go to <https://forgejo.208.haist.farm/admin/actions/runners>
2. Confirm `runner-pve4-1`, `runner-pve4-2`, `runner-pve4-3` show as **online**
3. Check labels match: `iac`, `self-hosted`, `ubuntu-latest`, `linux`, `cpu-heavy`, `runner-pve4-N`, `docker`

## Registration Token Rotation

When rotating registration tokens:
1. Generate new tokens via Forgejo UI (new runners section: create then delete old runner entry)
2. Update Vault: `vault kv put secret/forgejo-runner/pve4-N token=<NEW_TOKEN>`
3. Stop service: `pct exec <vmid> -- systemctl stop forgejo-runner`
4. Remove `.runner`: `pct exec <vmid> -- rm /opt/forgejo-runner/.runner`
5. Re-run: `ansible-playbook ansible/playbooks/forgejo-runner-pool.yml --tags runner-register`

## DR Site (810) Transfer Note

Per OPS-598, pve4-alienware will move to the DR Site (810). The runners will reconnect automatically on boot — no per-site configuration is baked into the role. The `iac-control` runner at the primary site provides geographic redundancy during and after the transfer.

## Apply Command (DRY RUN)

```bash
cd ~/repos/sentinel-iac
VAULT_TOKEN=$(cat ~/.vault-token) VAULT_ADDR=https://192.168.12.206:8200 VAULT_SKIP_VERIFY=true \
  ansible-playbook --check --diff \
    -i ansible/inventory/hosts.yml \
    --limit pve4-alienware \
    ansible/playbooks/forgejo-runner-pool.yml
```

## Apply Command (LIVE — operator authorization required)

```bash
cd ~/repos/sentinel-iac
VAULT_TOKEN=$(cat ~/.vault-token) VAULT_ADDR=https://192.168.12.206:8200 VAULT_SKIP_VERIFY=true \
  ansible-playbook \
    -i ansible/inventory/hosts.yml \
    --limit pve4-alienware \
    ansible/playbooks/forgejo-runner-pool.yml
```

## Verification

```bash
# Check LXC containers are running on pve4:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct list"
# Expected: VMIDs 210, 211, 212 all showing "running"

# Check Docker inside each LXC:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct exec 210 -- docker info"

# Check runner service status:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct exec 210 -- systemctl status forgejo-runner"

# Check runner registration:
ssh -i ~/.ssh/pve4_alienware_ed25519 root@192.168.12.60 "pct exec 210 -- cat /opt/forgejo-runner/.runner"

# Verify in Forgejo UI:
# https://forgejo.208.haist.farm/admin/actions/runners
```
