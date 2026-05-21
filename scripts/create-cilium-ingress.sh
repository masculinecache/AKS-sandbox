#!/usr/bin/env bash
set -euo pipefail

# Creates the Cilium ingress for echo-cilium.
# Run this AFTER Cilium is installed (make step2).

INGRESS_NAME="echo-server-cilium-ingress"
NAMESPACE="echo-server-cilium"
HOST="echo-cilium.centralus.cloudapp.azure.com"

echo "  Creating Cilium ingress: $INGRESS_NAME"

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $INGRESS_NAME
  namespace: $NAMESPACE
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt"
    acme.cert-manager.io/http01-edit-in-place: "true"
spec:
  ingressClassName: cilium
  rules:
  - host: $HOST
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: echo-server-cilium
            port:
              number: 80
  tls:
  - hosts:
    - $HOST
    secretName: echo-cilium-tls
EOF

echo "  Waiting for certificate to be issued..."
for i in {1..60}; do
    STATUS=$(kubectl get certificate echo-cilium-tls -n $NAMESPACE -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
    if [[ "$STATUS" == "True" ]]; then
        echo "  ✅ Certificate ready"
        exit 0
    fi
    echo "    ⏳ Waiting for certificate... ($i/60)"
    sleep 10
done

echo "  ⚠️  Certificate not ready after 10 minutes. Check:"
echo "     kubectl describe certificate echo-cilium-tls -n $NAMESPACE"
exit 1
