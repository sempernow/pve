# `pve` : **P**roxmox **V**irtual **E**nvironment 

[Proxmox logo](../autorun.ico)

**Headless install**

**Access**

- **Web**: https://192.168.28.181:8006
- **SSH**: `root@192.168.28.181`

**Creds**
```bash
Ubuntu (master =) ... /s/DEV/devops/infra/hypervisors/proxmox/pve
☩ agede creds.proxmox.age
pve:
  user: root
  pass: Prox***
```

## Infra Architecture and Resources Plan

Here's our preliminiary design goal for this private network: 

* One 3-node K0s cluster (1 control, 2 worker) on Debian 12.
* One RHEL 9 IdM domain controller having cross-forest trust *under* AD (WinSrv 2019) domain controller 
  that is on another subnet (NAT network on 10.0.11.0/24). 
  AD is the authoritative IdP. 

Guest VMs on this pve should be on segregated network (10.0.33.0/24, perhaps) having access to, but protected from, upstream gateway router (192.168.28.1) that connects this network to the internet.

```mermaid
flowchart TD
    LAN(
        Internet Gateway
        192.168.28.0/24
    )
    LAN --> PVE
    PVE -->vmbr1{
        vmbr1
        SNAT Bridge 
        10.0.33.0/24
    }
    vmbr1 --> k0s-ctrl
    vmbr1 --> k0s-w1
    vmbr1 --> k0s-w2
    
    LAN --> HyperV
    HyperV --> NAT1{
        NAT1/vEth
        NetNAT/InternalSW
        10.0.11.0/24
    }
    NAT1 --> W(
            Windows Server
        ADDC/DNS/DHCP/ADCS
    )
    NAT1 --> adm
    NAT1 --> k8s-cp-w1
    NAT1 --> k8s-cp-w2
    NAT1 --> k8s-cp-w3

    W -. AD/DHCP/DNS .-> adm
    W -. AD/DHCP/DNS .-> k8s-cp-w1
    W -. AD/DHCP/DNS .-> k8s-cp-w2
    W -. AD/DHCP/DNS .-> k8s-cp-w3

```

### Storage

The 100GB is default install. Is that too much? Regarding ZFS, taking some 8-16 GB of memory, not sure if we can afford that.

### CPU/RAM

Ryzen 7 has 16 threads. Each is a vCPU under a type-1 hypervisor (pve). 
So, regarding resources (cpu, ram), perhaps  :

* IdM : 2 vCPU / 4 GB 
* K0s control: 2 vCPU / 4 GB
* K0s worker: 4 vCPU / 16 GB

Guest VMs total: 12 CPU / 40 GB

That leaves 4 vCPU / 24 GB for the hypervisor (pve) *and* ZFS

So, if ZFS takes 16 GB, that leaves only 6 GB for pve.


## Assessment

Good plan overall. A few corrections and suggestions:

## CPU Misconception

vCPUs aren't "reserved" — they're scheduled. Proxmox (KVM) time-slices physical cores across VMs. You can safely overcommit for bursty workloads. Your 12 vCPU allocation across 16 threads is conservative and fine.

## RAM Reality

| Component | RAM |
|-----------|-----|
| Proxmox host | ~1-2 GB |
| IdM | 4 GB |
| K0s controller | 4 GB |
| K0s workers (2×16) | 32 GB |
| **Total** | ~42 GB |

Leaves ~22 GB free. You're not using ZFS (you have LVM-thin), so that concern doesn't apply unless you reinstall.

## Assessment by Component

**Storage (100GB root):** Oversized but harmless. Default installer is cautious. Not worth reinstalling.

**IdM (2 vCPU / 4 GB):** Tight but workable for lab. FreeIPA runs LDAP + Kerberos + DNS + CA. If sluggish, bump to 6GB.

**K0s controller (2 vCPU / 4 GB):** Fine for a 3-node cluster.

**K0s workers (4 vCPU / 16 GB each):** Generous — good if you're running real workloads. Could start at 8GB and scale up.

## Network Topology

For the segregated 10.0.33.0/24:

```
                    ┌─────────────────┐
                    │  192.168.28.1   │
                    │  (gateway/NAT)  │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │ pve host (vmbr0)            │
              │ 192.168.28.x                │
              └──────────────┬──────────────┘
                             │
         ┌───────────────────┴───────────────────┐
         │ vmbr1 (internal only, 10.0.33.0/24)   │
         │ no gateway, or pve as router          │
         └───────────────────┬───────────────────┘
                             │
        ┌────────────┬───────┴────────┬────────────┐
        │            │                │            │
    k0s-ctrl     k0s-w1          k0s-w2         IdM
   10.0.33.11   10.0.33.12      10.0.33.13    10.0.33.10
```

You'll need:

