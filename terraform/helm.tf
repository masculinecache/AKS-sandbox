# ── cert-manager ──────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "1.9.1"

  set = [
    {
      name  = "installCRDs"
      value = "true"
    }
  ]
}

# Give cert-manager's CRDs time to register before creating ClusterIssuer.
resource "time_sleep" "wait_for_crds" {
  create_duration = "30s"

  depends_on = [helm_release.cert_manager]
}

# ── ingress-nginx (default) ───────────────────────────────────────────────────
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.15.1"
  timeout          = 600

  set = [
    {
      name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
      value = "/healthz"
    },
    {
      name  = "controller.admissionWebhooks.enabled"
      value = "false"
    }
  ]

  depends_on = [
    helm_release.cert_manager
  ]
}

# ── echo-server-nginx ─────────────────────────────────────────────────────────
resource "helm_release" "echo_nginx" {
  name             = "echo-server-nginx"
  repository       = "https://ealenn.github.io/charts"
  chart            = "echo-server"
  namespace        = "echo-server-nginx"
  create_namespace = true
  version          = "0.5.0"

  set = [
    {
      name  = "tolerations[0].effect"
      value = "NoSchedule"
    },
    {
      name  = "tolerations[0].key"
      value = "kubernetes.azure.com/scalesetpriority"
    },
    {
      name  = "tolerations[0].operator"
      value = "Equal"
    },
    {
      name  = "tolerations[0].value"
      value = "spot"
    }
  ]

  depends_on = [
    helm_release.ingress_nginx
  ]
}

# ── echo-server-cilium ────────────────────────────────────────────────────────
resource "helm_release" "echo_cilium" {
  name             = "echo-server-cilium"
  repository       = "https://ealenn.github.io/charts"
  chart            = "echo-server"
  namespace        = "echo-server-cilium"
  create_namespace = true
  version          = "0.5.0"

  set = [
    {
      name  = "tolerations[0].effect"
      value = "NoSchedule"
    },
    {
      name  = "tolerations[0].key"
      value = "kubernetes.azure.com/scalesetpriority"
    },
    {
      name  = "tolerations[0].operator"
      value = "Equal"
    },
    {
      name  = "tolerations[0].value"
      value = "spot"
    }
  ]

  depends_on = [
    helm_release.ingress_nginx
  ]
}
