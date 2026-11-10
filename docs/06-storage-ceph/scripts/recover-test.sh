#!/bin/bash
# 从 pg-backups bucket 恢复到一个临时目录并校验 tar 完整性
set -uo pipefail
WORK=/root/ceph-rbd-released-audit-20261005/backup-work/recover-test
rm -rf "$WORK"; mkdir -p "$WORK"
echo "=== 1) 下载 base backup 到本地 ==="
s3cmd -c /root/.s3cfg-pgbackup get --recursive --force s3://pg-backups/pg16-ceph/base/20261005T134311/ "$WORK/" 2>&1 | tail -5
ls -la "$WORK"
echo
echo "=== 2) 校验 data.tar.gz 完整性（gzip -t + tar -tz）==="
gzip -t "$WORK/data.tar.gz" && echo "gzip 校验通过"
echo "tar 内文件数: $(tar -tzf "$WORK/data.tar.gz" | wc -l)"
echo "--- tar 前 15 项:"
tar -tzf "$WORK/data.tar.gz" | head -15
echo
echo "=== 3) 关键 PG 文件是否齐全 ==="
for f in backup_label pg_control global/pg_control base/1/PG_VERSION; do
  if tar -tzf "$WORK/data.tar.gz" | grep -qx "$f"; then echo "  OK   $f"; else echo "  MISS $f"; fi
done
echo
echo "=== 4) 读取 backup_label / backup.info ==="
tar -xzf "$WORK/data.tar.gz" -O backup_label 2>/dev/null || echo "(backup_label 未在 tar 顶层)"
echo "--- backup.info:"
cat "$WORK/backup.info" 2>/dev/null | head -20
echo
echo "=== 5) WAL 归档可用性 ==="
s3cmd -c /root/.s3cfg-pgbackup ls -r s3://pg-backups/pg16-ceph/wals/ 2>&1
