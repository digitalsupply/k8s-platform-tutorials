# Dashboard 更新实录：IngressRoute 更正、Cilium 面板、残留清理、Hubble/Alloy/Traefik 暴露

> 日期：2026-11-10  
> 范围：platform-gitops / Grafana / Traefik / Hubble / Alloy  
> 结论：已完成 Cilium 官方仪表盘导入、3 个残留仪表盘清理、Hubble/Alloy/Traefik Dashboard 通过 Traefik 以 `*.xyz` 暴露；ArgoCD/Grafana/Prometheus/Tekton/Traefik 实际一直通过 **IngressRoute** 暴露。

---

## 1. 更正：不是没有 Ingress，而是使用了 IngressRoute

之前清单只统计了标准 `Ingress`，遗漏了 Traefik `IngressRoute` CRD。实际路由：

```text
argocd/argocd
  match: Host(`argocd.devops.com`)
  service: argocd-server:80
  tls: argocd-tls

monitoring/grafana
  match: Host(`grafana.example.local`) || Host(`grafana.k8s.local`)
  service: prometheus-grafana:80
  tls: {}

monitoring/prometheus
  match: Host(`prom.example.local`) || Host(`prometheus.k8s.local`)
  service: prometheus-operated:9090
  tls: {}

tekton-pipelines/tekton-dashboard
  match: Host(`tekton.xyz`)
  service: tekton-dashboard:9097
  middlewares: tekton-dashboard-auth, tekton-dashboard-strip-auth
  tls: tekton-dashboard-tls

traefik/traefik-dashboard
  match: Host(`traefik.example.com`) && (PathPrefix(`/api`) || PathPrefix(`/dashboard`))
  service: TraefikService api@internal
  middlewares: traefik-dashboard-auth
```

验证（Host 指向 10.0.0.252）：

```text
grafana.k8s.local      302（登录跳转）
argocd.devops.com      200
prometheus.k8s.local   302
tekton.xyz             401（basic auth）
```

> 结论：用户在本机 hosts 映射后能正常访问，是因为 Traefik IngressRoute 已存在；原清单的“无 Ingress”表述已修正。

---

## 2. Cilium 官方 Grafana 仪表盘

### 2.1 来源

从 Cilium 1.20.4 chart 提取：

```text
files/cilium-agent/dashboards/cilium-dashboard.json
files/cilium-operator/dashboards/cilium-operator-dashboard.json
files/hubble/dashboards/hubble-dashboard.json
files/hubble/dashboards/hubble-dns-namespace.json
files/hubble/dashboards/hubble-l7-http-metrics-by-workload.json
files/hubble/dashboards/hubble-network-overview-namespace.json
```

### 2.2 处理

- 所有 `${DS_PROMETHEUS}` 替换为现有 Prometheus 数据源 UID `prometheus`；
- 删除不再使用的 `DS_PROMETHEUS` 模板变量和 `__inputs`；
- 设置唯一 UID：`cilium-agent`、`cilium-operator`、`hubble`、`hubble-dns`、`hubble-l7-http`、`hubble-network`；
- 放入 Grafana `monitoring` 文件夹（UID `dg3oftubp2vb4c`）；
- 以 `GrafanaDashboard` CR 形式写入 `platform/grafana/resources/dashboards-cilium.yaml`。

### 2.3 结果

Grafana 仪表盘总数：**47 → 50**。

新增：

```text
Cilium Metrics
Cilium Operator
Hubble Metrics and Monitoring
Hubble / DNS Overview (Namespace)
Hubble L7 HTTP Metrics by Workload
Hubble / Network Overview (Namespace)
```

验证数据源：

```text
/api/dashboards/uid/cilium-agent
  title: Cilium Metrics
  datasource.uid: prometheus
```

---

## 3. 清理残留仪表盘

### 3.1 删除的 3 个 GrafanaDashboard CR

```text
dash-calico-felix-dashboard-calico-felix-json
dash-prometheus-grafana-dashboard-apps-knative-eventing-json
dash-prometheus-proxy-proxy-json
```

对应仪表盘：

```text
Calico Felix - Node Dataplane
Knative Eventing 总览
Kubernetes / Proxy
```

备份：`/root/dashboard-cleanup-20261110/dashboards.yaml.bak`

清理后：

```text
Grafana 仪表盘 50（已含 Cilium）
Calico / Knative / Proxy 标题已不存在
GrafanaDashboard CR 中已无 calico/knative/proxy
```

> 底层 ConfigMap（`calico-felix-dashboard`、`prometheus-proxy` 等）仍在，但不再被导入 Grafana；
> 如需彻底清理，可在 monitoring Helm values 中关闭 `kubeProxy.enabled` 后再升级。

