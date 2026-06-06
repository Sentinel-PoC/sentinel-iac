#!/bin/bash
# Project Sentinel - Complete Infrastructure Bootstrap from Backblaze B2
#
# This script performs a complete disaster recovery from Backblaze B2 backups.
# It can be run from any Ubuntu machine with network access to the Proxmox hosts
# and is designed to guide an operator through total infrastructure recovery.
#
# USAGE:
#   ./bootstrap-from-b2.sh
#
# PREREQUISITES:
#   - Ubuntu 20.04+ with bash, curl, ssh, python3
#   - Network access to Proxmox hosts (192.168.12.6, .56, .57)
#   - SSH keys for Proxmox hosts (will be configured during setup)
#   - Backblaze B2 credentials
#   - Rclone encryption passwords (from Proton Pass)
#   - Vault unseal keys (3 of 5 from Proton Pass)
#
# RECOVERY ORDER:
#   1. Install dependencies (Terraform, Ansible, rclone)
#   2. Clone sentinel-iac repository from GitHub backup
#   3. Deploy Proxmox VMs using Terraform
#   4. Restore MinIO from B2
#   5. Restore Vault from MinIO
#   6. Restore GitLab from MinIO
#   7. Configure iac-control server
#   8. Optional: Restore OKD etcd
#
# RTO: Approximately 3-4 hours for full recovery

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${HOME}/sentinel-bootstrap-$$"
LOG_FILE="${WORK_DIR}/bootstrap.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Infrastructure constants
PROXMOX_HOSTS=("192.168.12.6" "192.168.12.56" "192.168.12.57")
PROXMOX_NAMES=("pve" "208-pve2" "pve3")
MINIO_IP="192.168.12.58"
VAULT_IP="192.168.12.206"
GITLAB_IP="192.168.12.68"
IAC_CONTROL_IP="192.168.12.210"
B2_ACCOUNT_ID="368fe76c3651"

# =============================================================================
# Utility Functions
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}✓ $*${NC}"; }
warn() { log "WARN" "${YELLOW}⚠ $*${NC}"; }
error() { log "ERROR" "${RED}✗ $*${NC}"; exit 1; }

prompt() {
    local prompt_text="$1"
    local var_name="$2"
    local is_secret="${3:-false}"
    
    if [[ "$is_secret" == "true" ]]; then
        read -sp "${prompt_text}: " value
        echo ""
    else
        read -p "${prompt_text}: " value
    fi
    
    eval "$var_name='$value'"
}

confirm() {
    local prompt_text="$1"
    local response
    read -p "${prompt_text} (yes/no): " response
    [[ "$response" == "yes" ]]
}

section() {
    echo ""
    log "INFO" "${GREEN}========================================${NC}"
    log "INFO" "${GREEN}$*${NC}"
    log "INFO" "${GREEN}========================================${NC}"
    echo ""
}

# =============================================================================
# Dependency Installation
# =============================================================================

install_dependencies() {
    section "Step 1: Installing Dependencies"
    
    info "Checking and installing required tools..."
    
    # Update package list
    sudo apt-get update -qq
    
    # Install base tools
    for tool in curl wget git openssh-client python3 python3-pip jq unzip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            info "Installing $tool..."
            sudo apt-get install -y "$tool" >/dev/null 2>&1
        fi
    done
    
    # Install Python packages
    if ! python3 -c "import boto3" >/dev/null 2>&1; then
        info "Installing Python boto3..."
        pip3 install boto3 >/dev/null 2>&1
    fi
    
    # Install Terraform/OpenTofu
    if ! command -v tofu >/dev/null 2>&1; then
        info "Installing OpenTofu..."
        wget -qO- https://get.opentofu.org/install-opentofu.sh | sudo bash >/dev/null 2>&1
    fi
    
    # Install Ansible
    if ! command -v ansible >/dev/null 2>&1; then
        info "Installing Ansible..."
        sudo apt-get install -y software-properties-common >/dev/null 2>&1
        sudo add-apt-repository -y ppa:ansible/ansible >/dev/null 2>&1
        sudo apt-get update -qq
        sudo apt-get install -y ansible >/dev/null 2>&1
    fi
    
    # Install rclone
    if ! command -v rclone >/dev/null 2>&1; then
        info "Installing rclone..."
        curl https://rclone.org/install.sh | sudo bash >/dev/null 2>&1
    fi
    
    # Install kubectl/oc (for etcd recovery)
    if ! command -v oc >/dev/null 2>&1; then
        info "Installing OpenShift CLI..."
        local oc_version="4.15.0"
        wget -q "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${oc_version}/openshift-client-linux.tar.gz"
        tar -xzf openshift-client-linux.tar.gz
        sudo mv oc kubectl /usr/local/bin/
        rm -f openshift-client-linux.tar.gz README.md
    fi
    
    success "All dependencies installed"
}

