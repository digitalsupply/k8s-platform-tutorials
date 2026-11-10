# Prometheus / Alertmanager 运维指南（GitOps 版）

> 集群：`https://10.0.0.168:6443`（kubeadm，v1.35.9）
> 命名空间：`monitoring`
> 仓库：`http://192.168.67.201/digitalsupply/platform-gitops.git`
> 最后更新：2026-11-10
> 相关记录：
> - `/root/monitoring-gitops-phase1.md`
> - `/root/monitoring-gitops-phase2-3.md`

---

## 1. 架构与 GitOps 布局

### 1.1 ArgoCD Application

| Application | 作用 | 源 |
|---|---|---|
| `platform-monitoring-stack` | kube-prometheus-stack 整体（Prometheus/Alertmanager CR、chart 规则、ServiceMonitor、Operator、Grafana、kube-state-metrics、node-exporter） | Helm chart 83.7.0 + Git `values.yaml` + Git `stack/` |
| `platform-monitoring-crds` | prometheus-operator 10 个 CRD | Git `platform/monitoring/crds/` |
| `platform-monitoring-rules` | 6 个自建 PrometheusRule | Git `platform/monitoring/rules/` |
| `platform-monitoring-wecom` | 企业微信适配器 Deployment/Service/ConfigMap/NetworkPolicy/SealedSecret | Git `platform/monitoring/wecom/` |
| `platform-grafana` | Grafana CR + Dashboard CR（external 模式） | Git `platform/grafana/resources/` |
| `deeptutor` / `compassio` | 各自团队规则与业务 | 各自 GitOps 仓库 |

### 1.2 关键文件

```text
platform/monitoring/
├── values.yaml                         # Prometheus/Alertmanager/Grafana 主配置
├── README.md                           # 平台说明
├── rules/                              # 6 个自建告警规则
│   ├── kustomization.yaml
│   └── *.yaml
├── stack/
│   ├── kustomization.yaml
│   └── sealedsecret-grafana-admin.yaml # Grafana admin 凭据
└── wecom/
    ├── kustomization.yaml
    ├── sealedsecret.yaml               # 企业微信 webhook
    ├── configmap.yaml                  # adapter.py
    ├── deployment.yaml
    ├── service.yaml
    └── networkpolicy.yaml
```

### 1.3 当前 selector（重要）

```yaml
# Prometheus CR
ruleSelector:
  matchLabels:
    release: prometheus
    platform.gitops/managed: "true"

# Alertmanager CR
alertmanagerConfigSelector:
  matchLabels:
    platform.gitops/managed: "true"
alertmanagerConfigNamespaceSelector: {}
```

含义：

- Prometheus **只加载**同时带 `release: prometheus` 和
  `platform.gitops/managed: "true"` 的 PrometheusRule；
- Alertmanager **只合并**带 `platform.gitops/managed: "true"` 的
  AlertmanagerConfig；
- 手工创建但没打标签的规则/配置会被忽略。

> 这是声明式白名单，不是安全边界。有写权限的人仍可伪造标签；
> 真正强制需要 RBAC / Kyverno / OPA。

---

## 2. 日常状态检查

```bash
export KUBECONFIG=~/.kube/deeptutor-config
```

### 2.1 ArgoCD

```bash
# 所有应用
kubectl -n argocd get applications

# 监控相关
kubectl -n argocd get app platform-monitoring-stack
kubectl -n argocd get app platform-monitoring-crds
kubectl -n argocd get app platform-monitoring-rules
kubectl -n argocd get app platform-monitoring-wecom
kubectl -n argocd get app platform-grafana

# 看某次操作结果
kubectl -n argocd get app platform-monitoring-stack -o json \
  | jq '{sync:.status.sync.status,health:.status.health.status,
         op:.status.operationState.phase,msg:.status.operationState.message}'
```

正常状态：

```text
Succeeded / Synced / Healthy
```

