# =============================================================================
# Packer Template: forgejo-server (VM 110) - Forgejo Git Forge
# =============================================================================
# This VM runs Forgejo + PostgreSQL + act_runner via Docker Compose.
# Located on pve3. Replaces GitLab CE as the self-hosted git forge.
#
# After building this template:
#   1. terraform apply (create VM from template)
#   2. ansible-playbook ansible/playbooks/forgejo-server.yml
#   3. Configure Keycloak OIDC client and Vault secrets
#   4. Create organization structure and agent accounts
#
# Runtime config:
#   - Docker-compose at /opt/forgejo/docker-compose.yml
#   - Data at /opt/forgejo/data/, /opt/forgejo/postgres/
#   - Route: forgejo.208.haist.farm -> VM direct (port 3000)
#   - SSH: port 2222 (Forgejo SSH passthrough)
# =============================================================================

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "proxmox_url" {
  type    = string
  default = "https://192.168.12.6:8006/api2/json"
}

variable "proxmox_token_id" {
  type    = string
  default = "terraform-prov@pve!api-token"
}

variable "proxmox_token_secret" {
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type    = string
  default = "pve3"
}

variable "vm_id" {
  type    = number
  default = 9110
}

variable "ssh_password" {
  description = "Temporary SSH password for cloud-init build VM (set via PKR_VAR_ssh_password)"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Source: Clone from ubuntu-2404-ci base template
# -----------------------------------------------------------------------------

source "proxmox-clone" "forgejo-server" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  task_timeout = "5m"

  node     = var.proxmox_node
  vm_id    = var.vm_id
  vm_name  = "forgejo-server-template"
  clone_vm = "ubuntu-2404-ci"

  full_clone      = true
  cores           = 2
  memory          = 4096
  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = "40G"
    storage_pool = "local-lvm"
    type         = "scsi"
  }

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  ipconfig {
    ip      = "192.168.12.244/24"
    gateway = "192.168.12.1"
  }

  ssh_username = "ubuntu"
  ssh_password = var.ssh_password
  ssh_timeout  = "10m"
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

build {
  sources = ["source.proxmox-clone.forgejo-server"]

  # Phase 1: Install Docker and dependencies
  provisioner "shell" {
    inline = [
      "sudo apt-get update -y",
      "sudo apt-get install -y docker.io docker-compose-v2 git qemu-guest-agent",
    ]
  }

  # Phase 2: Enable services and create directories
  provisioner "shell" {
    inline = [
      "sudo systemctl enable docker qemu-guest-agent",
      "sudo mkdir -p /opt/forgejo/data /opt/forgejo/postgres",
    ]
  }

  # Phase 3: Cleanup
  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /var/log/syslog /var/log/auth.log || true",
      "sync",
    ]
  }

  post-processor "manifest" {
    output     = "forgejo-server-manifest.json"
    strip_path = true
  }
}
