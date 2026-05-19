# Target Dev Cluster — allsynx-dev-test

Reference configuration for the production-adjacent dev cluster that this sandbox aims to mirror.

## Cluster & Node Pools

| Node pool | Mode | VM size | Count | Internal IPs |
|---|---|---|---|---|
| default | System | Standard_D4ds_v5 | 3 | 10.1.20.x |
| main2 | User | Standard_D2as_v4 | 5 | 10.1.8.x, 10.1.20.x, 10.1.60.x |
| ciliumtest | User | Standard_D2as_v4 | 1 | 10.1.58.x |

## CNI / Network Plugin

Pure Azure CNI — no Cilium, no overlay.

- `azure-cns` daemonset runs on every node (Azure Container Networking Service)
- `azure-ip-masq-agent` daemonset runs on every node
- Pods get Azure VNet IPs directly from the subnet (not an overlay CIDR)
- kube-proxy explicitly excludes eBPF/Cilium dataplane via node affinity selector: `kubernetes.azure.com/ebpf-dataplane NotIn [cilium]`
- No `networkPluginMode` — regular Azure CNI, not chained or overlay
- Pod interface prefix: `azv` (Azure CNI veth pairs)

## kube-proxy

| Setting | Value |
|---|---|
| Mode | iptables (default, no `--proxy-mode` flag) |
| Cluster CIDR | 10.1.0.0/18 |
| Detect local mode | InterfaceNamePrefix |
| HostNetwork | true (runs on host netns) |
| Image | mcr.microsoft.com/oss/v2/kubernetes/kube-proxy:v1.34.6-1 |

## Service & Pod Addressing

- Service CIDR: 10.0.0.0/16
- DNS service IP: 10.0.0.10
- Pod CIDR: 10.1.0.0/18 (Azure VNet IPs, each pod gets a real VNet IP)
- LB SKU: Standard
- Outbound type: loadBalancer (default Azure outbound via LB)

## HostPort Usage

Only CSI drivers use HostPort — no application pods:

| DaemonSet | HostPort |
|---|---|
| csi-azuredisk-node | 29603 |
| csi-azurefile-node | 29613, 29615 |

All other pods use standard `containerPort` only. The `ciliumtest` nodepool name suggests Cilium was evaluated at some point, but it's not active — the cluster is pure iptables/kube-proxy.

## Load Balancer & Ingress

- Single ingress controller: `ingress-nginx` at `40.77.10.33`, class `nginx`
- Ingress class `azure-application-gateway` also registered but no ingresses use it
- ~40 ingress resources across namespaces (bravo, echo, etc.) all pointing to class `nginx`, all behind the same LB IP
- All ingresses use the domain `*.thebenefitshub.com`

## Network Policies

None — `networkPolicy: none` at the AKS level.
