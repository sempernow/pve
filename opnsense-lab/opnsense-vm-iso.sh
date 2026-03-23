#!/usr/bin/env bash
set -e

# === opnsense-vm.sh - OPNsense firewall VM on Proxmox ===
#
# OPNsense is FreeBSD-based; it does NOT use cloud-init.
# Initial config is injected via a config.xml on an ISO
# labeled "OPNsense_Config" — OPNsense reads it on first boot.
#
# Subcommands:
#   template      Download OPNsense nano image → Proxmox template (VMID 9010)
#   create        Clone template → VM 120, attach config ISO, start
#   start         Start VM if stopped
#   status        Show VM + template state
#   destroy       Stop + delete VM 120
#   destroy-all   destroy + destroy template 9010
#
# Network:
#   Internet → 192.168.28.1
#     └── vmbr0 → OPNsense WAN (vtnet0)  192.168.28.182/24
#                 OPNsense LAN (vtnet1)  10.0.33.1/24 → vmbr1
#                   ├── k0s-ctrl  10.0.33.11
#                   ├── k0s-w1    10.0.33.12
#                   └── k0s-w2    10.0.33.13

# --- Config ---
VMID=120
NAME="opnsense"
TEMPLATE_ID=9010
STORAGE="local-lvm"
ISO_STORE="/var/lib/vz/template/iso"

CORES=2
RAM_MB=2048
DISK_SIZE="8G"

WAN_BRIDGE="vmbr0"
LAN_BRIDGE="vmbr1"
WAN_IP="192.168.28.182"
WAN_MASK="24"
WAN_GW="192.168.28.1"
LAN_IP="10.0.33.1"
LAN_MASK="24"

# OPNsense nano image: pre-installed FreeBSD disk, import-ready (no interactive install)
# Nano image is ~1 GB; disk is grown to DISK_SIZE after import.
OPNSENSE_VER="25.7"
OPNSENSE_FLAVOR="OpenSSL"          # or LibreSSL
OPNSENSE_ARCH="amd64"
OPNSENSE_IMG_BZ2="OPNsense-${OPNSENSE_VER}-nano-${OPNSENSE_ARCH}.img.bz2"  # flavor not in nano filename
OPNSENSE_IMG="/tmp/OPNsense-${OPNSENSE_VER}-nano-${OPNSENSE_ARCH}.img"
OPNSENSE_MIRROR="https://mirror.ams1.nl.leaseweb.net/opnsense/releases/${OPNSENSE_VER}"

# Root password for injected config.xml (SHA-512 crypt; change before use)
ROOT_PASSWORD="opnsense"

# --- Functions ---
vm_exists() { qm status "$1" &>/dev/null; }

hash_password() {
    # SHA-512 crypt — compatible with OPNsense/FreeBSD /etc/master.passwd
    python3 -c "import crypt; print(crypt.crypt('${ROOT_PASSWORD}', crypt.mksalt(crypt.METHOD_SHA512)))" \
        2>/dev/null \
        || openssl passwd -6 "${ROOT_PASSWORD}"
}

