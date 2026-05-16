# AKS Sandbox — Architecture & Debugging Chronicle

## Overview

Two independent ingress endpoints serving echo-server behind TLS, on a single-node AKS cluster with Cilium CNI chaining and spot instances.

| Endpoint | Ingress Controller | LB IP | Backend |
|---|---|---|---|
| `phillias-nginx.*` | ingress-nginx (class: `nginx`) | 20.236.249.188 | echo-server-nginx |
| `phillias-cilium.*` | cilium-ingress-nginx (class: `cilium-nginx`) | 20.80.113.117 | echo-server-cilium |

Both terminate TLS via cert-manager + Let's Encrypt.

---

## The Core Problem

**Goal**: Run Cilium Ingress Controller (Cilium's built-in L7 ingress, powered by Envoy via eBPF TPROXY) on AKS with Azure CNI, alongside an existing ingress-nginx.

**Result**: External connectivity to the Cilium ingress never worked. The path to the working two-ingress-nginx design was a sequence of failed experiments that progressively narrowed the root cause.

---

## Trace of All Experiments & Their Outcomes

### Phase 1 — Cilium Ingress Controller (vanilla)

| Attempt | What | Outcome |
|---|---|---|
| Deploy Cilium 1.19.4 with `ingressController.enabled=true` | Default config, no hostNetwork | Envoy stuck on `127.0.0.1:12256` — unreachable externally |
| Enable `hostNetwork.enabled=true` | Exposes Envoy on host ports | Still unreachable externally. Internal curl to pod IP works |
| Debug: Exec into Cilium agent, check Envoy admin | Found Envoy listeners on `127.0.0.1:12256` | Envoy not binding to `0.0.0.0` — hostNetwork not taking effect |
| Force-restart Cilium agent 3x | Eventually Envoy appears on `0.0.0.0:8080` | **Breakthrough**: hostNetwork works after multiple restarts. Config drift resolved. |

**Lesson**: hostNetwork mode in Cilium 1.19.4 with CNI chaining sometimes requires multiple agent restarts before the Envoy listener binds to `0.0.0.0`. The Cilium operator and agent don't always converge on first apply.

### Phase 2 — Envoy is Running, But External Access Still Fails

| Attempt | What | Outcome |
|---|---|---|
| Direct LoadBalancer service `cilium-ingress-lb` | New LB service targeting `:8080` (Envoy) | Internal DNS → Envoy works (404 response). External SYN times out |
| `forceDeviceDetection: true` | GitHub issue #42275 — forces device detection in eBPF | No change. That fix was for BGP, not Azure LB |
| `bpf.masquerade: true` + `ipv4NativeRoutingCIDR` | Enables BPF masquerading for pod-to-service | **Broke everything**. Internal pod-to-service connectivity completely lost. Had to revert. |
| `sharedListenerPort: 80` | Configmap shows `"80"`, but CiliumEnvoyConfig still created with port 8080 | Operator ignores this setting in chaining mode. Cilium 1.19.4 bug. |
| `service.beta.kubernetes.io/azure-load-balancer-disable-floating-ip: "true"` annotation | Tells Azure LB to disable DSR | Cloud provider ignores annotation, always reverts to `enableFloatingIP: true` |
| `az network lb rule update --floating-ip false --backend-port <NodePort>` | Direct CLI modification of LB rule | Cloud provider reverts within ~30s on next reconciliation |
| `externalTrafficPolicy: Local` | Changes LB to only route to nodes with local endpoints | Still creates DSR rules. Cloud provider always uses Floating IP. |
| Manually update Azure LB backend pools and probes | Override cloud-controller-manager's config | All overwritten by cloud-controller-manager within seconds |

**Root cause confirmed**: Azure's mandatory DSR/Floating IP mode on AKS sends TCP SYNs to the node with the *LB IP as destination*, not a NodePort. Cilium's eBPF TPROXY program hooks the TC ingress on `eth0` and attempts to redirect these packets to the local Envoy process. This fails because:

- The packet arrives with `dst=172.168.89.189:80` (the LB IP), not a local IP
- The eBPF program needs to do a TPROXY redirect to `127.0.0.1:8080` (Envoy)
- TPROXY with a non-local destination IP requires special kernel handling that breaks in this path
- The SYN never reaches Envoy → no SYN-ACK → client times out

**Why nginx ingress doesn't have this problem**: nginx ingress uses standard kube-proxy (or Cilium KPR) routing. Traffic goes LB → NodePort → kube-proxy → nginx pod. The pod IP (e.g. `10.224.0.31`) is a remote address, and Cilium's eBPF *forwards* the packet to the pod's network interface (veth pair), which works correctly with DSR. The packet leaves the host network namespace and enters the pod's namespace — the eBPF program handles this as standard service forwarding, not local TPROXY.

### Phase 3 — Failed Attempt to Disable DSR

| Attempt | What | Outcome |
|---|---|---|
| Deploy hostNetwork nginx to proxy `127.0.0.1:8080` | nginx DaemonSet on host network, listens on port 80/443, proxies to local Envoy | Not tested — the DSR issue applies at the LB → node level regardless of what listens on the node |
| Option 1: Cluster redeploy with Cilium as primary CNI | BYOCNI / Azure CNI Overlay mode | Highest effort. Requires cluster recreation. Not tested. |
| Option 2: Use existing ingress-nginx to proxy Cilium domain | Add `phillias-cilium` host to the nginx ingress, proxy to `echo-server-cilium.svc` | Works, but user requested ingress-nginx remain untouched |
| Option 3: Deploy second nginx ingress controller | Separate `cilium-ingress-nginx` with its own LB and DNS | **Chosen**. Clean separation. Same operational pattern. |

### Phase 4 — Second Nginx Ingress Implementation

| Attempt | What | Outcome |
|---|---|---|
| Deploy cilium-ingress-nginx via Helm | Second ingress-nginx controller, class `cilium-nginx`, externalTrafficPolicy=Local | LB IP `20.80.113.117` allocated. External HTTP works. |
| Move DNS label `phillias-cilium` from old LB to new LB | `az network public-ip update --dns-name` | DNS label moved successfully |
| Re-issue TLS cert | Clean stale CertificateRequest/Orders, update ClusterIssuer class to `cilium-nginx` | **Success**: Let's Encrypt issues cert for `phillias-cilium.centralus.cloudapp.azure.com` |
| Old nginx LB stops responding | Curl to `20.236.249.188` times out | Service looks healthy internally. Issue resolved by restarting nginx-ingress-controller pod. Suspect stale Cilium eBPF state. |

**Lesson**: After significant Cilium reconfiguration (especially hostNetwork toggle and LB service churn), the nginx ingress controller pod may need a restart to re-establish eBPF service mappings.

---

## Final Architecture

```
Internet
  │
  ├── phillias-nginx.centralus.cloudapp.azure.com ─┐
  │   LB: 20.236.249.188                            │
  │   └── ingress-nginx (class: nginx)              │
  │       └── echo-server-nginx ────────────────────┤
  │                                                 │
  ├── phillias-cilium.centralus.cloudapp.azure.com ─┘
  │   LB: 20.80.113.117                             
  │   └── cilium-ingress-nginx (class: cilium-nginx)
  │       └── echo-server-cilium                    
  │
  └── kubeview (72.152.58.240:8000)
```

All traffic flows: **Client → Azure LB (DSR) → Node → Cilium KPR → Pod IP**.

For nginx-based controllers, this path works because the backend is a pod IP routed through Cilium's kube-proxy replacement (standard service forwarding).

Cilium's TPROXY-based ingress cannot use this path because it requires local socket delivery of non-local destination IPs, which eBPF TPROXY cannot accomplish on Azure with DSR.

---

## Critical Configurations

### Cilium (`helm/values.yaml`)
```yaml
kubeProxyReplacement: true      # Required for Cilium Ingress Controller
routingMode: native
cni:
  chainingMode: generic-veth    # Required for Azure CNI coexistence
  chainingTarget: azure-vnet
bpf.masquerade: false           # BREAKS Azure CNI chaining
forceDeviceDetection: true      # No effect on DSR, kept for safety
ingressController:
  enabled: true
  hostNetwork:
    enabled: true               # Multiple agent restarts may be needed
    sharedListenerPort: 80      # Ignored by operator in chaining mode (uses 8080)
```

### ingress-nginx + cilium-ingress-nginx
```yaml
# Default ingress-nginx
controller.service.annotations:
  service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz

# cilium-ingress-nginx (2nd controller)  
controller:
  ingressClass: cilium-nginx
  ingressClassByName: true
  watchIngressWithoutClass: false
  service.externalTrafficPolicy: Local
```

### DNS & TLS
- Azure DNS labels (`cloudapp.azure.com`) — no subdomain support
- cert-manager ClusterIssuers — one per ingress class (`nginx`, `cilium-nginx`)
- TLS issuance may require cleaning stale CertificateRequest/Order objects if a previous attempt with a different controller class failed

---

## Known Issues

| Issue | Workaround |
|---|---|
| Cilium agent sometimes needs 2-3 restarts after hostNetwork toggle | `kubectl rollout restart -n cilium ds/cilium` until Envoy shows `0.0.0.0:8080` |
| `sharedListenerPort: 80` ignored in chaining mode | Accept port 8080, or patch CEC manually |
| nginx LB may stop responding after Cilium config changes | Restart nginx-ingress-controller pod |
| Stale ACME orders from previous controller class block re-issuance | Delete CertificateRequest + Order resources manually |
| Azure LB DSR cannot be disabled in AKS | Design around it (use nginx-based controllers) |
| BPF masquerade incompatible with Azure CNI chaining | Never enable — breaks all pod-to-service connectivity |
| Single spot node → hostPort conflicts on operator pods | Scale operator to 1 replica |
