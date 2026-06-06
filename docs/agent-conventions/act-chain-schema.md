# Act-Chain Audit Header — Convention v1

**Schema version:** v1  
**Introduced:** OPS-918 (2026-05-24)  
**Status:** Active  

---

## Purpose

RFC 8693 §4.1 defines an "act" claim that records the delegation chain in OAuth 2.0
token exchange. This convention adapts that shape to Overwatch Platform's human-readable
audit surfaces so forensic reconstruction of any agent-taken action is greppable,
not archaeological.

Without Act-Chain, answering "who authorized this change?" requires reading full session
transcripts. With Act-Chain, the delegation chain is discoverable by grep over Plane
comments, git log, and AGENT-STATE.md files.

---

## Schema

Single line on every audit surface:

```
Act-Chain: human=<operator> orchestrator=<team-or-session> executing=<agent-name> action=<verb> resource=<target>
```

### Fields

| Field | Required | Description | Examples |
|-------|----------|-------------|----------|
| `human` | yes | Operator who authorized the session | `jim` |
| `orchestrator` | yes | Team name or session ID that dispatched this agent | `backlog-2026-05-25`, `team-lead-session-042` |
| `executing` | yes | Agent name taking the action | `worker-918-actchain`, `judge-869-pr403` |
| `action` | yes | Verb describing the action | `edit`, `commit`, `comment`, `merge`, `create`, `delete` |
| `resource` | yes | Target of the action | `~/.claude/agents/worker.md`, `OPS-918`, `sentinel-iac#403` |
| `via` | no | Parent agent (only set when dispatched by another agent) | `worker-918-actchain` |

### Action Vocabulary

| Verb | When to use |
|------|-------------|
| `edit` | Modifying an existing file |
| `commit` | Pushing a git commit |
| `comment` | Posting a Plane issue comment |
| `merge` | Merging a PR |
| `create` | Creating a new file, issue, or PR |
| `delete` | Deleting a file or resource |
| `verify` | Running a verification/compliance check |
| `state-write` | Writing AGENT-STATE.md |

---

## Where It Appears

### 1. Plane Comments

Prepend the Act-Chain line **before** the note TYPE header (`**PLAN**`, `**CHANGE**`,
etc.). This keeps the audit header at the very top for easy grep on exports.

```
Act-Chain: human=jim orchestrator=backlog-2026-05-25 executing=worker-918-actchain action=comment resource=OPS-918
**PLAN** — Implement act-chain convention doc
**Timestamp:** 2026-05-24T12:00:00Z

Body text...
```

### 2. Git Commit Footers

Add as the last trailer line of the commit body, after `Co-Authored-By` if present:

```
[OPS-918] Add act-chain convention doc and update agent definitions

- Created sentinel-cache/conventions/act-chain-schema.md
- Updated worker.md, judge.md, compliance-scribe.md

Act-Chain: human=jim orchestrator=backlog-2026-05-25 executing=worker-918-actchain action=commit resource=sentinel-iac#worker/OPS-918-actchain
Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

### 3. AGENT-STATE.md Writes

Include in the Session Summary section:

```yaml
act_chain: "human=jim orchestrator=<session> executing=<agent> action=state-write resource=<repo>/AGENT-STATE.md"
```

---

## Nested / Chained Agents

When a lead or worker agent dispatches a subagent, the subagent adds `via=<parent-agent>`
between `orchestrator` and `executing`:

```
Act-Chain: human=jim orchestrator=backlog-2026-05-25 via=worker-918-actchain executing=test-subagent action=edit resource=/tmp/test-file
```

This creates a readable delegation chain: human → orchestrator → via (delegating agent) → executing (acting agent).

---

## Multi-Step Actions

Use **one Act-Chain line per audit surface** (per comment, per commit). If a single
comment documents multiple actions (e.g., a CHANGE note covering 3 file edits), use
the primary or most consequential action:

```
Act-Chain: human=jim orchestrator=backlog-2026-05-25 executing=worker-918-actchain action=commit resource=sentinel-iac#worker/OPS-918-actchain
**CHANGE** — Updated 3 agent definitions + convention doc
...
```

---

## Grep Patterns

```bash
# All actions authorized by operator jim
grep 'Act-Chain:.*human=jim' <file>

# All actions taken by a specific agent
git log --format='%H %s%n%b' | grep 'Act-Chain:.*executing=worker-918'

# All merge actions across git history
git log --format='%b' | grep 'Act-Chain:.*action=merge'

# Full delegation chain for an issue
grep 'Act-Chain:.*resource=OPS-918' <plane-export>

# Any action touching a specific file
grep 'Act-Chain:.*resource=.*worker\.md' <git-log>

# Subagent actions (has via= field)
grep 'Act-Chain:.*via=' <file>
```

---

## Rationale

AI-agentic systems lack natural audit trails at the action level. Session transcripts
contain the full delegation chain but are not indexed or greppable post-session.

Act-Chain makes causation discoverable:
- **Incident forensics:** "What authorized this file change?" → grep git log for Act-Chain
- **Compliance evidence:** "Which human authorized each agent action?" → grep Plane export
- **Delegation tracing:** "Did a subagent act within its scope?" → trace via= chain

Inspired by RFC 8693 (OAuth 2.0 Token Exchange) §4.1 "act" claim.

---

## Out of Scope (Phase 1)

The following are deferred to future phases:
- Machine-parseable structured format (JSON/YAML header)
- Cryptographic claim-signing of the header
- Automated lineage-graph generation
- Centralized Act-Chain log aggregation

---

## CLAUDE.md Addendum (Proposed — Requires Operator Authorization)

The following text is proposed for addition to CLAUDE.md §6 (Engineering Notes).
**Per CLAUDE.md hard limit, this has NOT been applied.** It is included here for
operator review on OPS-918.

```markdown
### Act-Chain Header (OPS-918)

Every agent comment, commit, and AGENT-STATE.md write emits a single Act-Chain
line for forensic audit lineage. Schema and examples:
`~/sentinel-cache/conventions/act-chain-schema.md`

Format:
`Act-Chain: human=<operator> orchestrator=<team-or-session> executing=<agent-name> action=<verb> resource=<target>`

In Plane comments: prepend before **NOTE TYPE** header.
In git commits: add as last trailer line.
In AGENT-STATE.md: include in Session Summary section.
```
