#!/usr/bin/env bash
set -e

# === k0s-cluster-vms.sh - K0s cluster VMs on isolated network ===

# --- Config ---
TEMPLATE_ID=9000
STORAGE="local-lvm"
BRIDGE="vmbr1"
GATEWAY="10.0.33.1"
SSH_KEY_PUB=~/.ssh/id_ed25519.pub
CI_USER="k0s"

# Node definitions: VMID:NAME:IP:CORES:RAM_MB:DISK_ADD
NODES=(
    "110:k0s-ctrl:10.0.33.11:2:4096:+29G"
    "111:k0s-w1:10.0.33.12:4:12288:+29G"
    "112:k0s-w2:10.0.33.13:4:12288:+29G"
)

# --- Functions ---
vm_exists() { qm status "$1" &>/dev/null; }

parse_node() {
    IFS=':' read -r VMID NAME IP CORES RAM DISK <<< "$1"
}

create_vm() {
    local vmid=$1 name=$2 ip=$3 cores=$4 ram=$5 disk=$6

    if vm_exists "$vmid"; then
        echo "ℹ️ VM $vmid ($name) already exists, skipping."
        return
    fi

    echo "Creating $name ($vmid) at $ip..."
    qm clone $TEMPLATE_ID $vmid --name "$name" --full 2>&1 |grep -v '%'
    qm set $vmid --memory $ram --cores $cores
    qm set $vmid --net0 virtio,bridge=$BRIDGE
    qm set $vmid --ciuser $CI_USER --sshkeys $SSH_KEY_PUB
    qm set $vmid --ipconfig0 ip=$ip/24,gw=$GATEWAY
    qm set $vmid --nameserver 8.8.8.8
    qm resize $vmid scsi0 $disk
}

start_vm() {
    local vmid=$1
    if [[ $(qm status $vmid 2>/dev/null | awk '{print $2}') == "running" ]]; then
        echo "ℹ️ VM $vmid already running."
    else
        qm start $vmid
        echo "✅ VM $vmid started."
    fi
}

destroy_vm() {
    local vmid=$1
    if vm_exists "$vmid"; then
        echo "🚧 Destroying VM $vmid..."
        qm stop $vmid --skiplock 2>/dev/null || true
        sleep 2
        qm destroy $vmid --purge
    fi
}

wait_for_ssh() {
    local ip=$1 max=30
    echo -n "Waiting for SSH at $ip..."
    for ((i=0; i<max; i++)); do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 $CI_USER@$ip "true" 2>/dev/null; then
            echo "ready."
            return 0
        fi
        echo -n "."
        sleep 2
    done
    echo "⚠️ timeout."
    return 1
}

# --- Main ---
case "${1:-create}" in
    create)
        for node in "${NODES[@]}"; do
            parse_node "$node"
            create_vm $VMID $NAME $IP $CORES $RAM $DISK
            start_vm $VMID
        done

        echo ""
        echo "✅ Cluster VMs created. Waiting for boot..."
        sleep 10

        echo ""
        echo "ℹ️ Node status:"
        printf "%-12s %-8s %-15s %s\n" "NAME" "VMID" "IP" "SSH"
        for node in "${NODES[@]}"; do
            parse_node "$node"
            if wait_for_ssh $IP; then
                STATUS="✓"
            else
                STATUS="✗"
            fi
            printf "%-12s %-8s %-15s %s\n" "$NAME" "$VMID" "$IP" "$STATUS"
        done

        echo ""
        echo "ℹ️ SSH commands:"
        for node in "${NODES[@]}"; do
            parse_node "$node"
            echo "  ssh $CI_USER@$IP  # $NAME"
        done
        ;;

    destroy)
        for node in "${NODES[@]}"; do
            parse_node "$node"
            destroy_vm $VMID
        done
        echo "✅ Cluster destroyed."
        ;;

    status)
        printf "%-12s %-8s %-10s %-15s\n" "NAME" "VMID" "STATE" "IP"
        for node in "${NODES[@]}"; do
            parse_node "$node"
            STATE=$(qm status $VMID 2>/dev/null | awk '{print $2}' || echo "missing")
            printf "%-12s %-8s %-10s %-15s\n" "$NAME" "$VMID" "$STATE" "$IP"
        done
        ;;

    *)
        echo "ℹ️ Usage: $0 {create|destroy|status}"
        exit 1
        ;;
esac