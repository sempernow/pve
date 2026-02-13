#!/usr/bin/env bash
set -e

# === debian12-template-v0.0.2.sh - Create Debian 12 cloud-init template ===

# --- Config ---
TEMPLATE_ID=9000
TEMPLATE_NAME="debian12-template"
IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
IMAGE_FILE="/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2"
STORAGE="local-lvm"
SNIPPET_STORAGE="local"
SNIPPET_DIR="/var/lib/vz/snippets"

# --- Enable snippets on local storage ---
echo "🚧 Enabling snippets content type on $SNIPPET_STORAGE..."
pvesm set $SNIPPET_STORAGE --content iso,vztmpl,snippets

# --- Create cloud-init snippet ---
echo "🚧 Creating cloud-init snippet..."
mkdir -p "$SNIPPET_DIR"

cat > "$SNIPPET_DIR/k0s-base.yaml" << 'EOF'
#cloud-config
packages:
  - qemu-guest-agent
  - curl
  - gnupg
  - apt-transport-https
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

# --- Remove existing template if present ---
if qm status $TEMPLATE_ID &>/dev/null; then
    echo "🚧 Removing existing template $TEMPLATE_ID..."
    qm destroy $TEMPLATE_ID --purge 2>/dev/null || true
fi

# --- Download cloud image ---
if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "⚡ Downloading cloud image..."
    wget -q --show-progress -O "$IMAGE_FILE" "$IMAGE_URL"
else
    echo "ℹ️ Cloud image already exists, skipping download."
fi

# --- Create template VM ---
echo "🚧 Creating template VM $TEMPLATE_ID..."
qm create $TEMPLATE_ID --name $TEMPLATE_NAME \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=vmbr0 \
    --ostype l26 \
    --agent enabled=1

echo "🚧 Importing disk..."
qm importdisk $TEMPLATE_ID "$IMAGE_FILE" $STORAGE
qm set $TEMPLATE_ID --scsihw virtio-scsi-pci --scsi0 $STORAGE:vm-$TEMPLATE_ID-disk-0

echo "🚧 Configuring cloud-init..."
qm set $TEMPLATE_ID --ide2 $STORAGE:cloudinit
qm set $TEMPLATE_ID --cicustom "vendor=$SNIPPET_STORAGE:snippets/k0s-base.yaml"

echo "🚧 Setting boot options..."
qm set $TEMPLATE_ID --boot c --bootdisk scsi0
qm set $TEMPLATE_ID --serial0 socket --vga serial0

echo "🚧 Converting to template..."
qm template $TEMPLATE_ID

# --- Cleanup ---
rm -f "$IMAGE_FILE"

echo ""
echo "✅ Template $TEMPLATE_ID ($TEMPLATE_NAME) created successfully."
echo "ℹ️ Cloud-init snippet: $SNIPPET_DIR/k0s-base.yaml"
echo ""
echo "ℹ️ Clone with: qm clone $TEMPLATE_ID <vmid> --name <name> --full"

