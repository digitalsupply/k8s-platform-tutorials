#!/usr/bin/env bash
# 只读检查：节点 CPU 是否满足 x86-64-v3（以及 Ceph-CSI 标准镜像常用的指令集）。
#
# 用法：
#   bash check_cpu_v3.sh
#   NODES="m01=10.0.0.61 worker01=10.0.0.122" bash check_cpu_v3.sh
#
# 说明：
#   - 默认使用 SSH 读取 /proc/cpuinfo，需要 root 免密；
#   - 只读，不修改任何节点；
#   - 退出码：0 全部满足，1 有节点缺失指令集或不可达。

set -uo pipefail

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

DEFAULT_NODES="m01=10.0.0.61 master01=10.0.0.121 master02=10.0.0.120 worker01=10.0.0.122 worker02=10.0.0.123 worker03=10.0.0.124"
NODES=${NODES:-$DEFAULT_NODES}

# x86-64-v3 的典型要求（不同编译器/发行版略有差异）
REQUIRED=(avx avx2 bmi1 bmi2 fma f16c movbe)

printf "%-10s %-8s %-30s %s\n" NODE STATUS MODEL "MISSING"
bad=0

for pair in $NODES; do
  name=${pair%%=*}
  ip=${pair##*=}

  out=$(ssh "${SSH_OPTS[@]}" "root@$ip" \
    'grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | xargs; grep -m1 "^flags" /proc/cpuinfo' \
    2>/dev/null) || {
      printf "%-10s %-8s %-30s %s\n" "$name" "UNREACH" "-" "ssh failed"
      bad=1
      continue
    }

  model=$(printf '%s\n' "$out" | head -1)
  flags=$(printf '%s\n' "$out" | tail -1)
  missing=""
  for f in "${REQUIRED[@]}"; do
    printf '%s\n' "$flags" | grep -qw "$f" || missing="$missing $f"
  done

  if [[ -z "$missing" ]]; then
    printf "%-10s %-8s %-30s %s\n" "$name" "v3-OK" "$model" "-"
  else
    printf "%-10s %-8s %-30s %s\n" "$name" "v3-LOW" "$model" "$missing"
    bad=1
  fi
done

exit "$bad"