### 3.2 Calico Felix 是什么？这个面板是干啥的？

**Calico Felix** 是 Calico 的 **每节点数据面 agent**：

- 监听 Kubernetes API 中的 NetworkPolicy、Pod、Service、Endpoint 等；
- 在节点上编程 **iptables / eBPF / IPSets**；
- 实现 Pod 网络策略、路由、接口管理、conntrack、ARP 等；
- 向 Prometheus 暴露 Felix 自身指标。

`Calico Felix - Node Dataplane` 面板展示：

- Felix CPU/内存；
- iptables/eBPF 规则数量与编程耗时；
- 数据面同步状态；
- 策略/路由变更；
- 节点级数据面健康。

当前集群已经从 Calico 切到 Cilium，所以这个面板是**历史残留**。  
Cilium 的替代者是 `Cilium Metrics`、`Cilium Operator`、Hubble 系列面板。

### 3.3 kube-proxy 面板是干啥的？

`Kubernetes / Proxy` 面板对应 **kube-proxy**：

- kube-proxy 负责实现 Service 的 ClusterIP / NodePort / LoadBalancer；
- 传统模式通过 **iptables / IPVS / nftables** 写规则，把 VIP:Port DNAT 到 PodIP:Port；
- 面板展示 kube-proxy 同步延迟、iptables/IPVS 规则数量、Service/Endpoint 变更、错误、CPU/内存。

当前集群已删除 kube-proxy，使用 **Cilium kube-proxy replacement**（eBPF BPF LB）。  
所以这个面板是**历史残留**，不再有真实数据。  
替代者是 Cilium 的 Service/BPF LB 指标（`Cilium Metrics`、`Cilium Operator`、Hubble 面板）。

### 3.4 Knative Eventing 面板

Knative 未安装，面板为历史残留；已删除。

---

## 4. Hubble / Alloy / Traefik Dashboard 暴露

### 4.1 新增 `platform-ui` ArgoCD App

```text
platform/ui/
├── hubble.yaml
├── alloy.yaml
└── traefik-xyz.yaml

clusters/prod/applications/platform-ui.yaml
```

ArgoCD：`platform-ui   Synced   Healthy`

### 4.2 Hubble UI：`hubble.xyz`

```text
entryPoint: websecure
Host: hubble.xyz
service: hubble-ui:80
middleware: hubble-ui-auth (basic auth)
TLS: tls: {}
```

同时创建 HTTP → HTTPS 跳转：`web Host(hubble.xyz) -> redirectScheme https`

### 4.3 Alloy UI：`alloy.xyz`

```text
entryPoint: websecure
Host: alloy.xyz
service: alloy:12345
middleware: alloy-ui-auth (basic auth)
TLS: tls: {}
```

HTTP → HTTPS 跳转同上。

### 4.4 Traefik Dashboard：`traefik.xyz`

```text
entryPoint: websecure
Host: traefik.xyz
PathPrefix: /api 或 /dashboard
service: TraefikService api@internal
middleware: traefik-dashboard-auth（复用已有认证）
TLS: tls: {}
```

原有 `traefik.example.com` 保持不变；`traefik.xyz` 是新增别名。

### 4.5 访问凭据

Hubble 和 Alloy 使用新生成的 basic auth：

```text
username: admin
password: <redacted>
```

密码文件：`/root/ui-exposure-20261110/password.txt`（chmod 600）

对应 Secret（不在 Git）：

```text
kube-system/hubble-ui-auth   key: users
logging/alloy-ui-auth        key: users
```

Traefik Dashboard 使用已有的 `traefik/traefik-dashboard-auth-secret` 和 `traefik-dashboard-auth` Middleware。

### 4.6 本机 hosts 需要增加

```text
10.0.0.252 hubble.xyz
10.0.0.252 alloy.xyz
10.0.0.252 traefik.xyz
```

已有域名（`grafana.k8s.local`、`argocd.devops.com`、`prometheus.k8s.local`、`tekton.xyz`）继续有效。

---

## 5. 验证结果

| 测试 | 结果 |
|---|---|
| `https://hubble.xyz/` 无认证 | `401` |
| `https://hubble.xyz/` 带 admin 密码 | `200` |
| `https://alloy.xyz/` 无认证 | `401` |
| `https://alloy.xyz/` 带 admin 密码 | `200` |
| `https://traefik.xyz/dashboard/` 无认证 | `401` |
| `http://hubble.xyz/` | `301 -> https://hubble.xyz/` |
| `http://alloy.xyz/` | `301 -> https://alloy.xyz/` |
| `https://grafana.k8s.local/` | `302` |
| `https://argocd.devops.com/` | `200` |
| `https://prometheus.k8s.local/` | `302` |
| `https://tekton.xyz/` | `401`（已有 basic auth） |
| Grafana 仪表盘总数 | `50` |
| Cilium 面板 | 6 个全部存在 |
| Calico/Knative/Proxy 面板 | 已删除 |
| ArgoCD `platform-ui` | `Synced / Healthy` |
| ArgoCD `platform-grafana` | `Synced / Healthy` |

