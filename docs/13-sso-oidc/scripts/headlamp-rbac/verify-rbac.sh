#!/usr/bin/env bash
# 验证 Headlamp 两个用户 ServiceAccount 的 RBAC 边界。
# 不依赖 Headlamp / 浏览器，直接问 apiserver。
#
# 用法:
#   ./verify-rbac.sh
set -euo pipefail

ACTS=(
  "list namespaces"
  "list pods"
  "create pods"
  "delete deployments"
  "get secrets"
  "create clusterrolebindings"
  "exec pods"
  "get nodes"
  "get nodes/proxy"
  "impersonate users"
)

check() {
  local sa="$1" act="$2"
  if kubectl auth can-i --as="system:serviceaccount:headlamp:$sa" $act >/dev/null 2>&1; then
    printf '  %-28s yes\n' "$act"
  else
    printf '  %-28s no\n' "$act"
  fi
}

for sa in headlamp-root headlamp-bigdev; do
  echo "--- system:serviceaccount:headlamp:$sa"
  for act in "${ACTS[@]}"; do
    check "$sa" "$act"
  done
  echo
done

echo "--- 对照：没有绑定的身份（相当于没有 token 的 smallops）"
kubectl auth can-i --as=system:serviceaccount:headlamp:headlamp-nonexistent \
  list pods 2>/dev/null || true

echo
echo "预期:"
echo "  headlamp-root   : 全部 yes"
echo "  headlamp-bigdev : 读/写 yes；exec、RBAC 写、nodes、nodes/proxy、impersonate no"
echo "  nonexistent     : no"
