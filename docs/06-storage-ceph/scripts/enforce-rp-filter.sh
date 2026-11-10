#!/usr/bin/env bash
# 在每台 K8s 节点上执行（root），幂等。
# 作用：将 rp_filter 从 strict(1) 调整为 loose(2)，并持久化到 /etc/sysctl.d。
set -euo pipefail

cat >/etc/sysctl.d/99-zz-k8s-rp-filter.conf <<'EOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.eth0.rp_filter = 2
net.ipv4.conf.eth1.rp_filter = 2
EOF

# 立即生效（/etc/sysctl.d 里的接口名可能因节点而异，这里按实际接口兜底）
sysctl --system >/dev/null
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
  echo 2 >"$f"
done

echo "[ok] $(hostname):"
for i in all default eth0 eth1; do
  [ -e "/proc/sys/net/ipv4/conf/$i/rp_filter" ] && \
    printf '  %-8s = %s\n' "$i" "$(cat /proc/sys/net/ipv4/conf/$i/rp_filter)"
done
