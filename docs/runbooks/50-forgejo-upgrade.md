# Runbook 50 — Forgejo Upgrade Procedure (14.0.5 → 15.0.2)

**Issue:** OPS-861
**Criticality:** HIGH — Forgejo is the platform's code forge, CI orchestrator, and container registry. All CI/CD pipelines depend on it. Downtime blocks all merges and deployments.
**Authored:** 2026-05-23 by worker-ops-861-forgejo-upgrade-research
**Related:** OPS-271 (Actions log API SSH workaround), OPS-827 (Forgejo NFS backup — pending), OPS-583 (runner pool), OPS-779 (nginx TLS sidecar)

> **PLANNING DOCUMENT — DO NOT EXECUTE without operator approval and a scheduled maintenance window.**
> The actual upgrade happens in a follow-on issue after operator review of this plan.

---

## 0. Headline: Frame-Shift on OPS-271

**OPS-861 was filed under the premise that upgrading Forgejo would retire the OPS-271 SSH log-fetch workaround.** That premise is incorrect based on source verification this session.

| Claim | Status |
|-------|--------|
| Forgejo 14.x is EOL and must be upgraded | **TRUE** — EOL 30 April 2026; upgrade is urgent regardless |
| v15.0.2 restores `GET /api/v1/admin/actions/runners` (was 404) | **TRUE** — route confirmed in v15.0.2 `api.go` |
| v15.0.2 adds the log-fetch routes (`/actions/tasks/{id}/logs`, `/actions/runs/{id}/logs`, `/actions/runs/{id}/jobs`) | **FALSE** — routes still absent from v15.0.2 API router (source-verified at tag) |

**Practical consequence:** Upgrading to v15.0.2 is the right action — it resolves an EOL security liability and unblocks programmatic runner management. But **OPS-271 is not retired by this upgrade**. The SSH workaround (`scripts/fetch-actions-log.sh`) must remain active after the upgrade. OPS-271 should stay open until either:
- A future Forgejo release registers the log-fetch routes (no version identified yet), or
- An upstream contribution or alternative API approach is implemented.

**The upgrade rationale is EOL remediation** (14.x discontinued 30 April 2026), not OPS-271 retirement. OPS-271 retirement is deferred to a follow-on issue.

---

## 1. Current State

### 1a. Live Version

| Field | Value | Source |
|-------|-------|--------|
| Version string | `14.0.5+gitea-1.22.0` | `GET /api/v1/version` (probed 2026-05-23) |
| Host | `forgejo-server` · `192.168.12.70` | sentinel-iac `ansible/inventory/hosts.yml` |
| PVE host | pve4-alienware | inventory comment |
| EOL status | **DISCONTINUED** (EOL 30 April 2026) | forgejo.org/releases |

Forgejo 14.x is no longer receiving security patches. Running a discontinued release is an unacceptable security posture for a platform that handles all CI secrets, code review, and runner registration tokens.

### 1b. Deployment Architecture

Forgejo is deployed via **Docker Compose** on a VM/LXC at `192.168.12.70`, managed by the Ansible role `ansible/roles/forgejo-server/`.

**Compose services:**

| Service | Image | Role |
|---------|-------|------|
| `forgejo` | `codeberg.org/forgejo/forgejo:14` | Application server |
| `postgres` | `postgres:16-alpine` | Database |
| `nginx` | `nginx:alpine` | TLS-terminating sidecar (OPS-779) |

**Key paths (on forgejo-server host):**

| Path | Contents |
|------|----------|
| `/opt/forgejo/` | Compose root and TLS dir |
| `/opt/forgejo/data/` | Forgejo data volume (repos, LFS, attachments) |
| `/opt/forgejo/data/gitea/conf/app.ini` | Application config |
| `/opt/forgejo/data/gitea/data/actions_log/` | Raw Actions log files (zstd) |
| `/opt/forgejo/postgres/` | PostgreSQL data volume |
| `/opt/forgejo/backups/` | Local backup staging area |

