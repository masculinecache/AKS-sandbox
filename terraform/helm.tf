locals {
  cilium_values = {
    kubeProxyReplacement = true
    routingMode          = "native"
    autoDirectNodeRoutes = true
    endpointRoutes = {
      enabled = true
    }
    enableIPv4Masquerade = false
    bpf = {
      masquerade = false
    }
    forceDeviceDetection = true
    cni = {
      chainingMode  = "generic-veth"
      chainingTarget = "azure-vnet"
      configMap     = "cni-configuration"
      customConf    = true
      exclusive     = false
      install       = false
    }
    nodeinit = {
      enabled = true
    }
    ingressController = {
      enabled          = true
      default          = false
      loadbalancerMode = "shared"
      hostNetwork = {
        enabled            = true
        sharedListenerPort = 80
      }
    }
    gatewayAPI = {
      enabled = false
    }
    hubble = {
      enabled = false
    }
    operator = {
      tolerations = [
        {
          effect  = "NoSchedule"
          key     = "kubernetes.azure.com/scalesetpriority"
          operator = "Equal"
          value   = "spot"
        }
      ]
    }
    tolerations = [
      {
        effect   = "NoSchedule"
        key      = "kubernetes.azure.com/scalesetpriority"
        operator = "Equal"
        value    = "spot"
      },
      {
        effect   = "NoSchedule"
        key      = "node.cilium.io/agent-not-ready"
        operator = "Exists"
      }
    ]
  }
}

# ── cert-manager ──────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "~> 1.16"

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# ── ingress-nginx (default) ───────────────────────────────────────────────────
resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "~> 4.15"

  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
    value = "/healthz"
  }

  depends_on = [
    helm_release.cert_manager
  ]
}

# ── Cilium ────────────────────────────────────────────────────────────────────
resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  namespace        = "cilium"
  create_namespace = true
  version          = "~> 1.19"

  values = [
    yamlencode(local.cilium_values)
  ]

  depends_on = [
    helm_release.cert_manager
  ]
}

# ── cilium-ingress-nginx (separate controller for Cilium domain) ──────────────
resource "helm_release" "cilium_ingress_nginx" {
  name             = "cilium-ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "cilium-ingress-nginx"
  create_namespace = true
  version          = "~> 4.15"

  set {
    name  = "controller.ingressClassResource.name"
    value = "cilium-nginx"
  }
  set {
    name  = "controller.ingressClassResource.controllerValue"
    value = "k8s.io/cilium-ingress-nginx"
  }
  set {
    name  = "controller.ingressClass"
    value = "cilium-nginx"
  }
  set {
    name  = "controller.ingressClassByName"
    value = "true"
  }
  set {
    name  = "controller.watchIngressWithoutClass"
    value = "false"
  }
  set {
    name  = "controller.service.externalTrafficPolicy"
    value = "Local"
  }
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/azure-load-balancer-health-probe-request-path"
    value = "/healthz"
  }

  depends_on = [
    helm_release.cilium,
    helm_release.ingress_nginx
  ]
}

# ── echo-server-nginx ─────────────────────────────────────────────────────────
resource "helm_release" "echo_server_nginx" {
  name             = "echo-server-nginx"
  repository       = "https://ealenn.github.io/charts"
  chart            = "echo-server"
  namespace        = "echo-server-nginx"
  create_namespace = true
  version          = "~> 0.5"

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "tolerations[0].key"
    value = "kubernetes.azure.com/scalesetpriority"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "spot"
  }

  depends_on = [
    helm_release.ingress_nginx
  ]
}

# ── echo-server-cilium ────────────────────────────────────────────────────────
resource "helm_release" "echo_server_cilium" {
  name             = "echo-server-cilium"
  repository       = "https://ealenn.github.io/charts"
  chart            = "echo-server"
  namespace        = "echo-server-cilium"
  create_namespace = true
  version          = "~> 0.5"

  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "tolerations[0].key"
    value = "kubernetes.azure.com/scalesetpriority"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "spot"
  }

  depends_on = [
    helm_release.cilium_ingress_nginx
  ]
}

# ── kubeview ──────────────────────────────────────────────────────────────────
resource "helm_release" "kubeview" {
  name             = "kubeview"
  chart            = "${path.module}/../charts/kubeview"
  namespace        = "kubeview"
  create_namespace = true

  set {
    name  = "loadBalancer.enabled"
    value = "true"
  }

  depends_on = [
    helm_release.cert_manager
  ]
}
