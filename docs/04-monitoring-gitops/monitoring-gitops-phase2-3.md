# K8s 监控告警 GitOps 改造记录（第二期 / 第三期）

> 集群：`https://10.0.0.168:6443`（kubeadm，v1.35.9）
> 命名空间：`monitoring`
> 记录时间：2026-11-09
> 前置文档：`/root/monitoring-gitops-phase1.md`
> 仓库：`http://192.168.67.201/digitalsupply/platform-gitops.git`

---

## 0. 总览

| 阶段 | 内容 | 结果 |
|---|---|---|
| 第一期 | 6 个自建 PrometheusRule 纳入 ArgoCD | ✅ 完成 |
| 第一期 | 修复 Alertmanager → wecom-adapter → 企业微信链路 | ✅ 完成 |
| 第二期 | wecom-adapter 整体 GitOps 化 + SealedSecret + 团队路由规范 | ✅ 完成 |
| 第三期 | kube-prometheus-stack 整体纳入 ArgoCD | ✅ 完成 |

最终状态：

- ArgoCD 应用总数：**28**，全部 `Synced / Healthy`（`compassio` 的滚动更新在验收期间短暂 Progressing，随后恢复）；
- `platform-monitoring-stack`：`Succeeded / Synced / Healthy`；
- Prometheus：**68 个 rule group、251 条 alerting 规则、0 条 health 异常**；
- Alertmanager：`Available=True / Reconciled=True`；
- Grafana：登录 API 返回 200，37 个 Dashboard 同步正常；
- Helm release `prometheus` 仍在（revision 13），但**以 ArgoCD 为准**，不再使用 `helm upgrade`。

---

## 1. 第二期：wecom-adapter 与团队告警规范

### 1.1 目标

1. 把 `wecom-adapter` 从手工资源迁移到 GitOps；
2. webhook URL 用 SealedSecret 管理，不写明文；
3. 把 Cilium DNS egress 修复固化到 Git；
4. 为基础路由加 `continue: true`，支持团队追加 `AlertmanagerConfig`。

### 1.2 仓库结构

```text
platform/monitoring/wecom/
├── kustomization.yaml
├── sealedsecret.yaml              # wecom-adapter / webhook-url
├── configmap.yaml                 # adapter.py
├── deployment.yaml
├── service.yaml
└── networkpolicy.yaml

clusters/prod/applications/
└── platform-monitoring-wecom.yaml
```

Kustomization：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - sealedsecret.yaml
  - configmap.yaml
  - deployment.yaml
  - service.yaml
  - networkpolicy.yaml
```

### 1.3 SealedSecret

生成方式：

```bash
kubectl -n monitoring get secret wecom-adapter -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > platform/monitoring/wecom/sealedsecret.yaml
```

SealedSecret 增加：

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

**踩坑：SealedSecret 无法接管已存在的 Secret**

首次同步报错：

```text
failed update: Resource "wecom-adapter" already exists and is not managed by SealedSecret
```

处理：

```bash
kubectl -n monitoring annotate secret wecom-adapter \
  sealedsecrets.bitnami.com/managed=true --overwrite
```

然后删除并重新创建 SealedSecret（ArgoCD 自动重建，或手动 apply 一次），
控制器日志出现：

```text
SealedSecret unsealed successfully
update suppressed, no changes in spec
```

Secret 的 ownerReference 变为：

```text
kind: SealedSecret, name: wecom-adapter, controller: true
```

### 1.4 NetworkPolicy（固化 DNS 修复）

```yaml
egress:
  - to:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: kube-system
        podSelector:
          matchLabels:
            k8s-app: kube-dns
    ports:
      - {port: 53, protocol: UDP}
      - {port: 53, protocol: TCP}
  - to:
      - ipBlock: {cidr: 0.0.0.0/0}
    ports:
      - {port: 443, protocol: TCP}
