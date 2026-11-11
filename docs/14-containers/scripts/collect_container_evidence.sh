#!/usr/bin/env bash
# 只读采集容器运行时证据：Docker / containerd / CRI / cgroup / netns。
#
# 用法：
#   bash collect_container_evidence.sh > container-evidence.txt
#   ssh root@host 'bash -s' < collect_container_evidence.sh > host-container.txt
#
# 不读取 Secret、环境变量、镜像内容。

set -uo pipefail
section() { printf '\n\n===== %s =====\n' "$*"; }
run() { printf '\n$ %s\n' "$*"; "$@" 2>&1 || printf '[exit=%s]\n' "$?"; }
run_sh() { printf '\n$ %s\n' "$*"; bash -c "$*" 2>&1 || printf '[exit=%s]\n' "$?"; }
have() { command -v "$1" >/dev/null 2>&1; }

section "0. 主机"
run_sh 'date -Is; hostname; uname -r; systemctl is-active docker containerd 2>/dev/null'

section "1. Docker"
if have docker; then
  run_sh 'docker version 2>/dev/null | head -20'
  run_sh 'docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Cgroup|Runtimes|Default Runtime|Security|Docker Root Dir"'
  run_sh 'docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}" 2>/dev/null | head -30'
  run_sh 'docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | head -30'
  run_sh 'docker system df 2>/dev/null'
else
  echo "docker not installed"
fi

section "2. containerd / CRI"
if have crictl; then
  run_sh 'crictl version 2>/dev/null'
  run_sh 'crictl info 2>/dev/null | head -50'
  run_sh 'crictl pods 2>/dev/null | head -20'
  run_sh 'crictl ps -a 2>/dev/null | head -20'
  run_sh 'crictl images 2>/dev/null | head -20'
  run_sh 'crictl imagefsinfo 2>/dev/null | head -30'
fi
if have ctr; then
  run_sh 'ctr namespaces list 2>/dev/null'
  run_sh 'ctr -n k8s.io containers list 2>/dev/null | head -10'
  run_sh 'ctr -n k8s.io tasks list 2>/dev/null | head -10'
  run_sh 'ctr -n k8s.io images list 2>/dev/null | head -10'
  run_sh 'ctr -n moby images list 2>/dev/null | head -10'
fi

section "3. 进程与 cgroup"
run_sh 'ps -eo pid,ppid,user,stat,comm,args | grep -E "containerd|shim|pause|runc|buildkit" | grep -v grep | head -30'
run_sh 'cat /proc/self/cgroup; cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null'
run_sh 'systemd-cgls /kubepods.slice 2>/dev/null | head -25'
run_sh 'find /sys/fs/cgroup/kubepods.slice -name memory.max 2>/dev/null | head -5 | while read f; do echo "$f = $(cat $f)"; done'

section "4. 网络 namespace（样本）"
run_sh 'lsns -t net -o NS,PID,COMMAND 2>/dev/null | head -10'
run_sh 'ip -br link | grep -E "lxc|cilium|veth" | head -20'

section "5. 存储"
run_sh 'df -hT; df -i'
run_sh 'findmnt -t overlay -o TARGET,SOURCE,OPTIONS 2>/dev/null | head -10'
run_sh 'du -sh /var/lib/docker /var/lib/containerd /var/lib/buildkitd-cache 2>/dev/null'

section "6. 结束"
run_sh 'date -Is'