### 2.2 Prometheus

```bash
kubectl -n monitoring get pod prometheus-prometheus-prometheus-0
kubectl -n monitoring get prometheus prometheus-prometheus

kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090
```

常用 API：

```bash
# 就绪
curl -s localhost:9090/-/ready

# 规则健康度
curl -s localhost:9090/api/v1/rules \
  | jq '{groups:(.data.groups|length),
         alerts:([.data.groups[].rules[]|select(.type=="alerting")]|length),
         bad:([.data.groups[].rules[]|select(.health!="ok")]|length)}'

# 当前 firing
curl -s localhost:9090/api/v1/alerts | jq '.data.alerts | length'

# 抓取目标
curl -s 'localhost:9090/api/v1/targets?state=active' \
  | jq '.data.activeTargets[] | {job:.labels.job, health, lastError}'
```

### 2.3 Alertmanager

```bash
kubectl -n monitoring get pod alertmanager-prometheus-alertmanager-0
kubectl -n monitoring get alertmanager prometheus-alertmanager

kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093
```

常用 API：

```bash
curl -s localhost:9093/api/v2/status | jq
curl -s localhost:9093/api/v2/alerts | jq
curl -s localhost:9093/api/v2/silences | jq
```

在 Pod 内使用 `amtool`：

```bash
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 alert query

kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=SomeAlert --duration=2h --comment="maintenance"
```

### 2.4 企业微信适配器

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=wecom-adapter
kubectl -n monitoring port-forward svc/wecom-adapter 8080:8080

curl -s localhost:8080/healthz
curl -s localhost:8080/stats | jq
```

`/stats` 字段：

- `received`：收到的 webhook 数；
- `sent`：成功投递企业微信数；
- `failed`：失败数；
- `last_errcode`：企业微信返回码，0 为成功；
- `last_error`：最近一次错误。

### 2.5 Grafana

```bash
kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
```

admin 凭据：

```bash
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Dashboard 健康度：

```bash
kubectl -n monitoring get grafanadashboards -o json \
  | jq '[.items[].status.conditions[]?
         | select(.type=="NoMatchingInstance" and .status=="True")]|length'
```

返回 `0` 为正常。

---

## 3. Prometheus 规则运维

### 3.1 规则来源

| 来源 | 位置 | 是否手工编辑 |
|---|---|---|
| chart 自带 35 个 | chart 内部 | ❌ 不要改，升级随 chart |
| 平台自建 6 个 | `platform/monitoring/rules/` | ✅ |
| deeptutor 2 个 | `deeptutor-gitops` | ✅ 团队仓库 |
| compassio 1 个 | `compassio-gitops` | ✅ 团队仓库 |

### 3.2 新增/修改平台规则

1. 在 `platform/monitoring/rules/` 新建 YAML：

   ```yaml
   apiVersion: monitoring.coreos.com/v1
   kind: PrometheusRule
   metadata:
     name: my-service-alerts
     namespace: monitoring
     labels:
       release: prometheus
   spec:
     groups:
       - name: my-service.rules
         rules:
           - alert: MyServiceDown
             expr: up{job="my-service"} == 0
             for: 5m
             labels:
               severity: critical
             annotations:
               summary: "my-service target down"
   ```

2. 加入 `platform/monitoring/rules/kustomization.yaml` 的 `resources`。
3. 本地校验：

   ```bash
   kubectl kustomize platform/monitoring/rules | grep -A3 'kind: PrometheusRule'
   kubectl apply --dry-run=client -k platform/monitoring/rules
   ```

4. 提交并推送。ArgoCD `platform-monitoring-rules` 自动同步。
5. 验证：

   ```bash
   kubectl -n monitoring get prometheusrules my-service-alerts -o jsonpath='{.metadata.labels}{"\n"}'
   # 必须包含 platform.gitops/managed=true 和 release=prometheus
   ```

