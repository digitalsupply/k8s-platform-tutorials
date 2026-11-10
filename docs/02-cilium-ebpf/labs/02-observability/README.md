# 实验 02:可观测性 — 用 Hubble 看透集群流量

**目标**:利用 Cilium 内置的 Hubble 可观测性层,实时查看集群内所有 L3/L4/L7 流量,学会排查"谁在访问谁"。

## 背景知识

Hubble 是 Cilium 的可观测性组件,基于 eBPF 在内核里实时抓取网络事件,提供:
- **Service Map / Dependency Graph**:可视化服务间依赖
- **流量日志**:每条流的 src → dst、协议、端口、verdict
- **关注点过滤**:按 namespace、pod、IP、协议过滤

本集群 Hubble 组件已部署:hubble-relay (聚合器,ClusterIP `10.43.148.231:80`) + hubble-ui。

## 步骤

### 1. 确认 Hubble 组件状态

```bash
cilium status | grep -A1 Hubble
kubectl get pods -n kube-system -l k8s-app=hubble   # relay + ui
```

### 2. 开启 UI 端口转发(方式 A:cilium-cli 自动转发)

```bash
cilium hubble ui
```

会自动打开/转发到 Hubble UI 的 Web 页面(Service Map 视图)。

### 3. 开启 Hubble CLI 观察流量(方式 B:手动转发 + hubble）

如果你有 hubble CLI:
```bash
cilium hubble port-forward &     # 转发 relay 端口(默认 4245)到 localhost
hubble observe
```

> 本环境没有独立 hubble CLI;最实用的替代是用 cilium-agent 内置的 **cilium monitor**。

### 4. (推荐)用 cilium monitor 实时观察

在一个终端监听所有流量:

```bash
# 监听所有事件
kubectl exec -n kube-system <cilium-pod> -- cilium monitor
# 只看被拒绝(drop)的事件
kubectl exec -n kube-system <cilium-pod> -- cilium monitor --type drop
# 只看某端点的流量
kubectl exec -n kube-system <cilium-pod> -- cilium monitor -e <endpoint-id>
```

在另一个终端从 test pod 访问 web 产生流量:

```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')
# 循环产生流量
kubectl exec -n lab $POD -- sh -c 'for i in $(seq 1 20); do curl -s -o /dev/null http://web.lab.svc.cluster.local/; done'
```

### 5. 查看 service map (cilium endpoint + service 关联)

```bash
cagent service list     # 看集群 Service 到后端的 eBPF 映射
cagent endpoint list    # 看 Pod endpoint
```

### 6. (进阶)绑定到特定 pod 过滤

```bash
cilium node list
cagent monitor -p <pod-ip>   # 用 pod IP 过滤
```

## 验证要点

- [ ] `cilium status` 显示 Hubble Relay: OK
- [ ] 用 `cilium monitor` 在产生流量时看到 `from` / `to` 事件,verdict 为 `FORWARDED`
- [ ] 能区分 Service 访问(看到 `service id`)与 pod 直连
- [ ] Hubble UI 能打开并显示 Service Map

## 思考

1. monitor 事件里的 `identity` 列,和你实验 01 看到的 identity list 对应吗?
2. 为什么可观测性在"零信任"网络里很重要?(提示:默认拒绝后要知道该放行谁)
