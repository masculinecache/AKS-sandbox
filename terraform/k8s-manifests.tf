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
    kubernetes_manifest.letsencrypt
  ]
}

resource "kubernetes_manifest" "ingress_echo_cilium" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "echo-server-cilium"
      namespace = "echo-server-cilium"
      annotations = {
        "cert-manager.io/cluster-issuer" = "letsencrypt"
      }
    }
    spec = {
      ingressClassName = "nginx"
      rules = [
        {
          host = "echo-cilium.centralus.cloudapp.azure.com"
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "echo-server-cilium"
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
          hosts      = ["echo-cilium.centralus.cloudapp.azure.com"]
          secretName = "echo-cilium-tls"
        }
      ]
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_manifest.letsencrypt
  ]
}

# ── Cilium Ingress (optional — apply after Cilium is installed) ────────────────
#
# The acme.cert-manager.io/http01-edit-in-place annotation solves the TLS
# chicken-and-egg problem: Cilium Envoy redirects HTTP→HTTPS when tls: is
# configured, which breaks ACME HTTP01 challenges. This annotation makes
# cert-manager issue a temporary self-signed certificate first, allowing
# the redirect to work, then replace it with the real cert once issued.
#
# See docs/TEST_PLAN_CILIUM_INGRESS.md for full details.

resource "kubernetes_manifest" "ingress_echo_cilium_cilium" {
  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = "echo-server-cilium-ingress"
      namespace = "echo-server-cilium"
      annotations = {
        "cert-manager.io/cluster-issuer"            = "letsencrypt"
        "acme.cert-manager.io/http01-edit-in-place" = "true"
      }
    }
    spec = {
      ingressClassName = "cilium"
      rules = [
        {
          host = "echo-cilium.centralus.cloudapp.azure.com"
          http = {
            paths = [
              {
                path     = "/"
                pathType = "Prefix"
                backend = {
                  service = {
                    name = "echo-server-cilium"
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
          hosts      = ["echo-cilium.centralus.cloudapp.azure.com"]
          secretName = "echo-cilium-tls"
        }
      ]
    }
  }

  depends_on = [
    helm_release.ingress_nginx,
    kubernetes_manifest.letsencrypt
  ]
}
