#!/usr/bin/env bash
# 批量统计 Ceph RBD 实际占用（只读）。
# 用法：bash rbd-du.sh [pool]
set -euo pipefail
POOL="${1:-k8s-rbd}"

if ! command -v rbd >/dev/null 2>&1; then
  echo "未找到 rbd 命令，请先安装 ceph-common 并配置 /etc/ceph/ceph.conf。" >&2
  exit 1
fi

printf '%-70s %12s\n' "IMAGE" "SIZE"
for img in $(rbd -p "$POOL" ls); do
  size=$(rbd -p "$POOL" du "$img" 2>/dev/null | awk '/^SIZE/{print $2}' || true)
  printf '%-70s %12s\n' "$img" "${size:-?}"
done
