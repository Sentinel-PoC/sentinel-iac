# OKD sandbox cluster — Terraform provider + state backend.
#
# Sandbox is a "delete-and-rebuild" environment for OPS-184 etcd-restore drill
# rehearsals and MW2 OKD upgrade dry-runs. State lives in MinIO at the same
# bucket as the rest of the platform (terraform/okd-sandbox.tfstate) so it can
# be rebuilt from any operator workstation, not just iac-control.

terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket = "terraform-state"
    key    = "terraform/okd-sandbox.tfstate"
    region = "us-east-1"

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
