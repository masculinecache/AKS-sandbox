# AKS Sandbox

Personal sandbox AKS cluster for experimenting with Kubernetes, ingress controllers, cert-manager, and Cilium.

## Architecture

```
Internet
  ├── echo-nginx.centralus.cloudapp.azure.com
  │   └── ingress-nginx (class: nginx)
  │       └── echo-server-nginx
  └── echo-cilium.centralus.cloudapp.azure.com
      └── Cilium Ingress (class: cilium)
          └── echo-server-cilium
```

## Components

| Component | Chart | Namespace | Purpose |
|---|---|---|---|
| AKS cluster | — | — | Azure Kubernetes Service, Azure CNI, 1.34.6 |
| cert-manager | `cert-manager` 1.9.1 | `cert-manager` | Let's Encrypt TLS automation |
| ingress-nginx | `ingress-nginx` 4.15.1 | `ingress-nginx` | Ingress controller (class: nginx) |
| echo-server-nginx | `echo-server` 0.5.0 | `echo-server-nginx` | Test app at echo-nginx.* |
| echo-server-cilium | `echo-server` 0.5.0 | `echo-server-cilium` | Test app at echo-cilium.* |
| Cilium | `cilium` 1.19.4 | `kube-system` | CNI + Ingress controller (class: cilium) |

## Prerequisites

- Azure CLI (`az`) with subscription `darren.slocum@gmail.com`
- Terraform >= 1.6
- kubectl
- Helm 3
- make
- Cilium CLI (`cilium`) — optional, for status checks

## Deployment

The deployment is split into phases to handle terraform ordering constraints:

```bash
# Full deployment (all phases)
make all

# Or run phases individually:
make phase1   # Create Azure infrastructure (AKS cluster)
make phase2   # Install cert-manager
make phase3   # Install ingress-nginx + echo servers
make phase4   # Apply K8s manifests (ClusterIssuer, Ingresses)
make phase5   # Set DNS labels on Load Balancer IPs
make phase6   # Install Cilium with best practices
make verify   # Verify endpoints are working
```

### Phase Details

**Phase 1** — Creates the Azure resource group, AKS cluster, and spot node pool.

**Phase 2** — Installs cert-manager and waits for CRDs to register. This must happen before any `kubernetes_manifest` resources that reference cert-manager CRDs.

**Phase 3** — Installs ingress-nginx and the echo server applications.

**Phase 4** — Applies Kubernetes manifests (ClusterIssuer, Ingress resources). These depend on both cert-manager CRDs and the echo-server namespaces.

**Phase 5** — Automatically discovers the LoadBalancer public IPs and sets Azure DNS labels (`echo-nginx` and `echo-cilium`). This is required for Let's Encrypt ACME challenges to resolve.

**Phase 6** — Installs Cilium with:
- Azure CNI `generic-veth` chaining
- Native routing (required for DSR mode)
- DSR load balancer mode
- Ingress controller with dedicated LB mode
- Correct ConfigMap key name (`cni-config`)

### Manual Terraform (without Make)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subscription ID
terraform init

# Phase 1: Infrastructure
terraform apply -target=azurerm_resource_group.main \
  -target=azurerm_kubernetes_cluster.main \
  -target=azurerm_kubernetes_cluster_node_pool.spot

# Phase 2: cert-manager
terraform apply -target=helm_release.cert_manager -target=time_sleep.wait_for_crds

# Phase 3: ingress-nginx + echo servers
terraform apply -target=helm_release.ingress_nginx \
  -target=helm_release.echo_nginx \
  -target=helm_release.echo_cilium

# Phase 4: K8s manifests
terraform apply

# Phase 5: DNS labels
../scripts/set-dns-labels.sh

# Phase 6: Cilium
../scripts/install-cilium.sh
```

## Cilium Configuration

Cilium is installed with best-practice settings for Azure CNI chaining:

| Setting | Value | Reason |
|---|---|---|
| `cni.chainingMode` | `generic-veth` | Works with Azure CNI |
| `cni.customConf` | `true` | Use custom CNI config |
| `cni.configMap` | `cilium-cni-configuration` | Source ConfigMap |
| `routingMode` | `native` | Required for DSR mode |
| `ipv4NativeRoutingCIDR` | Auto-detected | VNet CIDR for native routing |
| `loadBalancer.mode` | `dsr` | Direct Server Return for performance |
| `kubeProxyReplacement` | `true` | eBPF-based kube-proxy replacement |
| `bpf.masquerade` | `false` | Use iptables masquerade (Azure CNI compatible) |
| `enableMasqueradeToRouteSource` | `true` | Cross-node Envoy connectivity |
| `ingressController.enabled` | `true` | Enable Cilium ingress controller |
| `ingressController.loadbalancerMode` | `dedicated` | Dedicated LB per ingress |

### Cilium Ingress TLS

The Cilium ingress uses the `acme.cert-manager.io/http01-edit-in-place: "true"` annotation to solve the TLS chicken-and-egg problem:

1. cert-manager issues a temporary self-signed certificate
2. Cilium Envoy serves HTTPS with the temp cert
3. ACME challenge follows the HTTP→HTTPS redirect successfully
4. Real Let's Encrypt certificate replaces the temp cert

No workarounds needed — certificate issuance works directly through the Cilium ingress.

## Ingress URLs

- https://echo-nginx.centralus.cloudapp.azure.com (via ingress-nginx)
- https://echo-cilium.centralus.cloudapp.azure.com (via Cilium ingress)

## Useful Commands

```bash
# Check Cilium status
make cilium-status

# Restart cert-manager (creates CiliumEndpoints after Cilium install)
make restart-cert-manager

# Re-apply K8s manifests after changes
make reapply-manifests

# Verify endpoints
make verify
```

## Cleanup

```bash
make destroy    # Destroy all terraform resources
make clean      # Destroy + clean kubeconfig
```

## Notes

- The spot node pool may have zero nodes when idle (`min_count = 0`). Pods with tolerations for `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` will be scheduled there.
- cert-manager pods deployed before Cilium will not have CiliumEndpoints. Restart cert-manager after Cilium installation: `make restart-cert-manager`
- DNS labels are set automatically in Phase 5, but may take a few minutes to propagate.
