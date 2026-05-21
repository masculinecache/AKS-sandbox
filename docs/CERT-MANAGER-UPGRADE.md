# cert-manager Upgrade Guide: v1.9.1 to v1.20.2

> **Scope:** Deep analysis for upgrading cert-manager from v1.9.1 to current stable (v1.20.2) with minimal downtime on an AKS 1.34.6 cluster.

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
- **Known bugs in intermediate versions** are documented and avoidable (see Section 4)

---

## 3. The Upgrade Path (Non-Negotiable)

> cert-manager's official stance: **upgrade one minor version at a time**, always taking the latest patch.

```
v1.9.1  →  v1.10.2  →  v1.11.5  →  v1.12.14  →  v1.13.8
   →  v1.14.5  →  v1.15.5  →  v1.16.5  →  v1.17.1
   →  v1.18.6  →  v1.19.4  →  v1.20.2
```

That's **11 sequential upgrades**. Each requires updating `version` in `terraform/helm.tf` and running `terraform apply`.

### Versions to Skip

| Version | Why to Skip | Use Instead |
|---|---|---|
| **v1.14.0–v1.14.3** | Broken Helm chart — wrong cainjector OCI image | **v1.14.5** |
| **v1.19.0** | Bug: unexpected certificate renewal when `issuerRef` kind omitted | **v1.19.4** |

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

---

## 5. Downtime Analysis

### What Goes Down

The **webhook** is the single point of failure. It performs three critical functions:

1. **Validation** — rejects invalid Certificate/Issuer/Order resources
2. **Mutation** — sets defaults on create/update
3. **Conversion** — supports multiple API versions

If the webhook pod is not ready, the Kubernetes API server **cannot process any cert-manager custom resources**. This means:

- Creating new Certificates → fails
- Updating existing Certificates → fails
- ACME Order processing → may stall
- **Reading/listing resources** → still works (served from etcd)

### What Does NOT Go Down

| Service | Behavior During Upgrade |
|---|---|
| **Existing TLS secrets** | Remain valid and mounted. Ingress controllers keep serving HTTPS |
| **Already-issued certificates** | Continue working; no interruption to live traffic |
| **Certificate renewal** | Paused while controller is down, but cert-manager renews at 30 days before expiry |
| **Ingress-nginx / Cilium** | Unaffected; they only read the TLS Secret, not cert-manager itself |

### The Webhook Startup Window

When the webhook pod restarts (every Helm upgrade), there is a sequence:

1. New webhook pod starts
2. Generates self-signed CA + serving certificate
3. cainjector detects the new CA, updates `caBundle` in ValidatingWebhookConfiguration/MutatingWebhookConfiguration
4. API server now trusts the new CA

**With a single replica, steps 1–4 create a hard downtime window** — no webhook pod is serving during the transition.

**With 3 replicas and RollingUpdate:** Old pods keep serving while new pods start, but there is still a brief risk when cainjector updates the `caBundle` — old pods serve with CA "A", new pods with CA "B", and the API server only trusts one CA at a time.

> The cert-manager team acknowledges that **some brief unavailability is expected during upgrades**, even with HA. 3+ replicas + PDB is the best mitigation.

---

## 6. Minimal-Downtime Strategy

### Phase 0: Pre-Stage High Availability (Do This First)

Before touching the cert-manager version, harden the current v1.9.1 deployment.

**Terraform change in `terraform/helm.tf`:**

```hcl
resource "helm_release" "cert_manager" {
  # ... existing config ...
  version = "1.9.1"  # Keep current version for now

  set = [
    {
      name  = "installCRDs"
      value = "true"
    },
    {
      name  = "webhook.replicaCount"
      value = "3"
    }
  ]
}
```

Then run `terraform apply`. This scales the webhook to 3 replicas **without any version change** — zero risk.

**Why this works on v1.9.1:** `webhook.replicaCount` has existed since early cert-manager versions. The chart creates a Deployment with the standard `RollingUpdate` strategy, so the 3-replica webhook will roll one pod at a time.

**Why we can't add PDB yet:** `webhook.podDisruptionBudget` was only added in **v1.12.0**. It literally does not exist in the v1.9.1 chart. You must wait until the v1.12 upgrade to enable it.

### Phase 1: The Upgrade Chain

For each version bump, update `version` in `terraform/helm.tf` and run `terraform apply`.

