variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
  default     = "https://192.168.12.6:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form 'user@realm!tokenid=secret'. Source: Vault secret/proxmox/terraform-prov field api_token. NOT the root token."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key injected into agent-config so kubeadmin@<master> works for break-glass. Source: Vault secret/okd-sandbox/ssh field public_key (created by render.sh on first run)."
  type        = string
}

# ----- ISO and image -----------------------------------------------------------

variable "agent_iso_storage" {
  description = "Proxmox datastore where the agent.x86_64.iso lives on each PVE host. ISO is uploaded by `make upload-iso` to this datastore on both pve3 and 208-pve2."
  type        = string
  default     = "local"
}

variable "agent_iso_filename" {
  description = "Filename of the rendered agent ISO inside agent_iso_storage (relative). `make iso` produces _work/agent.x86_64.iso; `make upload-iso` puts it here."
  type        = string
  default     = "okd-sandbox-agent.x86_64.iso"
}

# ----- Disks -------------------------------------------------------------------

variable "os_disk_datastore" {
  description = "Proxmox datastore for the 100 GB OS disk on each master."
  type        = string
  default     = "local-lvm"
}

variable "os_disk_size" {
  description = "OS disk size (GB). OKD 4.19 minimum is 100."
  type        = number
  default     = 100
}

variable "lso_disk_datastore" {
  description = "Proxmox datastore for the 50 GB blank Local Storage Operator disk on each master."
  type        = string
  default     = "local-lvm"
}

variable "lso_disk_size" {
  description = "Local Storage Operator blank disk size (GB) on each master."
  type        = number
  default     = 50
}

# ----- Sizing ------------------------------------------------------------------

variable "master_cores" {
  description = "vCPU cores per master."
  type        = number
  default     = 4
}

variable "master_memory" {
  description = "Memory per master (MB). 12288 = 12 GB — operator-approved deviation from OKD 4.19's 16 GB minimum (documented in runbook §Known Issues)."
  type        = number
  default     = 12288
}

# ----- Network -----------------------------------------------------------------

variable "network_bridge" {
  description = "Proxmox bridge for the master NICs. LAN-shared with the rest of the platform per Q3."
  type        = string
  default     = "vmbr0"
}

variable "machine_network_cidr" {
  description = "CIDR for the master machine network. Must match install-config.networking.machineNetwork."
  type        = string
  default     = "192.168.12.0/24"
}

# Map of per-master attributes. Keys are referenced by Terraform `for_each`.
# Reserved IP block .220-.224 (Q3): masters .220-.222, API VIP .223, Ingress VIP .224.
variable "masters" {
  description = "Per-master attributes."
  type = map(object({
    vm_id       = number
    node        = string
    ip_cidr     = string
    mac_address = string
  }))
  default = {
    "master-1" = {
      vm_id       = 220
      node        = "pve3"
      ip_cidr     = "192.168.12.220/24"
      mac_address = "BC:24:11:00:01:20"
    }
    "master-2" = {
      vm_id       = 221
      node        = "208-pve2"
      ip_cidr     = "192.168.12.221/24"
      mac_address = "BC:24:11:00:01:21"
    }
    "master-3" = {
      vm_id       = 222
      node        = "208-pve2"
      ip_cidr     = "192.168.12.222/24"
      mac_address = "BC:24:11:00:01:22"
    }
  }
}

variable "tags" {
  description = "Tags applied to every master VM."
  type        = list(string)
  default     = ["sentinel", "okd-sandbox", "managed"]
}
