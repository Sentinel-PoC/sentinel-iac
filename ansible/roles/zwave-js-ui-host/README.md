# zwave-js-ui-host role — OPS-585

Installs [Z-Wave JS UI](https://github.com/zwave-js/zwave-js-ui) as a systemd
service on the host that physically has the ZWA-2 USB radio. Part of the
bridge-on-host architecture for Home Assistant (OPS-585).

## Architecture

```
Workstation (.55)          pve4 HA LXC (.81)
┌─────────────────────┐    ┌───────────────────────┐
│ ZWA-2 USB (by-id)   │    │ Home Assistant         │
│ └─ zwave-js-ui      │◄───┤ Z-Wave JS integration  │
│    WebSocket :3000  │    │ ws://192.168.12.55:3000│
│    Web UI    :8091  │    └───────────────────────┘
└─────────────────────┘
```

Home Assistant connects to zwave-js-ui's WebSocket server over the LAN.
No USB passthrough to HA is needed. Radio state survives HA restarts.

## USB Hardware Note

The ZWA-2 **must** be connected to a direct USB port, not through a USB hub.
USB hub electrical noise can degrade Z-Wave 900 MHz reception. The operator
moved the ZWA-2 to a direct port (2026-05-13) for this reason. When replacing
the adapter in future, honor this physical-port discipline.

Stable USB path (never use `/dev/ttyACM*`):
```
/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_80B54EE62650-if00
```

## Target host

- **Host:** workstation (208pc001, 192.168.12.55)
- **OS:** CachyOS / Arch Linux
- **Connection:** `ansible_connection=local` (no SSH; plays run from the workstation itself)
- **Node.js:** installed via `pacman -S nodejs npm` (rolling repos carry LTS ≥ 20)

## Secrets management

Z-Wave network security keys (S0, S2 Unauthenticated, S2 Authenticated,
S2 Access Control) and the WebSocket auth token are:
1. Generated at first role run (`openssl rand -hex 16` per key)
2. Written to Vault at `secret/home-assistant/zwave`
3. Fetched from Vault on every subsequent run
4. Written to `{{ zwavejs_store_dir }}/.env` (mode 0640, owner zwavejs)

**Back up the Vault path `secret/home-assistant/zwave`** — these keys are
required to re-pair Z-Wave devices if the radio is reset.

## Firewall

The workstation is not under common-role firewall management (see workstation
playbook comment). The operator must ensure:
- Port **3000/tcp** (WebSocket) — allow ingress from HA LXC (192.168.12.81)
- Port **8091/tcp** (Web UI) — allow ingress from operator workstation (loopback only, or LAN)

## Variables (key overrides)

| Variable | Default | Description |
|----------|---------|-------------|
| `zwavejs_serial_port` | `/dev/serial/by-id/usb-Nabu_Casa_ZWA-2_80B54EE62650-if00` | USB serial path |
| `zwavejs_store_dir` | `/var/lib/zwave-js-ui` | Persistent state directory |
| `zwavejs_ws_port` | `3000` | WebSocket port |
| `zwavejs_ui_port` | `8091` | Web UI port |
| `zwavejs_vault_path` | `secret/home-assistant/zwave` | Vault KV path for secrets |
| `zwavejs_user` | `zwavejs` | Service user |

## Usage

```bash
# Apply to workstation (run from workstation itself)
VAULT_TOKEN=<token> ansible-playbook -i ansible/inventory/hosts.ini \
  --limit 208pc001 ansible/playbooks/home-automation.yml \
  --tags zwave-js-ui
```

## Verification

After role apply, confirm:
1. `systemctl is-active zwave-js-ui` → `active`
2. `ss -tlnp | grep 3000` → port listening
3. Vault: `vault kv get secret/home-assistant/zwave` → all fields present
4. HA Z-Wave JS integration: add with `ws://192.168.12.55:3000` + auth token
