# Runbook 01 — Vault Sealed After Restart

**Scenario:** Vault returned to a sealed state after a VM reboot, crash, or Vault process restart. All services depending on Vault (ESO, Keycloak, sentinel-agent, SSH cert signing) will fail until Vault is unsealed.

**Expected symptom:** `curl -sk https://vault.208.haist.farm/v1/sys/seal-status | jq .sealed` returns `true`. Services return auth errors. ESO logs show `connection refused` or `permission denied` to Vault.

---

## 1. Confirm Vault is sealed

From any host with network access to iac-control or Vault directly:

```bash
curl -sk https://192.168.12.206:8200/v1/sys/seal-status | jq '{sealed, storage_type}'
```

Expected when sealed:
```json
{ "sealed": true, "storage_type": "raft" }
```

---

## 2. Check transit auto-unseal

Vault uses a transit auto-unseal via a secondary Vault instance. If the unseal Vault is healthy, Vault should have unsealed automatically within 60 seconds of restart.

```bash
# Check if Vault process is running on the VM
ssh ubuntu@192.168.12.206 "systemctl status vault"
```

If the service is running but still sealed, transit auto-unseal may have failed.

### 2a. Diagnose transit auto-unseal failure

```bash
ssh ubuntu@192.168.12.206 "sudo journalctl -u vault -n 50 --no-pager"
```

Look for: `core: vault is unsealed` (success) or `auto-unseal` error lines.

Common causes:
- Transit Vault instance unreachable (check which VM hosts it)
- Transit Vault also sealed (recursive — needs manual unseal keys)
- Network partition between the two Vault instances

### 2b. If transit Vault is also sealed

You need offline unseal key shares. These require operator involvement.

```bash
# On Vault VM (console access via Proxmox if SSH is down)
vault operator unseal   # enter key share 1
vault operator unseal   # enter key share 2
vault operator unseal   # enter key share 3 (threshold of 5)
```

Unseal keys are stored offline by the operator. If not available, escalate to break-glass procedure (runbook 08).

---

## 3. If transit auto-unseal is working but Vault is still sealed

Restart the Vault service; auto-unseal should trigger on startup:

```bash
ssh ubuntu@192.168.12.206 "sudo systemctl restart vault"
sleep 30
curl -sk https://192.168.12.206:8200/v1/sys/seal-status | jq .sealed
# Should return false
```

---

## 4. Verify Vault is healthy after unseal

```bash
# Check seal status
curl -sk https://192.168.12.206:8200/v1/sys/seal-status | jq '{sealed, initialized, version}'

# Check raft peer list (should see leader)
VAULT_TOKEN=<operator-token> VAULT_ADDR=https://192.168.12.206:8200 vault operator raft list-peers
```

---

## 5. Verify downstream services recover

After unseal, ESO will re-sync ExternalSecrets within ~2 minutes. Check:

```bash
# From iac-control with valid kubeconfig
export KUBECONFIG=/home/ubuntu/overwatch-repo/auth/kubeconfig.new

# ESO should start syncing
oc get externalsecret -A | grep -v Synced

# Keycloak should come up (if it was restarting)
oc get pods -n keycloak | grep -v Running
```

If ESO shows persistent sync failures after 5 minutes, check the ESO pod logs:

```bash
oc logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=30
```

---

## 6. If Vault remains sealed after all attempts

1. Check Proxmox for VM 205 (Vault) health — verify it is online and not resource-starved
2. Check Vault Raft storage integrity: `vault operator raft snapshot save /tmp/vault-snap.snap`
3. Escalate to break-glass (runbook 08) if operator intervention is required

## Related Runbooks
- [04-service-recovery-order.md](04-service-recovery-order.md) — what to recover after Vault comes up
- [08-break-glass.md](08-break-glass.md) — emergency access if operator unavailable
- [13-vault-autounseal-token-ttl-monitor.md](13-vault-autounseal-token-ttl-monitor.md) — prevent auto-unseal token expiry
- [15-vault-autounseal-rotation.md](15-vault-autounseal-rotation.md) — rotate the transit unseal key
