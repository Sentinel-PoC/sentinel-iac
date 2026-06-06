# Runbook 14 — IaC Drift Detection

**Issue:** OPS-193
**Criticality:** High — drift detection is the structural backstop for the framework's "every change has an issue and a note" rule.
**Host:** iac-control (192.168.12.210)

---

## What this is

A daily systemd timer on iac-control that diffs *live configuration* against *Ansible/IaC source-of-truth*. Catches the audit-drift class that surfaced four times during the 2026-04-29 audit (SEC-29, SEC-30, SEC-32, SEC-45).

Output: one JSON line per rule to journald (tag `iac-drift-check`) and `/var/log/iac-drift-check.json`. Wazuh decoder parses each line. Exit codes match `vault-health-probe`:

- `0` — all rules PASS
- `1` — at least one rule WARN
- `2` — at least one rule CRIT (OR script error)

---

## One-time deployment prerequisites

The Ansible role refuses to install the timer if the prerequisite env file is missing.

### 1. Create a scoped Vault token for the drift checker

The token needs read on the Vault paths the rules reference, plus `sys/policies/acl/*` read for any rule of kind `vault-policy`. The exact policy depends on which rules you enable; for the initial rule set, this works:

```hcl
# iac-drift-checker.hcl
path "secret/data/wazuh/api"      { capabilities = ["read"] }
path "secret/data/wazuh/indexer"  { capabilities = ["read"] }
path "sys/policies/acl/*"         { capabilities = ["read"] }
```

```bash
vault policy write iac-drift-checker iac-drift-checker.hcl
vault token create -policy=iac-drift-checker -period=720h -renewable=true \
    -display-name=iac-drift-checker -format=json | jq -r '.auth.client_token'
```

### 2. Place the token in the env file

```bash
sudo install -d -o root -g root -m 0750 /etc/iac-drift
echo "VAULT_TOKEN=<scoped-token-value>" | \
    sudo install -o root -g root -m 0400 /dev/stdin /etc/iac-drift/env
```

### 3. Deploy via Ansible

```bash
cd ~/repos/sentinel-iac/ansible
ansible-playbook -i inventory/hosts.yml playbooks/iac-control.yml \
  --tags=platform-timers,iac-drift-check
```

The role asserts the env file presence; missing/mis-permed file fails with an explicit message.

### 4. Smoke-test

```bash
ssh iac-control 'sudo /usr/local/bin/iac-drift-check.py --rules /usr/local/share/iac-drift/rules.yaml --dry-run' | jq -c '{rule_id, status}'
```

All current rules should PASS (the live state was verified clean during OPS-193 development).

---

## Interpreting alerts

| Status | What it means | Action |
|--------|--------------|--------|
| `OK` | Live matches expected. Logged for trend. | None. |
| `WARN` | Drift detected; severity is informational. Audit-trail gap (something changed without an issue). | Investigate within a few days. Either backport the live change to IaC (and update rules.yaml) OR revert the live change. |
| `CRIT` | Drift detected; security-posture loss or functional regression. | Investigate immediately. Most CRIT cases mean Ansible re-run would worsen the situation, so do NOT re-run any role until reconciled. |

The `_summary` line at end-of-run aggregates all rule outcomes.

---

## Adding a new rule

`scripts/iac-drift/rules.yaml` is the rule manifest. A new rule needs:

```yaml
- id: <unique-id>                  # short kebab-case
  system: <wazuh|vault|forgejo|harbor|other>
  severity: <crit|warn|info>
  description: One-line human summary
  rationale: Why this rule exists (issue ID + what would silently break without it)
  source:
    kind: <wazuh-api|vault-policy|http>
    # kind-specific fields (see existing rules for patterns)
  expect:
    # one of: equals, subset, contains, paths_contain, json_field_contains
```

**`subset` vs `equals`:** prefer `subset` when the live source has additional benign fields beyond what you're asserting. `equals` is strict and false-positives easily.

**Auth:** the script reads a Vault token from `/etc/iac-drift/env`. The Vault policy bound to that token must allow read on every Vault KV path the new rule's source references. Update the `iac-drift-checker` policy when adding rules that need new paths.

---

## Acknowledging an intentional drift

When you make a deliberate live-config change that diverges from IaC (rare, but happens during incident response), update `rules.yaml` *in the same PR* that backports the change to IaC. The rule's `rationale` should reference the issue that authorized the change.

If the change is short-lived (e.g., an emergency override that will be reverted), and you need to silence the alert temporarily, the right move is to add a comment to `rules.yaml` and merge a PR that documents the deliberate divergence — not to disable the rule. The audit trail matters.

---

## Manual diff for an unknown drift

```bash
# Run the check with verbose output for full observed values
ssh iac-control 'sudo /usr/local/bin/iac-drift-check.py \
    --rules /usr/local/share/iac-drift/rules.yaml \
    --rule-id <failing-rule-id> --verbose --dry-run'
```

The output JSON includes `observed` (the actual live response) and `diff` (a summary of why it failed) — enough to reconcile against the IaC.

---

## Cases this would have caught (regression test)

The four drift cases from 2026-04-29 are encoded in `rules.yaml` rules:

| Case | Rule that catches it |
|------|---------------------|
| SEC-29 — IaC missing rule 87202 trigger + narrower SSH coverage | `wazuh-ar-trigger-rule-87202`, `wazuh-ar-trigger-ssh-broadened-rules` |
| SEC-30 — claude-automation policy claim vs reality | `vault-claude-automation-policy-paths` |
| SEC-32 — vulnerability-detection effective config | `wazuh-vuln-detection-enabled` |
| SEC-45 — IaC narrowed white_list (lockout risk) | `wazuh-ar-whitelist-management-cidr`, `wazuh-ar-whitelist-okd-pod-cidr` |

If the Ansible re-run risks resurface, these rules will fire CRIT/WARN.

---

## Reference

- Issue: OPS-193
- Pattern source: `vault-autounseal-token-ttl.{sh,service,timer}` (OPS-190)
- Companion runbook: `13-vault-autounseal-token-ttl-monitor.md`
