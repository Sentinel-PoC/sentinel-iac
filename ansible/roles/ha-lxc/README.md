# ha-lxc role — OPS-585

Provisions a Home Assistant Container LXC on pve4-alienware.
Part of the bridge-on-host home automation architecture (OPS-585).

## Architecture

```
pve4-alienware (.60)
└── VMID 201: home-assistant LXC (Ubuntu 24.04, 192.168.12.81, privileged)
    └── Docker CE + HA Container (homeassistant/home-assistant:stable)
        ├── Z-Wave JS integration  → ws://192.168.12.55:3000  (workstation)
        └── MQTT integration       → mqtt://192.168.12.197:1883 (208-pi-001)
```

## Why privileged LXC?

Docker-in-LXC requires a **privileged** LXC container (`unprivileged=0`) and
the `nesting=1` feature. An unprivileged LXC cannot run Docker because cgroup
namespaces required for container isolation are not available.

## Why HA Container (not HA Core)?

HA Core (Python venv) is officially deprecated:
> "Beginning with Home Assistant 2025.6, affected systems will display a
> notification after updating, indicating that support will end in six months
> (with release 2025.12)." — [HA blog 2025-05-22](https://www.home-assistant.io)

HA Container (Docker image) is the correct supported path for non-HAOS installs.

## DNS note: use direct IPs

**Do NOT use `*.haist.farm` hostnames** for bridge service URLs. Pangolin's DNS
wildcard returns the VIP (192.168.12.168) for all `*.208.haist.farm` lookups.
Always configure with direct IPs:
- Z-Wave JS UI: `ws://192.168.12.55:3000` (not `208pc001.208.haist.farm`)
- MQTT: `mqtt://192.168.12.197:1883` (not `208pi001.208.haist.farm`)

## Integration setup (manual post-deploy)

After the role runs, complete integration setup via HA UI:

1. **Z-Wave JS integration:**
   - Go to Settings → Devices & Services → Add Integration → Z-Wave
   - WebSocket URL: `ws://192.168.12.55:3000`
   - Auth token: `vault kv get -field=ui_auth_token secret/home-assistant/zwave`

2. **MQTT integration:**
   - Go to Settings → Devices & Services → Add Integration → MQTT
   - Broker: `192.168.12.197`, Port: `1883`
   - Username: `vault kv get -field=username secret/home-assistant/mqtt-credentials`
   - Password: `vault kv get -field=password secret/home-assistant/mqtt-credentials`
   - Zigbee devices auto-appear after MQTT integration is connected.

## Variables (key overrides)

| Variable | Default | Description |
|----------|---------|-------------|
| `ha_lxc_id` | `201` | Proxmox container ID |
| `ha_lxc_name` | `home-assistant` | LXC hostname |
| `ha_lxc_ip` | `192.168.12.81` | Static IP |
| `ha_lxc_cores` | `4` | CPU cores |
| `ha_lxc_memory` | `4096` | RAM in MiB |
| `ha_image` | `ghcr.io/home-assistant/home-assistant:stable` | Docker image |
| `ha_config_dir` | `/config` | HA config volume |
| `ha_timezone` | `America/Indiana/Indianapolis` | Container timezone |

## Usage

```bash
# Provision (run from workstation or iac-control)
VAULT_TOKEN=<token> ansible-playbook -i ansible/inventory/hosts.ini \
  --limit pve4-alienware ansible/playbooks/home-automation.yml \
  --tags ha-lxc
```

## Verification

After role apply:
1. `pct status 201` → `running` (from pve4-alienware)
2. `pct exec 201 -- docker ps | grep homeassistant` → container running
3. `curl -s http://192.168.12.81:8123` → HA onboarding page (HTTP 200 or redirect)
4. Complete integration setup via HA UI (see above)
5. AC #7: Z-Wave JS shows "Connected" + MQTT shows "Connected" in HA
## ProxmoxVE integration (OPS-836 / OPS-847)

The proxmoxve core integration is config-flow only (no YAML config). Credentials are stored in
HA's internal config store. The Ansible role manages reconfiguration via the HA REST API.

### Token scoping (OPS-847)

| Cluster | HA Entry ID | Vault path | Token ID | Role |
|---------|-------------|-----------|----------|------|
| 3-node cluster (192.168.12.6) | `01KS72JE8JJ10WHH55HJYKW9B4` | `secret/proxmox-cluster` | `root@pam!ha-monitor` | PVEAuditor |
| pve4 standalone (192.168.12.60) | `01KS72K0QAJEA9X8EDXSQ4DV2F` | `secret/proxmox-pve4` | `root@pam!ha-monitor` | PVEAuditor |

