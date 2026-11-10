#!/bin/bash
# ==============================================================================
# 线 1：containerd 1.7.22 → 2.3.2 LTS 升级脚本（单节点）
#   配套 runc 1.3.3 → 1.4.3（containerd 2.3.2 官方内置版本）
#   目标：containerd 2.3.2 + runc 1.4.3，config.toml 保留 v2 不migrate
#
# 用法：在目标节点上以 root 执行
#   bash upgrade-containerd.sh <pause-image>
# 例：
#   bash upgrade-containerd.sh registry.k8s.io/pause:3.10
#
# ★ 前置条件（必须已满足）：
#   1. 该节点已被 kubectl cordon + drain
#   2. 已在控制节点记录 crictl ps -a / crictl images 基线
#   3. 已确认 etcd 不在该节点（worker 节点无此问题）
# ==============================================================================
set -euo pipefail

CONTAINERD_VER="2.3.2"
RUNC_VER="1.4.3"
# ★ containerd 2.3.x 官方推荐的 pause 镜像；如担心外部仓库可换 registry 镜像
PAUSE_IMAGE="${1:-registry.k8s.io/pause:3.10}"

CONTAINERD_TAR="containerd-${CONTAINERD_VER}-linux-amd64.tar.gz"
RUNC_BIN_URL="https://github.com/opencontainers/runc/releases/download/v${RUNC_VER}/runc.amd64"
DL_DIR="/tmp/ctr-upgrade-$$"
BACKUP_TAG="1.7.22"

