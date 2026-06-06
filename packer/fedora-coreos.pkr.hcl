# Sentinel FCOS Golden Image Template
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type    = string
  default = "https://192.168.12.6:8006/api2/json"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID (e.g. user@pve!token-name)"
  type        = string
  default     = "terraform-prov@pve!api-token"
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret (set via PKR_VAR_proxmox_token_secret env var)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node to build on"
  type        = string
  default     = "pve4-alienware"
}

variable "vm_id" {
  description = "VM ID to assign"
  type        = number
  default     = 9003
}

source "proxmox-iso" "sentinel-fcos" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  node                 = var.proxmox_node
  vm_id                = var.vm_id
  vm_name              = "sentinel-fcos-golden"
  template_description = "Fedora CoreOS Golden Image with Guest Agent"

  ssh_username = "core"

  # Use the existing FCOS qcow2 we downloaded
  boot_iso {
    type     = "scsi"
    iso_file = "local:iso/fedora-coreos-qemu.x86_64.qcow2"
    unmount  = true
  }
}

build {
  sources = ["source.proxmox-iso.sentinel-fcos"]

  provisioner "shell" {
    inline = [
      "rpm-ostree install -y qemu-guest-agent",
      "systemctl enable qemu-guest-agent"
    ]
  }
}
