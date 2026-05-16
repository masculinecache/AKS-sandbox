variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "centralus"
}

variable "cluster_name" {
  description = "AKS cluster name"
  type        = string
  default     = "sandbox-aks"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "rg-sandbox-aks"
}

variable "dns_prefix" {
  description = "DNS prefix for AKS cluster"
  type        = string
  default     = "sandbox-aks"
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34.6"
}

variable "system_node_count" {
  description = "Number of system node pool nodes"
  type        = number
  default     = 1
}

variable "system_node_vm_size" {
  description = "VM size for system node pool"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "spot_node_vm_size" {
  description = "VM size for spot node pool"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "spot_node_max_count" {
  description = "Max count for spot node pool autoscaling"
  type        = number
  default     = 3
}

variable "spot_node_min_count" {
  description = "Min count for spot node pool autoscaling"
  type        = number
  default     = 0
}

variable "acme_email" {
  description = "Email for Let's Encrypt registration"
  type        = string
  default     = "darren.slocum@gmail.com"
}
