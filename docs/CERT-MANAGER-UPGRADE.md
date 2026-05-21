# cert-manager Upgrade Guide: v1.9.1 to v1.20.2

> **Scope:** Deep analysis for upgrading cert-manager from v1.9.1 to current stable (v1.20.2) with minimal downtime on an AKS 1.34.6 cluster.
>
> **Primary recommendation:** Reinstall rather than incremental upgrade — cert-manager officially recommends reinstalling for large version jumps, and it results in **less total downtime** than 11 sequential upgrades.

---

## 1. Current State

| Component | Current Value | Notes |
|---|---|---|
| cert-manager version | **v1.9.1** (Jul 2022) | Pinned exact in `terraform/helm.tf` |
| Kubernetes version | **1.34.6** | Compatible with all target versions |
| Controller replicas | **1** | Chart default |
| Webhook replicas | **1** | Chart default — **single point of failure** |
| CA injector replicas | **1** | Chart default |
| PodDisruptionBudget | **None** | Not available in v1.9.1 chart |
| Resource limits | **None** | Best-effort QoS |
| CRD management | `installCRDs=true` via Helm | Safe on K8s 1.34+ |
| Certificates managed | 2 (echo-nginx, echo-cilium) | HTTP-01 via Let's Encrypt |

**Historical note:** This cluster was previously downgraded from v1.16.5 to v1.9.1 to match a target environment. The downgrade required manual webhook config deletion and stale Order cleanup.

---

## 2. Why Upgrade?

- **v1.9.1 is ~3.5 years old** and no longer receives security patches
- **Webhook availability** is the primary operational risk — modern versions support HA webhook deployments
- **v1.20.2** adds `selectableFields` CRD support, improved ACME handling, and production-grade HA options
- **Known bugs in intermediate versions** are documented and avoidable

---

## 3. Approach Comparison: Incremental vs Reinstall

### Option A: Incremental Upgrade (11 steps) — NOT RECOMMENDED

The cert-manager docs say to upgrade one minor version at a time:

```
v1.9.1 → v1.10.2 → v1.11.5 → v1.12.14 → v1.13.8 → v1.14.5
  → v1.15.5 → v1.16.5 → v1.17.1 → v1.18.6 → v1.19.4 → v1.20.2
```

| Factor | Assessment |
|---|---|
| **Steps** | 11 separate `terraform apply` runs |
| **Webhook outages** | **11** — each upgrade triggers a webhook rolling restart |
| **Total webhook downtime** | ~2 minutes (11 × ~10s each) spread over hours |
| **Risk** | Each step is a chance for something to go wrong |
| **Breaking changes** | Must handle 7 breaking changes across 11 steps |
| **Versions to skip** | Must avoid v1.14.0–1.14.3 and v1.19.0 |

### Option B: Reinstall (1 step) — RECOMMENDED

