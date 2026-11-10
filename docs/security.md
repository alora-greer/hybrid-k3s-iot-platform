# Security Model

## Principles

1. **Zero inbound ports.** The router forwards nothing. Public access is via
   an outbound-only Cloudflare Tunnel from inside K3s.
2. **No secrets in git — enforced mechanically.**
   - Strict [`.gitignore`](../.gitignore): `.env`, `*.tfvars`, `*.tfstate*`,
     kubeconfigs, keys, certs, backups.
   - Environment-specific values (hostnames, addresses) live in `.env` and are
     substituted at render time (`make render`) — the rendered output in
     `.rendered/` is gitignored.
   - Kubernetes secrets are committed **only** as SealedSecrets (encrypted to
     the in-cluster controller's public key).
   - gitleaks runs on every push/PR in CI and locally via `make scan`.
3. **Least privilege everywhere.** Per-source IAM users scoped to an S3
   prefix; no IAM keys in Terraform state.
4. **Network segmentation.** Lab devices live on an isolated router subnet;
   static DHCP reservations keep addressing predictable without hardcoding
   addresses in the repo.
5. **Local AI for live data.** Cluster diagnostics use a local Ollama model;
   see [ai-dev-environment.md](ai-dev-environment.md).

## Secret inventory

| Secret | Stored as | Where it's used |
|---|---|---|
| Home Assistant Long-Lived Access Token | SealedSecret `monitoring/home-assistant-token` | Prometheus ScrapeConfig |
| Cloudflare Tunnel token | SealedSecret `cloudflared/cloudflared-token` | cloudflared Deployment |
| Keycloak admin / client credentials | SealedSecret (planned) | Keycloak, Grafana OIDC |
| Grafana admin password | `terraform/k8s-addons/terraform.tfvars` (gitignored) | kube-prometheus-stack |
| AWS backup writer keys | Server-local `/etc/rancher/k3s/config.yaml` (0600), HA UI | K3s etcd-s3, HA backups |
| SealedSecrets controller key | In-cluster + offline password manager | Decrypting SealedSecrets |

## Sealing a secret

```bash
cp .env.example .env     # fill in HA_TOKEN etc.
make seal-ha-token       # plaintext only exists inside a pipe
git add k8s-manifests/monitoring/home-assistant-token.sealedsecret.yaml
```

## Rotation

- **HA token:** revoke in HA → new token in `.env` → `make seal-ha-token apply`.
- **Tunnel token:** rotate in Cloudflare → `make seal-cloudflared-token apply`.
- **AWS keys:** `aws iam create-access-key` → update consumer → delete old key.