download_image() {
    if [[ -f "$OPNSENSE_IMG" ]]; then
        if [[ ! -s "$OPNSENSE_IMG" ]]; then
            echo "⚠️  Stale zero-byte image found, removing: $OPNSENSE_IMG"
            rm -f "$OPNSENSE_IMG"
        else
            echo "ℹ️  Image already present: $OPNSENSE_IMG"
            return
        fi
    fi
    echo "⬇️  Downloading OPNsense ${OPNSENSE_VER} nano image..."
    curl -fLIX GET "${OPNSENSE_MIRROR}/${OPNSENSE_IMG_BZ2}" >/dev/null 2>&1 || {
        exit=$?
        echo "❌ ERR $exit at URL: '${OPNSENSE_MIRROR}/${OPNSENSE_IMG_BZ2}'"
        exit $exit
    }
    curl -L --progress-bar -o "${OPNSENSE_IMG}.bz2" "${OPNSENSE_MIRROR}/${OPNSENSE_IMG_BZ2}"

    # Reject HTML error pages masquerading as the download
    if ! file "${OPNSENSE_IMG}.bz2" | grep -q 'bzip2'; then
        echo "❌ Download is not a bzip2 file — likely a 404/error page from mirror."
        echo "   Content: $(head -c 120 "${OPNSENSE_IMG}.bz2")"
        echo "   Check mirror: curl -sI ${OPNSENSE_MIRROR}/${OPNSENSE_IMG_BZ2}"
        rm -f "${OPNSENSE_IMG}.bz2"
        exit 1
    fi

    echo "📦 Decompressing..."
    bunzip2 "${OPNSENSE_IMG}.bz2"

    # Validate: qemu-img must recognise the image and report non-zero virtualsize
    local vsize
    vsize=$(qemu-img info --output=json "$OPNSENSE_IMG" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('virtual-size',0))" 2>/dev/null \
        || echo 0)
    if [[ "$vsize" == "0" || -z "$vsize" ]]; then
        echo "❌ Image validation failed (virtualsize=0). File may be corrupt."
        echo "   Inspect: qemu-img info $OPNSENSE_IMG"
        echo "   Remove and retry: rm $OPNSENSE_IMG && $0 template"
        rm -f "$OPNSENSE_IMG"
        exit 1
    fi
    echo "✅ Image saved: $OPNSENSE_IMG  (virtualsize=${vsize} bytes)"
}

create_template() {
    if vm_exists "$TEMPLATE_ID"; then
        # Detect broken partial template: VM shell exists but scsi0 disk does not
        if ! qm config "$TEMPLATE_ID" 2>/dev/null | grep -q '^scsi0:'; then
            echo "⚠️  Template $TEMPLATE_ID exists but has no disk (broken import). Rebuilding..."
            qm destroy "$TEMPLATE_ID" --purge
        else
            echo "ℹ️  Template $TEMPLATE_ID already exists, skipping."
            return
        fi
    fi

    download_image

    echo "🔧 Building OPNsense template (VMID $TEMPLATE_ID)..."

    # Bare VM shell — serial console matches OPNsense nano's vtty0
    qm create $TEMPLATE_ID \
        --name "opnsense-tmpl" \
        --memory $RAM_MB \
        --cores $CORES \
        --cpu host \
        --ostype other \
        --scsihw virtio-scsi-pci \
        --serial0 socket \
        --vga serial0 \
        --onboot 0

    # Import nano disk → scsi0; nano boots without interactive install
    qm importdisk $TEMPLATE_ID "$OPNSENSE_IMG" $STORAGE 2>&1 | grep -v '%'
    qm set $TEMPLATE_ID --scsi0 ${STORAGE}:vm-${TEMPLATE_ID}-disk-0,cache=writeback
    qm set $TEMPLATE_ID --boot order=scsi0

    # Stub NICs; net0=WAN, net1=LAN — consistent across all clones
    qm set $TEMPLATE_ID --net0 virtio,bridge=$WAN_BRIDGE
    qm set $TEMPLATE_ID --net1 virtio,bridge=$LAN_BRIDGE

    qm template $TEMPLATE_ID
    echo "✅ Template $TEMPLATE_ID created."
}

