variable "vm_id" {
  description = "Proxmox VM ID"
  type        = number
}

variable "name" {
  description = "VM name"
  type        = string
}

variable "node" {
  description = "Proxmox node name"
  type        = string
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory in MB"
  type        = number
  default     = 4096
}

variable "disk_size" {
  description = "Disk size in GB"
  type        = number
  default     = 32
}

variable "disk_datastore" {
  description = "Proxmox datastore for disk"
  type        = string
  default     = "local-lvm"
}

variable "network_bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "ip_address" {
  description = "IP address with CIDR (e.g., 192.168.12.206/24) or 'dhcp'"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
  default     = "192.168.12.1"
}

variable "template_id" {
  description = "VM template ID to clone from"
  type        = number
}

variable "ssh_public_key" {
  description = "SSH public key for cloud-init"
  type        = string
}

variable "vm_user" {
  description = "Username for cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "cloud_init_datastore" {
  description = "Datastore for cloud-init drive"
  type        = string
  default     = "local-lvm"
}

variable "tags" {
  description = "Tags for the VM"
  type        = list(string)
  default     = []
}

variable "cpu_type" {
  description = "Emulated CPU type (default: host)"
  type        = string
  default     = "host"
}

variable "cpu_numa" {
  description = "Enable NUMA for the VM"
  type        = bool
  default     = false
}

variable "scsi_hardware" {
  description = "SCSI controller type (virtio-scsi-pci, virtio-scsi-single, etc.)"
  type        = string
  default     = "virtio-scsi-pci"
}

variable "disk_iothread" {
  description = "Enable iothreads for the disk"
  type        = bool
  default     = false
}

variable "disk_ssd" {
  description = "Enable SSD emulation for the disk"
  type        = bool
  default     = false
}

variable "memory_floating" {
  description = "Floating (ballooning) memory in MB, 0 to disable"
  type        = number
  default     = 0
}

variable "disk_discard" {
  description = "Enable discard (TRIM/UNMAP) passthrough for the disk — allows guest fstrim to reclaim thin-provisioned LVM space"
  type        = bool
  default     = true
}
