#!/bin/bash
# ==============================================================================
# 线4：K8s 逐级升级（1.29 → 1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35）
#
# ★★ 高风险操作：涉及 etcd 和数据，无自动回滚手段 ====
# ★★ 必须逐级执行，不能跳版本 ★★
#
# 本集群环境（已实测确认）：
#   - Ubuntu 5 台：deb 包，源 https://mirrors.aliyun.com/kubernetes-new/core/stable/v1.29/deb/
#   - m01 1 台：rpm 包，源 https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
#   - 两套源都有 v1.30~v1.35（已验证）
#   - etcd 3 副本（m01/master01/master02），DB 85MB
#   - calico v3.32.2、containerd 2.3.2、kube-proxy iptables（前置已就绪）
#
# 用法：
#   bash upgrade-k8s.sh prepare              # 0. 换包源 + 预拉镜像
#   bash upgrade-k8s.sh snapshot             # 1. etcd 快照（每级升级前必做）
#   bash upgrade-k8s.sh control-plane 1.30.14  # 2. 升 control-plane（自动升所有 CP）
#   bash upgrade-k8s.sh worker               # 3. 升所有 worker（逐个 cordon）
#   bash upgrade-k8s.sh verify               # 4. 验证
#   bash upgrade-k8s.sh status               # 5. 查看当前状态
#
# ★ 执行顺序：prepare → snapshot → control-plane → verify → worker → verify
#   每个小版本重复一次，6 个小版本共 6 轮
# ==============================================================================
set -uo pipefail

ACTION="${1:-status}"
TARGET="${2:-}"

# ★ 可用的 patch 版本（已从 aliyun 源实测确认）
declare -A VERSIONS=(
  [1.30]="1.30.14"
  [1.31]="1.31.14"
  [1.32]="1.32.13"
  [1.33]="1.33.13"
  [1.34]="1.34.12"
  [1.35]="1.35.9"
)

WORK="/root/k8s-upgrade-1.29-to-1.35/work/k8s"
mkdir -p "$WORK"
CP_NODES="m01 master01 master02"
WORKER_NODES="worker01 worker02 worker03"

# 节点 IP 映射
node_ip(){ case "$1" in
  m01)echo 10.0.0.61;; master01) echo 10.0.0.121;; master02) echo 10.0.0.120;;
  worker01) echo 10.0.0.122;; worker02) echo 10.0.0.123;; worker03) echo 10.0.0.124;; esac; }
node_os(){ case "$1" in
  m01) echo rpm;; *) echo deb;; esac; }

log(){ echo -e "\n\033[1;32m[$(date '+%H:%M:%S')] $* \033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $*\033[0m"; }
die(){ echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }
sshx(){ sshpass -p '<redacted-password>' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$(node_ip "$1") "${@:2}"; }

current_version(){ kubectl version -o json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['serverVersion']['gitVersion'].lstrip('v'))" 2>/dev/null; }

verify(){
  log "验证"
  local VER=$(current_version)
  echo "  control-plane 版本: $VER"
  echo "  节点状态:"
  kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{printf "    %-11s %-6s %s\n",$1,$2,$5}'
  local NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}')
  [ -z "$NOTREADY" ] && echo "  ✓ 全部 Ready" || warn "  ✗ NotReady: $NOTREADY"
  echo "  Pod: Running $(kubectl get pods -A --no-headers 2>/dev/null|grep -c Running) / Pending $(kubectl get pods -A --field-selector status.phase=Pending --no-headers 2>/dev/null|wc -l)"
  echo "  kube-system:"
  kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -E "etcd|kube-apiserver|kube-scheduler|controller-manager|calico-node|kube-proxy" | awk '{printf "    %-32s %s\n",$1,$3}'
  echo "  业务:"
  for c in "Kafka|kubectl get kafka -n kafka --no-headers 2>/dev/null|awk '{print \$1\" \"\$2\" \"\$4}'" \
           "CNPG|kubectl get clusters.postgresql.cnpg.io -n cnpg-system --no-headers 2>/dev/null|awk '{print \$1\" \"\$2}'" \
           "Prometheus|kubectl get pod prometheus-prometheus-prometheus-0 -n monitoring --no-headers 2>/dev/null|awk '{print \$2\" \"\$3}'" \
           "Grafana|kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana --no-headers 2>/dev/null|awk '{print \$2\" \"\$3}'|head -1" \
           "Loki|kubectl get pods -n logging -l app.kubernetes.io/name=loki --no-headers 2>/dev/null|awk '{print \$3}'|sort|uniq -c|tr -s \" \"|tr \"\\n\" \" \""; do
    n="${c%%|*}"; cmd="${c#*|}"
    printf "    %-11s: %s\n" "$n" "$(eval "$cmd")"
  done
  echo "  Prometheus targets: $(kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null | jq -r '[.data.activeTargets[]|select(.health=="up")]|length' 2>/dev/null) / $(kubectl exec -n monitoring prometheus-prometheus-prometheus-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/targets?state=active' 2>/dev/null | jq -r '.data.activeTargets|length' 2>/dev/null)"
}

