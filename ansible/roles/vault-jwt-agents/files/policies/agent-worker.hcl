# agent-worker — least-privilege Vault policy
# Tracking: OPS-345 Phase 3
#
# Grants ONLY:
#   - read own Forgejo credentials
#   - read shared Plane API key (for issue comments)
#   - lookup own token (needed for TTL inspection)
#
# Cross-role reads DENIED by absence of grant.

path "secret/data/forgejo-worker" {
  capabilities = ["read"]
}

path "secret/data/plane/api-key" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