**Ansible role:** `ansible/roles/forgejo-server/tasks/main.yml`
**Playbook:** `ansible/playbooks/forgejo-server.yml`

### 1c. Backup Posture

The `forgejo-backup` systemd timer runs daily:

1. **PostgreSQL dump** via `docker exec forgejo-postgres pg_dump` → `/opt/forgejo/backups/db-TIMESTAMP.sql`
2. **Data directory tar** (`/opt/forgejo/data/`) → `/opt/forgejo/backups/data-TIMESTAMP.tar.gz`
3. **MinIO upload** to `http://192.168.12.58:9000/forgejo-backups/` (non-fatal if unreachable)
4. **Retention:** last 7 pairs kept locally

**Gap (per `feedback_backup_separate_hardware.md`):** MinIO at `192.168.12.58` may be on the same PVE host as the forgejo-server VM. Separate-hardware backup to TrueNAS NFS (`192.168.12.205`) is tracked in **OPS-827** and is NOT yet implemented.

**Pre-upgrade requirement:** Operator must take a PVE VM snapshot via the Proxmox UI or API before the upgrade begins. This is the only guaranteed point-in-time consistent backup when PostgreSQL + data volume must be coherent.

### 1d. Runner Fleet

Six runner LXCs on `pve4-alienware` (VMIDs 210–215), each running `forgejo-runner` binary v12.10.0. Managed by `ansible/roles/forgejo-runner-pool/`. Runner instance URLs point directly to `http://192.168.12.70:3000` (bypasses Pangolin proxy — OPS-773/774).

### 1e. Actions API Status (Current)

The following endpoints return **HTTP 404 (plain-text "404 page not found")** on Forgejo 14.0.5 — these routes are absent from the API router:

| Endpoint | Status on 14.0.5 | Source |
|----------|-----------------|--------|
| `GET /api/v1/repos/{owner}/{repo}/actions/tasks/{id}/logs` | 404 | Live probe 2026-05-23 (task ID 26773) |
| `GET /api/v1/repos/{owner}/{repo}/actions/runs/{id}/logs` | 404 | Live probe 2026-05-23 |
| `GET /api/v1/repos/{owner}/{repo}/actions/runs/{id}/jobs` | 404 | Live probe 2026-05-23 |
| `GET /api/v1/repos/{owner}/{repo}/actions/runs/{id}/artifacts` | 404 | OPS-271 investigation |
| `GET /api/v1/repos/{owner}/{repo}/actions/jobs/{id}/logs` | 404 | OPS-271 investigation |
| `GET /api/v1/admin/runners` | 404 | OPS-271 investigation |

