#!/bin/bash
# 真正启动一个临时 postgres 实例，用备份的 data.tar.gz + 归档 WAL 做 PITR 恢复验证
set -uo pipefail
BASE=/root/ceph-rbd-released-audit-20260510
WORK=/root/ceph-rbd-released-audit-20261005/backup-work/recover-test
DEST=/tmp/pg_recover_verify
S3CFG=/root/.s3cfg-pgbackup

echo "=== 0) 环境检查 ==="
which postgres pg_ctl initdb 2>&1
ls /usr/pgsql-16/bin/ 2>/dev/null | head -5
PGVER=$(ls /usr/pgsql-16/bin/postgres 2>/dev/null && echo 16)
echo "PGVER=$PGVER"

echo
echo "=== 1) 准备恢复目录（模拟 CNPG 的 PGDATA 布局）==="
rm -rf "$DEST"; mkdir -p "$DEST/pgdata" "$DEST/wal"
cp -a "$BASE/etc/"* "$DEST/" 2>/dev/null
# 还原数据目录
tar -xzf "$WORK/data.tar.gz" -C "$DEST/pgdata"
echo "解压后文件数: $(find "$DEST/pgdata" -type f | wc -l)"
ls "$DEST/pgdata" | head -20

echo
echo "=== 2) 下载全部归档 WAL 到 restore_wal 目录 ==="
mkdir -p "$DEST/pgdata/restore_wal"
s3cmd -c $S3CFG get --recursive --force s3://pg-backups/pg16-ceph/wals/ "$DEST/pgdata/restore_wal/" 2>&1 | tail -3
ls -la "$DEST/pgdata/restore_wal/"

echo
echo "=== 3) 构造恢复用配置 ==="
cat > "$DEST/postgresql.conf" <<EOF
port = 5599
listen_addresses = 'localhost'
unix_socket_directories = '/tmp'
data_directory = '$DEST/pgdata'
hba_file = '$DEST/pg_hba.conf'
ident_file = '$DEST/pg_ident.conf'
archive_mode = off
restore_command = 'cp $DEST/pgdata/restore_wal/%f %p'
recovery_target_timeline = 'latest'
recovery_target_action = 'promote'
wal_keep_size = 512MB
shared_buffers = 128MB
max_connections = 20
fsync = off
EOF
cat > "$DEST/pg_hba.conf" <<EOF
local all all trust
host all all 127.0.0.1/32 trust
EOF
cp "$DEST/pgdata/pg_ident.conf" "$DEST/pg_ident.conf" 2>/dev/null || echo "local all postgres postgres" > "$DEST/pg_ident.conf"
# 移除 CNPG 的 override/custom（会指向不存在的 archive_command）
rm -f "$DEST/pgdata/override.conf" "$DEST/pgdata/custom.conf"
# 权限
chmod 700 "$DEST/pgdata"; chown -R 26:26 "$DEST/pgdata" 2>/dev/null || true

echo
echo "=== 4) 启动恢复（作为 postgres 用户无法切换则用当前用户 + 独立端口）==="
export PATH=/usr/pgsql-16/bin:$PATH
export PGDATA="$DEST/pgdata"
# 允许非 root 运行：PGDATA 属主已是 26，若当前是 root 则降权执行
if [ "$(id -u)" = "0" ]; then RUNAS="setpriv --reuid=26 --regid=26 --clear-groups"; else RUNAS=""; fi
$RUNAS /usr/pgsql-16/bin/pg_ctl -D "$DEST/pgdata" -l /tmp/pgrecover.log -o "-p 5599" -w -t 90 start 2>&1 | tail -10
echo "--- 启动日志:"
tail -40 /tmp/pgrecover.log 2>/dev/null

echo
echo "=== 5) 连接验证 ==="
sleep 3
psql -h /tmp -p 5599 -U postgres -d postgres -tAc "select 'CONNECTED', version();" 2>&1 | head -3
echo "--- 恢复后库清单:"
psql -h /tmp -p 5599 -U postgres -d postgres -tAc "select datname, pg_database_size(datname) from pg_database order by 2 desc;" 2>&1
echo "--- n8n 表数:"
psql -h /tmp -p 5599 -U postgres -d n8n -tAc "select count(*) from pg_tables where schemaname='public';" 2>&1
echo "--- n8n 关键表行数:"
psql -h /tmp -p 5599 -U postgres -d n8n -tAc "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 5;" 2>&1
echo "--- 是否处于恢复状态（应为 f，已 promote）:"
psql -h /tmp -p 5599 -U postgres -d postgres -tAc "select pg_is_in_recovery();" 2>&1
echo "--- 时间线:"
psql -h /tmp -p 5599 -U postgres -d postgres -tAc "select timeline_id from pg_control_checkpoint();" 2>&1

echo
echo "=== 6) 停止并清理 ==="
$RUNAS /usr/pgsql-16/bin/pg_ctl -D "$DEST/pgdata" -m immediate -w stop 2>&1 | tail -3
echo "done"
