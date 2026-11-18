#!/bin/bash
# Déploie vm-test de zéro avec cloud-init (seed ISO généré par cloud-localds)
set -e
IMG=/var/lib/libvirt/images
DIR=$(cd "$(dirname "$0")/.." && pwd)

# 1. Fichiers cloud-init
cat > "$DIR/cloud-init/user-data" << EOF
#cloud-config
hostname: vm-test
users:
  - name: labadmin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $(cat ~/.ssh/id_ed25519.pub)
EOF

cat > "$DIR/cloud-init/meta-data" << EOF
instance-id: vm-test-$(date +%s)
local-hostname: vm-test
EOF

# 2. cleanup de l'ancienne VM
virsh destroy vm-test 2>/dev/null || true
virsh undefine vm-test 2>/dev/null || true
sudo rm -f $IMG/vm-test.qcow2 $IMG/vm-test-seed.iso

# 3. Disque + ISO cloud-init
sudo qemu-img create -f qcow2 -F qcow2 -b $IMG/jammy-server-cloudimg-amd64.img $IMG/vm-test.qcow2 10G
sudo cloud-localds $IMG/vm-test-seed.iso "$DIR/cloud-init/user-data" "$DIR/cloud-init/meta-data"

# 4. Création de la VM
virt-install --name vm-test --memory 2048 --vcpus 2 \
  --disk $IMG/vm-test.qcow2 \
  --disk $IMG/vm-test-seed.iso,device=cdrom \
  --import \
  --network network=lab-isolated \
  --os-variant ubuntu22.04 --graphics none --noautoconsole

echo "VM en cours de démarrage, attendez ~1 min puis : virsh net-dhcp-leases lab-isolated"
