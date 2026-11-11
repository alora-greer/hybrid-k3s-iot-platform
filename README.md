# Hybrid K3s IoT Platform

[![ci](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml)

A production-style home lab that runs a **single-node K3s cluster** observing a
**Home Assistant IoT edge**, with **hybrid-cloud** off-site backups (AWS S3) and
DNS (GCP Cloud DNS), public access via **Cloudflare Tunnel with zero open router
ports**, and an **AI-assisted operator workflow** (Zed + Claude Code + local
Ollama/K8sGPT).

Everything is Infrastructure-as-Code, secrets are encrypted or kept out of git
by construction, and CI enforces it.

---

## Architecture

```
                                            Internet users
                                                   │
┌─ PUBLIC CLOUD ───────────────────────────────────┼───────────────────────────────────────────────┐
│  ┌─ GCP ─────────────────────┐   ┌─ Cloudflare ──▼─────────┐   ┌─ AWS ─────────────────────────┐ │
│  │ Cloud DNS · DNSSEC · CAA  │   │ Edge TLS · Access       │   │ S3 backups · SSE-KMS          │ │
│  │ grafana.<domain>  CNAME   ├───▶ Tunnel ingress          │   │ versioned · Glacier IR        │ │
│  │   → <tunnel>.cfargotunnel │   │                         │   │ per-prefix IAM writers        │ │
│  └───────────────────────────┘   └────────────┬────────────┘   └──────▲─────────────────▲──────┘ │
│                                               │                       │                 │        │
└───────────────────────────────────────────────┼───────────────────────┼─────────────────┼────────┘
                                                │ outbound-only tunnel  │ etcd snaps      │ HA
                                                │ (0 open ports)        │                 │ backups
                                                │                       │                 │
┌─ HOME LAB · GL.iNet Slate 7 subnet ───────────┼───────────────────────┼─────────────────┼────────┐
│                                               │                       │                 │        │
│  ┌─ lab-k3s-ctrl-01 · K3s · host A or B ¹ ────▼───────────────────────┴─────────┐       │        │
│  │ Grafana ◀── Traefik ◀─────────────── cloudflared ×2        etcd snapshot 6h  │       │        │
│  │    ▲                                                                         │       │        │
│  │    └───────────────────────────────────────────── Prometheus ─▶ Alertmanager │       │        │
│  │ SealedSecrets     K8sGPT operator                      ▲                     │       │        │
│  │                          │                             │                     │       │        │
│  └──────────────────────────┼─────────────────────────────┼─────────────────────┘       │        │
│                             │ LLM API (LAN)               │ scrape + Bearer token       │        │
│  ┌─ Mac workstation ────────▼─────────────┐   ┌───────────┴─────────────────────────────┴──────┐ │
│  │ Zed · Claude Code                      │   │ Raspberry Pi 4 · Home Assistant OS             │ │
│  │ kubectl · helm · terraform · kubeseal  │   │ /api/prometheus · native backups → S3          │ │
│  │ Ollama :11434 ◀── k8sgpt CLI           │   │ Sonoff Zigbee 3.0 ─▶ Aqara temp/contact        │ │
│  │   llama3.1 · qwen2.5-coder             │   │ HomeKit ─▶ ecobee Essential                    │ │
│  │                                        │   │ Ring cameras · smart plugs                     │ │
│  └────────────────────────────────────────┘   └────────────────────────────────────────────────┘ │
│                                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
```

¹ `lab-k3s-ctrl-01` runs on one of two interchangeable hosts. Everything above
the K3s API (add-ons, manifests, backups, tunnel) is identical either way:

```
 Option A · native bare metal                 Option B · Windows 11 + WSL2 (NAT) + portproxy
 ┌─ HP laptop ──────────────────────────┐     ┌─ HP laptop · Windows 11 ─────────────────────────────┐
 │ Ubuntu Server 24.04 LTS              │     │ LAN ─▶ <HP_HOST_IP>:6443 / 80 / 443                  │
 │ HandleLidSwitch=ignore               │     │ Windows Firewall: allow TCP 6443,80,443 (Private)    │
 │                                      │     │ netsh portproxy  0.0.0.0:<port> ─┐                   │
 │ K3s · <K3S_NODE_IP>:6443 / 80 / 443  │     │                                  ▼                   │
 │   (stable DHCP reservation)          │     │  ┌─ WSL2 VM · Ubuntu 24.04 · systemd=true ────────┐  │
 └──────────────────────────────────────┘     │  │ K3s · <WSL_INTERNAL_IP>:6443 / 80 / 443        │  │
                                              │  │   (NAT address may change on restart)          │  │
                                              │  └────────────────────────────────────────────────┘  │
                                              └──────────────────────────────────────────────────────┘
```

| Layer | Technology | Managed by |
|---|---|---|
| Network | GL.iNet GL-BE3600 Slate 7 — isolated subnet, DHCP reservations, no port forwards | Router UI (documented) |
| Compute | K3s on Ubuntu 24.04 — **A:** native Ubuntu Server (`HandleLidSwitch=ignore`) or **B:** Windows 11 + WSL2 + `netsh` portproxy | [`docs/bootstrap.md`](docs/bootstrap.md#k3s-host-preparation) · [`docs/hp-wsl-k3s-setup.md`](docs/hp-wsl-k3s-setup.md) |
| Cluster add-ons | SealedSecrets, kube-prometheus-stack, K8sGPT operator | [`terraform/k8s-addons`](terraform/k8s-addons) |
| Workloads | HA ScrapeConfig + alerts, Grafana ingress, cloudflared, K8sGPT CR | [`k8s-manifests`](k8s-manifests) |
| IoT edge | Home Assistant OS, Zigbee, HomeKit, Ring | [`docs/k3s-iot-stack.md`](docs/k3s-iot-stack.md) |
| Backups | AWS S3 + KMS + IAM least privilege | [`terraform/aws-backup`](terraform/aws-backup) |
| DNS | GCP Cloud DNS (DNSSEC, CAA) → Cloudflare Tunnel | [`terraform/gcp-dns`](terraform/gcp-dns) |
| AI tooling | Zed, Claude Code, Ollama, K8sGPT | [`docs/ai-dev-environment.md`](docs/ai-dev-environment.md) |

### K3s host options (`lab-k3s-ctrl-01`)

The HP laptop can host the single-node K3s server in one of two ways. Pick one;
the cluster add-ons, manifests, backups, and tunnel don't change.

| | **Option A: native Ubuntu Server** | **Option B: Windows 11 + WSL2 + portproxy** |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS on bare metal | Windows 11 host, Ubuntu 24.04 WSL2 distro |
| K3s API / Traefik reachable at | `<K3S_NODE_IP>:6443` / `:80` / `:443`, bound directly on the LAN NIC | `<HP_HOST_IP>:6443` / `:80` / `:443` → `netsh interface portproxy` → `<WSL_INTERNAL_IP>` |
| Networking | Plain LAN host with a DHCP reservation on the Slate 7 | WSL2 **NAT** (default) needs portproxy + Windows Firewall rules. **Mirrored** mode (`networkingMode=mirrored`) shares the host's address and can skip portproxy, but it's newer and has more edge cases |
| Address stability | Stable (DHCP reservation) | Windows host IP is stable (reservation). The **WSL2 NAT IP can change** on reboot or `wsl --shutdown`, so the portproxy needs refreshing |
| Reboot persistence | `systemd` starts `k3s.service`; lid close ignored via `HandleLidSwitch=ignore` | Requires `systemd=true` in `/etc/wsl.conf`, a startup task that boots the distro and re-applies portproxy, and Windows power settings (lid: *Do nothing*, sleep: *Never*) |
| TLS SAN | `lab-k3s-ctrl-01` (+ `<K3S_NODE_IP>`) | Must include `<HP_HOST_IP>`, because clients reach the API through the Windows host |
| Tradeoffs | Simplest and lowest overhead. Laptop is dedicated to Linux | Keeps Windows usable on the laptop. Extra NAT hop, TCP-only portproxy, and Windows Update reboots to plan around |

Step-by-step host prep for both options is in
[`docs/bootstrap.md`](docs/bootstrap.md#k3s-host-preparation). The full WSL2 walkthrough
(power, Wi-Fi profile, mirrored networking, kubeconfig) is in
[`docs/hp-wsl-k3s-setup.md`](docs/hp-wsl-k3s-setup.md).

---

## AI Dev Environment

The workstation layers AI assistance with a strict data boundary:
**anything that touches live cluster state runs on a local model.**

| Tool | Purpose | Model |
|---|---|---|
| **Zed** | Editor; inline assist + agent panel for Terraform/YAML | Ollama (local) or Claude |
| **Claude Code** | Agentic repo work: scaffolding modules, reviews, refactors. Guided by [`CLAUDE.md`](CLAUDE.md), which encodes the topology and hard security rules | Claude |
| **Ollama** | Local LLM runtime (OpenAI-compatible API on `:11434`) | `llama3.1:8b`, `qwen2.5-coder:7b` |
| **K8sGPT** | Cluster diagnostics — CLI for ad-hoc `analyze --explain`, operator for continuous `Result` CRs | Ollama (local) |

```bash
# Ad-hoc triage from the workstation, fully local
k8sgpt analyze --explain --backend localai --namespace monitoring

# Continuous findings from the in-cluster operator
kubectl get results -n k8sgpt-operator-system
```

Full setup: [`docs/ai-dev-environment.md`](docs/ai-dev-environment.md).

---

## K3s IoT Stack

1. **Sensors → Home Assistant.** Aqara Zigbee sensors (via the Sonoff dongle),
   the ecobee (paired locally over HomeKit — no cloud dependency), Ring cameras
   and smart plugs all land in Home Assistant OS on the Pi.
2. **Home Assistant → Prometheus.** HA exposes `/api/prometheus`; a
   Prometheus Operator `ScrapeConfig` scrapes it using a Long-Lived Access Token
   stored as a **SealedSecret**.
3. **Alerting.** `PrometheusRule`s fire on HA being unreachable, rooms out of
   temperature range, and stale Zigbee sensors (dead batteries / mesh drops).
4. **Dashboards.** Grafana is published at `grafana.<domain>` through
   **Cloudflare Tunnel → Traefik**; nothing is port-forwarded on the router.
5. **Resilience.** K3s etcd snapshots every 6 h and daily HA backups go to an
   encrypted, versioned S3 bucket with per-source, prefix-scoped IAM users.

Details: [`docs/k3s-iot-stack.md`](docs/k3s-iot-stack.md) ·
[`docs/backup-and-restore.md`](docs/backup-and-restore.md)

---

## Repository layout

```
.
├── CLAUDE.md                     # Project memory/rules for Claude Code
├── Makefile                      # render / diff / apply / seal-* / lint / scan
├── .env.example                  # Template for gitignored .env
├── .github/workflows/ci.yml      # gitleaks · terraform fmt/validate · kubeconform
├── terraform/
│   ├── aws-backup/               # S3 + KMS + least-privilege IAM writers
│   ├── gcp-dns/                  # Cloud DNS zone, DNSSEC, CAA, tunnel CNAMEs
│   └── k8s-addons/               # Helm: SealedSecrets, kube-prometheus-stack, K8sGPT
├── k8s-manifests/
│   ├── monitoring/               # HA ScrapeConfig, PrometheusRules, Grafana Ingress
│   ├── cloudflared/              # Tunnel Deployment + ServiceMonitor
│   └── k8sgpt/                   # K8sGPT CR → local Ollama
└── docs/
    ├── bootstrap.md              # Bare metal or WSL2 → running platform, in order
    ├── hp-wsl-k3s-setup.md       # K3s host on Windows 11 + WSL2 (Option B)
    ├── k3s-iot-stack.md
    ├── ai-dev-environment.md
    ├── backup-and-restore.md     # Restore drills, RPO/RTO
    └── security.md               # Secret inventory, rotation
```

---

## Quick start

```bash
cp .env.example .env                     # environment-specific values (gitignored)
for m in aws-backup gcp-dns k8s-addons; do
  cp terraform/$m/terraform.tfvars.example terraform/$m/terraform.tfvars
done

make help
make lint                                # terraform validate + kubeconform
make seal-ha-token seal-cloudflared-token
make diff && make apply
```

See [`docs/bootstrap.md`](docs/bootstrap.md) for the full ordered runbook.

---

## Security

- **Zero inbound ports** — Cloudflare Tunnel is outbound-only.
- **No secrets, IPs, or domains in git** — strict [`.gitignore`](.gitignore),
  `.env`-based rendering, SealedSecrets, gitleaks in CI.
- **Least privilege** — per-source IAM users scoped to one S3 prefix; no IAM
  keys in Terraform state; writers can't delete object versions.
- **Local AI for live data** — cluster telemetry never leaves the LAN.

See [`docs/security.md`](docs/security.md).

---

## Roadmap

- [ ] Keycloak (SealedSecret creds) as OIDC provider for Grafana
- [ ] Grafana dashboards-as-code for HA sensors and ecobee runtime
- [ ] Argo CD / Flux GitOps for `k8s-manifests/`
- [ ] SLOs on Home Assistant availability with burn-rate alerts
- [ ] Remote Terraform state (S3/GCS backends with locking)
