# 实验 01:基础概念 — 理解 Cilium 组件与身份

**目标**:掌握 Cilium 集群的基本监控命令,理解 Pod 在网络中的"身份"和 eBPF 数据面。

## 背景知识

Cilium 的核心是把网络功能(转发、负载均衡、安全策略)编译成 **eBPF 程序**注入 Linux 内核。
与传统 CNI 相比:
- 不走 iptables 链,而是由 eBPF 直接挂钩网络栈,性能更高
- 安全策略基于 **身份 (Identity)**,而不是 IP 地址 —— 即使 Pod 重建、IP 变了,身份保持不变

Cilium 组件:
- **cilium-agent** (DaemonSet,每节点一个):运行 eBPF 程序,负责转发和策略
- **cilium-operator**:管理集群级资源(身份分配、IPAM)
- **cilium-envoy** / **envoy**:L7 策略代理
- **hubble**:可观测性层

## 步骤

### 1. 查看 Cilium 整体状态

```bash
cilium status
```

重点看:Cilium / Operator / Envoy / Hubble Relay 是否 OK,Cluster Pods 数量。

### 2. 查看每个节点上的 Cilium agent

```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
cilium node list
```

### 3. 查看 Endpoint (每个 Pod 就是一个 endpoint)

agent 级命令,用便捷命令 `cagent` 在本机 cilium pod 内执行:

```bash
cagent endpoint list
```

注意 `IDENTITY` 一列 —— 这就是 Cilium 给每个 Pod 分配的安全身份;
`POLICY (ingress/egress) ENFORCEMENT` 列表示该端点当前是否执行策略(默认 Disabled,后续实验会变为 Enabled)。

### 4. 查看集群中的身份 (Identity)

```bash
cagent identity list
```

身份由 `k8s:label=value` 组合派生,例如 `k8s:app=web`。
`reserved:*` 是内置身份(host / world / remote-node 等)。

### 5. 直接查看 eBPF 程序/映射

```bash
cagent bpf endpoint list     # 端点的 BPF 状态
cagent bpf policy get <ENDID>   # 查看某 endpoint 的策略
cagent bpf lb list           # 负载均衡 BPF 表
cagent bpf ip list           # IP 与身份的对应
```

用 `cagent endpoint list` 找到 web pod 的 ENDPOINT ID,然后 `cagent bpf policy get <id>`。

### 6. 运行内建连接性自检 (可选)

这是 Cilium 官方推荐的健康检查,会创建临时 pod 做多维度连通性测试。

```bash
cilium connectivity test
```

> ⚠️ 本实验环境的沙箱访问外网受限:`registry.k8s.io`(connectivity test 的 dns-test-server 镜像所在)
> 无法拉取,而 `quay.io` 可以。因此完整套件可能因镜像拉取超时而不完整。
> 你可以用上面的基本命令替代验证连通性,无需强求跑通完整套件。

## 验证要点

- [ ] `cilium status` 全部 OK
- [ ] `cagent endpoint list` 看到 3 个节点上所有的 pod endpoint
- [ ] `cagent identity list` 能看到 `app=web`、`app=api`、`app=test` 对应身份
- [ ] `cilium connectivity test` 全部通过

## 思考

1. 为什么 Cilium 用身份而非 IP 做安全策略?(提示:Pod 重建换 IP 后身份是否保留)
2. `cilium bpf lb list` 和传统 iptables 的 nat 表区别是什么?