log(){ echo -e "\n\033[1;32m[$(date '+%H:%M:%S')] $* \033[0m"; }
warn(){ echo -e "\033[1;33m[WARN] $* \033[0m"; }
die(){ echo -e "\033[1;31m[ERROR] $* \033[0m"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 0/8  环境检查"
command -v containerd >/dev/null || die "未找到 containerd"
command -v systemctl >/dev/null || die "systemd 不可用"
[ "$(id -u)" -eq 0 ] || die "必须 root 执行"

# ★containerd 2.x 输出含"/containerd/v2"，旧正则会误匹配"v2"，需匹配完整 x.y.z
OLD_CTRD=$(containerd --version 2>/dev/null | grep -oP '\bv\K[0-9]+\.[0-9]+\.[0-9]+'|head -1)
OLD_RUNC=$(runc --version 2>/dev/null | awk '/^runc version/{print $3}')
echo "  当前 containerd : $OLD_CTRD"
echo "  当前 runc: $OLD_RUNC"
echo "  目标 containerd : $CONTAINERD_VER"
echo "  目标 runc       : $RUNC_VER"
echo "  pause 镜像      : $PAUSE_IMAGE"

# 前置安全检查
if [ "$OLD_CTRD" != "1.7.22" ]; then
  warn "当前 containerd 是 $OLD_CTRD，不是预期的 1.7.22"
  read -r -p "  继续吗？(yes/no) " a; [ "$a" = "yes" ] || die "已取消"
fi

# 确认 systemd 没被误用
if systemctl is-active --quiet kubelet && ! kubectl debug node/$(hostname)/test >/dev/null 2>&1; then
  warn "检测到节点可能有 Pod 运行中——请确认已完成 drain"
fi

mkdir -p "$DL_DIR"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 1/8  备份二进制与配置（★回滚依赖）"
BK="/root/ctr-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -a /usr/local/bin/containerd "$BK/containerd-$BACKUP_TAG" 2>/dev/null || true
# runc 路径节点间不一致（m01=/usr/bin，其余=/usr/local/sbin）
RUNC_PATH=$(command -v runc)
OLD_RUNC_VER=$(runc --version 2>/dev/null | awk '/^runc version/{print $3}')
cp -a "$RUNC_PATH" "$BK/runc-$OLD_RUNC_VER" 2>/dev/null || true
echo "$OLD_RUNC_VER" > "$BK/runc-old-version.txt"
cp -a /etc/containerd/config.toml "$BK/config.toml" 2>/dev/null || true
echo "$RUNC_PATH" > "$BK/runc-path.txt"
echo "  备份目录: $BK"
echo "  备份内容:"; ls -lh "$BK" | tail -n +2 | awk '{print "    "$5"\t"$9}'
[ -f "$BK/containerd-$BACKUP_TAG" ] || die "containerd 备份失败，回滚无保障，中止"

# 记录容器基线（供人工比对）
crictl ps -a > "$BK/crictl-ps-before.txt" 2>/dev/null || warn "crictl ps 记录失败"
crictl images > "$BK/crictl-images-before.txt" 2>/dev/null || warn "crictl images 记录失败"
BEFORE_CONTAINERS=$(grep -c . "$BK/crictl-ps-before.txt" 2>/dev/null || echo 0)
echo "  升级前容器数: $BEFORE_CONTAINERS"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 2/8  准备 containerd $CONTAINERD_VER 安装包"
cd "$DL_DIR"
# ★优先使用预置包（GitHub 对本集群网络不稳定，实测多次超时）
if [ -f "/tmp/${CONTAINERD_TAR}" ] && [ -f "/tmp/${CONTAINERD_TAR}.sha256sum" ]; then
  cp "/tmp/${CONTAINERD_TAR}" "/tmp/${CONTAINERD_TAR}.sha256sum" .
  echo "  使用预置安装包 /tmp/${CONTAINERD_TAR}"
else
  CD_URL="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/${CONTAINERD_TAR}"
  echo "  下载: $CD_URL"
  curl -fsSL --connect-timeout 20 --max-time 300 -o "$CONTAINERD_TAR" "$CD_URL" || die "下载失败。
★ 可从已升级节点复制：scp root@<已升级节点>:/tmp/ctr-upgrade-*/containerd-${CONTAINERD_VER}-linux-amd64.tar.gz /tmp/"
  curl -fsSL --connect-timeout 20 --max-time 120 -o "${CONTAINERD_TAR}.sha256sum" \
    "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VER}/${CONTAINERD_TAR}.sha256sum"
fi
echo "  sha256 校验:"
sha256sum -c "${CONTAINERD_TAR}.sha256sum" || die "★ sha256 校验失败，可能下载损坏，中止"
echo "  ✓ 校验通过"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 3/8  下载并安装 runc $RUNC_VER（★统一到 /usr/local/sbin）"
#★ 优先使用本地已校验的 runc（/tmp/runc.amd64，由官方 sha256 核对）
# ★ 实测教训：GitHub releases 对本集群网络间歇不可达（同一台机器 containerd 能下但 runc 不能），
#   可靠做法是从已升级节点取已验证副本+ 用 GitHub API 的 digest 核对 sha256
LOCAL_RUNC=/tmp/runc.amd64
if [ -f "$LOCAL_RUNC" ] && [ -x "$LOCAL_RUNC" ] \
   && "$LOCAL_RUNC" --version 2>/dev/null | grep -q "$RUNC_VER"; then
  echo "  ✓ 使用本地已校验的 runc: $("$LOCAL_RUNC" --version|head -1)"
  echo "    sha256: $(sha256sum "$LOCAL_RUNC" | cut -d' ' -f1)"
  # ★拷贝为 runc.amd64，使后续安装/自检逻辑与下载分支一致
  cp -f "$LOCAL_RUNC" ./runc.amd64 && chmod +x ./runc.amd64
else
  echo "  本地无 runc，尝试从 GitHub 下载..."
  for i in 1 2 3; do
    echo "  下载尝试 $i/3..."
    if curl -fsSL --connect-timeout 20 --max-time 180 -o runc.amd64 "$RUNC_BIN_URL"; then
      chmod +x runc.amd64
      if ./runc.amd64 --version 2>/dev/null | grep -q "$RUNC_VER"; then
        echo "  ✓ 下载成功并自检通过"; break
      fi
      warn "下载的 runc 版本不符（期望 $RUNC_VER），重试"
    else
      warn "下载失败，重试"
    fi
    sleep 5
  done
  [ -x ./runc.amd64 ] || die "runc $RUNC_VER 下载失败。可靠方案：从已升级节点(如 worker03)复制 /usr/local/sbin/runc 到 /tmp/runc.amd64，并核对 sha256 与 GitHub API digest 一致"
  chmod +x runc.amd64
fi
./runc.amd64 --version | grep -q "$RUNC_VER" || die "runc $RUNC_VER 自检失败"
echo "  最终 runc: $(./runc.amd64 --version|head -1)"

# ★关键顺序：先备份旧 runc，再安装新的（切勿反过来，否则会删掉刚装的）
RUNC_TARGET="/usr/local/sbin/runc"
if [ -f "$RUNC_TARGET" ] && [ "$RUNC_TARGET" != "$RUNC_PATH" ]; then
  OLDRUNCV=$(runc --version 2>/dev/null | awk '/^runc version/{print $3}')
  cp -a "$RUNC_TARGET" "${RUNC_TARGET}.old-${OLDRUNCV}"
  echo "  ✓ 旧 runc 已备份: $RUNC_TARGET.old-$OLDRUNCV"
fi
install -m 755 runc.amd64 "$RUNC_TARGET"
echo "  ✓ 已安装到 $RUNC_TARGET"
echo "  验证: $($RUNC_TARGET --version | head -1)"
[ -x "$RUNC_TARGET" ] || die "runc 安装后不可执行（检查是否误移动了刚装的文件）"
echo "  containerd 2.x 官方推荐 runc 路径: /usr/local/sbin/runc"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 4/8  安装 containerd $CONTAINERD_VER 二进制"
# 官方安装方式：tar Cxzvf /usr/local ...（二进制在 ./bin/）
# ★修正: tar 的 -C 必须放在文件参数之前（tar -C DIR -xzf FILE）
# ★且 containerd 2.x 包内无 containerd-shim（CRI v1alpha2 已移除）
# ★最简可靠方式：直接解出 bin/ 整个目录
# containerd 2.x 包内 bin/ 只有 4 项，无 shim-runc-v1（CRI v1alpha2 已移除）
echo "  包内 bin/ 内容:"
tar tzf "$CONTAINERD_TAR" | grep '^bin/' | sed 's/^/    /'
echo "  解压 bin/ 到 /usr/local"
tar -C /usr/local -xzf "$CONTAINERD_TAR" bin/
[ -f /usr/local/bin/containerd ] || die "containerd 二进制解压失败"
echo "  ✓ 已安装到 /usr/local/bin/"
# 关键：2.x tar 包还会带containerd-shim-runc-v1，但 CRI v1alpha2 在 2.0 已移除
# 本集群使用 CRI v1（kubelet 1.29），不需要 shim-runc-v1
[ -f /usr/local/bin/containerd-shim-runc-v2 ] || die "shim-runc-v2 缺失，2.x 必需"
echo "  ✓ containerd-shim-runc-v2 存在（CRI v1 必需）"

NEW_CTRD=$(containerd --version 2>/dev/null | grep -oP '\bv\K[0-9]+\.[0-9]+\.[0-9]+'|head -1)
NEW_RUNC=$(runc --version 2>/dev/null | awk '/^runc version/{print $3}')
echo "  验证: containerd=$NEW_CTRD  runc=$NEW_RUNC"
[ "$NEW_CTRD" = "$CONTAINERD_VER" ] || warn "containerd 版本读数异常（可能 systemd 尚未 reload）"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 5/8  更新 config.toml"
CFG=/etc/containerd/config.toml
echo "  当前 version: $(grep -oP '^\s*version\s*=\s*\K[0-9]+' "$CFG"|head -1)"
echo "  ★ 决策: 保留 version=2 不migrate（containerd 2.x 向下兼容读 v2；保留以便回滚）"

# 只改 pause 镜像（雷浩决策 5）
OLD_PAUSE=$(grep -oP 'sandbox_image\s*=\s*"\K[^"]+' "$CFG" 2>/dev/null|head -1)
echo "  旧 pause 镜像: ${OLD_PAUSE:-无}"
if grep -q 'sandbox_image' "$CFG"; then
  sed -i "s|sandbox_image = \".*\"|sandbox_image = \"${PAUSE_IMAGE}\"|" "$CFG"
  echo "  ✓ 已更新为: $PAUSE_IMAGE"
else
  #新版 manifest 结构：[plugins.'io.containerd.cri.v1.runtime'.containerd]
  # pause 镜像在 2.x 中位于 [plugins.'io.containerd.cri.v1.runtime'] sandbox_image
  warn "config 中未找到 sandbox_image，未修改。若容器启动失败请手动检查 pause 配置"
fi

# ★★ 关键（1.7→2.x 的关键差异）：显式设置 BinaryName
# containerd 2.x 通过 shim 调用 runc，shim 的 PATH 不含/usr/local/sbin，
# 若 BinaryName 为空会导致 kubelet 的 exec 探针全部失败：
#   "OCI runtime exec failed: exec: \"runc\": executable file not found in $PATH"
log "STEP 5b  ★ 显式设置 runc 绝对路径（containerd 2.x shim 必需）"
if grep -q 'BinaryName' "$CFG"; then
  CUR_BN=$(grep -oP 'BinaryName\s*=\s*"\K[^"]*' "$CFG" | head -1)
  if [ "$CUR_BN" != "/usr/local/sbin/runc" ]; then
    cp -a "$CFG" "${CFG}.bak-before-binaryname"
    sed -i 's|BinaryName = .*|BinaryName = "/usr/local/sbin/runc"|' "$CFG"
    echo "  ✓ 已设置 BinaryName = /usr/local/sbin/runc（原值: ${CUR_BN:-空}）"
  else
    echo "  ✓ BinaryName 已正确"
  fi
else
  warn "config 中未找到 BinaryName 字段，请人工确认"
fi

# SystemdCgroup 必须保持 true（与 kubelet cgroupDriver=systemd 一致）
SDCG=$(grep -oP 'SystemdCgroup\s*=\s*\K\w+' "$CFG"|head -1)
if [ "$SDCG" = "true" ]; then
  echo "  ✓ SystemdCgroup=true 保持不变（与 kubelet 一致）"
else
  warn "SystemdCgroup=$SDCG，请确认与 kubelet cgroupDriver 一致（应为 true/systemd）"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 6/8  重启 containerd并检查 CRI"
systemctl daemon-reload
systemctl restart containerd
sleep 5
if ! systemctl is-active --quiet containerd; then
  warn "containerd 启动失败！最近错误:"
  journalctl -u containerd --since "3 min ago" --no-pager | tail -25
  die "containerd 未正常运行，请检查上述日志。★备份在 $BK"
fi
echo "  ✓ containerd 服务 active"

echo "  crictl info:"
if crictl info > /tmp/crictl-info-after.txt 2>&1; then
  # ★不要 grep 整个 crictl info（它包含 ignoreXxxErrors 等字段名，会误判）
  if crictl info 2>&1 | grep -q '"lastUpdate"'; then
    echo "    ✓ CRI 正常响应"
  else
    warn "crictl info 响应异常"
  fi
else
  die "crictl info 失败"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 7/8  验证容器零重建（★关键）"
crictl ps -a > "$BK/crictl-ps-after.txt" 2>/dev/null || true
crictl images > "$BK/crictl-images-after.txt" 2>/dev/null || true
AFTER_CONTAINERS=$(grep -c . "$BK/crictl-ps-after.txt" 2>/dev/null || echo 0)
echo "  升级前容器数: $BEFORE_CONTAINERS"
echo "  升级后容器数: $AFTER_CONTAINERS"
if [ "$BEFORE_CONTAINERS" -eq "$AFTER_CONTAINERS" ]; then
  echo "  ✓ 容器数一致，无重建"
else
  warn "容器数变化！请人工 diff:"
  diff <(cut -c1-60 "$BK/crictl-ps-before.txt"|sort) <(cut -c1-60 "$BK/crictl-ps-after.txt"|sort) | head -20 || true
fi

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 8/8  检查日志与kubelet"
# ★只用容器d 本次重启之后的时间窗口（实测教训：修复前的错误会污染统计）
RESTART_TS=$(systemctl show containerd -p ActiveEnterTimestamp --value)
echo "--- containerd 错误日志（仅本次重启后）---"
echo "  重启时间: $RESTART_TS"
# ★只统计 level=error（warning/info 是正常的插件跳过信息，不算错误）
ERRS=$(journalctl -u containerd --since "$RESTART_TS" --no-pager | grep -c 'level=error' || true)
WARN_N=$(journalctl -u containerd --since "$RESTART_TS" --no-pager | grep -c 'level=warning' || true)
echo "  level=error: $ERRS | level=warning: $WARN_N（warning 为旧 1.x 配置字段被忽略，无害）"
if [ "${ERRS:-0}" -gt 0 ]; then
  warn "发现 $ERRS 条 error，请检查:"
  journalctl -u containerd --since "$RESTART_TS" --no-pager | grep 'level=error' | head -15
else
  echo "  ✓ 无 error/panic"
fi

echo "--- kubelet 状态 ---"
if systemctl is-active --quiet kubelet; then
  echo "  ✓ kubelet active"
  CJ=$(journalctl -u kubelet --since "5 min ago" --no-pager | grep -icE "cgroup.*(error|fail)|failed to create containerd" || true)
  [ "${CJ:-0}" -gt 0 ] && warn "kubelet 有 cgroup 相关错误（$CJ 条）" || echo "  ✓ kubelet 无 cgroup 错误"
else
  warn "kubelet 未运行"
fi

echo "--- pause 镜像预拉取（避免首次调度失败）---"
crictl pull "$PAUSE_IMAGE" 2>/dev/null && echo "  ✓ $PAUSE_IMAGE 已就绪" || warn "pause 镜像拉取失败（K8s 会重试，非致命）"

# ─────────────────────────────────────────────────────────────────────────────
cat <<EOF

══════════════════════════════════════════════════════════════
  containerd 升级完成（节点级）
  旧: $OLD_CTRD / runc $OLD_RUNC   →   新: $CONTAINERD_VER / runc $RUNC_VER
  备份目录: $BK
══════════════════════════════════════════════════════════════

★ 请在【控制节点】执行以下验证，通过后再继续下一节点：

  kubectl get node $(hostname)
      → 期望 STATUS=Ready

  kubectl get pods -A --field-selector spec.nodeName=$(hostname)
      → 期望全部 Running/Completed，无异常重启

  # CNI 验证（Calico 跨节点网络）
  kubectl -n kube-system get pods -l k8s-app=calico-node -o wide | grep $(hostname)
      → 期望 Running

★ 全部通过后执行：
  kubectl uncordon $(hostname)

★ 若需回滚：
  bash $DL_DIR/../rollback-containerd.sh $BK     （或手动按下方步骤）
  cp $BK/containerd-$BACKUP_TAG /usr/local/bin/containerd
  cp $BK/runc-1.3.3 \$(cat $BK/runc-path.txt)
  systemctl restart containerd
EOF
