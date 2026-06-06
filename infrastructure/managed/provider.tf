# Managed Layer - Tier 1
# This layer contains infrastructure managed by CI/CD automation
# State is stored in MinIO S3-compatible backend
#
# Prerequisites: Bootstrap layer must be operational
# - GitLab CI/CD running
# - Vault available for secrets
# - MinIO available for state storage
#
# Credentials:
#   S3 backend: Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
#   Proxmox:    Set TF_VAR_proxmox_api_token env var
#   See: scripts/vault-env.sh

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket = "terraform-state"
    key    = "sentinel-iac/managed/terraform.tfstate"
    region = "us-east-1"

    # MinIO configuration
    # Credentials via AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars
    endpoints = {
      s3 = "http://192.168.12.58:9000"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
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
