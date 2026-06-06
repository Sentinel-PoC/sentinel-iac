# Bootstrap Layer Variables
# These should be kept minimal - bootstrap resources use hardcoded values
# for reliability during disaster recovery
#
# Credentials:
#   Set TF_VAR_proxmox_api_token env var before running tofu plan/apply
#   See: scripts/vault-env.sh

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

# SSH Key - common across all bootstrap resources
variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOaasdPoVflRj8musM9BBmsH1fHLuZypmq3zwCuPjSfw haist@208PC001"
}
