locals {
  namespaces = ["monitoring", "cloudflared", "k8sgpt-operator-system"]
}

resource "kubernetes_namespace_v1" "this" {
  for_each = toset(local.namespaces)

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Sealed Secrets — lets encrypted secrets live safely in git.
# fullnameOverride matches kubeseal's default controller name.
# -----------------------------------------------------------------------------
resource "helm_release" "sealed_secrets" {
  name       = "sealed-secrets"
  repository = "https://bitnami-labs.github.io/sealed-secrets"
  chart      = "sealed-secrets"
  version    = var.chart_versions.sealed_secrets
  namespace  = "kube-system"

  values = [yamlencode({
    fullnameOverride = "sealed-secrets-controller"
  })]
}

# -----------------------------------------------------------------------------
# kube-prometheus-stack — Prometheus, Alertmanager, Grafana, node-exporter.
# Selectors are opened up so ServiceMonitors/ScrapeConfigs in any namespace
# (e.g. the Home Assistant ScrapeConfig in k8s-manifests/) are discovered.
# -----------------------------------------------------------------------------
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions.kube_prometheus_stack
  namespace  = kubernetes_namespace_v1.this["monitoring"].metadata[0].name
  timeout    = 600

  values = [yamlencode({
    prometheus = {
      prometheusSpec = {
        retention                               = var.prometheus_retention
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
        ruleSelectorNilUsesHelmValues           = false
        scrapeConfigSelectorNilUsesHelmValues   = false
        resources = {
          requests = { cpu = "200m", memory = "512Mi" }
          limits   = { memory = "1536Mi" }
        }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = "local-path"
              accessModes      = ["ReadWriteOnce"]
              resources        = { requests = { storage = var.prometheus_storage_size } }
            }
          }
        }
      }
    }

    grafana = {
      adminPassword = var.grafana_admin_password
      persistence   = { enabled = true, storageClassName = "local-path", size = "2Gi" }
    }

    # K3s bundles these into the k3s binary; their endpoints aren't scrapeable
    # the way the chart expects, so disable to avoid permanently-firing alerts.
    kubeControllerManager = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    kubeEtcd              = { enabled = false }
  })]
}

# -----------------------------------------------------------------------------
# K8sGPT operator — AI-assisted cluster diagnostics. The K8sGPT custom
# resource (k8s-manifests/k8sgpt/) points it at Ollama on the workstation.
# -----------------------------------------------------------------------------
resource "helm_release" "k8sgpt_operator" {
  name       = "k8sgpt-operator"
  repository = "https://charts.k8sgpt.ai/"
  chart      = "k8sgpt-operator"
  version    = var.chart_versions.k8sgpt_operator
  namespace  = kubernetes_namespace_v1.this["k8sgpt-operator-system"].metadata[0].name

  values = [yamlencode({
    serviceMonitor = { enabled = true }
  })]

  depends_on = [helm_release.kube_prometheus_stack] # needs ServiceMonitor CRD
}
