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

## Deployment

### Step 1: Base cluster + ingress-nginx + cert-manager + echo-nginx

```bash
make step1
```

This creates:
- AKS cluster with Azure CNI
- cert-manager with Let's Encrypt ClusterIssuer
- ingress-nginx controller
- echo-server-nginx with TLS via nginx ingress
- echo-server-cilium app (namespace + deployment, no ingress yet)
- DNS label for echo-nginx

After step 1, verify:
```bash
curl -I https://echo-nginx.centralus.cloudapp.azure.com
# Expected: HTTP/2 200
```

### Step 2: Install Cilium + create echo-cilium ingress

```bash
make step2
```

This installs:
- Cilium with Azure CNI `generic-veth` chaining
- Native routing (auto-detected VNet CIDR)
- DSR load balancer mode
- Cilium ingress controller
- Cilium ingress for echo-cilium with `http01-edit-in-place` annotation
- DNS label for echo-cilium
- Restarts cert-manager to create CiliumEndpoints

After step 2, verify:
```bash
curl -I https://echo-cilium.centralus.cloudapp.azure.com
# Expected: HTTP/1.1 200, server: envoy
```

### Full deployment

```bash
make all    # Runs step1 + step2 + verify
```

### Verify endpoints

```bash
make verify
```

## Step Details

**Step 1** — Base infrastructure:
1. Azure resource group + AKS cluster + spot node pool
2. cert-manager Helm chart + 30s CRD wait
3. ingress-nginx + echo-server-nginx + echo-server-cilium Helm charts
4. ClusterIssuer + echo-nginx Ingress (kubernetes_manifest)
5. DNS label on ingress-nginx LB IP

**Step 2** — Cilium installation:
1. Create CNI ConfigMap (`cni-config` key)
2. Install Cilium with native routing + DSR
3. Restart cert-manager pods (creates CiliumEndpoints)
4. Create Cilium ingress for echo-cilium
5. DNS label on Cilium LB IP

## Cilium Configuration

Cilium is installed with best-practice settings for Azure CNI chaining:

| Setting | Value | Reason |
|---|---|---|
| `cni.chainingMode` | `generic-veth` | Works with Azure CNI |
| `cni.customConf` | `true` | Use custom CNI config |
| `cni.configMap` | `cilium-cni-configuration` | Source ConfigMap |
| `routingMode` | `native` | Required for DSR mode |
| `ipv4NativeRoutingCIDR` | Auto-detected | VNet CIDR for native routing |
| `loadBalancer.mode` | `dsr` | Direct Server Return |
| `kubeProxyReplacement` | `true` | eBPF-based kube-proxy replacement |
| `bpf.masquerade` | `false` | Use iptables (Azure CNI compatible) |
| `enableMasqueradeToRouteSource` | `true` | Cross-node Envoy connectivity |
| `ingressController.enabled` | `true` | Enable Cilium ingress controller |
| `ingressController.loadbalancerMode` | `dedicated` | Dedicated LB per ingress |

## Ingress URLs

- https://echo-nginx.centralus.cloudapp.azure.com (via ingress-nginx)
- https://echo-cilium.centralus.cloudapp.azure.com (via Cilium ingress)

## Useful Commands

```bash
make cilium-status          # Check Cilium status
make restart-cert-manager   # Restart cert-manager (after Cilium install)
make verify                 # Verify both endpoints
make destroy                # Destroy all resources
make clean                  # Destroy + clean kubeconfig
```

## Notes

- The spot node pool may have zero nodes when idle (`min_count = 0`).
- cert-manager pods deployed before Cilium have no CiliumEndpoints. `make step2` automatically restarts them.
- DNS labels are set automatically but may take a few minutes to propagate.
