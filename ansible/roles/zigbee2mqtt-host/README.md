# zigbee2mqtt-host role — OPS-585

Installs [zigbee2mqtt](https://www.zigbee2mqtt.io/) + [mosquitto](https://mosquitto.org/)
as systemd services on the host with the ZBT-1 Zigbee USB radio.
Part of the bridge-on-host architecture for Home Assistant (OPS-585).

## Architecture

```
208-pi-001 (.197)             pve4 HA LXC (.81)
┌──────────────────────────┐  ┌────────────────────────────┐
│ ZBT-1 USB (by-id)        │  │ Home Assistant              │
│ └─ zigbee2mqtt :8080 UI  │  │ MQTT integration            │
│    mosquitto   :1883  ◄──┤──┤ mqtt://192.168.12.197:1883  │
│ (MQTT auto-discovery)    │  │ Zigbee devices auto-appear  │
└──────────────────────────┘  └────────────────────────────┘
```

zigbee2mqtt publishes MQTT discovery messages that HA MQTT integration
picks up automatically. No USB passthrough to HA needed.

## Target host

- **Host:** 208-pi-001 (192.168.12.197)
- **OS:** Ubuntu 24.04 LTS (aarch64, Raspberry Pi)
- **Node.js:** 20.x via NodeSource LTS
- **MQTT broker:** mosquitto (apt), password-protected

## Secrets management

MQTT credentials (username + password) are:
1. Generated at first role run (`openssl rand -base64 24`)
2. Written to Vault at `secret/home-assistant/mqtt-credentials`
3. Fetched from Vault on every subsequent run
4. Written to `{{ zigbee2mqtt_data_dir }}/.env` (mode 0640, owner zigbee2mqtt)

In HA: add MQTT integration with broker `192.168.12.197:1883`, credentials
from `vault kv get secret/home-assistant/mqtt-credentials`.

## Variables (key overrides)

| Variable | Default | Description |
|----------|---------|-------------|
| `zigbee2mqtt_serial_port` | `/dev/serial/by-id/usb-Nabu_Casa_Home_Assistant_Connect_ZBT-1_...` | USB serial path |
| `zigbee2mqtt_dir` | `/opt/zigbee2mqtt` | Install directory |
| `zigbee2mqtt_data_dir` | `/var/lib/zigbee2mqtt` | Data/config directory |
| `zigbee2mqtt_frontend_port` | `8080` | Web frontend port |
| `mqtt_port` | `1883` | MQTT broker port |
| `mqtt_ha_user` | `homeassistant` | MQTT username for HA |
| `mqtt_vault_path` | `secret/home-assistant/mqtt-credentials` | Vault KV path |
| `ha_lxc_ip` | `192.168.12.81` | HA LXC IP (for UFW rules) |

## Usage

```bash
VAULT_TOKEN=<token> ansible-playbook -i ansible/inventory/hosts.ini \
  --limit 208-pi-001 ansible/playbooks/home-automation.yml \
  --tags zigbee2mqtt
```

## Verification

After role apply, confirm:
1. `systemctl is-active zigbee2mqtt` → `active`
2. `systemctl is-active mosquitto` → `active`
3. `ss -tlnp | grep 1883` → MQTT port listening
4. `ss -tlnp | grep 8080` → zigbee2mqtt frontend listening
5. Vault: `vault kv get secret/home-assistant/mqtt-credentials` → fields present
6. In HA: MQTT integration connected, Zigbee devices auto-discovered after pairing
