# Terraform Modules

## Overview

Terraform (via OpenTofu) manages VM provisioning on the Proxmox cluster. The configuration is split into two layers:

- **`infrastructure/managed/`** — Production VM definitions (used in CI)
- **`infrastructure/bootstrap/`** — DR-only bootstrap layer (never in CI)
- **`infrastructure/modules/vm/`** — Reusable VM module

## VM Module

The `modules/vm/` module provides a standardized interface for creating Proxmox VMs:

```hcl
module "vm_name" {
  source = "../modules/vm"

  name        = "vm-name"
  target_node = "pve"
  vmid        = 200
  clone       = "ubuntu-template"
  cores       = 4
  memory      = 8192
  disk_size   = "50G"
  ip_config   = "ip=192.168.12.x/24,gw=192.168.12.1"
}
```

## Managed Layer

`infrastructure/managed/` contains the production Terraform definitions:

- `main.tf` — VM resource definitions for all managed VMs
- `provider.tf` — Proxmox provider configuration
- `variables.tf` — Input variables (API URL, credentials, node names)

### Credentials

Proxmox API credentials are stored in Vault at `secret/proxmox*` and injected via CI environment variables.

## Usage

```bash
# From iac-control:
cd ~/sentinel-repo/infrastructure/managed
tofu init
tofu plan      # Preview changes
tofu apply     # Apply (manual trigger in CI)
```

## Packer Golden Images

Packer templates build golden images for VM provisioning:

| Template | Image ID | Node | Purpose |
|----------|----------|------|---------|
| `gitlab-server.pkr.hcl` | 9201 | pve | GitLab CE base image |
| `vault-server.pkr.hcl` | 9205 | 208-pve2 | Vault server base image |
| `seedbox-vm.pkr.hcl` | 9109 | pve3 | Seedbox base image |
| `iac-control.pkr.hcl` | — | pve | IaC control node image |
| `minio-bootstrap.pkr.hcl` | — | pve3 | MinIO LXC image |
| `fedora-coreos.pkr.hcl` | — | — | CoreOS for OKD nodes |

> **Important**: Always use per-file init (`packer init <file>.pkr.hcl`), not `packer init .` which fails with duplicate variable declarations across templates.

## CI Integration

Terraform and Packer stages run as manual-trigger jobs on the `main` branch:

- `packer-validate` — Validates all Packer templates (automated)
- `build-templates` — Builds golden images (manual trigger)
- `provision` — Runs `tofu plan` and `tofu apply` (manual trigger)
