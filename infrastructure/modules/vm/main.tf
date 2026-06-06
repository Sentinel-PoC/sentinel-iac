# Reusable Proxmox VM Module
# Creates a VM by cloning from a template with cloud-init configuration
#
# Usage:
#   module "my_vm" {
#     source       = "../modules/vm"
#     vm_id        = 205
#     name         = "vault-server"
#     node         = "208-pve2"
#     cores        = 2
#     memory       = 4096
#     disk_size    = 32
#     ip_address   = "192.168.12.206/24"
#     gateway      = "192.168.12.1"
#     template_id  = 9205
#     ssh_public_key = var.ssh_public_key
#   }

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.70.0"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  node_name     = var.node
  vm_id         = var.vm_id
  name          = var.name
  scsi_hardware = var.scsi_hardware

  clone {
    vm_id = var.template_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = var.cores
    type  = var.cpu_type
    numa  = var.cpu_numa
  }

  memory {
    dedicated = var.memory
    floating  = var.memory_floating
  }

  disk {
    datastore_id = var.disk_datastore
    interface    = "scsi0"
    size         = var.disk_size
    iothread     = var.disk_iothread
    ssd          = var.disk_ssd
    discard      = var.disk_discard
  }

  network_device {
    bridge = var.network_bridge
  }

  initialization {
    datastore_id = var.cloud_init_datastore

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.ip_address != "dhcp" ? var.gateway : null
      }
    }

    user_account {
      username = var.vm_user
      keys     = [var.ssh_public_key]
    }
  }

  # DR rebuild: allow destroy+recreate
  # ignore_changes prevents drift from live-migrations, manual scaling, and cloud-init
  lifecycle {
    prevent_destroy = false
    ignore_changes = [
      clone,
      initialization,
      network_device,
      node_name,
    ]
  }

  tags = var.tags
}
