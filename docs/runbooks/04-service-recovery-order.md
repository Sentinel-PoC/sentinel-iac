# Service Recovery Order — Full Platform Outage

## Prerequisites
- Physical/IPMI access to Proxmox nodes (or they auto-start VMs on boot)
- Vault unseal key shares or transit auto-unseal working

## Recovery Order

### Phase 1: Infrastructure (first 5 minutes)
1. **Proxmox nodes** — verify all 3 online (pve:6, 208-pve2:56, pve3:57)
2. **TrueNAS** (VM 108 on pve3) — verify pools imported, iSCSI service running
   - `ssh root@192.168.12.205` → `zpool status` → `service iscsitargetd status`
3. **Vault** (VM 205 on 208-pve2) — verify unsealed
   - `curl -sk https://192.168.12.206:8200/v1/sys/seal-status | jq .sealed`
   - If sealed: transit auto-unseal should handle it. If transit is also down, need unseal keys.

### Phase 2: Networking & Auth (next 5 minutes)
4. **iac-control** (VM 200 on pve) — verify HAProxy running
   - `systemctl status haproxy`
   - HAProxy routes 80/443 to OKD, 8081 to Istio IngressGateway
5. **Pangolin proxy** (VM 107 on pve) — verify Docker containers running
   - Pangolin + Traefik + newt tunnel = external access to *.208.haist.farm
6. **OKD cluster** — verify all 3 masters Ready
   - From iac-control: `export KUBECONFIG=/home/ubuntu/.kube/config && oc get nodes`
   - If nodes NotReady: check kubelet, cri-o, OVN pods

### Phase 3: Core Services (next 10 minutes)
7. **External Secrets Operator** — pulls all secrets from Vault
   - `oc get externalsecret -A | grep -v Synced` — any not-synced need investigation
8. **Keycloak** — SSO for everything
   - `curl -sk https://auth.208.haist.farm/realms/sentinel/.well-known/openid-configuration | head -1`
9. **Harbor** — image registry, needed for any pod restart
   - `curl -sk https://harbor.208.haist.farm/api/v2.0/health`
10. **ArgoCD** — manages all deployments
    - `oc get application -n openshift-gitops` — all should be Synced/Healthy

### Phase 4: Applications (auto-recover via ArgoCD)
11. Most apps auto-recover once Phase 1-3 are up
12. Check: `oc get pods -A | grep -v Running | grep -v Completed`
13. PostgreSQL pods may need extra time (iSCSI mount + fsync, now seconds not minutes)

## Common Issues
- **Pods in ImagePullBackOff**: Harbor is down or unreachable
- **ExternalSecret not syncing**: Vault is sealed or ESO pod crashed
- **Services returning 502**: HAProxy/Istio IngressGateway not routing
- **Matrix not federating**: Cloudflare tunnel or Pangolin VM tunnel down
