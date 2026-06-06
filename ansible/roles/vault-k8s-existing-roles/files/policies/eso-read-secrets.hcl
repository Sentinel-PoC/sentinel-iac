# eso-read-secrets — Vault policy for External Secrets Operator
#
# Grants ESO controller pods read-only access to all application secrets
# in the KV v2 secret/ mount. Used by the vault-backend ClusterSecretStore
# which populates Kubernetes Secrets across all managed namespaces.
#
# Bound to: auth/kubernetes/role/external-secrets
# Service accounts: external-secrets, external-secrets-operator, vault-auth,
#                   default (in multiple OKD namespaces)
#
# Codified from live Vault — OPS-1206 (originally provisioned out-of-band)

# ESO read-only access to all application secrets
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