**At v1.12.x** (when webhook PDB becomes available), add:

```hcl
set = [
  # ... existing values ...
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
  }
]
```

**Recommended versions to target at each step:**

| Step | From | To | Notes |
|---|---|---|---|
| 1 | v1.9.1 | **v1.10.2** | Container name changes; no action needed |
| 2 | v1.10.2 | **v1.11.5** | Clean upgrade |
| 3 | v1.11.5 | **v1.12.14** | **Add webhook PDB values now** |
| 4 | v1.12.14 | **v1.13.8** | Clean upgrade |
| 5 | v1.13.8 | **v1.14.5** | Skip 1.14.0–1.14.3 |
| 6 | v1.14.5 | **v1.15.5** | `cmctl` separated; no impact |
| 7 | v1.15.5 | **v1.16.5** | Previously installed version |
| 8 | v1.16.5 | **v1.17.1** | Clean upgrade |
| 9 | v1.17.1 | **v1.18.6** | `RotationPolicy: Always` now default |
| 10 | v1.18.6 | **v1.19.4** | Skip v1.19.0 |
| 11 | v1.19.4 | **v1.20.2** | UID/GID change; final target |

### Phase 2: Post-Upgrade Hardening (Optional)

Once on v1.20.2, add production-grade HA settings:

```hcl
set = [
  {
    name  = "installCRDs"
    value = "true"
  },
  {
    name  = "replicaCount"
    value = "2"
  },
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
    name  = "global.priorityClassName"
    value = "system-cluster-critical"
  }
]
```

---

## 7. Verification Steps After Each Upgrade

After every `terraform apply` with a version bump:

```bash
# 1. Verify all pods are running
kubectl get pods -n cert-manager

# 2. Verify webhook is responsive
kubectl get validatingwebhookconfigurations cert-manager-webhook

# 3. Verify certificates are still valid
kubectl get certificate --all-namespaces

# 4. Verify ClusterIssuer is ready
kubectl get clusterissuer letsencrypt

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

---

## 8. Risk Matrix

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Webhook downtime during upgrade | High (single replica) | Medium (API ops fail) | Pre-stage 3 webhook replicas before any upgrade |
| Certificate expiry during long upgrade | Low | High | Certs renew 30 days before expiry; each step takes minutes |
| Stale Orders after version jump | Medium | Low (renewal stalls) | Monitor and delete stuck Orders/Requests |
| v1.18 RotationPolicy change | Certain | Low-Medium | Certs will rotate private keys on next renewal; ensure apps reload certs |
| Terraform state drift | Low | Medium | Use `terraform plan` before each apply |
| CiliumEndpoint loss after cert-manager restart | Medium | Medium | Restart cert-manager after Cilium install (already handled by `make step2`) |

---

## 9. Alternative: The "Clean Slate" Approach

If 11 sequential upgrades feels excessive, you have an alternative:

1. `make backup-certs` (save TLS secrets)
2. `terraform destroy` (destroy everything)
3. Update `helm.tf` to cert-manager v1.20.2 directly
4. `terraform apply` (fresh install)
5. `scripts/restore-certs.sh` (restore saved certs)
6. `make step2` (install Cilium, recreate ingresses)

**Pros:** Single version jump, no incremental risk, fastest path to v1.20.2.
**Cons:** Cluster destruction, DNS labels may change, all Azure resources recreated, Cilium reinstall required.

For a sandbox cluster, this is very reasonable. For production, the incremental path is safer.

---

## 10. References

- [cert-manager Supported Releases](https://cert-manager.io/docs/releases/)
- [cert-manager Upgrade Guide](https://cert-manager.io/docs/installation/upgrade/)
- [cert-manager v1.20 Release Notes](https://cert-manager.io/docs/releases/release-notes/release-notes-1.20/)
- [cert-manager v1.18 Release Notes](https://cert-manager.io/docs/releases/release-notes/release-notes-1.18/)
- [cert-manager Webhook Documentation](https://cert-manager.io/docs/concepts/webhook/)
- [cert-manager Best Practice Guide](https://cert-manager.io/docs/installation/best-practice/)
- [cert-manager Backup & Restore](https://cert-manager.io/docs/devops-tips/backup/)
- PR #3931 — [Added PodDisruptionBudgets to helm chart](https://github.com/cert-manager/cert-manager/pull/3931) (merged 2023-04-08, released v1.12.0)
