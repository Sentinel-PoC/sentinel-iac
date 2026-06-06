# Runbook 13 — Vault Auto-Unseal Token TTL Monitor

**Issue:** OPS-190 (follow-up to SEC-44)
**Criticality:** High — the absence of this monitor is what allowed the SEC-44 12-hour outage to go unobserved until Plane API failures surfaced it.
**Host:** iac-control (192.168.12.210)

---

## What this is

A daily timer on iac-control that asks the Transit Vault for the prod-Vault auto-unseal token's remaining lease, classifies it (`OK` / `WARN` / `CRIT`), and emits a JSON line to journald + `/var/log/vault-autounseal-token-ttl.json`.

Wazuh decodes the JSON via `vault-probe-decoders.xml` (program_name `vault-autounseal-token-ttl`). Wazuh rules can then alert on `status == "CRIT"` or `level == "warning"`.

| Threshold | Default | Override (env on the systemd service) |
|-----------|---------|---------------------------------------|
| WARN      | 7 days  | `VAULT_AUTOUNSEAL_WARN_SEC`           |
| CRIT      | 24 hours | `VAULT_AUTOUNSEAL_CRIT_SEC`           |

A `WARN` alert means: the operator has at least one week to rotate the auto-unseal token before the outage class recurs. A `CRIT` alert means: rotate today.

---

## One-time deployment prerequisites

The Ansible role refuses to install the timer if either prerequisite file is missing or has the wrong permissions. This is intentional — the alternative is silently shipping a broken monitor.

### 1. Capture the auto-unseal token's accessor

The accessor is a non-secret identifier you can hand to `auth/token/lookup-accessor` to query metadata about a token without holding the token itself.

If you still have the auto-unseal token value (e.g. just rotated it):

```bash
# from a machine with VAULT_TOKEN set to the Transit Vault root token
VAULT_ADDR=http://192.168.12.210:8201 \
  vault token lookup -format=json <auto-unseal-token-value> \
  | jq -r '.data.accessor'
```

If you don't have the token value but know which accessors exist:

```bash
VAULT_ADDR=http://192.168.12.210:8201 \
VAULT_TOKEN=<transit-root-token> \
  vault list -format=json /auth/token/accessors

# For each accessor, lookup-accessor and find the one with the autounseal policy:
for acc in $(vault list -format=json /auth/token/accessors | jq -r '.[]'); do
    pols=$(vault token lookup -accessor -format=json "$acc" | jq -r '.data.policies | join(",")')
    echo "$acc  policies=$pols"
done
```

Place the accessor in `/etc/vault-unseal/autounseal-accessor.token`:

```bash
sudo install -o root -g root -m 0644 /dev/stdin /etc/vault-unseal/autounseal-accessor.token <<<"<accessor-string>"
```

### 2. Create the lookup-token policy + token

Tight policy — `update` only on `auth/token/lookup-accessor`. Nothing else.

```bash
# transit-autounseal-lookup.hcl
path "auth/token/lookup-accessor" {
  capabilities = ["update"]
}
```

Apply it on the Transit Vault and issue a periodic token bound to it:

```bash
VAULT_ADDR=http://192.168.12.210:8201 VAULT_TOKEN=<transit-root-token> \
  vault policy write autounseal-lookup transit-autounseal-lookup.hcl

VAULT_ADDR=http://192.168.12.210:8201 VAULT_TOKEN=<transit-root-token> \
  vault token create -policy=autounseal-lookup -period=720h -renewable=true \
    -display-name=autounseal-ttl-monitor -format=json | jq -r '.auth.client_token'
```

Place the resulting token in `/etc/vault-unseal/lookup-token`:

```bash
sudo install -o root -g root -m 0400 /dev/stdin /etc/vault-unseal/lookup-token <<<"<lookup-token-value>"
```

> **Note:** the lookup-token itself has a TTL. A future improvement is a dedicated monitor for the lookup-token's own TTL — rolled into OPS-190 follow-up if WARN/CRIT events fire on the lookup-token side. For now, period=720h gives 30 days between renewals; stays alive as long as the timer fires daily.

### 3. Deploy the timer via Ansible

```bash
cd ~/repos/sentinel-iac/ansible
ansible-playbook -i inventory/hosts.yml playbooks/iac-control.yml \
  --tags=platform-timers,vault-autounseal-token-ttl
```

The role asserts both prerequisite files; a missing/mis-permed file fails the task with an explicit message.

### 4. Smoke-test the alerting paths before waiting for real expiry

Run the script in `--simulate` mode on iac-control to fire a synthetic CRIT into Wazuh and confirm the rule chain:

```bash
ssh iac-control 'sudo /usr/local/bin/vault-autounseal-token-ttl.sh --simulate 3600'
# expect: status=CRIT, exit code 2, JSON in stdout + journald + /var/log/...
```

If the Wazuh dashboard receives a CRIT for `vault_autounseal_token_ttl` within ~30s of running this, the path is wired.

---

## Interpreting alerts

| Alert | What it means | Action |
|-------|--------------|--------|
| `OK` (info) | TTL > 7 days | None. Logged for trend. |
| `WARN` (warning) | TTL between 24h and 7d | Schedule a rotation within the week. The auto-unseal token can be rotated against the Transit Vault without restarting prod Vault — see future OPS-191 runbook once that lands. |
| `CRIT` (critical) | TTL < 24h | Rotate today. Failure to rotate = SEC-44 recurrence. Until OPS-191 ships, the rotation is operator-manual. |
| `ERROR` (critical) | Script could not query Transit Vault (file missing, network failure, 403) | Investigate. The monitor itself is broken — the auto-unseal token may be fine or expiring; you don't know. Most common causes: lookup-token expired, accessor file deleted, Transit Vault sealed. |

`ERROR` and `CRIT` both exit 2 (critical level) so Wazuh aggregates them under one rule severity. The `status` field distinguishes them in dashboards.

---

## Manual rotation procedure (until OPS-191 ships)

When `WARN` or `CRIT` fires, the rotation is currently operator-manual. Rough sketch (full procedure deferred to OPS-191):

1. Issue a fresh periodic token on the Transit Vault bound to the `autounseal` policy.
2. Capture the new token's accessor and value.
3. SSH to vault-server (192.168.12.206), edit `/etc/vault/config/config.hcl`, replace the `token = "..."` line in the `seal "transit"` block.
4. `docker restart vault` on vault-server.
5. Verify `https://vault.208.haist.farm/v1/sys/health` returns 200 with `sealed: false`.
6. Update `/etc/vault-unseal/autounseal-accessor.token` on iac-control with the new accessor.
7. Revoke the old token on the Transit Vault.
8. Run `sudo /usr/local/bin/vault-autounseal-token-ttl.sh` once on iac-control to confirm it now reports `OK` for the new token.

---

## Reference

- Issue: OPS-190
- Parent: SEC-44 (post-mortem)
- Companions: OPS-191 (rotation automation, design phase), OPS-192 (Vault Agent template, long-term replacement)
- Pattern source: `vault-health-probe.{sh,service,timer}` in `ansible/roles/iac-control/files/`
