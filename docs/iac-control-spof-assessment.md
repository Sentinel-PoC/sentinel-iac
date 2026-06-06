# iac-control SPOF Assessment

> **Issue:** sentinel-iac #24
> **Date:** 2026-03-05
> **Status:** Assessment complete, recommendations pending operator review

## Executive Summary

iac-control (VM 200, 192.168.12.210) is the most critical single point of failure
on the Overwatch Platform. It serves as network gateway, DNS/DHCP/PXE server,
load balancer, CI runner, monitoring orchestrator, and automation hub. If this VM
goes down, the OKD cluster loses external connectivity, DNS resolution, and all
scheduled automation.

**Mitigation already in place:** config-server (VM 300) provides DNS HA via
keepalived VRRP failover. HAProxy and routing have no HA counterpart.

---

## Service Inventory

### Tier 1: Network-Critical (cluster down if lost)

| Service | Port(s) | Purpose | HA Status |
|---------|---------|---------|-----------|
| **HAProxy** | 80, 443, 6443, 22623 | OKD ingress LB + API LB | **NO HA** |
| **dnsmasq** | 53 | DNS for OKD + management VLAN | HA via config-server VRRP |
| **dnsmasq** | 67 | DHCP for OKD network | **NO HA** (only needed at boot) |
| **IP forwarding + iptables/UFW** | — | NAT gateway for 10.0.0.0/24 | **NO HA** |
| **Squid** | 3128 | OKD egress proxy (allowlisted) | **NO HA** |
| **keepalived** | VRRP (proto 112) | VIP 10.0.0.1 failover | Active (MASTER) |

### Tier 2: Automation & Monitoring (degraded ops if lost)

| Service | Schedule | Purpose | Can migrate to OKD? |
|---------|----------|---------|---------------------|
| **etcd-backup** | Daily 04:00 | Backs up OKD etcd to local disk | No (needs SSH to OKD nodes) |
| **proxmox-snapshot** | Daily 01:00 | Snapshots 6 VMs via Proxmox API | No (needs 192.168.12.x access) |
| **idrac-health** | Every 5min | Redfish health checks on 3 iDRACs | No (needs 192.168.12.x access) |
| **idrac-watchdog** | Every 5.5min | Auto power-cycle failed nodes | No (needs 192.168.12.x access) |
| **ssh-cert-renewal** | Every 90min | Signs SSH certs via Vault CA | No (needs host key access) |
| **netbox-sync** | Every 15min | Syncs Proxmox inventory to NetBox | Possibly (needs Proxmox API) |
| **tofu-drift-check** | (from file) | Detects Terraform state drift | No (needs tfstate on disk) |
| **gitlab-runner-cache** | Weekly Sun 03:00 | Cleans GitLab Runner build cache | No (local disk cleanup) |

### Tier 3: Application Services (impact limited)

| Service | Port | Purpose | Can migrate to OKD? |
|---------|------|---------|---------------------|
| **sentinel-matrix-bot** | 9095 | Alert forwarding to Matrix | Yes (already has OKD network access) |
| **qbit-proxy** | 18080 | socat proxy to seedbox qBittorrent | Yes (simple TCP proxy) |
| **nginx (PXE)** | 8080 | Serves iPXE/ignition files | No (only needed at cluster bootstrap) |
| **GitLab Runner** | — | CI job executor | Partially (could use K8s executor) |

### Tier 4: OKD CronJobs (already migrated)

These already run in OKD `sentinel-ops` namespace:

| CronJob | Schedule | Purpose |
|---------|----------|---------|
| grafana-health | Every 5min | Grafana availability check |
| nist-compliance-check | Daily 06:00 | NIST 800-53 compliance scan |
| minio-replicate | Every 6h | MinIO bucket replication |
| evidence-pipeline | Daily 07:00 | Compliance evidence collection |

---

## Risk Analysis

### If iac-control goes down completely:

| Impact | Duration | Severity |
|--------|----------|----------|
| OKD cluster loses external ingress (no HTTPS) | Until restored | **CRITICAL** |
| OKD API unreachable externally | Until restored | **CRITICAL** |
| No NAT for OKD egress (Squid proxy) | Until restored | HIGH |
| DNS failover to config-server (automatic) | Seconds (VRRP) | LOW |
| No etcd backups | Until restored | MEDIUM |
| No Proxmox snapshots | Until restored | MEDIUM |
| No iDRAC watchdog | Until restored | MEDIUM |
| No SSH cert renewal (certs expire in 2h) | Until restored | HIGH |
| No CI/CD builds | Until restored | LOW |
| No alert forwarding to Matrix | Until restored | MEDIUM |

### Recovery expectations:

- **VM restart** (e.g., Proxmox node reboot): ~2-5 minutes, all services auto-start
- **VM corruption** (needs rebuild): ~30-60 minutes from Packer golden image 9201
- **Proxmox host failure** (pve node down): Manual failover to backup, ~1 hour

---

## Recommendations

### Priority 1: Accept and document (no code changes)

These are acceptable risks for a homelab:

- **DHCP** — Only needed during OKD node PXE boot (rare event)
- **PXE/nginx** — Only needed during cluster installation
- **GitLab Runner cache cleanup** — Non-critical maintenance
- **tofu-drift-check** — Alerting only, no remediation

### Priority 2: Quick wins (migrate to OKD)

| Service | Effort | Approach |
|---------|--------|----------|
| sentinel-matrix-bot | Low | Containerize, deploy as OKD Deployment |
| qbit-proxy | Low | Replace with OKD Service + ExternalName or socat pod |

### Priority 3: Reduce blast radius (infrastructure changes)

| Action | Effort | Impact |
|--------|--------|--------|
| Document golden image rebuild procedure | Low | Faster recovery |
| Add HAProxy health check to monitoring | Low | Earlier detection |
| Consider keepalived for HAProxy (config-server as BACKUP) | Medium | HA for ingress |
| Automated VM recovery via Proxmox API | Medium | Self-healing |

### Priority 4: Major architectural changes (future consideration)

| Action | Effort | Impact |
|--------|--------|--------|
| Dedicated router VM (separate routing from services) | High | Isolation |
| MetalLB or similar in OKD (remove HAProxy dependency) | High | Cloud-native LB |
| Multi-path ingress (split across VMs) | High | Full HA |

---

## Current Mitigations

1. **DNS HA**: config-server (VM 300) runs identical dnsmasq, keepalived VRRP
   failover with VIP 10.0.0.1
2. **Golden image**: Packer template 9201 can rebuild iac-control from scratch
3. **GitOps config**: All service configs in Ansible (sentinel-iac repo), reproducible
4. **Proxmox snapshots**: iac-control (VM 200) snapshotted daily with 4 retention
5. **Disaster recovery**: Documented and tested procedures (see docs/disaster-recovery.md)

## Service Count Summary

| Category | Count |
|----------|-------|
| Long-running services | 8 (HAProxy, Squid, dnsmasq, keepalived, nginx, GitLab Runner, matrix-bot, qbit-proxy) |
| Systemd timers | 8 (etcd-backup, proxmox-snapshot, idrac-health, idrac-watchdog, ssh-cert-renewal, netbox-sync, tofu-drift, gitlab-cache) |
| Firewall/networking | 3 (UFW, iptables NAT, IP forwarding) |
| **Total managed services** | **19** |
| Already in OKD | 4 (CronJobs in sentinel-ops) |
