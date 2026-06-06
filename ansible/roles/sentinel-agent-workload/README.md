# sentinel-agent-workload

**Tracking issues:**
- [OPS-545](https://plane.208.haist.farm/) — OPS-351 Phase 4.5 (sentinel-worker, merged)
- [OPS-549](https://plane.208.haist.farm/) — OPS-351 Phase 4.6 (sentinel-{judge,planner,scribe} extension)

**Predecessors:** OPS-528, OPS-533, OPS-535, OPS-537, OPS-536, OPS-545 (all merged)
**Status:** Phase 4.6 ships all four roles (`worker`, `judge`, `planner`, `scribe`). Phase 4.7 will retire the Keycloak SA fallback and make the SPIRE path mandatory.

## Purpose

Provisions the **workload side** of the SPIRE migration: the Linux users,
shared supplementary group, host-side `spire-agent` CLI binary, and
sudoers entry that together let `agent-vault-auth.sh` mint a JWT-SVID and
exchange it at `vault auth/jwt-spire/login` for a scoped Vault token.

This role does **not** manage the SPIRE Agent itself (that's
`roles/iac-control/tasks/docker-services.yml` for iac-control and
`roles/workstation/tasks/spire-agent.yml` for workstation), and it does
**not** ship the `agent-vault-auth.sh` script (that lives in the
`claude-config` repo and is deployed separately).

## What it provisions

1. **Group `sentinel-agents` (PLURAL)** — GID 1500. Distinct from the
   pre-existing `sentinel-agent` (SINGULAR) GID 995, which is the SPIRE
   Agent container's own service account. A hard-guard fails loud if the
   singular's GID is ever found to differ from 995.
2. **Per-role Linux user** — for each role in `sentinel_workload_roles`, a
   user named `sentinel-<role>` with:
   - Primary group `sentinel-<role>` (same name)
   - Supplementary group `sentinel-agents` (matches the SPIRE workload
     entry's `unix:supplementary_group:sentinel-agents` selector)
   - Login shell `/usr/sbin/nologin` — no interactive login
   - Home `/var/lib/sentinel-<role>` (system-service convention)
   - Regular UID range (≥ 1500, +1 per role-index)
3. **`spire-agent` CLI host binary** — installs upstream 1.14.6 tarball
   to `/usr/local/bin/spire-agent` (sha256-pinned, mirrors PR #186's
   pattern). Skipped on hosts that already have the binary (workstation
   has it from OPS-533).
4. **Sudoers entry** — one fragment per role at
   `/etc/sudoers.d/sentinel-agent-workload-<role>`, granting
   `{{ ansible_user }}` NOPASSWD execution of
   `/usr/local/bin/agent-vault-auth.sh` as `sentinel-<role>` only. No
   other commands. `setenv` allowed so `VAULT_ADDR`, `VAULT_SKIP_VERIFY`,
   `VAULT_TOKEN`, `SESSION_ID` propagate.

## Why the user must be `sentinel-<role>` exactly

The SPIRE workload entries (registered in `roles/spire-workload-entries`
per OPS-535) use the Unix attestor selectors:

```
unix:user:sentinel-<role>
unix:supplementary_group:sentinel-agents
```

Both must match for SPIRE Agent to issue an SVID for the corresponding
SPIFFE ID. The selector check is via `SO_PEERCRED` on the Workload API
socket — the kernel reports the *connecting process*'s effective UID +
group membership. A typo in either name breaks attestation silently.

## Invocation

Added to `playbooks/iac-control.yml` and `playbooks/workstation.yml`.
Tag-gate the role with `--tags sentinel-agent-workload` to apply only
this role's tasks.

Sub-tags for finer control:

- `sentinel-workload-group` — group provisioning + hard guards
- `sentinel-workload-user` — per-role user provisioning
- `spire-agent-cli` — host-binary install
- `sentinel-workload-sudoers` — sudoers fragment(s)

## Phase 4.5 vs 4.6 vs 4.7

- **Phase 4.5 (OPS-545, merged):** worker role only; iac-control E2E proof.
- **Phase 4.6 (OPS-549, this PR):** extend `sentinel_workload_roles` to
  `[worker, judge, planner, scribe]`; per-role iac-control E2E proof.
- **Phase 4.7:** retire Keycloak SA path; the `agent-vault-auth.sh` SPIRE
  branch becomes mandatory rather than env-gated.

## Acceptance criteria for OPS-545 (Phase 4.5)

1. `id sentinel-worker` on iac-control returns the user with group
   `sentinel-agents` in its `groups` list.
2. `/usr/local/bin/spire-agent --version` on iac-control reports `1.14.6`
   on stderr.
3. Sudoers entry `/etc/sudoers.d/sentinel-agent-workload-worker` parses
   under `visudo -cf`.
4. 3-run Ansible apply produces `changed=0 failed=0` on the second and
   third runs (idempotency).
5. With `agent-vault-auth.sh` (the claude-config PR) in place at
   `/usr/local/bin/agent-vault-auth.sh`, `SENTINEL_AUTH_BACKEND=spire
   sudo -u sentinel-worker /usr/local/bin/agent-vault-auth.sh worker`
   returns a Vault token file path, and `/opt/vault/logs/audit.log`
   on the Vault host shows an entry with:
   - `.auth.display_name == "jwt-spire-spiffe://agents.haist.farm/sentinel/worker"`
   - `.auth.metadata.role == "sentinel-worker"`
   - `.auth.token_policies | contains(["agent-worker"])`

Acceptance for the workstation half is deferred to OPS-546 (workstation
SPIRE Agent crash-loop recovery) per Phase 4.5 D6 decision.

## NSS bind mode (OPS-549 architectural completion of OPS-528)

The iac-control SPIRE Agent container is distroless and ships with no
`/etc/passwd` or `/etc/group`. OPS-545 (Phase 4.5) introduced file-bind
mounts for both files so the Unix Workload Attestor's `user.LookupId(UID)`
and `group.LookupId(GID)` calls could resolve host usernames and group
memberships. That mode works for a one-shot bootstrap (worker created
before container start) but breaks the next user-add: glibc's
`useradd`/`groupadd` atomically rename a temp file over the target,
which changes the host inode, while the container's file-bind keeps
pointing to the original (now-orphaned) inode — silent attestation
failure for any post-start user add.

OPS-549 corrects this in `roles/iac-control/tasks/docker-services.yml`
by replacing the two file binds with a single directory bind
`/etc:/etc:ro`. A directory bind tracks dentry-tree lookups dynamically,
so atomic renames inside `/etc` are visible to the container
immediately, no restart needed. See the inline comment block on that
task for the conflict analysis (image-baked `/etc/spire`, distroless
`/etc/ssl/certs`, and Docker-managed `/etc/{hostname,hosts,resolv.conf}`
are all benignly shadowed).

Empirically verified during OPS-549 by adding a transient
`tx-bindtest` user on the host and observing the new entry appear in
the container's `/proc/$PID/root/etc/passwd` synchronously, with no
container restart and no Ansible re-apply.

(Workstation runs SPIRE Agent under systemd, not Docker, and is not
affected — host-mode systemd services share the host's `/etc` directly.)

## Acceptance criteria for OPS-549 (Phase 4.6)

1. `id sentinel-judge && id sentinel-planner && id sentinel-scribe` on
   iac-control each return the user with `sentinel-agents` in the
   supplementary group list.
2. 3-run Ansible apply: `N / 0 / 0` (idempotency preserved across the
   extended role-list).
3. Per-role SPIRE-only E2E test passes — for each of judge, planner,
   scribe:
   ```
   sudo -u sentinel-<role> env SENTINEL_AUTH_BACKEND=spire-only \
     /usr/local/bin/agent-vault-auth.sh <role>
   ```
   returns a Vault token file path.
4. `/opt/vault/logs/audit.log` on the Vault host shows a corresponding
   entry for each new role with:
   - `.auth.display_name == "jwt-spire-spiffe://agents.haist.farm/sentinel/<role>"`
   - `.auth.token_policies | contains(["agent-<role>"])`
5. Existing `sentinel-worker` E2E still passes (no regression on Phase 4.5).
6. Existing Keycloak path still works (default-path, no env var) for
   any role (no regression on OPS-347).
7. Workstation E2E remains deferred (OPS-546 unresolved).
