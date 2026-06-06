#!/bin/bash
# NIST CP-2: Full System Rollback Script
# Restores all infrastructure services to baseline configuration

set -e

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Log function
log_action() {
    logger -t "rollback-all" -p user.info "$1"
    echo "[$TIMESTAMP] $1"
}

# Main rollback logic
main() {
    log_action "Starting full system rollback procedure"
    
    # 1. Restore firewall rules
    log_action "Step 1/5: Reloading iptables rules"
    if netfilter-persistent reload; then
        log_action "  ✓ iptables rules restored"
    else
        log_action "  ✗ ERROR: Failed to restore iptables rules"
        exit 1
    fi
    
    # 2. Restart HAProxy
    log_action "Step 2/5: Restarting HAProxy"
    if systemctl restart haproxy; then
        log_action "  ✓ HAProxy restarted"
    else
        log_action "  ✗ ERROR: Failed to restart HAProxy"
        exit 1
    fi
    
    # 3. Restart Squid
    log_action "Step 3/5: Restarting Squid"
    if systemctl restart squid; then
        log_action "  ✓ Squid restarted"
    else
        log_action "  ✗ ERROR: Failed to restart Squid"
        exit 1
    fi
    
    # 4. Restart dnsmasq
    log_action "Step 4/5: Restarting dnsmasq"
    if systemctl restart dnsmasq; then
        log_action "  ✓ dnsmasq restarted"
    else
        log_action "  ✗ ERROR: Failed to restart dnsmasq"
        exit 1
    fi
    
    # 5. Apply netplan configuration
    log_action "Step 5/5: Applying netplan configuration"
    if netplan apply; then
        log_action "  ✓ netplan configuration applied"
    else
        log_action "  ✗ ERROR: Failed to apply netplan configuration"
        exit 1
    fi
    
    # Verification
    log_action "Verifying service states..."
    SERVICES=("haproxy" "squid" "dnsmasq")
    ALL_OK=true
    
    for service in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_action "  ✓ $service is active"
        else
            log_action "  ✗ $service is NOT active"
            ALL_OK=false
        fi
    done
    
    if [[ "$ALL_OK" == "true" ]]; then
        log_action "Full system rollback completed successfully"
        exit 0
    else
        log_action "WARNING: Some services failed verification"
        exit 1
    fi
}

main
