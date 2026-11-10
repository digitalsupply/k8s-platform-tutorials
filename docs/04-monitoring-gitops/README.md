# 04 · Monitoring GitOps：Prometheus / Alertmanager 从手工到 GitOps

## 当时的情况

改造前，`monitoring` 命名空间的 kube-prometheus-stack 由 **Helm release** 管理，
但：

- 6 个自建 PrometheusRule 是手工 `kubectl apply` 的，没有 Git 记录；
- Alertmanager 只有 n8n webhook，企业微信适配器已部署但**没有接入路由**；
- 企业微信适配器因为 NetworkPolicy/DNS 问题，实际上一直发不出消息；
- kube-prometheus-stack 本身不在 ArgoCD 管理范围内；
- CRD 是手工安装/升级的，版本落后于 operator；
- 手工创建的规则/配置可以被 Prometheus/Alertmanager 直接加载，存在绕过 GitOps 的口子。

改造目标：

1. 规则 GitOps 化；
2. 修复企业微信告警链路；
3. wecom-adapter 整体 GitOps 化；
4. kube-prometheus-stack 整体纳入 ArgoCD；
5. CRD 也纳入 GitOps；
6. 用白名单 selector 堵住手工规则/配置的口子。

## 分阶段结果

| 阶段 | 内容 | 关键结果 |
|---|---|---|
| 第一期 | 6 个自建规则纳入 ArgoCD；修复 WeCom 链路 | 规则 44 个，企业微信可用 |
| 第二期 | wecom-adapter GitOps + SealedSecret + 团队 AlertmanagerConfig 规范 | adapter 受 ArgoCD 管理，webhook 加密 |
| 第三期 | kube-prometheus-stack 整体纳入 ArgoCD | 监控栈 Synced/Healthy |
| 补充 | CRD GitOps + 告警白名单 | 10 个 CRD 受管，手工规则/配置被忽略 |

## 主要概念与原理

### 1. Prometheus Operator 与 CRD

kube-prometheus-stack 不是直接创建 Prometheus 进程，而是创建 CR：

- `Prometheus` CR：副本、存储、保留期、`ruleSelector`、`serviceMonitorSelector`；
- `Alertmanager` CR：副本、存储、路由/接收器配置来源；
- `PrometheusRule`：告警/记录规则；
- `ServiceMonitor` / `PodMonitor` / `Probe`：抓取配置；
- `AlertmanagerConfig`：团队级路由/接收器。

Operator 监听这些 CR，生成 StatefulSet、配置文件和 Secret。
所以 GitOps 的对象是 **CR**，不是 Operator 生成的 StatefulSet。

### 2. `ruleSelector` 与标签

Prometheus CR 通过 `ruleSelector` 选择 PrometheusRule。
改造前：

```yaml
ruleSelector:
  matchLabels:
    release: prometheus
```

问题：任何命名空间、任何手工规则，只要带这个标签就会被加载。

改造后：

```yaml
ruleSelector:
  matchLabels:
    release: prometheus
    platform.gitops/managed: "true"
```

chart 自带规则通过 `defaultRules.labels` 打标；自建/团队规则通过
Kustomize patch 打标。

### 3. Alertmanager 路由树与 `continue`

Alertmanager 的 `route` 是一棵树：

- 根路由有默认 receiver；
- 子路由按 matcher 匹配；
- `continue: true` 表示匹配后继续匹配后续兄弟路由；
- 没有 `continue` 时，第一个匹配的子路由会截断后续路由。

本案例把 n8n 和 wecom 两条基础路由都设为 `continue: true`，
这样团队 AlertmanagerConfig 追加的路由还能继续匹配。

### 4. ArgoCD 多源 Application

kube-prometheus-stack 使用 multi-source：

1. Git `ref: values`（values 来源）；
2. Helm chart（固定版本）；
3. Git 目录（Grafana admin SealedSecret）。

关键点：

- `ref: values` source **必须放在第一位**，否则会 Git 超时；
- `helm.skipCrds: true`，CRD 由独立 App 管理；
- `prune: false`，避免误删 Operator 生成资源。

### 5. SealedSecret

Grafana admin 和 WeCom webhook 都用 SealedSecret 管理。
SealedSecret 只能用对应集群的 sealed-secrets controller 私钥解密，
加密内容可以进 Git。

### 6. CRD 与 Operator 版本

CRD 是 API schema，Operator 是控制器。两者版本要匹配。
本案例 CRD 落后到 0.88.0，Operator 已是 0.90.1，导致
Alertmanager CR 的 `hostNetwork` 字段不在 schema 里。

