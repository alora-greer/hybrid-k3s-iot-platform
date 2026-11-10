output "releases" {
  description = "Installed Helm releases and their chart versions."
  value = {
    for r in [
      helm_release.sealed_secrets,
      helm_release.kube_prometheus_stack,
      helm_release.k8sgpt_operator,
    ] : r.name => r.metadata.version
  }
}
