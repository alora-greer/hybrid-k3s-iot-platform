# Bootstrap Order

From bare metal to a running platform. Each step is idempotent.

## Workstation prerequisites

```bash
brew install kubectl helm terraform kubeseal gettext gitleaks kubeconform \
             k8sgpt ollama gh awscli
brew install --cask google-cloud-sdk
```

## Steps

| # | Step | Command / location |
|---|---|---|
| 1 | Router: isolated subnet + DHCP reservations for K3s node, Pi, workstation | GL.iNet admin UI |
| 2 | Install Home Assistant OS on the Pi, pair Zigbee/HomeKit devices | [k3s-iot-stack.md](k3s-iot-stack.md) |
| 3 | AWS backup bucket + IAM writers | `cd terraform/aws-backup && terraform init && terraform apply` |
| 4 | Create writer access keys out-of-band | `aws iam create-access-key --user-name <user>` |
| 5 | Install K3s with etcd-s3 snapshots | [k3s-iot-stack.md](k3s-iot-stack.md#k3s-install) |
| 6 | Copy kubeconfig to workstation | [k3s-iot-stack.md](k3s-iot-stack.md#workstation-kubeconfig) |
| 7 | Cluster add-ons (SealedSecrets, Prometheus/Grafana, K8sGPT operator) | `cd terraform/k8s-addons && terraform apply` |
| 8 | Fill in `.env`, seal secrets | `cp .env.example .env && make seal-ha-token seal-cloudflared-token` |
| 9 | Apply manifests | `make diff && make apply` |
| 10 | DNS zone + tunnel CNAMEs | `cd terraform/gcp-dns && terraform apply`, set registrar NS + DS |
| 11 | Configure HA S3 backups with the `home-assistant` writer key | HA → Settings → System → Backups |
| 12 | Back up the SealedSecrets controller key offline | [backup-and-restore.md](backup-and-restore.md) |
