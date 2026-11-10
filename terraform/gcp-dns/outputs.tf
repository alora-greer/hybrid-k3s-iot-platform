output "name_servers" {
  description = "Set these as the domain's name servers at your registrar."
  value       = google_dns_managed_zone.public.name_servers
}

output "zone_name" {
  description = "Cloud DNS managed zone resource name."
  value       = google_dns_managed_zone.public.name
}

output "tunnel_fqdns" {
  description = "Hostnames routed via the Cloudflare Tunnel."
  value       = [for r in google_dns_record_set.tunnel : r.name]
}
