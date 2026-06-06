#!/bin/bash
set -e

# --- OpenTofu Installation ---
echo "Installing OpenTofu..."
# Download the installer script
curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
# Make it executable
chmod +x install-opentofu.sh
# Run the installer (using Debian package method)
./install-opentofu.sh --install-method deb
# Cleanup
rm install-opentofu.sh
echo "OpenTofu installed successfully."

# --- Ansible Installation ---
echo "Installing Ansible..."
sudo apt-get update
sudo apt-get install -y ansible
echo "Ansible installed successfully."

# --- Verification ---
echo "--------------------------------------------------"
tofu --version
ansible --version
echo "--------------------------------------------------"
echo "IaC Control Node Setup Complete!"
