#!/usr/bin/env bash
set -e

# === net-l2-bridge.sh - Add vmbr1 ===
BRIDGE="vmbr1"          # Bridge device; default gateway for VMs/containers.
SUBNET="10.0.33.0/24"   # Isolated, private (RFC-1918) subnet CIDR.

# OPNsense public (WAN) address : Unstable : By DHCP of upstream router
opnIP="192.168.28.182"

# --- Add bridge directly to main interfaces file, /etc/network/interfaces,
#     *not* to drop-in under /etc/network/interfaces.d/, is the PVE way.
add_bridge() {
    if grep -q "^iface $BRIDGE" /etc/network/interfaces; then
        echo "ℹ️ Bridge $BRIDGE already configured."
        return
    fi

    echo "🚧 Adding bridge '$BRIDGE' directly to /etc/network/interfaces"
    tee -a /etc/network/interfaces <<-EOF
	
	# BEGIN bridge $BRIDGE
	auto $BRIDGE
	iface $BRIDGE inet manual
	# L2 Bridge for K0s cluster
	    bridge-ports none
	    bridge-stp off
	    bridge-fd 0
        post-up ip route add $SUBNET via $opnIP
        pre-down ip route del $SUBNET via $opnIP

	# END bridge $BRIDGE
	EOF

    echo "ℹ️ Bringing up bridge '$BRIDGE'..."
    ifup $BRIDGE
}

apply_changes(){
    ifreload -a
    #sysctl --system
    #systemctl restart networking
}

# --- Main ---
case "${1:-create}" in
    create)
        add_bridge
        apply_changes
        echo ""
        echo "✅ Network setup complete:"
        echo "  Bridge: $BRIDGE"
        ;;
    status)
        ip addr show $BRIDGE 2>/dev/null || echo "$BRIDGE not found"
        ;;
    destroy)
        echo "🚧 Removing $BRIDGE ..."
        ifdown $BRIDGE 2>/dev/null || true
        sed -i "/^# BEGIN bridge $BRIDGE/,/^# END bridge $BRIDGE/d" /etc/network/interfaces
        apply_changes
        echo "✅ Bridge removed."
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|status|destroy}"
        exit 1
        ;;
esac