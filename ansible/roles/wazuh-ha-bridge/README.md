# wazuh-ha-bridge Ansible Role

**OPS-586 Section C** — Bridges Wazuh manager security alerts to Home Assistant
via MQTT, creating a live security posture dashboard.

## Architecture

```
Wazuh Manager (192.168.12.100)
  wazuh-integratord
    └─► custom-ha-mqtt Python script  ─► mosquitto (192.168.12.197:1883)
                                              │  topic: wazuh/alerts
                                              │  topic: wazuh/status
                                              ▼
                                       Home Assistant LXC (192.168.12.81)
                                         MQTT integration
                                           ├─ MQTT auto-discovery sensors
                                           ├─ Counter entities (packages/wazuh.yaml)
                                           └─ Telegram automation (level ≥ 10)
```

## Path rationale: MQTT over webhook

| Criterion | MQTT | Webhook |
|-----------|------|---------|
| Network dependency | Wazuh → mosquitto only | Wazuh → HA directly |
| HA restart resilience | Retained messages survive restart | Lost if HA is down |
| Observability | Broker logs, subscriber list | HA automation trace only |
| Complexity | Script + broker | Script + HA automation trigger |

**Decision:** MQTT chosen for decoupling and retained-message resilience.
Ref: https://www.home-assistant.io/integrations/mqtt/

## Integration script: custom-ha-mqtt

Located at `/var/ossec/integrations/custom-ha-mqtt` on the Wazuh manager.

- Called by `wazuh-integratord` per alert: `custom-ha-mqtt <alert_json> <api_key> <hook_url>`
- Ref: https://documentation.wazuh.com/current/user-manual/manager/integration-with-external-apis.html
- Reads MQTT credentials from `/var/ossec/etc/ha-mqtt.conf` (Vault: `secret/home-assistant/wazuh-mqtt-publisher`)
- Publishes to:
  - `wazuh/alerts` — raw alert JSON (non-retained, event stream for HA automations)
  - `wazuh/alerts/state` — extracted fields (non-retained, for state sensors)
  - `wazuh/status` — heartbeat JSON with `manager_up: true` (retained)
  - `homeassistant/sensor/wazuh_*/config` — MQTT auto-discovery (retained)

## HA sensors created (via MQTT auto-discovery)

| Entity | Description |
|--------|-------------|
| `sensor.wazuh_last_alert_level` | Integer level (1-16) of last alert |
| `sensor.wazuh_last_alert_host` | Hostname/agent name of last alert |
| `sensor.wazuh_last_alert_desc` | Rule description of last alert |
| `sensor.wazuh_last_alert_time` | Timestamp of last alert |
| `binary_sensor.wazuh_manager_online` | Manager reachability (LWT-backed) |

## HA package: packages/wazuh.yaml

Deployed via this role into `/config/packages/wazuh.yaml`:

- `counter.wazuh_critical_alerts` — incremented on level ≥ 10 alerts
- `counter.wazuh_high_alerts` — incremented on level 7-9 alerts
- `counter.wazuh_medium_alerts` — incremented on level 4-6 alerts
- `sensor.wazuh_security_posture` — template: GREEN / YELLOW / AMBER / RED
- Automation: daily counter reset at midnight
- Automation: critical alert → Telegram (DISABLED by default — enable after Telegram configured)

## Lovelace card

The file `/config/www/wazuh-security-card.yaml` (accessible at `/local/wazuh-security-card.yaml`)
contains a Lovelace vertical-stack card. To use:

1. Open HA dashboard editor
2. Add card → Manual (YAML)
3. Paste contents of `/config/www/wazuh-security-card.yaml`

## Usage

This role is applied to **three different hosts** using the enable-flags pattern:

```yaml
# On wazuh-manager (192.168.12.100)
- hosts: wazuh-manager
  roles:
    - role: wazuh-ha-bridge
      vars:
        wazuh_ha_configure_mosquitto: false
        wazuh_ha_configure_ha: false

# On 208-pi-001 (mosquitto broker, 192.168.12.197)
- hosts: edge_devices
  roles:
    - role: wazuh-ha-bridge
      vars:
        wazuh_ha_configure_wazuh: false
        wazuh_ha_configure_ha: false

# On pve4-alienware (HA LXC host)
- hosts: pve4-alienware
  roles:
    - role: wazuh-ha-bridge
      vars:
        wazuh_ha_configure_wazuh: false
        wazuh_ha_configure_mosquitto: false
```

## Vault secrets

| Path | Description |
|------|-------------|
| `secret/home-assistant/wazuh-mqtt-publisher` | MQTT username+password for Wazuh publisher user |
| `secret/home-assistant/telegram` | Telegram bot token (Section E creates; Section C reads) |

## Verification recipe (E2E — operator runs post-merge)

1. **Trigger synthetic Wazuh alert:**
   ```bash
   ssh wazuh-manager
   /var/ossec/bin/wazuh-logtest
   # Type a test log line; rule 1002 (unknown problem) typically fires at level 2
   # For a level 10 alert: use ossec-logtest with a brute-force pattern
   ```

2. **Watch MQTT topic:**
   ```bash
   ssh 208-pi-001
   PASS=$(vault kv get -field=password secret/home-assistant/mqtt-credentials)
   mosquitto_sub -h 127.0.0.1 -u homeassistant -P "$PASS" -t 'wazuh/#' -v
   ```

3. **Check HA state:**
   - Navigate to https://ha.208.haist.farm → Developer Tools → States
   - Filter: `wazuh` → verify `sensor.wazuh_last_alert_level` updated

4. **Check Telegram** (after enabling automation in packages/wazuh.yaml):
   - Trigger a level-10+ alert
   - Verify Telegram message arrives within 60 seconds

## Known limitations

### ossec.conf blockinfile override
The `<integration>` stanza is injected into `/var/ossec/etc/ossec.conf` via
`blockinfile`. If the `wazuh-server` role re-runs, it re-renders ossec.conf
from the J2 template, removing this stanza.

**Mitigation:** Run `wazuh-ha-bridge` role after `wazuh-server` role. Permanent
fix tracked in **OPS-611** (migrate stanza into `ossec-server.conf.j2`).

### configuration.yaml packages stanza conflict
Section C and Section E both add `homeassistant: packages: !include_dir_named packages`
to `configuration.yaml.j2`. The judge handles merge conflict resolution and
deduplication when PRs are merged. Either section can merge first — the stanza
is identical.

### Telegram automation disabled by default
The critical-alert Telegram automation in `packages/wazuh.yaml` has `enabled: false`
until the Telegram bot is configured (Section E or manually). Enable via HA UI:
Settings → Automations → "Wazuh — Critical Alert Telegram Notification" → Enable.
