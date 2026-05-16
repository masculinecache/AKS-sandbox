# AGENTS.md — AKS Sandbox

## File map

```
terraform/
├── main.tf              # Providers, backend config, required versions
├── variables.tf         # All input variables with defaults
├── terraform.tfvars.example  # Template (copy to terraform.tfvars, never commit)
├── aks.tf               # AKS cluster + spot node pool
├── helm.tf              # All Helm releases (cert-manager, nginx, Cilium, echo-server, kubeview)
└── k8s-manifests.tf     # ClusterIssuers, Ingresses, provider configs for helm/kubernetes
docs/
├── ARCHITECTURE.md      # System design, topology, debugging chronicle
└── AGENTS.md            # This file — codebase guide for agents
README.md                # Project overview, deployment instructions
```

## Conventions

### Terraform

- **One resource per conceptual concern** — AKS cluster in `aks.tf`, Helm charts in `helm.tf`, K8s manifests in `k8s-manifests.tf`
- **Helm values are inlined** via `values = [yamlencode(local.*)]` for Cilium (large config), or individual `set {}` blocks for simple values
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
- Helm chart versions: `~> X.Y` (allow patch upgrades, pin major.minor)
- Kubernetes version: set in `variables.tf` with default `"1.34.6"`

## Workflow

### Planning changes

```bash
cd terraform
terraform plan -out=tfplan
# Review the plan before applying
```

### Applying

```bash
terraform apply tfplan
# or directly:
terraform apply
```

### Destroying

```bash
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

  set {
    name  = "someValue"
    value = "true"
  }

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
        "cert-manager.io/cluster-issuer" = "letsencrypt"  # or letsencrypt-cilium
      }
    }
    spec = {
      ingressClassName = "nginx"  # or cilium-nginx
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
    helm_release.ingress_nginx,           # for class: nginx
    # or helm_release.cilium_ingress_nginx  # for class: cilium-nginx
    kubernetes_manifest.letsencrypt,      # for class: nginx
    # or kubernetes_manifest.letsencrypt_cilium  # for class: cilium-nginx
  ]
}
```

## Gotchas

### Cilium

- **`bpf.masquerade: false` is required** — setting `true` breaks all pod-to-service connectivity when chaining with Azure CNI
- **hostNetwork convergence is flaky** — after initial deploy or config change, the Envoy listener may stay on `127.0.0.1:12256`. Verify with `kubectl exec -n cilium ds/cilium -- ss -tlnp | grep envoy`. If stuck, restart the daemonset 2-3 times.
- **`sharedListenerPort: 80` is ignored** — in `generic-veth` chaining mode, the Cilium operator always creates CiliumEnvoyConfig with port 8080 regardless of this setting. Known Cilium 1.19.x behavior.
- **A new Azure LB may allocate a different public IP** — after destroying and recreating Cilium's LoadBalancer service, the DNS label must be updated on the new PIP.

### Azure

- **DSR/Floating IP cannot be disabled** — Azure AKS enforces this. Any annotation or CLI change to disable it gets reverted by the cloud-controller-manager within ~30 seconds.
- **DNS labels are global per region** — `phillias-cilium.centralus.cloudapp.azure.com` can only point to one PIP at a time. Moving the label requires removing it from the old PIP first.
- **ACME HTTP-01 challenges need the correct ingress class** — cert-manager creates solver ingresses. If the ClusterIssuer's `class` field doesn't match a running controller, the challenge hangs. Clean stale `CertificateRequest` + `Order` resources before retrying.

### State & drift

- **Terraform state is local** — lost if the working directory is deleted. There is no remote backend. Plan to add one before applying from a new machine.
- **Helm values specified via `set {}` take precedence over chart defaults** — Terraform's `helm_release` will detect drift and attempt to reconcile if someone runs `helm upgrade` outside of Terraform.
- **AKS version upgrades outside Terraform** — the `lifecycle.ignore_changes` block prevents Terraform from reverting node pool versions, but `terraform plan` will show a diff. Accept the drift or update `kubernetes_version`.

### TLS

- **cert-manager CertificateRequest may get stuck** if a prior HTTP-01 challenge failed with a different ingress controller class. Fix: delete the stale `CertificateRequest` and `Order` resources in the target namespace.
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
curl -s -o /dev/null -w "%{http_code}" https://phillias-nginx.centralus.cloudapp.azure.com
curl -s -o /dev/null -w "%{http_code}" https://phillias-cilium.centralus.cloudapp.azure.com
```

Expected output: both endpoints return `200`.
