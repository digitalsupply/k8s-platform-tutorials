# 实验 03:网络策略 L3/L4 — 学会放行与拦截

**目标**:掌握 Cilium 默认拒绝模型,用标签和端口精确控制谁可以访问谁。

## 背景知识

Cilium 的策略模型是 **默认允许** —— 除非你为某 endpoint 定义了策略,否则自由互通。
一旦某个方向定义了策略,该方向就变成 **默认拒绝**,只允许策略中显式放行的流量。
这正是实现**零信任**的基础。

Cilium 提供两种资源:
- `NetworkPolicy` (通用,与 Calico 也兼容的 K8s 标准)
- `CiliumNetworkPolicy` (Cilium 扩展,支持 L7、DNS、更细粒度,本实验重点)

Cilium 策略按 **identity(身份)** 匹配,而非 IP。所以即使 Pod 重建换 IP,策略依然生效。

> ⚠️ 重要概念:策略一旦应用,enforcement 从 Disabled 变为 Enabled,Cilium 只在**应用了该策略的 pod** 上做默认拒绝。

## 实验应用拓扑

```
test (curl)  ---->  web (nginx svc:80)  ---->  api (httpd svc:80)
```

一开始三者可以自由互通。我们用策略逐步收紧。

## 步骤

### 1. 确认基线:默认全通

```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')
# test -> web : 200
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "web:%{http_code}\n" http://web.lab.svc.cluster.local/
# test -> api : 200
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "api:%{http_code}\n" http://api.lab.svc.cluster.local/
# web 的另外一个 pod -> api
WEBPOD=$(kubectl get pod -n lab -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n lab $WEBPOD -- curl -s -o /dev/null -w "web->api:%{http_code}\n" http://api.lab.svc.cluster.local/
```

### 2. 应用策略:只允许 test 访问 web (ingress 默认拒绝)

`03-web-ingress.yaml`:只放行标签为 `role=curl` 的 pod 访问 web 的 80 端口。

```bash
kubectl apply -f 03-web-ingress.yaml
sleep 3
```

验证:
```bash
# test -> web : 200 (role=curl 被放行)
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "test->web:%{http_code}\n" http://web.lab.svc.cluster.local/
# web 的其他 pod -> web:被拒绝 (访问 web 的 pod,非 curl 身份)
WEBPOD=$(kubectl get pod -n lab -l app=web -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n lab $WEBPOD -- curl -s -o /dev/null -w "web->web(svc):%{http_code}\n" --max-time 5 http://web.lab.svc.cluster.local/ || echo "被拒绝/超时"
```

同时观察 cilium monitor 里的 drop 事件:
```bash
# 另一终端:
kubectl exec -n kube-system <cilium-pod> -- cilium monitor --type drop
```

### 3. 查看 enforcement 状态变化

```bash
cagent endpoint list          # web 端点的 POLICY(ingress) 变为 Enabled
cagent bpf policy get <web-endpoint-id>
```

### 4. 用 CiliumNetworkPolicy 做端口级控制(egress)

`03-web-egress.yaml`:只允许 web 出站到 api 的 80 端口(DNS 也需要 53)。

```bash
kubectl apply -f 03-web-egress.yaml
```

### 5. 清理

```bash
kubectl delete -f 03-web-ingress.yaml -f 03-web-egress.yaml
```

## 验证要点

- [ ] 未应用策略时三者互通 (200)
- [ ] 应用 ingress 策略后,`role=curl` 的 test 能访问 web,其它身份不能
- [ ] `cagent endpoint list` 中 web 的 enforcement 从 Disabled → Enabled
- [ ] monitor 能看到被拒绝的流量

## 思考

1. 策略匹配用 identity 而非 IP 有什么好处?(提示:滚动更新时 Pod IP 频繁变化)
2. ingress 和 egress 是分别独立生效的吗?能否只限制一个方向?