# Generate minimal OPNsense config.xml for first-boot injection.
# OPNsense reads /conf/config.xml from a CD-ROM labeled "OPNsense_Config".
# Schema ref: https://github.com/opnsense/core/blob/master/src/etc/config.xml
generate_config_xml() {
    local pw_hash
    pw_hash=$(hash_password)

    cat <<XMLEOF
<?xml version="1.0"?>
<opnsense>
  <version>21.7</version>
  <system>
    <hostname>${NAME}</hostname>
    <domain>localdomain</domain>
    <timezone>UTC</timezone>
    <webgui>
      <protocol>https</protocol>
    </webgui>
    <ssh>
      <enabled>enabled</enabled>
      <permitrootlogin>1</permitrootlogin>
    </ssh>
    <user>
      <name>root</name>
      <descr>System Administrator</descr>
      <scope>system</scope>
      <groupname>admins</groupname>
      <password>${pw_hash}</password>
      <uid>0</uid>
    </user>
  </system>
  <interfaces>
    <wan>
      <enable>1</enable>
      <if>vtnet0</if>
      <descr>WAN</descr>
      <ipaddr>${WAN_IP}</ipaddr>
      <subnet>${WAN_MASK}</subnet>
      <gateway>WAN_GW</gateway>
      <blockbogons>1</blockbogons>
      <blockpriv>1</blockpriv>
    </wan>
    <lan>
      <enable>1</enable>
      <if>vtnet1</if>
      <descr>LAN</descr>
      <ipaddr>${LAN_IP}</ipaddr>
      <subnet>${LAN_MASK}</subnet>
    </lan>
  </interfaces>
  <gateways>
    <gateway_item>
      <name>WAN_GW</name>
      <interface>wan</interface>
      <gateway>${WAN_GW}</gateway>
      <weight>1</weight>
      <ipprotocol>inet</ipprotocol>
      <defaultgw>1</defaultgw>
    </gateway_item>
  </gateways>
  <dhcpd>
    <lan>
      <enable>1</enable>
      <range>
        <from>10.0.33.100</from>
        <to>10.0.33.200</to>
      </range>
    </lan>
  </dhcpd>
  <nat>
    <outbound>
      <mode>automatic</mode>
    </outbound>
  </nat>
  <filter>
    <rule>
      <type>pass</type>
      <interface>lan</interface>
      <ipprotocol>inet</ipprotocol>
      <protocol>any</protocol>
      <source><any/></source>
      <destination><any/></destination>
      <descr>Default LAN allow-all</descr>
    </rule>
  </filter>
</opnsense>
XMLEOF
}

create_config_iso() {
    local vmid=$1
    local cfg_dir cfg_iso iso_name
    cfg_dir=$(mktemp -d)
    iso_name="opnsense-conf-${vmid}.iso"
    cfg_iso="${ISO_STORE}/${iso_name}"

    echo "🔧 Generating config.xml..."
    mkdir -p "${cfg_dir}/conf"
    generate_config_xml > "${cfg_dir}/conf/config.xml"

    # ISO label must be exactly "OPNsense_Config" for auto-import on first boot
    if command -v genisoimage &>/dev/null; then
        genisoimage -V OPNsense_Config -r -quiet -o "$cfg_iso" "${cfg_dir}"
    elif command -v mkisofs &>/dev/null; then
        mkisofs    -V OPNsense_Config -r -quiet -o "$cfg_iso" "${cfg_dir}"
    else
        echo "⚠️  genisoimage/mkisofs not found. Install with: apt install genisoimage"
        echo "    Config ISO skipped; configure OPNsense manually via web UI."
        rm -rf "${cfg_dir}"
        return 1
    fi

    qm set $vmid --ide2 "local:iso/${iso_name},media=cdrom"
    rm -rf "${cfg_dir}"
    echo "✅ Config ISO attached (ide2): ${iso_name}"
    echo "   OPNsense reads this on first boot, then renames it (won't re-apply)."
    echo "   After first boot: eject with: qm set $vmid --ide2 none,media=cdrom"
}