```

原因见第一期文档：Cilium 下 `ipBlock: 0.0.0.0/0` 不匹配 kube-dns 的 ClusterIP 后端。

### 1.5 ArgoCD Application

`clusters/prod/applications/platform-monitoring-wecom.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-monitoring-wecom
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  project: default
  source:
    repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
    targetRevision: main
    path: platform/monitoring/wecom
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  ignoreDifferences:
    - group: bitnami.com
      kind: SealedSecret
      jsonPointers: [/status]
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      limit: 10
      backoff: {duration: 10s, factor: 2, maxDuration: 5m}
```

先以 manual sync 创建，`kubectl diff` 确认只有：

- 删除 Deployment 上的 `kubectl.kubernetes.io/restartedAt`、
  `wecom-alert-receiver/secret-hash` 两个手工注解；
- 新建 SealedSecret。

确认后切换为 automated，同步成功。

### 1.6 团队 AlertmanagerConfig 规范

`values.yaml` 中 wecom 路由也加 `continue: true`：

```yaml
routes:
  - matchers: [severity =~ "critical|warning"]
    receiver: n8n-webhook
    continue: true
  - matchers: [severity =~ "critical|warning"]
    receiver: wecom
    continue: true
```

这样团队 `AlertmanagerConfig` 追加在基础路由之后仍能匹配。

示例：

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: team-routes
  namespace: deeptutor
spec:
  route:
    receiver: team-webhook
    matchers:
      - name: namespace
        value: deeptutor
    continue: true
  receivers:
    - name: team-webhook
      webhookConfigs:
        - url: https://example.invalid/team
          sendResolved: true
```

约定：

- 团队配置放各自 GitOps 仓库；
- 匹配条件必须带 `namespace`；
- `continue: true` 表示基础 n8n/企业微信通道仍会收到。

### 1.7 第二期验收

| 检查项 | 结果 |
|---|---|
| App `platform-monitoring-wecom` | Synced / Healthy |
| 适配器 Pod | 2/2 Running |
| 适配器 DNS | `qyapi.weixin.qq.com` 解析成功 |
| 适配器 TCP 443 | 连接成功 |
| SealedSecret | `wecom-adapter` 已接管 Secret |
| Alertmanager 路由 | n8n + wecom 均 `continue: true` |
| Helm revision | 10 |

---

## 2. 第三期：kube-prometheus-stack 整体纳入 ArgoCD

### 2.1 目标与前置条件

目标：kube-prometheus-stack 的 35 个 chart 规则、Prometheus/Alertmanager CR、
Grafana Deployment、ServiceMonitor、Dashboard ConfigMap 等全部由 ArgoCD 管理。

前置条件：

1. **Grafana admin 密码不在 Git**
   `helm get values` 显示唯一未写入 Git 的键是 `grafana.adminPassword`。
2. **RWO PVC 滚动更新死锁**
   Grafana 的 `prometheus-grafana-ceph` 是 RWO，跨节点滚动会卡住。
3. **Helm chart 与 CRD 的 `hostNetwork` 不一致**
   Alertmanager CRD 没有声明 `spec.hostNetwork`，chart 83.7.0 仍会渲染。

### 2.2 Grafana admin 迁移到 SealedSecret

从现有 Secret `prometheus-grafana`（3 个 key：`admin-user`、`admin-password`、
`ldap-toml`）生成新的 `prometheus-grafana-admin` SealedSecret：

```bash
kubectl -n monitoring get secret prometheus-grafana -o yaml \
  | kubeseal --format yaml \
      --controller-name sealed-secrets-controller \
      --controller-namespace kube-system \
  > platform/monitoring/stack/sealedsecret-grafana-admin.yaml
```

`values.yaml`：

```yaml
grafana:
  admin:
    existingSecret: prometheus-grafana-admin
  deploymentStrategy:
    type: Recreate
```

**踩坑 1：`grafana.strategy` 不生效**

最初写成：

