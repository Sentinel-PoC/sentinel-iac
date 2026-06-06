# autounseal-rotate-policy.hcl
# Vault policy for the auto-unseal token rotation service (OPS-191).
#
# Applied on the TRANSIT VAULT (iac-control, http://192.168.12.210:8201),
# NOT on the prod Vault.
#
# This policy is bound to the rotation-token: the long-lived orphan periodic
# token stored at /etc/vault-unseal/rotation-token (0400 ubuntu:root on
# iac-control).  The timer vault-autounseal-rotate.timer reads this token
# and uses it to:
#   1. Renew itself (token/renew-self) so the rotation-token never expires
#      as long as the weekly timer fires.
#   2. Create a new periodic child token with the autounseal policy (to replace
#      the token embedded in /etc/vault/config/config.hcl on vault-server).
#   3. Revoke the old autounseal token by accessor after the new one is
#      confirmed working.
#
# Bootstrap: create this policy on the transit vault, then issue the
# rotation-token (see docs/runbooks/15-vault-autounseal-rotation.md §Bootstrap).
#
# NIST: SC-12, IA-5, CM-3

# Renew itself — keeps the rotation-token alive between weekly runs.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# Look up itself — for pre-flight validation and accessor logging.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# Create a new child token bound to the autounseal-rotation token role.
# Scoped to the role path — prevents this token from creating arbitrary
# child tokens with any policy.  The role (created by
# ansible/playbooks/vault-transit-tokenrole.yml) sets
# allowed_policies=["autounseal"], orphan=true, period=800h.
path "auth/token/create/autounseal-rotation" {
  capabilities = ["update"]
}

# Revoke the old autounseal token by accessor — cleans up after rotation.
# We never hold the old token value; we only hold its accessor.
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}
