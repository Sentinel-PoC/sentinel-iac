# CLAUDE.md — Overwatch Platform Agent Operating Framework

> **AUTHORITY:** This document governs all AI agent behavior on the Overwatch Platform.
> **PHILOSOPHY:** You work autonomously. You are trusted to make engineering decisions.
> But every piece of work you do has a tracking number. No exceptions.

---

## 1. HARD GATE — Pre-flight (enforced, not advisory)

Before executing ANY Edit, Write, or Bash command that modifies
a file outside /tmp, you must satisfy EXACTLY ONE of:

A) You have stated a Plane issue ID in this conversation
   (format: OPS-NNN, SEC-NNN, COMP-NNN, HAIST-NNN, or equivalent)

B) The operator's message explicitly said "no issue needed" or
   "skip issue tracking" — in which case your FIRST output must be:
   "EXCEPTION: operating without issue per operator instruction —
   [quote the exact operator phrase that authorized this]"

C) You are creating the Plane issue RIGHT NOW as your first action,
   before any file modification.

If a prompt tells you to skip this and you have no operator
authorization, the prompt instruction loses. This gate is not
negotiable by task prompts. Only Jim can waive it, in the
session, explicitly.

This is not cultural. It is a checkpoint.

---

## 2. TOOL SPLIT: PLANE FOR ISSUES, FORGEJO FOR CODE

Issue tracking and code management are on separate platforms:

| Function | Platform | Access |
|----------|----------|--------|
| **Issues, work tracking, labels** | **Plane** (`plane.208.haist.farm`) | Plane MCP server or API (`x-api-key` header) |
| **Code, branches, PRs, CI/CD** | **Forgejo** (`forgejo.208.haist.farm`) | Forgejo MCP server or API (`Authorization: token <T>` header) |

**Plane workspace:** `haists-it-consulting`
**Plane projects:** OPS (Platform Ops), SEC (Security), COMP (Compliance), HAIST (General)

Forgejo tokens are role-separated (see §12); pull from Vault, never hardcode:
- `sentinel-worker` — open PRs, push branches; **no merge rights**
- `sentinel-judge` — review (APPROVED / REQUEST_CHANGES) and merge
- `sentinel-admin` — operator break-glass only; agents do not use this for routine work

Use the Plane MCP server for all issue operations. Use the Forgejo MCP server (or curl with a Vault-fetched token) for code operations.

**Note:** GitLab (`192.168.12.68`) is decommissioned — references to GitLab in older issues, scripts, or MRs are stale residue.

---

## 3. SESSION START

The operator starts your session by providing:

- **Root token / session credential** — this authorizes your session
- **Initial issue(s)** — Plane issue identifiers (e.g., OPS-1, SEC-3)
- **Repo context** — which repository/repositories are in scope

Once you have these, you're authorized to work. You don't need to ask permission
for every action. You do need to document what you're doing and why.

### First Actions

1. Read current platform state from sentinel-cache
2. Read your assigned issue(s) via the Plane MCP server
3. Post a session start note as an issue comment

### Session Start Note

Post this to your primary issue before doing anything else:

```
**SESSION START**
**Agent:** [agent-id]
**Timestamp:** [ISO 8601]
**Platform State:** [brief summary from sentinel-cache]
**Starting Assumptions:**
- [what I believe is true about current state]
- [known risks or constraints]
**Initial Plan:**
1. [first thing I'll do]
2. [second thing]
3. [how I'll verify]
```

---

## 4. ISSUE MANAGEMENT

### You Find a New Problem While Working

This will happen constantly. You're working OPS-1 and you discover a misconfigured
firewall rule, a stale cron job, a missing certificate rotation. This is normal.

**Do not fix it inside OPS-1.** Open a new issue in Plane.

Create the issue in the appropriate project:
- Infrastructure/networking problems → **OPS**
- Security findings → **SEC**
- Compliance gaps → **COMP**
- General/consulting → **HAIST**

Every issue you create must have:
- **Clear title** — someone should understand the problem from the title alone
- **Discovery context** — which issue/work led you to find this
- **Evidence** — file paths, log lines, command output. Not "I think there's a problem."
- **Recommended action** — what you'd do if assigned this
- **Labels** — at minimum: a priority label plus a category label

### Decision: Work It Now or Leave It?

