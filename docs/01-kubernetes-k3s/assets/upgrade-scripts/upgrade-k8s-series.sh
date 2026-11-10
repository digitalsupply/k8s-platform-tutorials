#!/bin/bash
# ==============================================================================
# 线4 连续升级驱动：1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35
#   每级：换源→装包→快照→CP→修metrics→worker→验证
#   ★ 任一级验证失败立即停止，不继续下一级
#
# 用法: bash upgrade-k8s-series.sh 1.31 1.32 1.33 1.34 1.35
#        bash upgrade-k8s-series.sh status
# ==============================================================================
set -uo pipefail
PW='<redacted-password>'
declare -A V=([1.31]="1.31.14" [1.32]="1.32.13" [1.33]="1.33.13" [1.34]="1.34.12" [1.35]="1.35.9")
CP="m01 master01 master02"; WK="worker01 worker02 worker03"
LOG="/root/k8s-upgrade-1.29-to-1.35/work/k8s/series.log"
mkdir -p "$(dirname $LOG)"

ip(){ case $1 in m01)echo 10.0.0.61;;master01)echo 10.0.0.121;;master02)echo 10.0.0.120;;worker01)echo 10.0.0.122;;worker02)echo 10.0.0.123;;worker03)echo 10.0.0.124;;esac; }
k(){ kubectl "$@" 2>&1; }
kx(){ sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$(ip "$1") "${@:2}" 2>&1; }
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# ── 校验 ─────────────────────────────────────────────────────────────────────
verify(){
  local FAIL=0
  # 1. 版本一致
  local CV=$(k version -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['serverVersion']['gitVersion'])" 2>/dev/null)
  log "  集群版本: $CV"
  [ "$CV" = "v$1" ] || { log "  ✗ 版本不符(期望 v$1)"; FAIL=1; }
  # 2. ★轮询等待节点版本上报同步（kubelet 启动后上报有延迟，固定等待会误判）
  local NV="" NR=0 SYNC=0
  for i in $(seq 1 12); do
    NV=$(k get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null | sort -u | tr -d '\n')
    NR=$(k get nodes --no-headers 2>/dev/null | awk '{print $2}' | grep -c '^Ready')
    SYNC=0; [ "$NV" = "v$1" ] && SYNC=1
    if [ "$NR" = "6" ] && [ "$SYNC" = "1" ]; then break; fi
    [ $i -lt 12 ] && { log "  等待节点同步($i/12): Ready=$NR/6 版本集=$NV"; sleep 20; }
  done
  log "  节点: $NR/6 Ready | 版本集: $NV"
  [ "$NR" = "6" ] || { log "  ✗ 有节点 NotReady"; FAIL=1; }
  [ "$SYNC" = "1" ] || { log "  ✗ 节点版本未同步到 v$1"; FAIL=1; }
  # 3. etcd 3/3
  local EH=$(kx m01 'export ETCDCTL_API=3; P=/etc/kubernetes/pki/etcd; etcdctl --endpoints=https://10.0.0.61:2379,https://10.0.0.121:2379,https://10.0.0.120:2379 --cacert=$P/ca.crt --cert=$P/healthcheck-client.crt --key=$P/healthcheck-client.key endpoint health 2>/dev/null|grep -c healthy')
  log "  etcd: $EH/3 healthy"
  [ "$EH" = "3" ] || { log "  ✗ etcd 不健康"; FAIL=1; }
  # 4. 关键业务（★不能包装成 kubectl eval —— kubectl 无此子命令）
  local PROM=$(k get pod prometheus-prometheus-prometheus-0 -n monitoring --no-headers 2>/dev/null | awk '{print $2}')
  local KAFKA=$(k get kafka -n kafka --no-headers 2>/dev/null | awk '{print $2}')
  local CALICO=$(k get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c Running)
  log "  Prometheus: $PROM"
  log "  Kafka: $KAFKA"
  log "  Calico: $CALICO/$CALICO"
  [ "$PROM" = "2/2" ] || { log "  ✗ Prometheus 异常($PROM)"; FAIL=1; }
  [ "$KAFKA" = "True" ] || { log "  ✗ Kafka 异常($KAFKA)"; FAIL=1; }
  [ "$CALICO" = "6" ] || { log "  ✗ Calico 异常($CALICO/6)"; FAIL=1; }
  # 5. DNS（用固定 Pod 名避免并发重名；只判断能否解析出 clusterIP）
  local DNS=$(k run dnstest-$1-$RANDOM --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
    nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -c '10.96.0.1')
  log "  DNS: $([ "${DNS:-0}" -ge 1 ] && echo 正常 || echo 异常)"
  [ "${DNS:-0}" -ge 1 ] || FAIL=1

  # 6. Prometheus targets
  local TG=$(k exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null | jq -r '[.data.activeTargets[]|select(.health=="up")]|length' 2>/dev/null)
  log "  Prometheus targets: $TG/125"
  [ "${TG:-0}" -ge 110 ] || { log "  ✗ targets 掉过多($TG)"; FAIL=1; }
  return $FAIL
}

