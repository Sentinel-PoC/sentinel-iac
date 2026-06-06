#!/bin/bash
# =============================================================================
# Day 0 Bootstrap: Create Ubuntu 24.04 Cloud-Init Template on Proxmox
# =============================================================================
# This script must be run on a Proxmox node BEFORE Packer can build iac-control.
# It creates template ID 9000 (ubuntu-2404-ci) that Packer clones from.
#
# Usage: ssh root@<proxmox-node> 'bash -s' < scripts/create-cloud-init-template.sh
# Or:    scp to node and run locally
# =============================================================================

set -euo pipefail

TEMPLATE_ID="${1:-9000}"
TEMPLATE_NAME="ubuntu-2404-ci"
STORAGE="local-lvm"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMAGE_FILE="/tmp/noble-server-cloudimg-amd64.img"

echo "=== Creating Proxmox cloud-init template ==="
echo "Template ID: ${TEMPLATE_ID}"
echo "Template Name: ${TEMPLATE_NAME}"
echo "Storage: ${STORAGE}"

# Check if template already exists
if qm status "${TEMPLATE_ID}" &>/dev/null; then
    echo "ERROR: VM/Template ${TEMPLATE_ID} already exists. Remove it first or use a different ID."
    exit 1
fi

# Download Ubuntu cloud image
if [ -f "${IMAGE_FILE}" ]; then
    echo "Image already downloaded at ${IMAGE_FILE}, skipping download"
else
    echo "Downloading Ubuntu 24.04 cloud image..."
    wget -O "${IMAGE_FILE}" "${IMAGE_URL}"
fi

# Create VM
echo "Creating VM ${TEMPLATE_ID}..."
qm create "${TEMPLATE_ID}" \
    --name "${TEMPLATE_NAME}" \
    --memory 2048 \
    --cores 2 \
    --net0 "virtio,bridge=vmbr0" \
    --agent "enabled=1"

# Import disk
echo "Importing disk..."
qm importdisk "${TEMPLATE_ID}" "${IMAGE_FILE}" "${STORAGE}"

# Configure VM
echo "Configuring VM..."
qm set "${TEMPLATE_ID}" \
    --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:vm-${TEMPLATE_ID}-disk-0" \
    --ide2 "${STORAGE}:cloudinit" \
    --boot c \
    --bootdisk scsi0 \
    --serial0 socket \
    --vga serial0

# Convert to template
echo "Converting to template..."
qm template "${TEMPLATE_ID}"

echo "=== Template ${TEMPLATE_ID} (${TEMPLATE_NAME}) created successfully ==="
echo "Packer can now clone from this template."

# Cleanup
rm -f "${IMAGE_FILE}"
echo "Cleaned up downloaded image."
