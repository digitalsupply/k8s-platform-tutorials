# 实验 05:高级 — 默认拒绝 + 跨命名空间 + 加密概念

**目标**:把前面学的串起来,实现"命名空间级零信任",并理解基于身份的安全与加密选项。

## 背景知识

- Cilium 策略是**累加式**的:默认允许,一旦有策略针对某 endpoint 即默认拒绝。
- 可用 `matchLabels` 做**跨命名空间**匹配(identity 里带 namespace 标签)。
- Cilium 支持对工作负载间流量加密:**IPsec** 或 **WireGuard**(透明,无需应用修改)。

## 步骤

### 1. 用命名空间标签做"租户隔离"

Kubernetes 会给每个 namespace 打标签 `kubernetes.io/metadata.name`。
先给 lab 相关命名空间验证该标签已被 Cilium 纳入身份。

```bash
kubectl get ns --show-labels
cagent identity list | grep -i "namespace"
```

### 2. 全面默认拒绝(演示零信任)

为 web 同时定义 ingress + egress 的默认拒绝策略(只有显式放行的能过):

`05-deny-all.yaml`:
```bash
kubectl apply -f 05-deny-all.yaml
```

验证几乎全部被阻断:
```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')
# test -> web: 被拒
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 6 http://web.lab.svc.cluster.local/ || echo "blocked"
# web -> api: 被拒 (egress 默认拒绝)
kubectl exec -n lab $(kubectl get pod -n lab -l app=web -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s -o /dev/null -w "%{http_code}\n" --max-time 6 http://api.lab.svc.cluster.local/ || echo "blocked"
```

观察 `cilium monitor --type drop` 了解是谁拒绝的。

### 3. 渐进式放行(最小权限)

在 deny-all 基础上,只放行 test→web:80。参考实验 03 的 `03-web-ingress.yaml`。
观察:放行一条,连通一条;没放行的仍被拒。体会"一票否决、增量放行"。

### 4. 加密(IPsec/WireGuard)概念

Cilium 加密是**透明**的:在工作负载间加解密,应用无感知。

```bash
# 查看当前加密状态
cilium status | grep -i encrypt
# cluster 里每个节点的 cilium-config
kubectl get cm -n kube-system cilium-config -o jsonpath='{.data.encryption}'
```

开启加密需要修改 Helm 配置(生产环境),本实验不实际改动,仅理解概念:
- IPsec:静态密钥,所有节点共享
- WireGuard:自动密钥交换,性能更好
- 两者都只在**跨节点、跨网络**时加密(同节点同主机网络内不加密以省开销)

### 5. 清理

```bash
kubectl delete -f 05-deny-all.yaml
```

## 验证要点

- [ ] deny-all 后 test→web、web→api 均被阻止
- [ ] 增量放行 test→web 后,该条连通、其它仍拒
- [ ] enforcement 体现在 web 端点的 ingress 与 egress 均为 Enabled
- [ ] 理解加密是透明的(应用无感)

## 思考

1. 为什么默认拒绝 + 最小权限放行能提升安全性?(横向移动被切断)
2. 加密只影响跨节点流量,这对性能优化意味着什么?
