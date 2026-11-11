#!/bin/sh
# 给 MinIO loki-chunks bucket 重设 ILM 生命周期规则（10 天过期）
# 已适配 minio/mc:latest 镜像：镜像内无 python3 / sed / grep / awk，只有 shell 内建 + cut/tr/head/tail
# 注意：mc ilm rule add 不支持 --id，规则 ID 由服务端随机生成
set -e
mc alias set la http://10.0.0.31:7480 "${S3_ACCESS_KEY:?set S3_ACCESS_KEY}" "${S3_SECRET_KEY:?set S3_SECRET_KEY}" >/dev/null

echo "=== rules before ==="
mc ilm rule ls la/loki-chunks

# 纯 shell 提取已有规则 ID（替代原 python3 实现）
ids=$(mc ilm rule ls --json la/loki-chunks | tr ',' '\n' | while IFS= read -r line; do
  case "$line" in
    *'"ID":"'*) printf '%s\n' "${line#*\"ID\":\"}" | cut -d'"' -f1 ;;
  esac
done)

echo "=== found ids ==="
echo "$ids"

n=0
for id in $ids; do
  n=$((n + 1))
  echo "removing [$n] $id"
  mc ilm rule remove --id "$id" la/loki-chunks
done

echo "=== add 10-day expiration rule ==="
mc ilm rule add --expire-days 10 la/loki-chunks

echo "=== rules after ==="
mc ilm rule ls la/loki-chunks
echo "=== bucket usage ==="
mc du la/loki-chunks
