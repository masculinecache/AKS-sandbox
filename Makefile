# AKS Sandbox Deployment
# Phased deployment to handle terraform ordering constraints

.PHONY: all phase1 phase2 phase3 phase4 phase5 phase6 verify destroy clean

# ── Configuration ──────────────────────────────────────────────────────────────
TERRAFORM_DIR := terraform
CLUSTER_NAME  := sandbox-aks
RG_NAME       := rg-sandbox-aks
LOCATION      := centralus

# ── All phases (full deployment) ───────────────────────────────────────────────
all: phase1 phase2 phase3 phase4 phase5 phase6 verify
	@echo "✅ Full deployment complete"

# ── Phase 1: Azure Infrastructure ──────────────────────────────────────────────
# Creates: Resource Group, AKS Cluster, Node Pool
phase1:
	@echo "🔧 Phase 1: Creating Azure infrastructure..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=azurerm_resource_group.main \
		-target=azurerm_kubernetes_cluster.main \
		-target=azurerm_kubernetes_cluster_node_pool.spot
	@echo "✅ Phase 1 complete"

# ── Phase 2: cert-manager ──────────────────────────────────────────────────────
# Installs cert-manager Helm chart and waits for CRDs to register
phase2: phase1
	@echo "🔧 Phase 2: Installing cert-manager..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=helm_release.cert_manager \
		-target=time_sleep.wait_for_crds
	@echo "✅ Phase 2 complete"

# ── Phase 3: ingress-nginx + echo servers ──────────────────────────────────────
phase3: phase2
	@echo "🔧 Phase 3: Installing ingress-nginx and echo servers..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve \
		-target=helm_release.ingress_nginx \
		-target=helm_release.echo_nginx \
		-target=helm_release.echo_cilium
	@echo "✅ Phase 3 complete"

# ── Phase 4: K8s manifests (ClusterIssuer + Ingresses) ─────────────────────────
phase4: phase3
	@echo "🔧 Phase 4: Applying Kubernetes manifests..."
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve
	@echo "✅ Phase 4 complete"

# ── Phase 5: Set DNS labels on Load Balancer IPs ───────────────────────────────
phase5: phase4
	@echo "🔧 Phase 5: Setting DNS labels on Load Balancer IPs..."
	@./scripts/set-dns-labels.sh
	@echo "✅ Phase 5 complete"

# ── Phase 6: Install Cilium ────────────────────────────────────────────────────
phase6: phase5
	@echo "🔧 Phase 6: Installing Cilium..."
	@./scripts/install-cilium.sh
	@echo "✅ Phase 6 complete"

# ── Verify deployment ──────────────────────────────────────────────────────────
verify: phase6
	@echo "🔍 Verifying deployment..."
	@./scripts/verify-deployment.sh

# ── Destroy everything ─────────────────────────────────────────────────────────
destroy:
	@echo "💥 Destroying all resources..."
	cd $(TERRAFORM_DIR) && terraform destroy -auto-approve
	@echo "✅ Destroy complete"

# ── Clean up kubeconfig ────────────────────────────────────────────────────────
clean: destroy
	@echo "🧹 Cleaning up kubeconfig..."
	@kubectl config delete-context $(CLUSTER_NAME) 2>/dev/null || true
	@kubectl config delete-cluster $(CLUSTER_NAME) 2>/dev/null || true
	@kubectl config unset users.clusterUser_$(RG_NAME)_$(CLUSTER_NAME) 2>/dev/null || true

# ── Quick targets ──────────────────────────────────────────────────────────────

# Re-run just the K8s manifests (useful after modifying ingress/certificate config)
reapply-manifests:
	cd $(TERRAFORM_DIR) && terraform apply -auto-approve

# Restart cert-manager pods (creates CiliumEndpoints after Cilium install)
restart-cert-manager:
	@echo "🔄 Restarting cert-manager..."
	@kubectl rollout restart deployment -n cert-manager
	@kubectl rollout status deployment -n cert-manager

# Get Cilium status
cilium-status:
	@cilium status --wait

# Get Hubble status (if enabled)
hubble-status:
	@cilium hubble status

# Show all targets
help:
	@echo "AKS Sandbox Deployment Targets"
	@echo ""
	@echo "  make all              - Full deployment (phases 1-6 + verify)"
	@echo "  make phase1           - Create Azure infrastructure"
	@echo "  make phase2           - Install cert-manager"
	@echo "  make phase3           - Install ingress-nginx + echo servers"
	@echo "  make phase4           - Apply K8s manifests"
	@echo "  make phase5           - Set DNS labels on LB IPs"
	@echo "  make phase6           - Install Cilium"
	@echo "  make verify           - Verify endpoints are working"
	@echo "  make destroy          - Destroy all resources"
	@echo "  make clean            - Destroy + clean kubeconfig"
	@echo ""
	@echo "Quick targets:"
	@echo "  make reapply-manifests  - Re-apply K8s manifests"
	@echo "  make restart-cert-manager - Restart cert-manager pods"
	@echo "  make cilium-status      - Show Cilium status"
	@echo "  make help               - Show this help"