create_vm() {
    if vm_exists "$VMID"; then
        echo "ℹ️  VM $VMID ($NAME) already exists, skipping."
        return
    fi

    if ! vm_exists "$TEMPLATE_ID"; then
        echo "⚠️  Template $TEMPLATE_ID not found. Run: $0 template"
        exit 1
    fi

    echo "🔧 Cloning template $TEMPLATE_ID → VM $VMID ($NAME)..."
    qm clone $TEMPLATE_ID $VMID --name "$NAME" --full 2>&1 | grep -v '%'

    qm set $VMID --memory $RAM_MB --cores $CORES

    # Grow disk from nano image size (~1 GB) to target
    # OPNsense/FreeBSD will expand the partition on first boot via growfs
    qm resize $VMID scsi0 $DISK_SIZE

    # Explicit NIC assignment (inherited from template; set explicitly for clarity)
    qm set $VMID --net0 virtio,bridge=$WAN_BRIDGE   # vtnet0 = WAN
    qm set $VMID --net1 virtio,bridge=$LAN_BRIDGE   # vtnet1 = LAN

    # Inject first-boot config (best-effort; manual config always works as fallback)
    create_config_iso $VMID || true

    echo ""
    echo "✅ VM $VMID ($NAME) ready."
    echo ""
    printf "  %-8s %-10s %-22s %s\n" "NIC" "IF" "IP" "BRIDGE"
    printf "  %-8s %-10s %-22s %s\n" "net0" "vtnet0/WAN" "${WAN_IP}/${WAN_MASK} gw ${WAN_GW}" "$WAN_BRIDGE"
    printf "  %-8s %-10s %-22s %s\n" "net1" "vtnet1/LAN" "${LAN_IP}/${LAN_MASK}" "$LAN_BRIDGE"
}

start_vm() {
    if [[ $(qm status $VMID 2>/dev/null | awk '{print $2}') == "running" ]]; then
        echo "ℹ️  VM $VMID already running."
    else
        qm start $VMID
        echo "✅ VM $VMID started."
    fi
}

destroy_vm() {
    if vm_exists "$VMID"; then
        echo "🚧 Destroying VM $VMID..."
        qm stop $VMID --skiplock 2>/dev/null || true
        sleep 2
        qm destroy $VMID --purge
        echo "✅ VM $VMID destroyed."
    else
        echo "ℹ️  VM $VMID not found."
    fi
}

destroy_template() {
    if vm_exists "$TEMPLATE_ID"; then
        echo "🚧 Destroying template $TEMPLATE_ID..."
        qm destroy $TEMPLATE_ID --purge
        echo "✅ Template $TEMPLATE_ID destroyed."
    else
        echo "ℹ️  Template $TEMPLATE_ID not found."
    fi
}

wait_for_web() {
    local ip=$1 max=30
    echo -n "Waiting for OPNsense web UI at https://${ip}..."
    for ((i=0; i<max; i++)); do
        if curl -sk --max-time 2 "https://${ip}" &>/dev/null; then
            echo " ready."
            return 0
        fi
        echo -n "."
        sleep 3
    done
    echo " ⚠️  timeout (still booting — check: qm terminal $VMID)"
    return 1
}

# --- Main ---
case "${1:-help}" in
    template)
        create_template
        ;;

    create)
        create_vm
        start_vm

        echo ""
        echo "ℹ️  Waiting for first boot (growfs + config import takes ~30s)..."
        sleep 30
        wait_for_web "$LAN_IP" || true

        echo ""
        echo "ℹ️  Access (from vmbr1 / k0s network):"
        echo "    Web UI:  https://${LAN_IP}     root / ${ROOT_PASSWORD}"
        echo "    Serial:  qm terminal ${VMID}"
        echo ""
        echo "ℹ️  After first boot, eject config ISO:"
        echo "    qm set ${VMID} --ide2 none,media=cdrom"
        ;;

    start)
        start_vm
        ;;

    destroy)
        destroy_vm
        ;;

    destroy-all)
        destroy_vm
        destroy_template
        ;;

    status)
        printf "%-20s %-8s %-10s\n" "NAME" "VMID" "STATE"
        TMPL_STATE=$(qm status $TEMPLATE_ID 2>/dev/null | awk '{print $2}' || echo "missing")
        VM_STATE=$(qm status $VMID 2>/dev/null | awk '{print $2}' || echo "missing")
        printf "%-20s %-8s %-10s\n" "opnsense-tmpl" "$TEMPLATE_ID" "$TMPL_STATE"
        printf "%-20s %-8s %-10s\n" "$NAME" "$VMID" "$VM_STATE"
        ;;

    *)
        echo "ℹ️  Usage: $0 {template|create|start|status|destroy|destroy-all}"
        exit 1
        ;;
esac