cert-manager officially recommends **reinstalling** for large version jumps. See the [reinstall guide](https://cert-manager.io/docs/installation/reinstall/).

```
helm uninstall cert-manager -n cert-manager
helm install cert-manager cert-manager/cert-manager --version v1.20.2
```

| Factor | Assessment |
|---|---|
| **Steps** | 1 uninstall + 1 install |
| **Webhook outages** | **1** — a single window between uninstall and install |
| **Total webhook downtime** | ~35–65 seconds **total** |
| **Risk** | Lower — fewer operations, no incremental breakage |
| **Breaking changes** | Handled at once; CRD upgrade prepares the ground |
| **Versions to skip** | Automatically handled — you jump directly to the target |

### Why Reinstall Has Less Downtime

During a `helm upgrade`, the webhook performs a rolling restart. For ~10 seconds, the old webhook is down and the new one isn't ready yet. Doing this 11 times = ~110 seconds of webhook disruption spread across hours.

During a `helm uninstall` + `helm install`, there is **one** window of ~35–65 seconds where the webhook is absent. During that window, the API server has no webhook configuration to call — it simply passes cert-manager API operations through without validation. No errors, no retries, just unvalidated acceptance.

**Total outage time is lower with reinstall, and the user-facing impact is identical** — TLS traffic is never interrupted in either approach.

---

## 4. Breaking Changes That Affect This Cluster

| Jump | Breaking Change | Impact |
|---|---|---|
| **v1.9 → v1.10** | Container names changed (`cert-manager` → `cert-manager-controller`, etc.) | **Low** — only breaks scripts that hardcode container names |
| **v1.12 → v1.13** | `.featureGates` no longer passed to webhook; use `webhook.featureGates` | **None** — no feature gates are configured |
| **v1.14 → v1.15** | `cmctl` moved to separate repo; `cert-manager-ctl` image removed | **Low** — only affects if `cmctl` is used in scripts |
| **v1.17 → v1.18** | `RotationPolicy` default changes `Never` → `Always` | **Medium** — certificates will rotate private keys on renewal. Usually fine but may require pod restarts to pick up new TLS secrets |
| **v1.17 → v1.18** | ACME HTTP01 uses `PathType: Exact` | **None** — ingress-nginx v1.15.1 is well above affected versions (< 1.13.2) |
| **v1.19 → v1.20** | Container UID/GID changed 1000 → 65532 | **Low** — may affect PodSecurityPolicies; this cluster does not use them |
| **v1.19 → v1.20** | `DefaultPrivateKeyRotationPolicyAlways` promoted to GA | **None** — already the default since v1.18 |

All of these are handled in a **single reinstall**. No need to stage through intermediate versions.

---

## 5. Downtime Analysis

### What Actually Goes Down

The **webhook** is the only component that matters for availability. It performs three functions:

1. **Validation** — rejects invalid Certificate/Issuer/Order resources
2. **Mutation** — sets defaults on create/update
3. **Conversion** — supports multiple API versions

When the webhook is unavailable, the Kubernetes API server **cannot validate cert-manager custom resources**:
- Creating new Certificates → fails (with webhook errors if webhook config exists, or passes unvalidated if webhook config is absent)
- Updating existing Certificates → fails similarly
- ACME Order processing → may stall
- **Reading/listing resources** → still works (served from etcd)

### What Does NOT Go Down

| Service | Behavior During Reinstall |
|---|---|
| **Existing TLS secrets** | Remain valid and mounted. Ingress controllers keep serving HTTPS |
| **Already-issued certificates** | Continue working; no interruption to live traffic |
| **Certificate renewal** | Paused while controller is down, but cert-manager renews at 30 days before expiry |
| **Ingress-nginx / Cilium** | Unaffected; they only read the TLS Secret, not cert-manager itself |

### The Webhook Startup Window

When the webhook is reinstalled (not upgraded), the sequence is:

1. **Uninstall phase:** Old webhook deployment is deleted. Webhook configs (ValidatingWebhookConfiguration, MutatingWebhookConfiguration) are removed.
2. **Gap phase:** No webhook configs exist. The API server does not call any webhook for cert-manager resources — operations proceed unvalidated. This is **safe** because without conversion webhooks, existing resources remain accessible.
3. **Install phase:** New webhook pod starts, generates a self-signed CA + serving certificate, cainjector updates the `caBundle` in new webhook configs, API server starts calling the webhook again.

**Total window: ~35–65 seconds.**

### Key Insight: Webhook Config Deletion Is a Feature, Not a Bug

When webhook configurations are deleted during uninstall, the API server **stops trying to reach the webhook**. This means:

- No `connection refused` errors
- No `webhook call failed` retries
- Cert-manager API operations simply pass through without validation

Compare to a broken `helm upgrade` where the old webhook is gone but the old webhook config still points to it — that causes real errors. The reinstall approach avoids this entirely by cleanly removing and recreating the webhook configs.

---

## 6. Minimal-Downtime Strategy: Reinstall

### Phase 0: Pre-Reinstall Backup (Zero Downtime)

Back up all cert-manager resources. These are your safety net.

```bash
# TLS secrets (already automated)
scripts/backup-certs.sh

# Custom resources
kubectl get certificaterequests --all-namespaces -o yaml > cm-backup-cr.yaml
kubectl get certificates --all-namespaces -o yaml > cm-backup-certs.yaml
kubectl get issuers --all-namespaces -o yaml > cm-backup-issuers.yaml
kubectl get clusterissuers -o yaml > cm-backup-clusterissuers.yaml
kubectl get orders --all-namespaces -o yaml > cm-backup-orders.yaml
kubectl get challenges --all-namespaces -o yaml > cm-backup-challenges.yaml
```

### Phase 1: Upgrade CRDs First (Zero Downtime)

Upgrading CRDs is a **separate, safe operation** that does not require cert-manager to be running. CRD schema changes are additive and backward-compatible.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.crds.yaml
```

**Why this is safe:** CRDs only define the schema. Existing custom resources (Certificate, ClusterIssuer, etc.) remain in etcd. The API server continues to serve them. The `cert-manager.io/v1` API version has been the storage version since cert-manager v1.0, so there is no version conversion issue.

**Note:** cert-manager v1.20.2 uses `selectableFields` in its CRDs, which requires Kubernetes ≥ 1.32. This cluster runs 1.34.6, so this is fully compatible. The old Helm-managed CRDs (`installCRDs=true`) are safely replaced by the kubectl-applied ones.

### Phase 2: Uninstall Old cert-manager (~5 Seconds)

```bash
helm uninstall cert-manager -n cert-manager
```

What happens:
- The cert-manager controller, webhook, and cainjector Deployments are deleted
- Webhook configs (ValidatingWebhookConfiguration, MutatingWebhookConfiguration) are deleted
- **CRDs are NOT deleted** (Helm 3 does not delete CRDs on uninstall)
- Custom resources (Certificate, ClusterIssuer, Orders, Challenges) **remain in etcd**
- TLS secrets in application namespaces **remain intact**

**Critical:** Because the webhook configurations are deleted (not left dangling), the API server stops calling the webhook. Cert-manager API operations now pass through without validation — no errors, just unvalidated acceptance.

### Phase 3: Disable installCRDs and Update Helm Values

Before installing the new version, update `terraform/helm.tf`:

1. **Remove `installCRDs=true`** — CRDs are now managed separately via `kubectl apply`
2. **Change `version`** to `"1.20.2"`
3. **Add HA values** for the webhook

```hcl
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "1.20.2"

  set = [
    # CRDs are managed separately — not via Helm
    {
      name  = "webhook.replicaCount"
      value = "3"
    },
    {
      name  = "webhook.podDisruptionBudget.enabled"
      value = "true"
    },
    {
      name  = "webhook.podDisruptionBudget.minAvailable"
      value = "1"
    },
    {
      name  = "cainjector.replicaCount"
      value = "2"
    },
    {
      name  = "cainjector.podDisruptionBudget.enabled"
      value = "true"
    },
    {
      name  = "cainjector.podDisruptionBudget.minAvailable"
      value = "1"
    },
    {
      name  = "replicaCount"
      value = "2"
    },
    {
      name  = "global.priorityClassName"
      value = "system-cluster-critical"
    }
  ]
}
```

### Phase 4: Install New cert-manager (~30–60 Seconds)

```bash
terraform apply
# or directly:
helm install cert-manager cert-manager/cert-manager --version v1.20.2 \
  --namespace cert-manager \
  --create-namespace \
  --set webhook.replicaCount=3 \
  --set webhook.podDisruptionBudget.enabled=true \
  --set webhook.podDisruptionBudget.minAvailable=1 \
  --set cainjector.replicaCount=2 \
  --set cainjector.podDisruptionBudget.enabled=true \
  --set cainjector.podDisruptionBudget.minAvailable=1 \
  --set replicaCount=2 \
  --set global.priorityClassName=system-cluster-critical
