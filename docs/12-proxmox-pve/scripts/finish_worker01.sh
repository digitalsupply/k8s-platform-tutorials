#!/bin/bash
set -euo pipefail
VMID=122
NODE=worker01
IP=10.0.0.122
OTHERS="worker02 worker03 master01 master02 m01"
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=4"

BK=/root/vm-conf-backup-$(date +%F)
mkdir -p "$BK"
cp -f "/etc/pve/qemu-server/$VMID.conf" "$BK/$VMID.conf.before-discard"
CUR=$(qm config "$VMID" | awk -F': ' '/^scsi0:/{print $2}')
if [[ "$CUR" != *discard=on* ]]; then
  qm set "$VMID" --scsi0 "$CUR,discard=on,ssd=1"
fi
qm config "$VMID" | grep '^scsi0:'

echo ">>> cordon other nodes"
for n in $OTHERS; do kubectl cordon "$n" >/dev/null; done

echo ">>> drain $NODE (no eviction, PDB bypass)"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force \
  --disable-eviction --timeout=300s || true

echo ">>> shutdown/start VM $VMID"
qm shutdown "$VMID" --timeout 240
qm start "$VMID"

echo ">>> wait ssh"
for i in $(seq 1 60); do
  $SSH root@"$IP" true 2>/dev/null && break
  sleep 5
done

echo ">>> wait node Ready"
for i in $(seq 1 60); do
  s=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$s" == "True" ]] && break
  sleep 5
done
kubectl get node "$NODE"

echo ">>> fstrim"
$SSH root@"$IP" 'fstrim -av; df -h / | tail -1'

echo ">>> uncordon $NODE"
kubectl uncordon "$NODE" >/dev/null

echo ">>> wait 45s for pods to land back on worker01"
sleep 45
kubectl get pods -A --no-headers | awk '$4!="Running"{print $1,$2,$4}' | head -30 || true

echo ">>> uncordon others"
for n in $OTHERS; do kubectl uncordon "$n" >/dev/null; done
kubectl get nodes
