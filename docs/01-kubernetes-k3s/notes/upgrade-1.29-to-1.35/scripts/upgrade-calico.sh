#!/bin/bash
# ==============================================================================
# 线 2：Calico 升级脚本（manifest 安装，两步走）
#   步骤1: v3.27.4 → v3.30.7
#   步骤2: v3.30.7 → v3.32.2
#
# ★ 本集群特有配置（必须对齐，否则跨节点网络会断）：
#   calico_backend      = bird      （★ 新 manifest 默认可能是 felix）
#   CLUSTER_TYPE        = k8s,bgp
#   IPPool ipipMode     = Always    （★ 新 manifest 默认可能是 Never）
#   IPPool cidr         = 10.244.0.0/16
#   veth_mtu            = 0
#   FelixConfiguration: bpfConnectTimeLoadBalancing=TCP
#                        bpfHostNetworkedNATWithoutCTLB=Enabled
#
# 用法（在控制节点执行）：
#   bash upgrade-calico.sh backup            # 仅备份
#   bash upgrade-calico.sh 3.30.7            # 升到 3.30
#   bash upgrade-calico.sh 3.32.2            # 升到 3.32
#   bash upgrade-calico.sh verify            # 验证当前状态
# ==============================================================================
set -uo pipefail

ACTION="${1:-}"
WORK="/root/k8s-upgrade-1.29-to-1.35/work/calico"
mkdir -p "$WORK"

log(){ echo -e "\n\033[1;32m[$(date '+%H:%M:%S')] $*\033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $*\033[0m"; }
die(){ echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }

EXPECT_CIDR="10.244.0.0/16"
EXPECT_BACKEND="bird"
EXPECT_IPIP="Always"

# ─────────────────────────────────────────────────────────────────────────────
calico_version(){
  kubectl get ds calico-node -n kube-system \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
    | grep -oP 'v\K[0-9.]+'
}

check_config(){
  log "检查当前 Calico 配置（本集群必须保持的值）"
  local backend=$(kubectl get cm calico-config -n kube-system -o jsonpath='{.data.calico_backend}' 2>/dev/null)
  local cluster_type=$(kubectl get ds calico-node -n kube-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLUSTER_TYPE")].value}' 2>/dev/null)
  local ippool_ipip=$(kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.ipipMode}' 2>/dev/null)
  local ippool_cidr=$(kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.cidr}' 2>/dev/null)
  echo "  calico_backend      : $backend  (期望 $EXPECT_BACKEND)"
  echo "  CLUSTER_TYPE        : $cluster_type  (期望 k8s,bgp)"
  echo "  IPPool ipipMode     : $ippool_ipip  (期望 $EXPECT_IPIP)"
  echo "  IPPool cidr         : $ippool_cidr  (期望 $EXPECT_CIDR)"
  echo "  Felix BPF 配置:"
  kubectl get felixconfiguration default -o json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k in ['bpfConnectTimeLoadBalancing','bpfHostNetworkedNATWithoutCTLB']:
    print(f'    {k}: {d[\"spec\"].get(k,\"(未设置)\")}')
" 2>/dev/null || echo "    (读取失败)"
}

# ─────────────────────────────────────────────────────────────────────────────
case "$ACTION" in

# ═══════════════════════════════════════════════════════════════════════
backup)
  BK="$WORK/backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK"
  log "备份 Calico 到 $BK"
  kubectl get crd -o yaml > "$BK/crds.yaml" 2>/dev/null
  kubectl get ds calico-node -n kube-system -o yaml > "$BK/calico-node.yaml"
  kubectl get deploy calico-kube-controllers -n kube-system -o yaml > "$BK/calico-kube-controllers.yaml"
  kubectl get cm calico-config -n kube-system -o yaml > "$BK/calico-config.yaml"
  kubectl get ippool default-ipv4-ippool -o yaml > "$BK/ippool.yaml"
  kubectl get felixconfiguration default -o yaml > "$BK/felixconfiguration.yaml" 2>/dev/null || true
  kubectl get cm typha-cfg -n kube-system -o yaml > "$BK/typha-cfg.yaml" 2>/dev/null || true
  echo "$BK" > /tmp/calico-latest-backup
  echo "  备份完成: $BK"
  ls -lh "$BK" | tail -n +2 | awk '{print "    "$5"\t"$9}'
  log "当前版本: $(calico_version)"
  check_config
  ;;

