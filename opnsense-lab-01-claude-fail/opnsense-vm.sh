#!/usr/bin/env bash
set -e

# === opnsense-vm.sh - Create OPNsense gateway VM on PVE ===
# - WAN (net0) on vmbr0 — LAN-facing, static 192.168.28.182/24
# - LAN (net1) on vmbr1 — internal, becomes 10.0.33.1/24

# --- Config ---
VMID=120
NAME="opnsense"
STORAGE="local-lvm"
DISK_SIZE="8G"
MEMORY=2048
CORES=2
OSTYPE="other"  # FreeBSD

# OPNsense release
OPNSENSE_VERSION="25.1"
OPNSENSE_MIRROR="https://mirror.dns-root.de/opnsense/releases/${OPNSENSE_VERSION}"
ISO_NAME="OPNsense-${OPNSENSE_VERSION}-dvd-amd64.iso"
ISO_BZ2="${ISO_NAME}.bz2"
ISO_DIR="/var/lib/vz/template/iso"
ISO_PATH="${ISO_DIR}/${ISO_NAME}"

# --- Functions ---
vm_exists() { qm status "$VMID" &>/dev/null; }

download_iso() {
    if [[ -f "$ISO_PATH" ]]; then
        echo "ℹ️ ISO already exists: $ISO_PATH"
        return
    fi

    echo "⚡ Downloading OPNsense ${OPNSENSE_VERSION} ISO..."
    mkdir -p "$ISO_DIR"

    if [[ -f "${ISO_DIR}/${ISO_BZ2}" ]]; then
        echo "ℹ️ Compressed ISO exists, decompressing..."
    else
        wget -q --show-progress -O "${ISO_DIR}/${ISO_BZ2}" "${OPNSENSE_MIRROR}/${ISO_BZ2}"
    fi

    echo "🚧 Decompressing ISO (this takes a while)..."
    bzip2 -dk "${ISO_DIR}/${ISO_BZ2}"
    echo "✅ ISO ready: $ISO_PATH"
}

create_vm() {
    if vm_exists; then
        echo "ℹ️ VM $VMID ($NAME) already exists, skipping."
        return
    fi

    download_iso

    echo "🚧 Creating OPNsense VM $VMID ($NAME)..."
    qm create $VMID --name "$NAME" \
        --ostype $OSTYPE \
        --memory $MEMORY \
        --cores $CORES \
        --scsihw virtio-scsi-pci \
        --net0 virtio,bridge=vmbr0 \
        --net1 virtio,bridge=vmbr1 \
        --serial0 socket \
        --vga std

    echo "🚧 Creating disk..."
    qm set $VMID --scsi0 ${STORAGE}:${DISK_SIZE}

    echo "🚧 Attaching ISO..."
    qm set $VMID --ide2 local:iso/${ISO_NAME},media=cdrom

    echo "🚧 Setting boot order (CD first for install)..."
    qm set $VMID --boot 'order=ide2;scsi0'

    echo "🚧 Starting VM..."
    qm start $VMID

    echo ""
    echo "✅ OPNsense VM $VMID created and started."
    echo ""
    echo "ℹ️ Complete the install via noVNC console in PVE web UI:"
    echo "  https://192.168.28.181:8006 → VM $VMID → Console"
    echo ""
    echo "  Login: installer / Password: opnsense"
    echo "  Select: Install (UFS)  →  da0  →  Confirm"
    echo "  Set root password  →  Complete install  →  Reboot"
    echo ""
    echo "  After install, run: $0 post-install"
}

post_install() {
    if ! vm_exists; then
        echo "❌ VM $VMID does not exist."
        exit 1
    fi

    echo "🚧 Detaching ISO..."
    qm set $VMID --delete ide2 2>/dev/null || true
    qm set $VMID --boot 'order=scsi0'

    echo "🚧 Switching display to serial console for headless operation..."
    qm set $VMID --vga serial0

    echo "🚧 Rebooting from disk..."
    qm reboot $VMID 2>/dev/null || { qm stop $VMID; sleep 3; qm start $VMID; }

    echo ""
    echo "✅ Post-install complete. VM $VMID boots from disk (serial console)."
    echo ""
    echo "ℹ️ Access serial console:"
    echo "  qm terminal $VMID"
    echo ""
    echo "ℹ️ Default login: root / opnsense"
    echo "ℹ️ Assign interfaces via console menu:"
    echo "  1) Assign interfaces  →  vtnet0=WAN, vtnet1=LAN"
    echo "  2) Set interface IPs"
    echo "     WAN: 192.168.28.182/24, GW: 192.168.28.1"
    echo "     LAN: 10.0.33.1/24 (no DHCP yet)"
    echo ""
    echo "ℹ️ Then configure via web UI or API:"
    echo "  https://192.168.28.182"
    echo ""
    echo "ℹ️ Or run: bash opnsense-config.sh create"
}

# --- Main ---
case "${1:-create}" in
    create)
        create_vm
        ;;
    post-install)
        post_install
        ;;
    start)
        qm start $VMID
        echo "✅ VM $VMID started."
        ;;
    stop)
        qm shutdown $VMID
        echo "✅ VM $VMID stopped."
        ;;
    console)
        qm terminal $VMID
        ;;
    status)
        if vm_exists; then
            qm status $VMID
            echo ""
            qm config $VMID | grep -E '^(name|memory|cores|net[0-9]|scsi[0-9]|boot)'
        else
            echo "❌ VM $VMID does not exist."
        fi
        ;;
    destroy)
        if vm_exists; then
            echo "🚧 Destroying VM $VMID..."
            qm stop $VMID --skiplock 2>/dev/null || true
            sleep 2
            qm destroy $VMID --purge
            echo "✅ VM $VMID destroyed."
        else
            echo "ℹ️ VM $VMID does not exist."
        fi
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|post-install|start|stop|console|status|destroy}"
        exit 1
        ;;
esac
