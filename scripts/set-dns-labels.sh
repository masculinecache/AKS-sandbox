#!/usr/bin/env bash
set -euo pipefail

RG_NAME="rg-sandbox-aks"
CLUSTER_NAME="sandbox-aks"
NGINX_DNS_LABEL="echo-nginx"
CILIUM_DNS_LABEL="echo-cilium"
NGINX_ONLY=false
CILIUM_ONLY=false

for arg in "$@"; do
  case $arg in
    --nginx-only) NGINX_ONLY=true ;;
    --cilium-only) CILIUM_ONLY=true ;;
  esac
done

if ! kubectl cluster-info &>/dev/null; then
  az aks get-credentials --resource-group "$RG_NAME" --name "$CLUSTER_NAME" --overwrite-existing
fi

NODE_RG="MC_${RG_NAME}_${CLUSTER_NAME}_centralus"

set_dns_label() {
  local IP=$1
  local DNS_LABEL=$2
  local PIP_NAME
  local CURRENT_DNS

  PIP_NAME=$(az network public-ip list --resource-group "$NODE_RG" --query "[?ipAddress=='$IP'].name | [0]" -o tsv 2>/dev/null || true)
  if [[ -z "$PIP_NAME" ]]; then
    echo "  ❌ Could not find PIP for IP $IP"
    return 1
  fi

  CURRENT_DNS=$(az network public-ip show --resource-group "$NODE_RG" --name "$PIP_NAME" --query "dnsSettings.domainNameLabel" -o tsv 2>/dev/null || true)
  if [[ "$CURRENT_DNS" == "$DNS_LABEL" ]]; then
    echo "  ✅ DNS label already set: $DNS_LABEL"
    return 0
  fi

  echo "  📝 Setting DNS label to '$DNS_LABEL'..."
  az network public-ip update --resource-group "$NODE_RG" --name "$PIP_NAME" --dns-name "$DNS_LABEL" --query "dnsSettings.fqdn" -o tsv
  echo "  ✅ DNS label set"
}

if [[ "$CILIUM_ONLY" != "true" ]]; then
  echo "  Looking for ingress-nginx LB IP..."
  NGINX_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [[ -z "$NGINX_IP" || "$NGINX_IP" == "<nil>" ]]; then
    for i in {1..30}; do
      sleep 10
      NGINX_IP=$(kubectl get service -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      if [[ -n "$NGINX_IP" && "$NGINX_IP" != "<nil>" ]]; then break; fi
    done
  fi

  if [[ -n "$NGINX_IP" && "$NGINX_IP" != "<nil>" ]]; then
    echo "  ✅ ingress-nginx LB IP: $NGINX_IP"
    set_dns_label "$NGINX_IP" "$NGINX_DNS_LABEL"
  else
    echo "  ⚠️  ingress-nginx LB IP not available"
  fi
fi

if [[ "$NGINX_ONLY" != "true" ]]; then
  echo "  Looking for Cilium ingress LB IP..."

  if ! helm list -n kube-system -q | grep -q "^cilium$" 2>/dev/null; then
    echo "  ⚠️  Cilium not installed yet. Run 'make step2' first."
    exit 0
  fi

  CILIUM_IP=$(kubectl get service -n kube-system cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z "$CILIUM_IP" || "$CILIUM_IP" == "<nil>" ]]; then
    for i in {1..30}; do
      sleep 10
      CILIUM_IP=$(kubectl get service -n kube-system cilium-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      if [[ -n "$CILIUM_IP" && "$CILIUM_IP" != "<nil>" ]]; then break; fi
    done
  fi

  if [[ -n "$CILIUM_IP" && "$CILIUM_IP" != "<nil>" ]]; then
    echo "  ✅ Cilium ingress LB IP: $CILIUM_IP"
    set_dns_label "$CILIUM_IP" "$CILIUM_DNS_LABEL"
  else
    echo "  ⚠️  Cilium ingress LB IP not available"
  fi
fi

echo ""
echo "🎉 DNS labels configured"
