# Infrastructure Architecture

## Network Topology

Two VLANs provide network isolation between public-facing infrastructure and the OKD cluster:

| Network | Bridge | Subnet | Purpose |
|---------|--------|--------|---------|
| LAN | vmbr0 | 192.168.12.0/24 | VM management, service access |
| Cluster | vmbr1 | 10.0.0.0/24 | OKD internal (masters, bootstrap) |

### Traffic Flow

```
Internet → Cloudflare Tunnel → pangolin-proxy (Traefik :443)
                                     ↓
              ┌──────────────────────────────────────────────┐
              │  VM services (vault, gitlab, wazuh, minio)   │
              │  OKD services (grafana, argocd, keycloak...) │
              └──────────────────────────────────────────────┘

Tailscale VPN → split DNS (208.haist.farm) → pangolin-proxy → backends
LAN clients  → dnsmasq (208.haist.farm)   → pangolin-proxy → backends
```

**Internal access** (`*.208.haist.farm`): Resolved via Tailscale split DNS or LAN dnsmasq to `192.168.12.168` (pangolin-proxy), then Traefik routes to backends. TLS via Let's Encrypt wildcard (Cloudflare DNS-01).

**External access** (`gitlab.haist.farm`, `auth.haist.farm`): Cloudflare CNAME → Cloudflare Tunnel → cloudflared on pangolin-proxy → Traefik → backend. Protected by Cloudflare Access with Keycloak OIDC.

## VM and LXC Inventory

| VM ID | Name | IP | Node | Purpose |
|-------|------|-----|------|---------|
| 200 | iac-control | 192.168.12.210 | pve | IaC orchestration, HAProxy LB, dnsmasq, Squid |
| 201 | gitlab-server | 192.168.12.68 | pve | GitLab CI/CD |
| 205 | vault-server | 192.168.12.206 | 208-pve2 | HashiCorp Vault (Docker) |
| 107 | pangolin-proxy | 192.168.12.168 | pve | Traefik + cloudflared (CF Tunnel) |
| 111 | wazuh | 192.168.12.100 | 208-pve2 | Wazuh SIEM v4.14.1 |
| 109 | seedbox-vm | 192.168.12.69 | pve3 | qBittorrent + gluetun VPN |
| 300 | config-server | 10.0.0.2 | pve | HA failover (LXC), keepalived BACKUP |
| 301 | minio-bootstrap | 192.168.12.58 | pve3 | MinIO primary (LXC) |
| 302 | minio-replica | 192.168.12.59 | pve | MinIO replica (LXC) |

**Golden images**: 9201 (gitlab/pve), 9205 (vault/208-pve2), 9109 (seedbox/pve3)

## OKD Cluster (Overwatch)

3-master OKD 4.19 cluster on the internal vmbr1 network:

| Node | IP | Role |
|------|----|------|
| master-0 | 10.0.0.221 | Control plane |
| master-1 | 10.0.0.222 | Control plane |
| master-2 | 10.0.0.223 | Control plane |
| bootstrap | 10.0.0.220 | Bootstrap (powered off) |

### Supporting Services on iac-control

iac-control (`10.0.0.1` on vmbr1) provides essential cluster infrastructure:

- **HAProxy** — Load balances OKD API (:6443), Machine Config (:22623), and Ingress (:80/:443) across all 3 masters
- **dnsmasq** — DHCP (10.0.0.100-150), DNS (cluster.local + overwatch.haist.farm zones), PXE boot for CoreOS
- **Squid** — Transparent HTTP proxy with domain allowlisting for egress control; iptables redirects port 80 traffic
- **keepalived** — VIP 10.0.0.1 (MASTER on iac-control, BACKUP on config-server LXC)
- **nginx** — PXE server (:8080) serving CoreOS ignition configs

### Air-Gapped Constraints

The OKD cluster has no direct internet egress. All external dependencies must be:

- Mirrored to Harbor container registry (`harbor.208.haist.farm`)
- Proxied through Squid (allowlisted domains only)
- Embedded inline (e.g., Grafana dashboards as JSON, not `gnetId` references)

## Proxmox Cluster

| Host | CPU | RAM | Key VMs |
|------|-----|-----|---------|
| pve (192.168.12.6) | 32 | 62GB | iac-control, gitlab-server, pangolin-proxy |
| 208-pve2 (192.168.12.56) | 36 | 125GB | vault-server, wazuh |
| pve3 (192.168.12.57) | 32 | 125GB | seedbox-vm, minio-bootstrap |

Proxmox snapshots run daily at 1AM UTC (keep 4 snapshots per VM).
