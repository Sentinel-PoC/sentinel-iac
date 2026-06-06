#!/usr/bin/env bash
# =============================================================================
# harden-proxmox.sh - CIS Benchmark hardening for Proxmox VE hosts
# =============================================================================
# Applies the same hardening that was manually applied to pve2 (192.168.12.56)
# and pve3 (192.168.12.57). Script is idempotent — safe to re-run.
#
# USAGE (run from WSL or any host with SSH access):
#   sshpass -p 'Bigmac#01' ssh root@192.168.12.56 'bash -s' < scripts/harden-proxmox.sh
#   sshpass -p 'Bigmac#01' ssh root@192.168.12.57 'bash -s' < scripts/harden-proxmox.sh
#
# NOTE: pve (192.168.12.6) does not accept SSH — manage via pvesh/API from 208-pve2.
#
# References: CIS Debian/Ubuntu Benchmark v1.0, NIST 800-53 controls:
#   AC-17 (SSH hardening), AU-2/AU-12 (audit), SI-2 (password policy),
#   SC-28 (file permissions), CM-6 (configuration settings)
# =============================================================================

set -euo pipefail

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[${TIMESTAMP}] Starting Proxmox CIS hardening..."

# -----------------------------------------------------------------------
# 1. SSH HARDENING (CIS 5.2.x)
# /etc/ssh/sshd_config.d/99-cis-hardening.conf
# -----------------------------------------------------------------------
echo "==> Applying SSH hardening..."

cat > /etc/ssh/sshd_config.d/99-cis-hardening.conf << 'SSHEOF'
# CIS Benchmark SSH Hardening for Proxmox
# Applied by harden-proxmox.sh

# Authentication (CIS 5.2.4, 5.2.5, 5.2.6, 5.2.7)
MaxAuthTries 4
LoginGraceTime 60
PermitEmptyPasswords no
HostbasedAuthentication no
IgnoreRhosts yes

# Session (CIS 5.2.16, 5.2.17)
ClientAliveInterval 300
ClientAliveCountMax 3

# Forwarding (CIS 5.2.13) - keep AllowTcpForwarding for Proxmox console
AllowAgentForwarding no
X11Forwarding no

# Logging (CIS 5.2.3)
LogLevel VERBOSE

# Banner (CIS 1.7.1)
Banner /etc/issue.net

# MAC algorithms (CIS 5.2.14)
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# Key exchange algorithms (CIS 5.2.15)
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group-exchange-sha256

# Ciphers (CIS 5.2.13)
Ciphers aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# MaxStartups to prevent brute-force (CIS 5.2.21)
MaxStartups 10:30:60

# Disable user environment (CIS 5.2.10)
PermitUserEnvironment no
SSHEOF

chmod 0600 /etc/ssh/sshd_config.d/99-cis-hardening.conf
echo "    SSH hardening config written."

# Validate and reload sshd
if sshd -t; then
    systemctl reload-or-restart ssh || systemctl reload-or-restart sshd || true
    echo "    sshd configuration valid — service reloaded."
else
    echo "    WARNING: sshd config validation failed — check /etc/ssh/sshd_config.d/99-cis-hardening.conf"
fi

# -----------------------------------------------------------------------
# 2. SYSCTL NETWORK HARDENING (CIS 3.x, 1.5.x)
# /etc/sysctl.d/99-cis-hardening.conf
# -----------------------------------------------------------------------
echo "==> Applying sysctl hardening..."

cat > /etc/sysctl.d/99-cis-hardening.conf << 'SYSCTLEOF'
# CIS Benchmark Network Hardening for Proxmox
# Applied by harden-proxmox.sh

# Disable ICMP redirects (CIS 3.2.2, 3.2.3)
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Enable martian packet logging (CIS 3.2.4)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable IP source routing (CIS 3.2.1)
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Enable TCP SYN cookies (CIS 3.2.8)
net.ipv4.tcp_syncookies = 1

# Enable ASLR (CIS 1.5.3)
kernel.randomize_va_space = 2

# Reverse path filtering (CIS 3.2.7)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable secure ICMP redirects (CIS 3.2.3)
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Restrict core dumps (CIS 1.5.1)
fs.suid_dumpable = 0

# Restrict kernel pointer exposure
kernel.kptr_restrict = 2

# Restrict dmesg access
kernel.dmesg_restrict = 1
SYSCTLEOF

chmod 0644 /etc/sysctl.d/99-cis-hardening.conf
sysctl --system > /dev/null 2>&1 || true
echo "    Sysctl hardening applied."

# -----------------------------------------------------------------------
# 3. LOGIN BANNERS (CIS 1.7.1, 1.7.2)
# /etc/issue and /etc/issue.net
# -----------------------------------------------------------------------
echo "==> Setting login banners..."

cat > /etc/issue.net << 'BANNEREOF'
*******************************************************************************
WARNING: This system is for authorized use only.

All activities on this system are monitored and recorded. Unauthorized access
or use of this system is prohibited and may result in disciplinary action
and/or civil and criminal penalties. By continuing to use this system, you
indicate your awareness of and consent to these conditions.
*******************************************************************************
BANNEREOF

cat > /etc/issue << 'ISSUEEOF'
*******************************************************************************
WARNING: Authorized use only. All activities are monitored.
*******************************************************************************
ISSUEEOF

chmod 0644 /etc/issue /etc/issue.net
echo "    Banners written."

# -----------------------------------------------------------------------
# 4. PASSWORD QUALITY (CIS 5.4.1)
# /etc/security/pwquality.conf
# -----------------------------------------------------------------------
echo "==> Applying password quality policy..."

