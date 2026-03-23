#!/usr/bin/env bash
# Download cloud image
cd /var/lib/vz/template/iso
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2

# Create a VM to become the template
qm create 9000 --name debian12-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0

# Import the disk to local-lvm
qm importdisk 9000 debian-12-generic-amd64.qcow2 local-lvm

# Attach the disk
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0

# Add cloud-init drive
qm set 9000 --ide2 local-lvm:cloudinit

# Set boot order
qm set 9000 --boot c --bootdisk scsi0

# Enable serial console (cloud images expect this)
qm set 9000 --serial0 socket --vga serial0

# Convert to template
qm template 9000
