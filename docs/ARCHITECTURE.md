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

## Target cluster equivalence

The sandbox targets `allsynx-dev-test` as a structural mirror. The table below evaluates networking equivalence — anything not listed is either identical (service CIDR, DNS IP, LB SKU, outbound type, kube-proxy iptables mode, HostPort usage, network policies) or non-structural (ingress count, app domains).

| Aspect | Target (allsynx-dev-test) | Sandbox | Status |
|---|---|---|---|
| CNI | Pure Azure CNI, no overlay, no pluginMode | Pure Azure CNI, no overlay, no pluginMode | ✅ Match |
| Pod CIDR | 10.1.0.0/18 (explicit) | Auto-assigned (not set in config) | ⚠️ Should be set explicitly |
| kube-proxy Cilium affinity | `kubernetes.azure.com/ebpf-dataplane NotIn [cilium]` (inert — no labeled nodes) | AKS default (same template) | ✅ Inert on both |
| Cilium deployed | No | Yes (in config, PR #8 strips it) | ⚠️ Pending merge |
| Ingress controller | ingress-nginx, class nginx, 1 LB | ingress-nginx + cilium-ingress-nginx, 2 LBs | ⚠️ Strip second controller |
| Domain | `*.thebenefitshub.com` | `*.centralus.cloudapp.azure.com` | 🚫 Cannot serve target domain — sandbox uses own DNS suffix |

### Blocker

**Domain** is the only genuine networking blocker. You cannot terminate TLS or route traffic for `*.thebenefitshub.com` without owning that zone. The sandbox works around this by using its own `centralus.cloudapp.azure.com` suffix — all structural networking properties (CNI mode, CIDRs, kube-proxy, LB, no HostPort, no network policies) are already equivalent or one config change away.

### Required changes for networking equivalence

1. Set `pod_cidr = "10.1.0.0/18"` in `aks.tf` `network_profile`
2. Merge PR #8 to strip Cilium, cilium-ingress-nginx, echo-server-cilium, kubeview, and the `letsencrypt-cilium` ClusterIssuer
3. Delete the `ingress_echo_cilium` Ingress and `letsencrypt-cilium` ClusterIssuer resources
4. Accept the domain as-is — it does not affect networking behavior

## Cilium on vanilla Azure CNI — challenges and feasibility

Installing Cilium on a standard AKS cluster (no `network_data_plane = "cilium"`) introduces significant friction. This section documents why pure Azure CNI is preferred for the target cluster and what barriers exist to adding Cilium later.

### No overlay context

The target uses pure Azure CNI flat VNet — pods receive real Azure VNet IPs from the subnet, no overlay, no tunneling. This simplifies pod-to-pod routing (handled by Azure's VNet directly) but has implications for Cilium:

- The standard Cilium migration guide (docs.cilium.io "k8s-install-migration") assumes you can cleanly remove kube-proxy. On AKS the addon manager regenerates the DaemonSet — you can scale it to 0, but this is unsupported and fights the platform.
- Azure CNI chaining (`generic-veth` + `chainingTarget: azure-vnet`) is a non-standard configuration path the basic migration guide doesn't cover. The chaining-specific settings (`bpf.masquerade=false`, `endpointRoutes.enabled=true`, etc.) must be derived from experimentation.

### Seven friction points

| # | Issue | Root cause | Severity |
|---|---|---|---|
| 1 | **kube-proxy conflict** | AKS never labels nodes with `kubernetes.azure.com/ebpf-dataplane=cilium` on vanilla clusters. kube-proxy keeps running on every node. `kubeProxyReplacement=true` causes two dataplanes managing the same iptables rules — race conditions, dropped connections, reconciliation loops. `kubeProxyReplacement=probe` degrades to hybrid mode, losing eBPF benefits. | 🔴 Critical |
| 2 | **Cilium ingress controller not serving external traffic** | External requests to the Cilium ingress controller LB timed out; internal traffic worked. Root cause undiagnosed — no packet capture taken. Leading theory (untested): DSR/TPROXY incompatibility where SYN arrives with non-local destination IP and TPROXY cannot redirect. Alternative theories include Envoy convergence failure, health probe rejection, port collision. Workaround: second nginx-based controller (`cilium-ingress-nginx`). | 🔴 Critical |
| 3 | **`bpf.masquerade` must be false** | Non-negotiable in chaining mode — `true` breaks all pod-to-service connectivity. Cilium falls back to iptables-based masquerading, defeating part of the eBPF value proposition. | 🟡 Significant |
| 4 | **hostNetwork convergence flaky** | Envoy often lands on `127.0.0.1:12256` instead of `0.0.0.0:8080` after install or config change. Requires 2-3 manual daemonset restarts — no operator logic handles this. | 🟡 Significant |
| 5 | **Resource pressure on small SKUs** | Cilium agent + Envoy consume ~500-800 MB RAM per node. Manageable on D2as_v4/D4ds_v5 but prohibitive on B-series (B2s). | 🟡 Moderate |
| 6 | **Network policy surprises** | Cilium enables policy enforcement by default. Target has `networkPolicy: none` at the AKS level — policies can silently break existing traffic (~40 ingresses) without explicit allow rules. Requires `policyEnforcementMode=default` with permissive defaults. | 🟡 Moderate |
| 7 | **Upgrade coupling** | AKS node image upgrades can ship newer `azure-cns` that changes IPAM or veth behavior, breaking Cilium's chaining config. Cilium, Azure CNI, and Kubernetes versions must all align — no independent upgrades. | 🟢 Minor |

### `bpf.hostLegacyRouting: true` — not applicable

This setting controls host-namespace to pod-namespace routing (iptables vs TC eBPF at the host level). The Cilium ingress controller failure (#2 above) is at a different layer — the external traffic never reaches Envoy regardless of how host-to-pod routing works. Whether Cilium uses iptables or eBPF for the host-to-pod hop doesn't matter if the initial SYN never arrives at Envoy. The hybrid approach (ingress-nginx for external traffic, Cilium KPR for internal service routing) already works correctly and `bpf.hostLegacyRouting` doesn't simplify it. If the root cause turns out to be something other than DSR/TPROXY (e.g., Envoy convergence failure), this conclusion should be revisited.

### Recommendation

The only clean path for Cilium on AKS is Azure CNI powered by Cilium (`network_data_plane = "cilium"`), where AKS handles the integration end-to-end, properly labels nodes to evict kube-proxy, and manages upgrades. For the existing target, pure Azure CNI avoids all seven issues. A new cluster with `network_data_plane = "cilium"` should be evaluated separately if eBPF dataplane benefits are needed.

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

**Short answer**: The Cilium-built-in ingress controller (Envoy via Cilium Ingress Controller) did not serve external traffic when tested. The root cause remains **undiagnosed** — see below for theories and untested hypotheses. A second nginx-based controller (`cilium-ingress-nginx`) was deployed as a working workaround.

**Observed behavior**: External HTTP/HTTPS requests to the Cilium ingress controller's LoadBalancer IP timed out. Internal cluster traffic (pods reaching the Envoy service ClusterIP) worked correctly. No tcpdump or packet capture was taken at the time.

**Leading theory (untested) — DSR/TPROXY incompatibility**:
- Azure LB with DSR sends TCP SYNs to the node with the LB IP as destination (not a NodePort)
- Cilium's eBPF TPROXY hook on `eth0` may fail to redirect these packets to the local Envoy process because TPROXY with a non-local destination IP requires special kernel handling
- The SYN never reaches Envoy → no SYN-ACK → client times out

**Alternative theories (also untested)**:

| Theory | What it would look like | How to test |
|---|---|---|
| CiliumEnvoyConfig never converged | Envoy stuck on `127.0.0.1:12256` instead of `0.0.0.0:8080` | `kubectl exec -n cilium ds/cilium -- ss -tlnp \| grep envoy` before and after restart |
| Cilium ingress controller Service's `externalTrafficPolicy` defaulted to Cluster, and DSR + Cluster mode together confused reply routing | SYN reaches Envoy, SYN-ACK is sent but source IP is wrong, client never receives it | Set `externalTrafficPolicy: Local` on the Cilium ingress controller's LoadBalancer service |
| Azure LB health probe never passed → backends marked unhealthy → LB drops traffic | LB probe requests to the health check endpoint return non-200 | Check LB backend health in Azure portal; verify the Cilium ingress controller's `/healthz` endpoint works |
| Cilium agent not running the ingress controller at all (misconfiguration or Helm values not applied) | No Envoy listener on any port | `kubectl exec -n cilium ds/cilium -- cilium status` to verify ingress controller is enabled and running |
| hostNetwork collision on port 80/443 with another process on the node (e.g., kube-proxy's health check server) | Port conflict logged in Cilium agent logs | Check `kubectl logs -n cilium ds/cilium` for EADDRINUSE |

**Why nginx works regardless of the root cause**:
- nginx ingress is deployed as a standard Kubernetes Service of type LoadBalancer
- Azure LB forwards traffic to NodePorts on the nodes
- kube-proxy (or Cilium KPR) routes from NodePort to the nginx pod
- This path does not depend on eBPF TPROXY, hostNetwork, or any Cilium-specific ingress mechanism — it works the same way any LoadBalancer Service works on AKS

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
| Cilium Ingress Controller with hostNetwork + separate LB service | External traffic timed out, internal traffic worked. Root cause not captured — no tcpdump taken. DSR/TPROXY leading theory only. |

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
