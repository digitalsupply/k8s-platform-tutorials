#!/bin/bash
# ==============================================================================
# 线 3：kube-proxy IPVS → iptables 迁移脚本
#   原因：K8s 1.35 弃用 IPVS（KEP-5495），1.38 移除
#   本集群 6 节点，366 条 IPVS 规则，规模小 → iptables 足够
#
# ★ 风险：迁移瞬间所有 Service 连接短暂中断（Kafka/CNPG 客户端会重连）
#   → 建议业务低峰期执行
#
# 用法：
#   bash migrate-kube-proxy-iptables.sh backup    # 备份
#   bash migrate-kube-proxy-iptables.sh check     # 查当前状态
#   bash migrate-kube-proxy-iptables.sh migrate   # 执行迁移
#   bash migrate-kube-proxy-iptables.sh rollback  # 回滚
# ==============================================================================
set -uo pipefail
ACTION="${1:-check}"
WORK="/root/k8s-upgrade-1.29-to-1.35/work/kube-proxy"
mkdir -p "$WORK"
CFG=/tmp/kube-proxy.conf.bak

log(){ echo -e "\n\033[1;32m[$(date '+%H:%M:%S')] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $*\033[0m"; }
die(){ echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }

current_mode(){ kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -oP '^\s*mode:\s*"\K[^"]+'; }

case "$ACTION" in

check)
  log "当前 kube-proxy 状态"
  MODE=$(current_mode)
  echo "  mode: $MODE"
  echo ""
  echo "  各节点 IPVS 规则数:"
  for n in $(kubectl get nodes --no-headers -o custom-columns=N:.metadata.name | tr -d ' '); do
    echo "    $n"
  done
  echo ""
  echo "  提示：在各节点执行 ipvsadm -Ln | wc -l 查看规则数"
  echo ""
  echo "  Service 统计:"
  kubectl get svc -A --no-headers | wc -l | xargs echo "    总 Service 数:"
  echo ""
  echo "  iptables KUBE-SERVICES 规则数（某节点）:"
  echo "    ssh <node> 'iptables -t nat -L KUBE-SERVICES -n | wc -l'"
  ;;

backup)
  log "备份 kube-proxy 配置"
  kubectl -n kube-system get cm kube-proxy -o yaml > "$WORK/kube-proxy-cm-$(date +%Y%m%d-%H%M%S).yaml"
  kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' > "$CFG"
  cp "$CFG" "$WORK/config.conf.$(date +%Y%m%d-%H%M%S)"
  echo "  ✓ 已备份到 $WORK/"
  ls -lt "$WORK" | head -5 | tail -n +2 | awk '{print "    "$6" "$7" "$9}'
  echo "  当前 mode: $(current_mode)"
  ;;

migrate)
  MODE=$(current_mode)
  log "迁移 kube-proxy: $MODE → iptables"

  if [ "$MODE" = "iptables" ]; then
    log "已经是 iptables 模式，无需迁移"; exit 0
  fi
  if [ "$MODE" != "ipvs" ]; then
    die "当前 mode=$MODE，不是预期的 ipvs，请人工确认"
  fi

  # 备份
  [ -f "$CFG" ] || { kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' > "$CFG"; }
  cp "$CFG" "$WORK/pre-migrate-$(date +%Y%m%d-%H%M%S).conf"
  echo "  ✓ 已备份当前配置"

  # 统计迁移前状态
  log "迁移前状态"
  SVC=$(kubectl get svc -A --no-headers | wc -l)
  echo "  Service 总数: $SVC"
  if [ "$SVC" -gt 200 ]; then
    warn "Service 数量较多（$SVC），iptables 规则可能接近上限"
    warn "iptables 单链默认上限 8192 条，建议："
    warn "  kubectl run ipt-test --image=alpine:3.20 --rm -it --privileged -- "
    warn "  iptables -C FORWARD -s 10.0.0.0/8 2>/dev/null || echo '需检查'"
  fi

  # 确认所有节点 Ready
  NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
  [ -z "$NOTREADY" ] || die "以下节点 NotReady，先修复: $NOTREADY"
  echo "  ✓ 全部节点 Ready"

  # 执行迁移
  log "生成 iptables 配置"
  NEWCONF="$WORK/config.iptables.conf"
  # 改 mode
  sed 's/^\(\s*\)mode:.*/\1mode: "iptables"/' "$CFG" > "$NEWCONF"
  # 清理 ipvs 专属段（避免残留无效配置）
  python3 - "$NEWCONF" <<'PYEOF'
import re,sys
p=sys.argv[1]
lines=open(p).read().splitlines()
out=[];skip=False;depth=0
for l in lines:
    # 移除 ipvs: 段（顶格或缩进 2 空格）
    if re.match(r'^\s*ipvs:\s*$', l):
        skip=True; depth=len(l)-len(l.lstrip()); continue
    if skip:
        ind=len(l)-len(l.lstrip())
        if l.strip()=='' or ind>depth:
            continue
        skip=False
    out.append(l)
open(p,"w").write("\n".join(out)+"\n")
PYEOF
  echo "  ✓ mode 已改为 iptables，ipvs 段已清理"
  echo "  --- diff 预览（前 20 行）---"
  diff "$CFG" "$NEWCONF" | head -20 || true

  # 应用
  log "应用配置并重启 kube-proxy"
  kubectl -n kube-system patch cm kube-proxy --type=merge \
    -p "{\"data\":{\"config.conf\":$(python3 -c "import json;print(json.dumps(open('$NEWCONF').read()))")}}"
  echo "  ✓ 配置已更新"

  kubectl -n kube-system rollout restart ds/kube-proxy
  kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s
  echo "  ✓ kube-proxy 已重启"

  # 验证
  log "验证迁移结果"
  NEWMODE=$(current_mode)
  echo "  mode: $MODE → $NEWMODE"
  kubectl -n kube-system logs ds/kube-proxy --tail=10 --prefix 2>/dev/null | grep -iE "iptables|ipvs|Using" | head -5

  cat <<'EOF'

★ 请在各节点手工验证：
  ssh <node> 'iptables -t nat -L KUBE-SERVICES -n | wc -l'    # 应 > 0
  ssh <node> 'ipvsadm -Ln 2>/dev/null | wc -l'                # 应为 0

★ 跨节点 Service 访问验证：
  kubectl get svc -A                     # 确认无异常
  # 访问一个 ClusterIP Service 确认正常
  kubectl port-forward svc/<name> 8080:80 & curl -s localhost:8080/healthz

★ 业务验证（重点）：
  - Kafka（Strimzi）：kubectl get kafka,pods -n kafka
  - PostgreSQL（CNPG）：kubectl get clusters.postgresql.cnpg.io -n cnpg-system
  - 监控栈：Grafana/Loki/Tempo 可访问

★ 回滚：bash $0 rollback
EOF
  ;;

rollback)
  log "回滚到 IPVS 模式"
  BK=$(ls -t "$WORK"/pre-migrate-*.conf 2>/dev/null | head -1)
  [ -n "$BK" ] || die "未找到迁移前备份（$WORK/pre-migrate-*.conf）"
  echo "  使用备份: $BK"
  kubectl -n kube-system patch cm kube-proxy --type=merge \
    -p "{\"data\":{\"config.conf\":$(python3 -c "import json;print(json.dumps(open('$BK').read()))")}}"
  kubectl -n kube-system rollout restart ds/kube-proxy
  kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s
  echo "  ✓ 已回滚，当前 mode: $(current_mode)"
  ;;

*)
  echo "用法: bash $0 {backup|check|migrate|rollback}"
  ;;
esac
