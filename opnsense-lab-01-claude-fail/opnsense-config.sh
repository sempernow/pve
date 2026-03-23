#!/usr/bin/env bash
set -e

# === opnsense-config.sh - Configure OPNsense via REST API ===
# Configures interfaces, DHCP, DNS (Unbound), firewall, and NAT
# after OPNsense has been installed and interfaces assigned.

# --- Config ---
OPNSENSE_WAN_IP="192.168.28.182"
OPNSENSE_LAN_IP="10.0.33.1"
OPNSENSE_LAN_CIDR="10.0.33.0/24"

API_BASE="https://${OPNSENSE_WAN_IP}/api"
API_KEY=""     # Set after creating API key in OPNsense GUI
API_SECRET=""  # or source from a credentials file

CREDS_FILE="$(dirname "$0")/.api_creds"

# k0s node definitions: NAME:IP
K0S_NODES=(
    "k0s-ctrl:10.0.33.11"
    "k0s-w1:10.0.33.12"
    "k0s-w2:10.0.33.13"
)

# --- Load API credentials ---
load_creds() {
    if [[ -f "$CREDS_FILE" ]]; then
        source "$CREDS_FILE"
    fi

    if [[ -z "$API_KEY" || -z "$API_SECRET" ]]; then
        echo "⚠️ API credentials not configured."
        echo ""
        echo "ℹ️ Create an API key in OPNsense:"
        echo "  1. Login to https://${OPNSENSE_WAN_IP}"
        echo "  2. System → Access → Users → Edit 'root'"
        echo "  3. Scroll to 'API keys' → Create"
        echo "  4. Save the key and secret to: $CREDS_FILE"
        echo ""
        echo "  Format of $CREDS_FILE:"
        echo '  API_KEY="your-key-here"'
        echo '  API_SECRET="your-secret-here"'
        exit 1
    fi
}

# --- API helper ---
api() {
    local method="$1" endpoint="$2" data="$3"
    curl -sk -X "$method" \
        -u "${API_KEY}:${API_SECRET}" \
        -H "Content-Type: application/json" \
        ${data:+-d "$data"} \
        "${API_BASE}${endpoint}"
}

# --- Configure DHCP on LAN ---
configure_dhcp() {
    echo "🚧 Configuring DHCP on LAN..."

    # Enable DHCP on LAN with range avoiding k0s static IPs (.11-.13)
    api POST /dhcpv4/settings/set '{
        "dhcpd": {
            "lan": {
                "enable": "1",
                "range": {
                    "from": "10.0.33.100",
                    "to": "10.0.33.200"
                },
                "gateway": "10.0.33.1",
                "dns": "10.0.33.1"
            }
        }
    }'

    echo "✅ DHCP configured: 10.0.33.100-200"
}

# --- Configure DNS (Unbound) ---
configure_dns() {
    echo "🚧 Configuring Unbound DNS..."

    # Enable forwarding mode (forward to upstream resolvers)
    api POST /unbound/settings/set '{
        "unbound": {
            "general": {
                "enabled": "1",
                "port": "53",
                "dnssec": "1"
            },
            "forwarding": {
                "enabled": "1"
            }
        }
    }'

    # Add upstream forwarders
    for dns in "8.8.8.8" "8.8.4.4"; do
        echo "  Adding forwarder: $dns"
        api POST /unbound/settings/addForward "{
            \"forward\": {
                \"enabled\": \"1\",
                \"server\": \"$dns\"
            }
        }"
    done

    # Add local host overrides for k0s nodes
    for node in "${K0S_NODES[@]}"; do
        IFS=':' read -r name ip <<< "$node"
        echo "  Adding host override: ${name}.k0s.local → $ip"
        api POST /unbound/settings/addHostOverride "{
            \"host\": {
                \"enabled\": \"1\",
                \"hostname\": \"$name\",
                \"domain\": \"k0s.local\",
                \"server\": \"$ip\",
                \"description\": \"k0s cluster node\"
            }
        }"
    done

    # Apply changes
    api POST /unbound/service/reconfigure

    echo "✅ DNS configured with forwarding and local overrides."
}

# --- Configure firewall rules ---
configure_firewall() {
    echo "🚧 Configuring firewall rules..."

    # LAN → WAN: allow all (OPNsense default, verify only)
    echo "  ℹ️ LAN → WAN allow-all is the OPNsense default."

    # Port forward: WAN:6443 → k0s-ctrl:6443 (Kubernetes API)
    echo "  Adding port forward: WAN:6443 → 10.0.33.11:6443"
    api POST /firewall/nat/addRule "{
        \"rule\": {
            \"enabled\": \"1\",
            \"interface\": \"wan\",
            \"protocol\": \"TCP\",
            \"src\": \"any\",
            \"srcport\": \"any\",
            \"dst\": \"wanip\",
            \"dstport\": \"6443\",
            \"target\": \"10.0.33.11\",
            \"targetport\": \"6443\",
            \"description\": \"k0s API server\"
        }
    }"

    # Port forward: WAN:30000-32767 → pass-through for NodePort services
    echo "  Adding port forward: WAN:30000-32767 (NodePort range)"
    api POST /firewall/nat/addRule "{
        \"rule\": {
            \"enabled\": \"1\",
            \"interface\": \"wan\",
            \"protocol\": \"TCP\",
            \"src\": \"any\",
            \"srcport\": \"any\",
            \"dst\": \"wanip\",
            \"dstport\": \"30000-32767\",
            \"target\": \"10.0.33.0/24\",
            \"targetport\": \"30000-32767\",
            \"description\": \"k0s NodePort services\"
        }
    }"

    # Apply firewall changes
    api POST /firewall/filter/apply

    echo "✅ Firewall rules configured."
}

# --- Show current config ---
show_status() {
    load_creds

    echo "ℹ️ OPNsense API status:"
    echo ""

    echo "--- Interfaces ---"
    api GET /diagnostics/interface/getInterfaceNames 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (API unreachable)"
    echo ""

    echo "--- DHCP Leases ---"
    api GET /dhcpv4/leases/searchLease 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (unavailable)"
    echo ""

    echo "--- Unbound Status ---"
    api GET /unbound/service/status 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (unavailable)"
}

# --- Main ---
case "${1:-create}" in
    create)
        load_creds
        configure_dhcp
        configure_dns
        configure_firewall
        echo ""
        echo "✅ OPNsense configuration complete."
        echo ""
        echo "ℹ️ Services:"
        echo "  DHCP:     10.0.33.100-200 on LAN"
        echo "  DNS:      Unbound at 10.0.33.1 (forwarding to 8.8.8.8, 8.8.4.4)"
        echo "  Firewall: LAN→WAN allow, WAN DNAT 6443→k0s-ctrl"
        echo "  NAT:      Outbound auto-masquerade"
        echo ""
        echo "ℹ️ DNS local overrides:"
        for node in "${K0S_NODES[@]}"; do
            IFS=':' read -r name ip <<< "$node"
            echo "  ${name}.k0s.local → $ip"
        done
        ;;
    status)
        show_status
        ;;
    destroy)
        echo "ℹ️ To reset OPNsense config, use the web UI:"
        echo "  https://${OPNSENSE_WAN_IP}"
        echo "  System → Configuration → Defaults"
        ;;
    *)
        echo "ℹ️ Usage: $0 {create|status|destroy}"
        echo ""
        echo "  Prerequisites:"
        echo "    1. OPNsense installed and interfaces assigned"
        echo "    2. API key created and saved to $CREDS_FILE"
        exit 1
        ;;
esac
