# Forgejo Token Permission Matrix — sentinel-admin org

**Last audited:** 2026-05-29 (OPS-437)
**Audit method:** Live Forgejo API via `/api/v1/repos/{repo}` (permissions object) and
`/api/v1/repos/{repo}/collaborators/{user}/permission`

---

## Token Roles

| Token | Vault path | Forgejo user | Role |
|-------|-----------|--------------|------|
| `FORGEJO_WORKER_TOKEN` | `secret/forgejo-worker.api_token` | `sentinel-worker` | Push branches, open PRs; **no merge** |
| `FORGEJO_JUDGE_TOKEN` | `secret/forgejo-judge.api_token` | `sentinel-judge` | Review (APPROVED/REQUEST_CHANGES), merge; **no admin** |
| `FORGEJO_ADMIN_TOKEN` | `secret/forgejo/vault-autogen-bot.token` | `koiakoia` (vault-autogen-bot) | Break-glass, add collaborators, requested_reviewers POST |

---

## Permission Matrix — sentinel-admin repos

Legend: `W` = write/push, `-` = no access, `(private)` = repo is private; no access is correct for these roles.

| Repo | sentinel-worker | sentinel-judge | Notes |
|------|----------------|----------------|-------|
| sentinel-admin/backstage | W | W | |
| sentinel-admin/cfwc-website | W | W | CFWC community website |
| sentinel-admin/claude-code-source | (private) | (private) | Internal tooling source; agents do not need direct push |
| sentinel-admin/claude-config | W | W | Agent automation configs |
| sentinel-admin/claude-memory | (private) | (private) | Memory files; not worker-operated |
| sentinel-admin/compliance-vault | W | W | Compliance docs |
| sentinel-admin/haists-website | W | W | |
| sentinel-admin/overwatch | W | W | Primary platform repo |
| sentinel-admin/overwatch-console | W | W | |
| sentinel-admin/overwatch-gitops | W | W | ArgoCD manifests |
| sentinel-admin/overwatch-harness | W | W | |
| sentinel-admin/overwatch-showcase | - | - | Frozen snapshot artifacts; workers do not operate here |
| sentinel-admin/plane-live-custom | - | - | SEC-59 build artifact; not a worker target |
| sentinel-admin/sentinel-cache | (private) | (private) | Cache/state files; not worker-operated |
| sentinel-admin/sentinel-iac | W | W | IaC (Terraform, Ansible, docs) |
| sentinel-admin/sentinel-sigma-rules | W | W | |
| sentinel-admin/sentinel-unifi | W | W | |
| sentinel-admin/wabash-ai | W | W | wabash.ai community site |

---

## Invariants

1. `sentinel-worker` has push permission on every repo where agents open PRs.
2. `sentinel-judge` has push permission on every repo where worker tokens push branches (required for merge).
3. Neither `sentinel-worker` nor `sentinel-judge` has admin permission on any repo.
4. Private repos that agents do not operate on (`claude-code-source`, `claude-memory`, `sentinel-cache`) correctly have no access — do not add collaborators without operator authorization.
5. `overwatch-showcase` and `plane-live-custom` are intentionally excluded; adding worker/judge would be out of scope.

---

## History

| Date | Event |
|------|-------|
| 2026-05-08 | OPS-437 filed: sentinel-worker had push=false on sentinel-admin/overwatch (gap discovered during OPS-436 rebase sweep) |
| 2026-05-08 to 2026-05-29 | overwatch push permission corrected (exact session not recorded) |
| 2026-05-29 | Full audit per OPS-437; all 13 active repos confirmed push=True; sentinel-judge added to wabash-ai (was missing); this matrix created |

---

## Re-auditing

To re-audit sentinel-worker push state against all repos, run as any token with read access:

```bash
FORGEJO_TOKEN=<worker-or-admin-token>
FORGEJO_HOST=forgejo.208.haist.farm

for REPO in backstage cfwc-website claude-config compliance-vault haists-website \
    overwatch overwatch-console overwatch-gitops overwatch-harness \
    sentinel-iac sentinel-sigma-rules sentinel-unifi wabash-ai; do
  PUSH=$(curl -s -H "Authorization: token ${FORGEJO_TOKEN}" \
    "https://${FORGEJO_HOST}/api/v1/repos/sentinel-admin/${REPO}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('permissions',{}).get('push','N/A'))")
  echo "  sentinel-admin/${REPO}: push=${PUSH}"
done
```

To add a collaborator (requires admin token):

```bash
curl -s --request PUT \
  --header "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{"permission": "write"}' \
  "https://${FORGEJO_HOST}/api/v1/repos/sentinel-admin/<REPO>/collaborators/sentinel-worker"
```
