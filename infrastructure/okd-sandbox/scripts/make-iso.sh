#!/usr/bin/env bash
# make-iso.sh — generate the agent-based-installer ISO.
#
# Inputs:  ../_work/{install-config.yaml, agent-config.yaml}  (from render.sh)
# Outputs: ../_work/agent.x86_64.iso (~1 GB)
#          ../_work/auth/{kubeconfig, kubeadmin-password}
#          ../_work/.openshift_install.log + .openshift_install_state.json
#
# `openshift-install agent create image` consumes install-config + agent-config
# in-place and rewrites the directory. We therefore work in a fresh manifest
# subdirectory, then copy the produced ISO back up.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${HERE}/../_work"
MANIFEST_DIR="${WORK}/manifests"

[[ -f "${WORK}/install-config.yaml" ]] || { echo "Run install/render.sh first." >&2; exit 1; }
[[ -f "${WORK}/agent-config.yaml"   ]] || { echo "Run install/render.sh first." >&2; exit 1; }

rm -rf "$MANIFEST_DIR"
mkdir -p "$MANIFEST_DIR"
cp "${WORK}/install-config.yaml" "${MANIFEST_DIR}/install-config.yaml"
cp "${WORK}/agent-config.yaml"   "${MANIFEST_DIR}/agent-config.yaml"

echo "[iso] running: openshift-install agent create image --dir ${MANIFEST_DIR}"
openshift-install agent create image --dir "${MANIFEST_DIR}" --log-level=info

# Hoist the ISO + auth bundle to the predictable _work paths the Makefile
# uploads from.
cp "${MANIFEST_DIR}/agent.x86_64.iso" "${WORK}/agent.x86_64.iso"
mkdir -p "${WORK}/auth"
cp "${MANIFEST_DIR}/auth/kubeconfig"        "${WORK}/auth/kubeconfig"        2>/dev/null || true
cp "${MANIFEST_DIR}/auth/kubeadmin-password" "${WORK}/auth/kubeadmin-password" 2>/dev/null || true

# Also stash the install log in a stable place — wait-bootstrap reads it on failure.
cp "${MANIFEST_DIR}/.openshift_install.log" "${WORK}/.openshift_install.log" 2>/dev/null || true

ls -lh "${WORK}/agent.x86_64.iso"
echo "[iso] done"
