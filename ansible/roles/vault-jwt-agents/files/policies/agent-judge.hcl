# agent-judge — least-privilege Vault policy
# Tracking: OPS-345 Phase 3
# Updated:  OPS-811 — add vault-autogen-bot merge token read
#
# Grants ONLY:
#   - read own Forgejo credentials (judge token has merge capability at the
#     Forgejo level — that power lives in the token, not in Vault scope)
#   - read vault-autogen-bot merge token (required for squash-merge PRs)
#   - read shared Plane API key (for issue comments)
#   - lookup own token (needed for TTL inspection)
#
# Cross-role reads DENIED by absence of grant.

path "secret/data/forgejo-judge" {
  capabilities = ["read"]
}

# Merge token — used by judges for squash-merge operations (OPS-811)
path "secret/data/forgejo/vault-autogen-bot" {
  capabilities = ["read"]
}

path "secret/metadata/forgejo/vault-autogen-bot" {
  capabilities = ["read"]
}

path "secret/data/plane/api-key" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
