variable "kubeconfig_path" {
  description = "Path to the kubeconfig for the K3s cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context to use (null = current context)."
  type        = string
  default     = null
}

# Chart versions: pin these in terraform.tfvars for reproducible installs.
# Find current versions with `helm search repo <repo>/<chart>`.
variable "chart_versions" {
  description = "Pinned Helm chart versions. null installs the latest available."
  type = object({
    sealed_secrets        = optional(string)
    kube_prometheus_stack = optional(string)
    k8sgpt_operator       = optional(string)
  })
  default = {}
}

variable "grafana_admin_password" {
  description = "Initial Grafana admin password (stored only in gitignored tfvars/state)."
  type        = string
  sensitive   = true
}

variable "prometheus_retention" {
  description = "Prometheus TSDB retention period."
  type        = string
  default     = "15d"
}

variable "prometheus_storage_size" {
  description = "PVC size for Prometheus (K3s local-path provisioner)."
  type        = string
  default     = "20Gi"
}
