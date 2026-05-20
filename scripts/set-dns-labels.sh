#!/usr/bin/env bash
set -euo pipefail

# ── set-dns-labels.sh ──────────────────────────────────────────────────────────
# Automatically sets Azure DNS labels on Load Balancer public IPs.
# Must run after ingress controllers have created their LoadBalancer services.
#
# This script:
# 1. Finds the ingress-nginx LB public IP
# 2. Finds the Cilium ingress LB public IP (if Cilium is installed)
# 3. Sets DNS labels on both PIPs
# ────────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG_NAME="rg-sandbox-aks"
CLUSTER_NAME="sandbox-aks"
NGINX_DNS_LABEL="echo-nginx"
CILIUM_DNS_LABEL="echo-cilium"

echo "🔍 Finding Load Balancer public IPs..."

# Get kubeconfig if needed
if ! kubectl cluster-info &>/dev/null; then
    echo "  Getting AKS credentials..."
    az aks get-credentials --resource-group "$RG_NAME" --name "$CLUSTER_NAME" --overwrite-existing
fi

# Get the node resource group (where Azure manages LB resources)
NODE_RG="MC_${RG_NAME}_${CLUSTER_NAME}_centralus"

# ── ingress-nginx LB IP ────────────────────────────────────────────────────────
echo "  Looking for ingress-nginx LB IP..."
NGINX_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "$NGINX_IP" || "$NGINX_IP" == "<nil>" ]]; then
    echo "  ⚠️  ingress-nginx LoadBalancer IP not found yet. Waiting..."
    for i in {1..30}; do
        sleep 10
        NGINX_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [[ -n "$NGINX_IP" && "$NGINX_IP" != "<nil>" ]]; then
            break
        fi
        echo "  ⏳ Waiting for ingress-nginx LB IP... ($i/30)"
    done
fi

if [[ -z "$NGINX_IP" || "$NGINX_IP" == "<nil>" ]]; then
    echo "  ❌ Failed to get ingress-nginx LoadBalancer IP after 5 minutes"
    exit 1
fi

echo "  ✅ ingress-nginx LB IP: $NGINX_IP"

# Find the PIP name for this IP
NGINX_PIP_NAME=$(az network public-ip list \
    --resource-group "$NODE_RG" \
    --query "[?ipAddress=='$NGINX_IP'].name | [0]" \
    -o tsv 2>/dev/null || true)

if [[ -z "$NGINX_PIP_NAME" ]]; then
    echo "  ❌ Could not find PIP for ingress-nginx IP $NGINX_IP"
    exit 1
fi

echo "  Found PIP: $NGINX_PIP_NAME"

# Check current DNS settings
CURRENT_NGINX_DNS=$(az network public-ip show \
    --resource-group "$NODE_RG" \
    --name "$NGINX_PIP_NAME" \
    --query "dnsSettings.domainNameLabel" \
    -o tsv 2>/dev/null || true)

if [[ "$CURRENT_NGINX_DNS" == "$NGINX_DNS_LABEL" ]]; then
    echo "  ✅ DNS label already set: $NGINX_DNS_LABEL"
else
    echo "  📝 Setting DNS label to '$NGINX_DNS_LABEL'..."
    az network public-ip update \
        --resource-group "$NODE_RG" \
        --name "$NGINX_PIP_NAME" \
        --dns-name "$NGINX_DNS_LABEL" \
        --query "dnsSettings.fqdn" \
        -o tsv
    echo "  ✅ DNS label set"
fi

# ── Cilium ingress LB IP ───────────────────────────────────────────────────────
echo ""
echo "  Looking for Cilium ingress LB IP..."

# Check if Cilium is installed
if ! helm list -n kube-system -q | grep -q "^cilium$" 2>/dev/null; then
    echo "  ⚠️  Cilium not installed yet. Skipping Cilium ingress DNS label."
    echo "     Run this script again after installing Cilium: make phase5"
    exit 0
fi

# Find the Cilium ingress service
CILIUM_SVC=$(kubectl get service -n echo-server-cilium -l io.cilium/lb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$CILIUM_SVC" ]]; then
    echo "  ⚠️  Cilium ingress LoadBalancer service not found. Waiting..."
    for i in {1..30}; do
        sleep 10
        CILIUM_SVC=$(kubectl get service -n echo-server-cilium -l io.cilium/lb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        if [[ -n "$CILIUM_SVC" ]]; then
            break
        fi
        echo "  ⏳ Waiting for Cilium ingress LB service... ($i/30)"
    done
fi

if [[ -z "$CILIUM_SVC" ]]; then
    echo "  ⚠️  No Cilium ingress LoadBalancer service found. Skipping."
    echo "     If you have a Cilium ingress, ensure it has spec.ingressClassName: cilium"
    exit 0
fi

CILIUM_IP=$(kubectl get service -n echo-server-cilium "$CILIUM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

if [[ -z "$CILIUM_IP" || "$CILIUM_IP" == "<nil>" ]]; then
    echo "  ⚠️  Cilium ingress LB IP not ready yet. Waiting..."
    for i in {1..30}; do
        sleep 10
        CILIUM_IP=$(kubectl get service -n echo-server-cilium "$CILIUM_SVC" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [[ -n "$CILIUM_IP" && "$CILIUM_IP" != "<nil>" ]]; then
            break
        fi
        echo "  ⏳ Waiting for Cilium ingress LB IP... ($i/30)"
    done
fi

if [[ -z "$CILIUM_IP" || "$CILIUM_IP" == "<nil>" ]]; then
    echo "  ⚠️  Failed to get Cilium ingress LoadBalancer IP after 5 minutes"
    echo "     You may need to run this script again later: make phase5"
    exit 0
fi

echo "  ✅ Cilium ingress LB IP: $CILIUM_IP"

# Find the PIP name for this IP
CILIUM_PIP_NAME=$(az network public-ip list \
    --resource-group "$NODE_RG" \
    --query "[?ipAddress=='$CILIUM_IP'].name | [0]" \
    -o tsv 2>/dev/null || true)

if [[ -z "$CILIUM_PIP_NAME" ]]; then
    echo "  ❌ Could not find PIP for Cilium ingress IP $CILIUM_IP"
    exit 1
fi

echo "  Found PIP: $CILIUM_PIP_NAME"

# Check current DNS settings
CURRENT_CILIUM_DNS=$(az network public-ip show \
    --resource-group "$NODE_RG" \
    --name "$CILIUM_PIP_NAME" \
    --query "dnsSettings.domainNameLabel" \
    -o tsv 2>/dev/null || true)

if [[ "$CURRENT_CILIUM_DNS" == "$CILIUM_DNS_LABEL" ]]; then
    echo "  ✅ DNS label already set: $CILIUM_DNS_LABEL"
else
    echo "  📝 Setting DNS label to '$CILIUM_DNS_LABEL'..."
    az network public-ip update \
        --resource-group "$NODE_RG" \
        --name "$CILIUM_PIP_NAME" \
        --dns-name "$CILIUM_DNS_LABEL" \
        --query "dnsSettings.fqdn" \
        -o tsv
    echo "  ✅ DNS label set"
fi

echo ""
echo "🎉 DNS labels configured:"
echo "   echo-nginx:  https://$NGINX_DNS_LABEL.centralus.cloudapp.azure.com"
echo "   echo-cilium: https://$CILIUM_DNS_LABEL.centralus.cloudapp.azure.com"
