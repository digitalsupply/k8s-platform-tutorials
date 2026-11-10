#!/usr/bin/env bash
# 只读核对 Released PV 与 Ceph RBD image。
# 用法：bash inspect-released-pv.sh [pool]
set -euo pipefail
POOL="${1:-k8s-rbd}"

echo "== PV 状态 =="
kubectl get pv -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,CAP:.spec.capacity.storage,SC:.spec.storageClassName,CLAIM:.spec.claimRef.name --no-headers |
  awk '$2=="Released" || $2=="Failed"'

echo
echo "== 所有 PVC（用于比对 UID） =="
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,UID:.metadata.uid,STATUS:.status.phase --no-headers

echo
echo "== Ceph RBD 镜像（pool=${POOL}） =="
if command -v rbd >/dev/null 2>&1; then
  rbd -p "$POOL" ls || true
  echo
  echo "== watchers（应为 none 才可清理） =="
  for img in $(rbd -p "$POOL" ls 2>/dev/null); do
    printf '%-70s ' "$img"
    rbd -p "$POOL" watchers "$img" 2>/dev/null || true
  done
else
  echo "未找到 rbd 命令，跳过 Ceph 侧检查。"
fi
