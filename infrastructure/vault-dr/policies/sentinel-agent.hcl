# sentinel-agent Vault policy
# Purpose: Read secrets needed for monitoring and autonomous operations
# AppRole: auth/approle/role/sentinel-agent
# Applied: vault policy write sentinel-agent /path/to/sentinel-agent.hcl
# Last updated: 2026-04-18 (OPS-215 — added forgejo path)

# Wazuh API credentials (Manager + Indexer)
path "secret/data/wazuh*" {
  capabilities = ["read"]
}

# Plane API key (issue tracking)
path "secret/data/plane*" {
  capabilities = ["read"]
}

# Forgejo token (repository signal source)
# Added OPS-215: AppRole was returning 403 on this path
path "secret/data/forgejo" {
  capabilities = ["read"]
}

# GitLab API (legacy — kept for compatibility)
path "secret/data/gitlab*" {
  capabilities = ["read"]
}

# Ntfy notification credentials
path "secret/data/ntfy*" {
  capabilities = ["read"]
}

# Ollama / local LLM credentials
path "secret/data/ollama*" {
  capabilities = ["read"]
}

# Anthropic API key (Claude LLM)
path "secret/data/anthropic*" {
  capabilities = ["read"]
}

# Gemini API key (LLM fallback)
path "secret/data/gemini*" {
  capabilities = ["read"]
}

# sentinel-agent own secrets (approle renewal, etc.)
path "secret/data/sentinel-agent/*" {
  capabilities = ["read"]
}

# SSH signing for remediation actions (admin role for managed hosts)
path "ssh/sign/admin" {
  capabilities = ["create", "update"]
}

# Token self-management
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/renew-self" {
  capabilities = ["update"]
}
