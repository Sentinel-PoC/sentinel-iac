# Vault Per-Task Token Broker — Design Document

**Tracking:** OPS-920 Phase 1 (design only; no infra changes this issue)
**Author:** worker-ops-920
**Date:** 2026-05-29
**Status:** Draft — ready for operator review + Phase 2 issue filing

---

## 1. Problem Statement

Every Overwatch agent session currently holds the operator's root Vault token
(or a session-scoped `claude-automation` token) for the full duration of the
session, which may span hours. Per OPS-345 Phase 3, agents exchange this for a
role-scoped token (`agent-worker`, `agent-judge`, etc.) via
`agent-vault-auth.sh`, but that scoped token is still session-long (1h TTL,
held in `~/.claude/cache/agent-vault-token-<session>-<role>`).

The current scope of that session token covers every secret the role is allowed
to read — not just the specific secret the agent needs for the specific action
it is currently performing. Example: the `agent-worker` policy grants read on
`secret/data/forgejo-worker`, `secret/data/plane/api-key`, and
`secret/data/proxmox-audit`. An agent writing a Plane comment (which requires
only `plane/api-key`) also holds the Forgejo push token for the entire session,
even during steps where Forgejo is not needed.

The blast radius of any single agent compromise is: all secrets readable by that
role for the duration of the session token TTL (1h).

**Goal:** Reduce blast radius to a single capability with a short TTL (seconds
to minutes) by issuing per-task tokens rather than per-session tokens.

---

## 2. Current Agent Vault-Access Patterns

### 2.1 Token acquisition path (observed from transcripts and agent-vault-auth.sh)

```
Operator starts session
  → sets VAULT_TOKEN (claude-automation policy, 720h period token)
  → agent calls agent-vault-auth.sh <role>
    → Keycloak client_credentials flow
      → Vault auth/jwt/login (role=sentinel-<role>)
        → 1h scoped token written to ~/.claude/cache/agent-vault-token-<session>-<role>
          → agent reads token file before each Vault operation
```

Three auth backends exist (Keycloak default, Authentik opt-in, SPIRE opt-in).
SPIRE is the most security-forward (workload-attested identity) but requires
the `sentinel-<role>` Unix user and a running SPIRE Agent — not available on
the workstation where most agent sessions run.

### 2.2 Per-role secret access (from live policy reads 2026-05-29)

| Role | Secrets accessible |
|------|--------------------|
| agent-worker | `secret/forgejo-worker`, `secret/plane/api-key`, `secret/proxmox-audit` |
| agent-judge | `secret/forgejo-judge`, `secret/forgejo/vault-autogen-bot`, `secret/plane/api-key` |
| agent-planner | `secret/forgejo-planner`, `secret/plane/api-key` |
| agent-scribe | `secret/forgejo-scribe`, `secret/plane/api-key` |

### 2.3 Distinct operations agents perform against Vault

From analysis of agent-vault-auth.sh, claude-config agent definitions, and
recent session transcripts:

| Operation | Secret needed | Frequency |
|-----------|---------------|-----------|
| Post Plane comment | `secret/plane/api-key` | Every session, many times |
| Push branch / open PR | `secret/forgejo-worker` | Once or twice per session |
| Add reviewer (admin token) | `secret/forgejo/vault-autogen-bot` | Once per PR |
| Merge PR (judge) | `secret/forgejo-judge` | Once per session |
| Read Proxmox state (worker) | `secret/proxmox-audit` | Occasionally |
| Sign SSH JIT cert | Vault SSH PKI | Per-session setup |
| Read infra secrets for IaC | Various `secret/data/*` (claude-automation) | Lead-session patterns |

---

## 3. Minimum Capability Scopes

A capability scope is a (secret-path, allowed-operations, max-TTL) tuple. The
principle is deny-by-default: an agent must declare which capability it needs
before the broker issues a token. The broker issues a token scoped to exactly
that capability.

Proposed initial capability set:

| Capability ID | Vault path(s) | Operations | Suggested TTL |
|---------------|---------------|------------|---------------|
| `plane-comment` | `secret/data/plane/api-key` | read | 5 min |
| `forgejo-push` | `secret/data/forgejo-worker` | read | 10 min |
| `forgejo-merge` | `secret/data/forgejo-judge`, `secret/data/forgejo/vault-autogen-bot` | read | 10 min |
| `forgejo-review-add` | `secret/data/forgejo/vault-autogen-bot` | read | 5 min |
| `proxmox-audit` | `secret/data/proxmox-audit` | read | 10 min |
| `ssh-sign` | `ssh/sign/admin`, `ssh/sign/claude-automation` | create | 5 min |
| `vault-inspect-self` | `auth/token/lookup-self` | read | 2 min |

