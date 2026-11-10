#!/bin/bash
# ==============================================================================
# containerd 回滚脚本（单节点）
#   从 upgrade-containerd.sh 生成的备份目录恢复 1.7.22 + runc 1.3.3
#
# 用法：bash rollback-containerd.sh /root/ctr-backup-YYYYMMDD-HHMMSS
# ==============================================================================
set -euo pipefail

BK="${1:?用法: bash rollback-containerd.sh <备份目录>}"
[ -d "$BK" ] || { echo "备份目录不存在: $BK"; exit 1; }
[ -f "$BK/containerd-1.7.22" ] || { echo "备份中无 containerd-1.7.22，中止"; exit 1; }

log(){ echo -e "\033[1;32m[$(date '+%H:%M:%S')] $*\033[0m"; }
die(){ echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }

log "回滚 containerd（备份: $BK）"
echo "  当前版本: $(containerd --version 2>/dev/null|grep -oP 'v\K[0-9.]+'|head -1)"
echo "  回滚到:1.7.22"

# 1. 恢复二进制
cp -a "$BK/containerd-1.7.22" /usr/local/bin/containerd || die "containerd 恢复失败"
chmod +x /usr/local/bin/containerd

# 2. 恢复 runc 到原路径
RUNC_ORIG=$(cat "$BK/runc-path.txt")
OLDRUNCV=$(cat "$BK/runc-old-version.txt" 2>/dev/null || echo "unknown")
if [ -f "$BK/runc-$OLDRUNCV" ]; then
  cp -a "$BK/runc-$OLDRUNCV" "$RUNC_ORIG" || warn "runc 恢复到 $RUNC_ORIG 失败"
  echo "  ✓ runc $OLDRUNCV 已恢复到 $RUNC_ORIG"
fi
# 清理 2.x 安装的 /usr/local/sbin/runc（若原本不存在）
[ "$RUNC_ORIG" = "/usr/local/sbin/runc" ] || rm -f /usr/local/sbin/runc

# 3. 恢复 config.toml
if [ -f "$BK/config.toml" ]; then
  cp -a "$BK/config.toml" /etc/containerd/config.toml
  echo "  ✓ config.toml 已恢复（★关键：config 一直是 v2，未 migrate，回滚无障碍）"
fi

# 4. 重启
log "重启 containerd"
systemctl daemon-reload
systemctl restart containerd
sleep 5
systemctl is-active --quiet containerd || die "containerd 回滚后启动失败"
echo "  ✓ containerd active"
echo "  当前版本: $(containerd --version|grep -oP 'v\K[0-9.]+'|head -1)"
echo "  当前 runc: $(runc --version 2>/dev/null|awk '/^runc version/{print $3}')"

log "验证容器"
crictl ps -a > "$BK/crictl-ps-rollback.txt" 2>/dev/null || true
echo "  容器数: $(grep -c . "$BK/crictl-ps-rollback.txt" 2>/dev/null || echo 0)"
crictl info > /dev/null 2>&1 && echo "  ✓ crictl info 正常" || warn "crictl info 异常"

cat <<EOF

══════════════════════════════════════════════
  回滚完成（节点级）
  ★ 请在控制节点执行 kubectl uncordon <node>
  ★ 并验证 kubectl get node <node> → Ready
══════════════════════════════════════════════
EOF
