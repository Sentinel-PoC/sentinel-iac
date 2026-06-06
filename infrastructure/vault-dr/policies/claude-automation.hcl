# Claude Code Automation — scoped Vault policy
# Created: 2026-02-06
# Updated: 2026-05-21 (OPS-736) — add deny overrides for judge/admin/operator paths
# Purpose: Least-privilege token for Claude Code agent sessions
#
# Token role: auth/token/roles/claude-session  (period=720h, renewable=true)
# Provisioning: ansible/playbooks/vault-claude-automation.yml
#
# Deny overrides (below) take precedence over the secret/data/* wildcard.
# Claude Code sessions may NOT read judge, admin, or operator-tier credentials.

# ---------------------------------------------------------------------------
# Allow: read all KV v2 secrets (wildcard, overridden by deny paths below)
# ---------------------------------------------------------------------------
path "secret/data/*" {
  capabilities = ["read"]
}

# List secret paths (metadata)
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}

# ---------------------------------------------------------------------------
# DENY overrides — judge / admin / operator credentials
# More-specific paths take precedence over the wildcard above.
# ---------------------------------------------------------------------------

# Forgejo judge token — sentinel-judge; review + merge rights
path "secret/data/forgejo-judge" {
  capabilities = []
}
path "secret/metadata/forgejo-judge" {
  capabilities = []
}

# Forgejo admin bot token — vault-autogen-bot; admin-tier
path "secret/data/forgejo/vault-autogen-bot" {
  capabilities = []
}
path "secret/metadata/forgejo/vault-autogen-bot" {
  capabilities = []
}

# Forgejo scribe agent token — scribe role only
path "secret/data/forgejo-scribe" {
  capabilities = []
}
path "secret/metadata/forgejo-scribe" {
  capabilities = []
}

# Forgejo planner agent token — planner role only
path "secret/data/forgejo-planner" {
  capabilities = []
}
path "secret/metadata/forgejo-planner" {
  capabilities = []
}

# Operator-tier secrets — never readable by automation
# Includes secret/operator/claude-session-token itself (prevents self-disclosure)
path "secret/data/operator/*" {
  capabilities = []
}
path "secret/metadata/operator/*" {
  capabilities = []
}

# Vault-level internal secrets
path "secret/data/vault/*" {
  capabilities = []
}
path "secret/metadata/vault/*" {
  capabilities = []
}

# ---------------------------------------------------------------------------
# Allow: SSH certificate signing (restricted role only)
# ---------------------------------------------------------------------------

# Sign SSH certificates — claude-automation SSH role only (not admin role)
path "ssh/sign/claude-automation" {
  capabilities = ["read", "update"]
}

# Read SSH role configuration — claude-automation role only
path "ssh/roles/claude-automation" {
  capabilities = ["read"]
}

# ---------------------------------------------------------------------------
# Allow: Vault system info (needed by compliance checks)
# ---------------------------------------------------------------------------
path "sys/mounts" {
  capabilities = ["read"]
}
path "sys/mounts/*" {
  capabilities = ["read"]
}