1. Create `vmbr1` (no physical interface, internal only)
2. Either run a router VM, or enable IP forwarding on pve host with iptables NAT

## Revised Resource Allocation

| VM | vCPU | RAM | Disk | Network |
|----|------|-----|------|---------|
| IdM | 2 | 4-6 GB | 40 GB | vmbr1 (+ vmbr0 for AD trust?) |
| k0s-ctrl | 2 | 4 GB | 32 GB | vmbr1 |
| k0s-w1 | 4 | 12 GB | 32 GB | vmbr1 |
| k0s-w2 | 4 | 12 GB | 32 GB | vmbr1 |
| **Total** | 12 | 32-34 GB | 136 GB | |

This leaves ~30GB RAM headroom for growth or burst.

Want to tackle the network setup (vmbr1 + routing) first, 
or proceed with VMs on the flat network for now?

---

## Q:

Let's create a VM on flat network for later teardown, just to have the IaC. 
Then we build the network, and then create VMs on that. 
We want to do all by code rather than web UI.

## A:

Good approach — validate the pattern, then apply to real infra.

### Validate the pattern

Create a VM on flat network: [__`k0s-flat-vm.sh`__](k0s-lab/k0s-flat-vm.sh)

Usage:

```bash
# Create and start
bash k0s-flat-vm.sh create

# Check status
bash k0s-flat-vm.sh status ## No IP due to no qemu-guest-agent
# Add that convenience imperatively ...
ssh k0s@192.168.28.84 '
    sudo apt update &&
        sudo apt install -y qemu-guest-agent &&
            sudo systemctl enable --now qemu-guest-agent
'
#...or bake it into template

# Console access
qm terminal 100 # user: k0s, pass: changeme

# Teardown
bash k0s-flat-vm.sh destroy
```

Prep to bake `qemu-guest-agent` into the template by creating snippet:

```bash
mkdir -p /var/lib/vz/snippets

cat > /var/lib/vz/snippets/k0s-packages.yaml << 'EOF'
#cloud-config
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF
```
- __`/var/lib/vz`__ is __`local`__ in Proxmox GUI.   
  It's the default local-storage directory  
  used to store __images__ (`*.iso`, `*.qcow2`),   
  container __templates__, and __backups__.   
  It acts as a standard file-based storage pool   
  for VMs and LXCs, often residing on the root partition. 


Create SSH key pair for guest host access:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

Add key installation to [__`k0s-flat-vm.sh`__](k0s-lab/k0s-flat-vm.sh).  
Then teardown/recreate the VM:
```bash
bash k0s-lab/k0s-flat-vm.sh destroy
bash k0s-lab/k0s-flat-vm.sh create
```

Revise template: @ [__`debian12-template-v0.0.2.sh`__](k0s-lab/debian12-template-v0.0.2.sh)


Key changes:

| Addition | Purpose |
|----------|---------|
| `pvesm set local --content ...snippets` | Enable snippets on local storage |
| `k0s-base.yaml` | Installs qemu-guest-agent + common tools |
| `--agent enabled=1` | Tells Proxmox to expect the agent |
| `--cicustom vendor=...` | Applies snippet to all clones |

Run it:

```bash
bash debian12-template.sh
```

Teardown / Recreate

```bash
bash k0s-lab/debian12-template-v0.0.2.sh    # Update template 9000
bash k0s-lab/k0s-flat-vm.sh destroy         # Delete old VM 100
bash k0s-lab/k0s-flat-vm.sh create          # Create new VM 100
```
- [__`debian12-template-v0.0.2.sh`__](k0s-lab/debian12-template-v0.0.2.sh)
- [__`k0s-flat.sh`__](k0s-lab/k0s-flat-vm.sh).  


Success!

@ `root@pve [08:30:54] [1] [#0] ~`
```bash
# Create a single test VM
bash vm/k0s-flat.sh

# Shell into `k0s-test` (VM 100) as `k0s`:
ssh k0s@192.168.28.102
```

---

### Build Network and VMs

Pattern is validated. Now we build:

1. [__`net-snat-bridge.sh`__](k0s-lab/net-snat-bridge.sh)
    - Creates `vmbr1`, configures routing/NAT
2. [__`k0s-cluster-vms.sh`__](k0s-lab/k0s-cluster-vms.sh)
    - Creates 3 VMs on `10.0.33.0/24`

```bash
# 1. Create isolated network
bash net-snat-bridge.sh create
bash net-snat-bridge.sh status

# 2. Create cluster
bash k0s-cluster-vms.sh create

# 3. Verify SSH from pve host
ssh k0s@10.0.33.11

# Smoke test SNAT for internet connectivity
ssh k0s@10.0.33.11 "curl -s ifconfig.me && echo"

```

### Install/Create Kubernetes cluster `K0sctl`/`K0s`

Create the 3-node cluster on the VMs of `10.0.33.0/24`

