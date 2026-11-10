# 实验 07:故障排查 — 用 Cilium 定位网络问题

**目标**:综合运用前面所学,面对"Pod 间不通"时,系统地用 Cilium 工具链定位问题。

## 排查方法论(顺序很重要)

1. **先看指标**:Pod 是否 Running、endpoint 是否 ready
2. **再看决策**:该 endpoint 的策略 enforcement 状态
3. **查身份**:来源/目标 identity 是什么、策略是否放行该 identity
4. **看数据面落地**:bpf 表里有没有对应条目
5. **实时抓现场**:cilium monitor / monitor truncate / pcapture

## 常用命令速查

```bash
# 1. 整体状态
cilium status

# 2. endpoint 状态与 enforcement
cagent endpoint list
cagent endpoint get <endpoint-id>

# 3. 查看某个 endpoint 生效的策略 (落到 bpf)
# 注意: bpf/endpoint 命令要在"该 pod 所在节点"的 agent 上执行,用 CILIUM_NODE 指定
CILIUM_NODE=<pod所在节点> cagent bpf policy get <endpoint-id>
CILIUM_NODE=<pod所在节点> cagent endpoint get <endpoint-id>   # 含身份/策略

# 4. 查看 identity
cagent identity list | grep <app>

# 5. 数据面:IP/LB 映射
cagent bpf ip list
cagent bpf lb list

# 6. 实时看丢弃/拒绝
kubectl exec -n kube-system <cilium-pod> -- cilium monitor --type drop
kubectl exec -n kube-system <cilium-pod> -- cilium monitor -v   # verbose,含 L7

# 7. 抓包
kubectl exec -n kube-system <cilium-pod> -- cilium monitor --type trace
```

## 实战演练:定位"test 访问 web 超时"

### 场景 A:策略导致(最经典)

按实验 03/05 给 web 施加 ingress 拒绝策略,然后 test→web 失败。用流程定位:

```bash
# 1. 确认 pod 和 endpoint 都 ready
kubectl get pod -n lab -l app=web -o wide
# 找到 web pod 所在的节点和 IP,得到 endpoint id
CILIUM_NODE=<web所在节点> cagent endpoint list | grep <web-ip>

# 2. 看到 enforcement=Enabled + 被拒
# 3. 查 web 生效策略,谁被放行了? (在 web 所在节点执行)
CILIUM_NODE=<web所在节点> cagent bpf policy get <web-endpoint-id>

# 4. 实时看 drop —— 解释"为什么"
kubectl exec -n kube-system <web所在节点的cilium-pod> -- cilium monitor --type drop
```

### 场景 B:身份不匹配

策略里写错 label(如 `role=curl` 写成 `role=curlx`),导致 test 没被放行。
用 identity 对比:
```bash
cagent identity list | grep -E "test|role"
kubectl get pod -n lab -l app=test --show-labels
```

### 场景 C:BGP/MTU/路由问题(DNS 常见)

Pod 能 ping 但 DNS 失败 / 大包丢:
```bash
cagent bpf ip list | grep <dns-ip>
# MTU 检查:cilium status 的 "IPv4 big TCP"
# 常见原因:overlay MTU 与底层不一致
cilium status | grep -i mtu
```

## 排查 Checklist (背下来很有用)

- [ ] `cilium status`:agent/operator/envoy 都 OK?
- [ ] endpoint ready?哪个节点?IP 多少?
- [ ] enforcement 是否 Enabled?哪一方(ingress/egress)?
- [ ] identity 是否正确匹配策略 label?
- [ ] bpf policy / lb / ip 表有没有该条目?
- [ ] monitor --type drop 有没有 strike?verdict 是什么?
- [ ] 是不是把策略限定在特定 namespace,而目标在别的 ns?

## 练习

给定故障:test 访问 api 超时。
请按上述方法论,逐步用命令判断是"策略拒绝"还是"服务未就绪",并给出修复。

> 提示:可用 `kubectl -n lab logs <test-pod>` 看客户端侧错误;
> 用 monitor --type drop 看服务端侧 mistrack。
> 最终打开权限或修复后,用 `curl` 验证恢复 200。