# ═══════════════════════════════════════════════════════════════════════
verify)
  log "当前 Calico 状态"
  echo "  版本: $(calico_version)"
  echo "  calico-node Pod:"
  kubectl -n kube-system get pods -l k8s-app=calico-node -o wide 2>/dev/null | head -8
  check_config
  echo "  节点 Ready:"
  kubectl get nodes --no-headers | awk '{print "    "$1" "$2}'
  echo "  跨节点网络测试:"
  local_ok=0
  for n in worker01 worker02 worker03; do
    if kubectl get nodes $n -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; then
      echo "    $n: Ready ✓"; local_ok=$((local_ok+1))
    else
      echo "    $n: NOT READY ✗"
    fi
  done
  [ "$local_ok" -gt 0 ] && echo "  → $local_ok/3 worker Ready"
  ;;

# ═══════════════════════════════════════════════════════════════════════
*)
  VER="$ACTION"
  CURRENT=$(calico_version)
  log "Calico 升级: v$CURRENT → v$VER"

  # 只允许 3.30.x 或 3.32.x
  case "$VER" in
    3.30.*) STEP="步骤1（3.27 → 3.30）" ;;
    3.32.*) STEP="步骤2（3.30 → 3.32）" ;;
    *) die "本脚本只支持 3.30.x 或 3.32.x，收到: $VER" ;;
  esac
  log "执行 $STEP"

  # ── 前置检查 ─────────────────────────────────────────────────────────────
  log "PRE-FLIGHT 前置检查"
  BACKUP=$(cat /tmp/calico-latest-backup 2>/dev/null || echo "")
  if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
    warn "未找到备份。建议先执行: bash $0 backup"
    read -r -p "  无备份继续？(yes/no) " a; [ "$a" = "yes" ] || die "已取消"
  else
    echo "  使用备份: $BACKUP"
  fi

  # 校验顺序（3.30 必须在 3.32 之前）
  if [[ "$VER" == 3.32* && "$CURRENT" != 3.30.* ]]; then
    die "★ 顺序错误：从 v$CURRENT 升 3.32 会跨 5 个 minor。必须先升 3.30。"
  fi

  echo "  检查所有节点 Ready:"
  NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
  if [ -n "$NOTREADY" ]; then
    die "以下节点 NotReady，先修复: $NOTREADY"
  fi
  echo "  ✓ 全部节点 Ready"

  # ── 下载manifest ─────────────────────────────────────────────────────────
  log "下载 Calico v$VER manifest"
  MF="$WORK/calico-v$VER.yaml"
  # ★优先使用本地已下载的 manifest
  # （实测 raw.githubusercontent.com 在本环境不通，ghproxy.net 可用）
  if [ -s "$MF" ]; then
    echo "  使用本地已下载 manifest: $MF ($(du -h $MF|cut -f1))"
  else
    URL="https://raw.githubusercontent.com/projectcalico/calico/v$VER/manifests/calico.yaml"
    ALT="https://ghproxy.net/$URL"
    echo "  尝试下载: $URL"
    if ! curl -fsSL -m 120 -o "$MF" "$URL" 2>/dev/null; then
      echo "  直连失败，尝试镜像: ghproxy.net"
      curl -fsSL -m 180 -o "$MF" "$ALT" || die "下载失败。★ 手动下载后放到 $MF"
    fi
    echo "  ✓ 已下载 $(du -h $MF|cut -f1)"
  fi
  # 内容校验
  grep -q "kind: CustomResourceDefinition" "$MF" || die "manifest 内容异常（缺 CRD 定义）"
  grep -q "docker.io/calico/node:v$VER" "$MF" || warn "manifest 中未见 v$VER 镜像，请确认版本正确"

  # ── ★★ 关键：修改 manifest 以对齐本集群配置 ───────────────────────────────
  log "★ 修改 manifest 对齐本集群配置"

  # 1) calico_backend: 新版默认可能是 felix，必须改回bird
  if grep -q 'calico_backend' "$MF"; then
    CUR_BE=$(kubectl get cm calico-config -n kube-system -o jsonpath='{.data.calico_backend}')
    sed -i "s/calico_backend: .*/calico_backend: \"${CUR_BE}\"/" "$MF"
    echo "  ✓ calico_backend 保持 = $CUR_BE"
  fi

  # 2) IPPool ipipMode: ★ 最关键，绝不能变成 Never
  if grep -q 'CALICO_IPV4POOL_IPIP' "$MF"; then
    CUR_IPIP=$(kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.ipipMode}')
    sed -i "s/CALICO_IPV4POOL_IPIP: .*/CALICO_IPV4POOL_IPIP: \"${CUR_IPIP}\"/" "$MF"
    echo "  ✓ CALICO_IPV4POOL_IPIP 保持 = $CUR_IPIP  ★跨节点网络依赖此项"
  else
    warn "manifest 中无 CALICO_IPV4POOL_IPIP，需确认默认是否仍为 Always"
  fi

  # 3) IPPool CIDR
  if grep -q 'CALICO_IPV4POOL_CIDR' "$MF"; then
    sed -i "s|CALICO_IPV4POOL_CIDR: .*|CALICO_IPV4POOL_CIDR: \"${EXPECT_CIDR}\"|" "$MF"
    echo "  ✓ CIDR 保持 = $EXPECT_CIDR"
  fi

  # 4) VXLAN 必须保持 Never（当前是 IPIP 封装）
  sed -i 's/CALICO_IPV4POOL_VXLAN: .*/CALICO_IPV4POOL_VXLAN: "Never"/' "$MF" 2>/dev/null || true
  echo "  ✓ VXLAN 保持 Never（IPIP 模式）"

  # 5) CLUSTER_TYPE 保持 k8s,bgp
  sed -i 's/CLUSTER_TYPE: .*/CLUSTER_TYPE: "k8s,bgp"/' "$MF" 2>/dev/null || true
  echo "  ✓ CLUSTER_TYPE 保持 k8s,bgp"

  echo "  --- 修改后关键字段确认 ---"
  grep -E 'calico_backend:|CALICO_IPV4POOL_IPIP|CALICO_IPV4POOL_CIDR|CALICO_IPV4POOL_VXLAN|CLUSTER_TYPE' "$MF" | head -8

  # ── 应用 ─────────────────────────────────────────────────────────────────
  log "应用 manifest（kubectl apply --server-side --force-conflicts）"
  echo "  ★ 官方推荐 --server-side（避免 3-way merge 冲突）"
  kubectl apply --server-side --force-conflicts -f "$MF" 2>&1 | tail -20
  APPLY_RC=$?
  [ $APPLY_RC -eq 0 ] || warn "apply 有报错，请检查（部分资源可能已更新）"

  # ── 等待滚动完成 ─────────────────────────────────────────────────────────
  log "等待 calico-node 滚动完成"
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s 2>&1 | tail -3
  kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=180s 2>&1 | tail -2

  # ── 验证 ─────────────────────────────────────────────────────────────────
  log "验证升级结果"
  NEW=$(calico_version)
  echo "  版本: $CURRENT → $NEW"
  check_config

  echo "  --- 节点状态 ---"
  kubectl get nodes --no-headers | awk '{print "    "$1"\t"$2}'
  NOTREADY=$(kubectl get nodes --no-headers | awk '$2!="Ready"{print $1}')
  if [ -n "$NOTREADY" ]; then
    die "以下节点 NotReady：$NOTREADY