```yaml
grafana:
  strategy:
    type: Recreate
```

渲染结果仍是 `RollingUpdate`。Grafana 子 chart 的字段名是
`deploymentStrategy`，修正后渲染为 `Recreate`。

**踩坑 2：RWO 滚动死锁**

第一次 Helm 升级后：

```text
FailedAttachVolume: Volume is already used by pod(s) prometheus-grafana-...
```

新 Pod 在 worker01，旧 Pod 在 worker02，RWO 卷无法同时挂载；Deployment
默认 `maxUnavailable=0`，新 Pod 等旧 Pod 退出，旧 Pod 等新 Pod ready。

处理：

```bash
kubectl -n monitoring scale deploy prometheus-grafana --replicas=0
kubectl -n monitoring wait --for=delete pod -l app.kubernetes.io/name=grafana --timeout=120s
kubectl -n monitoring scale deploy/prometheus-grafana --replicas=1
```

之后把 `deploymentStrategy` 固定为 `Recreate`，避免再次死锁。

### 2.3 Helm chart 仓库注册

ArgoCD 增加 Helm repo Secret（public repo，无凭据）：

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: prometheus-community-helm
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: prometheus-community
  url: https://prometheus-community.github.io/helm-charts
```

在 repo-server 内验证：

```bash
kubectl -n argocd exec deploy/argocd-repo-server -- \
  helm search repo pc/kube-prometheus-stack --version 83.7.0
```

### 2.4 多源 Application

`clusters/prod/applications/platform-monitoring-stack.yaml`：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-monitoring-stack
  namespace: argocd
spec:
  project: default
  sources:
    # 1) values 引用源，必须放在第一位
    - repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
      targetRevision: main
      ref: values
    # 2) Helm chart
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: 83.7.0
      helm:
        releaseName: prometheus
        skipCrds: true
        valueFiles:
          - $values/platform/monitoring/values.yaml
    # 3) 辅助 Secret
    - repoURL: http://192.168.67.201/digitalsupply/platform-gitops.git
      targetRevision: main
      path: platform/monitoring/stack
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  ignoreDifferences:
    - group: bitnami.com
      kind: SealedSecret
      jsonPointers: [/status]
    - group: ""
      kind: Service
      jsonPointers:
        - /spec/clusterIP
        - /spec/clusterIPs
        - /spec/ipFamilies
        - /spec/ipFamilyPolicy
        - /spec/healthCheckNodePort
    - group: monitoring.coreos.com
      kind: PrometheusRule
      jsonPointers:
        - /metadata/annotations/prometheus-operator-validated
    # 注意：CRD 升级到 0.90.1 后，Alertmanager/Prometheus 的
    # /spec/hostNetwork ignoreDifferences 已移除，不再需要。
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

### 2.5 踩坑记录

#### 坑 A：`source 1 of 3` 渲染超时

第一次 App 状态：

```text
Failed to load target state: failed to generate manifest for source 1 of 3:
rpc error: code = DeadlineExceeded
```

controller 日志：

```text
compare_app_state_ms=60004 git_ms=60002
```

不是 chart 慢，而是 **`ref: values` source 放在第二位**导致 ArgoCD 把它当普通
source 处理，Git 操作 60s 超时。把 ref source 调整到 `sources` 第一位后解决。

#### 坑 B：structured merge diff 报 `hostNetwork` 不在 schema

```text
error calculating structured merge diff:
error building typed value from config resource:
.spec.hostNetwork: field not declared in schema
```

检查：

```bash
kubectl get crd alertmanagers.monitoring.coreos.com -o json \
  | jq '.spec.versions[] | select(.served) | .schema.openAPIV3Schema.properties.spec.properties.hostNetwork'
