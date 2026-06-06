# Deployment

## Docker Compose

Vault runs as a single Docker container managed by Docker Compose at `/opt/vault/docker-compose.yml`.

```yaml
services:
  vault:
    image: hashicorp/vault:1.21.2
    container_name: vault
    restart: always
    cap_add:
      - IPC_LOCK
    environment:
      VAULT_ADDR: "http://127.0.0.1:8200"
      VAULT_API_ADDR: "http://127.0.0.1:8200"
    ports:
      - "8200:8200"
    volumes:
      - /opt/vault/data:/vault/file
      - /etc/vault/config:/vault/config
      - /opt/vault/logs:/vault/logs
    extra_hosts:
      - "api.overwatch.haist.farm:192.168.12.210"
    command: server
```

Key details:

- **`IPC_LOCK`** capability is added so Vault can lock memory (even though `disable_mlock = true` is set in config, the capability is kept for forward compatibility).
- **`extra_hosts`** maps `api.overwatch.haist.farm` to iac-control's IP (`192.168.12.210`). This enables the Kubernetes auth method to reach the OKD API server for token validation.
- **`restart: always`** ensures the container restarts automatically. Transit auto-unseal handles the seal state after restart.
- The internal `VAULT_ADDR` uses HTTP because TLS termination is at the listener level inside the container.

## Configuration (config.hcl)

Deployed to `/etc/vault/config/config.hcl` on the host (mounted as `/vault/config/config.hcl` inside the container).

```hcl
ui = true
disable_mlock = true

storage "file" {
  path = "/vault/file"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/tls/cert.pem"
  tls_key_file  = "/vault/tls/key.pem"
}

seal "transit" {
  address         = "http://192.168.12.210:8201"
  token           = "<transit-token>"
  disable_renewal = "false"
  key_name        = "autounseal"
  mount_path      = "transit/"
}

api_addr     = "https://192.168.12.206:8200"
cluster_addr = "https://192.168.12.206:8201"
```

### Configuration Notes

- **`disable_mlock = true`** -- Required for Docker deployments where the mlock syscall may not be available.
- **File storage** -- Single-node, no HA. Data stored at `/vault/file` inside the container, mapped to `/opt/vault/data/` on the host.
- **TLS** -- Cert and key at `/vault/tls/` inside the container. The TLS files must be owned by uid 100 (the vault user inside the container): `chown 100:100 /path/to/cert.pem /path/to/key.pem`. [VERIFY: The exact host path for TLS files is not defined in the Ansible role -- they may be placed manually or via a separate process under the config directory.]
- **Transit seal** -- Points to the Transit Vault on iac-control at `http://192.168.12.210:8201`. See [Transit Auto-Unseal](transit-unseal.md).

## Ansible Role Flow

The playbook at `ansible/playbooks/vault-server.yml` runs three roles:

```yaml
- name: Configure Vault server
  hosts: vault
  become: true
  vars:
    docker_users: [root]
  roles:
    - role: common      # tags: [common]
    - role: docker-host  # tags: [docker]
    - role: vault-server # tags: [vault]
```

The `vault-server` role tasks execute in this order:

1. **Validate secrets** -- Asserts `minio_access_key` and `minio_secret_key` are provided (for backup configuration).
2. **Create directories** -- `/opt/vault/data`, `/etc/vault/config`, `/opt/vault/logs`, `/opt/vault`.
3. **Deploy docker-compose.yml** -- From template, triggers container restart on change.
4. **Deploy config.hcl** -- From template, triggers container restart on change.
5. **Deploy logrotate** -- Rotates `/opt/vault/logs/audit.log` daily, 30-day retention, compress.
6. **Deploy backup script** -- `/usr/local/bin/vault-backup.sh`.
7. **Deploy backup env** -- `/etc/vault-backup.env` (mode 0600, contains MinIO credentials).
8. **Deploy backup systemd units** -- `vault-backup.service` and `vault-backup.timer`.
9. **Start Vault** -- `docker compose up -d`.
10. **Enable backup timer** -- Starts the daily backup timer.
11. **Reminder** -- Prints message that Vault needs manual unseal (legacy message; auto-unseal handles this now).

### Required Extra Vars

The role requires MinIO credentials passed via `--extra-vars` or Vault lookup:

```bash
# On iac-control
cd ~/sentinel-repo/ansible
ansible-playbook -i inventory/hosts.ini playbooks/vault-server.yml \
  --tags vault \
  -e minio_access_key="<key>" \
  -e minio_secret_key="<secret>"
```

## CRITICAL WARNING

**NEVER run `ansible-playbook vault-server.yml` without `--tags` scope.** Running the full playbook re-templates `config.hcl`, which requires the transit unseal token as a variable. If the token variable is unset or defaults to `CHANGE_ME`, the rendered config will have an invalid transit seal stanza, and Vault will fail to start. At minimum, scope to `--tags vault` and provide all required variables.

If you accidentally deploy a bad config:

1. SSH to vault-server: `ssh -i ~/.ssh/id_sentinel root@192.168.12.206`
2. Check the rendered config: `cat /etc/vault/config/config.hcl`
3. Fix the transit token value manually if needed.
4. Restart: `cd /opt/vault && docker compose restart`

## Directory Structure on vault-server

```
/opt/vault/
  docker-compose.yml        # Docker Compose definition
  data/                     # Vault file storage backend
  logs/
    audit.log               # Vault audit log (rotated daily)

/etc/vault/
  config/
    config.hcl              # Vault server configuration

/etc/vault-backup.env       # MinIO credentials (mode 0600)

/usr/local/bin/
  vault-backup.sh           # Daily backup script

/etc/systemd/system/
  vault-backup.service      # Backup oneshot service
  vault-backup.timer        # Daily 2AM UTC trigger
```

## Firewall

UFW allows ports 22 (SSH) and 8200 (Vault API) as configured in the Ansible inventory:

```ini
firewall_allowed_ports='[22,8200]'
```

## Audit Logging

Vault audit logs are written to `/opt/vault/logs/audit.log` (mounted from the host). Logrotate handles rotation:

```
/opt/vault/logs/audit.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
```

The `copytruncate` directive avoids restarting Vault to rotate logs. Audit logs are retained for 30 days before deletion.

Wazuh agent (ID 001) on the vault-server monitors these logs as part of SIEM integration.