> 新建文件必须带 `metadata.labels`（至少 `release: prometheus`），
> 因为 Kustomize patch 是在 `/metadata/labels/` 下追加白名单标签。

### 3.3 为什么规则没被加载

按顺序排查：

```bash
# 1. 标签是否齐全
kubectl -n monitoring get prometheusrules <name> -o jsonpath='{.metadata.labels}{"\n"}'

# 2. Prometheus 实际选择器
kubectl -n monitoring get prometheus prometheus-prometheus \
  -o jsonpath='{.spec.ruleSelector}{"\n"}'

# 3. Operator 是否报错
kubectl -n monitoring logs deploy/prometheus-operator --tail=100 | grep -i error

# 4. Prometheus 是否加载
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules | jq -r '.data.groups[].rules[].name' | grep <AlertName>
```

常见原因：

- 少了 `platform.gitops/managed: "true"`；
- 少了 `release: prometheus`；
- YAML 写在 base 但没被 Kustomize/ArgoCD 引用；
- 表达式非法，Prometheus `health=err`（见 `/api/v1/rules` 的 `lastError`）。

---

## 4. Alertmanager 运维

### 4.1 配置层级

```text
platform/monitoring/values.yaml
  └─ alertmanager.config
       └─ Secret alertmanager-prometheus-alertmanager
            └─ Operator 校验/规范化
                 └─ Secret alertmanager-prometheus-alertmanager-generated
                      └─ Alertmanager Pod 挂载
```

- 全局路由/接收器：改 `values.yaml`；
- 团队级路由：用 `AlertmanagerConfig` CR，必须带白名单标签。

### 4.2 修改全局路由

编辑 `values.yaml`：

```yaml
alertmanager:
  config:
    route:
      receiver: n8n-webhook
      routes:
        - matchers: [severity =~ "critical|warning"]
          receiver: n8n-webhook
          continue: true
        - matchers: [severity =~ "critical|warning"]
          receiver: wecom
          continue: true
    receivers:
      - name: n8n-webhook
        webhook_configs:
          - url: https://...
            send_resolved: true
      - name: wecom
        webhook_configs:
          - url: http://wecom-adapter.monitoring.svc:8080/
            send_resolved: true
            max_alerts: 10
```

提交推送后 ArgoCD 自动同步。验证：

```bash
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 config show
```

### 4.3 团队 AlertmanagerConfig

必须带标签，否则不会被合并：

```yaml
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: team-routes
  namespace: deeptutor
  labels:
    platform.gitops/managed: "true"
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

说明：

- `continue: true` 表示团队通道之外，基础 n8n/企业微信仍会收到；
- 一定要带 `namespace` matcher，避免接到其他团队告警；
- 修改后检查生成配置：

  ```bash
  kubectl -n monitoring get secret alertmanager-prometheus-alertmanager-generated \
    -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip -c \
    | grep -A5 team-webhook
  ```

### 4.4 静默（Silence）

```bash
# 新增 2 小时静默
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=HighCPU --duration=2h --comment="maintenance"

# 查询
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 silence query

# 过期
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 silence expire <silence-id>
```

> Silence 存在 PVC 里，不属于 GitOps；重建 Alertmanager 后可能丢失。

---

## 5. 企业微信链路

### 5.1 链路

```text
Prometheus -> Alertmanager -> wecom receiver
  -> http://wecom-adapter.monitoring.svc:8080/
  -> qyapi.weixin.qq.com 群机器人
```

### 5.2 排查

```bash
# 1. Pod 健康
kubectl -n monitoring get pods -l app.kubernetes.io/name=wecom-adapter

# 2. 适配器统计
kubectl -n monitoring port-forward svc/wecom-adapter 8080:8080 &
curl -s localhost:8080/stats | jq

# 3. DNS / 出网
kubectl -n monitoring exec -i deploy/wecom-adapter -c adapter -- python3 -c \
  "import socket; print(socket.getaddrinfo('qyapi.weixin.qq.com',443)[0][4][0])"