These map 1:1 to Vault policies. Each capability has a corresponding Vault
policy and a corresponding Vault token role with `token_explicit_max_ttl` at
the suggested TTL.

### 3.1 How scope declaration works

Before each action, the agent:

1. Calls the broker: `broker request-token --capability plane-comment --ttl 5m`
2. Broker authenticates the agent identity (see §5), checks the allowlist, and
   issues a Vault token scoped to the `plane-comment` policy.
3. Agent uses the token for that single operation.
4. Token expires automatically after 5 minutes; no revocation needed for normal
   operation (broker may revoke on scope-boundary violations).

---

## 4. Broker API Surface

### 4.1 Option A: Unix domain socket (RECOMMENDED)

**API shape:** JSON-over-Unix-socket (single request/response, no persistent
connection state)

```
Socket: /run/sentinel-broker/broker.sock  (systemd-created, mode 0660)
Owner:  root:sentinel-agents (group-accessible to all sentinel-* users)
```

Request:
```json
{
  "version": "1",
  "capability": "plane-comment",
  "ttl": "5m",
  "agent_id": "worker-ops-920",
  "trace_id": "abc123"
}
```

Response (success):
```json
{
  "vault_token": "hvs.XXXX",
  "expires_at": "2026-05-29T01:05:00Z",
  "capability": "plane-comment"
}
```

Response (denied):
```json
{
  "error": "capability 'forgejo-merge' not in allowlist for agent identity sentinel-worker",
  "code": "CAPABILITY_DENIED"
}
```

**Rationale:** Unix sockets are the lightest-weight IPC mechanism. No TLS
complexity (kernel-enforced POSIX file permissions). SPIRE's Workload API uses
the same pattern. The broker process does SO_PEERCRED on every connection to
read the caller's UID/GID — this is the agent identity for allowlist lookup.

**CLI wrapper for agents:**

```bash
# Thin CLI wrapper
sentinel-broker get-token --capability plane-comment --ttl 5m
```

The CLI writes the token to a per-request tmpfile in `/run/sentinel-broker/`,
echoes the path, and the agent reads-then-deletes it (zero token lifespan in
environment variables).

### 4.2 Option B: HTTP (localhost only)

```
Listen: 127.0.0.1:9200 (not 0.0.0.0)
Auth: mutual attestation via short-lived bearer token in Authorization header
```

Less preferred: HTTP requires additional code to prevent non-localhost binding
from being a regression risk. Adds TLS-or-not decision overhead. Suitable if
the broker needs to run on a different host (iac-control → workstation), but
that use case is not in scope for Phase 2.

### 4.3 Option C: mTLS over UNIX socket or TCP

Most secure but requires PKI infrastructure already present (Vault PKI or
SPIRE SVIDs). Appropriate for Phase 3+ once SPIRE is deployed on all agent
hosts. Not recommended for Phase 2 — adds 2 weeks of infra work before value
is delivered.

**Decision:** Build Phase 2 against Option A (Unix socket). Design the protocol
so Option C can be added as a transport layer without changing the request/response
JSON schema.

---

## 5. Broker Policy Engine

### 5.1 Identity

The broker uses SO_PEERCRED to read the connecting process's UID. The UID maps
to a Unix user in the `sentinel-agents` group:

| Unix user | Agent role | Default allowlist |
|-----------|------------|-------------------|
| `sentinel-worker` | WORKER | `plane-comment`, `forgejo-push`, `proxmox-audit`, `vault-inspect-self` |
| `sentinel-judge` | JUDGE | `plane-comment`, `forgejo-merge`, `forgejo-review-add`, `vault-inspect-self` |
| `sentinel-planner` | PLANNER | `plane-comment`, `vault-inspect-self` |
| `sentinel-scribe` | SCRIBE | `plane-comment`, `forgejo-push`, `vault-inspect-self` |

For the **workstation** case (lead sessions running as the operator user `koiakoia`):
- The broker recognizes the operator UID and applies the `claude-automation` allowlist.
- This is intentionally broader (matching current behavior) but still task-scoped.
- Operator sessions use this path; dedicated sentinel-* users are for daemon-mode agents.

