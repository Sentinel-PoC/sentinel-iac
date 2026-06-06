#!/usr/bin/env bash
# stash-kubeconfig.sh — write cluster credentials to Vault for operator/agent retrieval.
#
# Vault layout (single-version KV v2):
#   secret/okd-sandbox
#     kubeconfig           — full kubeconfig contents (multiline)
#     kubeadmin_password   — initial kubeadmin password
#     api_url              — https://api.okd-sandbox.sandbox.208.haist.farm:6443
#     stashed_at           — ISO 8601 timestamp
#
# Re-running overwrites in place. Operators retrieve with:
#   vault kv get -field=kubeconfig secret/okd-sandbox > ~/.kube/config-okd-sandbox

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/../_work"
KCFG="${WORK}/auth/kubeconfig"
KPWD="${WORK}/auth/kubeadmin-password"

[[ -f "$KCFG" ]] || { echo "kubeconfig not found at $KCFG. Did install-complete succeed?" >&2; exit 1; }
[[ -f "$KPWD" ]] || { echo "kubeadmin-password not found at $KPWD." >&2; exit 1; }

: "${VAULT_ADDR:=https://vault.208.haist.farm}"
export VAULT_ADDR
vault token lookup >/dev/null

vault kv put secret/okd-sandbox \
  kubeconfig="@${KCFG}" \
  kubeadmin_password="$(cat "$KPWD")" \
  api_url="https://api.okd-sandbox.sandbox.208.haist.farm:6443" \
  stashed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "[stash] wrote secret/okd-sandbox"
