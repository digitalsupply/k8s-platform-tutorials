#!/bin/sh
# 只读采集中间件 OS 层证据；不修改 sysctl、不重启服务、不写数据。
set -eu

echo "=== host"
uname -a
echo "THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
echo "THP_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"
sysctl vm.overcommit_memory vm.swappiness net.core.somaxconn 2>/dev/null || true
sysctl net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog 2>/dev/null || true
sysctl net.ipv4.ip_local_port_range net.ipv4.tcp_max_tw_buckets fs.nr_open 2>/dev/null || true
echo "ulimit_n=$(ulimit -n)"

echo
echo "=== redis"
for ns in compassio deeptutor argocd; do
  kubectl -n "$ns" get pods 2>/dev/null | grep -i redis || true
done

echo
echo "=== kafka"
kubectl -n kafka get kafka my-cluster 2>/dev/null || true
kubectl -n kafka get pods 2>/dev/null | grep -E 'kafka|strimzi' || true

echo
echo "=== nginx"
kubectl get pods -A 2>/dev/null | grep -i nginx || true
kubectl -n compassio get deploy compassio-frontend 2>/dev/null || true

echo
echo "=== postgres"
kubectl -n cnpg-system get cluster pg16-ceph 2>/dev/null || true

echo
echo "=== mysql/mariadb"
kubectl get pods -A 2>/dev/null | grep -Ei 'mysql|maria' || echo "not deployed"
