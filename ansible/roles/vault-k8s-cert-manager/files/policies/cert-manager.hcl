# cert-manager Vault policy — OPS-1202
#
# Grants cert-manager controller permission to sign TLS certificates
# via the pki_int intermediate CA using the 208-haist-farm role.
#
# Bound to: auth/kubernetes/role/cert-manager
# Service account: cert-manager/cert-manager (OKD cluster)
# PKI role allows: *.208.haist.farm SAN/CN, max TTL 8760h
#
# NIST: SC-12 (key management), SC-17 (PKI cert issuance)
# Tracking: OPS-1202

path "pki_int/sign/208-haist-farm" {
  capabilities = ["create", "update"]
}
