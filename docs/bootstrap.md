# Bootstrap Order

From bare metal (or a Windows 11 + WSL2 host) to a running platform. Each step is idempotent.

## Workstation prerequisites

```bash
brew install kubectl helm terraform kubeseal gettext gitleaks kubeconform \
             k8sgpt ollama gh awscli
brew install --cask google-cloud-sdk
```

## Placeholders

Look these up locally and never commit real values (see [security.md](security.md)):

| Placeholder | Meaning |
|---|---|
| `<K3S_NODE_IP>` | Option A: the Ubuntu laptop's LAN address (its DHCP reservation on the router) |
| `<HP_HOST_IP>` | Option B: the HP laptop's **Windows** LAN address (its DHCP reservation on the router) |
| `<WSL_INTERNAL_IP>` | Option B: the WSL2 NAT address of the Ubuntu distro (can change on restart) |
| `<API_ENDPOINT>` | Whatever clients use to reach the API: `<K3S_NODE_IP>`, `<HP_HOST_IP>`, or `lab-k3s-ctrl-01` if it resolves on the LAN |

## Steps

| # | Step | Command / location |
|---|---|---|
| 1 | Router: isolated subnet + DHCP reservations for K3s node, Pi, workstation | GL.iNet admin UI |
| 2 | Install Home Assistant OS on the Pi, pair Zigbee/HomeKit devices | [k3s-iot-stack.md](k3s-iot-stack.md) |
| 3 | AWS backup bucket + IAM writers | `cd terraform/aws-backup && terraform init && terraform apply` |
| 4 | Create writer access keys out-of-band | `aws iam create-access-key --user-name <user>` |
| 5 | Prepare the K3s host: **Option A** (native Ubuntu) **or** **Option B** (Windows 11 WSL2 + portproxy) | [K3s host preparation](#k3s-host-preparation) |
| 6 | Install K3s with etcd-s3 snapshots and the right TLS SANs | [Shared: K3s install](#shared-k3s-install) |
| 7 | Verify the node and copy kubeconfig to workstation | [Shared: verification](#shared-verification) |
| 8 | Cluster add-ons (SealedSecrets, Prometheus/Grafana, K8sGPT operator) | `cd terraform/k8s-addons && terraform apply` |
| 9 | Fill in `.env`, seal secrets | `cp .env.example .env && make seal-ha-token seal-cloudflared-token` |
| 10 | Apply manifests | `make diff && make apply` |
| 11 | DNS zone + tunnel CNAMEs | `cd terraform/gcp-dns && terraform apply`, set registrar NS + DS |
| 12 | Configure HA S3 backups with the `home-assistant` writer key | HA → Settings → System → Backups |
| 13 | Back up the SealedSecrets controller key offline | [backup-and-restore.md](backup-and-restore.md) |

---

## K3s host preparation

`lab-k3s-ctrl-01` runs on **one** of these. Steps 8 onward don't change based on
which you pick. See the [README comparison](../README.md#k3s-host-options-lab-k3s-ctrl-01)
for the tradeoffs.

### Option A: Native Ubuntu Server

Ubuntu Server 24.04 LTS installed directly on the HP laptop.

1. Install Ubuntu Server 24.04 LTS, set the hostname to `lab-k3s-ctrl-01`, and
   confirm it picks up its DHCP reservation (`<K3S_NODE_IP>`).
2. Harden it as a laptop-server (lid close ignored, unattended upgrades). Details are in
   [k3s-iot-stack.md](k3s-iot-stack.md#laptop-as-server-hardening):

   ```bash
   sudo sed -i 's/^#\?HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf
   sudo sed -i 's/^#\?HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=ignore/' /etc/systemd/logind.conf
   sudo systemctl restart systemd-logind
   sudo apt install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
   ```

K3s binds directly to the LAN NIC, so no port forwarding is needed. Continue to
[Shared: K3s install](#shared-k3s-install).

### Option B: Windows 11 WSL2 + portproxy

K3s runs in an Ubuntu 24.04 WSL2 distro on the Windows 11 laptop. With WSL2's
default **NAT** networking the distro sits behind a private address
(`<WSL_INTERNAL_IP>`), so Windows forwards TCP 6443 (K3s API) and 80/443
(Traefik) to it with `netsh interface portproxy`.

This section is the condensed runbook. For the full walkthrough (Wi-Fi profile,
mirrored networking, kubeconfig export), see [hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md).

> **NAT vs mirrored:** if `networkingMode=mirrored` works on your WSL build
> (Phase 2 of [hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md#phase-2-wsl2-engine-preparation)),
> the distro shares `<HP_HOST_IP>` and you can skip steps B3–B6. You still
> need the firewall rules (B5) unless you also set `firewall=false`. The steps
> below assume NAT, which is the default and works on more builds.

**B1. Windows host power and network.** Lid close: *Do nothing*. Sleep: *Never*.
Set the GL.iNet Wi-Fi profile to **Private**
([Phase 1](hp-wsl-k3s-setup.md#phase-1-windows-host-network--power-configuration)).
Plan Windows Update active hours, because those reboots take the cluster down.

**B2. Install the distro and enable systemd** (K3s ships as a systemd unit):

```powershell
# Admin PowerShell
wsl --install -d Ubuntu-24.04
wsl --update
```

Inside Ubuntu, create `/etc/wsl.conf`:

```ini
[boot]
systemd=true

[network]
hostname=lab-k3s-ctrl-01
```

To use NAT mode explicitly (the default), make sure `%USERPROFILE%\.wslconfig`
does **not** set `networkingMode=mirrored`, or set it to `nat` directly:

```ini
[wsl2]
networkingMode=nat
```

Then restart WSL from PowerShell and confirm systemd is PID 1:

```powershell
wsl --shutdown
wsl -d Ubuntu-24.04 -- ps -p 1 -o comm=    # expect: systemd
```

**B3. Get the WSL IP** (`<WSL_INTERNAL_IP>`):

```bash
# Inside Ubuntu: use eth0. `hostname -I` also lists CNI/flannel addresses once K3s is up.
ip -4 addr show eth0
```

```powershell
# Or from Windows
wsl -d Ubuntu-24.04 -- ip -4 -o addr show eth0
```

**B4. Forward the ports (Admin PowerShell).** Portproxy is TCP-only and depends
on the **IP Helper** (`iphlpsvc`) service, which runs by default:

```powershell
netsh interface portproxy add v4tov4 listenport=6443 listenaddress=0.0.0.0 connectport=6443 connectaddress=<WSL_INTERNAL_IP>
netsh interface portproxy add v4tov4 listenport=80   listenaddress=0.0.0.0 connectport=80   connectaddress=<WSL_INTERNAL_IP>
netsh interface portproxy add v4tov4 listenport=443  listenaddress=0.0.0.0 connectport=443  connectaddress=<WSL_INTERNAL_IP>
```

> 80/443 are only needed for **LAN** access to Traefik. Public traffic arrives
> via cloudflared, which runs in-cluster and connects outbound, so it never
> uses the portproxy. Outbound traffic from WSL (Prometheus scraping Home
> Assistant, K8sGPT calling Ollama, etcd snapshots to S3) works through NAT
> without any rules.

**B5. Windows Firewall rules (Admin PowerShell),** scoped to the Private profile and the local subnet:

```powershell
New-NetFirewallRule -DisplayName "K3s API (WSL portproxy)" -Direction Inbound -Protocol TCP `
  -LocalPort 6443 -Action Allow -Profile Private -RemoteAddress LocalSubnet
New-NetFirewallRule -DisplayName "Traefik HTTP/HTTPS (WSL portproxy)" -Direction Inbound -Protocol TCP `
  -LocalPort 80,443 -Action Allow -Profile Private -RemoteAddress LocalSubnet
```

If you already created the broader `K3s API` rule from
[hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md), remove it so you only have one
6443 rule: `Remove-NetFirewallRule -DisplayName "K3s API"`.

**B6. Verify the forwarding:**

```powershell
netsh interface portproxy show all
Get-NetTCPConnection -State Listen -LocalPort 6443,80,443
Test-NetConnection -ComputerName 127.0.0.1 -Port 6443    # after K3s is installed
```

**B7. Refresh the portproxy and keep WSL running after reboot.** The NAT
address can change after a reboot or `wsl --shutdown`, and WSL stops a distro
when its last process exits. Save this script **locally on the Windows host**
(it's machine-specific, so keep it out of this repo), for example at
`C:\lab\Update-K3sPortProxy.ps1`:

```powershell
# Update-K3sPortProxy.ps1. Run elevated, as the user that owns the WSL distro.
$Distro = 'Ubuntu-24.04'
$Ports  = 6443, 80, 443

# Any wsl.exe call boots the distro (and k3s.service via systemd) if it is stopped.
$line  = wsl.exe -d $Distro -- ip -4 -o addr show eth0
$WslIp = ($line -replace '.*inet (\S+)/.*', '$1').Trim()
if ($WslIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Could not determine WSL IP (got: '$line')" }

foreach ($p in $Ports) {
  netsh interface portproxy delete v4tov4 listenport=$p listenaddress=0.0.0.0 2>$null | Out-Null
  netsh interface portproxy add    v4tov4 listenport=$p listenaddress=0.0.0.0 connectport=$p connectaddress=$WslIp
}

# Keep the distro alive so K3s isn't stopped when no shell is open.
if (-not (Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" | Where-Object { $_.CommandLine -match 'sleep infinity' })) {
  Start-Process -WindowStyle Hidden wsl.exe -ArgumentList "-d $Distro --exec sleep infinity"
}

netsh interface portproxy show v4tov4
```

Register it as a scheduled task (Admin PowerShell). WSL distros are installed
per user, so the task must run as **your** account, not `SYSTEM`:

```powershell
$Action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\lab\Update-K3sPortProxy.ps1'
$Trigger   = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
$Settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName 'K3s-WSL-PortProxy' -Action $Action -Trigger $Trigger `
  -Principal $Principal -Settings $Settings

Start-ScheduledTask -TaskName 'K3s-WSL-PortProxy'    # test it now
```

> If your WSL build won't start a distro under an S4U (non-interactive) logon,
> switch to `New-ScheduledTaskTrigger -AtLogOn` and enable automatic sign-in
> for the laptop's local account.

Continue to [Shared: K3s install](#shared-k3s-install). Option B needs the
extra `<HP_HOST_IP>` TLS SAN.

---

## Shared: K3s install

Run this on `lab-k3s-ctrl-01`: the bare-metal host for Option A, or the Ubuntu WSL
distro for Option B. Create `/etc/rancher/k3s/config.yaml` there, mode `0600`
(**not** in git). The canonical version is in
[k3s-iot-stack.md](k3s-iot-stack.md#k3s-install). The only difference between
the options is `tls-san`:

```yaml
cluster-init: true                 # embedded etcd (required for etcd snapshots)
write-kubeconfig-mode: "0600"
tls-san:
  - lab-k3s-ctrl-01
  - <K3S_NODE_IP>                  # Option A: the node's LAN address
  # - <HP_HOST_IP>                 # Option B: REQUIRED, since clients reach the API via the Windows host
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
sudo chmod 600 /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | sh -
```

If K3s is already installed without the right SAN (for example, from the quick
install in [hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md#phase-4-network-bridge-fallback-portproxy),
which passes `--tls-san <HP_HOST_IP>` via `INSTALL_K3S_EXEC`, an equivalent
approach), add it to `config.yaml` and run `sudo systemctl restart k3s`.

> **Option B caveat:** K3s auto-detects the node IP, which is
> `<WSL_INTERNAL_IP>` under NAT. If that address changes, the single-node
> embedded etcd normally recovers on restart. If `k3s.service` fails to come
> back, check `journalctl -u k3s` and see the K3s docs for
> `k3s server --cluster-reset`. Restore from an etcd snapshot if needed
> ([backup-and-restore.md](backup-and-restore.md)).

## Shared: verification

On the server:

```bash
sudo systemctl is-active k3s                 # active
sudo kubectl get nodes -o wide               # lab-k3s-ctrl-01   Ready
sudo kubectl -n kube-system get pods         # coredns, traefik, metrics-server Running
sudo k3s etcd-snapshot ls                    # after the first scheduled snapshot
```

From the Mac workstation, copy the kubeconfig. The file is root-only (`0600`),
so read it with `sudo`. For Option B, use the `sudo cat` route from
[hp-wsl-k3s-setup.md](hp-wsl-k3s-setup.md#phase-5-macos-workstation-connection),
because WSL doesn't run sshd by default.

```bash
# Save the server's /etc/rancher/k3s/k3s.yaml to ~/.kube/lab-k3s.yaml, then:
sed -i '' 's/127.0.0.1/<API_ENDPOINT>/' ~/.kube/lab-k3s.yaml   # <K3S_NODE_IP> (A) or <HP_HOST_IP> (B)
chmod 600 ~/.kube/lab-k3s.yaml
export KUBECONFIG=~/.kube/lab-k3s.yaml

nc -vz <API_ENDPOINT> 6443                   # reachability (through the portproxy for Option B)
openssl s_client -connect <API_ENDPOINT>:6443 </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName  # SAN must list <API_ENDPOINT>
kubectl get nodes                            # lab-k3s-ctrl-01   Ready
```

A `x509: certificate is valid for ..., not <API_ENDPOINT>` error means the
`tls-san` entry is missing. A timeout on Option B usually means the WSL IP changed:
re-run `C:\lab\Update-K3sPortProxy.ps1` and check `netsh interface portproxy show all`.

Kubeconfig files are gitignored by pattern; never commit them. Continue with
step 8 in the [Steps](#steps) table.
