# Runbook 22 — Provision CI Secrets to Image-Build Repos

**Issue:** OPS-255  
**Scope:** Any `sentinel-admin` Forgejo repo that has image-build workflows requiring
Harbor push, cosign signing, and DefectDojo reporting.

---

## Background

When OPS-239 fixed missing CI secrets in `overwatch-gitops`, the secrets were
provisioned manually as a one-off. OPS-255 standardizes this as a repeatable
pattern so future repos do not suffer the same silent failure.

The standard CI secret set is derived from the two existing image-build repos
(`overwatch-console`, `overwatch-gitops`) and the shared composite actions in
`.forgejo/actions/{sign,attest,report}/`.

---

## Standard CI Secret Set

Every repo with an image-build workflow needs these five secrets:

| Secret Name | Vault Path | Vault Field | Purpose |
|---|---|---|---|
| `HARBOR_USERNAME` | `secret/harbor/robot` | `username` | Push images to Harbor registry |
| `HARBOR_PASSWORD` | `secret/harbor/robot` | `password` | Push images to Harbor registry |
| `COSIGN_KEY` | `secret/cosign` | `private_key` | Sign images with platform cosign key |
| `COSIGN_PASSWORD` | `secret/cosign` | `password` | cosign key passphrase (`n/a` = empty) |
| `DEFECTDOJO_API_KEY` | `secret/defectdojo` | `api_token` | Upload scan results to DefectDojo |

**Notes:**
- `COSIGN_PASSWORD` is typically empty (Vault stores `n/a`). The script handles this.
- `HARBOR_USERNAME` is the Harbor robot account scoped to the `sentinel` project
  (`robot$ci-system`). It has push+create+pull+read+list on `sentinel/`.
- Some repos additionally need `GITOPS_TOKEN` (Forgejo token for cross-repo image-tag
  commits) and `DEFECTDOJO_URL`. These are repo-specific — add them separately.

---

## Provisioning a New Repo

### Prerequisites

- Vault token with read access to `secret/harbor/robot`, `secret/cosign`,
  `secret/defectdojo`. The session root token or `claude-automation` policy satisfies this.
- Forgejo token that owns the target repo (vault-autogen-bot or sentinel-admin
  user token). The `sentinel-worker` token lacks the `write:issue` scope needed
  for secrets API; use the admin bot token: `secret/forgejo/vault-autogen-bot.token`.

### Steps

1. Pull tokens from Vault:

```bash
FG_TOKEN=$(VAULT_ADDR=https://vault.208.haist.farm vault kv get \
  -field=token secret/forgejo/vault-autogen-bot)
```

2. Run the provisioning script (dry-run first):

```bash
FG_TOKEN="$FG_TOKEN" VAULT_TOKEN="$VAULT_TOKEN" \
  ./scripts/provision-ci-secrets.sh sentinel-admin/<repo-name> --dry-run
```

3. If the dry-run output looks correct, run without `--dry-run`:

```bash
FG_TOKEN="$FG_TOKEN" VAULT_TOKEN="$VAULT_TOKEN" \
  ./scripts/provision-ci-secrets.sh sentinel-admin/<repo-name>
```

4. Verify in Forgejo UI: `Settings → Actions → Secrets` for the repo, or via API:

```bash
curl -s -H "Authorization: token $FG_TOKEN" \
  "https://forgejo.208.haist.farm/api/v1/repos/sentinel-admin/<repo-name>/actions/secrets" \
  | python3 -m json.tool
```

Expected output lists all five secret names with `created_at` timestamps.

---

## Checklist for New Image-Build Repos

When adding an image-build workflow to a new repo:

- [ ] Run `provision-ci-secrets.sh` for the repo (step above)
- [ ] Add repo to `forgejo-branch-protection.sh` with appropriate status checks
- [ ] If the workflow uses `GITOPS_TOKEN` (cross-repo image-tag commits), provision
      it separately from `secret/forgejo-worker.api_token` or a dedicated robot token
- [ ] If the workflow uses `DEFECTDOJO_URL`, provision it from `secret/defectdojo.url`
- [ ] Trigger the build workflow on a test PR to confirm secrets are read successfully
- [ ] Add the image to `scripts/image-manifest.txt` after first successful push

---

## Org-Level Secrets (Not Implemented)

Forgejo supports organization-level secrets that all repos in the org can read.
Setting `HARBOR_USERNAME`, `HARBOR_PASSWORD`, `COSIGN_KEY`, and `DEFECTDOJO_API_KEY`
at the `sentinel-admin` org level would eliminate per-repo provisioning for shared
values.

This is not implemented because:
1. Org-level secrets require an org-owner token, which is `sentinel-admin` (break-glass tier).
2. It is not clear whether all `sentinel-admin` repos should have access to the
   cosign private key and Harbor push credentials — scope is currently per-repo.
3. Evaluating this change requires an operator decision (security tradeoff).

Tracked as a potential future improvement; operator decision required before implementing.

---

## Troubleshooting

**Script fails with "vault read failed":**
Verify `VAULT_TOKEN` has policy `claude-automation` or explicit read on the three paths.
Test: `vault kv get secret/harbor/robot`

**Script fails with HTTP 403 from Forgejo:**
The `sentinel-worker` token cannot write repo secrets. Use the vault-autogen-bot token
(`secret/forgejo/vault-autogen-bot.token`).

**Secrets provisioned but workflow still fails with auth error:**
The Forgejo runner context caches secrets at job start. If the secret was updated
while a job was running, re-trigger the workflow. No restart needed for new secrets.

**Build fails with "harbor: unauthorized":**
The `robot$ci-system` robot account in Harbor may have expired or been rotated.
Check `secret/harbor/robot.rotated_at` and compare with Harbor's robot account list.
Re-provision after rotation.
