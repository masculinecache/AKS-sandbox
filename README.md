# AKS Sandbox

Personal sandbox AKS cluster for experimenting with Kubernetes, Cilium, ingress controllers, and cert-manager.

## Architecture

```
Internet
  ├── phillias-nginx.centralus.cloudapp.azure.com (20.236.249.188)
  │   └── ingress-nginx (class: nginx)
  │       └── echo-server-nginx
  │
  ├── phillias-cilium.centralus.cloudapp.azure.com (20.80.113.117)
  │   └── cilium-ingress-nginx (class: cilium-nginx)
  │       └── echo-server-cilium
  │
  └── kubeview.centralus.cloudapp.azure.com (72.152.58.240)
      └── kubeview LoadBalancer
```

## Components

| Component | Chart | Namespace | Purpose |
|---|---|---|---|
| AKS cluster | — | — | Azure Kubernetes Service, Azure CNI, 1.34.6 |
| cert-manager | `cert-manager` 1.16+ | `cert-manager` | Let's Encrypt TLS automation |
| ingress-nginx | `ingress-nginx` 4.15+ | `ingress-nginx` | Default ingress controller (class: nginx) |
| Cilium | `cilium` 1.19+ | `cilium` | CNI chaining + kube-proxy replacement |
| cilium-ingress-nginx | `ingress-nginx` 4.15+ | `cilium-ingress-nginx` | 2nd ingress controller (class: cilium-nginx) |
| echo-server-nginx | `echo-server` 0.5+ | `echo-server-nginx` | Test app behind nginx ingress |
| echo-server-cilium | `echo-server` 0.5+ | `echo-server-cilium` | Test app behind cilium-nginx ingress |
| kubeview | `kubeview` | `kubeview` | Kubernetes visualizer |

## Prerequisites

- Azure CLI (`az`) with subscription `darren.slocum@gmail.com`
- Terraform >= 1.6
- kubectl
- Helm 3

## Deployment

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your subscription ID
terraform init
terraform plan
terraform apply
```

After apply, ClusterIssuers and Ingress resources will be created automatically. Cert-manager will handle Let's Encrypt TLS issuance.

**Note**: The spot node pool may have zero nodes when idle (`min_count = 0`). Pods with tolerations for `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` will be scheduled there.

## Design Decisions

### Why two ingress controllers?
Cilium's eBPF TPROXY for L7 ingress cannot handle Azure's mandatory DSR/Floating IP mode on AKS with Azure CNI chaining. Nginx ingress handles DSR correctly because its backends are pod IPs routed via kube-proxy replacement, not local Envoy TPROXY. A second nginx ingress controller provides a clean separate endpoint for the Cilium domain.

### Spot instances
All workloads use spot node pools with tolerations. The `spot_max_price = -1` means Azure will evict at the standard VM price (don't pay more than on-demand).

### No external-dns
Azure DNS labels (`cloudapp.azure.com`) are used instead of custom domains. Azure DNS labels do not support subdomains.

## Ingress URLs

- https://phillias-nginx.centralus.cloudapp.azure.com (echo-server)
- https://phillias-cilium.centralus.cloudapp.azure.com (echo-server)
- http://72.152.58.240:8000 (kubeview)

## Cleanup

```bash
cd terraform
terraform destroy
az group delete --name rg-sandbox-aks --yes --no-wait
```