```

What happens:
- New webhook deployment starts with 3 replicas
- New webhook configs are created
- cainjector generates the CA and updates `caBundle`
- Controller starts and discovers existing Certificate resources
- Controller detects existing TLS secrets → marks Certificates as Ready **without ACME issuance**
- ClusterIssuer is reconciled — Let's Encrypt account key (`letsencrypt-account-key`) is picked up from existing Secret

### Phase 5: Post-Upgrade Restart (If Cilium Is Installed)

If Cilium is installed, cert-manager pods need to be restarted to get CiliumEndpoints:

```bash
kubectl rollout restart deployment -n cert-manager -l app.kubernetes.io/name=cert-manager
kubectl rollout status deployment -n cert-manager --timeout=5m
```

This is the same issue documented in `TEST_PLAN_CILIUM_INGRESS.md` — pods deployed before Cilium have no CiliumEndpoint, so Azure LB health probes to the node fail.

---

## 7. Why This Works (The Mechanics)

### CRDs Survive Uninstall

Helm 3 does not delete CRDs when running `helm uninstall`. The cert-manager CRDs remain in the cluster with all custom resources intact.

**However**, with `installCRDs=true` in the old version, Helm created the CRDs. When uninstalling, Helm does NOT delete them. This is confirmed behavior across all Helm 3 versions. See [Helm docs: CRDs](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/).

### Existing Certificates Are Reused

When the new cert-manager controller starts and finds existing Certificate resources, it:

1. Checks if the referenced Secret exists
2. Verifies the certificate is still valid (not expired, correct domain)
3. If valid → marks the Certificate as `Ready=True` without creating any ACME Order
4. If near expiry → renews normally via ACME

This is the same mechanism that `scripts/restore-certs.sh` uses after a cluster rebuild.

### Let's Encrypt Account Survives

The ClusterIssuer references `privateKeySecretRef.name = "letsencrypt-account-key"`. This Secret contains the ACME account registration. If it already exists, the new cert-manager reuses it — no new ACME registration needed. This means no ACME rate limit concerns during the reinstall.

### The Webhook Downtime Window Is Lowest Possible

| Approach | Webhook Disruption | Total Operations |
|---|---|---|
| 11 incremental upgrades | ~110s cumulative (spread over hours) | 11 helm upgrades |
| **Reinstall (recommended)** | **~35–65s (one shot)** | **1 uninstall + 1 install** |
| Clean slate (destroy + rebuild) | ~300s+ (cluster creation) | Terraform apply |

---

## 8. Verification Steps

After the reinstall completes:

```bash
# 1. Verify all pods are running (3 webhook, 2 cainjector, 2 controller)
kubectl get pods -n cert-manager

