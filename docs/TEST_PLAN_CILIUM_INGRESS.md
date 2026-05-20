# Test Plan & Results: Cilium Ingress Controller on Vanilla AKS

## Objective

Determine why the Cilium-built-in ingress controller (Envoy via CEC) does not serve external traffic on a standard AKS cluster with Azure CNI (no `network_data_plan = "cilium"`).

## Outcome

The Cilium ingress controller **works** on vanilla AKS with the right configuration. Verified end-to-end: external client → Azure LB → Envoy → echo-server pod.

**Critical finding**: cert-manager pods deployed **before** Cilium have **no CiliumEndpoint**. Without a CiliumEndpoint, cert-manager's Go HTTP client traffic is invisible to Cilium's identity-aware BPF dataplane. The L7 LB (Envoy) receives SYN packets from an "unknown" identity (`SourceSecurityID=0`) and drops them with `connection refused`. Restarting cert-manager after Cilium is installed creates the CiliumEndpoint and resolves the issue.

---

## Working configuration

### Step 1: Create the CNI ConfigMap

The ConfigMap must be created **before** installing Cilium, with the key `cni-config` in the `kube-system` namespace:

```bash
kubectl create configmap cilium-cni-configuration -n kube-system \
  --from-literal=cni-config='{
  "cniVersion": "0.3.1",
  "name": "azure",
  "plugins": [
    {
      "type": "azure-vnet",
      "mode": "transparent",
      "ipsToRouteViaHost": ["169.254.20.10"],
      "ipam": { "type": "azure-vnet-ipam" }
    },
    {
      "type": "portmap",
      "capabilities": { "portMappings": true },
      "snat": true
    },
    {
      "type": "cilium-cni",
      "enable-debug": false
    }
  ]
}'
```

**Critical**: The key name must be exactly `cni-config`. Cilium mounts the ConfigMap at `/tmp/cni-configuration/` and expects a file named `cni-config`. Using `cni-conf.json` or any other key name fails silently.

### Step 2: Install Cilium

Use the provided script which auto-detects the VNet CIDR and applies best-practice settings:

```bash
./scripts/install-cilium.sh
```

Or manually:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm install cilium cilium/cilium --version 1.19.4 \
  --namespace kube-system \
  --set cni.chainingMode=generic-veth \
  --set cni.customConf=true \
  --set cni.configMap=cilium-cni-configuration \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.224.0.0/12 \
  --set ipam.mode=kubernetes \
  --set bpf.masquerade=false \
  --set enableIPv4Masquerade=true \
  --set enableMasqueradeToRouteSource=true \
  --set kubeProxyReplacement=true \
  --set loadBalancer.mode=dsr \
  --set ingressController.enabled=true \
  --set ingressController.default=false \
  --set ingressController.enforceHttps=true \
  --set ingressController.loadbalancerMode=dedicated \
  --set hubble.enabled=false \
  --set operator.replicas=1
