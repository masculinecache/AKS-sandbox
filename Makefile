# AKS Sandbox Deployment
# Two-step process:
#   Step 1: Cluster + ingress-nginx + cert-manager + echo-nginx
#   Step 2: Cilium + echo-cilium

.PHONY: all step1 step2 verify destroy clean

TERRAFORM_DIR := terraform
CLUSTER_NAME  := sandbox-aks
RG_NAME       := rg-sandbox-aks

# ── Full deployment ────────────────────────────────────────────────────────────
all: step1 step2 verify
	@echo "✅ Full deployment complete"

# ── Step 1: Base cluster + ingress-nginx + cert-manager + echo-nginx ──────────
step1:
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  Step 1: Base cluster + ingress-nginx + cert-manager + echo-nginx"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Phase 1.1: Creating Azure infrastructure..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=azurerm_resource_group.main \
		-target=azurerm_kubernetes_cluster.main \
		-target=azurerm_kubernetes_cluster_node_pool.spot
	@echo "  ✅ Infrastructure created"
	@echo ""
	@echo "  Phase 1.2: Installing cert-manager..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=helm_release.cert_manager \
		-target=time_sleep.wait_for_crds
	@echo "  ✅ cert-manager installed"
	@echo ""
	@echo "  Phase 1.3: Installing ingress-nginx and echo servers..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=helm_release.ingress_nginx \
		-target=helm_release.echo_nginx \
		-target=helm_release.echo_cilium
	@echo "  ✅ ingress-nginx and echo servers installed"
	@echo ""
	@echo "  Phase 1.4: Applying Kubernetes manifests..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve
	@echo "  ✅ Manifests applied"
	@echo ""
	@echo "  Phase 1.5: Setting DNS label for echo-nginx..."
	@./scripts/set-dns-labels.sh --nginx-only
	@echo "  ✅ DNS label set"
	@echo ""
	@echo "🎉 Step 1 complete!"
	@echo "   echo-nginx: https://echo-nginx.centralus.cloudapp.azure.com"
	@echo ""
	@echo "   Next: run 'make step2' to install Cilium and enable echo-cilium"

# ── Step 2: Install Cilium + create echo-cilium ingress ───────────────────────
step2:
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  Step 2: Install Cilium + create echo-cilium ingress"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo ""
	@echo "  Phase 2.1: Installing Cilium..."
	@./scripts/install-cilium.sh
	@echo "  ✅ Cilium installed"
	@echo ""
	@echo "  Phase 2.2: Restarting cert-manager for CiliumEndpoints..."
	@kubectl rollout restart deployment -n cert-manager
	@kubectl rollout status deployment -n cert-manager --timeout=120s
	@echo "  ✅ cert-manager restarted"
	@echo ""
	@echo "  Phase 2.3: Creating Cilium ingress for echo-cilium..."
	@./scripts/create-cilium-ingress.sh
	@echo "  ✅ Cilium ingress created"
	@echo ""
	@echo "  Phase 2.4: Setting DNS label for echo-cilium..."
	@./scripts/set-dns-labels.sh --cilium-only
	@echo "  ✅ DNS label set"
	@echo ""
	@echo "🎉 Step 2 complete!"
	@echo "   echo-cilium: https://echo-cilium.centralus.cloudapp.azure.com"

# ── Verify deployment ──────────────────────────────────────────────────────────
verify:
	@echo ""
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo "  Verification"
	@echo "═══════════════════════════════════════════════════════════════════"
	@echo ""
	@./scripts/verify-deployment.sh

# ── Destroy everything ─────────────────────────────────────────────────────────
destroy:
	@echo "💥 Destroying all resources..."
	cd $(TERRAFORM_DIR) && terraform destroy -auto-approve
	@echo "✅ Destroy complete"

# ── Clean up kubeconfig ────────────────────────────────────────────────────────
clean: destroy
	@kubectl config delete-context $(CLUSTER_NAME) 2>/dev/null || true
	@kubectl config delete-cluster $(CLUSTER_NAME) 2>/dev/null || true
	@kubectl config unset users.clusterUser_$(RG_NAME)_$(CLUSTER_NAME) 2>/dev/null || true

# ── Quick targets ──────────────────────────────────────────────────────────────

cilium-status:
	@cilium status --brief 2>/dev/null || kubectl exec -n kube-system -l k8s-app=cilium -- cilium status --brief

restart-cert-manager:
	@kubectl rollout restart deployment -n cert-manager
	@kubectl rollout status deployment -n cert-manager

help:
	@echo "AKS Sandbox — Two-Step Deployment"
	@echo ""
	@echo "  make step1    - Step 1: Cluster + ingress-nginx + cert-manager + echo-nginx"
	@echo "  make step2    - Step 2: Cilium + echo-cilium"
	@echo "  make all      - Run step1 + step2 + verify"
	@echo "  make verify   - Verify both endpoints"
	@echo "  make destroy  - Destroy all resources"
	@echo "  make clean    - Destroy + clean kubeconfig"
	@echo ""
	@echo "Quick targets:"
	@echo "  make cilium-status        - Show Cilium status"
	@echo "  make restart-cert-manager - Restart cert-manager pods"
	@echo "  make help                 - Show this help"
