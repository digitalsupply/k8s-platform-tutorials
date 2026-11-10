#!/usr/bin/env bash
# 便捷封装:在本地节点的 cilium agent 内执行命令
# 用法: ./cagent endpoint list  或  source 后直接 cagent <args>
cagent() {
  local node="${CILIUM_NODE:-$(hostname)}"
  local pod
  pod=$(kubectl get pod -n kube-system -l k8s-app=cilium \
        -o jsonpath="{.items[?(@.spec.nodeName=='$node')].metadata.name}")
  if [[ -z "$pod" ]]; then
    echo "未找到 $node 上的 cilium pod" >&2; return 1
  fi
  kubectl exec -n kube-system "$pod" -- cilium "$@"
}
export -f cagent