```

**Key settings for Azure CNI + DSR**:
- `routingMode=native` — Required for DSR mode (disables vxlan tunneling)
- `ipv4NativeRoutingCIDR` — Must match the AKS VNet CIDR (auto-detected by script)
- `loadBalancer.mode=dsr` — Direct Server Return for optimal performance
- `ipam.mode=kubernetes` — Azure CNI handles IPAM, not Cilium

⚠️ **Note**: After install, wait ~30s for EDS to sync before testing. Early requests may return `503 Service Unavailable — upstream connect error`.

### Step 3: Restart cert-manager (if already deployed)

If cert-manager was deployed **before** Cilium, it has no CiliumEndpoint. Restart it:

```bash
kubectl delete pod -n cert-manager -l app.kubernetes.io/name=cert-manager
```

Verify the new pod has a CiliumEndpoint:

```bash
kubectl get ciliumendpoint -n cert-manager
# Expected: cert-manager-xxx   <security-id>   ready   <ip>
```

---

## Key findings

| Finding | Detail |
|---|---|
| DSR/TPROXY is **not** the issue | External traffic reaches Envoy without TPROXY problems when `hostNetwork.enabled=false` |
| `hostNetwork=true` fails due to capability drop | `cilium-envoy-starter` drops `NET_BIND_SERVICE` before exec'ing Envoy — CapEff=0 on PID 7 |
| `portmap` chaining fails to create CiliumEndpoints | Cilium does not create endpoints for Azure CNI pods when using `portmap` chaining, so EDS has zero backends |
| `generic-veth` chaining creates CiliumEndpoints | With `generic-veth` + `customConf=true`, Cilium creates proper endpoints and EDS routing works |
| Auto-chaining is not supported for `generic-veth` | Cilium docs confirm `generic-veth` requires `customConf=true`. The `findExistingCNIConfig` function cannot parse the Azure CNI `plugins[]` format. |
| EDS sync delay after restart | Envoy's EDS cluster takes ~20-30s to reflect backend endpoints after Cilium agent restart + pod recreation |
| `endpointRoutes.enabled` is **not needed** | Azure CNI assigns directly-routable VNet IPs; per-endpoint routes are redundant. Confirmed with `InstallEndpointRoute: false` — `rq_success::1`. |
| ConfigMap key must be `cni-config` | The Cilium agent mounts the ConfigMap at `/tmp/cni-configuration/` and expects a file named `cni-config`. Using `--from-literal=config=...` fails silently. |
| ConfigMap must be in `cilium` namespace | Helm sets `cni.configMap=cni-configuration`, but the Cilium agent looks for it in its own namespace (`cilium`), not `kube-system`. |
| `kubeProxyReplacement=true` is required | The initial Cilium install with `kubeProxyReplacement=true` removes AKS's kube-proxy DaemonSet. Switching to `false` later leaves no kube-proxy replacement, breaking NodePort/LB forwarding. |
| `enableMasqueradeToRouteSource=true` fixes cross-node Envoy→backend connectivity | Without this, cilium-envoy's `reserved:ingress` identity egress connections to pods on other nodes time out (`cx_connect_fail`). The setting causes outbound traffic from Envoy to be masqueraded to the local route source IP, allowing return traffic to be properly routed. Note: incompatible with `bpf.masquerade=true`. |
| **cert-manager needs CiliumEndpoint** (NEW) | Pods without CiliumEndpoints cannot reach services through Cilium's L7 LB. cert-manager's ACME self-check fails with `connection refused` until restarted after Cilium install. |
| **Azure DNS labels are single-PIP** (NEW) | Each Azure public IP supports exactly one DNS label. Reassigning requires removing from old PIP first: `--set dnsSettings=null`. |
| **Cilium ingress TLS chicken-and-egg** | A Cilium Ingress with `tls:` blocks ACME HTTP-01 challenges because Envoy redirects HTTP→HTTPS before the certificate exists. **Fix**: Add `acme.cert-manager.io/http01-edit-in-place: "true"` annotation — cert-manager issues a temporary self-signed cert first, allowing the redirect to work, then replaces it with the real cert. |

---

## Prerequisites

- AKS cluster, Azure CNI, no `network_data_plan = "cilium"`, no overlay
- Cilium installed via Helm with `ingressController.enabled=true` (and `hostNetwork.enabled=true` if using that mode)
- A test LoadBalancer service exposing the Cilium ingress controller
- A test ingress + backend pod (echo-server or similar) provisioned behind the Cilium ingress class
- Node with `kubectl exec` access and `tcpdump` available (or install via `apt-get update && apt-get install -y tcpdump` on a debug pod with hostNetwork)
- Second terminal / tmux pane for simultaneous observation

---

## Migration plan flow

Use the Makefile for effortless deployment:

```bash
make all    # Full deployment: phases 1-6 + verification
```

Or run phases individually:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 1: Azure Infrastructure                    │
│  make phase1                                                        │
│                                                                     │
│  Creates: Resource Group, AKS Cluster, Spot Node Pool               │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 2: cert-manager                            │
│  make phase2                                                        │
│                                                                     │
│  Installs cert-manager Helm chart + waits for CRDs                  │
│  (Required before any kubernetes_manifest resources)                │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 3: ingress-nginx + echo servers            │
│  make phase3                                                        │
│                                                                     │
│  Installs ingress-nginx, echo-server-nginx, echo-server-cilium    │
│  (Creates namespaces for ingress resources)                         │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 4: K8s manifests                           │
│  make phase4                                                        │
│                                                                     │
│  Applies: ClusterIssuer, Ingresses (nginx + cilium)                 │
│  Certificates begin ACME challenge process                          │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 5: DNS labels                              │
│  make phase5                                                        │
│                                                                     │
│  Auto-discovers LoadBalancer IPs and sets Azure DNS labels          │
│  (echo-nginx → ingress-nginx LB, echo-cilium → Cilium LB)         │
│  Required for Let's Encrypt ACME challenges to resolve              │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Phase 6: Cilium                                  │
│  make phase6                                                        │
│                                                                     │
│  Installs Cilium with:                                              │
│  - generic-veth Azure CNI chaining                                  │
│  - Native routing (required for DSR)                                │
│  - DSR load balancer mode                                           │
│  - Ingress controller with dedicated LB                             │
│                                                                     │
│  ⚠️ cert-manager pods created BEFORE Cilium have NO CiliumEndpoint │
│     Run: make restart-cert-manager                                  │
└─────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Verify                                           │
│  make verify                                                        │
│                                                                     │
│  Tests both endpoints with valid TLS certificates:                  │
│  - https://echo-nginx.centralus.cloudapp.azure.com                  │
│  - https://echo-cilium.centralus.cloudapp.azure.com                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

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
| 2 | **Cilium ingress controller not serving external traffic** | External requests to the Cilium ingress controller LB timed out; internal traffic worked. Root cause: pods without CiliumEndpoints (like cert-manager deployed before Cilium) cannot reach Envoy. `hostNetwork=true` also fails due to `NET_BIND_SERVICE` capability drop. | 🔴 Critical |
| 3 | **`bpf.masquerade` must be false** | Non-negotiable in chaining mode — `true` breaks all pod-to-service connectivity. Cilium falls back to iptables-based masquerading, defeating part of the eBPF value proposition. | 🟡 Significant |
| 4 | **hostNetwork convergence flaky** | Envoy often lands on `127.0.0.1:12256` instead of `0.0.0.0:8080` after install or config change. Requires 2-3 manual daemonset restarts — no operator logic handles this. | 🟡 Significant |
| 5 | **Resource pressure on small SKUs** | Cilium agent + Envoy consume ~500-800 MB RAM per node. Manageable on D2as_v4/D4ds_v5 but prohibitive on B-series (B2s). | 🟡 Moderate |
| 6 | **Network policy surprises** | Cilium enables policy enforcement by default. Target has `networkPolicy: none` at the AKS level — policies can silently break existing traffic (~40 ingresses) without explicit allow rules. Requires `policyEnforcementMode=default` with permissive defaults. | 🟡 Moderate |
| 7 | **Upgrade coupling** | AKS node image upgrades can ship newer `azure-cns` that changes IPAM or veth behavior, breaking Cilium's chaining config. Cilium, Azure CNI, and Kubernetes versions must all align — no independent upgrades. | 🟢 Minor |

### `bpf.hostLegacyRouting: true` — not applicable

This setting controls host-namespace to pod-namespace routing (iptables vs TC eBPF at the host level). The Cilium ingress controller failure (#2 above) is at a different layer — the external traffic never reaches Envoy regardless of how host-to-pod routing works. Whether Cilium uses iptables or eBPF for the host-to-pod hop doesn't matter if the initial SYN never arrives at Envoy. The hybrid approach (ingress-nginx for external traffic, Cilium KPR for internal service routing) already works correctly and `bpf.hostLegacyRouting` doesn't simplify it. If the root cause turns out to be something other than DSR/TPROXY (e.g., Envoy convergence failure), this conclusion should be revisited.

### Recommendation

The only clean path for Cilium on AKS is Azure CNI powered by Cilium (`network_data_plane = "cilium"`), where AKS handles the integration end-to-end, properly labels nodes to evict kube-proxy, and manages upgrades. For the existing target, pure Azure CNI avoids all seven issues. A new cluster with `network_data_plane = "cilium"` should be evaluated separately if eBPF dataplane benefits are needed.

---

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

---

## Tests (ordered least→most invasive)

### Phase 1: Verify Envoy is listening

**Goal**: Eliminate theory #1 (Envoy never converged).

```bash
# On each node or via kubectl:
kubectl exec -n cilium ds/cilium -- ss -tlnp | grep envoy
```

| Expected | Actual |
|---|---|
| `0.0.0.0:8080` (sharedListenerPort ignored in chaining, CEC uses 8080) | ✅ `0.0.0.0:8080` — Envoy converged correctly with `hostNetwork=false`. With `hostNetwork=true`, `127.0.0.1:12256` due to `NET_BIND_SERVICE` capability drop. |

### Phase 2: Confirm Cilium ingress controller is active

**Goal**: Eliminate theory #4 (ingress controller not running).

```bash
kubectl exec -n cilium ds/cilium -- cilium status
```

Check for: `Ingress Controller: Enabled` in the output.

If disabled, verify Helm values — the issue is deployment config, not networking.

### Phase 3: Test LB health probe

**Goal**: Eliminate theory #3 (backends marked unhealthy).

```bash
# From within the cluster (a debug pod or the node itself):
curl -s -o /dev/null -w "%{http_code}" http://<cilium-ingress-svc-cluster-ip>/healthz

