# =============================================================================
# Managed Layer - VM Recovery / "Delete & Rebuild" Definitions
# =============================================================================
# These VM definitions enable automated recovery via CI/CD pipeline.
# They mirror the bootstrap layer but with prevent_destroy = false.
#
# IMPORTANT NOTES:
# - These VMs also exist in infrastructure/bootstrap/ with prevent_destroy=true
# - The bootstrap layer is for IMPORT/DR reference only
# - This managed layer is for "destroy and recreate" scenarios
# - State is stored in MinIO S3 backend
# - After terraform apply, run the corresponding Ansible playbook to configure
#
# WORKFLOW:
#   1. terraform apply (creates bare VM from template)
#   2. ansible-playbook (configures all services)
#   3. restore script (restores data from backup, if applicable)
# =============================================================================

# -----------------------------------------------------------------------------
# Vault Server (VM 205) - Secrets Management
# Node: 208-pve2 | IP: 192.168.12.206
# After rebuild: ansible-playbook ansible/playbooks/vault-server.yml
# Then: vault operator unseal (manual, Shamir keys from Proton Pass)
# Then: restore from MinIO vault-backups/ (optional)
# -----------------------------------------------------------------------------
module "vault_server" {
  source = "../modules/vm"

  vm_id          = 205 + var.vm_id_offset
  name           = "vault-server${var.resource_suffix}"
  node           = "208-pve2"
  cores          = 2
  memory         = 4096
  disk_size      = 32
  disk_datastore = "vast"
  ip_address     = "192.168.12.206/24"
  gateway        = "192.168.12.1"
  template_id    = 9205 + var.vm_id_offset
  ssh_public_key = var.ssh_public_key
  vm_user        = "koiakoia"
  tags           = ["sentinel", "vault", "managed"]
}

# -----------------------------------------------------------------------------
# GitLab Server (VM 201) - CI/CD Platform
# Node: 208-pve2 | IP: DHCP (typically 192.168.12.68)
# Live-migrated from pve to 208-pve2. Disk on "vast" datastore.
# After rebuild: ansible-playbook ansible/playbooks/gitlab-server.yml
# Then: restore from MinIO gitlab-backups/ (optional)
# -----------------------------------------------------------------------------
module "gitlab_server" {
  source = "../modules/vm"

  vm_id                = 201
  name                 = "gitlab-server"
  node                 = "208-pve2"
  cores                = 4
  memory               = 16384
  disk_size            = 50
  disk_datastore       = "vast"
  cloud_init_datastore = "vast"
  ip_address           = "dhcp"
  template_id          = 9201
  ssh_public_key       = var.ssh_public_key
  vm_user              = "koiakoia"
  tags                 = ["sentinel", "gitlab", "managed"]
}

# -----------------------------------------------------------------------------
# Seedbox VM (VM 109) - qBittorrent + VPN
# Node: 208-pve3 | IP: 192.168.12.69
# After rebuild: ansible-playbook ansible/playbooks/seedbox-vm.yml
# Then: configure VPN credentials manually
# -----------------------------------------------------------------------------
module "seedbox_vm" {
  source = "../modules/vm"

  vm_id           = 109
  name            = "seedbox"
  node            = "pve3"
  cores           = 12
  memory          = 24000
  disk_size       = 32
  ip_address      = "192.168.12.69/24"
  gateway         = "192.168.12.1"
  template_id     = 9109
  ssh_public_key  = var.ssh_public_key
  vm_user         = "koiakoia"
  tags            = ["sentinel", "seedbox", "managed"]
  cpu_type        = "x86-64-v2-AES"
  cpu_numa        = true
  scsi_hardware   = "virtio-scsi-single"
  disk_iothread   = true
  disk_ssd        = true
  memory_floating = 4098
}

# -----------------------------------------------------------------------------
# Forgejo Server (VM 110) - Git Forge
# Node: pve4 | IP: 192.168.12.70 (migrated pve3->pve4 2026-05-29, OPS-1056: decouple
#   code platform + runners from the OKD cluster onto standalone pve4)
# After rebuild: ansible-playbook ansible/playbooks/forgejo-server.yml
# Then: configure Keycloak OIDC client + Vault secrets
# -----------------------------------------------------------------------------
module "forgejo_server" {
  source = "../modules/vm"

  vm_id          = 110
  name           = "forgejo-server"
  node           = "pve4"
  cores          = 2
  memory         = 8192
  disk_size      = 40
  ip_address     = "192.168.12.70/24"
  gateway        = "192.168.12.1"
  template_id    = 9110
  ssh_public_key = var.ssh_public_key
  vm_user        = "koiakoia"
  cpu_type       = "kvm64"
  tags           = ["sentinel", "forgejo", "managed"]
}

# -----------------------------------------------------------------------------
# iac-control (VM 200) - Infrastructure Orchestration
# Node: pve | IP: 192.168.12.210
# NOTE: This is the "seed" VM that runs Terraform itself. Including it here
# is for DR documentation completeness. In practice, iac-control is rebuilt
# via Packer template + manual Ansible from a recovery workstation.
# After rebuild: ansible-playbook ansible/playbooks/iac-control.yml
# Then: restore repos from GitLab, SSH keys from Vault
# -----------------------------------------------------------------------------
module "iac_control" {
  source = "../modules/vm"

  vm_id          = 200
  name           = "iac-control"
  node           = "pve"
  cores          = 8
  memory         = 12288
  disk_size      = 103
  ip_address     = "192.168.12.210/24"
  gateway        = "192.168.12.1"
  template_id    = 9000
  ssh_public_key = var.ssh_public_key
  vm_user        = "ubuntu"
  tags           = ["sentinel", "iac-control", "managed"]
}

# -----------------------------------------------------------------------------
# MinIO Bootstrap (LXC 301) - Object Storage
# Node: 208-pve3 | IP: 192.168.12.58
# NOTE: This is an LXC container, NOT a VM. The vm module cannot manage LXC.
# For MinIO recovery, use the LXC setup script in packer/minio-bootstrap-lxc-setup.sh
# or the Ansible playbook ansible/playbooks/minio-bootstrap.yml against a fresh LXC.
# See also: infrastructure/minio-dr/README.md
# -----------------------------------------------------------------------------
# module "minio_bootstrap" {
#   # LXC containers require proxmox_virtual_environment_container resource
#   # which has different parameters than proxmox_virtual_environment_vm.
#   # MinIO DR is handled via:
#   #   1. Create LXC on pve3 using Proxmox CLI/API
#   #   2. Run ansible-playbook ansible/playbooks/minio-bootstrap.yml
#   #   3. Restore data from B2: rclone sync b2-encrypted: minio:
# }

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "vault_server_id" {
  description = "VM ID of Vault server"
  value       = module.vault_server.vm_id
}

output "gitlab_server_id" {
  description = "VM ID of GitLab server"
  value       = module.gitlab_server.vm_id
}

output "seedbox_vm_id" {
  description = "VM ID of Seedbox"
  value       = module.seedbox_vm.vm_id
}

output "forgejo_server_id" {
  description = "VM ID of Forgejo server"
  value       = module.forgejo_server.vm_id
}

output "iac_control_id" {
  description = "VM ID of iac-control"
  value       = module.iac_control.vm_id
}
