#!/usr/bin/env bash
set -euo pipefail

# ── verify-deployment.sh ────────────────────────────────────────────────────────
# Verifies that both ingress endpoints are serving valid TLS certificates.
#
# Checks:
# 1. echo-nginx endpoint (via ingress-nginx)
# 2. echo-cilium endpoint (via Cilium ingress, if installed)
# 3. Certificate validity and TLS version
# ────────────────────────────────────────────────────────────────────────────────

NGINX_URL="https://echo-nginx.centralus.cloudapp.azure.com"
CILIUM_URL="https://echo-cilium.centralus.cloudapp.azure.com"
MAX_RETRIES=30
RETRY_DELAY=10

FAILED=0

echo "🔍 Verifying deployment..."
echo ""

# ── Verify echo-nginx ──────────────────────────────────────────────────────────
echo "  Testing echo-nginx endpoint: $NGINX_URL"
NGINX_OK=0
for i in $(seq 1 $MAX_RETRIES); do
    if curl -sfI "$NGINX_URL" -o /dev/null 2>/dev/null; then
        NGINX_OK=1
        break
    fi
    echo "    ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done

if [[ $NGINX_OK -eq 1 ]]; then
    echo "    ✅ echo-nginx is responding"
    echo ""
    echo "    TLS details:"
    curl -svI "$NGINX_URL" 2>&1 | grep -E "(subject:|SSL connection|HTTP/)" | sed 's/^/      /'
else
    echo "    ❌ echo-nginx failed after $MAX_RETRIES attempts"
    FAILED=1
fi

echo ""

# ── Verify echo-cilium ─────────────────────────────────────────────────────────
echo "  Testing echo-cilium endpoint: $CILIUM_URL"

# Check if Cilium is installed
if ! helm list -n kube-system -q | grep -q "^cilium$" 2>/dev/null; then
    echo "    ⚠️  Cilium not installed - skipping echo-cilium verification"
    echo "       Run 'make phase6' to install Cilium, then run 'make verify' again"
    if [[ $FAILED -eq 1 ]]; then
        exit 1
    fi
    exit 0
fi

CILIUM_OK=0
for i in $(seq 1 $MAX_RETRIES); do
    if curl -sfI "$CILIUM_URL" -o /dev/null 2>/dev/null; then
        CILIUM_OK=1
        break
    fi
    echo "    ⏳ Attempt $i/$MAX_RETRIES failed, retrying in ${RETRY_DELAY}s..."
    sleep $RETRY_DELAY
done

if [[ $CILIUM_OK -eq 1 ]]; then
    echo "    ✅ echo-cilium is responding"
    echo ""
    echo "    TLS details:"
    curl -svI "$CILIUM_URL" 2>&1 | grep -E "(subject:|SSL connection|HTTP/|server:)" | sed 's/^/      /'
else
    echo "    ❌ echo-cilium failed after $MAX_RETRIES attempts"
    FAILED=1
fi

echo ""

# ── Check certificates ─────────────────────────────────────────────────────────
echo "  Checking certificate status in cluster:"
kubectl get certificate -A 2>/dev/null | sed 's/^/    /' || true

echo ""

# ── Summary ────────────────────────────────────────────────────────────────────
if [[ $FAILED -eq 0 ]]; then
    echo "🎉 All endpoints verified successfully!"
    echo ""
    echo "   echo-nginx:  $NGINX_URL"
    echo "   echo-cilium: $CILIUM_URL"
    exit 0
else
    echo "❌ Some endpoints failed verification"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check DNS propagation: dig +short echo-nginx.centralus.cloudapp.azure.com"
    echo "  2. Check certificate status: kubectl describe certificate -A"
    echo "  3. Check ingress status: kubectl get ingress -A"
    echo "  4. Check Cilium endpoints: kubectl get ciliumendpoint -A"
    exit 1
fi
