#!/bin/bash
#
#							[_SLM_SCRIPTS_]
#
# tool de recover de VMs compromises : isolement -> preuve -> restauration -> vérif
# Usage : ./remediate.sh <vm> <snapshot_sain>
set -e
VM=${1:-msf2}
SNAP=${2:-clean}
DATE=$(date +%Y%m%d-%H%M%S)
MACS=$(virsh domiflist "$VM" | awk 'NR>2 && $5 {print $5}')

echo "[1/4] isolement réseau de $VM"
for MAC in $MACS; do virsh domif-setlink "$VM" "$MAC" down; done

echo "[2/4] conservation de l'état compromis (preuve pour analyse)"
virsh snapshot-create-as "$VM" "incident-$DATE" "Etat compromis conserve pour analyse"

echo "[3/4] restauration du snapshot '$SNAP'"
virsh snapshot-revert "$VM" "$SNAP" --running
for MAC in $MACS; do virsh domif-setlink "$VM" "$MAC" down; done

echo "[4/4] State après remédiation"
virsh domstate "$VM"
for MAC in $MACS; do echo "Lien $MAC : $(virsh domif-getlink "$VM" "$MAC" | awk '{print $NF}')"; done
virsh snapshot-list "$VM"

echo
echo "Vérifiez la VM, puis reconnectez-la avec :"
for MAC in $MACS; do echo "  virsh domif-setlink $VM $MAC up"; done
