# AKS Sandbox — Architecture Guide

## Identity

- **Cluster**: `sandbox-aks` in `centralus`
- **Subscription**: `76beeea0-d6f9-481f-9b4b-ff847547c6d4` (Basic, darren.slocum@gmail.com)
- **Node**: single `Standard_D2s_v6` (system pool) + spot pool `Standard_D2s_v5` (0-3, autoscaling)
- **Kubernetes**: v1.34.6, Azure CNI (no network policy), Cilium 1.19.4 CNI chaining
- **Terraform root**: `terraform/` in this repo
- **Repo**: `github.com/phillias/AKS-sandbox`

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
  ├── phillias-nginx.centralus.cloudapp.azure.com ─── LB: 20.236.249.188
  │     └── ingress-nginx (class: nginx) ──→ echo-server-nginx
  │
  ├── phillias-cilium.centralus.cloudapp.azure.com ── LB: 20.80.113.117
  │     └── cilium-ingress-nginx (class: cilium-nginx) ──→ echo-server-cilium
  │
  └── 72.152.58.240:8000 ──→ kubeview
```

All ingress traffic follows the same path:
```
Client → Azure LB (DSR) → Node → Cilium KPR → Pod IP
```

## Namespace reference

| Namespace | What runs there | Why it exists |
|---|---|---|
| `ingress-nginx` | Default ingress controller (class: `nginx`) | Serves `phillias-nginx.*` — the primary ingress for the cluster. Installed first, kept as-is. |
| `cilium` | Cilium agent, operator, Envoy (Cilium ingress controller) | CNI chaining + kube-proxy replacement. The Cilium Ingress Controller is deployed here but **does not serve traffic externally** — Azure DSR/Floating IP prevents eBPF TPROXY from working. |
| `cilium-ingress-nginx` | Second ingress controller (class: `cilium-nginx`) | Serves `phillias-cilium.*` — a separate nginx controller to work around the DSR issue above. Same chart as `ingress-nginx` but with a different ingress class and its own LoadBalancer. |
| `cert-manager` | cert-manager controller + CRDs | Automatic Let's Encrypt TLS for both domains. Creates solver ingresses during HTTP-01 challenges. |
| `echo-server-nginx` | echo-server pod | Test application behind the default nginx ingress. |
| `echo-server-cilium` | echo-server pod | Test application behind the cilium-nginx ingress. |
| `kubeview` | kubeview pod | Cluster visualizer UI, accessible on its own LoadBalancer. |
| `kube-system` | System pods (CoreDNS, metrics-server, etc.) | Standard AKS system namespace. |
| `default` | (empty) | Unused — all workloads are in named namespaces. |

### Namespace design principles

- **One ingress class per controller namespace** — `ingress-nginx` owns class `nginx`, `cilium-ingress-nginx` owns class `cilium-nginx`. No controller watches ingresses from the other class.
- **App namespaces match their ingress class** — `echo-server-nginx` uses class `nginx`, `echo-server-cilium` uses class `cilium-nginx`. This makes it obvious which ingress controller serves which app.
- **cert-manager has its own namespace** — standard practice. It creates solver ingresses in the target app's namespace during HTTP-01 challenges.
- **Cilium shares its namespace with the broken ingress controller** — the Cilium Ingress Controller lives in `cilium` but is effectively unused for external traffic. It remains deployed because removing it would require changing Cilium Helm values (`ingressController.enabled=true`), and it doesn't interfere with anything.

## Verifications

### Health checks

```bash
# Both endpoints should return 200 + echo-server JSON
curl -s https://phillias-nginx.centralus.cloudapp.azure.com | jq .host
curl -s https://phillias-cilium.centralus.cloudapp.azure.com | jq .host

# TLS validity
curl -svI https://phillias-nginx.centralus.cloudapp.azure.com 2>&1 | grep "SSL certificate verify"
curl -svI https://phillias-cilium.centralus.cloudapp.azure.com 2>&1 | grep "SSL certificate verify"

# LB reachability (should not time out)
curl -s -o /dev/null -w "%{http_code}" http://20.236.249.188/healthz
curl -s -o /dev/null -w "%{http_code}" http://20.80.113.117/healthz
```

### Cluster health

```bash
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed  # should be near-empty
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
| System pool | nodepool1, Standard_D2s_v6, 1 node |
| Spot pool | spotpool, Standard_D2s_v5, 0-3, `spotMaxPrice=-1` |
| Spot taint | `kubernetes.azure.com/scalesetpriority=spot:NoSchedule` |

### Helm releases (`terraform/helm.tf`)

| Release | Chart | Namespace | Key config |
|---|---|---|---|
| cert-manager | jetstack/cert-manager ~>1.16 | cert-manager | `installCRDs=true` |
| ingress-nginx | ingress-nginx ~>4.15 | ingress-nginx | LB probe `/healthz`, class: nginx |
| cilium | cilium/cilium ~>1.19 | cilium | See Cilium config below |
| cilium-ingress-nginx | ingress-nginx ~>4.15 | cilium-ingress-nginx | class: cilium-nginx, `externalTrafficPolicy=Local` |
| echo-server-nginx | ealenn/echo-server ~>0.5 | echo-server-nginx | spot toleration |
| echo-server-cilium | ealenn/echo-server ~>0.5 | echo-server-cilium | spot toleration |
| kubeview | benc-uk/kubeview (local chart: `charts/kubeview`) | kubeview | LB enabled |

### Cilium config (from `terraform/helm.tf` locals)

