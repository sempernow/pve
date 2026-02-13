#!/usr/bin/env bash
set -e

# === k0s-flat-vm.sh - Test VM on flat network (vmbr0) ===

# --- Config ---
TEMPLATE_ID=9000
VMID=100
NAME="k0s-test"
STORAGE="local-lvm"

CI_USER="k0s"
CI_PASS="changeme"
DISK_SIZE="+29G"
MEMORY=4096
CORES=2
BRIDGE="vmbr0"
SSH_KEY_PUB=~/.ssh/id_ed25519.pub

# --- Functions ---
vm_exists() { qm status "$1" &>/dev/null; }

create_vm() {
    local vmid=$1 name=$2

    if vm_exists "$vmid"; then
        echo "VM $vmid already exists."
        return
    fi

    echo "Cloning $name ($vmid)..."
    qm clone $TEMPLATE_ID $vmid --name "$name" --full 2>&1 |grep -v '%'
    qm set $vmid --memory $MEMORY --cores $CORES
    qm set $vmid --net0 virtio,bridge=$BRIDGE
    #qm set $vmid --ciuser $CI_USER --cipassword $CI_PASS --ipconfig0 ip=dhcp
    qm set $vmid --ciuser $CI_USER --sshkeys $SSH_KEY_PUB --ipconfig0 ip=dhcp
    qm resize $vmid scsi0 $DISK_SIZE

}

start_vm() {
    local vmid=$1
    if [[ $(qm status $vmid 2>/dev/null | awk '{print $2}') == "running" ]]; then
        echo "VM $vmid already running."
    else
        qm start $vmid
        echo "VM $vmid started."
    fi
}

get_ip() {
    local vmid=$1
    sleep 5
    qm guest cmd $vmid network-get-interfaces 2>/dev/null \
        | grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -v '^127\.' | head -1 || echo "pending..."
}

destroy_vm() {
    local vmid=$1
    if vm_exists "$vmid"; then
        echo "Destroying VM $vmid..."
        qm stop $vmid --skiplock 2>/dev/null || true
        sleep 2
        qm destroy $vmid --purge
        echo "VM $vmid destroyed."
    else
        echo "VM $vmid does not exist."
    fi
}

# --- Main ---
case "${1:-create}" in
    create)
        create_vm $VMID $NAME
        start_vm $VMID
        echo "Waiting for IP..."
        IP=$(get_ip $VMID)
        echo "$NAME ($VMID): $IP"
        echo ""
        echo "SSH: ssh $CI_USER@$IP"
        ;;
    destroy)
        destroy_vm $VMID
        ;;
    status)
        qm status $VMID
        IP=$(get_ip $VMID)
        echo "IP: $IP"
        ;;
    *)
        echo "Usage: $0 {create|destroy|status}"
        exit 1
        ;;
esac
