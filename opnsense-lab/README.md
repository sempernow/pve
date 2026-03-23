# OPNsense v25.7 on pve 8.4.1

**Q**:

Following the IaC pattern of file f0s-cluster-vms.sh: 

Create IaC for OPNsense v25.7 installed onto guest VM 
having 2 cpu, 2 GB memory, and 8GB local-lvm storage 
at pve 8.4.1 by template, 
and fitting this network architecture:

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


**A**:

The script follows the exact `k0s-cluster-vms.sh` idioms — `vm_exists`, `start_vm`, `destroy_vm`, emoji status, `printf` tables, case/esac dispatcher — with adaptations for a single-VM firewall appliance. A few things worth calling out explicitly:

**Why not cloud-init?**

OPNsense is FreeBSD-based. It has no cloud-init agent and ignores the Proxmox cloud-init drive entirely. The equivalent mechanism is the `OPNsense_Config` ISO: OPNsense detects a CD-ROM with that exact volume label on first boot, reads `/conf/config.xml` from it, and imports it. The script generates this ISO via `genisoimage` (already present on PVE) and attaches it as `ide2`. After first boot OPNsense renames the applied config internally so it won't re-apply — but you should still eject the ISO (`qm set 120 --ide2 none,media=cdrom`).

**Nano image vs. DVD/serial**

The nano image (`OPNsense-25.7-OpenSSL-nano-amd64.img.bz2`) is a pre-installed disk image (~1 GB compressed) that you `qm importdisk` directly — no interactive installer needed, which is why it fits the IaC pattern. The `template` subcommand handles the download + import + `qm template` conversion once; `create` just clones.

**Disk resize**

The nano image is ~1 GB on disk. `qm resize scsi0 8G` grows the block device before first boot; OPNsense/FreeBSD runs `growfs` automatically on first boot to expand into the new space. No manual partition work needed.

**Workflow**

```bash
bash opnsense-vm.sh template    # one-time: download image, build VMID 9010
bash opnsense-vm.sh create      # clone → 120, inject config ISO, start, wait
bash opnsense-vm.sh status
bash opnsense-vm.sh destroy-all # teardown both
```

```bash
qm stop 120
qm set 120 --delete serial0
qm set 120 --vga std
qm set 120 --ide2 none,media=cdrom
qm start 120

```

### Configure via pve Console

>The XML didn't apply, so reverting to GUI (pve > Console), 
>and via menu selections, set LAN and WAN, and then rebooted

Log in first:

```
login: root
password: opnsense
```

That drops you into the OPNsense console menu:

```
0) Logout
1) Assign interfaces
2) Set interface IP address
...
```

#### 1) Assign interfaces

```
Do VLANs need to be set up? n
Enter WAN interface: vtnet1
Enter LAN interface: vtnet0
Do you want to proceed? y
```

#### 2. Set interface IP address

For **WAN**:

```
Enter interface to configure: 1  (WAN)
Configure IPv4 via DHCP? n
Enter IPv4 address: 192.168.28.182
Subnet bit count: 24
Enter upstream gateway: 192.168.28.1
Configure IPv6? n
Revert to HTTP? n
```

For **LAN**:

```
Enter interface to configure: 2  (LAN)
Configure IPv4 via DHCP? n
Enter IPv4 address: 10.0.33.1
Subnet bit count: 24
No upstream gateway for LAN — just press Enter
Configure IPv6? n
```

After that OPNsense will print the updated IP summary 
and the web UI at `https://192.168.28.182` should respond from your workstation.