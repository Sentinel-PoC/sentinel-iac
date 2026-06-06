# Transit Auto-Unseal

## Overview

Vault uses HashiCorp's Transit auto-unseal mechanism. A separate "Transit Vault" instance on iac-control (`192.168.12.210:8201`) holds the encryption key used to automatically unseal the primary Vault on startup.

```
+-------------------------------+     +-------------------------------+
| iac-control (192.168.12.210)  |     | vault-server (192.168.12.206) |
|                               |     |                               |
| Transit Vault (:8201)         |     | Primary Vault (:8200)         |
| - transit/ mount              |<----| - seal "transit" stanza       |
| - key: "autounseal"          |     | - auto-unseals on start       |
| - token in config.hcl        |     |                               |
| - vault-unseal-transit.timer  |     |                               |
|   (every 2 min keep-alive)    |     |                               |
+-------------------------------+     +-------------------------------+
```

## Configuration

The primary Vault's `config.hcl` contains a `seal "transit"` stanza:

```hcl
seal "transit" {
  address         = "http://192.168.12.210:8201"
  token           = "<transit-token>"
  disable_renewal = "false"
  key_name        = "autounseal"
  mount_path      = "transit/"
}
```

- **`address`** -- Transit Vault on iac-control, port 8201 (HTTP, no TLS for internal traffic).
- **`token`** -- A long-lived Vault token with permission to use the `transit/` mount on the Transit Vault.
- **`key_name`** -- The Transit encryption key name (`autounseal`).
- **`disable_renewal = "false"`** -- The token is automatically renewed, preventing expiry.

### Transit Vault on iac-control

The Transit Vault is a separate Vault instance running on iac-control at port 8201. It has a single purpose: holding the `autounseal` Transit encryption key.

A systemd timer (`vault-unseal-transit.timer`) runs every 2 minutes on iac-control to keep the Transit Vault unsealed. [VERIFY: Confirm the exact timer unit name and check interval on iac-control.]

## Boot Sequence After Reboot

This is the critical operational procedure. The order matters:

### Scenario 1: Only vault-server Reboots

1. Vault container restarts automatically (`restart: always`).
2. Vault reads `seal "transit"` stanza from config.
3. Vault contacts Transit Vault at `http://192.168.12.210:8201`.
4. Transit Vault decrypts the master key.
5. Vault auto-unseals. No operator intervention needed.

### Scenario 2: Only iac-control Reboots

1. Transit Vault on iac-control goes down.
2. Primary Vault remains unsealed (already running).
3. `vault-unseal-transit.timer` starts on iac-control after boot.
4. Transit Vault comes back within 2 minutes.
5. If primary Vault restarts before Transit is back, it will fail to auto-unseal. See Scenario 3.

### Scenario 3: Both Reboot (or Vault Restarts While Transit Is Down)

**This is the failure mode that requires operator action.**

1. iac-control must boot first (or be manually started).
2. Wait for `vault-unseal-transit.timer` to unseal the Transit Vault (up to 2 minutes).
3. Verify Transit Vault is unsealed:
   ```bash
   ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210
   VAULT_ADDR=http://127.0.0.1:8201 vault status
   ```
4. Then restart the primary Vault container:
   ```bash
   ssh -i ~/.ssh/id_sentinel root@192.168.12.206
   cd /opt/vault && docker compose restart
   ```
5. Verify primary Vault is unsealed:
   ```bash
   curl -sk https://192.168.12.206:8200/v1/sys/health
   # HTTP 200 = unsealed and active
   # HTTP 503 = sealed
   # HTTP 429 = unsealed but standby
   ```

### Scenario 4: Transit Vault Token Expired or Invalid

If the transit token in `config.hcl` is expired or revoked:

1. Vault will fail to auto-unseal with errors like `error unsealing: error from transit seal`.
2. Generate a new token on the Transit Vault with `transit/` permissions.
3. Update `/etc/vault/config/config.hcl` on vault-server with the new token.
4. Restart the Vault container: `cd /opt/vault && docker compose restart`.

## Manual Unseal (Fallback)

If Transit auto-unseal is completely broken, you can fall back to Shamir key unseal. Vault was initialized with 5 key shares, 3 threshold. Keys are stored in Proton Pass.

```bash
ssh -i ~/.ssh/id_sentinel root@192.168.12.206
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_SKIP_VERIFY=true

vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>
```

**Important**: Shamir unseal only works until the next restart. If Transit is still broken, Vault will re-seal on restart. Fix the Transit chain before relying on Shamir.

## Health Check

The NIST compliance script (`scripts/nist-compliance-check.sh`) checks Vault health as part of the SC-23 control:

```bash
# HTTP status codes from /v1/sys/health:
# 200 = initialized, unsealed, active
# 429 = unsealed, standby
# 472 = DR secondary
# 473 = performance standby
# 501 = not initialized
# 503 = sealed
curl -sk -o /dev/null -w '%{http_code}' https://vault.208.haist.farm/v1/sys/health
```

## Troubleshooting

### Vault Sealed After Restart

```bash
# Check primary Vault seal status
curl -sk https://192.168.12.206:8200/v1/sys/health
# If 503, check Transit Vault
ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210 \
  "VAULT_ADDR=http://127.0.0.1:8201 vault status"
```

If Transit Vault is sealed, check the unseal timer:

```bash
ssh -i ~/.ssh/id_sentinel ubuntu@192.168.12.210 \
  "systemctl status vault-unseal-transit.timer"
```

### Container Not Starting

```bash
ssh -i ~/.ssh/id_sentinel root@192.168.12.206
cd /opt/vault
docker compose logs vault
# Common causes:
# - Bad config.hcl (invalid transit token placeholder "CHANGE_ME")
# - TLS cert files missing or wrong permissions (must be uid 100)
# - Port 8200 already in use
```

### Transit Vault Unreachable

```bash
# From vault-server, test connectivity to Transit Vault
ssh -i ~/.ssh/id_sentinel root@192.168.12.206 \
  "curl -s http://192.168.12.210:8201/v1/sys/health"
# If unreachable: check iac-control is up, Transit Vault container is running,
# and no firewall blocking port 8201
```
