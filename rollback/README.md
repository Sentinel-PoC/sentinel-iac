# Rollback Scripts

**NIST CP-2: Contingency Planning - Tested rollback procedures for iac-control**

These scripts provide tested rollback capabilities for infrastructure services on iac-control (192.168.12.210). All procedures log to syslog and verify successful restoration.

## Scripts

### rollback-firewall.sh
**Purpose**: Restore iptables firewall rules from baseline configuration

**What it does:**
1. Reloads iptables from `/etc/iptables/rules.v4` via `netfilter-persistent reload`
2. Logs all actions to syslog with tag `rollback-firewall`
3. Verifies rules loaded correctly by counting INPUT and FORWARD chains
4. Returns exit code 0 on success, 1 on failure

**Usage:**
```bash
sudo /opt/rollback/rollback-firewall.sh
```

**Testing:**
- Tested 2026-02-06: Successfully restored 22 FORWARD rules after flush
- Syslog verification confirmed all steps logged correctly

### rollback-all.sh
**Purpose**: Full system rollback for all infrastructure services

**What it does:**
1. Reloads iptables rules (`netfilter-persistent reload`)
2. Restarts HAProxy (`systemctl restart haproxy`)
3. Restarts Squid proxy (`systemctl restart squid`)
4. Restarts dnsmasq (`systemctl restart dnsmasq`)
5. Applies netplan network config (`netplan apply`)
6. Logs each step to syslog with tag `rollback-all`
7. Verifies all services are active
8. Returns exit code 0 on success, 1 on failure

**Usage:**
```bash
sudo /opt/rollback/rollback-all.sh
```

**When to use:**
- Configuration changes cause service failures
- After applying Ansible playbooks if issues occur
- Emergency restoration of known-good baseline

## Deployment

These scripts are deployed to iac-control at `/opt/rollback/`:

```bash
# Copy to iac-control
scp rollback/*.sh ubuntu@192.168.12.210:/tmp/
ssh ubuntu@192.168.12.210 "sudo mv /tmp/*.sh /opt/rollback/ && sudo chmod +x /opt/rollback/*.sh"
```

## Syslog Monitoring

All rollback actions are logged. Monitor with:

```bash
# Watch firewall rollbacks
sudo journalctl -t rollback-firewall -f

# Watch full system rollbacks
sudo journalctl -t rollback-all -f

# Check recent rollback activity
sudo journalctl -t rollback-firewall -t rollback-all --since "1 hour ago"
```

## NIST CP-2 Compliance

These scripts satisfy:
- **CP-2**: Contingency plan with tested procedures
- **CP-2(1)**: Plan coordinates restoration activities
- **CP-2(8)**: Identifies critical infrastructure components (HAProxy, Squid, dnsmasq, iptables)
- **CP-10**: System recovery and reconstitution procedures

## Related Documentation

- **Configuration Baseline**: `/ansible/` - Ansible playbooks for iac-control
- **Compliance Docs**: `/compliance/` - AC-2, SC-7 documentation
- **Change Management**: Ensure rollback scripts updated when baseline changes

## Testing Schedule

Rollback procedures should be tested:
- After any configuration changes to verify they still work
- Quarterly as part of compliance review
- Before major infrastructure changes
- During DR exercises

**Last Tested**: 2026-02-06
**Next Test Due**: 2026-05-06
