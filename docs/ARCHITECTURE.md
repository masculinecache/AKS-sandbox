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
  ├── echo-nginx.centralus.cloudapp.azure.com ─── LB: ingress-nginx (172.170.50.73, class: nginx)
  │     └── echo-server-nginx
  └── echo-cilium.centralus.cloudapp.azure.com ─── LB: Cilium ingress controller (20.83.6.166, class: cilium)
        └── echo-server-cilium
```

Both apps are also behind the same `ingress-nginx` controller (class: nginx) as a secondary path.
echo-cilium has **dual ingress** — the primary Cilium LB (DNS label `echo-cilium`) and a secondary ingress-nginx path via the shared controller.
The dual path exists because the Azure DNS label `echo-cilium.centralus.cloudapp.azure.com` is bound to the Cilium LB's public IP.
If the Cilium ingress controller is removed, the DNS label must be reassigned to the ingress-nginx LB's public IP.

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
|---|---|---|---|---|
| cert-manager | cert-manager 1.9.1 | cert-manager | `installCRDs=true`, `force_conflicts=true` on ClusterIssuer |
| ingress-nginx | ingress-nginx 4.15.1 | ingress-nginx | LB probe `/healthz` |
| echo-server-nginx | echo-server 0.5.0 | echo-server-nginx | spot toleration |
| echo-server-cilium | echo-server 0.5.0 | echo-server-cilium | spot toleration |

### TLS

| Domain | ClusterIssuer | Ingress class(es) | Secret |
|---|---|---|---|---|
| echo-nginx.* | letsencrypt | nginx | echo-nginx-tls |
| echo-cilium.* | letsencrypt | nginx, cilium | echo-cilium-tls |

Both use the same `letsencrypt` ClusterIssuer with HTTP-01 challenge. echo-cilium has two ingress resources: one class `nginx` (via ingress-nginx shared LB) and one class `cilium` (via Cilium ingress controller LB at 20.83.6.166). The Cilium LB carries the Azure DNS label for echo-cilium.

## Target cluster equivalence

The sandbox targets `allsynx-dev-test` as a structural mirror. The table below evaluates networking equivalence — anything not listed is either identical (service CIDR, DNS IP, LB SKU, outbound type, kube-proxy iptables mode, HostPort usage, network policies) or non-structural (ingress count, app domains).

| Aspect | Target (allsynx-dev-test) | Sandbox | Status |
|---|---|---|---|---|
| CNI | Pure Azure CNI, no overlay, no pluginMode | Pure Azure CNI, no overlay, no pluginMode | ✅ Match |
| Pod CIDR | 10.1.0.0/18 (explicit) | Auto-assigned (not set in config) | ⚠️ Should be set explicitly |
| kube-proxy Cilium affinity | `kubernetes.azure.com/ebpf-dataplane NotIn [cilium]` (inert — no labeled nodes) | AKS default (same template) | ✅ Inert on both |
| Cilium deployed | No | Yes (CNI + ingress controller) | ⚠️ Not equivalent — kept for Cilium ingress testing |
| Ingress controller | ingress-nginx, class nginx, 1 LB | ingress-nginx (class nginx) + Cilium ingress controller, 2 LBs | ⚠️ Dual controllers: nginx for shared routing, Cilium for `echo-cilium` DNS label |
| Domain | `*.thebenefitshub.com` | `*.centralus.cloudapp.azure.com` | 🚫 Cannot serve target domain — sandbox uses own DNS suffix |

### Blocker

**Domain** is the only genuine networking blocker. You cannot terminate TLS or route traffic for `*.thebenefitshub.com` without owning that zone. The sandbox works around this by using its own `centralus.cloudapp.azure.com` suffix — all structural networking properties (CNI mode, CIDRs, kube-proxy, LB, no HostPort, no network policies) are already equivalent or one config change away.

### Required changes for networking equivalence

1. Set `pod_cidr = "10.1.0.0/18"` in `aks.tf` `network_profile`
2. Strip Cilium and its ingress controller, leaving only ingress-nginx (class nginx, 1 LB)
3. Reassign the `echo-cilium` Azure DNS label from the Cilium LB public IP to the ingress-nginx LB public IP
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
  │     ├── echo-server-nginx
  │     │     └── Ingress (echo-server-nginx, class: nginx)
  │     └── echo-server-cilium
  │           ├── Ingress (echo-server-cilium, class: nginx)
  │           └── Ingress (echo-server-cilium-ingress, class: cilium)
  ├── Cilium ingress controller (built-in, from cilium Helm chart)
  └── ClusterIssuer (letsencrypt)
```

