# AGENTS.md — AKS Sandbox

## File map

```
terraform/
├── main.tf              # Providers, backend config, required versions
├── variables.tf         # All input variables with defaults
├── terraform.tfvars.example  # Template (copy to terraform.tfvars, never commit)
├── aks.tf               # AKS cluster + spot node pool
├── helm.tf              # All Helm releases (cert-manager, ingress-nginx, echo-server)
└── k8s-manifests.tf     # ClusterIssuers, Ingresses, provider configs for helm/kubernetes
scripts/
├── apply.sh             # Three-phase deploy wrapper
└── destroy.sh           # Cleanup wrapper
docs/
├── ARCHITECTURE.md      # System design, topology, debugging chronicle
├── AGENTS.md            # This file — codebase guide for agents
README.md                # Project overview, deployment instructions
```

## Conventions

### Terraform

- **One resource per conceptual concern** — AKS cluster in `aks.tf`, Helm charts in `helm.tf`, K8s manifests in `k8s-manifests.tf`
- **Helm values use `set = []` blocks** — all values are simple key-value pairs; no `values` / `yamlencode` blocks
- **Dependency chains are explicit** via `depends_on` in deploy order (cert-manager → ingress → apps → TLS)
- **Sensitive variables** (`subscription_id`) pass through `variables.tf` with `sensitive = true`, never hardcoded
- **State**: local backend (`backend "local" {}`). No remote state store configured.
- **Providers** all derive creds from the AKS cluster's `kube_config` block, not static files

### Naming

- `resource "azurerm_*"` names match `snake_case` convention, prefixed by resource category
  - `main` for the primary resource group / cluster (e.g. `azurerm_kubernetes_cluster.main`)
  - Descriptive names for supporting resources (`azurerm_kubernetes_cluster_node_pool.spot`)
- Helm release names match the chart's purpose (`echo-server-nginx`, not just `echo-server`)
- Files are named by provider/resource category, not by app

### Version pinning

- Provider versions: `~> 4.0` (azurerm), `~> 3.0` (helm), `~> 2.0` (kubernetes)
- Helm chart versions: pinned to exact versions (e.g. `"4.15.1"`, `"0.5.0"`)
- Kubernetes version: set in `variables.tf` with default `"1.34.6"`

## Workflow

### Planning changes

```bash
cd terraform
terraform plan -out=tfplan
# Review the plan before applying
```

### Applying (phased deployment)

`kubernetes_manifest` resources cannot be planned before the AKS cluster exists, and cert-manager CRDs must be registered before ClusterIssuer resources can be created.

Use the Makefile for effortless phased deployment:

```bash
make all    # Full deployment: phases 1-6 + verification
```

Or run phases individually:

```bash
make phase1   # Azure infrastructure (AKS cluster)
make phase2   # cert-manager + CRD wait
make phase3   # ingress-nginx + echo servers
make phase4   # K8s manifests (ClusterIssuer, Ingresses)
make phase5   # DNS labels on Load Balancer IPs
make phase6   # Cilium with best practices
make verify   # Verify endpoints are working
```

Or manually with terraform:

```bash
cd terraform

# Phase 1 — cluster infra
terraform apply -auto-approve \
  -target=azurerm_resource_group.main \
  -target=azurerm_kubernetes_cluster.main \
  -target=azurerm_kubernetes_cluster_node_pool.spot

# Phase 2 — cert-manager + CRD registration
terraform apply -auto-approve \
  -target=helm_release.cert_manager \
  -target=time_sleep.wait_for_crds

# Phase 3 — ingress-nginx + echo servers
terraform apply -auto-approve \
  -target=helm_release.ingress_nginx \
  -target=helm_release.echo_nginx \
  -target=helm_release.echo_cilium

# Phase 4 — K8s manifests
terraform apply -auto-approve

# Phase 5 — DNS labels
../scripts/set-dns-labels.sh

# Phase 6 — Cilium
../scripts/install-cilium.sh
```

### Destroying

```bash
./scripts/destroy.sh
# or manually:
cd terraform
terraform destroy
# If resource group remains (stale NSG/LB):
az group delete --name rg-sandbox-aks --yes --no-wait
```

### State

```bash
terraform state list                    # all managed resources
terraform state show <resource>         # specific resource details
terraform refresh                       # sync state with real world
```

State is local (`terraform.tfstate`). It is gitignored. On a fresh clone, run `terraform init` then `terraform plan` to see diff vs real infra.

## Adding a new Helm release

1. Add the chart repo to `helm.tf` if not already present
2. Create a `helm_release` resource
3. If the new release depends on an existing one (e.g. needs CRDs deployed first), add `depends_on`
4. If the new release creates a Kubernetes resource that needs an Ingress or ClusterIssuer, add it to `k8s-manifests.tf`
5. Run `terraform fmt` after editing

