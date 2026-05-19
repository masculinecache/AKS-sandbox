# AKS Sandbox — Architecture Guide

## Identity

- **Cluster**: `sandbox-aks` in `centralus`
- **Subscription**: `76beeea0-d6f9-481f-9b4b-ff847547c6d4` (Basic, darren.slocum@gmail.com)
- **Node pool**: 2 `Standard_D2s_v6` (system) + spot `Standard_D2s_v5` (0-3, autoscaling)
- **Kubernetes**: v1.34.6, Azure CNI
- **Terraform root**: `terraform/` in this repo
- **Repo**: `github.com/masculinecache/AKS-sandbox`

## Prerequisites

```bash
az login --tenant 76beeea0-d6f9-481f-9b4b-ff847547c6d4
az account set --subscription 76beeea0-d6f9-481f-9b4b-ff847547c6d4
az aks get-credentials --resource-group rg-sandbox-aks --name sandbox-aks
```

Tools needed: `terraform >= 1.6`, `helm`, `kubectl`, `az`.

## Topology

```
Internet
  ├── echo-nginx.centralus.cloudapp.azure.com ─── LB: ingress-nginx (class: nginx)
  │     └── echo-server-nginx
  └── echo-cilium.centralus.cloudapp.azure.com ─── LB: ingress-nginx (class: nginx)
        └── echo-server-cilium
```

Both apps share the same ingress controller (`ingress-nginx`). The `echo-cilium` name is retained from the earlier Cilium-based stack; it now routes through nginx like everything else.

## Namespace reference

| Namespace | What runs there | Why it exists |
|---|---|---|
| `ingress-nginx` | Default ingress controller (class: `nginx`) | Single ingress controller serving both domains |
| `cert-manager` | cert-manager controller + CRDs | Let's Encrypt TLS for both domains |
| `echo-server-nginx` | echo-server pod | Test app at `echo-nginx.*` |
| `echo-server-cilium` | echo-server pod | Test app at `echo-cilium.*` |
| `kube-system` | System pods (CoreDNS, metrics-server, etc.) | Standard AKS system namespace |
| `default` | (empty) | Unused |

## Verifications

### Health checks

```bash
# Both endpoints should return 200 + echo-server JSON
curl -s https://echo-nginx.centralus.cloudapp.azure.com | jq .host
curl -s https://echo-cilium.centralus.cloudapp.azure.com | jq .host

# TLS validity
curl -svI https://echo-nginx.centralus.cloudapp.azure.com 2>&1 | grep "SSL certificate verify"
curl -svI https://echo-cilium.centralus.cloudapp.azure.com 2>&1 | grep "SSL certificate verify"
```

### Cluster health

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed
helm list -A
```

## Configuration reference

### AKS cluster (`terraform/aks.tf`)

| Parameter | Value |
|---|---|
| Network plugin | azure |
| Network policy | none |
| Service CIDR | 10.0.0.0/16 |
| DNS service IP | 10.0.0.10 |
| LB SKU | standard |
| System pool | nodepool1, Standard_D2s_v6, 2 nodes |
| Spot pool | spotpool, Standard_D2s_v5, 0-3, `spotMaxPrice=-1` |
| Spot taint | `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` |

### Helm releases (`terraform/helm.tf`)

| Release | Chart | Namespace | Key config |
|---|---|---|---|
| cert-manager | cert-manager 1.16.5 | cert-manager | `installCRDs=true` |
| ingress-nginx | ingress-nginx 4.15.1 | ingress-nginx | LB probe `/healthz` |
| echo-server-nginx | echo-server 0.5.0 | echo-server-nginx | spot toleration |
| echo-server-cilium | echo-server 0.5.0 | echo-server-cilium | spot toleration |

### TLS

| Domain | ClusterIssuer | Ingress class | Secret |
|---|---|---|---|
| echo-nginx.* | letsencrypt | nginx | echo-nginx-tls |
| echo-cilium.* | letsencrypt | nginx | echo-cilium-tls |

Both use the same `letsencrypt` ClusterIssuer with HTTP-01 challenge.

## Deployment order (dependency chain)

```
cert-manager
  ├── ingress-nginx
  │     ├── echo-server-nginx
  │     │     └── Ingress (echo-server-nginx, class: nginx)
  │     └── echo-server-cilium
  │           └── Ingress (echo-server-cilium, class: nginx)
  └── ClusterIssuer (letsencrypt)
```

Apply with `terraform apply`.

## Design decisions

### Spot instances
All workloads use spot node pools with tolerations. `spot_max_price = -1` means Azure evicts at the standard VM price.

### No external-dns
Azure DNS labels (`cloudapp.azure.com`) are used instead of custom domains.

### Single ingress controller
Both apps share `ingress-nginx`. The `echo-cilium` name is retained for historical continuity but routes through the same nginx ingress class.

## Deployment from scratch

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit subscription_id

terraform init
terraform plan
terraform apply  # creates AKS + all Helm releases + manifests (~15 min)

# After apply, wait for TLS certs
kubectl get certificate -A
```

## Cleanup

```bash
cd terraform
terraform destroy
# If that leaves resource group behind:
az group delete --name rg-sandbox-aks --yes --no-wait
```