# null
```

chart 模板第 214 行仍无条件渲染：

```yaml
hostNetwork: {{ .Values.alertmanager.alertmanagerSpec.hostNetwork }}
```

初步处理：在 Application 中忽略 Alertmanager/Prometheus 的 `/spec/hostNetwork`。

**最终根因与解法：** 集群里的 CRD 是 0.88.0，而运行的 operator 和 chart 已经是 0.90.1。
chart 自带的 0.90.1 CRD 已经声明了 `hostNetwork`。因此把 CRD 升级到 0.90.1
后，`ignoreDifferences` 就可以删除。详见 2.7 节。

#### 坑 C：首次同步 Prometheus 健康检查失败

同步过程中 Prometheus StatefulSet 因新增 `fsGroup: 2000` 重启：

```text
shard 0: pod prometheus-prometheus-prometheus-0:
containers with incomplete status: [init-config-reloader]
```

这是同步时的瞬时状态。等待 Pod 2/2 Running 后，App 变为 `Synced/Healthy`。
`fsGroupChangePolicy: OnRootMismatch` 已存在，不会对 19G+ TSDB 递归 chown。

#### 坑 D：Grafana Dashboard 全部 NoMatchingInstance

Helm 升级删除了旧 Secret `prometheus-grafana`，但 `platform-grafana` 的
Grafana CR 仍引用它：

```text
creating grafana http client: secrets "prometheus-grafana" not found
Grafana instances not ready, excluded from matching
```

处理：

1. 修改 `platform/grafana/resources/grafana.yaml`：

   ```yaml
   spec:
     external:
       adminUser:
         name: prometheus-grafana-admin
         key: admin-user
       adminPassword:
         name: prometheus-grafana-admin
         key: admin-password
   ```

2. 推送后 ArgoCD 同步 Grafana CR；
3. 重启 grafana-operator，等待 Grafana CR 出现：

   ```text
   GrafanaReady=True  Grafana reconcile completed
   ```

4. Dashboard 的 `NoMatchingInstance` 归零，`platform-grafana` 恢复 `Synced/Healthy`。

#### 坑 E：Helm hook 资源

chart 的 `prometheus-admission-create/patch` Job、ServiceAccount、RBAC 都带
`helm.sh/hook`。ArgoCD 按 hook 处理，PreSync/PostSync 阶段运行；
`hook-succeeded` 后 Job 会被删除。当前：

- `prometheus-admission-create` 曾 Complete；
- ValidatingWebhookConfiguration 的 `caBundle` 已写入；
- `prometheus-admission` Secret 存在。

### 2.6 CRD 升级（hostNetwork 的最终解法）

版本对比：

| 对象 | 版本 | `spec.hostNetwork` |
|---|---|---|
| 集群 Alertmanager CRD | 0.88.0 | ❌ |
| 运行中的 prometheus-operator | 0.90.1 | — |
| chart 83.7.0 自带 CRD | 0.90.1 | ✅ |

操作：

```bash
# 1. 备份
mkdir -p /root/k8s-crd-backup-20261110
for crd in $(kubectl get crd -o name | grep 'monitoring.coreos.com'); do
  kubectl get "$crd" -o yaml > "/root/k8s-crd-backup-20261110/$(basename "$crd").yaml"
done

# 2. 导出 chart CRD 并预览 diff
helm show crds prometheus-community/kube-prometheus-stack --version 83.7.0 \
  > /tmp/kps-crds.yaml
kubectl diff -f /tmp/kps-crds.yaml | head

# 3. 升级（单版本 CRD，无 conversion webhook）
kubectl apply --server-side --force-conflicts -f /tmp/kps-crds.yaml

# 4. 验证
kubectl get crd alertmanagers.monitoring.coreos.com \
  -o jsonpath='{.metadata.annotations.operator\.prometheus\.io/version}{"\n"}'
# 0.90.1
kubectl get crd alertmanagers.monitoring.coreos.com -o json \
  | jq -r '.spec.versions[] | select(.served)
           | .schema.openAPIV3Schema.properties.spec.properties.hostNetwork.type'
