# Sentinel Platform — Infrastructure Deployment Guide

**Last Updated**: 2026-02-07
**Purpose**: Step-by-step procedures for rebuilding any VM using the automated IaC pipeline.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Proxmox Cluster                             │
│                                                                     │
│  pve (.6)           208-pve2 (.56)          pve3 (.57)              │
│  ├─ iac-control     ├─ vault-server         ├─ seedbox-vm           │
│  │  VM 200          │  VM 205               │  VM 109               │
│  │  .210            │  .206                 │  .69                  │
│  │                  │                       │                       │
│  ├─ gitlab-server   ├─ master-1 (OKD)      ├─ minio-bootstrap      │
│  │  VM 201          │  10.0.0.221          │  LXC 301              │
│  │  .68             ├─ master-2 (OKD)      │  .58                  │
│  │                  │  10.0.0.222          ├─ minio-replica        │
│  ├─ pangolin-proxy  ├─ master-3 (OKD)      │  LXC 302              │
│  │  VM 107          │  10.0.0.223          │  .59                  │
│  │  .168            ├─ wazuh               │                       │
│  │                  │  VM 111              │                       │
│  └─ config-server   │  .100                │                       │
│     LXC 300         │                      │                       │
│     10.0.0.2        │                      │                       │
└─────────────────────────────────────────────────────────────────────┘
```

### VM Roles

| VM | Purpose | Key Services |
|----|---------|-------------|
| **iac-control** (200) | Orchestration node | HAProxy (OKD LB), dnsmasq (DNS/DHCP), Squid (egress proxy), GitLab Runner, iptables NAT |
| **vault-server** (205) | Secrets management | HashiCorp Vault (Docker), SSH CA, daily backups |
| **gitlab-server** (201) | Source control + CI/CD | GitLab CE Omnibus, weekly backups |
| **pangolin-proxy** (107) | Reverse proxy + tunnel | Traefik, cloudflared (Cloudflare Tunnel), TLS termination |
| **minio-bootstrap** (301) | Object storage + backup hub | MinIO primary, rclone B2 encrypted sync |
| **minio-replica** (302) | Object storage replica | MinIO replica, high availability |
| **wazuh** (111) | Security monitoring | Wazuh SIEM v4.14.1, 9 agents, custom rules |
| **seedbox-vm** (109) | Media downloads | qBittorrent + gluetun VPN (Docker) |
| **config-server** (300) | HA failover node | dnsmasq (DNS backup), keepalived BACKUP |
| **OKD cluster** (10.0.0.221-223) | Container platform | 3-node OpenShift/OKD, ArgoCD, workloads |

### Dependency Order (rebuild sequence)

```
MinIO (301) → Vault (205) → GitLab (201) → iac-control (200) → OKD → seedbox (109)
```

MinIO must be first (backup access), then Vault (secrets), then GitLab (repos + CI), then iac-control (needs all three). Seedbox is independent — can be rebuilt anytime.

---

## IaC Stack

### Packer (Golden Images)

Base template images with OS + packages pre-installed. Located in `packer/`.

| Template | Base OS | Node | Template VM ID | Key Packages |
|----------|---------|------|----------------|-------------|
| `iac-control.pkr.hcl` | Ubuntu 24.04 | pve | 9200 | haproxy, dnsmasq, squid, docker, nginx, GitLab Runner |
| `vault-server.pkr.hcl` | Ubuntu 24.04 | 208-pve2 | 9205 | docker, docker-compose, jq, curl |
| `gitlab-server.pkr.hcl` | Ubuntu 24.04 | pve | 9201 | GitLab CE Omnibus, postfix |
| `seedbox-vm.pkr.hcl` | Ubuntu 24.04 | pve3 | 9109 | docker, docker-compose |
| `minio-bootstrap.pkr.hcl` | Ubuntu 24.04 | pve3 | 9301 | MinIO, rclone (LXC workaround) |

All templates clone from `ubuntu-2404-ci` base and use `proxmox-clone` builder.

### Terraform (VM Provisioning)

Two layers in `infrastructure/`:

- **bootstrap/** — Imports of manually-created VMs (GitLab, Vault, config-server). `prevent_destroy = true`. For DR documentation only.
- **managed/** — Automated provisioning using `modules/vm`. Creates VMs from Packer templates with cloud-init.

Managed VMs: `vault_server`, `gitlab_server`, `seedbox_vm`, `iac_control`
State backend: MinIO S3 (`terraform-state` bucket)
Provider: `bpg/proxmox` 0.70.0

### Ansible (Configuration Management)

Playbooks in `ansible/` configure VMs after provisioning.

#### Shared Roles

| Role | Purpose |
|------|---------|
| `common` | SSH banner, session timeout, Vault SSH CA trust, 30-day log retention, AIDE FIM, qemu-guest-agent |
| `docker-host` | Docker CE install, daemon.json (json-file log driver), docker-compose, user group |

#### VM-Specific Roles

| Role | Playbook | Key Tasks |
|------|----------|-----------|
| `iac-control` | `playbooks/iac-control.yml` | HAProxy, dnsmasq, Squid, iptables/NAT, netplan, etcd-backup timer, grafana-alert-receiver, qbit-proxy, GitLab Runner, nginx PXE |
| `vault-server` | `playbooks/vault-server.yml` | Docker-compose (Vault 1.15.4), config.hcl, audit logging, backup timer, logrotate |
| `gitlab-server` | `playbooks/gitlab-server.yml` | GitLab CE install, gitlab.rb, backup timer |
| `minio-server` | `playbooks/minio-bootstrap.yml` | MinIO binary, systemd unit, rclone B2 config, bucket creation |
| `seedbox` | `playbooks/seedbox-vm.yml` | Docker-compose (qBittorrent + gluetun), config dirs |

#### Inventory (`ansible/inventory/hosts.ini`)

```ini
[iac_control]
192.168.12.210 ansible_user=ubuntu

