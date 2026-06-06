#!/bin/bash
# standardize-logrotate.sh - Set all logrotate configs to 30-day retention
# Addresses NIST 800-53 AU-11 (Audit Record Retention)
# Run on: iac-control, gitlab-server, vault-server

set -euo pipefail

echo "Standardizing logrotate to 30-day retention..."

# Fix rsyslog (common on all servers)
if [ -f /etc/logrotate.d/rsyslog ]; then
    sed -i 's/^\tweekly$/\tdaily/' /etc/logrotate.d/rsyslog
    sed -i 's/^\trotate 4$/\trotate 30/' /etc/logrotate.d/rsyslog
    echo "  Fixed: rsyslog -> daily rotate 30"
fi

# Fix squid (iac-control only)
if [ -f /etc/logrotate.d/squid ]; then
    sed -i 's/^\trotate 2$/\trotate 30/' /etc/logrotate.d/squid
    echo "  Fixed: squid -> daily rotate 30"
fi

# Fix haproxy (iac-control only)
if [ -f /etc/logrotate.d/haproxy ]; then
    sed -i 's/^    rotate 7$/    rotate 30/' /etc/logrotate.d/haproxy
    echo "  Fixed: haproxy -> daily rotate 30"
fi

# Fix nginx (iac-control only)
if [ -f /etc/logrotate.d/nginx ]; then
    sed -i 's/^\trotate 14$/\trotate 30/' /etc/logrotate.d/nginx
    echo "  Fixed: nginx -> daily rotate 30"
fi

echo "Done. Verify with: grep -r 'rotate ' /etc/logrotate.d/"