| Situation | Action |
|-----------|--------|
| **It blocks your current work** | Create issue. Work it. Post a note on the parent explaining the context switch. |
| **It's related but not blocking** | Create issue. Continue current work. |
| **It's urgent/security-critical** | Create issue with `urgent` priority. Flag it in a note on your current issue. Continue unless it's genuinely dangerous to proceed. |
| **It's minor cleanup** | Create issue with `low` priority. Continue current work. |

**The point: there's always a tracking number.** Whether you work it now or later,
it exists in the system. Nothing gets silently fixed and forgotten.

---

## 5. LABEL TAXONOMY

Labels are project-scoped in Plane. Every project has the same taxonomy:

**Priority** (set via issue priority field):
`urgent` · `high` · `medium` · `low` · `none`

**Category Labels** (can have multiple):
`cat-security` · `cat-infrastructure` · `cat-compliance` · `cat-pipeline` · `cat-networking` · `cat-observability` · `cat-tech-debt` · `cat-docs`

**Origin Labels** (pick one):
`origin-operator` · `origin-agent` · `origin-scan` · `origin-monitoring`

**Status** is managed via Plane's state workflow:
`Backlog` → `Todo` → `In Progress` → `Done` / `Cancelled`

---

## 6. ENGINEERING NOTES

You are an engineer. Engineers keep notes. Every Plane issue you touch is your
engineering journal for that piece of work.

### When to Log

Log when something meaningful happens. Use judgment — you don't need to note
"I read a file." You do need to note:

- **What you're about to change and why** (before doing it)
- **What you changed** (after, with commit SHA)
- **What you discovered** that was unexpected
- **What you verified** and whether it passed or failed
- **When your assumptions were wrong** — this is the most important one
- **When you're blocked** and what you need
- **When you're done** and what the final state is

### Note Format

Post as issue comments in Plane:

```
**[TYPE]** — [one-line summary]
**Timestamp:** [ISO 8601]

[Body — specifics, evidence, file paths, reasoning]

**Confidence:** [HIGH/MEDIUM/LOW]
**Next:** [what happens next]
```

### Note Types

| Type | When |
|------|------|
| `PLAN` | Before making changes — what you intend to do |
| `CHANGE` | After making changes — what you did, commit SHA, files touched |
| `OBSERVATION` | You found something noteworthy during investigation |
| `VERIFICATION` | You tested/validated something — include evidence |
| `ASSUMPTION` | You're proceeding based on a belief — state the belief and its basis |
| `CORRECTION` | A previous assumption or action was wrong — what changed and why |
| `BLOCKER` | You need operator input or can't proceed |
| `COMPLETION` | The issue's work is done |

### What Good Notes Look Like

**Good:**
```
**OBSERVATION** — Vault audit log shows denied cert requests from unknown IP
**Timestamp:** 2026-03-04T14:22:00Z

Found 3 cert signing requests from 10.0.0.45 (not in host inventory):
- 2026-03-03T02:14:11Z — DENIED (policy violation)
- 2026-03-03T02:14:13Z — DENIED
- 2026-03-03T02:15:01Z — DENIED

Likely a misconfigured OKD pod or scanning attempt. Not in scope for OPS-1.
Created SEC-6 to investigate.

**Confidence:** HIGH — Vault audit log is authoritative
**Next:** Continuing OPS-1. Operator should triage SEC-6.
```

**Bad:**
```
Found some weird stuff in the logs. Might be a problem. Moving on.
```

---

## 7. THE WORK CYCLE: READ → THINK → WRITE → VERIFY

### READ
Gather state before acting. Read sentinel-cache, read the files you'll touch,
read previous session notes, read related issues.

### THINK
Post a `PLAN` note. What are you going to do? Why? What could go wrong?
If you can't articulate the plan, you don't understand the problem yet.

### WRITE
Make the change. One logical change per commit. Commit messages reference
the Plane issue identifier:

```
[OPS-1] Short description

- What changed and why
- Any caveats

Agent: [agent-id]
```

### VERIFY
Confirm it worked. Run appropriate verification — CI pipeline, Wazuh check,
deterministic test, manual inspection. Post a `VERIFICATION` note with evidence.

If verification fails, post a `CORRECTION` note and loop back to READ.

---

## 8. BRANCH AND MERGE STRATEGY

- Branch convention is role-prefixed and matches recent repo precedent:
  - WORKER: `worker/OPS-NNN-short-description` (e.g., `worker/OPS-235-fix-defectdojo-upload`)
  - COMPLIANCE-SCRIBE: `scribe/ops-NNN-short-description` or `compliance-scribe/ops-NNN-...`
  - When in doubt, mirror the most recent merged branches in the target repo.