# From Azure CLI:
az network lb probe list \
  --resource-group MC_rg-sandbox-aks_sandbox-aks_centralus \
  --lb-name kubernetes-internal \
  --query "[?contains(name, 'cilium')].{Name:name,Port:port,ProbeThreshold:numberOfProbes,Interval:intervalInSeconds}" \
  -o table
```

If the cluster-internal health check returns non-200 or the LB probe shows unhealthy backends, the issue is health probe configuration — the LB won't forward traffic.

### Phase 4: Check CiliumEndpoint for cert-manager

**Goal**: Verify the critical finding — pods without CiliumEndpoints cannot reach Cilium L7 LB.

```bash
# Check if cert-manager has a CiliumEndpoint
kubectl get ciliumendpoint -n cert-manager

# Expected output if working:
# NAME                            SECURITY IDENTITY   ENDPOINT STATE   IPV4
# cert-manager-xxx                57357               ready            10.224.0.x

# If NO output — cert-manager was deployed before Cilium.
# Fix: restart cert-manager
kubectl delete pod -n cert-manager -l app.kubernetes.io/name=cert-manager
```

### Phase 5: tcpdump — does the SYN arrive?

**Goal**: Distinguish DSR/TPROXY theory from Envoy convergence theory with empirical data.

On a node that has a Cilium ingress controller pod scheduled:

```bash
# Determine which node runs the ingress controller pod
INGRESS_NODE=$(kubectl get pod -n cilium -l io.cilium/app=operator -o jsonpath='{.items[0].spec.nodeName}')

