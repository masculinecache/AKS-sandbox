# AKS Sandbox

Personal sandbox AKS cluster for experimenting with Kubernetes, ingress controllers, and cert-manager.

## Architecture

```
Internet
  ├── echo-nginx.centralus.cloudapp.azure.com
  │   └── ingress-nginx (class: nginx)
  │       └── echo-server-nginx
  └── echo-cilium.centralus.cloudapp.azure.com
      └── ingress-nginx (class: nginx)
          └── echo-server-cilium
```

## Components

| Component | Chart | Namespace | Purpose |
|---|---|---|---|
| AKS cluster | — | — | Azure Kubernetes Service, Azure CNI, 1.34.6 |
| cert-manager | `cert-manager` 1.16.5 | `cert-manager` | Let's Encrypt TLS automation |
| ingress-nginx | `ingress-nginx` 4.15.1 | `ingress-nginx` | Ingress controller (class: nginx) |
| echo-server-nginx | `echo-server` 0.5.0 | `echo-server-nginx` | Test app at echo-nginx.* |
| echo-server-cilium | `echo-server` 0.5.0 | `echo-server-cilium` | Test app at echo-cilium.* |

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

## Ingress URLs

- https://echo-nginx.centralus.cloudapp.azure.com (echo-server)
- https://echo-cilium.centralus.cloudapp.azure.com (echo-server)

## Cleanup

```bash
cd terraform
terraform destroy
az group delete --name rg-sandbox-aks --yes --no-wait
```