Example pattern:

```hcl
resource "helm_release" "my_app" {
  name             = "my-app"
  repository       = "https://charts.example.com"
  chart            = "my-chart"
  namespace        = "my-app"
  create_namespace = true
  version          = "~> 1.0"

  set = [
    {
      name  = "someValue"
      value = "true"
    }
  ]

  depends_on = [
    helm_release.some_prerequisite
  ]
}
```

## Adding a new Ingress

Add to `k8s-manifests.tf` following the existing pattern:

```hcl
resource "kubernetes_manifest" "ingress_my_app" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "my-app"
      namespace = "my-app"
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt"
      }
    }
    spec = {
      ingressClassName = "nginx"
      rules = [{
        host = "my-app.centralus.cloudapp.azure.com"
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = "my-app"
                port = { number = 80 }
              }
            }
          }]
        }
      }]
      tls = [{
        hosts      = ["my-app.centralus.cloudapp.azure.com"]
        secretName = "my-app-tls"
      }]
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_manifest.letsencrypt
  ]
}
```

### Dependency chain

The apply order is critical:

```
azurerm_resource_group.main
  └── azurerm_kubernetes_cluster.main
        ├── azurerm_kubernetes_cluster_node_pool.spot
        ├── helm_release.cert_manager
        │     └── time_sleep.wait_for_crds  (30s delay for CRD registration)
        │           └── kubernetes_manifest.letsencrypt
        ├── helm_release.ingress_nginx
        │     ├── helm_release.echo_nginx
        │     └── helm_release.echo_cilium
        └── kubernetes_manifest.ingress_echo_nginx
        └── kubernetes_manifest.ingress_echo_cilium
```

The `time_sleep` resource is the key fix for the cert-manager CRD race condition — without it, `kubernetes_manifest.letsencrypt` fails with "no matches for kind 'ClusterIssuer'" because the CRDs haven't been registered yet by the API server, even though the Helm release reports as deployed.

## Gotchas

### Azure

- **DNS labels are global per region** — `echo-cilium.centralus.cloudapp.azure.com` can only point to one PIP at a time. Moving the label requires removing it from the old PIP first:
  ```bash
  az network public-ip update -g <rg> -n <old-pip> --set dnsSettings=null
  az network public-ip update -g <rg> -n <new-pip> --dns-name "<label>"
  ```
- **ACME HTTP-01 challenges need the correct ingress class** — cert-manager creates solver ingresses. If the ClusterIssuer's `class` field doesn't match a running controller, the challenge hangs. Clean stale `CertificateRequest` + `Order` resources before retrying.

### cert-manager

- **`force_conflicts = true` required on ClusterIssuer** — cert-manager's status patches collide with Terraform's `kubernetes_manifest` field ownership without this. Add `field_manager { force_conflicts = true }` to the resource.
- **Stale Orders cause "ACME client for issuer not initialised/available"** — after upgrade or downgrade, old Order resources in `valid` state may trigger repeating error loops. Delete them:
  ```bash
  kubectl delete order -n <namespace> <order-name>
  ```
  The Certificate and Secret remain intact.
- **Helm downgrade in-place is blocked** — use `terraform taint helm_release.cert_manager` and re-apply, after deleting webhook configurations first to prevent destroy hang.

### State & drift

- **Terraform state is local** — lost if the working directory is deleted. There is no remote backend. Plan to add one before applying from a new machine.
- **Helm values specified via `set {}` take precedence over chart defaults** — Terraform's `helm_release` will detect drift and attempt to reconcile if someone runs `helm upgrade` outside of Terraform.
- **AKS version upgrades outside Terraform** — the `lifecycle.ignore_changes` block prevents Terraform from reverting node pool versions, but `terraform plan` will show a diff. Accept the drift or update `kubernetes_version`.

### TLS

- **cert-manager CertificateRequest may get stuck** if a prior HTTP-01 challenge failed. Fix: delete the stale `CertificateRequest` and `Order` resources in the target namespace.
- **Let's Encrypt has rate limits** — 50 certificates per domain per week. During debugging, avoid repeated ingress creation/deletion cycles that trigger re-issuance.

## Verifying changes

After `terraform apply`, always run:

```bash
# Basic cluster health
kubectl get nodes
kubectl get pods -A | grep -E "Pending|CrashLoopBackOff|Error"

# Helm release status
helm list -A

# TLS readiness
kubectl get certificate -A

# Endpoint reachability
curl -s -o /dev/null -w "%{http_code}" https://echo-nginx.centralus.cloudapp.azure.com
curl -s -o /dev/null -w "%{http_code}" https://echo-cilium.centralus.cloudapp.azure.com
```

Expected output: both endpoints return `200`.