# Start tcpdump on that node — capture traffic to the LB frontend IP
# (replace LB_FRONTEND_IP with the actual LoadBalancer IP)
kubectl debug node/$INGRESS_NODE -it --image=nicolaka/netshoot -- /bin/bash
# Inside the debug pod:
tcpdump -i any -nn -e "tcp port 80 or tcp port 443" -w /tmp/cilium-ingress.pcap
```

From outside the cluster, send traffic to the LB:

```bash
curl -sv http://<LB_IP> 2>&1
curl -sv https://<LB_IP> 2>&1
```

Stop tcpdump after 10-15 seconds and analyze:

```bash
tcpdump -r /tmp/cilium-ingress.pcap -nn
```

| Observed | Conclusion |
|---|---|
| SYN packet seen arriving at node, **no SYN-ACK** emitted from the node | DSR/TPROXY theory plausible. SYN reaches node with LB IP as dst, kernel/NIC drops it or TPROXY can't redirect. |
| SYN packet seen arriving at node, **SYN-ACK emitted** | Envoy is receiving and responding. Issue is in reply routing (see Phase 6). |
| **No SYN packet** seen at node at all | Not a Cilium issue. Azure LB is not forwarding traffic to this node — check probe status (Phase 3) or LB rule. Also verify the service selector matches the ingress controller pod labels. |

If the SYN arrives but no SYN-ACK returns, proceed to Phase 6 to isolate whether the problem is reply-routing or TPROXY handling.

### Phase 6: Test without hostNetwork

**Goal**: Eliminate theory #5 (port collision on host) and partially distinguish Envoy convergence from DSR.

Deploy the Cilium ingress controller with `hostNetwork.enabled=false` (the default). This creates a standard ClusterIP→NodePort path instead of binding directly to the host's port 8080.

```bash
helm upgrade cilium cilium/cilium --version 1.19.4 \
  --namespace cilium \
  --reuse-values \
  --set ingressController.hostNetwork.enabled=false
