# 60 — Agent JWT auth migration: Keycloak → Authentik (dual-running staging)

**Tracking:** OPS-870 (this issue) · OPS-867 (audit parent) · OPS-656 (predecessor — jwt-authentik/ mount IaC)
**Status:** PLANNING ONLY — no live infra changes made in this document's authoring session.
**Execution:** requires a separate operator-authorized child issue.
**Last updated:** 2026-05-23 by worker-ops-870-jwt-migration-plan

---

## §0 — Headline

Migrate the Overwatch agent framework (worker/judge/scribe/planner) from authenticating
to Vault via Keycloak-issued JWTs (`auth/jwt/`) to Authentik-issued JWTs
(`auth/jwt-authentik/`).

| Item | Value |
|------|-------|
| **Current IdP** | Keycloak (`auth.208.haist.farm/realms/sentinel`) |
| **Target IdP** | Authentik (`auth-next.208.haist.farm`) |
| **Change surface** | One env var (`SENTINEL_AUTH_BACKEND`) in session-env.sh |
| **Risk** | HIGH — wrong write to `auth/jwt-authentik/` during execution can lock out the entire agent fleet |
| **Mitigation** | Keep `auth/jwt/` (Keycloak) alive throughout migration; new sessions use Authentik only after 48h of clean dual-run traffic |

---

## §1 — Background

### OPS-867 audit (2026-05-23, Done)

The OPS-867 worker audited the full Authentik→Keycloak migration state. Key finding
relevant to this issue (from Keycloak pod logs, most recent ~4h window):

- `sentinel-worker`: 26 CLIENT_LOGIN events (Vault JWT auth via Keycloak)
- `sentinel-judge`: 21 CLIENT_LOGIN events (same path)
- `sentinel-scribe`: 1 CLIENT_LOGIN event
- Total: ~48 agent JWT authentications per 4h window

Keycloak is running 1/1 replicas with active traffic. It **cannot** be decommissioned
until these 48 agent calls per 4h are moved to Authentik.

OPS-867 COMPLETION comment: *"Vault JWT / agents (MEDIUM effort): Separate issue per
vault-jwt-authentik/ mount — agents already have auth infrastructure built out (OPS-656)."*

### OPS-656 predecessor (Done, 2026-05-22)

OPS-630 manually created the `auth/jwt-authentik/` Vault mount. OPS-656 added the
IaC codification (`ansible/roles/vault-jwt-authentik/`) so the mount and 4 roles can
be reproduced deterministically. That work is merged to main.

**Pre-state entering OPS-870:** Both Vault JWT mounts exist and are fully configured.
All 4 Authentik applications (sentinel-worker/judge/scribe/planner) exist in Authentik.
All client credentials are in Vault. The agent bootstrap script (`agent-vault-auth.sh`)
already has the Authentik backend implemented. The migration is an env-var flip, not
new code.

---

## §2 — Current state (sourced from live Vault reads, 2026-05-23T04:15Z)

### 2.1 Vault auth mount inventory

Four JWT-family mounts active:

| Mount | Type | Description | Status |
|-------|------|-------------|--------|
| `jwt/` | jwt | Keycloak sentinel realm JWT (OPS-345) | **PRODUCTION — agents using this** |
| `jwt-authentik/` | jwt | Authentik JWT (OPS-630) | Provisioned, NOT yet receiving agent traffic |
| `jwt-spire/` | jwt | SPIRE trust-domain JWT-SVID (OPS-536) | Separate auth path, not in scope |
| `approle/` | approle | AppRole | Not in scope |

### 2.2 `auth/jwt/` (Keycloak) — mount-level config

```
bound_issuer:               https://auth.208.haist.farm/realms/sentinel
jwt_validation_pubkeys:     [RSA public key, PEM-pinned at mount creation]
jwks_url:                   (empty — uses pinned pubkey)
oidc_discovery_url:         (empty)
```

**Notable:** The Keycloak mount uses a **pinned RSA public key** (not JWKS URL or OIDC
discovery). This means key rotation at Keycloak would silently break agent auth. This is
not a migration blocker but is a hygiene finding — tracked separately by OPS-656 follow-up.

### 2.3 `auth/jwt/` (Keycloak) — per-role config

