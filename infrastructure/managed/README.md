# Managed Layer (Tier 1) - CI/CD Automated Infrastructure

## Overview

This directory contains Terraform configurations for **non-critical infrastructure** that can be safely managed through automated CI/CD pipelines. These resources depend on the bootstrap layer being operational.

## Resources

| Resource | Type | ID | Node | Purpose |
|----------|------|-----|------|---------|
| n8n_server | VM | 202 | pve | Workflow automation platform |
| manageiq_server | VM | 203 | 208-pve2 | Infrastructure management (CMDB, automation) |

## State Management

State is stored in MinIO S3-compatible storage:
- **Bucket**: `terraform-state`
- **Key**: `sentinel-iac/managed/terraform.tfstate`
- **Endpoint**: `http://192.168.12.58:9000`

## Prerequisites

Before managing this layer, ensure:
1. Bootstrap layer is operational (GitLab, Vault, Config Server)
2. MinIO is accessible at 192.168.12.58:9000
3. Proxmox API is accessible

## CI/CD Integration

This layer is managed by GitLab CI/CD:

```yaml
# Pipeline stages
provision_plan:   # terraform plan (automatic on main)
provision_apply:  # terraform apply (manual trigger)
configure_software: # Ansible configuration (manual)
```

### Running Manually

```bash
cd sentinel-repo/infrastructure/managed

# Initialize
tofu init

# Plan changes
tofu plan

# Apply changes (use with caution)
tofu apply
```

## Adding New Resources

When adding new managed resources:

1. Add the resource to `main.tf`
2. Add any required variables to `variables.tf`
3. Update this README with the new resource
4. Create a merge request for review
5. Let CI/CD handle the apply

## Relationship to Bootstrap Layer

```
Bootstrap Layer (Tier 0)        Managed Layer (Tier 1)
+------------------+            +------------------+
| GitLab (201)     |<---runs----| CI/CD Pipeline   |
| Vault (205)      |<--secrets--| (future)         |
| Config (300)     |            | n8n (202)        |
+------------------+            | ManageIQ (203)   |
        ^                       +------------------+
        |                               |
        +-------depends on--------------+
```

## Disaster Recovery

If this layer needs recovery:

1. Ensure bootstrap layer is operational
2. Run `tofu init` to connect to state backend
3. Run `tofu plan` to see what needs to be created
4. Run `tofu apply` to recreate resources

Unlike the bootstrap layer, this layer can be fully automated since:
- State is in MinIO (requires GitLab + Vault to be up)
- Resources are not critical for DR recovery
- CI/CD can handle the apply

## Security Notes

- Credentials should be moved to Vault (future enhancement)
- CI/CD variables provide credentials during pipeline runs
- For local runs, ensure proper credential management