- [__`kubectl-install.sh`__](k0s-lab/kubectl-install.sh)
- [__`k0s-install.sh`__](k0s-lab/k0s-install.sh)

@ `root@pve [12:08:42] [1] [#0] ~/vm`

```bash
bash k0s-install.sh install
export KUBECONFIG=$(pwd)/kubeconfig
```

Change TZ to EST

```bash
timedatectl set-timezone America/New_York
```

## IdM 

Continuing from the original architecture plan, remaining items:

- IdM (FreeIPA)
    - RHEL 9 VM with cross-forest trust to AD
- Network access controls
    - Protecting the `10.0.33.0/24` subnet from upstream

Want to spin up the IdM VM next, 
or take a break and commit these scripts to a repo first?

## Create VM 

### by GUI (button)

1. OS tab — select ISO from `local`
    - But don't do this GUI method. Using a `*.iso` would an interactive install.
    Rather, use __`qm`__-automated __`cloud-init`__ script method on a __`*.qcow2`__ artifact:
        - https://cloud.debian.org/images/cloud/bookworm/latest/ , e.g.,
        - https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2
2. Disks tab — select `local-lvm` for the VM's virtual hard drive


### by CLI [`qm`](https://pve.proxmox.com/pve-docs/qm.1.html)

Proxmox CLI for managing QEMU/KVM VMs

| Command | What it does |
|---------|--------------|
| `qm create` | Create a VM |
| `qm set` | Modify VM config |
| `qm start/stop` | Power control |
| `qm importdisk` | Import a disk image |
| `qm template` | Convert VM to template |
| `qm clone` | Clone a VM or template |
| `qm list` | List all VMs |

There's also `pct` for LXC containers, and `pvesm` for storage (which you used earlier).

## Create VM Template 

```bash
bash debian12-template.sh
```

Debian 12 (bookworm) configured for `cloud-init` method (__`*.qcow2`__)

@ [__`debian12-template-v0.0.1.sh`__](pve/vm/debian12-template-v0.0.1.sh)

## **W**ake **o**n **L**an (WoL) 

### How to wake a __headless__ Proxmox node:

- **Configure** for WoL:
    - BIOS/UEFI: 
        - Disable: "`ERP Ready`"
        - Enable: "`Resume By PCI-E Device`"
    - Install `ethtool` (installed by default at pve v8.4.1): 
        ```bash
        apt install ethtool -y
        ```
    - Enable WoL on the public-facing interface (__`$ifc`__): 
        ```bash
        ethtool -s $ifc wol g # Wake on Magic Packet
        ethtool -s $ifc wol u # Wake on any traffic
        ```
    - Make it persistent by appending to the interfaces file &hellip; 
        ```bash
        tee -a /etc/network/interfaces <<-EOH
        post-up /sbin/ethtool -s $ifc wol g
        EOH
        ```
- **Wake Proxmox** (pve):
    - Send Magic Packet:   
        -   Use a WoL app on remote machine to send magic packet to Proxmox's MAC address.
        - SSH config
            ```ini
            Host proxmox pve
                HostName 192.168.1.181
                User root
                # Runs WoL cmd locally before SSH session
                ProxyCommand sh -c "wakeonlan <MAC_ADDR> && sleep 30; nc %h %p"
            ```
- **Wake guest VM** on pve:  
    ```bash
    qm sendkey $vm_id # Wake via SSH ProxyCommand method
    ```
- Automation: Tools like Home Assistant can be configured to detect network activity and automatically send the wake-on-lan packet to boot the server. 

Note: Ensure the NIC supports WOL, as indicated by `Wake-on: g` in the `ethtool` `<interface>` output. 



---

<!-- 

… ⋮ ︙ • ● – — ™ ® © ± ° ¹ ² ³ ¼ ½ ¾ ÷ × ₽ € ¥ £ ¢ ¤ ♻ ⚐ ⚑ ✪ ❤  \ufe0f
☢ ☣ ☠ ¦ ¶ § † ‡ ß µ Ø ƒ Δ ☡ ☈ ☧ ☩ ✚ ☨ ☦ ☓ ♰ ♱ ✖  ☘  웃 𝐀𝐏𝐏 🡸 🡺 ➔
ℹ️ ⚠️ ✅ ⌛ 🚀 🚧 🛠️ 🔧 🔍 🧪 👈 ⚡ ❌ 💡 🔒 📊 📈 🧩 📦 🥇 ✨️ 🔚

# Markdown Cheatsheet

[Markdown Cheatsheet](https://github.com/adam-p/markdown-here/wiki/Markdown-Cheatsheet "Wiki @ GitHub")

# README HyperLink

README ([MD](__PATH__/README.md)|[HTML](__PATH__/README.html)) 

# Bookmark

- Target
<a name="foo"></a>

- Reference
[Foo](#foo)

-->
