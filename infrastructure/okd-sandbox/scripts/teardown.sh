#!/usr/bin/env bash
# teardown.sh — bring the sandbox cluster down.
#
# Usage:
#   teardown.sh soft   # terraform destroy only; leave Vault stash + ISO + state in place
#   teardown.sh hard   # soft + delete Vault stash, _work/, and the ISO from PVE hosts
#
# Idempotent: re-running with the cluster already down is a no-op (and prints OK).
# Drill iteration cost is the dominant constraint here — both modes must be safe to
# run from any state without manual cleanup.

set -euo pipefail

MODE="${1:-soft}"
case "$MODE" in
  soft|hard) ;;
  *) echo "Usage: $0 [soft|hard]" >&2; exit 64 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HERE}/.."
TF_DIR="${ROOT}/terraform"
WORK="${ROOT}/_work"

: "${VAULT_ADDR:=https://vault.208.haist.farm}"
export VAULT_ADDR

# 1. Terraform destroy ----------------------------------------------------
if [[ -d "${TF_DIR}/.terraform" ]]; then
  echo "[teardown] terraform destroy"
  TF_VAR_proxmox_api_token="$(vault kv get -field=api_token secret/proxmox/terraform-prov 2>/dev/null || true)" \
    tofu -chdir="${TF_DIR}" destroy -auto-approve || \
    echo "[teardown][WARN] terraform destroy returned non-zero. State may be partial; check Proxmox UI."
else
  echo "[teardown] terraform never initialized in ${TF_DIR}; nothing to destroy"
fi

[[ "$MODE" == "soft" ]] && { echo "[teardown] soft complete"; exit 0; }

# 2. Hard mode: rm -rf _work/, drop Vault stash, remove ISO from PVE -----
echo "[teardown] hard mode — removing _work/, Vault stash, and ISOs from PVE hosts"

rm -rf "${WORK}"

vault kv metadata delete secret/okd-sandbox 2>/dev/null || true

# Best-effort ISO removal. Operator must have ssh root@<pve> trust set up.
for HOST in pve3 208-pve2; do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "root@${HOST}" \
    'rm -f /var/lib/vz/template/iso/okd-sandbox-agent.x86_64.iso' \
    2>/dev/null && echo "[teardown] removed ISO on ${HOST}" \
    || echo "[teardown][WARN] could not remove ISO on ${HOST} (network or perms)"
done

echo "[teardown] hard complete"
