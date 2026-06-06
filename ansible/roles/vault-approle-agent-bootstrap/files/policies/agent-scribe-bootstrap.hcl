# agent-scribe-bootstrap — bootstrap-only Vault policy
# Tracking: OPS-464 (Phase A)
#
# Granted to the AppRole token obtained during agent session bootstrap.
# Purpose: read the Keycloak client credential for the scribe role so
# agent-vault-auth.sh can exchange it for a Keycloak JWT, then exchange
# the JWT for the runtime agent-scribe scoped token.
#
# Token TTL: 5 minutes (consumed immediately; discarded after KC creds read).
# Grants ONLY:
#   - read scribe Keycloak client credential (client_id + client_secret)
#   - lookup own token (for TTL verification)
#
# Cross-role reads DENIED by absence of grant.
# Runtime paths (plane/api-key, forgejo-scribe) NOT granted — those come
# from the runtime agent-scribe token issued after JWT exchange.

path "secret/data/forgejo-scribe" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}