# boolean
```

升级后从 `platform-monitoring-stack` 的 `ignoreDifferences` 中删除：

```yaml
- group: monitoring.coreos.com
  kind: Alertmanager
  jsonPointers: [/spec/hostNetwork]
- group: monitoring.coreos.com
  kind: Prometheus
  jsonPointers: [/spec/hostNetwork]
```

提交：`7771914 fix(monitoring): drop hostNetwork ignore after
prometheus-operator CRD 0.90.1 upgrade`。

结果：App 仍为 `Succeeded / Synced / Healthy`，structured merge diff
不再报 `field not declared in schema`。

### 2.7 同步与验收

同步结果：

```text
phase: Succeeded
message: successfully synced (no more tasks)
sync: Synced
health: Healthy
```

完整验收：

```bash
# ArgoCD
kubectl -n argocd get applications

# Prometheus / Alertmanager
kubectl -n monitoring get prometheus prometheus-prometheus
kubectl -n monitoring get alertmanager prometheus-alertmanager

# 规则健康度
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules \
  | jq '{groups:(.data.groups|length),
         alerts:([.data.groups[].rules[]|select(.type=="alerting")]|length),
         bad:([.data.groups[].rules[]|select(.health!="ok")]|length)}'
```

结果：

| 检查项 | 结果 |
|---|---|
| 68 个 rule group | ✅ |
| 251 条 alerting 规则 | ✅ |
| health 异常 | 0 |
| Prometheus CR | Available=True / Reconciled=True |
| Alertmanager CR | Available=True / Reconciled=True |
| Alertmanager 通知 | n8n + wecom，均 `continue: true` |
| Grafana API | 200 |
| Grafana Dashboard | 37/37 同步正常 |
| SealedSecret | `wecom-adapter`、`prometheus-grafana-admin` |
| ArgoCD 应用 | 28 个，全部 Healthy |

---

### 2.8 CRD 纳入 GitOps（2026-11-10）

此前 CRD 是 `skipCrds: true` + 手工 `kubectl apply`。2026-11-10 起改为
独立 Application 管理：

```text
platform/monitoring/crds/
├── kustomization.yaml
├── alertmanagerconfigs.monitoring.coreos.com.yaml
├── alertmanagers.monitoring.coreos.com.yaml
├── podmonitors.monitoring.coreos.com.yaml
├── probes.monitoring.coreos.com.yaml
├── prometheusagents.monitoring.coreos.com.yaml
├── prometheuses.monitoring.coreos.com.yaml
├── prometheusrules.monitoring.coreos.com.yaml
├── scrapeconfigs.monitoring.coreos.com.yaml
├── servicemonitors.monitoring.coreos.com.yaml
└── thanosrulers.monitoring.coreos.com.yaml
```

Application `platform-monitoring-crds`：

- `sync-wave: "-10"`，先于监控栈；
- `prune: false`，不允许删除 CRD；
- `ServerSideApply=true` + `Force=true`，接管历史字段；
- 监控栈保持 `skipCrds: true`，避免重复管理。

提交：`c2160d3 feat(monitoring): manage prometheus-operator CRDs in GitOps`。

验证：

```bash
kubectl -n argocd get app platform-monitoring-crds
kubectl -n argocd get app platform-monitoring-crds -o json \
  | jq '[.status.resources[]|select(.kind=="CustomResourceDefinition")]|length'