# 4. Alertmanager 是否配置 wecom
kubectl -n monitoring exec alertmanager-prometheus-alertmanager-0 -c alertmanager -- \
  amtool --alertmanager.url=http://localhost:9093 config show | grep -A5 wecom
```

常见问题：

| 现象 | 原因 | 处理 |
|---|---|---|
| `URLError [Errno -3]` | DNS 被 NetworkPolicy 挡 | 放行到 kube-dns Pod 的 53/UDP、53/TCP |
| `errcode 93000/40058` | webhook key 无效 | 更新 `wecom-adapter` SealedSecret |
| `errcode 45009` | 触发 20 条/分钟限流 | 降低频率/合并告警 |
| `errcode 0` 但无消息 | 群机器人被移除/群不对 | 检查企业微信后台 |

### 5.3 轮换 webhook URL

```bash
# 1. 从现有 Secret 生成新 Secret（只改 webhook-url）
kubectl -n monitoring get secret wecom-adapter -o yaml > /tmp/wecom.yaml
# 编辑 /tmp/wecom.yaml 的 data.webhook-url（base64）

# 2. 重新 seal
kubeseal --format yaml \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  < /tmp/wecom.yaml > platform/monitoring/wecom/sealedsecret.yaml

# 3. 提交推送后，重启适配器让 env 重新注入
kubectl -n monitoring rollout restart deploy/wecom-adapter
```

---

## 6. Grafana

### 6.1 登录与凭据

```bash
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

### 6.2 轮换 admin 密码

```bash
# 1. 取现有 secret，保留 admin-user / admin-password / ldap-toml 三个 key
kubectl -n monitoring get secret prometheus-grafana-admin -o yaml > /tmp/grafana-admin.yaml
# 修改 data.admin-password（base64）

# 2. 重新 seal
kubeseal --format yaml \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  < /tmp/grafana-admin.yaml \
  > platform/monitoring/stack/sealedsecret-grafana-admin.yaml

# 3. 提交推送；Secret 更新不会自动重启 Grafana，需要手动 rollout
kubectl -n monitoring rollout restart deploy/prometheus-grafana
```

### 6.3 RWO PVC 死锁

Grafana 的 `prometheus-grafana-ceph` 是 RWO，跨节点滚动会卡在：

```text
FailedAttachVolume: Volume is already used by pod(s)
```

已通过 `grafana.deploymentStrategy: Recreate` 规避。
如果仍然出现：

```bash
kubectl -n monitoring scale deploy prometheus-grafana --replicas=0
kubectl -n monitoring wait --for=delete pod -l app.kubernetes.io/name=grafana --timeout=120s
kubectl -n monitoring scale deploy prometheus-grafana --replicas=1
```

### 6.4 Dashboard NoMatchingInstance

原因通常是 Grafana CR 引用的 admin Secret 不存在，或 operator 需要重启：

```bash
kubectl -n monitoring get grafana prometheus-grafana -o jsonpath='{.spec.external}{"\n"}'
kubectl -n grafana-operator rollout restart deploy/grafana-operator
kubectl -n monitoring get grafana prometheus-grafana -o json \
  | jq '.status.conditions'
# 期望 GrafanaReady=True
```

---

## 7. 变更流程

### 7.1 标准 GitOps 流程

1. 修改 Git 文件；
2. 本地校验（`kubectl kustomize` / `helm template` / `kubectl apply --dry-run`）；
3. 提交并推送 `main`；
4. ArgoCD 自动/手动同步；
5. 验证状态和业务指标。

### 7.2 触发同步

