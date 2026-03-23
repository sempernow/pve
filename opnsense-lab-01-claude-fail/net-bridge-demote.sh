#!/usr/bin/env bash
set -e

echo "⚠️ DEPRICATED : Use net-l2-bridge.sh"
exit 0


# === net-bridge-demote.sh - Transition vmbr1 from SNAT to plain L2 ===
# Removes the host's 10.0.33.1 address and iptables MASQUERADE from vmbr1,
# so OPNsense becomes the sole gateway for 10.0.33.0/24.
#
# Prerequisite: OPNsense VM must be running with LAN interface on vmbr1
#               configured as 10.0.33.1/24 BEFORE running this script.

BRIDGE="vmbr1"
SUBNET="10.0.33.0/24"
GATEWAY_IP="10.0.33.1"
EXTERNAL_IFACE="vmbr0"
INTERFACES_FILE="/etc/network/interfaces"

demote_bridge() {
    echo "🚧 Demoting $BRIDGE from SNAT gateway to plain L2 bridge..."

    # Remove iptables MASQUERADE rule (safe if already absent)
    iptables -t nat -D POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE 2>/dev/null || true

    # Remove IP address from bridge (OPNsense now owns 10.0.33.1)
    ip addr del ${GATEWAY_IP}/24 dev $BRIDGE 2>/dev/null || true

    # Rewrite vmbr1 stanza in interfaces file
    # Replace the SNAT block with a minimal L2-only config
    if grep -q "iface $BRIDGE inet static" "$INTERFACES_FILE"; then
        echo "🚧 Rewriting $BRIDGE config in $INTERFACES_FILE..."

        # Back up first
        cp "$INTERFACES_FILE" "${INTERFACES_FILE}.bak.snat"

        # Use sed to replace the iface stanza
        # Match from "iface vmbr1 inet static" through the post-down line
        sed -i "/iface $BRIDGE inet static/,/post-down.*MASQUERADE/{
            /iface $BRIDGE/c\\iface $BRIDGE inet manual
            /address/d
            /post-up.*ip_forward/d
            /post-up.*MASQUERADE/d
            /post-down.*MASQUERADE/d
            /SNAT Bridge/d
        }" "$INTERFACES_FILE"

        echo "✅ $INTERFACES_FILE updated. Backup: ${INTERFACES_FILE}.bak.snat"
    else
        echo "ℹ️ $BRIDGE already configured as manual or not found."
    fi

    echo ""
    echo "✅ Bridge $BRIDGE demoted to plain L2."
    echo "   OPNsense now owns ${GATEWAY_IP}/24 on $BRIDGE."
    echo ""
    echo "ℹ️ Verify: ip addr show $BRIDGE"
    echo "ℹ️ Verify: iptables -t nat -L POSTROUTING -n -v"
}

restore_bridge() {
    echo "🚧 Restoring $BRIDGE SNAT configuration..."

    if [[ -f "${INTERFACES_FILE}.bak.snat" ]]; then
        cp "${INTERFACES_FILE}.bak.snat" "$INTERFACES_FILE"
        echo "✅ Restored $INTERFACES_FILE from backup."
    else
        echo "⚠️ No backup found. Manually restoring..."
        # Rewrite the stanza back to SNAT mode
        sed -i "/iface $BRIDGE inet manual/c\\iface $BRIDGE inet static" "$INTERFACES_FILE"
        sed -i "/iface $BRIDGE inet static/a\\
    # SNAT Bridge for K0s cluster\\
    address ${GATEWAY_IP}/24\\
    bridge-ports none\\
    bridge-stp off\\
    bridge-fd 0\\
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward\\
    post-up   iptables -t nat -A POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE\\
    post-down iptables -t nat -D POSTROUTING -s $SUBNET -o $EXTERNAL_IFACE -j MASQUERADE" "$INTERFACES_FILE"
    fi

    echo "🚧 Reapplying bridge config..."
    ifdown $BRIDGE 2>/dev/null || true
    ifup $BRIDGE

    echo ""
    echo "✅ Bridge $BRIDGE restored to SNAT mode."
    echo "   Host owns ${GATEWAY_IP}/24 with MASQUERADE."
}

# --- Main ---
case "${1:-create}" in
    create)
        demote_bridge
        ;;
    status)
        echo "ℹ️ Bridge $BRIDGE:"
        ip addr show $BRIDGE 2>/dev/null || echo "  $BRIDGE not found"
        echo ""
        echo "ℹ️ NAT rules:"
        iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E "$SUBNET|Chain" || echo "  No NAT rules"
        echo ""
        echo "ℹ️ Backup exists:"
        ls -la "${INTERFACES_FILE}.bak.snat" 2>/dev/null || echo "  No backup"
        ;;
    destroy)
        restore_bridge
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|status|destroy}"
        echo ""
        echo "  create  - Demote vmbr1 to plain L2 (OPNsense takes over)"
        echo "  destroy - Restore vmbr1 SNAT (host-managed NAT)"
        echo "  status  - Show current bridge and NAT state"
        exit 1
        ;;
esac