### 5.2 Allowlist format

Stored in a TOML config file at `/etc/sentinel-broker/allowlist.toml`:

```toml
# Per-identity capability allowlists
# identity = OS username (from SO_PEERCRED UID → /etc/passwd lookup)

[identity.sentinel-worker]
capabilities = ["plane-comment", "forgejo-push", "proxmox-audit", "vault-inspect-self"]

[identity.sentinel-judge]
capabilities = ["plane-comment", "forgejo-merge", "forgejo-review-add", "vault-inspect-self"]

[identity.sentinel-planner]
capabilities = ["plane-comment", "vault-inspect-self"]

[identity.sentinel-scribe]
capabilities = ["plane-comment", "forgejo-push", "vault-inspect-self"]

[identity.koiakoia]
# Operator-user: all capabilities (matches claude-automation policy)
capabilities = ["plane-comment", "forgejo-push", "forgejo-merge", "forgejo-review-add", "proxmox-audit", "ssh-sign", "vault-inspect-self"]
```

Config changes require broker restart. Allowlist is NOT hot-reloaded (prevents
TOCTOU attacks against the allowlist file).

### 5.3 Rate limiting

Per-identity rate limits prevent a compromised agent from exhausting Vault token
creation quotas:

- Default: 60 token requests per minute per identity
- After limit: `RATE_EXCEEDED` error; broker logs the event

### 5.4 Audit log

Every token request is logged to structured JSON:

```json
{
  "ts": "2026-05-29T01:00:05Z",
  "identity": "sentinel-worker",
  "pid": 12345,
  "capability": "plane-comment",
  "ttl_requested": "5m",
  "outcome": "ISSUED",
  "vault_accessor": "hvs-accessor-XXXX",
  "trace_id": "abc123"
}
```

Log destination: `/var/log/sentinel/broker.jsonl` (append-only, logrotate weekly).
The `vault_accessor` field enables correlation with Vault's audit log for full
token lifecycle tracking.

---

## 6. Deployment Options

### 6.1 Workstation systemd user service (RECOMMENDED for Phase 2)

```ini
# ~/.config/systemd/user/sentinel-broker.service
[Unit]
Description=Sentinel per-task Vault token broker
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sentinel-broker serve --config /etc/sentinel-broker/config.toml
Restart=on-failure
RestartSec=5s
# Socket activation supported (see below)

[Install]
WantedBy=default.target
```

**Socket activation:** systemd creates `/run/sentinel-broker/broker.sock` before
broker starts. Broker inherits the socket fd (SD_LISTEN_FDS protocol). This means
the broker can be socket-activated: first agent connection wakes it up.

**Rationale:** Matches how `agent-vault-auth.sh` already runs (workstation-side).
Avoids adding an SSH hop to get a token from iac-control. Works for the common
case where the operator runs Claude Code on the workstation.

### 6.2 iac-control daemon

Alternative: run the broker on `iac-control` (192.168.12.210) accessible over
SSH or mTLS. All agent sessions SSH to iac-control to reach OKD; they could
also call the broker there.

**Disadvantage:** Adds network hop + auth complexity. Requires agents that run
on the workstation to SSH out for each token request. Not recommended for Phase 2.

### 6.3 Per-agent sidecar

A separate broker process per agent session, started by `agent-vault-auth.sh`.
The sidecar holds one root credential and issues capability tokens to the agent.

**Disadvantage:** Multiple broker processes, each with Vault root access. Defeats
the purpose (multiplies the attack surface). Not recommended.

**Decision for Phase 2:** Workstation systemd user service (§6.1).

---

## 7. Tool-Wrapping Requirements

Existing agents use Vault secrets directly via:

1. `vault kv get -field=<field> <path>` — reads a specific secret field
2. `VAULT_TOKEN=$(cat ...) vault kv get ...` — same with explicit token
3. `curl -H "Authorization: token $FORGEJO_TOKEN" ...` — Forgejo API calls

The broker introduces a new pattern: agents call `sentinel-broker get-token`
instead of `vault kv get` in the high-level flows. The existing `vault` CLI is
still used after the broker issues the token, so no changes to the Vault CLI.

### 7.1 Wrapper approach

Three wrapper scripts for the highest-frequency operations:

