# MinIO DR - Rebuild & B2 Recovery

## Overview

MinIO LXC 301 (192.168.12.58) hosts:
- MinIO object storage (terraform state, vault backups, gitlab backups)
- rclone hourly sync to Backblaze B2 (encrypted)

**CRITICAL**: MinIO is the first service to restore — all other backups flow through it.

## Configuration Stored in Vault

| Vault Path | Contents |
|-----------|----------|
| `secret/minio` | MinIO access key + secret key |
| `secret/minio-config/rclone-conf` | Full rclone.conf (B2 + MinIO + crypt config) |
| `secret/minio-config/b2-encryption-keys` | rclone crypt password + salt |
| `secret/minio-config/backup-script` | backup-to-b2.sh script |
| `secret/backblaze` | B2 account ID + app key |

## Rebuild Procedure

### Step 1: Create LXC Container

Use Proxmox on pve3 (192.168.12.57):
```bash
# Create container (Ubuntu template, 2 cores, 2GB RAM, 32GB disk)
pct create 301 local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    --hostname minio-bootstrap --cores 2 --memory 2048 --rootfs local-lvm:32 \
    --net0 name=eth0,bridge=vmbr0,ip=192.168.12.58/24,gw=192.168.12.1 \
    --start 1
```

### Step 2: Install MinIO

```bash
pct exec 301 -- bash -c '
wget https://dl.min.io/server/minio/release/linux-amd64/minio
chmod +x minio && mv minio /usr/local/bin/
mkdir -p /data
# Create systemd service
cat > /etc/systemd/system/minio.service << EOF
[Unit]
Description=MinIO
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/minio server /data --console-address ":9001"
EnvironmentFile=/etc/default/minio
Restart=always

[Install]
WantedBy=multi-user.target
EOF
'
```

### Step 3: Configure MinIO Credentials

Retrieve from Vault:
```bash
# From a machine with Vault access
VAULT_ADDR=http://192.168.12.206:8200 VAULT_TOKEN=<root-token> \
    vault kv get -format=json secret/minio
```

Set on MinIO:
```bash
pct exec 301 -- bash -c '
cat > /etc/default/minio << EOF
MINIO_ROOT_USER=minio-admin
MINIO_ROOT_PASSWORD=<secret from Vault>
EOF
systemctl enable --now minio
'
```

### Step 4: Recreate Buckets

```bash
# From iac-control
python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://192.168.12.58:9000',
    aws_access_key_id='minio-admin', aws_secret_access_key='SECRET',
    region_name='us-east-1')
for bucket in ['terraform-state', 'vault-backups', 'gitlab-backups']:
    s3.create_bucket(Bucket=bucket)
    print(f'Created {bucket}')
"
```

### Step 5: Install rclone and Restore from B2

```bash
pct exec 301 -- bash -c '
curl https://rclone.org/install.sh | bash
mkdir -p /root/.config/rclone
'
```

Retrieve rclone config from Vault:
```bash
# From Vault
VAULT_ADDR=http://192.168.12.206:8200 VAULT_TOKEN=<root-token> \
    vault kv get -field=value secret/minio-config/rclone-conf > /tmp/rclone.conf
# Copy to MinIO LXC
pct push 301 /tmp/rclone.conf /root/.config/rclone/rclone.conf
```

Pull data back from B2:
```bash
pct exec 301 -- bash -c '
rclone sync b2-encrypted:terraform-state/ minio:terraform-state/ --log-level INFO
rclone sync b2-encrypted:vault-backups/ minio:vault-backups/ --log-level INFO
rclone sync b2-encrypted:gitlab-backups/ minio:gitlab-backups/ --log-level INFO
'
```

### Step 6: Restore Backup Timer

Retrieve and deploy the backup script from Vault:
```bash
VAULT_ADDR=http://192.168.12.206:8200 VAULT_TOKEN=<root-token> \
    vault kv get -field=value secret/minio-config/backup-script > /tmp/backup-to-b2.sh
pct push 301 /tmp/backup-to-b2.sh /usr/local/bin/backup-to-b2.sh
pct exec 301 -- chmod +x /usr/local/bin/backup-to-b2.sh
```

Re-enable the hourly systemd timer for B2 sync.

## If Vault Is Also Lost

The B2 encryption keys are also stored in Proton Pass (user's password manager):
- **rclone crypt password**: `8dcMj+8nqcp5Za3BdhJmWqLQ2zOvu6MSFdiNu8jYi2s=`
- **rclone crypt salt**: `WR1MbVjFAA9+edlMt9vt+VMbdKcXi51QP/Vqy1d8Wco=`

These are the raw passwords. rclone.conf stores them in obscured form. To reconstruct:
```bash
rclone obscure "8dcMj+8nqcp5Za3BdhJmWqLQ2zOvu6MSFdiNu8jYi2s="  # → password line
rclone obscure "WR1MbVjFAA9+edlMt9vt+VMbdKcXi51QP/Vqy1d8Wco="  # → password2 line
```
