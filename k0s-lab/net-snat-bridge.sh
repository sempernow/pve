#!/usr/bin/env bash
set -e

# === net-snat-bridge.sh - Create isolated SNAT Gateway network ===
# - vmbr1 is a Linux bridge with bridge_ports none (no physical uplink — internal only).
# - iptables MASQUERADE on egress to vmbr0 does the SNAT.
# - The bridge (vmbr1) itself acts as gateway, packet-forwarding routes between bridges (vmbr1, vmbr0).

BRIDGE="vmbr1"          # Bridge device; default gateway for VMs/containers.
SUBNET="10.0.33.0/24"   # Isolated, private (RFC-1918) subnet CIDR.
GATEWAY_IP="10.0.33.1"  # Outbound connectivity via IP masquerading.
EXTERNAL_IFACE="vmbr0"

# --- Add bridge to /etc/network/interfaces ---
add_bridge() {
    if grep -q "^iface $BRIDGE" /etc/network/interfaces; then
        echo "ℹ️ Bridge $BRIDGE already configured."
        return
    fi

    echo "🚧 Adding bridge '$BRIDGE' to /etc/network/interfaces..."
    # Source NAT (SNAT/MASQUERADE) 
    # - iptables rule translates private IPs to external interface IP.
    # - This provides ONE-WAY CONNECTIVITY:
    #   - Internal machines (on this NAT subnet) may initiate outbound connections.
    #   - External machines *cannot* directly initiate connections inbound (without port forwarding).
    tee -a /etc/network/interfaces <<-EOF
	# BEGIN bridge $BRIDGE
	auto $BRIDGE
	iface $BRIDGE inet static
	    # NAT bridge for K0s cluster
	    address $GATEWAY_IP
	    netmask 255.255.255.0
	    bridge_ports none
	    bridge_stp off
	    bridge_fd 0
	    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
	    post-up   iptables -t nat -A POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE
	    post-down iptables -t nat -D POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE
	    
	# END bridge $BRIDGE
	EOF

    echo "ℹ️ Bringing up bridge '$BRIDGE'..."
    ifup $BRIDGE
}

# --- Persist IP forwarding ---
persist_forwarding() {
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "ℹ️ IP forwarding already persistent."
        return
    fi

    echo "🚧 Enabling persistent IP forwarding..."
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
}

# --- Main ---
case "${1:-create}" in
    create)
        add_bridge
        persist_forwarding
        echo ""
        echo "✅ Network setup complete:"
        echo "  Bridge: $BRIDGE"
        echo "  Gateway: $GATEWAY_IP"
        echo "  Subnet: $SUBNET"
        echo "  NAT: $SUBNET -> $EXTERNAL_IFACE"
        ;;
    status)
        ip addr show $BRIDGE 2>/dev/null || echo "$BRIDGE not found"
        echo ""
        echo "ℹ️ NAT rules:"
        iptables -t nat -L POSTROUTING -n -v | grep -E "$SUBNET|Chain"
        echo ""
        echo "ℹ️ IP forwarding:"
        cat /proc/sys/net/ipv4/ip_forward
        ;;
    destroy)
        echo "🚧 Removing $BRIDGE..."
        ifdown $BRIDGE 2>/dev/null || true
        sed -i "/^# BEGIN bridge $BRIDGE/,/^# END bridge $BRIDGE/d" /etc/network/interfaces
        echo "✅ Bridge removed. NAT rules cleared on ifdown."
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|status|destroy}"
        exit 1
        ;;
esac