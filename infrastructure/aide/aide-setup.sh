#!/bin/bash
# AIDE File Integrity Monitoring Setup
# Addresses NIST 800-53: CM-6(2), SI-3(7), SI-7(1)
# Run as root or with sudo

set -euo pipefail

echo "=== Installing AIDE ==="
apt-get update -qq
apt-get install -y aide aide-common

echo "=== Verifying config ==="
ls -la /etc/aide/aide.conf

echo "=== Initializing AIDE baseline (may take 10+ minutes) ==="
aideinit

echo "=== Copying baseline database ==="
cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

echo "=== Creating daily cron job ==="
cat > /etc/cron.daily/aide-check << 'CRON'
#!/bin/bash
/usr/bin/aide --config=/etc/aide/aide.conf --check 2>&1 | /usr/bin/logger -t aide-check
CRON
chmod +x /etc/cron.daily/aide-check

echo "=== AIDE setup complete ==="
echo "Baseline database: /var/lib/aide/aide.db"
echo "Daily checks will run via /etc/cron.daily/aide-check"
echo "Check results: journalctl -t aide-check"
echo ""
echo "To update baseline after authorized changes:"
echo "  sudo aide --update"
echo "  sudo cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db"