# 10
```

---

## 3. 最终 Git 提交

```text
c2160d3 feat(monitoring): manage prometheus-operator CRDs in GitOps
7771914 fix(monitoring): drop hostNetwork ignore after prometheus-operator CRD 0.90.1 upgrade
d4618c9 fix(monitoring): stabilize prometheus-adapter for Compassio HPA        （同事提交）
4ab1868 feat(monitoring): enable self-heal for kube-prometheus-stack app without prune
0bff5d7 fix(grafana): point operator client at prometheus-grafana-admin secret
748d9d8 feat(monitoring): add prometheus-adapter for Compassio LLM-wait HPA   （同事提交）
cf63060 fix(monitoring): ignore hostNetwork diff not present in Alertmanager CRD
8532872 fix(monitoring): put values ref source first for multi-source app
a708e2a feat(monitoring): adopt kube-prometheus-stack into ArgoCD
8a86b1b feat(monitoring): enable automated sync for wecom-adapter app
cbdd96d feat(monitoring): move wecom-adapter into GitOps
9a341c2 feat(monitoring): manage PrometheusRules in GitOps and route alerts to WeCom
```

---

## 3.1 GitOps 白名单收口（2026-11-10）

### 背景

改造后仍有两个口子：

1. 手工创建、带 `release: prometheus` 的 PrometheusRule 会被加载；
2. 任意命名空间的手工 AlertmanagerConfig 会被合并。

### 白名单标签

统一要求 GitOps 管理的对象带：

```yaml
metadata:
  labels:
    platform.gitops/managed: "true"
```

覆盖方式：

| 对象 | 标签来源 |
|---|---|
| chart 自带 35 个 PrometheusRule | `values.yaml` 的 `defaultRules.labels` |
| `platform/monitoring/rules/` 6 个规则 | `rules/kustomization.yaml` 的 JSON6902 patch |
| deeptutor 2 个规则 | `deeptutor-gitops/overlays/prod` 的 patch |
| compassio 1 个规则 | `compassio-gitops/overlays/prod` 的 patch |
| 团队 AlertmanagerConfig | 必须写在 `metadata.labels` |

### 收紧 selector

```yaml
prometheus:
  prometheusSpec:
    ruleSelector:
      matchLabels:
        release: prometheus
        platform.gitops/managed: "true"

alertmanager:
  alertmanagerSpec:
    alertmanagerConfigSelector:
      matchLabels:
        platform.gitops/managed: "true"
    alertmanagerConfigNamespaceSelector: {}
```

> 分两步上线：先给 44 个规则打标签，确认全部带标签；再收紧 selector，
> 避免规则发现出现空窗。

### 验证

```bash
# 44 = 35 chart + 6 platform + 2 deeptutor + 1 compassio
kubectl get prometheusrules -A -o json \
  | jq '[.items[] | select(.metadata.labels["platform.gitops/managed"]=="true")]|length'