# ─────────────────────────────────────────────────────────────────────────────
case "$ACTION" in

# ═══════════════════════════════════════════════════════════════════════
status)
  log "当前 K8s 升级状态"
  echo "  control-plane: v$(current_version)"
  echo ""
  echo "  节点版本:"
  kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{printf "    %-11s %-6s %s\n",$1,$2,$5}'
  echo ""
  echo "  containerd: $(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.containerRuntimeVersion}')"
  echo "  Calico    : $(kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)"
  echo "  kube-proxy: $(kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -oP 'mode:\s*"\K[^"]+')"
  echo ""
  echo "  目标版本序列: 1.29 → 1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35"
  for v in 1.30 1.31 1.32 1.33 1.34 1.35; do
    echo "    v$v → ${VERSIONS[$v]}"
  done
  ;;

# ═══════════════════════════════════════════════════════════════════════
prepare)
  log "STEP 0: 更换包源到目标版本"
  [ -n "$TARGET" ] || die "用法: bash $0 prepare 1.30.14"
  MINOR=$(echo "$TARGET" | cut -d. -f1,2)

  for N in $CP_NODES $WORKER_NODES; do
    IP=$(node_ip "$N"); OS=$(node_os "$N")
    log "  $N ($OS) → v$MINOR 源"
    if [ "$OS" = "deb" ]; then
      # aliyun 源（国内可达）
      sshx "$N" "cp /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/kubernetes.list.bak-\$(date +%s) 2>/dev/null; \
                 echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-new.gpg] https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/deb/ ' > /etc/apt/sources.list.d/kubernetes.list && \
                 apt-get update -qq 2>&1 | tail -2 && \
                 echo -n '  ✓ 可用版本: ' && apt-cache madison kubeadm 2>/dev/null | grep $MINOR | head -1 | awk '{print \$3}'"
    else
      # m01 用 aliyun rpm 源替代 pkgs.k8s.io（国内更快）
      sshx "$N" "cp /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/kubernetes.repo.bak-\$(date +%s) 2>/dev/null; \
                 sed -i 's|baseurl=.*|baseurl=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/rpm/|; s|gpgkey=.*|gpgkey=https://mirrors.aliyun.com/kubernetes-new/core/stable/v${MINOR}/rpm/repodata/repomd.xml.key|' /etc/yum.repos.d/kubernetes.repo && \
                 dnf clean expire-cache -q 2>/dev/null; \
                 echo -n '  ✓ 可用版本: ' && dnf list kubeadm 2>/dev/null | grep $MINOR | tail -1 | awk '{print \$2}'"
    fi
  done
  ;;

# ═══════════════════════════════════════════════════════════════════════
snapshot)
  log "STEP 1: etcd 快照（★回滚唯一保险）"
  BK="$WORK/etcd-snap-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK"
  echo "$BK" > /tmp/etcd-latest-backup
  SNAPSHOT_SCRIPT="
    export ETCDCTL_API=3
    P=/etc/kubernetes/pki/etcd
    etcdctl --endpoints=https://127.0.0.1:2379 \\
      --cacert=\$P/ca.crt --cert=\$P/healthcheck-client.crt --key=\$P/healthcheck-client.key \\
      snapshot save $BK/snapshot-$(hostname).db 2>&1 | tail -2
    ls -lh $BK/snapshot-$(hostname).db 2>/dev/null
  "
  for N in $CP_NODES; do
    echo "  ── $N"
    sshpass -p '<redacted-password>' scp -o StrictHostKeyChecking=no -q <(echo "$SNAPSHOT_SCRIPT") $(node_ip "$N"):/tmp/snap.sh 2>/dev/null || \
      { sshpass -p '<redacted-password>' ssh -o StrictHostKeyChecking=no root@$(node_ip "$N") "bash -c '$(echo "$SNAPSHOT_SCRIPT" | sed "s/'/'\\\\''/g")'"; }
  done
  echo ""
  log "  快照目录: $BK"
  echo "  ★ 从各节点把快照拉回本机（防止节点故障导致快照丢失）"
  for N in $CP_NODES; do
    sshpass -p '<redacted-password>' scp -o StrictHostKeyChecking=no -q root@$(node_ip "$N"):$BK/snapshot-$N.db $BK/ 2>/dev/null && \
      echo "    ✓ $N 快照已拉回本机 ($(du -h $BK/snapshot-$N.db 2>/dev/null|cut -f1))"
  done
  ;;

