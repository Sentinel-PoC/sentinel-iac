# AIDE File Integrity Monitoring

AIDE (Advanced Intrusion Detection Environment) monitors filesystem changes
to detect unauthorized modifications to system files, configs, and binaries.

## NIST 800-53 Controls
- **CM-6(2)**: Configuration change detection
- **SI-3(7)**: Integrity verification for software/firmware
- **SI-7(1)**: File integrity checking

## Deployed On
- iac-control (192.168.12.210)
- gitlab-server (192.168.12.68)

## Usage

### Installation
```bash
sudo ./aide-setup.sh
```

### Check for changes
```bash
sudo aide --check
```

### Update baseline after authorized changes
```bash
sudo aide --update
sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
```

### View daily check results
```bash
journalctl -t aide-check
```

## Configuration
- Config: `/etc/aide/aide.conf`
- Baseline DB: `/var/lib/aide/aide.db`
- Daily cron: `/etc/cron.daily/aide-check`
- Logs: syslog via `logger -t aide-check`
