# agent-scribe — least-privilege Vault policy
# Tracking: OPS-345 Phase 3
#
# Grants ONLY:
#   - read own Forgejo credentials (IaC writes go via Forgejo token, not Vault path)
#   - read shared Plane API key (for issue comments)
#   - lookup own token (needed for TTL inspection)
#
# compliance-vault write paths are NOT granted here — no live Vault path
# exists for that yet. If Phase 3.5 migration reveals a needed path,
# file a follow-up issue (deferred per planner spec §9 decision A).
# Cross-role reads DENIED by absence of grant.

path "secret/data/forgejo-scribe" {
  capabilities = ["read"]
}

path "secret/data/plane/api-key" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
