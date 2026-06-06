output "master_vm_ids" {
  description = "Map of master name -> Proxmox VM ID."
  value       = { for k, v in proxmox_virtual_environment_vm.master : k => v.vm_id }
}

output "master_nodes" {
  description = "Map of master name -> Proxmox node hosting it."
  value       = { for k, v in proxmox_virtual_environment_vm.master : k => v.node_name }
}

output "master_ips" {
  description = "Map of master name -> static IP (without CIDR), parsed from var.masters."
  value       = { for k, v in var.masters : k => split("/", v.ip_cidr)[0] }
}
