# CI Runners

**OPS-618** | See also: [CI Runner Pool — full runbook](ci/runner-pool.md)

## Quick Reference

The Overwatch platform runs 4 Forgejo Actions runners:

| Runner | IP | Labels | Notes |
|--------|----|--------|-------|
| `iac-control` | 192.168.12.210 | `iac`, `self-hosted`, `ubuntu-latest` | Persistent; has local creds (`/etc/cosign/`, `/etc/sentinel/`) |
| `runner-pve4-1` | 192.168.12.82 | `iac`, `cpu-heavy`, `self-hosted`, `ubuntu-latest`, `linux`, `docker`, `runner-pve4-1` | pve4-alienware VMID 210 |
| `runner-pve4-2` | 192.168.12.85 | `iac`, `cpu-heavy`, `self-hosted`, `ubuntu-latest`, `linux`, `docker`, `runner-pve4-2` | pve4-alienware VMID 211 |
| `runner-pve4-3` | 192.168.12.84 | `iac`, `cpu-heavy`, `self-hosted`, `ubuntu-latest`, `linux`, `docker`, `runner-pve4-3` | pve4-alienware VMID 212 |

## Routing Summary

- **`runs-on: iac`** — dispatches to any of the 4 runners. Use for lightweight jobs or jobs that need iac-control local resources (compliance env, cosign key, kubeconfig).
- **`runs-on: cpu-heavy`** — dispatches to pve4 pool only (3 runners). Use for CPU-intensive scans: trivy, semgrep, gitleaks, checkov, ansible-lint.

Heavy scan jobs in `security-scan.yml`, `sast-semgrep.yml`, `ansible-lint.yml`, and `gitleaks-full-history.yml` are routed to `cpu-heavy` (implemented OPS-618).

## Full Documentation

See [docs/ci/runner-pool.md](ci/runner-pool.md) for:
- Full topology and label taxonomy
- Workflow routing decision matrix
- Ansible role reference and operator runbook
- Runner restart and maintenance procedures