The full-root token `root@pam!Claudette` (`secret/proxmox`) is **no longer used by HA proxmoxve**.
It may be revoked per OPS-271 (general Claudette token scoping).

### Reconfigure via Ansible (ha-proxmoxve tag)

The `ha_proxmoxve.yml` task reconfigures the 3-node cluster proxmoxve entry using the PVEAuditor
token from Vault. Run this task when rotating the proxmox-cluster token in Vault:

```bash
VAULT_TOKEN=<token> ansible-playbook -i ansible/inventory/hosts.ini \
  --limit pve4-alienware ansible/playbooks/home-automation.yml \
  --tags ha-proxmoxve
```

The task:
1. Fetches `secret/proxmox-cluster` (api_token_id, api_token_secret) from Vault
2. Starts a proxmoxve reconfigure flow via HA REST API
3. Submits connection settings (host=192.168.12.6, auth_method=pam, token=true)
4. Submits the PVEAuditor token credentials
5. Asserts `reconfigure_successful` and verifies the entry is in `loaded` state

### Manual setup (first-time only / after HA data loss)

If the proxmoxve config entry is missing (e.g., after full HA data wipe), set up manually:

1. Go to Settings → Devices & Services → Add Integration → **ProxmoxVE**
2. Host: `192.168.12.6`, Port: `8006`, Auth: `pam`, Username: `root`, Token: `yes`
3. Token ID: `ha-monitor` (not the full `root@pam!ha-monitor` — just the part after `!`)
4. Token secret: `vault kv get -field=api_token_secret secret/proxmox-cluster`
5. After setup, update `ha_proxmoxve_cluster_entry_id` in defaults/main.yml to the new entry ID

## Section E integration setup (OPS-586 / OPS-617)

Section E covers six "Media & Comms" integrations. All six use HA config flow (UI setup).
The Ansible role deploys lovelace dashboards and automation packages — not the integrations themselves.

### Integration matrix

| Integration | Setup path | Ansible deploys |
|-------------|-----------|-----------------|
| **Telegram bot** | HA UI config flow (OPS-617) | ~~telegram_bot.yaml~~ removed; automations package |
| **Jellyfin** | HA UI config flow | Lovelace card |
| **UniFi Network** | HA UI config flow | Lovelace card |
| **Google Calendar** | HA UI config flow (OAuth) | Lovelace card |
| **NWS Weather** | HA UI config flow | Lovelace card |
| **TrueNAS** | HACS + HA UI config flow | Lovelace card |

### Telegram bot setup (OPS-617: YAML config removed)

**Why YAML was removed:** HA 2026.5+ uses `config_entry_only_config_schema` for `telegram_bot`,
which causes HA to reject any `telegram_bot:` key in `configuration.yaml` and enter recovery mode.
The Ansible role previously deployed `telegram_bot.yaml` and added `telegram_bot: !include telegram_bot.yaml`
to `configuration.yaml`. This was removed in OPS-617.

**One-time operator setup after role apply:**

1. Go to Settings → Devices & Services → Add Integration → **Telegram bot**
2. Platform: **Polling** (HA does not need internet exposure for polling)
3. API key: retrieve from Vault — `vault kv get -field=bot_token secret/telegram/bot_token`
4. Complete the flow; HA will show a "Telegram bot" entry in D&S
5. Add your chat ID: three-dot menu next to Telegram bot → **Add allowed chat ID**
   - To find your chat ID: send any message to [@id_bot](https://t.me/id_bot) on Telegram

After setup, the `telegram_bot.send_message` service is available for automations.
The Section E automations package (`packages/section_e_automations.yaml`) uses this service.

### Skip-tags safety (Issue 2 / OPS-617)

**Before OPS-617:** Running `--skip-tags telegram` skipped rendering `telegram_bot.yaml`,
but `telegram_bot: !include telegram_bot.yaml` remained in `configuration.yaml` → HA
failed to parse the missing file → recovery mode.

**After OPS-617:** The `!include telegram_bot.yaml` line is removed from `configuration.yaml.j2`.
No Vault-dependent `!include` lines remain. Running any `--skip-tags` combination is safe —
the rendered `configuration.yaml` will always be parseable by HA regardless of which tags
are skipped.

The Section E automations and lovelace dashboard can be skipped via `--skip-tags ha-integrations`
without affecting HA startup.

