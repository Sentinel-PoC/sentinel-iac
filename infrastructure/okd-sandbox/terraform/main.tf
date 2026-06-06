# OKD sandbox cluster — 3 masters, agent-based installer.
#
# DEVIATION FROM ARCHITECT'S §3 — module reuse
# ---------------------------------------------
# The architect's plan called for "3 calls into ../../modules/vm/". That module
# is template-clone + cloud-init based: it is built around `clone { vm_id = ...
# }` and a single scsi0 disk and has no MAC-address or extra-disk knobs. The
# OKD agent-based installer requires (a) ISO boot — no template clone, (b) a
# stable MAC address per master so agent-config.yaml can pin host roles, and
# (c) a second blank disk for the Local Storage Operator (Q5).
#
# Generalising the existing module to support all three would have been a
# breaking change to a 5-VM-consumer module. Instead this file uses
# `proxmox_virtual_environment_vm` directly. The pattern stays close to the
# module's conventions (named map of masters, lifecycle ignore_changes,
# per-host node assignment) so future consolidation is straightforward.
# Logged as observation in the OPS-186 PR description.

resource "proxmox_virtual_environment_vm" "master" {
  for_each = var.masters

  node_name     = each.value.node
  vm_id         = each.value.vm_id
  name          = "okd-sandbox-${each.key}"
  scsi_hardware = "virtio-scsi-pci"
  on_boot       = true

  # Agent ISO boot — no template clone. CD-ROM holds the rendered agent ISO;
  # boot order falls back to disk after first reboot (when openshift-install
  # finishes writing the bootstrap image to scsi0).
  cdrom {
    enabled   = true
    file_id   = "${var.agent_iso_storage}:iso/${var.agent_iso_filename}"
    interface = "ide2"
  }

  boot_order = ["ide2", "scsi0"]

  agent {
    enabled = false # qemu-guest-agent is not in the agent ISO; disable to avoid 90s timeout on every action
  }

  cpu {
    cores = var.master_cores
    type  = "host"
  }

  memory {
    dedicated = var.master_memory
  }

  # OS / root disk. OKD writes RHCOS / SCOS here during agent bootstrap.
  disk {
    datastore_id = var.os_disk_datastore
    interface    = "scsi0"
    size         = var.os_disk_size
    file_format  = "raw"
    iothread     = true
  }

  # Local Storage Operator backing disk (Q5). Blank, formatted later by the
  # local-disk-provisioner DaemonSet into a PV for the cluster default SC.
  disk {
    datastore_id = var.lso_disk_datastore
    interface    = "scsi1"
    size         = var.lso_disk_size
    file_format  = "raw"
    iothread     = true
  }

  network_device {
    bridge      = var.network_bridge
    mac_address = each.value.mac_address
    model       = "virtio"
  }

  # NB: no `initialization {}` block — agent ISO carries its own ignition.
  # Cloud-init drive would conflict with the agent ISO bootstrap.

  lifecycle {
    prevent_destroy = false
    # ISO file_id rotates each render; ignore so terraform doesn't try to
    # re-create the VM every time the ISO is re-uploaded.
    ignore_changes = [
      cdrom,
    ]
  }

  tags = var.tags
}
