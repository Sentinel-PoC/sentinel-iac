# Managed Layer Variables

variable "proxmox_endpoint" {
  description = "Proxmox API endpoint URL"
  type        = string
  default     = "https://192.168.12.6:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token (set via TF_VAR_proxmox_api_token env var)"
  type        = string
  sensitive   = true
  default     = ""
}
variable "resource_suffix" {
  description = "Suffix appended to resource names"
  type        = string
  default     = ""
}

variable "vm_id_offset" {
  description = "Offset added to VM IDs (0 for production)"
  type        = number
  default     = 0
}
# SSH Key - common across all managed resources
variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOaasdPoVflRj8musM9BBmsH1fHLuZypmq3zwCuPjSfw haist@208PC001"
}
