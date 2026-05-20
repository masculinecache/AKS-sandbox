# Test Plan & Results: Cilium Ingress Controller on Vanilla AKS

## Objective

Determine why the Cilium-built-in ingress controller (Envoy via CEC) does not serve external traffic on a standard AKS cluster with Azure CNI (no `network_data_plan = "cilium"`).

## Outcome

The Cilium ingress controller **works** on vanilla AKS with the right configuration. Verified end-to-end: external client → Azure LB → Envoy → echo-server pod.

### Working configuration

The ConfigMap must be created **before** installing Cilium, with the key `cni-config` in the `cilium` namespace:

```bash
kubectl create namespace cilium

kubectl create configmap -n cilium cni-configuration --from-literal=cni-config='{
  "cniVersion": "0.3.0",
  "name": "azure",
  "plugins": [
    { "type": "azure-vnet", "mode": "transparent",
      "ipsToRouteViaHost": ["169.254.20.10"],
      "ipam": { "type": "azure-vnet-ipam" } },
    { "type": "cilium-cni", "chaining-mode": "generic-veth" },
    { "type": "portmap",
      "capabilities": { "portMappings": true }, "snat": true }
  ]
}'
```

Then install Cilium:

```bash
helm repo add cilium https://helm.cilium.io/

helm install cilium cilium/cilium --version 1.19.4 \
  --namespace cilium \
  --set kubeProxyReplacement=true \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.224.0.0/12 \
  --set ipam.mode=cluster-pool \
  --set cni.chainingMode=generic-veth \
  --set cni.customConf=true \
  --set cni.configMap=cni-configuration \
  --set bpf.masquerade=false \
  --set enable-masquerade-to-route-source=true \
  --set ingressController.enabled=true \
  --set ingressController.hostNetwork.enabled=false \
  --set ingressController.loadbalancerMode=shared \
  --set nodeinit.enabled=true
```

⚠️ **Note**: After install, wait ~30s for EDS to sync before testing. Early requests may return `503 Service Unavailable — upstream connect error`.

### Key findings

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
| `enable-masquerade-to-route-source=true` fixes cross-node Envoy→backend connectivity | Without this, cilium-envoy's `reserved:ingress` identity egress connections to pods on other nodes time out (`cx_connect_fail`). The setting causes outbound traffic from Envoy to be masqueraded to the local route source IP, allowing return traffic to be properly routed. Note: incompatible with `bpf.masquerade=true`. |

## Prerequisites

- AKS cluster, Azure CNI, no `network_data_plan = "cilium"`, no overlay
- Cilium installed via Helm with `ingressController.enabled=true` (and `hostNetwork.enabled=true` if using that mode)
- A test LoadBalancer service exposing the Cilium ingress controller
- A test ingress + backend pod (echo-server or similar) provisioned behind the Cilium ingress class
- Node with `kubectl exec` access and `tcpdump` available (or install via `apt-get update && apt-get install -y tcpdump` on a debug pod with hostNetwork)
- Second terminal / tmux pane for simultaneous observation

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

### Phase 4: tcpdump — does the SYN arrive?

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
| SYN packet seen arriving at node, **SYN-ACK emitted** | Envoy is receiving and responding. Issue is in reply routing (see Phase 5). |
| **No SYN packet** seen at node at all | Not a Cilium issue. Azure LB is not forwarding traffic to this node — check probe status (Phase 3) or LB rule. Also verify the service selector matches the ingress controller pod labels. |

If the SYN arrives but no SYN-ACK returns, proceed to Phase 5 to isolate whether the problem is reply-routing or TPROXY handling.

### Phase 5: Test without hostNetwork

**Goal**: Eliminate theory #5 (port collision on host) and partially distinguish Envoy convergence from DSR.

Deploy the Cilium ingress controller with `hostNetwork.enabled=false` (the default). This creates a standard ClusterIP→NodePort path instead of binding directly to the host's port 8080.

```bash
helm upgrade cilium cilium/cilium --version 1.19.4 \
  --namespace cilium \
  --reuse-values \
  --set ingressController.hostNetwork.enabled=false
```

**Result**: ✅ External traffic **worked** with `hostNetwork=false`. Envoy returned `server: envoy` HTTP 404 (no backends) at the LB IP. This disproves DSR/TPROXY as the root cause.

## Summary

| Signal | Root cause |
|---|---|
| Envoy on `127.0.0.1:12256` (hostNetwork=true) | `NET_BIND_SERVICE` capability dropped by cilium-envoy-starter — CEC binds to `127.0.0.1` as fallback |
| Envoy on `0.0.0.0:8080` (hostNetwork=false), no healthy upstream | `portmap` chaining: Cilium doesn't create CiliumEndpoints for Azure CNI pods, so EDS has zero backends |
| Envoy on `0.0.0.0:8080`, healthy upstream | ✅ `generic-veth` chaining + `customConf=true` + custom ConfigMap — the working config |
| Auto-chaining fails always | Cilium's `findExistingCNIConfig` can't match the Azure CNI `plugins[]` format, and `generic-veth` requires `customConf=true` per docs |
| `endpointRoutes.enabled=true` not required | Azure CNI VNet IPs are directly routable; per-endpoint routes redundant. Tested `InstallEndpointRoute: false`. |
