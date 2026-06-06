# Runbook 15 — Vault Auto-Unseal Token Rotation

**Issue:** OPS-191 (follow-up to SEC-44 / OPS-190)
**Criticality:** High — stops the structural cause of the SEC-44 12-hour outage from recurring.
**Host:** iac-control (192.168.12.210) — rotation runs here; targets vault-server (192.168.12.206).

---

## What this is

A weekly systemd timer on iac-control (`vault-autounseal-rotate.timer`) that:

1. Verifies prod Vault and transit Vault are healthy (abort if sealed).
2. Renews its own credential (rotation-token) to keep it alive.
3. Issues a fresh periodic autounseal token on the Transit Vault.
4. SSHes to vault-server and replaces the `token = "..."` line in
   `/etc/vault/config/config.hcl`.
5. Restarts the Vault Docker container.
6. Polls prod Vault health until unsealed (max 60s).
7. Runs an encrypt/decrypt roundtrip probe on the transit key to confirm.
8. Revokes the old token by accessor.
9. Updates `/etc/vault-unseal/autounseal-accessor.token` with the new accessor.
10. Emits a JSON log line to journald + `/var/log/vault-autounseal-rotation.json`.

If any phase fails, the script logs a CRIT entry (Wazuh will alert) and stops
safely without leaving the system in a broken state (see Failure Modes below).

**Cadence:** Sunday 03:00 UTC. Token period = 800h (~33 days). ~4.5× margin.

---

## Prerequisites

### 1. Deploy the `autounseal-rotate` policy on the Transit Vault

The policy file is in `policies/vault/autounseal-rotate-policy.hcl`.

```bash
# From a host with vault CLI and access to the Transit Vault root/admin token
export VAULT_ADDR=http://192.168.12.210:8201
export VAULT_TOKEN=<transit-vault-root-or-admin-token>

vault policy write autounseal-rotate \
  /path/to/sentinel-iac/policies/vault/autounseal-rotate-policy.hcl
```

Verify:
```bash
vault policy read autounseal-rotate
```

### 2. Create the rotation-token (orphan, periodic, on Transit Vault)

```bash
vault token create \
  -policy=autounseal-rotate \
  -period=720h \
  -renewable=true \
  -orphan \
  -display-name=autounseal-rotate \
  -format=json | tee /tmp/rotation-token.json

# Extract and place on iac-control
ROT_TOKEN=$(cat /tmp/rotation-token.json | jq -r '.auth.client_token')
```

Place the token on iac-control at `/etc/vault-unseal/rotation-token`:

```bash
ssh ubuntu@192.168.12.210 \
  "echo '$ROT_TOKEN' | sudo install -m 0400 -o ubuntu -g root /dev/stdin /etc/vault-unseal/rotation-token"

# Verify permissions
ssh ubuntu@192.168.12.210 "ls -la /etc/vault-unseal/rotation-token"
# expected: -r-------- 1 ubuntu root ... /etc/vault-unseal/rotation-token
```

Destroy the local copy:
```bash
rm -f /tmp/rotation-token.json
```

### 3. Deploy the timer via Ansible

The deployment asserts the rotation-token file is present before installing.

```bash
cd ~/repos/sentinel-iac/ansible
ansible-playbook -i inventory/hosts.yml playbooks/iac-control.yml \
  --tags platform-timers,vault-autounseal-rotate
```

If the rotation-token file is missing or mis-permed, the playbook fails loudly
with an explicit message — it never silently "succeeds" without the dependency.

### 4. Smoke test with --dry-run

```bash
ssh ubuntu@192.168.12.210 \
  'sudo -u ubuntu /usr/local/bin/vault-autounseal-rotate.sh --dry-run'
```

Expected output: prints plan (transit addr, SSH target, config path, new token
period) without touching anything. Exit 0.

### 5. Manual test run (optional, only in a maintenance window)

```bash
ssh ubuntu@192.168.12.210 \
  'sudo -u ubuntu /usr/local/bin/vault-autounseal-rotate.sh'
```

Monitor: `journalctl -u vault-autounseal-rotate -f`

After the run, confirm:
- `https://vault.208.haist.farm/v1/sys/health` → `sealed: false`
- `cat /etc/vault-unseal/autounseal-accessor.token` updated (last 8 chars differ)
- `/var/log/vault-autounseal-rotation.json` last line shows `"status":"ROTATION_COMPLETE"`

---

## Normal operation

