#!/usr/bin/env bash
# 在 Proxmox 宿主机上把一个 K8s 节点 VM 的 CPU 型号从 v2 改为 x86-64-v3。
#
# 这是“破坏性”脚本：会 drain 节点、关机、改 CPU、开机、等待 Ready、uncordon。
# 默认只做 dry-run；确认后加 --execute。
#
# 用法：
#   bash migrate_vm_cpu_v3.sh worker03 124 10.0.0.124            # dry-run
#   bash migrate_vm_cpu_v3.sh worker03 124 10.0.0.124 --execute  # 真正执行
#
# 前置条件：
#   - 在 PVE 宿主机（有 qm 命令）上执行；
#   - 本机 kubectl 指向目标集群；
#   - 目标 CPU 型号在 qm 中可用：qm set <vmid> --cpu x86-64-v3；
#   - 有状态负载已确认可切换（CNPG/Kafka 等），必要时先手工 failover；
#   - 控制面节点请逐台执行，m01 最后，并准备好指向 VIP 的临时 kubeconfig。
#
# 安全策略：
#   - 执行前备份 /etc/pve/qemu-server/<vmid>.conf；
#   - 任何一步失败立即退出，不自动回滚 CPU 型号；
#   - 关机等待超时会退出，避免在 VM 仍运行时改配置。

set -euo pipefail

NODE=${1:-}
VMID=${2:-}
IP=${3:-}
MODE=${4:-}

if [[ -z "$NODE" || -z "$VMID" || -z "$IP" ]]; then
  sed -n '2,25p' "$0"
  exit 2
fi

if [[ "$MODE" != "--execute" ]]; then
  echo "== DRY RUN =="
  echo "node=$NODE vmid=$VMID ip=$IP"
  echo "1) kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=600s"
  echo "2) qm shutdown $VMID --timeout 120  (wait stopped)"
  echo "3) qm set $VMID --cpu x86-64-v3"
  echo "4) qm start $VMID  (wait running)"
  echo "5) kubectl wait --for=condition=Ready node/$NODE --timeout=600s"
  echo "6) kubectl uncordon $NODE"
  echo
  echo "确认无误后加 --execute。"
  exit 0
fi

command -v qm >/dev/null || { echo "qm not found: run on PVE host"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

CUR_CPU=$(qm config "$VMID" | awk -F': ' '/^cpu:/{print $2}')
if [[ "$CUR_CPU" == "x86-64-v3" ]]; then
  echo "VM $VMID already uses x86-64-v3; nothing to do."
  exit 0
fi

echo ">>> backup VM config"
BK="/root/vm-conf-backup-$(date +%F)"
mkdir -p "$BK"
cp -f "/etc/pve/qemu-server/$VMID.conf" "$BK/$VMID.conf.before-cpu-v3"

echo ">>> record current state"
kubectl get node "$NODE" -o wide || true
qm status "$VMID"

echo ">>> drain $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=600s

echo ">>> shutdown VM $VMID"
qm shutdown "$VMID" --timeout 120
for i in $(seq 1 60); do
  s=$(qm status "$VMID" | awk '{print $2}')
  [[ "$s" == "stopped" ]] && break
  sleep 2
done
[[ "$(qm status "$VMID" | awk '{print $2}')" == "stopped" ]] || {
  echo "VM $VMID did not stop; aborting without changing CPU"; exit 1;
}

echo ">>> set CPU x86-64-v3"
qm set "$VMID" --cpu x86-64-v3
qm config "$VMID" | grep -E '^cpu:|^cores:|^sockets:' || true

echo ">>> start VM $VMID"
qm start "$VMID"
for i in $(seq 1 60); do
  s=$(qm status "$VMID" | awk '{print $2}')
  [[ "$s" == "running" ]] && break
  sleep 2
done
[[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]] || {
  echo "VM $VMID did not start"; exit 1;
}

echo ">>> wait node Ready"
kubectl wait --for=condition=Ready "node/$NODE" --timeout=600s

echo ">>> verify avx2"
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "root@$IP" 'grep -m1 "^flags" /proc/cpuinfo | grep -o avx2' || true

echo ">>> uncordon $NODE"
kubectl uncordon "$NODE"
kubectl get node "$NODE"
