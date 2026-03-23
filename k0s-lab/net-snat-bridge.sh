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

# --- Add bridge directly to main interfaces file, /etc/network/interfaces,
#     *not* to drop-in under /etc/network/interfaces.d/, is the PVE way.
add_bridge() {
    if grep -q "^iface $BRIDGE" /etc/network/interfaces; then
        echo "ℹ️ Bridge $BRIDGE already configured."
        return
    fi

    echo "🚧 Adding bridge '$BRIDGE' directly to /etc/network/interfaces"
    # Source NAT (SNAT/MASQUERADE) 
    # https://pve.proxmox.com/wiki/Network_Configuration#sysadmin_network_masquerading 
    # - iptables rule translates private IPs to external interface IP.
    # - This provides ONE-WAY CONNECTIVITY:
    #   - Internal machines (on this NAT subnet) may initiate outbound connections.
    #   - External machines *cannot* directly initiate connections inbound (without port forwarding).
    tee -a /etc/network/interfaces <<-EOF
	
	# BEGIN bridge $BRIDGE
	auto $BRIDGE
	iface $BRIDGE inet static
	# SNAT Bridge for K0s cluster
	    address $GATEWAY_IP/24
	    bridge-ports none
	    bridge-stp off
	    bridge-fd 0
	    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
	    post-up   iptables -t nat -A POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE
	    post-down iptables -t nat -D POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE
	
	# END bridge $BRIDGE
	EOF

    echo "ℹ️ Bringing up bridge '$BRIDGE'..."
    ifup $BRIDGE
}

# --- IP forwarding ---
persist_forwarding() {
    # Check if it's already active and uncommented
    if grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "ℹ️ IP forwarding already persistent."
    elif grep -q "#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "🚧 Uncommenting existing IP forwarding..."
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
        echo "🚧 Adding net.ipv4.ip_forward=1 to sysctl.conf..."
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi

    # Apply changes immediately
    sysctl -w net.ipv4.ip_forward=1
}
remove_forwarding() {
    echo "🚧 Disabling IP forwarding..."
    # Remove the line whether it's commented or not
    sed -i '/net.ipv4.ip_forward=1/d' /etc/sysctl.conf
    
    # Force the kernel to turn it off now
    sysctl -w net.ipv4.ip_forward=0
}

apply_changes(){
    ifreload -a
    sysctl --system
    #systemctl restart networking
}

# --- Main ---
case "${1:-create}" in
    create)
        add_bridge
        persist_forwarding
        apply_changes
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
        echo "🚧 Removing $BRIDGE, MASQUERADE and IP Forwarding ..."
        ifdown $BRIDGE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE 2>/dev/null || true
        sed -i "/^# BEGIN bridge $BRIDGE/,/^# END bridge $BRIDGE/d" /etc/network/interfaces
        remove_forwarding
        apply_changes
        echo "✅ Bridge and such removed."
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|status|destroy}"
        exit 1
        ;;
esac