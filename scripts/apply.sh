#!/usr/bin/env bash
set -euo pipefail

# AKS Sandbox — two-phase Terraform apply
#
# Phase 1: Infrastructure (resource group, AKS cluster, node pool)
#   These don't need the Kubernetes API and can be planned/applied from scratch.
#
# Phase 2: Everything else (Helm releases + Kubernetes manifests)
#   cert-manager → ingress-nginx → echo-server → ClusterIssuer → Ingresses
#
# Usage:
#   ./scripts/apply.sh            # full deployment (phases 1 + 2 + 2b)
#   ./scripts/apply.sh --phase 1  # infra only
#   ./scripts/apply.sh --phase 2  # helm releases only (cluster must exist)
#   ./scripts/apply.sh --plan     # plan all phases without applying

cd "$(dirname "$0")/../terraform"

PHASE="${1:-all}"
PLAN_ONLY=false

if [[ "$PHASE" == "--plan" ]]; then
  PLAN_ONLY=true
  PHASE="all"
elif [[ "$PHASE" == "--phase" ]]; then
  PHASE="$2"
fi

case "$PHASE" in
  1|all)
    echo "=== Phase 1: Infrastructure ==="
    if $PLAN_ONLY; then
      terraform plan -out=tfplan-phase1 \
        -target=azurerm_resource_group.main \
        -target=azurerm_kubernetes_cluster.main \
        -target=azurerm_kubernetes_cluster_node_pool.spot
    else
      terraform apply -auto-approve \
        -target=azurerm_resource_group.main \
        -target=azurerm_kubernetes_cluster.main \
        -target=azurerm_kubernetes_cluster_node_pool.spot
    fi
    ;;
esac

[[ "$PHASE" == "1" ]] && exit 0

case "$PHASE" in
  2|all)
    echo "=== Phase 2: Helm Releases ==="
    if $PLAN_ONLY; then
      terraform plan -out=tfplan-phase2 \
        -target=helm_release.cert_manager \
        -target=helm_release.ingress_nginx \
        -target=helm_release.echo_nginx \
        -target=helm_release.echo_cilium
    else
      terraform apply -auto-approve \
        -target=helm_release.cert_manager \
        -target=helm_release.ingress_nginx \
        -target=helm_release.echo_nginx \
        -target=helm_release.echo_cilium
    fi
    ;;
esac

[[ "$PHASE" == "2" ]] && exit 0

if [[ "$PHASE" == "all" ]]; then
  echo "=== Phase 3: ClusterIssuer + Ingresses ==="
  if $PLAN_ONLY; then
    terraform plan -out=tfplan
  else
    terraform apply -auto-approve
  fi
fi
