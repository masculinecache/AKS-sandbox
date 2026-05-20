provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.main.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = azurerm_kubernetes_cluster.main.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.main.kube_config.0.cluster_ca_certificate)
  }
}

# ── ClusterIssuers ────────────────────────────────────────────────────────────

resource "kubernetes_manifest" "letsencrypt" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt"
    }
    spec = {
      acme = {
        email  = var.acme_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-account-key"
        }
        solvers = [
          {
            http01 = {
              ingress = {
                class = "nginx"
              }
            }
          }
        ]
      }
    }
  }

  depends_on = [
    helm_release.cert_manager,
    time_sleep.wait_for_crds
  ]
}

# ── Ingresses ─────────────────────────────────────────────────────────────────

resource "kubernetes_manifest" "ingress_echo_nginx" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "echo-server-nginx"
      namespace = "echo-server-nginx"
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt"
      }
    }
    spec = {
      ingressClassName = "nginx"
      rules = [
        {
          host = "echo-nginx.centralus.cloudapp.azure.com"
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "echo-server-nginx"
                    port = {
                      number = 80
                    }
                  }
                }
              }
            ]
          }
        }
      ]
      tls = [
        {
          hosts      = ["echo-nginx.centralus.cloudapp.azure.com"]
          secretName = "echo-nginx-tls"
        }
      ]
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    helm_release.echo_nginx,
    kubernetes_manifest.letsencrypt
  ]
}

# ── Cilium Ingress (created in Step 2 via scripts/install-cilium.sh) ──────────
#
# The echo-cilium ingress is NOT created here because it requires Cilium to be
# installed first. Creating a cilium-class Ingress before Cilium is installed
# would fail validation.
#
# Step 2 (make step2) handles:
#   1. Cilium installation
#   2. Cilium ingress creation with http01-edit-in-place annotation
#   3. DNS label assignment
#   4. cert-manager restart
