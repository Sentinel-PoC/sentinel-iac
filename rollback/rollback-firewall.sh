#!/bin/bash
# NIST CP-2: Firewall Rollback Script
# Restores iptables rules from baseline configuration

set -e

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
RULES_FILE="/etc/iptables/rules.v4"

# Log function
log_action() {
    logger -t "rollback-firewall" -p user.info "$1"
    echo "[$TIMESTAMP] $1"
}

# Main rollback logic
main() {
    log_action "Starting firewall rollback procedure"
    
    # Check if rules file exists
    if [[ ! -f "$RULES_FILE" ]]; then
        log_action "ERROR: Rules file $RULES_FILE not found"
        exit 1
    fi
    
    # Reload iptables from persistent rules
    log_action "Reloading iptables from $RULES_FILE"
    if netfilter-persistent reload; then
        log_action "Successfully reloaded netfilter rules"
    else
        log_action "ERROR: Failed to reload netfilter rules"
        exit 1
    fi
    
    # Verify rules loaded
    FORWARD_RULES=$(iptables -L FORWARD -n | wc -l)
    INPUT_RULES=$(iptables -L INPUT -n | wc -l)
    
    if [[ $FORWARD_RULES -gt 5 ]] && [[ $INPUT_RULES -gt 5 ]]; then
        log_action "Verification passed: FORWARD rules=$FORWARD_RULES, INPUT rules=$INPUT_RULES"
        log_action "Firewall rollback completed successfully"
        exit 0
    else
        log_action "WARNING: Rule counts seem low - FORWARD=$FORWARD_RULES, INPUT=$INPUT_RULES"
        exit 1
    fi
}

main
