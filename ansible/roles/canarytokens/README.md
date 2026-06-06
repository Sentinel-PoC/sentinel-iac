# canarytokens Ansible Role

**Tracking:** OPS-572 — Plan G'/02 passive-beacon deception layer  
**Upstream:** [thinkst/canarytokens-docker](https://github.com/thinkst/canarytokens-docker)

## Purpose

Deploys Thinkst Canarytokens self-hosted server using the upstream Docker Compose
files plus a thin overlay for port binding and image pinning.

Canarytokens are passive deception artifacts that report outward when accessed —
they do NOT accept inbound commands and are NOT a command-and-control mechanism.

## Legal posture

**HARD LIMITS — do not remove:**

- **NO reverse-shell payloads**
- **NO hack-back**
- **NO active C2 into attacker systems**
- Passive beacon (outbound HTTP/DNS report) ONLY
- CFAA compliance: tokens report TO the operator, not FROM the operator's systems INTO attacker infrastructure

See `compliance-vault/runbooks/canarytoken-plant-strategy.md` for full legal posture and NIST control mapping.

## Architecture

```
Attacker (LAN or internet)
         │
         │  opens Office doc / uses AWS key / uses SSH key / etc.
         ▼
Canarytokens switchboard (iac-control 192.168.12.210)
  :5354 UDP/TCP — DNS canary trips
  :8083          — HTTP canary trips
         │
         ├─► Webhook receiver (loopback :9001) → /opt/canarytokens/logs/alerts.json
         │   └── Wazuh localfile → decoder canarytokens → rules 199700-199708 → SIEM alert
         │
         └─► (Admin UI: nginx :80 → Pangolin → canarytokens.208.haist.farm, Keycloak-gated)
```

## Upstream compose structure

This role clones `thinkst/canarytokens-docker` (main branch) for the nginx config
and canarytokens source tree, then **replaces** the upstream `docker-compose.yml`
with a standalone generated file (`templates/docker-compose.yml.j2`).

**Why replace rather than use docker-compose.override.yml:**
Docker Compose override files merge `ports:` additively — an override would ADD
our restricted bindings on top of upstream's 0.0.0.0 bindings (ports 25, 3306, 53,
6443, 51820 from switchboard_common), not replace them. Replacing the upstream file
gives full control over port bindings.

**What the generated compose differs from upstream:**
- No `build:` directives (pre-built Docker Hub images only — no local build)
- Image tags pinned (`sha-c18517c` for canarytokens; `latest` for nginx; `7.0.10` for redis)
- Port bindings restricted to specific IP/loopback (not 0.0.0.0)
- Switchboard: only DNS + HTTP channels enabled (not SMTP/MySQL/k8s/WireGuard)

**Service structure, volume mounts, and commands** are taken verbatim from upstream
`common-services.yml` (lines 7, 26, 45, 58).

**Services** (from upstream common-services.yml):
| Service | Image | Purpose |
|---------|-------|---------|
| `redis` | `redis:7.0.10` | Token storage |
| `frontend` | `thinkst/canarytokens` | Admin UI + token generation |
| `switchboard` | `thinkst/canarytokens` | Trip receiver (DNS/HTTP/SMTP/etc.) |
| `nginx` | `thinkst/canarytokens_nginx` | HTTP proxy / static serving |

## Env files (generated from templates)

Three per-service env files, written to `{{ canarytokens_dir }}/src/`:

| File | Key vars | Verified against |
|------|----------|-----------------|
| `frontend.env` | `CANARY_PUBLIC_IP`, `CANARY_DOMAINS`, `CANARY_NXDOMAINS` | `frontend.env.dist` |
| `switchboard.env` | `CANARY_PUBLIC_DOMAIN`, `CANARY_WG_PRIVATE_KEY_SEED` | `switchboard.env.dist` |
| `certbot.env` | `MY_DOMAIN_NAME`, `EMAIL_ADDRESS` | `certbot.env.dist` |

**Note:** Env var prefix is `CANARY_*` (not `CANARYTOKEN_*`). Token type selection
is done at admin-UI time — there are no env-level enable/disable flags upstream.

## Variables (key ones)

| Variable | Default | Description |
|----------|---------|-------------|
| `CANARY_PUBLIC_IP` | `192.168.12.210` | IP that trips resolve to |
| `CANARY_DOMAINS` | `canary.208.haist.farm` | Token domain |
| `CANARY_PUBLIC_DOMAIN` | `canary.208.haist.farm` | Switchboard domain |
| `CANARY_WG_PRIVATE_KEY_SEED` | `""` | WG token key (required; from Vault) |
| `canarytokens_image_tag` | `sha-c18517c` | Docker Hub commit-SHA tag |
| `canarytokens_nginx_image` | `thinkst/canarytokens_nginx:latest` | Nginx image |

## Deployment

```bash
# Generate WG key seed (one-time)
WG_SEED=$(python3 -c "import secrets; print(secrets.token_hex(32))")

# Store in Vault
vault kv put secret/canarytokens \
  wg_private_key_seed="${WG_SEED}"

# Deploy (pass secrets as extra-vars)
ansible-playbook playbooks/canarytokens.yml \
  -e "CANARY_WG_PRIVATE_KEY_SEED=${WG_SEED}"
```

## Post-deploy steps

1. DNS: `canary.208.haist.farm A 192.168.12.210` in dnsmasq + CNAME wildcard
2. Pangolin route: `canarytokens.208.haist.farm → 192.168.12.210:80` + Keycloak ForwardAuth
3. Generate token set per `compliance-vault/runbooks/canarytoken-plant-strategy.md`
4. Encrypt token inventory: `gpg --encrypt --recipient admin@haist.farm sentinel-cache/canarytoken-inventory.md`

## Token inventory

Planted token locations are recorded in `sentinel-cache/canarytoken-inventory.md.gpg`
(GPG-encrypted with operator key `admin@haist.farm`).
