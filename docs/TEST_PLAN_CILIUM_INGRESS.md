# Test Plan: Cilium Ingress Controller on Vanilla AKS

## Objective

Determine why the Cilium-built-in ingress controller (Envoy via CEC) does not serve external traffic on a standard AKS cluster with Azure CNI (no `network_data_plan = "cilium"`). Internal traffic to the service ClusterIP works; external traffic via LoadBalancer times out.

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

| Expected | If wrong → |
|---|---|
| `0.0.0.0:8080` (sharedListenerPort ignored in chaining, CEC uses 8080) | **Theory A confirmed.** Envoy stuck on `127.0.0.1:12256`. Run `kubectl rollout restart -n cilium ds/cilium` up to 3 times and re-check. If it never transitions to `0.0.0.0:8080`, root cause is CEC convergence failure — stop. |

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

Wait for the CEC (CiliumEnvoyConfig) to reconcile and the LoadBalancer service to get a new IP (or reuse the existing one). Then re-run the tcpdump test (Phase 4).

| Result | Conclusion |
|---|---|
| External traffic now works | hostNetwork mode was the root cause — either port collision (#5) or Envoy convergence failure (#1 specific to hostNetwork). DSR theory is not the primary issue. |
| External traffic still fails, SYN arrives but no SYN-ACK | DSR/TPROXY theory (#6) is the most likely remaining cause. Cilium's eBPF TPROXY cannot redirect the non-local-destination SYN even through the standard service path. |
| External traffic still fails, no SYN arrives | Re-check all earlier phases; likely a deployment/configuration issue unrelated to Cilium ingress. |

If DSR/TPROXY is confirmed, move to Phase 6 as a final confirmation.

### Phase 6: Repeat on Azure CNI powered by Cilium

**Goal**: Confirm DSR/TPROXY theory by testing on a cluster where the platform manages the integration.

Provision a second AKS cluster with `network_profile.network_data_plane = "cilium"` (Azure CNI powered by Cilium). On this cluster:

1. AKS labels nodes with `kubernetes.azure.com/ebpf-dataplane=cilium` and evicts kube-proxy
2. Azure CNI + Cilium are integrated by the cloud provider
3. The Cilium daemonset may handle traffic differently at the host level

Install Cilium via Helm with the same `ingressController.enabled=true` config. Repeat Phases 1-4 on this cluster.

| Result | Conclusion |
|---|---|
| Cilium ingress works on powered-by-Cilium cluster | Strongly confirms DSR/TPROXY is the issue on vanilla AKS. The platform integration resolves the non-local-destination-IP problem. |
| Cilium ingress also fails on powered-by-Cilium cluster | Root cause is something other than DSR/TPROXY (e.g., Envoy convergence, health probes, misconfiguration common to both). Narrow down using Phases 1-5 on this cluster. |

## Summary

After executing Phases 1-4, you will know whether the SYN reaches the node. After Phase 5, you will know whether hostNetwork is the culprit. Phase 6 is the definitive test to validate or dismiss the DSR/TPROXY theory.

| Signal | Most likely root cause |
|---|---|
| Envoy on `127.0.0.1:12256` | CEC convergence failure |
| SYN arrives, no SYN-ACK, hostNetwork=on | DSR/TPROXY or port collision |
| SYN arrives, no SYN-ACK, hostNetwork=off | DSR/TPROXY |
| No SYN arrives at node | LB health probe or service selector misconfiguration |
| Works only on powered-by-Cilium cluster | AKS-integrated Cilium handles the non-local-IP path; vanilla chaining cannot |