cat > /etc/security/pwquality.conf << 'PWEOF'
# CIS password quality for Proxmox
# Applied by harden-proxmox.sh
minlen = 14
dcredit = -1
ucredit = -1
ocredit = -1
lcredit = -1
minclass = 4
maxrepeat = 3
PWEOF

chmod 0644 /etc/security/pwquality.conf
echo "    Password quality policy applied."

# -----------------------------------------------------------------------
# 5. LOGIN.DEFS TUNING (CIS 5.4.1.x)
# -----------------------------------------------------------------------
echo "==> Tuning login.defs..."

_set_logindefs() {
    local key="$1"
    local value="$2"
    if grep -qE "^\s*${key}\s" /etc/login.defs; then
        sed -i "s|^\s*${key}\s.*|${key}\t${value}|" /etc/login.defs
    else
        echo -e "${key}\t${value}" >> /etc/login.defs
    fi
}

_set_logindefs PASS_MAX_DAYS 365
_set_logindefs PASS_MIN_DAYS 1
_set_logindefs PASS_WARN_AGE 14
_set_logindefs LOGIN_RETRIES 5
_set_logindefs LOGIN_TIMEOUT 60
_set_logindefs ENCRYPT_METHOD YESCRYPT

echo "    login.defs tuned."

# -----------------------------------------------------------------------
# 6. AUDITD RULES (CIS 4.x — 28 rules)
# /etc/audit/rules.d/cis-hardening.rules
# -----------------------------------------------------------------------
echo "==> Applying auditd rules..."

# Ensure auditd is installed
if ! command -v auditctl &> /dev/null; then
    apt-get install -y auditd audispd-plugins > /dev/null 2>&1
fi

mkdir -p /etc/audit/rules.d

cat > /etc/audit/rules.d/cis-hardening.rules << 'AUDITEOF'
# CIS auditd rules for Proxmox - applied by harden-proxmox.sh
# NIST AU-2, AU-12

# Time changes (CIS 4.1.4)
-a always,exit -F arch=b64 -S adjtimex,settimeofday -F key=time-change
-a always,exit -F arch=b64 -S clock_settime -F key=time-change
-w /etc/localtime -p wa -k time-change

# Identity (CIS 4.1.5)
-w /etc/group -p wa -k identity
-w /etc/passwd -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/security/opasswd -p wa -k identity

# Network (CIS 4.1.6)
-a always,exit -F arch=b64 -S sethostname,setdomainname -F key=system-locale
-w /etc/issue -p wa -k system-locale
-w /etc/issue.net -p wa -k system-locale
-w /etc/hosts -p wa -k system-locale
-w /etc/network -p wa -k system-locale

# Logins (CIS 4.1.7)
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins
-w /var/log/tallylog -p wa -k logins

# Sessions (CIS 4.1.8)
-w /var/run/utmp -p wa -k session
-w /var/log/wtmp -p wa -k session
-w /var/log/btmp -p wa -k session

# Permission changes (CIS 4.1.9)
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -F auid>=1000 -F auid!=-1 -F key=perm_mod
-a always,exit -F arch=b64 -S chown,fchown,lchown,fchownat -F auid>=1000 -F auid!=-1 -F key=perm_mod

# Sudo actions (CIS 4.1.14)
-w /var/log/sudo.log -p wa -k actions

# Kernel modules (CIS 4.1.17)
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -F key=modules

# Sudoers (CIS 4.1.15)
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d -p wa -k scope
AUDITEOF

chmod 0640 /etc/audit/rules.d/cis-hardening.rules

# Load rules if auditd is running
if systemctl is-active --quiet auditd; then
    augenrules --load > /dev/null 2>&1 || auditctl -R /etc/audit/rules.d/cis-hardening.rules || true
    echo "    Auditd rules loaded."
else
    systemctl enable auditd > /dev/null 2>&1 || true
    systemctl start auditd > /dev/null 2>&1 || true
    echo "    Auditd started and rules will load on next restart."
fi

# -----------------------------------------------------------------------
# 7. CRITICAL FILE PERMISSIONS (CIS 6.1.x)
# -----------------------------------------------------------------------
echo "==> Setting critical file permissions..."

chmod 644 /etc/passwd
chmod 000 /etc/shadow
chmod 644 /etc/group
chmod 000 /etc/gshadow

# Ensure correct ownership
chown root:root /etc/passwd /etc/group
chown root:shadow /etc/shadow /etc/gshadow 2>/dev/null || chown root:root /etc/shadow /etc/gshadow

echo "    File permissions set."

# -----------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------
TIMESTAMP_END=$(date '+%Y-%m-%d %H:%M:%S')
echo ""
echo "[${TIMESTAMP_END}] Proxmox CIS hardening complete."
echo "    Summary:"
echo "      - SSH hardening:       /etc/ssh/sshd_config.d/99-cis-hardening.conf"
echo "      - Sysctl hardening:    /etc/sysctl.d/99-cis-hardening.conf"
echo "      - Login banners:       /etc/issue, /etc/issue.net"
echo "      - Password quality:    /etc/security/pwquality.conf"
echo "      - Login.defs:          PASS_MAX_DAYS=365, ENCRYPT_METHOD=YESCRYPT"
echo "      - Auditd rules (28):   /etc/audit/rules.d/cis-hardening.rules"
echo "      - File permissions:    passwd/shadow/group/gshadow"
echo ""
echo "    NOTE: Review sshd_config for AllowTcpForwarding if Proxmox console"
echo "    access breaks — Proxmox VNC console uses websocket, not TCP forwarding."