---

## 6. Git 提交

```text
platform-gitops:
  9334a53 feat(grafana): add official Cilium agent/operator/Hubble dashboards
  c98c7bf chore(grafana): remove stale Calico Felix, Knative Eventing, kube-proxy dashboards
  9b3ff2b feat(ui): expose Hubble, Alloy and Traefik dashboards via Traefik at *.xyz
```

---

## 7. 注意事项

1. **`platform-ui` app 使用 `prune: false`**
   - 删除 Git 文件不会自动删除集群里的 IngressRoute/Middleware；
   - 回滚需要手动删除资源或先改 `prune: true`。

2. **basic auth Secret 不在 Git**
   - 命名空间重建后需要重新创建：
     ```bash
     kubectl -n kube-system create secret generic hubble-ui-auth --from-literal=users="admin:<hash>"
     kubectl -n logging create secret generic alloy-ui-auth --from-literal=users="admin:<hash>"
     ```
   - 密码可轮换：重新 `htpasswd -nb admin <new>` 后更新 Secret。

3. **TLS 使用 Traefik 默认证书**
   - `tls: {}`；浏览器可能提示自签/默认证书；
   - 如需受信任证书，给 `hubble.xyz` / `alloy.xyz` / `traefik.xyz` 加 cert-manager Certificate + TLS Secret。

4. **Traefik Dashboard 只暴露 `/api` 和 `/dashboard`**，继续使用已有 `traefik-dashboard-auth`。

5. **Cilium 面板数据源**已写死 UID `prometheus`；如果以后修改 Grafana Prometheus 数据源 UID，需要同步更新仪表盘或恢复 `DS_PROMETHEUS` 变量。

6. **残留 ConfigMap**：`calico-felix-dashboard`、`prometheus-proxy` 等仍存在，但已不影响 Grafana；可在 monitoring Helm values 关闭 `kubeProxy.enabled` 后清理。

7. **Hubble/Alloy 面板没有做公开分享**，仍然需要 basic auth；不建议去掉认证直接暴露到公网。

---

## 8. 回滚

### 8.1 回滚 UI 暴露

```bash
kubectl delete ingressroute -n kube-system hubble hubble-http-redirect
kubectl delete ingressroute -n logging alloy alloy-http-redirect
kubectl delete ingressroute -n traefik traefik-xyz traefik-xyz-http-redirect
kubectl delete middleware -n kube-system hubble-ui-auth hubble-https-redirect
kubectl delete middleware -n logging alloy-ui-auth alloy-https-redirect
kubectl delete middleware -n traefik traefik-https-redirect
kubectl delete secret -n kube-system hubble-ui-auth
kubectl delete secret -n logging alloy-ui-auth
```

或删除 `platform-ui` ArgoCD App（资源需手动清理，因为 `prune: false`）。

### 8.2 回滚 Cilium 仪表盘

从 `platform/grafana/resources/dashboards-cilium.yaml` 删除 CR，提交后 ArgoCD 同步。

### 8.3 恢复被清理的仪表盘

```bash
cp /root/dashboard-cleanup-20261110/dashboards.yaml.bak \
  platform/grafana/resources/dashboards.yaml
```

提交后 `platform-grafana` 会重新导入 3 个残留仪表盘（不推荐）。

---

## 9. 一句话总结

- **ArgoCD/Grafana/Prometheus/Tekton/Traefik 一直有暴露**，只是用 Traefik `IngressRoute`，不是标准 `Ingress`；之前的清单已更正。
- **Cilium 官方 6 个 Grafana 面板已导入**，Grafana 总数 47 → 50。
- **Calico Felix / Knative Eventing / kube-proxy 三个残留面板已删除**；Calico Felix 是 Calico 节点数据面 agent，kube-proxy 面板是传统 iptables/IPVS Service 代理指标，二者在 Cilium 化后都已失效。
- **Hubble UI 用 `hubble.xyz`、Alloy UI 用 `alloy.xyz`、Traefik Dashboard 用 `traefik.xyz`**，通过 Traefik IngressRoute + basic auth 暴露；HTTP 自动跳 HTTPS。
- 凭据：`admin / UxbIilbJ1RX2Rej`（Hubble/Alloy；Traefik 用原有认证）。
