#!/usr/bin/env bash
set -euo pipefail

# ── install-cilium.sh ───────────────────────────────────────────────────────────
# Installs Cilium 1.19.4 with best-practice settings for Azure CNI chaining.
#
# Configuration:
# - generic-veth CNI chaining (works with Azure CNI)
# - Native routing (required for DSR mode)
# - DSR load balancer mode for optimal performance
# - Custom CNI ConfigMap with correct key name: cni-config
# - Ingress controller enabled with dedicated LB mode
# - Masquerade to route source for cross-node connectivity
# ────────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CILIUM_VERSION="1.19.4"

echo "🔧 Installing Cilium ${CILIUM_VERSION}..."

# Add Cilium Helm repo if not present
if ! helm repo list | grep -q "^cilium " 2>/dev/null; then
    echo "  Adding Cilium Helm repo..."
    helm repo add cilium https://helm.cilium.io/
fi

echo "  Updating Helm repos..."
helm repo update cilium

# Get AKS VNet CIDR for native routing
RG_NAME="rg-sandbox-aks"
CLUSTER_NAME="sandbox-aks"

echo "  Detecting AKS VNet configuration..."
if ! kubectl cluster-info &>/dev/null; then
    echo "  Getting AKS credentials..."
    az aks get-credentials --resource-group "$RG_NAME" --name "$CLUSTER_NAME" --overwrite-existing
fi

# Get VNet address space from the cluster's node resource group
NODE_RG="MC_${RG_NAME}_${CLUSTER_NAME}_centralus"
VNET_CIDR=$(az network vnet list \
    --resource-group "$NODE_RG" \
    --query "[0].addressSpace.addressPrefixes[0]" \
    -o tsv 2>/dev/null || true)

if [[ -z "$VNET_CIDR" ]]; then
    echo "  ⚠️  Could not detect VNet CIDR, using default 10.224.0.0/12"
    VNET_CIDR="10.224.0.0/12"
fi

echo "  Using native routing CIDR: $VNET_CIDR"

# Create the CNI ConfigMap with the CORRECT key name: cni-config
# This is critical - Cilium expects the key to be exactly "cni-config"
echo "  Creating Cilium CNI configuration ConfigMap..."
kubectl create configmap cilium-cni-configuration -n kube-system \
    --from-literal=cni-config='{
  "cniVersion": "0.3.1",
  "name": "azure",
  "plugins": [
    {
      "type": "azure-vnet",
      "mode": "transparent",
      "ipsToRouteViaHost": ["169.254.20.10"],
      "ipam": {
        "type": "azure-vnet-ipam"
      }
    },
    {
      "type": "portmap",
      "capabilities": {
        "portMappings": true
      },
      "snat": true
    },
    {
      "type": "cilium-cni",
      "enable-debug": false
    }
  ]
}' --dry-run=client -o yaml | kubectl apply -f -

echo "  ✅ ConfigMap created/updated"

# Generate Cilium values file with native routing + DSR
cat > /tmp/cilium-values.yaml <<EOF
# Cilium ${CILIUM_VERSION} best-practice settings for Azure CNI chaining
cni:
  chainingMode: generic-veth
  customConf: true
  configMap: cilium-cni-configuration

# Native routing is required for DSR mode
# With Azure CNI, pods are on the VNet, so native routing works
routingMode: native
ipv4NativeRoutingCIDR: "${VNET_CIDR}"

# IPAM not needed with Azure CNI chaining (Azure CNI handles IPAM)
ipam:
  mode: kubernetes

# Disable BPF masquerade - use iptables-based masquerade
# Required for Azure CNI chaining compatibility
bpf:
  masquerade: false

enableIPv4Masquerade: true
enableMasqueradeToRouteSource: true

# Replace kube-proxy with eBPF
kubeProxyReplacement: true

# DSR mode for optimal load balancer performance
loadBalancer:
  mode: dsr

# Ingress controller configuration
ingressController:
  enabled: true
  default: false
  enforceHttps: true
  loadbalancerMode: dedicated

# Disable Hubble (not needed for this sandbox)
hubble:
  enabled: false

# Single operator replica (sufficient for small clusters)
operator:
  replicas: 1
EOF

echo "  Generated Cilium values with native routing + DSR"

# Install/upgrade Cilium
echo "  Installing Cilium..."
helm upgrade --install cilium cilium/cilium \
    --version "$CILIUM_VERSION" \
    --namespace kube-system \
    --values /tmp/cilium-values.yaml \
    --wait \
    --timeout 5m

echo "  ✅ Cilium installed"

# Wait for Cilium pods to be ready
echo "  Waiting for Cilium pods to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=cilium -n kube-system --timeout=300s

echo "  ✅ Cilium pods are ready"

# Verify Cilium status
echo ""
echo "  Cilium status:"
cilium status --brief 2>/dev/null || kubectl exec -n kube-system -l k8s-app=cilium -- cilium status --brief

echo ""
echo "🎉 Cilium ${CILIUM_VERSION} installed successfully with:"
echo "   - Azure CNI generic-veth chaining"
echo "   - Native routing (CIDR: ${VNET_CIDR})"
echo "   - DSR load balancer mode"
echo "   - Ingress controller enabled"
