# Bootstrap Layer - Tier 0
# Config Server Only
#
# This layer contains:
# - Config Server (LXC 300) - OKD ignition files
#
# GitLab (201) and Vault (205) are managed in the managed layer
# (infrastructure/managed/) to avoid dual-management state conflicts.
#
# This resource is foundational and must be recoverable independently
# of the managed layer and CI/CD pipeline.

#------------------------------------------------------------------------------
# Sentinel Config Server - OKD Ignition Files
# LXC Container ID: 300 | Node: pve | IP: 10.0.0.2/24 (OKD network)
#------------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "sentinel_config_server" {
  node_name = "pve"
  vm_id     = 300

  initialization {
    hostname = "config-server"
    ip_config {
      ipv4 {
        address = "10.0.0.2/24"
        gateway = "10.0.0.1"
      }
    }
    user_account {
      keys = [var.ssh_public_key]
    }
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr1"
  }

  operating_system {
    template_file_id = "local:vztmpl/ubuntu-25.04-standard_25.04-1.1_amd64.tar.zst"
    type             = "ubuntu"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 8
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      initialization
    ]
  }
}

#------------------------------------------------------------------------------
# Outputs
#------------------------------------------------------------------------------
output "config_server_id" {
  description = "Container ID of Config server"
  value       = proxmox_virtual_environment_container.sentinel_config_server.vm_id
}
