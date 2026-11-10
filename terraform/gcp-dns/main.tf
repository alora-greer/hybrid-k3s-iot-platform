resource "google_project_service" "dns" {
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_dns_managed_zone" "public" {
  name        = var.zone_name
  dns_name    = var.domain
  description = "Public zone for the hybrid K3s IoT platform (managed by Terraform)"
  visibility  = "public"

  dynamic "dnssec_config" {
    for_each = var.enable_dnssec ? [1] : []
    content {
      state = "on"
    }
  }

  depends_on = [google_project_service.dns]
}

# Service hostnames -> Cloudflare Tunnel. No inbound ports are opened on the
# home router; cloudflared inside K3s dials out to Cloudflare's edge.
resource "google_dns_record_set" "tunnel" {
  for_each = toset(var.tunnel_hostnames)

  managed_zone = google_dns_managed_zone.public.name
  name         = "${each.value}.${var.domain}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["${var.cloudflare_tunnel_id}.cfargotunnel.com."]
}

# Restrict which CAs may issue certificates for the domain.
resource "google_dns_record_set" "caa" {
  managed_zone = google_dns_managed_zone.public.name
  name         = var.domain
  type         = "CAA"
  ttl          = 3600
  rrdatas = [
    "0 issue \"letsencrypt.org\"",
    "0 issue \"pki.goog\"",
    "0 issue \"digicert.com\"",
  ]
}

resource "google_dns_record_set" "extra" {
  for_each = var.extra_records

  managed_zone = google_dns_managed_zone.public.name
  name         = each.value.name == "" ? var.domain : "${each.value.name}.${var.domain}"
  type         = each.value.type
  ttl          = each.value.ttl
  rrdatas      = each.value.rrdatas
}