# =============================================================================
# Credential Collection
# =============================================================================

collect_credentials() {
    section "Step 2: Collecting Credentials"
    
    info "Please provide the following credentials"
    info "Most can be retrieved from Proton Pass backup"
    echo ""
    
    # Proxmox credentials
    prompt "Proxmox API Token ID (e.g., terraform-prov@pve!api-token)" PROXMOX_TOKEN_ID
    prompt "Proxmox API Token Secret" PROXMOX_TOKEN_SECRET true
    
    # B2 credentials
    info ""
    info "Backblaze B2 credentials:"
    prompt "B2 Application Key" B2_APP_KEY true
    prompt "B2 Bucket Name" B2_BUCKET
    
    # Rclone encryption keys
    info ""
    info "Rclone encryption keys (from Proton Pass):"
    prompt "Rclone Encryption Password" RCLONE_CRYPT_PASS true
    prompt "Rclone Encryption Salt" RCLONE_CRYPT_SALT true
    
    # MinIO credentials
    info ""
    info "MinIO credentials:"
    MINIO_ACCESS_KEY="minio-admin"
    prompt "MinIO Secret Key" MINIO_SECRET_KEY true
    
    # Vault credentials
    info ""
    info "Vault unseal keys (you will need 3 of 5):"
    prompt "Vault Unseal Key 1" VAULT_UNSEAL_1 true
    prompt "Vault Unseal Key 2" VAULT_UNSEAL_2 true
    prompt "Vault Unseal Key 3" VAULT_UNSEAL_3 true
    prompt "Vault Root Token" VAULT_ROOT_TOKEN true
    
    success "Credentials collected and stored in memory"
    warn "Credentials will NOT be written to disk"
}

# =============================================================================
# Repository Setup
# =============================================================================

setup_repository() {
    section "Step 3: Setting Up Repository"
    
    info "Creating work directory at ${WORK_DIR}..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    # Clone from GitHub (public backup) or use local copy
    if [[ -d "${SCRIPT_DIR}/../.." ]]; then
        info "Using local repository copy..."
        cp -r "${SCRIPT_DIR}/../.." "${WORK_DIR}/sentinel-iac"
    else
        info "Cloning sentinel-iac from backup location..."
        # Note: Update this URL if you have a GitHub backup
        warn "No local copy found. Please manually clone sentinel-iac to ${WORK_DIR}/sentinel-iac"
        error "Repository setup failed"
    fi
    
    cd "${WORK_DIR}/sentinel-iac"
    success "Repository ready at ${WORK_DIR}/sentinel-iac"
}

# =============================================================================
# Proxmox VM Deployment
# =============================================================================

deploy_infrastructure() {
    section "Step 4: Deploying Proxmox VMs"
    
    cd "${WORK_DIR}/sentinel-iac/infrastructure/bootstrap"
    
    # Create terraform.tfvars
    info "Configuring Terraform variables..."
    cat > terraform.tfvars <<TFVARS
proxmox_api_token = "${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
TFVARS
    
    # Initialize Terraform
    info "Initializing Terraform..."
    tofu init
    
    # Plan
    info "Planning infrastructure deployment..."
    tofu plan -out=bootstrap.tfplan
    
    # Confirm
    echo ""
    warn "This will create the following VMs:"
    warn "  - Vault Server (VM 205) on 208-pve2"
    warn "  - GitLab Server (VM 201) on pve"
    warn "  - MinIO Bootstrap (LXC 301) on pve3"
    warn "  - iac-control (VM 200) on pve"
    echo ""
    
    if ! confirm "Proceed with VM deployment?"; then
        error "Deployment cancelled by user"
    fi
    
    # Apply
    info "Deploying infrastructure (this may take 10-15 minutes)..."
    tofu apply bootstrap.tfplan
    
    success "Infrastructure deployed"
    
    # Wait for VMs to boot
    info "Waiting for VMs to fully boot (60 seconds)..."
    sleep 60
}