```

**Result**: ✅ External traffic **worked** with `hostNetwork=false`. Envoy returned `server: envoy` HTTP 404 (no backends) at the LB IP. This disproves DSR/TPROXY as the root cause.

---

## Summary

| Signal | Root cause |
|---|---|
| Envoy on `127.0.0.1:12256` (hostNetwork=true) | `NET_BIND_SERVICE` capability dropped by cilium-envoy-starter — CEC binds to `127.0.0.1` as fallback |
| Envoy on `0.0.0.0:8080` (hostNetwork=false), no healthy upstream | `portmap` chaining: Cilium doesn't create CiliumEndpoints for Azure CNI pods, so EDS has zero backends |
| Envoy on `0.0.0.0:8080`, healthy upstream | ✅ `generic-veth` chaining + `customConf=true` + custom ConfigMap — the working config |
| Auto-chaining fails always | Cilium's `findExistingCNIConfig` can't match the Azure CNI `plugins[]` format, and `generic-veth` requires `customConf=true` per docs |
| `endpointRoutes.enabled=true` not required | Azure CNI VNet IPs are directly routable; per-endpoint routes redundant. Tested `InstallEndpointRoute: false`. |
| cert-manager ACME self-check: `connection refused` | cert-manager deployed before Cilium → no CiliumEndpoint → traffic dropped by BPF. **Fix**: restart cert-manager after Cilium install. |
| Cilium Ingress with TLS blocks ACME challenges | Envoy redirects HTTP→HTTPS before certificate exists. **Fix**: Add `acme.cert-manager.io/http01-edit-in-place: "true"` on the Ingress. This auto-propagates to `cert-manager.io/issue-temporary-certificate: "true"` on the Certificate, creating a temp self-signed cert that allows the redirect to work. |
| Azure DNS label conflict | One DNS label per public IP. **Fix**: remove from old PIP before adding to new PIP. |

---

## References

### Documentation

- [Cilium Installation — Kubernetes](https://docs.cilium.io/en/stable/installation/k8s-install-helm/) — Helm install reference
- [Cilium CNI Chaining — Generic VETH](https://docs.cilium.io/en/stable/installation/cni-chaining-generic-veth/) — `generic-veth` chaining mode
- [Cilium Ingress Controller](https://docs.cilium.io/en/stable/network/servicemesh/ingress/) — Ingress controller configuration
- [Cilium kube-proxy replacement](https://docs.cilium.io/en/stable/network/kubernetes/kube-proxy-free/) — KPR mode requirements
- [Azure CNI — IP address management](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni) — Azure CNI pod networking
- [cert-manager ACME HTTP-01](https://cert-manager.io/docs/configuration/acme/http01/) — ACME challenge mechanism
- [cert-manager Ingress Shim](https://cert-manager.io/docs/usage/ingress/) — Automatic certificate provisioning

### Helm Charts

- `https://helm.cilium.io/` — Cilium Helm repository
- `https://charts.jetstack.io` — cert-manager Helm repository
- `https://kubernetes.github.io/ingress-nginx` — ingress-nginx Helm repository

### Azure Resources

- `service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path` — Azure LB health probe annotation
- `service.beta.kubernetes.io/azure-dns-label-name` — Azure DNS label annotation (when set via Service)
- `az network public-ip update --dns-name` — Azure CLI for DNS label management

### Related Issues

- Cilium `hostNetwork` + `NET_BIND_SERVICE`: Envoy binds to `127.0.0.1` instead of `0.0.0.0` when capability is dropped
- Azure CNI `plugins[]` format: Cilium's `findExistingCNIConfig()` cannot parse Azure CNI's CNI config structure
- cert-manager ACME self-check: Requires pod-to-service connectivity through the ingress controller for HTTP-01 validation
