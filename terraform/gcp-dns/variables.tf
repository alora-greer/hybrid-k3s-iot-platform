variable "project_id" {
  description = "GCP project that hosts the Cloud DNS zone."
  type        = string
}

variable "zone_name" {
  description = "Cloud DNS managed zone resource name (e.g. homelab-public)."
  type        = string
  default     = "homelab-public"
}

variable "domain" {
  description = "Apex domain, with trailing dot (e.g. example.com.)."
  type        = string

  validation {
    condition     = endswith(var.domain, ".")
    error_message = "domain must be fully qualified and end with a trailing dot."
  }
}

variable "enable_dnssec" {
  description = "Enable DNSSEC on the zone. Remember to publish the DS record at your registrar."
  type        = bool
  default     = true
}

variable "cloudflare_tunnel_id" {
  description = "Cloudflare Tunnel UUID. Service hostnames are CNAMEd to <id>.cfargotunnel.com."
  type        = string
  sensitive   = true
}

variable "tunnel_hostnames" {
  description = "Subdomain labels routed through the Cloudflare Tunnel (e.g. [\"grafana\", \"ha\"])."
  type        = list(string)
  default     = ["grafana"]
}

variable "extra_records" {
  description = "Additional records (TXT verification, MX, CAA...) keyed by a unique id."
  type = map(object({
    name    = string # relative label, or "" for the apex
    type    = string
    ttl     = optional(number, 300)
    rrdatas = list(string)
  }))
  default = {}
}
