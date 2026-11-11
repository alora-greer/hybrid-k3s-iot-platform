# Security Model

## Principles

1. **Zero inbound ports on the router.** The router forwards nothing. Public
   access is via an outbound-only Cloudflare Tunnel from inside K3s. Services
   on the lab LAN (K3s API, Ollama, the HA scrape) are not individually
   authenticated or segmented; see [Known gaps](#known-gaps).
2. **No secrets in git — enforced mechanically.**
   - Strict [`.gitignore`](../.gitignore): `.env`, `*.tfvars`, `*.tfstate*`,
     kubeconfigs, keys, certs, backups.
   - Environment-specific values (hostnames, addresses) live in `.env` and are
     substituted at render time (`make render`) — the rendered output in
     `.rendered/` is gitignored.
   - Kubernetes secrets are committed **only** as SealedSecrets (encrypted to
     the in-cluster controller's public key).
   - gitleaks runs on every push/PR in CI and locally via `make scan`.
3. **Least privilege for backups.** Per-source IAM users scoped to an S3
   prefix, with no `s3:DeleteObjectVersion`; no IAM keys in Terraform state.
   A leaked writer key can still read its own prefix's backups, and keys are
   long-lived (see [Known gaps](#known-gaps)).
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
| Grafana admin password | `terraform/k8s-addons/terraform.tfvars` (gitignored). **Also** in plaintext in local Terraform state, in the Helm release Secret (`sh.helm.release.v1.*`) and the chart-created Grafana Secret in `monitoring`, and therefore in etcd snapshots (SSE-KMS encrypted in S3) | kube-prometheus-stack |
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

## Known gaps

Stated plainly so they are not mistaken for working controls:

- **No Cloudflare Access in front of Grafana.** The public hostname is
  protected only by the Grafana login (admin password from tfvars).
- **HA scrape is plain HTTP.** The Bearer token crosses the LAN in cleartext.
- **Ollama API is unauthenticated, cleartext HTTP on the LAN.** Restrict
  `:11434` to the K3s node.
- **In-cluster hops are plain HTTP.** TLS ends at the Cloudflare edge; the
  tunnel → Traefik → Grafana path uses Traefik's `web` entrypoint. cloudflared
  metrics listen unauthenticated on `:2000`.
- **Public Grafana login** uses the chart's default `admin` user, with no MFA
  or rate limiting.
- **Secrets at rest on the node.** K3s `secrets-encryption` is not enabled,
  and the etcd-s3 writer keys sit in plaintext in
  `/etc/rancher/k3s/config.yaml` (keep it `0600`).
- **SealedSecrets key is inside the etcd snapshots.** Anyone who can read and
  decrypt the `k3s/` snapshots can decrypt every SealedSecret in git.
- **No S3 Object Lock / MFA delete.** Writers can't remove versions, but
  history protection relies on the 90-day noncurrent retention only.
- **Long-lived IAM user access keys** for the S3 writers. Rotate them; consider
  IAM Roles Anywhere later.
- **Local Terraform state.** No remote backend is configured (the `aws-backup`
  and `gcp-dns` backends are commented out in `versions.tf`; `k8s-addons` has
  none), so state is local, unencrypted (gitignored) and contains the Grafana
  admin password. `backend.hcl` is not yet in `.gitignore`.
- **No NetworkPolicies** in the cluster.
- **Unpinned versions.** Helm charts install the latest when `chart_versions`
  is unset; the K3s install script is unpinned (set `INSTALL_K3S_VERSION`); CI
  downloads kubeconform `latest`; GitHub Actions are pinned by tag, not SHA.
- **Alertmanager has no receivers**, so alerts notify no one.
- **DNS split:** Cloud DNS tunnel CNAMEs do not route without a
  Cloudflare-hosted zone (see the README's Known limitation).
