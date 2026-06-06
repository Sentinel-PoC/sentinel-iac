# Bootstrap Layer (Tier 0) - Disaster Recovery Infrastructure

## Overview

This directory contains Terraform configurations for **critical bootstrap infrastructure** that must be recoverable independently of CI/CD pipelines. These resources form the foundation of the infrastructure and are required for the managed layer to function.

## Resources

| Resource | Type | ID | Node | Purpose |
|----------|------|-----|------|---------|
| gitlab_server | VM | 201 | pve | CI/CD platform - runs GitLab and runners |
| vault_server | VM | 205 | 208-pve2 | Secrets management - HashiCorp Vault |
| sentinel_config_server | LXC | 300 | pve | OKD ignition files and cluster config |

## State Management

**IMPORTANT**: This layer uses a **local backend**. The `terraform.tfstate` file should be committed to git.

This design choice ensures:
1. State is available even if MinIO/S3 is down
2. Recovery can proceed without external dependencies
3. State history is preserved in git history

## Disaster Recovery Procedure

### Prerequisites
- Access to Proxmox API (https://192.168.12.6:8006)
- Valid API token for terraform-prov@pve
- Network access to management VLAN (192.168.12.0/24)

### Recovery Steps

1. **Clone the repository** (if not available locally):
   ```bash
   git clone <repo-url> sentinel-repo
   cd sentinel-repo/infrastructure/bootstrap
   ```

2. **Initialize Terraform**:
   ```bash
   tofu init
   # or: terraform init
   ```

3. **Review the current state**:
   ```bash
   tofu plan
   ```

4. **If resources need to be recreated**:
   ```bash
   # Remove from state if resource is destroyed but state exists
   tofu state rm proxmox_virtual_environment_vm.gitlab_server
   
   # Re-apply to create
   tofu apply
   ```

5. **If importing existing resources**:
   ```bash
   # Import GitLab VM
   tofu import proxmox_virtual_environment_vm.gitlab_server pve/qemu/201
   
   # Import Vault VM
   tofu import proxmox_virtual_environment_vm.vault_server 208-pve2/qemu/205
   
   # Import Config Server LXC
   tofu import proxmox_virtual_environment_container.sentinel_config_server pve/lxc/300
   ```

## Recovery Order

If performing a full disaster recovery, resources should be restored in this order:

1. **Vault Server** (VM 205) - Required for secrets
2. **Config Server** (LXC 300) - Required for OKD cluster config
3. **GitLab Server** (VM 201) - Required for CI/CD to resume

## Post-Recovery Checklist

- [ ] Vault is unsealed and accessible at https://192.168.12.206:8200
- [ ] GitLab is accessible and runners are registered
- [ ] Config server is serving ignition files on OKD network
- [ ] CI/CD pipeline can run against managed/ layer

## Security Notes

- API tokens in provider.tf should ideally come from environment variables
- For production, consider using `PROXMOX_VE_API_TOKEN` environment variable
- State file may contain sensitive data - ensure git repo has appropriate access controls

## Related Documentation

- Managed Layer: `../managed/README.md`
- Vault Setup: See Vault documentation
- GitLab Setup: `../install_gitlab.yml`
