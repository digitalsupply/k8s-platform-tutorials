#!/usr/bin/env bash
#
# 清理 etcd 备份桶（Ceph RGW / S3）。
#
# 行为：
#   1. 删除 hourly/ 前缀（历史小时快照）；
#   2. 删除 daily/ 中早于 KEEP_DAYS 天的对象；
#   3. 删除根目录 test-* 测试对象。
#
# 依赖：aws CLI。凭据通过环境变量或 ~/.aws/credentials 提供：
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_DEFAULT_REGION
#
# 用法：
#   KEEP_DAYS=3 S3_ENDPOINT=http://10.0.0.31:7480 S3_BUCKET=etcd-backups \
#     bash docs/06-storage-ceph/scripts/cleanup-etcd-backups.sh
#
# 说明：
#   - 只删桶内对象，不修改 bucket lifecycle；
#     lifecycle 用 s3api put-bucket-lifecycle-configuration 配置，
#     参考 assets/etcd-backups-lifecycle.json。
#   - 删除对象后 Ceph 空间可能不会立刻下降，先查孤儿，见
#     scripts/ceph-orphan-cleanup.sh。
set -euo pipefail

EP=${S3_ENDPOINT:-http://10.0.0.31:7480}
BUCKET=${S3_BUCKET:-etcd-backups}
KEEP_DAYS=${KEEP_DAYS:-3}
DELETE_HOURLY=${DELETE_HOURLY:-true}

AW=(aws --endpoint-url "$EP" --no-verify-ssl)

echo "[cleanup] endpoint=$EP bucket=$BUCKET keep_days=$KEEP_DAYS"

# 1) hourly 前缀（历史小时快照）
if [ "$DELETE_HOURLY" = "true" ]; then
  n=$("${AW[@]}" s3 ls "s3://$BUCKET/hourly/" 2>/dev/null | wc -l)
  echo "[cleanup] hourly objects: $n"
  if [ "$n" -gt 0 ]; then
    "${AW[@]}" s3 rm "s3://$BUCKET/hourly/" --recursive
  fi
fi

# 2) daily 中早于 KEEP_DAYS 天的对象（滚动保留 KEEP_DAYS 份）
CUTOFF=$(date -d "$KEEP_DAYS days ago" +%Y%m%d)
echo "[cleanup] daily cutoff: keep >= $CUTOFF"
"${AW[@]}" s3 ls "s3://$BUCKET/daily/" 2>/dev/null | awk '{print $4}' | while read -r key; do
  [ -z "$key" ] && continue
  d=$(printf '%s' "$key" | sed -n 's#etcd-\([0-9]\{8\}\)\.db#\1#p')
  if [ -n "$d" ] && [ "$d" -lt "$CUTOFF" ]; then
    echo "[cleanup] delete daily/$key (date $d < $CUTOFF)"
    "${AW[@]}" s3 rm "s3://$BUCKET/daily/$key"
  fi
done

# 3) 根目录测试对象
"${AW[@]}" s3 ls "s3://$BUCKET/" 2>/dev/null | awk '{print $4}' | while read -r key; do
  [ -z "$key" ] && continue
  case "$key" in
    test-*)
      echo "[cleanup] delete test object $key"
      "${AW[@]}" s3 rm "s3://$BUCKET/$key"
      ;;
  esac
done

echo "[cleanup] after:"
"${AW[@]}" s3 ls "s3://$BUCKET/"
"${AW[@]}" s3 ls "s3://$BUCKET/daily/"