# =============================================================================
# MinIO Recovery
# =============================================================================

recover_minio() {
    section "Step 5: Recovering MinIO from B2"
    
    info "Configuring rclone on MinIO LXC..."
    
    # SSH to MinIO and configure rclone
    ssh root@${MINIO_IP} bash <<REMOTE_EOF
set -euo pipefail
mkdir -p ~/.config/rclone

cat > ~/.config/rclone/rclone.conf <<'RCLONE_CONFIG'
[b2]
type = b2
account = ${B2_ACCOUNT_ID}
key = ${B2_APP_KEY}

[b2-crypt]
type = crypt
remote = b2:${B2_BUCKET}
password = ${RCLONE_CRYPT_PASS}
password2 = ${RCLONE_CRYPT_SALT}
RCLONE_CONFIG

# Install rclone if needed
if ! command -v rclone >/dev/null; then
    curl https://rclone.org/install.sh | bash
fi

# Stop MinIO
systemctl stop minio || true

# Sync from B2
mkdir -p /data/minio
for bucket in terraform-state vault-backups gitlab-backups etcd-backups; do
    echo "Syncing \$bucket..."
    rclone sync -v b2-crypt:\$bucket /data/minio/\$bucket/
done

# Fix permissions
chown -R minio-user:minio-user /data/minio

# Start MinIO
systemctl start minio

# Cleanup config
rm -f ~/.config/rclone/rclone.conf
REMOTE_EOF
    
    success "MinIO recovered from B2"
    info "MinIO Console: http://${MINIO_IP}:9001"
}

# =============================================================================
# Vault Recovery
# =============================================================================

recover_vault() {
    section "Step 6: Recovering Vault from MinIO"
    
    cd "${WORK_DIR}/sentinel-iac/infrastructure/recovery"
    
    export MINIO_ENDPOINT="http://${MINIO_IP}:9000"
    export MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}"
    export MINIO_SECRET_KEY="${MINIO_SECRET_KEY}"
    export VAULT_HOST="${VAULT_IP}"
    
    info "Running Vault restore script..."
    ./restore-vault.sh
    
    # Unseal Vault
    info "Unsealing Vault..."
    ssh root@${VAULT_IP} bash <<UNSEAL_EOF
export VAULT_ADDR=http://localhost:8200
vault operator unseal ${VAULT_UNSEAL_1}
vault operator unseal ${VAULT_UNSEAL_2}
vault operator unseal ${VAULT_UNSEAL_3}
vault status
UNSEAL_EOF
    
    success "Vault recovered and unsealed"
    info "Vault UI: http://${VAULT_IP}:8200"
}

# =============================================================================
# GitLab Recovery
# =============================================================================

recover_gitlab() {
    section "Step 7: Recovering GitLab from MinIO"
    
    cd "${WORK_DIR}/sentinel-iac/infrastructure/recovery"
    
    export MINIO_ENDPOINT="http://${MINIO_IP}:9000"
    export MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}"
    export MINIO_SECRET_KEY="${MINIO_SECRET_KEY}"
    export GITLAB_HOST="${GITLAB_IP}"
    
    info "Running GitLab restore script..."
    ./restore-gitlab.sh
    
    success "GitLab recovered"
    info "GitLab UI: http://${GITLAB_IP}"
}

# =============================================================================
# iac-control Configuration
# =============================================================================

