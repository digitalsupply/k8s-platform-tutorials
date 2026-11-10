#!/bin/bash
set -euo pipefail
VMID=$1
NODE=$2
IP=$3
BK=/root/vm-conf-backup-$(date +%F)
mkdir -p "$BK"
cp -f "/etc/pve/qemu-server/$VMID.conf" "$BK/$VMID.conf.before-discard"

CUR=$(qm config "$VMID" | awk -F': ' '/^scsi0:/{print $2}')
if [[ "$CUR" != *discard=on* ]]; then
  echo ">>> adding discard=on,ssd=1 to VM $VMID"
  qm set "$VMID" --scsi0 "$CUR,discard=on,ssd=1"
else
  echo ">>> discard already enabled on VM $VMID"
fi
qm config "$VMID" | grep '^scsi0:'

echo ">>> draining $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force --timeout=300s

echo ">>> shutting down VM $VMID"
qm shutdown "$VMID" --timeout 240

echo ">>> starting VM $VMID"
qm start "$VMID"

echo ">>> waiting for ssh on $IP"
ok=0
for i in $(seq 1 60); do
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 "root@$IP" 'true' 2>/dev/null; then ok=1; break; fi
  sleep 5
done
[[ $ok == 1 ]] || { echo "SSH timeout"; exit 1; }

echo ">>> waiting for node $NODE Ready"
for i in $(seq 1 60); do
  s=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  [[ "$s" == "True" ]] && break
  sleep 5
done
kubectl get node "$NODE"

echo ">>> fstrim on $IP"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$IP" 'fstrim -av; df -h / | tail -1'

echo ">>> uncordon $NODE"
kubectl uncordon "$NODE"
kubectl get node "$NODE"
