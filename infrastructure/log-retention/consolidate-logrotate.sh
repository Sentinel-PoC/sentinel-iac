#!/bin/bash
# Consolidate logrotate configs to 30-day minimum retention
# Addresses NIST 800-53: AU-11 (Audit Record Retention)
# Run as root or with sudo

set -euo pipefail

echo "=== Updating global logrotate.conf ==="
sed -i 's/^weekly$/daily/' /etc/logrotate.conf
sed -i 's/^rotate 4$/rotate 30/' /etc/logrotate.conf

echo "=== Updating individual configs ==="

# apport: daily rotate 7 -> daily rotate 30
if [ -f /etc/logrotate.d/apport ]; then
    sed -i 's/rotate 7/rotate 30/' /etc/logrotate.d/apport
    echo "  Fixed: apport"
fi

# bootlog: daily rotate 7 -> daily rotate 30
if [ -f /etc/logrotate.d/bootlog ]; then
    sed -i 's/rotate 7/rotate 30/' /etc/logrotate.d/bootlog
    echo "  Fixed: bootlog"
fi

# btmp: monthly rotate 1 -> daily rotate 30
if [ -f /etc/logrotate.d/btmp ]; then
    sed -i 's/monthly/daily/' /etc/logrotate.d/btmp
    sed -i 's/rotate 1/rotate 30/' /etc/logrotate.d/btmp
    echo "  Fixed: btmp"
fi

# ufw: weekly rotate 4 -> daily rotate 30
if [ -f /etc/logrotate.d/ufw ]; then
    sed -i 's/weekly/daily/' /etc/logrotate.d/ufw
    sed -i 's/rotate 4/rotate 30/' /etc/logrotate.d/ufw
    echo "  Fixed: ufw"
fi

# wtmp: monthly rotate 1 -> daily rotate 30
if [ -f /etc/logrotate.d/wtmp ]; then
    sed -i 's/monthly/daily/' /etc/logrotate.d/wtmp
    sed -i 's/rotate 1/rotate 30/' /etc/logrotate.d/wtmp
    echo "  Fixed: wtmp"
fi

echo "=== Verification ==="
echo "Global config:"
grep -E 'rotate |daily|weekly' /etc/logrotate.conf
echo ""
echo "Per-service retention:"
for f in /etc/logrotate.d/*; do
    freq=$(grep -m1 -oE 'daily|weekly|monthly' "$f" 2>/dev/null || echo "inherit")
    rot=$(grep -m1 -oE 'rotate [0-9]+' "$f" 2>/dev/null || echo "rotate default")
    echo "  $(basename $f): $freq $rot"
done
echo ""
echo "=== Done. All configs now have minimum 30-day retention ==="