```bash
# 普通刷新
kubectl -n argocd annotate app platform-monitoring-stack \
  argocd.argoproj.io/refresh=normal --overwrite

# 强制重新拉取（值没更新时用）
kubectl -n argocd annotate app platform-monitoring-stack \
  argocd.argoproj.io/refresh=hard --overwrite

# 手动触发一次 sync
kubectl -n argocd patch app platform-monitoring-stack --type merge \
  -p '{"operation":{"sync":{"prune":false,
       "syncOptions":["ServerSideApply=true","RespectIgnoreDifferences=true"]}}}'
```

### 7.3 回滚

优先 Git revert：

```bash
cd platform-gitops
git revert <commit>
git push origin main
```

紧急停用自动同步：

```bash
kubectl -n argocd patch app platform-monitoring-stack --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

> 不要用 `helm rollback`：资源已由 ArgoCD 接管，Helm 与 ArgoCD 混用会冲突。

---

## 8. 升级

### 8.1 升级 kube-prometheus-stack

1. 修改 `clusters/prod/applications/platform-monitoring-stack.yaml`：

   ```yaml
   targetRevision: 84.x.x
   ```

2. **更新 CRD（GitOps）**：

   当前 CRD 由 `platform-monitoring-crds` App 管理，源在
   `platform/monitoring/crds/`。升级时：

   ```bash
   # 导出新版本 CRD，按 CRD 名拆分覆盖 platform/monitoring/crds/ 下的文件
   helm show crds prometheus-community/kube-prometheus-stack --version 84.x.x \
     > /tmp/kps-crds.yaml
   ```

   提交推送后 `platform-monitoring-crds` 自动同步。
   仅在 ArgoCD 不可用时才手工兜底：

   ```bash
   kubectl apply --server-side --force-conflicts -f /tmp/kps-crds.yaml
   ```

3. 提交 App 变更并推送；
4. 检查：

   ```bash
   kubectl -n argocd get app platform-monitoring-stack
   kubectl -n monitoring get prometheus prometheus-prometheus
   kubectl -n monitoring get alertmanager prometheus-alertmanager
   ```

5. 如果新版本又出现 CRD/schema diff，按需调整 `ignoreDifferences`。

### 8.2 CRD 版本一致性

```bash
kubectl get crd -o json | jq -r '.items[]
  | select(.metadata.name|test("monitoring.coreos.com$"))
  | [.metadata.name, .metadata.annotations["operator.prometheus.io/version"]]
  | @tsv'
```

应与运行的 operator 版本一致。当前：`0.90.1`。

---

## 9. 故障排查速查

| 现象 | 优先检查 |
|---|---|
| 规则不加载 | `platform.gitops/managed` / `release` 标签、`ruleSelector`、Operator 日志 |
| AlertmanagerConfig 不生效 | 白名单标签、namespace matcher、生成 Secret |
| 企业微信无消息 | adapter `/healthz`、`/stats`、DNS、webhook key、Route |
| n8n 无消息 | n8n 服务/Cloudflare；当前已知 `connection reset` |
| Prometheus Pod `Init:0/1` | fsGroup 递归 chown、PVC 挂载、`fsGroupChangePolicy` |
| Grafana Pod `Init:0/1` | RWO PVC 跨节点、Deployment 策略 |
| Grafana Dashboard 不同步 | admin Secret 引用、重启 grafana-operator |
| `hostNetwork: field not declared` | CRD 落后，升级 CRD |
| Alertmanager 配置不生效 | `amtool check-config`、生成 Secret、Operator 日志 |
| Ceph 池满 | `ceph df`、孤儿 RBD 镜像、`MAX AVAIL` |
| Alertmanager silence 丢失 | PVC 数据；silence 是运行时状态 |

---

## 10. 注意事项（Do / Don't）

### Do

- 所有规则/配置通过 Git 修改；
- PrometheusRule 必须带 `release: prometheus` 和 `platform.gitops/managed: "true"`；
- AlertmanagerConfig 必须带 `platform.gitops/managed: "true"`；
- 每次变更后检查 ArgoCD 状态和 Prometheus `/api/v1/rules`；
- 升级 chart 前先备份 CRD、先升级 CRD；
- 轮换 Secret 后重启对应 Deployment（env 不会自动更新）；
- 定期检查 Grafana Dashboard、WeCom `/stats`、PVC 容量。

### Don't

- ❌ 不要 `helm upgrade/rollback prometheus`；
- ❌ 不要手工创建不带白名单标签的 PrometheusRule/AlertmanagerConfig；
- ❌ 不要直接改 Operator 生成的 `*-generated` Secret；
- ❌ 不要删除 PVC 或强制删除 RWO Pod；
- ❌ 不要修改 chart 自带的 35 个规则（升级会覆盖）；
- ❌ 不要把高基数指标直接写进告警表达式；
- ❌ 不要依赖标签做安全隔离（需要 RBAC/准入策略）。

### 两个已知边界

1. **`prune: false`**
   从 Git 删除 chart 资源不会自动删除集群对象；chart 升级后需要人工清理。
2. **CRD 由独立 App 管理**
   `platform-monitoring-crds` 管理 `platform/monitoring/crds/`，
   `prune: false`；升级 chart 时更新 vendored CRD 文件并提交。

---

## 11. 常用命令速查

```bash
export KUBECONFIG=~/.kube/deeptutor-config

