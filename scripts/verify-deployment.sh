#!/usr/bin/env bash
set -euo pipefail

NGINX_URL="https://echo-nginx.centralus.cloudapp.azure.com"
CILIUM_URL="https://echo-cilium.centralus.cloudapp.azure.com"
MAX_RETRIES=30
RETRY_DELAY=10
FAILED=0

echo "  Testing echo-nginx endpoint: $NGINX_URL"
NGINX_OK=0
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sfI "$NGINX_URL" -o /dev/null 2>/dev/null; then
    NGINX_OK=1; break
  fi
  echo "    ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
  sleep $RETRY_DELAY
done

if [[ $NGINX_OK -eq 1 ]]; then
  echo "    ✅ echo-nginx is responding"
  curl -svI "$NGINX_URL" 2>&1 | grep -E "(subject:|SSL connection|HTTP/)" | sed 's/^/      /'
else
  echo "    ❌ echo-nginx failed after $MAX_RETRIES attempts"
  FAILED=1
fi

echo ""

if ! helm list -n kube-system -q | grep -q "^cilium$" 2>/dev/null; then
  echo "  ⚠️  Cilium not installed — skipping echo-cilium verification"
  echo "       Run 'make step2' to install Cilium, then run 'make verify' again"
  if [[ $FAILED -eq 1 ]]; then exit 1; fi
  exit 0
fi

echo "  Testing echo-cilium endpoint: $CILIUM_URL"
CILIUM_OK=0
for i in $(seq 1 $MAX_RETRIES); do
  if curl -sfI "$CILIUM_URL" -o /dev/null 2>/dev/null; then
    CILIUM_OK=1; break
  fi
  echo "    ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
  sleep $RETRY_DELAY
done

if [[ $CILIUM_OK -eq 1 ]]; then
  echo "    ✅ echo-cilium is responding"
  curl -svI "$CILIUM_URL" 2>&1 | grep -E "(subject:|SSL connection|HTTP/|server:)" | sed 's/^/      /'
else
  echo "    ❌ echo-cilium failed after $MAX_RETRIES attempts"
  FAILED=1
fi

echo ""
echo "  Certificate status:"
kubectl get certificate -A 2>/dev/null | sed 's/^/    /' || true

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "🎉 All endpoints verified!"
  echo "   echo-nginx:  $NGINX_URL"
  echo "   echo-cilium: $CILIUM_URL"
else
  echo "❌ Some endpoints failed"
  echo "  Troubleshooting:"
  echo "    dig +short echo-nginx.centralus.cloudapp.azure.com"
  echo "    kubectl describe certificate -A"
  echo "    kubectl get ingress -A"
  echo "    kubectl get ciliumendpoint -A"
  exit 1
fi