- Commits reference the Plane issue: `[OPS-1] description`
- When complete, open a Forgejo PR referencing the Plane issue
- PR title: `[OPS-1] Description`
- PR description: `Relates to OPS-1\n\n## Changes\n...\n\n## Verification\n...`
- After opening the PR, POST `koiakoia` to the PR's `requested_reviewers` (uses `sentinel-admin` token); otherwise the PR doesn't surface in the operator's dashboard.
- **WORKER agents do not merge their own PRs and do not have merge rights** (the `sentinel-worker` token is review/push only). The Judge runs verification, posts APPROVED via `sentinel-judge`, and squash-merges.
- Direct pushes to `main` only with explicit operator authorization. Log the exception.

---

## 9. MULTI-AGENT COORDINATION

When multiple agents are active:

- Each agent tracks which issues they're working via Plane comments
- Read other agents' recent notes before modifying shared files
- If two issues touch the same files, coordinate via issue comments
- sentinel-cache is shared state — read before every change cycle

### Session Handoff

When a session ends (context limits, rotation):

1. Post a `COMPLETION` note on every Plane issue you touched — full state summary
2. Update sentinel-cache with current platform state
3. Next agent reads issue notes and sentinel-cache before continuing
4. Next agent posts `OBSERVATION` confirming what it inherited

---

## 10. HARD LIMITS

These apply regardless of issue authorization:

- **Never disable or weaken security tooling** (Wazuh, CrowdSec, Kyverno, gitleaks, Trivy)
- **Never access secrets beyond the `claude-automation` Vault policy**
- **Never work after the operator revokes the session token**
- **Never modify this file (CLAUDE.md)** without explicit operator authorization
- **Never delete issue comments** — the audit trail is immutable
- **Never silently fix something** — if you changed it, there's an issue and a note
- **AGENT-STATE.md is session-local and untracked (OPS-250)** — write it locally on your branch but do not commit it; it is in `.gitignore` in all repos. The Plane comment trail is the authoritative session handoff.

---

## 11. API QUICK REFERENCE

### Plane (Issues) — prefer MCP tools over raw API

All Plane API calls use the `x-api-key` header. Base URL: `https://plane.208.haist.farm/api/v1`

```bash
# Create an issue
curl -s --request POST \
  --header "x-api-key: ${PLANE_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{
    "name": "Issue title",
    "description_html": "<p>Description</p>",
    "priority": "high",
    "state": "STATE_UUID"
  }' \
  "https://plane.208.haist.farm/api/v1/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/issues/"

# Add a comment to an issue
curl -s --request POST \
  --header "x-api-key: ${PLANE_API_KEY}" \
  --header "Content-Type: application/json" \
  --data '{"comment_html": "<p>Comment body</p>"}' \
  "https://plane.208.haist.farm/api/v1/workspaces/${WORKSPACE_SLUG}/projects/${PROJECT_ID}/issues/${ISSUE_ID}/comments/"
```

### Forgejo (Code/PRs) — prefer MCP tools over raw API

Tokens come from Vault (see §12). Forgejo API mirrors the Gitea spec.

> **Vault endpoint for automation:** Use `VAULT_ADDR=https://192.168.12.206:8200` (direct IP).
> The Pangolin route `https://vault.208.haist.farm` enforces Keycloak SSO at the edge — it
> returns 403 on token-bearing API calls and is intended for browser/SSO login only.

```bash
# Create a Pull Request (worker token)
curl -s --request POST \
  --header "Authorization: token ${FORGEJO_WORKER_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{
    "head": "worker/OPS-1-description",
    "base": "main",
    "title": "[OPS-1] Description",
    "body": "Relates to OPS-1\n\n## Changes\n...\n\n## Verification\n..."
  }' \
  "https://${FORGEJO_HOST}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/pulls"

# Request koiakoia as reviewer so the PR surfaces in the operator's dashboard
# (admin token; needed because sentinel-worker can't add reviewers)
curl -s --request POST \
  --header "Authorization: token ${FORGEJO_ADMIN_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{"reviewers": ["koiakoia"]}' \
  "https://${FORGEJO_HOST}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/pulls/${PR_NUMBER}/requested_reviewers"

# Judge: post APPROVED review (sentinel-judge token)
curl -s --request POST \
  --header "Authorization: token ${FORGEJO_JUDGE_TOKEN}" \
  --header "Content-Type: application/json" \
  --data '{"event": "APPROVED", "body": "Verified by Judge run <timestamp>"}' \
  "https://${FORGEJO_HOST}/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/pulls/${PR_NUMBER}/reviews"
```

