#\!/bin/bash
set -e
echo "=== EMERGENCY SERVICE MESH ROLLBACK ==="

for ns in demo homepage monitoring media; do
  echo "Removing injection from $ns..."
  oc label namespace $ns istio-injection- 2>/dev/null || true
  oc rollout restart deployment -n $ns 2>/dev/null || true
done

echo "Removing mesh policies..."
oc delete peerauthentication --all -A 2>/dev/null || true
oc delete authorizationpolicy --all -A 2>/dev/null || true
oc delete destinationrule --all -A 2>/dev/null || true

echo "Removing Istio control plane..."
oc delete istio default 2>/dev/null || true

echo "Removing Istio CNI..."
oc delete istiocni default 2>/dev/null || true

echo "Waiting for pods to restart..."
sleep 30

oc delete namespace istio-system istio-cni observability 2>/dev/null || true

echo "=== ROLLBACK COMPLETE ==="