# ── 换源 ─────────────────────────────────────────────────────────────────────
switch_repo(){
  local MINOR=$1
  for N in $CP $WK; do
    if [ "$N" = "m01" ]; then
      kx $N "sed -i 's|baseurl=.*|baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/rpm/|; s|gpgkey=.*|gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/rpm/repodata/repomd.xml.key|' /etc/yum.repos.d/kubernetes.repo; dnf clean expire-cache -q 2>/dev/null; dnf makecache -q 2>/dev/null"
    else
      # ★结尾必须是 "URL<空格>/"，否则 Malformed
      kx $N "printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-new.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/deb/ /\n' > /etc/apt/sources.list.d/kubernetes.list; apt-get update -qq 2>/dev/null"
    fi
  done
}

# ── 装包 ─────────────────────────────────────────────────────────────────────
install_pkgs(){
  local N=$1 VER=$2
  if [ "$N" = "m01" ]; then
    kx $N "dnf install -y -q kubeadm-${VER}-150500.1.1.x86_64 >/dev/null 2>&1 && dnf install -y -q kubelet-${VER}-150500.1.1.x86_64 kubectl-${VER}-150500.1.1.x86_64 >/dev/null 2>&1 && echo OK || echo FAIL"
  else
    kx $N "apt-mark unhold kubeadm kubelet kubectl >/dev/null 2>&1; apt-get install -y -qq kubeadm=${VER}-1.1 >/dev/null 2>&1 && apt-get install -y -qq kubelet=${VER}-1.1 kubectl=${VER}-1.1 >/dev/null 2>&1 && apt-mark hold kubelet kubectl >/dev/null 2>&1 && echo OK || echo FAIL"
  fi
}

# ★修复1: apt-mark hold 会阻止服务重启 → 必须显式 restart 并验证进程确实是新版本
restart_kubelet(){
  local N=$1 VER=$2
  kx $N "systemctl restart kubelet && sleep 5" >/dev/null 2>&1
  # ★验证: kubelet 进程的启动时间必须晚于本次升级(用包文件 mtime 判断)
  local CHK=$(kx $N "P=\$(pgrep kubelet|head -1); [ -z \"\$P\" ] && echo NOPROC && exit; ST=\$(stat -c %Y /proc/\$P 2>/dev/null); PK=\$(stat -c %Y /usr/bin/kubelet 2>/dev/null);       BIN=\$(/usr/bin/kubelet --version 2>/dev/null|awk '{print \$2}');       if [ \"\$ST\" -ge \"\$PK\" ] 2>/dev/null; then echo \"OK \$BIN\"; else echo \"STALE \$BIN(proc#\$ST<bin#\$PK)\"; fi")
  echo "$CHK"
}

# ── 预拉镜像 ─────────────────────────────────────────────────────────────────
pull_imgs(){
  local VER=$1
  for N in $CP; do
    for I in kube-apiserver kube-controller-manager kube-scheduler; do
      kx $N "crictl pull registry.k8s.io/$I:v$VER >/dev/null 2>&1" >/dev/null
    done
  done
}

# ── ★修复2: 确保 /run/systemd/resolve/resolv.conf 存在 ──────────────────────
# Rocky 9.6 无此文件（systemd-resolved 未启用），而 kubelet 默认用它生成 Pod DNS
# ★缺失会导致重启 kubelet 后所有 Pod sandbox 创建失败（含 apiserver 静态 Pod）
ensure_resolv_conf(){
  local FIXED=0
  for N in $CP $WK; do
    local R=$(kx $N '[ -f /run/systemd/resolve/resolv.conf ] && echo OK || { mkdir -p /run/systemd/resolve && cp /etc/resolv.conf /run/systemd/resolve/resolv.conf && echo FIXED; }')
    if [ "$R" = "FIXED" ]; then log "  ⚠ $N 缺失 resolv.conf，已自动创建"; FIXED=$((FIXED+1)); fi
  done
  [ "$FIXED" = "0" ] && log "  ✓ resolv.conf 检查通过"
}

