# OKD etcd Backup to MinIO

Automated daily backup of OKD etcd data to MinIO object storage.

## Components

- `etcd-backup.sh` - Backup script (installed at `/usr/local/bin/etcd-backup.sh`)
- `etcd-backup.service` - Systemd oneshot service
- `etcd-backup.timer` - Daily timer (4AM UTC with 5min random delay)

## How It Works

1. SSH from iac-control to OKD master-1 (10.0.0.221)
2. Run `/usr/local/bin/cluster-backup.sh` to create etcd snapshot + kube resources
3. SCP backup files back to iac-control
4. Upload to MinIO `etcd-backups` bucket via `mc`
5. Prune backups older than 7 days

## Prerequisites

- `mc` (MinIO client) installed and configured with `minio` alias
- SSH key at `/home/ubuntu/.ssh/id_sentinel` with access to CoreOS masters
- MinIO bucket `etcd-backups` exists

## Installation

```bash
sudo cp etcd-backup.sh /usr/local/bin/etcd-backup.sh
sudo chmod +x /usr/local/bin/etcd-backup.sh
sudo cp etcd-backup.service /etc/systemd/system/
sudo cp etcd-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now etcd-backup.timer
```

## Manual Run

```bash
sudo systemctl start etcd-backup.service
journalctl -u etcd-backup.service -f
```

## Backup Contents

- `snapshot_YYYY-MM-DD_HHMMSS.db` - etcd database snapshot (~97MB)
- `static_kuberesources_YYYY-MM-DD_HHMMSS.tar.gz` - Kubernetes static pod manifests (~80KB)

## NIST 800-53 Controls

- **CP-9**: Information System Backup
- **CP-10**: Information System Recovery and Reconstitution
