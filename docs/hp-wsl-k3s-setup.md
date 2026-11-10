# HP Laptop WSL2 K3s Control Plane Setup

This guide documents the configuration required to run a K3s control plane inside Windows 11 WSL2 and securely expose the Kubernetes API to a remote macOS workstation over the local GL.iNet subnet.

> **Which guide applies?** This document covers running `lab-k3s-ctrl-01` on a
> **Windows 11 host via WSL2**. For the native bare-metal **Ubuntu Server 24.04**
> install, see [k3s-iot-stack.md](k3s-iot-stack.md#k3s-server-setup-lab-k3s-ctrl-01).
> The rest of the platform (add-ons, manifests, backups) is identical either way.

Placeholders used below (look them up locally; never commit real values):

| Placeholder | Meaning |
|---|---|
| `<HP_HOST_IP>` | The HP laptop's Windows LAN address (its DHCP reservation on the router) |
| `<WSL_INTERNAL_IP>` | The WSL2 NAT address inside Ubuntu (only relevant if mirrored networking fails) |

## Phase 1: Windows Host Network & Power Configuration

1. **Keep the server awake:**
   - Navigate to **Control Panel** -> **Power Options** -> **Choose what closing the lid does**.
   - Set "When I close the lid" (Plugged in) to **Do nothing**.
   - Set "Sleep" to **Never**.
2. **Set Wi-Fi to Private:**
   - In Windows Settings -> **Network & internet** -> **Wi-Fi**, click the active GL.iNet network and change the profile type from **Public** to **Private** to allow local inbound traffic.
3. **Open the Windows Firewall (Admin PowerShell):**

   ```powershell
   New-NetFirewallRule -DisplayName "K3s API" -Direction Inbound -LocalPort 6443 -Protocol TCP -Action Allow
   ```

## Phase 2: WSL2 Engine Preparation

1. **Enable mirrored networking:**
   - Open PowerShell and edit the global WSL config: `notepad "$env:USERPROFILE\.wslconfig"`
   - Add the following block to attempt passing the host's LAN address directly to Ubuntu:

     ```ini
     [wsl2]
     networkingMode=mirrored
     firewall=false
     ```

2. **Force the WSL engine update** so WSL supports the latest networking features:

   ```powershell
   wsl --update
   wsl --shutdown
   ```

## Phase 3: Ubuntu Subsystem Configuration

1. **Enable systemd and set the hostname:**
   - Open the Ubuntu WSL terminal and create `/etc/wsl.conf` (e.g. `sudo vi /etc/wsl.conf`) with:

     ```ini
     [boot]
     systemd=true
     [network]
     hostname=lab-k3s-ctrl-01
     ```

   - Restart the subsystem from Windows PowerShell: `wsl --shutdown`

2. **Install K3s:**
   - Re-open the Ubuntu terminal and run the K3s installation script:

     ```bash
     curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 0600
     ```

   - Verify the control plane is live: `sudo kubectl get nodes`

## Phase 4: Network Bridge Fallback (Portproxy)

If WSL fails to inherit the host's LAN address (`<HP_HOST_IP>`) and instead assigns a NAT address (`<WSL_INTERNAL_IP>`), manually bridge traffic from Windows into the WSL subsystem.

1. **Find the internal WSL address:**
   - In the Ubuntu terminal, run `ip -4 addr show eth0` and note the address; this is `<WSL_INTERNAL_IP>`.

2. **Create the port proxy (Admin PowerShell)** to forward incoming API requests to the Linux subsystem:

   ```powershell
   netsh interface portproxy add v4tov4 listenport=6443 listenaddress=0.0.0.0 connectport=6443 connectaddress=<WSL_INTERNAL_IP>
   ```

   > The WSL NAT address can change after a reboot or `wsl --shutdown`; re-check
   > it and update the proxy rule if the API becomes unreachable.

3. **Update the K3s TLS SAN** so K3s accepts traffic addressed to the Windows host. Reinstall K3s with `<HP_HOST_IP>` in the certificate's Subject Alternative Names:

   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --tls-san <HP_HOST_IP> --write-kubeconfig-mode 0600" sh -s -
   ```

## Phase 5: macOS Workstation Connection

1. **Export the cluster credentials.** The kubeconfig is mode `0600` (root-only), so read it with `sudo` in the HP laptop's Ubuntu terminal:

   ```bash
   sudo cat /etc/rancher/k3s/k3s.yaml
   ```

2. **Configure the Mac:**
   - Save the output to `~/.kube/lab-k3s.yaml` (kubeconfig files are gitignored by pattern; never commit them) and run `chmod 600 ~/.kube/lab-k3s.yaml`.
   - Edit the `server` line, replacing `127.0.0.1` with the HP laptop's Windows address: `https://<HP_HOST_IP>:6443`.
   - `export KUBECONFIG=~/.kube/lab-k3s.yaml`

3. **Verify remote access:**
   - From the Mac terminal, run `kubectl get nodes`. It should return `lab-k3s-ctrl-01` with a `Ready` status.