# ── ★pause 镜像 tag 保障（kubeadm 健康检查 Job 硬编码用它）─────────────────
#★ 本环境 registry.k8s.io 的 manifest 请求被拒（insufficient_scope），
#  但 aliyuncs 源可用且 digest 相同 → 给 k8s.io 名字打 tag
ensure_pause_tag(){
  local D="sha256:873ed75102791e5b0b8a7fcd41606c92fcec98d56d05ead4ac5131650004c136"
  for N in $CP $WK; do
    kx $N "crictl pull registry.aliyuncs.com/google_containers/pause:3.10 >/dev/null 2>&1; \
           ctr -n k8s.io images tag $D registry.k8s.io/pause:3.10 >/dev/null 2>&1" >/dev/null
  done
}

# ── 修 metrics bind-address ──────────────────────────────────────────────────
fix_metrics(){
  for N in $CP; do
    kx $N "mkdir -p /root/k8s-upgrade-1.29-to-1.35/work/k8s/manifest-backup; cp -a /etc/kubernetes/manifests/*.yaml /root/k8s-upgrade-1.29-to-1.35/work/k8s/manifest-backup/ 2>/dev/null; \
      sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' /etc/kubernetes/manifests/kube-controller-manager.yaml /etc/kubernetes/manifests/kube-scheduler.yaml; \
      IP=\$(hostname -I|awk '{print \$1}'); \
      grep -q listen-metrics-urls /etc/kubernetes/manifests/etcd.yaml && sed -i \"s#--listen-metrics-urls=.*#--listen-metrics-urls=http://127.0.0.1:2381,http://\$IP:2381#\" /etc/kubernetes/manifests/etcd.yaml" >/dev/null
  done
}

# ── 清 PDB 残留 ──────────────────────────────────────────────────────────────
cleanup_pods(){
  local N=$1
  # ★修复3: 清理已退出的孤儿容器（kubelet 重启后元数据残留会导致 StartContainer 报 container not found）
  kx $N "crictl rm -a >/dev/null 2>&1" >/dev/null
  for P in $(k get pods -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | \
    grep -vE 'calico-node|kube-proxy|alloy|speaker|node-exporter|loki-canary|nodeplugin|apiserver|etcd|controller-manager|scheduler|coredns|kube-vip' | awk '{print $2}'); do
    local NS=$(k get pods -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | grep " $P " | awk '{print $1}' | head -1)
    [ -n "$NS" ] && k delete pod $P -n $NS --grace-period=0 --force --timeout=30s >/dev/null 2>&1
  done
}

# ── 升级一个节点 ─────────────────────────────────────────────────────────────
upgrade_node(){
  local N=$1 VER=$2
  # ★只 drain 不 cordon —— 健康检查 Job 需要能调度到节点（kubeadm 内部要求）
  k drain $N --ignore-daemonsets --delete-emptydir-data --force --timeout=120s >/dev/null 2>&1
  cleanup_pods $N
  sleep 4

  # ★★ 顺序至关重要：先 kubeadm upgrade apply，最后才重启 kubelet
  #   反过来（先重启 kubelet）会让静态 Pod 用旧 manifest 重建，
  #   导致 kubeadm 健康检查超时、apply 静默失败。
  if [[ " $CP " == *" $N "* ]]; then
    # ★★ CP 节点：必须先装 kubeadm 新版，否则 apply 会被版本检查拒绝
    #   "Specified version ... higher than the kubeadm minor release (33 > 32)"
    #   但不能重启 kubelet —— 会让静态 Pod 用旧 manifest 重建，导致健康检查超时
    local R=$(install_pkgs $N $VER)
    [ "$R" = "OK" ] || { log "  ✗ $N 装包失败"; k uncordon $N >/dev/null 2>&1; return 1; }
    # apply（kubeadm 已是新版，但 kubelet 进程仍是旧版 —— apply 会自己重启静态 Pod）
    local OUT=$(kx $N "kubeadm upgrade apply v$VER -y --ignore-preflight-errors=CoreDNSUnsupportedPlugins 2>&1")
    # ★kubeadm 各版本成功提示语不同：
    #   ≤1.32: "[upgrade/successful] SUCCESS!..."
    #   ≥1.33: "[upgrade] SUCCESS! A control plane node..."
    if echo "$OUT" | grep -qE "upgrade/successful|SUCCESS!|successfully upgraded"; then
      log "    $N control-plane apply 成功"
    else
      log "  ✗ $N apply 失败:"
      echo "$OUT" | grep -iE "FATAL|error" | head -3 | sed 's/^/      /'
      k uncordon $N >/dev/null 2>&1
      return 1
    fi
  else
    local R=$(install_pkgs $N $VER)
    if [ "$R" != "OK" ]; then log "  ✗ $N 装包失败"; return 1; fi
    kx $N "kubeadm upgrade node 2>&1 | tail -1" >/dev/null
  fi

  # ★修复1: 显式重启 kubelet并验证进程确实换新
  local RK=$(restart_kubelet $N $VER)
  case "$RK" in
    OK*)   log "    $N kubelet $(echo $RK|cut -d' ' -f2) 已重启" ;;
    STALE*) log "  ✗ $N kubelet 进程未换新($RK)"; k uncordon $N >/dev/null 2>&1; return 1 ;;
    *)     log "  ✗ $N kubelet 重启异常($RK)"; k uncordon $N >/dev/null 2>&1; return 1 ;;
  esac
  k uncordon $N >/dev/null 2>&1
  return 0
}