```yaml
kubeProxyReplacement: true
routingMode: native
cni:
  chainingMode: generic-veth
  chainingTarget: azure-vnet
bpf.masquerade: false              # REQUIRED for Azure CNI chaining
endpointRoutes.enabled: true
forceDeviceDetection: true
ingressController:
  enabled: true
  hostNetwork.enabled: true        # may need 2-3 agent restarts to converge
  hostNetwork.sharedListenerPort: 80  # ignored in chaining mode, CEC uses 8080
```

### TLS

| Domain | ClusterIssuer | Ingress class | Secret |
|---|---|---|---|
| phillias-nginx.* | letsencrypt | nginx | echo-nginx-tls |
| phillias-cilium.* | letsencrypt-cilium | cilium-nginx | echo-cilium-tls |

Both ClusterIssuers (`terraform/k8s-manifests.tf`) use HTTP-01 challenge with Let's Encrypt production endpoint. cert-manager creates solver ingresses automatically.

## Deployment order (dependency chain)

```
cert-manager
  ├── ingress-nginx
  │     └── echo-server-nginx
  │           └── Ingress (echo-server-nginx, class: nginx)
  │                 └── ClusterIssuer (letsencrypt)
  ├── cilium
  │     └── cilium-ingress-nginx
  │           └── echo-server-cilium
  │                 └── Ingress (echo-server-cilium, class: cilium-nginx)
  │                       └── ClusterIssuer (letsencrypt-cilium)
  └── kubeview
```

Apply with `terraform apply`. ClusterIssuers and Ingresses are created as `kubernetes_manifest` resources with explicit `depends_on` chains.

## Design decisions

### Why two ingress controllers instead of one?

**Short answer**: Cilium's built-in ingress (eBPF TPROXY + Envoy) cannot handle Azure's mandatory DSR/Floating IP mode on AKS with Azure CNI. Nginx-based controllers can.

**Technical root cause**:
- Azure LB with DSR sends TCP SYNs to the node with the LB IP as destination (not a NodePort)
- Cilium's eBPF TPROXY hook on `eth0` tries to redirect these packets to the local Envoy process
- TPROXY with a non-local destination IP requires special kernel handling that does not work in this path
- The SYN never reaches Envoy → no SYN-ACK → client times out

**Why nginx works**:
- nginx ingress uses standard service forwarding (kube-proxy / Cilium KPR)
- Traffic goes: LB → NodePort → Cilium KPR → pod IP (via veth pair)
- The pod IP is a *remote* address — Cilium forwards the packet through the pod's network interface
- This forwarding path works correctly with DSR

**Why not just use one nginx for both domains?**: User requirement: ingress-nginx must remain the default and untouched. A second controller provides clean isolation.

### Why two separate ClusterIssuers?
Each solver ingress created by cert-manager during HTTP-01 challenge must use the correct ingress class. `letsencrypt` uses `class: nginx` (for the default controller), `letsencrypt-cilium` uses `class: cilium-nginx` (for the second controller). Without separate issuers, solver ingresses would be created with the wrong class and the challenge would fail.

## Known issues & workarounds

| Symptom | Root cause | Workaround |
|---|---|---|
| Cilium Envoy stuck on `127.0.0.1:12256` | hostNetwork not converged | `kubectl rollout restart -n cilium ds/cilium` 2-3 times until Envoy shows `0.0.0.0:8080` |
| `sharedListenerPort: 80` has no effect | Cilium 1.19.4 ignores this in chaining mode | Accept port 8080, or patch CiliumEnvoyConfig manually |
| nginx-ingress LB stops responding externally | Stale eBPF state after Cilium reconfiguration | `kubectl rollout restart -n ingress-ginx deploy/ingress-nginx-controller` |
| ACME cert stuck at "pending" | Stale CertificateRequest/Order from previous failed attempt with wrong ingress class | `kubectl delete certificaterequest -n <ns> --all && kubectl delete order -n <ns> --all` |
| Azure LB health probe fails after DNS label change | Transient cloud-controller-manager state | Wait 2-3 minutes or restart nginx pod |
| cilium-operator stuck at 2 replicas on single node | hostPort conflict, only 1 node | `kubectl scale deploy -n cilium cilium-operator --replicas=1` |
| `bpf.masquerade: true` breaks all connectivity | Incompatible with Azure CNI chaining | Never enable; keep `bpf.masquerade: false` |
| `externalTrafficPolicy: Local` changes are reverted | Cloud-controller-manager enforces Azure defaults | Accept default DSR behavior; work around it with nginx-based controllers |

## Failed experiments (noted to prevent repetition)

These were tried and conclusively proven ineffective:

| Attempt | Result |
|---|---|
| `forceDeviceDetection: true` | No effect (fix was for BGP, not Azure LB) |
| `azure-load-balancer-disable-floating-ip: "true"` annotation | Cloud provider ignores, always reverts to floating IP |
| Direct `az network lb rule update --floating-ip false` | Cloud provider reverts within ~30s |
| Manual LB backend pool / probe edits | Overwritten by cloud-controller-manager |
| `externalTrafficPolicy: Local` | Still uses DSR, no change in behavior |
| `bpf.masquerade: true` with `ipv4NativeRoutingCIDR` | Broke all pod-to-service connectivity |
| Cilium Ingress Controller with hostNetwork + separate LB service | Internal routing works, external SYN still times out (DSR applies at LB → node level) |

## Deployment from scratch

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit subscription_id

terraform init
terraform plan
terraform apply  # creates AKS + all Helm releases + manifests (~15 min)

# After apply, wait for TLS certs (cert-manager needs time for HTTP-01 challenge)
# Check progress:
kubectl get certificate -A
```

## Cleanup

```bash
cd terraform
terraform destroy
# If that leaves resource group behind:
az group delete --name rg-sandbox-aks --yes --no-wait
```
