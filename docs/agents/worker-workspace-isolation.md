# Worker Workspace Isolation Contract

**Issue:** OPS-862  
**Authored:** 2026-05-23 by worker-ops-862 (job 52a6ee4b)  
**Relates to:** OPS-527, OPS-859 (contamination incident, merge SHA `5e3f704a3869`)  
**Status:** Active — enforced contract for all worker dispatches

---

## Why This Matters: The Contamination Incident

On 2026-05-23 (backlog-burn-026 session), two workers ran concurrently against the
`sentinel-iac` repository:

- **worker-ops-527** — SPIRE Agent SVID-rebootstrap regression fix in Ansible
- **worker-ops-859** — TrueNAS update planning runbook

Both workers cloned into `$CLAUDE_JOB_DIR/sentinel-iac/` — the **same path**. Each
worker wrote its own files and pushed a branch. Because they shared a working directory,
every file from both workers was present in both trees when each worker ran `git add`.
Both branches ended up with **byte-identical content** covering both deliverables.

Resolution required:
- Judge spotted scope-bleed on PR #385; lead confirmed identical SHAs across both branches
- Lead-side surgical Forgejo content-API DELETE of cross-bleed files
- Bundle-merge of one PR (PR #386) covering both deliverables; sibling PR #385 closed as superseded
- Both OPS-527 and OPS-859 closed via the same merge SHA `5e3f704a3869`

**Cost:** ~20 minutes of lead-side coordination overhead, one contaminated branch that
had to be surgically repaired at the file level via Forgejo content API.

This will recur on every concurrent dispatch that touches the same repository without
explicit isolation.

---

## Fix #1 — Lead-Side Primary (Agent Tool `isolation` Parameter)

The cleanest fix is at the dispatch layer. When the lead spawns a worker subagent via
the **Agent tool**, it must set `isolation: "worktree"`:

```json
{
  "tool": "Agent",
  "params": {
    "isolation": "worktree",
    "prompt": "... worker brief here ..."
  }
}
```

With `isolation: "worktree"`, the harness creates a fresh git worktree for the spawned
agent, guaranteeing each worker gets an independent working directory that cannot overlap
with another worker's tree.

**This is the default as of backlog-burn-027 session.** The lead sets it on every
Agent spawn as a standing policy.

**Verification:** The spawned worker can confirm isolation by running:

```bash
git rev-parse --git-common-dir
```

If it returns a path ending in `.git` (not `.git` itself), the agent is in a worktree.
If it returns `.git`, the agent is in the main clone — isolation was not applied.

---

## Fix #2 — Worker-Side Fallback (Per-Worker Clone Path)

Lead-side isolation can be forgotten. For defense-in-depth, every worker brief **must**
instruct workers to clone into a per-spawn subdirectory rather than the job root.

### The Contract

Workers **MUST NOT** clone into `$CLAUDE_JOB_DIR/<repo>/`.

Workers **MUST** clone into `$CLAUDE_JOB_DIR/$AGENT_ID/<repo>/` (or a deterministic
per-spawn subdirectory if `$AGENT_ID` is not set).

### Worker Brief Preamble (include in every brief that touches a repo)

```
## Setup — Workspace Isolation

Before cloning any repository, create a per-worker subdirectory:

```bash
# Establish isolated work directory
WORK_DIR="${CLAUDE_JOB_DIR}/${AGENT_ID:-$(basename $CLAUDE_JOB_DIR)}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Clone the target repo into the per-worker dir
git clone https://${FORGEJO_HOST}/<owner>/<repo>.git
cd <repo>
git checkout -b worker/OPS-NNN-short-description
```

Do NOT use `~/repos/<repo>` or any pre-existing clone on the workstation.
Each worker must start from a fresh clone in its own directory.
```

### Why `AGENT_ID` (with fallback)

`$AGENT_ID` is set by the harness when the agent is spawned with a named identity.
If it is unset (e.g., bare invocation without identity params), fall back to
`$(basename $CLAUDE_JOB_DIR)` which gives the unique job-ID component of the path
(e.g., `52a6ee4b`). This is always unique per spawn.

---

## Startup Detection Check

Every worker brief should include this detection block immediately after cloning.
It verifies whether isolation is in place and exits or clones into the fallback
path if it is not:

```bash
## Detection: confirm workspace isolation
WDIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "NOT_GIT")

if [[ "$WDIR" == "NOT_GIT" ]]; then
  echo "[ISOLATION] Not in a git repo yet — using per-worker clone path (expected at brief start)"
elif [[ "$WDIR" == ".git" ]]; then
  echo "[ISOLATION WARNING] Running in main clone, not a worktree."
  echo "[ISOLATION] Switching to per-worker path: ${CLAUDE_JOB_DIR}/${AGENT_ID:-$(basename $CLAUDE_JOB_DIR)}/"
  WORK_DIR="${CLAUDE_JOB_DIR}/${AGENT_ID:-$(basename $CLAUDE_JOB_DIR)}"
  mkdir -p "${WORK_DIR}"
  # Re-clone into isolated path, then continue
  cd "${WORK_DIR}"
  git clone https://${FORGEJO_HOST}/<owner>/<repo>.git
  cd <repo>
elif [[ "$WDIR" =~ /.git$ ]] || [[ "$WDIR" =~ /.git/worktrees ]]; then
  echo "[ISOLATION OK] Worktree confirmed: $WDIR"
fi
```

The key signal: if `git rev-parse --git-common-dir` returns a path containing
`.claude/worktrees/` or any path that differs from `.git`, the agent is in a
worktree and isolation is confirmed. If it returns literally `.git`, the agent
is in the main clone and should migrate to the per-worker path.

---

## Reuse-of-Existing-Clone Hazard

A worker that runs `cd ~/repos/<repo>` is using the **operator's persistent local
clone**. This defeats isolation for two reasons:

1. **Stale state**: the clone's index and working tree reflect whatever the operator
   or a previous agent last did. The worker may commit unstaged changes it did not
   create.
2. **Cross-worker contamination**: if two workers both `cd ~/repos/sentinel-iac` and
   create branches, they share the working tree. Any file created by either worker
   is visible to the other.

**Workers must always do a fresh clone into their per-spawn directory.** The one
exception is when the lead explicitly grants a worker a dedicated worktree via
`git worktree add` (this is the lead-side fix #1 path). In that case the worker
should use the provided worktree path, not clone again.

---

## Cleanup

`$CLAUDE_JOB_DIR` is created by the harness for each job and automatically reaped
when the job ends. Per-`$AGENT_ID` subdirectories within it are therefore also reaped
automatically. Workers do not need to clean up after themselves.

Git worktrees created via `git worktree add` inside a persistent repo (e.g.,
`~/repos/sentinel-iac/.claude/worktrees/<branch>`) are **not** auto-reaped. The lead
or operator should run `git worktree prune` periodically to remove stale entries.

---

## Quick Reference Table

| Scenario | Correct path |
|----------|-------------|
| Worker spawned with `isolation: "worktree"` | Use the harness-provided worktree path; `git rev-parse --git-common-dir` returns a `.git` subpath |
| Worker spawned without isolation | Clone into `$CLAUDE_JOB_DIR/$AGENT_ID/<repo>/` |
| `$AGENT_ID` not set | Clone into `$CLAUDE_JOB_DIR/$(basename $CLAUDE_JOB_DIR)/<repo>/` |
| `~/repos/<repo>` exists on workstation | DO NOT USE — reuse hazard. Always fresh-clone. |
| Lead creates worktree via `git worktree add` | Use the provided worktree path; do not clone separately |

---

## Cross-References

- **OPS-862** — This issue. Tracks the fix + documentation of this contract.
- **OPS-527** — SPIRE Agent regression fix; one of the two contaminated workers.
- **OPS-859** — TrueNAS update planning; sibling contaminated worker.
- **Merge SHA `5e3f704a3869`** — Bundle-merge that resolved the contamination.
- **CLAUDE.md §8** — Branch and merge strategy (proposed §8a amendment tracked in OPS-862 Plane comment).