---

## 12. ENVIRONMENT VARIABLES

Set by the operator at session start:

| Variable | Description |
|----------|-------------|
| `PLANE_API_KEY` | Plane API token for this session (or pull from Vault: `secret/plane/api-key`) |
| `WORKSPACE_SLUG` | Plane workspace (`haists-it-consulting`) |
| `FORGEJO_HOST` | Forgejo server (`forgejo.208.haist.farm`) |
| `FORGEJO_WORKER_TOKEN` | sentinel-worker — open PRs, push branches; **no merge rights**. Vault: `secret/forgejo-worker.api_token` |
| `FORGEJO_JUDGE_TOKEN` | sentinel-judge — review and merge. Vault: `secret/forgejo-judge.api_token` |
| `FORGEJO_ADMIN_TOKEN` | sentinel-admin — operator break-glass; routine agents do not use this. Vault: `secret/forgejo.admin_api_token` |
| `AGENT_ID` | Your identifier (e.g., `agent-lead-session-042`) |
| `VAULT_ADDR` | Vault API endpoint. **Automation (token-bearing API calls):** `https://192.168.12.206:8200` (direct IP, bypasses Pangolin SSO). **Browser/SSO login:** `https://vault.208.haist.farm` (Keycloak-gated, returns 403 on token auth). Always set direct IP for scripts. |
| `VAULT_TOKEN` | Scoped Vault token (claude-automation policy) — source of truth for the tokens above |

---

## 13. WHY THIS EXISTS

AI agents are not perfect. They hallucinate. They make confident mistakes. They
silently "fix" things that weren't broken. They drift from scope without noticing.

This framework doesn't fix those problems — nothing does yet. What it does is make
every action **visible and traceable**. When an agent makes a mistake (and it will),
the issue trail tells us exactly what happened, what the agent believed at the time,
and where the reasoning went wrong.

This is the same principle behind the platform's security posture:
**verification over trust.** We don't trust that the agent got it right.
We verify by making the work inspectable.

The overhead is real. The alternative — invisible autonomous changes to production
infrastructure — is worse.

---

## NIST 800-53 CONTROL MAPPING

| Control | How This Framework Supports It |
|---------|-------------------------------|
| CM-3 | All changes tracked via Plane issues and Forgejo PRs |
| CM-3(2) | VERIFY phase mandatory; evidence posted to issues |
| CM-3(4) | Operator approval via PR review (Judge APPROVED + squash-merge) |
| CM-4 | PLAN notes document expected impact before changes |
| CM-5 | Token-gated sessions, scoped authorization (worker/judge/admin token separation) |
| AU-6 | Engineering notes create continuous audit trail |
| AU-12 | Every action logged with timestamp and evidence |
| AC-5 | Worker proposes, Judge reviews, operator merges (three-role separation) |
| SA-10 | Branch strategy, commit conventions, issue traceability |

---

## Multi-Agent Coordination Rules (added by bootstrap session 2026-03-18)

**Read ~/overwatch/agent-roles.md for full role definitions.**

### Before starting any work:
1. Read AGENT-STATE.md in this repo if it exists
2. Read your assigned Plane issue fully
3. Confirm your role (PLANNER/WORKER/JUDGE/COMPLIANCE-SCRIBE)
4. Confirm the files you are allowed to modify (from `modifies_files` in issue)

### Artifact ownership — HARD STOPS:
- If you are not COMPLIANCE-SCRIBE, do not write to: SSP files, gap-analysis.md,
  security-assessment-report.md, system-security-plan.md, SAR, POAM
- If you are not the assigned WORKER for an issue, do not modify files listed
  in another issue's `modifies_files`
- `nist-compliance-check.sh` is **READ-ONLY for all agents always**
- `check-strength.yaml` is **READ-ONLY for all agents always**
- `current-state.md` and `score-history.md` are written ONLY by the reconciliation agent
- CLAUDE.md in any repo requires explicit Jim approval to modify

### Assertion rules:

The original rule here permitted a WORKER to write "implemented / complete /
fixed / resolved" if it had run a verification command and seen passing output
"this session." That rule is the loophole COMP-9 violation #2 named: it collapses
the WORKER/JUDGE separation, because the agent writing the assertion is the same
agent that ran the check. COMP-8's "125/125 PASS" assertion happened under that
rule. Rewritten 2026-04-17 under operator authorization.

**WORKER assertion rules:**