**`sentinel-plane-comment`** — wraps Plane API comment POST:
```bash
#!/usr/bin/env bash
# Acquires plane-comment capability token, posts comment, token expires
TOKEN=$(sentinel-broker get-token --capability plane-comment --ttl 5m)
PLANE_API_KEY=$(VAULT_TOKEN="$TOKEN" vault kv get -field=api_key secret/plane/api-key)
# ... rest of curl POST
```

**`sentinel-forgejo-push`** — wraps git push via HTTPS with token:
```bash
#!/usr/bin/env bash
TOKEN=$(sentinel-broker get-token --capability forgejo-push --ttl 10m)
FORGEJO_TOKEN=$(VAULT_TOKEN="$TOKEN" vault kv get -field=api_token secret/forgejo-worker)
git push "https://sentinel-worker:${FORGEJO_TOKEN}@forgejo.208.haist.farm/..."
```

**`sentinel-forgejo-pr`** — wraps PR creation + reviewer assignment.

These wrappers live in `claude-config/scripts/` (following precedent of
`agent-vault-auth.sh`) and are called by agents instead of raw `vault kv get`.

### 7.2 Migration path

Phase 2 (build broker + update policies):
- `agent-vault-auth.sh` continues to work unchanged (backward compatible)
- New `sentinel-broker` binary installed on workstation + iac-control
- Wrappers added to `claude-config/scripts/`

Phase 3 (migrate agent definitions):
- Agent role definitions (`claude-config/agents/*.md`) updated to call wrappers
- `agent-vault-auth.sh` demoted to "session bootstrap only" (gets only a
  `vault-inspect-self` capability, not the full role policy)

Phase 4 (harden):
- Vault role policies narrowed: `agent-worker` policy restricted to
  `auth/token/lookup-self` only (broker handles all other secret reads)
- Session tokens become truly minimal

---

## 8. SPIFFE/Workload-Attestation Extension Point

The Phase 2 broker uses SO_PEERCRED (Unix UID → username → allowlist). This is
correct but relies on OS-level user separation, which requires `sentinel-*` Unix
users to be provisioned and agents to run as those users — not the current
workstation pattern.

SPIFFE/SPIRE provides a stronger attestation: the broker issues a token only to
a process whose SVID (SPIFFE Verifiable Identity Document) matches an expected
SPIFFE ID. The agent doesn't need to run as a specific Unix user; instead SPIRE
attests the process by workload selectors (binary hash, container label, etc.).

### 8.1 Extension point in the broker

The broker's identity resolution is abstracted behind an `Attestor` interface:

```python
class Attestor(Protocol):
    def attest(self, conn: socket.socket) -> AgentIdentity:
        """Given a connected socket, return the agent's identity."""
        ...
```

Phase 2 implements `PeerCredAttestor` (SO_PEERCRED). Phase 3+ adds
`SpiffeAttestor` (SPIRE Workload API via `/run/spire-agent/agent.sock`).

The broker config selects the attestor:

```toml
[attestor]
type = "peer-cred"   # or "spiffe" for SPIRE-enabled hosts

[attestor.spiffe]
socket = "/run/spire-agent/agent.sock"
trust_domain = "agents.haist.farm"
```

### 8.2 SPIFFE ID → allowlist mapping

When SPIRE is the attestor, the agent identity is its SPIFFE ID:

```
spiffe://agents.haist.farm/sentinel/worker
```

The allowlist maps SPIFFE IDs to capabilities using the same TOML structure:

```toml
[identity."spiffe://agents.haist.farm/sentinel/worker"]
capabilities = ["plane-comment", "forgejo-push", "proxmox-audit", "vault-inspect-self"]
```

This is a strict superset of the peer-cred approach — same logic, stronger identity.

### 8.3 Dual-attestor during migration

During the SPIRE rollout period, the broker can run both attestors:
- If the connecting socket has a valid SPIRE SVID → use SPIFFE identity
- If not (SPIRE agent not present) → fall back to peer-cred identity

Same dual-path pattern as `agent-vault-auth.sh`'s `SENTINEL_AUTH_BACKEND=spire`
mode (tries SPIRE, falls back to Keycloak).

---

## 9. Implementation Issues for Phase 2+

The following Plane issues should be filed to implement this design:

### Phase 2 — Build the broker