Apply with `terraform apply`.

## Design decisions

### Spot instances
All workloads use spot node pools with tolerations. `spot_max_price = -1` means Azure evicts at the standard VM price.

### No external-dns
Azure DNS labels (`cloudapp.azure.com`) are used instead of custom domains.

### Dual ingress controllers (nginx + Cilium)
Both apps share `ingress-nginx` (class: nginx) as the primary controller. echo-cilium also has a Cilium ingress resource (class: cilium) served by Cilium's built-in ingress controller at a second Azure LB IP. The dual path exists because the `echo-cilium.centralus.cloudapp.azure.com` DNS label is bound to the Cilium LB's public IP — reassigning it to the ingress-nginx LB would consolidate to a single controller.

The `echo-cilium` name is retained for historical continuity from the earlier Cilium-based stack.

## Deployment workflow (two-phase apply)

`kubernetes_manifest` resources require the AKS cluster to exist before they can be planned. On a fresh cluster, Terraform cannot validate the provider config at plan time. The deployment is therefore split into phases.

### Using the deploy script (recommended)

```bash
./scripts/apply.sh             # phases 1 + 2 + 3
./scripts/apply.sh --phase 1   # infra only
./scripts/apply.sh --phase 2   # helm releases only (cluster must exist)
./scripts/apply.sh --plan      # plan all phases (dry-run)
```

### VM SKU selection

| Pool | SKU | Rationale |
|---|---|---|
| **System** | `Standard_D2s_v6` | Latest D-series (6th gen, Intel Xeon Platinum). Best price/performance in `centralus` — more cores per vCPU at the same price as v5. Suitable for control-plane workloads that must stay up. |
| **Spot** | `Standard_D2s_v5` | Previous gen, but **spot capacity is reliably available**. The v6 spot pool is newer and often has zero available capacity in `centralus`. For burst/evictable workloads, v5 is the pragmatic choice. |

The split also avoids a single SKU dependency — if v6 spot becomes scarce the cluster still bursts on v5, and vice versa. For this sandbox workload the performance difference is negligible; the choice is driven entirely by spot-market availability.

**If availability becomes a problem:**
- Both pools can be unified to `D2s_v5` (broader capacity, trivially slower).
- System pool could use `D2s_v6` with spot on `D2s_v5` as-is (current best-practice default).
- If spot reliability for v6 improves in the future, both can migrate to `D2s_v6`.

### System node count (2 instead of 1)

Azure CNI pre-allocates a block of IPs per node from the subnet. With a single system node and spot at 0 when idle, the cluster had no room to schedule system DaemonSets or pod replicas during rolling updates. Two nodes provide enough headroom for control-plane components to survive a node drain.

## Cilium ingress on vanilla AKS — empirical findings

The Cilium-built-in ingress controller **works** on vanilla AKS with `generic-veth` chaining + custom CNI config.

### Working setup