# ArgoCD
kubectl -n argocd get applications
kubectl -n argocd get app platform-monitoring-stack
kubectl -n argocd get app platform-monitoring-crds
kubectl -n argocd get app platform-monitoring-rules
kubectl -n argocd get app platform-monitoring-wecom

# Prometheus
kubectl -n monitoring port-forward svc/prometheus-prometheus 9090:9090 &
curl -s localhost:9090/api/v1/rules | jq
curl -s localhost:9090/api/v1/alerts | jq
curl -s 'localhost:9090/api/v1/targets?state=active' | jq

# Alertmanager
kubectl -n monitoring port-forward svc/prometheus-alertmanager 9093:9093 &
curl -s localhost:9093/api/v2/status | jq
curl -s localhost:9093/api/v2/alerts | jq

# 规则标签检查
kubectl get prometheusrules -A -o json \
  | jq '[.items[] | select(.metadata.labels["platform.gitops/managed"]=="true")]|length'
# 期望 44

# 企业微信
kubectl -n monitoring get pods -l app.kubernetes.io/name=wecom-adapter
kubectl -n monitoring port-forward svc/wecom-adapter 8080:8080 &
curl -s localhost:8080/stats | jq

# Grafana
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
kubectl -n monitoring get grafanadashboards -o json \
  | jq '[.items[].status.conditions[]?
         | select(.type=="NoMatchingInstance" and .status=="True")]|length'
```

---

## 12. 参考

- 第一期记录：`/root/monitoring-gitops-phase1.md`
- 第二/三期记录：`/root/monitoring-gitops-phase2-3.md`
- 仓库说明：`platform/monitoring/README.md`
- 关键提交：

  ```text
  a2121c5 docs(monitoring): document CRD GitOps workflow
  c2160d3 feat(monitoring): manage prometheus-operator CRDs in GitOps
  610f993 docs(monitoring): record GitOps allowlist selectors
  6ebe572 feat(monitoring): restrict rule and AlertmanagerConfig discovery to GitOps-managed objects
  e861a59 feat(monitoring): add GitOps allowlist label to all PrometheusRules
  7771914 fix(monitoring): drop hostNetwork ignore after prometheus-operator CRD 0.90.1 upgrade
  4ab1868 feat(monitoring): enable self-heal for kube-prometheus-stack app without prune
  0bff5d7 fix(grafana): point operator client at prometheus-grafana-admin secret
  a708e2a feat(monitoring): adopt kube-prometheus-stack into ArgoCD
  cbdd96d feat(monitoring): move wecom-adapter into GitOps
  9a341c2 feat(monitoring): manage PrometheusRules in GitOps and route alerts to WeCom
  ```