The timer fires every Sunday at 03:00 UTC. Each run emits ~8-10 JSON log lines to
`/var/log/vault-autounseal-rotation.json` and journald. A successful run ends with
`"status":"ROTATION_COMPLETE"`.

Wazuh decodes the JSON via `vault-probe-decoders.xml` (program_name
`vault-autounseal-rotate`). Any line with `"level":"critical"` fires an alert.

---

## Failure modes and recovery

### Failure: Pre-flight abort (exit 1)

**Cause:** Prod Vault is sealed, transit Vault unreachable, or rotation-token
expired/unreadable.

**State:** No changes made. Old autounseal token intact.

**Recovery:** Fix the underlying condition (unseal vault, check transit vault,
re-bootstrap rotation-token), then either wait for next Sunday's run or trigger
manually (see §5 above).

---

### Failure: SSH backup failed (exit 2, early)

**Cause:** iac-control cannot SSH to vault-server (cert expired, network issue).

**State:** New token created on transit vault but not deployed — it is
immediately revoked by the script. No config change. Old token intact.

**Recovery:**
1. Check `jit-ssh-cert-renew.timer` status on iac-control:
   `systemctl status jit-ssh-cert-renew.timer`
2. Trigger cert renewal: `systemctl start jit-ssh-cert-renew`
3. Re-run rotation manually after cert is valid.

---

### Failure: Health check failed post-restart (exit 2, late)

**Cause:** Vault did not unseal within 60s after `docker restart vault`.

**State:** New token is in config.hcl; old token NOT yet revoked. Vault may
be starting up and `vault-unseal-transit.timer` (runs every 2 min) will unseal
it shortly.

**Recovery:**
1. Wait 2-3 minutes; vault-unseal-transit.timer may resolve it automatically.
2. Check: `curl -sk https://vault.208.haist.farm/v1/sys/health | jq .sealed`
3. If still sealed after 5 min, SSH to vault-server:
   ```bash
   ssh koiakoia@192.168.12.206 'sudo docker logs vault --tail=50'
   ```
4. If the new token is working, update the accessor file manually:
   ```bash
   # On iac-control, get new accessor:
   NEW_ACC=$(VAULT_ADDR=http://192.168.12.210:8201 vault token lookup \
     -format=json <new-token> | jq -r '.data.accessor')
   echo "$NEW_ACC" | sudo tee /etc/vault-unseal/autounseal-accessor.token
   ```

---

### Failure: Vault did not unseal and config shows new token

**Cause:** New token invalid or transit key inaccessible.

**Recovery (manual rollback):**
1. SSH to vault-server:
   ```bash
   ssh koiakoia@192.168.12.206
   sudo cp /etc/vault/config/config.hcl.pre-rotation /etc/vault/config/config.hcl
   sudo docker restart vault
   ```
2. Verify unsealed: `curl -sk https://vault.208.haist.farm/v1/sys/health | jq .sealed`
3. Revoke the unused new token by accessor on transit vault.
4. File a blocker comment on OPS-191 with the error log.

---

## Ansible IaC drift note

The `ansible-drift-remediate.timer` on iac-control runs `--tags common` only —
it does **not** run the vault-server role or overwrite `config.hcl`. If you
manually re-run the vault-server playbook, always pass:

```bash
ansible-playbook playbooks/vault-server.yml \
  --extra-vars "vault_transit_unseal_token=$(cat /tmp/current-token)"
```

Otherwise the template renders `vault_transit_token: "CHANGE_ME"` (the default)
and overwrites the live token. The rotation script does NOT update any Ansible
variable; the config.hcl on vault-server is the source of truth for the live token.

A future improvement (OPS-192 / Vault Agent template pattern) will eliminate this
by having Vault Agent render config.hcl from a Vault KV path.

---

## Monitoring

| Log source | Path / tag |
|------------|-----------|
| JSON log file | `/var/log/vault-autounseal-rotation.json` |
| journald | `journalctl -t vault-autounseal-rotate` |
| Wazuh | program_name `vault-autounseal-rotate`, same decoders as vault-health-probe |

Alert on any log line with `"level":"critical"`.
Rotation success: last line of each weekly run is `"status":"ROTATION_COMPLETE"`.

---

## Reference

- Issue: OPS-191
- Parent: SEC-44 (post-mortem)
- TTL monitor: OPS-190 (runbook 13)
- Long-term architecture: OPS-192 (Vault Agent template)
- Policy source: `policies/vault/autounseal-rotate-policy.hcl`
- Script: `scripts/vault-autounseal-rotate.sh`