[vault]
192.168.12.206 ansible_user=root

[gitlab]
192.168.12.68 ansible_user=koiakoia

[minio]
192.168.12.58 ansible_user=root

[seedbox]
192.168.12.69 ansible_user=koiakoia
```

---

## Rebuild Procedures

### Method A: Full Rebuild (VM destroyed)

**Pipeline**: Packer → Terraform → Ansible → Restore

1. **Build template** (if needed): Trigger `build-<vm>-template` in GitLab CI (manual)
2. **Provision VM**: Trigger `managed_plan` → review → `managed_apply` (manual)
3. **Configure**: Trigger `rebuild-<vm>` in GitLab CI (manual)
4. **Restore data**: Run backup restore (VM-specific, see below)

### Method B: Configuration Drift Fix (VM running)

**Pipeline**: Ansible only

1. Trigger `rebuild-<vm>` in GitLab CI — Ansible is idempotent, safe to re-run
2. Or run manually: `ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/<vm>.yml`

### Method C: Local Manual Run

From iac-control:
```bash
cd ~/sentinel-repo
ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/<vm>.yml
```

---

## Per-VM Rebuild Details

### iac-control (VM 200)

**GitLab CI jobs**: `build_golden_image` → `managed_apply` → `rebuild-iac-control`

**Post-Ansible manual steps**:
1. Restore SSH keys from Vault: `vault kv get -field=value secret/iac-control/ssh-id-ed25519 > ~/.ssh/id_ed25519`
2. Restore kubeconfig: `vault kv get -field=value secret/iac-control/kubeconfig > ~/.kube/config`
3. Register GitLab Runner (new token required): `gitlab-runner register`
4. Verify: `oc get nodes`, `haproxy -c -f /etc/haproxy/haproxy.cfg`, `dig @localhost api.overwatch.local`

**Key configs deployed by Ansible**:
- `/etc/haproxy/haproxy.cfg` — OKD API + ingress load balancer
- `/etc/dnsmasq.d/overwatch.conf` — DNS for 10.0.0.0/24 + haist.farm
- `/etc/squid/squid.conf` — Transparent proxy with domain allowlist
- `/etc/iptables/rules.v4` — NAT, Docker chains, NFS forwarding
- Systemd: etcd-backup (daily 4AM), grafana-alert-receiver (:9095), qbit-proxy (:18080)

### vault-server (VM 205)

**GitLab CI jobs**: `build-vault-template` → `managed_apply` → `rebuild-vault`

**Post-Ansible manual steps**:
1. **Unseal Vault**: `vault operator unseal` (3 of 5 keys from Proton Pass)
2. Restore data from backup (if needed):
   ```bash
   mc cp minio/vault-backups/$(mc ls minio/vault-backups/ --json | python3 -c "import json,sys; print(sorted([json.loads(l)['key'] for l in sys.stdin])[-1])") /tmp/
   tar xzf /tmp/vault-backup-*.tar.gz -C /opt/vault/
   docker restart vault
   vault operator unseal  # re-unseal after restart
   ```
3. Verify: `vault status`, `vault kv list secret/`

### gitlab-server (VM 201)

**GitLab CI jobs**: `build-gitlab-template` → `managed_apply` → `rebuild-gitlab`

**Post-Ansible manual steps**:
1. Restore config backup FIRST (contains encryption keys):
   ```bash
   mc cp minio/gitlab-backups/config/<latest> /tmp/
   tar xzf /tmp/gitlab-config-*.tar.gz -C /
   gitlab-ctl reconfigure
   ```
2. Restore app data:
   ```bash
   mc cp minio/gitlab-backups/app/<latest> /var/opt/gitlab/backups/
   gitlab-ctl stop puma && gitlab-ctl stop sidekiq
   BACKUP=<timestamp> gitlab-backup restore
   gitlab-ctl reconfigure && gitlab-ctl restart
   ```
3. Update CI/CD variables if PAT changed
4. Verify: `gitlab-ctl status`, web UI, `git clone` test

### minio-bootstrap (LXC 301)

**Note**: LXC containers cannot be managed by standard Terraform Proxmox VM module. Manual LXC creation required, then run Ansible.

**Manual steps**:
1. Create LXC on pve3 (see `infrastructure/minio-dr/README.md`)
2. Run: `ansible-playbook -i ansible/inventory/hosts.ini ansible/playbooks/minio-bootstrap.yml`
3. Pull data from B2: `rclone sync b2-encrypted:terraform-state/ /data/minio/terraform-state/` (repeat per bucket)
4. Verify: `mc ls minio/terraform-state`, B2 sync timer active

### seedbox-vm (VM 109)

**GitLab CI jobs**: `build-seedbox-template` → `managed_apply` → `rebuild-seedbox`

**Post-Ansible manual steps**:
1. Add ProtonVPN WireGuard config to `/home/koiakoia/seedbox/.env` (from Vault or Proton Pass)
2. Start containers: `cd /home/koiakoia/seedbox && docker compose up -d`
3. Verify: `docker ps`, test qBittorrent WebUI at http://192.168.12.69:8080

---

## Credential Management

### Where Secrets Live

All platform credentials are stored in Vault KV (`secret/` mount). High-criticality
secrets (root token, unseal keys, encryption passphrases) have an additional offline
backup in Proton Pass. The specific path inventory is maintained in the operator's
internal documentation and is not enumerated in published compliance artifacts
(OPSEC hardening — COMP-29).

### Ansible Secret Handling

Ansible playbooks do **not** embed secrets. Where credentials are needed:
- Vault lookups via `community.hashi_vault` (planned)
- Environment variables from GitLab CI/CD masked variables
- Post-deploy manual steps for initial secret seeding

---

## Pipeline Reference

### GitLab CI Stages

```
lint → security-scan → packer-validate → build-templates → provision → configure → compliance-report
```

| Stage | Jobs | Trigger |
|-------|------|---------|
| lint | yamllint, ansible-lint, tflint | Auto (push/MR) |
| security-scan | trivy-iac, trivy-fs, gitleaks | Auto |
| packer-validate | packer-validate | Auto |
| build-templates | build_golden_image, build-vault-template, build-gitlab-template, build-seedbox-template | Manual |
| provision | managed_plan, managed_apply | Auto (plan) / Manual (apply) |
| configure | rebuild-iac-control, rebuild-vault, rebuild-gitlab, rebuild-minio, rebuild-seedbox | Manual |
| compliance-report | compliance-report | Auto (main only) |

### Ansible Role Catalog

| Role | Variables (key) | Templates |
|------|----------------|-----------|
| `common` | `vault_ssh_ca_public_key`, `session_timeout_seconds`, `log_retention_days`, `aide_enabled` | issue.net, trusted-ca.pem, session-timeout.sh, sentinel-logrotate, aide.conf, aide-cron |
| `docker-host` | `docker_users`, `docker_log_max_size`, `docker_log_max_file` | daemon.json |
| `iac-control` | `okd_master_nodes`, `haproxy_api_port`, `squid_port`, `squid_allowed_domains`, `okd_interface`, `okd_network` | haproxy.cfg, dnsmasq-overwatch.conf, squid.conf, rules.v4, okd-egress-allowlist.txt, 99-ens19.yaml, etcd-backup.sh/service/timer, grafana-alert-receiver.py/service, qbit-proxy.service, gitlab-runner-config.toml |
| `vault-server` | `vault_docker_image`, `vault_data_dir`, `vault_config_dir`, `vault_backup_*` | docker-compose.yml, config.hcl, vault-backup.sh/service/timer, vault-logrotate |
| `gitlab-server` | `gitlab_external_url`, `gitlab_backup_*` | gitlab.rb, gitlab-backup.sh/service/timer |
| `minio-server` | `minio_data_dir`, `minio_user`, `minio_password_vault_path`, `minio_buckets` | minio.service, rclone.conf, minio-b2-sync.sh/service/timer |
| `seedbox` | `seedbox_compose_dir`, `seedbox_config_dir`, `qbit_webui_port`, `gluetun_vpn_type` | docker-compose.yml |

---

## Keycloak SSO (OKD Namespace)

**Deployment Method**: ArgoCD GitOps (overwatch-gitops repo)

**Manifests**: `overwatch-gitops/apps/keycloak/`
- `kustomization.yaml` — Kustomize overlay
- `namespace.yaml` — Namespace definition
- `postgresql-*.yaml` — PostgreSQL 16 (PVC, Deployment, Service)
- `keycloak-*.yaml` — Keycloak 26.0 (Deployment, Service, Route, ConfigMap)

**ArgoCD Application**: `overwatch-gitops/clusters/overwatch/apps/keycloak-app.yaml`

### Initial Deployment

1. Apply ArgoCD Application (from iac-control):
   ```bash
   oc apply -f ~/overwatch-gitops/clusters/overwatch/apps/keycloak-app.yaml
   ```
2. Wait for pods: `oc get pods -n keycloak -w`
3. Grant SCC (ArgoCD cannot apply ClusterRoleBindings):
   ```bash
   oc adm policy add-scc-to-user anyuid -z default -n keycloak
   oc adm policy add-scc-to-user anyuid -z keycloak-sa -n keycloak
   ```
4. Verify route: `curl -sk https://auth.208.haist.farm`