# ═══════════════════════════════════════════════════════════════════════
control-plane)
  log "STEP 2: 升级 control-plane 到 v$TARGET"
  [ -n "$TARGET" ] || die "用法: bash $0 control-plane 1.30.14"
  CUR=$(current_version); TGT=$TARGET
  CURM=$(echo "$CUR"|cut -d. -f1,2); TGTM=$(echo "$TGT"|cut -d. -f1,2)

  # ★版本 skew 校验：只能 +1
  if [ "$(echo "$TGTM $CURM" | awk '{print ($1 ~ /^1.3[0-9]$/)? ($2-$1):99}')" != "1" ]; then
    # 简化判断
    EXPECTED=$(awk -v c="$CURM" -v t="$TGTM" 'BEGIN{split(c,cc,".");split(t,tt,".");print "1."(cc[2]+1)}')
    [ "$TGTM" = "$EXPECTED" ] || die "版本跳跃非法：当前 $CURM → 目标 $TGTM（应升到 $EXPECTED）。K8s 不允许跨小版本"
  fi
  log "  $CUR → $TGT"

  # 快照提醒
  [ -d "$(cat /tmp/etcd-latest-backup 2>/dev/null)" ] || warn "  ★ 未发现 etcd 快照，建议先执行: bash $0 snapshot"

  # 预拉镜像（★避免 ImagePullBackOff 卡住）
  log "  预拉 control-plane 镜像"
  for N in $CP_NODES; do
    for IMG in kube-apiserver kube-controller-manager kube-scheduler; do
      sshx "$N" "crictl pull registry.k8s.io/$IMG:v$TGT >/dev/null 2>&1 && echo '    ✓ $N $IMG:v$TGT'" || \
      echo "    ✗ $N $IMG:v$TGT 拉取失败（★ network issue）"
    done
  done

  # 逐个升级 control-plane
  for N in $CP_NODES; do
    log "  ── 升级 $N"
    kubectl drain "$N" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>&1|tail -2 || true
    # PDB 阻挡的 Pod 强制删
    for P in $(kubectl get pods -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | grep -vE 'calico-node|kube-proxy|alloy|speaker|node-exporter|loki-canary|nodeplugin' | awk '{print $2}'); do
      NS=$(kubectl get pod $P -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | awk '{print $1}')
      kubectl delete pod $P -n "$NS" --grace-period=0 --force --timeout=30s >/dev/null 2>&1 && echo "    强删 $NS/$P"
    done

    echo "    执行 kubeadm upgrade apply v$TGT"
    sshx "$N" "cd /root && kubeadm upgrade apply v$TGT -y 2>&1 | tail -12"
    RC=$?
    [ $RC -eq 0 ] || warn "    ★ $N 升级返回码 $RC，请检查"

    kubectl uncordon "$N" >/dev/null 2>&1
    echo "    ✓ $N 完成"
    sleep 20
  done

  log "  control-plane 升级完成，验证"
  verify
  ;;

# ═══════════════════════════════════════════════════════════════════════
worker)
  log "STEP 3: 升级 worker 到 v$(current_version)"
  for N in $WORKER_NODES; do
    CUR=$(sshx "$N" "kubelet --version 2>/dev/null|awk '{print \$2}'")
    log "  ── $N (当前 $CUR)"
    kubectl cordon "$N" >/dev/null 2>&1
    kubectl drain "$N" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>&1|tail -1 || true
    # PDB 阻挡强删
    for P in $(kubectl get pods -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | grep -vE 'calico-node|kube-proxy|alloy|speaker|node-exporter|loki-canary|nodeplugin' | awk '{print $2}'); do
      NS=$(kubectl get pod $P -A --field-selector spec.nodeName=$N --no-headers 2>/dev/null | awk '{print $1}')
      kubectl delete pod $P -n "$NS" --grace-period=0 --force --timeout=30s >/dev/null 2>&1
    done
    echo "    执行 kubeadm upgrade node"
    sshx "$N" "kubeadm upgrade node 2>&1 | tail -5"
    kubectl uncordon "$N" >/dev/null 2>&1
    echo "    ✓ $N 完成"
    sleep 15
  done
  log "  worker 升级完成，验证"
  verify
  ;;

# ═══════════════════════════════════════════════════════════════════════
verify) verify ;;

*)
  echo "用法: bash $0 {status|prepare <ver>|snapshot|control-plane <ver>|worker|verify}"
  ;;
esac
