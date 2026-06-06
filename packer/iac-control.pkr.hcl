# =============================================================================
# Packer Template: iac-control (VM 200) - Tier -1 Seed Infrastructure
# =============================================================================
# This VM is the IaC orchestration node that runs OpenTofu, Ansible, and
# GitLab Runner. It also serves as the OKD cluster load balancer (HAProxy),
# DNS/DHCP server (dnsmasq), PXE boot server (nginx), and NAT gateway for
# the 10.0.0.0/24 OKD internal network.
#
# This is a "seed" VM - it cannot be managed by Terraform because it IS the
# machine that runs Terraform. This Packer template exists for disaster
# recovery: rebuild from scratch, then restore repos from GitLab.
# =============================================================================

packer {
  required_plugins {
    proxmox = {
      version = ">= 1.1.2"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "proxmox_url" {
  type    = string
  default = "https://192.168.12.6:8006/api2/json"
}

variable "proxmox_token_id" {
  description = "Proxmox API token ID (e.g. user@pve!token-name)"
  type        = string
  default     = "terraform-prov@pve!api-token"
}

variable "proxmox_token_secret" {
  description = "Proxmox API token secret (set via PKR_VAR_proxmox_token_secret)"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node to build on"
  type        = string
  default     = "pve"
}

variable "vm_id" {
  description = "VM ID to assign"
  type        = number
  default     = 200
}

variable "ssh_public_key" {
  description = "SSH public key for the ubuntu user (cloud-init)"
  type        = string
  default     = ""
}

variable "vault_ca_public_key" {
  description = "Vault SSH CA public key for TrustedUserCAKeys"
  type        = string
  default     = ""
}

variable "gitlab_runner_token" {
  description = "GitLab runner registration token (set via PKR_VAR_gitlab_runner_token)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "gitlab_url" {
  description = "GitLab server URL"
  type        = string
  default     = "http://192.168.12.68"
}

variable "ssh_password" {
  description = "Temporary SSH password for cloud-init build VM (set via PKR_VAR_ssh_password)"
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Source: Ubuntu 24.04 cloud image via proxmox-clone from a cloud-init template
# -----------------------------------------------------------------------------
# PREREQUISITE: An Ubuntu 24.04 cloud-init template must exist on the Proxmox
# node. Create one with:
#   wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
#   qm create 9000 --name ubuntu-2404-ci --memory 2048 --net0 virtio,bridge=vmbr0
#   qm importdisk 9000 noble-server-cloudimg-amd64.img local-lvm
#   qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
#   qm set 9000 --ide2 local-lvm:cloudinit --boot c --bootdisk scsi0
#   qm set 9000 --serial0 socket --vga serial0 --agent enabled=1
#   qm template 9000

source "proxmox-clone" "iac-control" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_token_id
  token                    = var.proxmox_token_secret
  insecure_skip_tls_verify = true

  task_timeout = "5m"

  node    = var.proxmox_node
  vm_id   = var.vm_id
  vm_name = "iac-control"

  # Clone from Ubuntu 24.04 cloud-init template
  clone_vm = "ubuntu-2404-ci"
  full_clone = true

  cores  = 1
  memory = 2048

  scsi_controller = "virtio-scsi-pci"

  # Disk: 64GB on local-lvm (sized for 26 services + 30d log retention)
  disks {
    disk_size    = "64G"
    storage_pool = "local-lvm"
    type         = "scsi"
  }

  # NIC 0: Management network (192.168.12.0/24)
  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  # NIC 1: OKD internal network (10.0.0.0/24)
  network_adapters {
    bridge = "vmbr1"
    model  = "virtio"
  }

  # Cloud-init settings
  cloud_init              = true
  cloud_init_storage_pool = "local-lvm"

  ipconfig {
    ip      = "192.168.12.243/24"
    gateway = "192.168.12.1"
  }

  ssh_username = "ubuntu"
  ssh_password = var.ssh_password
  ssh_timeout  = "10m"
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

build {
  sources = ["source.proxmox-clone.iac-control"]

  # ---------------------------------------------------------------------------
  # Phase 1: Add package repositories (HashiCorp, GitLab Runner, Docker)
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 1: Adding package repositories'",
      "sudo apt-get update -y",
      "sudo apt-get install -y curl gnupg software-properties-common apt-transport-https ca-certificates",

      # HashiCorp repo (tofu, packer)
      "curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg",
      "echo \"deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main\" | sudo tee /etc/apt/sources.list.d/hashicorp.list",

      # OpenTofu repo
      "curl -fsSL https://get.opentofu.org/opentofu.gpg | sudo tee /etc/apt/keyrings/opentofu.gpg >/dev/null",
      "curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | sudo gpg --no-tty --batch --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg 2>/dev/null",
      "echo \"deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main\" | sudo tee /etc/apt/sources.list.d/opentofu.list",

      # GitLab Runner repo
      "curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash",

      "sudo apt-get update -y",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 2: Install all required packages
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 2: Installing packages'",
      "sudo apt-get install -y tofu packer ansible docker.io podman haproxy dnsmasq nginx sshpass gitlab-runner qemu-guest-agent iptables-persistent net-tools jq git vim open-vm-tools pipx",
      "sudo PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install semgrep",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 3: Configure networking (dual-NIC, IP forwarding, NAT)
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 3: Configuring networking'",

      # Enable IP forwarding persistently
      "echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ip-forward.conf",
      "sudo sysctl -w net.ipv4.ip_forward=1",

      # Configure secondary NIC (ens19 / eth1) with static IP for OKD network
      # cloud-init handles eth0 (192.168.12.210/24), we configure ens19 manually
      "sudo tee /etc/systemd/network/20-okd-internal.network > /dev/null <<'NETCFG'",
      "[Match]",
      "Name=ens19 enp0s19",
      "",
      "[Network]",
      "Address=10.0.0.10/24",
      "Address=10.0.0.1/24",
      "NETCFG",

      # NAT masquerade for OKD network (10.0.0.0/24 -> eth0)
      "sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE",
      # Forwarding rules
      "sudo iptables -A FORWARD -i ens19 -o eth0 -j ACCEPT",
      "sudo iptables -A FORWARD -i eth0 -o ens19 -m state --state RELATED,ESTABLISHED -j ACCEPT",
      "sudo iptables -A FORWARD -i eth0 -o ens19 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
      # Persist iptables
      "sudo sh -c 'iptables-save > /etc/iptables/rules.v4'",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 4: Configure HAProxy (OKD API + Ingress load balancer)
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 4: Configuring HAProxy'",
      "sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'HAPCFG'",
      "global",
      "    log /dev/log local0",
      "    log /dev/log local1 notice",
      "    chroot /var/lib/haproxy",
      "    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners",
      "    stats timeout 30s",
      "    user haproxy",
      "    group haproxy",
      "    daemon",
      "    ca-base /etc/ssl/certs",
      "    crt-base /etc/ssl/private",
      "    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384",
      "    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256",
      "    ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets",
      "",
      "defaults",
      "    log     global",
      "    mode    http",
      "    option  httplog",
      "    option  dontlognull",
      "    timeout connect 5000",
      "    timeout client  50000",
      "    timeout server  50000",
      "    errorfile 400 /etc/haproxy/errors/400.http",
      "    errorfile 403 /etc/haproxy/errors/403.http",
      "    errorfile 408 /etc/haproxy/errors/408.http",
      "    errorfile 500 /etc/haproxy/errors/500.http",
      "    errorfile 502 /etc/haproxy/errors/502.http",
      "    errorfile 503 /etc/haproxy/errors/503.http",
      "    errorfile 504 /etc/haproxy/errors/504.http",
      "",
      "# --- OKD 4 Overwatch Cluster Load Balancing ---",
      "",
      "frontend okd4_api_frontend",
      "    bind *:6443",
      "    default_backend okd4_api_backend",
      "    mode tcp",
      "    option tcplog",
      "",
      "backend okd4_api_backend",
      "    balance roundrobin",
      "    mode tcp",
      "    server master1   10.0.0.221:6443 check",
      "    server master2   10.0.0.222:6443 check",
      "    server master3   10.0.0.223:6443 check",
      "",
      "frontend okd4_machine_config_frontend",
      "    bind *:22623",
      "    default_backend okd4_machine_config_backend",
      "    mode tcp",
      "    option tcplog",
      "",
      "backend okd4_machine_config_backend",
      "    balance roundrobin",
      "    mode tcp",
      "    server master1   10.0.0.221:22623 check",
      "    server master2   10.0.0.222:22623 check",
      "    server master3   10.0.0.223:22623 check",
      "",
      "frontend okd4_http_ingress_frontend",
      "    bind *:80",
      "    default_backend okd4_http_ingress_backend",
      "    mode tcp",
      "    option tcplog",
      "",
      "backend okd4_http_ingress_backend",
      "    balance roundrobin",
      "    mode tcp",
      "    server master1 10.0.0.221:80 check",
      "    server master2 10.0.0.222:80 check",
      "    server master3 10.0.0.223:80 check",
      "",
      "frontend okd4_https_ingress_frontend",
      "    bind *:443",
      "    default_backend okd4_https_ingress_backend",
      "    mode tcp",
      "    option tcplog",
      "",
      "backend okd4_https_ingress_backend",
      "    balance roundrobin",
      "    mode tcp",
      "    server master1 10.0.0.221:443 check",
      "    server master2 10.0.0.222:443 check",
      "    server master3 10.0.0.223:443 check",
      "",
      "listen stats",
      "    bind :9000",
      "    mode http",
      "    stats enable",
      "    stats uri /",
      "    stats hide-version",
      "HAPCFG",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 5: Configure dnsmasq (DNS + DHCP + PXE for OKD cluster)
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 5: Configuring dnsmasq'",

      # Disable systemd-resolved to free port 53 (dnsmasq needs it)
      "sudo systemctl disable --now systemd-resolved || true",
      "sudo rm -f /etc/resolv.conf",
      "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf",
      "echo 'nameserver 1.1.1.1' | sudo tee -a /etc/resolv.conf",

      "sudo tee /etc/dnsmasq.d/overwatch.conf > /dev/null <<'DNSCFG'",
      "log-queries",
      "# OpenShift SCOS PXE & DNS Configuration",
      "# Network: 10.0.0.0/24",
      "# Domain: overwatch.haist.farm",
      "",
      "# --- Interface Binding ---",
      "interface=ens19",
      "bind-interfaces",
      "except-interface=fan-*",
      "",
      "# --- DHCP Configuration ---",
      "dhcp-range=10.0.0.50,10.0.0.100,12h",
      "dhcp-option=3,10.0.0.1",
      "dhcp-option=6,10.0.0.1",
      "",
      "# --- DNS Configuration ---",
      "domain=overwatch.haist.farm",
      "local=/overwatch.haist.farm/",
      "expand-hosts",
      "",
      "# --- Static DNS Records (Load Balancer) ---",
      "address=/api.overwatch.haist.farm/10.0.0.1",
      "address=/api-int.overwatch.haist.farm/10.0.0.1",
      "address=/.apps.overwatch.haist.farm/10.0.0.1",
      "",
      "# --- PXE / iPXE Booting ---",
      "dhcp-match=set:ipxe,175",
      "",
      "# --- Static Leases & Node Definitions ---",
      "dhcp-host=bc:24:11:d8:cf:14,10.0.0.220,set:bootstrap",
      "dhcp-host=BC:24:11:F1:90:7A,master-1,10.0.0.221,set:master",
      "dhcp-host=BC:24:11:54:EF:CF,master-2,10.0.0.222,set:master",
      "dhcp-host=BC:24:11:EC:8C:91,master-3,10.0.0.223,set:master",
      "",
      "# --- Boot Logic ---",
      "dhcp-boot=tag:bootstrap,tag:ipxe,http://10.0.0.2/ignition/bootstrap.ipxe",
      "dhcp-boot=tag:master,tag:ipxe,http://10.0.0.2/ignition/master.ipxe",
      "",
      "# --- Upstream Forwarding ---",
      "server=1.1.1.1",
      "server=8.8.8.8",
      "DNSCFG",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 6: Configure nginx (PXE/ignition file server on port 8080)
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 6: Configuring nginx'",
      # nginx default serves on port 80 but HAProxy uses 80 for OKD ingress,
      # so nginx listens on 8080 for serving ignition/PXE files.
      # NOTE: The dnsmasq PXE config points to 10.0.0.2:80 - this may need
      # updating depending on how the nginx port is resolved in production.
      # The current live system has nginx on port 80 (default config) and
      # HAProxy also on port 80 - HAProxy wins the bind. Nginx serves files
      # on the internal network only, where HAProxy binds apply.
      "sudo mkdir -p /var/www/html/ignition",
      "sudo mkdir -p /var/www/html/scos",
      "sudo chown -R www-data:www-data /var/www/html",

      # Create iPXE boot scripts
      "sudo tee /var/www/html/bootstrap.ipxe > /dev/null <<'IPXE'",
      "#!ipxe",
      "kernel http://10.0.0.2/scos/vmlinuz initrd=initrd.img coreos.inst.install_dev=/dev/sda coreos.inst.insecure coreos.inst.image_url=http://10.0.0.2/scos/metal.raw.gz coreos.inst.ignition_url=http://10.0.0.2/ignition/bootstrap-install.ign ip=dhcp nameserver=10.0.0.2 console=tty0 console=ttyS0,115200n8 coreos.live.rootfs_url=http://10.0.0.2/scos/rootfs.img",
      "initrd http://10.0.0.2/scos/initrd.img",
      "boot",
      "IPXE",

      "sudo tee /var/www/html/master.ipxe > /dev/null <<'IPXE'",
      "#!ipxe",
      "kernel http://10.0.0.2/scos/vmlinuz initrd=initrd.img coreos.inst.install_dev=/dev/sda coreos.inst.insecure coreos.inst.image_url=http://10.0.0.2/scos/metal.raw.gz coreos.inst.ignition_url=http://10.0.0.2/ignition/master.ign ip=dhcp nameserver=10.0.0.2 coreos.live.rootfs_url=http://10.0.0.2/scos/rootfs.img",
      "initrd http://10.0.0.2/scos/initrd.img",
      "boot",
      "IPXE",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 7: Configure Vault SSH CA trust
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 7: Configuring Vault SSH CA trust'",
      # The Vault CA public key must be provided as a variable.
      # If not provided, this creates a placeholder that must be updated manually.
      "if [ -n '${var.vault_ca_public_key}' ]; then",
      "  echo '${var.vault_ca_public_key}' | sudo tee /etc/ssh/trusted-ca.pem",
      "else",
      "  echo '# PLACEHOLDER: Replace with Vault SSH CA public key' | sudo tee /etc/ssh/trusted-ca.pem",
      "  echo '# vault read -field=public_key ssh-client-signer/config/ca' | sudo tee -a /etc/ssh/trusted-ca.pem",
      "fi",
      "sudo chmod 644 /etc/ssh/trusted-ca.pem",

      # Add TrustedUserCAKeys to sshd_config if not already present
      "grep -q TrustedUserCAKeys /etc/ssh/sshd_config || echo 'TrustedUserCAKeys /etc/ssh/trusted-ca.pem' | sudo tee -a /etc/ssh/sshd_config",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 8: Configure GitLab Runner
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 8: Configuring GitLab Runner'",
      "sudo usermod -aG docker gitlab-runner",

      # If a token is provided, register the runner
      "if [ -n '${var.gitlab_runner_token}' ]; then",
      "  sudo gitlab-runner register --non-interactive \\",
      "    --url '${var.gitlab_url}' \\",
      "    --token '${var.gitlab_runner_token}' \\",
      "    --executor shell \\",
      "    --description 'iac-control-runner-direct' \\",
      "    --tag-list 'iac,sentinel-iac'",
      "else",
      "  echo 'WARNING: No GitLab runner token provided. Register manually after build:'",
      "  echo '  sudo gitlab-runner register --url ${var.gitlab_url} --executor shell'",
      "fi",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 9: Configure Docker and user groups
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 9: Configuring Docker and user setup'",
      "sudo usermod -aG docker ubuntu",
      "sudo systemctl enable docker",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 10: Enable all required services
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 10: Enabling services'",
      "sudo systemctl enable haproxy",
      "sudo systemctl enable dnsmasq",
      "sudo systemctl enable nginx",
      "sudo systemctl enable docker",
      "sudo systemctl enable containerd",
      "sudo systemctl enable gitlab-runner",
      "sudo systemctl enable qemu-guest-agent",
      "sudo systemctl enable netfilter-persistent",
      "sudo systemctl enable podman",
      "sudo systemctl enable podman-auto-update.timer",
    ]
  }

  # ---------------------------------------------------------------------------
  # Phase 11: Clean up for templating
  # ---------------------------------------------------------------------------
  provisioner "shell" {
    inline = [
      "echo '>>> Phase 11: Cleanup'",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo cloud-init clean --logs",
      "sudo truncate -s 0 /var/log/syslog /var/log/auth.log || true",
      "sync",
    ]
  }

  # ---------------------------------------------------------------------------
  # Post-processor: add template description
  # ---------------------------------------------------------------------------
  post-processor "manifest" {
    output     = "iac-control-manifest.json"
    strip_path = true
  }
}
