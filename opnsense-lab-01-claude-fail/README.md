# `opnsense-lab` : OPNsense Gateway VM on PVE

OPNsense replaces the host-level `iptables MASQUERADE` (`net-snat-bridge.sh`)
with a proper network appliance VM that owns all L3 services on `vmbr1`.

---

## Architecture

```
Internet
    │
  192.168.28.1 (LAN gateway)
    │
  vmbr0 (PVE host, 192.168.28.181)
    │
 OPNsense VM (VMID 120, 2 vCPU / 2 GB)
  ├── WAN (vtnet0) → vmbr0  192.168.28.182/24  gw 192.168.28.1
  └── LAN (vtnet1) → vmbr1  10.0.33.1/24
    │
  vmbr1 (plain L2 bridge, no host IP)
  ├── k0s-ctrl   10.0.33.11
  ├── k0s-w1     10.0.33.12
  └── k0s-w2     10.0.33.13
```

OPNsense provides on `vmbr1`:

| Service | Detail |
|---------|--------|
| **NAT/Gateway** | Outbound masquerade for `10.0.33.0/24` |
| **DHCP** | Range `10.0.33.100-.200` (avoids k0s static IPs `.11-.13`) |
| **DNS (Unbound)** | Forwards to `8.8.8.8/8.8.4.4`, local overrides for `*.k0s.local` |
| **Firewall** | LAN→WAN allow; WAN→LAN block except DNAT rules |
| **Port Forwarding** | `6443` → `10.0.33.11:6443` (k0s API), `30000-32767` (NodePort) |

The k0s nodes require **zero reconfiguration** — their gateway (`10.0.33.1`)
transfers from the PVE host to OPNsense transparently.

---

## Implementation Plan

### IaC Tooling

Shell scripts with `qm` CLI, matching the established `k0s-lab/` convention.
OPNsense is FreeBSD-based (no cloud-init), so the install is a one-time manual step
via serial console. All subsequent configuration is automated via the OPNsense REST API.

### File Structure

```
opnsense-lab/
├── .gitignore              # *.iso, *.img, *.bz2
├── README.md               # This file
├── opnsense-vm.sh          # Phase 1: Create/destroy OPNsense VM
├── net-bridge-demote.sh    # Transition vmbr1 from SNAT to plain L2
├── opnsense-config.sh      # Phase 2: Configure via OPNsense REST API
└── .api_creds              # API key/secret (gitignored)
```

### Steps

| Step | Script | Action |
|------|--------|--------|
| 1 | `opnsense-vm.sh create` | Download ISO, create VM 120 (2CPU/2GB, 8GB disk, 2 NICs), boot from ISO |
| 2 | Manual (one-time) | Install OPNsense via serial console: `qm terminal 120` |
| 3 | `opnsense-vm.sh post-install` | Detach ISO, set boot to disk, reboot |
| 4 | Manual (one-time) | Assign interfaces via console menu and set IPs |
| 5 | `net-bridge-demote.sh create` | Remove host's `10.0.33.1` and MASQUERADE from `vmbr1` |
| 6 | `opnsense-config.sh create` | Configure DHCP, DNS, firewall, NAT via API |

### Key Challenges & Mitigations

| Challenge | Mitigation |
|-----------|------------|
| **IP conflict during transition** | OPNsense takes `10.0.33.1` only after `net-bridge-demote.sh` removes the host's claim |
| **OPNsense has no cloud-init** | One-time manual install via serial console (~2 min), then all config via API |
| **Self-signed HTTPS** | API calls use `curl -k` |
| **k0s nodes hardcode DNS `8.8.8.8`** | Works through OPNsense NAT; optionally update later to `10.0.33.1` |
| **FreeBSD NIC naming** | virtio driver yields `vtnet0`/`vtnet1` in OPNsense |

---

## Usage

### Prerequisites

- PVE host with `vmbr0` and `vmbr1` configured (via `k0s-lab/net-snat-bridge.sh`)
- SSH access to PVE host as root
- Internet access on PVE host (to download ISO)

### 1. Create the VM

```bash
bash opnsense-vm.sh create
```

Downloads the OPNsense DVD ISO and creates VM 120 with:
- 2 vCPU, 2 GB RAM, 8 GB disk
- `net0` (WAN) on `vmbr0`
- `net1` (LAN) on `vmbr1`
- VGA display (for noVNC install), serial socket (for post-install headless)

### 2. Install OPNsense (one-time, via noVNC)

Open the PVE web UI console:

```
https://192.168.28.181:8006 → VM 120 → Console
```

At the console:
1. Login: `installer` / Password: `opnsense`
2. Select **Install (UFS)** → disk `da0` → confirm
3. Set root password → **Complete install** → **Reboot**

### 3. Post-install

```bash
bash opnsense-vm.sh post-install
```

Detaches ISO and sets boot to disk.

### 4. Assign interfaces (one-time, via console)

```bash
qm terminal 120
```
- Break out of PXE: **`CTRL+O`**

Login as `root`, then use the console menu:
1. **Option 1** — Assign interfaces: `vtnet0` = WAN, `vtnet1` = LAN
2. **Option 2** — Set interface IPs:
   - WAN: `192.168.28.182/24`, gateway `192.168.28.1`
   - LAN: `10.0.33.1/24`, no DHCP server yet

### 5. Transition vmbr1

**Critical step** — run only after OPNsense LAN is configured:

```bash
bash net-bridge-demote.sh create
```

This removes the PVE host's `10.0.33.1` address and iptables MASQUERADE,
so OPNsense becomes the sole gateway. k0s nodes' gateway (`10.0.33.1`)
now resolves to OPNsense.

To revert (restore host-managed NAT):
```bash
bash net-bridge-demote.sh destroy
```

### 6. Create API key

1. Open `https://192.168.28.182` in a browser
2. Login: `root` / (your password)
3. **System → Access → Users → Edit root**
4. Scroll to **API keys → Create**
5. Save to `.api_creds`:
   ```bash
   API_KEY="your-key-here"
   API_SECRET="your-secret-here"
   ```

### 7. Configure services

```bash
bash opnsense-config.sh create
```

Configures via API:
- **DHCP**: `10.0.33.100-200` on LAN
- **DNS (Unbound)**: forwarding to `8.8.8.8` / `8.8.4.4`, local overrides:
  - `k0s-ctrl.k0s.local` → `10.0.33.11`
  - `k0s-w1.k0s.local` → `10.0.33.12`
  - `k0s-w2.k0s.local` → `10.0.33.13`
- **Firewall**: port forward `6443` → k0s-ctrl, NodePort range `30000-32767`

### Verify

```bash
# From PVE host — k0s nodes can reach internet through OPNsense
ssh k0s@10.0.33.11 "curl -s ifconfig.me && echo"

# From workstation — k0s API via OPNsense port forward
# Update static route to point at OPNsense WAN IP:
#   route add 10.0.33.0 mask 255.255.255.0 192.168.28.182 -p
kubectl --kubeconfig ~/.kube/config_pve_k0s get nodes
```

---

## Teardown

```bash
# Restore host-managed NAT first
bash net-bridge-demote.sh destroy

# Destroy the VM
bash opnsense-vm.sh destroy
```

---

## Management

| Task | Command |
|------|---------|
| VM status | `bash opnsense-vm.sh status` |
| Serial console | `bash opnsense-vm.sh console` |
| Web UI | `https://192.168.28.182` |
| Bridge status | `bash net-bridge-demote.sh status` |
| API status | `bash opnsense-config.sh status` |
