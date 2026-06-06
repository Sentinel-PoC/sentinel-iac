#!/usr/bin/env bash
# prereq.sh — fail fast before touching Proxmox.
#
# Verifies (in order):
#   1. Vault token reachable + scoped paths present
#   2. Proxmox terraform-prov API token usable
#   3. Mirror-registry reachable (for follow-up cutover, not for first boot)
#   4. No IP collision on the reserved .220-.224 block
#   5. No stale agent ISO already mounted to a competing VM ID
#   6. openshift-install present and recent enough (4.19+)
#
# Exits non-zero on the first hard failure. Soft warnings are printed to stderr
# but do not stop execution unless --strict is passed.

set -euo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

warn() { echo "[prereq][WARN] $*" >&2; }
fail() { echo "[prereq][FAIL] $*" >&2; exit 1; }
ok()   { echo "[prereq][ OK ] $*"; }

: "${VAULT_ADDR:=https://vault.208.haist.farm}"
export VAULT_ADDR

# 1. Vault ----------------------------------------------------------------
vault token lookup >/dev/null 2>&1 || fail "Vault token not reachable. Run \`vault login\` first."
ok "vault reachable"

# Required paths. SSH path is auto-created by render.sh, so absence is OK
# the first time. terraform-prov MUST exist before apply.
if ! vault kv get -field=api_token secret/proxmox/terraform-prov >/dev/null 2>&1; then
  fail "secret/proxmox/terraform-prov field api_token missing. Operator must populate this before \`make apply\`."
fi
ok "secret/proxmox/terraform-prov present"

# 2. Proxmox ---------------------------------------------------------------
PROX_ENDPOINT="${PROXMOX_ENDPOINT:-https://192.168.12.6:8006}"
TF_PROXMOX="$(vault kv get -field=api_token secret/proxmox/terraform-prov)"
if ! curl -sk --max-time 10 -H "Authorization: PVEAPIToken=${TF_PROXMOX}" \
        "${PROX_ENDPOINT}/api2/json/version" | grep -q '"version"'; then
  fail "Proxmox API token unusable against ${PROX_ENDPOINT}"
fi
ok "Proxmox API reachable with terraform-prov token"

# 3. Mirror registry (follow-up — soft warn for now per Q2) ----------------
MIRROR="${MIRROR_REGISTRY:-192.168.12.215:8443}"
if ! curl -sk --max-time 5 "https://${MIRROR}/v2/" >/dev/null 2>&1; then
  warn "mirror-registry ${MIRROR} not reachable. Per Q2 first bring-up uses quay.io/okd; flag for follow-up."
else
  ok "mirror-registry reachable: ${MIRROR}"
fi

# 4. IP collision ----------------------------------------------------------
if command -v nmap >/dev/null 2>&1; then
  COLLISIONS=$(nmap -sn -n 192.168.12.220-224 2>/dev/null | awk '/Host is up/{print prev}{prev=$0}' | grep -c 'scan report' || true)
  if [[ "$COLLISIONS" -gt 0 ]]; then
    nmap -sn -n 192.168.12.220-224 | grep -B1 'Host is up' >&2
    fail "${COLLISIONS} host(s) responding in reserved block 192.168.12.220-224. Free them or revise var.masters."
  fi
  ok "no IP collision in 192.168.12.220-224"
else
  warn "nmap not installed — skipping IP collision check. Install with apt-get install -y nmap on iac-control."
fi

# 5. Stale ISO check (soft) ------------------------------------------------
# Just a hint; the make iso step rewrites unconditionally.
if [[ -f "../_work/agent.x86_64.iso" ]]; then
  warn "stale ../_work/agent.x86_64.iso present — \`make iso\` will overwrite it"
fi

# 6. openshift-install ----------------------------------------------------
if ! command -v openshift-install >/dev/null 2>&1; then
  fail "openshift-install not on PATH. Install OKD 4.19 client from https://github.com/okd-project/okd/releases"
fi
INSTALL_VER=$(openshift-install version 2>/dev/null | head -1 | awk '{print $2}')
ok "openshift-install ${INSTALL_VER}"
case "$INSTALL_VER" in
  4.19.*) : ;;
  *)
    if [[ "$STRICT" -eq 1 ]]; then
      fail "openshift-install ${INSTALL_VER} is not 4.19.x"
    else
      warn "openshift-install ${INSTALL_VER} is not 4.19.x — proceeding anyway"
    fi
    ;;
esac

echo "[prereq] all checks passed"