All 4 roles have identical structure; values differ only in `azp` claim and policy:

| Field | sentinel-worker | sentinel-judge | sentinel-scribe | sentinel-planner |
|-------|----------------|----------------|-----------------|------------------|
| `bound_issuer` | null (→ inherits `https://auth.208.haist.farm/realms/sentinel`) | same | same | same |
| `bound_audiences` | `['account']` | `['account']` | `['account']` | `['account']` |
| `bound_claims` | `{azp: sentinel-worker}` | `{azp: sentinel-judge}` | `{azp: sentinel-scribe}` | `{azp: sentinel-planner}` |
| `user_claim` | `azp` | `azp` | `azp` | `azp` |
| `token_policies` | `[agent-worker]` | `[agent-judge]` | `[agent-scribe]` | `[agent-planner]` |
| `token_ttl` | 3600s | 3600s | 3600s | 3600s |
| `token_max_ttl` | 3600s | 3600s | 3600s | 3600s |
| `token_explicit_max_ttl` | 3600s | 3600s | 3600s | 3600s |
| `token_no_default_policy` | true | true | true | true |

**Verified state:** §2.3 reflects `vault read auth/jwt/role/<role>` output at 2026-05-23T14:41:55Z. Re-verify before relying on §2.3 in any subsequent execution session.

### 2.4 `auth/jwt-authentik/` (Authentik) — mount-level config

```
bound_issuer:       "" (empty — intentional; issuer validated per-role via bound_claims.iss)
jwks_url:           http://192.168.12.83:9000/application/o/sentinel-worker/jwks/
oidc_discovery_url: (empty)
default_role:       sentinel-worker
```

**Design note on empty `bound_issuer`:** The IaC (`defaults/main.yml`) documents this
explicitly — all Authentik applications share the same RSA signing key; the per-role
`bound_claims.iss` provides per-application issuer binding, which is MORE granular than
mount-level `bound_issuer`. Vault validates both: JWKS signature AND `bound_claims.iss`
per login attempt.

**Design note on HTTP JWKS URL:** The internal address `http://192.168.12.83:9000` is
used deliberately to avoid TLS certificate issues between Vault (192.168.12.206) and
Authentik (192.168.12.83). Both are on the same /24 LAN segment. This follows the
pattern documented in `ansible/roles/vault-jwt-authentik/defaults/main.yml`.

### 2.5 `auth/jwt-authentik/` (Authentik) — per-role config

| Field | sentinel-worker | sentinel-judge | sentinel-scribe | sentinel-planner |
|-------|----------------|----------------|-----------------|------------------|
| `bound_issuer` | null (→ inherits empty — issuer checked via bound_claims) | same | same | same |
| `bound_audiences` | `KcpY84WET1wGEv7gGzYM0kWQZwb7pFc95LHRYCWl` | `7jOJvYpGJiW2NX74DzFQhymNNkuRUUeVDUAvKfbo` | `8WYzGcdQ6OEhturGtH0m2ts4IcHrpcHgU1Bw3Gvb` | `5JHHWafdWG7BimHufIxYd5JgxILXaghk4XejZ6El` |
| `bound_claims` | `{iss: https://auth-next.208.haist.farm/application/o/sentinel-worker/}` | `{iss: .../sentinel-judge/}` | `{iss: .../sentinel-scribe/}` | `{iss: .../sentinel-planner/}` |
| `user_claim` | `azp` | `azp` | `azp` | `azp` |
| `token_policies` | `[agent-worker]` | `[agent-judge]` | `[agent-scribe]` | `[agent-planner]` |
| `token_ttl` | 3600s | 3600s | 3600s | 3600s |
| `token_max_ttl` | 3600s | 3600s | 3600s | 3600s |
| `token_explicit_max_ttl` | **not set** (gap) | same gap | same gap | same gap |
| `token_no_default_policy` | **false** (gap) | same gap | same gap | same gap |

**Gap noted (OPS-853):** The live mount is missing `token_explicit_max_ttl` and has
`token_no_default_policy=false`. Running `ansible/playbooks/vault-jwt-authentik.yml`
against the live mount will apply this hardening. This is a security improvement, not a
migration blocker. The execution runbook in §4 includes applying the playbook as Step 0.