- `cni.chainingMode=generic-veth`, `cni.customConf=true`, `cni.configMap=cni-configuration`
- ConfigMap chains: `azure-vnet → cilium-cni → portmap`
- `ingressController.hostNetwork.enabled=false` (required — `hostNetwork=true` fails due to `NET_BIND_SERVICE` capability drop in `cilium-envoy-starter`)
- `enable-masquerade-to-route-source=true` (required with `bpf.masquerade=false` — without this, cilium-envoy's `reserved:ingress` identity egress to pods on other nodes times out with `cx_connect_fail`)
- `cni.exclusive` and `cni.chainingTarget` are irrelevant with `customConf=true`

### Why auto-chaining fails

Cilium's `findExistingCNIConfig()` cannot parse the Azure CNI `plugins[]` list format against the chaining target. The docs confirm `generic-veth` **requires** `customConf=true`.

### Why portmap chaining fails

With `cni.chainingMode=portmap`, Cilium does not create CiliumEndpoints for Azure CNI-managed pods. Envoy's EDS clusters have zero backends → "no healthy upstream".

### Full request path (working)

```
Internet → Azure LB (20.221.114.240) → NodePort → Cilium Envoy → EDS → backend pod (10.224.0.x:8080)
```

## Known issues & workarounds

### Manual phased apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit subscription_id
terraform init

# Phase 1 — create cluster and node pool (~8 min)
terraform apply -auto-approve \
  -target=azurerm_resource_group.main \
  -target=azurerm_kubernetes_cluster.main \
  -target=azurerm_kubernetes_cluster_node_pool.spot

# Phase 2 — deploy Helm releases (~2 min)
terraform apply -auto-approve \
  -target=helm_release.cert_manager \
  -target=helm_release.ingress_nginx \
  -target=helm_release.echo_nginx \
  -target=helm_release.echo_cilium

# Phase 3 — ClusterIssuer + Ingresses (~30s)
terraform apply -auto-approve
```

After Phase 3, cert-manager handles Let's Encrypt HTTP-01 challenges asynchronously. Check progress:

```bash
kubectl get certificate -A
```

### Why phases are needed

| Phase | Resources | Why separate |
|---|---|---|
| 1 | Resource group, AKS cluster, node pool | These don't need the Kubernetes API; they create the cluster that everything else depends on. |
| 2 | Helm releases (cert-manager, ingress-nginx, echo-server) | cert-manager must be fully deployed and its CRDs registered before `ClusterIssuer` can be created. A `time_sleep.wait_for_crds` (30s) provides a safety window between Phases 2 and 3. |
| 3 | ClusterIssuer, Ingresses | Requires both the cluster (API) and cert-manager CRDs. The plan now succeeds because both the cluster and providers are known to Terraform state. |

## cert-manager downgrade (1.16.5 → 1.9.1)

The sandbox was downgraded from cert-manager 1.16.5 to 1.9.1 to match the target dev cluster (allsynx-dev-test). Key findings:

### Compatibility

cert-manager 1.9.1 runs successfully on K8s 1.34.6 despite its official support matrix ending at K8s 1.24. All chart templates use GA API versions (`apiextensions.k8s.io/v1`, `admissionregistration.k8s.io/v1`), making them forward-compatible.

### Downgrade procedure

Helm refuses downgrade in-place (`helm upgrade --version` fails). The working approach:

1. Delete webhook configurations before modifying the Helm release to prevent Helm destroy from hanging:
   ```bash
   kubectl delete validatingwebhookconfigurations cert-manager-webhook
   kubectl delete mutatingwebhookconfigurations cert-manager-webhook
   ```
2. Taint the Helm release in Terraform state and re-apply:
   ```bash
   terraform taint helm_release.cert_manager
   terraform apply -auto-approve -target=helm_release.cert_manager
   ```
3. CRDs are re-installed automatically when `installCRDs=true`.

### Stale order cleanup

After downgrade, cert-manager logs showed a repeating error:
```
"ACME client for issuer not initialised/available"
```

Caused by the order controller re-processing Order resources that were created under cert-manager 1.16.5 and are in `valid` state. The ClusterIssuer's ACME client initializes correctly (`verified existing registration with ACME server`) but the in-memory issuer factory doesn't have the client available when the order controller queries it.

**Fix**: Delete the stale completed Orders:
```bash
kubectl delete order -n <namespace> <order-name>
```

The Certificate resources and Secrets remain intact. New certificate issuances create fresh Orders cleanly.

### Field manager conflicts

The `letsencrypt` ClusterIssuer requires `force_conflicts = true` on the Terraform `kubernetes_manifest` resource:
```hcl
field_manager {
  force_conflicts = true
}
```

Without this, cert-manager's status patches collide with Terraform's field ownership, causing `terraform apply` to fail on subsequent runs.

### DNS label management

Azure public IPs only support a single DNS label each. Reassigning a DNS label from one PIP to another is a two-step process:
```bash
# Remove from old PIP
az network public-ip update -g <rg> -n <old-pip> --set dnsSettings=null

# Add to new PIP
az network public-ip update -g <rg> -n <new-pip> --dns-name "<label>"
```

This is relevant when switching ingress controllers — the DNS label must follow the LB.

## Cleanup

```bash
./scripts/destroy.sh
# or manually:
# cd terraform && terraform destroy
# az group delete --name rg-sandbox-aks --yes --no-wait
```
