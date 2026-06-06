#!/usr/bin/env bash
# render.sh — populate install-config.yaml + agent-config.yaml from templates.
#
# Inputs:
#   - install-config.yaml.tpl, agent-config.yaml.tpl (in this directory)
#   - Vault secrets (read with the operator's existing token):
#       * secret/okd-sandbox/ssh        public_key, private_key   (created on first run)
#       * secret/okd-sandbox/pull       pull_secret                (placeholder for now;
#                                                                  see Q2 — quay.io/okd
#                                                                  egress sufficient for
#                                                                  bring-up, no Red Hat
#                                                                  pull secret required)
#
# Outputs (written to ../_work/, NOT committed):
#   - ../_work/install-config.yaml
#   - ../_work/agent-config.yaml
#   - ../_work/ssh_key, ../_work/ssh_key.pub  (mode 0600 / 0644)
#
# Idempotent: re-running with no Vault changes produces identical files.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/../_work"
mkdir -p "$WORK"

: "${VAULT_ADDR:=https://vault.208.haist.farm}"
export VAULT_ADDR

# --- 1. Ensure SSH keypair in Vault. Auto-generate on first run. ----------
if ! vault kv get -field=public_key secret/okd-sandbox/ssh >/dev/null 2>&1; then
  echo "[render] generating new SSH keypair for okd-sandbox break-glass access..."
  TMPKEY="$(mktemp -d)"
  ssh-keygen -t ed25519 -N '' -C 'okd-sandbox-break-glass' -f "${TMPKEY}/id" >/dev/null
  vault kv put secret/okd-sandbox/ssh \
    public_key="$(cat "${TMPKEY}/id.pub")" \
    private_key="@${TMPKEY}/id" >/dev/null
  rm -rf "$TMPKEY"
fi

vault kv get -field=public_key  secret/okd-sandbox/ssh > "${WORK}/ssh_key.pub"
vault kv get -field=private_key secret/okd-sandbox/ssh > "${WORK}/ssh_key"
chmod 0600 "${WORK}/ssh_key"
chmod 0644 "${WORK}/ssh_key.pub"

# --- 2. Pull secret. Placeholder for now (Q2). ----------------------------
# OKD-SCOS pulls from quay.io/okd are anonymous; a stub `{}` pullSecret is
# accepted by openshift-install. When/if the cluster is moved to the internal
# mirror, the real Vault path is secret/okd-sandbox/pull field pull_secret.
PULL_SECRET="$(vault kv get -field=pull_secret secret/okd-sandbox/pull 2>/dev/null || echo '{}')"

# --- 3. Static / operator-decided values. ---------------------------------
# Per Q3: machineNetwork = 192.168.12.0/24; reserved IPs .220-.224.
export MACHINE_NETWORK_CIDR="${MACHINE_NETWORK_CIDR:-192.168.12.0/24}"
export API_VIP="${API_VIP:-192.168.12.223}"
export INGRESS_VIP="${INGRESS_VIP:-192.168.12.224}"
export GATEWAY="${GATEWAY:-192.168.12.1}"
export UPSTREAM_DNS="${UPSTREAM_DNS:-192.168.12.1}"

export MASTER_1_IP="${MASTER_1_IP:-192.168.12.220}"
export MASTER_2_IP="${MASTER_2_IP:-192.168.12.221}"
export MASTER_3_IP="${MASTER_3_IP:-192.168.12.222}"
export MASTER_1_MAC="${MASTER_1_MAC:-BC:24:11:00:01:20}"
export MASTER_2_MAC="${MASTER_2_MAC:-BC:24:11:00:01:21}"
export MASTER_3_MAC="${MASTER_3_MAC:-BC:24:11:00:01:22}"

export PULL_SECRET
SSH_PUBLIC_KEY="$(cat "${WORK}/ssh_key.pub")"
export SSH_PUBLIC_KEY

# --- 4. envsubst — only the placeholders we declare. -----------------------
# shellcheck disable=SC2016  # single quotes intentional — envsubst expands these
SUBSTS='${MACHINE_NETWORK_CIDR} ${API_VIP} ${INGRESS_VIP} ${PULL_SECRET} ${SSH_PUBLIC_KEY} ${MASTER_1_IP} ${MASTER_2_IP} ${MASTER_3_IP} ${MASTER_1_MAC} ${MASTER_2_MAC} ${MASTER_3_MAC} ${UPSTREAM_DNS} ${GATEWAY}'

envsubst "$SUBSTS" < "${HERE}/install-config.yaml.tpl" > "${WORK}/install-config.yaml"
envsubst "$SUBSTS" < "${HERE}/agent-config.yaml.tpl"   > "${WORK}/agent-config.yaml"

echo "[render] wrote ${WORK}/install-config.yaml"
echo "[render] wrote ${WORK}/agent-config.yaml"