### 2.6 Authentik client credentials (Vault)

All 4 agent clients are pre-configured in Vault:

| Path | Fields present |
|------|---------------|
| `secret/authentik/clients/sentinel-worker` | `client_id`, `client_secret`, `client_type`, `grant_type`, `note`, `authentik_provider_pk` |
| `secret/authentik/clients/sentinel-judge` | same fields |
| `secret/authentik/clients/sentinel-scribe` | same fields |
| `secret/authentik/clients/sentinel-planner` | same fields |

The `client_id` values in Vault match the `bound_audiences` in the Vault JWT roles exactly.
This confirms the Authentik applications and Vault roles were configured consistently.

### 2.7 Agent bootstrap script configuration

File: `~/repos/claude-config/scripts/agent-vault-auth.sh` (OPS-347 + OPS-545 + OPS-630)

Three backends are already implemented:

| `SENTINEL_AUTH_BACKEND` value | Behavior |
|-------------------------------|----------|
| unset or `keycloak` | **Current default** — Keycloak only |
| `authentik-keycloak` | Authentik first; Keycloak fallback on any failure |
| `authentik` | Authentik only; fail hard if Authentik path fails |
| `spire` | SPIRE first; Keycloak fallback |
| `spire-only` | SPIRE only (strict) |

**Current production state:** `SENTINEL_AUTH_BACKEND` is NOT set in `session-env.sh` →
defaults to `keycloak`. All new agent sessions use Keycloak today.