### Post-Deploy Configuration (Keycloak Admin API)

1. **Get admin token**: POST to `/realms/master/protocol/openid-connect/token`
2. **Create sentinel realm** with brute force protection and password policy
3. **Create groups**: admin, operator, viewer
4. **Create OIDC clients**: okd-console, argocd, grafana (with groups mapper)
5. **Store secrets in Vault**: `vault kv put secret/keycloak/<client> clientSecret=<secret>`

### SSO Integration

**OKD OAuth**:
```bash
oc create secret generic keycloak-okd-secret --from-literal=clientSecret=<secret> -n openshift-config
oc patch oauth cluster --type merge -p '{"spec":{"identityProviders":[...]}}'
```

**ArgoCD OIDC**:
```bash
oc create secret generic argocd-keycloak-secret --from-literal=oidc.keycloak.clientSecret=<secret> -n openshift-gitops
# Patch ArgoCD CR to use Keycloak OIDC (replaces Dex)
```

**Grafana OIDC**:
```bash
oc create secret generic grafana-keycloak-secret --from-literal=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<secret> -n monitoring
# Update Grafana Helm values with auth.generic_oauth section
```

### DNS Requirement

Add to dnsmasq on iac-control:
```
address=/auth.208.haist.farm/10.0.0.1
```
This ensures internal OKD pods can resolve the Keycloak route via the OKD router VIP.

### Credentials

Keycloak OIDC client secrets and the PostgreSQL password are stored in Vault KV.
See the operator's internal credential inventory for specific paths (OPSEC — COMP-29).

---

## What Stays Manual

| Item | Reason |
|------|--------|
| Vault unseal | Shamir key split — by design (security) |
| OKD CSR approval | Bootstrap trust anchor — by design |
| Proxmox host recovery | Bare metal — out of scope |
| Initial Vault seed | First-time population — one-time |
| VPN credentials | ProtonVPN keys in Vault, but needs Vault first |
| MinIO LXC creation | Terraform Proxmox provider doesn't support LXC cloning |
| GitLab Runner registration | Requires new token per instance |