# 2. Verify webhook is responsive
kubectl get validatingwebhookconfigurations cert-manager-webhook

# 3. Verify certificates are still valid
kubectl get certificate --all-namespaces
# Expected: both certificates show Ready=True

# 4. Verify ClusterIssuer is ready
kubectl get clusterissuer letsencrypt
# Expected: READY=True

# 5. Check for any stuck CertificateRequests
kubectl get certificaterequests --all-namespaces | grep -v True

# 6. Test the endpoints (should still serve HTTPS)
curl -I https://echo-nginx.centralus.cloudapp.azure.com
curl -I https://echo-cilium.centralus.cloudapp.azure.com
```

**If you see stuck CertificateRequests:** Delete them and cert-manager will recreate:

```bash
kubectl delete certificaterequest -n echo-server-nginx <stuck-request-name>
kubectl delete certificaterequest -n echo-server-cilium <stuck-request-name>
```

**If webhook doesn't become ready:** Check cert-manager logs:

```bash
kubectl logs -n cert-manager deployment/cert-manager-webhook
```

Common issue: cainjector may need time to generate the CA and update `caBundle` in webhook configurations.

---

## 9. Rollback Plan

If the reinstall fails, the rollback steps depend on what phase failed.

### If CRD upgrade fails (Phase 1)

CRD upgrades are additive. `kubectl apply` is idempotent. Simply revert:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.crds.yaml
```

