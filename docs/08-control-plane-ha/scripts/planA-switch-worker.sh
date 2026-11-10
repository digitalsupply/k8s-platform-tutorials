#!/bin/bash
# 方案A：把 worker 的 kubelet.conf 默认 cluster 从 m01(10.0.0.61) 切到 VIP(10.0.0.168)
# 用法: bash planA-switch-worker.sh <workerNN>
# 逐台执行；失败自动回滚并重启 kubelet。
set -uo pipefail
PW='<redacted-password>'
N=${1:?usage: $0 <workerNN>}
case $N in
  worker01) IP=10.0.0.122;;
  worker02) IP=10.0.0.123;;
  worker03) IP=10.0.0.124;;
  *) echo "unknown node $N"; exit 2;;
esac
OLD='https://10.0.0.61:6443'
NEW='https://10.0.0.168:6443'
TS=$(date +%Y%m%d-%H%M%S)
BK="/etc/kubernetes/kubelet.conf.planAbak.$TS"

R(){ sshpass -p "$PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$IP "$@" 2>&1; }

echo "### [$N / $IP] 步骤1: 备份 + 前置校验"
R "
set -e
cp -a /etc/kubernetes/kubelet.conf $BK
n=\$(grep -c '$OLD' /etc/kubernetes/kubelet.conf)
echo \"  backup=$BK  occurrences($OLD)=\$n\"
[ \"\$n\" = '1' ] || { echo '  ABORT: 期望恰好1处旧 server，实际 '\$n; exit 3; }
grep -q 'current-context: default-context' /etc/kubernetes/kubelet.conf || { echo '  ABORT: current-context 非 default-context'; exit 3; }
grep -q 'certificate-authority-data' /etc/kubernetes/kubelet.conf || { echo '  ABORT: 缺少 CA'; exit 3; }
echo '  前置校验通过'
" || { echo "!! 前置校验失败，未改动，退出"; exit 1; }

echo "### [$N] 步骤2: 单行替换 server -> VIP"
R "sed -i 's|$OLD|$NEW|' /etc/kubernetes/kubelet.conf; diff $BK /etc/kubernetes/kubelet.conf; echo '  diff-rc='\$?"

echo "### [$N] 步骤3: 重启 kubelet"
R "systemctl restart kubelet; sleep 8; systemctl is-active kubelet; systemctl status kubelet --no-pager | head -5"

echo "### [$N] 步骤4: 校验 kubelet 与 API 连接（VIP 连接 + 身份）"
R "ss -tnp 2>/dev/null | grep 10.0.0.168:6443 | grep kubelet || echo '  [!] 未见 kubelet 到 VIP 的连接'"
R "kubectl --kubeconfig=/etc/kubernetes/kubelet.conf auth whoami 2>&1 | head -3"
echo "### [$N] 步骤5: 本机 kubelet 日志尾"
R "journalctl -u kubelet --since '-60s' --no-pager | tail -8"
echo "BACKUP_FILE=$BK"
