output "vm_id" {
  description = "The VM ID"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "name" {
  description = "The VM name"
  value       = proxmox_virtual_environment_vm.vm.name
}
