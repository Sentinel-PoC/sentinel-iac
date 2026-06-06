# Bootstrap Layer - Tier 0
# This layer contains critical infrastructure that must be recoverable manually
# State is stored locally (committed to git) for disaster recovery scenarios
#
# IMPORTANT: This layer should NEVER be managed by CI/CD automation
# It is designed for manual disaster recovery operations only
#
# Credentials:
#   Proxmox: Set TF_VAR_proxmox_api_token env var
#   See: scripts/vault-env.sh

terraform {
  required_version = ">= 1.5.0"

  # Local backend for DR - state file should be committed to git
  # This ensures we can recover even if MinIO/S3 is down
  backend "local" {
    path = "terraform.tfstate"
  }
  
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.70.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true
}
