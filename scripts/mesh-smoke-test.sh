#\!/bin/bash
set -e
echo "=== Istio Mesh Smoke Test ==="

echo "--- Sail Operator ---"
oc get csv -n openshift-operators | grep sail

echo "--- Sail Custom Resources ---"
echo "IstioCNI:"
oc get istiocni default -o jsonpath="  Ready: {.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"
echo "Istio:"
oc get istio default -o jsonpath="  Ready: {.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}"

echo "--- Control Plane ---"
oc get pods -n istio-system
oc get pods -n istio-cni

echo "--- Observability Stack ---"
oc get pods -n observability

echo "--- Sidecar Status ---"
for ns in demo homepage monitoring media; do
  PODS=$(oc get pods -n $ns -o jsonpath="{range .items[*]}{.metadata.name}: {range .spec.containers[*]}{.name} {end}{\"\\n\"}{end}" 2>/dev/null)
  if echo "$PODS" | grep -q "istio-proxy"; then
    echo "  $ns: MESHED"
  else
    echo "  $ns: NOT MESHED"
  fi
done

echo "--- mTLS Status ---"
oc get peerauthentication -A

echo "--- Authorization Policies ---"
oc get authorizationpolicy -A

echo "--- ServiceMonitors ---"
oc get servicemonitor -n istio-system

echo "--- Service Accessibility ---"
for svc in hello-demo.apps.overwatch.haist.farm home.208.haist.farm grafana.208.haist.farm kiali.208.haist.farm jaeger.208.haist.farm; do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "https://$svc" 2>/dev/null || echo "FAIL")
  echo "  $svc: $STATUS"
done

echo "=== Smoke Test Complete ==="
