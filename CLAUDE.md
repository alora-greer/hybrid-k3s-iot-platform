# Project Context: Hybrid K3s IoT Platform & AI Dev Environment

## Who I Am & Goal
I am a DevOps/Platform Engineer (strong in GCP, Terraform, Chef, Docker, Prometheus, Grafana, Keycloak) building a production-grade home lab portfolio repo to land a remote Mid-level SaaS/FinTech SRE or Platform role.

## Hardware & Network Architecture
1. **DevOps Workstation (New Mac):** Runs Zed editor, Claude Code, `kubectl`, `helm`, `terraform`, and local Ollama.
2. **K3s Server (`lab-k3s-ctrl-01`):** Old HP Laptop running Ubuntu Server 24.04 LTS (`HandleLidSwitch=ignore`) and K3s (Control Plane + Worker + Traefik Ingress).
3. **IoT Edge Node (Raspberry Pi 4 8GB):** Runs Home Assistant OS natively with a Sonoff Zigbee 3.0 dongle, Aqara temp/contact sensors, Ring cameras, Smart Plugs, and an ecobee Essential thermostat (paired locally via HomeKit Device). Exposes `/api/prometheus`.
4. **Network Gateway:** GL.iNet GL-BE3600 Slate 7 router providing an isolated subnet and static DHCP reservations.
5. **Hybrid Cloud:** AWS S3 (encrypted off-site K3s/Home Assistant backups + IAM least-privilege policy) and GCP Cloud DNS (custom domain routing via Cloudflare Tunnel so zero home router ports are opened).

## Security & Git Rules (STRICT)
- NEVER hardcode IP addresses, tokens, passwords, or domain names in tracked files.
- Always use `.gitignore` to block `.env`, `*.tfvars`, `*.tfstate*`, and `kubeconfig.yaml`.
- Use Kubernetes Secrets or SealedSecrets for the Home Assistant Long-Lived Access Token and Keycloak credentials.
