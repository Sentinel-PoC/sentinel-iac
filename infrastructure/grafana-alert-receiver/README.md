# Sentinel Matrix Bot

Webhook receiver that forwards Grafana, Wazuh, and GitLab events to Matrix rooms. Replaces the
original `grafana-alert-receiver.py`.

## Components

- `sentinel-matrix-bot.py` — HTTP webhook server (port 9095), path-based routing
- `sentinel-matrix-bot.service` — Systemd service with EnvironmentFile
- Legacy files (`grafana-alert-receiver.*`) kept for reference

## Architecture

```
Grafana  ──(POST /grafana)──→  sentinel-matrix-bot (:9095)  ──→  #grafana-alerts Matrix room
Wazuh    ──(POST /wazuh)───→  sentinel-matrix-bot (:9095)  ──→  #wazuh-alerts Matrix room
GitLab   ──(POST /gitlab)──→  sentinel-matrix-bot (:9095)  ──→  #gitlab-alerts Matrix room
```

## Configuration

Environment variables in `/etc/sentinel/matrix-bot.env`:

| Variable | Description |
|----------|-------------|
| `MATRIX_HOMESERVER` | Synapse base URL (e.g., `https://matrix.208.haist.farm`) |
| `MATRIX_TOKEN` | Bot access token (from Vault `secret/matrix/bot`) |
| `MATRIX_ROOM_GRAFANA` | Room ID for Grafana alerts |
| `MATRIX_ROOM_WAZUH` | Room ID for Wazuh alerts |
| `MATRIX_ROOM_GITLAB` | Room ID for GitLab events |

## Deployment

Deployed via Ansible `iac-control` role (`--tags matrix-bot`). The role:
1. Stops legacy `grafana-alert-receiver` service
2. Deploys bot script, env file, and systemd unit
3. Enables and starts `sentinel-matrix-bot.service`

## NIST 800-53 Controls

- **SI-4(5)**: System-generated alerts on indicators of compromise
- **IR-6(1)**: Automated incident reporting
- **IR-4(1)**: Automated incident handling processes