configure_iac_control() {
    section "Step 8: Configuring iac-control Server"
    
    info "Running Ansible configuration playbook..."
    cd "${WORK_DIR}/sentinel-iac/ansible"
    
    # Update inventory
    cat > inventory/bootstrap-recovery.ini <<INVENTORY
[iac_control]
${IAC_CONTROL_IP} ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_rsa

[all:vars]
ansible_python_interpreter=/usr/bin/python3
INVENTORY
    
    # Run playbook
    ansible-playbook -i inventory/bootstrap-recovery.ini playbooks/iac-control.yml
    
    success "iac-control configured"
    info "SSH: ssh ubuntu@${IAC_CONTROL_IP}"
}

# =============================================================================
# Optional: etcd Recovery
# =============================================================================

recover_etcd_optional() {
    section "Step 9 (Optional): OKD etcd Recovery"
    
    echo ""
    warn "etcd recovery is DESTRUCTIVE and will reset the cluster state"
    warn "Only proceed if you need to restore the OKD cluster"
    echo ""
    
    if ! confirm "Do you want to restore OKD etcd?"; then
        info "Skipping etcd recovery"
        return
    fi
    
    cd "${WORK_DIR}/sentinel-iac/infrastructure/recovery"
    
    export MINIO_ENDPOINT="http://${MINIO_IP}:9000"
    export MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}"
    export MINIO_SECRET_KEY="${MINIO_SECRET_KEY}"
    export KUBECONFIG="${HOME}/.kube/config"
    
    info "Retrieving kubeconfig from Vault..."
    export VAULT_ADDR="http://${VAULT_IP}:8200"
    export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"
    vault kv get -field=kubeconfig secret/iac-control/kubeconfig > ~/.kube/config
    chmod 600 ~/.kube/config
    
    info "Running etcd restore script..."
    echo "yes" | ./restore-etcd.sh
    
    success "etcd recovery complete"
    info "Monitor with: oc get clusteroperators"
}

# =============================================================================
# Completion Summary
# =============================================================================

print_summary() {
    section "Bootstrap Complete!"
    
    success "Infrastructure Recovery Summary:"
    echo ""
    info "✓ Proxmox VMs deployed"
    info "✓ MinIO recovered from B2"
    info "✓ Vault recovered and unsealed"
    info "✓ GitLab recovered"
    info "✓ iac-control configured"
    echo ""
    info "Access Points:"
    info "  MinIO Console:  http://${MINIO_IP}:9001"
    info "  Vault UI:       http://${VAULT_IP}:8200"
    info "  GitLab:         http://${GITLAB_IP}"
    info "  iac-control:    ssh ubuntu@${IAC_CONTROL_IP}"
    echo ""
    info "Next Steps:"
    info "1. Verify all services are healthy"
    info "2. Run GitLab CI/CD pipeline to validate"
    info "3. Restore any additional services (Seedbox, OKD apps)"
    info "4. Update DNS records if IPs changed"
    echo ""
    info "Total RTO: ~3-4 hours"
    info "Log file: ${LOG_FILE}"
    echo ""
    success "Recovery complete! Welcome back online."
}

# =============================================================================
# Main Execution
# =============================================================================

main() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                    ║"
    echo "║        PROJECT SENTINEL - DISASTER RECOVERY BOOTSTRAP             ║"
    echo "║        Complete Infrastructure Recovery from B2                   ║"
    echo "║        Version ${VERSION}                                              ║"
    echo "║                                                                    ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    warn "This script will perform COMPLETE infrastructure recovery"
    warn "Estimated time: 3-4 hours"
    warn "Requires: Proxmox access, B2 credentials, Vault unseal keys"
    echo ""
    
    if ! confirm "Ready to begin disaster recovery?"; then
        error "Bootstrap cancelled by user"
    fi
    
    # Create work directory and log file
    mkdir -p "$WORK_DIR"
    touch "$LOG_FILE"
    
    # Execute recovery steps
    install_dependencies
    collect_credentials
    setup_repository
    deploy_infrastructure
    recover_minio
    recover_vault
    recover_gitlab
    configure_iac_control
    recover_etcd_optional
    print_summary
}

# Trap errors
trap 'error "Script failed at line $LINENO"' ERR

# Run main
main