## 踩坑点

### 坑 1：企业微信适配器 DNS 失败

现象：

```text
URLError: <urlopen error [Errno -3] Try again>
```

根因：NetworkPolicy 只放行 `ipBlock: 0.0.0.0/0` 的 53/443；
在 Cilium 下，这不能放行到 kube-dns ClusterIP 的后端 Pod。

修复：显式放行到 `kube-system/k8s-app=kube-dns` 的 53/UDP、53/TCP。

### 坑 2：SealedSecret 不能直接接管已有 Secret

```text
failed update: Resource "wecom-adapter" already exists
and is not managed by SealedSecret
```

修复：给现有 Secret 打 `sealedsecrets.bitnami.com/managed=true`，
再让控制器重新 reconcile。

### 坑 3：`ref: values` source 顺序

`source 1 of 3` 渲染超时，controller 日志 `git_ms=60002`。
把 ref source 放到第一位后解决。

### 坑 4：Alertmanager CRD 缺 `hostNetwork`

chart 83.7.0 会渲染 `hostNetwork`，但 0.88.0 CRD 没声明，
ArgoCD structured merge diff 报 `field not declared in schema`。

最终修复：把 CRD 升级到 0.90.1，而不是长期 ignore。

### 坑 5：Grafana RWO PVC 滚动死锁

新 Pod 等旧 Pod 释放 RWO 卷，旧 Pod 等新 Pod ready。

修复：

- 把 `grafana.deploymentStrategy` 设为 `Recreate`；
- 必要时 `scale 0 → 1` 释放卷。

> 注意字段名是 `deploymentStrategy`，不是 `strategy`。

### 坑 6：Grafana admin Secret 迁移

Helm 删除了旧 Secret `prometheus-grafana`，但 Grafana CR 还引用它，
导致 37 个 Dashboard `NoMatchingInstance`。

修复：把 Grafana CR 的 `adminUser/adminPassword` 指向
`prometheus-grafana-admin`，重启 grafana-operator，等待 `GrafanaReady=True`。

### 坑 7：Helm hook 资源

chart 的 admission Job/ServiceAccount/RBAC 带 `helm.sh/hook`。
ArgoCD 按 hook 处理，PreSync/PostSync 运行；不要手工删除。

### 坑 8：白名单 selector 的“空窗”

先收紧 selector、后给规则打标签，会让 Prometheus 短暂看不到规则。
正确顺序：

1. 先给所有规则打 `platform.gitops/managed=true`；
2. 确认 44 个规则都有标签；
3. 再收紧 `ruleSelector` / `alertmanagerConfigSelector`。

## 修复关键

1. **PrometheusRule / AlertmanagerConfig 是 GitOps 对象**；
2. **标签白名单**：`platform.gitops/managed=true`；
3. **基础路由 `continue: true`**，给团队路由留空间；
4. **CRD 独立 App**，`sync-wave: -10`，`prune: false`；
5. **Grafana 用 SealedSecret + `existingSecret` + `Recreate`**；
6. **不要再用 Helm CLI**，否则会和 ArgoCD 的字段管理冲突；
7. **运行时状态（TSDB、silences、PVC）不属于 GitOps**。

## 当前状态

见 [04-current-state.md](04-current-state.md)：

- 44 个 PrometheusRule，全部带白名单标签；
- 68 groups / 251 alerts / 0 health 异常；
- `ruleSelector` 与 `alertmanagerConfigSelector` 已收紧；
- 10 个 CRD 由 `platform-monitoring-crds` 管理；
- 监控相关 5 个 ArgoCD App 全部 Synced/Healthy。

## 文档列表

| 文档 | 内容 |
|---|---|
| [monitoring-gitops-phase1.md](monitoring-gitops-phase1.md) | 第一期：规则 GitOps、WeCom DNS/路由修复、完整命令与验证 |
| [monitoring-gitops-phase2-3.md](monitoring-gitops-phase2-3.md) | 第二/三期：adapter GitOps、stack 整体接管、CRD、白名单、踩坑记录 |
| [prometheus-alertmanager-ops-guide.md](prometheus-alertmanager-ops-guide.md) | 日常运维：状态检查、规则/路由变更、升级、回滚、排障速查 |
| [04-current-state.md](04-current-state.md) | 2026-11-10 当前集群状态快照 |

## 一句话总结

**把“人手工改 Prometheus/Alertmanager”变成“改 Git → ArgoCD 同步”，
同时用标签白名单和 CRD 版本对齐，堵住绕过 GitOps 的口子。**
