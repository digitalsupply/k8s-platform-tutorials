# 实验 06:Service 与负载均衡 — 深入 eBPF 数据面

**目标**:理解 Cilium 如何替代 kube-proxy,用 eBPF 实现 Service 负载均衡,并观察多副本分发。

## 背景知识

本集群开启了 `kube-proxy-replacement: true`,意味着**没有 kube-proxy**,
Service 的 ClusterIP/NodePort/LoadBalancer 负载均衡全部由 Cilium 的 **eBPF 程序**完成:
- 每个节点上,访问 Service IP 的数据包被 eBPF 拦截
- 根据后端集合,选择一个后端(Pod IP:Port)转发(DSR or 隧道)
- 以上全部在内核态完成,不经 iptables,低延迟高吞吐

## 步骤

### 1. 确认没有 kube-proxy

```bash
kubectl get pods -n kube-system | grep -i kube-proxy || echo "无 kube-proxy (已被 Cilium 替代)"
```

### 2. 查看 Service 的 eBPF 负载均衡表

```bash
# 本机节点上所有 Service 的 BPF LB 表
cagent bpf lb list
# 只看 web 服务 (ClusterIP 10.43.162.164:80)
cagent bpf lb list | grep -E "10.43.162.164"
```

找到 web Service → 观察其后端列表(两条,对应两个 web pod)。

### 3. 观察多副本负载均衡分发

web 有 2 个副本,分布在不同节点。用 test pod 连续访问并观察命中后端:

```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')
# 连续请求,看响应是否轮流/随机命中不同后端
for i in 1 2 3 4 5 6; do
  kubectl exec -n lab $POD -- curl -s http://web.lab.svc.cluster.local/hostname
done
echo
```

(nginx 的 `/hostname` 返回容器主机名,可看出命中了哪个后端 pod)

### 4. 查看 pod 身份到 Service 端点的 BPF 映射

```bash
cagent bpf ep list        # endpoint
cagent bpf ip list        # ip -> identity
```

### 5. 对比:直接访问 Pod IP vs 访问 Service

说明:直接访问 backend Pod IP 会绕过 Service 的 LB(但仍受策略约束)。

## 验证要点

- [ ] `kubectl get pods -n kube-system | grep kube-proxy` 为空
- [ ] `cagent bpf lb list` 中 web Service 对应 2 个后端
- [ ] 连续请求 `/hostname` 出现至少 2 个不同的后端主机名(负载均衡生效)

## 思考

1. 没有 kube-proxy、没有 iptables,Cilium 靠什么实现 Service 转发?
2. 访问 `/hostname` 命中的后端分布是否均匀?为什么 eBPF 用哈希/加权而非常规轮询?