**Migration switch point:** Adding one line to the session-env.sh template (or to the
operator's agent-launch env):

```bash
export SENTINEL_AUTH_BACKEND=authentik-keycloak  # dual-run phase
# later:
export SENTINEL_AUTH_BACKEND=authentik            # cutover phase
```

### 2.8 Vault audit device

```
file/ → /vault/logs/audit.log (covers ALL Vault paths)
```

All `auth/jwt-authentik/login` events will appear in `/vault/logs/audit.log` alongside
`auth/jwt/login` events. Audit continuity (AU-12) is maintained through the migration.

### 2.9 Agents consuming `auth/jwt/` (Keycloak) today

Based on OPS-867 audit (Keycloak logs, ~4h window, 2026-05-23):

| Agent role | CLIENT_LOGIN events / 4h |
|-----------|--------------------------|
| sentinel-worker | 26 |
| sentinel-judge | 21 |
| sentinel-scribe | 1 |
| sentinel-planner | 0 (no sessions observed) |
| **Total** | **~48** |

All agent sessions are launched by the operator on the workstation (`192.168.12.55`)
via the overwatch-harness or manual Claude Code session with `session-env.sh` sourced.

---

## §3 — Target state

### 3.1 `auth/jwt-authentik/` — target mount-level config

No change to JWKS URL or bound_issuer. The mount is already configured correctly.
Running the IaC playbook applies two security hardening items (not config changes for
migration):

```
jwks_url:                   http://192.168.12.83:9000/application/o/sentinel-worker/jwks/
bound_issuer:               "" (intentional — role-level bound_claims.iss discriminates)
default_role:               sentinel-worker
```

### 3.2 `auth/jwt-authentik/` — target per-role config (post-hardening)

Same as current PLUS two security improvements applied by running the Ansible playbook:

| Field | Target value (all 4 roles) |
|-------|---------------------------|
| `token_explicit_max_ttl` | `1h` (closes renewal-stacking loophole) |
| `token_no_default_policy` | `true` (drops auto-attached default policy) |

All other fields remain identical to current state.

### 3.3 Agent framework — target config

`SENTINEL_AUTH_BACKEND=authentik` in session-env.sh (after dual-run validation).

Agents authenticate to Vault via:
```
Authentik client_credentials → https://auth-next.208.haist.farm/application/o/token/
JWT → vault write auth/jwt-authentik/login role=sentinel-<role> jwt=<token>
Vault scoped token → ~/.claude/cache/agent-vault-token-${SESSION_ID}-<role>
```

### 3.4 Token claim shape — Authentik vs Keycloak

**This is the critical difference.** Authentik JWTs have a different claim layout:

| Claim | Keycloak value | Authentik value |
|-------|---------------|-----------------|
| `iss` | `https://auth.208.haist.farm/realms/sentinel` | `https://auth-next.208.haist.farm/application/o/sentinel-{role}/` |
| `aud` | `['account']` | `['{client_id}']` (per-application UUID string) |
| `azp` | `sentinel-{role}` (client_id) | `{client_id}` (same UUID as `aud`) |
| `sub` | UUID of the service account | UUID of the service account in Authentik |

**What this means for Vault role binding:**

- Vault's `auth/jwt-authentik/` roles use `user_claim: azp` — the `azp` claim in
  Authentik JWTs is the `client_id` UUID, not a human-readable role name.
- Vault audit log attribution will show UUID strings (e.g., `KcpY84WET1wGEv7...`) as
  the entity alias, not `sentinel-worker`. This is cosmetically different from Keycloak
  (which shows `sentinel-worker`). It does not affect functionality.
- The `bound_claims.iss` check provides the human-readable role binding:
  `iss: https://auth-next.208.haist.farm/application/o/sentinel-worker/` is the load-bearing
  discriminator that ties a token to one specific agent role.

### 3.5 What does NOT change

- Vault policies (`agent-worker`, `agent-judge`, `agent-scribe`, `agent-planner`) — unchanged
- Token TTL (1h) — unchanged
- Scoped token cache path (`~/.claude/cache/agent-vault-token-${SESSION_ID}-{role}`) — unchanged
- All Vault secret paths accessed by agents — unchanged
- CLAUDE.md — unchanged
- check-strength.yaml, nist-compliance-check.sh — unchanged

---

## §4 — Execution procedure (dual-running staging)

> **CRITICAL:** Every step below is operator-executed. Workers do NOT execute these
> steps. The execution session requires a separate operator-authorized child issue.
> This runbook is planning documentation only.

### Step 0 — Apply IaC playbook to harden jwt-authentik/ roles (optional but recommended)

**Purpose:** Apply `token_explicit_max_ttl=1h` and `token_no_default_policy=true` to
the 4 existing jwt-authentik/ roles. This is an idempotent hardening step that does
NOT change migration-relevant config.

**Verification before:** `vault read auth/jwt-authentik/role/sentinel-worker` shows
`token_explicit_max_ttl=0` (not set) and `token_no_default_policy=false`.

**Command** (from iac-control or workstation with Vault reachable):

```bash
cd ~/repos/sentinel-iac
ansible-playbook ansible/playbooks/vault-jwt-authentik.yml \
  -e vault_token="$VAULT_TOKEN" \
  -e vault_addr=https://vault.208.haist.farm
```

**Verification after:** `vault read -format=json auth/jwt-authentik/role/sentinel-worker`
shows `token_explicit_max_ttl=3600` and `token_no_default_policy=true`.

**Rollback:** Re-run playbook with override vars
`vault_jwt_authentik_token_no_default_policy=false vault_jwt_authentik_token_explicit_max_ttl=0`.

---

### Step 1 — Verify Authentik client credentials are accessible

**Purpose:** Confirm agent-vault-auth.sh can read from `secret/authentik/clients/sentinel-{role}`
before switching backends.

**Commands** (run as the operator session, not as an agent):

```bash
# Verify all 4 paths exist and have required fields
for role in worker judge scribe planner; do
  CLIENT_ID=$(vault kv get -field=client_id "secret/authentik/clients/sentinel-$role")
  CLIENT_SECRET=$(vault kv get -field=client_secret "secret/authentik/clients/sentinel-$role")
  echo "sentinel-$role: client_id=${CLIENT_ID} secret_len=${#CLIENT_SECRET}"
done
```

**Expected output:** 4 lines, each with non-empty client_id and secret_len > 0.
**Failure path:** If any path returns an error → check Vault policy for agent-worker
(`secret/authentik/clients/*` must be readable). Do NOT proceed to Step 2.

---

### Step 2 — Manual end-to-end canary test (Authentik path only)

**Purpose:** Confirm the Authentik→Vault JWT exchange works for at least `sentinel-worker`
before switching any live agent sessions.

**Commands** (from workstation, using operator VAULT_TOKEN):

```bash
# Manually invoke the Authentik backend for sentinel-worker
SENTINEL_AUTH_BACKEND=authentik-keycloak \
  bash ~/repos/claude-config/scripts/agent-vault-auth.sh worker 2>&1

# The script should print:
# [agent-vault-auth] Trying Authentik backend (role=worker)...
# [agent-vault-auth] [AK] Authentik client_id=KcpY84WET1wGEv7... loaded.
# [agent-vault-auth] [AK] JWT obtained (NNN chars). Exchanging for Vault token...
# [agent-vault-auth] [AK] Vault scoped token obtained (95 chars).
# [agent-vault-auth] Token written (mode 0600) to ~/.claude/cache/agent-vault-token-default-worker
# /home/koiakoia/.claude/cache/agent-vault-token-default-worker
```

**Verify the token works:**

```bash
TOKEN=$(cat ~/.claude/cache/agent-vault-token-default-worker)
VAULT_TOKEN="$TOKEN" vault token lookup 2>&1
# Expected: display_name, policies=[agent-worker], ttl < 3600
```

**Read a known-good Vault path with the scoped token:**

```bash
VAULT_TOKEN="$TOKEN" vault kv get secret/forgejo-worker 2>&1
# Expected: shows the secret fields (confirms agent-worker policy works)
```

**Failure path:** If Authentik returns `error` in JWT response → check Authentik admin UI:
confirm `sentinel-worker` application is active, `client_credentials` grant is enabled,
client_secret matches Vault `secret/authentik/clients/sentinel-worker.client_secret`.

---

### Step 3 — Enable dual-run mode in session-env.sh

**Purpose:** All NEW agent sessions use Authentik first, with automatic Keycloak fallback.
Existing agent sessions (holding valid Keycloak tokens) are unaffected until their 1h
token expires.

**File to edit:** The session-env.sh template used by overwatch-harness or manually sourced
by the operator before launching agents. Currently at `$CLAUDE_JOB_DIR/session-env.sh`
(job-specific) — the persistent source is in the overwatch-harness dispatch logic.

**Change (add one line):**

```bash
export SENTINEL_AUTH_BACKEND=authentik-keycloak
```

This enables `authentik-keycloak` mode: Authentik first, Keycloak fallback on any failure.

**Verification:** Launch one new agent session. Check session startup logs in Plane (first
comment should include `[AK]` lines from the auth script). Confirm token lookup shows
`display_name` with Authentik-sourced entity alias.

**Keycloak fallback behavior:** If Authentik is down or returns an error, agent-vault-auth.sh
automatically falls back to Keycloak without any manual intervention. The log will show:
`[agent-vault-auth] Authentik backend failed — falling back to Keycloak (dual-path).`

---

### Step 4 — 48h dual-run observation

**Purpose:** Observe that agent sessions successfully authenticate via Authentik for 48
consecutive hours with no fleet-wide impact.

**Monitoring:**

```bash
# Check Vault audit log for jwt-authentik/ traffic
grep "auth/jwt-authentik" /vault/logs/audit.log | tail -50
# Expected: CLIENT_LOGIN events with auth.display_name matching Authentik client_ids

# Check Vault audit log for Keycloak fallbacks (should be zero if Authentik is healthy)
grep "auth/jwt/login" /vault/logs/audit.log | tail -20
# Expected: zero new sentinel-* events (old sessions may appear until TTL expires)

# Check for auth failures
grep '"error"' /vault/logs/audit.log | grep "jwt-authentik" | tail -20
# Expected: none
```

**Acceptable during observation:**
- Some `auth/jwt/` events in the first hour (existing sessions using cached Keycloak tokens)
- Zero `auth/jwt/` events from sentinel-* after the first 1-2h (all sessions refreshed)
- All new `auth/jwt-authentik/` events succeeding (no error entries)

**Failure during observation:** If any agent session fails to auth:
1. Check if it's Authentik-path failure or Keycloak-fallback: look for `[KC]` in agent logs
2. If Authentik-path failing but Keycloak-fallback succeeding → do NOT proceed to Step 5.
   Investigate Authentik error before cutover.
3. If both paths failing → operator emergency: proceed to §6 Rollback.

---

### Step 5 — Cutover to Authentik-only

**Prerequisite:** 48h clean operation in dual-run mode. Zero `auth/jwt/` events from
sentinel-* agents in the last 2h.

**Change:**

```bash
# In session-env.sh / agent launch env:
export SENTINEL_AUTH_BACKEND=authentik  # was: authentik-keycloak
```

**Verification:** Launch fresh agent session. Confirm no `[KC]` lines in auth script
output. Confirm Vault audit log shows ONLY `auth/jwt-authentik/` events for new sessions.

---

### Step 6 — 48h Authentik-only observation before disabling Keycloak mount

**Purpose:** Final confirmation that no agent path still depends on `auth/jwt/`.

**Monitoring:**

```bash
# Zero sentinel-* CLIENT_LOGIN events on jwt/ in last 48h
grep "auth/jwt/login" /vault/logs/audit.log | grep "sentinel-" | tail -20
# Expected: none (or only events from before the Step 5 cutover timestamp)
```

**Success criterion:** No `auth/jwt/` events from sentinel-* agents for 48 consecutive
hours of normal fleet operation.

**On success:** Operator creates child issue for `auth/jwt/` mount archival (disable or
revoke, not delete — preserve Vault audit log continuity). That is a separate issue,
not part of OPS-870.

---

## §5 — Verification matrix

| Step | Command | Expected | Failure indication |
|------|---------|----------|--------------------|
| 0 — IaC applied | `vault read -format=json auth/jwt-authentik/role/sentinel-worker \| jq '.data.token_explicit_max_ttl,.data.token_no_default_policy'` | `3600`, `true` | Still `0`, `false` → playbook not applied |
| 1 — Creds accessible | `vault kv get -field=client_id secret/authentik/clients/sentinel-worker` | UUID string | `permission denied` → policy gap |
| 2 — Manual canary | auth script output includes `[AK]` lines and exits 0 | Token file written | `[AK] Failed to extract access_token` → Authentik config issue |
| 2 — Token valid | `VAULT_TOKEN=$(cat cache/...) vault token lookup` | `policies=[agent-worker]` | `permission denied` → wrong role binding |
| 2 — Vault path read | `VAULT_TOKEN=$(cat cache/...) vault kv get secret/forgejo-worker` | Secret fields displayed | `permission denied` → agent-worker policy gap |
| 3 — Dual-run active | `grep "[AK]" <agent-session-log>` | `[AK] Vault scoped token obtained` | `[KC]` lines only → env var not set |
| 4 — 48h clean | `grep "auth/jwt-authentik" /vault/logs/audit.log \| wc -l` | Count increasing | Zero → no agent sessions starting |
| 4 — No fallbacks | `grep "auth/jwt/login" /vault/logs/audit.log \| grep "sentinel" \| wc -l` | Same count or decreasing | Increasing → Authentik failing, Keycloak carrying load |
| 5 — Cutover | Agent log: no `[KC]` lines | Only `[AK]` lines | `[KC]` present → fallback triggered → Authentik error |
| 6 — Final clean | 48h Vault audit with no `auth/jwt/login` from sentinel-* | Zero count | Any count → investigate before disabling mount |

---

## §6 — Rollback procedure

### Rollback from Step 3 (dual-run active, need to revert to Keycloak-only)

This is the cheapest rollback. No Vault changes needed.

```bash
# Remove the SENTINEL_AUTH_BACKEND line from session-env.sh
# (or set it back to keycloak)
export SENTINEL_AUTH_BACKEND=keycloak  # or unset SENTINEL_AUTH_BACKEND
```

Existing Keycloak tokens remain valid (1h TTL). Next session refresh uses Keycloak.
No agent downtime.

### Rollback from Step 5 (Authentik-only, reverting to dual-run)

```bash
export SENTINEL_AUTH_BACKEND=authentik-keycloak
```

Existing tokens (from Authentik) remain valid until TTL expires. No interruption.

### Emergency rollback — total agent auth failure

If agents cannot auth via either Authentik or Keycloak:

1. **Operator SSH to workstation** (192.168.12.55, always accessible, never auto-blocked)
2. **Set session env manually:**
   ```bash
   export VAULT_TOKEN=$(cat ~/.vault-token)  # operator root token
   export SENTINEL_AUTH_BACKEND=keycloak
   ```
3. **Test Keycloak path manually:**
   ```bash
   bash ~/repos/claude-config/scripts/agent-vault-auth.sh worker 2>&1
   ```
4. If Keycloak also fails, the operator holds the root `VAULT_TOKEN` and can operate
   Vault directly without any JWT exchange. The agent framework can be bypassed entirely
   for emergency operator-driven recovery.

### Rollback if Authentik provider is misconfigured

If the Authentik application (`sentinel-worker` etc.) is misconfigured and Authentik
is returning 401/400 on the token endpoint:

1. Revert `SENTINEL_AUTH_BACKEND=keycloak` (immediate fallback, 0 downtime)
2. Agent sessions will continue using the Keycloak path
3. Investigate Authentik admin UI: confirm `client_credentials` grant is enabled,
   `client_secret` matches Vault, application is active
4. After fixing Authentik config, re-test via Step 2 before enabling dual-run again

---

## §7 — Risk register

| Risk | Trigger | Detection | Recovery |
|------|---------|-----------|----------|
| **Agent fleet total lockout** | Both Authentik and Keycloak paths fail simultaneously | Agents fail to post SESSION START comment; no new Vault audit events from sentinel-* | Operator uses root VAULT_TOKEN directly (no JWT exchange needed); set `SENTINEL_AUTH_BACKEND=keycloak`; verify Keycloak is reachable at `https://auth.208.haist.farm/realms/sentinel/protocol/openid-connect/token` |
| **Authentik provider downtime during dual-run** | Authentik VM (192.168.12.83) down; Keycloak still up | Agent logs show `[AK] Failed` then `[KC] Vault scoped token obtained` | No action needed — Keycloak carries load automatically in `authentik-keycloak` mode |
| **bound_claims mismatch (iss URL wrong)** | Vault role has wrong `iss` for this application | Vault returns `403 permission denied` with `claim "iss" does not match bound claim` | Check Authentik provider's issuer URL: curl the OIDC discovery endpoint `https://auth-next.208.haist.farm/application/o/sentinel-worker/.well-known/openid-configuration` and compare `issuer` field to Vault role's `bound_claims.iss` |
| **bound_audiences mismatch (client_id wrong)** | Vault role has wrong `bound_audiences` for this application | Vault returns `403` with `audience claim does not match` | Compare `vault read auth/jwt-authentik/role/sentinel-worker .data.bound_audiences[0]` with `vault kv get -field=client_id secret/authentik/clients/sentinel-worker`; they must match |
| **Authentik client_secret rotation (Vault stale)** | Operator rotates Authentik client secret; Vault secret not updated | Agent auth returns `401 Unauthorized` from Authentik token endpoint | Update `secret/authentik/clients/sentinel-{role}` with new client_secret; test via Step 2 canary |
| **Token TTL mismatch during transition** | jwt/ and jwt-authentik/ have different TTLs | Agents hold tokens with different remaining TTLs | Both mounts are configured at 3600s (1h). No mismatch. |
| **Vault JWKS fetch failure** | Authentik VM down; Vault cannot refresh JWKS cache | Vault returns `JWKS validation failed` or similar | Vault caches JWKS; short outages tolerated. If Authentik is down > JWKS cache TTL, fall back to Keycloak via `SENTINEL_AUTH_BACKEND=keycloak`. |
| **Audit continuity gap (AU-12)** | `auth/jwt-authentik/` events not appearing in audit log | Audit log shows only `auth/jwt/` events during dual-run | Vault `file/` audit device covers ALL paths. Verify: `grep "jwt-authentik" /vault/logs/audit.log` within 5 minutes of a successful Authentik auth. If missing, run `vault audit list` and confirm `file/` is enabled. |
| **OPS-853 hardening gap** | jwt-authentik/ roles have `token_no_default_policy=false` | Scoped tokens include extra `default` policy grants | Apply Ansible playbook (Step 0). Tokens from the old config remain valid for up to 1h; no security event, just over-permissive for that TTL window. |

---

## §8 — Acceptance criteria

All boxes must be checked before this migration is considered complete:

- [ ] Step 0: Ansible playbook applied; `token_explicit_max_ttl=3600` and `token_no_default_policy=true` confirmed on all 4 jwt-authentik/ roles
- [ ] Step 1: All 4 `secret/authentik/clients/sentinel-{role}` paths return non-empty `client_id` and `client_secret`
- [ ] Step 2: Manual canary (`SENTINEL_AUTH_BACKEND=authentik-keycloak`) succeeds for `sentinel-worker`; scoped token validated against Vault; `secret/forgejo-worker` readable
- [ ] Step 3: `SENTINEL_AUTH_BACKEND=authentik-keycloak` set in session-env.sh; at least one live agent session shows `[AK]` lines in auth log
- [ ] Step 4: 48 consecutive hours of `auth/jwt-authentik/` traffic; zero `auth/jwt/` events from sentinel-* during that window (after existing 1h tokens expire)
- [ ] Step 5: `SENTINEL_AUTH_BACKEND=authentik`; fresh agent session shows only `[AK]` lines, no `[KC]` fallback
- [ ] **Final criterion:** No `auth/jwt/login` events for sentinel-* agents in 48 consecutive hours of agent-fleet operation
- [ ] Plane OPS-870 marked Done by Judge after execution session completes

---

## §9 — Execution gate

**THIS RUNBOOK IS PLANNING DOCUMENTATION ONLY.**

No live Vault changes were made in the session that authored this document (2026-05-23).
No Authentik configuration was changed. No Ansible playbook was applied.

Execution requires:
1. A separate operator-authorized child issue (child of OPS-870)
2. Operator scheduling in a future session
3. A WORKER assigned to the execution issue who follows §4 step-by-step with
   evidence posted to Plane per CLAUDE.md §6 Engineering Notes standards

The execution issue should reference this runbook as the staging procedure.

---

## Appendix A — Vault probe commands (run during planning, 2026-05-23T04:15Z)

All commands were read-only (`vault read`, `vault list`, no writes):

```bash
# Timestamp: 2026-05-23T04:15Z
vault auth list -format=json                                       # mount inventory
vault read -format=json auth/jwt/config                            # Keycloak mount config
vault list -format=json auth/jwt/role                              # role list
vault read -format=json auth/jwt/role/sentinel-{worker,judge,scribe,planner}
vault read -format=json auth/jwt-authentik/config                  # Authentik mount config
vault list -format=json auth/jwt-authentik/role
vault read -format=json auth/jwt-authentik/role/sentinel-{worker,judge,scribe,planner}
vault audit list -format=json                                      # audit devices
vault kv get -format=json secret/authentik/clients/sentinel-{worker,judge,scribe,planner}  # keys only
```

Claims cited from live Vault output vs. extrapolated:

| Claim | Source |
|-------|--------|
| All `auth/jwt/` config values | Live Vault read 2026-05-23T04:15Z |
| All `auth/jwt-authentik/` config values | Live Vault read 2026-05-23T04:15Z |
| All per-role `bound_audiences` values | Live Vault read 2026-05-23T04:15Z |
| `SENTINEL_AUTH_BACKEND` defaults | Source code read from `~/repos/claude-config/scripts/agent-vault-auth.sh` |
| Authentik client_ids (match Vault bound_audiences) | Live `vault kv get secret/authentik/clients/sentinel-{role}` 2026-05-23T04:15Z |
| Authentik VM address (192.168.12.83) | OPS-867 audit comments |
| Keycloak CLIENT_LOGIN count (~48 per 4h) | OPS-867 audit comments (sourced from Keycloak pod logs) |
| OPS-853 hardening gap | IaC `defaults/main.yml` comment lines 131-135 |
| Authentik token URL | `agent-vault-auth.sh` source (AUTHENTIK_TOKEN_URL) |
| Vault audit device file path | Live `vault audit list` 2026-05-23T04:15Z |

---

## Appendix B — Files modified by this runbook's authoring

**This PR adds one file only:**

- `docs/runbooks/60-agent-jwt-migration.md` (this file)

**No IaC was modified.** No Vault config was written. No Authentik config was changed.
The Ansible role (`ansible/roles/vault-jwt-authentik/`) is pre-existing from OPS-656
and is cited by the execution procedure in §4 Step 0 but was not run.
