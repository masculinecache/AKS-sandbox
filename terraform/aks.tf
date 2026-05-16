resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version

  default_node_pool {
    name                = "nodepool1"
    vm_size             = var.system_node_vm_size
    node_count          = var.system_node_count
    os_disk_size_gb     = 128
    type                = "VirtualMachineScaleSets"
    orchestrator_version = var.kubernetes_version
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "none"
    load_balancer_sku = "standard"
    service_cidr      = "10.0.0.0/16"
    dns_service_ip    = "10.0.0.10"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = false

  tags = {
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }

  lifecycle {
    ignore_changes = [
      kubernetes_version,
      default_node_pool[0].orchestrator_version,
    ]
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "spot" {
  name                  = "spotpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.spot_node_vm_size
  node_count            = 1
  min_count             = var.spot_node_min_count
  max_count             = var.spot_node_max_count
  enable_auto_scaling   = true
  os_disk_size_gb       = 128
  priority              = "Spot"
  eviction_policy       = "Delete"
  spot_max_price        = -1 # <= hourly price of standard
  node_labels = {
    "kubernetes.azure.com/scalesetpriority" = "spot"
  }
  node_taints = [
    "kubernetes.azure.com/scalesetpriority=spot:NoSchedule"
  ]
  orchestrator_version = var.kubernetes_version

  tags = {
    Environment = "sandbox"
    ManagedBy   = "terraform"
  }
}