# ── 快照 ─────────────────────────────────────────────────────────────────────
snapshot(){
  local BK="/root/k8s-upgrade-1.29-to-1.35/work/k8s/etcd-snap-$1-$(date +%Y%m%d-%H%M%S)"
  for N in $CP; do
    kx $N "mkdir -p $BK; ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt --key=/etc/kubernetes/pki/etcd/healthcheck-client.key snapshot save $BK/s-$N.db 2>&1 | grep -c saved" | grep -q 1 && \
      sshpass -p "$PW" scp -o StrictHostKeyChecking=no -q root@$(ip $N):$BK/s-$N.db $BK/ 2>/dev/null
  done
  log "  快照: $BK ($(ls -1 $BK/*.db 2>/dev/null|wc -l) 份)"
}

# ── 主流程 ───────────────────────────────────────────────────────────────────
if [ "${1:-}" = "status" ]; then
  echo "当前: $(k version -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['serverVersion']['gitVersion'])")"
  k get nodes --no-headers | awk '{printf "  %-10s %s\n",$1,$5}'
  exit 0
fi

for MINOR in "$@"; do
  VER=${V[$MINOR]}
  [ -z "$VER" ] && { log "未知版本 $MINOR"; exit 1; }
  log "════════════ 升级到 v$VER ════════════"
  CUR=$(k version -o json | python3 -c "import json,sys;print(json.load(sys.stdin)['serverVersion']['gitVersion'].lstrip('v'))" 2>/dev/null)
  EXPECT=$(awk -v c="$CUR" 'BEGIN{split(c,x,".");print "1."(x[2]+1)}')
  if [ "$MINOR" != "$EXPECT" ]; then log "✗ 版本跳跃非法:当前 $CUR，应升 $EXPECT"; exit 1; fi
  log "  $CUR → $VER"

  # ★清理上一级可能遗留的失败健康检查 Job
  for J in $(k get jobs -n kube-system --no-headers 2>/dev/null | grep upgrade-health | awk '{print $1}'); do
    k delete job $J -n kube-system --ignore-not-found >/dev/null 2>&1
  done
  ensure_resolv_conf
  snapshot "$MINOR"
  switch_repo "$MINOR"
  sleep 5
  log "  预拉镜像..."
  pull_imgs "$VER"
  ensure_pause_tag

  log "  升级 control-plane..."
  for N in $CP; do
    upgrade_node $N "$VER"
    sleep 15
  done
  fix_metrics
  log "  已修 metrics bind-address"

  log "  升级 worker..."
  for N in $WK; do
    upgrade_node $N "$VER"
    sleep 10
  done

  log "  ★等待稳定(60s)..."
  sleep 60
  log "  ── 验证 v$VER ──"
  if verify "$VER"; then
    log "  ✅ v$VER 验证通过"
  else
    log "  ✗✗ v$VER 验证失败 —— 停止,不继续下一级"
    log "  回滚参考: /root/k8s-upgrade-1.29-to-1.35/work/k8s/etcd-snap-$MINOR-*"
    exit 1
  fi
done
log "全部完成"
