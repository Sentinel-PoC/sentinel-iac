# Log Retention Consolidation

Standardizes all logrotate configs to a minimum 30-day retention period.

## NIST 800-53 Controls
- **AU-11**: Audit Record Retention (30-day minimum)

## Applied To
- iac-control (192.168.12.210)
- gitlab-server (192.168.12.68)

## Changes Made

### Global (/etc/logrotate.conf)
- `weekly` → `daily`
- `rotate 4` → `rotate 30`

### Per-Service Fixes
| Config | Before | After |
|--------|--------|-------|
| apport | daily rotate 7 | daily rotate 30 |
| bootlog | daily rotate 7 | daily rotate 30 |
| btmp | monthly rotate 1 | daily rotate 30 |
| ufw | weekly rotate 4 | daily rotate 30 |
| wtmp | monthly rotate 1 | daily rotate 30 |

### Already Compliant (no changes needed)
- alternatives: monthly rotate 12 (365 days)
- apt: monthly rotate 12 (365 days)
- dpkg: monthly rotate 12 (365 days)
- haproxy: daily rotate 30 (iac-control only)
- nginx: daily rotate 30 (iac-control only)
- rsyslog: daily rotate 30
- security-logs: daily rotate 30 (iac-control only)
- squid: daily rotate 30 (iac-control only)

## Usage
```bash
sudo ./consolidate-logrotate.sh
```