OPS-271 (merged PR #387) ships `scripts/fetch-actions-log.sh` as an SSH-based workaround that reads `.log.zst` files directly from `/opt/forgejo/data/gitea/data/actions_log/`.

---

## 2. Target State

### 2a. Recommended Target Version

**Target: Forgejo v15.0.2** (released 2026-05-12)

| Property | Value | Source |
|----------|-------|--------|
| Version | `v15.0.2` | code.forgejo.org API |
| Release date | 2026-05-12 | code.forgejo.org releases API |
| LTS support end | 2027-07-15 | forgejo.org/releases/ |
| Binary SHA256 (linux-amd64) | `d0e6f83ec24bc84eba90fdab48ad08b16f61e6b1e5095bf8483be849d860fdc8` | [code.forgejo.org download](https://code.forgejo.org/forgejo/forgejo/releases/download/v15.0.2/forgejo-15.0.2-linux-amd64.sha256) |
| Docker image tag | `codeberg.org/forgejo/forgejo:15.0.2` | Forgejo container registry |
| v15.0.0 release notes | [codeberg.org/forgejo/forgejo release-notes-published/15.0.0.md](https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/release-notes-published/15.0.0.md) | codeberg.org |
| v15.0.2 release notes | [codeberg.org/forgejo/forgejo release-notes-published/15.0.2.md](https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/release-notes-published/15.0.2.md) | codeberg.org |
| v15 announcement | [forgejo.org/2026-04-release-v15-0/](https://forgejo.org/2026-04-release-v15-0/) | forgejo.org |

**Why v15.0.2:**
- Forgejo 14.x is EOL (30 April 2026); v15.0.2 is the only current LTS (v11.x expires 2026-07-16).
- v15.0.2 includes security fixes from v15.0.0 base plus PR #12494 (OAuth validation hardening, LFS token scope, Actions Artifact V4 signature strengthening).
- No v16.x release exists yet (scheduled 2026-07-16 per release table in announcement).

### 2b. Actions API Changes in v15.0.2

**Source-verified** against `routers/api/v1/api.go` at tag `v15.0.2` on codeberg.org (file length: 69,680 chars, actions group at line 1235).

| Endpoint | v14.0.5 | v15.0.2 | Notes |
|----------|---------|---------|-------|
| `GET /api/v1/admin/actions/runners` | 404 | **200** | New: runner management API (PR #10677) |
| `POST /api/v1/admin/actions/runners` | 404 | **200** | New: ephemeral runner registration (PR #9962) |
| `GET /api/v1/admin/actions/runners/{id}` | 404 | **200** | New |
| `DELETE /api/v1/admin/actions/runners/{id}` | 404 | **200** | New |
| `GET /api/v1/admin/actions/runners/jobs` | 404 | **200** | New |
| `GET /api/v1/repos/{owner}/{repo}/actions/tasks/{id}/logs` | 404 | **404** | Still absent from router |
| `GET /api/v1/repos/{owner}/{repo}/actions/runs/{id}/logs` | 404 | **404** | Still absent from router |
| `GET /api/v1/repos/{owner}/{repo}/actions/runs/{id}/jobs` | 404 | **404** | Still absent from router |

**Critical finding:** The specific log-fetch routes motivating OPS-271 are **still not registered in v15.0.2**. The SSH workaround in `scripts/fetch-actions-log.sh` must remain in service post-upgrade. The upgrade resolves the `/admin/runners` 404 gap and unblocks programmatic runner management, but **does not retire the OPS-271 SSH log workaround**.

### 2c. Post-Upgrade Verification Commands

```bash
# Version check (should show 15.0.2)
curl -s -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  https://forgejo.208.haist.farm/api/v1/version

# Admin runners API (should now be 200)
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  https://forgejo.208.haist.farm/api/v1/admin/actions/runners

# Task log route (still expected 404 in v15)
TASK_ID=$(curl -s -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  "https://forgejo.208.haist.farm/api/v1/repos/sentinel-admin/sentinel-iac/actions/tasks?limit=1" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['workflow_runs'][0]['id'])")
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  "https://forgejo.208.haist.farm/api/v1/repos/sentinel-admin/sentinel-iac/actions/tasks/${TASK_ID}/logs"
```

---

## 3. Breaking Changes Survey (14.0.5 → 15.0.2)

This upgrade spans one major version (14 → 15). Per Forgejo semantic versioning, breaking changes occur only on major-version bumps.

**Sources consulted:**
- v15.0.0 full notes: https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/release-notes-published/15.0.0.md
- v15.0.2 patch notes: https://codeberg.org/forgejo/forgejo/raw/branch/forgejo/release-notes-published/15.0.2.md
- v15.0 announcement: https://forgejo.org/2026-04-release-v15-0/

### BC-1: Cookie Names Changed — IMPACTS ALL USERS

**Source:** PR #10645 in v15.0.0 release notes ("Make cookie names brand independent").
**Description:** The `COOKIE_REMEMBER_NAME` default changed from `gitea_incredible` to a new Forgejo-branded value. All users will be **forced to re-login** after upgrade unless the old cookie name is preserved.

**Impact on this deployment:** HIGH occurrence / LOW severity. The Forgejo instance uses Authentik/Keycloak OIDC for login. Users will see one re-login prompt post-upgrade.

**Mitigation:**
- **Option A (Recommended):** Accept the re-login. No config change needed. Users authenticate once via OIDC.
- **Option B (Zero-disruption):** Add to `[security]` section of `app.ini.j2` before upgrade:
  ```ini
  COOKIE_REMEMBER_NAME = gitea_incredible
  ```
  Current `templates/app.ini.j2` does NOT set this field — if Option B is chosen, the template must be updated and the playbook re-run before the container is upgraded.

### BC-2: Docker Rootless Config File Location Change

**Source:** PR #11098 in v15.0.0 release notes.
**Description:** Backward-compat shim for `/etc/gitea/app.ini` removed; new location is `/var/lib/gitea/custom/conf/app.ini` for rootless images.

**Impact on this deployment:** NONE. The deployment uses the **standard (non-rootless)** Docker image with config mounted at `/opt/forgejo/data/gitea/conf/app.ini` via the `/data:/data` volume. The `/etc/gitea` path is not used.

### BC-3: API Access Token Scope Enforcement — IMPACTS AUTOMATION TOKENS

**Source:** PRs #11468, #11736, #11457, #11458, #11437 in v15.0.0 release notes.
**Description:**
- Admin-level permissions removed from repo-specific and public-only access tokens.
- `POST /repos/{template_owner}/{template_repo}/generate` and `DELETE /repos/{username}/{reponame}` now require `write:user` or `write:organization` scope.
- APIs returning 403 for private repos with public-only tokens now return 404 (consistent with general permission-check behaviour).
- `/user/repos`, `/users/{username}/repos`, `/orgs/{org}/repos`, `/teams/{id}/repos` no longer return private repos for public-only tokens.

**Impact on this deployment:** MEDIUM. `sentinel-worker` and `sentinel-judge` are full-access tokens (not public-only), so most changes don't apply. The 403→404 behaviour change is safe for agent workflows. However, any CI step that creates/deletes repositories via template should be audited for scope requirements.

**Action:** After upgrade, verify full CI pipeline (security-scan.yml) completes without new 403/404 errors.

### BC-4: CO_COMMITTER_TRAILERS Removed

**Source:** PR #11096 in v15.0.0 release notes.
**Description:** `repository.pull-request.ADD_CO_COMMITTER_TRAILERS` option removed; was injecting redundant `Co-authored-by:` / `Co-committed-by:` trailers into squash merges.

**Impact on this deployment:** NONE. `app.ini.j2` does not set this option. The implicit default (was enabled) is now gone — squash merges will simply not inject these trailers, which is the correct behaviour.

### BC-5: SSH authorized_keys Validation on Startup

**Source:** PR #10010 (in v14.0.0 — already in our current version).
**Impact on this deployment:** ALREADY PRESENT — no action needed for v15 upgrade.

### BC-6: Runner Registration Token API Deprecated

**Source:** PR #11650 in v15.0.0 release notes.
**Description:** `/admin/actions/runners/registration-token` endpoint deprecated (still present). New flow uses `POST /api/v1/admin/actions/runners` or web UI form.

**Impact on this deployment:** LOW. The runner-pool Ansible role uses Vault-stored tokens (registered manually, stored at `secret/forgejo-runner/pve4-N`). The registration endpoints are not called in regular playbook runs. No immediate change required.

---

## 4. Upgrade Procedure

### 4a. Pre-Flight Checklist

```
[ ] Announce maintenance window (target: off-peak, e.g., 02:00–04:00 local)
[ ] Verify current backup timestamp:
    ssh ubuntu@192.168.12.70 "ls -lt /opt/forgejo/backups/ | head -6"
[ ] Run forgejo-backup now for a fresh backup:
    ssh ubuntu@192.168.12.70 "sudo systemctl start forgejo-backup.service && sleep 5 && journalctl -u forgejo-backup -n 20"
[ ] Take PVE VM snapshot (THE critical safety net):
    # On pve4-alienware:
    qm snapshot <VMID> pre-forgejo-upgrade-ops861 --description "OPS-861 pre-upgrade"
    # VMID: identify from PVE web UI (forgejo-server LXC/VM on pve4)
[ ] Confirm runner fleet idle (no active jobs):
    curl -s -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
      "https://forgejo.208.haist.farm/api/v1/repos/sentinel-admin/sentinel-iac/actions/tasks?limit=5" | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print('Statuses:', [r['status'] for r in d['workflow_runs']])"
    # All must be: success, failure, cancelled (not queued/running)
[ ] Decide on BC-1 mitigation (cookie name — see §3):
    Option A: accept re-login (default, no change)
    Option B: update app.ini.j2 with COOKIE_REMEMBER_NAME = gitea_incredible before running
[ ] Update Ansible defaults:
    ansible/roles/forgejo-server/defaults/main.yml:
      forgejo_image: "codeberg.org/forgejo/forgejo:15.0.2"
```

### 4b. Estimated Downtime

| Phase | Duration |
|-------|----------|
| `docker compose pull` (image pre-pull, before stop) | 2–5 min |
| `docker compose stop forgejo nginx` | 10 sec |
| Queue flush | 30–60 sec |
| `docker compose up -d` + DB migration | 1–3 min |
| Health probe + smoke test | 2–5 min |
| **Total window** | **~7–12 min** |

PostgreSQL schema migration runs automatically on container startup. For v14→v15 it is lightweight (no full-table rewrites documented in release notes).

### 4c. Execution Steps

**Step 1 — Pre-pull image (before maintenance window, no downtime):**
```bash
ssh ubuntu@192.168.12.70
cd /opt/forgejo
# Update docker-compose.yml image tag to 15.0.2
sudo docker compose pull forgejo
```

**Step 2 — Enter maintenance window and flush queues:**
```bash
ssh ubuntu@192.168.12.70
cd /opt/forgejo
sudo docker exec forgejo forgejo manager flush-queues
# Wait for confirmation, then:
sudo docker compose stop forgejo nginx
```

**Step 3 — Start updated containers:**

Via Ansible (preferred — ensures all templates re-rendered):
```bash
# From iac-control or workstation:
ansible-playbook ansible/playbooks/forgejo-server.yml --tags forgejo
```

Via manual compose (break-glass):
```bash
ssh ubuntu@192.168.12.70
cd /opt/forgejo
sudo docker compose up -d
```

**Step 4 — Monitor startup:**
```bash
sudo docker compose logs -f forgejo 2>&1 | grep -E "(Started|Error|WARN|migration|FATAL|Listen)"
# Success: "Listen: http://0.0.0.0:3000"
# Failure: "FATAL" — stop and rollback per §4e
```

**Step 5 — Health and version check:**
```bash
curl -s http://192.168.12.70:3000/api/healthz
# Expected: {"status":"pass"}

curl -s -H "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  https://forgejo.208.haist.farm/api/v1/version
# Expected: {"version":"15.0.2"}
```

**Step 6 — Trigger CI run and verify:**
Push a commit to `sentinel-iac` main or open a trivial PR. Wait for CI to complete. This validates runner connectivity, artifact uploads, and OIDC token flows.

### 4d. Verification Matrix

| Check | Expected | Command |
|-------|----------|---------|
| Version | `{"version":"15.0.2"}` | `GET /api/v1/version` |
| Health | `{"status":"pass"}` | `GET /api/healthz` |
| Admin runners API | HTTP 200 | `GET /api/v1/admin/actions/runners` |
| Task log API (still absent) | HTTP 404 | `GET /api/v1/repos/.../actions/tasks/{id}/logs` |
| Full CI pipeline | All jobs green | Push commit, check Actions tab |
| SSH log workaround | Log output | `./scripts/fetch-actions-log.sh {TASK_ID}` |
| OIDC login | Dashboard loads | Operator browser test (Authentik or Keycloak button) |
| No FATAL in logs | Clean startup | `docker compose logs forgejo \| grep FATAL` |

### 4e. Rollback Procedure

**Trigger:** FATAL on startup, migration error, CI pipelines broken after upgrade.

**Option 1 — PVE snapshot rollback (RTO: ~5 min, zero data loss):**
```bash
# On pve4-alienware (Proxmox CLI or web UI):
qm rollback <VMID> pre-forgejo-upgrade-ops861
# Start the VM, then verify: docker compose up -d (uses v14 compose file from snapshot)
```

**Option 2 — Manual restore from backup (RTO: ~15 min, risk: up to 24h of commits lost):**
```bash
ssh ubuntu@192.168.12.70
cd /opt/forgejo
sudo docker compose down
# Update docker-compose.yml back to forgejo:14
sudo docker exec -i forgejo-postgres psql -U forgejo forgejo < /opt/forgejo/backups/db-LATEST.sql
sudo tar xzf /opt/forgejo/backups/data-LATEST.tar.gz -C /opt/forgejo
sudo docker compose up -d
# Verify: curl -s https://forgejo.208.haist.farm/api/v1/version
```

---

## 5. Runner Fleet Compatibility

### 5a. Version Matrix

| Component | Current | Latest | Forgejo v15 compatible |
|-----------|---------|--------|------------------------|
| `forgejo` server | 14.0.5 | **15.0.2** (target) | — |
| `forgejo-runner` | 12.10.0 | 12.10.1 | YES (12.x fully compatible) |
| Runner OIDC tokens | N/A | Requires runner ≥ 12.5.0 | YES (12.10.0 > 12.5.0) |

**Source:** v15.0 announcement notes OIDC token support requires "Forgejo Runner (>v12.5.0)". Current fleet is at v12.10.0. No protocol-breaking change between runner 12.x and Forgejo 15.x is documented in the v15.0.0 release notes.

**Recommendation:** No runner upgrade is required for the Forgejo version upgrade. Recommend tracking runner 12.10.0 → 12.10.1 in a follow-on low-priority issue (minor fix release, 2026-05-05).

### 5b. Runner Registration Post-Upgrade

Existing runner registrations (`.runner` config files on each LXC, tokens in Vault at `secret/forgejo-runner/pve4-N`) remain valid across upgrades. No re-registration needed unless `.runner` files are lost.

**New in v15:** `POST /api/v1/admin/actions/runners` enables programmatic ephemeral runner registration. Not required for the existing fleet but enables future automation.

---

## 6. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| PostgreSQL schema migration fails at startup | LOW | HIGH | Pre-upgrade PVE snapshot; rollback RTO ~5 min |
| OIDC login broken post-upgrade (session change) | LOW | HIGH | Operator browser test required; rollback available |
| API token scope changes break CI automation | MEDIUM | MEDIUM | Full CI run post-upgrade; audit 403/404 responses |
| Cookie name change forces re-login | HIGH | LOW | Known/expected; accept or set COOKIE_REMEMBER_NAME |
| Artifact upload path broken (nginx sidecar) | LOW | HIGH | nginx config unchanged; verified by CI run with artifact |
| Actions queue deserialization on startup | LOW | HIGH | Pre-stop queue flush (`forgejo manager flush-queues`) |
| MinIO backup unavailable during upgrade | LOW | LOW | PVE snapshot is primary safety net; MinIO is secondary |
| Runner tokens invalidated | VERY LOW | MEDIUM | Forgejo does not invalidate runner tokens on upgrade |
| Log file format incompatible (zstd) | LOW | LOW | SSH workaround reads runner-generated files; format unchanged |

**Primary data-loss scenario:** Mid-migration abort with partial DB schema change. Mitigated entirely by PVE snapshot pre-upgrade.

---

## 7. Integration Risk Details

### 7a. Authentik/Keycloak OIDC

OIDC discovery URLs and client credentials in `app.ini` are unchanged. The upgrade does not modify OIDC config. However, v15 changes session cookie assignment (session cookie now set only for logged-in users). Recommend operator browser login test immediately post-upgrade to confirm OIDC redirect and token exchange still work.

### 7b. Vault / ESO / Automation Tokens

`sentinel-worker`, `sentinel-judge`, and `sentinel-admin` tokens stored in Vault are not affected by the upgrade. Token format and API endpoint paths are unchanged (save for the admin/runners URL restructuring which adds new paths rather than removing old ones).

### 7c. ArgoCD Repo Sync

ArgoCD syncs from Forgejo via `sentinel-admin` credentials over git/SSH or HTTPS. Full-access admin tokens are not subject to the v15 public-only/repo-specific token scope changes. ArgoCD sync should be unaffected.

### 7d. nginx TLS Sidecar (OPS-779)

The nginx sidecar at `:443` proxying to Forgejo `:3000` is external to the Forgejo container and entirely unchanged by the upgrade. `LOCAL_ROOT_URL = http://forgejo.208.haist.farm:3000/` in `app.ini` remains correct.

### 7e. Actions Mirrors (OPS-251)

Forgejo mirrors `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` from `code.forgejo.org`. Mirror protocol is not affected by the upgrade. The `tasks/action-mirrors.yml` task runs idempotently on each playbook execution.

---

## 8. Acceptance Criteria

The upgrade is accepted when ALL of the following are satisfied:

```
[ ] GET /api/v1/version returns {"version":"15.0.2"}
[ ] GET /api/v1/admin/actions/runners returns HTTP 200
[ ] GET /api/healthz returns {"status":"pass"}
[ ] Full CI pipeline (security-scan.yml) completes successfully on a push to main
[ ] Operator confirms OIDC login works via browser (Authentik or Keycloak button)
[ ] scripts/fetch-actions-log.sh {TASK_ID} returns log output
     (SSH workaround intact post-upgrade)
[ ] No FATAL entries in docker logs since container start
[ ] AGENT-STATE.md updated on upgrade-execution branch
```

**OPS-271 retirement condition:** The SSH log workaround is NOT retired by this upgrade. OPS-271 should remain open until a future Forgejo release registers the log-fetch API routes. Re-test the route after upgrade to confirm status (still 404) and update OPS-271 comments accordingly.

---

## 9. Ansible Implementation Notes

The upgrade requires this change to IaC (tracked in the upgrade-execution follow-on issue):

**`ansible/roles/forgejo-server/defaults/main.yml`:**
```yaml
# Before:
forgejo_image: "codeberg.org/forgejo/forgejo:14"
# After:
forgejo_image: "codeberg.org/forgejo/forgejo:15.0.2"
```

Optional BC-1 mitigation — **`ansible/roles/forgejo-server/templates/app.ini.j2`** (add to `[security]` section):
```ini
COOKIE_REMEMBER_NAME = gitea_incredible
```

No other Ansible role changes are required. The existing role structure (Docker Compose, PostgreSQL 16, nginx sidecar, backup timer) is compatible with Forgejo v15.0.2.

---

## 10. Related Issues

| Issue | Status | Relationship |
|-------|--------|--------------|
| OPS-271 | Open (workaround merged) | SSH log-fetch workaround; NOT retired by this upgrade |
| OPS-827 | Open | Forgejo NFS backup to TrueNAS; should be resolved before upgrade |
| OPS-583/OPS-762 | Closed | Runner pool; runners compatible with v15 |
| OPS-779 | Closed | nginx TLS sidecar; unchanged by upgrade |
| OPS-871 | Open | Forgejo OIDC source cleanup (Keycloak removal); coordinate timing with upgrade |
