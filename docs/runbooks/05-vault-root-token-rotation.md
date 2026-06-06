# Runbook 05 — Vault Root Token Rotation

**Scenario:** The Vault root token needs to be rotated. This is done periodically for security hygiene or after a suspected compromise. Vault root tokens have unrestricted access — they should be revoked when not in use and regenerated only when needed.

**Prerequisites:**
- Vault is unsealed and healthy
- You have the unseal key shares (threshold number) OR an existing valid root token
- Access to iac-control (192.168.12.210)

---

## 1. Understand the two approaches

| Situation | Approach |
|-----------|----------|
| You have an existing root token to revoke and replace | Use `vault token create` + revoke old token |
| Root token is lost or expired, need to generate from scratch | Use `vault operator generate-root` with unseal key shares |
| Existing root token needs rotation, keys available | Use `generate-root` for a clean rotation |

For routine rotation where you have a working root token, use the generate-root approach for a clean audit trail.

---

## 2. Generate a new root token

Root token generation requires the unseal key shares (quorum threshold).

```bash
export VAULT_ADDR=https://192.168.12.206:8200

# Step 1: Initialize root token generation
vault operator generate-root -init
```

Note the `OTP` and `Nonce` values from the output. You'll need both.

```bash
# Step 2: Provide each key share (run once per key holder)
vault operator generate-root -nonce=<NONCE>
# Enter key share when prompted
# Repeat for each share until threshold is met
```

When the threshold is reached, the command returns an `Encoded Token`. Decode it:

```bash
vault operator generate-root -decode=<ENCODED-TOKEN> -otp=<OTP>
```

This outputs the new root token.

---

## 3. Store the new root token

**Do not leave the root token in shell history or environment variables.**

1. Store in the operator's offline secure storage immediately
2. Update Vault at `secret/vault/root-token` if used by automation (see note below)

**Note:** Automation (sentinel-agent, ESO, CI) should use AppRole or token-based auth with scoped policies — NOT the root token. If anything in automation is using the root token, that is a finding (file a SEC issue).

---

## 4. Revoke the old root token

```bash
# Use the NEW token to revoke the old one
VAULT_TOKEN=<new-root-token> vault token revoke <old-root-token>
```

Verify revocation:
```bash
VAULT_TOKEN=<old-root-token> vault token lookup
# Should return "permission denied" or "bad token"
```

---

## 5. Verify Vault is still healthy after rotation

```bash
# Check seal status
curl -sk https://192.168.12.206:8200/v1/sys/seal-status | jq '{sealed, initialized}'

# Verify new token works
VAULT_ADDR=https://192.168.12.206:8200 VAULT_TOKEN=<new-root-token> vault token lookup

# Check ESO is still syncing (it uses its own AppRole, not root token)
export KUBECONFIG=/home/ubuntu/overwatch-repo/auth/kubeconfig.new
oc get externalsecret -A | grep -c Synced
```

---

## 6. Update downstream consumers (if any)

Run a check to ensure nothing is using the old token:

```bash
# Check Vault audit log for recent use of the old token
VAULT_TOKEN=<new-root-token> vault audit list
# If file audit is enabled, grep for the old token accessor
```

Known Vault token consumers and their auth method:
- ESO (External Secrets Operator) — AppRole via `secret/eso-token`
- sentinel-agent — AppRole
- CI pipeline — token from `secret/forgejo-worker`
- Prometheus — token with read-only policy
- SSH CA signing — token from claude-automation policy

None of these should be using the root token. If any are, rotate them to AppRole or scoped tokens and file a SEC issue.

---

## 7. Post-rotation checklist

- [ ] New root token stored offline in operator's secure storage
- [ ] Old root token revoked
- [ ] `vault token lookup` on old token returns error
- [ ] ESO continuing to sync (check `oc get externalsecret -A`)
- [ ] Keycloak still accessible (https://auth.208.haist.farm)
- [ ] Forgejo actions still running (check recent CI pipeline)
- [ ] AGENT-STATE.md updated with rotation timestamp if in session context

---

## Related Runbooks
- [01-vault-unseal.md](01-vault-unseal.md) — if Vault is sealed during this process
- [15-vault-autounseal-rotation.md](15-vault-autounseal-rotation.md) — rotate the transit unseal key
- [21-orphaned-credential-sweep.md](21-orphaned-credential-sweep.md) — find and remove unused credentials
