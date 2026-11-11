# K3s IoT Stack

> **Which guide applies?** The K3s server setup below covers a native
> bare-metal **Ubuntu Server 24.04** install on `lab-k3s-ctrl-01`. If the HP
> laptop instead runs **Windows 11 with K3s inside WSL2**, follow
> [hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md) for the host setup; everything
> else in this document applies unchanged.

## Components

| Component | Where | Role |
|---|---|---|
| GL.iNet Slate 7 (GL-BE3600) | Network edge | Isolated lab subnet, static DHCP reservations, **no port forwards** |
| `lab-k3s-ctrl-01` | Old HP laptop, Ubuntu Server 24.04 | Single-node K3s: control plane + worker + Traefik |
| Raspberry Pi 4 (8 GB) | Home Assistant OS | IoT hub, exposes `/api/prometheus` |
| Sonoff Zigbee 3.0 dongle | Pi USB | Zigbee coordinator (ZHA / Zigbee2MQTT) |
| Aqara temp & contact sensors | Zigbee mesh | Environment + door/window state |
| ecobee Essential | Wi-Fi, paired via HomeKit Device | Local thermostat control (no cloud dependency) |
| Ring cameras | Wi-Fi | Home Assistant's Ring **cloud** integration (not local) |
| Smart plugs | Wi-Fi | Power metering |

## Data flow

```
 Aqara sensors ─┐
 (Zigbee)       ├─▶ Sonoff dongle ─▶ Home Assistant OS ──▶ /api/prometheus
 Smart plugs ───┤                     (Raspberry Pi)            │
 ecobee (HAP) ──┤                                               │ HTTP + Bearer token
 Ring cameras ──┘                                               │ (SealedSecret)
                                                                ▼
                         ┌──────────── K3s: lab-k3s-ctrl-01 ────────────┐
                         │ Prometheus (ScrapeConfig: home-assistant)    │
                         │   ├─ PrometheusRules → Alertmanager *        │
                         │   └─ Grafana dashboards                      │
                         │ Traefik ◀── cloudflared (outbound tunnel)    │
                         └──────────────────────────────────────────────┘
```

\* No Alertmanager receivers are configured yet; see below.

## Monitoring stack defaults

`terraform/k8s-addons` installs kube-prometheus-stack with Prometheus on a
20Gi `local-path` PVC and 15d retention (`prometheus_storage_size`,
`prometheus_retention`), and Grafana on a 2Gi `local-path` PVC. Both live on
the node's disk and are **not** covered by the S3 backups
([backup-and-restore.md](backup-and-restore.md)).

**Alertmanager has no receivers configured.** `PrometheusRule`s fire and show
up in the Prometheus and Alertmanager UIs, but nothing notifies anyone. Adding
receivers (email/Slack/ntfy) is on the roadmap.

## K3s server setup (`lab-k3s-ctrl-01`)

### Laptop-as-server hardening

```bash
# Keep running with the lid closed
sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
sudo sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
sudo systemctl restart systemd-logind

# Unattended security updates
sudo apt install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
```

The laptop battery acts as a built-in UPS for short power blips.

### K3s install

`/etc/rancher/k3s/config.yaml` (on the server only, mode `0600` — **not** in git):

```yaml
cluster-init: true                 # embedded etcd (required for etcd snapshots)
write-kubeconfig-mode: "0600"
tls-san:
  - lab-k3s-ctrl-01
etcd-snapshot-schedule-cron: "0 */6 * * *"
etcd-snapshot-retention: 20
etcd-s3: true
etcd-s3-bucket: <from terraform/aws-backup output>
etcd-s3-region: <region>
etcd-s3-folder: k3s
etcd-s3-access-key: <k3s writer access key>
etcd-s3-secret-key: <k3s writer secret key>
```

```bash
curl -sfL https://get.k3s.io | sh -
```

### Workstation kubeconfig

```bash
scp lab-k3s-ctrl-01:/etc/rancher/k3s/k3s.yaml ~/.kube/lab-k3s.yaml   # needs sudo on server
sed -i '' 's/127.0.0.1/lab-k3s-ctrl-01/' ~/.kube/lab-k3s.yaml
chmod 600 ~/.kube/lab-k3s.yaml
export KUBECONFIG=~/.kube/lab-k3s.yaml
```

Kubeconfig files are gitignored by pattern.

## Home Assistant → Prometheus

1. Enable the integration in `configuration.yaml` on the Pi:

   ```yaml
   prometheus:
     namespace: homeassistant
     filter:
       include_domains: [sensor, binary_sensor, climate, switch]
   ```

2. Create a **Long-Lived Access Token** (Profile → Security), put it in
   `.env` as `HA_TOKEN`, then:

   ```bash
   make seal-ha-token      # writes k8s-manifests/monitoring/home-assistant-token.sealedsecret.yaml
   ```

3. `make apply` deploys the `ScrapeConfig` and `PrometheusRule`s.

Rule notes:

- `ZigbeeSensorStale` matches **every** `sensor`-domain entity, not only
  Zigbee ones, using `homeassistant_last_updated_time_seconds`. That metric
  only changes when an entity's state or attributes change, so a sensor with a
  steady reading can trip the alert even though it is healthy.
- `RoomTemperatureOutOfRange` uses the `_celsius` metric
  (`homeassistant_sensor_temperature_celsius`); if HA is configured for
  Fahrenheit the rule will not match anything.

Useful queries:

```promql
homeassistant_sensor_temperature_celsius
homeassistant_binary_sensor_state{domain="binary_sensor"}   # Aqara contact sensors
homeassistant_climate_current_temperature_celsius            # ecobee
homeassistant_sensor_power_w                                 # smart plugs
```

## Public access via Cloudflare Tunnel

1. Create a remotely-managed tunnel in Cloudflare Zero Trust; copy its token
   into `.env` as `CLOUDFLARE_TUNNEL_TOKEN`.
2. `make seal-cloudflared-token && make apply`.
3. In the tunnel's public hostnames, route `grafana.<domain>` →
   `http://traefik.kube-system.svc.cluster.local:80`.
4. `terraform/gcp-dns` creates the matching CNAME → `<tunnel-id>.cfargotunnel.com`.
5. **Not deployed yet:** Cloudflare Access or Keycloak OIDC in front of
   Grafana. Today the public hostname is protected only by the Grafana login.

> **DNS caveat (known limitation):** the CNAMEs created by `terraform/gcp-dns`
> (`<tunnel-id>.cfargotunnel.com`) only route if the zone is hosted on
> Cloudflare. A tunnel hostname whose DNS is hosted elsewhere (such as Cloud
> DNS) requires a [partial (CNAME) zone setup](https://developers.cloudflare.com/dns/zone-setups/partial-setup/setup/),
> which is Business/Enterprise only, and records then point to
> `<hostname>.cdn.cloudflare.net`. On a free plan the CNAMEs as written will
> not route traffic. See also
> [Cloudflare's tunnel DNS docs](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/).
>
> **Suggested resolution:** move this domain's DNS to Cloudflare (free full
> setup) and use Cloud DNS for other records or domains.
