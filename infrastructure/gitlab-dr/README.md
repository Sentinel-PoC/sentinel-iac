# GitLab DR - Backup & Restore

## Backup Overview

| Component | Schedule | Retention | Location |
|-----------|----------|-----------|----------|
| Application data | Weekly (Sun 3AM UTC) | 14 days | MinIO `gitlab-backups/app/` → B2 |
| Config (secrets.json + gitlab.rb) | Weekly (Sun 3AM UTC) | 14 days | MinIO `gitlab-backups/config/` → B2 |

**SKIP list**: artifacts, builds, pages, registry, packages, terraform_state (all reproducible or unused)
**Strategy**: `STRATEGY=copy` (non-blocking, uses pg_dump copy)

## Files on GitLab VM (201)

- `/usr/local/bin/gitlab-backup.sh` — backup script
- `/etc/systemd/system/gitlab-backup.service` — systemd unit
- `/etc/systemd/system/gitlab-backup.timer` — weekly timer
- `/etc/gitlab-backup.env` — MinIO credentials (chmod 600)

## Restore Procedure

### Prerequisites
- Fresh GitLab installation (same version or compatible)
- Access to MinIO or B2 backup data
- MinIO credentials (Vault: `secret/minio`) or B2 creds + rclone config (Vault: `secret/minio-config/`)

### Step 1: Restore Configuration (MUST be first)

```bash
# Download config backup from MinIO
python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://192.168.12.58:9000',
    aws_access_key_id='minio-admin', aws_secret_access_key='SECRET',
    region_name='us-east-1')
# List to find latest
resp = s3.list_objects_v2(Bucket='gitlab-backups', Prefix='config/')
latest = sorted(resp['Contents'], key=lambda x: x['LastModified'])[-1]
s3.download_file('gitlab-backups', latest['Key'], '/tmp/gitlab-config.tar.gz')
"

# Restore config files
tar -xzf /tmp/gitlab-config.tar.gz -C /
gitlab-ctl reconfigure
```

### Step 2: Restore Application Data

```bash
# Download app backup
python3 -c "
import boto3
s3 = boto3.client('s3', endpoint_url='http://192.168.12.58:9000',
    aws_access_key_id='minio-admin', aws_secret_access_key='SECRET',
    region_name='us-east-1')
resp = s3.list_objects_v2(Bucket='gitlab-backups', Prefix='app/')
latest = sorted(resp['Contents'], key=lambda x: x['LastModified'])[-1]
s3.download_file('gitlab-backups', latest['Key'], '/var/opt/gitlab/backups/' + latest['Key'].split('/')[-1])
"

# Stop services, restore, restart
gitlab-ctl stop puma
gitlab-ctl stop sidekiq
BACKUP=TIMESTAMP_YYYY_MM_DD_VERSION gitlab-backup restore
gitlab-ctl reconfigure
gitlab-ctl restart
gitlab-rake gitlab:check SANITIZE=true
```

### Step 3: Verify

```bash
# Check GitLab is running
gitlab-ctl status
# Check web UI
curl -s -o /dev/null -w "%{http_code}" http://localhost
# Check repos are accessible
```

## Restore from B2 (if MinIO is also lost)

See `DR-RUNBOOK.md` for the full recovery chain (MinIO first, then GitLab).
