# SSH Certificate Authority

## Overview

Vault operates an SSH Certificate Authority (CA) that signs short-lived SSH certificates for all operator and automation access to managed VMs. Static `authorized_keys` files are disabled across the entire fleet -- only Vault-signed certificates can authenticate.

```
  Operator / Automation
         |
    id_sentinel.pub
         |
         v
  Vault SSH CA (ssh/sign/admin)
         |
    id_sentinel-cert.pub (2h TTL)
         |
         v
  Target VM: sshd trusts /etc/ssh/trusted-ca.pem
             AuthorizedKeysFile none
             AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```

## SSH Secrets Engine Configuration

The SSH secrets engine is mounted at `ssh/`. The CA public key is stored at `ssh/config/ca`.

### Admin Role (`ssh/roles/admin`)

| Setting | Value |
|---------|-------|
| Allowed users | `ubuntu`, `root`, `koiakoia`, `core` |
| Default user | `ubuntu` |
| Default TTL | 30 minutes |
| Max TTL | 4 hours |
| Key type | CA-signed user certificates |

The automation renewal script uses a 2-hour TTL (`--ttl 2h`) to bridge the 90-minute renewal interval with margin.

## Host-Side Configuration

Every managed VM receives the following SSH CA configuration via the `common` Ansible role.

### Trusted CA Key

The Vault SSH CA public key is stored in `ansible/inventory/group_vars/all/vault-ssh.yml`:

```yaml
vault_ssh_ca_public_key: >-
  ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ...
```

This is deployed to `/etc/ssh/trusted-ca.pem` on every host via the template `trusted-ca.pem.j2`. The `sshd_config` directive is set by the common role:

```
TrustedUserCAKeys /etc/ssh/trusted-ca.pem
```

### AuthorizedKeysFile Disabled

The SSH hardening drop-in at `/etc/ssh/sshd_config.d/50-sentinel-hardening.conf` enforces:

```
AuthorizedKeysFile none
```

This completely disables static public key authentication. Only Vault-signed certificates work.

### AuthorizedPrincipalsFile

Each host has per-user principal files at `/etc/ssh/auth_principals/<username>`. These restrict which certificate principals can log in as which local user:

```
# /etc/ssh/auth_principals/ubuntu
ubuntu

# /etc/ssh/auth_principals/root
root

# /etc/ssh/auth_principals/koiakoia
koiakoia
```

The principals are configured in `ansible/roles/common/defaults/main.yml`:

```yaml
sshd_auth_principals:
  ubuntu:
    - ubuntu
  root:
    - root
  koiakoia:
    - koiakoia
```

And the hardening drop-in includes:

```
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```

### Additional SSH Hardening

The drop-in config (`50-sentinel-hardening.conf`) also enforces:

```
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256
MaxAuthTries 4
DisableForwarding yes
X11Forwarding no
MaxStartups 10:30:60
LoginGraceTime 60
Banner /etc/issue.net
AllowGroups sudo
```

Note: `AllowGroups` defaults to `sudo` but is overridden per host in inventory. For vault-server, it is `sudo root` to allow root SSH access for Docker management.

## Certificate Signing

### Manual Signing (from WSL workstation)

```bash
# Set Vault credentials
export VAULT_ADDR="https://vault.208.haist.farm"
export VAULT_TOKEN="hvs.xxxxx"  # From Proton Pass or Vault token

# Sign via SSH to vault-server (Docker exec)
ssh -i ~/.ssh/id_sentinel root@192.168.12.206 \
  "docker exec -e VAULT_TOKEN=$VAULT_TOKEN vault vault write \
  -field=signed_key ssh/sign/admin \
  public_key='$(cat ~/.ssh/id_sentinel.pub)'" \
  > ~/.ssh/id_sentinel-cert.pub

chmod 600 ~/.ssh/id_sentinel-cert.pub
```

### Manual Signing (via API)

```bash
export VAULT_ADDR="https://vault.208.haist.farm"
export VAULT_TOKEN="hvs.xxxxx"

curl -sk -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"public_key\": \"$(cat ~/.ssh/id_sentinel.pub)\",
    \"valid_principals\": \"ubuntu,root,koiakoia\",
    \"ttl\": \"2h\"
  }" \
  "${VAULT_ADDR}/v1/ssh/sign/admin" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['data']['signed_key'])" \
  > ~/.ssh/id_sentinel-cert.pub

chmod 600 ~/.ssh/id_sentinel-cert.pub
```

### Using the Certificate

SSH automatically detects the cert if it follows the `<key>-cert.pub` naming convention:

```bash
# Auto-detection (cert at ~/.ssh/id_sentinel-cert.pub)
ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210

# Explicit cert specification
ssh -i ~/.ssh/id_sentinel \
  -o CertificateFile=~/.ssh/id_sentinel-cert.pub \
  ubuntu@192.168.12.210
```

### Verify a Certificate

```bash
ssh-keygen -L -f ~/.ssh/id_sentinel-cert.pub
# Shows: serial, key ID, principals, validity period
```

## Automated Renewal

### ssh-cert-renew.sh

