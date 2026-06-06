#!/usr/bin/env bash
# 03-default-storageclass.sh — make `local-storage` the cluster default SC.
#
# Per Q5 — Jim's standard RH bare-metal compact-cluster pattern. Without this
# step PVCs that omit storageClassName fail to bind.
#
# Idempotent: re-running on a cluster where local-storage is already default
# is a no-op (the patch is JSON-merge-equivalent).

set -euo pipefail

: "${KUBECONFIG:?KUBECONFIG must point at the sandbox kubeconfig}"

# Wait up to 60s for the SC to exist (LocalVolume creates it after the operator
# rolls out its DaemonSet — typically 30-60s after `oc apply -f 02-local-volume.yaml`).
for i in $(seq 1 30); do
  if oc get sc local-storage >/dev/null 2>&1; then break; fi
  echo "[default-sc] waiting for storageclass/local-storage (${i}/30)..."
  sleep 2
done
oc get sc local-storage >/dev/null

# Drop any existing default flag, then set local-storage as default.
oc get sc -o json \
  | jq -r '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true") | .metadata.name' \
  | while read -r SC; do
      [[ -n "$SC" ]] || continue
      [[ "$SC" == "local-storage" ]] && continue
      echo "[default-sc] removing default flag from ${SC}"
      oc patch sc "$SC" -p \
        '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
    done

echo "[default-sc] setting local-storage as default"
oc patch sc local-storage -p \
  '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

oc get sc
