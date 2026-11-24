#!/usr/bin/env bash
#
# 查找并清理 Ceph RGW 数据池里的“泄漏孤儿”（multipart part / shadow 等），
# 用于修复“删除对象后空间不降”的问题。
#
# 依赖：在能访问 Ceph 集群的机器上执行，需要 ceph / rado sgw-admin。
#
# 用法：
#   POOL=my-zone.rgw.buckets.data DRY_RUN=true bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
#      # 只列出将要删除的孤儿，不实际删除
#   POOL=my-zone.rgw.buckets.data bash docs/06-storage-ceph/scripts/ceph-orphan-cleanup.sh
#      # 实际删除
#
# 警告：
#   只会删除 `radosgw-admin orphans find` 判定为 leaked 的对象（无 bucket 索引引用）。
#   执行前先用 DRY_RUN=true 核对，并保留命令输出。
set -euo pipefail

POOL=${POOL:-my-zone.rgw.buckets.data}
DRY_RUN=${DRY_RUN:-false}
JOB_ID=${JOB_ID:-orphan-cleanup-$(date +%Y%m%d%H%M%S)}

echo "[orphan] pool=$POOL dry_run=$DRY_RUN job=$JOB_ID"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# orphans find 会把日志和结果都打到 stdout，只取 "leaked:" 行
# （这些对象已无索引引用，属于泄漏孤儿）
radosgw-admin orphans find --pool="$POOL" --job-id="$JOB_ID" --yes-i-really-mean-it > "$tmp" 2>/dev/null

mapfile -t leaked < <(grep '^leaked:' "$tmp" | sed 's/^leaked: //')
echo "[orphan] leaked count: ${#leaked[@]}"

ok=0
fail=0
for oid in "${leaked[@]}"; do
  [ -z "$oid" ] && continue
  if [ "$DRY_RUN" = "true" ]; then
    echo "[orphan] (dry-run) would delete: $oid"
    continue
  fi
  if rados -p "$POOL" rm "$oid" >/dev/null 2>&1; then
    ok=$((ok + 1))
  else
    fail=$((fail + 1))
    echo "[orphan] FAIL: $oid"
  fi
done

echo "[orphan] done: ok=$ok fail=$fail"