### If uninstall succeeds but install fails (Phase 3 fails)

The cluster has no cert-manager. TLS secrets still serve HTTPS. To recover:

```bash
# Reinstall old version
helm install cert-manager cert-manager/cert-manager --version v1.9.1 \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Then restore from backup:

```bash
kubectl apply -f cm-backup-clusterissuers.yaml
kubectl apply -f cm-backup-certs.yaml
# etc.
```

### If everything fails

Run the clean slate approach:

```bash
make backup-certs
terraform destroy
# Fix helm.tf
terraform apply
scripts/restore-certs.sh
make step2
```

---

## 10. Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Webhook startup delay | Medium | Low (cainjector CA generation lags) | `rollout status --timeout=5m`; check logs |
| Certificate expiry if reinstall takes too long | Low | High | Certs renew 30 days before expiry; reinstall takes minutes |
| Stale Orders after reinstall | Medium | Low (renewal stalls) | Delete stuck Orders/Requests |
| v1.18 RotationPolicy change | Certain | Low-Medium | Certs will rotate private keys on next renewal |
| CRD storage version incompatibility | Low | Medium | Backup custom resources before CRD upgrade |
| Helm state drift (install outside Terraform) | Low | Medium | Use `terraform apply` not `helm install` directly |
| CiliumEndpoint loss after cert-manager restart | Medium | Medium | Restart cert-manager after Cilium install |

---

## 11. Quick Reference: All Commands

```bash
# === Pre-reinstall backup ===
scripts/backup-certs.sh
kubectl get certificaterequests --all-namespaces -o yaml > cm-backup-cr.yaml
kubectl get certificates --all-namespaces -o yaml > cm-backup-certs.yaml
kubectl get clusterissuers -o yaml > cm-backup-clusterissuers.yaml

# === Phase 1: CRD upgrade (zero downtime) ===
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.crds.yaml

# === Phase 2: Uninstall old (5s webhook gap) ===
helm uninstall cert-manager -n cert-manager

# === Phase 3: Update terraform/helm.tf ===
# Remove installCRDs, update version, add HA values

# === Phase 4: Install new (30-60s webhook startup) ===
terraform apply

# === Phase 5: Verify ===
kubectl get pods -n cert-manager
kubectl get certificate --all-namespaces
kubectl get clusterissuer letsencrypt
curl -I https://echo-nginx.centralus.cloudapp.azure.com
curl -I https://echo-cilium.centralus.cloudapp.azure.com

# === If Cilium is installed ===
kubectl rollout restart deployment -n cert-manager -l app.kubernetes.io/name=cert-manager
```

---

## 12. References

- [cert-manager Reinstall Guide](https://cert-manager.io/docs/installation/reinstall/)
- [cert-manager Supported Releases](https://cert-manager.io/docs/releases/)
- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager v1.20 Release Notes](https://cert-manager.io/docs/releases/release-notes/release-notes-1.20/)
- [cert-manager v1.18 Release Notes](https://cert-manager.io/docs/releases/release-notes/release-notes-1.18/)
- [cert-manager Webhook Documentation](https://cert-manager.io/docs/concepts/webhook/)
- [cert-manager Best Practice Guide](https://cert-manager.io/docs/installation/best-practice/)
- [cert-manager Backup & Restore](https://cert-manager.io/docs/devops-tips/backup/)
- PR #3931 — [Added PodDisruptionBudgets to helm chart](https://github.com/cert-manager/cert-manager/pull/3931)
- [Troubleshooting: Stale Orders](docs/ARCHITECTURE.md)
- [Certificate Backup/Restore Scripts](scripts/backup-certs.sh)
- [Cilium CiliumEndpoint Issue](docs/TEST_PLAN_CILIUM_INGRESS.md)