★ 排查建议：
  kubectl -n kube-system get pods -l k8s-app=calico-node -o wide
  kubectl -n kube-system logs <calico-node-pod> --tail=50
  ★ 回滚：kubectl apply -f $BACKUP/calico-node.yaml"
  fi
  echo "  ✓ 全部节点 Ready"

  echo "  --- 跨节点网络验证 ---"
  cat <<'TIP'
  在两个不同节点上各起一个 Pod，测试互相 ping：
    kubectl run test-a --image=busybox:1.36 -- sleep=3600 --overrides='{"spec":{"nodeName":"worker01"}}'
    kubectl run test-b --image=busybox:1.36 -- sleep=3600 --overrides='{"spec":{"nodeName":"worker02"}}'
    kubectl exec test-a -- ping -c 3 <test-b的IP>
    kubectl exec test-b -- ping -c 3 <test-a的IP>
    kubectl delete pod test-a test-b
TIP

  cat <<EOF

══════════════════════════════════════════════════════════════
  Calico 升级到 v$NEW 完成
  备份: ${BACKUP:-未备份}
══════════════════════════════════════════════════════════════

★ 下一步：
  1. 执行跨节点 ping 验证（上方命令）
  2. 确认所有业务正常（Traefik / 监控栈 / ArgoCD）
  3. 若升到 3.30，可继续下一跳：
       bash $0 3.32.2
     若已到 3.32，则线2 完成，进入线3（kube-proxy IPVS → iptables）
EOF
  ;;
esac