# 44
```

正反测试：

| 测试 | 结果 |
|---|---|
| 手工 PrometheusRule，仅 `release=prometheus` | ❌ 未被加载 |
| 手工 PrometheusRule，带白名单标签 | ✅ 被加载 |
| 手工 AlertmanagerConfig，无标签 | ❌ 未进入生成配置 |
| 手工 AlertmanagerConfig，带标签 | ✅ 被合并 |
| 清理测试对象 | ✅ 已删除，无残留 |

### 提交

```text
e861a59 feat(monitoring): add GitOps allowlist label to all PrometheusRules
6ebe572 feat(monitoring): restrict rule and AlertmanagerConfig discovery to GitOps-managed objects
563fce4 chore(alerts): add GitOps managed label to PrometheusRules   （deeptutor-gitops）
2b6b77c chore(alerts): add GitOps managed label to PrometheusRules   （compassio-gitops）
```

### 注意

标签是**声明式白名单**，不是安全边界。拥有写权限的人仍然可以伪造该标签；
真正的强制需要 RBAC / Kyverno / OPA 等准入策略配合。

---

## 4. 运维手册（改造后）

### 4.1 日常变更

| 变更 | 操作 |
|---|---|
| PrometheusRule | 改 `platform/monitoring/rules/*.yaml` → 提交 → ArgoCD 自动同步 |
| 监控栈 values | 改 `platform/monitoring/values.yaml` → 提交 → ArgoCD 自动同步 |
| Chart 版本 | 改 `platform-monitoring-stack.yaml` 的 `targetRevision` → 提交 |
| wecom-adapter | 改 `platform/monitoring/wecom/` → 提交 |
| Grafana admin 密码 | 重新 seal → 提交 → `rollout restart deploy/wecom-adapter` 不适用，Grafana 密码变更需重启 Grafana |

### 4.2 不要再用 Helm CLI

虽然 Helm release `prometheus` 还存在（revision 13），但资源已由 ArgoCD 接管。
**不要执行**：

```bash
helm upgrade prometheus ...
helm rollback prometheus ...
```

否则会与 ArgoCD 的字段管理冲突。如需回滚，优先 revert Git 提交，让 ArgoCD 同步。

### 4.3 已知限制

1. `platform-monitoring-stack` 的 `prune` 为 `false`
   - 避免误删 operator 生成资源；
   - chart 升级后如果删除了某个资源，需要人工确认清理。

2. Alertmanager CRD 的 `hostNetwork`
   - 已把 prometheus-operator CRD 从 0.88.0 升级到 0.90.1，`hostNetwork` 已声明；
   - `ignoreDifferences` 已移除；
   - CRD 已由 `platform-monitoring-crds` Application 管理；
   - 升级 chart/operator 时，更新 `platform/monitoring/crds/` 并提交即可。

3. Grafana RWO PVC
   - 必须保持 `deploymentStrategy: Recreate`；
   - 跨节点滚动会死锁。

4. n8n webhook 异常（既有问题）
   - `n8n.example.com` 返回 Cloudflare `connection reset by peer`；
   - 与企业微信链路无关，需单独排查 n8n/Cloudflare。

5. `grafana.adminPassword` 仍残留在 Helm release values 中
   - 但 `grafana.admin.existingSecret` 已生效，实际不再使用该值；
   - 只要不执行 `helm upgrade`，不会造成影响。

---

## 5. 回滚方案

### 5.1 回滚监控栈 values / chart 版本

```bash
cd platform-gitops
git revert <commit>
git push origin main
kubectl -n argocd get app platform-monitoring-stack
```

ArgoCD 自动同步回滚后的状态。

### 5.2 紧急停用 ArgoCD 自动同步

```bash
kubectl -n argocd patch app platform-monitoring-stack --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

然后按需用 `kubectl apply` 或 Helm（仅限已确认不会与 ArgoCD 冲突的场景）。

### 5.3 恢复 Helm CLI 管理（不推荐）

Helm release 仍在，但 ArgoCD 已接管。若要恢复：

1. 停用并删除 ArgoCD Application（注意不要 prune 资源）；
2. 用与 Git values 一致的 `helm upgrade --reuse-values` 恢复；
3. 重新评估后续是否再次 GitOps 化。

---

## 6. 验收命令汇总

```bash
export KUBECONFIG=~/.kube/deeptutor-config

# ArgoCD
kubectl -n argocd get applications
kubectl -n argocd get app platform-monitoring-stack
kubectl -n argocd get app platform-monitoring-wecom
kubectl -n argocd get app platform-monitoring-rules

# 规则
kubectl get prometheusrules -A
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules \
  | jq '[.data.groups[].rules[]|select(.health!="ok")]|length'

# Alertmanager
kubectl -n monitoring get secret alertmanager-prometheus-alertmanager \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | sed -n '/^receivers:/,/^templates:/p'

# Grafana
kubectl -n monitoring get secret prometheus-grafana-admin
kubectl -n monitoring get grafanadashboards -o json \
  | jq '[.items[].status.conditions[]? | select(.type=="NoMatchingInstance" and .status=="True")]|length'

# 企业微信适配器
kubectl -n monitoring get pods -l app.kubernetes.io/name=wecom-adapter
kubectl -n monitoring exec -i deploy/wecom-adapter -c adapter -- python3 -c \
  "import socket; print(socket.getaddrinfo('qyapi.weixin.qq.com',443)[0][4][0])"
```