The script at `scripts/ssh-cert-renew.sh` (deployed to `/home/ubuntu/sentinel-repo/scripts/ssh-cert-renew.sh` on iac-control) automatically renews SSH certificates:

- **Runs as**: `ubuntu` user on iac-control
- **Token source**: `VAULT_TOKEN` env var or `/etc/sentinel/compliance.env`
- **Keys signed**: `~/.ssh/id_sentinel` and `~/.ssh/id_wazuh` (if present)
- **TTL**: 2 hours
- **Principals**: `ubuntu,root,koiakoia`
- **Skip logic**: If current cert has more than 10 minutes remaining, skips renewal
- **Log**: `/var/log/sentinel/ssh-cert-renew.log`
- **Vault URL**: `https://vault.208.haist.farm` (uses `-k` to skip TLS verify)

### systemd Timer

The renewal timer on iac-control fires every 90 minutes and also at 05:50 UTC (10 minutes before the daily compliance check at 06:00):

```ini
# ssh-cert-renewal.timer
[Timer]
OnCalendar=*-*-* 00/1:30:00
OnCalendar=*-*-* 05:50:00 UTC
RandomizedDelaySec=60
Persistent=true
```

The service unit:

```ini
# ssh-cert-renewal.service
[Service]
Type=oneshot
User=ubuntu
EnvironmentFile=/etc/sentinel/compliance.env
ExecStart=/home/ubuntu/sentinel-repo/scripts/ssh-cert-renew.sh
```

### Timing Chain

```
05:50 UTC  ssh-cert-renewal.timer fires
           -> signs fresh 2h cert (valid until ~07:50)
06:00 UTC  nist-compliance-check.timer fires
           -> SSH checks use the fresh cert
07:20 UTC  next 90-min renewal fires
           -> extends cert to ~09:20
```

**Critical**: If the cert renewal timer fails or the Vault token expires, SSH-dependent compliance checks (AU-2, SC-7, etc.) produce cascading false failures. Always check cert validity first when debugging compliance failures.

## CA Key Rotation

To rotate the Vault SSH CA key:

1. Generate a new CA key on Vault:
   ```bash
   vault write ssh/config/ca generate_signing_key=true
   # WARNING: This destroys the old CA key. All existing certs become invalid.
   ```
2. Read the new public key:
   ```bash
   vault read -field=public_key ssh/config/ca
   ```
3. Update `ansible/inventory/group_vars/all/vault-ssh.yml` with the new key.
4. Re-run the `common` role on ALL managed hosts:
   ```bash
   cd ~/sentinel-repo/ansible
   for playbook in playbooks/*.yml; do
     ansible-playbook -i inventory/hosts.ini "$playbook" --tags vault-ssh
   done
   ```
5. Re-sign all operator and automation SSH keys.

## Managed Hosts

All hosts in the Ansible inventory trust the Vault SSH CA:

| Host | IP | SSH User | Notes |
|------|----|----------|-------|
| iac-control | 192.168.12.210 | ubuntu | AllowGroups: sudo |
| vault-server | 192.168.12.206 | root | AllowGroups: sudo root |
| gitlab-server | 192.168.12.68 | koiakoia | AllowGroups: sudo |
| minio-bootstrap | 192.168.12.58 | root | AllowGroups: sudo root |
| seedbox-vm | 192.168.12.69 | koiakoia | AllowGroups: sudo |
| pangolin-proxy | 192.168.12.168 | ubuntu | AllowGroups: sudo |
| wazuh-server | 192.168.12.100 | koiakoia | Uses id_wazuh key |
| config-server | 10.0.0.2 | ubuntu | AllowGroups: sudo |

## Troubleshooting

### "Permission denied (publickey)"

1. Check if the cert exists and is not expired:
   ```bash
   ssh-keygen -L -f ~/.ssh/id_sentinel-cert.pub
   ```
2. If expired, re-sign the key (manual or wait for timer).
3. Verify the target host has `/etc/ssh/trusted-ca.pem` with the correct CA key.
4. Verify `/etc/ssh/auth_principals/<user>` contains the expected principal.

### Compliance Checks Failing After Cert Expiry

Expired certs cause SSH connection failures, which cascade into false compliance failures on AU-2, SC-7, and other controls that probe remote hosts via SSH. Resolution:

```bash
# On iac-control, manually trigger cert renewal
/home/ubuntu/sentinel-repo/scripts/ssh-cert-renew.sh

# Then re-run compliance check
/home/ubuntu/sentinel-repo/scripts/nist-compliance-check.sh
```

### New VM Not Accepting Vault Certs

Ensure the `common` role has been applied to the new VM:

```bash
ansible-playbook -i inventory/hosts.ini playbooks/<new-vm>.yml --tags vault-ssh
```

Check that the host has:

- `/etc/ssh/trusted-ca.pem` -- CA public key
- `/etc/ssh/sshd_config.d/50-sentinel-hardening.conf` -- Contains `AuthorizedKeysFile none` and `AuthorizedPrincipalsFile`
- `TrustedUserCAKeys /etc/ssh/trusted-ca.pem` in `sshd_config`
- `/etc/ssh/auth_principals/<user>` files for each allowed user