| Issue title | Scope | Estimated effort |
|-------------|-------|-----------------|
| Build `sentinel-broker` daemon (Unix socket, peer-cred attestor, allowlist engine) | sentinel-iac: new Python or Go service | 2-3 days |
| Write Vault policy + token role for each capability scope | sentinel-iac: Ansible playbook extension | 0.5 day |
| Write `sentinel-plane-comment`, `sentinel-forgejo-push`, `sentinel-forgejo-pr` wrapper scripts | claude-config: scripts/ | 1 day |
| Deploy broker as systemd user service on workstation (Ansible role) | sentinel-iac: ansible/roles/sentinel-broker | 1 day |
| Add broker audit log to rsyslog forward chain | sentinel-iac: existing rsyslog role | 0.5 day |

### Phase 3 — Migrate agent definitions

| Issue title | Scope |
|-------------|-------|
| Update `agent-vault-auth.sh` to bootstrap session token with lookup-self only | claude-config: scripts/ |
| Update worker/judge/planner/scribe agent definitions to call wrappers | claude-config: agents/*.md |
| Narrow `agent-worker`/`agent-judge`/etc. Vault policies to `auth/token/lookup-self` only | sentinel-iac: Ansible |

### Phase 4 — SPIRE attestation

| Issue title | Scope |
|-------------|-------|
| Add `SpiffeAttestor` to broker (SPIRE Workload API, dual-path) | sentinel-iac: broker codebase |
| Deploy sentinel-* Unix users + SPIRE workload entries on iac-control | sentinel-iac: Ansible |
| Test SPIRE attestation path end-to-end on iac-control | sentinel-iac |

---

## 10. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Broker becomes SPOF — all agents blocked if it crashes | Medium | High | systemd Restart=on-failure; socket activation means first request restarts it; fall back to `agent-vault-auth.sh` session token during outage |
| Capability scope too narrow — agent can't complete task | Medium | Medium | Allowlist changes require operator approval (PR to sentinel-iac); start with conservative-but-sufficient scopes above |
| SO_PEERCRED bypassed via UID impersonation | Low | High | Requires root on workstation; defense-in-depth only; SPIRE attestation (Phase 4) addresses this |
| Token cache file readable by other users | Low | Medium | Temp tokens written to `/run/sentinel-broker/<pid>/token` (mode 0600, agent-owned); deleted after use |
| Rate limit blocks legitimate agent under high load | Low | Medium | 60 req/min is generous for single-agent sessions; adjustable in config |

---

## 11. What This Design Does NOT Address

- **Lead session pattern (claude-automation token):** Lead sessions run as the
  operator user and currently hold the `claude-automation` policy token. Full
  broker integration for lead sessions is Phase 3+. Phase 2 targets daemon-mode
  worker/judge agents only.
- **OKD workloads:** Pods in OKD use the Kubernetes auth method, not the broker.
  This is a separate trust domain.
- **Cross-host broker:** Phase 2 broker runs only on the workstation. iac-control
  agents that need tokens will continue to use `agent-vault-auth.sh` until Phase
  3 adds broker deployment to iac-control.
- **Secret rotation:** The broker doesn't change how secrets are stored in Vault
  or how Forgejo tokens are rotated. Rotation cadence is a separate concern
  (tracked in OPS-346 and related issues).

---

## Appendix A: Relevant Existing Infrastructure

| Component | Location | Tracking |
|-----------|----------|---------|
| `agent-vault-auth.sh` | `claude-config/scripts/` | OPS-347, OPS-545, OPS-630 |
| `agent-worker` Vault policy | Vault: `agent-worker` | OPS-345 Phase 3 |
| `auth/jwt/` Vault mount | Vault: Keycloak JWT auth | OPS-345 |
| `auth/jwt-spire/` Vault mount | Vault: SPIRE JWT-SVID auth | OPS-536 |
| SPIRE Agent on iac-control | `192.168.12.210` | OPS-545 |
| `worker-workspace-isolation.md` | `sentinel-iac/docs/agents/` | OPS-862, OPS-881 |
| `token-permission-matrix.md` | `sentinel-iac/docs/agents/` | OPS-437 |

## Appendix B: NIST 800-53 Alignment

| Control | How this design supports it |
|---------|----------------------------|
| AC-3 | Capability allowlist enforces deny-by-default access to Vault secrets |
| AC-5 | Broker separates credential issuance (broker) from credential use (agent) |
| AC-6 | Per-task tokens grant only the minimum privilege needed for that operation |
| IA-5(13) | Short token TTLs limit credential lifetime to task duration |
| AU-12 | Broker audit log records every token issuance with accessor for Vault correlation |
| CM-5 | All capability scope changes require IaC PR (allowlist.toml in sentinel-iac) |