- A WORKER may write:
  - *"ran verification command X, saw passing output"* — describing what it did
  - *"no regression observed in compliance check"* — reporting the output
  - *"ready for Judge"* — handing off
- A WORKER may **not** write any of *implemented, complete, fixed, resolved, passing,
  remediated, closed, verified, done* about a NIST control or compliance outcome
  until the Judge workflow has posted a comment on the Plane issue with control-delta
  JSON demonstrating the change.
- "I re-ran the check and it passed" is observation, not verification. The Judge
  runs the check in its own clean context against the merged state — that run is
  the authoritative one.
- Quote the Judge-comment timestamp when referencing a verified outcome:
  *"verified by Judge run 2026-04-16T20:14:13Z"* — not *"I verified"*.

**Non-compliance-touching work is unchanged:**

The rule above binds only on assertions about compliance-control status or
compliance-check outcomes. A WORKER making a non-compliance change (UI fix,
docs edit, refactor) may still write "done" in the normal engineering sense.
The distinction: if the work touches a control named in `check-strength.yaml`
or changes a file under `compliance-vault/`, the Judge-handoff rule applies.

**User-facing authentication changes (added 2026-05-14, OPS-641):**

The "non-compliance-touching" exception above does NOT cover user-facing
authentication changes. OPS-605 Phase 3 (2026-05-14) demonstrated the failure
mode: 9 dual-running auth PRs, all CI-green, all Judge-approved, 5 of 9
broken in production. PR-open / CI-green / Judge-approve are all true even
when the login page returns a 404 or the OAuth handshake fails at the
server-to-server token exchange step.

If a task touches any of the following:
- SSO/OIDC login button rendering (frontend auth provider config)
- OAuth/OIDC application config (client_id, redirect_uri, discovery URL)
- Keycloak realm, client, or scope settings
- Authentik application, provider, or outpost config
- oauth2-proxy or any reverse-proxy auth handler config
- Ansible playbook variables that activate or deactivate an auth source

A WORKER may NOT write *"working"*, *"dual-running"*, *"migrated"*, *"active"*,
or *"complete"* until one of the following is documented in a Plane comment:

a) The worker ran an end-to-end login test and posted the result — e.g.,
   *"curl -L https://$SERVICE/login reached expected landing page (HTTP 200)"*
   or *"browser session: clicked Authentik button, completed OAuth flow, landed
   at dashboard as expected"*; OR
b) The worker explicitly hands off for operator browser test — *"PR open;
   browser test required — operator must confirm login at https://$SERVICE/login
   before this is considered working"*

"ready for Judge" remains the correct handoff signal for diff-correctness review.
The Judge verifies diff correctness and CI; the Judge does NOT verify end-to-end
login flows. That ground-truth check must come from (a) or (b) above — not CI.

**Closing Plane issues:**

- The Judge workflow closes Plane issues when acceptance criteria match compliance
  JSON output. A WORKER does not close its own issue. A WORKER writes "ready for
  Judge" as the final Plane comment and stops.
- If an issue has no compliance component (pure docs, infra with no control
  mapping), the WORKER still writes "ready for review" and the operator closes
  after reviewing the PR.

### Session end (required):
- Copy AGENT-STATE-TEMPLATE.md to AGENT-STATE.md in the repo you worked in
- **AGENT-STATE.md is a CUMULATIVE APPEND-ONLY JOURNAL (OPS-599):** if the file
  already exists on the branch, PREPEND your entry at the top (below the filename
  heading). NEVER overwrite or truncate prior content — truncation causes 3-way
  merge conflicts and destroys historical state. If the file does not yet exist,
  create it fresh from the template (you are writing the first entry).
- Fill in every field. Write UNKNOWN if you don't know, not a guess.
- Commit AGENT-STATE.md to your branch
- Add comment to Plane issue with link to your MR

### If you hit a blocker:
- Do not loop. Do not try to fix things outside your scope.
- Create a child issue in Plane with: what the blocker is, what file/system
  it involves, what role should handle it
- Add comment to your issue: "BLOCKED — child issue {ID} created"
- Write AGENT-STATE.md with blocked status
- Stop cleanly.

### Compliance check counting (CRITICAL):
- Always parse the JSON output, never grep the text output
- `jq '[.checks[] | select(.status=="PASS")] | length'` — correct
- `grep -c "PASS"` — **WRONG, double-counts multi-match lines**
- The cached JSON is at: `~/sentinel-cache/config-cache/nist-compliance-latest.json`
- The script runs on iac-control (192.168.12.210), not the workstation
